const std = @import("std");
const Cartridge = @import("cartridge.zig").Cartridge;
const Mirroring = @import("cartridge.zig").Mirroring;

/// MMC3 (Mapper 4) bank, mirroring, and A12-qualified IRQ registers.
pub const Mapper4 = struct {
    prg_rom: []const u8,
    chr_rom: []const u8,
    chr_is_ram: bool,
    prg_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    chr_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    bank_select: u8 = 0,
    bank_data: [8]u8 = [_]u8{0} ** 8,
    mirroring_mode: Mirroring,
    prg_ram_enabled: bool = true,
    prg_ram_write_protected: bool = false,
    irq_latch: u8 = 0,
    irq_counter: u8 = 0,
    irq_reload: bool = false,
    irq_enabled: bool = false,
    irq_pending: bool = false,
    a12_low_dots: u4 = 0,

    pub fn init(cartridge: Cartridge) Mapper4 {
        return .{
            .prg_rom = cartridge.prg_rom,
            .chr_rom = cartridge.chr_rom,
            .chr_is_ram = cartridge.chr_is_ram,
            .mirroring_mode = cartridge.mirroring,
        };
    }

    pub fn cpuRead(self: *const Mapper4, address: u16) ?u8 {
        if (address >= 0x6000 and address < 0x8000) return if (self.prg_ram_enabled) self.prg_ram[address - 0x6000] else null;
        if (address < 0x8000) return null;
        const count = self.prg_rom.len / 0x2000;
        const last = count - 1;
        const second_last = count - 2;
        const slot = (address - 0x8000) >> 13;
        const mode = self.bank_select & 0x40 != 0;
        const bank: usize = switch (slot) {
            0 => if (mode) second_last else @as(usize, self.bank_data[6]) % count,
            1 => @as(usize, self.bank_data[7]) % count,
            2 => if (mode) @as(usize, self.bank_data[6]) % count else second_last,
            3 => last,
            else => unreachable,
        };
        return self.prg_rom[bank * 0x2000 + @as(usize, address & 0x1fff)];
    }

    pub fn cpuWrite(self: *Mapper4, address: u16, value: u8) bool {
        if (address >= 0x6000 and address < 0x8000) {
            if (self.prg_ram_enabled and !self.prg_ram_write_protected) self.prg_ram[address - 0x6000] = value;
            return true;
        }
        if (address < 0x8000) return false;
        switch (address & 0xe001) {
            0x8000 => self.bank_select = value,
            0x8001 => self.bank_data[self.bank_select & 7] = value,
            0xa000 => self.mirroring_mode = if (value & 1 == 0) .vertical else .horizontal,
            0xa001 => {
                self.prg_ram_enabled = value & 0x80 != 0;
                self.prg_ram_write_protected = value & 0x40 != 0;
            },
            0xc000 => self.irq_latch = value,
            0xc001 => self.irq_reload = true,
            0xe000 => {
                self.irq_enabled = false;
                self.irq_pending = false;
            },
            0xe001 => self.irq_enabled = true,
            else => unreachable,
        }
        return true;
    }

    pub fn ppuRead(self: *const Mapper4, address: u16) ?u8 {
        if (address >= 0x2000) return null;
        const offset = self.chrOffset(address);
        if (self.chr_is_ram) return self.chr_ram[offset];
        return self.chr_rom[offset];
    }

    pub fn ppuWrite(self: *Mapper4, address: u16, value: u8) bool {
        if (address >= 0x2000 or !self.chr_is_ram) return false;
        self.chr_ram[self.chrOffset(address)] = value;
        return true;
    }

    pub fn mirroring(self: *const Mapper4) Mirroring {
        return self.mirroring_mode;
    }

    /// Samples the PPU address bus once per dot. MMC3 clocks its counter on
    /// an A12 rise only after the line has remained low for at least eight
    /// dots, filtering the short low gaps between pattern fetches.
    pub fn clockPpuAddress(self: *Mapper4, address: u16) void {
        if (address & 0x1000 == 0) {
            self.a12_low_dots = @min(self.a12_low_dots +| 1, 8);
            return;
        }
        const qualified_rise = self.a12_low_dots >= 8;
        self.a12_low_dots = 0;
        if (!qualified_rise) return;
        if (self.irq_counter == 0 or self.irq_reload) {
            self.irq_counter = self.irq_latch;
            self.irq_reload = false;
        } else {
            self.irq_counter -= 1;
        }
        if (self.irq_counter == 0 and self.irq_enabled) self.irq_pending = true;
    }

    pub fn irqPending(self: *const Mapper4) bool {
        return self.irq_pending;
    }

    fn chrOffset(self: *const Mapper4, address: u16) usize {
        const count = if (self.chr_is_ram) 8 else self.chr_rom.len / 0x400;
        const slot = address >> 10;
        const invert = self.bank_select & 0x80 != 0;
        const pair0 = @as(usize, self.bank_data[0] & 0xfe);
        const pair1 = @as(usize, self.bank_data[1] & 0xfe);
        const bank: usize = if (!invert) switch (slot) {
            0 => pair0,
            1 => pair0 + 1,
            2 => pair1,
            3 => pair1 + 1,
            4 => self.bank_data[2],
            5 => self.bank_data[3],
            6 => self.bank_data[4],
            7 => self.bank_data[5],
            else => unreachable,
        } else switch (slot) {
            0 => self.bank_data[2],
            1 => self.bank_data[3],
            2 => self.bank_data[4],
            3 => self.bank_data[5],
            4 => pair0,
            5 => pair0 + 1,
            6 => pair1,
            7 => pair1 + 1,
            else => unreachable,
        };
        return (bank % count) * 0x400 + @as(usize, address & 0x03ff);
    }
};

test "MMC3 switches PRG and CHR banks and controls mirroring" {
    var prg: [4 * 0x2000]u8 = undefined;
    for (0..4) |bank| @memset(prg[bank * 0x2000 ..][0..0x2000], @intCast(0x10 + bank));
    var chr: [8 * 0x400]u8 = undefined;
    for (0..8) |bank| @memset(chr[bank * 0x400 ..][0..0x400], @intCast(0x20 + bank));
    var mapper = Mapper4{ .prg_rom = &prg, .chr_rom = &chr, .chr_is_ram = false, .mirroring_mode = .vertical };
    try std.testing.expectEqual(@as(?u8, 0x10), mapper.cpuRead(0x8000));
    try std.testing.expectEqual(@as(?u8, 0x12), mapper.cpuRead(0xc000));
    try std.testing.expect(mapper.cpuWrite(0x8000, 6));
    try std.testing.expect(mapper.cpuWrite(0x8001, 1));
    try std.testing.expectEqual(@as(?u8, 0x11), mapper.cpuRead(0x8000));
    try std.testing.expect(mapper.cpuWrite(0x8000, 0));
    try std.testing.expect(mapper.cpuWrite(0x8001, 4));
    try std.testing.expectEqual(@as(?u8, 0x24), mapper.ppuRead(0));
    try std.testing.expectEqual(@as(?u8, 0x25), mapper.ppuRead(0x400));
    try std.testing.expect(mapper.cpuWrite(0xa000, 1));
    try std.testing.expectEqual(Mirroring.horizontal, mapper.mirroring());
}

test "MMC3 IRQ clocks only on A12 rises after an eight-dot low period" {
    var prg: [4 * 0x2000]u8 = [_]u8{0} ** (4 * 0x2000);
    var chr: [8 * 0x400]u8 = [_]u8{0} ** (8 * 0x400);
    var mapper = Mapper4{ .prg_rom = &prg, .chr_rom = &chr, .chr_is_ram = false, .mirroring_mode = .vertical };
    try std.testing.expect(mapper.cpuWrite(0xc000, 2));
    try std.testing.expect(mapper.cpuWrite(0xe001, 0));

    for (0..8) |_| mapper.clockPpuAddress(0);
    mapper.clockPpuAddress(0x1000);
    try std.testing.expectEqual(@as(u8, 2), mapper.irq_counter);
    try std.testing.expect(!mapper.irqPending());

    for (0..7) |_| mapper.clockPpuAddress(0);
    mapper.clockPpuAddress(0x1000);
    try std.testing.expectEqual(@as(u8, 2), mapper.irq_counter);

    for (0..8) |_| mapper.clockPpuAddress(0);
    mapper.clockPpuAddress(0x1000);
    try std.testing.expectEqual(@as(u8, 1), mapper.irq_counter);
    for (0..8) |_| mapper.clockPpuAddress(0);
    mapper.clockPpuAddress(0x1000);
    try std.testing.expect(mapper.irqPending());

    try std.testing.expect(mapper.cpuWrite(0xe000, 0));
    try std.testing.expect(!mapper.irqPending());
    try std.testing.expect(!mapper.irq_enabled);
    try std.testing.expect(mapper.cpuWrite(0xc001, 0));
    for (0..8) |_| mapper.clockPpuAddress(0);
    mapper.clockPpuAddress(0x1000);
    try std.testing.expectEqual(@as(u8, 2), mapper.irq_counter);
}
