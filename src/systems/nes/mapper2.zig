const Cartridge = @import("cartridge.zig").Cartridge;
const Mirroring = @import("cartridge.zig").Mirroring;

/// UNROM/UOROM (Mapper 2): a switchable 16 KiB bank at $8000 and the final
/// 16 KiB bank fixed at $C000. It always exposes CHR-RAM and has no IRQ.
pub const Mapper2 = struct {
    prg_rom: []const u8,
    prg_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    chr_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    mirroring: Mirroring,
    bank_select: u8 = 0,

    pub fn init(cartridge: Cartridge) Mapper2 {
        return .{
            .prg_rom = cartridge.prg_rom,
            .mirroring = cartridge.mirroring,
        };
    }

    pub fn cpuRead(self: *const Mapper2, address: u16) ?u8 {
        if (address >= 0x6000 and address < 0x8000) return self.prg_ram[address - 0x6000];
        if (address < 0x8000) return null;
        const bank_count = self.prg_rom.len / (16 * 1024);
        const bank: usize = if (address < 0xc000)
            @as(usize, self.bank_select) % bank_count
        else
            bank_count - 1;
        return self.prg_rom[bank * 16 * 1024 + @as(usize, address & 0x3fff)];
    }

    pub fn cpuWrite(self: *Mapper2, address: u16, value: u8) bool {
        if (address >= 0x6000 and address < 0x8000) {
            self.prg_ram[address - 0x6000] = value;
            return true;
        }
        if (address >= 0x8000) {
            self.bank_select = value;
            return true;
        }
        return false;
    }

    pub fn ppuRead(self: *const Mapper2, address: u16) ?u8 {
        if (address >= 0x2000) return null;
        return self.chr_ram[address];
    }

    pub fn ppuWrite(self: *Mapper2, address: u16, value: u8) bool {
        if (address >= 0x2000) return false;
        self.chr_ram[address] = value;
        return true;
    }
};

test "UNROM switches low PRG bank and fixes the last bank at $C000" {
    var prg: [3 * 16 * 1024]u8 = undefined;
    @memset(prg[0 .. 16 * 1024], 0x10);
    @memset(prg[16 * 1024 .. 2 * 16 * 1024], 0x20);
    @memset(prg[2 * 16 * 1024 ..], 0x30);
    var mapper = Mapper2{ .prg_rom = &prg, .mirroring = .vertical };
    try @import("std").testing.expectEqual(@as(?u8, 0x10), mapper.cpuRead(0x8000));
    try @import("std").testing.expectEqual(@as(?u8, 0x30), mapper.cpuRead(0xc000));
    try @import("std").testing.expect(mapper.cpuWrite(0x9000, 1));
    try @import("std").testing.expectEqual(@as(?u8, 0x20), mapper.cpuRead(0x8000));
    try @import("std").testing.expectEqual(@as(?u8, 0x30), mapper.cpuRead(0xc000));
}
