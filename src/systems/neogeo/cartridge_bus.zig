const std = @import("std");
const address_map = @import("address_map.zig");
const CartridgeIo = @import("cartridge_io.zig").CartridgeIo;
const DipSwitchWatchdog = @import("dipswitch_watchdog.zig").DipSwitchWatchdog;
const PaletteRam = @import("palette_ram.zig").PaletteRam;
const SystemControl = @import("system_control.zig").SystemControl;
const VectorSource = @import("system_control.zig").VectorSource;

/// Partial, asset-free cartridge-system 68000 bus. It composes only address
/// targets with evidence-backed byte/word device contracts: mirrored work RAM,
/// word-wide palette RAM, byte-wide I/O, caller-supplied system ROM, and the
/// fixed P-ROM window with its separately controlled 128-byte vector area.
/// Banked P-ROM, open-bus values, memory cards, backup RAM and LSPC are not
/// silently emulated here.
pub const CartridgeBus = struct {
    variant: address_map.CartridgeVariant,
    /// Caller-owned fixed P-ROM byte image. It is visible at $000080 onward;
    /// its first 128 bytes appear at $000000 only when the vector latch picks
    /// the cartridge source.
    program_rom: []const u8 = &.{},
    /// Caller-owned 128 KiB system-ROM image. A shorter slice makes the
    /// uncovered physical bytes unmapped rather than filling them with a
    /// guessed open-bus value.
    system_rom: []const u8 = &.{},
    work_ram: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024),
    palette_ram: PaletteRam = .{},
    io: CartridgeIo,
    dipswitch_watchdog: DipSwitchWatchdog = .{},
    system_control: SystemControl = .{},

    pub fn init(variant: address_map.CartridgeVariant) CartridgeBus {
        return .{ .variant = variant, .io = CartridgeIo.init(variant) };
    }

    pub fn readByte(self: *const CartridgeBus, address: u32) ?u8 {
        const decoded = self.decode(address) orelse return null;
        return switch (decoded.target) {
            .fixed_program_rom => self.readFixedProgramByte(decoded.offset),
            .work_ram => self.work_ram[@intCast(decoded.offset)],
            .system_rom => readRomByte(self.system_rom, decoded.offset),
            .player_1, .sound, .player_2, .system => self.io.read(decoded),
            .dip_switch_and_watchdog => self.dipswitch_watchdog.read(decoded),
            // Palette accesses are word-wide in this deliberately narrow
            // slice. Byte-write masks need their own hardware evidence.
            else => null,
        };
    }

    pub fn writeByte(self: *CartridgeBus, address: u32, value: u8) bool {
        const decoded = self.decode(address) orelse return false;
        switch (decoded.target) {
            .work_ram => self.work_ram[@intCast(decoded.offset)] = value,
            .sound => return self.io.write(decoded, value),
            .dip_switch_and_watchdog => return self.dipswitch_watchdog.write(decoded),
            .system_control => return self.system_control.write(decoded),
            else => return false,
        }
        return true;
    }

    pub fn readWord(self: *const CartridgeBus, address: u32) ?u16 {
        if (address & 1 != 0) return null;
        const decoded = self.decode(address) orelse return null;
        return switch (decoded.target) {
            .fixed_program_rom => blk: {
                const high = self.readFixedProgramByte(decoded.offset) orelse break :blk null;
                const low = self.readFixedProgramByte(decoded.offset + 1) orelse break :blk null;
                break :blk (@as(u16, high) << 8) | low;
            },
            .work_ram => blk: {
                if (decoded.offset > 0xfffe) break :blk null;
                const high = self.work_ram[@intCast(decoded.offset)];
                const low = self.work_ram[@intCast(decoded.offset + 1)];
                break :blk (@as(u16, high) << 8) | low;
            },
            .palette => blk: {
                if (decoded.offset & 1 != 0) break :blk null;
                break :blk self.palette_ram.readWord(@intCast(decoded.offset / 2));
            },
            .system_rom => blk: {
                const high = readRomByte(self.system_rom, decoded.offset) orelse break :blk null;
                const low = readRomByte(self.system_rom, decoded.offset + 1) orelse break :blk null;
                break :blk (@as(u16, high) << 8) | low;
            },
            // I/O word lane values and their low-byte behavior are not part
            // of this slice. Callers must use the proven byte access path.
            else => null,
        };
    }

    pub fn writeWord(self: *CartridgeBus, address: u32, value: u16) bool {
        if (address & 1 != 0) return false;
        const decoded = self.decode(address) orelse return false;
        switch (decoded.target) {
            .work_ram => {
                if (decoded.offset > 0xfffe) return false;
                self.work_ram[@intCast(decoded.offset)] = @truncate(value >> 8);
                self.work_ram[@intCast(decoded.offset + 1)] = @truncate(value);
            },
            .palette => {
                if (decoded.offset & 1 != 0) return false;
                return self.palette_ram.writeWord(@intCast(decoded.offset / 2), value);
            },
            else => return false,
        }
        return true;
    }

    fn decode(self: *const CartridgeBus, address: u32) ?address_map.DecodedAddress {
        if (address > 0xffffff) return null;
        return address_map.decode(self.variant, @intCast(address));
    }

    fn readFixedProgramByte(self: *const CartridgeBus, offset: u32) ?u8 {
        const rom = if (offset < vector_window_bytes and self.system_control.vector_source == .bios)
            self.system_rom
        else
            self.program_rom;
        return readRomByte(rom, offset);
    }
};

const vector_window_bytes: u32 = 0x80;

fn readRomByte(rom: []const u8, offset: u32) ?u8 {
    if (offset >= rom.len) return null;
    return rom[@intCast(offset)];
}

test "Neo Geo cartridge bus mirrors work RAM and keeps big-endian word order" {
    var bus = CartridgeBus.init(.mvs);
    try std.testing.expect(bus.writeWord(0x1f1234, 0xbeef));
    try std.testing.expectEqual(@as(?u16, 0xbeef), bus.readWord(0x101234));
    try std.testing.expectEqual(@as(?u8, 0xbe), bus.readByte(0x111234));
    try std.testing.expect(bus.writeByte(0x101235, 0x42));
    try std.testing.expectEqual(@as(?u16, 0xbe42), bus.readWord(0x1f1234));
    try std.testing.expect(!bus.writeWord(0x101235, 0));
    try std.testing.expectEqual(@as(?u16, null), bus.readWord(0x10ffff));
}

test "Neo Geo cartridge bus maps palette words but rejects unproven byte lanes" {
    var bus = CartridgeBus.init(.aes);
    try std.testing.expect(bus.writeWord(0x7fe010, 0x7c00));
    try std.testing.expectEqual(@as(?u16, 0x7c00), bus.readWord(0x400010));
    try std.testing.expectEqual(@as(?u8, null), bus.readByte(0x400010));
    try std.testing.expect(!bus.writeByte(0x400010, 0xff));
}

test "Neo Geo cartridge bus mirrors caller-supplied system ROM as read-only big-endian bytes" {
    const system_rom = [_]u8{ 0x12, 0x34, 0x56 };
    var bus = CartridgeBus.init(.mvs);
    bus.system_rom = &system_rom;
    try std.testing.expectEqual(@as(?u8, 0x12), bus.readByte(0xc00000));
    try std.testing.expectEqual(@as(?u8, 0x34), bus.readByte(0xc20001));
    try std.testing.expectEqual(@as(?u16, 0x1234), bus.readWord(0xce0000));
    try std.testing.expectEqual(@as(?u16, null), bus.readWord(0xc00002));
    try std.testing.expect(!bus.writeByte(0xc00000, 0));
    try std.testing.expect(!bus.writeWord(0xc00000, 0));
}

test "Neo Geo cartridge bus switches only the fixed P-ROM vector window" {
    var program = [_]u8{0} ** 0x82;
    program[0] = 0x12;
    program[1] = 0x34;
    program[0x80] = 0x56;
    program[0x81] = 0x78;
    var system = [_]u8{0} ** vector_window_bytes;
    system[0] = 0xab;
    system[1] = 0xcd;

    var bus = CartridgeBus.init(.mvs);
    bus.program_rom = &program;
    bus.system_rom = &system;
    try std.testing.expectEqual(@as(?u16, 0xabcd), bus.readWord(0));
    try std.testing.expectEqual(@as(?u16, 0), bus.readWord(0x7e));
    try std.testing.expectEqual(@as(?u8, 0), bus.readByte(0x7f));
    try std.testing.expectEqual(@as(?u16, 0x5678), bus.readWord(0x80));
    try std.testing.expect(bus.writeByte(0x3a0013, 0));
    try std.testing.expectEqual(VectorSource.cartridge, bus.system_control.vector_source);
    try std.testing.expectEqual(@as(?u16, 0x1234), bus.readWord(0));
    try std.testing.expectEqual(@as(?u16, 0), bus.readWord(0x7e));
    try std.testing.expectEqual(@as(?u8, 0), bus.readByte(0x7f));
    try std.testing.expectEqual(@as(?u16, 0x5678), bus.readWord(0x80));
    try std.testing.expect(!bus.writeWord(0, 0));
}

test "Neo Geo cartridge bus uses decoded I/O byte lanes without I/O word guesses" {
    var bus = CartridgeBus.init(.mvs);
    try std.testing.expect(bus.io.setPlayerButtons(0, .{ .up = true, .a = true }));
    try std.testing.expectEqual(@as(?u8, 0xee), bus.readByte(0x31ff7e));
    try std.testing.expect(bus.writeByte(0x33fffe, 0x42));
    try std.testing.expectEqual(@as(?u8, 0x42), bus.io.takeSoundCommand());
    bus.io.writeSoundReply(0xa5);
    try std.testing.expectEqual(@as(?u8, 0xa5), bus.readByte(0x320000));
    try std.testing.expectEqual(@as(?u8, null), bus.readByte(0x320001));
    try std.testing.expectEqual(@as(?u16, null), bus.readWord(0x320000));
    try std.testing.expect(!bus.writeWord(0x320000, 0));
}

test "Neo Geo cartridge bus connects MVS DIP input and watchdog kicks" {
    var bus = CartridgeBus.init(.mvs);
    bus.dipswitch_watchdog.setDips(0x5a);
    try std.testing.expectEqual(@as(?u8, 0x5a), bus.readByte(0x31ff01));
    try std.testing.expect(bus.writeByte(0x31ff01, 0x42));
    try std.testing.expectEqual(@as(u64, 1), bus.dipswitch_watchdog.watchdog_kicks);

    var aes = CartridgeBus.init(.aes);
    try std.testing.expectEqual(@as(?u8, null), aes.readByte(0x300001));
    try std.testing.expect(!aes.writeByte(0x300001, 0));
}

test "Neo Geo cartridge bus routes system-control writes without a palette side effect" {
    var bus = CartridgeBus.init(.aes);
    try std.testing.expect(bus.writeByte(0x3b0013, 0x42));
    try std.testing.expectEqual(@import("system_control.zig").VectorSource.cartridge, bus.system_control.vector_source);
    try std.testing.expect(bus.writeByte(0x3a001f, 0));
    try std.testing.expectEqual(@import("system_control.zig").PaletteBank.bank_1, bus.system_control.palette_bank);
    try std.testing.expectEqual(@as(?u16, 0), bus.readWord(0x400000));
    try std.testing.expect(!bus.writeByte(0x3a0012, 0));
    try std.testing.expectEqual(@as(?u8, null), bus.readByte(0x3a0013));
    try std.testing.expectEqual(@as(?u16, null), bus.readWord(0x3a0012));
}

test "Neo Geo cartridge bus rejects unmapped and non-24-bit addresses" {
    var bus = CartridgeBus.init(.aes);
    try std.testing.expectEqual(@as(?u8, null), bus.readByte(0x3e0000));
    try std.testing.expect(!bus.writeByte(0x1_000000, 0));
    try std.testing.expectEqual(@as(?u16, null), bus.readWord(0x1_000000));
}
