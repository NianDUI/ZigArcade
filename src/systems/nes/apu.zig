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
const dmc_period_table = [_]u16{ 428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 85, 72, 54 };

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
    frame_irq_tail: u2 = 0,
    frame_counter_write_value: ?u8 = null,
    frame_counter_write_delay: u3 = 0,
    pulse1_divider: u16 = 0,
    pulse1_step: u3 = 0,
    pulse_clock_phase: bool = false,
    pulse1_length: u8 = 0,
    pulse1_envelope_divider: u8 = 0,
    pulse1_envelope_decay: u4 = 0,
    pulse1_envelope_start: bool = false,
    pulse1_sweep_divider: u8 = 0,
    pulse1_sweep_reload: bool = false,
    pulse2_divider: u16 = 0,
    pulse2_step: u3 = 0,
    pulse2_length: u8 = 0,
    pulse2_envelope_divider: u8 = 0,
    pulse2_envelope_decay: u4 = 0,
    pulse2_envelope_start: bool = false,
    pulse2_sweep_divider: u8 = 0,
    pulse2_sweep_reload: bool = false,
    triangle_divider: u16 = 0,
    triangle_step: u5 = 0,
    triangle_length: u8 = 0,
    triangle_linear_counter: u8 = 0,
    triangle_linear_reload: bool = false,
    noise_divider: u16 = 0,
    noise_shift: u15 = 1,
    noise_length: u8 = 0,
    dmc_divider: u16 = 0,
    dmc_output: u7 = 0,
    dmc_sample_address: u16 = 0xc000,
    dmc_sample_length: u16 = 1,
    dmc_current_address: u16 = 0xc000,
    dmc_bytes_remaining: u16 = 0,
    dmc_sample_buffer: ?u8 = null,
    dmc_shift: u8 = 0,
    dmc_bits_remaining: u4 = 8,
    dmc_silence: bool = true,
    dmc_request_pending: bool = false,
    dmc_irq: bool = false,
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
            if (address == 0x4010) self.reloadDmcTimer();
            if (address == 0x4010 and value & 0x80 == 0) self.dmc_irq = false;
            if (address == 0x4011) self.dmc_output = @truncate(value);
            if (address == 0x4012) self.dmc_sample_address = 0xc000 | (@as(u16, value) << 6);
            if (address == 0x4013) self.dmc_sample_length = (@as(u16, value) << 4) | 1;
            if (address == 0x4001) self.pulse1_sweep_reload = true;
            if (address == 0x4005) self.pulse2_sweep_reload = true;
            if (address == 0x4003 and self.channel_enable & 1 != 0) {
                self.pulse1_length = length_table[value >> 3];
                self.pulse1_envelope_start = true;
            }
            if (address == 0x4007 and self.channel_enable & 2 != 0) {
                self.pulse2_length = length_table[value >> 3];
                self.pulse2_envelope_start = true;
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
                self.dmc_irq = false;
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
                if (self.channel_enable & 0x10 == 0) self.dmc_bytes_remaining = 0 else if (self.dmc_bytes_remaining == 0) self.restartDmc();
                return true;
            },
            0x4017 => {
                self.frame_irq_inhibit = value & 0x40 != 0;
                if (self.frame_irq_inhibit) self.clearFrameIrq();
                self.frame_counter_write_value = value;
                self.frame_counter_write_delay = if (self.cpu_cycles & 1 == 0) 3 else 4;
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
            (@as(u8, @intFromBool(self.dmc_bytes_remaining != 0)) << 4) |
            (@as(u8, @intFromBool(self.frame_irq)) << 6);
        const with_dmc_irq = value | (@as(u8, @intFromBool(self.dmc_irq)) << 7);
        self.clearFrameIrq();
        return with_dmc_irq;
    }

    /// Advances exactly one APU tick per CPU cycle. The 4-step sequence makes
    /// its IRQ observable at its terminal quarter-frame interval; five-step
    /// mode omits that IRQ. Sequencer envelopes/lengths are added later.
    pub fn tick(self: *Apu, cycles: u16) void {
        for (0..cycles) |_| {
            self.cpu_cycles += 1;
            self.clockPendingFrameCounterWrite();
            self.frame_counter_cycles +%= 1;
            self.clockFrameSequencer();
            self.tickPulses();
            self.tickTriangle();
            self.tickNoise();
            self.tickDmc();
            self.sample_phase += sample_rate_hz;
            if (self.sample_phase >= cpu_clock_hz) {
                self.sample_phase -= cpu_clock_hz;
                const sample = [_]i16{self.mixedSample()};
                self.sink.write(self.cpu_cycles, &sample);
            }
        }
    }

    pub fn frameIrqPending(self: *const Apu) bool {
        return self.frame_irq or self.dmc_irq;
    }

    pub fn takeDmcReadRequest(self: *Apu) ?u16 {
        if (!self.dmc_request_pending) return null;
        self.dmc_request_pending = false;
        return self.dmc_current_address;
    }

    pub fn provideDmcSample(self: *Apu, value: u8) void {
        if (self.dmc_sample_buffer != null or self.dmc_bytes_remaining == 0) return;
        self.dmc_sample_buffer = value;
        self.dmc_current_address +%= 1;
        if (self.dmc_current_address == 0) self.dmc_current_address = 0x8000;
        self.dmc_bytes_remaining -= 1;
        if (self.dmc_bytes_remaining == 0) {
            if (self.registers[16] & 0x40 != 0) self.restartDmc() else if (self.registers[16] & 0x80 != 0) self.dmc_irq = true;
        }
    }

    fn clockFrameSequencer(self: *Apu) void {
        const cycle = self.frame_counter_cycles;
        // NTSC frame events are expressed in CPU cycles. Mode 0 raises the
        // frame flag on three consecutive clocks around its terminal step;
        // wrapping through maxInt preserves the following 29,830-cycle period.
        if (!self.frame_mode_5_step and self.frame_irq_tail != 0) {
            if (self.frame_irq_tail == 2) {
                self.clockQuarterFrame();
                self.clockLengthCounters();
                self.clockPulseSweeps();
            }
            self.setFrameIrq();
            self.frame_irq_tail -= 1;
        }
        if (cycle == 7458 or cycle == 22372) self.clockQuarterFrame();
        if (cycle == 14914) {
            self.clockQuarterFrame();
            self.clockLengthCounters();
            self.clockPulseSweeps();
        }
        if (!self.frame_mode_5_step and cycle == 29829) {
            self.setFrameIrq();
            self.frame_irq_tail = 2;
            self.frame_counter_cycles = std.math.maxInt(u16);
        } else if (self.frame_mode_5_step and cycle == 37282) {
            self.clockQuarterFrame();
            self.clockLengthCounters();
            self.clockPulseSweeps();
            self.frame_counter_cycles = 0;
        }
    }

    fn clockPendingFrameCounterWrite(self: *Apu) void {
        if (self.frame_counter_write_value == null) return;
        self.frame_counter_write_delay -= 1;
        if (self.frame_counter_write_delay != 0) return;
        const value = self.frame_counter_write_value.?;
        self.frame_counter_write_value = null;
        self.frame_mode_5_step = value & 0x80 != 0;
        self.frame_counter_cycles = 0;
        self.frame_irq_tail = 0;
        if (self.frame_mode_5_step) {
            self.clockQuarterFrame();
            self.clockLengthCounters();
            self.clockPulseSweeps();
        }
    }

    fn setFrameIrq(self: *Apu) void {
        if (self.frame_irq_inhibit) return;
        self.frame_irq = true;
    }

    fn clearFrameIrq(self: *Apu) void {
        self.frame_irq = false;
    }

    fn clockQuarterFrame(self: *Apu) void {
        self.clockTriangleLinearCounter();
        self.clockPulseEnvelope(.one);
        self.clockPulseEnvelope(.two);
    }

    fn clockPulseSweeps(self: *Apu) void {
        self.clockPulseSweep(.one);
        self.clockPulseSweep(.two);
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
        if (self.channel_enable & enable_mask == 0 or length == 0 or self.pulseTimerPeriod(pulse) < 8 or self.pulseSweepMutes(pulse)) return 0;
        const duty = (self.registers[offset] >> 6) & 3;
        const high = pulseHigh(duty, step);
        const amplitude = @as(i16, self.pulseVolume(pulse)) * 2048;
        return if (high) amplitude else -amplitude;
    }

    fn pulseVolume(self: *const Apu, pulse: Pulse) u4 {
        const offset: usize = if (pulse == .one) 0 else 4;
        if (self.registers[offset] & 0x10 != 0) return @truncate(self.registers[offset]);
        return if (pulse == .one) self.pulse1_envelope_decay else self.pulse2_envelope_decay;
    }

    fn clockPulseSweep(self: *Apu, pulse: Pulse) void {
        const offset: usize = if (pulse == .one) 0 else 4;
        const register = self.registers[offset + 1];
        const divider = switch (pulse) {
            .one => &self.pulse1_sweep_divider,
            .two => &self.pulse2_sweep_divider,
        };
        const reload = switch (pulse) {
            .one => &self.pulse1_sweep_reload,
            .two => &self.pulse2_sweep_reload,
        };
        if (divider.* == 0 and register & 0x80 != 0) self.applyPulseSweep(pulse, register);
        if (divider.* == 0 or reload.*) {
            divider.* = (register >> 4) & 7;
            reload.* = false;
        } else divider.* -= 1;
    }

    fn applyPulseSweep(self: *Apu, pulse: Pulse, register: u8) void {
        const target = self.pulseSweepTarget(pulse, register) orelse return;
        const offset: usize = if (pulse == .one) 0 else 4;
        self.registers[offset + 2] = @truncate(target);
        self.registers[offset + 3] = (self.registers[offset + 3] & 0xf8) | @as(u8, @truncate(target >> 8));
    }

    fn pulseSweepMutes(self: *const Apu, pulse: Pulse) bool {
        const offset: usize = if (pulse == .one) 0 else 4;
        const register = self.registers[offset + 1];
        return register & 0x80 != 0 and register & 7 != 0 and self.pulseSweepTarget(pulse, register) == null;
    }

    fn pulseSweepTarget(self: *const Apu, pulse: Pulse, register: u8) ?u16 {
        const shift: u4 = @truncate(register & 7);
        if (shift == 0) return self.pulseTimerPeriod(pulse);
        const timer = self.pulseTimerPeriod(pulse);
        const delta = timer >> shift;
        const target: i32 = if (register & 0x08 != 0)
            @as(i32, timer) - @as(i32, delta) - @as(i32, if (pulse == .one) 1 else 0)
        else
            @as(i32, timer) + @as(i32, delta);
        if (target < 8 or target > 0x7ff) return null;
        return @intCast(target);
    }

    fn clockPulseEnvelope(self: *Apu, pulse: Pulse) void {
        const offset: usize = if (pulse == .one) 0 else 4;
        const start = switch (pulse) {
            .one => &self.pulse1_envelope_start,
            .two => &self.pulse2_envelope_start,
        };
        const divider = switch (pulse) {
            .one => &self.pulse1_envelope_divider,
            .two => &self.pulse2_envelope_divider,
        };
        const decay = switch (pulse) {
            .one => &self.pulse1_envelope_decay,
            .two => &self.pulse2_envelope_decay,
        };
        if (start.*) {
            start.* = false;
            decay.* = 15;
            divider.* = self.registers[offset] & 0x0f;
        } else if (divider.* == 0) {
            divider.* = self.registers[offset] & 0x0f;
            if (decay.* != 0) decay.* -= 1 else if (self.registers[offset] & 0x20 != 0) decay.* = 15;
        } else divider.* -= 1;
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

    fn reloadDmcTimer(self: *Apu) void {
        self.dmc_divider = dmc_period_table[self.registers[16] & 0x0f] - 1;
    }

    fn restartDmc(self: *Apu) void {
        self.dmc_current_address = self.dmc_sample_address;
        self.dmc_bytes_remaining = self.dmc_sample_length;
    }

    fn tickDmc(self: *Apu) void {
        if (self.dmc_sample_buffer == null and self.dmc_bytes_remaining != 0) self.dmc_request_pending = true;
        if (self.dmc_divider != 0) {
            self.dmc_divider -= 1;
            return;
        }
        self.reloadDmcTimer();
        if (!self.dmc_silence) {
            if (self.dmc_shift & 1 != 0) {
                if (self.dmc_output <= 125) self.dmc_output += 2;
            } else if (self.dmc_output >= 2) self.dmc_output -= 2;
        }
        self.dmc_shift >>= 1;
        self.dmc_bits_remaining -= 1;
        if (self.dmc_bits_remaining == 0) {
            self.dmc_bits_remaining = 8;
            if (self.dmc_sample_buffer) |sample| {
                self.dmc_shift = sample;
                self.dmc_sample_buffer = null;
                self.dmc_silence = false;
            } else self.dmc_silence = true;
        }
    }

    fn dmcSample(self: *const Apu) i16 {
        if (self.channel_enable & 0x10 == 0) return 0;
        return (@as(i16, self.dmc_output) - 64) * 256;
    }

    fn mixedSample(self: *const Apu) i16 {
        const mixed: i32 = @as(i32, self.mixedPulseSample()) + self.triangleSample() + self.noiseSample() + self.dmcSample();
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

    apu.tick(29829);
    try std.testing.expect(apu.frameIrqPending());
    try std.testing.expectEqual(@as(?u8, 0x50), apu.cpuRead(0x4015));
    try std.testing.expect(!apu.frameIrqPending());
}

test "APU five-step mode and IRQ inhibit suppress frame IRQ" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x4017, 0x80);
    apu.tick(14915);
    try std.testing.expect(!apu.frameIrqPending());

    _ = apu.cpuWrite(0x4017, 0x00);
    apu.tick(29832);
    try std.testing.expect(apu.frameIrqPending());
    _ = apu.cpuWrite(0x4017, 0x40);
    try std.testing.expect(!apu.frameIrqPending());
}

test "APU frame-counter write delay follows CPU parity" {
    var null_sink = NullAudioSink{};
    var even_apu = Apu.init(null_sink.asSink());
    _ = even_apu.cpuWrite(0x4017, 0x80);
    even_apu.tick(2);
    try std.testing.expect(!even_apu.frame_mode_5_step);
    even_apu.tick(1);
    try std.testing.expect(even_apu.frame_mode_5_step);

    var odd_apu = Apu.init(null_sink.asSink());
    odd_apu.cpu_cycles = 1;
    _ = odd_apu.cpuWrite(0x4017, 0x80);
    odd_apu.tick(3);
    try std.testing.expect(!odd_apu.frame_mode_5_step);
    odd_apu.tick(1);
    try std.testing.expect(odd_apu.frame_mode_5_step);
}

test "APU frame sequencer clocks terminal half-frames in four and five step modes" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x4000, 0x00);
    _ = apu.cpuWrite(0x4015, 1);
    _ = apu.cpuWrite(0x4003, 0x18); // length index 3 -> 2
    apu.tick(14914);
    try std.testing.expectEqual(@as(u8, 1), apu.pulse1_length);
    apu.tick(14916);
    try std.testing.expectEqual(@as(u8, 0), apu.pulse1_length);

    _ = apu.cpuWrite(0x4003, 0x18);
    _ = apu.cpuWrite(0x4017, 0x80);
    try std.testing.expectEqual(@as(u8, 2), apu.pulse1_length);
    apu.tick(3); // delayed five-step reset clocks a half-frame once
    try std.testing.expectEqual(@as(u8, 1), apu.pulse1_length);
    apu.tick(14913);
    try std.testing.expectEqual(@as(u8, 0), apu.pulse1_length);
}

test "APU pulse-1 length reloads on $4003 and appears in $4015 status" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x4015, 1);
    _ = apu.cpuWrite(0x4003, 0xf8); // length-table index 31 -> 30
    try std.testing.expectEqual(@as(u8, 30), apu.pulse1_length);
    try std.testing.expectEqual(@as(?u8, 0x01), apu.cpuRead(0x4015));

    apu.frame_counter_cycles = 14913;
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

test "APU pulse envelope decays and loops at quarter-frame timing" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x4000, 0x00); // envelope period 0, no loop
    _ = apu.cpuWrite(0x4015, 1);
    _ = apu.cpuWrite(0x4003, 0xf8);
    apu.tick(7458);
    try std.testing.expectEqual(@as(u4, 15), apu.pulse1_envelope_decay);
    apu.tick(7456);
    try std.testing.expectEqual(@as(u4, 14), apu.pulse1_envelope_decay);

    _ = apu.cpuWrite(0x4004, 0x20); // looping pulse 2 envelope
    _ = apu.cpuWrite(0x4015, 2);
    _ = apu.cpuWrite(0x4007, 0xf8);
    apu.tick(7458);
    apu.pulse2_envelope_decay = 0;
    apu.tick(7458);
    try std.testing.expectEqual(@as(u4, 15), apu.pulse2_envelope_decay);
}

test "APU pulse sweep adjusts channels with their hardware negate difference" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x4002, 100);
    _ = apu.cpuWrite(0x4006, 100);
    _ = apu.cpuWrite(0x4001, 0x89); // enabled, negate, period 0, shift 1
    _ = apu.cpuWrite(0x4005, 0x89);
    apu.clockPulseSweeps();
    try std.testing.expectEqual(@as(u16, 49), apu.pulseTimerPeriod(.one));
    try std.testing.expectEqual(@as(u16, 50), apu.pulseTimerPeriod(.two));
}

test "APU invalid pulse sweep target mutes without changing its timer" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x4000, 0xdf);
    _ = apu.cpuWrite(0x4002, 0x00);
    _ = apu.cpuWrite(0x4003, 0x07); // timer $700
    _ = apu.cpuWrite(0x4001, 0x81); // positive sweep, shift 1 -> overflow
    _ = apu.cpuWrite(0x4015, 1);
    try std.testing.expect(apu.pulseSweepMutes(.one));
    try std.testing.expectEqual(@as(i16, 0), apu.pulseSample(.one));
    apu.clockPulseSweeps();
    try std.testing.expectEqual(@as(u16, 0x700), apu.pulseTimerPeriod(.one));
}

test "APU DMC requests CPU memory and raises IRQ at sample end" {
    var null_sink = NullAudioSink{};
    var apu = Apu.init(null_sink.asSink());
    _ = apu.cpuWrite(0x4010, 0x8f); // IRQ enabled, fastest rate
    _ = apu.cpuWrite(0x4012, 2);
    _ = apu.cpuWrite(0x4013, 0);
    _ = apu.cpuWrite(0x4015, 0x10);
    apu.tick(1);
    try std.testing.expectEqual(@as(?u16, 0xc080), apu.takeDmcReadRequest());
    apu.provideDmcSample(0x01);
    try std.testing.expectEqual(@as(u16, 0), apu.dmc_bytes_remaining);
    try std.testing.expect(apu.dmc_irq);
    try std.testing.expectEqual(@as(?u8, 0x80), apu.cpuRead(0x4015));
    _ = apu.cpuWrite(0x4011, 0x7f);
    try std.testing.expectEqual(@as(u7, 0x7f), apu.dmc_output);
    _ = apu.cpuWrite(0x4010, 0x0f);
    try std.testing.expect(!apu.dmc_irq);
    _ = apu.cpuWrite(0x4015, 0);
    try std.testing.expect(!apu.dmc_irq);
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

    apu.tick(7458);
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
