const std = @import("std");

/// A deliberately narrow 68000 diagnostic core. It establishes reset-vector
/// fetch, big-endian instruction fetch, register state, stack return and
/// control flow before the full P5a instruction set is introduced. Unsupported
/// opcodes fail loudly rather than guessing behavior.
pub const Cpu = struct {
    d: [8]u32 = [_]u32{0} ** 8,
    a: [8]u32 = [_]u32{0} ** 8,
    pc: u32 = 0,
    sr: u16 = 0x2700,

    const flag_extend: u16 = 0x0010;
    const flag_negative: u16 = 0x0008;
    const flag_zero: u16 = 0x0004;
    const flag_overflow: u16 = 0x0002;
    const flag_carry: u16 = 0x0001;

    pub fn reset(self: *Cpu, bus: anytype) Error!void {
        self.a[7] = try readLong(bus, 0);
        self.pc = try readLong(bus, 4);
        self.sr = 0x2700;
    }

    /// Executes NOP, MOVEQ, selected MOVE forms, branches, DBF, JSR (An) and
    /// RTS. Cycle values are diagnostic timing anchors, not a claim of full
    /// 68000 bus-cycle accuracy yet.
    pub fn step(self: *Cpu, bus: anytype) Error!u16 {
        const opcode = try self.fetchWord(bus);
        if (opcode == 0x4e71) return 4; // NOP
        if (opcode == 0x4e75) { // RTS
            self.pc = try readLong(bus, self.a[7]);
            self.a[7] +%= 4;
            return 16;
        }
        if (opcode & 0xfff8 == 0x4e90) { // JSR (An)
            const register: usize = @intCast(opcode & 7);
            try self.pushLong(bus, self.pc);
            self.pc = self.a[register];
            return 16;
        }
        if (opcode & 0xfff8 == 0x4ed0) { // JMP (An)
            const register: usize = @intCast(opcode & 7);
            self.pc = self.a[register];
            return 8;
        }
        if (opcode & 0xff00 == 0x6100) { // BSR.s/.w
            const low: u8 = @truncate(opcode);
            const displacement: i32 = if (low != 0)
                @as(i32, @as(i8, @bitCast(low)))
            else blk: {
                const extension = try self.fetchWord(bus);
                break :blk @as(i32, @as(i16, @bitCast(extension)));
            };
            try self.pushLong(bus, self.pc);
            if (displacement < 0) {
                self.pc -%= @intCast(-displacement);
            } else {
                self.pc +%= @intCast(displacement);
            }
            return if (low == 0) 20 else 18;
        }
        if (opcode & 0xf1ff == 0x203c) { // MOVE.L #imm,Dn
            const register: usize = @intCast((opcode >> 9) & 7);
            self.d[register] = try self.fetchLong(bus);
            self.setMoveLongFlags(self.d[register]);
            return 12;
        }
        if (opcode & 0xf1f8 == 0x2080) { // MOVE.L Dn,(An)
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            try writeLong(bus, self.a[destination], self.d[source]);
            self.setMoveLongFlags(self.d[source]);
            return 12;
        }
        if (opcode & 0xf1f8 == 0x2010) { // MOVE.L (An),Dn
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            self.d[destination] = try readLong(bus, self.a[source]);
            self.setMoveLongFlags(self.d[destination]);
            return 12;
        }
        if (opcode & 0xf1f8 == 0x2018) { // MOVE.L (An)+,Dn
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            self.d[destination] = try readLong(bus, self.a[source]);
            self.a[source] +%= 4;
            self.setMoveLongFlags(self.d[destination]);
            return 12;
        }
        if (opcode & 0xf1f8 == 0x2020) { // MOVE.L -(An),Dn
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            self.a[source] -%= 4;
            self.d[destination] = try readLong(bus, self.a[source]);
            self.setMoveLongFlags(self.d[destination]);
            return 14;
        }
        if (opcode & 0xf1f8 == 0x20c0) { // MOVE.L Dn,(An)+
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            try writeLong(bus, self.a[destination], self.d[source]);
            self.a[destination] +%= 4;
            self.setMoveLongFlags(self.d[source]);
            return 12;
        }
        if (opcode & 0xf1f8 == 0x2100) { // MOVE.L Dn,-(An)
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            self.a[destination] -%= 4;
            try writeLong(bus, self.a[destination], self.d[source]);
            self.setMoveLongFlags(self.d[source]);
            return 14;
        }
        if (opcode & 0xf1f8 == 0x2028) { // MOVE.L (d16,An),Dn
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            const address = self.addressWithWordDisplacement(self.a[source], try self.fetchWord(bus));
            self.d[destination] = try readLong(bus, address);
            self.setMoveLongFlags(self.d[destination]);
            return 16;
        }
        if (opcode & 0xf1f8 == 0x2140) { // MOVE.L Dn,(d16,An)
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            const address = self.addressWithWordDisplacement(self.a[destination], try self.fetchWord(bus));
            try writeLong(bus, address, self.d[source]);
            self.setMoveLongFlags(self.d[source]);
            return 16;
        }
        if (opcode & 0xf1ff == 0x207c) { // MOVEA.L #imm,An
            const register: usize = @intCast((opcode >> 9) & 7);
            self.a[register] = try self.fetchLong(bus);
            return 12;
        }
        if (opcode & 0xf1ff == 0x307c) { // MOVEA.W #imm,An
            const register: usize = @intCast((opcode >> 9) & 7);
            const immediate: i16 = @bitCast(try self.fetchWord(bus));
            self.a[register] = @bitCast(@as(i32, immediate));
            return 8;
        }
        if (opcode & 0xf1f8 == 0x41e8) { // LEA (d16,An),An
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            self.a[destination] = self.addressWithWordDisplacement(self.a[source], try self.fetchWord(bus));
            return 8;
        }
        if (opcode & 0xf1ff == 0x41fa) { // LEA (d16,PC),An
            const destination: usize = @intCast((opcode >> 9) & 7);
            // On 68000, PC-relative effective addresses use the address of
            // the extension word itself, not the PC after consuming it.
            const extension_address = self.pc;
            const displacement = try self.fetchWord(bus);
            self.a[destination] = self.addressWithWordDisplacement(extension_address, displacement);
            return 8;
        }
        if (opcode & 0xf1ff == 0x303c) { // MOVE.W #imm,Dn
            const register: usize = @intCast((opcode >> 9) & 7);
            const value = try self.fetchWord(bus);
            self.d[register] = (self.d[register] & 0xffff0000) | value;
            self.setMoveWordFlags(value);
            return 8;
        }
        if (opcode & 0xf1ff == 0x30bc) { // MOVE.W #imm,(An)
            const register: usize = @intCast((opcode >> 9) & 7);
            const value = try self.fetchWord(bus);
            try writeWord(bus, self.a[register], value);
            self.setMoveWordFlags(value);
            return 16;
        }
        if (opcode & 0xf1f8 == 0x3080) { // MOVE.W Dn,(An)
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            const value: u16 = @truncate(self.d[source]);
            try writeWord(bus, self.a[destination], value);
            self.setMoveWordFlags(value);
            return 8;
        }
        if (opcode & 0xf1f8 == 0x3010) { // MOVE.W (An),Dn
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            const value = try readWord(bus, self.a[source]);
            self.d[destination] = (self.d[destination] & 0xffff0000) | value;
            self.setMoveWordFlags(value);
            return 8;
        }
        if (opcode & 0xf1f8 == 0x3028) { // MOVE.W (d16,An),Dn
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            const address = self.addressWithWordDisplacement(self.a[source], try self.fetchWord(bus));
            const value = try readWord(bus, address);
            self.d[destination] = (self.d[destination] & 0xffff0000) | value;
            self.setMoveWordFlags(value);
            return 12;
        }
        if (opcode & 0xf1f8 == 0x3140) { // MOVE.W Dn,(d16,An)
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            const address = self.addressWithWordDisplacement(self.a[destination], try self.fetchWord(bus));
            const value: u16 = @truncate(self.d[source]);
            try writeWord(bus, address, value);
            self.setMoveWordFlags(value);
            return 12;
        }
        if (opcode & 0xf1f8 == 0x3018) { // MOVE.W (An)+,Dn
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            const value = try readWord(bus, self.a[source]);
            self.a[source] +%= 2;
            self.d[destination] = (self.d[destination] & 0xffff0000) | value;
            self.setMoveWordFlags(value);
            return 8;
        }
        if (opcode & 0xf1f8 == 0x30c0) { // MOVE.W Dn,(An)+
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            const value: u16 = @truncate(self.d[source]);
            try writeWord(bus, self.a[destination], value);
            self.a[destination] +%= 2;
            self.setMoveWordFlags(value);
            return 8;
        }
        if (opcode & 0xf1f8 == 0x3020) { // MOVE.W -(An),Dn
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            self.a[source] -%= 2;
            const value = try readWord(bus, self.a[source]);
            self.d[destination] = (self.d[destination] & 0xffff0000) | value;
            self.setMoveWordFlags(value);
            return 10;
        }
        if (opcode & 0xf1f8 == 0x3100) { // MOVE.W Dn,-(An)
            const destination: usize = @intCast((opcode >> 9) & 7);
            const source: usize = @intCast(opcode & 7);
            self.a[destination] -%= 2;
            const value: u16 = @truncate(self.d[source]);
            try writeWord(bus, self.a[destination], value);
            self.setMoveWordFlags(value);
            return 10;
        }
        if (opcode & 0xf100 == 0x7000) { // MOVEQ #imm8,Dn
            const register: usize = @intCast((opcode >> 9) & 7);
            const immediate: i8 = @bitCast(@as(u8, @truncate(opcode)));
            self.d[register] = @bitCast(@as(i32, immediate));
            self.setMoveLongFlags(self.d[register]);
            return 4;
        }
        if (opcode & 0xf1ff == 0xb0bc) { // CMP.L #imm,Dn
            const register: usize = @intCast((opcode >> 9) & 7);
            self.setCompareLongFlags(self.d[register], try self.fetchLong(bus));
            return 14;
        }
        if (opcode & 0xf1ff == 0xb07c) { // CMP.W #imm,Dn
            const register: usize = @intCast((opcode >> 9) & 7);
            const source = try self.fetchWord(bus);
            self.setCompareWordFlags(@truncate(self.d[register]), source);
            return 8;
        }
        if (opcode & 0xf1f8 == 0x5080) { // ADDQ.L #imm3,Dn (encoded 0 means 8)
            const register: usize = @intCast(opcode & 7);
            const encoded: u32 = @intCast((opcode >> 9) & 7);
            const immediate = if (encoded == 0) @as(u32, 8) else encoded;
            const destination = self.d[register];
            self.d[register] +%= immediate;
            self.setAddLongFlags(destination, immediate, self.d[register]);
            return 8;
        }
        if (opcode & 0xf1f8 == 0x5040) { // ADDQ.W #imm3,Dn (encoded 0 means 8)
            const register: usize = @intCast(opcode & 7);
            const encoded: u16 = @intCast((opcode >> 9) & 7);
            const immediate = if (encoded == 0) @as(u16, 8) else encoded;
            const destination: u16 = @truncate(self.d[register]);
            const result = destination +% immediate;
            self.d[register] = (self.d[register] & 0xffff0000) | result;
            self.setAddWordFlags(destination, immediate, result);
            return 4;
        }
        if (opcode & 0xf1f8 == 0x5180) { // SUBQ.L #imm3,Dn (encoded 0 means 8)
            const register: usize = @intCast(opcode & 7);
            const encoded: u32 = @intCast((opcode >> 9) & 7);
            const immediate = if (encoded == 0) @as(u32, 8) else encoded;
            const destination = self.d[register];
            self.d[register] -%= immediate;
            self.setSubtractLongFlags(destination, immediate, self.d[register], true);
            return 8;
        }
        if (opcode & 0xf1f8 == 0x5140) { // SUBQ.W #imm3,Dn (encoded 0 means 8)
            const register: usize = @intCast(opcode & 7);
            const encoded: u16 = @intCast((opcode >> 9) & 7);
            const immediate = if (encoded == 0) @as(u16, 8) else encoded;
            const destination: u16 = @truncate(self.d[register]);
            const result = destination -% immediate;
            self.d[register] = (self.d[register] & 0xffff0000) | result;
            self.setSubtractWordFlags(destination, immediate, result, true);
            return 4;
        }
        if (opcode & 0xfff8 == 0x51c8) { // DBF Dn,displacement
            const register: usize = @intCast(opcode & 7);
            const displacement: i32 = @as(i32, @as(i16, @bitCast(try self.fetchWord(bus))));
            const counter: u16 = @truncate(self.d[register]);
            const decremented = counter -% 1;
            self.d[register] = (self.d[register] & 0xffff0000) | decremented;
            if (decremented != 0xffff) {
                if (displacement < 0) {
                    self.pc -%= @intCast(-displacement);
                } else {
                    self.pc +%= @intCast(displacement);
                }
                return 10;
            }
            return 12;
        }
        if (opcode & 0xfff8 == 0x4a80) { // TST.L Dn
            const register: usize = @intCast(opcode & 7);
            self.setMoveLongFlags(self.d[register]);
            return 4;
        }
        if (opcode & 0xfff8 == 0x4a40) { // TST.W Dn
            const register: usize = @intCast(opcode & 7);
            self.setMoveWordFlags(@truncate(self.d[register]));
            return 4;
        }
        if (opcode & 0xfff8 == 0x4240) { // CLR.W Dn
            const register: usize = @intCast(opcode & 7);
            self.d[register] &= 0xffff0000;
            self.setMoveWordFlags(0);
            return 4;
        }
        if (opcode & 0xfff8 == 0x4280) { // CLR.L Dn
            const register: usize = @intCast(opcode & 7);
            self.d[register] = 0;
            self.setMoveLongFlags(0);
            return 4;
        }
        if (opcode & 0xfff8 == 0x4840) { // SWAP Dn
            const register: usize = @intCast(opcode & 7);
            self.d[register] = (self.d[register] << 16) | (self.d[register] >> 16);
            self.setMoveLongFlags(self.d[register]);
            return 4;
        }
        if (opcode & 0xfff8 == 0x4880) { // EXT.W Dn: byte -> word
            const register: usize = @intCast(opcode & 7);
            const value: i8 = @bitCast(@as(u8, @truncate(self.d[register])));
            const extended: u16 = @bitCast(@as(i16, value));
            self.d[register] = (self.d[register] & 0xffff0000) | extended;
            self.setMoveWordFlags(extended);
            return 4;
        }
        if (opcode & 0xfff8 == 0x48c0) { // EXT.L Dn: word -> long
            const register: usize = @intCast(opcode & 7);
            const value: i16 = @bitCast(@as(u16, @truncate(self.d[register])));
            self.d[register] = @bitCast(@as(i32, value));
            self.setMoveLongFlags(self.d[register]);
            return 4;
        }
        if (opcode & 0xf0f8 == 0x50c0) { // Scc Dn
            const register: usize = @intCast(opcode & 7);
            const condition: u4 = @intCast((opcode >> 8) & 0x0f);
            const set = self.conditionTrue(condition);
            const value: u32 = if (set) 0xff else 0;
            self.d[register] = (self.d[register] & 0xffffff00) | value;
            return 4;
        }
        if (opcode & 0xfff8 == 0x0040) { // ORI.W #imm,Dn
            const register: usize = @intCast(opcode & 7);
            const result: u16 = @truncate(self.d[register] | try self.fetchWord(bus));
            self.d[register] = (self.d[register] & 0xffff0000) | result;
            self.setMoveWordFlags(result);
            return 8;
        }
        if (opcode & 0xfff8 == 0x0080) { // ORI.L #imm,Dn
            const register: usize = @intCast(opcode & 7);
            self.d[register] |= try self.fetchLong(bus);
            self.setMoveLongFlags(self.d[register]);
            return 16;
        }
        if (opcode & 0xfff8 == 0x0240) { // ANDI.W #imm,Dn
            const register: usize = @intCast(opcode & 7);
            const result: u16 = @truncate(self.d[register] & try self.fetchWord(bus));
            self.d[register] = (self.d[register] & 0xffff0000) | result;
            self.setMoveWordFlags(result);
            return 8;
        }
        if (opcode & 0xfff8 == 0x0280) { // ANDI.L #imm,Dn
            const register: usize = @intCast(opcode & 7);
            self.d[register] &= try self.fetchLong(bus);
            self.setMoveLongFlags(self.d[register]);
            return 16;
        }
        if (opcode & 0xfff8 == 0x0a40) { // EORI.W #imm,Dn
            const register: usize = @intCast(opcode & 7);
            const result: u16 = @truncate(self.d[register] ^ try self.fetchWord(bus));
            self.d[register] = (self.d[register] & 0xffff0000) | result;
            self.setMoveWordFlags(result);
            return 8;
        }
        if (opcode & 0xfff8 == 0x0a80) { // EORI.L #imm,Dn
            const register: usize = @intCast(opcode & 7);
            self.d[register] ^= try self.fetchLong(bus);
            self.setMoveLongFlags(self.d[register]);
            return 16;
        }
        if (opcode & 0xfff8 == 0x4640) { // NOT.W Dn
            const register: usize = @intCast(opcode & 7);
            const result: u16 = ~@as(u16, @truncate(self.d[register]));
            self.d[register] = (self.d[register] & 0xffff0000) | result;
            self.setMoveWordFlags(result);
            return 4;
        }
        if (opcode & 0xfff8 == 0x4680) { // NOT.L Dn
            const register: usize = @intCast(opcode & 7);
            self.d[register] = ~self.d[register];
            self.setMoveLongFlags(self.d[register]);
            return 4;
        }
        if (opcode & 0xfff8 == 0x4440) { // NEG.W Dn
            const register: usize = @intCast(opcode & 7);
            const destination: u16 = @truncate(self.d[register]);
            const result = 0 -% destination;
            self.d[register] = (self.d[register] & 0xffff0000) | result;
            self.setNegateWordFlags(destination, result);
            return 4;
        }
        if (opcode & 0xfff8 == 0x4480) { // NEG.L Dn
            const register: usize = @intCast(opcode & 7);
            const destination = self.d[register];
            self.d[register] = 0 -% destination;
            self.setNegateLongFlags(destination, self.d[register]);
            return 4;
        }
        if (opcode & 0xff00 == 0x6000 or opcode & 0xff00 == 0x6200 or opcode & 0xff00 == 0x6300 or opcode & 0xff00 == 0x6400 or opcode & 0xff00 == 0x6500 or opcode & 0xff00 == 0x6600 or opcode & 0xff00 == 0x6700 or opcode & 0xff00 == 0x6800 or opcode & 0xff00 == 0x6900 or opcode & 0xff00 == 0x6a00 or opcode & 0xff00 == 0x6b00 or opcode & 0xff00 == 0x6c00 or opcode & 0xff00 == 0x6d00 or opcode & 0xff00 == 0x6e00 or opcode & 0xff00 == 0x6f00) { // BRA/BHI/BLS/BCC/BCS/BNE/BEQ/BVC/BVS/BPL/BMI/BGE/BLT/BGT/BLE .s/.w
            const low: u8 = @truncate(opcode);
            const displacement: i32 = if (low != 0)
                @as(i32, @as(i8, @bitCast(low)))
            else blk: {
                const extension = try self.fetchWord(bus);
                break :blk @as(i32, @as(i16, @bitCast(extension)));
            };
            const condition = opcode & 0xff00;
            const should_branch = switch (condition) {
                0x6000 => true, // BRA
                0x6200 => self.sr & (flag_carry | flag_zero) == 0, // BHI: !C && !Z
                0x6300 => self.sr & (flag_carry | flag_zero) != 0, // BLS: C || Z
                0x6400 => self.sr & flag_carry == 0, // BCC
                0x6500 => self.sr & flag_carry != 0, // BCS
                0x6600 => self.sr & flag_zero == 0, // BNE
                0x6700 => self.sr & flag_zero != 0, // BEQ
                0x6800 => self.sr & flag_overflow == 0, // BVC
                0x6900 => self.sr & flag_overflow != 0, // BVS
                0x6a00 => self.sr & flag_negative == 0, // BPL
                0x6b00 => self.sr & flag_negative != 0, // BMI
                0x6c00 => (self.sr & flag_negative != 0) == (self.sr & flag_overflow != 0), // BGE: N == V
                0x6d00 => (self.sr & flag_negative != 0) != (self.sr & flag_overflow != 0), // BLT: N != V
                0x6e00 => self.sr & flag_zero == 0 and (self.sr & flag_negative != 0) == (self.sr & flag_overflow != 0), // BGT: !Z && N == V
                0x6f00 => self.sr & flag_zero != 0 or (self.sr & flag_negative != 0) != (self.sr & flag_overflow != 0), // BLE: Z || N != V
                else => unreachable,
            };
            if (should_branch) {
                if (displacement < 0) {
                    self.pc -%= @intCast(-displacement);
                } else {
                    self.pc +%= @intCast(displacement);
                }
            }
            return if (low == 0) 12 else 10;
        }
        return error.UnsupportedOpcode;
    }

    fn fetchWord(self: *Cpu, bus: anytype) Error!u16 {
        const word = try readWord(bus, self.pc);
        self.pc +%= 2;
        return word;
    }

    fn fetchLong(self: *Cpu, bus: anytype) Error!u32 {
        const value = try readLong(bus, self.pc);
        self.pc +%= 4;
        return value;
    }

    fn pushLong(self: *Cpu, bus: anytype, value: u32) Error!void {
        self.a[7] -%= 4;
        try writeLong(bus, self.a[7], value);
    }

    fn addressWithWordDisplacement(_: *const Cpu, base: u32, encoded_displacement: u16) u32 {
        const displacement: i16 = @bitCast(encoded_displacement);
        return if (displacement < 0)
            base -% @as(u32, @intCast(-@as(i32, displacement)))
        else
            base +% @as(u32, @intCast(displacement));
    }

    /// Shared 68000 condition-code decoder for Dn-only Scc. Bcc accepts all
    /// non-zero conditions separately; condition 0 (true) and 1 (false) are
    /// meaningful only to Scc in this restricted implementation.
    fn conditionTrue(self: *const Cpu, condition: u4) bool {
        const n = self.sr & flag_negative != 0;
        const z = self.sr & flag_zero != 0;
        const v = self.sr & flag_overflow != 0;
        const c = self.sr & flag_carry != 0;
        return switch (condition) {
            0 => true, // ST
            1 => false, // SF
            2 => !c and !z, // SHI
            3 => c or z, // SLS
            4 => !c, // SCC
            5 => c, // SCS
            6 => !z, // SNE
            7 => z, // SEQ
            8 => !v, // SVC
            9 => v, // SVS
            10 => !n, // SPL
            11 => n, // SMI
            12 => n == v, // SGE
            13 => n != v, // SLT
            14 => !z and n == v, // SGT
            15 => z or n != v, // SLE
        };
    }

    fn setMoveLongFlags(self: *Cpu, value: u32) void {
        self.sr &= ~(flag_negative | flag_zero | flag_overflow | flag_carry);
        if (value == 0) self.sr |= flag_zero;
        if (value & 0x80000000 != 0) self.sr |= flag_negative;
    }

    fn setMoveWordFlags(self: *Cpu, value: u16) void {
        self.sr &= ~(flag_negative | flag_zero | flag_overflow | flag_carry);
        if (value == 0) self.sr |= flag_zero;
        if (value & 0x8000 != 0) self.sr |= flag_negative;
    }

    /// CMP computes destination - source for condition codes while preserving
    /// both operands and X. C represents an unsigned borrow.
    fn setCompareLongFlags(self: *Cpu, destination: u32, source: u32) void {
        const result = destination -% source;
        self.setSubtractLongFlags(destination, source, result, false);
    }

    fn setCompareWordFlags(self: *Cpu, destination: u16, source: u16) void {
        const result = destination -% source;
        self.setSubtractWordFlags(destination, source, result, false);
    }

    fn setSubtractWordFlags(self: *Cpu, destination: u16, source: u16, result: u16, update_extend: bool) void {
        self.sr &= ~(flag_negative | flag_zero | flag_overflow | flag_carry);
        if (update_extend) self.sr &= ~flag_extend;
        if (result == 0) self.sr |= flag_zero;
        if (result & 0x8000 != 0) self.sr |= flag_negative;
        if ((destination ^ source) & (destination ^ result) & 0x8000 != 0) {
            self.sr |= flag_overflow;
        }
        if (source > destination) {
            self.sr |= flag_carry;
            if (update_extend) self.sr |= flag_extend;
        }
    }

    fn setSubtractLongFlags(self: *Cpu, destination: u32, source: u32, result: u32, update_extend: bool) void {
        self.sr &= ~(flag_negative | flag_zero | flag_overflow | flag_carry);
        if (update_extend) self.sr &= ~flag_extend;
        if (result == 0) self.sr |= flag_zero;
        if (result & 0x80000000 != 0) self.sr |= flag_negative;
        if ((destination ^ source) & (destination ^ result) & 0x80000000 != 0) {
            self.sr |= flag_overflow;
        }
        if (source > destination) {
            self.sr |= flag_carry;
            if (update_extend) self.sr |= flag_extend;
        }
    }

    fn setAddLongFlags(self: *Cpu, destination: u32, source: u32, result: u32) void {
        self.sr &= ~(flag_extend | flag_negative | flag_zero | flag_overflow | flag_carry);
        if (result == 0) self.sr |= flag_zero;
        if (result & 0x80000000 != 0) self.sr |= flag_negative;
        if (~(destination ^ source) & (destination ^ result) & 0x80000000 != 0) {
            self.sr |= flag_overflow;
        }
        if (result < destination) self.sr |= flag_extend | flag_carry;
    }

    fn setAddWordFlags(self: *Cpu, destination: u16, source: u16, result: u16) void {
        self.sr &= ~(flag_extend | flag_negative | flag_zero | flag_overflow | flag_carry);
        if (result == 0) self.sr |= flag_zero;
        if (result & 0x8000 != 0) self.sr |= flag_negative;
        if (~(destination ^ source) & (destination ^ result) & 0x8000 != 0) {
            self.sr |= flag_overflow;
        }
        if (result < destination) self.sr |= flag_extend | flag_carry;
    }

    fn setNegateWordFlags(self: *Cpu, destination: u16, result: u16) void {
        self.sr &= ~(flag_extend | flag_negative | flag_zero | flag_overflow | flag_carry);
        if (result == 0) self.sr |= flag_zero;
        if (result & 0x8000 != 0) self.sr |= flag_negative;
        if (destination == 0x8000) self.sr |= flag_overflow;
        if (destination != 0) self.sr |= flag_extend | flag_carry;
    }

    fn setNegateLongFlags(self: *Cpu, destination: u32, result: u32) void {
        self.sr &= ~(flag_extend | flag_negative | flag_zero | flag_overflow | flag_carry);
        if (result == 0) self.sr |= flag_zero;
        if (result & 0x80000000 != 0) self.sr |= flag_negative;
        if (destination == 0x80000000) self.sr |= flag_overflow;
        if (destination != 0) self.sr |= flag_extend | flag_carry;
    }
};

pub const Error = error{
    BusFault,
    UnsupportedOpcode,
};

fn readWord(bus: anytype, address: u32) Error!u16 {
    return bus.readWord(address) orelse error.BusFault;
}

fn readLong(bus: anytype, address: u32) Error!u32 {
    return bus.readLong(address) orelse error.BusFault;
}

fn writeWord(bus: anytype, address: u32, value: u16) Error!void {
    if (!bus.writeWord(address, value)) return error.BusFault;
}

fn writeLong(bus: anytype, address: u32, value: u32) Error!void {
    try writeWord(bus, address, @truncate(value >> 16));
    try writeWord(bus, address +% 2, @truncate(value));
}

test "68000 diagnostic CPU resets, executes MOVEQ and branches over an opcode" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc, // reset SSP = $10FFFC
        0x00, 0x00, 0x00, 0x08, // reset PC = $000008
        0x4e, 0x71, // NOP
        0x70, 0xff, // MOVEQ #-1,D0
        0x60, 0x02, // BRA.s +2 (skip word at $00000E)
        0xff, 0xff, // unsupported opcode, skipped
        0x4e, 0x71, // NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    try std.testing.expectEqual(@as(u32, 0x10fffc), cpu.a[7]);
    try std.testing.expectEqual(@as(u32, 8), cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xffffffff), cpu.d[0]);
    try std.testing.expectEqual(@as(u16, 10), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 16), cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 diagnostic CPU RTS reads a big-endian return address and rejects unknown opcodes" {
    const Bus = @import("bus.zig").Bus;
    var program: [0x20]u8 = [_]u8{0} ** 0x20;
    program[0..8].* = .{ 0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00, 0x08 };
    program[8..10].* = .{ 0x4e, 0x75 };
    program[0x18..0x1a].* = .{ 0x4e, 0x71 };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    try std.testing.expect(bus.writeWord(0x100010, 0));
    try std.testing.expect(bus.writeWord(0x100012, 0x0018));
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    try std.testing.expectEqual(@as(u16, 16), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x18), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x100014), cpu.a[7]);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    cpu.pc = 0x0e;
    try std.testing.expectError(error.UnsupportedOpcode, cpu.step(&bus));
}

test "68000 JSR through an address register pushes a big-endian return address for RTS" {
    const Bus = @import("bus.zig").Bus;
    var program: [0x20]u8 = [_]u8{0} ** 0x20;
    program[0..8].* = .{ 0x00, 0x10, 0xff, 0xfc, 0x00, 0x00, 0x00, 0x08 };
    program[8..10].* = .{ 0x4e, 0x91 }; // JSR (A1)
    program[10..12].* = .{ 0x4e, 0x71 }; // return target: NOP
    program[0x10..0x12].* = .{ 0x4e, 0x71 }; // subroutine: NOP
    program[0x12..0x14].* = .{ 0x4e, 0x75 }; // RTS
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[1] = 0x10;
    try std.testing.expectEqual(@as(u16, 16), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x10), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x10fff8), cpu.a[7]);
    try std.testing.expectEqual(@as(?u32, 0x0000000a), bus.readLong(0x10fff8));
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u16, 16), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x0a), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x10fffc), cpu.a[7]);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 JMP through an address register changes PC without touching the stack or CCR" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x4e, 0xd3, // JMP (A3)
        0xff, 0xff, // skipped
        0x4e, 0x71, // target: NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[3] = 12;
    cpu.sr = 0x271f;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 12), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x10fffc), cpu.a[7]);
    try std.testing.expectEqual(@as(u16, 0x271f), cpu.sr);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 BSR uses relative short and word targets with RTS return addresses" {
    const Bus = @import("bus.zig").Bus;
    var program: [0x30]u8 = [_]u8{0} ** 0x30;
    program[0..8].* = .{ 0x00, 0x10, 0xff, 0xfc, 0x00, 0x00, 0x00, 0x08 };
    program[8..10].* = .{ 0x61, 0x06 }; // BSR.s $10
    program[10..12].* = .{ 0x61, 0x00 }; // BSR.w $20
    program[12..14].* = .{ 0x00, 0x12 };
    program[14..16].* = .{ 0x4e, 0x71 }; // final return target: NOP
    program[16..18].* = .{ 0x4e, 0x75 }; // short subroutine: RTS
    program[0x20..0x22].* = .{ 0x4e, 0x75 }; // word subroutine: RTS
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    try std.testing.expectEqual(@as(u16, 18), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x10), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x10fff8), cpu.a[7]);
    try std.testing.expectEqual(@as(?u32, 0x0000000a), bus.readLong(0x10fff8));
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0x0a), cpu.pc);
    try std.testing.expectEqual(@as(u16, 20), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x20), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x10fff8), cpu.a[7]);
    try std.testing.expectEqual(@as(?u32, 0x0000000e), bus.readLong(0x10fff8));
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0x0e), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x10fffc), cpu.a[7]);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 diagnostic CPU loads a big-endian immediate long into any D register" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc, // reset SSP
        0x00, 0x00, 0x00, 0x08, // reset PC
        0x26, 0x3c, // MOVE.L #$12345678,D3
        0x12, 0x34,
        0x56, 0x78,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.d[3]);
    try std.testing.expectEqual(@as(u32, 14), cpu.pc);
}

test "68000 MOVE.L transfers big-endian values between data registers and address-register memory" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x24, 0x81, // MOVE.L D1,(A2)
        0x2c, 0x12, // MOVE.L (A2),D6
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[2] = 0x100000;
    cpu.d[1] = 0x80abcdef;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry;
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(?u32, 0x80abcdef), bus.readLong(0x100000));
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry) == 0);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x80abcdef), cpu.d[6]);
    try std.testing.expect(cpu.sr & Cpu.flag_negative != 0);
}

test "68000 MOVE.L predecrement and postincrement advance addresses by four bytes" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x24, 0x1f, // MOVE.L (A7)+,D2
        0x2f, 0x02, // MOVE.L D2,-(A7)
        0x26, 0x20, // MOVE.L -(A0),D3
        0x2a, 0xc3, // MOVE.L D3,(A5)+
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    try std.testing.expect(bus.writeWord(0x100000, 0x80ab));
    try std.testing.expect(bus.writeWord(0x100002, 0xcdef));
    try std.testing.expect(bus.writeWord(0x100010, 0x1234));
    try std.testing.expect(bus.writeWord(0x100012, 0x5678));
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[7] = 0x100000;
    cpu.a[0] = 0x100014;
    cpu.a[5] = 0x100020;
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x80abcdef), cpu.d[2]);
    try std.testing.expectEqual(@as(u32, 0x100004), cpu.a[7]);
    try std.testing.expectEqual(@as(u16, 14), try cpu.step(&bus));
    try std.testing.expectEqual(@as(?u32, 0x80abcdef), bus.readLong(0x100000));
    try std.testing.expectEqual(@as(u32, 0x100000), cpu.a[7]);
    try std.testing.expectEqual(@as(u16, 14), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.d[3]);
    try std.testing.expectEqual(@as(u32, 0x100010), cpu.a[0]);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(?u32, 0x12345678), bus.readLong(0x100020));
    try std.testing.expectEqual(@as(u32, 0x100024), cpu.a[5]);
}

test "68000 MOVE.L transfers through signed address displacements" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x26, 0x28, // MOVE.L -4(A0),D3
        0xff, 0xfc,
        0x2b, 0x43, // MOVE.L D3,4(A5)
        0x00, 0x04,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    try std.testing.expect(bus.writeWord(0x100000, 0x80ab));
    try std.testing.expect(bus.writeWord(0x100002, 0xcdef));
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[0] = 0x100004;
    cpu.a[5] = 0x100010;
    try std.testing.expectEqual(@as(u16, 16), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x80abcdef), cpu.d[3]);
    try std.testing.expect(cpu.sr & Cpu.flag_negative != 0);
    try std.testing.expectEqual(@as(u16, 16), try cpu.step(&bus));
    try std.testing.expectEqual(@as(?u32, 0x80abcdef), bus.readLong(0x100014));
}

test "68000 diagnostic CPU loads a big-endian immediate long into an address register" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x24, 0x7c, // MOVEA.L #$00100000,A2
        0x00, 0x10,
        0x00, 0x00,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x00100000), cpu.a[2]);
}

test "68000 MOVEA.W immediate sign-extends without changing condition codes" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x34, 0x7c, // MOVEA.W #$8001,A2
        0x80, 0x01,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.sr = 0x271f;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xffff8001), cpu.a[2]);
    try std.testing.expectEqual(@as(u16, 0x271f), cpu.sr);
}

test "68000 LEA address displacement preserves CCR and supports a distinct destination" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x49, 0xe8, // LEA -$20(A0),A4
        0xff, 0xe0,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[0] = 0x00100020;
    cpu.sr = 0x271f;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x00100000), cpu.a[4]);
    try std.testing.expectEqual(@as(u32, 0x00100020), cpu.a[0]);
    try std.testing.expectEqual(@as(u16, 0x271f), cpu.sr);
}

test "68000 LEA PC displacement uses the extension-word address and preserves CCR" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x4d, 0xfa, // LEA -$0004(PC),A6; extension word is at $000A
        0xff, 0xfc,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.sr = 0x271f;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 6), cpu.a[6]);
    try std.testing.expectEqual(@as(u32, 12), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0x271f), cpu.sr);
}

test "68000 diagnostic CPU writes an immediate word through an address register" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x30, 0xbc, // MOVE.W #$beef,(A0)
        0xbe, 0xef,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[0] = 0x100000;
    try std.testing.expectEqual(@as(u16, 16), try cpu.step(&bus));
    try std.testing.expectEqual(@as(?u16, 0xbeef), bus.readWord(0x100000));
    cpu.a[0] = 0;
    cpu.pc = 8;
    try std.testing.expectError(error.BusFault, cpu.step(&bus));
}

test "68000 MOVE.W immediate writes only the low data-register word and sets word flags" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x36, 0x3c, // MOVE.W #$8000,D3
        0x80, 0x00,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[3] = 0xface_0000;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface8000), cpu.d[3]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry) == 0);
}

test "68000 MOVE.W transfers between data registers and address-register memory" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x34, 0x81, // MOVE.W D1,(A2)
        0x3a, 0x12, // MOVE.W (A2),D5
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[2] = 0x100000;
    cpu.d[1] = 0x1234_8001;
    cpu.d[5] = 0xaaaa_0000;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_overflow | Cpu.flag_carry;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(?u16, 0x8001), bus.readWord(0x100000));
    try std.testing.expect(cpu.sr & Cpu.flag_negative != 0);
    try std.testing.expect(cpu.sr & Cpu.flag_extend != 0);
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry) == 0);
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xaaaa8001), cpu.d[5]);
    try std.testing.expect(cpu.sr & Cpu.flag_negative != 0);
}

test "68000 MOVE.W transfers through signed address displacements" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x32, 0x28, // MOVE.W -2(A0),D1
        0xff, 0xfe,
        0x35, 0x41, // MOVE.W D1,2(A2)
        0x00, 0x02,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    try std.testing.expect(bus.writeWord(0x100000, 0x8001));
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[0] = 0x100002;
    cpu.a[2] = 0x100000;
    cpu.d[1] = 0xabcd0000;
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xabcd8001), cpu.d[1]);
    try std.testing.expect(cpu.sr & Cpu.flag_negative != 0);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(?u16, 0x8001), bus.readWord(0x100002));
}

test "68000 MOVE.W postincrement advances address registers after each word transfer" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x34, 0x1f, // MOVE.W (A7)+,D2
        0x3e, 0xc2, // MOVE.W D2,(A7)+
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    try std.testing.expect(bus.writeWord(0x100000, 0x8001));
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[7] = 0x100000;
    cpu.d[2] = 0xaaaa0000;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xaaaa8001), cpu.d[2]);
    try std.testing.expectEqual(@as(u32, 0x100002), cpu.a[7]);
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(?u16, 0x8001), bus.readWord(0x100002));
    try std.testing.expectEqual(@as(u32, 0x100004), cpu.a[7]);
}

test "68000 MOVE.W predecrement updates address registers before each word transfer" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x36, 0x20, // MOVE.W -(A0),D3
        0x3f, 0x03, // MOVE.W D3,-(A7)
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    try std.testing.expect(bus.writeWord(0x100000, 0x8001));
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[0] = 0x100002;
    cpu.a[7] = 0x100006;
    cpu.d[3] = 0xaaaa0000;
    try std.testing.expectEqual(@as(u16, 10), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xaaaa8001), cpu.d[3]);
    try std.testing.expectEqual(@as(u32, 0x100000), cpu.a[0]);
    try std.testing.expectEqual(@as(u16, 10), try cpu.step(&bus));
    try std.testing.expectEqual(@as(?u16, 0x8001), bus.readWord(0x100004));
    try std.testing.expectEqual(@as(u32, 0x100004), cpu.a[7]);
}

test "68000 MOVE.W immediate applies word-width N/Z flags" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x30, 0xbc, // MOVE.W #0,(A0)
        0x00, 0x00,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[0] = 0x100000;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_overflow | Cpu.flag_carry;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_zero != 0);
    try std.testing.expect(cpu.sr & Cpu.flag_extend != 0);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_overflow | Cpu.flag_carry) == 0);
}

test "68000 MOVEQ updates N/Z and clears V/C without changing X" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x70, 0x00, // MOVEQ #0,D0
        0x70, 0xff, // MOVEQ #-1,D0
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.sr |= Cpu.flag_extend | Cpu.flag_overflow | Cpu.flag_carry;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_zero != 0);
    try std.testing.expect(cpu.sr & Cpu.flag_extend != 0);
    try std.testing.expect(cpu.sr & (Cpu.flag_overflow | Cpu.flag_carry | Cpu.flag_negative) == 0);
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_negative != 0);
    try std.testing.expect(cpu.sr & Cpu.flag_zero == 0);
}

test "68000 MOVE.L immediate and TST.L share N/Z flag behavior" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x20, 0x3c, // MOVE.L #0,D0
        0x00, 0x00,
        0x00, 0x00,
        0x4a, 0x80, // TST.L D0
        0x20, 0x3c, // MOVE.L #$80000000,D0
        0x80, 0x00,
        0x00, 0x00,
        0x4a, 0x80, // TST.L D0
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_zero != 0);
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_zero != 0);
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_negative != 0);
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_negative != 0);
}

test "68000 TST.W uses the data-register low word and preserves X" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x4a, 0x43, // TST.W D3
        0x4a, 0x43, // TST.W D3
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[3] = 0x80000000;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_overflow | Cpu.flag_carry;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_extend) == (Cpu.flag_zero | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_overflow | Cpu.flag_carry) == 0);
    cpu.d[3] = 0x00008000;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry) == 0);
}

test "68000 CLR.W and CLR.L update only their operand widths and preserve X" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x42, 0x45, // CLR.W D5
        0x42, 0x86, // CLR.L D6
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[5] = 0xfacebeef;
    cpu.d[6] = 0x80abcdef;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_overflow | Cpu.flag_carry;
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface0000), cpu.d[5]);
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_extend) == (Cpu.flag_zero | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_overflow | Cpu.flag_carry) == 0);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0), cpu.d[6]);
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_extend) == (Cpu.flag_zero | Cpu.flag_extend));
}

test "68000 SWAP exchanges data-register words and applies long flags" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x48, 0x47, // SWAP D7
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[7] = 0x00018000;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry;
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x80000001), cpu.d[7]);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_negative) == (Cpu.flag_extend | Cpu.flag_negative));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry) == 0);
}

test "68000 EXT sign-extends byte and word while preserving X" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x48, 0x85, // EXT.W D5
        0x48, 0xc6, // EXT.L D6
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[5] = 0xface0080;
    cpu.d[6] = 0xface8001;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry;
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xfaceff80), cpu.d[5]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry) == 0);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xffff8001), cpu.d[6]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
}

test "68000 Scc writes only the low byte without changing CCR" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x50, 0xc0, // ST D0
        0x51, 0xc5, // SF D5
        0x57, 0xc1, // SEQ D1
        0x56, 0xc2, // SNE D2
        0x57, 0xc3, // SEQ D3
        0x56, 0xc4, // SNE D4
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[0] = 0xface0000;
    cpu.d[1] = 0xface0000;
    cpu.d[2] = 0xface0000;
    cpu.d[3] = 0xface0000;
    cpu.d[4] = 0xface0000;
    cpu.d[5] = 0xface0000;
    cpu.sr = 0x271f; // Z is set
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface00ff), cpu.d[0]);
    try std.testing.expectEqual(@as(u16, 0x271f), cpu.sr);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface0000), cpu.d[5]);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface00ff), cpu.d[1]);
    try std.testing.expectEqual(@as(u16, 0x271f), cpu.sr);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface0000), cpu.d[2]);
    cpu.sr &= ~Cpu.flag_zero;
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface0000), cpu.d[3]);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface00ff), cpu.d[4]);
    try std.testing.expect(cpu.sr & Cpu.flag_zero == 0);
}

test "68000 Scc matches carry, overflow and signed comparison conditions" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x52, 0xc0, // SHI D0
        0x53, 0xc1, // SLS D1
        0x54, 0xc2, // SCC D2
        0x55, 0xc3, // SCS D3
        0x58, 0xc4, // SVC D4
        0x59, 0xc5, // SVS D5
        0x5c, 0xc6, // SGE D6
        0x5d, 0xc7, // SLT D7
        0x5a, 0xc0, // SPL D0
        0x5b, 0xc1, // SMI D1
        0x5e, 0xc2, // SGT D2
        0x5f, 0xc3, // SLE D3
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.sr = 0x2700 | Cpu.flag_negative | Cpu.flag_overflow; // N=V=1, C=Z=0
    const expected = [_]u8{ 0xff, 0x00, 0xff, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0xff, 0xff, 0x00 };
    for (0..expected.len) |index| {
        _ = try cpu.step(&bus);
        try std.testing.expectEqual(expected[index], @as(u8, @truncate(cpu.d[index % 8])));
        try std.testing.expectEqual(@as(u16, 0x270a), cpu.sr);
    }
}

test "68000 ORI applies immediate word and long masks while preserving X" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x00, 0x42, // ORI.W #$8001,D2
        0x80, 0x01,
        0x00, 0x83, // ORI.L #$80000000,D3
        0x80, 0x00,
        0x00, 0x00,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[2] = 0xface0000;
    cpu.d[3] = 1;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface8001), cpu.d[2]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry) == 0);
    try std.testing.expectEqual(@as(u16, 16), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x80000001), cpu.d[3]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
}

test "68000 ANDI applies immediate word and long masks while preserving X" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x02, 0x44, // ANDI.W #$8001,D4
        0x80, 0x01,
        0x02, 0x85, // ANDI.L #$80000000,D5
        0x80, 0x00,
        0x00, 0x00,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[4] = 0xfaceffff;
    cpu.d[5] = 0x80abcdef;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface8001), cpu.d[4]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry) == 0);
    try std.testing.expectEqual(@as(u16, 16), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x80000000), cpu.d[5]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
}

test "68000 EORI applies immediate word and long masks while preserving X" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x0a, 0x46, // EORI.W #$8001,D6
        0x80, 0x01,
        0x0a, 0x87, // EORI.L #$80000001,D7
        0x80, 0x00,
        0x00, 0x01,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[6] = 0xface0000;
    cpu.d[7] = 0x00000001;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface8001), cpu.d[6]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry) == 0);
    try std.testing.expectEqual(@as(u16, 16), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x80000000), cpu.d[7]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
}

test "68000 NOT applies word and long inversion while preserving X" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x46, 0x41, // NOT.W D1
        0x46, 0x82, // NOT.L D2
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[1] = 0xface7ffe;
    cpu.d[2] = 0x7fffffff;
    cpu.sr |= Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry;
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface8001), cpu.d[1]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry) == 0);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x80000000), cpu.d[2]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_extend));
}

test "68000 NEG applies word and long two's-complement flags including overflow" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x44, 0x43, // NEG.W D3
        0x44, 0x84, // NEG.L D4
        0x44, 0x45, // NEG.W D5
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[3] = 0xface0001;
    cpu.d[4] = 0x80000000;
    cpu.d[5] = 0xdead0000;
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xfaceffff), cpu.d[3]);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_carry) == (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_carry));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow) == 0);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x80000000), cpu.d[4]);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_overflow | Cpu.flag_carry) == (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_overflow | Cpu.flag_carry));
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xdead0000), cpu.d[5]);
    try std.testing.expect(cpu.sr & Cpu.flag_zero != 0);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_overflow | Cpu.flag_carry) == 0);
}

test "68000 CMP.L immediate preserves registers and X while updating subtraction flags" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0xb0, 0xbc, // CMP.L #1,D0
        0x00, 0x00,
        0x00, 0x01,
        0xb0, 0xbc, // CMP.L #1,D0
        0x00, 0x00,
        0x00, 0x01,
        0xb0, 0xbc, // CMP.L #1,D0
        0x00, 0x00,
        0x00, 0x01,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.sr |= Cpu.flag_extend;

    cpu.d[0] = 0;
    try std.testing.expectEqual(@as(u16, 14), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0), cpu.d[0]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_carry | Cpu.flag_extend) == (Cpu.flag_negative | Cpu.flag_carry | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow) == 0);

    cpu.d[0] = 1;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_extend) == (Cpu.flag_zero | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_overflow | Cpu.flag_carry) == 0);

    cpu.d[0] = 0x80000000;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & (Cpu.flag_overflow | Cpu.flag_extend) == (Cpu.flag_overflow | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_zero | Cpu.flag_carry) == 0);
}

test "68000 CMP.W immediate compares only the low word and preserves X" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0xb2, 0x7c, // CMP.W #$8001,D1
        0x80, 0x01,
        0xb2, 0x7c, // CMP.W #1,D1
        0x00, 0x01,
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.sr |= Cpu.flag_extend;
    cpu.d[1] = 0xface8001;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface8001), cpu.d[1]);
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_extend) == (Cpu.flag_zero | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_overflow | Cpu.flag_carry) == 0);

    cpu.d[1] = 0xface8000;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & (Cpu.flag_overflow | Cpu.flag_extend) == (Cpu.flag_overflow | Cpu.flag_extend));
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_zero | Cpu.flag_carry) == 0);
}

test "68000 CMP.L condition codes drive BEQ control flow" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0xb0, 0xbc, // CMP.L #$1234,D0
        0x00, 0x00,
        0x12, 0x34,
        0x67, 0x02, // BEQ.s +2
        0xff, 0xff, // must be skipped
        0x4e, 0x71, // NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[0] = 0x1234;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_zero != 0);
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 18), cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 ADDQ.L uses encoded eight and updates all arithmetic flags" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x50, 0x80, // ADDQ.L #8,D0 (quick field 0)
        0x54, 0x81, // ADDQ.L #2,D1
        0x52, 0x82, // ADDQ.L #1,D2
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);

    cpu.d[0] = 0xfffffff8;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0), cpu.d[0]);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_carry) == (Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_carry));
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_overflow) == 0);

    cpu.d[1] = 0x7fffffff;
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0x80000001), cpu.d[1]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_overflow) == (Cpu.flag_negative | Cpu.flag_overflow));
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_carry) == 0);

    cpu.d[2] = 0;
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 1), cpu.d[2]);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_zero | Cpu.flag_overflow | Cpu.flag_carry) == 0);
}

test "68000 ADDQ.W preserves the high word and applies word arithmetic flags" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x50, 0x40, // ADDQ.W #8,D0
        0x54, 0x41, // ADDQ.W #2,D1
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[0] = 0xfacefff8;
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface0000), cpu.d[0]);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_carry) == (Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_carry));
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_overflow) == 0);
    cpu.d[1] = 0xbeef7fff;
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0xbeef8001), cpu.d[1]);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_overflow) == (Cpu.flag_negative | Cpu.flag_overflow));
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_zero | Cpu.flag_carry) == 0);
}

test "68000 SUBQ.L uses encoded eight and updates all arithmetic flags" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x51, 0x80, // SUBQ.L #8,D0 (quick field 0)
        0x55, 0x81, // SUBQ.L #2,D1
        0x53, 0x82, // SUBQ.L #1,D2
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);

    cpu.d[0] = 8;
    cpu.sr |= Cpu.flag_extend;
    try std.testing.expectEqual(@as(u16, 8), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0), cpu.d[0]);
    try std.testing.expect(cpu.sr & Cpu.flag_zero != 0);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_overflow | Cpu.flag_carry) == 0);

    cpu.d[1] = 0;
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0xfffffffe), cpu.d[1]);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_carry) == (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_carry));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow) == 0);

    cpu.d[2] = 0x80000000;
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0x7fffffff), cpu.d[2]);
    try std.testing.expect(cpu.sr & Cpu.flag_overflow != 0);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_zero | Cpu.flag_carry) == 0);
}

test "68000 SUBQ.W preserves the high word and applies word arithmetic flags" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x51, 0x40, // SUBQ.W #8,D0
        0x53, 0x41, // SUBQ.W #1,D1
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[0] = 0xface0000;
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xfacefff8), cpu.d[0]);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_carry) == (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_carry));
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_overflow) == 0);
    cpu.d[1] = 0xbeef8000;
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0xbeef7fff), cpu.d[1]);
    try std.testing.expect(cpu.sr & Cpu.flag_overflow != 0);
    try std.testing.expect(cpu.sr & (Cpu.flag_extend | Cpu.flag_negative | Cpu.flag_zero | Cpu.flag_carry) == 0);
}

test "68000 DBF decrements only the low word, branches until minus one and preserves CCR" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x51, 0xc8, // DBF D0,-4: targets its own opcode
        0xff, 0xfc,
        0x4e, 0x71, // NOP after the exhausted loop
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[0] = 0xface0002;
    cpu.sr = 0x271f;
    try std.testing.expectEqual(@as(u16, 10), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface0001), cpu.d[0]);
    try std.testing.expectEqual(@as(u32, 8), cpu.pc);
    try std.testing.expectEqual(@as(u16, 10), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xface0000), cpu.d[0]);
    try std.testing.expectEqual(@as(u32, 8), cpu.pc);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0xfaceffff), cpu.d[0]);
    try std.testing.expectEqual(@as(u32, 12), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0x271f), cpu.sr);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 diagnostic word-copy loop composes MOVE postincrement and DBF" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x34, 0x18, // loop: MOVE.W (A0)+,D2
        0x30, 0xc2, // MOVE.W D2,(A0)+; source and destination use one buffer for this diagnostic
        0x51, 0xc9, // DBF D1,-8: re-enter the first MOVE
        0xff, 0xf8,
        0x4e, 0x71, // NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    try std.testing.expect(bus.writeWord(0x100000, 0x1111));
    try std.testing.expect(bus.writeWord(0x100004, 0x2222));
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.a[0] = 0x100000;
    cpu.d[1] = 1; // execute the loop body twice
    for (0..6) |_| _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(?u16, 0x1111), bus.readWord(0x100002));
    try std.testing.expectEqual(@as(?u16, 0x2222), bus.readWord(0x100006));
    try std.testing.expectEqual(@as(u32, 0x100008), cpu.a[0]);
    try std.testing.expectEqual(@as(u32, 0x0000ffff), cpu.d[1]);
    try std.testing.expectEqual(@as(u32, 16), cpu.pc);
}

test "68000 BNE branches only when Z is clear" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x70, 0x00, // MOVEQ #0,D0 sets Z
        0x66, 0x02, // BNE.s +2, not taken
        0x4e, 0x71, // NOP
        0x70, 0x01, // MOVEQ #1,D0 clears Z
        0x66, 0x02, // BNE.s +2, taken
        0xff, 0xff, // skipped
        0x4e, 0x71, // NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    _ = try cpu.step(&bus);
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 12), cpu.pc);
    _ = try cpu.step(&bus);
    _ = try cpu.step(&bus);
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 20), cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 BCC and BCS branch from the carry flag with short and word displacements" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0xb0, 0x7c, // CMP.W #1,D0 sets C for D0=0
        0x00, 0x01,
        0x65, 0x02, // BCS.s +2, taken
        0xff, 0xff, // skipped
        0xb0, 0x7c, // CMP.W #0,D0 clears C
        0x00, 0x00,
        0x64, 0x00, // BCC.w +2, taken
        0x00, 0x02,
        0xff, 0xff, // skipped
        0x4e, 0x71, // NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[0] = 0;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_carry != 0);
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 16), cpu.pc);
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_carry == 0);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 26), cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 BPL and BMI branch from the negative flag with short and word displacements" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x4a, 0x40, // TST.W D0: D0=$8000 sets N
        0x6b, 0x02, // BMI.s +2, taken
        0xff, 0xff, // skipped
        0x4a, 0x40, // TST.W D0: D0=0 clears N
        0x6a, 0x00, // BPL.w +2, taken
        0x00, 0x02,
        0xff, 0xff, // skipped
        0x4e, 0x71, // NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[0] = 0x8000;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_negative != 0);
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 14), cpu.pc);
    cpu.d[0] = 0;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_negative == 0);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 22), cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 BVC and BVS branch from the overflow flag with short and word displacements" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x52, 0x40, // ADDQ.W #1,D0: D0=$7fff causes V
        0x69, 0x02, // BVS.s +2, taken
        0xff, 0xff, // skipped
        0x4a, 0x40, // TST.W D0 clears V
        0x68, 0x00, // BVC.w +2, taken
        0x00, 0x02,
        0xff, 0xff, // skipped
        0x4e, 0x71, // NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[0] = 0x7fff;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_overflow != 0);
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 14), cpu.pc);
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_overflow == 0);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 22), cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 BGE and BLT use the signed N xor V condition with short and word displacements" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0xb0, 0x7c, // CMP.W #1,D0: D0=$8000 gives N=0,V=1, so signed less-than
        0x00, 0x01,
        0x6d, 0x02, // BLT.s +2, taken
        0xff, 0xff, // skipped
        0xb0, 0x7c, // CMP.W #$8000,D0: equal gives N=V=0
        0x80, 0x00,
        0x6c, 0x00, // BGE.w +2, taken
        0x00, 0x02,
        0xff, 0xff, // skipped
        0x4e, 0x71, // NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[0] = 0x8000;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_negative == 0);
    try std.testing.expect(cpu.sr & Cpu.flag_overflow != 0);
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 16), cpu.pc);
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & (Cpu.flag_negative | Cpu.flag_overflow) == 0);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 26), cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 BGT and BLE use signed comparison including the zero case" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0xb0, 0x7c, // CMP.W #1,D0: D0=2 gives !Z, N=V=0
        0x00, 0x01,
        0x6e, 0x02, // BGT.s +2, taken
        0xff, 0xff, // skipped
        0xb0, 0x7c, // CMP.W #2,D0: equal gives Z
        0x00, 0x02,
        0x6f, 0x00, // BLE.w +2, taken
        0x00, 0x02,
        0xff, 0xff, // skipped
        0x4e, 0x71, // NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[0] = 2;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & (Cpu.flag_zero | Cpu.flag_negative | Cpu.flag_overflow) == 0);
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 16), cpu.pc);
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_zero != 0);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 26), cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 BHI and BLS use unsigned carry and zero conditions" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0xb0, 0x7c, // CMP.W #1,D0: D0=2 gives !C && !Z
        0x00, 0x01,
        0x62, 0x02, // BHI.s +2, taken
        0xff, 0xff, // skipped
        0xb0, 0x7c, // CMP.W #2,D0: equal gives Z
        0x00, 0x02,
        0x63, 0x00, // BLS.w +2, taken
        0x00, 0x02,
        0xff, 0xff, // skipped
        0x4e, 0x71, // NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    cpu.d[0] = 2;
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & (Cpu.flag_carry | Cpu.flag_zero) == 0);
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 16), cpu.pc);
    _ = try cpu.step(&bus);
    try std.testing.expect(cpu.sr & Cpu.flag_zero != 0);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 26), cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}

test "68000 BEQ branches only when Z is set, with short and word displacements" {
    const Bus = @import("bus.zig").Bus;
    const program = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x70, 0x01, // MOVEQ #1,D0 clears Z
        0x67, 0x02, // BEQ.s +2, not taken
        0x70, 0x00, // MOVEQ #0,D0 sets Z
        0x67, 0x00, // BEQ.w, taken
        0x00, 0x02,
        0xff, 0xff, // skipped
        0x4e, 0x71, // NOP
    };
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    var cpu: Cpu = .{};
    try cpu.reset(&bus);
    _ = try cpu.step(&bus);
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 12), cpu.pc);
    _ = try cpu.step(&bus);
    try std.testing.expectEqual(@as(u16, 12), try cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 20), cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), try cpu.step(&bus));
}
