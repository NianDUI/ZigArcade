const std = @import("std");
const Frame = @import("../core/frame.zig").Frame;

pub const max_base64_payload = 4096;
pub const raw_chunk_bytes = 3072;
/// The largest current terminal source is the 320x240 diagnostic frame. A
/// compressed payload can be slightly larger than its RGB source, so reserve
/// a small margin and fall back to raw Kitty transmission beyond this bound.
pub const max_compressed_frame_bytes = 320 * 240 * 3 + 4096;
const compression_threshold_bytes = 64 * 1024;
pub const probe_image_id: u32 = 0x5A_4741;

pub const ProbeResult = enum { pending, supported, rejected };

/// Separates Kitty APC replies from ordinary user bytes received on the same
/// controlling TTY while a capability query is in flight. APC can be split
/// across reads; ordinary bytes are retained for the input loop rather than
/// being consumed by probing.
pub const ProbeDemux = struct {
    parser: ProbeParser = .{},
    pending: [1024]u8 = undefined,
    pending_len: usize = 0,
    input: [256]u8 = undefined,
    input_len: usize = 0,

    pub fn feed(self: *ProbeDemux, image_id: u32, bytes: []const u8) error{ ProbeOverflow, InputOverflow }!ProbeResult {
        if (bytes.len > self.pending.len - self.pending_len) return error.ProbeOverflow;
        @memcpy(self.pending[self.pending_len..][0..bytes.len], bytes);
        self.pending_len += bytes.len;

        while (true) {
            const buffered = self.pending[0..self.pending_len];
            const start = std.mem.indexOf(u8, buffered, "\x1b_G") orelse {
                if (buffered.len != 0 and buffered[buffered.len - 1] == 0x1b) {
                    try self.appendInput(buffered[0 .. buffered.len - 1]);
                    self.pending[0] = 0x1b;
                    self.pending_len = 1;
                } else {
                    try self.appendInput(buffered);
                    self.pending_len = 0;
                }
                return .pending;
            };
            if (start != 0) {
                try self.appendInput(buffered[0..start]);
                self.discardPrefix(start);
                continue;
            }
            const terminator = std.mem.indexOfPos(u8, buffered, 3, "\x1b\\") orelse return .pending;
            const apc_len = terminator + 2;
            const result = self.parser.feed(image_id, buffered[0..apc_len]);
            self.discardPrefix(apc_len);
            if (result != .pending) {
                // The response can share a read with the first user key.
                // Once our matching reply is complete, all remaining bytes
                // belong to the input layer rather than the probe parser.
                try self.appendInput(self.pending[0..self.pending_len]);
                self.pending_len = 0;
                return result;
            }
        }
    }

    pub fn takeInput(self: *ProbeDemux) []const u8 {
        defer self.input_len = 0;
        return self.input[0..self.input_len];
    }

    fn appendInput(self: *ProbeDemux, bytes: []const u8) error{InputOverflow}!void {
        if (bytes.len > self.input.len - self.input_len) return error.InputOverflow;
        @memcpy(self.input[self.input_len..][0..bytes.len], bytes);
        self.input_len += bytes.len;
    }

    fn discardPrefix(self: *ProbeDemux, len: usize) void {
        const remaining = self.pending_len - len;
        std.mem.copyForwards(u8, self.pending[0..remaining], self.pending[len..self.pending_len]);
        self.pending_len = remaining;
    }
};

pub const ProbeParser = struct {
    bytes: [1024]u8 = undefined,
    len: usize = 0,

    /// Accepts arbitrary chunks from the controlling TTY. Only a complete APC
    /// response for the requested image ID changes the result.
    pub fn feed(self: *ProbeParser, image_id: u32, input: []const u8) ProbeResult {
        const remaining = self.bytes.len - self.len;
        const copied = @min(remaining, input.len);
        @memcpy(self.bytes[self.len..][0..copied], input[0..copied]);
        self.len += copied;
        if (copied != input.len) return .rejected;

        const all = self.bytes[0..self.len];
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, all, search_start, "\x1b_G")) |start| {
            const terminator_offset = std.mem.indexOfPos(u8, all, start + 3, "\x1b\\") orelse return .pending;
            const payload = all[start + 3 .. terminator_offset];
            if (responseForImage(payload, image_id)) |result| return result;
            search_start = terminator_offset + 2;
        }
        return .pending;
    }
};

fn responseForImage(payload: []const u8, image_id: u32) ?ProbeResult {
    var expected: [24]u8 = undefined;
    const expected_id = std.fmt.bufPrint(&expected, "i={d}", .{image_id}) catch return .rejected;
    const separator = std.mem.indexOfScalar(u8, payload, ';') orelse return null;
    const params = payload[0..separator];
    if (std.mem.indexOf(u8, params, expected_id) == null) return null;
    if (std.mem.eql(u8, payload[separator + 1 ..], "OK")) return .supported;
    return .rejected;
}

pub const Options = struct {
    image_id: u32 = 1,
    placement_id: u32 = 1,
    columns: u16 = 128,
    rows: u16 = 60,
    quiet: bool = true,
};

/// Fits an image into terminal cells while retaining its pixel aspect ratio.
/// A standard terminal cell is treated as twice as tall as it is wide, which
/// makes a 256x240 NES frame occupy 128x60 cells at its native display size.
/// One row is reserved by the caller for status text.
pub fn fitOptions(frame: Frame, max_columns: u16, max_rows: u16) Options {
    if (max_columns == 0 or max_rows == 0) return .{};
    const columns_per_row = @as(u32, frame.width) * 2;
    const rows_from_width = @max(@as(u32, 1), @as(u32, max_columns) * frame.height / columns_per_row);
    const rows: u16 = @intCast(@min(@as(u32, max_rows), rows_from_width));
    const columns: u16 = @intCast(@min(
        @as(u32, max_columns),
        @max(@as(u32, 1), @as(u32, rows) * columns_per_row / frame.height),
    ));
    return .{ .columns = columns, .rows = rows };
}

/// Encodes one RGB frame as Kitty APC transmit-and-display commands. Large
/// frames use zlib because uncompressed 256x240 RGB at 30 FPS can saturate a
/// terminal's graphics queue and make the UI appear frozen. The output owns no
/// terminal state; callers must write it atomically relative to other terminal
/// escape sequences.
pub fn appendFrame(writer: *std.Io.Writer, frame: Frame, options: Options) !void {
    if (frame.format != .rgb888) return error.UnsupportedPixelFormat;
    if (frame.stride != @as(u32, frame.width) * 3) return error.UnsupportedStride;
    if (frame.pixels.len != @as(usize, frame.stride) * frame.height) return error.InvalidFrame;

    var compressed: [max_compressed_frame_bytes]u8 = undefined;
    const transmission = try compressFrame(frame, &compressed);
    var raw_offset: usize = 0;
    var first = true;
    while (raw_offset < transmission.bytes.len) {
        const raw_len = @min(raw_chunk_bytes, transmission.bytes.len - raw_offset);
        const raw = transmission.bytes[raw_offset..][0..raw_len];
        var encoded: [max_base64_payload]u8 = undefined;
        const payload = std.base64.standard.Encoder.encode(&encoded, raw);
        const more = raw_offset + raw_len < transmission.bytes.len;

        try writer.writeAll("\x1b_G");
        if (first) {
            try writer.print(
                "a=T,q={d},t=d,f=24,s={d},v={d},i={d},p={d},c={d},r={d},C=1{s},m={d};",
                .{
                    @intFromBool(options.quiet),
                    frame.width,
                    frame.height,
                    options.image_id,
                    options.placement_id,
                    options.columns,
                    options.rows,
                    if (transmission.compressed) ",o=z" else "",
                    @intFromBool(more),
                },
            );
        } else {
            try writer.print("q={d},m={d};", .{ @intFromBool(options.quiet), @intFromBool(more) });
        }
        try writer.writeAll(payload);
        try writer.writeAll("\x1b\\");

        raw_offset += raw_len;
        first = false;
    }
}

const Transmission = struct {
    bytes: []const u8,
    compressed: bool,
};

fn compressFrame(frame: Frame, storage: []u8) !Transmission {
    if (frame.pixels.len < compression_threshold_bytes or frame.pixels.len > storage.len) {
        return .{ .bytes = frame.pixels, .compressed = false };
    }

    var output: std.Io.Writer = .fixed(storage);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&output, &history, .zlib, .fastest);
    try compressor.writer.writeAll(frame.pixels);
    try compressor.finish();
    return .{ .bytes = output.buffered(), .compressed = true };
}

pub fn appendDeleteAll(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1b_Ga=d,d=A,q=1\x1b\\");
}

/// Emits a one-pixel direct-RGB query. The terminal must answer through the
/// same controlling TTY with `ESC_Gi=<id>;OK ESC\\` on success.
pub fn appendProbe(writer: *std.Io.Writer, image_id: u32) !void {
    if (image_id == 0) return error.InvalidProbeImageId;
    try writer.print("\x1b_Ga=q,q=0,t=d,f=24,s=1,v=1,i={d};AAAA\x1b\\", .{image_id});
}

test "Kitty frame splits RGB source into 3072-byte chunks" {
    const pixels = [_]u8{0x7f} ** (raw_chunk_bytes + 3);
    const frame = Frame{
        .pixels = &pixels,
        .width = 1025,
        .height = 1,
        .stride = 3075,
        .format = .rgb888,
        .frame_number = 0,
    };
    var output: [6000]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try appendFrame(&writer, frame, .{});
    const result = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, result, "m=1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "m=0;") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result, "\x1b_G"));
}

test "Kitty zlib-compresses a terminal-sized RGB frame" {
    const pixels = [_]u8{0x7f} ** (256 * 240 * 3);
    const frame = Frame{
        .pixels = &pixels,
        .width = 256,
        .height = 240,
        .stride = 256 * 3,
        .format = .rgb888,
        .frame_number = 0,
    };
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try appendFrame(&writer, frame, .{});
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "o=z") != null);
    try std.testing.expect(writer.buffered().len < 4096);
}

test "Kitty fit options preserve NES aspect ratio within terminal cells" {
    const frame = Frame{ .pixels = &.{}, .width = 256, .height = 240, .stride = 768, .format = .rgb888, .frame_number = 0 };
    const wide = fitOptions(frame, 160, 59);
    try std.testing.expectEqual(@as(u16, 125), wide.columns);
    try std.testing.expectEqual(@as(u16, 59), wide.rows);
    const narrow = fitOptions(frame, 80, 59);
    try std.testing.expectEqual(@as(u16, 78), narrow.columns);
    try std.testing.expectEqual(@as(u16, 37), narrow.rows);
}

test "Kitty rejects non-tight RGB frame" {
    const pixels = [_]u8{0} ** 6;
    var output: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try std.testing.expectError(error.UnsupportedStride, appendFrame(&writer, .{
        .pixels = &pixels,
        .width = 1,
        .height = 2,
        .stride = 4,
        .format = .rgb888,
        .frame_number = 0,
    }, .{}));
}

test "Kitty teardown deletes all terminal image data once" {
    var output: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try appendDeleteAll(&writer);
    try std.testing.expectEqualStrings("\x1b_Ga=d,d=A,q=1\x1b\\", writer.buffered());
}

test "Kitty probe accepts a fragmented matching response" {
    var parser: ProbeParser = .{};
    try std.testing.expectEqual(.pending, parser.feed(42, "keyboard\x1b_Gi=42,p=1"));
    try std.testing.expectEqual(.supported, parser.feed(42, ";OK\x1b\\"));
}

test "Kitty probe ignores a different image response" {
    var parser: ProbeParser = .{};
    try std.testing.expectEqual(.pending, parser.feed(42, "\x1b_Gi=77;OK\x1b\\"));
}

test "Kitty probe skips an unrelated APC before its response" {
    var parser: ProbeParser = .{};
    try std.testing.expectEqual(.supported, parser.feed(42, "\x1b_Gi=77;OK\x1b\\\x1b_Gi=42;OK\x1b\\"));
}

test "Kitty probe rejects a matching error response" {
    var parser: ProbeParser = .{};
    try std.testing.expectEqual(.rejected, parser.feed(42, "\x1b_Gi=42;EINVAL\x1b\\"));
}

test "Kitty probe demux preserves user input around a fragmented reply" {
    var demux: ProbeDemux = .{};
    try std.testing.expectEqual(.pending, try demux.feed(42, "w\x1b_Gi=42;O"));
    try std.testing.expectEqualStrings("w", demux.takeInput());
    try std.testing.expectEqual(.supported, try demux.feed(42, "K\x1b\\z"));
    try std.testing.expectEqualStrings("z", demux.takeInput());
}
