/// Cartridge Neo Geo 68000 address decoding facts for MVS and AES. This
/// module deliberately describes only address selection and mirroring:
/// register side effects, BIOS vector selection and protection chips belong
/// to their owning devices.
///
/// Evidence and scope are recorded in docs/NEOGEO_ADDRESS_MAP.md.
pub const Target = enum {
    fixed_program_rom,
    work_ram,
    banked_program_rom,
    player_1,
    dip_switch_and_watchdog,
    sound,
    player_2,
    system,
    system_control,
    video,
    palette,
    memory_card,
    system_rom,
    backup_ram,
};

/// The visible memory-card and backup-RAM windows differ by cartridge system.
/// Callers must choose explicitly rather than silently inheriting one board's
/// persistent-device layout.
pub const CartridgeVariant = enum {
    mvs,
    aes,
};

pub const DecodedAddress = struct {
    target: Target,
    /// Byte offset within the physical device after address mirroring.
    offset: u32,
};

pub const fixed_program_rom_start: u24 = 0x000000;
pub const fixed_program_rom_end: u24 = 0x0fffff;
pub const work_ram_start: u24 = 0x100000;
pub const work_ram_end: u24 = 0x1fffff;
pub const banked_program_rom_start: u24 = 0x200000;
pub const banked_program_rom_end: u24 = 0x2fffff;
pub const io_start: u24 = 0x300000;
pub const io_end: u24 = 0x3fffff;
pub const palette_start: u24 = 0x400000;
pub const palette_end: u24 = 0x7fffff;
pub const memory_card_start: u24 = 0x800000;
pub const memory_card_end: u24 = 0xbfffff;
pub const system_rom_start: u24 = 0xc00000;
pub const system_rom_end: u24 = 0xcfffff;
pub const backup_ram_start: u24 = 0xd00000;
pub const backup_ram_end: u24 = 0xdfffff;

pub const p1_address: u24 = 0x300000;
pub const dipswitch_watchdog_address: u24 = 0x300001;
pub const sound_address: u24 = 0x320000;
pub const player_2_address: u24 = 0x340000;
pub const system_address: u24 = 0x380000;
pub const system_control_address: u24 = 0x3a0001;
pub const video_address: u24 = 0x3c0000;

/// Maps a 24-bit 68000 bus address to a physical cartridge-system device.
/// `null` means that the selected board variant does not define the address;
/// board-specific devices must be layered explicitly instead of guessed.
pub fn decode(variant: CartridgeVariant, address: u24) ?DecodedAddress {
    if (address <= fixed_program_rom_end) return .{ .target = .fixed_program_rom, .offset = address };

    if (address >= work_ram_start and address <= work_ram_end) {
        return .{ .target = .work_ram, .offset = address & 0xffff };
    }

    if (address >= banked_program_rom_start and address <= banked_program_rom_end) {
        return .{ .target = .banked_program_rom, .offset = address - banked_program_rom_start };
    }

    // MVS reserves bit 7 for its TEST register at $300080/$300081. AES maps
    // P1 more broadly. The Wiki explicitly marks its decode masks unverified;
    // the MVS split below follows the independently pinned MAME map.
    const p1_mask: u24 = switch (variant) {
        .mvs => 0xfe0081,
        .aes => 0xfe0001,
    };
    if (matches(address, p1_address, p1_mask)) return .{ .target = .player_1, .offset = address & 1 };
    if (variant == .mvs and matches(address, dipswitch_watchdog_address, 0xfe0081)) {
        return .{ .target = .dip_switch_and_watchdog, .offset = address & 1 };
    }
    if (matches(address, sound_address, 0xfe0001)) return .{ .target = .sound, .offset = address & 1 };
    if (matches(address, player_2_address, 0xfe0001)) return .{ .target = .player_2, .offset = address & 1 };
    if (matches(address, system_address, 0xfe0001)) return .{ .target = .system, .offset = address & 1 };
    if (matches(address, system_control_address, 0xfe0001)) return .{ .target = .system_control, .offset = address & 0x1f };
    if (matches(address, video_address, 0xfe0001)) return .{ .target = .video, .offset = address & 0x0f };

    if (address >= palette_start and address <= palette_end) {
        return .{ .target = .palette, .offset = address & 0x1fff };
    }

    if (variant == .aes and address >= memory_card_start and address <= memory_card_end) {
        return .{ .target = .memory_card, .offset = address - memory_card_start };
    }

    if (address >= system_rom_start and address <= system_rom_end) {
        return .{ .target = .system_rom, .offset = address & 0x1ffff };
    }

    if (variant == .mvs and address >= backup_ram_start and address <= backup_ram_end) {
        return .{ .target = .backup_ram, .offset = address & 0xffff };
    }

    return null;
}

fn matches(address: u24, base: u24, mask: u24) bool {
    return address & mask == base;
}

test "Neo Geo common cartridge decoder normalizes documented RAM and palette mirrors" {
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .work_ram, .offset = 0x00f2 },
        decode(.mvs, 0x1000f2).?,
    );
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .work_ram, .offset = 0x00f2 },
        decode(.aes, 0x1f00f2).?,
    );
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .palette, .offset = 0x0010 },
        decode(.mvs, 0x400010).?,
    );
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .palette, .offset = 0x0010 },
        decode(.aes, 0x7fe010).?,
    );
}

test "Neo Geo common cartridge decoder applies documented I/O decode masks" {
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .player_1, .offset = 0 },
        decode(.mvs, 0x31ff7e).?,
    );
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .dip_switch_and_watchdog, .offset = 1 },
        decode(.mvs, 0x31ff01).?,
    );
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .sound, .offset = 0 },
        decode(.mvs, 0x33fffe).?,
    );
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .system_control, .offset = 0x1f },
        decode(.aes, 0x3bffff).?,
    );
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .video, .offset = 0x0e },
        decode(.mvs, 0x3dfffe).?,
    );
}

test "Neo Geo decoder separates MVS TEST space from the AES P1 mirror" {
    try @import("std").testing.expectEqual(@as(?DecodedAddress, null), decode(.mvs, 0x300080));
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .player_1, .offset = 0 },
        decode(.aes, 0x300080).?,
    );
    try @import("std").testing.expectEqual(@as(?DecodedAddress, null), decode(.aes, 0x300001));
}

test "Neo Geo cartridge decoder separates AES memory card and MVS backup RAM" {
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .memory_card, .offset = 0x3fffff },
        decode(.aes, 0xbfffff).?,
    );
    try @import("std").testing.expectEqual(@as(?DecodedAddress, null), decode(.mvs, 0xbfffff));
    try @import("std").testing.expectEqual(
        DecodedAddress{ .target = .backup_ram, .offset = 0xffff },
        decode(.mvs, 0xdfffff).?,
    );
    try @import("std").testing.expectEqual(@as(?DecodedAddress, null), decode(.aes, 0xd00000));
}

test "Neo Geo cartridge decoder leaves undefined gaps unmapped" {
    // $350000 is a P2 mirror under its $FE0001 decode mask; use an address
    // outside every common cartridge range and documented I/O selection.
    try @import("std").testing.expectEqual(@as(?DecodedAddress, null), decode(.mvs, 0x3e0000));
    try @import("std").testing.expectEqual(@as(?DecodedAddress, null), decode(.aes, 0xe00000));
}
