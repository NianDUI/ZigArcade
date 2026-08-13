const std = @import("std");

/// Minimal 68000-side Neo Geo address map for diagnostics. This deliberately
/// excludes CPU execution and game devices; it establishes the byte/word
/// big-endian contract and BIOS-over-P-ROM overlay at reset without requiring
/// proprietary BIOS content.
pub const Bus = struct {
    program_rom: []const u8,
    bios_rom: []const u8,
    bios_overlay: bool = true,
    work_ram: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024),

    /// The P-ROM becomes visible only through this explicit transition; no
    /// later address-map extension should mutate overlay state implicitly.
    pub fn disableBiosOverlay(self: *Bus) void {
        self.bios_overlay = false;
    }

    pub fn readByte(self: *const Bus, address: u32) ?u8 {
        if (address < 0x100000) {
            const rom = if (self.bios_overlay) self.bios_rom else self.program_rom;
            return if (address < rom.len) rom[@intCast(address)] else null;
        }
        if (address >= 0x100000 and address < 0x110000) return self.work_ram[@intCast(address - 0x100000)];
        return null;
    }

    pub fn writeByte(self: *Bus, address: u32, value: u8) bool {
        if (address < 0x100000) return false;
        if (address >= 0x100000 and address < 0x110000) {
            self.work_ram[@intCast(address - 0x100000)] = value;
            return true;
        }
        return false;
    }

    pub fn readWord(self: *const Bus, address: u32) ?u16 {
        if (address & 1 != 0) return null;
        const high = self.readByte(address) orelse return null;
        const low = self.readByte(address + 1) orelse return null;
        return (@as(u16, high) << 8) | low;
    }

    pub fn readLong(self: *const Bus, address: u32) ?u32 {
        if (address & 1 != 0) return null;
        const high = self.readWord(address) orelse return null;
        const low = self.readWord(address + 2) orelse return null;
        return (@as(u32, high) << 16) | low;
    }

    pub fn writeWord(self: *Bus, address: u32, value: u16) bool {
        if (address & 1 != 0) return false;
        if (address < 0x100000 or address + 1 >= 0x110000) return false;
        if (!self.writeByte(address, @truncate(value >> 8))) return false;
        if (!self.writeByte(address + 1, @truncate(value))) return false;
        return true;
    }
};

test "Neo Geo diagnostic bus overlays BIOS then exposes big-endian RAM words" {
    const program = [_]u8{ 0x12, 0x34 };
    const bios = [_]u8{ 0xab, 0xcd };
    var bus = Bus{ .program_rom = &program, .bios_rom = &bios };
    try std.testing.expectEqual(@as(?u16, 0xabcd), bus.readWord(0));
    bus.disableBiosOverlay();
    try std.testing.expectEqual(@as(?u16, 0x1234), bus.readWord(0));
    try std.testing.expect(bus.writeWord(0x100000, 0xbeef));
    try std.testing.expectEqual(@as(?u16, 0xbeef), bus.readWord(0x100000));
    try std.testing.expectEqual(@as(?u32, 0xbeef0000), bus.readLong(0x100000));
    try std.testing.expect(!bus.writeWord(0x100001, 0x1234));
    try std.testing.expectEqual(@as(?u16, null), bus.readWord(0x100001));
    try std.testing.expect(!bus.writeByte(0, 0));
}

test "Neo Geo diagnostic bus rejects unmapped ROM and boundary-crossing word writes" {
    const program = [_]u8{0x00};
    var bus = Bus{ .program_rom = &program, .bios_rom = &.{} };
    bus.disableBiosOverlay();
    try std.testing.expectEqual(@as(?u8, null), bus.readByte(1));
    try std.testing.expect(!bus.writeWord(0x10ffff, 0x1234));
    try std.testing.expectEqual(@as(u8, 0), bus.work_ram[0xffff]);
}
