const std = @import("std");
const Cartridge = @import("cartridge.zig").Cartridge;
const Mirroring = @import("cartridge.zig").Mirroring;

/// AOROM/AMROM (Mapper 7): a switchable 32 KiB PRG window, 8 KiB CHR-RAM,
/// and one-screen nametable selection. Standard iNES boards expose up to
/// eight 32 KiB PRG banks; outer-bank variants are rejected by Cartridge.
pub const Mapper7 = struct {
    prg_rom: []const u8,
    chr_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    bank_select: u8 = 0,

    pub fn init(cartridge: Cartridge) Mapper7 {
        return .{ .prg_rom = cartridge.prg_rom };
    }

    pub fn cpuRead(self: *const Mapper7, address: u16) ?u8 {
        if (address < 0x8000) return null;
        const bank_count = self.prg_rom.len / (32 * 1024);
        const bank = @as(usize, self.bank_select & 0x07) % bank_count;
        return self.prg_rom[bank * 32 * 1024 + @as(usize, address - 0x8000)];
    }

    pub fn cpuWrite(self: *Mapper7, address: u16, value: u8) bool {
        if (address < 0x8000) return false;
        self.bank_select = value;
        return true;
    }

    pub fn ppuRead(self: *const Mapper7, address: u16) ?u8 {
        if (address >= 0x2000) return null;
        return self.chr_ram[address];
    }

    pub fn ppuWrite(self: *Mapper7, address: u16, value: u8) bool {
        if (address >= 0x2000) return false;
        self.chr_ram[address] = value;
        return true;
    }

    pub fn mirroring(self: *const Mapper7) Mirroring {
        return if (self.bank_select & 0x10 == 0) .single_screen_lower else .single_screen_upper;
    }
};

test "AOROM switches its 32 KiB PRG bank and one-screen mirroring" {
    var prg: [2 * 32 * 1024]u8 = undefined;
    @memset(prg[0 .. 32 * 1024], 0x11);
    @memset(prg[32 * 1024 ..], 0x22);
    var mapper = Mapper7{ .prg_rom = &prg };
    try std.testing.expectEqual(@as(?u8, 0x11), mapper.cpuRead(0x8000));
    try std.testing.expectEqual(Mirroring.single_screen_lower, mapper.mirroring());
    try std.testing.expect(mapper.cpuWrite(0x9000, 0x11));
    try std.testing.expectEqual(@as(?u8, 0x22), mapper.cpuRead(0x8000));
    try std.testing.expectEqual(Mirroring.single_screen_upper, mapper.mirroring());
    try std.testing.expect(mapper.ppuWrite(0x1fff, 0x7a));
    try std.testing.expectEqual(@as(?u8, 0x7a), mapper.ppuRead(0x1fff));
}
