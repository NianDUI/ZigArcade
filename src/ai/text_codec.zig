const std = @import("std");
const observation = @import("observation.zig");
const scene = @import("nes/scene.zig");

pub const Error = observation.Header.Error || error{
    ExpectedKeyframe,
    UnsupportedSystem,
    FrameMismatch,
    InvalidShapeReference,
    ShapeCatalogFull,
    ResynchronizationRequired,
    OutputTooSmall,
};

/// Aliases remain stable between keyframes. Each keyframe starts a new
/// catalog, which bounds storage and gives the receiver an explicit resync
/// point before scrolling or animation exhausts it.
pub const ShapeCatalog = struct {
    ids: [scene.max_shapes]u64 = undefined,
    count: u16 = 0,

    pub fn reset(self: *ShapeCatalog) void {
        self.count = 0;
    }

    pub fn ensureScene(self: *ShapeCatalog, visual_scene: *const scene.Scene) Error!void {
        for (visual_scene.shapes[0..visual_scene.shape_count]) |shape| _ = try self.ensure(shape.id);
    }

    pub fn ensure(self: *ShapeCatalog, id: u64) Error!u16 {
        if (self.alias(id)) |found| return found;
        if (self.count == scene.max_shapes) return error.ShapeCatalogFull;
        const result = self.count;
        self.ids[result] = id;
        self.count += 1;
        return result;
    }

    pub fn alias(self: *const ShapeCatalog, id: u64) ?u16 {
        for (self.ids[0..self.count], 0..) |known, index| if (known == id) return @intCast(index);
        return null;
    }
};

/// Encodes a complete, self-contained observation. The stable grammar is
/// intentionally compact but human-readable so it can be used for protocol
/// samples before choosing a target-model tokenizer. `h` hashes the preceding
/// bytes of the line, avoiding a self-referential digest.
pub fn encodeKeyframe(header: observation.Header, visual_scene: *const scene.Scene, catalog: *ShapeCatalog, output: []u8) Error![]const u8 {
    var next_catalog = ShapeCatalog{};
    const encoded = try encodeKeyframeWithCatalog(header, visual_scene, &next_catalog, output);
    catalog.* = next_catalog;
    return encoded;
}

fn encodeKeyframeWithCatalog(header: observation.Header, visual_scene: *const scene.Scene, catalog: *ShapeCatalog, output: []u8) Error![]const u8 {
    try header.validate();
    if (header.kind != .keyframe) return error.ExpectedKeyframe;
    if (header.system != .nes) return error.UnsupportedSystem;
    if (header.frame != visual_scene.frame_number) return error.FrameMismatch;
    catalog.reset();
    try catalog.ensureScene(visual_scene);

    var writer = Writer{ .remaining = output };
    try writer.print("K v={d} q={d} f={d} r=", .{ header.version, header.sequence, header.frame });
    try writer.hex(&header.rom_sha256);
    try writer.write("\n");
    try encodeShapes(&writer, visual_scene, catalog);
    try encodePalette(&writer, visual_scene.palette);
    try encodeBackground(&writer, visual_scene, catalog);
    try encodeSprites(&writer, visual_scene, catalog);
    try encodeRaster(&writer, visual_scene);

    const body_len = writer.written(output);
    const hash = observation.stateHash(output[0..body_len]);
    try writer.write("h=");
    try writer.hex(&hash);
    try writer.write("\n");
    return output[0..writer.written(output)];
}

pub fn encodeDelta(header: observation.Header, base: *const scene.Scene, current: *const scene.Scene, catalog: *ShapeCatalog, output: []u8) Error![]const u8 {
    var next_catalog = catalog.*;
    const encoded = try encodeDeltaWithCatalog(header, base, current, &next_catalog, output);
    catalog.* = next_catalog;
    return encoded;
}

fn encodeDeltaWithCatalog(header: observation.Header, base: *const scene.Scene, current: *const scene.Scene, catalog: *ShapeCatalog, output: []u8) Error![]const u8 {
    try header.validate();
    if (header.kind != .delta) return error.ExpectedKeyframe;
    if (header.system != .nes) return error.UnsupportedSystem;
    if (header.frame != current.frame_number) return error.FrameMismatch;
    try ensureDeltaScene(catalog, base);
    const prior_shape_count = catalog.count;
    try ensureDeltaScene(catalog, current);

    var writer = Writer{ .remaining = output };
    var changed = false;
    try writer.print("D v={d} q={d} base={d} f={d}\nsh", .{ header.version, header.sequence, header.base_sequence, header.frame });
    for (current.shapes[0..current.shape_count]) |shape| {
        const alias = catalog.alias(shape.id) orelse return error.InvalidShapeReference;
        if (alias < prior_shape_count) continue;
        changed = true;
        try writer.print(" a{d}=", .{alias});
        try writer.hex(shape.bytes[0..shape.byte_len]);
        if (shape.kind == .sprite_8x16) try writer.write("/16");
    }
    try writer.write("\nbg");
    for (current.cells, 0..) |cell, index| {
        if (sameCell(cell, base.cells[index])) continue;
        changed = true;
        try writer.print(" {d}=", .{index});
        try encodeCell(&writer, catalog, cell);
    }
    try writer.write("\npal");
    for (current.palette, 0..) |entry, index| {
        if (entry == base.palette[index]) continue;
        changed = true;
        try writer.print(" {d}={x:0>2}", .{ index, entry & 0x3f });
    }
    try writer.write("\nsp");
    for (current.sprites, 0..) |sprite, index| {
        const base_visible = spriteVisible(base, base.sprites[index]);
        const current_visible = spriteVisible(current, sprite);
        if (base_visible == current_visible and (!current_visible or std.meta.eql(sprite, base.sprites[index]))) continue;
        changed = true;
        if (!current_visible) {
            try writer.print(" {d}=-", .{index});
            continue;
        }
        try encodeSprite(&writer, catalog, sprite);
    }
    if (!sameRaster(base, current)) {
        changed = true;
        try writer.write("\n");
        try encodeRaster(&writer, current);
    } else try writer.write("\n");
    if (!changed) try writer.write("idle\n");
    const body_len = writer.written(output);
    const hash = observation.stateHash(output[0..body_len]);
    try writer.write("h=");
    try writer.hex(&hash);
    try writer.write("\n");
    return output[0..writer.written(output)];
}

fn ensureDeltaScene(catalog: *ShapeCatalog, visual_scene: *const scene.Scene) Error!void {
    for (visual_scene.shapes[0..visual_scene.shape_count]) |shape| {
        if (catalog.alias(shape.id) != null) continue;
        if (catalog.count == scene.max_shapes) return error.ResynchronizationRequired;
        _ = try catalog.ensure(shape.id);
    }
}

fn sameRaster(left: *const scene.Scene, right: *const scene.Scene) bool {
    return left.scroll_x == right.scroll_x and left.scroll_y == right.scroll_y and left.nametable == right.nametable and
        left.ctrl == right.ctrl and left.mask == right.mask and left.raster_event_count == right.raster_event_count and
        std.meta.eql(left.raster_events, right.raster_events);
}

fn encodeShapes(writer: *Writer, visual_scene: *const scene.Scene, catalog: *const ShapeCatalog) Error!void {
    try writer.write("sh");
    for (visual_scene.shapes[0..visual_scene.shape_count]) |shape| {
        const alias = catalog.alias(shape.id) orelse return error.InvalidShapeReference;
        try writer.print(" a{d}=", .{alias});
        try writer.hex(shape.bytes[0..shape.byte_len]);
        if (shape.kind == .sprite_8x16) try writer.write("/16");
    }
    try writer.write("\n");
}

fn encodePalette(writer: *Writer, palette: [32]u8) Error!void {
    try writer.write("pal");
    for (palette, 0..) |entry, index| try writer.print(" {d}={x:0>2}", .{ index, entry & 0x3f });
    try writer.write("\n");
}

fn encodeBackground(writer: *Writer, visual_scene: *const scene.Scene, catalog: *const ShapeCatalog) Error!void {
    try writer.write("bg ");
    for (0..scene.background_rows) |row| {
        if (row != 0) try writer.write("/");
        var column: usize = 0;
        while (column < scene.background_columns) {
            const cell = visual_scene.cells[row * scene.background_columns + column];
            var run: usize = 1;
            while (column + run < scene.background_columns and sameCell(cell, visual_scene.cells[row * scene.background_columns + column + run])) {
                run += 1;
            }
            if (column != 0) try writer.write(",");
            try encodeCell(writer, catalog, cell);
            if (run > 1) try writer.print("*{d}", .{run});
            column += run;
        }
    }
    try writer.write("\n");
}

fn encodeCell(writer: *Writer, catalog: *const ShapeCatalog, cell: scene.BackgroundCell) Error!void {
    if (!cell.visible) return writer.write(".");
    const alias = catalog.alias(cell.shape_id) orelse return error.InvalidShapeReference;
    try writer.print("a{d}/p{d}", .{ alias, cell.palette });
}

fn encodeSprites(writer: *Writer, visual_scene: *const scene.Scene, catalog: *const ShapeCatalog) Error!void {
    try writer.write("sp");
    for (visual_scene.sprites) |sprite| {
        if (!spriteVisible(visual_scene, sprite)) continue;
        try encodeSprite(writer, catalog, sprite);
    }
    try writer.write("\n");
}

fn encodeSprite(writer: *Writer, catalog: *const ShapeCatalog, sprite: scene.Sprite) Error!void {
    const alias = catalog.alias(sprite.shape_id) orelse return error.InvalidShapeReference;
    try writer.print(" {d}@{d},{d}:a{d},p{d}", .{ sprite.oam_index, sprite.x, @as(u16, sprite.y) + 1, alias, sprite.palette });
    if (sprite.flip_x) try writer.write(",fx");
    if (sprite.flip_y) try writer.write(",fy");
    if (sprite.behind_background) try writer.write(",bg");
}

fn spriteVisible(visual_scene: *const scene.Scene, sprite: scene.Sprite) bool {
    if (!sprite.on_screen) return false;
    const shape = visual_scene.findShape(sprite.shape_id) orelse return false;
    const height: usize = if (sprite.size == .sprite_8x16) 16 else 8;
    for (0..height) |local_y| {
        const screen_y = @as(usize, sprite.y) + 1 + local_y;
        if (screen_y >= 240) continue;
        const source_y = if (sprite.flip_y) height - 1 - local_y else local_y;
        const tile_offset = (source_y / 8) * 16;
        const row = source_y & 7;
        const low = shape.bytes[tile_offset + row];
        const high = shape.bytes[tile_offset + 8 + row];
        for (0..8) |local_x| {
            const screen_x = @as(usize, sprite.x) + local_x;
            if (screen_x >= 256) continue;
            const source_x = if (sprite.flip_x) local_x else 7 - local_x;
            if (((low >> @as(u3, @intCast(source_x))) | (high >> @as(u3, @intCast(source_x)))) & 1 == 0) continue;
            const state = rasterStateAtScene(visual_scene, screen_x, screen_y);
            if (state.mask & 0x10 != 0 and (screen_x >= 8 or state.mask & 0x04 != 0)) return true;
        }
    }
    return false;
}

fn rasterStateAtScene(visual_scene: *const scene.Scene, screen_x: usize, screen_y: usize) @import("../systems/nes/ppu.zig").PresentationRasterState {
    const ppu = @import("../systems/nes/ppu.zig");
    var state = ppu.PresentationRasterState{
        .scroll_x = visual_scene.scroll_x,
        .scroll_y = visual_scene.scroll_y,
        .nametable = visual_scene.nametable,
        .ctrl = visual_scene.ctrl,
        .mask = visual_scene.mask,
    };
    for (visual_scene.raster_events[0..visual_scene.raster_event_count]) |event| {
        if (event.scanline > screen_y or (event.scanline == screen_y and event.dot > screen_x + 1)) break;
        state = event.state;
    }
    return state;
}

fn encodeRaster(writer: *Writer, visual_scene: *const scene.Scene) Error!void {
    try writer.print("rs s{d},{d},n{d},c{x:0>2},m{x:0>2}", .{
        visual_scene.scroll_x,
        visual_scene.scroll_y,
        visual_scene.nametable,
        visual_scene.ctrl,
        visual_scene.mask,
    });
    for (visual_scene.raster_events[0..visual_scene.raster_event_count]) |event| {
        try writer.print(" y{d}d{d}:s{d},{d},n{d},c{x:0>2},m{x:0>2}", .{
            event.scanline,
            event.dot,
            event.state.scroll_x,
            event.state.scroll_y,
            event.state.nametable,
            event.state.ctrl,
            event.state.mask,
        });
    }
    try writer.write("\n");
}

fn sameCell(left: scene.BackgroundCell, right: scene.BackgroundCell) bool {
    return left.shape_id == right.shape_id and left.palette == right.palette and left.visible == right.visible;
}

const Writer = struct {
    remaining: []u8,

    fn write(self: *Writer, text: []const u8) Error!void {
        if (text.len > self.remaining.len) return error.OutputTooSmall;
        @memcpy(self.remaining[0..text.len], text);
        self.remaining = self.remaining[text.len..];
    }

    fn print(self: *Writer, comptime format: []const u8, args: anytype) Error!void {
        const formatted = std.fmt.bufPrint(self.remaining, format, args) catch return error.OutputTooSmall;
        self.remaining = self.remaining[formatted.len..];
    }

    fn hex(self: *Writer, bytes: []const u8) Error!void {
        const digits = "0123456789abcdef";
        if (bytes.len * 2 > self.remaining.len) return error.OutputTooSmall;
        for (bytes) |byte| {
            self.remaining[0] = digits[byte >> 4];
            self.remaining[1] = digits[byte & 0x0f];
            self.remaining = self.remaining[2..];
        }
    }

    fn written(self: Writer, output: []const u8) usize {
        return output.len - self.remaining.len;
    }
};

fn sampleSnapshot() @import("../systems/nes/ppu.zig").PresentationSnapshot {
    const ppu = @import("../systems/nes/ppu.zig");
    const empty_event = ppu.PresentationRasterEvent{
        .scanline = 0,
        .dot = 0,
        .state = .{ .scroll_x = 0, .scroll_y = 0, .nametable = 0, .ctrl = 0, .mask = 0 },
    };
    var snapshot = ppu.PresentationSnapshot{
        .frame_number = 12,
        .scroll_x = 0,
        .scroll_y = 0,
        .nametable = 0,
        .ctrl = 0,
        .mask = 0x1a,
        .mirroring = .horizontal,
        .oam = [_]u8{0xff} ** 256,
        .nametables = [_]u8{0} ** (2 * 1024),
        .pattern = [_]u8{0} ** 0x2000,
        .palette = [_]u8{0} ** 32,
        .raster_events = [_]ppu.PresentationRasterEvent{empty_event} ** ppu.presentation_raster_event_capacity,
        .raster_event_count = 0,
    };
    snapshot.nametables[0] = 1;
    @memset(snapshot.pattern[16..32], 0x11);
    snapshot.oam[0..4].* = .{ 9, 1, 0, 20 };
    return snapshot;
}

test "keyframe text is deterministic and bounded" {
    var snapshot = sampleSnapshot();
    snapshot.palette[0] = 0x21;
    const visual_scene = try scene.build(snapshot);
    const header = observation.Header{
        .system = .nes,
        .rom_sha256 = [_]u8{0} ** 32,
        .sequence = 3,
        .base_sequence = 0,
        .frame = 12,
        .kind = .keyframe,
    };
    var first: [8192]u8 = undefined;
    var second: [8192]u8 = undefined;
    var catalog = ShapeCatalog{};
    const encoded_first = try encodeKeyframe(header, &visual_scene, &catalog, &first);
    const encoded_second = try encodeKeyframe(header, &visual_scene, &catalog, &second);
    try std.testing.expectEqualSlices(u8, encoded_first, encoded_second);
    try std.testing.expect(std.mem.indexOf(u8, encoded_first, "K v=1 q=3 f=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_first, "sp 0@20,10") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_first, "pal 0=21") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_first, "h=") != null);
    var too_small: [8]u8 = undefined;
    try std.testing.expectError(error.OutputTooSmall, encodeKeyframe(header, &visual_scene, &catalog, &too_small));
}

test "delta includes palette changes and complete sprite patches" {
    const base = try scene.build(sampleSnapshot());
    var next_snapshot = sampleSnapshot();
    next_snapshot.frame_number = 13;
    next_snapshot.palette[0x11] = 0x21;
    next_snapshot.oam[2] = 0x60;
    const current = try scene.build(next_snapshot);
    var catalog = ShapeCatalog{};
    var storage: [8192]u8 = undefined;
    _ = try encodeKeyframe(.{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 1, .base_sequence = 0, .frame = 12, .kind = .keyframe }, &base, &catalog, &storage);
    const encoded = try encodeDelta(.{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 2, .base_sequence = 1, .frame = 13, .kind = .delta }, &base, &current, &catalog, &storage);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "pal 17=21") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "sp 0@20,10:") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, ",fx,bg") != null);
}

test "delta explicitly removes a no-longer-visible sprite" {
    const base = try scene.build(sampleSnapshot());
    var next_snapshot = sampleSnapshot();
    next_snapshot.frame_number = 13;
    next_snapshot.oam[0] = 0xff;
    const current = try scene.build(next_snapshot);
    var catalog = ShapeCatalog{};
    var storage: [8192]u8 = undefined;
    _ = try encodeKeyframe(.{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 1, .base_sequence = 0, .frame = 12, .kind = .keyframe }, &base, &catalog, &storage);
    const encoded = try encodeDelta(.{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 2, .base_sequence = 1, .frame = 13, .kind = .delta }, &base, &current, &catalog, &storage);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "sp 0=-") != null);
}

test "encoding failure leaves the shape catalog unchanged" {
    const base = try scene.build(sampleSnapshot());
    var next_snapshot = sampleSnapshot();
    next_snapshot.frame_number = 13;
    next_snapshot.nametables[0] = 2;
    @memset(next_snapshot.pattern[32..48], 0x22);
    const current = try scene.build(next_snapshot);
    var catalog = ShapeCatalog{};
    var storage: [8192]u8 = undefined;
    _ = try encodeKeyframe(.{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 1, .base_sequence = 0, .frame = 12, .kind = .keyframe }, &base, &catalog, &storage);
    const count_before = catalog.count;
    var too_small: [8]u8 = undefined;
    try std.testing.expectError(error.OutputTooSmall, encodeDelta(.{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 2, .base_sequence = 1, .frame = 13, .kind = .delta }, &base, &current, &catalog, &too_small));
    try std.testing.expectEqual(count_before, catalog.count);
}

test "keyframe excludes left-clipped sprites" {
    var snapshot = sampleSnapshot();
    snapshot.oam[3] = 0;
    const visual_scene = try scene.build(snapshot);
    var catalog = ShapeCatalog{};
    var storage: [8192]u8 = undefined;
    const encoded = try encodeKeyframe(.{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 1, .base_sequence = 0, .frame = 12, .kind = .keyframe }, &visual_scene, &catalog, &storage);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "sp 0@") == null);
}

test "keyframe retains sprites with visible pixels beyond the left clip" {
    var snapshot = sampleSnapshot();
    snapshot.oam[3] = 7;
    const visual_scene = try scene.build(snapshot);
    var catalog = ShapeCatalog{};
    var storage: [8192]u8 = undefined;
    const encoded = try encodeKeyframe(.{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 1, .base_sequence = 0, .frame = 12, .kind = .keyframe }, &visual_scene, &catalog, &storage);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "sp 0@7,10:") != null);
}

test "keyframes reset a full catalog and deltas request resynchronization" {
    const visual_scene = try scene.build(sampleSnapshot());
    var catalog = ShapeCatalog{ .ids = [_]u64{0} ** scene.max_shapes, .count = scene.max_shapes };
    var storage: [8192]u8 = undefined;
    _ = try encodeKeyframe(.{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 1, .base_sequence = 0, .frame = 12, .kind = .keyframe }, &visual_scene, &catalog, &storage);
    try std.testing.expect(catalog.count < scene.max_shapes);

    catalog = .{ .ids = [_]u64{0} ** scene.max_shapes, .count = scene.max_shapes };
    try std.testing.expectError(error.ResynchronizationRequired, encodeDelta(
        .{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 2, .base_sequence = 1, .frame = 12, .kind = .delta },
        &visual_scene,
        &visual_scene,
        &catalog,
        &storage,
    ));
}

test "delta preserves episode aliases and sends only changed cells" {
    const base = try scene.build(sampleSnapshot());
    var next_snapshot = sampleSnapshot();
    next_snapshot.frame_number = 13;
    next_snapshot.nametables[0] = 2;
    @memset(next_snapshot.pattern[32..48], 0x22);
    const current = try scene.build(next_snapshot);
    var catalog = ShapeCatalog{};
    var keyframe: [8192]u8 = undefined;
    _ = try encodeKeyframe(.{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 1, .base_sequence = 0, .frame = 12, .kind = .keyframe }, &base, &catalog, &keyframe);
    const original_alias = catalog.alias(base.cells[0].shape_id).?;
    var output: [8192]u8 = undefined;
    const encoded = try encodeDelta(.{ .system = .nes, .rom_sha256 = [_]u8{0} ** 32, .sequence = 2, .base_sequence = 1, .frame = 13, .kind = .delta }, &base, &current, &catalog, &output);
    try std.testing.expectEqual(original_alias, catalog.alias(base.cells[0].shape_id).?);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "D v=1 q=2 base=1 f=13") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "bg 0=") != null);
}
