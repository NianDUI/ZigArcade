const AudioSink = @import("../core/audio.zig").AudioSink;

pub const sample_rate_hz = 44_100;

/// Keeps the command-line interface portable while making real audio an
/// explicit macOS-only capability for now.
pub const Sink = struct {
    pub const Telemetry = struct {
        received_samples: u64 = 0,
        non_silent_samples: u64 = 0,
        callback_count: u64 = 0,
        rendered_samples: u64 = 0,
        underrun_samples: u64 = 0,
        is_running: u32 = 0,
        is_running_status: i32 = -1,
        last_render_error: i32 = 0,
        last_render_error_status: i32 = -1,
    };

    pub fn init(_: *Sink) !void {
        return error.AudioOutputUnsupported;
    }

    pub fn deinit(_: *Sink) void {}

    pub fn asSink(self: *Sink) AudioSink {
        return .{ .context = self, .write_fn = write };
    }

    pub fn telemetry(_: *const Sink) Telemetry {
        return .{};
    }

    fn write(_: *anyopaque, _: u64, _: []const i16) void {}
};

test "unsupported host audio reports a clear error" {
    var sink = Sink{};
    try @import("std").testing.expectError(error.AudioOutputUnsupported, sink.init());
}
