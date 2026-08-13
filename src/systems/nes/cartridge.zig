const std = @import("std");

pub const Mirroring = enum { horizontal, vertical, single_screen_lower, single_screen_upper };
pub const MapperId = enum(u8) { nrom = 0, mmc1 = 1, unrom = 2, cnrom = 3, aorom = 7 };

pub const Error = error{
    CorruptRom,
    UnsupportedRomFormat,
    UnsupportedMapper,
    UnsupportedTrainer,
    UnsupportedFourScreenMirroring,
    UnsupportedBatteryBackedRam,
    UnsupportedNromLayout,
    UnsupportedMapperLayout,
};

/// A validated, borrowed iNES 1.0 image. The caller owns `image` and must
/// keep it alive for the lifetime of this value and any mapper made from it.
pub const Cartridge = struct {
    prg_rom: []const u8,
    chr_rom: []const u8,
    chr_is_ram: bool,
    mirroring: Mirroring,
    mapper: MapperId,

    pub fn parse(image: []const u8) Error!Cartridge {
        if (image.len < 16) return error.CorruptRom;
        const header = image[0..16];
        if (!std.mem.eql(u8, header[0..4], "NES\x1a")) return error.UnsupportedRomFormat;

        const flags6 = header[6];
        const flags7 = header[7];
        if ((flags7 & 0x0c) == 0x08) return error.UnsupportedRomFormat; // NES 2.0
        if (flags6 & 0x04 != 0) return error.UnsupportedTrainer;
        if (flags6 & 0x08 != 0) return error.UnsupportedFourScreenMirroring;
        if (flags6 & 0x02 != 0) return error.UnsupportedBatteryBackedRam;

        const mapper = (flags6 >> 4) | (flags7 & 0xf0);
        const mapper_id: MapperId = switch (mapper) {
            0 => .nrom,
            1 => .mmc1,
            2 => .unrom,
            3 => .cnrom,
            7 => .aorom,
            else => return error.UnsupportedMapper,
        };

        const prg_size = @as(usize, header[4]) * 16 * 1024;
        const chr_size = @as(usize, header[5]) * 8 * 1024;
        switch (mapper_id) {
            .nrom => {
                if (prg_size != 16 * 1024 and prg_size != 32 * 1024) return error.UnsupportedNromLayout;
                if (chr_size != 0 and chr_size != 8 * 1024) return error.UnsupportedNromLayout;
            },
            .mmc1 => {
                // This is the standard iNES MMC1 layout. Board variants with
                // outer PRG banking exceed these ranges and need separate
                // board identification rather than silently wrapping banks.
                if (prg_size < 2 * 16 * 1024 or prg_size > 16 * 16 * 1024 or chr_size > 32 * 4 * 1024) {
                    return error.UnsupportedMapperLayout;
                }
            },
            .unrom => {
                if (prg_size < 2 * 16 * 1024 or chr_size != 0) return error.UnsupportedMapperLayout;
            },
            .cnrom => {
                if ((prg_size != 16 * 1024 and prg_size != 32 * 1024) or chr_size < 2 * 8 * 1024) {
                    return error.UnsupportedMapperLayout;
                }
            },
            .aorom => {
                if (prg_size < 32 * 1024 or prg_size > 8 * 32 * 1024 or prg_size % (32 * 1024) != 0 or chr_size != 0) {
                    return error.UnsupportedMapperLayout;
                }
            },
        }
        if (image.len < 16 + prg_size + chr_size) return error.CorruptRom;

        return .{
            .prg_rom = image[16..][0..prg_size],
            .chr_rom = image[16 + prg_size ..][0..chr_size],
            .chr_is_ram = chr_size == 0,
            .mirroring = if (flags6 & 0x01 != 0) .vertical else .horizontal,
            .mapper = mapper_id,
        };
    }
};

test "iNES Mapper 0 parser exposes NROM slices and vertical mirroring" {
    var image: [16 + 16 * 1024 + 8 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024 + 8 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 1, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    image[16] = 0xa9;
    image[16 + 16 * 1024] = 0xff;

    const cartridge = try Cartridge.parse(&image);
    try std.testing.expectEqual(@as(usize, 16 * 1024), cartridge.prg_rom.len);
    try std.testing.expectEqual(@as(usize, 8 * 1024), cartridge.chr_rom.len);
    try std.testing.expect(!cartridge.chr_is_ram);
    try std.testing.expectEqual(Mirroring.vertical, cartridge.mirroring);
    try std.testing.expectEqual(MapperId.nrom, cartridge.mapper);
    try std.testing.expectEqual(@as(u8, 0xa9), cartridge.prg_rom[0]);
    try std.testing.expectEqual(@as(u8, 0xff), cartridge.chr_rom[0]);
}

test "iNES parser accepts MMC1 PRG-ROM with either CHR-ROM or CHR-RAM" {
    var image: [16 + 2 * 16 * 1024 + 8 * 1024]u8 = [_]u8{0} ** (16 + 2 * 16 * 1024 + 8 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 2, 1, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var cartridge = try Cartridge.parse(&image);
    try std.testing.expectEqual(MapperId.mmc1, cartridge.mapper);
    try std.testing.expect(!cartridge.chr_is_ram);

    image[5] = 0;
    cartridge = try Cartridge.parse(image[0 .. 16 + 2 * 16 * 1024]);
    try std.testing.expect(cartridge.chr_is_ram);

    image[4] = 17;
    try std.testing.expectError(error.UnsupportedMapperLayout, Cartridge.parse(&image));
}

test "iNES NROM parser recognizes CHR RAM and rejects unsupported header features" {
    var image: [16 + 16 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const cartridge = try Cartridge.parse(&image);
    try std.testing.expect(cartridge.chr_is_ram);
    try std.testing.expectEqual(@as(usize, 0), cartridge.chr_rom.len);

    image[7] = 0x08;
    try std.testing.expectError(error.UnsupportedRomFormat, Cartridge.parse(&image));
    image[7] = 0;
    image[6] = 0x04;
    try std.testing.expectError(error.UnsupportedTrainer, Cartridge.parse(&image));
    image[6] = 0x40;
    try std.testing.expectError(error.UnsupportedMapper, Cartridge.parse(&image));
}

test "iNES parser accepts CHR-RAM Mapper 2 and rejects CHR-ROM UNROM layouts" {
    var image: [16 + 3 * 16 * 1024]u8 = [_]u8{0} ** (16 + 3 * 16 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 3, 0, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const cartridge = try Cartridge.parse(&image);
    try std.testing.expectEqual(MapperId.unrom, cartridge.mapper);
    try std.testing.expect(cartridge.chr_is_ram);

    image[5] = 1;
    try std.testing.expectError(error.UnsupportedMapperLayout, Cartridge.parse(&image));
}

test "iNES parser accepts CNROM CHR-ROM banks and rejects unsupported layouts" {
    var image: [16 + 16 * 1024 + 2 * 8 * 1024]u8 = [_]u8{0} ** (16 + 16 * 1024 + 2 * 8 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 1, 2, 0x30, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const cartridge = try Cartridge.parse(&image);
    try std.testing.expectEqual(MapperId.cnrom, cartridge.mapper);
    try std.testing.expect(!cartridge.chr_is_ram);

    image[5] = 0;
    try std.testing.expectError(error.UnsupportedMapperLayout, Cartridge.parse(&image));
    image[5] = 1;
    try std.testing.expectError(error.UnsupportedMapperLayout, Cartridge.parse(&image));
}

test "iNES parser accepts standard AOROM and rejects CHR-ROM variants" {
    var image: [16 + 2 * 32 * 1024]u8 = [_]u8{0} ** (16 + 2 * 32 * 1024);
    image[0..16].* = .{ 'N', 'E', 'S', 0x1a, 4, 0, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const cartridge = try Cartridge.parse(&image);
    try std.testing.expectEqual(MapperId.aorom, cartridge.mapper);
    try std.testing.expect(cartridge.chr_is_ram);

    image[5] = 1;
    try std.testing.expectError(error.UnsupportedMapperLayout, Cartridge.parse(&image));
}
