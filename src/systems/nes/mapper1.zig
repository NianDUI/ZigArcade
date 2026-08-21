const std = @import("std");
const Cartridge = @import("cartridge.zig").Cartridge;
const Mirroring = @import("cartridge.zig").Mirroring;

/// MMC1 (Mapper 1) serial mapper. This models the common iNES board layout:
/// switchable 16/32 KiB PRG, switchable 4/8 KiB CHR, 8 KiB PRG-RAM, and the
/// mapper-controlled single-screen/horizontal/vertical mirroring modes.
pub const Mapper1 = struct {
    prg_rom: []const u8,
    chr_rom: []const u8,
    chr_is_ram: bool,
    prg_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    chr_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    shift_register: u5 = 0x10,
    control: u5 = 0x0c,
    chr_bank_0: u5 = 0,
    chr_bank_1: u5 = 0,
    prg_bank: u5 = 0,

    pub fn init(cartridge: Cartridge) Mapper1 {
        return .{
            .prg_rom = cartridge.prg_rom,
            .chr_rom = cartridge.chr_rom,
            .chr_is_ram = cartridge.chr_is_ram,
        };
    }

    pub fn cpuRead(self: *const Mapper1, address: u16) ?u8 {
        if (address >= 0x6000 and address < 0x8000) {
            if (self.prg_bank & 0x10 != 0) return null;
            return self.prg_ram[address - 0x6000];
        }
        if (address < 0x8000) return null;
        return self.prg_rom[self.prgOffset(address)];
    }

    pub fn cpuWrite(self: *Mapper1, address: u16, value: u8) bool {
        if (address >= 0x6000 and address < 0x8000) {
            if (self.prg_bank & 0x10 == 0) self.prg_ram[address - 0x6000] = value;
            return true;
        }
        if (address < 0x8000) return false;
        if (value & 0x80 != 0) {
            self.shift_register = 0x10;
            self.control |= 0x0c;
            return true;
        }
        const complete = self.shift_register & 1 != 0;
        // MMC1 only samples D0. Games commonly write values whose upper bits
        // are unrelated register contents, so feeding those bits into the
        // serial latch would choose the wrong bank.
        self.shift_register = (self.shift_register >> 1) | (@as(u5, @truncate(value & 1)) << 4);
        if (complete) {
            self.writeRegister(address, self.shift_register);
            self.shift_register = 0x10;
        }
        return true;
    }

    pub fn ppuRead(self: *const Mapper1, address: u16) ?u8 {
        if (address >= 0x2000) return null;
        if (self.chr_is_ram) return self.chr_ram[address];
        return self.chr_rom[self.chrOffset(address)];
    }

    pub fn ppuWrite(self: *Mapper1, address: u16, value: u8) bool {
        if (address >= 0x2000 or !self.chr_is_ram) return false;
        self.chr_ram[address] = value;
        return true;
    }

    pub fn mirroring(self: *const Mapper1) Mirroring {
        return switch (self.control & 0x03) {
            0 => .single_screen_lower,
            1 => .single_screen_upper,
            2 => .vertical,
            3 => .horizontal,
            else => unreachable,
        };
    }

    fn writeRegister(self: *Mapper1, address: u16, value: u5) void {
        switch ((address >> 13) & 0x03) {
            0 => self.control = value,
            1 => self.chr_bank_0 = value,
            2 => self.chr_bank_1 = value,
            3 => self.prg_bank = value,
            else => unreachable,
        }
    }

    fn prgOffset(self: *const Mapper1, address: u16) usize {
        const bank_count = self.prg_rom.len / (16 * 1024);
        const mode = (self.control >> 2) & 0x03;
        const bank: usize = switch (mode) {
            0, 1 => (@as(usize, self.prg_bank & 0x0e) >> 1) * 2 + @as(usize, (address - 0x8000) >> 14),
            2 => if (address < 0xc000) 0 else @as(usize, self.prg_bank & 0x0f),
            3 => if (address < 0xc000) @as(usize, self.prg_bank & 0x0f) else bank_count - 1,
            else => unreachable,
        };
        return (bank % bank_count) * 16 * 1024 + @as(usize, address & 0x3fff);
    }

    fn chrOffset(self: *const Mapper1, address: u16) usize {
        const bank_count = self.chr_rom.len / (4 * 1024);
        const bank: usize = if (self.control & 0x10 == 0)
            @as(usize, self.chr_bank_0 & 0x1e) + @as(usize, address >> 12)
        else if (address < 0x1000)
            @as(usize, self.chr_bank_0)
        else
            @as(usize, self.chr_bank_1);
        return (bank % bank_count) * 4 * 1024 + @as(usize, address & 0x0fff);
    }
};

fn serialWrite(mapper: *Mapper1, address: u16, value: u5) void {
    for (0..5) |bit| _ = mapper.cpuWrite(address, @truncate(value >> @intCast(bit)));
}

test "MMC1 serial registers select PRG, CHR and mirroring modes" {
    var prg: [4 * 16 * 1024]u8 = undefined;
    for (0..4) |bank| @memset(prg[bank * 16 * 1024 ..][0 .. 16 * 1024], @intCast(0x10 + bank));
    var chr: [4 * 4 * 1024]u8 = undefined;
    for (0..4) |bank| @memset(chr[bank * 4 * 1024 ..][0 .. 4 * 1024], @intCast(0x20 + bank));
    var mapper = Mapper1{ .prg_rom = &prg, .chr_rom = &chr, .chr_is_ram = false };

    try std.testing.expectEqual(@as(?u8, 0x10), mapper.cpuRead(0x8000));
    try std.testing.expectEqual(@as(?u8, 0x13), mapper.cpuRead(0xc000));
    serialWrite(&mapper, 0xe000, 2);
    try std.testing.expectEqual(@as(?u8, 0x12), mapper.cpuRead(0x8000));
    try std.testing.expectEqual(@as(?u8, 0x13), mapper.cpuRead(0xc000));

    serialWrite(&mapper, 0x8000, 0x1e); // 4 KiB CHR mode, vertical mirroring
    serialWrite(&mapper, 0xa000, 1);
    serialWrite(&mapper, 0xc000, 3);
    try std.testing.expectEqual(Mirroring.vertical, mapper.mirroring());
    try std.testing.expectEqual(@as(?u8, 0x21), mapper.ppuRead(0));
    try std.testing.expectEqual(@as(?u8, 0x23), mapper.ppuRead(0x1000));
}

test "MMC1 reset restores fixed-last-bank mode and CHR-RAM is writable" {
    var prg: [2 * 16 * 1024]u8 = undefined;
    @memset(prg[0 .. 16 * 1024], 0x11);
    @memset(prg[16 * 1024 ..], 0x22);
    var mapper = Mapper1{ .prg_rom = &prg, .chr_rom = &.{}, .chr_is_ram = true };
    serialWrite(&mapper, 0x8000, 0);
    try std.testing.expectEqual(Mirroring.single_screen_lower, mapper.mirroring());
    try std.testing.expect(mapper.cpuWrite(0x8000, 0x80));
    try std.testing.expectEqual(Mirroring.single_screen_lower, mapper.mirroring());
    try std.testing.expectEqual(@as(?u8, 0x22), mapper.cpuRead(0xc000));
    try std.testing.expect(mapper.ppuWrite(0x1fff, 0x7a));
    try std.testing.expectEqual(@as(?u8, 0x7a), mapper.ppuRead(0x1fff));
}

test "MMC1 mirrors a single 16 KiB PRG bank in every banking mode" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    prg[0] = 0x11;
    prg[0x3fff] = 0x22;
    var mapper = Mapper1{ .prg_rom = &prg, .chr_rom = &.{}, .chr_is_ram = true };

    try std.testing.expectEqual(@as(?u8, 0x11), mapper.cpuRead(0x8000));
    try std.testing.expectEqual(@as(?u8, 0x11), mapper.cpuRead(0xc000));
    serialWrite(&mapper, 0x8000, 0);
    serialWrite(&mapper, 0xe000, 0x0f);
    try std.testing.expectEqual(@as(?u8, 0x22), mapper.cpuRead(0xbfff));
    try std.testing.expectEqual(@as(?u8, 0x22), mapper.cpuRead(0xffff));
}

test "MMC1 serial latch ignores CPU write bits above D0" {
    var prg: [3 * 16 * 1024]u8 = undefined;
    @memset(prg[0 .. 16 * 1024], 0x10);
    @memset(prg[16 * 1024 .. 2 * 16 * 1024], 0x20);
    @memset(prg[2 * 16 * 1024 ..], 0x30);
    var mapper = Mapper1{ .prg_rom = &prg, .chr_rom = &.{}, .chr_is_ram = true };
    // Write serial value 1 (LSB first) with arbitrary high bits set.
    for (0..5) |bit| {
        const serial_bit: u8 = @truncate(@as(u5, 1) >> @intCast(bit));
        try std.testing.expect(mapper.cpuWrite(0xe000, serial_bit | 0x7e));
    }
    try std.testing.expectEqual(@as(?u8, 0x20), mapper.cpuRead(0x8000));
    try std.testing.expectEqual(@as(?u8, 0x30), mapper.cpuRead(0xc000));
}
