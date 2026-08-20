const std = @import("std");
const Apu = @import("apu.zig").Apu;
const Controllers = @import("controller.zig").Controllers;
const Mapper = @import("mapper.zig").Mapper;
const Mapper0 = @import("mapper0.zig").Mapper0;
const Ppu = @import("ppu.zig").Ppu;

pub const AccessKind = enum { read, write };

pub const Access = struct {
    kind: AccessKind,
    address: u16,
    value: u8,
};

pub const CpuCycleHook = *const fn (context: *anyopaque) void;

/// Deterministic CPU bus used by instruction tests. Without a mapper it is a
/// flat 64 KiB test fixture. Attaching Mapper 0 enables the first real NES
/// address routes: internal 2 KiB RAM mirrors, PPU register mirrors, and
/// cartridge PRG at $8000. APU/controller routes stay inert in this P2a slice.
pub const TestBus = struct {
    memory: [0x10000]u8 = [_]u8{0} ** 0x10000,
    trace: [1024]Access = undefined,
    trace_len: usize = 0,
    trace_enabled: bool = true,
    mapper: ?Mapper = null,
    ppu: ?*Ppu = null,
    apu: ?*Apu = null,
    controllers: ?*Controllers = null,
    dma_request: ?u8 = null,
    /// The integrated NES clocks devices between CPU bus cycles. Unit tests
    /// leave this disabled and retain the simple deterministic fixture bus.
    cpu_cycle_hook: ?CpuCycleHook = null,
    cpu_cycle_after_access_hook: ?CpuCycleHook = null,
    cpu_cycle_context: ?*anyopaque = null,
    cpu_cycle_accesses: u8 = 0,

    pub fn attachMapper0(self: *TestBus, mapper: *Mapper0) void {
        self.mapper = Mapper.fromMapper0(mapper);
    }

    pub fn attachMapper(self: *TestBus, mapper: Mapper) void {
        self.mapper = mapper;
    }

    pub fn attachPpu(self: *TestBus, ppu: *Ppu) void {
        self.ppu = ppu;
    }

    pub fn attachApu(self: *TestBus, apu: *Apu) void {
        self.apu = apu;
    }

    pub fn attachControllers(self: *TestBus, controllers: *Controllers) void {
        self.controllers = controllers;
    }

    pub fn takeDmaRequest(self: *TestBus) ?u8 {
        const request = self.dma_request;
        self.dma_request = null;
        return request;
    }

    /// Arms a hook for one CPU instruction. The first bus operation belongs
    /// to the current CPU cycle; every later one starts after one completed
    /// cycle, so the hook is called before it. `endCpuCycleHook` returns the
    /// number of observable bus cycles for the caller to clock the tail.
    pub fn beginCpuCycleHook(self: *TestBus, context: *anyopaque, hook: CpuCycleHook, after_access_hook: CpuCycleHook) void {
        self.cpu_cycle_context = context;
        self.cpu_cycle_hook = hook;
        self.cpu_cycle_after_access_hook = after_access_hook;
        self.cpu_cycle_accesses = 0;
    }

    pub fn endCpuCycleHook(self: *TestBus) u8 {
        const access_count = self.cpu_cycle_accesses;
        self.cpu_cycle_context = null;
        self.cpu_cycle_hook = null;
        self.cpu_cycle_after_access_hook = null;
        self.cpu_cycle_accesses = 0;
        return access_count;
    }

    /// Per-access tracing is for bounded instruction tests. Full frame runs
    /// turn it off rather than silently discarding a partial trace.
    pub fn setTraceEnabled(self: *TestBus, enabled: bool) void {
        self.trace_enabled = enabled;
        self.trace_len = 0;
    }

    pub fn read(self: *TestBus, address: u16) u8 {
        self.clockBeforeCpuBusAccess();
        const value = if (self.mapper) |*mapper|
            self.readMapped(mapper, address)
        else
            self.memory[address];
        self.record(.{ .kind = .read, .address = address, .value = value });
        self.clockAfterCpuBusAccess();
        return value;
    }

    /// Side-effect-free cartridge observation for diagnostics at safe frame
    /// boundaries. CPU execution must continue to use `read` so device timing
    /// and register side effects remain visible.
    pub fn peekCartridge(self: *const TestBus, address: u16) ?u8 {
        const mapper = self.mapper orelse return null;
        return mapper.cpuRead(address);
    }

    pub fn write(self: *TestBus, address: u16, value: u8) void {
        self.clockBeforeCpuBusAccess();
        if (self.mapper) |*mapper| {
            if (address < 0x2000) {
                self.memory[address & 0x07ff] = value;
            } else if (address < 0x4000) {
                if (self.ppu) |ppu| ppu.cpuWrite(@truncate(address & 7), value);
            } else if (address == 0x4014) {
                self.dma_request = value;
            } else if (address == 0x4016) {
                if (self.controllers) |controllers| controllers.writeStrobe(value);
            } else {
                const handled_by_apu = if (self.apu) |apu| apu.cpuWrite(address, value) else false;
                if (!handled_by_apu) {
                    _ = mapper.cpuWrite(address, value);
                }
            }
        } else {
            self.memory[address] = value;
        }
        self.record(.{ .kind = .write, .address = address, .value = value });
        self.clockAfterCpuBusAccess();
    }

    pub fn clearTrace(self: *TestBus) void {
        self.trace_len = 0;
    }

    pub fn accesses(self: *const TestBus) []const Access {
        return self.trace[0..self.trace_len];
    }

    fn record(self: *TestBus, access: Access) void {
        if (!self.trace_enabled) return;
        std.debug.assert(self.trace_len < self.trace.len);
        self.trace[self.trace_len] = access;
        self.trace_len += 1;
    }

    fn clockBeforeCpuBusAccess(self: *TestBus) void {
        if (self.cpu_cycle_hook) |hook| {
            if (self.cpu_cycle_accesses != 0) hook(self.cpu_cycle_context orelse unreachable);
            self.cpu_cycle_accesses += 1;
        }
    }

    fn clockAfterCpuBusAccess(self: *TestBus) void {
        if (self.cpu_cycle_after_access_hook) |hook| hook(self.cpu_cycle_context orelse unreachable);
    }

    fn readMapped(self: *const TestBus, mapper: *const Mapper, address: u16) u8 {
        if (address < 0x2000) return self.memory[address & 0x07ff];
        if (address < 0x4000) {
            // Reads have register side effects, so obtaining this optional
            // device through a const bus is intentional: the pointer itself
            // is mutable even while CPU routing state is not.
            return if (self.ppu) |ppu| ppu.cpuRead(@truncate(address & 7)) else 0;
        }
        if (address == 0x4016) return if (self.controllers) |controllers| controllers.read(0) else 0;
        if (address == 0x4017) return if (self.controllers) |controllers| controllers.read(1) else 0;
        if (self.apu) |apu| if (apu.cpuRead(address)) |value| return value;
        return mapper.cpuRead(address) orelse 0;
    }
};

test "test bus captures side-effecting read and write order" {
    var bus: TestBus = .{};
    bus.memory[0x1234] = 0xab;
    try std.testing.expectEqual(@as(u8, 0xab), bus.read(0x1234));
    bus.write(0x0080, 0xcd);
    try std.testing.expectEqualSlices(Access, &.{
        .{ .kind = .read, .address = 0x1234, .value = 0xab },
        .{ .kind = .write, .address = 0x0080, .value = 0xcd },
    }, bus.accesses());
}

test "mapped bus mirrors internal RAM and fetches NROM reset vector" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    prg[0x3ffc] = 0x00;
    prg[0x3ffd] = 0x80;
    prg[0] = 0xea;
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var bus: TestBus = .{};
    bus.attachMapper0(&mapper);

    bus.write(0x0000, 0x5a);
    bus.write(0x6000, 0x7c);
    try std.testing.expectEqual(@as(u8, 0x5a), bus.read(0x0800));
    try std.testing.expectEqual(@as(?u8, 0x7c), bus.peekCartridge(0x6000));
    try std.testing.expectEqual(@as(?u8, null), bus.peekCartridge(0x5000));
    try std.testing.expectEqual(@as(u8, 0xea), bus.read(0x8000));
    try std.testing.expectEqual(@as(u8, 0x00), bus.read(0xfffc));
    try std.testing.expectEqual(@as(u8, 0x80), bus.read(0xfffd));
}

test "mapped bus mirrors CPU PPU register range" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    var bus: TestBus = .{};
    bus.attachMapper0(&mapper);
    bus.attachPpu(&ppu);

    bus.write(0x2008, 0x80); // $2000 mirror: PPUCTRL
    try std.testing.expectEqual(@as(u8, 0x80), ppu.ctrl);
    ppu.status = 0x80;
    try std.testing.expectEqual(@as(u8, 0x80), bus.read(0x3ffa)); // $2002 mirror
    try std.testing.expectEqual(@as(u8, 0), ppu.status & 0x80);
}

test "mapped bus routes controller reads and strobe writes" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var controllers: Controllers = .{};
    controllers.ports[0].setHostButtons(.{ .a = true, .start = true });
    var bus: TestBus = .{};
    bus.attachMapper0(&mapper);
    bus.attachControllers(&controllers);
    bus.write(0x4016, 1);
    bus.write(0x4016, 0);
    try std.testing.expectEqual(@as(u8, 1), bus.read(0x4016));
    try std.testing.expectEqual(@as(u8, 0), bus.read(0x4016));
    try std.testing.expectEqual(@as(u8, 0), bus.read(0x4016));
    try std.testing.expectEqual(@as(u8, 1), bus.read(0x4016));
}

test "mapped bus routes the volatile Mapper 0 PRG RAM window" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var bus: TestBus = .{};
    bus.attachMapper0(&mapper);
    bus.write(0x6123, 0xbe);
    try std.testing.expectEqual(@as(u8, 0xbe), bus.read(0x6123));
}

test "mapped bus separates APU $4017 writes from controller port two reads" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var null_sink = @import("../../core/audio.zig").NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    var controllers: Controllers = .{};
    controllers.ports[1].setHostButtons(.{ .a = true });
    var bus: TestBus = .{};
    bus.attachMapper0(&mapper);
    bus.attachApu(&apu);
    bus.attachControllers(&controllers);
    bus.write(0x4017, 0xc0);
    try std.testing.expect(!apu.frame_mode_5_step);
    try std.testing.expect(apu.frame_irq_inhibit);
    apu.tick(4);
    try std.testing.expect(apu.frame_mode_5_step);
    bus.write(0x4016, 1);
    try std.testing.expectEqual(@as(u8, 1), bus.read(0x4017));
}

test "APU attachment does not intercept cartridge mapper writes" {
    const Mapper2 = @import("mapper2.zig").Mapper2;
    var prg: [2 * 16 * 1024]u8 = undefined;
    @memset(prg[0 .. 16 * 1024], 0x11);
    @memset(prg[16 * 1024 ..], 0x22);
    var mapper = Mapper2{ .prg_rom = &prg, .mirroring = .horizontal };
    var null_sink = @import("../../core/audio.zig").NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    var bus: TestBus = .{};
    bus.attachMapper(@import("mapper.zig").Mapper.fromMapper2(&mapper));
    bus.attachApu(&apu);

    try std.testing.expectEqual(@as(u8, 0x11), bus.read(0x8000));
    bus.write(0x8000, 1);
    try std.testing.expectEqual(@as(u8, 0x22), bus.read(0x8000));
}
