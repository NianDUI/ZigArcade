/// Interleaved signed 16-bit PCM emitted at an emulated CPU/master-clock
/// timestamp. Sinks must never use wall clock to alter emulation; they may
/// drop or buffer samples only according to their own presentation policy.
pub const AudioSink = struct {
    context: *anyopaque,
    write_fn: *const fn (context: *anyopaque, emulated_cycle: u64, interleaved_pcm: []const i16) void,

    pub fn write(self: AudioSink, emulated_cycle: u64, interleaved_pcm: []const i16) void {
        self.write_fn(self.context, emulated_cycle, interleaved_pcm);
    }
};

/// Default core sink: records no samples and allocates nothing. It keeps the
/// system's audio call sites deterministic before a host audio backend exists.
pub const NullAudioSink = struct {
    pub fn asSink(self: *NullAudioSink) AudioSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(_: *anyopaque, _: u64, _: []const i16) void {}
};

test "null audio sink accepts timestamped PCM without side effects" {
    var sink: NullAudioSink = .{};
    sink.asSink().write(1234, &.{ 100, -100 });
}
