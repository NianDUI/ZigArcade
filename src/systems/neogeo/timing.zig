const std = @import("std");

/// A deliberately small raster clock for diagnostics. It owns scanline/VBlank
/// sequencing only; 68000/Z80 cycle ratios and raster IRQ registers are added
/// later once their board-specific behavior is locked by P5a evidence.
pub const Timing = struct {
    pub const total_scanlines = 264;
    pub const visible_scanlines = 224;
    pub const vblank_start = visible_scanlines;

    scanline: u16 = 0,
    frame_number: u64 = 0,
    vblank: bool = false,
    vblank_edge: bool = false,

    /// Advances exactly one scanline and latches the first VBlank edge until
    /// the host observes it with `takeVBlankEdge`.
    pub fn tickScanline(self: *Timing) void {
        self.vblank_edge = false;
        self.scanline += 1;
        if (self.scanline == vblank_start) {
            self.vblank = true;
            self.vblank_edge = true;
        }
        if (self.scanline == total_scanlines) {
            self.scanline = 0;
            self.frame_number += 1;
            self.vblank = false;
        }
    }

    pub fn takeVBlankEdge(self: *Timing) bool {
        const edge = self.vblank_edge;
        self.vblank_edge = false;
        return edge;
    }
};

test "Neo Geo timing enters VBlank once per 264-line frame" {
    var timing: Timing = .{};
    for (0..Timing.vblank_start - 1) |_| timing.tickScanline();
    try std.testing.expectEqual(@as(u16, Timing.vblank_start - 1), timing.scanline);
    try std.testing.expect(!timing.vblank);
    timing.tickScanline();
    try std.testing.expect(timing.vblank);
    try std.testing.expect(timing.takeVBlankEdge());
    try std.testing.expect(!timing.takeVBlankEdge());
    for (0..Timing.total_scanlines - Timing.vblank_start) |_| timing.tickScanline();
    try std.testing.expectEqual(@as(u16, 0), timing.scanline);
    try std.testing.expectEqual(@as(u64, 1), timing.frame_number);
    try std.testing.expect(!timing.vblank);
}
