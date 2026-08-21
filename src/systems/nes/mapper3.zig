const std = @import("std");
const Cartridge = @import("cartridge.zig").Cartridge;
const Mirroring = @import("cartridge.zig").Mirroring;

/// CNROM (Mapper 3): NROM-style fixed PRG mapping plus a switchable 8 KiB
/// CHR-ROM bank at PPU $0000-$1FFF. PRG writes select CHR; they do not alter
/// program ROM. This implementation deliberately rejects CHR-RAM variants.
pub const Mapper3 = struct {
    prg_rom: []const u8,
    chr_rom: []const u8,
    prg_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    mirroring: Mirroring,
    chr_bank_select: u8 = 0,

    pub fn init(cartridge: Cartridge) Mapper3 {
        return .{
            .prg_rom = cartridge.prg_rom,
            .chr_rom = cartridge.chr_rom,
            .mirroring = cartridge.mirroring,
        };
    }

    pub fn cpuRead(self: *const Mapper3, address: u16) ?u8 {
        if (address >= 0x6000 and address < 0x8000) return self.prg_ram[address - 0x6000];
        if (address < 0x8000) return null;
        return self.prg_rom[@as(usize, address - 0x8000) % self.prg_rom.len];
    }

    pub fn cpuWrite(self: *Mapper3, address: u16, value: u8) bool {
        if (address >= 0x6000 and address < 0x8000) {
            self.prg_ram[address - 0x6000] = value;
            return true;
        }
        if (address >= 0x8000) {
            self.chr_bank_select = value;
            return true;
        }
        return false;
    }

    pub fn ppuRead(self: *const Mapper3, address: u16) ?u8 {
        if (address >= 0x2000) return null;
        const bank_count = self.chr_rom.len / (8 * 1024);
        const bank = @as(usize, self.chr_bank_select) % bank_count;
        return self.chr_rom[bank * 8 * 1024 + address];
    }

    pub fn ppuWrite(_: *Mapper3, _: u16, _: u8) bool {
        return false;
    }
};

test "CNROM switches its 8 KiB CHR bank while preserving fixed PRG" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    prg[0] = 0xa9;
    var chr: [2 * 8 * 1024]u8 = undefined;
    @memset(chr[0 .. 8 * 1024], 0x11);
    @memset(chr[8 * 1024 ..], 0x22);
    var mapper = Mapper3{ .prg_rom = &prg, .chr_rom = &chr, .mirroring = .horizontal };
    try std.testing.expectEqual(@as(?u8, 0xa9), mapper.cpuRead(0x8000));
    try std.testing.expectEqual(@as(?u8, 0x11), mapper.ppuRead(0));
    try std.testing.expect(mapper.cpuWrite(0x8000, 1));
    try std.testing.expectEqual(@as(?u8, 0x22), mapper.ppuRead(0));
    try std.testing.expect(!mapper.ppuWrite(0, 0xff));
}

test "CNROM with one CHR bank safely ignores bank selection" {
    var prg: [32 * 1024]u8 = [_]u8{0} ** (32 * 1024);
    var chr: [8 * 1024]u8 = [_]u8{0x5a} ** (8 * 1024);
    var mapper = Mapper3{ .prg_rom = &prg, .chr_rom = &chr, .mirroring = .vertical };

    try std.testing.expect(mapper.cpuWrite(0x8000, 0xff));
    try std.testing.expectEqual(@as(?u8, 0x5a), mapper.ppuRead(0x1fff));
}
