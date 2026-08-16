const Mapper0 = @import("mapper0.zig").Mapper0;
const Mapper1 = @import("mapper1.zig").Mapper1;
const Mapper2 = @import("mapper2.zig").Mapper2;
const Mapper3 = @import("mapper3.zig").Mapper3;
const Mapper4 = @import("mapper4.zig").Mapper4;
const Mapper7 = @import("mapper7.zig").Mapper7;
const Mirroring = @import("cartridge.zig").Mirroring;

/// Type-erased cartridge mapper contract shared by the CPU bus and PPU.
/// Mappers retain ownership of their volatile RAM; this value only borrows a
/// mapper that must remain alive while the bus/PPU uses it.
pub const Mapper = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        cpu_read: *const fn (context: *const anyopaque, address: u16) ?u8,
        cpu_write: *const fn (context: *anyopaque, address: u16, value: u8) bool,
        ppu_read: *const fn (context: *const anyopaque, address: u16) ?u8,
        ppu_write: *const fn (context: *anyopaque, address: u16, value: u8) bool,
        mirroring: *const fn (context: *const anyopaque) Mirroring,
    };

    pub fn fromMapper0(mapper: *Mapper0) Mapper {
        return .{ .context = mapper, .vtable = &mapper0_vtable };
    }

    pub fn fromMapper1(mapper: *Mapper1) Mapper {
        return .{ .context = mapper, .vtable = &mapper1_vtable };
    }

    pub fn fromMapper2(mapper: *Mapper2) Mapper {
        return .{ .context = mapper, .vtable = &mapper2_vtable };
    }

    pub fn fromMapper3(mapper: *Mapper3) Mapper {
        return .{ .context = mapper, .vtable = &mapper3_vtable };
    }
    pub fn fromMapper4(mapper: *Mapper4) Mapper {
        return .{ .context = mapper, .vtable = &mapper4_vtable };
    }

    pub fn fromMapper7(mapper: *Mapper7) Mapper {
        return .{ .context = mapper, .vtable = &mapper7_vtable };
    }

    pub fn cpuRead(self: *const Mapper, address: u16) ?u8 {
        return self.vtable.cpu_read(self.context, address);
    }

    pub fn cpuWrite(self: *Mapper, address: u16, value: u8) bool {
        return self.vtable.cpu_write(self.context, address, value);
    }

    pub fn ppuRead(self: *const Mapper, address: u16) ?u8 {
        return self.vtable.ppu_read(self.context, address);
    }

    pub fn ppuWrite(self: *Mapper, address: u16, value: u8) bool {
        return self.vtable.ppu_write(self.context, address, value);
    }

    pub fn mirroring(self: *const Mapper) Mirroring {
        return self.vtable.mirroring(self.context);
    }
};

const mapper4_vtable = Mapper.VTable{ .cpu_read = struct {
    fn call(c: *const anyopaque, a: u16) ?u8 {
        return (@as(*const Mapper4, @ptrCast(@alignCast(c)))).cpuRead(a);
    }
}.call, .cpu_write = struct {
    fn call(c: *anyopaque, a: u16, v: u8) bool {
        return (@as(*Mapper4, @ptrCast(@alignCast(c)))).cpuWrite(a, v);
    }
}.call, .ppu_read = struct {
    fn call(c: *const anyopaque, a: u16) ?u8 {
        return (@as(*const Mapper4, @ptrCast(@alignCast(c)))).ppuRead(a);
    }
}.call, .ppu_write = struct {
    fn call(c: *anyopaque, a: u16, v: u8) bool {
        return (@as(*Mapper4, @ptrCast(@alignCast(c)))).ppuWrite(a, v);
    }
}.call, .mirroring = struct {
    fn call(c: *const anyopaque) Mirroring {
        return (@as(*const Mapper4, @ptrCast(@alignCast(c)))).mirroring();
    }
}.call };

const mapper1_vtable = Mapper.VTable{
    .cpu_read = struct {
        fn call(context: *const anyopaque, address: u16) ?u8 {
            const mapper: *const Mapper1 = @ptrCast(@alignCast(context));
            return mapper.cpuRead(address);
        }
    }.call,
    .cpu_write = struct {
        fn call(context: *anyopaque, address: u16, value: u8) bool {
            const mapper: *Mapper1 = @ptrCast(@alignCast(context));
            return mapper.cpuWrite(address, value);
        }
    }.call,
    .ppu_read = struct {
        fn call(context: *const anyopaque, address: u16) ?u8 {
            const mapper: *const Mapper1 = @ptrCast(@alignCast(context));
            return mapper.ppuRead(address);
        }
    }.call,
    .ppu_write = struct {
        fn call(context: *anyopaque, address: u16, value: u8) bool {
            const mapper: *Mapper1 = @ptrCast(@alignCast(context));
            return mapper.ppuWrite(address, value);
        }
    }.call,
    .mirroring = struct {
        fn call(context: *const anyopaque) Mirroring {
            const mapper: *const Mapper1 = @ptrCast(@alignCast(context));
            return mapper.mirroring();
        }
    }.call,
};

const mapper0_vtable = Mapper.VTable{
    .cpu_read = struct {
        fn call(context: *const anyopaque, address: u16) ?u8 {
            const mapper: *const Mapper0 = @ptrCast(@alignCast(context));
            return mapper.cpuRead(address);
        }
    }.call,
    .cpu_write = struct {
        fn call(context: *anyopaque, address: u16, value: u8) bool {
            const mapper: *Mapper0 = @ptrCast(@alignCast(context));
            return mapper.cpuWrite(address, value);
        }
    }.call,
    .ppu_read = struct {
        fn call(context: *const anyopaque, address: u16) ?u8 {
            const mapper: *const Mapper0 = @ptrCast(@alignCast(context));
            return mapper.ppuRead(address);
        }
    }.call,
    .ppu_write = struct {
        fn call(context: *anyopaque, address: u16, value: u8) bool {
            const mapper: *Mapper0 = @ptrCast(@alignCast(context));
            return mapper.ppuWrite(address, value);
        }
    }.call,
    .mirroring = struct {
        fn call(context: *const anyopaque) Mirroring {
            const mapper: *const Mapper0 = @ptrCast(@alignCast(context));
            return mapper.mirroring;
        }
    }.call,
};

const mapper2_vtable = Mapper.VTable{
    .cpu_read = struct {
        fn call(context: *const anyopaque, address: u16) ?u8 {
            const mapper: *const Mapper2 = @ptrCast(@alignCast(context));
            return mapper.cpuRead(address);
        }
    }.call,
    .cpu_write = struct {
        fn call(context: *anyopaque, address: u16, value: u8) bool {
            const mapper: *Mapper2 = @ptrCast(@alignCast(context));
            return mapper.cpuWrite(address, value);
        }
    }.call,
    .ppu_read = struct {
        fn call(context: *const anyopaque, address: u16) ?u8 {
            const mapper: *const Mapper2 = @ptrCast(@alignCast(context));
            return mapper.ppuRead(address);
        }
    }.call,
    .ppu_write = struct {
        fn call(context: *anyopaque, address: u16, value: u8) bool {
            const mapper: *Mapper2 = @ptrCast(@alignCast(context));
            return mapper.ppuWrite(address, value);
        }
    }.call,
    .mirroring = struct {
        fn call(context: *const anyopaque) Mirroring {
            const mapper: *const Mapper2 = @ptrCast(@alignCast(context));
            return mapper.mirroring;
        }
    }.call,
};

const mapper3_vtable = Mapper.VTable{
    .cpu_read = struct {
        fn call(context: *const anyopaque, address: u16) ?u8 {
            const mapper: *const Mapper3 = @ptrCast(@alignCast(context));
            return mapper.cpuRead(address);
        }
    }.call,
    .cpu_write = struct {
        fn call(context: *anyopaque, address: u16, value: u8) bool {
            const mapper: *Mapper3 = @ptrCast(@alignCast(context));
            return mapper.cpuWrite(address, value);
        }
    }.call,
    .ppu_read = struct {
        fn call(context: *const anyopaque, address: u16) ?u8 {
            const mapper: *const Mapper3 = @ptrCast(@alignCast(context));
            return mapper.ppuRead(address);
        }
    }.call,
    .ppu_write = struct {
        fn call(context: *anyopaque, address: u16, value: u8) bool {
            const mapper: *Mapper3 = @ptrCast(@alignCast(context));
            return mapper.ppuWrite(address, value);
        }
    }.call,
    .mirroring = struct {
        fn call(context: *const anyopaque) Mirroring {
            const mapper: *const Mapper3 = @ptrCast(@alignCast(context));
            return mapper.mirroring;
        }
    }.call,
};

const mapper7_vtable = Mapper.VTable{
    .cpu_read = struct {
        fn call(context: *const anyopaque, address: u16) ?u8 {
            const mapper: *const Mapper7 = @ptrCast(@alignCast(context));
            return mapper.cpuRead(address);
        }
    }.call,
    .cpu_write = struct {
        fn call(context: *anyopaque, address: u16, value: u8) bool {
            const mapper: *Mapper7 = @ptrCast(@alignCast(context));
            return mapper.cpuWrite(address, value);
        }
    }.call,
    .ppu_read = struct {
        fn call(context: *const anyopaque, address: u16) ?u8 {
            const mapper: *const Mapper7 = @ptrCast(@alignCast(context));
            return mapper.ppuRead(address);
        }
    }.call,
    .ppu_write = struct {
        fn call(context: *anyopaque, address: u16, value: u8) bool {
            const mapper: *Mapper7 = @ptrCast(@alignCast(context));
            return mapper.ppuWrite(address, value);
        }
    }.call,
    .mirroring = struct {
        fn call(context: *const anyopaque) Mirroring {
            const mapper: *const Mapper7 = @ptrCast(@alignCast(context));
            return mapper.mirroring();
        }
    }.call,
};
