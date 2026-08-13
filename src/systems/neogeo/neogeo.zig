const std = @import("std");
const Frame = @import("../../core/frame.zig").Frame;
const Actions = @import("../../core/input.zig").Actions;
const Bus = @import("bus.zig").Bus;
const fixed = @import("fixed.zig");
const FixedMap = @import("fixed_map.zig").FixedMap;
const PaletteRam = @import("palette_ram.zig").PaletteRam;
const Timing = @import("timing.zig").Timing;
const Buttons = @import("input.zig").Buttons;
const buttonsFromActions = @import("input.zig").buttonsFromActions;
const SoundLatch = @import("sound_latch.zig").SoundLatch;
const M68k = @import("m68k.zig").Cpu;
const video = @import("video.zig");

/// Asset-free Neo Geo diagnostic assembly. It deliberately accepts synthetic
/// P-ROM/BIOS slices and a caller-provided fixed tile store; no ROM-set file
/// loading or CPU execution lives here. This lets P5a/P5b contracts mature
/// around one object before legal local loading is introduced.
pub const NeoGeoDiagnostic = struct {
    bus: Bus,
    cpu: M68k = .{},
    fixed_map: FixedMap = .{},
    palette_ram: PaletteRam = .{},
    timing: Timing = .{},
    buttons: Buttons = .{},
    sound_latch: SoundLatch = .{},
    framebuffer: [video.frame_rgb_bytes]u8 = undefined,

    pub fn init(program_rom: []const u8, bios_rom: []const u8) NeoGeoDiagnostic {
        return .{ .bus = .{ .program_rom = program_rom, .bios_rom = bios_rom } };
    }

    /// Reset vectors are read through the current BIOS overlay. A future
    /// hardware register will control when the program ROM becomes visible.
    pub fn resetCpu(self: *NeoGeoDiagnostic) @import("m68k.zig").Error!void {
        try self.cpu.reset(&self.bus);
    }

    pub fn stepCpu(self: *NeoGeoDiagnostic) @import("m68k.zig").Error!u16 {
        return self.cpu.step(&self.bus);
    }

    /// Runs an exact, caller-bounded number of diagnostic instructions and
    /// returns their cycle anchors. This is intentionally not a game-loop or
    /// a claim that the current core implements STOP, interrupts or full 68000
    /// timing; the explicit bound keeps synthetic diagnostics deterministic.
    pub fn stepCpuInstructions(self: *NeoGeoDiagnostic, instruction_count: usize) @import("m68k.zig").Error!u64 {
        var cycles: u64 = 0;
        for (0..instruction_count) |_| cycles += try self.stepCpu();
        return cycles;
    }

    /// Executes until the accumulated diagnostic cycle anchors reach
    /// `minimum_cycles`, or `max_instructions` makes further execution
    /// impossible. A final instruction may exceed the requested budget;
    /// callers receive that fact explicitly instead of silently skipping an
    /// instruction. This is a deterministic CPU-only helper, not a Neo Geo
    /// master-clock or scanline scheduler.
    pub fn stepCpuCycleBudget(self: *NeoGeoDiagnostic, minimum_cycles: u64, max_instructions: usize) CycleBudgetError!CycleBudgetResult {
        var result: CycleBudgetResult = .{};
        while (result.cycles < minimum_cycles and result.instructions < max_instructions) {
            try accumulateCycleBudget(&result.cycles, try self.stepCpu());
            result.instructions += 1;
        }
        result.reached_budget = result.cycles >= minimum_cycles;
        return result;
    }

    pub fn tickScanline(self: *NeoGeoDiagnostic) void {
        self.timing.tickScanline();
    }

    pub fn setActions(self: *NeoGeoDiagnostic, actions: Actions) void {
        self.buttons = buttonsFromActions(actions);
    }

    pub fn writeSoundCommand(self: *NeoGeoDiagnostic, command: u8) void {
        self.sound_latch.writeCommand(command);
    }

    pub fn renderFixed(self: *NeoGeoDiagnostic, tiles: []const u8, palette_bank: usize) Error!Frame {
        const colors = self.palette_ram.decodeBank(palette_bank) orelse return error.InvalidPaletteBank;
        var frame = try video.renderFixedGrid(tiles, self.fixed_map.asSlice(), colors, &self.framebuffer);
        frame.frame_number = self.timing.frame_number;
        return frame;
    }
};

pub const Error = video.Error || error{InvalidPaletteBank};

pub const CycleBudgetError = @import("m68k.zig").Error || error{CycleBudgetOverflow};

pub const CycleBudgetResult = struct {
    cycles: u64 = 0,
    instructions: usize = 0,
    reached_budget: bool = false,
};

fn accumulateCycleBudget(total: *u64, added: u16) CycleBudgetError!void {
    const sum = @addWithOverflow(total.*, @as(u64, added));
    if (sum[1] != 0) return error.CycleBudgetOverflow;
    total.* = sum[0];
}

test "Neo Geo diagnostic assembles bus, raster frame number, palette and fixed grid" {
    const program = [_]u8{ 0x12, 0x34 };
    const bios = [_]u8{ 0xab, 0xcd };
    var neogeo = NeoGeoDiagnostic.init(&program, &bios);
    var tiles: [fixed.tile_bytes]u8 = [_]u8{0} ** fixed.tile_bytes;
    @memset(tiles[0..8], 0xff); // palette index 1
    try @import("std").testing.expect(neogeo.fixed_map.write(0, 0, 0));
    try @import("std").testing.expect(neogeo.palette_ram.writeWord(1, 0x7c00));
    for (0..Timing.total_scanlines) |_| neogeo.tickScanline();
    const frame = try neogeo.renderFixed(&tiles, 0);
    try @import("std").testing.expectEqual(@as(u64, 1), frame.frame_number);
    try @import("std").testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, frame.pixels[0..3]);
    try @import("std").testing.expectEqual(@as(?u16, 0xabcd), neogeo.bus.readWord(0));
    try @import("std").testing.expectError(error.InvalidPaletteBank, neogeo.renderFixed(&tiles, 4096 - 15));
}

test "Neo Geo diagnostic exposes the current raster frame number in every rendered frame" {
    var neogeo = NeoGeoDiagnostic.init(&.{}, &.{});
    var tiles: [fixed.tile_bytes]u8 = [_]u8{0} ** fixed.tile_bytes;
    try @import("std").testing.expect(neogeo.palette_ram.writeWord(0, 0));
    const initial = try neogeo.renderFixed(&tiles, 0);
    try @import("std").testing.expectEqual(@as(u64, 0), initial.frame_number);
    for (0..Timing.total_scanlines) |_| neogeo.tickScanline();
    const next = try neogeo.renderFixed(&tiles, 0);
    try @import("std").testing.expectEqual(@as(u64, 1), next.frame_number);
}

test "Neo Geo diagnostic accepts host-neutral actions without bus coupling" {
    var neogeo = NeoGeoDiagnostic.init(&.{}, &.{});
    neogeo.setActions(.{ .primary_4 = true, .coin = true, .down = true });
    try @import("std").testing.expect(neogeo.buttons.d and neogeo.buttons.coin and neogeo.buttons.down);
    try @import("std").testing.expect(!neogeo.buttons.a);
}

test "Neo Geo diagnostic connects BIOS reset vectors to the limited 68000 core" {
    const bios = [_]u8{
        0x00, 0x10, 0xff, 0xfc, // SSP
        0x00, 0x00, 0x00, 0x08, // PC
        0x4e, 0x71, // NOP
    };
    var neogeo = NeoGeoDiagnostic.init(&.{}, &bios);
    try neogeo.resetCpu();
    try @import("std").testing.expectEqual(@as(u32, 8), neogeo.cpu.pc);
    try @import("std").testing.expectEqual(@as(u16, 4), try neogeo.stepCpu());
}

test "Neo Geo diagnostic executes a bounded BIOS program against work RAM" {
    const bios = [_]u8{
        0x00, 0x10, 0xff, 0xfc, // SSP
        0x00, 0x00, 0x00, 0x08, // PC
        0x20, 0x7c, // MOVEA.L #$00100000,A0
        0x00, 0x10,
        0x00, 0x00,
        0x30, 0xbc, // MOVE.W #$beef,(A0)
        0xbe, 0xef,
    };
    var neogeo = NeoGeoDiagnostic.init(&.{}, &bios);
    try neogeo.resetCpu();
    try @import("std").testing.expectEqual(@as(u64, 28), try neogeo.stepCpuInstructions(2));
    try @import("std").testing.expectEqual(@as(?u16, 0xbeef), neogeo.bus.readWord(0x100000));
    try @import("std").testing.expectEqual(@as(u32, 0x12), neogeo.cpu.pc);
}

test "Neo Geo diagnostic cycle budget does not skip instructions or exceed its instruction cap" {
    const bios = [_]u8{
        0x00, 0x10, 0xff, 0xfc,
        0x00, 0x00, 0x00, 0x08,
        0x4e, 0x71, // NOP: 4
        0x70, 0x01, // MOVEQ: 4
        0x4e, 0x71, // NOP: 4
    };
    var neogeo = NeoGeoDiagnostic.init(&.{}, &bios);
    try neogeo.resetCpu();
    const reached = try neogeo.stepCpuCycleBudget(6, 3);
    try @import("std").testing.expectEqual(@as(u64, 8), reached.cycles);
    try @import("std").testing.expectEqual(@as(usize, 2), reached.instructions);
    try @import("std").testing.expect(reached.reached_budget);
    try @import("std").testing.expectEqual(@as(u32, 12), neogeo.cpu.pc);

    var capped = NeoGeoDiagnostic.init(&.{}, &bios);
    try capped.resetCpu();
    const incomplete = try capped.stepCpuCycleBudget(12, 2);
    try @import("std").testing.expectEqual(@as(u64, 8), incomplete.cycles);
    try @import("std").testing.expectEqual(@as(usize, 2), incomplete.instructions);
    try @import("std").testing.expect(!incomplete.reached_budget);
    try @import("std").testing.expectEqual(@as(u32, 12), capped.cpu.pc);
}

test "Neo Geo diagnostic cycle budget reports accumulation overflow explicitly" {
    var cycles: u64 = std.math.maxInt(u64) - 3;
    try std.testing.expectError(error.CycleBudgetOverflow, accumulateCycleBudget(&cycles, 4));
    try std.testing.expectEqual(std.math.maxInt(u64) - 3, cycles);
}

test "Neo Geo diagnostic exposes a sound command latch without a Z80 dependency" {
    var neogeo = NeoGeoDiagnostic.init(&.{}, &.{});
    neogeo.writeSoundCommand(0x55);
    try @import("std").testing.expectEqual(@as(?u8, 0x55), neogeo.sound_latch.takeCommand());
}
