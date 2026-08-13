const std = @import("std");
const Actions = @import("../../core/input.zig").Actions;

/// Neo Geo controller semantics at the system boundary. Physical input-port
/// addresses and active-low bus encoding are deliberately deferred to P5a;
/// this mapping prevents frontends from learning Neo Geo-specific buttons.
pub const Buttons = packed struct(u16) {
    a: bool = false,
    b: bool = false,
    c: bool = false,
    d: bool = false,
    start: bool = false,
    coin: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    _reserved: u6 = 0,
};

pub fn buttonsFromActions(actions: Actions) Buttons {
    return .{
        .a = actions.primary_1,
        .b = actions.primary_2,
        .c = actions.primary_3,
        .d = actions.primary_4,
        .start = actions.start,
        .coin = actions.coin,
        .up = actions.up,
        .down = actions.down,
        .left = actions.left,
        .right = actions.right,
    };
}

test "Neo Geo maps all four public primary actions plus start and coin" {
    const buttons = buttonsFromActions(.{
        .primary_1 = true,
        .primary_2 = true,
        .primary_3 = true,
        .primary_4 = true,
        .start = true,
        .coin = true,
        .left = true,
    });
    try std.testing.expect(buttons.a and buttons.b and buttons.c and buttons.d);
    try std.testing.expect(buttons.start and buttons.coin and buttons.left);
    try std.testing.expect(!buttons.right);
}
