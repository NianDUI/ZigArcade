const std = @import("std");
const TestBus = @import("bus.zig").TestBus;
const Ppu = @import("ppu.zig").Ppu;

/// OAM DMA halts the CPU after a write to $4014. It is represented as an
/// explicit CPU-bus-cycle state machine so all 256 source reads retain mapper
/// and I/O side effects. The first dummy cycle is always present; an odd DMA
/// start adds one alignment cycle, yielding 513 or 514 total cycles.
pub const OamDma = struct {
    const Phase = enum { dummy, alignment, read, write, done };

    page: u8,
    dummy_address: u16,
    index: u8 = 0,
    buffer: u8 = 0,
    phase: Phase = .dummy,
    needs_alignment: bool,

    /// `cpu_cycles` is the completed CPU cycle count immediately after the
    /// CPU write to $4014. An even count puts the following halt on the APU
    /// get phase and requires a put-phase alignment cycle.
    pub fn init(page: u8, dummy_address: u16, cpu_cycles: u64) OamDma {
        return .{
            .page = page,
            .dummy_address = dummy_address,
            .needs_alignment = cpu_cycles & 1 == 0,
        };
    }

    /// Performs one CPU bus cycle. Returns false on the cycle that completes
    /// the final OAM write, true while more DMA cycles remain.
    pub fn tick(self: *OamDma, bus: *TestBus, ppu: *Ppu) bool {
        switch (self.phase) {
            .dummy => {
                _ = bus.read(self.dummy_address);
                self.phase = if (self.needs_alignment) .alignment else .read;
            },
            .alignment => {
                _ = bus.read(self.dummy_address);
                self.phase = .read;
            },
            .read => {
                const address = (@as(u16, self.page) << 8) | @as(u16, self.index);
                self.buffer = bus.read(address);
                self.phase = .write;
            },
            .write => {
                ppu.dmaWrite(self.buffer);
                if (self.index == 0xff) {
                    self.phase = .done;
                    return false;
                }
                self.index +%= 1;
                self.phase = .read;
            },
            .done => return false,
        }
        return true;
    }

    /// DMC DMA shares the 2A03 bus-arbitration unit with OAM DMA. These spans
    /// are the measured additional CPU stalls for the request's landing
    /// phase, including the one/three-cycle tail exceptions.
    pub fn dmcStallCycles(self: *const OamDma) u16 {
        if (self.phase == .write and self.index == 0xfe) return 1;
        if (self.phase == .write and self.index == 0xff) return 3;
        if (self.phase == .done and self.index == 0xff) return 3;
        return 2;
    }
};

test "OAM DMA performs 514 cycles from an even completed write and reads mapper source" {
    const Mapper0 = @import("mapper0.zig").Mapper0;
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    for (&prg, 0..) |*byte, index| byte.* = @truncate(index);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.oam_addr = 0x80;
    var bus: TestBus = .{};
    bus.attachMapper0(&mapper);
    bus.attachPpu(&ppu);
    var dma = OamDma.init(0x80, 0x9000, 4);

    var cycles: usize = 0;
    while (dma.tick(&bus, &ppu)) cycles += 1;
    cycles += 1;
    try std.testing.expectEqual(@as(usize, 514), cycles);
    try std.testing.expectEqual(@as(u8, 0), ppu.oam[0x80]);
    try std.testing.expectEqual(@as(u8, 0x7f), ppu.oam[0xff]);
    try std.testing.expectEqual(@as(u8, 0x80), ppu.oam[0]);
    try std.testing.expectEqual(@as(usize, 258), bus.accesses().len);
    try std.testing.expectEqual(@as(u16, 0x9000), bus.accesses()[0].address);
    try std.testing.expectEqual(@as(u16, 0x9000), bus.accesses()[1].address);
    try std.testing.expectEqual(@as(u16, 0x8000), bus.accesses()[2].address);
}

test "OAM DMA performs 513 cycles from an odd completed write" {
    const Mapper0 = @import("mapper0.zig").Mapper0;
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
    var dma = OamDma.init(0x00, 0x8000, 5);

    var cycles: usize = 0;
    while (dma.tick(&bus, &ppu)) cycles += 1;
    cycles += 1;
    try std.testing.expectEqual(@as(usize, 513), cycles);
    try std.testing.expectEqual(@as(usize, 257), bus.accesses().len);
    try std.testing.expectEqual(@as(u16, 0x8000), bus.accesses()[0].address);
    try std.testing.expectEqual(@as(u16, 0x0000), bus.accesses()[1].address);
}

test "OAM DMA exposes phase-specific DMC stall lengths" {
    var dma = OamDma.init(0x00, 0x8000, 4);
    try std.testing.expectEqual(@as(u16, 2), dma.dmcStallCycles());

    dma.phase = .write;
    dma.index = 0xfd;
    try std.testing.expectEqual(@as(u16, 2), dma.dmcStallCycles());
    dma.index = 0xfe;
    try std.testing.expectEqual(@as(u16, 1), dma.dmcStallCycles());
    dma.index = 0xff;
    try std.testing.expectEqual(@as(u16, 3), dma.dmcStallCycles());
}
