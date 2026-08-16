const std = @import("std");
const AudioSink = @import("../../core/audio.zig").AudioSink;
const NullAudioSink = @import("../../core/audio.zig").NullAudioSink;
const Frame = @import("../../core/frame.zig").Frame;
const Apu = @import("apu.zig").Apu;
const TestBus = @import("bus.zig").TestBus;
const Cartridge = @import("cartridge.zig").Cartridge;
const Controllers = @import("controller.zig").Controllers;
const Cpu = @import("cpu.zig").Cpu;
const OamDma = @import("dma.zig").OamDma;
const Mapper = @import("mapper.zig").Mapper;
const Mapper0 = @import("mapper0.zig").Mapper0;
const Mapper1 = @import("mapper1.zig").Mapper1;
const Mapper2 = @import("mapper2.zig").Mapper2;
const Mapper3 = @import("mapper3.zig").Mapper3;
const Mapper4 = @import("mapper4.zig").Mapper4;
const Mapper7 = @import("mapper7.zig").Mapper7;
const Ppu = @import("ppu.zig").Ppu;
const ppu_frame_rgb_bytes = @import("ppu.zig").frame_rgb_bytes;
const ppu_frame_height = @import("ppu.zig").frame_height;
const ppu_frame_width = @import("ppu.zig").frame_width;

/// The first integrated NES slice. It owns mutable mapper, PPU, and CPU-bus
/// state while borrowing immutable cartridge ROM slices from the loader.
pub const Nes = struct {
    cpu: Cpu = .{},
    mapper: union(enum) { nrom: Mapper0, mmc1: Mapper1, unrom: Mapper2, cnrom: Mapper3, mmc3: Mapper4, aorom: Mapper7 } = undefined,
    ppu: Ppu = undefined,
    apu: Apu = undefined,
    null_audio_sink: NullAudioSink = .{},
    controllers: Controllers = .{},
    bus: TestBus = .{},
    framebuffer: [ppu_frame_rgb_bytes]u8 = undefined,
    background_opaque: [ppu_frame_width * ppu_frame_height]u8 = undefined,

    pub fn init(self: *Nes, cartridge: Cartridge) void {
        self.null_audio_sink = .{};
        self.initWithAudioSink(cartridge, self.null_audio_sink.asSink());
    }

    /// Host audio is injected at the machine boundary; the default initializer
    /// deliberately retains its silent deterministic sink for tests and tools.
    pub fn initWithAudioSink(self: *Nes, cartridge: Cartridge, sink: AudioSink) void {
        self.mapper = switch (cartridge.mapper) {
            .nrom => .{ .nrom = Mapper0.init(cartridge) },
            .mmc1 => .{ .mmc1 = Mapper1.init(cartridge) },
            .unrom => .{ .unrom = Mapper2.init(cartridge) },
            .cnrom => .{ .cnrom = Mapper3.init(cartridge) },
            .mmc3 => .{ .mmc3 = Mapper4.init(cartridge) },
            .aorom => .{ .aorom = Mapper7.init(cartridge) },
        };
        const mapper = self.mapperRef();
        self.ppu = Ppu.init(mapper);
        self.apu = Apu.init(sink);
        self.controllers = .{};
        self.bus = .{};
        self.bus.setTraceEnabled(false);
        self.bus.attachMapper(mapper);
        self.bus.attachPpu(&self.ppu);
        self.bus.attachApu(&self.apu);
        self.bus.attachControllers(&self.controllers);
        self.cpu.reset(&self.bus);
    }

    fn mapperRef(self: *Nes) Mapper {
        return switch (self.mapper) {
            .nrom => |*mapper| Mapper.fromMapper0(mapper),
            .mmc1 => |*mapper| Mapper.fromMapper1(mapper),
            .unrom => |*mapper| Mapper.fromMapper2(mapper),
            .cnrom => |*mapper| Mapper.fromMapper3(mapper),
            .mmc3 => |*mapper| Mapper.fromMapper4(mapper),
            .aorom => |*mapper| Mapper.fromMapper7(mapper),
        };
    }

    /// Executes one CPU instruction boundary and advances the PPU exactly
    /// three dots per elapsed CPU cycle. NMI is latched by PPU dots and only
    /// requested immediately before the following CPU instruction boundary.
    pub fn step(self: *Nes) !u16 {
        if (self.ppu.takeNmi()) self.cpu.requestNmi();
        self.cpu.setIrqLine(self.apu.frameIrqPending() or self.mapperRef().irqPending());
        const cycles = try self.cpu.step(&self.bus);
        self.advanceDevices(cycles);
        var dmc_cycles = self.serviceDmcDma();
        if (self.bus.takeDmaRequest()) |page| {
            var dma = OamDma.init(page, self.cpu.pc, self.cpu.cycles);
            var dma_cycles: u16 = 0;
            while (true) {
                dma_cycles += 1;
                const active = dma.tick(&self.bus, &self.ppu);
                self.apu.tick(1);
                dmc_cycles += self.serviceDmcDma();
                for (0..3) |_| self.ppu.tickDot();
                if (!active) break;
            }
            self.cpu.cycles += dma_cycles + dmc_cycles;
            return @as(u16, cycles) + dma_cycles + dmc_cycles;
        }
        self.cpu.cycles += dmc_cycles;
        return @as(u16, cycles) + dmc_cycles;
    }

    fn advanceDevices(self: *Nes, cpu_cycles: u8) void {
        self.apu.tick(cpu_cycles);
        for (0..@as(usize, cpu_cycles) * 3) |_| self.ppu.tickDot();
    }

    /// A DMC sample fetch occupies the CPU bus for four cycles. Service it
    /// outside the CPU instruction boundary and inside OAM DMA alike, keeping
    /// device clocks and the CPU cycle counter in the same timeline.
    fn serviceDmcDma(self: *Nes) u16 {
        const address = self.apu.takeDmcReadRequest() orelse return 0;
        self.apu.provideDmcSample(self.bus.read(address));
        self.apu.tick(4);
        for (0..12) |_| self.ppu.tickDot();
        return 4;
    }

    /// Runs until the next PPU frame boundary. Background pixels are emitted
    /// by the PPU dot clock itself; only the still-staged sprite overlay runs
    /// after the completed frame is copied out.
    pub fn runFrame(self: *Nes) !Frame {
        const target_frame = self.ppu.frame_number + 1;
        while (self.ppu.frame_number != target_frame) _ = try self.step();
        try self.ppu.copyClockedBackground(&self.framebuffer, &self.background_opaque);
        try self.ppu.renderSpritesWithBackground(&self.framebuffer, &self.background_opaque);
        return .{
            .pixels = &self.framebuffer,
            .width = ppu_frame_width,
            .height = ppu_frame_height,
            .stride = ppu_frame_width * 3,
            .format = .rgb888,
            .frame_number = self.ppu.frame_number,
        };
    }
};

test "Nes steps CPU from NROM and advances PPU three dots per CPU cycle" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16] = 0xea; // NOP
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);

    try std.testing.expectEqual(@as(u16, 0x8000), nes.cpu.pc);
    try std.testing.expectEqual(@as(u16, 2), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x8001), nes.cpu.pc);
    try std.testing.expectEqual(@as(u16, 6), nes.ppu.dot);
    try std.testing.expectEqual(@as(u16, 0), nes.ppu.scanline);
}

test "Nes DMC fetch stalls the CPU four cycles and advances device clocks" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16] = 0xea; // NOP
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    _ = nes.apu.cpuWrite(0x4010, 0x0f);
    _ = nes.apu.cpuWrite(0x4015, 0x10);

    try std.testing.expectEqual(@as(u16, 6), try nes.step());
    try std.testing.expectEqual(@as(u64, 13), nes.cpu.cycles); // reset's seven cycles plus NOP and DMC fetch
    try std.testing.expectEqual(@as(u64, 6), nes.apu.cpu_cycles);
    try std.testing.expectEqual(@as(u16, 18), nes.ppu.dot);
    try std.testing.expect(nes.apu.dmc_sample_buffer != null);
}

test "Nes delivers PPU NMI at the next CPU instruction boundary" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16] = 0xea;
    image[16 + 0x3ffa] = 0x00;
    image[16 + 0x3ffb] = 0x90;
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.ppu.ctrl = 0x80;
    nes.ppu.scanline = 241;
    nes.ppu.dot = 1;

    _ = try nes.step(); // NOP advances dots and latches VBlank NMI.
    try std.testing.expectEqual(@as(u16, 0x8001), nes.cpu.pc);
    try std.testing.expectEqual(@as(u16, 7), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x9000), nes.cpu.pc);
}

test "Nes stalls CPU for OAM DMA and advances PPU through every DMA cycle" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16..][0..3].* = .{ 0x8d, 0x14, 0x40 }; // STA $4014
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.cpu.a = 0x00;
    nes.cpu.cycles = 0; // even completed write cycle -> 513 DMA cycles

    try std.testing.expectEqual(@as(u16, 517), try nes.step());
    try std.testing.expectEqual(@as(u64, 517), nes.cpu.cycles);
    try std.testing.expectEqual(@as(u16, 187), nes.ppu.dot);
    try std.testing.expectEqual(@as(u16, 4), nes.ppu.scanline);
    try std.testing.expectEqual(@as(u64, 517), nes.apu.cpu_cycles);
}

test "Nes runFrame advances to a PPU frame boundary and exposes RGB frame" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    // A tight two-cycle loop: NOP; JMP $8000.
    image[16..][0..4].* = .{ 0xea, 0x4c, 0x00, 0x80 };
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);

    const frame = try nes.runFrame();
    try std.testing.expectEqual(@as(u64, 1), frame.frame_number);
    try std.testing.expectEqual(@as(u16, ppu_frame_width), frame.width);
    try std.testing.expectEqual(@as(u16, ppu_frame_height), frame.height);
    try std.testing.expectEqual(@as(usize, ppu_frame_rgb_bytes), frame.pixels.len);
}

test "Nes delivers APU frame IRQ at the next CPU instruction boundary" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16] = 0xea;
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    image[16 + 0x3ffe] = 0x00;
    image[16 + 0x3fff] = 0x90;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.cpu.status.interrupt_disable = false;
    nes.apu.tick(14915);

    try std.testing.expectEqual(@as(u16, 7), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x9000), nes.cpu.pc);
}

test "Nes delivers a pending MMC3 IRQ at the next CPU instruction boundary" {
    var image: [16 + 2 * 16 * 1024]u8 = [_]u8{0} ** (16 + 2 * 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 2, 0, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16] = 0xea;
    image[16 + 0x1000] = 0xea;
    image[16 + 0x7ffc] = 0x00;
    image[16 + 0x7ffd] = 0x80;
    image[16 + 0x7ffe] = 0x00;
    image[16 + 0x7fff] = 0x90;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.cpu.status.interrupt_disable = false;
    nes.bus.write(0xc000, 0);
    nes.bus.write(0xe001, 0);
    var mapper = nes.mapperRef();
    for (0..8) |_| mapper.clockPpuAddress(0);
    mapper.clockPpuAddress(0x1000);

    try std.testing.expectEqual(@as(u16, 7), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x9000), nes.cpu.pc);
}

test "MMC3 IRQ acknowledgement clears a masked CPU IRQ line" {
    var image: [16 + 2 * 16 * 1024]u8 = [_]u8{0} ** (16 + 2 * 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 2, 0, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16..][0..2].* = .{ 0xea, 0xea };
    image[16 + 0x7ffc] = 0x00;
    image[16 + 0x7ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.bus.write(0xc000, 0);
    nes.bus.write(0xe001, 0);
    var mapper = nes.mapperRef();
    for (0..8) |_| mapper.clockPpuAddress(0);
    mapper.clockPpuAddress(0x1000);

    try std.testing.expectEqual(@as(u16, 2), try nes.step()); // I flag masks the asserted line.
    nes.bus.write(0xe000, 0);
    nes.cpu.status.interrupt_disable = false;
    try std.testing.expectEqual(@as(u16, 2), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x8002), nes.cpu.pc);
}

test "UNROM boots from fixed bank and switches the lower PRG window" {
    var image: [16 + 3 * 16 * 1024]u8 = [_]u8{0} ** (16 + 3 * 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 3, 0, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16] = 0xa9; // bank 0: LDA #$11
    image[17] = 0x11;
    image[16 + 16 * 1024] = 0xa9; // bank 1: LDA #$22
    image[16 + 16 * 1024 + 1] = 0x22;
    const fixed_bank = 16 + 2 * 16 * 1024;
    image[fixed_bank] = 0x4c; // JMP $8000 from fixed bank
    image[fixed_bank + 1] = 0x00;
    image[fixed_bank + 2] = 0x80;
    image[fixed_bank + 0x3ffc] = 0x00;
    image[fixed_bank + 0x3ffd] = 0xc0;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);

    try std.testing.expectEqual(@as(u16, 0xc000), nes.cpu.pc);
    _ = try nes.step(); // JMP $8000
    try std.testing.expectEqual(@as(u16, 0x8000), nes.cpu.pc);
    _ = try nes.step(); // bank 0 LDA
    try std.testing.expectEqual(@as(u8, 0x11), nes.cpu.a);
    nes.bus.write(0x8000, 1);
    nes.cpu.pc = 0x8000;
    _ = try nes.step(); // bank 1 LDA
    try std.testing.expectEqual(@as(u8, 0x22), nes.cpu.a);
}

test "CNROM CPU bank write selects a different PPU CHR-ROM bank" {
    var image: [16 + 16 * 1024 + 2 * 8 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024 + 2 * 8 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 2, 0x30, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    @memset(image[16 + 16 * 1024 ..][0 .. 8 * 1024], 0x31);
    @memset(image[16 + 16 * 1024 + 8 * 1024 ..], 0x42);
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);

    var mapper = nes.mapperRef();
    try std.testing.expectEqual(@as(?u8, 0x31), mapper.ppuRead(0));
    nes.bus.write(0x8000, 1);
    mapper = nes.mapperRef();
    try std.testing.expectEqual(@as(?u8, 0x42), mapper.ppuRead(0));
}

test "MMC1 serial CPU writes switch the active PRG bank through the NES bus" {
    var image: [16 + 3 * 16 * 1024]u8 = [_]u8{0} ** (16 + 3 * 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 3, 0, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16] = 0x11;
    image[16 + 16 * 1024] = 0x22;
    image[16 + 2 * 16 * 1024] = 0x33;
    image[16 + 2 * 16 * 1024 + 0x3ffc] = 0x00;
    image[16 + 2 * 16 * 1024 + 0x3ffd] = 0xc0;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);

    try std.testing.expectEqual(@as(u8, 0x11), nes.bus.read(0x8000));
    for (0..5) |bit| nes.bus.write(0xe000, @truncate(@as(u5, 1) >> @intCast(bit)));
    try std.testing.expectEqual(@as(u8, 0x22), nes.bus.read(0x8000));
    try std.testing.expectEqual(@as(u8, 0x33), nes.bus.read(0xc000));
}

test "AOROM boots from bank zero, switches PRG, and the PPU follows one-screen mirroring" {
    var image: [16 + 2 * 32 * 1024]u8 = [_]u8{0} ** (16 + 2 * 32 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 4, 0, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16] = 0x11;
    image[16 + 32 * 1024] = 0x22;
    image[16 + 0x7ffc] = 0x00;
    image[16 + 0x7ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);

    try std.testing.expectEqual(@as(u16, 0x8000), nes.cpu.pc);
    try std.testing.expectEqual(@as(u8, 0x11), nes.bus.read(0x8000));
    nes.bus.write(0x8000, 0x11);
    try std.testing.expectEqual(@as(u8, 0x22), nes.bus.read(0x8000));
    nes.bus.write(0x2006, 0x24);
    nes.bus.write(0x2006, 0x00);
    nes.bus.write(0x2007, 0x7b);
    nes.bus.write(0x2006, 0x28);
    nes.bus.write(0x2006, 0x00);
    _ = nes.bus.read(0x2007); // buffered nametable read
    try std.testing.expectEqual(@as(u8, 0x7b), nes.bus.read(0x2007));
}

test "NROM CPU program configures PPU palette and produces an RGB frame" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    // Select $3F00 through PPUADDR and write palette entry 0 before enabling
    // rendering. Once rendering is active, the PPU itself advances v during
    // tile fetches, so visible-region palette updates must synchronize first.
    // CHR-RAM and nametable default to tile/color 0, so every framebuffer
    // pixel becomes the selected backdrop color.
    image[16..][0..23].* = .{
        0xa9, 0x3f, // LDA #$3F
        0x8d, 0x06, 0x20, // STA $2006
        0xa9, 0x00, // LDA #$00
        0x8d, 0x06, 0x20, // STA $2006
        0xa9, 0x21, // LDA #$21
        0x8d, 0x07, 0x20, // STA $2007
        0xa9, 0x0a, // LDA #$0A
        0x8d, 0x01, 0x20, // STA $2001
        0x4c, 0x14, 0x80, // JMP $8014
    };
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);

    _ = try nes.runFrame(); // setup occurs during the first visible frame
    const frame = try nes.runFrame();
    try std.testing.expectEqual(@as(u8, 0x0a), nes.ppu.mask);
    try std.testing.expectEqual(@as(u8, 0x21), nes.ppu.palette[0]);
    try std.testing.expectEqualSlices(u8, &.{ 76, 154, 236 }, frame.pixels[0..3]);
    const last_pixel = (ppu_frame_width * ppu_frame_height - 1) * 3;
    try std.testing.expectEqualSlices(u8, &.{ 76, 154, 236 }, frame.pixels[last_pixel..][0..3]);
    try std.testing.expectEqual(@as(u64, 1082226717624806288), std.hash.Wyhash.hash(0, frame.pixels));
}
