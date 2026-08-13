const std = @import("std");
const Frame = @import("../core/frame.zig").Frame;

pub const default_width = 128;
pub const default_height = 120;
pub const default_rgb_bytes = default_width * default_height * 3;
/// Largest currently supported 2x-reduced terminal frame: a 320x240 source
/// (the Neo Geo diagnostic viewport itself is 320x224). The ANSI fallback
/// takes caller-owned scratch memory, so it may be reused for either system.
pub const max_reduced_rgb_bytes = (320 / 2) * (240 / 2) * 3;

/// Presents a tightly packed RGB frame with an ANSI upper-half block per pair
/// of pixels. The caller chooses an already scaled frame when needed.
pub fn appendFrame(writer: *std.Io.Writer, frame: Frame) !void {
    if (frame.format != .rgb888) return error.UnsupportedPixelFormat;
    if (frame.width == 0 or frame.height == 0 or frame.height % 2 != 0) return error.InvalidFrame;
    if (frame.stride != @as(u32, frame.width) * 3) return error.UnsupportedStride;
    if (frame.pixels.len != @as(usize, frame.stride) * frame.height) return error.InvalidFrame;

    try writer.writeAll("\x1b[H");
    var y: usize = 0;
    while (y < frame.height) : (y += 2) {
        var x: usize = 0;
        while (x < frame.width) : (x += 1) {
            const top = frame.pixels[y * frame.stride + x * 3 ..][0..3];
            const bottom = frame.pixels[(y + 1) * frame.stride + x * 3 ..][0..3];
            try writer.print(
                "\x1b[38;2;{d};{d};{d}m\x1b[48;2;{d};{d};{d}m▀",
                .{ top[0], top[1], top[2], bottom[0], bottom[1], bottom[2] },
            );
        }
        try writer.writeAll("\x1b[0m\r\n");
    }
}

/// Nearest-neighbour 2x reduction used by the ANSI fallback. A 256x240 NES
/// frame becomes 128x120 pixels (128x60 terminal cells), while the current
/// 320x224 Neo Geo diagnostic frame becomes 160x112 pixels (160x56 cells).
/// `pixels` belongs to the caller and may be larger than the required output,
/// making this path allocation-free with one scratch capacity for both.
pub fn downsample2x(frame: Frame, pixels: []u8) !Frame {
    if (frame.format != .rgb888) return error.UnsupportedPixelFormat;
    if (frame.width % 2 != 0 or frame.height % 2 != 0) return error.InvalidFrame;
    if (frame.stride != @as(u32, frame.width) * 3) return error.UnsupportedStride;
    if (frame.pixels.len != @as(usize, frame.stride) * frame.height) return error.InvalidFrame;
    const width = frame.width / 2;
    const height = frame.height / 2;
    const required_pixels = @as(usize, width) * height * 3;
    if (pixels.len < required_pixels) return error.InvalidFrame;

    for (0..height) |y| {
        for (0..width) |x| {
            const source = ((y * 2) * @as(usize, frame.width) + x * 2) * 3;
            const destination = (y * @as(usize, width) + x) * 3;
            @memcpy(pixels[destination..][0..3], frame.pixels[source..][0..3]);
        }
    }
    return .{
        .pixels = pixels[0..required_pixels],
        .width = width,
        .height = height,
        .stride = @as(u32, width) * 3,
        .format = .rgb888,
        .frame_number = frame.frame_number,
    };
}

test "ANSI uses upper-half blocks and homes cursor" {
    const pixels = [_]u8{ 255, 0, 0, 0, 0, 255 };
    var output: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try appendFrame(&writer, .{
        .pixels = &pixels,
        .width = 1,
        .height = 2,
        .stride = 3,
        .format = .rgb888,
        .frame_number = 0,
    });
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b[H"));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "▀") != null);
}

test "ANSI 2x downsample preserves every other source pixel and frame metadata" {
    const pixels = [_]u8{
        1,  2,  3,  4,  5,  6,
        7,  8,  9,  10, 11, 12,
        13, 14, 15, 16, 17, 18,
        19, 20, 21, 22, 23, 24,
        25, 26, 27, 28, 29, 30,
        31, 32, 33, 34, 35, 36,
        37, 38, 39, 40, 41, 42,
        43, 44, 45, 46, 47, 48,
    };
    var reduced_pixels: [2 * 2 * 3]u8 = undefined;
    const reduced = try downsample2x(.{
        .pixels = &pixels,
        .width = 4,
        .height = 4,
        .stride = 12,
        .format = .rgb888,
        .frame_number = 7,
    }, &reduced_pixels);
    try std.testing.expectEqual(@as(u16, 2), reduced.width);
    try std.testing.expectEqual(@as(u16, 2), reduced.height);
    try std.testing.expectEqual(@as(u64, 7), reduced.frame_number);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 7, 8, 9, 25, 26, 27, 31, 32, 33 }, reduced.pixels);
}

test "ANSI 2x downsample accepts the shared Neo Geo scratch capacity" {
    var source: [320 * 224 * 3]u8 = undefined;
    @memset(&source, 0);
    source[0..3].* = .{ 1, 2, 3 };
    var reduced_pixels: [max_reduced_rgb_bytes]u8 = undefined;
    const reduced = try downsample2x(.{
        .pixels = &source,
        .width = 320,
        .height = 224,
        .stride = 320 * 3,
        .format = .rgb888,
        .frame_number = 3,
    }, &reduced_pixels);
    try std.testing.expectEqual(@as(u16, 160), reduced.width);
    try std.testing.expectEqual(@as(u16, 112), reduced.height);
    try std.testing.expectEqual(@as(usize, 160 * 112 * 3), reduced.pixels.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, reduced.pixels[0..3]);
}
