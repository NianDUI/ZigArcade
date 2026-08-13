const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;
const TestBus = @import("bus.zig").TestBus;

pub const ExpectedState = struct {
    pc: u16,
    a: u8,
    x: u8,
    y: u8,
    status: u8,
    sp: u8,
    cycles: u64,
};

pub const Mismatch = struct {
    field: []const u8,
    expected: u64,
    actual: u64,
};

pub const Failure = struct {
    line_index: usize,
    mismatch: Mismatch,
};

/// Compares CPU state before executing an instruction. This is the stable
/// core used by the future `nestest.log` line parser and test-ROM runner.
pub fn compare(cpu: *const Cpu, expected: ExpectedState) ?Mismatch {
    if (cpu.pc != expected.pc) return .{ .field = "PC", .expected = expected.pc, .actual = cpu.pc };
    if (cpu.a != expected.a) return .{ .field = "A", .expected = expected.a, .actual = cpu.a };
    if (cpu.x != expected.x) return .{ .field = "X", .expected = expected.x, .actual = cpu.x };
    if (cpu.y != expected.y) return .{ .field = "Y", .expected = expected.y, .actual = cpu.y };
    if (@as(u8, @bitCast(cpu.status)) != expected.status) return .{
        .field = "P",
        .expected = expected.status,
        .actual = @as(u8, @bitCast(cpu.status)),
    };
    if (cpu.sp != expected.sp) return .{ .field = "SP", .expected = expected.sp, .actual = cpu.sp };
    if (cpu.cycles != expected.cycles) return .{ .field = "CYC", .expected = expected.cycles, .actual = cpu.cycles };
    return null;
}

/// Runs a deterministic sequence in the same order as `nestest.log`: inspect
/// CPU state before each instruction, then execute that instruction. The
/// caller controls the trace source, so no ROM/log is embedded in the repo.
pub fn run(cpu: *Cpu, bus: *TestBus, expected: []const ExpectedState) !?Failure {
    for (expected, 0..) |state, line_index| {
        if (compare(cpu, state)) |mismatch| return .{ .line_index = line_index, .mismatch = mismatch };
        _ = try cpu.step(bus);
    }
    return null;
}

/// Parses a machine-friendly trace line. The eventual `nestest` adapter only
/// needs to convert its human-oriented format into this canonical record.
/// Example: `PC=C000 A=00 X=00 Y=00 P=24 SP=FD CYC=7`
pub fn parseCanonical(line: []const u8) !ExpectedState {
    var result: ExpectedState = undefined;
    var seen: u7 = 0;
    var fields = std.mem.tokenizeAny(u8, line, " \t\r\n");
    while (fields.next()) |field| {
        const separator = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidTrace;
        const key = field[0..separator];
        const value = field[separator + 1 ..];
        if (std.mem.eql(u8, key, "PC")) {
            result.pc = try std.fmt.parseInt(u16, value, 16);
            seen |= 1 << 0;
        } else if (std.mem.eql(u8, key, "A")) {
            result.a = try std.fmt.parseInt(u8, value, 16);
            seen |= 1 << 1;
        } else if (std.mem.eql(u8, key, "X")) {
            result.x = try std.fmt.parseInt(u8, value, 16);
            seen |= 1 << 2;
        } else if (std.mem.eql(u8, key, "Y")) {
            result.y = try std.fmt.parseInt(u8, value, 16);
            seen |= 1 << 3;
        } else if (std.mem.eql(u8, key, "P")) {
            result.status = try std.fmt.parseInt(u8, value, 16);
            seen |= 1 << 4;
        } else if (std.mem.eql(u8, key, "SP")) {
            result.sp = try std.fmt.parseInt(u8, value, 16);
            seen |= 1 << 5;
        } else if (std.mem.eql(u8, key, "CYC")) {
            result.cycles = try std.fmt.parseInt(u64, value, 10);
            seen |= 1 << 6;
        } else return error.InvalidTrace;
    }
    if (seen != 0x7f) return error.InvalidTrace;
    return result;
}

/// Parses the CPU state section emitted by the standard `nestest.log` format.
/// The instruction disassembly and PPU columns deliberately remain ignored:
/// CPU trace validation owns PC/A/X/Y/P/SP/CYC, while PPU validation belongs
/// to P2. Example input begins `C000  4C ... A:00 X:00 ... CYC:7`.
pub fn parseNestest(line: []const u8) !ExpectedState {
    if (line.len < 4) return error.InvalidTrace;
    var result = ExpectedState{
        .pc = try std.fmt.parseInt(u16, line[0..4], 16),
        .a = undefined,
        .x = undefined,
        .y = undefined,
        .status = undefined,
        .sp = undefined,
        .cycles = undefined,
    };
    result.a = try parseTaggedHex(line, "A:");
    result.x = try parseTaggedHex(line, "X:");
    result.y = try parseTaggedHex(line, "Y:");
    result.status = try parseTaggedHex(line, "P:");
    result.sp = try parseTaggedHex(line, "SP:");
    result.cycles = try parseTaggedDecimal(line, "CYC:");
    return result;
}

fn parseTaggedHex(line: []const u8, tag: []const u8) !u8 {
    const start = (std.mem.indexOf(u8, line, tag) orelse return error.InvalidTrace) + tag.len;
    if (line.len < start + 2) return error.InvalidTrace;
    return std.fmt.parseInt(u8, line[start..][0..2], 16);
}

fn parseTaggedDecimal(line: []const u8, tag: []const u8) !u64 {
    const start = (std.mem.indexOf(u8, line, tag) orelse return error.InvalidTrace) + tag.len;
    const end = std.mem.indexOfAnyPos(u8, line, start, " \t\r\n") orelse line.len;
    return std.fmt.parseInt(u64, line[start..end], 10);
}

test "canonical trace parses and reports exact mismatch field" {
    const expected = try parseCanonical("PC=C000 A=00 X=01 Y=02 P=24 SP=FD CYC=7");
    var cpu: Cpu = .{
        .pc = 0xc000,
        .a = 0,
        .x = 1,
        .y = 2,
        .status = @bitCast(@as(u8, 0x24)),
        .sp = 0xfd,
        .cycles = 7,
    };
    try std.testing.expect(compare(&cpu, expected) == null);
    cpu.x = 3;
    const mismatch = compare(&cpu, expected).?;
    try std.testing.expectEqualStrings("X", mismatch.field);
    try std.testing.expectEqual(@as(u64, 1), mismatch.expected);
    try std.testing.expectEqual(@as(u64, 3), mismatch.actual);
}

test "nestest trace extracts CPU fields while ignoring PPU columns" {
    const state = try parseNestest(
        "C000  4C F5 C5  JMP $C5F5                       A:00 X:01 Y:02 P:24 SP:FD PPU:  0, 21 CYC:7",
    );
    try std.testing.expectEqual(@as(u16, 0xc000), state.pc);
    try std.testing.expectEqual(@as(u8, 0), state.a);
    try std.testing.expectEqual(@as(u8, 1), state.x);
    try std.testing.expectEqual(@as(u8, 2), state.y);
    try std.testing.expectEqual(@as(u8, 0x24), state.status);
    try std.testing.expectEqual(@as(u8, 0xfd), state.sp);
    try std.testing.expectEqual(@as(u64, 7), state.cycles);
}

test "trace runner compares before every step and returns first failure" {
    var bus: TestBus = .{};
    bus.memory[0x8000..][0..4].* = .{ 0xa9, 0x01, 0xe8, 0xea };
    var cpu: Cpu = .{ .pc = 0x8000, .cycles = 7 };
    const expected = [_]ExpectedState{
        .{ .pc = 0x8000, .a = 0, .x = 0, .y = 0, .status = 0x24, .sp = 0xfd, .cycles = 7 },
        .{ .pc = 0x8002, .a = 1, .x = 0, .y = 0, .status = 0x24, .sp = 0xfd, .cycles = 9 },
        .{ .pc = 0x8003, .a = 1, .x = 1, .y = 0, .status = 0x24, .sp = 0xfd, .cycles = 11 },
    };
    try std.testing.expect(try run(&cpu, &bus, &expected) == null);

    cpu = .{ .pc = 0x8000, .cycles = 7 };
    var bad = expected;
    bad[1].a = 2;
    const failure = (try run(&cpu, &bus, &bad)).?;
    try std.testing.expectEqual(@as(usize, 1), failure.line_index);
    try std.testing.expectEqualStrings("A", failure.mismatch.field);
}
