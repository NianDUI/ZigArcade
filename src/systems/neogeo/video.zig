const std = @import("std");
const Frame = @import("../../core/frame.zig").Frame;
const fixed = @import("fixed.zig");
const palette = @import("palette.zig");

pub const frame_width = 320;
pub const frame_height = 224;
pub const frame_rgb_bytes = frame_width * frame_height * 3;
pub const fixed_columns = frame_width / fixed.tile_width;
pub const fixed_rows = frame_height / fixed.tile_height;
pub const fixed_tile_count = fixed_columns * fixed_rows;

/// Renders a synthetic fixed-layer diagnostic by repeatedly tiling one 8x8
/// S-ROM-format tile over the full Neo Geo viewport. This has no tilemap,
/// scroll, sprite, or palette-RAM assumptions; its only job is to lock the
/// `320x224 RGB888` handoff contract shared with terminal frontends.
pub fn renderRepeatedFixedTile(tile: []const u8, colors: [16]palette.Color, rgb: []u8) Error!Frame {
    if (rgb.len != frame_rgb_bytes) return error.InvalidFrameBuffer;
    var indices: [fixed.tile_width * fixed.tile_height]u8 = undefined;
    try fixed.decodeTile(tile, &indices);
    for (0..frame_height) |y| {
        for (0..frame_width) |x| {
            const index = indices[(y % fixed.tile_height) * fixed.tile_width + x % fixed.tile_width];
            const offset = (y * frame_width + x) * 3;
            rgb[offset..][0..3].* = colors[index].rgb;
        }
    }
    return .{
        .pixels = rgb,
        .width = frame_width,
        .height = frame_height,
        .stride = frame_width * 3,
        .format = .rgb888,
        .frame_number = 0,
    };
}

/// Renders a caller-provided 40x28 fixed-layer tile grid. `tiles` is a
/// contiguous S-ROM-format tile store and `tilemap` is row-major; palette
/// selection, scrolling, VRAM addressing, and real S-ROM loading remain
/// outside this pure diagnostic function.
pub fn renderFixedGrid(tiles: []const u8, tilemap: []const u16, colors: [16]palette.Color, rgb: []u8) Error!Frame {
    if (rgb.len != frame_rgb_bytes) return error.InvalidFrameBuffer;
    if (tiles.len == 0 or tiles.len % fixed.tile_bytes != 0) return error.InvalidTileStore;
    if (tilemap.len != fixed_tile_count) return error.InvalidTileMap;
    const tile_count = tiles.len / fixed.tile_bytes;

    var indices: [fixed.tile_width * fixed.tile_height]u8 = undefined;
    for (0..fixed_rows) |tile_y| {
        for (0..fixed_columns) |tile_x| {
            const tile_index = tilemap[tile_y * fixed_columns + tile_x];
            if (tile_index >= tile_count) return error.InvalidTileMap;
            const tile_offset = @as(usize, tile_index) * fixed.tile_bytes;
            try fixed.decodeTile(tiles[tile_offset..][0..fixed.tile_bytes], &indices);
            for (0..fixed.tile_height) |pixel_y| {
                for (0..fixed.tile_width) |pixel_x| {
                    const index = indices[pixel_y * fixed.tile_width + pixel_x];
                    const x = tile_x * fixed.tile_width + pixel_x;
                    const y = tile_y * fixed.tile_height + pixel_y;
                    const offset = (y * frame_width + x) * 3;
                    rgb[offset..][0..3].* = colors[index].rgb;
                }
            }
        }
    }
    return .{
        .pixels = rgb,
        .width = frame_width,
        .height = frame_height,
        .stride = frame_width * 3,
        .format = .rgb888,
        .frame_number = 0,
    };
}

pub const Error = fixed.Error || error{
    InvalidFrameBuffer,
    InvalidTileStore,
    InvalidTileMap,
};

test "Neo Geo fixed diagnostic renderer produces a 320x224 RGB frame" {
    var tile: [fixed.tile_bytes]u8 = [_]u8{0} ** fixed.tile_bytes;
    tile[0] = 0x80; // pixel 0 of each first row: color index 1
    var colors: [16]palette.Color = [_]palette.Color{.{ .rgb = .{ 0, 0, 0 }, .dark = false }} ** 16;
    colors[1] = .{ .rgb = .{ 12, 34, 56 }, .dark = false };
    var rgb: [frame_rgb_bytes]u8 = undefined;
    const frame = try renderRepeatedFixedTile(&tile, colors, &rgb);
    try std.testing.expectEqual(@as(u16, frame_width), frame.width);
    try std.testing.expectEqual(@as(u16, frame_height), frame.height);
    try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56 }, frame.pixels[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, frame.pixels[3..6]);
    try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56 }, frame.pixels[(8 * frame_width * 3)..][0..3]);
}

test "Neo Geo fixed grid renders row-major tiles and rejects invalid map data" {
    var tiles: [2 * fixed.tile_bytes]u8 = [_]u8{0} ** (2 * fixed.tile_bytes);
    @memset(tiles[0..8], 0xff); // tile 0: solid palette index 1
    @memset(tiles[fixed.tile_bytes .. fixed.tile_bytes + 8], 0xff);
    @memset(tiles[fixed.tile_bytes + 8 .. fixed.tile_bytes + 16], 0xff); // tile 1: index 3
    var tilemap: [fixed_tile_count]u16 = [_]u16{0} ** fixed_tile_count;
    tilemap[1] = 1;
    tilemap[fixed_columns] = 1;
    var colors: [16]palette.Color = [_]palette.Color{.{ .rgb = .{ 0, 0, 0 }, .dark = false }} ** 16;
    colors[1] = .{ .rgb = .{ 1, 2, 3 }, .dark = false };
    colors[3] = .{ .rgb = .{ 4, 5, 6 }, .dark = false };
    var rgb: [frame_rgb_bytes]u8 = undefined;
    const frame = try renderFixedGrid(&tiles, &tilemap, colors, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, frame.pixels[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, frame.pixels[8 * 3 ..][0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, frame.pixels[(8 * frame_width * 3)..][0..3]);
    try std.testing.expectEqual(@as(u64, 5149001596224924360), std.hash.Wyhash.hash(0, frame.pixels));

    tilemap[0] = 2;
    try std.testing.expectError(error.InvalidTileMap, renderFixedGrid(&tiles, &tilemap, colors, &rgb));
    try std.testing.expectError(error.InvalidTileStore, renderFixedGrid(tiles[0..31], &tilemap, colors, &rgb));
}
