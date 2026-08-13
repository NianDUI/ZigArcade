const std = @import("std");
const address_map = @import("address_map.zig");
const Buttons = @import("input.zig").Buttons;
const SoundLatch = @import("sound_latch.zig").SoundLatch;

/// Side-effect boundary for the confirmed cartridge I/O subset. It accepts a
/// decoded address rather than raw 68000 addresses so address mirroring and
/// byte-lane selection remain the sole responsibility of address_map.zig. This is not a complete
/// Neo Geo bus: DIP, watchdog, system-control and LSPC registers intentionally
/// remain unsupported until their own state and timing contracts are modeled.
pub const CartridgeIo = struct {
    variant: address_map.CartridgeVariant,
    players: [2]Buttons = .{ .{}, .{} },
    system_buttons: SystemButtons = .{},
    sound: SoundLatch = .{},
    /// The MVS upper status nibble includes board/peripheral state that is not
    /// modeled yet. A future MVS board device supplies these raw bits; it is
    /// deliberately not guessed from frontend input.
    mvs_system_upper: u4 = 0,

    pub fn init(variant: address_map.CartridgeVariant) CartridgeIo {
        return .{ .variant = variant };
    }

    pub fn setPlayerButtons(self: *CartridgeIo, player: usize, buttons: Buttons) bool {
        if (player >= self.players.len) return false;
        self.players[player] = buttons;
        return true;
    }

    /// REG_STATUS_B carries start/select rather than coin switches. It stays
    /// separate from `Buttons` because the public host action ABI has only one
    /// system-level select bit today; assigning it to either player here would
    /// silently invent multiplayer frontend semantics.
    pub fn setSystemButtons(self: *CartridgeIo, buttons: SystemButtons) void {
        self.system_buttons = buttons;
    }

    pub fn read(self: *const CartridgeIo, decoded: address_map.DecodedAddress) ?u8 {
        if (decoded.offset != 0) return null;
        return switch (decoded.target) {
            .player_1 => encodePlayer(self.players[0]),
            .player_2 => encodePlayer(self.players[1]),
            .sound => self.sound.readReply(),
            .system => self.encodeSystemStatus(),
            else => null,
        };
    }

    /// Only REG_SOUND is implemented in this device slice. The command is
    /// latched for the Z80-facing consumer; interrupt delivery is not implied.
    pub fn write(self: *CartridgeIo, decoded: address_map.DecodedAddress, value: u8) bool {
        if (decoded.offset != 0) return false;
        switch (decoded.target) {
            .sound => self.sound.writeCommand(value),
            else => return false,
        }
        return true;
    }

    pub fn takeSoundCommand(self: *CartridgeIo) ?u8 {
        return self.sound.takeCommand();
    }

    pub fn writeSoundReply(self: *CartridgeIo, value: u8) void {
        self.sound.writeReply(value);
    }

    fn encodeSystemStatus(self: *const CartridgeIo) u8 {
        var value: u8 = switch (self.variant) {
            .aes => 0x00,
            .mvs => @as(u8, self.mvs_system_upper) << 4,
        };
        if (!self.system_buttons.p1_start) value |= 1 << 0;
        if (!self.system_buttons.p1_select) value |= 1 << 1;
        if (!self.system_buttons.p2_start) value |= 1 << 2;
        if (!self.system_buttons.p2_select) value |= 1 << 3;
        return value;
    }
};

pub const SystemButtons = packed struct(u8) {
    p1_start: bool = false,
    p1_select: bool = false,
    p2_start: bool = false,
    p2_select: bool = false,
    _reserved: u4 = 0,
};

/// REG_P1CNT/REG_P2CNT order is U,D,L,R,A,B,C,D from bit 0 to bit 7 and the
/// physical inputs are active-low.
fn encodePlayer(buttons: Buttons) u8 {
    var value: u8 = 0xff;
    if (buttons.up) value &= ~@as(u8, 1 << 0);
    if (buttons.down) value &= ~@as(u8, 1 << 1);
    if (buttons.left) value &= ~@as(u8, 1 << 2);
    if (buttons.right) value &= ~@as(u8, 1 << 3);
    if (buttons.a) value &= ~@as(u8, 1 << 4);
    if (buttons.b) value &= ~@as(u8, 1 << 5);
    if (buttons.c) value &= ~@as(u8, 1 << 6);
    if (buttons.d) value &= ~@as(u8, 1 << 7);
    return value;
}

test "Neo Geo cartridge I/O encodes both player ports as active-low" {
    var io = CartridgeIo.init(.aes);
    try std.testing.expect(io.setPlayerButtons(0, .{ .up = true, .left = true, .a = true, .d = true }));
    try std.testing.expect(io.setPlayerButtons(1, .{ .down = true, .right = true, .b = true, .c = true }));
    try std.testing.expectEqual(@as(?u8, 0x6a), io.read(.{ .target = .player_1, .offset = 0 }));
    try std.testing.expectEqual(@as(?u8, 0x95), io.read(.{ .target = .player_2, .offset = 0 }));
    try std.testing.expect(!io.setPlayerButtons(2, .{}));
}

test "Neo Geo cartridge I/O maps start and select into variant-safe system status" {
    var aes = CartridgeIo.init(.aes);
    aes.setSystemButtons(.{ .p1_start = true, .p1_select = true, .p2_start = true });
    try std.testing.expectEqual(@as(?u8, 0x08), aes.read(.{ .target = .system, .offset = 0 }));

    var mvs = CartridgeIo.init(.mvs);
    mvs.mvs_system_upper = 0xa;
    mvs.setSystemButtons(.{ .p2_select = true });
    try std.testing.expectEqual(@as(?u8, 0xa7), mvs.read(.{ .target = .system, .offset = 0 }));
}

test "Neo Geo cartridge I/O connects REG_SOUND without inventing other writes" {
    var io = CartridgeIo.init(.mvs);
    try std.testing.expect(io.write(.{ .target = .sound, .offset = 0 }, 0x42));
    try std.testing.expectEqual(@as(?u8, 0x42), io.takeSoundCommand());
    io.writeSoundReply(0xa5);
    try std.testing.expectEqual(@as(?u8, 0xa5), io.read(.{ .target = .sound, .offset = 0 }));
    try std.testing.expectEqual(@as(?u8, 0xa5), io.read(.{ .target = .sound, .offset = 0 }));
    try std.testing.expectEqual(@as(?u8, null), io.read(.{ .target = .sound, .offset = 1 }));
    try std.testing.expect(!io.write(.{ .target = .sound, .offset = 1 }, 0x99));
    try std.testing.expectEqual(@as(?u8, null), io.takeSoundCommand());
    try std.testing.expect(!io.write(.{ .target = .video, .offset = 0 }, 0));
    try std.testing.expectEqual(@as(?u8, null), io.read(.{ .target = .palette, .offset = 0 }));
}
