const std = @import("std");
const video = @import("video.zig");

/// Synthetic fixed-layer tilemap RAM. It gives P5b a stable row-major 40x28
/// boundary while keeping real Neo Geo VRAM port/address-increment behavior
/// out of the diagnostic renderer until the hardware register map is added.
pub const FixedMap = struct {
    tiles: [video.fixed_tile_count]u16 = [_]u16{0} ** video.fixed_tile_count,

    pub fn read(self: *const FixedMap, column: usize, row: usize) ?u16 {
        if (column >= video.fixed_columns or row >= video.fixed_rows) return null;
        return self.tiles[row * video.fixed_columns + column];
    }

    pub fn write(self: *FixedMap, column: usize, row: usize, tile: u16) bool {
        if (column >= video.fixed_columns or row >= video.fixed_rows) return false;
        self.tiles[row * video.fixed_columns + column] = tile;
        return true;
    }

    pub fn asSlice(self: *const FixedMap) []const u16 {
        return &self.tiles;
    }
};

test "Neo Geo fixed map stores 40x28 row-major tile words without wraparound" {
    var map: FixedMap = .{};
    try std.testing.expect(map.write(39, 27, 0x0123));
    try std.testing.expectEqual(@as(?u16, 0x0123), map.read(39, 27));
    try std.testing.expect(!map.write(40, 0, 0xffff));
    try std.testing.expect(!map.write(0, 28, 0xffff));
    try std.testing.expectEqual(@as(?u16, null), map.read(40, 0));
    try std.testing.expectEqual(@as(usize, video.fixed_tile_count), map.asSlice().len);
}
