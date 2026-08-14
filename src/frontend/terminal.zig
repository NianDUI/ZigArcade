const std = @import("std");

const poll_interval_ms = 50;
const escape_prefix_grace_timeouts = 8;
const apc_discard_grace_timeouts = 16;
var pending_signal = std.atomic.Value(u32).init(0);

pub const Key = union(enum) {
    byte: u8,
    up,
    down,
    left,
    right,
};

/// Legacy terminals expose only a press-like byte stream. Kitty Keyboard
/// Protocol additionally provides real press/repeat/release transitions.
pub const KeyState = enum { legacy, press, repeat, release };

pub const KeyEvent = struct {
    key: Key,
    state: KeyState,
};

/// Every terminal-initiated exit carries its observable source so callers can
/// diagnose a vanished fullscreen session instead of treating EOF, signals,
/// and an explicit Escape key as indistinguishable.
pub const ExitReason = enum { escape, input_closed, interrupt, terminate, hangup };

pub const Event = union(enum) { none, key: KeyEvent, exit: ExitReason, suspended };

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
    apc_discarding: bool = false,
    apc_previous_was_escape: bool = false,
    apc_discard_timeouts: u8 = 0,
    escape_prefix_pending: bool = false,
    escape_prefix_timeouts: u8 = 0,

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
    /// (`ESC [ A/B/C/D`) and Kitty Keyboard Protocol transitions while
    /// retaining a lone Escape byte for legacy frontends. The NES loop
    /// supplies the shorter timeout for frame pacing; the demo keeps the
    /// original 50 ms lifecycle cadence through `nextEvent`.
    pub fn nextEventTimeout(self: *Session, timeout_ms: i32) !Event {
        if (takePendingSignal()) |signal| return eventForSignal(signal);
        if (self.apc_discarding) return self.continueDiscardingApc(timeout_ms);
        if (self.escape_prefix_pending) return self.continueEscapePrefix(timeout_ms);

        var fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return .none;
        if (takePendingSignal()) |signal| return eventForSignal(signal);

        const byte = try self.readByte() orelse return .{ .exit = .input_closed };
        if (byte != 0x1b) return .{ .key = .{ .key = .{ .byte = byte }, .state = .legacy } };
        self.escape_prefix_pending = true;
        self.escape_prefix_timeouts = 0;
        return self.continueEscapePrefix(5);
    }

    fn continueEscapePrefix(self: *Session, timeout_ms: i32) !Event {
        const csi = switch (try self.readByteWithTimeout(timeout_ms)) {
            .byte => |value| value,
            .timeout => {
                self.escape_prefix_timeouts +%= 1;
                if (self.escape_prefix_timeouts < escape_prefix_grace_timeouts) return .none;
                self.escape_prefix_pending = false;
                return .{ .key = .{ .key = .{ .byte = 0x1b }, .state = .legacy } };
            },
            .input_closed => {
                self.escape_prefix_pending = false;
                return .{ .exit = .input_closed };
            },
        };
        self.escape_prefix_pending = false;
        // Kitty graphics replies are APC sequences (`ESC _ ... ESC \\`) on
        // the same TTY as user input. They are terminal protocol traffic, not
        // an Escape key; consuming them here prevents a quiet image response
        // from ending a game session.
        if (csi == '_') {
            self.apc_discarding = true;
            self.apc_previous_was_escape = false;
            self.apc_discard_timeouts = 0;
            return self.continueDiscardingApc(0);
        }
        // ST terminates APC, OSC, and DCS terminal control strings. An orphan
        // terminator may arrive after a fragmented reply; it is never a game
        // key and must not become a legacy Escape event.
        if (csi == '\\') return .none;
        if (csi != '[') return .{ .key = .{ .key = .{ .byte = 0x1b }, .state = .legacy } };

        var params: [32]u8 = undefined;
        var len: usize = 0;
        while (len < params.len) {
            const next = switch (try self.readByteWithTimeout(5)) {
                .byte => |value| value,
                .timeout => return .{ .key = .{ .key = .{ .byte = 0x1b }, .state = .legacy } },
                .input_closed => return .{ .exit = .input_closed },
            };
            if (next >= 0x40 and next <= 0x7e) {
                return .{ .key = keyEventForCsi(params[0..len], next) orelse .{ .key = .{ .byte = 0x1b }, .state = .legacy } };
            }
            params[len] = next;
            len += 1;
        }
        return .{ .key = .{ .key = .{ .byte = 0x1b }, .state = .legacy } };
    }

    /// Discards a terminal APC reply over as many event-loop calls as needed.
    /// A non-blocking follow-up avoids holding up the emulation loop when a
    /// terminal splits a large graphics reply across several reads.
    fn continueDiscardingApc(self: *Session, initial_timeout_ms: i32) !Event {
        var timeout_ms = initial_timeout_ms;
        while (true) {
            switch (try self.readByteWithTimeout(timeout_ms)) {
                .timeout => {
                    self.apc_discard_timeouts +%= 1;
                    if (self.apc_discard_timeouts >= apc_discard_grace_timeouts) {
                        self.apc_discarding = false;
                        self.apc_previous_was_escape = false;
                    }
                    return .none;
                },
                .input_closed => {
                    self.apc_discarding = false;
                    return .{ .exit = .input_closed };
                },
                .byte => |byte| {
                    if (self.apc_previous_was_escape and byte == '\\') {
                        self.apc_discarding = false;
                        return .none;
                    }
                    self.apc_previous_was_escape = byte == 0x1b;
                    self.apc_discard_timeouts = 0;
                    timeout_ms = 0;
                },
            }
        }
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

    const TimedByte = union(enum) { timeout, byte: u8, input_closed };

    fn readByteWithTimeout(self: *Session, timeout_ms: i32) !TimedByte {
        if (self.pending_input_len != 0) return .{ .byte = (try self.readByte()).? };
        var fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return .timeout;
        return if (try self.readByte()) |byte| .{ .byte = byte } else .input_closed;
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

        // 0b1011: disambiguate escape, report press/repeat/release, and
        // encode text keys too. Unsupported terminals ignore this request and
        // keep their normal legacy byte stream.
        try output.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H\x1b[>11u");
        self.active = true;
    }

    fn deactivate(self: *Session, output: *std.Io.Writer) void {
        if (!self.active) return;
        output.writeAll("\x1b[<u\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
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

fn keyEventForCsi(params: []const u8, final: u8) ?KeyEvent {
    const key = switch (final) {
        'A', 'B', 'C', 'D' => keyForCursorSequence(final).?,
        'u' => keyForCodepoint(params) orelse return null,
        else => return null,
    };
    return .{ .key = key, .state = keyStateForCsi(params) };
}

fn keyForCodepoint(params: []const u8) ?Key {
    var end: usize = 0;
    while (end < params.len and params[end] != ';' and params[end] != ':') : (end += 1) {}
    if (end == 0) return null;
    const codepoint = std.fmt.parseInt(u32, params[0..end], 10) catch return null;
    if (codepoint > 0xff) return null;
    return .{ .byte = @intCast(codepoint) };
}

fn keyStateForCsi(params: []const u8) KeyState {
    // A CSI key sequence without the `:event` suffix is traditional terminal
    // input, so it must keep the bounded fallback rather than stick forever.
    const colon = std.mem.lastIndexOfScalar(u8, params, ':') orelse return .legacy;
    const state = std.fmt.parseInt(u8, params[colon + 1 ..], 10) catch return .press;
    return switch (state) {
        1 => .press,
        2 => .repeat,
        3 => .release,
        else => .press,
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
        .INT => .{ .exit = .interrupt },
        .TERM => .{ .exit = .terminate },
        .HUP => .{ .exit = .hangup },
        else => .none,
    };
}

test "terminal signals map to lifecycle events" {
    try std.testing.expectEqual(Event{ .exit = .interrupt }, eventForSignal(.INT));
    try std.testing.expectEqual(Event{ .exit = .terminate }, eventForSignal(.TERM));
    try std.testing.expectEqual(Event.suspended, eventForSignal(.TSTP));
}

test "terminal recognizes standard ANSI cursor sequence suffixes" {
    try std.testing.expectEqual(Key.up, keyForCursorSequence('A').?);
    try std.testing.expectEqual(Key.down, keyForCursorSequence('B').?);
    try std.testing.expectEqual(Key.right, keyForCursorSequence('C').?);
    try std.testing.expectEqual(Key.left, keyForCursorSequence('D').?);
    try std.testing.expectEqual(@as(?Key, null), keyForCursorSequence('~'));
}

test "Kitty keyboard events preserve press repeat and release" {
    const pressed = keyEventForCsi("1;1:1", 'C').?;
    try std.testing.expectEqual(Key.right, pressed.key);
    try std.testing.expectEqual(KeyState.press, pressed.state);
    const repeated = keyEventForCsi("1;1:2", 'C').?;
    try std.testing.expectEqual(KeyState.repeat, repeated.state);
    const released = keyEventForCsi("119;1:3", 'u').?;
    try std.testing.expectEqual(KeyState.release, released.state);
    try std.testing.expectEqual(Key{ .byte = 'w' }, released.key);
    try std.testing.expectEqual(KeyState.legacy, keyEventForCsi("", 'C').?.state);
    try std.testing.expect(keyEventForCsi("57358;1:1", 'u') == null);
}

test "terminal queues probe-time user input in order" {
    var session: Session = .{};
    try session.queueInput("zx");
    try std.testing.expectEqual(@as(?u8, 'z'), try session.readByte());
    try std.testing.expectEqual(@as(?u8, 'x'), try session.readByte());
}

test "terminal discards fragmented Kitty APC replies without generating Escape" {
    var session: Session = .{};
    session.apc_discarding = true;
    try session.queueInput("Gi=1");
    try std.testing.expectEqual(Event.none, try session.continueDiscardingApc(0));
    try std.testing.expect(session.apc_discarding);
    try session.queueInput(";OK\x1b\\");
    try std.testing.expectEqual(Event.none, try session.continueDiscardingApc(0));
    try std.testing.expect(!session.apc_discarding);
}

test "terminal abandons an unterminated Kitty APC reply after a bounded wait" {
    var session: Session = .{};
    session.apc_discarding = true;
    for (0..apc_discard_grace_timeouts) |_| {
        try std.testing.expectEqual(Event.none, try session.continueDiscardingApc(0));
    }
    try std.testing.expect(!session.apc_discarding);
}

test "terminal retains a fragmented escape prefix until it becomes a Kitty APC reply" {
    var session: Session = .{};
    // The initial ESC arrived in a previous read. Ghostty can deliver the
    // following underscore and APC body later than the old five-millisecond
    // look-ahead window.
    session.escape_prefix_pending = true;
    try session.queueInput("_");
    try std.testing.expectEqual(Event.none, try session.continueEscapePrefix(0));
    try std.testing.expect(session.apc_discarding);
    try session.queueInput("Gi=1;OK\x1b\\");
    try std.testing.expectEqual(Event.none, try session.continueDiscardingApc(0));
    try std.testing.expect(!session.apc_discarding);
}

test "terminal ignores an orphan terminal string terminator" {
    var session: Session = .{};
    session.escape_prefix_pending = true;
    try session.queueInput("\\");
    try std.testing.expectEqual(Event.none, try session.continueEscapePrefix(0));
}
