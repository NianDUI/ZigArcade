const std = @import("std");
const Mapper = @import("mapper.zig").Mapper;
const Mapper0 = @import("mapper0.zig").Mapper0;
const Mirroring = @import("cartridge.zig").Mirroring;

pub const frame_width = 256;
pub const frame_height = 240;
pub const frame_rgb_bytes = frame_width * frame_height * 3;

pub const RenderError = error{InvalidFrameBuffer};

/// A fixed NTSC-oriented palette for the first framebuffer path. Palette RAM
/// supplies the 6-bit index; this table supplies its host RGB representation.
const rgb_palette = [_][3]u8{
    .{ 84, 84, 84 },    .{ 0, 30, 116 },    .{ 8, 16, 144 },    .{ 48, 0, 136 },
    .{ 68, 0, 100 },    .{ 92, 0, 48 },     .{ 84, 4, 0 },      .{ 60, 24, 0 },
    .{ 32, 42, 0 },     .{ 8, 58, 0 },      .{ 0, 64, 0 },      .{ 0, 60, 0 },
    .{ 0, 50, 60 },     .{ 0, 0, 0 },       .{ 0, 0, 0 },       .{ 0, 0, 0 },
    .{ 152, 150, 152 }, .{ 8, 76, 196 },    .{ 48, 50, 236 },   .{ 92, 30, 228 },
    .{ 136, 20, 176 },  .{ 160, 20, 100 },  .{ 152, 34, 32 },   .{ 120, 60, 0 },
    .{ 84, 90, 0 },     .{ 40, 114, 0 },    .{ 8, 124, 0 },     .{ 0, 118, 40 },
    .{ 0, 102, 120 },   .{ 0, 0, 0 },       .{ 0, 0, 0 },       .{ 0, 0, 0 },
    .{ 236, 238, 236 }, .{ 76, 154, 236 },  .{ 120, 124, 236 }, .{ 176, 98, 236 },
    .{ 228, 84, 236 },  .{ 236, 88, 180 },  .{ 236, 106, 100 }, .{ 212, 136, 32 },
    .{ 160, 170, 0 },   .{ 116, 196, 0 },   .{ 76, 208, 32 },   .{ 56, 204, 108 },
    .{ 56, 180, 204 },  .{ 60, 60, 60 },    .{ 0, 0, 0 },       .{ 0, 0, 0 },
    .{ 236, 238, 236 }, .{ 168, 204, 236 }, .{ 188, 188, 236 }, .{ 212, 178, 236 },
    .{ 236, 174, 236 }, .{ 236, 174, 212 }, .{ 236, 180, 176 }, .{ 228, 196, 144 },
    .{ 204, 210, 120 }, .{ 180, 222, 120 }, .{ 168, 226, 144 }, .{ 152, 226, 180 },
    .{ 160, 214, 228 }, .{ 160, 162, 160 }, .{ 0, 0, 0 },       .{ 0, 0, 0 },
};

/// RP2C02 register and memory slice. `tickDot` is the sole timing source;
/// background/sprite fetch and rasterization will extend it without replacing
/// the dot clock contract established here.
pub const Ppu = struct {
    mapper: Mapper,
    nametables: [2 * 1024]u8 = [_]u8{0} ** (2 * 1024),
    palette: [32]u8 = [_]u8{0} ** 32,
    oam: [256]u8 = [_]u8{0} ** 256,

    ctrl: u8 = 0,
    mask: u8 = 0,
    status: u8 = 0,
    oam_addr: u8 = 0,
    v: u16 = 0,
    t: u16 = 0,
    fine_x: u3 = 0,
    /// CPU writes configure the *next* visible state. The frame renderer
    /// samples a separate copy at VBlank, before a game's next NMI starts
    /// using the PPU registers as temporary VRAM-update registers.
    pending_scroll_x: u8 = 0,
    pending_scroll_y: u8 = 0,
    pending_nametable: u2 = 0,
    presentation_scroll_x: u8 = 0,
    presentation_scroll_y: u8 = 0,
    presentation_nametable: u2 = 0,
    presentation_ctrl: u8 = 0,
    presentation_mask: u8 = 0,
    // The simplified renderer samples a whole frame at VBlank, but games
    // commonly split the next frame after Sprite 0. Keep the initial display
    // state for hit detection separate from later gameplay scroll writes.
    sprite_zero_scroll_x: u8 = 0,
    sprite_zero_scroll_y: u8 = 0,
    sprite_zero_nametable: u2 = 0,
    sprite_zero_ctrl: u8 = 0,
    sprite_zero_setup_pending: bool = true,
    sprite_zero_scroll_writes: u2 = 0,
    sprite_zero_ctrl_captured: bool = false,
    write_toggle: bool = false,
    read_buffer: u8 = 0,
    open_bus: u8 = 0,
    scanline: u16 = 0,
    dot: u16 = 0,
    frame_number: u64 = 0,
    nmi_pending: bool = false,
    /// Observable timing telemetry for diagnosing games that synchronize on
    /// PPUSTATUS bit 6. It does not influence emulation state or rendering.
    sprite_zero_hit_count: u64 = 0,
    last_sprite_zero_hit_frame: u64 = 0,
    last_sprite_zero_hit_scanline: u16 = 0,
    last_sprite_zero_hit_dot: u16 = 0,

    pub fn init(mapper: anytype) Ppu {
        return switch (@TypeOf(mapper)) {
            Mapper => .{ .mapper = mapper },
            *Mapper0 => .{ .mapper = Mapper.fromMapper0(mapper) },
            else => @compileError("Ppu.init expects Mapper or *Mapper0"),
        };
    }

    /// Advances exactly one NTSC PPU dot and latches an NMI edge at the
    /// start of VBlank when PPUCTRL enables it.
    pub fn tickDot(self: *Ppu) void {
        if (self.scanline == 241 and self.dot == 1) {
            self.latchPresentationState();
            self.latchSpriteZeroState();
            self.status |= 0x80;
            if (self.ctrl & 0x80 != 0) self.nmi_pending = true;
        } else if (self.scanline == 261 and self.dot == 1) {
            self.status &= ~@as(u8, 0x80);
            self.status &= ~@as(u8, 0x40); // sprite-0 hit
            self.status &= ~@as(u8, 0x20); // sprite overflow
        }
        if (self.scanline < frame_height) {
            if (self.dot == 65) self.clockSpriteOverflow();
            if (self.dot > 0 and self.dot <= frame_width) self.clockSpriteZeroHit(@intCast(self.dot - 1));
        }

        // NTSC odd frames omit the final pre-render dot while either layer
        // is enabled. Keep this in the canonical dot clock: render sampling
        // never adjusts timing on its own.
        if (self.scanline == 261 and self.dot == 339 and self.frame_number & 1 != 0 and self.renderingEnabled()) {
            self.dot = 0;
            self.scanline = 0;
            self.frame_number += 1;
            return;
        }

        self.dot += 1;
        if (self.dot == 341) {
            self.dot = 0;
            self.scanline += 1;
            if (self.scanline == 262) {
                self.scanline = 0;
                self.frame_number += 1;
            }
        }
    }

    fn renderingEnabled(self: *const Ppu) bool {
        return self.mask & 0x18 != 0;
    }

    /// Evaluates the pixel currently passing the sprite-0 detector. This is
    /// deliberately part of the dot clock rather than the host renderer:
    /// games such as Super Mario Bros. poll $2002 during the visible region
    /// and use the hit to install their gameplay scroll after the status bar.
    ///
    /// The full background fetch pipeline is still outside this first PPU
    /// slice, but the register-visible result follows its practical rules:
    /// both layers and left-edge rendering must be enabled, the sprite pixel
    /// must be non-transparent, and it must overlap a non-transparent
    /// background pixel.
    fn clockSpriteZeroHit(self: *Ppu, screen_x: usize) void {
        if (self.status & 0x40 != 0) return;
        if (self.mask & 0x18 != 0x18) return;
        if (screen_x == 255) return;

        const sprite_y = @as(usize, self.oam[0]) + 1;
        const sprite_height: usize = if (self.sprite_zero_ctrl & 0x20 != 0) 16 else 8;
        if (self.scanline < sprite_y or self.scanline >= sprite_y + sprite_height) return;

        const sprite_x = @as(usize, self.oam[3]);
        if (screen_x < sprite_x or screen_x >= sprite_x + 8) return;
        if (screen_x < 8 and (self.mask & 0x06) != 0x06) return;

        const attributes = self.oam[2];
        const local_y = @as(usize, self.scanline) - sprite_y;
        const source_y = if (attributes & 0x80 != 0) sprite_height - 1 - local_y else local_y;
        const tile_address = spriteTileAddressForControl(self.sprite_zero_ctrl, self.oam[1], source_y);
        const local_x = screen_x - sprite_x;
        const source_x = if (attributes & 0x40 != 0) local_x else 7 - local_x;
        const bit: u3 = @intCast(source_x);
        const sprite_color = ((self.readMemory(tile_address) >> bit) & 1) |
            (((self.readMemory(tile_address + 8) >> bit) & 1) << 1);
        if (sprite_color == 0) return;
        if (!self.currentBackgroundOpaque(screen_x, self.scanline)) return;

        self.status |= 0x40;
        self.sprite_zero_hit_count += 1;
        self.last_sprite_zero_hit_frame = self.frame_number;
        self.last_sprite_zero_hit_scanline = self.scanline;
        self.last_sprite_zero_hit_dot = self.dot;
    }

    pub fn spriteZeroHitTelemetry(self: *const Ppu) SpriteZeroHitTelemetry {
        return .{
            .count = self.sprite_zero_hit_count,
            .frame = self.last_sprite_zero_hit_frame,
            .scanline = self.last_sprite_zero_hit_scanline,
            .dot = self.last_sprite_zero_hit_dot,
        };
    }

    /// Sprite evaluation starts shortly after each visible scanline begins.
    /// Model the useful overflow result at its first observable point, rather
    /// than leaking it from the asynchronous host-frame renderer.
    fn clockSpriteOverflow(self: *Ppu) void {
        if (self.mask & 0x18 == 0) return;
        if (self.spritesThroughIndexOnScanline(63, self.scanline, if (self.ctrl & 0x20 != 0) 16 else 8) > 8) {
            self.status |= 0x20;
        }
    }

    fn spriteTileAddressForControl(ctrl: u8, tile: u8, source_y: usize) u16 {
        if (ctrl & 0x20 == 0) {
            const pattern_base: u16 = if (ctrl & 0x08 != 0) 0x1000 else 0;
            return pattern_base + @as(u16, tile) * 16 + @as(u16, @intCast(source_y));
        }
        const pattern_base: u16 = if (tile & 1 != 0) 0x1000 else 0;
        const tile_number = (tile & 0xfe) + @as(u8, @intCast(source_y / 8));
        return pattern_base + @as(u16, tile_number) * 16 + @as(u16, @intCast(source_y & 7));
    }

    fn currentBackgroundOpaque(self: *const Ppu, screen_x: usize, screen_y: usize) bool {
        if (screen_x < 8 and self.mask & 0x02 == 0) return false;
        const world_x = (screen_x + self.sprite_zero_scroll_x) % 512;
        const world_y = (screen_y + self.sprite_zero_scroll_y) % 480;
        const base_x: u16 = self.sprite_zero_nametable & 1;
        const base_y: u16 = self.sprite_zero_nametable >> 1;
        const nametable_x = (base_x + @as(u16, @intCast(world_x / 256))) & 1;
        const nametable_y = (base_y + @as(u16, @intCast(world_y / 240))) & 1;
        const nametable_base = 0x2000 + ((nametable_y << 1 | nametable_x) << 10);
        const local_x = world_x % 256;
        const local_y = world_y % 240;
        const tile = self.readMemory(nametable_base + @as(u16, @intCast((local_y / 8) * 32 + local_x / 8)));
        const row: u16 = @intCast(local_y & 7);
        const pattern_base: u16 = if (self.sprite_zero_ctrl & 0x10 != 0) 0x1000 else 0;
        const tile_address = pattern_base + @as(u16, tile) * 16 + row;
        const shift: u3 = @intCast(7 - (local_x & 7));
        return ((self.readMemory(tile_address) >> shift) & 1) |
            ((self.readMemory(tile_address + 8) >> shift) & 1) != 0;
    }

    /// Captures the configuration that produced the just-finished visible
    /// frame. It deliberately runs before the VBlank NMI handler can reset
    /// $2005/$2006 while uploading data for the following frame.
    fn latchPresentationState(self: *Ppu) void {
        self.presentation_scroll_x = self.pending_scroll_x;
        self.presentation_scroll_y = self.pending_scroll_y;
        self.presentation_nametable = self.pending_nametable;
        self.presentation_ctrl = self.ctrl;
        self.presentation_mask = self.mask;
    }

    fn latchSpriteZeroState(self: *Ppu) void {
        self.sprite_zero_scroll_x = self.pending_scroll_x;
        self.sprite_zero_scroll_y = self.pending_scroll_y;
        self.sprite_zero_nametable = self.pending_nametable;
        self.sprite_zero_ctrl = self.ctrl;
        self.sprite_zero_setup_pending = true;
        self.sprite_zero_scroll_writes = 0;
        self.sprite_zero_ctrl_captured = false;
    }

    pub fn takeNmi(self: *Ppu) bool {
        const pending = self.nmi_pending;
        self.nmi_pending = false;
        return pending;
    }

    /// OAM DMA uses the same auto-increment behavior as a CPU write to
    /// $2004, but bypasses CPU register routing because it is a PPU-side bus.
    pub fn dmaWrite(self: *Ppu, value: u8) void {
        self.oam[self.oam_addr] = value;
        self.oam_addr +%= 1;
    }

    /// Renders the current background state into a 256x240 RGB buffer. It is
    /// intentionally a presentation readout: all PPU timing stays in
    /// `tickDot`. It uses the VBlank-latched state of the completed frame,
    /// never the mutable CPU VRAM-update latches.
    pub fn renderBackground(self: *const Ppu, rgb: []u8) RenderError!void {
        return self.renderBackgroundWithOpacity(rgb, null);
    }

    /// Same background rendering path, additionally writing one byte per
    /// pixel whose non-zero value means a non-transparent background pattern
    /// color. This is kept separate from host RGB for sprite priority.
    pub fn renderBackgroundWithOpacity(self: *const Ppu, rgb: []u8, opacity: ?[]u8) RenderError!void {
        if (rgb.len != frame_rgb_bytes) return error.InvalidFrameBuffer;
        if (opacity) |buffer| if (buffer.len != frame_width * frame_height) return error.InvalidFrameBuffer;
        if (self.presentation_mask & 0x08 == 0) {
            const backdrop = rgbForPaletteIndex(self.palette[0]);
            for (0..frame_width * frame_height) |pixel| {
                rgb[pixel * 3 ..][0..3].* = backdrop;
                if (opacity) |buffer| buffer[pixel] = 0;
            }
            return;
        }
        const pattern_base: u16 = if (self.presentation_ctrl & 0x10 != 0) 0x1000 else 0;
        const scroll_x = self.presentation_scroll_x;
        const scroll_y = self.presentation_scroll_y;
        const base_nametable = self.presentation_nametable;
        for (0..frame_height) |y| {
            for (0..frame_width) |x| {
                if (x < 8 and self.presentation_mask & 0x02 == 0) {
                    const offset = (y * frame_width + x) * 3;
                    rgb[offset..][0..3].* = rgbForPaletteIndex(self.palette[0]);
                    if (opacity) |buffer| buffer[y * frame_width + x] = 0;
                    continue;
                }
                const world_x = (x + scroll_x) % 512;
                const world_y = (y + scroll_y) % 480;
                const base_x: u16 = base_nametable & 1;
                const base_y: u16 = base_nametable >> 1;
                const nametable_x = (base_x + @as(u16, @intCast(world_x / 256))) & 1;
                const nametable_y = (base_y + @as(u16, @intCast(world_y / 240))) & 1;
                const nametable_base = 0x2000 + ((nametable_y << 1 | nametable_x) << 10);
                const local_x = world_x % 256;
                const local_y = world_y % 240;
                const tile_x = local_x / 8;
                const tile_y = local_y / 8;
                const row = local_y & 7;
                const tile = self.readMemory(nametable_base + @as(u16, @intCast(tile_y * 32 + tile_x)));
                const tile_address = pattern_base + @as(u16, tile) * 16 + @as(u16, @intCast(row));
                const low_plane = self.readMemory(tile_address);
                const high_plane = self.readMemory(tile_address + 8);
                const shift: u3 = @intCast(7 - (local_x & 7));
                const color_low = (low_plane >> shift) & 1;
                const color_high = (high_plane >> shift) & 1;
                const color: u8 = color_low | (color_high << 1);

                const attribute_address = nametable_base + 0x03c0 +
                    @as(u16, @intCast((tile_y / 4) * 8 + tile_x / 4));
                const attribute = self.readMemory(attribute_address);
                const attribute_shift: u3 = @intCast(((tile_y & 2) << 1) | (tile_x & 2));
                const palette_select = (attribute >> attribute_shift) & 0x03;
                const palette_entry = if (color == 0) self.palette[0] else self.palette[palette_select * 4 + color];
                const host_rgb = rgbForPaletteIndex(palette_entry);
                const offset = (y * frame_width + x) * 3;
                rgb[offset..][0..3].* = host_rgb;
                if (opacity) |buffer| buffer[y * frame_width + x] = @intFromBool(color != 0);
            }
        }
    }

    /// Presentation-side sprite overlay for the current OAM. It preserves the
    /// OAM priority order, color-0 transparency, palette selection, both
    /// flips, and the background-priority bit. Sprite evaluation limits and
    /// sprite-0 hit remain timing work in the dot-clock path.
    pub fn renderSprites(self: *Ppu, rgb: []u8) RenderError!void {
        return self.renderSpritesWithBackground(rgb, null);
    }

    /// Renders sprites after a background pass. When supplied, `background`
    /// contains pattern-opacity rather than RGB values, avoiding false
    /// priority decisions when two palette entries have identical host RGB.
    pub fn renderSpritesWithBackground(self: *Ppu, rgb: []u8, background: ?[]const u8) RenderError!void {
        if (rgb.len != frame_rgb_bytes) return error.InvalidFrameBuffer;
        if (background) |buffer| if (buffer.len != frame_width * frame_height) return error.InvalidFrameBuffer;
        if (self.presentation_mask & 0x10 == 0) return;
        const sprite_height: usize = if (self.presentation_ctrl & 0x20 != 0) 16 else 8;
        var sprite_index: usize = 64;
        while (sprite_index > 0) {
            sprite_index -= 1;
            const offset = sprite_index * 4;
            const sprite_y = self.oam[offset];
            const tile = self.oam[offset + 1];
            const attributes = self.oam[offset + 2];
            const sprite_x = self.oam[offset + 3];
            for (0..sprite_height) |local_y| {
                const screen_y = @as(usize, sprite_y) + 1 + local_y;
                if (screen_y >= frame_height) continue;
                if (self.spritesThroughIndexOnScanline(sprite_index, screen_y, sprite_height) > 8) continue;
                const source_y = if (attributes & 0x80 != 0) sprite_height - 1 - local_y else local_y;
                const tile_address = self.spriteTileAddress(tile, source_y);
                const low_plane = self.readMemory(tile_address);
                const high_plane = self.readMemory(tile_address + 8);
                for (0..8) |local_x| {
                    const screen_x = @as(usize, sprite_x) + local_x;
                    if (screen_x >= frame_width) continue;
                    if (screen_x < 8 and self.presentation_mask & 0x04 == 0) continue;
                    const source_x = if (attributes & 0x40 != 0) local_x else 7 - local_x;
                    const bit: u3 = @intCast(source_x);
                    const color: u8 = ((low_plane >> bit) & 1) | (((high_plane >> bit) & 1) << 1);
                    if (color == 0) continue;
                    const rgb_offset = (screen_y * frame_width + screen_x) * 3;
                    const background_is_opaque = self.backgroundOpaque(rgb, background, screen_x, screen_y);
                    if (attributes & 0x20 != 0 and background_is_opaque) continue;
                    const palette_select = attributes & 0x03;
                    const palette_entry = self.palette[0x10 + palette_select * 4 + color];
                    rgb[rgb_offset..][0..3].* = rgbForPaletteIndex(palette_entry);
                }
            }
        }
    }

    fn spriteTileAddress(self: *const Ppu, tile: u8, source_y: usize) u16 {
        if (self.presentation_ctrl & 0x20 == 0) {
            const pattern_base: u16 = if (self.presentation_ctrl & 0x08 != 0) 0x1000 else 0;
            return pattern_base + @as(u16, tile) * 16 + @as(u16, @intCast(source_y));
        }
        const pattern_base: u16 = if (tile & 1 != 0) 0x1000 else 0;
        const tile_number = (tile & 0xfe) + @as(u8, @intCast(source_y / 8));
        return pattern_base + @as(u16, tile_number) * 16 + @as(u16, @intCast(source_y & 7));
    }

    /// Evaluation is ordered by OAM index. The first eight in-range sprites
    /// on a scanline are rendered; any ninth sprite makes overflow observable.
    /// The hardware's buggy overflow-search behavior is a later dot-level
    /// refinement, but this models the normal practical limit correctly.
    fn spritesThroughIndexOnScanline(self: *const Ppu, inclusive_index: usize, screen_y: usize, sprite_height: usize) u8 {
        var count: u8 = 0;
        for (0..(inclusive_index + 1)) |index| {
            const top = @as(usize, self.oam[index * 4]) + 1;
            if (screen_y >= top and screen_y < top + sprite_height) count += 1;
        }
        return count;
    }

    fn backgroundOpaque(self: *const Ppu, rgb: []const u8, background: ?[]const u8, x: usize, y: usize) bool {
        if (background) |buffer| return buffer[y * frame_width + x] != 0;
        const offset = (y * frame_width + x) * 3;
        return !std.mem.eql(u8, rgb[offset..][0..3], &rgbForPaletteIndex(self.palette[0]));
    }

    pub fn rgbForPaletteIndex(index: u8) [3]u8 {
        return rgb_palette[index & 0x3f];
    }

    /// `register_address` is already mirrored to $2000-$2007 by the CPU bus.
    pub fn cpuRead(self: *Ppu, register_address: u3) u8 {
        const value: u8 = switch (register_address) {
            2 => blk: {
                const status = (self.status & 0xe0) | (self.open_bus & 0x1f);
                self.status &= ~@as(u8, 0x80);
                // A status read that clears VBlank before the CPU observes
                // the edge suppresses this still-pending PPU NMI request.
                self.nmi_pending = false;
                self.write_toggle = false;
                break :blk status;
            },
            4 => self.oam[self.oam_addr],
            7 => self.readData(),
            else => self.open_bus,
        };
        self.open_bus = value;
        return value;
    }

    pub fn cpuWrite(self: *Ppu, register_address: u3, value: u8) void {
        self.open_bus = value;
        switch (register_address) {
            0 => {
                const had_nmi_enabled = self.ctrl & 0x80 != 0;
                self.ctrl = value;
                self.t = (self.t & ~@as(u16, 0x0c00)) | (@as(u16, value & 0x03) << 10);
                self.pending_nametable = @truncate(value);
                if (!self.sprite_zero_ctrl_captured) {
                    self.sprite_zero_nametable = @truncate(value);
                    self.sprite_zero_ctrl = value;
                    self.sprite_zero_ctrl_captured = true;
                }
                if (!had_nmi_enabled and value & 0x80 != 0 and self.status & 0x80 != 0) {
                    self.nmi_pending = true;
                }
            },
            1 => self.mask = value,
            3 => self.oam_addr = value,
            4 => {
                self.dmaWrite(value);
            },
            5 => self.writeScroll(value),
            6 => self.writeAddress(value),
            7 => {
                self.writeMemory(self.v & 0x3fff, value);
                self.incrementVramAddress();
            },
            else => {},
        }
    }

    fn readData(self: *Ppu) u8 {
        const address = self.v & 0x3fff;
        defer self.incrementVramAddress();
        if (address >= 0x3f00) {
            const palette_value = self.readMemory(address);
            self.read_buffer = self.readMemory(address - 0x1000);
            return palette_value;
        }
        const result = self.read_buffer;
        self.read_buffer = self.readMemory(address);
        return result;
    }

    fn writeScroll(self: *Ppu, value: u8) void {
        if (!self.write_toggle) {
            self.t = (self.t & ~@as(u16, 0x001f)) | @as(u16, value >> 3);
            self.fine_x = @truncate(value);
            self.pending_scroll_x = value;
            if (self.sprite_zero_setup_pending) self.sprite_zero_scroll_x = value;
        } else {
            self.t = (self.t & ~@as(u16, 0x73e0)) |
                (@as(u16, value & 0x07) << 12) |
                (@as(u16, value & 0xf8) << 2);
            self.pending_scroll_y = value;
            if (self.sprite_zero_setup_pending) self.sprite_zero_scroll_y = value;
        }
        self.write_toggle = !self.write_toggle;
        if (self.sprite_zero_setup_pending) {
            self.sprite_zero_scroll_writes += 1;
            if (self.sprite_zero_scroll_writes == 2) self.sprite_zero_setup_pending = false;
        }
    }

    fn writeAddress(self: *Ppu, value: u8) void {
        if (!self.write_toggle) {
            self.t = (self.t & 0x00ff) | ((@as(u16, value) & 0x3f) << 8);
        } else {
            self.t = (self.t & 0x7f00) | value;
            self.v = self.t;
        }
        self.write_toggle = !self.write_toggle;
    }

    fn incrementVramAddress(self: *Ppu) void {
        self.v +%= if (self.ctrl & 0x04 != 0) 32 else 1;
        self.v &= 0x7fff;
    }

    fn readMemory(self: *const Ppu, address: u16) u8 {
        const normalized = address & 0x3fff;
        if (normalized < 0x2000) return self.mapper.ppuRead(normalized) orelse 0;
        if (normalized < 0x3f00) return self.nametables[self.nametableIndex(normalized)];
        return self.palette[self.paletteIndex(normalized)];
    }

    fn writeMemory(self: *Ppu, address: u16, value: u8) void {
        const normalized = address & 0x3fff;
        if (normalized < 0x2000) {
            _ = self.mapper.ppuWrite(normalized, value);
        } else if (normalized < 0x3f00) {
            self.nametables[self.nametableIndex(normalized)] = value;
        } else {
            self.palette[self.paletteIndex(normalized)] = value;
        }
    }

    fn nametableIndex(self: *const Ppu, address: u16) usize {
        const mirrored = if (address >= 0x3000) address - 0x1000 else address;
        const relative = mirrored - 0x2000;
        const table = relative >> 10;
        const offset = relative & 0x03ff;
        const physical_table: u16 = switch (self.mapper.mirroring()) {
            .vertical => table & 1,
            .horizontal => table >> 1,
            .single_screen_lower => 0,
            .single_screen_upper => 1,
        };
        return @as(usize, physical_table) * 0x400 + offset;
    }

    fn paletteIndex(_: *const Ppu, address: u16) usize {
        var index: u8 = @truncate(address & 0x1f);
        if (index & 0x13 == 0x10) index -%= 0x10;
        return index;
    }
};

pub const SpriteZeroHitTelemetry = struct {
    count: u64,
    frame: u64,
    scanline: u16,
    dot: u16,
};

test "PPU nametable and palette mirrors follow Mapper 0 mirroring" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .vertical,
    };
    var ppu = Ppu.init(&mapper);
    ppu.writeMemory(0x2000, 0x11);
    ppu.writeMemory(0x2400, 0x22);
    try std.testing.expectEqual(@as(u8, 0x11), ppu.readMemory(0x3000));
    try std.testing.expectEqual(@as(u8, 0x22), ppu.readMemory(0x3400));
    ppu.writeMemory(0x3f10, 0x3a);
    try std.testing.expectEqual(@as(u8, 0x3a), ppu.readMemory(0x3f00));
}

test "PPU supports mapper-controlled MMC1 single-screen mirroring" {
    const Mapper1 = @import("mapper1.zig").Mapper1;
    var prg: [2 * 16 * 1024]u8 = [_]u8{0} ** (2 * 16 * 1024);
    var mapper = Mapper1{ .prg_rom = &prg, .chr_rom = &.{}, .chr_is_ram = true };
    var ppu = Ppu.init(@import("mapper.zig").Mapper.fromMapper1(&mapper));
    for (0..5) |bit| _ = mapper.cpuWrite(0x8000, @truncate(@as(u5, 0) >> @intCast(bit)));
    ppu.writeMemory(0x2000, 0x51);
    try std.testing.expectEqual(@as(u8, 0x51), ppu.readMemory(0x2c00));

    for (0..5) |bit| _ = mapper.cpuWrite(0x8000, @truncate(@as(u5, 1) >> @intCast(bit)));
    ppu.writeMemory(0x2400, 0x62);
    try std.testing.expectEqual(@as(u8, 0x62), ppu.readMemory(0x2800));
    // The lower physical nametable persists while the mapper has selected
    // the upper one; reveal it again by changing mirroring back.
    for (0..5) |bit| _ = mapper.cpuWrite(0x8000, @truncate(@as(u5, 0) >> @intCast(bit)));
    try std.testing.expectEqual(@as(u8, 0x51), ppu.readMemory(0x2000));
}

test "PPUSTATUS clears VBlank and PPUADDR latch" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.status = 0x80;
    ppu.open_bus = 0x1b;
    ppu.cpuWrite(6, 0x21);
    try std.testing.expectEqual(@as(u8, 0x81), ppu.cpuRead(2));
    ppu.cpuWrite(6, 0x23);
    ppu.cpuWrite(6, 0x45);
    try std.testing.expectEqual(@as(u16, 0x2345), ppu.v);
    try std.testing.expectEqual(@as(u8, 0), ppu.status & 0x80);
}

test "PPUDATA is buffered outside palette and honors 32-byte increment" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.writeMemory(0x2000, 0x5a);
    ppu.v = 0x2000;
    try std.testing.expectEqual(@as(u8, 0), ppu.cpuRead(7));
    try std.testing.expectEqual(@as(u8, 0x5a), ppu.cpuRead(7));
    ppu.cpuWrite(0, 0x04);
    ppu.v = 0x2000;
    ppu.cpuWrite(7, 0x33);
    try std.testing.expectEqual(@as(u16, 0x2020), ppu.v);
    try std.testing.expectEqual(@as(u8, 0x33), ppu.readMemory(0x2000));
}

test "VBlank and enabling NMI during VBlank produce one pending NMI" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.scanline = 241;
    ppu.dot = 1;
    ppu.tickDot();
    try std.testing.expect(ppu.status & 0x80 != 0);
    try std.testing.expect(!ppu.takeNmi());
    ppu.cpuWrite(0, 0x80);
    try std.testing.expect(ppu.takeNmi());
    try std.testing.expect(!ppu.takeNmi());
}

test "PPUSTATUS read suppresses an undelivered VBlank NMI edge" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.ctrl = 0x80;
    ppu.scanline = 241;
    ppu.dot = 1;
    ppu.tickDot();
    try std.testing.expect(ppu.nmi_pending);
    _ = ppu.cpuRead(2);
    try std.testing.expect(!ppu.nmi_pending);
    try std.testing.expect(!ppu.takeNmi());
}

test "rendering odd frame skips the final pre-render dot" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.mask = 0x08;
    ppu.frame_number = 1;
    ppu.scanline = 261;
    ppu.dot = 339;
    ppu.tickDot();
    try std.testing.expectEqual(@as(u16, 0), ppu.dot);
    try std.testing.expectEqual(@as(u16, 0), ppu.scanline);
    try std.testing.expectEqual(@as(u64, 2), ppu.frame_number);

    ppu.mask = 0;
    ppu.frame_number = 1;
    ppu.scanline = 261;
    ppu.dot = 339;
    ppu.tickDot();
    try std.testing.expectEqual(@as(u16, 340), ppu.dot);
    try std.testing.expectEqual(@as(u16, 261), ppu.scanline);
}

test "sprite-0 hit is raised on the overlapping visible PPU dot" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.mask = 0x1e; // background, sprites, and both left-edge enables
    for (0..8) |row| mapper.chr_ram[16 + row] = 0x80;
    ppu.writeMemory(0x2000, 1);
    ppu.oam[0..4].* = .{ 0, 1, 0, 0 };

    ppu.scanline = 1;
    ppu.dot = 1;
    ppu.tickDot();
    try std.testing.expect(ppu.status & 0x40 != 0);
    const hit = ppu.spriteZeroHitTelemetry();
    try std.testing.expectEqual(@as(u64, 1), hit.count);
    try std.testing.expectEqual(@as(u16, 1), hit.scanline);
    try std.testing.expectEqual(@as(u16, 1), hit.dot);

    ppu.status &= ~@as(u8, 0x40);
    ppu.mask = 0x18; // clipped at the left edge
    ppu.dot = 1;
    ppu.tickDot();
    try std.testing.expect(ppu.status & 0x40 == 0);
}

test "sprite-0 state keeps the first VBlank display setup" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.pending_scroll_x = 44;
    ppu.pending_scroll_y = 12;
    ppu.pending_nametable = 1;
    ppu.ctrl = 0x91;
    ppu.scanline = 241;
    ppu.dot = 1;
    ppu.tickDot();

    // Some games write scroll before PPUCTRL during their VBlank handler;
    // capture the first display setup regardless of that ordering.
    ppu.cpuWrite(5, 0);
    ppu.cpuWrite(5, 0);
    ppu.cpuWrite(0, 0x10); // display setup for the status-bar scanlines
    ppu.cpuWrite(0, 0x15); // temporary VRAM-upload increment/nametable mode

    try std.testing.expectEqual(@as(u8, 0), ppu.sprite_zero_scroll_x);
    try std.testing.expectEqual(@as(u8, 0), ppu.sprite_zero_scroll_y);
    try std.testing.expectEqual(@as(u2, 0), ppu.sprite_zero_nametable);
    try std.testing.expectEqual(@as(u8, 0x10), ppu.sprite_zero_ctrl);
}

test "PPUMASK disables layers and leaves the universal backdrop" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    for (0..8) |row| mapper.chr_ram[16 + row] = 0xff;
    ppu.palette[0] = 0x21;
    ppu.palette[0x11] = 0x16;
    ppu.oam[0..4].* = .{ 0, 1, 0, 0 };
    var rgb: [frame_rgb_bytes]u8 = undefined;
    var opacity: [frame_width * frame_height]u8 = undefined;
    try ppu.renderBackgroundWithOpacity(&rgb, &opacity);
    try ppu.renderSpritesWithBackground(&rgb, &opacity);
    try std.testing.expectEqualSlices(u8, &.{ 76, 154, 236 }, rgb[0..3]);
    try std.testing.expectEqual(@as(u8, 0), opacity[0]);
}

test "background renderer decodes tile planes and attribute palette selection" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.mask = 0x0a;
    ppu.latchPresentationState();
    // Tile 0: the leftmost pixel of each row has color index 1; all other
    // pixels are transparent background color 0.
    for (0..8) |row| mapper.chr_ram[row] = 0x80;
    ppu.writeMemory(0x2000, 0);
    ppu.writeMemory(0x23c0, 0x01); // top-left 2x2 tile quadrant -> palette 1
    ppu.palette[0] = 0x0f;
    ppu.palette[5] = 0x21;
    var rgb: [frame_rgb_bytes]u8 = undefined;
    try ppu.renderBackground(&rgb);
    try std.testing.expectEqualSlices(u8, &.{ 76, 154, 236 }, rgb[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, rgb[3..6]);
    try std.testing.expectError(error.InvalidFrameBuffer, ppu.renderBackground(rgb[0..3]));
}

test "background renderer scrolls across nametable edges using PPU scroll state" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .vertical,
    };
    var ppu = Ppu.init(&mapper);
    ppu.mask = 0x0a;
    // Tile 1 is solid color index 1, tile 2 is solid color index 2.
    for (0..8) |row| {
        mapper.chr_ram[16 + row] = 0xff;
        mapper.chr_ram[32 + 8 + row] = 0xff;
    }
    ppu.writeMemory(0x201f, 1);
    ppu.writeMemory(0x2400, 2);
    ppu.palette[0] = 0x0f;
    ppu.palette[1] = 0x21;
    ppu.palette[2] = 0x16;
    ppu.cpuWrite(5, 248); // scroll right from final tile of nametable 0
    ppu.cpuWrite(5, 0);
    ppu.latchPresentationState();
    // A VBlank handler may immediately restore $2005 to zero for VRAM work;
    // it configures the following frame and must not rewrite this one.
    ppu.cpuWrite(5, 0);
    ppu.cpuWrite(5, 0);
    var rgb: [frame_rgb_bytes]u8 = undefined;
    try ppu.renderBackground(&rgb);
    try std.testing.expectEqualSlices(u8, &.{ 76, 154, 236 }, rgb[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 152, 34, 32 }, rgb[24..27]);
}

test "sprite overlay handles palette flips transparency and background priority" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.mask = 0x14;
    ppu.latchPresentationState();
    // Tile 1 has color 1 at its left edge and color 2 at its right edge.
    for (0..8) |row| {
        mapper.chr_ram[16 + row] = 0x80;
        mapper.chr_ram[16 + 8 + row] = 0x01;
    }
    ppu.palette[0] = 0x0f;
    ppu.palette[0x11] = 0x21;
    ppu.palette[0x12] = 0x16;
    ppu.oam[0..4].* = .{ 9, 1, 0x40, 20 }; // x flip
    ppu.oam[4..8].* = .{ 9, 1, 0x20, 40 }; // behind opaque background
    var rgb: [frame_rgb_bytes]u8 = undefined;
    @memset(&rgb, 0);
    try ppu.renderSprites(&rgb);
    const flipped_left = (10 * frame_width + 20) * 3;
    const flipped_right = (10 * frame_width + 27) * 3;
    try std.testing.expectEqualSlices(u8, &.{ 152, 34, 32 }, rgb[flipped_left..][0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 76, 154, 236 }, rgb[flipped_right..][0..3]);

    const behind_offset = (10 * frame_width + 40) * 3;
    rgb[behind_offset..][0..3].* = Ppu.rgbForPaletteIndex(0x21);
    try ppu.renderSprites(&rgb);
    try std.testing.expectEqualSlices(u8, &.{ 76, 154, 236 }, rgb[behind_offset..][0..3]);
}

test "lower OAM index wins where opaque sprites overlap" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.mask = 0x14;
    ppu.latchPresentationState();
    for (0..8) |row| {
        mapper.chr_ram[16 + row] = 0xff; // tile 1 color 1
        mapper.chr_ram[32 + 8 + row] = 0xff; // tile 2 color 2
    }
    ppu.palette[0x11] = 0x21;
    ppu.palette[0x12] = 0x16;
    ppu.oam[0..4].* = .{ 19, 1, 0, 30 };
    ppu.oam[4..8].* = .{ 19, 2, 0, 30 };
    var rgb: [frame_rgb_bytes]u8 = undefined;
    @memset(&rgb, 0);
    try ppu.renderSprites(&rgb);
    const offset = (20 * frame_width + 30) * 3;
    try std.testing.expectEqualSlices(u8, &.{ 76, 154, 236 }, rgb[offset..][0..3]);
}

test "8x16 sprites select pattern table from tile bit and span two tiles" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.ctrl = 0x20; // 8x16 sprites
    ppu.mask = 0x14;
    ppu.latchPresentationState();
    // Tile byte 3 chooses $1000. The top half is tile 2 (color 1), bottom
    // half tile 3 (color 2) in that table.
    for (0..8) |row| {
        mapper.chr_ram[0x1000 + 2 * 16 + row] = 0x80;
        mapper.chr_ram[0x1000 + 3 * 16 + 8 + row] = 0x80;
    }
    ppu.palette[0x11] = 0x21;
    ppu.palette[0x12] = 0x16;
    ppu.oam[0..4].* = .{ 29, 3, 0, 50 };
    var rgb: [frame_rgb_bytes]u8 = undefined;
    @memset(&rgb, 0);
    try ppu.renderSprites(&rgb);
    const top = (30 * frame_width + 50) * 3;
    const bottom = (38 * frame_width + 50) * 3;
    try std.testing.expectEqualSlices(u8, &.{ 76, 154, 236 }, rgb[top..][0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 152, 34, 32 }, rgb[bottom..][0..3]);
}

test "sprite renderer limits each scanline to eight and raises overflow plus sprite-0 hit" {
    var prg: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    var mapper = Mapper0{
        .prg_rom = &prg,
        .chr_rom = &.{},
        .chr_is_ram = true,
        .mirroring = .horizontal,
    };
    var ppu = Ppu.init(&mapper);
    ppu.mask = 0x14;
    ppu.latchPresentationState();
    for (0..8) |row| mapper.chr_ram[16 + row] = 0x80;
    ppu.palette[0x11] = 0x21;
    for (0..9) |index| ppu.oam[index * 4 ..][0..4].* = .{ 39, 1, 0, 60 };
    var rgb: [frame_rgb_bytes]u8 = undefined;
    @memset(&rgb, 0);
    var background: [frame_width * frame_height]u8 = [_]u8{0} ** (frame_width * frame_height);
    background[40 * frame_width + 60] = 1;
    try ppu.renderSpritesWithBackground(&rgb, &background);
    ppu.scanline = 40;
    ppu.dot = 65;
    ppu.tickDot();
    try std.testing.expect(ppu.status & 0x20 != 0);
    const visible = (40 * frame_width + 60) * 3;
    try std.testing.expectEqualSlices(u8, &.{ 76, 154, 236 }, rgb[visible..][0..3]);
}
