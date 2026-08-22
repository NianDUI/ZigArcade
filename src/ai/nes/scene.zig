const std = @import("std");
const Mirroring = @import("../../systems/nes/cartridge.zig").Mirroring;
const ppu = @import("../../systems/nes/ppu.zig");

pub const background_columns = 32;
pub const background_rows = 30;
pub const background_cell_count = background_columns * background_rows;
pub const max_sprites = 64;
pub const max_shapes = 1024;
const shape_slot_capacity = 2048;

pub const ShapeKind = enum(u8) {
    tile_8x8 = 0,
    sprite_8x16 = 1,
};

/// `id` is derived from decoded pattern bytes and size mode, never from the
/// mapper-local tile number. Flips and palette are appearance data on cells
/// or sprites, so the same visual shape remains reusable.
pub const Shape = struct {
    id: u64,
    kind: ShapeKind,
    byte_len: u8,
    bytes: [32]u8,
};

pub const BackgroundCell = struct {
    shape_id: u64 = 0,
    palette: u2 = 0,
    visible: bool = false,
};

pub const Sprite = struct {
    oam_index: u6,
    x: u8,
    y: u8,
    shape_id: u64,
    palette: u2,
    flip_x: bool,
    flip_y: bool,
    behind_background: bool,
    on_screen: bool,
    size: ShapeKind,
};

/// A ROM-agnostic, fixed-capacity representation of the video information a
/// player can see. It contains no CPU RAM, game labels, or mutable emulator
/// pointer. Background cells sample the state at their top-left pixel; the
/// full raster event list preserves changes that occur inside a cell.
pub const Scene = struct {
    frame_number: u64,
    scroll_x: u8,
    scroll_y: u8,
    nametable: u2,
    ctrl: u8,
    mask: u8,
    mirroring: Mirroring,
    palette: [32]u8,
    cells: [background_cell_count]BackgroundCell,
    sprites: [max_sprites]Sprite,
    raster_events: [ppu.presentation_raster_event_capacity]ppu.PresentationRasterEvent,
    raster_event_count: usize,
    shapes: [max_shapes]Shape,
    shape_count: u16,
    shape_slots: [shape_slot_capacity]u16,

    pub fn findShape(self: *const Scene, id: u64) ?*const Shape {
        for (self.shapes[0..self.shape_count]) |*shape| {
            if (shape.id == id) return shape;
        }
        return null;
    }
};

pub const Error = error{
    InvalidRasterEventCount,
    ShapeCapacityExceeded,
};

pub fn build(snapshot: ppu.PresentationSnapshot) Error!Scene {
    if (snapshot.raster_event_count > ppu.presentation_raster_event_capacity) {
        return error.InvalidRasterEventCount;
    }

    var scene = Scene{
        .frame_number = snapshot.frame_number,
        .scroll_x = snapshot.scroll_x,
        .scroll_y = snapshot.scroll_y,
        .nametable = snapshot.nametable,
        .ctrl = snapshot.ctrl,
        .mask = snapshot.mask,
        .mirroring = snapshot.mirroring,
        .palette = snapshot.palette,
        .cells = undefined,
        .sprites = undefined,
        .raster_events = snapshot.raster_events,
        .raster_event_count = snapshot.raster_event_count,
        .shapes = undefined,
        .shape_count = 0,
        .shape_slots = [_]u16{0} ** shape_slot_capacity,
    };

    for (0..background_rows) |cell_y| {
        for (0..background_columns) |cell_x| {
            const screen_x = cell_x * 8;
            const screen_y = cell_y * 8;
            const state = rasterStateAt(snapshot, screen_x, screen_y);
            scene.cells[cell_y * background_columns + cell_x] = try backgroundCell(&scene, snapshot, state, screen_x, screen_y);
        }
    }

    for (0..max_sprites) |index| {
        const offset = index * 4;
        const raw_y = snapshot.oam[offset];
        const tile = snapshot.oam[offset + 1];
        const attributes = snapshot.oam[offset + 2];
        const x = snapshot.oam[offset + 3];
        const on_screen = raw_y < ppu.frame_height - 1;
        const screen_y: usize = if (on_screen) @as(usize, raw_y) + 1 else 0;
        const state = rasterStateAt(snapshot, x, screen_y);
        const size: ShapeKind = if (state.ctrl & 0x20 == 0) .tile_8x8 else .sprite_8x16;
        scene.sprites[index] = .{
            .oam_index = @intCast(index),
            .x = x,
            .y = raw_y,
            .shape_id = try spriteShape(&scene, snapshot, state.ctrl, tile),
            .palette = @truncate(attributes & 0x03),
            .flip_x = attributes & 0x40 != 0,
            .flip_y = attributes & 0x80 != 0,
            .behind_background = attributes & 0x20 != 0,
            .on_screen = on_screen,
            .size = size,
        };
    }
    return scene;
}

fn backgroundCell(
    scene: *Scene,
    snapshot: ppu.PresentationSnapshot,
    state: ppu.PresentationRasterState,
    screen_x: usize,
    screen_y: usize,
) Error!BackgroundCell {
    if (state.mask & 0x08 == 0 or (screen_x < 8 and state.mask & 0x02 == 0)) return .{};
    const world_x = (screen_x + state.scroll_x) % 512;
    const world_y = (screen_y + state.scroll_y) % 480;
    const base_x: usize = state.nametable & 1;
    const base_y: usize = state.nametable >> 1;
    const nametable_x = (base_x + world_x / 256) & 1;
    const nametable_y = (base_y + world_y / 240) & 1;
    const nametable_base = 0x2000 + ((nametable_y << 1 | nametable_x) << 10);
    const local_x = world_x % 256;
    const local_y = world_y % 240;
    const tile_x = local_x / 8;
    const tile_y = local_y / 8;
    const tile = snapshot.nametables[nametableIndex(snapshot.mirroring, nametable_base + tile_y * 32 + tile_x)];
    const attribute = snapshot.nametables[nametableIndex(snapshot.mirroring, nametable_base + 0x03c0 + (tile_y / 4) * 8 + tile_x / 4)];
    const attribute_shift: u3 = @intCast(((tile_y & 2) << 1) | (tile_x & 2));
    const pattern_base: usize = if (state.ctrl & 0x10 != 0) 0x1000 else 0;
    const pattern_address = pattern_base + @as(usize, tile) * 16;
    return .{
        .shape_id = try addShape(scene, .tile_8x8, snapshot.pattern[pattern_address..][0..16]),
        .palette = @truncate((attribute >> attribute_shift) & 0x03),
        .visible = true,
    };
}

fn spriteShape(scene: *Scene, snapshot: ppu.PresentationSnapshot, ctrl: u8, tile: u8) Error!u64 {
    var bytes: [32]u8 = [_]u8{0} ** 32;
    if (ctrl & 0x20 == 0) {
        const pattern_base: usize = if (ctrl & 0x08 != 0) 0x1000 else 0;
        const address = pattern_base + @as(usize, tile) * 16;
        @memcpy(bytes[0..16], snapshot.pattern[address..][0..16]);
        return addShape(scene, .tile_8x8, bytes[0..16]);
    }
    const pattern_base: usize = if (tile & 1 != 0) 0x1000 else 0;
    const top_address = pattern_base + @as(usize, tile & 0xfe) * 16;
    @memcpy(bytes[0..16], snapshot.pattern[top_address..][0..16]);
    @memcpy(bytes[16..32], snapshot.pattern[top_address + 16 ..][0..16]);
    return addShape(scene, .sprite_8x16, &bytes);
}

fn addShape(scene: *Scene, kind: ShapeKind, pattern: []const u8) Error!u64 {
    const id = shapeId(kind, pattern);
    var slot: usize = @truncate(id);
    slot &= shape_slot_capacity - 1;
    for (0..shape_slot_capacity) |_| {
        const stored = scene.shape_slots[slot];
        if (stored == 0) {
            if (scene.shape_count == max_shapes) return error.ShapeCapacityExceeded;
            const index: usize = scene.shape_count;
            var bytes: [32]u8 = [_]u8{0} ** 32;
            @memcpy(bytes[0..pattern.len], pattern);
            scene.shapes[index] = .{
                .id = id,
                .kind = kind,
                .byte_len = @intCast(pattern.len),
                .bytes = bytes,
            };
            scene.shape_count += 1;
            scene.shape_slots[slot] = @intCast(index + 1);
            return id;
        }
        const shape = scene.shapes[stored - 1];
        if (shape.id == id and shape.kind == kind and shape.byte_len == pattern.len and
            std.mem.eql(u8, shape.bytes[0..shape.byte_len], pattern)) return id;
        slot = (slot + 1) & (shape_slot_capacity - 1);
    }
    return error.ShapeCapacityExceeded;
}

fn shapeId(kind: ShapeKind, pattern: []const u8) u64 {
    var canonical: [33]u8 = undefined;
    canonical[0] = @intFromEnum(kind);
    @memcpy(canonical[1..][0..pattern.len], pattern);
    return std.hash.Wyhash.hash(0x517cc1b727220a95, canonical[0 .. pattern.len + 1]);
}

fn rasterStateAt(snapshot: ppu.PresentationSnapshot, screen_x: usize, screen_y: usize) ppu.PresentationRasterState {
    var state = ppu.PresentationRasterState{
        .scroll_x = snapshot.scroll_x,
        .scroll_y = snapshot.scroll_y,
        .nametable = snapshot.nametable,
        .ctrl = snapshot.ctrl,
        .mask = snapshot.mask,
    };
    for (snapshot.raster_events[0..snapshot.raster_event_count]) |event| {
        if (event.scanline > screen_y or (event.scanline == screen_y and event.dot > screen_x + 1)) break;
        state = event.state;
    }
    return state;
}

fn nametableIndex(mirroring: Mirroring, address: usize) usize {
    const mirrored = if (address >= 0x3000) address - 0x1000 else address;
    const relative = mirrored - 0x2000;
    const table = relative >> 10;
    const offset = relative & 0x03ff;
    const physical_table = switch (mirroring) {
        .vertical => table & 1,
        .horizontal => table >> 1,
        .single_screen_lower => 0,
        .single_screen_upper => 1,
    };
    return physical_table * 0x400 + offset;
}

fn blankSnapshot() ppu.PresentationSnapshot {
    const empty_event = ppu.PresentationRasterEvent{
        .scanline = 0,
        .dot = 0,
        .state = .{ .scroll_x = 0, .scroll_y = 0, .nametable = 0, .ctrl = 0, .mask = 0 },
    };
    return .{
        .frame_number = 12,
        .scroll_x = 0,
        .scroll_y = 0,
        .nametable = 0,
        .ctrl = 0,
        .mask = 0x0a,
        .mirroring = .horizontal,
        .oam = [_]u8{0xff} ** 256,
        .nametables = [_]u8{0} ** (2 * 1024),
        .pattern = [_]u8{0} ** 0x2000,
        .palette = [_]u8{0} ** 32,
        .raster_events = [_]ppu.PresentationRasterEvent{empty_event} ** ppu.presentation_raster_event_capacity,
        .raster_event_count = 0,
    };
}

test "scene uses presentation pattern content rather than tile number" {
    var snapshot = blankSnapshot();
    snapshot.nametables[0] = 1;
    snapshot.nametables[0x3c0] = 0x02;
    @memset(snapshot.pattern[16..32], 0x11);
    snapshot.oam[0..4].* = .{ 9, 2, 0xe3, 20 };
    @memset(snapshot.pattern[32..48], 0x22);

    const scene = try build(snapshot);
    const cell = scene.cells[0];
    try std.testing.expect(cell.visible);
    try std.testing.expectEqual(@as(u2, 2), cell.palette);
    try std.testing.expectEqual(@as(u8, 20), scene.sprites[0].x);
    try std.testing.expect(scene.sprites[0].on_screen);
    try std.testing.expect(scene.sprites[0].flip_x);
    try std.testing.expect(scene.sprites[0].flip_y);
    try std.testing.expect(scene.sprites[0].behind_background);
    try std.testing.expect(cell.shape_id != scene.sprites[0].shape_id);
    try std.testing.expectEqual(@as(u8, 0x11), scene.findShape(cell.shape_id).?.bytes[0]);

    snapshot.pattern[16] = 0x33;
    const changed = try build(snapshot);
    try std.testing.expect(cell.shape_id != changed.cells[0].shape_id);
}

test "scene applies raster scroll before sampling later background cells" {
    var snapshot = blankSnapshot();
    snapshot.nametables[0] = 1;
    snapshot.nametables[2] = 2;
    @memset(snapshot.pattern[16..32], 0x11);
    @memset(snapshot.pattern[32..48], 0x22);
    snapshot.raster_events[0] = .{
        .scanline = 0,
        .dot = 9,
        .state = .{ .scroll_x = 8, .scroll_y = 0, .nametable = 0, .ctrl = 0, .mask = 0x0a },
    };
    snapshot.raster_event_count = 1;

    const scene = try build(snapshot);
    try std.testing.expect(scene.cells[0].shape_id != scene.cells[1].shape_id);
    try std.testing.expectEqual(@as(u8, 0x11), scene.findShape(scene.cells[0].shape_id).?.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x22), scene.findShape(scene.cells[1].shape_id).?.bytes[0]);
    try std.testing.expectEqual(@as(usize, 1), scene.raster_event_count);
}
