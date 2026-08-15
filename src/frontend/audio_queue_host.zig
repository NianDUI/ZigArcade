const builtin = @import("builtin");

const implementation = if (builtin.os.tag == .macos)
    @import("audio_queue_macos.zig")
else
    @import("audio_stub.zig");

pub const Sink = implementation.Sink;
pub const sample_rate_hz = implementation.sample_rate_hz;
