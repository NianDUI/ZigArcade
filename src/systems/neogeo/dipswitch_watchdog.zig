const std = @import("std");
const address_map = @import("address_map.zig");

/// MVS REG_DIPSW read and watchdog-kick write boundary. DIP polarity and
/// configuration meaning belong to the caller, so this device exposes only
/// one raw byte and deliberately returns null until it is supplied. A write
/// is observable as a watchdog kick, but no timeout or reset period is
/// invented without a board timing contract.
pub const DipSwitchWatchdog = struct {
    dips: ?u8 = null,
    watchdog_kicks: u64 = 0,

    pub fn setDips(self: *DipSwitchWatchdog, value: u8) void {
        self.dips = value;
    }

    pub fn read(self: *const DipSwitchWatchdog, decoded: address_map.DecodedAddress) ?u8 {
        if (!isRegister(decoded)) return null;
        return self.dips;
    }

    /// REG_DIPSW writes kick the MVS watchdog; their data has no modeled
    /// meaning. The counter saturates so diagnostics can observe that at
    /// least one kick occurred without wraparound changing that fact.
    pub fn write(self: *DipSwitchWatchdog, decoded: address_map.DecodedAddress) bool {
        if (!isRegister(decoded)) return false;
        if (self.watchdog_kicks != std.math.maxInt(u64)) self.watchdog_kicks += 1;
        return true;
    }
};

fn isRegister(decoded: address_map.DecodedAddress) bool {
    return decoded.target == .dip_switch_and_watchdog and decoded.offset == 1;
}

test "Neo Geo MVS DIP register exposes only caller-supplied raw bits" {
    var device: DipSwitchWatchdog = .{};
    const decoded = address_map.decode(.mvs, 0x31ff01).?;
    try std.testing.expectEqual(@as(?u8, null), device.read(decoded));
    device.setDips(0xa5);
    try std.testing.expectEqual(@as(?u8, 0xa5), device.read(decoded));
    try std.testing.expectEqual(@as(u64, 0), device.watchdog_kicks);
}

test "Neo Geo MVS watchdog writes accept register mirrors and ignore data" {
    var device: DipSwitchWatchdog = .{};
    const mirrored = address_map.decode(.mvs, 0x31ff01).?;
    try std.testing.expect(device.write(mirrored));
    try std.testing.expect(device.write(mirrored));
    try std.testing.expectEqual(@as(u64, 2), device.watchdog_kicks);
}

test "Neo Geo MVS DIP watchdog rejects wrong target and byte lane" {
    var device: DipSwitchWatchdog = .{};
    try std.testing.expectEqual(@as(?u8, null), device.read(.{ .target = .player_1, .offset = 1 }));
    try std.testing.expect(!device.write(.{ .target = .dip_switch_and_watchdog, .offset = 0 }));
    try std.testing.expectEqual(@as(u64, 0), device.watchdog_kicks);
}
