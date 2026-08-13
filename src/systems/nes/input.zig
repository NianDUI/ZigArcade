const std = @import("std");
const Actions = @import("../../core/input.zig").Actions;
const Buttons = @import("controller.zig").Buttons;

/// Maps the portable raw-byte fallback. This deliberately represents a
/// single sampled frame because traditional terminal input has no reliable
/// key-release event. Kitty keyboard protocol can replace this at the host
/// input layer without changing controller serial behavior.
pub fn actionsForByte(byte: u8) Actions {
    return switch (byte) {
        'w', 'W' => .{ .up = true },
        's', 'S' => .{ .down = true },
        'a', 'A' => .{ .left = true },
        'd', 'D' => .{ .right = true },
        'z', 'Z' => .{ .primary_1 = true },
        'x', 'X' => .{ .primary_2 = true },
        '\r', '\n' => .{ .start = true },
        '\t' => .{ .select = true },
        else => .{},
    };
}

/// NES is intentionally the only place that knows how stable public actions
/// map onto its A/B/Select/Start serial controller bits.
pub fn buttonsFromActions(actions: Actions) Buttons {
    return .{
        .a = actions.primary_1,
        .b = actions.primary_2,
        .select = actions.select,
        .start = actions.start,
        .up = actions.up,
        .down = actions.down,
        .left = actions.left,
        .right = actions.right,
    };
}

test "raw terminal keys map to stable actions then NES buttons" {
    try std.testing.expect(actionsForByte('w').up);
    try std.testing.expect(actionsForByte('D').right);
    try std.testing.expect(actionsForByte('z').primary_1);
    try std.testing.expect(actionsForByte('X').primary_2);
    try std.testing.expect(actionsForByte('\r').start);
    try std.testing.expect(actionsForByte('\t').select);
    try std.testing.expect(!actionsForByte('q').primary_1);

    const buttons = buttonsFromActions(.{ .up = true, .primary_1 = true, .primary_3 = true });
    try std.testing.expect(buttons.up);
    try std.testing.expect(buttons.a);
    try std.testing.expect(!buttons.b);
}
