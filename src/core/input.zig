/// Stable, host-neutral input state shared by every emulated system. Systems
/// translate these semantic actions at their own boundary; terminal code must
/// not know a controller's serial bit order or hardware register layout.
pub const Actions = packed struct(u16) {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    primary_1: bool = false,
    primary_2: bool = false,
    primary_3: bool = false,
    primary_4: bool = false,
    select: bool = false,
    start: bool = false,
    coin: bool = false,
    pause: bool = false,
    _reserved: u4 = 0,
};

test "actions have a fixed 16-bit representation" {
    const std = @import("std");
    const actions = Actions{ .up = true, .primary_1 = true, .coin = true };
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(Actions));
    try std.testing.expectEqual(@as(u16, 0x0411), @as(u16, @bitCast(actions)));
}
