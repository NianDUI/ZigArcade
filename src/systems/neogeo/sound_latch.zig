const std = @import("std");

/// Minimal 68000<->Z80 sound-command boundary. The command latch has pending
/// state because the Z80 consumes it; the reply is a buffered latest value
/// that the 68000 may read repeatedly without clearing. Actual port addresses,
/// NMI gating, Z80 execution and YM2610 registers remain P5b work.
pub const SoundLatch = struct {
    command: u8 = 0,
    command_pending: bool = false,
    reply: u8 = 0,

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
    }

    /// The 68k REG_SOUND read path observes a buffered value. It must not
    /// clear the reply; Z80 port $0C owns updates to this latch.
    pub fn readReply(self: *const SoundLatch) u8 {
        return self.reply;
    }
};

test "Neo Geo sound command is consumed once while the reply remains readable" {
    var latch: SoundLatch = .{};
    try std.testing.expectEqual(@as(?u8, null), latch.takeCommand());
    latch.writeCommand(0x12);
    latch.writeCommand(0x34);
    try std.testing.expectEqual(@as(?u8, 0x34), latch.takeCommand());
    try std.testing.expectEqual(@as(?u8, null), latch.takeCommand());
    latch.writeReply(0xa5);
    try std.testing.expectEqual(@as(u8, 0xa5), latch.readReply());
    try std.testing.expectEqual(@as(u8, 0xa5), latch.readReply());
}
