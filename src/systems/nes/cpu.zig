const std = @import("std");
const TestBus = @import("bus.zig").TestBus;
const Access = @import("bus.zig").Access;

pub const Status = packed struct(u8) {
    carry: bool = false,
    zero: bool = false,
    interrupt_disable: bool = true,
    decimal: bool = false,
    break_flag: bool = false,
    unused: bool = true,
    overflow: bool = false,
    negative: bool = false,
};

/// Ricoh 2A03 CPU state. Decimal arithmetic is deliberately absent: the NES
/// CPU carries the decimal flag but does not perform BCD adjustment.
pub const Cpu = struct {
    const RmwOperation = enum { asl, lsr, rol, ror, inc, dec };

    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    sp: u8 = 0xfd,
    pc: u16 = 0,
    status: Status = .{},
    cycles: u64 = 0,
    irq_pending: bool = false,
    nmi_pending: bool = false,
    nmi_vector_hijack: bool = false,
    nmi_hijack_consumed: bool = false,
    nmi_after_vector_select: bool = false,
    irq_poll_one_cycle_early: bool = false,
    /// CLI, SEI, and PLP expose their new I flag immediately to software but
    /// IRQ polling at the following instruction boundary still uses the old
    /// value. RTI is intentionally excluded because its restored I flag takes
    /// effect immediately.
    irq_i_override: ?bool = null,

    pub fn reset(self: *Cpu, bus: *TestBus) void {
        self.* = .{};
        self.sp = 0xfd;
        self.status.interrupt_disable = true;
        self.pc = read16(bus, 0xfffc);
        self.cycles = 7;
    }

    /// Signals are sampled at instruction boundaries. A latched NMI always
    /// wins over IRQ; IRQ remains pending while the I flag masks it.
    pub fn requestIrq(self: *Cpu) void {
        self.irq_pending = true;
    }

    /// Updates the level of the shared maskable-IRQ line. Cartridge and APU
    /// sources are level-triggered: once every source acknowledges, a masked
    /// IRQ must not remain latched and fire later after RTI.
    pub fn setIrqLine(self: *Cpu, asserted: bool) void {
        self.irq_pending = asserted;
    }

    pub fn requestNmi(self: *Cpu) void {
        self.nmi_pending = true;
    }

    pub fn observeNmiEdge(self: *Cpu) void {
        self.nmi_vector_hijack = true;
    }

    pub fn takeNmiHijackConsumed(self: *Cpu) bool {
        const consumed = self.nmi_hijack_consumed;
        self.nmi_hijack_consumed = false;
        return consumed;
    }

    pub fn takeNmiAfterVectorSelect(self: *Cpu) bool {
        const late = self.nmi_after_vector_select;
        self.nmi_after_vector_select = false;
        return late;
    }

    /// Executes one supported instruction and returns its cycle count. This
    /// initial P1 slice records all architecturally visible bus reads/writes;
    /// undocumented opcodes and interrupt micro-sequences are added later.
    pub fn step(self: *Cpu, bus: *TestBus) !u8 {
        self.irq_poll_one_cycle_early = false;
        const irq_disabled = self.irq_i_override orelse self.status.interrupt_disable;
        self.irq_i_override = null;
        if (self.nmi_pending) {
            self.nmi_pending = false;
            self.nmi_vector_hijack = false;
            return self.serviceInterrupt(bus, 0xfffa);
        }
        if (self.irq_pending and !irq_disabled) {
            self.irq_pending = false;
            return self.serviceInterrupt(bus, 0xfffe);
        }

        const opcode = self.fetchByte(bus);
        const previous_interrupt_disable = self.status.interrupt_disable;
        const elapsed: u8 = switch (opcode) {
            0x00 => self.brk(bus),
            0x08 => self.php(bus),
            0x09 => self.ora(self.fetchByte(bus)),
            0x0a => self.aslAccumulator(),
            0x06 => self.rmwZeroPageOperation(bus, .asl),
            0x0e => self.rmwAbsoluteOperation(bus, .asl),
            0x16 => self.rmwZeroPageIndexedOperation(bus, self.x, .asl),
            0x1e => self.rmwAbsoluteIndexedOperation(bus, self.x, .asl),
            0x10 => self.branch(bus, !self.status.negative), // BPL
            0x01 => self.operateIndexedIndirect(bus, Cpu.ora),
            0x05 => self.operateZeroPage(bus, Cpu.ora),
            0x0d => self.operateAbsolute(bus, Cpu.ora),
            0x11 => self.operateIndirectIndexed(bus, Cpu.ora),
            0x15 => self.operateZeroPageIndexed(bus, self.x, Cpu.ora),
            0x19 => self.operateAbsoluteIndexed(bus, self.y, Cpu.ora),
            0x1d => self.operateAbsoluteIndexed(bus, self.x, Cpu.ora),
            0x18 => blk: {
                self.status.carry = false;
                break :blk 2;
            }, // CLC
            0x20 => self.jsr(bus),
            0x28 => self.plp(bus),
            0x29 => self.andValue(self.fetchByte(bus)),
            0x2a => self.rolAccumulator(),
            0x26 => self.rmwZeroPageOperation(bus, .rol),
            0x2e => self.rmwAbsoluteOperation(bus, .rol),
            0x36 => self.rmwZeroPageIndexedOperation(bus, self.x, .rol),
            0x3e => self.rmwAbsoluteIndexedOperation(bus, self.x, .rol),
            0x24 => self.bitZeroPage(bus),
            0x2c => self.bitAbsolute(bus),
            0x21 => self.operateIndexedIndirect(bus, Cpu.andValue),
            0x25 => self.operateZeroPage(bus, Cpu.andValue),
            0x2d => self.operateAbsolute(bus, Cpu.andValue),
            0x31 => self.operateIndirectIndexed(bus, Cpu.andValue),
            0x30 => self.branch(bus, self.status.negative), // BMI
            0x35 => self.operateZeroPageIndexed(bus, self.x, Cpu.andValue),
            0x39 => self.operateAbsoluteIndexed(bus, self.y, Cpu.andValue),
            0x3d => self.operateAbsoluteIndexed(bus, self.x, Cpu.andValue),
            0x38 => blk: {
                self.status.carry = true;
                break :blk 2;
            }, // SEC
            0x40 => self.rti(bus),
            0x48 => self.pha(bus),
            0x49 => self.eor(self.fetchByte(bus)),
            0x4a => self.lsrAccumulator(),
            0x4c => self.jmpAbsolute(bus),
            0x4e => self.lsrAbsolute(bus),
            0x46 => self.rmwZeroPageOperation(bus, .lsr),
            0x56 => self.rmwZeroPageIndexedOperation(bus, self.x, .lsr),
            0x5e => self.rmwAbsoluteIndexedOperation(bus, self.x, .lsr),
            0x41 => self.operateIndexedIndirect(bus, Cpu.eor),
            0x45 => self.operateZeroPage(bus, Cpu.eor),
            0x4d => self.operateAbsolute(bus, Cpu.eor),
            0x6c => self.jmpIndirect(bus),
            0x50 => self.branch(bus, !self.status.overflow), // BVC
            0x51 => self.operateIndirectIndexed(bus, Cpu.eor),
            0x55 => self.operateZeroPageIndexed(bus, self.x, Cpu.eor),
            0x59 => self.operateAbsoluteIndexed(bus, self.y, Cpu.eor),
            0x58 => blk: {
                self.status.interrupt_disable = false;
                break :blk 2;
            }, // CLI
            0x60 => self.rts(bus),
            0x69 => self.adc(self.fetchByte(bus)),
            0x68 => self.pla(bus),
            0x6a => self.rorAccumulator(),
            0x66 => self.rmwZeroPageOperation(bus, .ror),
            0x6e => self.rmwAbsoluteOperation(bus, .ror),
            0x76 => self.rmwZeroPageIndexedOperation(bus, self.x, .ror),
            0x7e => self.rmwAbsoluteIndexedOperation(bus, self.x, .ror),
            0x70 => self.branch(bus, self.status.overflow), // BVS
            0x5d => self.operateAbsoluteIndexed(bus, self.x, Cpu.eor),
            0x61 => self.operateIndexedIndirect(bus, Cpu.adc),
            0x65 => self.operateZeroPage(bus, Cpu.adc),
            0x6d => self.operateAbsolute(bus, Cpu.adc),
            0x71 => self.operateIndirectIndexed(bus, Cpu.adc),
            0x75 => self.operateZeroPageIndexed(bus, self.x, Cpu.adc),
            0x79 => self.operateAbsoluteIndexed(bus, self.y, Cpu.adc),
            0x7d => self.operateAbsoluteIndexed(bus, self.x, Cpu.adc),
            0x78 => blk: {
                self.status.interrupt_disable = true;
                break :blk 2;
            }, // SEI
            0x81 => self.staIndexedIndirect(bus),
            0x84 => self.styZeroPage(bus),
            0x85 => self.staZeroPage(bus),
            0x88 => blk: {
                self.y -%= 1;
                self.setZn(self.y);
                break :blk 2;
            }, // DEY
            0x86 => self.stxZeroPage(bus),
            0x8a => self.transfer(&self.a, self.x), // TXA
            0x8c => self.styAbsolute(bus),
            0x8d => self.staAbsolute(bus),
            0x8e => self.stxAbsolute(bus),
            0x91 => self.staIndirectIndexed(bus),
            0x99 => self.staAbsoluteY(bus),
            0x9d => self.staAbsoluteX(bus),
            0x90 => self.branch(bus, !self.status.carry), // BCC
            0x94 => self.styZeroPageX(bus),
            0x95 => self.staZeroPageX(bus),
            0x96 => self.stxZeroPageY(bus),
            0x98 => blk: {
                self.a = self.y;
                self.setZn(self.a);
                break :blk 2;
            }, // TYA
            0x9a => blk: {
                self.sp = self.x;
                break :blk 2;
            }, // TXS
            0xa0 => self.ldy(self.fetchByte(bus)),
            0xa2 => self.ldx(self.fetchByte(bus)),
            0xa9 => self.lda(self.fetchByte(bus)),
            0xa8 => self.transfer(&self.y, self.a), // TAY
            0xaa => self.transfer(&self.x, self.a), // TAX
            0xa1 => self.ldaIndexedIndirect(bus),
            0xa4 => self.ldyZeroPage(bus),
            0xa5 => self.ldaZeroPage(bus),
            0xa6 => self.ldxZeroPage(bus),
            0xad => self.ldaAbsolute(bus),
            0xae => self.ldxAbsolute(bus),
            0xac => self.ldyAbsolute(bus),
            0xbd => self.ldaAbsoluteX(bus),
            0xb0 => self.branch(bus, self.status.carry), // BCS
            0xb1 => self.ldaIndirectIndexed(bus),
            0xb4 => self.ldyZeroPageX(bus),
            0xb5 => self.ldaZeroPageX(bus),
            0xb6 => self.ldxZeroPageY(bus),
            0xb8 => blk: {
                self.status.overflow = false;
                break :blk 2;
            }, // CLV
            0xb9 => self.ldaAbsoluteY(bus),
            0xba => blk: {
                self.x = self.sp;
                self.setZn(self.x);
                break :blk 2;
            }, // TSX
            0xbc => self.ldyAbsoluteX(bus),
            0xbe => self.ldxAbsoluteY(bus),
            0xc0 => self.compare(self.y, self.fetchByte(bus)),
            0xc9 => self.compare(self.a, self.fetchByte(bus)),
            0xc1 => self.compareIndexedIndirect(bus),
            0xc4 => self.compareZeroPage(bus, self.y),
            0xc5 => self.compareZeroPage(bus, self.a),
            0xc6 => self.decZeroPage(bus),
            0xd6 => self.rmwZeroPageIndexedOperation(bus, self.x, .dec),
            0xde => self.rmwAbsoluteIndexedOperation(bus, self.x, .dec),
            0xcc => self.compareAbsolute(bus, self.y),
            0xcd => self.compareAbsolute(bus, self.a),
            0xce => self.decAbsolute(bus),
            0xc8 => blk: {
                self.y +%= 1;
                self.setZn(self.y);
                break :blk 2;
            }, // INY
            0xca => blk: {
                self.x -%= 1;
                self.setZn(self.x);
                break :blk 2;
            }, // DEX
            0xd0 => self.branch(bus, !self.status.zero), // BNE
            0xd1 => self.compareIndirectIndexed(bus),
            0xd5 => self.compareZeroPageIndexed(bus, self.a, self.x),
            0xd9 => self.compareAbsoluteIndexed(bus, self.y),
            0xd8 => blk: {
                self.status.decimal = false;
                break :blk 2;
            }, // CLD (flag only on 2A03)
            0xdd => self.compareAbsoluteIndexed(bus, self.x),
            0xe0 => self.compare(self.x, self.fetchByte(bus)),
            0xe1 => self.operateIndexedIndirect(bus, Cpu.sbc),
            0xe4 => self.compareZeroPage(bus, self.x),
            0xe5 => self.operateZeroPage(bus, Cpu.sbc),
            0xe6 => self.incZeroPage(bus),
            0xf6 => self.rmwZeroPageIndexedOperation(bus, self.x, .inc),
            0xfe => self.rmwAbsoluteIndexedOperation(bus, self.x, .inc),
            0xec => self.compareAbsolute(bus, self.x),
            0xed => self.operateAbsolute(bus, Cpu.sbc),
            0xee => self.incAbsolute(bus),
            0xe8 => blk: {
                self.x +%= 1;
                self.setZn(self.x);
                break :blk 2;
            }, // INX
            0xea => 2, // NOP
            0xe9 => self.sbc(self.fetchByte(bus)),
            0xf0 => self.branch(bus, self.status.zero), // BEQ
            0xf1 => self.operateIndirectIndexed(bus, Cpu.sbc),
            0xf5 => self.operateZeroPageIndexed(bus, self.x, Cpu.sbc),
            0xf8 => blk: {
                self.status.decimal = true;
                break :blk 2;
            }, // SED (flag remains observable; arithmetic stays binary)
            0xf9 => self.operateAbsoluteIndexed(bus, self.y, Cpu.sbc),
            0xfd => self.operateAbsoluteIndexed(bus, self.x, Cpu.sbc),
            else => return error.UnsupportedOpcode,
        };
        if (opcode == 0x28 or opcode == 0x58 or opcode == 0x78) {
            self.irq_i_override = previous_interrupt_disable;
        }
        self.cycles += elapsed;
        return elapsed;
    }

    fn lda(self: *Cpu, value: u8) u8 {
        self.a = value;
        self.setZn(value);
        return 2;
    }

    fn ldx(self: *Cpu, value: u8) u8 {
        self.x = value;
        self.setZn(value);
        return 2;
    }

    fn ldy(self: *Cpu, value: u8) u8 {
        self.y = value;
        self.setZn(value);
        return 2;
    }

    fn adc(self: *Cpu, value: u8) u8 {
        const carry: u16 = @intFromBool(self.status.carry);
        const sum: u16 = @as(u16, self.a) + value + carry;
        const result: u8 = @truncate(sum);
        self.status.carry = sum > 0xff;
        self.status.overflow = ((self.a ^ result) & (value ^ result) & 0x80) != 0;
        self.a = result;
        self.setZn(result);
        return 2;
    }

    fn sbc(self: *Cpu, value: u8) u8 {
        return self.adc(~value);
    }

    fn andValue(self: *Cpu, value: u8) u8 {
        self.a &= value;
        self.setZn(self.a);
        return 2;
    }

    fn ora(self: *Cpu, value: u8) u8 {
        self.a |= value;
        self.setZn(self.a);
        return 2;
    }

    fn eor(self: *Cpu, value: u8) u8 {
        self.a ^= value;
        self.setZn(self.a);
        return 2;
    }

    fn operateZeroPage(self: *Cpu, bus: *TestBus, comptime operation: fn (*Cpu, u8) u8) u8 {
        const address = self.fetchByte(bus);
        _ = operation(self, bus.read(address));
        return 3;
    }

    fn operateZeroPageIndexed(self: *Cpu, bus: *TestBus, index: u8, comptime operation: fn (*Cpu, u8) u8) u8 {
        const base = self.fetchByte(bus);
        _ = bus.read(base);
        _ = operation(self, bus.read(base +% index));
        return 4;
    }

    fn operateAbsolute(self: *Cpu, bus: *TestBus, comptime operation: fn (*Cpu, u8) u8) u8 {
        const address = self.fetchWord(bus);
        _ = operation(self, bus.read(address));
        return 4;
    }

    fn operateAbsoluteIndexed(self: *Cpu, bus: *TestBus, index: u8, comptime operation: fn (*Cpu, u8) u8) u8 {
        const base = self.fetchWord(bus);
        const address = base +% index;
        if ((base & 0xff00) != (address & 0xff00)) {
            _ = bus.read((base & 0xff00) | (address & 0x00ff));
            _ = operation(self, bus.read(address));
            return 5;
        }
        _ = operation(self, bus.read(address));
        return 4;
    }

    fn operateIndexedIndirect(self: *Cpu, bus: *TestBus, comptime operation: fn (*Cpu, u8) u8) u8 {
        const base = self.fetchByte(bus);
        _ = bus.read(base);
        const address = readZeroPage16(bus, base +% self.x);
        _ = operation(self, bus.read(address));
        return 6;
    }

    fn operateIndirectIndexed(self: *Cpu, bus: *TestBus, comptime operation: fn (*Cpu, u8) u8) u8 {
        const pointer = self.fetchByte(bus);
        const base = readZeroPage16(bus, pointer);
        const address = base +% self.y;
        if ((base & 0xff00) != (address & 0xff00)) {
            _ = bus.read((base & 0xff00) | (address & 0x00ff));
            _ = operation(self, bus.read(address));
            return 6;
        }
        _ = operation(self, bus.read(address));
        return 5;
    }

    fn transfer(self: *Cpu, destination: *u8, source: u8) u8 {
        destination.* = source;
        self.setZn(source);
        return 2;
    }

    fn bit(self: *Cpu, value: u8) void {
        self.status.zero = (self.a & value) == 0;
        self.status.negative = value & 0x80 != 0;
        self.status.overflow = value & 0x40 != 0;
    }

    fn compare(self: *Cpu, register: u8, value: u8) u8 {
        self.status.carry = register >= value;
        self.setZn(register -% value);
        return 2;
    }

    fn aslAccumulator(self: *Cpu) u8 {
        self.status.carry = self.a & 0x80 != 0;
        self.a <<= 1;
        self.setZn(self.a);
        return 2;
    }

    fn rolAccumulator(self: *Cpu) u8 {
        const carry_in: u8 = @intFromBool(self.status.carry);
        self.status.carry = self.a & 0x80 != 0;
        self.a = (self.a << 1) | carry_in;
        self.setZn(self.a);
        return 2;
    }

    fn rorAccumulator(self: *Cpu) u8 {
        const carry_in: u8 = if (self.status.carry) 0x80 else 0;
        self.status.carry = self.a & 1 != 0;
        self.a = (self.a >> 1) | carry_in;
        self.setZn(self.a);
        return 2;
    }

    fn lsrAccumulator(self: *Cpu) u8 {
        self.status.carry = self.a & 1 != 0;
        self.a >>= 1;
        self.setZn(self.a);
        return 2;
    }

    fn pha(self: *Cpu, bus: *TestBus) u8 {
        _ = bus.read(self.pc);
        self.push(bus, self.a);
        return 3;
    }

    fn pla(self: *Cpu, bus: *TestBus) u8 {
        _ = bus.read(self.pc);
        _ = bus.read(0x0100 | @as(u16, self.sp));
        self.a = self.pull(bus);
        self.setZn(self.a);
        return 4;
    }

    fn php(self: *Cpu, bus: *TestBus) u8 {
        _ = bus.read(self.pc);
        var pushed = self.status;
        pushed.break_flag = true;
        pushed.unused = true;
        self.push(bus, @bitCast(pushed));
        return 3;
    }

    fn plp(self: *Cpu, bus: *TestBus) u8 {
        _ = bus.read(self.pc);
        _ = bus.read(0x0100 | @as(u16, self.sp));
        self.status = @bitCast(self.pull(bus));
        self.status.break_flag = false;
        self.status.unused = true;
        return 4;
    }

    fn staZeroPage(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchByte(bus);
        bus.write(address, self.a);
        return 3;
    }

    fn stxZeroPage(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchByte(bus);
        bus.write(address, self.x);
        return 3;
    }

    fn styZeroPage(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchByte(bus);
        bus.write(address, self.y);
        return 3;
    }

    fn staZeroPageX(self: *Cpu, bus: *TestBus) u8 {
        return self.storeZeroPageIndexed(bus, self.x, self.a);
    }

    fn stxZeroPageY(self: *Cpu, bus: *TestBus) u8 {
        return self.storeZeroPageIndexed(bus, self.y, self.x);
    }

    fn styZeroPageX(self: *Cpu, bus: *TestBus) u8 {
        return self.storeZeroPageIndexed(bus, self.x, self.y);
    }

    fn storeZeroPageIndexed(self: *Cpu, bus: *TestBus, index: u8, value: u8) u8 {
        const base = self.fetchByte(bus);
        _ = bus.read(base);
        bus.write(base +% index, value);
        return 4;
    }

    fn staIndexedIndirect(self: *Cpu, bus: *TestBus) u8 {
        const base = self.fetchByte(bus);
        _ = bus.read(base);
        const pointer = base +% self.x;
        const address = readZeroPage16(bus, pointer);
        bus.write(address, self.a);
        return 6;
    }

    fn staIndirectIndexed(self: *Cpu, bus: *TestBus) u8 {
        const pointer = self.fetchByte(bus);
        const base = readZeroPage16(bus, pointer);
        const address = base +% self.y;
        _ = bus.read((base & 0xff00) | (address & 0x00ff));
        bus.write(address, self.a);
        return 6;
    }

    fn staAbsolute(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchWord(bus);
        bus.write(address, self.a);
        return 4;
    }

    fn stxAbsolute(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchWord(bus);
        bus.write(address, self.x);
        return 4;
    }

    fn styAbsolute(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchWord(bus);
        bus.write(address, self.y);
        return 4;
    }

    fn jmpAbsolute(self: *Cpu, bus: *TestBus) u8 {
        self.pc = self.fetchWord(bus);
        return 3;
    }

    fn jmpIndirect(self: *Cpu, bus: *TestBus) u8 {
        const pointer = self.fetchWord(bus);
        const low = bus.read(pointer);
        // Original 6502 hardware does not carry into the next page when an
        // indirect pointer ends in $FF. NES software can rely on this bug.
        const high = bus.read((pointer & 0xff00) | ((pointer +% 1) & 0x00ff));
        self.pc = @as(u16, low) | (@as(u16, high) << 8);
        return 5;
    }

    fn ldaAbsoluteX(self: *Cpu, bus: *TestBus) u8 {
        return self.ldaAbsoluteIndexed(bus, self.x);
    }

    fn ldaAbsoluteY(self: *Cpu, bus: *TestBus) u8 {
        return self.ldaAbsoluteIndexed(bus, self.y);
    }

    fn ldaAbsoluteIndexed(self: *Cpu, bus: *TestBus, index: u8) u8 {
        const base = self.fetchWord(bus);
        const address = base +% index;
        if ((base & 0xff00) != (address & 0xff00)) {
            _ = bus.read((base & 0xff00) | (address & 0x00ff));
            _ = self.lda(bus.read(address));
            return 5;
        }
        _ = self.lda(bus.read(address));
        return 4;
    }

    fn ldxAbsoluteY(self: *Cpu, bus: *TestBus) u8 {
        const base = self.fetchWord(bus);
        const address = base +% self.y;
        if ((base & 0xff00) != (address & 0xff00)) {
            _ = bus.read((base & 0xff00) | (address & 0x00ff));
            _ = self.ldx(bus.read(address));
            return 5;
        }
        _ = self.ldx(bus.read(address));
        return 4;
    }

    fn ldyAbsoluteX(self: *Cpu, bus: *TestBus) u8 {
        const base = self.fetchWord(bus);
        const address = base +% self.x;
        if ((base & 0xff00) != (address & 0xff00)) {
            _ = bus.read((base & 0xff00) | (address & 0x00ff));
            _ = self.ldy(bus.read(address));
            return 5;
        }
        _ = self.ldy(bus.read(address));
        return 4;
    }

    fn ldaZeroPage(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchByte(bus);
        _ = self.lda(bus.read(address));
        return 3;
    }

    fn ldaZeroPageX(self: *Cpu, bus: *TestBus) u8 {
        const base = self.fetchByte(bus);
        _ = bus.read(base);
        _ = self.lda(bus.read(base +% self.x));
        return 4;
    }

    fn ldxZeroPage(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchByte(bus);
        _ = self.ldx(bus.read(address));
        return 3;
    }

    fn ldxZeroPageY(self: *Cpu, bus: *TestBus) u8 {
        const base = self.fetchByte(bus);
        _ = bus.read(base);
        _ = self.ldx(bus.read(base +% self.y));
        return 4;
    }

    fn ldyZeroPage(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchByte(bus);
        _ = self.ldy(bus.read(address));
        return 3;
    }

    fn ldyZeroPageX(self: *Cpu, bus: *TestBus) u8 {
        const base = self.fetchByte(bus);
        _ = bus.read(base);
        _ = self.ldy(bus.read(base +% self.x));
        return 4;
    }

    fn ldaIndexedIndirect(self: *Cpu, bus: *TestBus) u8 {
        const base = self.fetchByte(bus);
        _ = bus.read(base);
        const address = readZeroPage16(bus, base +% self.x);
        _ = self.lda(bus.read(address));
        return 6;
    }

    fn ldaIndirectIndexed(self: *Cpu, bus: *TestBus) u8 {
        const pointer = self.fetchByte(bus);
        const base = readZeroPage16(bus, pointer);
        const address = base +% self.y;
        if ((base & 0xff00) != (address & 0xff00)) {
            _ = bus.read((base & 0xff00) | (address & 0x00ff));
            _ = self.lda(bus.read(address));
            return 6;
        }
        _ = self.lda(bus.read(address));
        return 5;
    }

    fn ldaAbsolute(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchWord(bus);
        _ = self.lda(bus.read(address));
        return 4;
    }

    fn ldxAbsolute(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchWord(bus);
        _ = self.ldx(bus.read(address));
        return 4;
    }

    fn ldyAbsolute(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchWord(bus);
        _ = self.ldy(bus.read(address));
        return 4;
    }

    fn bitZeroPage(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchByte(bus);
        self.bit(bus.read(address));
        return 3;
    }

    fn bitAbsolute(self: *Cpu, bus: *TestBus) u8 {
        const address = self.fetchWord(bus);
        self.bit(bus.read(address));
        return 4;
    }

    fn staAbsoluteY(self: *Cpu, bus: *TestBus) u8 {
        return self.staAbsoluteIndexed(bus, self.y);
    }

    fn staAbsoluteX(self: *Cpu, bus: *TestBus) u8 {
        return self.staAbsoluteIndexed(bus, self.x);
    }

    fn staAbsoluteIndexed(self: *Cpu, bus: *TestBus, index: u8) u8 {
        const base = self.fetchWord(bus);
        const address = base +% index;
        // Indexed stores always perform this intermediate read, whether or
        // not the addition crosses a page.
        _ = bus.read((base & 0xff00) | (address & 0x00ff));
        bus.write(address, self.a);
        return 5;
    }

    fn compareZeroPage(self: *Cpu, bus: *TestBus, register: u8) u8 {
        const address = self.fetchByte(bus);
        return self.compare(register, bus.read(address)) + 1;
    }

    fn compareZeroPageIndexed(self: *Cpu, bus: *TestBus, register: u8, index: u8) u8 {
        const base = self.fetchByte(bus);
        _ = bus.read(base);
        _ = self.compare(register, bus.read(base +% index));
        return 4;
    }

    fn compareAbsolute(self: *Cpu, bus: *TestBus, register: u8) u8 {
        const address = self.fetchWord(bus);
        _ = self.compare(register, bus.read(address));
        return 4;
    }

    fn compareAbsoluteIndexed(self: *Cpu, bus: *TestBus, index: u8) u8 {
        const base = self.fetchWord(bus);
        const address = base +% index;
        if ((base & 0xff00) != (address & 0xff00)) {
            _ = bus.read((base & 0xff00) | (address & 0x00ff));
            _ = self.compare(self.a, bus.read(address));
            return 5;
        }
        _ = self.compare(self.a, bus.read(address));
        return 4;
    }

    fn compareIndexedIndirect(self: *Cpu, bus: *TestBus) u8 {
        const base = self.fetchByte(bus);
        _ = bus.read(base);
        const address = readZeroPage16(bus, base +% self.x);
        _ = self.compare(self.a, bus.read(address));
        return 6;
    }

    fn compareIndirectIndexed(self: *Cpu, bus: *TestBus) u8 {
        const pointer = self.fetchByte(bus);
        const base = readZeroPage16(bus, pointer);
        const address = base +% self.y;
        if ((base & 0xff00) != (address & 0xff00)) {
            _ = bus.read((base & 0xff00) | (address & 0x00ff));
            _ = self.compare(self.a, bus.read(address));
            return 6;
        }
        _ = self.compare(self.a, bus.read(address));
        return 5;
    }

    fn lsrAbsolute(self: *Cpu, bus: *TestBus) u8 {
        return self.rmwAbsoluteOperation(bus, .lsr);
    }

    fn incZeroPage(self: *Cpu, bus: *TestBus) u8 {
        return self.rmwZeroPageOperation(bus, .inc);
    }

    fn decZeroPage(self: *Cpu, bus: *TestBus) u8 {
        return self.rmwZeroPageOperation(bus, .dec);
    }

    fn incAbsolute(self: *Cpu, bus: *TestBus) u8 {
        return self.rmwAbsoluteOperation(bus, .inc);
    }

    fn decAbsolute(self: *Cpu, bus: *TestBus) u8 {
        return self.rmwAbsoluteOperation(bus, .dec);
    }

    fn rmwZeroPageOperation(self: *Cpu, bus: *TestBus, operation: RmwOperation) u8 {
        const address = self.fetchByte(bus);
        return self.rmwAt(bus, address, operation, 5);
    }

    fn rmwZeroPageIndexedOperation(self: *Cpu, bus: *TestBus, index: u8, operation: RmwOperation) u8 {
        const base = self.fetchByte(bus);
        _ = bus.read(base);
        return self.rmwAt(bus, base +% index, operation, 6);
    }

    fn rmwAbsoluteOperation(self: *Cpu, bus: *TestBus, operation: RmwOperation) u8 {
        const address = self.fetchWord(bus);
        return self.rmwAt(bus, address, operation, 6);
    }

    fn rmwAbsoluteIndexedOperation(self: *Cpu, bus: *TestBus, index: u8, operation: RmwOperation) u8 {
        const base = self.fetchWord(bus);
        const address = base +% index;
        _ = bus.read((base & 0xff00) | (address & 0x00ff));
        return self.rmwAt(bus, address, operation, 7);
    }

    fn rmwAt(self: *Cpu, bus: *TestBus, address: u16, operation: RmwOperation, cycles: u8) u8 {
        const value = bus.read(address);
        // 6502 RMW operations write the original byte before the result.
        bus.write(address, value);
        const result: u8 = switch (operation) {
            .asl => blk: {
                self.status.carry = value & 0x80 != 0;
                break :blk value << 1;
            },
            .lsr => blk: {
                self.status.carry = value & 1 != 0;
                break :blk value >> 1;
            },
            .rol => blk: {
                const carry_in: u8 = @intFromBool(self.status.carry);
                self.status.carry = value & 0x80 != 0;
                break :blk (value << 1) | carry_in;
            },
            .ror => blk: {
                const carry_in: u8 = if (self.status.carry) 0x80 else 0;
                self.status.carry = value & 1 != 0;
                break :blk (value >> 1) | carry_in;
            },
            .inc => value +% 1,
            .dec => value -% 1,
        };
        bus.write(address, result);
        self.setZn(result);
        return cycles;
    }

    fn jsr(self: *Cpu, bus: *TestBus) u8 {
        const target_low = self.fetchByte(bus);
        _ = bus.read(0x0100 | @as(u16, self.sp));
        self.push(bus, @truncate(self.pc >> 8));
        self.push(bus, @truncate(self.pc));
        const target_high = self.fetchByte(bus);
        self.pc = @as(u16, target_low) | (@as(u16, target_high) << 8);
        return 6;
    }

    fn rts(self: *Cpu, bus: *TestBus) u8 {
        _ = bus.read(self.pc);
        _ = bus.read(0x0100 | @as(u16, self.sp));
        const low = self.pull(bus);
        const high = self.pull(bus);
        self.pc = (@as(u16, high) << 8) | low;
        _ = bus.read(self.pc);
        self.pc +%= 1;
        return 6;
    }

    fn rti(self: *Cpu, bus: *TestBus) u8 {
        _ = bus.read(self.pc);
        _ = bus.read(0x0100 | @as(u16, self.sp));
        self.status = @bitCast(self.pull(bus));
        self.status.break_flag = false;
        self.status.unused = true;
        const low = self.pull(bus);
        const high = self.pull(bus);
        self.pc = (@as(u16, high) << 8) | low;
        return 6;
    }

    fn branch(self: *Cpu, bus: *TestBus, condition: bool) u8 {
        const offset: i8 = @bitCast(self.fetchByte(bus));
        if (!condition) return 2;

        const previous_pc = self.pc;
        // Branch-taken timing performs a dummy read at the next instruction.
        _ = bus.read(previous_pc);
        const target: i32 = @as(i32, previous_pc) + @as(i32, offset);
        self.pc = @truncate(@as(u32, @bitCast(target)));
        if ((previous_pc & 0xff00) != (self.pc & 0xff00)) {
            _ = bus.read((previous_pc & 0xff00) | (self.pc & 0x00ff));
            return 4;
        }
        // A taken branch that remains on-page polls IRQ before its final
        // dummy cycle, so an edge on that cycle waits through one opcode.
        self.irq_poll_one_cycle_early = true;
        return 3;
    }

    fn brk(self: *Cpu, bus: *TestBus) u8 {
        // BRK consumes its padding byte before pushing the return address.
        _ = self.fetchByte(bus);
        self.push(bus, @truncate(self.pc >> 8));
        self.push(bus, @truncate(self.pc));
        const vector = self.selectInterruptVector(0xfffe);
        var pushed = self.status;
        pushed.break_flag = true;
        pushed.unused = true;
        self.push(bus, @bitCast(pushed));
        self.status.interrupt_disable = true;
        self.pc = read16(bus, vector);
        self.finishInterruptVectoring();
        return 7;
    }

    fn serviceInterrupt(self: *Cpu, bus: *TestBus, vector: u16) u8 {
        _ = bus.read(self.pc);
        _ = bus.read(self.pc);
        self.push(bus, @truncate(self.pc >> 8));
        self.push(bus, @truncate(self.pc));
        const actual_vector = self.selectInterruptVector(vector);
        var pushed = self.status;
        pushed.break_flag = false;
        pushed.unused = true;
        self.push(bus, @bitCast(pushed));
        self.status.interrupt_disable = true;
        self.pc = read16(bus, actual_vector);
        self.finishInterruptVectoring();
        self.cycles += 7;
        return 7;
    }

    fn fetchByte(self: *Cpu, bus: *TestBus) u8 {
        const value = bus.read(self.pc);
        self.pc +%= 1;
        return value;
    }

    fn fetchWord(self: *Cpu, bus: *TestBus) u16 {
        const low = self.fetchByte(bus);
        const high = self.fetchByte(bus);
        return @as(u16, low) | (@as(u16, high) << 8);
    }

    fn push(self: *Cpu, bus: *TestBus, value: u8) void {
        bus.write(0x0100 | @as(u16, self.sp), value);
        self.sp -%= 1;
    }

    fn selectInterruptVector(self: *Cpu, vector: u16) u16 {
        if (vector != 0xfffe or !self.nmi_vector_hijack) return vector;
        self.nmi_vector_hijack = false;
        self.nmi_hijack_consumed = true;
        return 0xfffa;
    }

    fn finishInterruptVectoring(self: *Cpu) void {
        if (!self.nmi_vector_hijack) return;
        self.nmi_vector_hijack = false;
        self.nmi_after_vector_select = true;
    }

    fn pull(self: *Cpu, bus: *TestBus) u8 {
        self.sp +%= 1;
        return bus.read(0x0100 | @as(u16, self.sp));
    }

    fn setZn(self: *Cpu, value: u8) void {
        self.status.zero = value == 0;
        self.status.negative = value & 0x80 != 0;
    }
};

fn read16(bus: *TestBus, address: u16) u16 {
    const low = bus.read(address);
    const high = bus.read(address +% 1);
    return @as(u16, low) | (@as(u16, high) << 8);
}

fn readZeroPage16(bus: *TestBus, address: u8) u16 {
    const low = bus.read(address);
    const high = bus.read(address +% 1);
    return @as(u16, low) | (@as(u16, high) << 8);
}

const NmiEdgeInjector = struct {
    cpu: *Cpu,
    trigger_access: u8,
    access_count: u8 = 0,

    fn beforeAccess(context: *anyopaque) void {
        _ = context;
    }

    fn afterAccess(context: *anyopaque) void {
        const self: *NmiEdgeInjector = @ptrCast(@alignCast(context));
        self.access_count += 1;
        if (self.access_count == self.trigger_access) self.cpu.observeNmiEdge();
    }
};

test "reset fetches reset vector and sets 2A03 defaults" {
    var bus: TestBus = .{};
    bus.memory[0xfffc] = 0x34;
    bus.memory[0xfffd] = 0x12;
    var cpu: Cpu = .{};
    cpu.reset(&bus);
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.pc);
    try std.testing.expectEqual(@as(u8, 0xfd), cpu.sp);
    try std.testing.expect(cpu.status.interrupt_disable);
    try std.testing.expect(!cpu.status.decimal);
    try std.testing.expectEqual(@as(u64, 7), cpu.cycles);
}

test "LDA immediate sets zero and negative flags" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..4].* = .{ 0xa9, 0x00, 0xa9, 0x80 };
    var cpu: Cpu = .{ .pc = 0x8000 };
    try std.testing.expectEqual(@as(u8, 2), try cpu.step(&bus));
    try std.testing.expect(cpu.status.zero);
    try std.testing.expectEqual(@as(u8, 2), try cpu.step(&bus));
    try std.testing.expect(cpu.status.negative);
}

test "ADC is binary even when decimal flag is set" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..2].* = .{ 0x69, 0x01 };
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0x09, .status = .{ .decimal = true } };
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u8, 0x0a), cpu.a);
}

test "STA absolute produces opcode operand operand write trace" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..3].* = .{ 0x8d, 0x34, 0x12 };
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0xbe };
    try std.testing.expectEqual(@as(u8, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0xbe), bus.memory[0x1234]);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0x8d },
        .{ .kind = .read, .address = 0x8001, .value = 0x34 },
        .{ .kind = .read, .address = 0x8002, .value = 0x12 },
        .{ .kind = .write, .address = 0x1234, .value = 0xbe },
    }, bus.accesses());
}

test "taken BNE across page emits both dummy reads" {
    var bus: TestBus = .{};
    bus.memory[0x80fd] = 0xd0;
    bus.memory[0x80fe] = 0x01;
    var cpu: Cpu = .{ .pc = 0x80fd };
    try std.testing.expectEqual(@as(u8, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x8100), cpu.pc);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x80fd, .value = 0xd0 },
        .{ .kind = .read, .address = 0x80fe, .value = 0x01 },
        .{ .kind = .read, .address = 0x80ff, .value = 0x00 },
        .{ .kind = .read, .address = 0x8000, .value = 0x00 },
    }, bus.accesses());
}

test "taken on-page branch marks its early IRQ poll" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..4].* = .{ 0xd0, 0x01, 0xea, 0xea };
    var cpu: Cpu = .{ .pc = 0x8000 };

    try std.testing.expectEqual(@as(u8, 3), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x8003), cpu.pc);
    try std.testing.expect(cpu.irq_poll_one_cycle_early);

    cpu.pc = 0x8000;
    cpu.status.zero = true;
    try std.testing.expectEqual(@as(u8, 2), try cpu.step(&bus));
    try std.testing.expect(!cpu.irq_poll_one_cycle_early);
}

test "BRK pushes PC plus two and vectors through IRQ" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..2].* = .{ 0x00, 0xea };
    bus.memory[0xfffe] = 0x78;
    bus.memory[0xffff] = 0x56;
    var cpu: Cpu = .{ .pc = 0x8000, .sp = 0xfd };
    try std.testing.expectEqual(@as(u8, 7), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x5678), cpu.pc);
    try std.testing.expectEqual(@as(u8, 0x80), bus.memory[0x01fd]);
    try std.testing.expectEqual(@as(u8, 0x02), bus.memory[0x01fc]);
    try std.testing.expect(bus.memory[0x01fb] & 0x10 != 0);
}

test "NMI after BRK's PC pushes hijacks the vector but keeps B set" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..2].* = .{ 0x00, 0xea };
    bus.memory[0xfffa] = 0x34;
    bus.memory[0xfffb] = 0x12;
    bus.memory[0xfffe] = 0x78;
    bus.memory[0xffff] = 0x56;
    var cpu: Cpu = .{ .pc = 0x8000, .sp = 0xfd };
    var injector = NmiEdgeInjector{ .cpu = &cpu, .trigger_access = 4 };
    bus.beginCpuCycleHook(&injector, NmiEdgeInjector.beforeAccess, NmiEdgeInjector.afterAccess);
    try std.testing.expectEqual(@as(u8, 7), try cpu.step(&bus));
    _ = bus.endCpuCycleHook();
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.pc);
    try std.testing.expect(bus.memory[0x01fb] & 0x10 != 0);
    try std.testing.expect(cpu.takeNmiHijackConsumed());
}

test "NMI after the IRQ PC pushes hijacks the vector without B" {
    var bus: TestBus = .{};
    bus.memory[0xfffa] = 0x34;
    bus.memory[0xfffb] = 0x12;
    bus.memory[0xfffe] = 0x78;
    bus.memory[0xffff] = 0x56;
    var cpu: Cpu = .{ .pc = 0x8000, .sp = 0xfd, .status = .{ .interrupt_disable = false } };
    cpu.requestIrq();
    var injector = NmiEdgeInjector{ .cpu = &cpu, .trigger_access = 4 };
    bus.beginCpuCycleHook(&injector, NmiEdgeInjector.beforeAccess, NmiEdgeInjector.afterAccess);
    try std.testing.expectEqual(@as(u8, 7), try cpu.step(&bus));
    _ = bus.endCpuCycleHook();
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.pc);
    try std.testing.expect(bus.memory[0x01fb] & 0x10 == 0);
    try std.testing.expect(cpu.takeNmiHijackConsumed());
}

test "hardware IRQ entry performs two dummy reads before stacking" {
    var bus: TestBus = .{};
    bus.memory[0xfffe] = 0x34;
    bus.memory[0xffff] = 0x12;
    var cpu: Cpu = .{ .pc = 0x8000, .sp = 0xfd, .status = .{ .interrupt_disable = false } };
    cpu.requestIrq();
    try std.testing.expectEqual(@as(u8, 7), try cpu.step(&bus));
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0 },
        .{ .kind = .read, .address = 0x8000, .value = 0 },
        .{ .kind = .write, .address = 0x01fd, .value = 0x80 },
        .{ .kind = .write, .address = 0x01fc, .value = 0x00 },
        .{ .kind = .write, .address = 0x01fb, .value = 0x20 },
        .{ .kind = .read, .address = 0xfffe, .value = 0x34 },
        .{ .kind = .read, .address = 0xffff, .value = 0x12 },
    }, bus.accesses());
}

test "JSR and RTS preserve the return address and stack order" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..4].* = .{ 0x20, 0x00, 0x90, 0xea };
    bus.memory[0x9000] = 0x60;
    var cpu: Cpu = .{ .pc = 0x8000, .sp = 0xfd };
    try std.testing.expectEqual(@as(u8, 6), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x9000), cpu.pc);
    try std.testing.expectEqual(@as(u8, 0x80), bus.memory[0x01fd]);
    try std.testing.expectEqual(@as(u8, 0x02), bus.memory[0x01fc]);
    bus.clearTrace();
    try std.testing.expectEqual(@as(u8, 6), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x8003), cpu.pc);
}

test "NMI has priority over IRQ and pushes status without B" {
    var bus: TestBus = .{};
    bus.memory[0xfffa] = 0x00;
    bus.memory[0xfffb] = 0x90;
    bus.memory[0xfffe] = 0x00;
    bus.memory[0xffff] = 0xa0;
    var cpu: Cpu = .{ .pc = 0x8123, .sp = 0xfd, .status = .{ .interrupt_disable = false } };
    cpu.requestIrq();
    cpu.requestNmi();
    try std.testing.expectEqual(@as(u8, 7), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x9000), cpu.pc);
    try std.testing.expect(bus.memory[0x01fb] & 0x10 == 0);
    try std.testing.expect(cpu.irq_pending);
}

test "masked IRQ executes one instruction after CLI before vectoring" {
    var bus: TestBus = .{};
    bus.memory[0x8000] = 0x58; // CLI
    bus.memory[0x8001] = 0xea; // NOP
    bus.memory[0xfffe] = 0x00;
    bus.memory[0xffff] = 0x90;
    var cpu: Cpu = .{ .pc = 0x8000, .status = .{ .interrupt_disable = true } };
    cpu.requestIrq();
    try std.testing.expectEqual(@as(u8, 2), try cpu.step(&bus));
    try std.testing.expect(!cpu.status.interrupt_disable);
    try std.testing.expectEqual(@as(u8, 2), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x8002), cpu.pc);
    try std.testing.expectEqual(@as(u8, 7), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x9000), cpu.pc);
}

test "CLI followed by SEI allows one IRQ after SEI" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..2].* = .{ 0x58, 0x78 }; // CLI; SEI
    bus.memory[0xfffe] = 0x00;
    bus.memory[0xffff] = 0x90;
    var cpu: Cpu = .{ .pc = 0x8000, .status = .{ .interrupt_disable = true } };
    cpu.requestIrq();
    try std.testing.expectEqual(@as(u8, 2), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 2), try cpu.step(&bus));
    try std.testing.expect(cpu.status.interrupt_disable);
    try std.testing.expectEqual(@as(u8, 7), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x9000), cpu.pc);
}

test "RTI restores PC and status but clears B flag" {
    var bus: TestBus = .{};
    bus.memory[0x8000] = 0x40;
    bus.memory[0x01fb] = 0x31; // C, I, B, unused
    bus.memory[0x01fc] = 0x34;
    bus.memory[0x01fd] = 0x12;
    var cpu: Cpu = .{ .pc = 0x8000, .sp = 0xfa };
    try std.testing.expectEqual(@as(u8, 6), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.pc);
    try std.testing.expect(cpu.status.carry);
    try std.testing.expect(!cpu.status.break_flag);
    try std.testing.expect(cpu.status.unused);
}

test "absolute X load adds a page-cross dummy read" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..3].* = .{ 0xbd, 0xff, 0x12 };
    bus.memory[0x1200] = 0x99;
    bus.memory[0x1300] = 0x42;
    var cpu: Cpu = .{ .pc = 0x8000, .x = 1 };
    try std.testing.expectEqual(@as(u8, 5), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0x42), cpu.a);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0xbd },
        .{ .kind = .read, .address = 0x8001, .value = 0xff },
        .{ .kind = .read, .address = 0x8002, .value = 0x12 },
        .{ .kind = .read, .address = 0x1200, .value = 0x99 },
        .{ .kind = .read, .address = 0x1300, .value = 0x42 },
    }, bus.accesses());
}

test "LSR absolute uses read write write sequence" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..3].* = .{ 0x4e, 0x34, 0x12 };
    bus.memory[0x1234] = 0x81;
    var cpu: Cpu = .{ .pc = 0x8000 };
    try std.testing.expectEqual(@as(u8, 6), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0x40), bus.memory[0x1234]);
    try std.testing.expect(cpu.status.carry);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0x4e },
        .{ .kind = .read, .address = 0x8001, .value = 0x34 },
        .{ .kind = .read, .address = 0x8002, .value = 0x12 },
        .{ .kind = .read, .address = 0x1234, .value = 0x81 },
        .{ .kind = .write, .address = 0x1234, .value = 0x81 },
        .{ .kind = .write, .address = 0x1234, .value = 0x40 },
    }, bus.accesses());
}

test "SBC uses carry as not-borrow and retains binary arithmetic" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..2].* = .{ 0xe9, 0x01 };
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0x10, .status = .{ .carry = true, .decimal = true } };
    try std.testing.expectEqual(@as(u8, 2), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0x0f), cpu.a);
    try std.testing.expect(cpu.status.carry);
}

test "logic compare and accumulator shifts update flags" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..9].* = .{ 0x29, 0x0f, 0x09, 0x80, 0xc9, 0x8f, 0x0a, 0x6a, 0x4a };
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0xff, .status = .{ .carry = true } };
    _ = try cpu.step(&bus); // AND #$0F
    try std.testing.expectEqual(@as(u8, 0x0f), cpu.a);
    _ = try cpu.step(&bus); // ORA #$80
    try std.testing.expectEqual(@as(u8, 0x8f), cpu.a);
    _ = try cpu.step(&bus); // CMP #$8F
    try std.testing.expect(cpu.status.carry);
    try std.testing.expect(cpu.status.zero);
    _ = try cpu.step(&bus); // ASL A
    try std.testing.expectEqual(@as(u8, 0x1e), cpu.a);
    try std.testing.expect(cpu.status.carry);
    _ = try cpu.step(&bus); // ROR A, carry in
    try std.testing.expectEqual(@as(u8, 0x8f), cpu.a);
    _ = try cpu.step(&bus); // LSR A
    try std.testing.expectEqual(@as(u8, 0x47), cpu.a);
    try std.testing.expect(cpu.status.carry);
}

test "PHA PLA PHP PLP use stack and normalize status B bit" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..4].* = .{ 0x48, 0x68, 0x08, 0x28 };
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0x80, .sp = 0xfd, .status = .{ .carry = true } };
    _ = try cpu.step(&bus); // PHA
    cpu.a = 0;
    _ = try cpu.step(&bus); // PLA
    try std.testing.expectEqual(@as(u8, 0x80), cpu.a);
    try std.testing.expect(cpu.status.negative);
    _ = try cpu.step(&bus); // PHP
    cpu.status = .{};
    _ = try cpu.step(&bus); // PLP
    try std.testing.expect(cpu.status.carry);
    try std.testing.expect(!cpu.status.break_flag);
    try std.testing.expect(cpu.status.unused);
}

test "indexed indirect wraps pointer in zero page" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..2].* = .{ 0xa1, 0xff };
    bus.memory[0x00ff] = 0x34;
    bus.memory[0x0000] = 0x12;
    bus.memory[0x1234] = 0x5a;
    var cpu: Cpu = .{ .pc = 0x8000, .x = 0 };
    try std.testing.expectEqual(@as(u8, 6), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0x5a), cpu.a);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0xa1 },
        .{ .kind = .read, .address = 0x8001, .value = 0xff },
        .{ .kind = .read, .address = 0x00ff, .value = 0x34 },
        .{ .kind = .read, .address = 0x00ff, .value = 0x34 },
        .{ .kind = .read, .address = 0x0000, .value = 0x12 },
        .{ .kind = .read, .address = 0x1234, .value = 0x5a },
    }, bus.accesses());
}

test "indirect indexed emits page-cross dummy read" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..2].* = .{ 0xb1, 0x80 };
    bus.memory[0x0080] = 0xff;
    bus.memory[0x0081] = 0x12;
    bus.memory[0x1200] = 0x99;
    bus.memory[0x1300] = 0x42;
    var cpu: Cpu = .{ .pc = 0x8000, .y = 1 };
    try std.testing.expectEqual(@as(u8, 6), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0x42), cpu.a);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0xb1 },
        .{ .kind = .read, .address = 0x8001, .value = 0x80 },
        .{ .kind = .read, .address = 0x0080, .value = 0xff },
        .{ .kind = .read, .address = 0x0081, .value = 0x12 },
        .{ .kind = .read, .address = 0x1200, .value = 0x99 },
        .{ .kind = .read, .address = 0x1300, .value = 0x42 },
    }, bus.accesses());
}

test "STA indexed indirect and INC zero page preserve bus write sequences" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..4].* = .{ 0x81, 0x40, 0xe6, 0x20 };
    bus.memory[0x0040] = 0x34;
    bus.memory[0x0041] = 0x12;
    bus.memory[0x0020] = 0xff;
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0xbe };
    try std.testing.expectEqual(@as(u8, 6), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0xbe), bus.memory[0x1234]);
    bus.clearTrace();
    try std.testing.expectEqual(@as(u8, 5), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0), bus.memory[0x0020]);
    try std.testing.expect(cpu.status.zero);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8002, .value = 0xe6 },
        .{ .kind = .read, .address = 0x8003, .value = 0x20 },
        .{ .kind = .read, .address = 0x0020, .value = 0xff },
        .{ .kind = .write, .address = 0x0020, .value = 0xff },
        .{ .kind = .write, .address = 0x0020, .value = 0x00 },
    }, bus.accesses());
}

test "all newly-supported branch conditions take and fall through" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..8].* = .{ 0x10, 0x02, 0x50, 0x02, 0x70, 0x02, 0xf0, 0x02 };
    var cpu: Cpu = .{ .pc = 0x8000, .status = .{} };
    _ = try cpu.step(&bus); // BPL taken
    try std.testing.expectEqual(@as(u16, 0x8004), cpu.pc);
    cpu.status.overflow = true;
    _ = try cpu.step(&bus); // BVS taken
    try std.testing.expectEqual(@as(u16, 0x8008), cpu.pc);
    cpu.pc = 0x8002;
    cpu.status.overflow = false;
    _ = try cpu.step(&bus); // BVC taken
    try std.testing.expectEqual(@as(u16, 0x8006), cpu.pc);
    cpu.pc = 0x8006;
    cpu.status.zero = true;
    _ = try cpu.step(&bus); // BEQ taken
    try std.testing.expectEqual(@as(u16, 0x800a), cpu.pc);
}

test "JMP indirect reproduces the 6502 page-end high-byte bug" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..3].* = .{ 0x6c, 0xff, 0x12 };
    bus.memory[0x12ff] = 0x34;
    bus.memory[0x1200] = 0x56;
    bus.memory[0x1300] = 0x78;
    var cpu: Cpu = .{ .pc = 0x8000 };
    try std.testing.expectEqual(@as(u8, 5), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x5634), cpu.pc);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0x6c },
        .{ .kind = .read, .address = 0x8001, .value = 0xff },
        .{ .kind = .read, .address = 0x8002, .value = 0x12 },
        .{ .kind = .read, .address = 0x12ff, .value = 0x34 },
        .{ .kind = .read, .address = 0x1200, .value = 0x56 },
    }, bus.accesses());
}

test "absolute indexed store has mandatory dummy read and absolute RMW double write" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..6].* = .{ 0x99, 0xff, 0x12, 0xee, 0x34, 0x12 };
    bus.memory[0x1200] = 0xaa;
    bus.memory[0x1300] = 0;
    bus.memory[0x1234] = 0x7f;
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0xbe, .y = 1 };
    try std.testing.expectEqual(@as(u8, 5), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0xbe), bus.memory[0x1300]);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0x99 },
        .{ .kind = .read, .address = 0x8001, .value = 0xff },
        .{ .kind = .read, .address = 0x8002, .value = 0x12 },
        .{ .kind = .read, .address = 0x1200, .value = 0xaa },
        .{ .kind = .write, .address = 0x1300, .value = 0xbe },
    }, bus.accesses());
    bus.clearTrace();
    try std.testing.expectEqual(@as(u8, 6), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0x80), bus.memory[0x1234]);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8003, .value = 0xee },
        .{ .kind = .read, .address = 0x8004, .value = 0x34 },
        .{ .kind = .read, .address = 0x8005, .value = 0x12 },
        .{ .kind = .read, .address = 0x1234, .value = 0x7f },
        .{ .kind = .write, .address = 0x1234, .value = 0x7f },
        .{ .kind = .write, .address = 0x1234, .value = 0x80 },
    }, bus.accesses());
}

test "BIT takes N and V from memory without changing A" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..5].* = .{ 0x24, 0x10, 0x2c, 0x20, 0x12 };
    bus.memory[0x0010] = 0x40;
    bus.memory[0x1220] = 0xc0;
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0xc0 };

    try std.testing.expectEqual(@as(u8, 3), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0xc0), cpu.a);
    try std.testing.expect(!cpu.status.zero);
    try std.testing.expect(cpu.status.overflow);
    try std.testing.expect(!cpu.status.negative);

    try std.testing.expectEqual(@as(u8, 4), try cpu.step(&bus));
    try std.testing.expect(!cpu.status.zero);
    try std.testing.expect(cpu.status.overflow);
    try std.testing.expect(cpu.status.negative);
}

test "zero-page indexed stores issue base dummy reads and wrap" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..6].* = .{ 0x95, 0xff, 0x96, 0xff, 0x94, 0xff };
    bus.memory[0x00ff] = 0x55;
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0xaa, .x = 1, .y = 2 };

    try std.testing.expectEqual(@as(u8, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0xaa), bus.memory[0x0000]);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0x95 },
        .{ .kind = .read, .address = 0x8001, .value = 0xff },
        .{ .kind = .read, .address = 0x00ff, .value = 0x55 },
        .{ .kind = .write, .address = 0x0000, .value = 0xaa },
    }, bus.accesses());

    bus.clearTrace();
    try std.testing.expectEqual(@as(u8, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 1), bus.memory[0x0001]);
    try std.testing.expectEqual(@as(u8, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 2), bus.memory[0x0000]);
}

test "transfers update ZN except TXS" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..4].* = .{ 0x8a, 0xa8, 0xaa, 0x9a };
    var cpu: Cpu = .{ .pc = 0x8000, .x = 0x80, .status = .{} };

    _ = try cpu.step(&bus); // TXA
    try std.testing.expectEqual(@as(u8, 0x80), cpu.a);
    try std.testing.expect(cpu.status.negative);
    _ = try cpu.step(&bus); // TAY
    try std.testing.expectEqual(@as(u8, 0x80), cpu.y);
    _ = try cpu.step(&bus); // TAX
    try std.testing.expectEqual(@as(u8, 0x80), cpu.x);

    cpu.status.zero = true;
    cpu.status.negative = false;
    _ = try cpu.step(&bus); // TXS
    try std.testing.expectEqual(@as(u8, 0x80), cpu.sp);
    try std.testing.expect(cpu.status.zero);
    try std.testing.expect(!cpu.status.negative);
}

test "LDY absolute X and LDX absolute Y add page-cross dummy reads" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..6].* = .{ 0xbc, 0xff, 0x12, 0xbe, 0xff, 0x12 };
    bus.memory[0x1200] = 0x99;
    bus.memory[0x1300] = 0x80;
    var cpu: Cpu = .{ .pc = 0x8000, .x = 1, .y = 1 };

    try std.testing.expectEqual(@as(u8, 5), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0x80), cpu.y);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0xbc },
        .{ .kind = .read, .address = 0x8001, .value = 0xff },
        .{ .kind = .read, .address = 0x8002, .value = 0x12 },
        .{ .kind = .read, .address = 0x1200, .value = 0x99 },
        .{ .kind = .read, .address = 0x1300, .value = 0x80 },
    }, bus.accesses());

    bus.clearTrace();
    cpu.y = 1;
    try std.testing.expectEqual(@as(u8, 5), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0x80), cpu.x);
}

test "CPU reset and NOP execute from an NROM image" {
    const Mapper0 = @import("mapper0.zig").Mapper0;
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    prg[0] = 0xea;
    prg[0x3ffc] = 0x00;
    prg[0x3ffd] = 0x80;
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var bus: TestBus = .{};
    bus.attachMapper0(&mapper);
    var cpu: Cpu = .{};
    cpu.reset(&bus);
    try std.testing.expectEqual(@as(u16, 0x8000), cpu.pc);
    try std.testing.expectEqual(@as(u8, 2), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x8001), cpu.pc);
}

test "ALU addressing families preserve page-cross and zero-page bus timing" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..5].* = .{ 0x79, 0xff, 0x12, 0x35, 0x20 };
    bus.memory[0x1200] = 0xaa;
    bus.memory[0x1300] = 0x01;
    bus.memory[0x0020] = 0x55;
    bus.memory[0x0021] = 0x0f;
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0x7f, .x = 1, .y = 1 };

    try std.testing.expectEqual(@as(u8, 5), try cpu.step(&bus)); // ADC $12FF,Y
    try std.testing.expectEqual(@as(u8, 0x80), cpu.a);
    try std.testing.expect(cpu.status.overflow);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0x79 },
        .{ .kind = .read, .address = 0x8001, .value = 0xff },
        .{ .kind = .read, .address = 0x8002, .value = 0x12 },
        .{ .kind = .read, .address = 0x1200, .value = 0xaa },
        .{ .kind = .read, .address = 0x1300, .value = 0x01 },
    }, bus.accesses());

    bus.clearTrace();
    try std.testing.expectEqual(@as(u8, 4), try cpu.step(&bus)); // AND $20,X
    try std.testing.expectEqual(@as(u8, 0), cpu.a);
    try std.testing.expect(cpu.status.zero);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8003, .value = 0x35 },
        .{ .kind = .read, .address = 0x8004, .value = 0x20 },
        .{ .kind = .read, .address = 0x0020, .value = 0x55 },
        .{ .kind = .read, .address = 0x0021, .value = 0x0f },
    }, bus.accesses());
}

test "STA indirect indexed performs mandatory dummy read and CMP uses memory" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..4].* = .{ 0x91, 0x80, 0xc5, 0x10 };
    bus.memory[0x0080] = 0xff;
    bus.memory[0x0081] = 0x12;
    bus.memory[0x1200] = 0x55;
    bus.memory[0x0010] = 0xbe;
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0xbe, .y = 1 };

    try std.testing.expectEqual(@as(u8, 6), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u8, 0xbe), bus.memory[0x1300]);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8000, .value = 0x91 },
        .{ .kind = .read, .address = 0x8001, .value = 0x80 },
        .{ .kind = .read, .address = 0x0080, .value = 0xff },
        .{ .kind = .read, .address = 0x0081, .value = 0x12 },
        .{ .kind = .read, .address = 0x1200, .value = 0x55 },
        .{ .kind = .write, .address = 0x1300, .value = 0xbe },
    }, bus.accesses());

    bus.clearTrace();
    try std.testing.expectEqual(@as(u8, 3), try cpu.step(&bus));
    try std.testing.expect(cpu.status.carry);
    try std.testing.expect(cpu.status.zero);
}

test "memory shifts and rotates retain indexed RMW bus sequence" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..5].* = .{ 0x1e, 0x20, 0x00, 0x7e, 0xff };
    bus.memory[0x8005] = 0x12;
    bus.memory[0x0021] = 0x80;
    bus.memory[0x1200] = 0x11;
    bus.memory[0x1300] = 0x01;
    var cpu: Cpu = .{ .pc = 0x8000, .x = 1, .status = .{ .carry = true } };

    try std.testing.expectEqual(@as(u8, 7), try cpu.step(&bus)); // ASL $0020,X
    try std.testing.expectEqual(@as(u8, 0), bus.memory[0x0021]);
    try std.testing.expect(cpu.status.carry);
    try std.testing.expect(cpu.status.zero);
    bus.clearTrace();

    try std.testing.expectEqual(@as(u8, 7), try cpu.step(&bus)); // ROR $12FF,X
    try std.testing.expectEqual(@as(u8, 0x80), bus.memory[0x1300]);
    try std.testing.expect(cpu.status.carry);
    try std.testing.expect(cpu.status.negative);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8003, .value = 0x7e },
        .{ .kind = .read, .address = 0x8004, .value = 0xff },
        .{ .kind = .read, .address = 0x8005, .value = 0x12 },
        .{ .kind = .read, .address = 0x1200, .value = 0x11 },
        .{ .kind = .read, .address = 0x1300, .value = 0x01 },
        .{ .kind = .write, .address = 0x1300, .value = 0x01 },
        .{ .kind = .write, .address = 0x1300, .value = 0x80 },
    }, bus.accesses());
}

test "BMI and CMP absolute indexed implement branch and page-cross timing" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..5].* = .{ 0x30, 0x02, 0xd9, 0xff, 0x12 };
    bus.memory[0x1200] = 0x44;
    bus.memory[0x1300] = 0x80;
    var cpu: Cpu = .{ .pc = 0x8000, .a = 0x80, .y = 1, .status = .{ .negative = true } };

    try std.testing.expectEqual(@as(u8, 3), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 0x8004), cpu.pc);
    cpu.pc = 0x8002;
    bus.clearTrace();
    try std.testing.expectEqual(@as(u8, 5), try cpu.step(&bus));
    try std.testing.expect(cpu.status.carry);
    try std.testing.expect(cpu.status.zero);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x8002, .value = 0xd9 },
        .{ .kind = .read, .address = 0x8003, .value = 0xff },
        .{ .kind = .read, .address = 0x8004, .value = 0x12 },
        .{ .kind = .read, .address = 0x1200, .value = 0x44 },
        .{ .kind = .read, .address = 0x1300, .value = 0x80 },
    }, bus.accesses());
}

test "all 151 official 2A03 opcodes are dispatched" {
    // This is the complete official 6502/2A03 opcode set. Each opcode is
    // executed against a zeroed, side-effect-safe test bus; detailed cycle
    // and bus ordering remain covered by the focused tests above.
    const official_opcodes = [_]u8{
        0x00, 0x01, 0x05, 0x06, 0x08, 0x09, 0x0a, 0x0d, 0x0e, 0x10, 0x11, 0x15, 0x16, 0x18, 0x19, 0x1d, 0x1e,
        0x20, 0x21, 0x24, 0x25, 0x26, 0x28, 0x29, 0x2a, 0x2c, 0x2d, 0x2e, 0x30, 0x31, 0x35, 0x36, 0x38, 0x39,
        0x3d, 0x3e, 0x40, 0x41, 0x45, 0x46, 0x48, 0x49, 0x4a, 0x4c, 0x4d, 0x4e, 0x50, 0x51, 0x55, 0x56, 0x58,
        0x59, 0x5d, 0x5e, 0x60, 0x61, 0x65, 0x66, 0x68, 0x69, 0x6a, 0x6c, 0x6d, 0x6e, 0x70, 0x71, 0x75, 0x76,
        0x78, 0x79, 0x7d, 0x7e, 0x81, 0x84, 0x85, 0x86, 0x88, 0x8a, 0x8c, 0x8d, 0x8e, 0x90, 0x91, 0x94, 0x95,
        0x96, 0x98, 0x99, 0x9a, 0x9d, 0xa0, 0xa1, 0xa2, 0xa4, 0xa5, 0xa6, 0xa8, 0xa9, 0xaa, 0xac, 0xad, 0xae,
        0xb0, 0xb1, 0xb4, 0xb5, 0xb6, 0xb8, 0xb9, 0xba, 0xbc, 0xbd, 0xbe, 0xc0, 0xc1, 0xc4, 0xc5, 0xc6, 0xc8,
        0xc9, 0xca, 0xcc, 0xcd, 0xce, 0xd0, 0xd1, 0xd5, 0xd6, 0xd8, 0xd9, 0xdd, 0xde, 0xe0, 0xe1, 0xe4, 0xe5,
        0xe6, 0xe8, 0xe9, 0xea, 0xec, 0xed, 0xee, 0xf0, 0xf1, 0xf5, 0xf6, 0xf8, 0xf9, 0xfd, 0xfe,
    };
    try std.testing.expectEqual(@as(usize, 151), official_opcodes.len);
    for (official_opcodes) |opcode| {
        var bus: TestBus = .{};
        bus.memory[0x8000] = opcode;
        var cpu: Cpu = .{ .pc = 0x8000 };
        _ = try cpu.step(&bus);
    }
}
