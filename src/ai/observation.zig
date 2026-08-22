const std = @import("std");

pub const protocol_version: u16 = 1;
pub const canonical_header_size = 60;
pub const RomHash = [32]u8;
pub const StateHash = [16]u8;

pub const SystemId = enum(u8) {
    nes = 1,
    neogeo = 2,
};

pub const Kind = enum(u8) {
    keyframe = 0,
    delta = 1,
};

/// Versioned metadata shared by every AI observation. The visual payload is
/// deliberately separate so a tokenizer-facing codec cannot leak into a
/// system emulator or its snapshot API.
pub const Header = struct {
    version: u16 = protocol_version,
    system: SystemId,
    rom_sha256: RomHash,
    sequence: u64,
    base_sequence: u64,
    frame: u64,
    kind: Kind,

    pub const Error = error{
        UnsupportedVersion,
        InvalidSequence,
        InvalidBaseSequence,
        BufferTooSmall,
    };

    pub fn validate(self: Header) Error!void {
        if (self.version != protocol_version) return error.UnsupportedVersion;
        if (self.sequence == 0) return error.InvalidSequence;
        switch (self.kind) {
            .keyframe => if (self.base_sequence != 0) return error.InvalidBaseSequence,
            .delta => if (self.base_sequence == 0 or self.base_sequence >= self.sequence) return error.InvalidBaseSequence,
        }
    }

    /// Writes a padding-free, little-endian header suitable for stable state
    /// hashing. This is not an HTTP or tokenizer encoding.
    pub fn encodeCanonical(self: Header, output: []u8) Error![]const u8 {
        try self.validate();
        if (output.len < canonical_header_size) return error.BufferTooSmall;
        writeU16Le(output[0..2], self.version);
        output[2] = @intFromEnum(self.system);
        output[3] = @intFromEnum(self.kind);
        writeU64Le(output[4..12], self.sequence);
        writeU64Le(output[12..20], self.base_sequence);
        writeU64Le(output[20..28], self.frame);
        output[28..60].* = self.rom_sha256;
        return output[0..canonical_header_size];
    }
};

/// Produces a fixed 128-bit fingerprint without relying on host struct
/// layout. It is for trace identity and resynchronization, not cryptography.
pub fn stateHash(canonical: []const u8) StateHash {
    const first = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, canonical);
    const second = std.hash.Wyhash.hash(0x243f6a8885a308d3, canonical);
    var result: StateHash = undefined;
    writeU64Le(result[0..8], first);
    writeU64Le(result[8..16], second);
    return result;
}

fn writeU16Le(output: []u8, value: u16) void {
    output[0] = @truncate(value);
    output[1] = @truncate(value >> 8);
}

fn writeU64Le(output: []u8, value: u64) void {
    for (0..8) |index| output[index] = @truncate(value >> @as(u6, @intCast(index * 8)));
}

test "canonical keyframe header has stable field ordering" {
    var rom_hash: RomHash = [_]u8{0} ** 32;
    rom_hash[0] = 0xaa;
    rom_hash[31] = 0x55;
    const header = Header{
        .system = .nes,
        .rom_sha256 = rom_hash,
        .sequence = 7,
        .base_sequence = 0,
        .frame = 120,
        .kind = .keyframe,
    };
    var bytes: [canonical_header_size]u8 = undefined;
    const canonical = try header.encodeCanonical(&bytes);
    try std.testing.expectEqual(@as(usize, canonical_header_size), canonical.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 0, 7, 0, 0, 0 }, canonical[0..8]);
    try std.testing.expectEqual(@as(u8, 0xaa), canonical[28]);
    try std.testing.expectEqual(@as(u8, 0x55), canonical[59]);
    try std.testing.expectEqual(stateHash(canonical), stateHash(canonical));
}

test "delta headers require an earlier base sequence" {
    const base = Header{
        .system = .nes,
        .rom_sha256 = [_]u8{0} ** 32,
        .sequence = 7,
        .base_sequence = 0,
        .frame = 120,
        .kind = .delta,
    };
    try std.testing.expectError(error.InvalidBaseSequence, base.validate());
    try std.testing.expectError(error.InvalidBaseSequence, (Header{
        .system = .nes,
        .rom_sha256 = [_]u8{0} ** 32,
        .sequence = 7,
        .base_sequence = 7,
        .frame = 120,
        .kind = .delta,
    }).validate());
}
