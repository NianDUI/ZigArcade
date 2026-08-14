const std = @import("std");
const Frame = @import("core/frame.zig").Frame;
const PixelFormat = @import("core/frame.zig").PixelFormat;
const ansi = @import("frontend/ansi.zig");
const kitty = @import("frontend/kitty.zig");
const terminal = @import("frontend/terminal.zig");
const Actions = @import("core/input.zig").Actions;
const Cartridge = @import("systems/nes/cartridge.zig").Cartridge;
const actionsForByte = @import("systems/nes/input.zig").actionsForByte;
const buttonsFromActions = @import("systems/nes/input.zig").buttonsFromActions;
const Nes = @import("systems/nes/nes.zig").Nes;
const neogeo_fixed = @import("systems/neogeo/fixed.zig");
const neogeo_address_map = @import("systems/neogeo/address_map.zig");
const neogeo_cartridge_bus = @import("systems/neogeo/cartridge_bus.zig");
const neogeo_cartridge_io = @import("systems/neogeo/cartridge_io.zig");
const neogeo_dipswitch_watchdog = @import("systems/neogeo/dipswitch_watchdog.zig");
const neogeo_system_control = @import("systems/neogeo/system_control.zig");
const NeoGeoFixedMap = @import("systems/neogeo/fixed_map.zig").FixedMap;
const NeoGeoDiagnostic = @import("systems/neogeo/neogeo.zig").NeoGeoDiagnostic;
const neogeo_video = @import("systems/neogeo/video.zig");

comptime {
    _ = neogeo_address_map;
    _ = neogeo_cartridge_bus;
    _ = neogeo_cartridge_io;
    _ = neogeo_dipswitch_watchdog;
    _ = neogeo_system_control;
}

const Renderer = enum { ansi, kitty, auto };
const nes_frame_interval_ns: u64 = 16_639_267;
/// Traditional terminal input has no reliable key-up event. Retain a sampled
/// game key long enough for games to register movement; terminal key-repeat
/// refreshes this window while the player holds the key.
const raw_input_hold_frames: u8 = 8;
const presentation_divisor: u64 = 2;
const max_framehash_frames: u32 = 10_000;

const NesRunOptions = struct {
    renderer: Renderer = .auto,
    log_path: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "--demo")) return runDemo(init, args[2]);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--demo-neogeo")) return runNeoGeoDemo(init, args[2]);
    if (args.len == 3 and std.mem.eql(u8, args[1], "inspect")) return inspectNesRom(init, args[2]);
    if (args.len == 5 and std.mem.eql(u8, args[1], "framehash") and std.mem.eql(u8, args[3], "--frames")) {
        return hashNesFrames(init, args[2], try parseFrameCount(args[4]));
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "nes")) {
        return runNesWithOptions(init, args[2], try parseNesRunOptions(args[3..]));
    }
    try printUsage(init.io);
    return error.InvalidArguments;
}

fn runNeoGeoDemo(init: std.process.Init, renderer_name: []const u8) !void {
    var renderer = try parseRenderer(renderer_name);
    var tiles: [2 * neogeo_fixed.tile_bytes]u8 = [_]u8{0} ** (2 * neogeo_fixed.tile_bytes);
    // Two four-color checker tiles make the 40x28 fixed-layer grid
    // recognizable without shipping S-ROM or palette assets.
    for (0..neogeo_fixed.tile_height) |row| {
        tiles[row] = if (row & 1 == 0) 0xaa else 0x55;
        tiles[8 + row] = if (row & 1 == 0) 0x33 else 0xcc;
        tiles[neogeo_fixed.tile_bytes + row] = if (row & 1 == 0) 0x55 else 0xaa;
        tiles[neogeo_fixed.tile_bytes + 8 + row] = if (row & 1 == 0) 0xcc else 0x33;
    }
    const empty_rom = [_]u8{};
    var neogeo = NeoGeoDiagnostic.init(&empty_rom, &empty_rom);
    _ = neogeo.palette_ram.writeWord(1, 0x001f); // RGB555: blue
    _ = neogeo.palette_ram.writeWord(2, 0x7c00); // RGB555: red
    _ = neogeo.palette_ram.writeWord(3, 0x03e0); // RGB555: green
    for (0..neogeo_video.fixed_rows) |y| {
        for (0..neogeo_video.fixed_columns) |x| {
            _ = neogeo.fixed_map.write(x, y, @intCast((x + y) & 1));
        }
    }
    for (0..@import("systems/neogeo/timing.zig").Timing.total_scanlines) |_| neogeo.tickScanline();
    const frame = try neogeo.renderFixed(&tiles, 0);
    try presentDemoFrame(init, &renderer, frame);
}

fn parseFrameCount(value: []const u8) !u32 {
    const count = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArguments;
    if (count == 0 or count > max_framehash_frames) return error.InvalidArguments;
    return count;
}

fn parseRenderer(value: []const u8) !Renderer {
    return if (std.mem.eql(u8, value, "ansi"))
        .ansi
    else if (std.mem.eql(u8, value, "kitty"))
        .kitty
    else if (std.mem.eql(u8, value, "auto"))
        .auto
    else
        error.InvalidArguments;
}

fn parseNesRunOptions(args: []const []const u8) !NesRunOptions {
    if (args.len % 2 != 0) return error.InvalidArguments;
    var options = NesRunOptions{};
    var renderer_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 2) {
        if (std.mem.eql(u8, args[index], "--renderer")) {
            if (renderer_seen) return error.InvalidArguments;
            options.renderer = try parseRenderer(args[index + 1]);
            renderer_seen = true;
        } else if (std.mem.eql(u8, args[index], "--log")) {
            if (options.log_path != null or args[index + 1].len == 0) return error.InvalidArguments;
            options.log_path = args[index + 1];
        } else {
            return error.InvalidArguments;
        }
    }
    return options;
}

fn runDemo(init: std.process.Init, renderer_name: []const u8) !void {
    var renderer = parseRenderer(renderer_name) catch {
        try printUsage(init.io);
        return error.InvalidArguments;
    };

    var rgb: [256 * 240 * 3]u8 = undefined;
    fillColorBars(&rgb);
    const frame = Frame{
        .pixels = &rgb,
        .width = 256,
        .height = 240,
        .stride = 256 * 3,
        .format = .rgb888,
        .frame_number = 0,
    };

    try presentDemoFrame(init, &renderer, frame);
}

fn presentDemoFrame(init: std.process.Init, renderer: *Renderer, frame: Frame) !void {
    var output_storage: [8192]u8 = undefined;
    var output_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &output_storage);
    const output = &output_file_writer.interface;

    var session: terminal.Session = .{};
    try session.enter(init.io, output);
    defer leavePresentation(&session, output);

    if (renderer.* == .auto) renderer.* = if (try probeKitty(init.io, output, &session)) .kitty else .ansi;

    try appendExitPrompt(init.io, output);
    try appendPresentedFrame(init.io, output, renderer.*, frame);
    try output.flush();
    while (true) {
        switch (try session.nextEvent()) {
            .key, .exit => break,
            .suspended => {
                try kitty.appendDeleteAll(output);
                try session.suspendAndResume(output);
                try appendExitPrompt(init.io, output);
                try appendPresentedFrame(init.io, output, renderer.*, frame);
                try output.flush();
            },
            .none => {},
        }
    }
}

fn appendExitPrompt(io: std.Io, output: *std.Io.Writer) !void {
    const row = if (try terminal.viewport(io)) |view| view.rows else 61;
    if (row > 1) {
        try output.print("\x1b[0m\x1b[{d};1H\x1b[2KEsc 退出 · 方向键/WASD 移动 · Z/X A/B · Enter Start", .{row});
    }
    try output.writeAll("\x1b[H");
}

/// Loads a supported iNES 1.0 cartridge and presents its RGB frames. ROM
/// bytes live in the process arena for the whole run, keeping the cartridge's
/// borrowed PRG/CHR slices valid.
fn runNes(init: std.process.Init, rom_path: []const u8) !void {
    return runNesWithOptions(init, rom_path, .{});
}

/// Validates a ROM without entering raw terminal mode. This is intentionally
/// useful before a play session: errors report unsupported board/layout
/// choices while the successful output exposes exactly what ZigArcade saw.
fn inspectNesRom(init: std.process.Init, rom_path: []const u8) !void {
    const image = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        rom_path,
        init.arena.allocator(),
        .limited(8 * 1024 * 1024),
    );
    const cartridge = Cartridge.parse(image) catch |err| {
        try appendCartridgeError(init.io, rom_path, err);
        return err;
    };
    var output_storage: [512]u8 = undefined;
    var output_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &output_storage);
    const output = &output_file_writer.interface;
    try appendCartridgeInfo(output, cartridge);
    try output.flush();
}

/// Runs a fixed amount of emulated time without a TTY and prints a stable
/// framebuffer checksum. It gives users of legal local ROMs a reproducible
/// regression primitive without putting any ROM data in this repository.
fn hashNesFrames(init: std.process.Init, rom_path: []const u8, frame_count: u32) !void {
    const image = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        rom_path,
        init.arena.allocator(),
        .limited(8 * 1024 * 1024),
    );
    const cartridge = Cartridge.parse(image) catch |err| {
        try appendCartridgeError(init.io, rom_path, err);
        return err;
    };
    var nes: Nes = undefined;
    nes.init(cartridge);
    var frame: Frame = undefined;
    for (0..frame_count) |_| frame = try nes.runFrame();
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &digest, .{});
    const image_sha256 = std.fmt.bytesToHex(digest, .lower);

    var output_storage: [256]u8 = undefined;
    var output_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &output_storage);
    const output = &output_file_writer.interface;
    try output.print(
        "rom-sha256: {s}\nframes: {d}\nframebuffer-wyhash: {d}\n",
        .{ image_sha256, frame.frame_number, std.hash.Wyhash.hash(0, frame.pixels) },
    );
    try output.flush();
}

fn appendCartridgeInfo(output: *std.Io.Writer, cartridge: Cartridge) !void {
    try output.print(
        "iNES 1.0: mapper {d} ({s})\nPRG-ROM: {d} KiB\nCHR: {d} KiB ({s})\nMirroring: {s}\n",
        .{
            @intFromEnum(cartridge.mapper),
            mapperName(cartridge.mapper),
            cartridge.prg_rom.len / 1024,
            if (cartridge.chr_is_ram) 8 else cartridge.chr_rom.len / 1024,
            if (cartridge.chr_is_ram) "RAM" else "ROM",
            mirroringName(cartridge.mirroring),
        },
    );
}

fn appendCartridgeError(io: std.Io, rom_path: []const u8, err: @import("systems/nes/cartridge.zig").Error) !void {
    var stderr_storage: [512]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_storage);
    try stderr_writer.interface.print("无法加载 NES ROM '{s}'：{s}\n", .{ rom_path, cartridgeErrorDescription(err) });
    try stderr_writer.interface.flush();
}

fn cartridgeErrorDescription(err: @import("systems/nes/cartridge.zig").Error) []const u8 {
    return switch (err) {
        error.CorruptRom => "文件长度不足或 ROM 数据损坏",
        error.UnsupportedRomFormat => "仅支持 iNES 1.0；NES 2.0 或无效头部尚不支持",
        error.UnsupportedMapper => "仅支持 Mapper 0 (NROM)、1 (MMC1)、2 (UNROM)、3 (CNROM)、7 (AOROM)",
        error.UnsupportedTrainer => "带 trainer 的 iNES ROM 尚不支持",
        error.UnsupportedFourScreenMirroring => "four-screen 镜像尚不支持",
        error.UnsupportedBatteryBackedRam => "电池存档 ROM 尚不支持",
        error.UnsupportedNromLayout => "NROM 的 PRG/CHR 大小不受支持",
        error.UnsupportedMapperLayout => "该 mapper 的 PRG/CHR 版型不在当前支持范围内",
    };
}

fn mapperName(mapper: @import("systems/nes/cartridge.zig").MapperId) []const u8 {
    return switch (mapper) {
        .nrom => "NROM",
        .mmc1 => "MMC1",
        .unrom => "UNROM",
        .cnrom => "CNROM",
        .aorom => "AOROM",
    };
}

fn mirroringName(mirroring: @import("systems/nes/cartridge.zig").Mirroring) []const u8 {
    return switch (mirroring) {
        .horizontal => "horizontal",
        .vertical => "vertical",
        .single_screen_lower => "single-screen lower",
        .single_screen_upper => "single-screen upper",
    };
}

fn runNesWithOptions(init: std.process.Init, rom_path: []const u8, options: NesRunOptions) !void {
    const image = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        rom_path,
        init.arena.allocator(),
        .limited(8 * 1024 * 1024),
    );
    const cartridge = Cartridge.parse(image) catch |err| {
        try appendCartridgeError(init.io, rom_path, err);
        return err;
    };
    var nes: Nes = undefined;
    nes.init(cartridge);

    var output_storage: [8192]u8 = undefined;
    var output_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &output_storage);
    const output = &output_file_writer.interface;
    var session: terminal.Session = .{};
    try session.enter(init.io, output);
    defer leavePresentation(&session, output);

    var renderer = try selectRenderer(init.io, output, &session, options.renderer);
    var logger = RunLogger{};
    try logger.open(init.io, options.log_path);
    defer logger.deinit(init.io);
    try logger.write(init.io, "start renderer={s} rom={s}\n", .{ @tagName(renderer), rom_path });
    var held_actions = Actions{};
    var held_frames: u8 = 0;
    var presented_frames: u64 = 0;
    var next_frame_deadline = std.Io.Clock.Timestamp.now(init.io, .awake).addDuration(nesFrameDuration());
    while (true) {
        nes.controllers.ports[0].setHostButtons(buttonsFromActions(consumeHeldActions(&held_actions, &held_frames)));
        const frame = try nes.runFrame();
        // Emulation advances one NTSC frame each loop (about 60 Hz). The
        // terminal is intentionally updated every second emulated frame to
        // cap the initial presentation path near 30 FPS; never slow or skip
        // the emulated clock just because a frame was not presented.
        if (shouldPresentFrame(frame.frame_number)) {
            const logged_frame = shouldLogNesFrame(frame.frame_number);
            if (logged_frame) try logger.write(init.io, "frame={d} present=begin\n", .{frame.frame_number});
            const present_started = std.Io.Clock.Timestamp.now(init.io, .awake);
            try appendExitPrompt(init.io, output);
            try appendPresentedFrame(init.io, output, renderer, frame);
            try output.flush();
            presented_frames += 1;
            if (logged_frame) {
                const present_finished = std.Io.Clock.Timestamp.now(init.io, .awake);
                try logger.write(
                    init.io,
                    "frame={d} present=end duration_ms={d} presented={d}\n",
                    .{ frame.frame_number, elapsedMilliseconds(present_started, present_finished), presented_frames },
                );
            }
        }
        switch (try waitForNextNesFrame(init.io, &session, &next_frame_deadline, &held_actions, &held_frames)) {
            .exit => |reason| {
                try logger.write(init.io, "frame={d} terminal=exit reason={s}\n", .{ frame.frame_number, @tagName(reason) });
                break;
            },
            .suspended => {
                try logger.write(init.io, "frame={d} terminal=suspended\n", .{frame.frame_number});
                try kitty.appendDeleteAll(output);
                try session.suspendAndResume(output);
                renderer = try selectRenderer(init.io, output, &session, options.renderer);
                next_frame_deadline = std.Io.Clock.Timestamp.now(init.io, .awake).addDuration(nesFrameDuration());
                try logger.write(init.io, "frame={d} terminal=resumed renderer={s}\n", .{ frame.frame_number, @tagName(renderer) });
            },
            .none => {},
            .key => unreachable,
        }
    }
}

const RunLogger = struct {
    file: ?std.Io.File = null,
    storage: [512]u8 = undefined,
    writer: ?std.Io.File.Writer = null,

    fn open(self: *RunLogger, io: std.Io, path: ?[]const u8) !void {
        return self.openInDir(io, std.Io.Dir.cwd(), path);
    }

    fn openInDir(self: *RunLogger, io: std.Io, dir: std.Io.Dir, path: ?[]const u8) !void {
        const value = path orelse return;
        self.file = try dir.createFile(io, value, .{});
        self.writer = self.file.?.writer(io, &self.storage);
    }

    fn deinit(self: *RunLogger, io: std.Io) void {
        if (self.file) |file| file.close(io);
    }

    fn write(self: *RunLogger, io: std.Io, comptime format: []const u8, args: anytype) !void {
        _ = io;
        if (self.writer) |*writer| {
            try writer.interface.print(format, args);
            try writer.interface.flush();
        }
    }
};

fn shouldLogNesFrame(frame_number: u64) bool {
    return frame_number % 60 == 1;
}

fn elapsedMilliseconds(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) u64 {
    return @intCast(@max(@as(i96, 0), @divTrunc(start.durationTo(end).raw.nanoseconds, std.time.ns_per_ms)));
}

/// Waits only until the next emulated-frame deadline. Rendering and input
/// processing therefore consume the same 60 Hz budget rather than being added
/// to a fixed sleep after every frame.
fn waitForNextNesFrame(
    io: std.Io,
    session: *terminal.Session,
    deadline: *std.Io.Clock.Timestamp,
    held_actions: *Actions,
    held_frames: *u8,
) !terminal.Event {
    while (true) {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        if (now.compare(.gte, deadline.*)) {
            while (deadline.*.compare(.lte, now)) deadline.* = deadline.*.addDuration(nesFrameDuration());
            return .none;
        }
        const remaining_ns: u64 = @intCast(now.durationTo(deadline.*).raw.nanoseconds);
        switch (try session.nextEventTimeout(timeoutMsForRemaining(remaining_ns))) {
            .key => |event| {
                if (event.state != .release and isEscapeKey(event.key)) return .{ .exit = .escape };
                switch (event.state) {
                    .legacy => {
                        held_actions.* = actionsForKey(event.key);
                        held_frames.* = raw_input_hold_frames;
                    },
                    .press, .repeat => applyKeyAction(held_actions, event.key, true),
                    .release => applyKeyAction(held_actions, event.key, false),
                }
            },
            .exit => |reason| return .{ .exit = reason },
            .suspended => return .suspended,
            .none => {},
        }
    }
}

fn nesFrameDuration() std.Io.Clock.Duration {
    return .{ .raw = .fromNanoseconds(nes_frame_interval_ns), .clock = .awake };
}

fn timeoutMsForRemaining(remaining_ns: u64) i32 {
    std.debug.assert(remaining_ns != 0);
    const rounded_up = (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    return @intCast(@min(rounded_up, @as(u64, std.math.maxInt(i32))));
}

fn isEscapeKey(key: terminal.Key) bool {
    return switch (key) {
        .byte => |byte| byte == 0x1b,
        else => false,
    };
}

fn actionsForKey(key: terminal.Key) Actions {
    return switch (key) {
        .byte => |byte| actionsForByte(byte),
        .up => .{ .up = true },
        .down => .{ .down = true },
        .left => .{ .left = true },
        .right => .{ .right = true },
    };
}

/// Returns the sampled terminal action for this emulated frame, then expires
/// it after its short hold window. Keeping this state here ensures every host
/// input path still reaches the NES controller only at a frame boundary.
fn consumeHeldActions(held_actions: *Actions, held_frames: *u8) Actions {
    const actions = held_actions.*;
    if (held_frames.* == 0) return actions;
    held_frames.* -= 1;
    if (held_frames.* == 0) held_actions.* = .{};
    return actions;
}

fn applyKeyAction(actions: *Actions, key: terminal.Key, pressed: bool) void {
    const current: u16 = @bitCast(actions.*);
    const changed: u16 = @bitCast(actionsForKey(key));
    actions.* = @bitCast(if (pressed) current | changed else current & ~changed);
}

fn shouldPresentFrame(frame_number: u64) bool {
    return frame_number % presentation_divisor == 1;
}

fn appendPresentedFrame(io: std.Io, output: *std.Io.Writer, renderer: Renderer, frame: Frame) !void {
    switch (renderer) {
        .ansi => {
            var pixels: [ansi.max_reduced_rgb_bytes]u8 = undefined;
            const reduced = try ansi.downsample2x(frame, &pixels);
            try ansi.appendFrame(output, reduced);
        },
        .kitty => {
            const options = if (try terminal.viewport(io)) |view|
                kitty.fitOptions(frame, view.columns, if (view.rows > 1) view.rows - 1 else 1)
            else
                kitty.Options{};
            try kitty.appendFrame(output, frame, options);
        },
        .auto => unreachable,
    }
}

/// A Kitty image lives in the terminal, not in Zig memory. Delete it only on
/// session teardown (never between frames), then restore the TTY regardless
/// of whether the best-effort protocol cleanup itself succeeds.
fn leavePresentation(session: *terminal.Session, output: *std.Io.Writer) void {
    kitty.appendDeleteAll(output) catch {};
    session.leave(output);
    output.flush() catch {};
}

fn selectRenderer(io: std.Io, output: *std.Io.Writer, session: *terminal.Session, requested: Renderer) !Renderer {
    return switch (requested) {
        .ansi => .ansi,
        .auto => if (try probeKitty(io, output, session)) .kitty else .ansi,
        .kitty => if (try probeKitty(io, output, session)) .kitty else error.TerminalUnsupported,
    };
}

fn probeKitty(io: std.Io, output: *std.Io.Writer, session: *terminal.Session) !bool {
    try kitty.appendProbe(output, kitty.probe_image_id);
    try output.flush();

    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromNanoseconds(200 * std.time.ns_per_ms),
        .clock = .awake,
    });
    var demux: kitty.ProbeDemux = .{};
    var input: [256]u8 = undefined;
    while (true) {
        const remaining = deadline.durationFromNow(io);
        if (remaining.raw.nanoseconds <= 0) break;
        const timeout_ms: i32 = @intCast(@max(@as(i96, 1), @divFloor(remaining.raw.nanoseconds, std.time.ns_per_ms)));
        var fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) break;
        const read_count = try std.posix.read(std.posix.STDIN_FILENO, &input);
        const result = try demux.feed(kitty.probe_image_id, input[0..read_count]);
        try session.queueInput(demux.takeInput());
        switch (result) {
            .supported => return true,
            .rejected => return false,
            .pending => {},
        }
    }
    return false;
}

fn printUsage(io: std.Io) !void {
    var stderr_storage: [512]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_storage);
    try stderr_writer.interface.writeAll(
        "Usage:\n" ++
            "  zigarcade --demo <ansi|kitty|auto>\n" ++
            "  zigarcade --demo-neogeo <ansi|kitty|auto>\n" ++
            "  zigarcade inspect <path/to/rom.nes>\n" ++
            "  zigarcade framehash <path/to/rom.nes> --frames <1-10000>\n" ++
            "  zigarcade nes <path/to/rom.nes> [--renderer ansi|kitty|auto] [--log <path>]\n",
    );
    try stderr_writer.interface.flush();
}

fn fillColorBars(rgb: []u8) void {
    const colors = [_][3]u8{
        .{ 255, 255, 255 }, .{ 255, 255, 0 }, .{ 0, 255, 255 }, .{ 0, 255, 0 },
        .{ 255, 0, 255 },   .{ 255, 0, 0 },   .{ 0, 0, 255 },   .{ 0, 0, 0 },
    };
    const width: usize = 256;
    for (0..240) |y| {
        for (0..width) |x| {
            const color = colors[x * colors.len / width];
            const offset = (y * width + x) * 3;
            rgb[offset..][0..3].* = color;
        }
    }
}

test "color bar fills all pixels" {
    var pixels: [8 * 2 * 3]u8 = undefined;
    fillColorBarsForSize(&pixels, 8, 2);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, pixels[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, pixels[21..24]);
}

test "renderer parser accepts documented values and rejects others" {
    try std.testing.expectEqual(Renderer.ansi, try parseRenderer("ansi"));
    try std.testing.expectEqual(Renderer.kitty, try parseRenderer("kitty"));
    try std.testing.expectEqual(Renderer.auto, try parseRenderer("auto"));
    try std.testing.expectError(error.InvalidArguments, parseRenderer("sixel"));
}

test "NES run options accept an optional renderer and file log" {
    const options = try parseNesRunOptions(&.{ "--renderer", "kitty", "--log", "run.log" });
    try std.testing.expectEqual(Renderer.kitty, options.renderer);
    try std.testing.expectEqualStrings("run.log", options.log_path.?);
    try std.testing.expectError(error.InvalidArguments, parseNesRunOptions(&.{ "--renderer", "auto", "--renderer", "ansi" }));
}

test "runtime log retains multiple phase records" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var logger = RunLogger{};
    try logger.openInDir(std.testing.io, temporary.dir, "run.log");
    try logger.write(std.testing.io, "first={d}\n", .{1});
    try logger.write(std.testing.io, "second={d}\n", .{2});
    logger.deinit(std.testing.io);
    const logged = try temporary.dir.readFileAlloc(std.testing.io, "run.log", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(logged);
    try std.testing.expectEqualStrings("first=1\nsecond=2\n", logged);
}

test "Neo Geo diagnostic demo reuses the renderer selection contract" {
    try std.testing.expectEqual(Renderer.auto, try parseRenderer("auto"));
    try std.testing.expectEqual(Renderer.kitty, try parseRenderer("kitty"));
    try std.testing.expectError(error.InvalidArguments, parseRenderer("sixel"));
}

test "framehash frame parser accepts only a bounded positive count" {
    try std.testing.expectEqual(@as(u32, 1), try parseFrameCount("1"));
    try std.testing.expectEqual(max_framehash_frames, try parseFrameCount("10000"));
    try std.testing.expectError(error.InvalidArguments, parseFrameCount("0"));
    try std.testing.expectError(error.InvalidArguments, parseFrameCount("10001"));
    try std.testing.expectError(error.InvalidArguments, parseFrameCount("two"));
}

test "cartridge info names supported mapper and mirroring variants" {
    const MapperId = @import("systems/nes/cartridge.zig").MapperId;
    const Mirroring = @import("systems/nes/cartridge.zig").Mirroring;
    try std.testing.expectEqualStrings("MMC1", mapperName(.mmc1));
    try std.testing.expectEqualStrings("CNROM", mapperName(.cnrom));
    try std.testing.expectEqualStrings("single-screen upper", mirroringName(.single_screen_upper));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(MapperId.mmc1));
    try std.testing.expectEqual(Mirroring.vertical, .vertical);
}

test "cartridge inspection reports validated iNES metadata" {
    const MapperId = @import("systems/nes/cartridge.zig").MapperId;
    const Mirroring = @import("systems/nes/cartridge.zig").Mirroring;
    var prg: [32 * 1024]u8 = [_]u8{0} ** (32 * 1024);
    var output: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try appendCartridgeInfo(&writer, .{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .vertical,
        .mapper = MapperId.unrom,
    });
    try std.testing.expectEqualStrings(
        "iNES 1.0: mapper 2 (UNROM)\nPRG-ROM: 32 KiB\nCHR: 8 KiB (RAM)\nMirroring: vertical\n",
        writer.buffered(),
    );
    try std.testing.expectEqual(Mirroring.vertical, .vertical);
}

test "cartridge errors explain current compatibility boundary" {
    const CartridgeError = @import("systems/nes/cartridge.zig").Error;
    try std.testing.expectEqualStrings(
        "仅支持 Mapper 0 (NROM)、1 (MMC1)、2 (UNROM)、3 (CNROM)、7 (AOROM)",
        cartridgeErrorDescription(CartridgeError.UnsupportedMapper),
    );
    try std.testing.expectEqualStrings("电池存档 ROM 尚不支持", cartridgeErrorDescription(CartridgeError.UnsupportedBatteryBackedRam));
}

test "30 FPS presentation retains every 60 Hz emulation frame" {
    try std.testing.expect(shouldPresentFrame(1));
    try std.testing.expect(!shouldPresentFrame(2));
    try std.testing.expect(shouldPresentFrame(3));
}

test "frame scheduler waits to the 60 Hz deadline without sub-millisecond spin" {
    try std.testing.expectEqual(@as(i32, 1), timeoutMsForRemaining(1));
    try std.testing.expectEqual(@as(i32, 17), timeoutMsForRemaining(nes_frame_interval_ns));
}

test "terminal cursor keys and lone Escape map to stable actions" {
    try std.testing.expect(actionsForKey(.up).up);
    try std.testing.expect(actionsForKey(.down).down);
    try std.testing.expect(actionsForKey(.left).left);
    try std.testing.expect(actionsForKey(.right).right);
    try std.testing.expect(actionsForKey(.{ .byte = 'z' }).primary_1);
    try std.testing.expect(isEscapeKey(.{ .byte = 0x1b }));
    try std.testing.expect(!isEscapeKey(.left));
}

test "raw terminal samples retain buttons for a short movement window" {
    var actions = Actions{ .right = true };
    var remaining = @as(u8, 2);
    try std.testing.expect(consumeHeldActions(&actions, &remaining).right);
    try std.testing.expectEqual(@as(u8, 1), remaining);
    try std.testing.expect(consumeHeldActions(&actions, &remaining).right);
    try std.testing.expectEqual(@as(u8, 0), remaining);
    try std.testing.expect(!consumeHeldActions(&actions, &remaining).right);
    try std.testing.expectEqual(@as(u8, 8), raw_input_hold_frames);
}

test "Kitty key releases preserve other held controls" {
    var actions = Actions{};
    applyKeyAction(&actions, .right, true);
    applyKeyAction(&actions, .{ .byte = 'z' }, true);
    applyKeyAction(&actions, .right, false);
    try std.testing.expect(!actions.right);
    try std.testing.expect(actions.primary_1);
}

fn fillColorBarsForSize(rgb: []u8, width: usize, height: usize) void {
    const colors = [_][3]u8{
        .{ 255, 255, 255 }, .{ 255, 255, 0 }, .{ 0, 255, 255 }, .{ 0, 255, 0 },
        .{ 255, 0, 255 },   .{ 255, 0, 0 },   .{ 0, 0, 255 },   .{ 0, 0, 0 },
    };
    for (0..height) |y| for (0..width) |x| {
        const offset = (y * width + x) * 3;
        rgb[offset..][0..3].* = colors[x * colors.len / width];
    };
}
