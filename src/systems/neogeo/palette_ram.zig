const std = @import("std");
const palette = @import("palette.zig");

pub const color_count = 4096;

/// Synthetic 16-bit palette RAM. It stores original words so future sprite
/// and fixed-layer palette-bank addressing can share one representation;
/// callers may decode any contiguous 16-color bank without exposing RAM
/// internals to the renderer.
pub const PaletteRam = struct {
    words: [color_count]u16 = [_]u16{0} ** color_count,

    pub fn readWord(self: *const PaletteRam, index: usize) ?u16 {
        if (index >= color_count) return null;
        return self.words[index];
    }

    pub fn writeWord(self: *PaletteRam, index: usize, word: u16) bool {
        if (index >= color_count) return false;
        self.words[index] = word;
        return true;
    }

    pub fn decodeBank(self: *const PaletteRam, first: usize) ?[16]palette.Color {
        if (first > color_count - 16) return null;
        var colors: [16]palette.Color = undefined;
        for (0..colors.len) |index| colors[index] = palette.decodeWord(self.words[first + index]);
        return colors;
    }
};

test "Neo Geo palette RAM stores words and decodes a bounded 16-color bank" {
    var ram: PaletteRam = .{};
    try std.testing.expect(ram.writeWord(0, 0x7c00));
    try std.testing.expect(ram.writeWord(1, 0x03e0));
    const bank = ram.decodeBank(0).?;
    try std.testing.expectEqual(@as(?u16, 0x7c00), ram.readWord(0));
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, &bank[0].rgb);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0 }, &bank[1].rgb);
    try std.testing.expect(!ram.writeWord(color_count, 0xffff));
    try std.testing.expectEqual(@as(?u16, null), ram.readWord(color_count));
    try std.testing.expectEqual(@as(?[16]palette.Color, null), ram.decodeBank(color_count - 15));
}
