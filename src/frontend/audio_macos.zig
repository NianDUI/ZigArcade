const std = @import("std");
const AudioSink = @import("../core/audio.zig").AudioSink;

// Minimal stable AudioUnit ABI. Declaring it directly avoids importing macOS
// headers that make Zig 0.16 translate unrelated Objective-C Blocks.
const AudioComponent = *opaque {};
const AudioUnit = *opaque {};

const AudioComponentDescription = extern struct {
    component_type: u32,
    component_subtype: u32,
    component_manufacturer: u32,
    component_flags: u32,
    component_flags_mask: u32,
};

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

const AudioBuffer = extern struct {
    number_channels: u32,
    data_byte_size: u32,
    data: ?*anyopaque,
};

const AudioBufferList = extern struct {
    number_buffers: u32,
    buffers: [1]AudioBuffer,
};

const RenderCallback = *const fn (
    ?*anyopaque,
    ?*anyopaque,
    ?*const anyopaque,
    u32,
    u32,
    ?*AudioBufferList,
) callconv(.c) i32;

const RenderCallbackConfig = extern struct {
    callback: RenderCallback,
    context: ?*anyopaque,
};

extern fn AudioComponentFindNext(?AudioComponent, *const AudioComponentDescription) callconv(.c) ?AudioComponent;
extern fn AudioComponentInstanceNew(AudioComponent, *AudioUnit) callconv(.c) i32;
extern fn AudioComponentInstanceDispose(AudioUnit) callconv(.c) i32;
extern fn AudioUnitSetProperty(AudioUnit, u32, u32, u32, ?*const anyopaque, u32) callconv(.c) i32;
extern fn AudioUnitGetProperty(AudioUnit, u32, u32, u32, *anyopaque, *u32) callconv(.c) i32;
extern fn AudioUnitInitialize(AudioUnit) callconv(.c) i32;
extern fn AudioUnitUninitialize(AudioUnit) callconv(.c) i32;
extern fn AudioOutputUnitStart(AudioUnit) callconv(.c) i32;
extern fn AudioOutputUnitStop(AudioUnit) callconv(.c) i32;

const linear_pcm_format = 0x6c70636d; // 'lpcm'
const linear_pcm_signed_packed = 0x04 | 0x08;
const audio_unit_type_output = 0x61756f75; // 'auou'
const audio_unit_subtype_default_output = 0x64656620; // 'def '
const audio_unit_manufacturer_apple = 0x6170706c; // 'appl'
const audio_unit_scope_global = 0;
const audio_unit_scope_input = 1;
const audio_unit_property_stream_format = 8;
const audio_unit_property_last_render_error = 22;
const audio_unit_property_set_render_callback = 23;
const audio_output_unit_property_is_running = 2001;

pub const sample_rate_hz = 44_100;
const ring_capacity = 1 << 15;
const ring_mask = ring_capacity - 1;

/// A single-producer (emulation) / single-consumer (AudioUnit render thread)
/// PCM sink. Full buffers drop their newest samples so host audio can never
/// slow the deterministic emulation clock.
pub const Sink = struct {
    samples: [ring_capacity]i16 = undefined,
    write_index: std.atomic.Value(usize) = .init(0),
    read_index: std.atomic.Value(usize) = .init(0),
    unit: ?AudioUnit = null,
    received_samples: std.atomic.Value(u64) = .init(0),
    non_silent_samples: std.atomic.Value(u64) = .init(0),
    callback_count: std.atomic.Value(u64) = .init(0),
    rendered_samples: std.atomic.Value(u64) = .init(0),
    underrun_samples: std.atomic.Value(u64) = .init(0),

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
        const component = AudioComponentFindNext(null, &.{
            .component_type = audio_unit_type_output,
            .component_subtype = audio_unit_subtype_default_output,
            .component_manufacturer = audio_unit_manufacturer_apple,
            .component_flags = 0,
            .component_flags_mask = 0,
        }) orelse return error.DefaultOutputAudioUnitNotFound;
        var unit: AudioUnit = undefined;
        if (AudioComponentInstanceNew(component, &unit) != 0) return error.AudioUnitCreateFailed;
        self.unit = unit;
        errdefer self.deinit();

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
        if (AudioUnitSetProperty(
            unit,
            audio_unit_property_stream_format,
            audio_unit_scope_input,
            0,
            &format,
            @sizeOf(AudioStreamBasicDescription),
        ) != 0) return error.AudioUnitFormatFailed;

        const callback = RenderCallbackConfig{ .callback = renderCallback, .context = self };
        if (AudioUnitSetProperty(
            unit,
            audio_unit_property_set_render_callback,
            audio_unit_scope_input,
            0,
            &callback,
            @sizeOf(RenderCallbackConfig),
        ) != 0) return error.AudioUnitCallbackFailed;
        if (AudioUnitInitialize(unit) != 0) return error.AudioUnitInitializeFailed;
        if (AudioOutputUnitStart(unit) != 0) return error.AudioUnitStartFailed;
    }

    pub fn deinit(self: *Sink) void {
        if (self.unit) |unit| {
            _ = AudioOutputUnitStop(unit);
            _ = AudioUnitUninitialize(unit);
            _ = AudioComponentInstanceDispose(unit);
            self.unit = null;
        }
    }

    pub fn asSink(self: *Sink) AudioSink {
        return .{ .context = self, .write_fn = write };
    }

    pub fn telemetry(self: *const Sink) Telemetry {
        var is_running: u32 = 0;
        var is_running_size: u32 = @sizeOf(u32);
        var last_render_error: i32 = 0;
        var last_render_error_size: u32 = @sizeOf(i32);
        const is_running_status = if (self.unit) |unit|
            AudioUnitGetProperty(unit, audio_output_unit_property_is_running, audio_unit_scope_global, 0, &is_running, &is_running_size)
        else
            -1;
        const last_render_error_status = if (self.unit) |unit|
            AudioUnitGetProperty(unit, audio_unit_property_last_render_error, audio_unit_scope_global, 0, &last_render_error, &last_render_error_size)
        else
            -1;
        return .{
            .received_samples = self.received_samples.load(.monotonic),
            .non_silent_samples = self.non_silent_samples.load(.monotonic),
            .callback_count = self.callback_count.load(.monotonic),
            .rendered_samples = self.rendered_samples.load(.monotonic),
            .underrun_samples = self.underrun_samples.load(.monotonic),
            .is_running = is_running,
            .is_running_status = is_running_status,
            .last_render_error = last_render_error,
            .last_render_error_status = last_render_error_status,
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

    fn renderCallback(
        context: ?*anyopaque,
        _: ?*anyopaque,
        _: ?*const anyopaque,
        _: u32,
        frame_count: u32,
        buffer_list: ?*AudioBufferList,
    ) callconv(.c) i32 {
        const self: *Sink = @ptrCast(@alignCast(context orelse return 0));
        const list = buffer_list orelse return 0;
        _ = self.callback_count.fetchAdd(1, .monotonic);
        const buffers: [*]AudioBuffer = @ptrCast(&list.buffers[0]);
        for (buffers[0..list.number_buffers]) |*buffer| {
            const data = buffer.data orelse continue;
            const requested_samples: usize = frame_count;
            const available_samples: usize = buffer.data_byte_size / @sizeOf(i16);
            const sample_count = @min(requested_samples, available_samples);
            const output: [*]i16 = @ptrCast(@alignCast(data));
            for (output[0..sample_count]) |*sample| {
                if (self.takeSample()) |value| {
                    sample.* = value;
                } else {
                    _ = self.underrun_samples.fetchAdd(1, .monotonic);
                    sample.* = 0;
                }
            }
            buffer.data_byte_size = @intCast(sample_count * @sizeOf(i16));
            _ = self.rendered_samples.fetchAdd(sample_count, .monotonic);
        }
        return 0;
    }
};

test "macOS audio sink buffers PCM without a device" {
    var sink = Sink{};
    sink.asSink().write(0, &.{ 100, -200 });
    try std.testing.expectEqual(@as(?i16, 100), sink.takeSample());
    try std.testing.expectEqual(@as(?i16, -200), sink.takeSample());
    try std.testing.expectEqual(@as(?i16, null), sink.takeSample());
    const telemetry = sink.telemetry();
    try std.testing.expectEqual(@as(u64, 2), telemetry.received_samples);
    try std.testing.expectEqual(@as(u64, 2), telemetry.non_silent_samples);
}
