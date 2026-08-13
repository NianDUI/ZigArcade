const std = @import("std");

/// NES controller bit order on $4016/$4017 reads: A, B, Select, Start, Up,
/// Down, Left, Right. Bit 0 is the only data bit exposed by this device.
pub const Buttons = packed struct(u8) {
    a: bool = false,
    b: bool = false,
    select: bool = false,
    start: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

pub const Port = struct {
    host: Buttons = .{},
    latched: u8 = 0,
    shift_count: u4 = 8,

    pub fn setHostButtons(self: *Port, buttons: Buttons) void {
        self.host = buttons;
    }

    fn latch(self: *Port) void {
        self.latched = @bitCast(self.host);
        self.shift_count = 0;
    }

    fn readLiveA(self: *const Port) u8 {
        return @intFromBool(self.host.a);
    }

    fn readLatched(self: *Port) u8 {
        if (self.shift_count >= 8) return 1;
        const result = self.latched & 1;
        self.latched = (self.latched >> 1) | 0x80;
        self.shift_count += 1;
        return result;
    }
};

pub const Controllers = struct {
    ports: [2]Port = .{ .{}, .{} },
    strobe: bool = false,

    pub fn writeStrobe(self: *Controllers, value: u8) void {
        const next_strobe = value & 1 != 0;
        if (self.strobe and !next_strobe) {
            self.ports[0].latch();
            self.ports[1].latch();
        }
        self.strobe = next_strobe;
    }

    pub fn read(self: *Controllers, port_index: u1) u8 {
        const port = &self.ports[port_index];
        return if (self.strobe) port.readLiveA() else port.readLatched();
    }
};

test "controller strobe high returns live A without shifting" {
    var controllers: Controllers = .{};
    controllers.ports[0].setHostButtons(.{ .a = true, .b = true });
    controllers.writeStrobe(1);
    try std.testing.expectEqual(@as(u8, 1), controllers.read(0));
    controllers.ports[0].setHostButtons(.{ .a = false, .b = true });
    try std.testing.expectEqual(@as(u8, 0), controllers.read(0));
    try std.testing.expectEqual(@as(u4, 8), controllers.ports[0].shift_count);
}

test "controller latches two ports then shifts eight bits and returns one" {
    var controllers: Controllers = .{};
    controllers.ports[0].setHostButtons(.{ .a = true, .select = true, .up = true, .left = true });
    controllers.ports[1].setHostButtons(.{ .b = true, .start = true, .down = true, .right = true });
    controllers.writeStrobe(1);
    controllers.writeStrobe(0);
    const expected0 = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0 };
    const expected1 = [_]u8{ 0, 1, 0, 1, 0, 1, 0, 1 };
    for (expected0, expected1) |left, right| {
        try std.testing.expectEqual(left, controllers.read(0));
        try std.testing.expectEqual(right, controllers.read(1));
    }
    try std.testing.expectEqual(@as(u8, 1), controllers.read(0));
    try std.testing.expectEqual(@as(u8, 1), controllers.read(1));
}
