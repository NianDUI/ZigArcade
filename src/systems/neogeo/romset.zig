const std = @import("std");

/// Logical Neo Geo ROM regions. The loader owns file I/O; this module only
/// validates a caller-provided manifest, so it never embeds or distributes
/// BIOS/game data and can be tested entirely with synthetic metadata.
pub const Region = enum { program, sprites, fixed, audio_cpu, samples, bios };

pub const Entry = struct {
    region: Region,
    name: []const u8,
    size: usize,
    sha256: [32]u8,

    /// Verifies a caller-owned local byte slice against manifest metadata.
    /// It intentionally does not open files, retain bytes, or expose data.
    pub fn verifyBytes(self: Entry, bytes: []const u8) Error!void {
        if (bytes.len != self.size) return error.SizeMismatch;
        var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
        if (!std.mem.eql(u8, &actual, &self.sha256)) return error.HashMismatch;
    }
};

pub const Manifest = struct {
    entries: []const Entry,

    pub fn validate(self: Manifest) Error!void {
        if (self.entries.len == 0) return error.MissingProgram;
        var has_program = false;
        var has_sprites = false;
        var has_fixed = false;
        var has_audio_cpu = false;
        var has_samples = false;
        var has_bios = false;
        for (self.entries) |entry| {
            if (entry.name.len == 0 or entry.size == 0) return error.InvalidEntry;
            switch (entry.region) {
                .program => has_program = true,
                .sprites => has_sprites = true,
                .fixed => has_fixed = true,
                .audio_cpu => has_audio_cpu = true,
                .samples => has_samples = true,
                .bios => has_bios = true,
            }
        }
        if (!has_program) return error.MissingProgram;
        if (!has_sprites) return error.MissingSprites;
        if (!has_fixed) return error.MissingFixed;
        if (!has_audio_cpu) return error.MissingAudioCpu;
        if (!has_samples) return error.MissingSamples;
        if (!has_bios) return error.MissingBios;
    }

    pub fn totalSize(self: Manifest, region: Region) usize {
        var total: usize = 0;
        for (self.entries) |entry| {
            if (entry.region == region) total += entry.size;
        }
        return total;
    }
};

pub const Error = error{
    InvalidEntry,
    MissingProgram,
    MissingSprites,
    MissingFixed,
    MissingAudioCpu,
    MissingSamples,
    MissingBios,
    SizeMismatch,
    HashMismatch,
};

fn testEntry(region: Region, name: []const u8, size: usize) Entry {
    return .{ .region = region, .name = name, .size = size, .sha256 = [_]u8{0xa5} ** 32 };
}

fn hashedTestEntry(region: Region, name: []const u8, bytes: []const u8) Entry {
    var sha256: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sha256, .{});
    return .{ .region = region, .name = name, .size = bytes.len, .sha256 = sha256 };
}

test "Neo Geo manifest requires all logical regions and totals repeated files" {
    const entries = [_]Entry{
        testEntry(.program, "p1.bin", 1024),
        testEntry(.sprites, "c1.bin", 2048),
        testEntry(.sprites, "c2.bin", 2048),
        testEntry(.fixed, "s1.bin", 512),
        testEntry(.audio_cpu, "m1.bin", 1024),
        testEntry(.samples, "v1.bin", 4096),
        testEntry(.bios, "sp-s2.sp1", 128),
    };
    const manifest = Manifest{ .entries = &entries };
    try manifest.validate();
    try std.testing.expectEqual(@as(usize, 4096), manifest.totalSize(.sprites));
    try std.testing.expectEqual(@as(usize, 4096), manifest.totalSize(.samples));
}

test "Neo Geo manifest rejects missing and malformed entries" {
    const incomplete = [_]Entry{testEntry(.program, "p1.bin", 1)};
    const incomplete_manifest = Manifest{ .entries = &incomplete };
    try std.testing.expectError(error.MissingSprites, incomplete_manifest.validate());

    const malformed = [_]Entry{testEntry(.program, "", 1)};
    const malformed_manifest = Manifest{ .entries = &malformed };
    try std.testing.expectError(error.InvalidEntry, malformed_manifest.validate());
}

test "Neo Geo entry validates only caller-owned bytes against SHA-256 metadata" {
    const bytes = "local-test-bytes";
    const entry = hashedTestEntry(.program, "p1.bin", bytes);
    try entry.verifyBytes(bytes);
    try std.testing.expectError(error.SizeMismatch, entry.verifyBytes(bytes[0..4]));
    try std.testing.expectError(error.HashMismatch, entry.verifyBytes("local-test-byteS"));
}
