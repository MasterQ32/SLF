const std = @import("std");

pub const SymbolSize = enum(u8) {
    @"8 bits" = 1,
    @"16 bits" = 2,
    @"32 bits" = 4,
    @"64 bits" = 8,
};

const magic_number = [4]u8{ 0xFB, 0xAD, 0xB6, 0x02 };

pub const Linker = struct {
    const Module = struct {
        view: View,

        // will be defined in the link step
        base_offset: u32 = undefined,
    };

    allocator: std.mem.Allocator,
    modules: std.ArrayListUnmanaged(Module),

    pub fn init(allocator: std.mem.Allocator) Linker {
        return Linker{
            .allocator = allocator,
            .modules = .{},
        };
    }

    pub fn deinit(self: *Linker) void {
        self.modules.deinit(self.allocator);
        self.* = undefined;
    }

    /// Adds a module to be linked.
    /// Modules are processed in the order they are added, and can shadow symbols of previous modules.
    pub fn addModule(self: *Linker, module: View) !void {
        const ptr = try self.modules.addOne(self.allocator);
        ptr.* = Module{
            .view = module,
        };
    }

    pub const LinkOptions = struct {
        /// Align each module to this.
        module_alignment: u32 = 16,
        /// Enforce the symbol size and reject modules that don't have this.
        symbol_size: ?SymbolSize = null,
        /// The base address where all modules are relocated to.
        base_address: u32 = 0,
    };
    pub fn link(self: *Linker, output: *std.io.StreamSource, options: LinkOptions) !void {
        if (self.modules.items.len == 0)
            return error.NothingToLink;

        var symbol_size: SymbolSize = options.symbol_size orelse self.modules.items[0].view.symbol_size;
        var write_offset: u32 = options.base_address;
        for (self.modules.items) |*_module| {
            const module: *Module = _module;

            module.base_offset = write_offset;
            if (module.view.symbol_size != symbol_size)
                return error.MismatchingSymbolSize;

            write_offset += try std.math.cast(u32, std.mem.alignForward(module.view.data().len, options.module_alignment));
        }

        var symbol_table = std.StringHashMap(u64).init(self.allocator);
        defer symbol_table.deinit();

        const Patch = struct {
            offset: u64,
            symbol: []const u8,
        };

        var patches = std.ArrayList(Patch).init(self.allocator);
        defer patches.deinit();

        for (self.modules.items) |*_module| {
            const module: *Module = _module;

            std.log.debug("Process object file...", .{});

            try output.seekTo(module.base_offset);

            try output.writer().writeAll(module.view.data());

            // first resolve inputs
            if (module.view.imports()) |imports| {
                var strings = module.view.strings().?;
                var iter = imports.iterator();
                while (iter.next()) |sym| {
                    const string = strings.get(sym.symbol_name);

                    const symbol_offset = module.base_offset + sym.offset;

                    if (symbol_table.get(string.text)) |address| {
                        // we got that!
                        try output.seekTo(symbol_offset);
                        try patchStream(output, symbol_size, address, .replace);

                        std.log.debug("Directly resolving symbol {s} to {X:0>4} at offset {X:0>4}", .{ string.text, address, symbol_offset });
                    } else {
                        // we must patch this later
                        try patches.append(Patch{
                            .offset = symbol_offset,
                            .symbol = string.text,
                        });
                        std.log.debug("Adding patch for symbol {s} at offset {X:0>4}", .{ string.text, symbol_offset });
                    }
                }
            }

            // then publish outputs
            if (module.view.exports()) |exports| {
                var strings = module.view.strings().?;
                var iter = exports.iterator();
                while (iter.next()) |sym| {
                    const string = strings.get(sym.symbol_name);
                    try symbol_table.put(string.text, module.base_offset + sym.offset);

                    std.log.debug("Publishing symbol {s} at offset {X:0>4}", .{ string.text, module.base_offset + sym.offset });
                }
            }

            // then try resolving all patches
            {
                var i: usize = 0;
                while (i < patches.items.len) {
                    const patch = patches.items[i];

                    if (symbol_table.get(patch.symbol)) |address| {
                        try output.seekTo(patch.offset);
                        try patchStream(output, symbol_size, address, .replace);

                        std.log.debug("Patch-resolving symbol {s} to {X:0>4} at offset {X:0>4}", .{ patch.symbol, address, patch.offset });

                        // order isn't important at this point anymore
                        _ = patches.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }

            // then resolve all internal references
            if (module.view.relocations()) |relocs| {
                var i: u32 = 0;
                while (i < relocs.count) : (i += 1) {
                    try output.seekTo(module.base_offset + relocs.get(i));
                    try patchStream(output, symbol_size, module.base_offset, .add);
                }
            }
        }

        {
            std.debug.print("symbols:\n", .{});

            var iter = symbol_table.iterator();
            while (iter.next()) |kv| {
                std.debug.print("{X:0>8}: {s}\n", .{ kv.value_ptr.*, kv.key_ptr.* });
            }
        }

        {
            std.debug.print("unresolved symbols:\n", .{});

            for (patches.items) |patch| {
                std.debug.print("{X:0>8}: {s}\n", .{ patch.offset, patch.symbol });
            }
        }
    }

    const PatchMode = enum { replace, add };
    fn patchStream(stream: *std.io.StreamSource, size: SymbolSize, data: u64, kind: PatchMode) !void {
        switch (size) {
            .@"8 bits" => try patchStreamTyped(u8, stream, data, kind),
            .@"16 bits" => try patchStreamTyped(u16, stream, data, kind),
            .@"32 bits" => try patchStreamTyped(u32, stream, data, kind),
            .@"64 bits" => try patchStreamTyped(u64, stream, data, kind),
        }
    }

    fn patchStreamTyped(comptime Offset: type, stream: *std.io.StreamSource, data: u64, kind: PatchMode) !void {
        const pos = try stream.getPos();

        const old_val = try stream.reader().readIntLittle(Offset);
        const new_val = try std.math.cast(Offset, data);

        const value = switch (kind) {
            .replace => new_val,
            .add => old_val +% new_val,
        };

        try stream.seekTo(pos);
        try stream.writer().writeIntLittle(Offset, value);
    }
};

pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    stream: *std.io.StreamSource,

    exports: std.StringHashMapUnmanaged(u32) = .{},
    imports: std.StringHashMapUnmanaged(u32) = .{},
    strings: std.StringHashMapUnmanaged(u32) = .{},
    relocs: std.ArrayListUnmanaged(u32) = .{},

    pub fn init(allocator: std.mem.Allocator, symbol_size: SymbolSize, stream: *std.io.StreamSource) !Builder {
        var builder = Builder{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .stream = stream,
        };

        try builder.stream.writer().writeAll(&[_]u8{
            0xFB, 0xAD, 0xB6, 0x02, // magic
            0xAA, 0xAA, 0xAA, 0xAA, // export_table
            0xAA, 0xAA, 0xAA, 0xAA, // import_table
            0xAA, 0xAA, 0xAA, 0xAA, // relocs_table
            0xAA, 0xAA, 0xAA, 0xAA, // string_table
            0x20, 0x00, 0x00, 0x00, // section_start
            0xAA, 0xAA, 0xAA, 0xAA, // section_size
            @enumToInt(symbol_size), // symbol_size
            0x00, 0x00, 0x00, // padding
        });

        return builder;
    }

    pub fn deinit(self: *Builder) void {
        self.exports.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Returns the current offset into the data section.
    pub fn getOffset(self: *Builder) !u32 {
        return try self.stream.getPos() - 0x20;
    }

    /// Appends bytes to the data section.
    pub fn append(self: *Builder, data: []const u8) !void {
        try self.stream.writer().writeAll(data);
    }

    /// If `offset` is null, the current offset is used.
    pub fn addExport(self: *Builder, name: []const u8, offset: ?u32) !void {
        const real_offset = offset orelse try self.stream.getPos();
        const interned_name = try self.internString(name);

        try self.exports.put(self.allocator, interned_name, real_offset);
    }

    /// If `offset` is null, the current offset is used.
    pub fn addImport(self: *Builder, name: []const u8, offset: ?u32) !void {
        const real_offset = offset orelse try self.stream.getPos();
        const interned_name = try self.internString(name);

        try self.imports.put(self.allocator, interned_name, real_offset);
    }

    /// If `offset` is null, the current offset is used.
    pub fn addRelocation(self: *Builder, offset: ?u32) !void {
        const real_offset = offset orelse try self.stream.getPos();
        try self.relocs.append(self.allocator, real_offset);
    }

    pub fn finalize(self: *Builder) !void {
        var writer = self.stream.writer();

        const data_end_marker = try self.stream.getPos();

        const string_table_pos = try self.alignData(4);
        {
            var total_size: u32 = 4;
            var iter = self.strings.iterator();
            while (iter.next()) |kv| {
                total_size += @truncate(u32, kv.key_ptr.len) + 5; // 4 byte length + nul terminator
            }

            try writer.writeIntLittle(u32, total_size);

            var offset: u32 = 4;
            iter = self.strings.iterator();
            while (iter.next()) |kv| {
                kv.value_ptr.* = offset;
                try writer.writeIntLittle(u32, @truncate(u32, kv.key_ptr.len));
                try writer.writeAll(kv.key_ptr.*);
                try writer.writeByte(0);
                offset += @truncate(u32, kv.key_ptr.len) + 5;
            }
        }

        const export_table_pos = try self.alignData(4);
        {
            try writer.writeIntLittle(u32, self.exports.count());
            var iter = self.exports.iterator();
            while (iter.next()) |sym| {
                const name_str = sym.key_ptr.*;
                const value = sym.value_ptr.*;

                const name_id = self.strings.get(name_str) orelse unreachable;

                try writer.writeIntLittle(u32, name_id);
                try writer.writeIntLittle(u32, value);
            }
        }

        const import_table_pos = try self.alignData(4);
        {
            try writer.writeIntLittle(u32, self.imports.count());
            var iter = self.imports.iterator();
            while (iter.next()) |sym| {
                const name_str = sym.key_ptr.*;
                const value = sym.value_ptr.*;

                const name_id = self.strings.get(name_str) orelse unreachable;

                try writer.writeIntLittle(u32, name_id);
                try writer.writeIntLittle(u32, value);
            }
        }

        const relocs_table_pos = try self.alignData(4);
        {
            try writer.writeIntLittle(u32, @truncate(u32, self.relocs.items.len));
            for (self.relocs.items) |reloc| {
                try writer.writeIntLittle(u32, reloc);
            }
        }

        const end_of_file_marker = try self.stream.getPos();

        try self.stream.seekTo(4);

        try writer.writeIntLittle(u32, export_table_pos); // export_table
        try writer.writeIntLittle(u32, import_table_pos); // import_table
        try writer.writeIntLittle(u32, relocs_table_pos); // relocs_table
        try writer.writeIntLittle(u32, string_table_pos); // string_table
        try writer.writeIntLittle(u32, 0x20); // section_start
        try writer.writeIntLittle(u32, @truncate(u32, data_end_marker) - 0x20); // section_size

        try self.stream.seekTo(end_of_file_marker);
    }

    fn internString(self: *Builder, string: []const u8) ![]const u8 {
        const gop = self.strings.getOrPut(self.allocator, string);
        if (!gop.found_existing) {
            errdefer self.strings.remove(string);
            const copy = try self.arena.allocator().dupe(u8, string);
            gop.key_ptr.* = copy;

            // we leave the value dangling until finalize() so we
            // can store the string offset in the table then.
            gop.value_ptr.* = undefined;
        }
        return gop.key_ptr.*;
    }

    fn alignData(self: *Builder, alignment: u32) !u32 {
        const pos = try self.stream.getPos();
        const aligned = @truncate(u32, std.mem.alignForward(pos, alignment));
        try self.stream.seekTo(aligned);
        return aligned;
    }
};

/// A view of a SLF file. Allows accessing the data structure from a flat buffer without allocation.
pub const View = struct {
    const offsets = struct {
        const magic = 0;
        const export_table = 4;
        const import_table = 8;
        const relocs_table = 12;
        const string_table = 16;
        const section_start = 20;
        const section_size = 24;
        const symbol_size = 28;
    };

    buffer: []const u8,

    symbol_size: SymbolSize,

    pub const InitOptions = struct {
        validate_symbols: bool = false,
    };

    pub const InitError = error{ InvalidHeader, InvalidData };
    pub fn init(buffer: []const u8, options: InitOptions) InitError!View {
        if (!std.mem.startsWith(u8, buffer, &magic_number))
            return error.InvalidHeader;
        if (buffer.len < 32) return error.InvalidData;

        const export_table = std.mem.readIntLittle(u32, buffer[offsets.export_table..][0..4]);
        const import_table = std.mem.readIntLittle(u32, buffer[offsets.import_table..][0..4]);
        const relocs_table = std.mem.readIntLittle(u32, buffer[offsets.relocs_table..][0..4]);
        const string_table = std.mem.readIntLittle(u32, buffer[offsets.string_table..][0..4]);
        const section_start = std.mem.readIntLittle(u32, buffer[offsets.section_start..][0..4]);
        const section_size = std.mem.readIntLittle(u32, buffer[offsets.section_size..][0..4]);
        const symbol_size = std.mem.readIntLittle(u8, buffer[offsets.symbol_size..][0..1]);

        // std.debug.print("{} {} {} {} {} {} {}\n", .{
        //     export_table,
        //     import_table,
        //     relocs_table,
        //     string_table,
        //     section_start,
        //     section_size,
        //     symbol_size,
        // });

        // validate basic boundaries
        if (export_table > buffer.len - 4) return error.InvalidData;
        if (import_table > buffer.len - 4) return error.InvalidData;
        if (relocs_table > buffer.len - 4) return error.InvalidData;
        if (string_table > buffer.len - 4) return error.InvalidData;
        if (section_start + section_size > buffer.len) return error.InvalidData;

        const string_table_size = if (string_table != 0) blk: {
            const length = std.mem.readIntLittle(u32, buffer[string_table..][0..4]);
            if (string_table + length > buffer.len) return error.InvalidData;

            var offset: u32 = 4;
            while (offset < length) {
                const len = std.mem.readIntLittle(u32, buffer[string_table + offset ..][0..4]);
                // std.debug.print("{} + {} + 5 > {}\n", .{
                //     offset, len, length,
                // });
                if (offset + len + 5 > length) return error.InvalidData;
                if (string_table + len + 1 > buffer.len) return error.InvalidData;
                if (buffer[string_table + offset + len + 4] != 0) return error.InvalidData;
                offset += 5 + len;
            }
            break :blk length;
        } else 0;

        if (export_table != 0) {
            const count = std.mem.readIntLittle(u32, buffer[export_table..][0..4]);
            if (export_table + 8 * count + 4 > buffer.len) return error.InvalidData;

            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const name_index = std.mem.readIntLittle(u32, buffer[export_table + 4 + 8 * i ..][0..4]);
                const offset = std.mem.readIntLittle(u32, buffer[export_table + 4 + 8 * i ..][4..8]);
                if (name_index + 5 > string_table_size) return error.InvalidData; // not possible for string table
                if (options.validate_symbols) {
                    if (offset + symbol_size > section_size) return error.InvalidData; // out of bounds
                }
            }
        }

        if (import_table != 0) {
            const count = std.mem.readIntLittle(u32, buffer[import_table..][0..4]);
            if (import_table + 8 * count + 4 > buffer.len) return error.InvalidData;

            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const name_index = std.mem.readIntLittle(u32, buffer[import_table + 4 + 8 * i ..][0..4]);
                const offset = std.mem.readIntLittle(u32, buffer[import_table + 4 + 8 * i ..][4..8]);
                if (name_index + 5 > string_table_size) return error.InvalidData; // not possible for string table
                if (options.validate_symbols) {
                    if (offset + symbol_size > section_size) return error.InvalidData; // out of bounds
                }
            }
        }

        if (relocs_table != 0) {
            const count = std.mem.readIntLittle(u32, buffer[relocs_table..][0..4]);
            if (relocs_table + 4 * count + 4 > buffer.len) return error.InvalidData;

            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const offset = std.mem.readIntLittle(u32, buffer[relocs_table + 4 + 4 * i ..][0..4]);
                // std.debug.print("{} + {} > {}\n", .{ offset, symbol_size, section_size });

                // relocation must always be inside the section table
                if (offset + symbol_size > section_size) return error.InvalidData; // out of bounds
            }
        }

        return View{
            .buffer = buffer,
            .symbol_size = std.meta.intToEnum(SymbolSize, symbol_size) catch return error.InvalidData,
        };
    }

    pub fn imports(self: View) ?SymbolTable {
        const import_table = std.mem.readIntLittle(u32, self.buffer[offsets.import_table..][0..4]);
        if (import_table == 0)
            return null;
        return SymbolTable.init(self.buffer[import_table..]);
    }

    pub fn exports(self: View) ?SymbolTable {
        const export_table = std.mem.readIntLittle(u32, self.buffer[offsets.export_table..][0..4]);
        if (export_table == 0)
            return null;
        return SymbolTable.init(self.buffer[export_table..]);
    }

    pub fn strings(self: View) ?StringTable {
        const string_table = std.mem.readIntLittle(u32, self.buffer[offsets.string_table..][0..4]);
        if (string_table == 0)
            return null;
        return StringTable.init(self.buffer[string_table..]);
    }

    pub fn relocations(self: View) ?RelocationTable {
        const relocs_table = std.mem.readIntLittle(u32, self.buffer[offsets.relocs_table..][0..4]);
        if (relocs_table == 0)
            return null;
        return RelocationTable.init(self.buffer[relocs_table..]);
    }

    pub fn data(self: View) []const u8 {
        const section_start = std.mem.readIntLittle(u32, self.buffer[offsets.section_start..][0..4]);
        const section_size = std.mem.readIntLittle(u32, self.buffer[offsets.section_size..][0..4]);

        return self.buffer[section_start..][0..section_size];
    }
};

pub const SymbolTable = struct {
    buffer: []const u8,
    count: usize,

    pub fn init(buffer: []const u8) SymbolTable {
        const count = std.mem.readIntLittle(u32, buffer[0..4]);

        return SymbolTable{
            .count = count,
            .buffer = buffer[4..],
        };
    }

    pub fn get(self: SymbolTable, index: usize) Symbol {
        const symbol_name = std.mem.readIntLittle(u32, self.buffer[8 * index ..][0..4]);
        const offset = std.mem.readIntLittle(u32, self.buffer[8 * index ..][4..8]);

        return Symbol{
            .offset = offset,
            .symbol_name = symbol_name,
        };
    }

    pub fn iterator(self: SymbolTable) Iterator {
        return Iterator{ .table = self };
    }

    pub const Iterator = struct {
        table: SymbolTable,
        index: usize = 0,

        pub fn next(self: *Iterator) ?Symbol {
            if (self.index >= self.table.count)
                return null;
            const index = self.index;
            self.index += 1;
            return self.table.get(index);
        }
    };
};

pub const Symbol = struct {
    offset: u32,
    symbol_name: u32,
};

pub const RelocationTable = struct {
    buffer: []const u8,
    count: u32,

    pub fn init(buffer: []const u8) RelocationTable {
        const count = std.mem.readIntLittle(u32, buffer[0..4]);
        return RelocationTable{
            .count = count,
            .buffer = buffer[4..],
        };
    }

    pub fn get(self: RelocationTable, index: u32) u32 {
        std.debug.assert(index < self.count);
        return std.mem.readIntLittle(u32, self.buffer[4 * index ..][0..4]);
    }

    pub fn iterator(self: RelocationTable) Iterator {
        return Iterator{ .table = self };
    }

    pub const Iterator = struct {
        table: RelocationTable,
        index: u32 = 0,

        pub fn next(self: *Iterator) ?u32 {
            if (self.index >= self.table.count) {
                return null;
            }
            const value = self.table.get(self.index);
            self.index += 1;
            return value;
        }
    };
};

pub const StringTable = struct {
    buffer: []const u8,
    limit: u32,

    pub fn init(buffer: []const u8) StringTable {
        const limit = std.mem.readIntLittle(u32, buffer[0..4]);
        return StringTable{
            .limit = limit,
            .buffer = buffer,
        };
    }

    pub fn iterator(self: StringTable) Iterator {
        return Iterator{ .table = self };
    }

    pub fn get(self: StringTable, offset: u32) String {
        const length = std.mem.readIntLittle(u32, self.buffer[offset..][0..4]);

        return String{
            .offset = @truncate(u32, offset),
            .text = self.buffer[offset + 4 ..][0..length :0],
        };
    }

    pub const Iterator = struct {
        table: StringTable,
        offset: u32 = 4, // we start *after* the table length marker

        pub fn next(self: *Iterator) ?String {
            if (self.offset >= self.table.limit)
                return null;

            const string = self.table.get(self.offset);

            self.offset += 4; // skip length
            self.offset += @truncate(u32, string.text.len);
            self.offset += 1; // skip zero terminator

            return string;
        }
    };
};

pub const String = struct {
    offset: u32,
    text: [:0]const u8,
};

fn hexToBits(comptime str: []const u8) *const [str.len / 2]u8 {
    comptime {
        comptime var res: [str.len / 2]u8 = undefined;
        @setEvalBranchQuota(8 * str.len);

        inline for (res) |*c, i| {
            c.* = std.fmt.parseInt(u8, str[2 * i ..][0..2], 16) catch unreachable;
        }
        return &res;
    }
}

test "parse empty, but valid file" {
    _ = try View.init(hexToBits("fbadb60200000000000000000000000000000000000000000000000002000000"), .{});
}

test "parse invalid header" {
    // Header too short:
    try std.testing.expectError(error.InvalidHeader, View.init(hexToBits(""), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidHeader, View.init(hexToBits("f2adb602"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb60200000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb6020000000000000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb60200000000000000000000000000000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb6020000000000000000000000000000000000000000"), .{ .validate_symbols = true }));

    // invalid/out of bounds header fields:

    //                                                                          EEEEEEEEIIIIIIIISSSSSSSSssssssssllllllllBB______
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602190000000000000000000000000000000000000002000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000001900000000000000000000000000000002000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000019000000000000000000000002000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb6020000000000000000000000001C0000000100000002000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000000000001D00000002000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000000000000000000000000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000000000000000000003000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000000000000000000005000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000000000000000000007000000"), .{ .validate_symbols = true }));
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000000000000000000009000000"), .{ .validate_symbols = true }));

    // out of bounds table size:

    // import table
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb6021C00000000000000000000000000000000000000020000000300000001000000020000000300000004000000050000000600000"), .{ .validate_symbols = true }));

    // export table
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000001C000000000000000000000000000000020000000300000001000000020000000300000004000000050000000600000"), .{ .validate_symbols = true }));

    // string table
    //                                                                  MMMMMMMMEEEEEEEERRRRRRRRIIIIIIIISSSSSSSSssssssssllllllllBB______LLLLLLLLllllllllH e l l o ZZllllllllW o r l d ZZllllllllZ i g   i s   g r e a t ! ZZ
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000200000000000000000000000020000002A0000000500000048656C6C6F0005000000576F726C64000D0000005A6967206973206772656174210"), .{})); // too short
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000200000000000000000000000020000002A0000000500000048656C6C6F0105000000576F726C64000D0000005A69672069732067726561742100"), .{})); // non-null item
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000200000000000000000000000020000002A0000000500000048656C6C6F0005000000576F726C64020D0000005A69672069732067726561742100"), .{})); // non-null item
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000200000000000000000000000020000002A0000000500000048656C6C6F0005000000576F726C64000D0000005A69672069732067726561742103"), .{})); // non-null item
    try std.testing.expectError(error.InvalidData, View.init(hexToBits("fbadb602000000000000000000000000200000000000000000000000020000002A0000000500000048656C6C6F0005000000576F726C64000E0000005A6967206973206772656174210000000000000000"), .{})); // item out of table
}

test "parse string table" {
    //                                    MMMMMMMMEEEEEEEERRRRRRRRIIIIIIIISSSSSSSSssssssssllllllllBB______LLLLLLLLllllllllH e l l o ZZllllllllW o r l d ZZllllllllZ i g   i s   g r e a t ! ZZ
    const view = try View.init(hexToBits("fbadb602000000000000000000000000200000000000000000000000020000002A0000000500000048656C6C6F0005000000576F726C64000D0000005A69672069732067726561742100"), .{});

    const table = view.strings() orelse return error.MissingTable;

    var iter = table.iterator();
    try std.testing.expectEqualStrings("Hello", (iter.next() orelse return error.UnexpectedNull).text);
    try std.testing.expectEqualStrings("World", (iter.next() orelse return error.UnexpectedNull).text);
    try std.testing.expectEqualStrings("Zig is great!", (iter.next() orelse return error.UnexpectedNull).text);
    try std.testing.expectEqual(@as(?String, null), iter.next());
}

test "parse export table" {
    //                                    MMMMMMMMEEEEEEEEIIIIIIIIRRRRRRRRSSSSSSSSssssssssllllllllBB______LLLLLLLLNNNNNNN1OOOOOOO1NNNNNNN2OOOOOOO2NNNNNNN3OOOOOOO3LLLLLLLLllllllll..........................ZZ
    const view = try View.init(hexToBits("fbadb6022000000000000000000000003C00000000000000080000000200000003000000010000000200000003000000040000000500000006000000160000000D000000FFFFFFFFFFFFFFFFFFFFFFFFFF00"), .{});

    const sym_1 = Symbol{ .symbol_name = 1, .offset = 2 };
    const sym_2 = Symbol{ .symbol_name = 3, .offset = 4 };
    const sym_3 = Symbol{ .symbol_name = 5, .offset = 6 };

    const table = view.exports() orelse return error.MissingTable;

    try std.testing.expectEqual(@as(usize, 3), table.count);

    try std.testing.expectEqual(sym_1, table.get(0));
    try std.testing.expectEqual(sym_2, table.get(1));
    try std.testing.expectEqual(sym_3, table.get(2));

    var iter = table.iterator();

    try std.testing.expectEqual(@as(?Symbol, sym_1), iter.next());
    try std.testing.expectEqual(@as(?Symbol, sym_2), iter.next());
    try std.testing.expectEqual(@as(?Symbol, sym_3), iter.next());
    try std.testing.expectEqual(@as(?Symbol, null), iter.next());
}

test "parse import table" {
    //                                    MMMMMMMMEEEEEEEEIIIIIIIIRRRRRRRRSSSSSSSSssssssssllllllllBB______LLLLLLLLNNNNNNN1OOOOOOO1NNNNNNN2OOOOOOO2NNNNNNN3OOOOOOO3LLLLLLLLllllllll..........................ZZ
    const view = try View.init(hexToBits("fbadb6020000000020000000000000003C00000000000000080000000200000003000000010000000200000003000000040000000500000006000000160000000D000000FFFFFFFFFFFFFFFFFFFFFFFFFF00"), .{});

    const sym_1 = Symbol{ .symbol_name = 1, .offset = 2 };
    const sym_2 = Symbol{ .symbol_name = 3, .offset = 4 };
    const sym_3 = Symbol{ .symbol_name = 5, .offset = 6 };

    const table = view.imports() orelse return error.MissingTable;

    try std.testing.expectEqual(@as(usize, 3), table.count);

    try std.testing.expectEqual(sym_1, table.get(0));
    try std.testing.expectEqual(sym_2, table.get(1));
    try std.testing.expectEqual(sym_3, table.get(2));

    var iter = table.iterator();

    try std.testing.expectEqual(@as(?Symbol, sym_1), iter.next());
    try std.testing.expectEqual(@as(?Symbol, sym_2), iter.next());
    try std.testing.expectEqual(@as(?Symbol, sym_3), iter.next());
    try std.testing.expectEqual(@as(?Symbol, null), iter.next());
}

test "parse relocation table" {
    // we overlap relocations and sections here as it doesn't do any harm
    //                                    MMMMMMMMEEEEEEEEIIIIIIIIRRRRRRRRSSSSSSSSssssssssllllllllBB______LLLLLLLLaaaaaaaabbbbbbbbcccccccc
    const view = try View.init(hexToBits("fbadb60200000000000000002000000000000000200000000C0000000200000003000000040000000500000002000000"), .{});

    const table = view.relocations() orelse return error.MissingTable;

    try std.testing.expectEqual(@as(u32, 4), table.get(0));
    try std.testing.expectEqual(@as(u32, 5), table.get(1));
    try std.testing.expectEqual(@as(u32, 2), table.get(2));

    var iter = table.iterator();
    try std.testing.expectEqual(@as(?u32, 4), iter.next());
    try std.testing.expectEqual(@as(?u32, 5), iter.next());
    try std.testing.expectEqual(@as(?u32, 2), iter.next());
    try std.testing.expectEqual(@as(?u32, null), iter.next());
}

const SymbolName = struct {
    name: []const u8,
    offset: u32,
};

fn expectSymbol(name: []const u8, offset: u32) SymbolName {
    return SymbolName{
        .name = name,
        .offset = offset,
    };
}

const SlfExpectation = struct {
    exports: []const SymbolName = &.{},
    imports: []const SymbolName = &.{},
    relocs: []const u32 = &.{},
    data: []const u8 = "",
};

fn expectSlf(dataset: []const u8, expected: SlfExpectation) !void {
    const view = try View.init(dataset, .{});

    const imports = view.imports() orelse return error.UnexpectedData;
    const exports = view.exports() orelse return error.UnexpectedData;
    const relocations = view.relocations() orelse return error.UnexpectedData;
    const strings = view.strings() orelse return error.UnexpectedData;

    try std.testing.expectEqual(expected.exports.len, exports.count);
    try std.testing.expectEqual(expected.imports.len, imports.count);
    try std.testing.expectEqual(expected.relocs.len, relocations.count);

    _ = strings;

    // TODO: Implement better result verification

    try std.testing.expectEqualStrings(expected.data, view.data());
}

test "builder api: empty builder" {
    var buffer: [65536]u8 = undefined;
    var source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(&buffer) };
    {
        var builder = try Builder.init(std.testing.allocator, .@"16 bits", &source);
        defer builder.deinit();

        try builder.finalize();
    }
    try expectSlf(source.buffer.getWritten(), .{});
}

test "builder api: append data" {
    var buffer: [65536]u8 = undefined;
    var source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(&buffer) };
    {
        var builder = try Builder.init(std.testing.allocator, .@"16 bits", &source);
        defer builder.deinit();

        try builder.append("Hello, World!");

        try builder.finalize();
    }
    try expectSlf(source.buffer.getWritten(), .{
        .data = "Hello, World!",
    });
}

fn dumpHexStream(dataset: []const u8) void {
    var i: usize = 0;
    while (i < dataset.len) {
        const limit = std.math.min(16, dataset.len - i);
        std.debug.print("{X:0>8} {}\n", .{ i, std.fmt.fmtSliceHexLower(dataset[i..][0..limit]) });
        i += limit;
    }
}
