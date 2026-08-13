const std = @import("std");
const Cartridge = @import("cartridge.zig").Cartridge;
const Mirroring = @import("cartridge.zig").Mirroring;

/// NROM has no registers or bank switching. CPU ROM is 16 KiB mirrored once
/// or 32 KiB direct-mapped; PPU pattern data is either immutable ROM or the
/// cartridge's 8 KiB of volatile CHR RAM.
pub const Mapper0 = struct {
    prg_rom: []const u8,
    chr_rom: []const u8,
    prg_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    chr_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    chr_is_ram: bool,
    mirroring: Mirroring,

    pub fn init(cartridge: Cartridge) Mapper0 {
        return .{
            .prg_rom = cartridge.prg_rom,
            .chr_rom = cartridge.chr_rom,
            .chr_is_ram = cartridge.chr_is_ram,
            .mirroring = cartridge.mirroring,
        };
    }

    pub fn cpuRead(self: *const Mapper0, address: u16) ?u8 {
        if (address >= 0x6000 and address < 0x8000) return self.prg_ram[address - 0x6000];
        if (address < 0x8000) return null;
        const offset = @as(usize, address - 0x8000) % self.prg_rom.len;
        return self.prg_rom[offset];
    }

    /// NROM's conventional 8 KiB PRG-RAM window is volatile in this MVP.
    /// Battery-backed images are rejected by the cartridge parser, and this
    /// memory is therefore never serialized as a save file.
    pub fn cpuWrite(self: *Mapper0, address: u16, value: u8) bool {
        if (address < 0x6000 or address >= 0x8000) return false;
        self.prg_ram[address - 0x6000] = value;
        return true;
    }

    pub fn ppuRead(self: *const Mapper0, address: u16) ?u8 {
        if (address >= 0x2000) return null;
        return if (self.chr_is_ram) self.chr_ram[address] else self.chr_rom[address];
    }

    pub fn ppuWrite(self: *Mapper0, address: u16, value: u8) bool {
        if (address >= 0x2000 or !self.chr_is_ram) return false;
        self.chr_ram[address] = value;
        return true;
    }
};

test "NROM mirrors 16 KiB PRG ROM but maps 32 KiB directly" {
    var prg16: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    prg16[0] = 0x11;
    prg16[0x3fff] = 0x22;
    var mapper16 = Mapper0{
        .prg_rom = &prg16,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    try std.testing.expectEqual(@as(?u8, 0x11), mapper16.cpuRead(0x8000));
    try std.testing.expectEqual(@as(?u8, 0x11), mapper16.cpuRead(0xc000));
    try std.testing.expectEqual(@as(?u8, 0x22), mapper16.cpuRead(0xffff));
    try std.testing.expectEqual(@as(?u8, 0), mapper16.cpuRead(0x7fff));
    try std.testing.expectEqual(@as(?u8, null), mapper16.cpuRead(0x5fff));

    var prg32: [32 * 1024]u8 = [_]u8{0} ** (32 * 1024);
    prg32[0] = 0x33;
    prg32[16 * 1024] = 0x44;
    const mapper32 = Mapper0{
        .prg_rom = &prg32,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .vertical,
    };
    try std.testing.expectEqual(@as(?u8, 0x33), mapper32.cpuRead(0x8000));
    try std.testing.expectEqual(@as(?u8, 0x44), mapper32.cpuRead(0xc000));
}

test "NROM writes only to CHR RAM" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    try std.testing.expect(mapper.ppuWrite(0x1fff, 0x5a));
    try std.testing.expectEqual(@as(?u8, 0x5a), mapper.ppuRead(0x1fff));
    try std.testing.expect(!mapper.ppuWrite(0x2000, 0x77));

    const chr_rom = [_]u8{0x12} ** (8 * 1024);
    var rom_mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &chr_rom,
        .chr_is_ram = false,
        .mirroring = .horizontal,
    };
    try std.testing.expect(!rom_mapper.ppuWrite(0, 0x34));
    try std.testing.expectEqual(@as(?u8, 0x12), rom_mapper.ppuRead(0));
}

test "NROM exposes volatile 8 KiB PRG RAM without writing PRG ROM" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    prg[0] = 0xea;
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    try std.testing.expect(mapper.cpuWrite(0x6000, 0x5a));
    try std.testing.expect(mapper.cpuWrite(0x7fff, 0xa5));
    try std.testing.expectEqual(@as(?u8, 0x5a), mapper.cpuRead(0x6000));
    try std.testing.expectEqual(@as(?u8, 0xa5), mapper.cpuRead(0x7fff));
    try std.testing.expect(!mapper.cpuWrite(0x8000, 0x00));
    try std.testing.expectEqual(@as(?u8, 0xea), mapper.cpuRead(0x8000));
}
