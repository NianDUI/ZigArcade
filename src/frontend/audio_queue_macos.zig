const std = @import("std");
const AudioSink = @import("../core/audio.zig").AudioSink;

// Minimal C ABI for the callback-based AudioQueue API. Keep this separate
// from the production AudioUnit backend so the two paths can be compared.
const AudioQueueRef = *opaque {};

const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
};

const AudioQueueBuffer = extern struct {
    audio_data_bytes_capacity: u32,
    audio_data: *anyopaque,
    audio_data_byte_size: u32,
    user_data: ?*anyopaque,
    packet_description_capacity: u32,
    packet_descriptions: ?*anyopaque,
    packet_description_count: u32,
};
const AudioQueueBufferRef = *AudioQueueBuffer;

const OutputCallback = *const fn (?*anyopaque, AudioQueueRef, AudioQueueBufferRef) callconv(.c) void;

extern fn AudioQueueNewOutput(
    *const AudioStreamBasicDescription,
    OutputCallback,
    ?*anyopaque,
    ?*anyopaque,
    ?*anyopaque,
    u32,
    *AudioQueueRef,
) callconv(.c) i32;
extern fn AudioQueueDispose(AudioQueueRef, u8) callconv(.c) i32;
extern fn AudioQueueAllocateBuffer(AudioQueueRef, u32, *AudioQueueBufferRef) callconv(.c) i32;
extern fn AudioQueueEnqueueBuffer(AudioQueueRef, AudioQueueBufferRef, u32, ?*const anyopaque) callconv(.c) i32;
extern fn AudioQueueStart(AudioQueueRef, ?*const anyopaque) callconv(.c) i32;
extern fn AudioQueueStop(AudioQueueRef, u8) callconv(.c) i32;

const linear_pcm_format = 0x6c70636d; // 'lpcm'
const linear_pcm_signed_packed = 0x04 | 0x08;
pub const sample_rate_hz = 44_100;
const ring_capacity = 1 << 15;
const ring_mask = ring_capacity - 1;
const queue_buffer_count = 3;
const queue_buffer_samples = 1024;
const queue_buffer_bytes = queue_buffer_samples * @sizeOf(i16);

/// Experimental AudioQueue backend. It has the same SPSC handoff semantics as
/// AudioUnit, but its callback refills reusable queue-owned buffers.
pub const Sink = struct {
    samples: [ring_capacity]i16 = undefined,
    write_index: std.atomic.Value(usize) = .init(0),
    read_index: std.atomic.Value(usize) = .init(0),
    queue: ?AudioQueueRef = null,
    stopping: std.atomic.Value(bool) = .init(false),
    received_samples: std.atomic.Value(u64) = .init(0),
    non_silent_samples: std.atomic.Value(u64) = .init(0),
    callback_count: std.atomic.Value(u64) = .init(0),
    rendered_samples: std.atomic.Value(u64) = .init(0),
    underrun_samples: std.atomic.Value(u64) = .init(0),
    last_error: std.atomic.Value(i32) = .init(0),
    is_running: std.atomic.Value(u32) = .init(0),

    pub const Telemetry = struct {
        received_samples: u64,
        non_silent_samples: u64,
        callback_count: u64,
        rendered_samples: u64,
        underrun_samples: u64,
        is_running: u32,
        is_running_status: i32,
        last_render_error: i32,
        last_render_error_status: i32,
    };

    pub fn init(self: *Sink) !void {
        self.* = .{};
        const format = AudioStreamBasicDescription{
            .sample_rate = sample_rate_hz,
            .format_id = linear_pcm_format,
            .format_flags = linear_pcm_signed_packed,
            .bytes_per_packet = @sizeOf(i16),
            .frames_per_packet = 1,
            .bytes_per_frame = @sizeOf(i16),
            .channels_per_frame = 1,
            .bits_per_channel = @bitSizeOf(i16),
            .reserved = 0,
        };
        var queue: AudioQueueRef = undefined;
        if (AudioQueueNewOutput(&format, outputCallback, self, null, null, 0, &queue) != 0) return error.AudioQueueCreateFailed;
        self.queue = queue;
        errdefer self.deinit();

        for (0..queue_buffer_count) |_| {
            var buffer: AudioQueueBufferRef = undefined;
            if (AudioQueueAllocateBuffer(queue, queue_buffer_bytes, &buffer) != 0) return error.AudioQueueBufferAllocationFailed;
            self.fillBuffer(buffer);
            if (AudioQueueEnqueueBuffer(queue, buffer, 0, null) != 0) return error.AudioQueueEnqueueFailed;
        }
        if (AudioQueueStart(queue, null) != 0) return error.AudioQueueStartFailed;
        self.is_running.store(1, .release);
    }

    pub fn deinit(self: *Sink) void {
        if (self.queue) |queue| {
            self.stopping.store(true, .release);
            _ = AudioQueueStop(queue, 1);
            _ = AudioQueueDispose(queue, 1);
            self.queue = null;
            self.is_running.store(0, .release);
        }
    }

    pub fn asSink(self: *Sink) AudioSink {
        return .{ .context = self, .write_fn = write };
    }

    pub fn telemetry(self: *const Sink) Telemetry {
        return .{
            .received_samples = self.received_samples.load(.monotonic),
            .non_silent_samples = self.non_silent_samples.load(.monotonic),
            .callback_count = self.callback_count.load(.monotonic),
            .rendered_samples = self.rendered_samples.load(.monotonic),
            .underrun_samples = self.underrun_samples.load(.monotonic),
            .is_running = self.is_running.load(.acquire),
            .is_running_status = 0,
            .last_render_error = self.last_error.load(.monotonic),
            .last_render_error_status = 0,
        };
    }

    fn write(context: *anyopaque, _: u64, interleaved_pcm: []const i16) void {
        const self: *Sink = @ptrCast(@alignCast(context));
        for (interleaved_pcm) |sample| {
            _ = self.received_samples.fetchAdd(1, .monotonic);
            if (sample != 0) _ = self.non_silent_samples.fetchAdd(1, .monotonic);
            const write_index = self.write_index.load(.monotonic);
            const next_index = (write_index + 1) & ring_mask;
            if (next_index == self.read_index.load(.acquire)) continue;
            self.samples[write_index] = sample;
            self.write_index.store(next_index, .release);
        }
    }

    fn takeSample(self: *Sink) ?i16 {
        const read_index = self.read_index.load(.monotonic);
        if (read_index == self.write_index.load(.acquire)) return null;
        const sample = self.samples[read_index];
        self.read_index.store((read_index + 1) & ring_mask, .release);
        return sample;
    }

    fn fillBuffer(self: *Sink, buffer: AudioQueueBufferRef) void {
        // Every queue buffer is allocated with `queue_buffer_bytes` above.
        // Use that requested, fixed size rather than consuming a platform
        // struct field across this hand-written experimental ABI boundary.
        const capacity = queue_buffer_samples;
        const output: [*]i16 = @ptrCast(@alignCast(buffer.audio_data));
        for (output[0..capacity]) |*sample| {
            if (self.takeSample()) |value| {
                sample.* = value;
            } else {
                _ = self.underrun_samples.fetchAdd(1, .monotonic);
                sample.* = 0;
            }
        }
        buffer.audio_data_byte_size = @intCast(capacity * @sizeOf(i16));
        _ = self.rendered_samples.fetchAdd(capacity, .monotonic);
    }

    fn outputCallback(context: ?*anyopaque, queue: AudioQueueRef, buffer: AudioQueueBufferRef) callconv(.c) void {
        const self: *Sink = @ptrCast(@alignCast(context orelse return));
        _ = self.callback_count.fetchAdd(1, .monotonic);
        if (self.stopping.load(.acquire)) return;
        self.fillBuffer(buffer);
        const status = AudioQueueEnqueueBuffer(queue, buffer, 0, null);
        if (status != 0) self.last_error.store(status, .release);
    }
};

test "AudioQueue sink buffers PCM without a device" {
    var sink = Sink{};
    sink.asSink().write(0, &.{ 100, -200 });
    try std.testing.expectEqual(@as(?i16, 100), sink.takeSample());
    try std.testing.expectEqual(@as(?i16, -200), sink.takeSample());
    try std.testing.expectEqual(@as(?i16, null), sink.takeSample());
}
