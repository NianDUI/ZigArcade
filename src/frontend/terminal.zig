const std = @import("std");

const poll_interval_ms = 50;
var pending_signal = std.atomic.Value(u32).init(0);

pub const Key = union(enum) {
    byte: u8,
    up,
    down,
    left,
    right,
};

pub const Event = union(enum) { none, key: Key, exit, suspended };

pub const Viewport = struct { columns: u16, rows: u16 };

/// Returns the current terminal-cell geometry, or null when the operating
/// system cannot provide it. The presentation path then uses its conservative
/// fixed fallback.
pub fn viewport(io: std.Io) !?Viewport {
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = (try io.operate(.{ .device_io_control = .{
        .file = std.Io.File.stdout(),
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } })).device_io_control;
    if (result < 0 or size.col == 0 or size.row == 0) return null;
    return .{ .columns = size.col, .rows = size.row };
}

pub const Session = struct {
    original_termios: ?std.posix.termios = null,
    old_int: ?std.posix.Sigaction = null,
    old_term: ?std.posix.Sigaction = null,
    old_hup: ?std.posix.Sigaction = null,
    old_tstp: ?std.posix.Sigaction = null,
    active: bool = false,
    signal_handlers_installed: bool = false,
    pending_input: [256]u8 = undefined,
    pending_input_len: usize = 0,

    pub fn enter(self: *Session, io: std.Io, output: *std.Io.Writer) !void {
        if (!try std.Io.File.stdin().isTty(io) or !try std.Io.File.stdout().isTty(io)) {
            return error.NotTerminal;
        }

        self.original_termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        self.installSignalHandlers();
        errdefer self.restoreSignalHandlers();
        try self.activate(output);
    }

    pub fn leave(self: *Session, output: *std.Io.Writer) void {
        self.deactivate(output);
        self.restoreSignalHandlers();
        self.* = .{};
    }

    /// Queues ordinary bytes observed by a protocol probe so the game input
    /// loop receives them in their original order after probing completes.
    pub fn queueInput(self: *Session, bytes: []const u8) error{InputOverflow}!void {
        if (bytes.len > self.pending_input.len - self.pending_input_len) return error.InputOverflow;
        @memcpy(self.pending_input[self.pending_input_len..][0..bytes.len], bytes);
        self.pending_input_len += bytes.len;
    }

    /// Polling makes lifecycle signals observable without terminal I/O from a
    /// signal handler. It waits at most 50 ms in the no-input case.
    pub fn nextEvent(self: *Session) !Event {
        return self.nextEventTimeout(poll_interval_ms);
    }

    /// Reads one raw key. It recognizes the portable ANSI cursor sequences
    /// (`ESC [ A/B/C/D`) while retaining a lone Escape byte for the frontend.
    /// The NES loop supplies the shorter timeout for frame pacing; the demo
    /// keeps the original 50 ms lifecycle cadence through `nextEvent`.
    pub fn nextEventTimeout(self: *Session, timeout_ms: i32) !Event {
        if (takePendingSignal()) |signal| return eventForSignal(signal);

        var fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return .none;
        if (takePendingSignal()) |signal| return eventForSignal(signal);

        const byte = try self.readByte() orelse return .exit;
        if (byte != 0x1b) return .{ .key = .{ .byte = byte } };
        const csi = try self.readByteWithTimeout(5) orelse return .{ .key = .{ .byte = byte } };
        if (csi != '[') return .{ .key = .{ .byte = byte } };
        const final = try self.readByteWithTimeout(5) orelse return .{ .key = .{ .byte = byte } };
        return .{ .key = keyForCursorSequence(final) orelse .{ .byte = byte } };
    }

    fn readByte(self: *Session) !?u8 {
        if (self.pending_input_len != 0) {
            const byte = self.pending_input[0];
            self.pending_input_len -= 1;
            std.mem.copyForwards(u8, self.pending_input[0..self.pending_input_len], self.pending_input[1 .. self.pending_input_len + 1]);
            return byte;
        }
        return readStdinByte();
    }

    fn readByteWithTimeout(self: *Session, timeout_ms: i32) !?u8 {
        if (self.pending_input_len != 0) return self.readByte();
        var fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return null;
        return self.readByte();
    }

    /// Restore terminal state before yielding to default SIGTSTP. A SIGCONT
    /// returns here and re-enters raw mode plus alternate screen.
    pub fn suspendAndResume(self: *Session, output: *std.Io.Writer) !void {
        self.deactivate(output);
        try output.flush();

        if (self.old_tstp) |old| std.posix.sigaction(.TSTP, &old, null);
        try std.posix.raise(.TSTP);
        self.installTstpHandler();
        try self.activate(output);
    }

    fn activate(self: *Session, output: *std.Io.Writer) !void {
        const saved = self.original_termios orelse return error.InvalidSession;
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.IEXTEN = false;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
        errdefer std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, saved) catch {};

        try output.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
        self.active = true;
    }

    fn deactivate(self: *Session, output: *std.Io.Writer) void {
        if (!self.active) return;
        output.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        if (self.original_termios) |saved| std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, saved) catch {};
        self.active = false;
    }

    fn installSignalHandlers(self: *Session) void {
        if (self.signal_handlers_installed) return;
        const action = signalAction();
        var old_int: std.posix.Sigaction = undefined;
        var old_term: std.posix.Sigaction = undefined;
        var old_hup: std.posix.Sigaction = undefined;
        var old_tstp: std.posix.Sigaction = undefined;
        std.posix.sigaction(.INT, &action, &old_int);
        std.posix.sigaction(.TERM, &action, &old_term);
        std.posix.sigaction(.HUP, &action, &old_hup);
        std.posix.sigaction(.TSTP, &action, &old_tstp);
        self.old_int = old_int;
        self.old_term = old_term;
        self.old_hup = old_hup;
        self.old_tstp = old_tstp;
        self.signal_handlers_installed = true;
    }

    fn installTstpHandler(_: *Session) void {
        const action = signalAction();
        std.posix.sigaction(.TSTP, &action, null);
    }

    fn restoreSignalHandlers(self: *Session) void {
        if (!self.signal_handlers_installed) return;
        if (self.old_int) |old| std.posix.sigaction(.INT, &old, null);
        if (self.old_term) |old| std.posix.sigaction(.TERM, &old, null);
        if (self.old_hup) |old| std.posix.sigaction(.HUP, &old, null);
        if (self.old_tstp) |old| std.posix.sigaction(.TSTP, &old, null);
        self.signal_handlers_installed = false;
    }
};

fn readStdinByte() !?u8 {
    var byte: [1]u8 = undefined;
    const count = try std.posix.read(std.posix.STDIN_FILENO, &byte);
    return if (count == 0) null else byte[0];
}

fn keyForCursorSequence(final: u8) ?Key {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        else => null,
    };
}

fn signalAction() std.posix.Sigaction {
    return .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
}

fn onSignal(signal: std.posix.SIG) callconv(.c) void {
    pending_signal.store(@intFromEnum(signal), .seq_cst);
}

fn takePendingSignal() ?std.posix.SIG {
    const raw = pending_signal.swap(0, .seq_cst);
    if (raw == 0) return null;
    return @enumFromInt(raw);
}

fn eventForSignal(signal: std.posix.SIG) Event {
    return switch (signal) {
        .TSTP => .suspended,
        .INT, .TERM, .HUP => .exit,
        else => .none,
    };
}

test "terminal signals map to lifecycle events" {
    try std.testing.expectEqual(Event.exit, eventForSignal(.INT));
    try std.testing.expectEqual(Event.exit, eventForSignal(.TERM));
    try std.testing.expectEqual(Event.suspended, eventForSignal(.TSTP));
}

test "terminal recognizes standard ANSI cursor sequence suffixes" {
    try std.testing.expectEqual(Key.up, keyForCursorSequence('A').?);
    try std.testing.expectEqual(Key.down, keyForCursorSequence('B').?);
    try std.testing.expectEqual(Key.right, keyForCursorSequence('C').?);
    try std.testing.expectEqual(Key.left, keyForCursorSequence('D').?);
    try std.testing.expectEqual(@as(?Key, null), keyForCursorSequence('~'));
}

test "terminal queues probe-time user input in order" {
    var session: Session = .{};
    try session.queueInput("zx");
    try std.testing.expectEqual(@as(?u8, 'z'), try session.readByte());
    try std.testing.expectEqual(@as(?u8, 'x'), try session.readByte());
}
