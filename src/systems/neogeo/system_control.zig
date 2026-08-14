const std = @import("std");
const address_map = @import("address_map.zig");

/// State held by the documented system-control addressable latch. Cartridge
/// boards use a 74HC259-style latch: the write data is ignored, the selected
/// address bit chooses a latch value, and only odd 68000 byte lanes trigger
/// it. This device records only the two controls whose effects are known well
/// enough to model independently; ROM and palette devices consume neither
/// state yet.
pub const SystemControl = struct {
    vector_source: VectorSource = .bios,
    palette_bank: PaletteBank = .bank_0,

    /// Applies one already-decoded odd-byte system-control write. Returns
    /// false for every latch whose function is not modeled in this narrow
    /// device, instead of inventing an effect from its write data.
    pub fn write(self: *SystemControl, decoded: address_map.DecodedAddress) bool {
        if (decoded.target != .system_control or decoded.offset & 1 == 0) return false;

        switch (decoded.offset) {
            0x03 => self.vector_source = .bios,
            0x13 => self.vector_source = .cartridge,
            0x0f => self.palette_bank = .bank_0,
            0x1f => self.palette_bank = .bank_1,
            else => return false,
        }
        return true;
    }
};

pub const VectorSource = enum {
    bios,
    cartridge,
};

pub const PaletteBank = enum {
    bank_0,
    bank_1,
};

test "Neo Geo system control switches vector source from odd latch writes" {
    var control: SystemControl = .{};
    try std.testing.expectEqual(VectorSource.bios, control.vector_source);
    try std.testing.expect(control.write(address_map.decode(.mvs, 0x3a0013).?));
    try std.testing.expectEqual(VectorSource.cartridge, control.vector_source);
    try std.testing.expect(control.write(address_map.decode(.aes, 0x3a0003).?));
    try std.testing.expectEqual(VectorSource.bios, control.vector_source);
}

test "Neo Geo system control switches palette bank from odd latch writes" {
    var control: SystemControl = .{};
    try std.testing.expectEqual(PaletteBank.bank_0, control.palette_bank);
    try std.testing.expect(control.write(address_map.decode(.mvs, 0x3a001f).?));
    try std.testing.expectEqual(PaletteBank.bank_1, control.palette_bank);
    try std.testing.expect(control.write(address_map.decode(.aes, 0x3a000f).?));
    try std.testing.expectEqual(PaletteBank.bank_0, control.palette_bank);
}

test "Neo Geo system control accepts mirrored latch addresses" {
    var control: SystemControl = .{};
    const decoded = address_map.decode(.mvs, 0x3b001f).?;
    try std.testing.expectEqual(address_map.Target.system_control, decoded.target);
    try std.testing.expectEqual(@as(u32, 0x1f), decoded.offset);
    try std.testing.expect(control.write(decoded));
    try std.testing.expectEqual(PaletteBank.bank_1, control.palette_bank);
}

test "Neo Geo system control rejects invalid lanes, targets, and unknown latches" {
    var control: SystemControl = .{};
    try std.testing.expect(!control.write(.{ .target = .system_control, .offset = 0x02 }));
    try std.testing.expect(!control.write(.{ .target = .sound, .offset = 0x03 }));
    try std.testing.expect(!control.write(.{ .target = .system_control, .offset = 0x01 }));
    try std.testing.expectEqual(VectorSource.bios, control.vector_source);
    try std.testing.expectEqual(PaletteBank.bank_0, control.palette_bank);
}
