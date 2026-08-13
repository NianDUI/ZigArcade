const std = @import("std");

/// Minimal 68000<->Z80 sound-command boundary. Each direction is a single
/// latest-value latch with explicit pending state; actual port addresses,
/// interrupt lines, Z80 execution and YM2610 registers remain P5b work.
pub const SoundLatch = struct {
    command: u8 = 0,
    command_pending: bool = false,
    reply: u8 = 0,
    reply_pending: bool = false,

    pub fn writeCommand(self: *SoundLatch, value: u8) void {
        self.command = value;
        self.command_pending = true;
    }

    pub fn takeCommand(self: *SoundLatch) ?u8 {
        if (!self.command_pending) return null;
        self.command_pending = false;
        return self.command;
    }

    pub fn writeReply(self: *SoundLatch, value: u8) void {
        self.reply = value;
        self.reply_pending = true;
    }

    pub fn takeReply(self: *SoundLatch) ?u8 {
        if (!self.reply_pending) return null;
        self.reply_pending = false;
        return self.reply;
    }
};

test "Neo Geo sound latch transfers each direction once and latest command wins" {
    var latch: SoundLatch = .{};
    try std.testing.expectEqual(@as(?u8, null), latch.takeCommand());
    latch.writeCommand(0x12);
    latch.writeCommand(0x34);
    try std.testing.expectEqual(@as(?u8, 0x34), latch.takeCommand());
    try std.testing.expectEqual(@as(?u8, null), latch.takeCommand());
    latch.writeReply(0xa5);
    try std.testing.expectEqual(@as(?u8, 0xa5), latch.takeReply());
    try std.testing.expectEqual(@as(?u8, null), latch.takeReply());
}
