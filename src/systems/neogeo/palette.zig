const std = @import("std");

/// Converts the RGB555 portion of a Neo Geo palette word to host RGB888.
/// Bit 15 is the hardware's dark/shadow flag and is intentionally returned
/// separately until sprite/fixed-layer compositing defines its exact use.
pub const Color = struct {
    rgb: [3]u8,
    dark: bool,
};

pub fn decodeWord(word: u16) Color {
    const red: u8 = @truncate((word >> 10) & 0x1f);
    const green: u8 = @truncate((word >> 5) & 0x1f);
    const blue: u8 = @truncate(word & 0x1f);
    return .{
        .rgb = .{ expand5(red), expand5(green), expand5(blue) },
        .dark = word & 0x8000 != 0,
    };
}

fn expand5(component: u8) u8 {
    return (component << 3) | (component >> 2);
}

test "Neo Geo palette expands RGB555 and preserves the dark flag" {
    const color = decodeWord(0xfc1f); // dark + red=31 + green=0 + blue=31
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 255 }, &color.rgb);
    try std.testing.expect(color.dark);
    try std.testing.expectEqualSlices(u8, &.{ 132, 132, 132 }, &decodeWord(0x4210).rgb);
}
