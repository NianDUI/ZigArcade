const std = @import("std");

pub const tile_width = 8;
pub const tile_height = 8;
pub const tile_bytes = 32;

/// Decodes one Neo Geo S-ROM fixed-layer 8x8 4bpp tile into palette indices.
/// Bytes are arranged as four 8-byte bitplanes: planes 0/1 first, then 2/3;
/// within each byte bit 7 is the leftmost pixel. The caller owns all ROM and
/// output buffers, so this remains safe for synthetic diagnostics.
pub fn decodeTile(tile: []const u8, indices: []u8) Error!void {
    if (tile.len != tile_bytes or indices.len != tile_width * tile_height) return error.InvalidTile;
    for (0..tile_height) |y| {
        const plane0 = tile[y];
        const plane1 = tile[8 + y];
        const plane2 = tile[16 + y];
        const plane3 = tile[24 + y];
        for (0..tile_width) |x| {
            const shift: u3 = @intCast(7 - x);
            indices[y * tile_width + x] = ((plane0 >> shift) & 1) |
                (((plane1 >> shift) & 1) << 1) |
                (((plane2 >> shift) & 1) << 2) |
                (((plane3 >> shift) & 1) << 3);
        }
    }
}

pub const Error = error{InvalidTile};

test "Neo Geo fixed tile decoder combines four bitplanes left to right" {
    var tile: [tile_bytes]u8 = [_]u8{0} ** tile_bytes;
    // Top row produces 1, 2, 4, 8, then 15 for the fifth pixel.
    tile[0] = 0x88;
    tile[8] = 0x48;
    tile[16] = 0x28;
    tile[24] = 0x18;
    var indices: [tile_width * tile_height]u8 = undefined;
    try decodeTile(&tile, &indices);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 4, 8, 15, 0, 0, 0 }, indices[0..tile_width]);
    try std.testing.expectError(error.InvalidTile, decodeTile(tile[0..31], &indices));
}
