const std = @import("std");
const AudioSink = @import("../../core/audio.zig").AudioSink;
const NullAudioSink = @import("../../core/audio.zig").NullAudioSink;

pub const cpu_clock_hz = 1_789_773;
pub const sample_rate_hz = 44_100;

const length_table = [_]u8{
    10, 254, 20, 2,  40, 4,  80, 6,  160, 8,  60, 10, 14, 12, 26, 14,
    12, 16,  24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30,
};

/// RP2A03 APU's initial pulse-1/frame-counter slice. It produces a
/// deterministic mono PCM stream at 44.1 kHz in emulated CPU-cycle time;
/// additional channels and nonlinear NES mixing are deliberately deferred.
pub const Apu = struct {
    sink: AudioSink,
    registers: [0x14]u8 = [_]u8{0} ** 0x14, // $4000-$4013
    channel_enable: u8 = 0, // last value written to $4015
    cpu_cycles: u64 = 0,
    frame_counter_cycles: u16 = 0,
    frame_mode_5_step: bool = false,
    frame_irq_inhibit: bool = false,
    frame_irq: bool = false,
    pulse1_divider: u16 = 0,
    pulse1_step: u3 = 0,
    pulse_clock_phase: bool = false,
    pulse1_length: u8 = 0,
    sample_phase: u32 = 0,

    pub fn init(sink: AudioSink) Apu {
        return .{ .sink = sink };
    }

    /// Handles APU-owned CPU register writes. `$4014` DMA and `$4016`
    /// controller strobe are intentionally excluded by the CPU bus router.
    pub fn cpuWrite(self: *Apu, address: u16, value: u8) bool {
        if (address >= 0x4000 and address <= 0x4013) {
            self.registers[address - 0x4000] = value;
            if (address == 0x4002 or address == 0x4003) self.reloadPulse1Timer();
            if (address == 0x4003 and self.channel_enable & 1 != 0) {
                self.pulse1_length = length_table[value >> 3];
            }
            return true;
        }
        switch (address) {
            0x4015 => {
                self.channel_enable = value & 0x1f;
                if (self.channel_enable & 1 == 0) {
                    self.pulse1_step = 0;
                    self.pulse1_length = 0;
                }
                return true;
            },
            0x4017 => {
                self.frame_mode_5_step = value & 0x80 != 0;
                self.frame_irq_inhibit = value & 0x40 != 0;
                if (self.frame_irq_inhibit) self.frame_irq = false;
                self.frame_counter_cycles = 0;
                return true;
            },
            else => return false,
        }
    }

    /// `$4015` exposes pulse-1 length status and acknowledges the
    /// frame-counter IRQ. Other channel/DMC status bits remain zero.
    pub fn cpuRead(self: *Apu, address: u16) ?u8 {
        if (address != 0x4015) return null;
        const value: u8 = @as(u8, @intFromBool(self.pulse1_length != 0)) |
            (@as(u8, @intFromBool(self.frame_irq)) << 6);
        self.frame_irq = false;
        return value;
    }

    /// Advances exactly one APU tick per CPU cycle. The 4-step sequence makes
    /// its IRQ observable at its terminal quarter-frame interval; five-step
    /// mode omits that IRQ. Sequencer envelopes/lengths are added later.
    pub fn tick(self: *Apu, cycles: u16) void {
        for (0..cycles) |_| {
            self.cpu_cycles += 1;
            self.frame_counter_cycles += 1;
            if (self.frame_counter_cycles == 14915) {
                if (!self.frame_mode_5_step and !self.frame_irq_inhibit) self.frame_irq = true;
                self.frame_counter_cycles = 0;
            }
            if (self.frame_counter_cycles == 7457) self.clockLengthCounters();
            self.tickPulse1();
            self.sample_phase += sample_rate_hz;
            if (self.sample_phase >= cpu_clock_hz) {
                self.sample_phase -= cpu_clock_hz;
                const sample = [_]i16{self.pulse1Sample()};
                self.sink.write(self.cpu_cycles, &sample);
            }
        }
    }

    pub fn frameIrqPending(self: *const Apu) bool {
        return self.frame_irq;
    }

    fn pulse1TimerPeriod(self: *const Apu) u16 {
        return @as(u16, self.registers[2]) | (@as(u16, self.registers[3] & 0x07) << 8);
    }

    fn reloadPulse1Timer(self: *Apu) void {
        self.pulse1_divider = self.pulse1TimerPeriod();
    }

    fn tickPulse1(self: *Apu) void {
        self.pulse_clock_phase = !self.pulse_clock_phase;
        if (!self.pulse_clock_phase) return;
        if (self.pulse1_divider == 0) {
            self.reloadPulse1Timer();
            self.pulse1_step +%= 1;
        } else {
            self.pulse1_divider -= 1;
        }
    }

    fn pulse1Sample(self: *const Apu) i16 {
        if (self.channel_enable & 1 == 0 or self.pulse1_length == 0 or self.pulse1TimerPeriod() < 8) return 0;
        const duty = (self.registers[0] >> 6) & 3;
        const high = pulseHigh(duty, self.pulse1_step);
        const amplitude = @as(i16, self.registers[0] & 0x0f) * 2048;
        return if (high) amplitude else -amplitude;
    }

    fn clockLengthCounters(self: *Apu) void {
        if (self.pulse1_length != 0 and self.registers[0] & 0x20 == 0) self.pulse1_length -= 1;
    }
};

fn pulseHigh(duty: u8, step: u3) bool {
    const sequences = [_]u8{ 0b01000000, 0b01100000, 0b01111000, 0b10011111 };
    return sequences[duty] & (@as(u8, 0x80) >> step) != 0;
}

test "APU stores CPU-visible registers and reports frame IRQ through $4015" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    try std.testing.expect(apu.cpuWrite(0x4000, 0x3f));
    try std.testing.expect(apu.cpuWrite(0x4015, 0x1f));
    try std.testing.expectEqual(@as(u8, 0x3f), apu.registers[0]);
    try std.testing.expectEqual(@as(u8, 0x1f), apu.channel_enable);
    try std.testing.expect(!apu.cpuWrite(0x4014, 0));

    apu.tick(14915);
    try std.testing.expect(apu.frameIrqPending());
    try std.testing.expectEqual(@as(?u8, 0x40), apu.cpuRead(0x4015));
    try std.testing.expect(!apu.frameIrqPending());
}

test "APU five-step mode and IRQ inhibit suppress frame IRQ" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x4017, 0x80);
    apu.tick(14915);
    try std.testing.expect(!apu.frameIrqPending());

    _ = apu.cpuWrite(0x4017, 0x00);
    apu.tick(14915);
    try std.testing.expect(apu.frameIrqPending());
    _ = apu.cpuWrite(0x4017, 0x40);
    try std.testing.expect(!apu.frameIrqPending());
}

test "APU pulse-1 length reloads on $4003 and appears in $4015 status" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x4015, 1);
    _ = apu.cpuWrite(0x4003, 0xf8); // length-table index 31 -> 30
    try std.testing.expectEqual(@as(u8, 30), apu.pulse1_length);
    try std.testing.expectEqual(@as(?u8, 0x01), apu.cpuRead(0x4015));

    apu.frame_counter_cycles = 7456;
    apu.tick(1);
    try std.testing.expectEqual(@as(u8, 29), apu.pulse1_length);
    _ = apu.cpuWrite(0x4015, 0);
    try std.testing.expectEqual(@as(?u8, 0), apu.cpuRead(0x4015));
}

test "APU pulse 1 emits timestamped PCM at the fixed sample rate" {
    var capture: TestCapture = .{};
    var apu = Apu.init(.{ .context = &capture, .write_fn = TestCapture.write });
    _ = apu.cpuWrite(0x4000, 0xdf); // 25% duty, constant volume 15
    _ = apu.cpuWrite(0x4002, 8);
    _ = apu.cpuWrite(0x4015, 1);
    _ = apu.cpuWrite(0x4003, 0xf8);
    apu.tick(@as(u16, @intCast(cpu_clock_hz / 100))); // approximately 10 ms
    try std.testing.expectEqual(@as(usize, 440), capture.count);
    try std.testing.expect(capture.last_cycle > 0);
    try std.testing.expect(capture.first_sample != 0);
}

const TestCapture = struct {
    count: usize = 0,
    last_cycle: u64 = 0,
    first_sample: i16 = 0,

    fn write(context: *anyopaque, cycle: u64, samples: []const i16) void {
        const self: *TestCapture = @ptrCast(@alignCast(context));
        self.count += samples.len;
        self.last_cycle = cycle;
        if (self.count == samples.len) self.first_sample = samples[0];
    }
};
