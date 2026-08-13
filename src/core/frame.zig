pub const PixelFormat = enum { rgb888, rgba8888 };

pub const Frame = struct {
    pixels: []const u8,
    width: u16,
    height: u16,
    stride: u32,
    format: PixelFormat,
    frame_number: u64,
};

pub fn rgbBytesPerPixel(format: PixelFormat) u8 {
    return switch (format) {
        .rgb888 => 3,
        .rgba8888 => 4,
    };
}
