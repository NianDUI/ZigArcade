const std = @import("std");
const input = @import("../core/input.zig");

pub const max_hold_frames: u8 = 60;
pub const controller_button_mask: u16 = 0x0fff;
pub const default_allowed_mask: u16 = 0x00ff;

const up_mask: u16 = 1 << 0;
const down_mask: u16 = 1 << 1;
const left_mask: u16 = 1 << 2;
const right_mask: u16 = 1 << 3;

pub const Policy = struct {
    allowed_mask: u16 = default_allowed_mask,
    allow_opposite_directions: bool = false,
};

/// A replacement-style P1 plan. At expiry the runner must replace `mask`
/// with zero, which makes model failures unable to leave a controller held.
pub const ActionPlan = struct {
    mask: u16,
    frames: u8,

    pub const Error = error{
        UnsupportedButtons,
        DisallowedButtons,
        OpposingHorizontalDirections,
        OpposingVerticalDirections,
        InvalidDuration,
    };

    pub fn init(mask: u16, frames: u8, policy: Policy) Error!ActionPlan {
        if (frames == 0 or frames > max_hold_frames) return error.InvalidDuration;
        if (mask & ~controller_button_mask != 0) return error.UnsupportedButtons;
        if (mask & ~policy.allowed_mask != 0) return error.DisallowedButtons;
        if (!policy.allow_opposite_directions and mask & (left_mask | right_mask) == (left_mask | right_mask)) {
            return error.OpposingHorizontalDirections;
        }
        if (!policy.allow_opposite_directions and mask & (up_mask | down_mask) == (up_mask | down_mask)) {
            return error.OpposingVerticalDirections;
        }
        return .{ .mask = mask, .frames = frames };
    }

    pub fn actions(self: ActionPlan) input.Actions {
        return @bitCast(self.mask);
    }
};

pub fn maskForActions(actions: input.Actions) u16 {
    return @bitCast(actions);
}

test "action plan preserves combined direction and primary button" {
    const plan = try ActionPlan.init(0x0018, 12, .{});
    const actions = plan.actions();
    try std.testing.expect(actions.right);
    try std.testing.expect(actions.primary_1);
    try std.testing.expect(!actions.left);
    try std.testing.expectEqual(@as(u16, 0x0018), maskForActions(actions));
}

test "action plan rejects unsafe or unauthorized masks" {
    try std.testing.expectError(error.InvalidDuration, ActionPlan.init(0x0008, 0, .{}));
    try std.testing.expectError(error.InvalidDuration, ActionPlan.init(0x0008, max_hold_frames + 1, .{}));
    try std.testing.expectError(error.OpposingHorizontalDirections, ActionPlan.init(left_mask | right_mask, 1, .{}));
    try std.testing.expectError(error.DisallowedButtons, ActionPlan.init(1 << 9, 1, .{}));
    try std.testing.expectError(error.UnsupportedButtons, ActionPlan.init(1 << 12, 1, .{ .allowed_mask = 0xffff }));
}
