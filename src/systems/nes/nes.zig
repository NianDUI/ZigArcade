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
    tracking_cpu_instruction: bool = false,
    instruction_cycle_progress: u8 = 0,
    nmi_edge_cycle: ?u8 = null,
    nmi_deferred: bool = false,
    irq_edge_cycle: ?u8 = null,
    irq_edge_subdot: u2 = 0,
    irq_deferred: bool = false,
    // A 513-cycle OAM DMA releases the CPU one APU phase earlier than the
    // aligned 514-cycle form, affecting the first resumed IRQ poll only.
    post_dma_apu_irq_early: bool = false,
    dmc_instruction_stall_cycles: u16 = 0,
    dmc_delayed_by_write: bool = false,

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
        self.apu.powerOn();
        self.controllers = .{};
        self.bus = .{};
        self.tracking_cpu_instruction = false;
        self.instruction_cycle_progress = 0;
        self.nmi_edge_cycle = null;
        self.nmi_deferred = false;
        self.irq_edge_cycle = null;
        self.irq_edge_subdot = 0;
        self.irq_deferred = false;
        self.post_dma_apu_irq_early = false;
        self.dmc_instruction_stall_cycles = 0;
        self.dmc_delayed_by_write = false;
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

    /// Applies the console reset button without clearing cartridge RAM.
    pub fn reset(self: *Nes) void {
        self.apu.reset();
        _ = self.ppu.takeNmi();
        _ = self.bus.takeDmaRequest();
        self.tracking_cpu_instruction = false;
        self.instruction_cycle_progress = 0;
        self.nmi_edge_cycle = null;
        self.nmi_deferred = false;
        self.irq_edge_cycle = null;
        self.irq_edge_subdot = 0;
        self.irq_deferred = false;
        self.post_dma_apu_irq_early = false;
        self.dmc_instruction_stall_cycles = 0;
        self.dmc_delayed_by_write = false;
        self.cpu.reset(&self.bus);
    }

    /// Executes one CPU instruction boundary and advances the PPU exactly
    /// three dots per elapsed CPU cycle. NMI is latched by PPU dots and only
    /// requested immediately before the following CPU instruction boundary.
    pub fn step(self: *Nes) !u16 {
        if (self.ppu.takeNmi()) self.cpu.requestNmi();
        const release_deferred_nmi = self.nmi_deferred;
        self.nmi_deferred = false;
        const suppress_late_irq = self.irq_deferred;
        self.irq_deferred = false;
        self.tracking_cpu_instruction = true;
        self.instruction_cycle_progress = 0;
        self.nmi_edge_cycle = null;
        self.irq_edge_cycle = null;
        self.dmc_instruction_stall_cycles = 0;
        self.dmc_delayed_by_write = false;
        self.cpu.setIrqLine(!suppress_late_irq and self.irqLinePending());
        self.bus.beginCpuCycleHook(@ptrCast(self), clockCpuBusCycle, sampleCpuBusCycle);
        const cycles = self.cpu.step(&self.bus) catch |err| {
            _ = self.bus.endCpuCycleHook();
            self.tracking_cpu_instruction = false;
            return err;
        };
        const bus_cycles = self.bus.endCpuCycleHook();
        std.debug.assert(bus_cycles <= cycles);
        // The hook advances one cycle before every bus access after the
        // first. Complete the current bus cycle and any internal cycles that
        // did not touch the bus (for example an accumulator operation).
        self.advanceDevices(cycles - bus_cycles + 1, true);
        self.tracking_cpu_instruction = false;
        if (self.bus.currentCpuAccessKind() == .write and self.apu.dmcReadPending()) self.dmc_delayed_by_write = true;
        const nmi_hijacked = self.cpu.takeNmiHijackConsumed();
        const nmi_after_vector_select = self.cpu.takeNmiAfterVectorSelect();
        if (nmi_after_vector_select) {
            self.nmi_deferred = true;
        } else if (!nmi_hijacked) {
            if (release_deferred_nmi) self.cpu.requestNmi();
            if (self.nmi_edge_cycle) |edge_cycle| {
                if (edge_cycle + 1 < cycles) {
                    self.cpu.requestNmi();
                } else {
                    self.nmi_deferred = true;
                }
            }
        }
        if (self.irq_edge_cycle) |edge_cycle| {
            // The 2A03 samples IRQ near the start of an instruction's
            // penultimate cycle. An edge after the first PPU dot of that CPU
            // cycle misses the poll and must wait through one more opcode.
            const poll_cycle = cycles - (if (self.cpu.irq_poll_one_cycle_early) @as(u8, 2) else 1);
            if (edge_cycle > poll_cycle or (edge_cycle == poll_cycle and self.irq_edge_subdot > 0)) {
                self.irq_deferred = true;
            }
        }
        if (self.bus.takeDmaRequest()) |page| {
            var dma = OamDma.init(page, self.cpu.pc, self.cpu.cycles + self.dmc_instruction_stall_cycles);
            var dma_cycles: u16 = 0;
            var dmc_cycles = self.dmc_instruction_stall_cycles;
            var irq_during_dma = false;
            while (true) {
                dma_cycles += 1;
                const irq_before_dma_cycle = self.irqLinePending();
                const active = dma.tick(&self.bus, &self.ppu);
                self.apu.tick(1);
                const dmc_stall_cycles = dma.dmcStallCycles();
                const serviced_dmc = self.serviceDmcDmaWithStall(dmc_stall_cycles);
                dmc_cycles += serviced_dmc;
                for (0..3) |_| self.ppu.tickDot();
                if (!irq_before_dma_cycle and self.irqLinePending()) irq_during_dma = true;
                if (!active) break;
            }
            // IRQ cannot interrupt the CPU while OAM DMA owns the bus. A line
            // raised during the halt is first eligible after one resumed opcode.
            if (irq_during_dma) self.irq_deferred = true;
            self.post_dma_apu_irq_early = !dma.needs_alignment;
            self.cpu.cycles += dma_cycles + dmc_cycles;
            return @as(u16, cycles) + dma_cycles + dmc_cycles;
        }
        const dmc_cycles = self.dmc_instruction_stall_cycles + self.serviceDmcDma();
        self.cpu.cycles += dmc_cycles;
        return @as(u16, cycles) + dmc_cycles;
    }

    fn advanceDevices(self: *Nes, cpu_cycles: u8, sample_nmi_after_cycle: bool) void {
        for (0..cpu_cycles) |_| {
            const irq_before_apu = self.irqLinePending();
            self.apu.tick(1);
            if (self.tracking_cpu_instruction and !irq_before_apu and self.irqLinePending() and self.irq_edge_cycle == null) {
                self.irq_edge_cycle = self.instruction_cycle_progress + 1;
                self.irq_edge_subdot = if (self.post_dma_apu_irq_early) 0 else 1;
            }
            for (0..3) |subdot| {
                const irq_before = self.irqLinePending();
                self.ppu.tickDot();
                if (self.tracking_cpu_instruction and !irq_before and self.irqLinePending() and self.irq_edge_cycle == null) {
                    self.irq_edge_cycle = self.instruction_cycle_progress + 1;
                    self.irq_edge_subdot = @intCast(subdot);
                }
            }
            if (self.tracking_cpu_instruction) {
                self.instruction_cycle_progress += 1;
                if (sample_nmi_after_cycle) self.sampleNmiLine();
            }
            self.post_dma_apu_irq_early = false;
        }
    }

    fn clockCpuBusCycle(context: *anyopaque) void {
        const self: *Nes = @ptrCast(@alignCast(context));
        const access_kind = self.bus.currentCpuAccessKind();
        if (access_kind == .read and self.apu.dmcReadPending()) self.serviceInstructionDmc();
        self.advanceDevices(1, false);
        if (access_kind == .write) {
            if (self.apu.dmcReadPending()) self.dmc_delayed_by_write = true;
            return;
        }
        self.serviceInstructionDmc();
    }

    fn serviceInstructionDmc(self: *Nes) void {
        const stall_cycles: u16 = if (self.dmc_delayed_by_write) 3 else 4;
        const serviced = self.serviceDmcDmaDuringCpuRead(stall_cycles, self.bus.currentCpuAccessAddress());
        self.dmc_instruction_stall_cycles += serviced;
        if (serviced != 0) self.dmc_delayed_by_write = false;
    }

    fn sampleCpuBusCycle(context: *anyopaque) void {
        const self: *Nes = @ptrCast(@alignCast(context));
        self.sampleNmiLine();
    }

    fn sampleNmiLine(self: *Nes) void {
        if (self.ppu.takeNmi() and self.nmi_edge_cycle == null) {
            self.nmi_edge_cycle = self.instruction_cycle_progress + 1;
            self.cpu.observeNmiEdge();
        }
    }

    fn irqLinePending(self: *Nes) bool {
        return self.apu.frameIrqPending() or self.mapperRef().irqPending();
    }

    /// A DMC sample fetch occupies the CPU bus for four cycles. Service it
    /// outside the CPU instruction boundary and inside OAM DMA alike, keeping
    /// device clocks and the CPU cycle counter in the same timeline.
    fn serviceDmcDma(self: *Nes) u16 {
        const stall_cycles: u16 = if (self.dmc_delayed_by_write) 3 else 4;
        const serviced = self.serviceDmcDmaWithStall(stall_cycles);
        if (serviced != 0) self.dmc_delayed_by_write = false;
        return serviced;
    }

    fn serviceDmcDmaWithStall(self: *Nes, stall_cycles: u16) u16 {
        return self.serviceDmcDmaTransfer(stall_cycles, null);
    }

    fn serviceDmcDmaDuringCpuRead(self: *Nes, stall_cycles: u16, cpu_address: u16) u16 {
        return self.serviceDmcDmaTransfer(stall_cycles, cpu_address);
    }

    fn serviceDmcDmaTransfer(self: *Nes, stall_cycles: u16, phantom_address: ?u16) u16 {
        const address = self.apu.takeDmcReadRequest() orelse return 0;
        const phantom_reads: u16 = if (phantom_address) |cpu_address|
            if (cpu_address == 0x4016 or cpu_address == 0x4017) 1 else stall_cycles - 1
        else
            0;
        for (0..stall_cycles) |cycle| {
            self.apu.tick(1);
            for (0..3) |_| self.ppu.tickDot();
            if (cycle < phantom_reads) _ = self.bus.dmaRead(phantom_address.?);
        }
        self.apu.provideDmcSample(self.bus.dmaRead(address));
        return stall_cycles;
    }

    /// Runs until the next PPU frame boundary. Both background and fetched
    /// sprites are composed by the PPU dot clock; the host only copies the
    /// completed frame after the boundary.
    pub fn runFrame(self: *Nes) !Frame {
        const target_frame = self.ppu.frame_number + 1;
        while (self.ppu.frame_number != target_frame) _ = try self.step();
        try self.ppu.copyClockedBackground(&self.framebuffer, &self.background_opaque);
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

test "Nes DMC halt repeats PPU data reads before the sample get cycle" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.bus.setTraceEnabled(true);
    nes.bus.clearTrace();
    _ = nes.apu.cpuWrite(0x4015, 0x10);

    try std.testing.expectEqual(@as(u16, 4), nes.serviceDmcDmaDuringCpuRead(4, 0x2007));
    try std.testing.expectEqual(@as(u16, 3), nes.ppu.v);
    try std.testing.expectEqual(@as(usize, 4), nes.bus.accesses().len);
    for (nes.bus.accesses()[0..3]) |access| try std.testing.expectEqual(@as(u16, 0x2007), access.address);
    try std.testing.expectEqual(@as(u16, 0xc000), nes.bus.accesses()[3].address);
}

test "Nes DMC halt clocks a controller port only once" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.controllers.ports[0].setHostButtons(.{ .a = true, .select = true });
    nes.bus.write(0x4016, 1);
    nes.bus.write(0x4016, 0);
    nes.bus.setTraceEnabled(true);
    nes.bus.clearTrace();
    _ = nes.apu.cpuWrite(0x4015, 0x10);

    try std.testing.expectEqual(@as(u16, 4), nes.serviceDmcDmaDuringCpuRead(4, 0x4016));
    try std.testing.expectEqual(@as(usize, 2), nes.bus.accesses().len);
    try std.testing.expectEqual(@as(u16, 0x4016), nes.bus.accesses()[0].address);
    try std.testing.expectEqual(@as(u16, 0xc000), nes.bus.accesses()[1].address);
    try std.testing.expectEqual(@as(u8, 0), nes.bus.read(0x4016)); // B
    try std.testing.expectEqual(@as(u8, 1), nes.bus.read(0x4016)); // Select
}

test "Nes defers a PPU NMI edge raised after a two-cycle instruction poll" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16..][0..2].* = .{ 0xea, 0xea };
    image[16 + 0x3ffa] = 0x00;
    image[16 + 0x3ffb] = 0x90;
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.ppu.ctrl = 0x80;
    nes.ppu.scanline = 240;
    nes.ppu.dot = 340;

    _ = try nes.step(); // NOP advances dots and latches VBlank NMI after its poll.
    try std.testing.expectEqual(@as(u16, 0x8001), nes.cpu.pc);
    try std.testing.expectEqual(@as(u16, 2), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x8002), nes.cpu.pc);
    try std.testing.expectEqual(@as(u16, 7), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x9000), nes.cpu.pc);
}

test "Nes PPUSTATUS read after VBlank starts retracts an unsampled NMI edge" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16..][0..4].* = .{ 0xad, 0x02, 0x20, 0xea }; // LDA $2002; NOP
    image[16 + 0x3ffa] = 0x00;
    image[16 + 0x3ffb] = 0x90;
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.ppu.ctrl = 0x80;
    nes.ppu.scanline = 241;
    nes.ppu.dot = 0;

    try std.testing.expectEqual(@as(u16, 4), try nes.step());
    try std.testing.expect(nes.cpu.a & 0x80 != 0);
    try std.testing.expect(nes.ppu.status & 0x80 == 0);
    try std.testing.expectEqual(@as(u16, 2), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x8004), nes.cpu.pc);
}

test "Nes PPUSTATUS read on VBlank's start dot suppresses that frame" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16..][0..4].* = .{ 0xad, 0x02, 0x20, 0xea }; // LDA $2002; NOP
    image[16 + 0x3ffa] = 0x00;
    image[16 + 0x3ffb] = 0x90;
    image[16 + 0x3ffc] = 0x00;
    image[16 + 0x3ffd] = 0x80;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.ppu.ctrl = 0x80;
    // The fourth bus access of LDA absolute is its data read. Starting ten
    // PPU dots before scanline 241 dot 0 puts that read on the suppression
    // boundary, then the instruction tail clocks the suppressed transition.
    nes.ppu.scanline = 240;
    nes.ppu.dot = 332;

    try std.testing.expectEqual(@as(u16, 4), try nes.step());
    try std.testing.expect(nes.cpu.a & 0x80 == 0);
    try std.testing.expect(nes.ppu.status & 0x80 == 0);
    try std.testing.expectEqual(@as(u16, 2), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x8004), nes.cpu.pc);
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
    nes.cpu.cycles = 0; // STA completes on cycle four -> 514 DMA cycles

    try std.testing.expectEqual(@as(u16, 518), try nes.step());
    try std.testing.expectEqual(@as(u64, 518), nes.cpu.cycles);
    try std.testing.expectEqual(@as(u16, 190), nes.ppu.dot);
    try std.testing.expectEqual(@as(u16, 4), nes.ppu.scanline);
    try std.testing.expectEqual(@as(u64, 518), nes.apu.cpu_cycles);
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

test "Nes reset preserves cartridge RAM and reapplies CPU and APU reset state" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16 + 0x3ffc] = 0x34;
    image[16 + 0x3ffd] = 0x12;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.bus.write(0x6000, 0x5a);
    _ = nes.apu.cpuWrite(0x4015, 0x0f);
    _ = nes.apu.cpuWrite(0x4017, 0x80);

    nes.reset();

    try std.testing.expectEqual(@as(?u8, 0x5a), nes.bus.peekCartridge(0x6000));
    try std.testing.expectEqual(@as(u16, 0x1234), nes.cpu.pc);
    try std.testing.expectEqual(@as(u8, 0), nes.apu.channel_enable);
    try std.testing.expect(nes.apu.frame_mode_5_step);
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
    nes.apu.tick(29829);

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

test "Nes accepts an MMC3 IRQ edge before the penultimate-cycle poll" {
    var image: [16 + 2 * 16 * 1024]u8 = [_]u8{0} ** (16 + 2 * 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 2, 0, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16..][0..2].* = .{ 0xea, 0xea };
    image[16 + 0x7ffc] = 0x00;
    image[16 + 0x7ffd] = 0x80;
    image[16 + 0x7ffe] = 0x00;
    image[16 + 0x7fff] = 0x90;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.cpu.status.interrupt_disable = false;
    nes.ppu.mask = 0x18;
    nes.ppu.ctrl = 0x08;
    nes.ppu.scanline = 261;
    nes.ppu.dot = 260;
    nes.bus.write(0xc000, 0);
    nes.bus.write(0xe001, 0);
    var mapper = nes.mapperRef();
    for (0..8) |_| mapper.clockPpuAddress(0);

    try std.testing.expectEqual(@as(u16, 2), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x8001), nes.cpu.pc);
    try std.testing.expectEqual(@as(u16, 7), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x9000), nes.cpu.pc);
}

test "Nes defers an MMC3 IRQ edge after the penultimate-cycle poll" {
    var image: [16 + 2 * 16 * 1024]u8 = [_]u8{0} ** (16 + 2 * 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 2, 0, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16..][0..3].* = .{ 0xea, 0xea, 0xea };
    image[16 + 0x7ffc] = 0x00;
    image[16 + 0x7ffd] = 0x80;
    image[16 + 0x7ffe] = 0x00;
    image[16 + 0x7fff] = 0x90;
    const cartridge = try Cartridge.parse(&image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    nes.cpu.status.interrupt_disable = false;
    nes.ppu.mask = 0x18;
    nes.ppu.ctrl = 0x08;
    nes.ppu.scanline = 261;
    nes.ppu.dot = 259;
    nes.bus.write(0xc000, 0);
    nes.bus.write(0xe001, 0);
    var mapper = nes.mapperRef();
    for (0..8) |_| mapper.clockPpuAddress(0);

    try std.testing.expectEqual(@as(u16, 2), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x8001), nes.cpu.pc);
    try std.testing.expectEqual(@as(u16, 2), try nes.step());
    try std.testing.expectEqual(@as(u16, 0x8002), nes.cpu.pc);
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

test "BSD-2-Clause nes15 fixture reaches a deterministic rendered title frame" {
    const image = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/fixtures/nes15-NTSC.nes",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(image);
    const cartridge = try Cartridge.parse(image);
    var nes: Nes = undefined;
    nes.init(cartridge);
    var frame: Frame = undefined;
    for (0..3) |_| frame = try nes.runFrame();

    try std.testing.expectEqual(@as(u64, 8264638174104152342), std.hash.Wyhash.hash(0, frame.pixels));
}
