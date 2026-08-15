const std = @import("std");
const AudioSink = @import("../../core/audio.zig").AudioSink;
const NullAudioSink = @import("../../core/audio.zig").NullAudioSink;

pub const cpu_clock_hz = 1_789_773;
pub const sample_rate_hz = 44_100;

const length_table = [_]u8{
    10, 254, 20, 2,  40, 4,  80, 6,  160, 8,  60, 10, 14, 12, 26, 14,
    12, 16,  24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30,
};
const noise_period_table = [_]u16{ 4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068 };

/// RP2A03 APU slice. It produces deterministic mono PCM at 44.1 kHz in
/// emulated CPU-cycle time. The pulse channels share their half-rate timer
/// clock while triangle advances once per CPU cycle; noise and DMC follow.
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
    pulse2_divider: u16 = 0,
    pulse2_step: u3 = 0,
    pulse2_length: u8 = 0,
    triangle_divider: u16 = 0,
    triangle_step: u5 = 0,
    triangle_length: u8 = 0,
    triangle_linear_counter: u8 = 0,
    triangle_linear_reload: bool = false,
    noise_divider: u16 = 0,
    noise_shift: u15 = 1,
    noise_length: u8 = 0,
    sample_phase: u32 = 0,

    pub fn init(sink: AudioSink) Apu {
        return .{ .sink = sink };
    }

    /// Handles APU-owned CPU register writes. `$4014` DMA and `$4016`
    /// controller strobe are intentionally excluded by the CPU bus router.
    pub fn cpuWrite(self: *Apu, address: u16, value: u8) bool {
        if (address >= 0x4000 and address <= 0x4013) {
            self.registers[address - 0x4000] = value;
            if (address == 0x4002 or address == 0x4003) self.reloadPulseTimer(.one);
            if (address == 0x4006 or address == 0x4007) self.reloadPulseTimer(.two);
            if (address == 0x400a or address == 0x400b) self.reloadTriangleTimer();
            if (address == 0x400e) self.reloadNoiseTimer();
            if (address == 0x4003 and self.channel_enable & 1 != 0) {
                self.pulse1_length = length_table[value >> 3];
            }
            if (address == 0x4007 and self.channel_enable & 2 != 0) {
                self.pulse2_length = length_table[value >> 3];
            }
            if (address == 0x400b) {
                if (self.channel_enable & 4 != 0) self.triangle_length = length_table[value >> 3];
                self.triangle_linear_reload = true;
            }
            if (address == 0x400f and self.channel_enable & 8 != 0) self.noise_length = length_table[value >> 3];
            return true;
        }
        switch (address) {
            0x4015 => {
                self.channel_enable = value & 0x1f;
                if (self.channel_enable & 1 == 0) {
                    self.pulse1_step = 0;
                    self.pulse1_length = 0;
                }
                if (self.channel_enable & 2 == 0) {
                    self.pulse2_step = 0;
                    self.pulse2_length = 0;
                }
                if (self.channel_enable & 4 == 0) {
                    self.triangle_step = 0;
                    self.triangle_length = 0;
                    self.triangle_linear_counter = 0;
                }
                if (self.channel_enable & 8 == 0) self.noise_length = 0;
                return true;
            },
            0x4017 => {
                self.frame_mode_5_step = value & 0x80 != 0;
                self.frame_irq_inhibit = value & 0x40 != 0;
                if (self.frame_irq_inhibit) self.frame_irq = false;
                self.frame_counter_cycles = 0;
                if (self.frame_mode_5_step) {
                    self.clockTriangleLinearCounter();
                    self.clockLengthCounters();
                }
                return true;
            },
            else => return false,
        }
    }

    /// `$4015` exposes active pulse lengths and acknowledges frame IRQ.
    pub fn cpuRead(self: *Apu, address: u16) ?u8 {
        if (address != 0x4015) return null;
        const value: u8 = @as(u8, @intFromBool(self.pulse1_length != 0)) |
            (@as(u8, @intFromBool(self.pulse2_length != 0)) << 1) |
            (@as(u8, @intFromBool(self.triangle_length != 0)) << 2) |
            (@as(u8, @intFromBool(self.noise_length != 0)) << 3) |
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
            self.clockFrameSequencer();
            self.tickPulses();
            self.tickTriangle();
            self.tickNoise();
            self.sample_phase += sample_rate_hz;
            if (self.sample_phase >= cpu_clock_hz) {
                self.sample_phase -= cpu_clock_hz;
                const sample = [_]i16{self.mixedSample()};
                self.sink.write(self.cpu_cycles, &sample);
            }
        }
    }

    pub fn frameIrqPending(self: *const Apu) bool {
        return self.frame_irq;
    }

    fn clockFrameSequencer(self: *Apu) void {
        const cycle = self.frame_counter_cycles;
        if (cycle == 3729 or cycle == 11186) self.clockTriangleLinearCounter();
        if (cycle == 7457) {
            self.clockTriangleLinearCounter();
            self.clockLengthCounters();
        }
        if (!self.frame_mode_5_step and cycle == 14915) {
            self.clockTriangleLinearCounter();
            self.clockLengthCounters();
            if (!self.frame_irq_inhibit) self.frame_irq = true;
            self.frame_counter_cycles = 0;
        } else if (self.frame_mode_5_step and cycle == 18641) {
            self.clockTriangleLinearCounter();
            self.clockLengthCounters();
            self.frame_counter_cycles = 0;
        }
    }

    const Pulse = enum { one, two };

    fn pulseTimerPeriod(self: *const Apu, pulse: Pulse) u16 {
        const offset: usize = if (pulse == .one) 0 else 4;
        return @as(u16, self.registers[offset + 2]) | (@as(u16, self.registers[offset + 3] & 0x07) << 8);
    }

    fn reloadPulseTimer(self: *Apu, pulse: Pulse) void {
        switch (pulse) {
            .one => self.pulse1_divider = self.pulseTimerPeriod(.one),
            .two => self.pulse2_divider = self.pulseTimerPeriod(.two),
        }
    }

    fn tickPulses(self: *Apu) void {
        self.pulse_clock_phase = !self.pulse_clock_phase;
        if (!self.pulse_clock_phase) return;
        self.tickPulse(.one);
        self.tickPulse(.two);
    }

    fn tickPulse(self: *Apu, pulse: Pulse) void {
        const divider = switch (pulse) {
            .one => &self.pulse1_divider,
            .two => &self.pulse2_divider,
        };
        if (divider.* == 0) {
            self.reloadPulseTimer(pulse);
            switch (pulse) {
                .one => self.pulse1_step +%= 1,
                .two => self.pulse2_step +%= 1,
            }
        } else divider.* -= 1;
    }

    fn pulseSample(self: *const Apu, pulse: Pulse) i16 {
        const offset: usize = if (pulse == .one) 0 else 4;
        const enable_mask: u8 = if (pulse == .one) 1 else 2;
        const length = if (pulse == .one) self.pulse1_length else self.pulse2_length;
        const step = if (pulse == .one) self.pulse1_step else self.pulse2_step;
        if (self.channel_enable & enable_mask == 0 or length == 0 or self.pulseTimerPeriod(pulse) < 8) return 0;
        const duty = (self.registers[offset] >> 6) & 3;
        const high = pulseHigh(duty, step);
        const amplitude = @as(i16, self.registers[offset] & 0x0f) * 2048;
        return if (high) amplitude else -amplitude;
    }

    fn mixedPulseSample(self: *const Apu) i16 {
        const mixed: i32 = @as(i32, self.pulseSample(.one)) + self.pulseSample(.two);
        return @intCast(std.math.clamp(mixed, @as(i32, std.math.minInt(i16)), @as(i32, std.math.maxInt(i16))));
    }

    fn reloadTriangleTimer(self: *Apu) void {
        self.triangle_divider = self.triangleTimerPeriod();
    }

    fn triangleTimerPeriod(self: *const Apu) u16 {
        return @as(u16, self.registers[10]) | (@as(u16, self.registers[11] & 0x07) << 8);
    }

    fn tickTriangle(self: *Apu) void {
        if (self.triangle_divider == 0) {
            self.reloadTriangleTimer();
            if (self.triangle_length != 0 and self.triangle_linear_counter != 0 and self.triangleTimerPeriod() >= 2) self.triangle_step +%= 1;
        } else self.triangle_divider -= 1;
    }

    fn clockTriangleLinearCounter(self: *Apu) void {
        if (self.triangle_linear_reload) {
            self.triangle_linear_counter = self.registers[8] & 0x7f;
        } else if (self.triangle_linear_counter != 0) self.triangle_linear_counter -= 1;
        if (self.registers[8] & 0x80 == 0) self.triangle_linear_reload = false;
    }

    fn triangleSample(self: *const Apu) i16 {
        if (self.channel_enable & 4 == 0 or self.triangle_length == 0 or self.triangle_linear_counter == 0 or self.triangleTimerPeriod() < 2) return 0;
        const ramp: i16 = if (self.triangle_step < 16) @intCast(self.triangle_step) else @intCast(31 - self.triangle_step);
        return (ramp - 8) * 1536;
    }

    fn reloadNoiseTimer(self: *Apu) void {
        self.noise_divider = noise_period_table[self.registers[14] & 0x0f] - 1;
    }

    fn tickNoise(self: *Apu) void {
        if (self.noise_divider != 0) {
            self.noise_divider -= 1;
            return;
        }
        self.reloadNoiseTimer();
        const tap: u4 = if (self.registers[14] & 0x80 != 0) 6 else 1;
        const feedback: u15 = (self.noise_shift & 1) ^ ((self.noise_shift >> tap) & 1);
        self.noise_shift = (self.noise_shift >> 1) | (feedback << 14);
    }

    fn noiseSample(self: *const Apu) i16 {
        if (self.channel_enable & 8 == 0 or self.noise_length == 0 or self.noise_shift & 1 != 0) return 0;
        return @as(i16, self.registers[12] & 0x0f) * 1024;
    }

    fn mixedSample(self: *const Apu) i16 {
        const mixed: i32 = @as(i32, self.mixedPulseSample()) + self.triangleSample() + self.noiseSample();
        return @intCast(std.math.clamp(mixed, @as(i32, std.math.minInt(i16)), @as(i32, std.math.maxInt(i16))));
    }

    fn clockLengthCounters(self: *Apu) void {
        if (self.pulse1_length != 0 and self.registers[0] & 0x20 == 0) self.pulse1_length -= 1;
        if (self.pulse2_length != 0 and self.registers[4] & 0x20 == 0) self.pulse2_length -= 1;
        if (self.triangle_length != 0 and self.registers[8] & 0x80 == 0) self.triangle_length -= 1;
        if (self.noise_length != 0 and self.registers[12] & 0x20 == 0) self.noise_length -= 1;
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

test "APU frame sequencer clocks terminal half-frames in four and five step modes" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x4000, 0x00);
    _ = apu.cpuWrite(0x4015, 1);
    _ = apu.cpuWrite(0x4003, 0x18); // length index 3 -> 2
    apu.tick(7457);
    try std.testing.expectEqual(@as(u8, 1), apu.pulse1_length);
    apu.tick(7458);
    try std.testing.expectEqual(@as(u8, 0), apu.pulse1_length);

    _ = apu.cpuWrite(0x4003, 0x18);
    _ = apu.cpuWrite(0x4017, 0x80); // immediate half-frame clocks length once
    try std.testing.expectEqual(@as(u8, 1), apu.pulse1_length);
    apu.tick(18641);
    try std.testing.expectEqual(@as(u8, 0), apu.pulse1_length);
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

test "APU pulse-2 length and PCM mix are independently enabled" {
    var capture: TestCapture = .{};
    var apu = Apu.init(.{ .context = &capture, .write_fn = TestCapture.write });
    _ = apu.cpuWrite(0x4004, 0xdf);
    _ = apu.cpuWrite(0x4006, 8);
    _ = apu.cpuWrite(0x4015, 2);
    _ = apu.cpuWrite(0x4007, 0xf8);
    try std.testing.expectEqual(@as(u8, 30), apu.pulse2_length);
    try std.testing.expectEqual(@as(?u8, 0x02), apu.cpuRead(0x4015));

    apu.tick(@as(u16, @intCast(cpu_clock_hz / 100)));
    try std.testing.expectEqual(@as(usize, 440), capture.count);
    try std.testing.expect(capture.first_sample != 0);

    _ = apu.cpuWrite(0x4015, 0);
    try std.testing.expectEqual(@as(u8, 0), apu.pulse2_length);
}

test "APU triangle clocks its linear counter and timer independently" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x4008, 0xff); // control flag and linear-counter reload 127
    _ = apu.cpuWrite(0x400a, 2);
    _ = apu.cpuWrite(0x4015, 4);
    _ = apu.cpuWrite(0x400b, 0xf8);
    try std.testing.expectEqual(@as(u8, 30), apu.triangle_length);
    try std.testing.expectEqual(@as(?u8, 0x04), apu.cpuRead(0x4015));

    apu.tick(3729);
    try std.testing.expectEqual(@as(u8, 127), apu.triangle_linear_counter);
    const before = apu.triangle_step;
    apu.tick(3);
    try std.testing.expect(apu.triangle_step != before);

    _ = apu.cpuWrite(0x4015, 0);
    try std.testing.expectEqual(@as(u8, 0), apu.triangle_length);
}

test "APU noise reloads length, shifts its LFSR and reports status" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x400c, 0x3f);
    _ = apu.cpuWrite(0x400e, 0x00);
    _ = apu.cpuWrite(0x4015, 8);
    _ = apu.cpuWrite(0x400f, 0xf8);
    try std.testing.expectEqual(@as(u8, 30), apu.noise_length);
    try std.testing.expectEqual(@as(?u8, 0x08), apu.cpuRead(0x4015));
    const before = apu.noise_shift;
    apu.tick(4);
    try std.testing.expect(apu.noise_shift != before);
    _ = apu.cpuWrite(0x4015, 0);
    try std.testing.expectEqual(@as(u8, 0), apu.noise_length);
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
