const std = @import("std");
const types = @import("types.zig");
const RawBson = types.RawBson;
const Type = types.Type;

/// see https://bsonspec.org/spec.html
pub fn Reader(comptime T: type) type {
    return struct {
        reader: std.io.CountingReader(T),
        arena: std.heap.ArenaAllocator,

        pub fn init(allocator: std.mem.Allocator, rdr: T) @This() {
            return .{ .reader = std.io.countingReader(rdr), .arena = std.heap.ArenaAllocator.init(allocator) };
        }

        // create a new Reader starting where this reader left off, sharing allocation states so that it only needs
        // freed once
        fn fork(self: *@This()) @This() {
            return .{ .reader = std.io.countingReader(self.reader.child_reader), .arena = self.arena };
        }

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        pub fn read(self: *@This()) !RawBson {
            const len = try self.readI32();
            var elements = std.ArrayList(types.Document.Element).init(self.arena.allocator());
            defer elements.deinit();
            std.debug.print("reading doc of len {d} curr count {d}\n", .{ len, self.reader.bytes_read });

            while (self.reader.bytes_read < len - 1) {
                std.debug.print("bytes read {d}, total bytes {d}\n", .{ self.reader.bytes_read, len });
                const maybe_type = try self.readI8();
                const tpe = Type.fromInt(maybe_type);
                const name = try self.readCStr();
                const element = switch (tpe) {
                    .double => blk: {
                        break :blk RawBson{ .double = types.Double.init(try self.readF64()) };
                    },
                    .string => blk: {
                        const strLen = try self.readI32();
                        var buf = try std.ArrayList(u8).initCapacity(
                            self.arena.allocator(),
                            @intCast(strLen - 1),
                        );
                        defer buf.deinit();
                        try buf.resize(@intCast(strLen - 1));
                        var bytes = try buf.toOwnedSlice();
                        _ = try self.reader.reader().readAtLeast(
                            bytes[0..],
                            @intCast(strLen - 1),
                        );
                        if (try self.reader.reader().readByte() != 0) {
                            return error.NullTerminatorNotFound;
                        }
                        break :blk RawBson{ .string = bytes };
                    },
                    .document => blk: {
                        std.debug.print("forking reader after byte # {d}\n", .{self.reader.bytes_read});
                        var child = self.fork();
                        const raw = try child.read();
                        // inform the current reader of the byte count that were read...
                        self.reader.bytes_read += child.reader.bytes_read;
                        break :blk raw;
                    },
                    .array => blk: {
                        std.debug.print("forking reader after byte # {d}\n", .{self.reader.bytes_read});
                        var child = self.fork();
                        const raw = try child.read();
                        // inform the current reader of the byte count that were read...
                        self.reader.bytes_read += child.reader.bytes_read;
                        switch (raw) {
                            .document => |doc| {
                                // an array is just a document whose keys are array indexes. i.e { "0": "...", "1": "..." }
                                var elems = try std.ArrayList(RawBson).initCapacity(self.arena.allocator(), doc.elements.len);
                                defer elems.deinit();
                                for (doc.elements) |elem| {
                                    elems.appendAssumeCapacity(elem.v);
                                }
                                break :blk RawBson{ .array = try elems.toOwnedSlice() };
                            },
                            else => unreachable,
                        }
                    },
                    // .binary => ...
                    .undefined => RawBson{ .undefined = {} },
                    .object_id => blk: {
                        var bytes: [12]u8 = undefined;
                        const count = try self.reader.reader().read(&bytes);
                        if (count != 12) {
                            std.debug.print("only read {d} objectId bytes", .{count});
                            return error.TooFewObjectIdBytes;
                        }
                        break :blk RawBson{
                            .object_id = try types.ObjectId.fromBytes(bytes),
                        };
                    },
                    .boolean => RawBson{
                        .boolean = (try self.readI8()) == 1,
                    },
                    .datetime => RawBson{
                        .datetime = types.Datetime.fromMillis(
                            try self.readI64(),
                        ),
                    },
                    .null => RawBson{ .null = {} },
                    .regex => RawBson{
                        .regex = types.Regex.init(
                            try self.readCStr(),
                            try self.readCStr(),
                        ),
                    },
                    // .dbpointer =>
                    .javascript => blk: {
                        const strLen = try self.readI32();
                        var buf = try std.ArrayList(u8).initCapacity(
                            self.arena.allocator(),
                            @intCast(strLen - 1),
                        );
                        defer buf.deinit();
                        try buf.resize(@intCast(strLen - 1));
                        var bytes = try buf.toOwnedSlice();
                        _ = try self.reader.reader().readAtLeast(
                            bytes[0..],
                            @intCast(strLen - 1),
                        );
                        if (try self.reader.reader().readByte() != 0) {
                            return error.NullTerminatorNotFound;
                        }
                        break :blk RawBson{ .javascript = types.JavaScript.init(bytes) };
                    },
                     .symbol => blk: {
                        const strLen = try self.readI32();
                        var buf = try std.ArrayList(u8).initCapacity(
                            self.arena.allocator(),
                            @intCast(strLen - 1),
                        );
                        defer buf.deinit();
                        try buf.resize(@intCast(strLen - 1));
                        var bytes = try buf.toOwnedSlice();
                        _ = try self.reader.reader().readAtLeast(
                            bytes[0..],
                            @intCast(strLen - 1),
                        );
                        if (try self.reader.reader().readByte() != 0) {
                            return error.NullTerminatorNotFound;
                        }
                        break :blk RawBson{ .symbol = types.Symbol.init(bytes) };
                    },
                    // code with scope
                    .int32 => RawBson{
                        .int32 = types.Int32{
                            .value = try self.readI32(),
                        },
                    },
                    .timestamp => RawBson{
                        .timestamp = types.Timestamp.init(
                            try self.readU32(),
                            try self.readU32(),
                        ),
                    },
                    .int64 => RawBson{
                        .int64 = types.Int64{
                            .value = try self.readI64(),
                        },
                    },
                    .decimal128 => blk: {
                        var bytes: [16]u8 = undefined;
                        const count = try self.reader.reader().read(&bytes);
                        if (count != 16) {
                            return error.TooFewDecimal128Bytes;
                        }
                        break :blk RawBson{
                            .decimal128 = types.Decimal128{
                                .value = &bytes,
                            },
                        };
                    },
                    .min_key => RawBson{ .min_key = types.MinKey{} },
                    .max_key => RawBson{ .max_key = types.MaxKey{} },
                    else => {
                        std.debug.print("unsupported type {any}\n", .{tpe});
                        @panic("unsupported type");
                    },
                };
                try elements.append(.{ .k = name, .v = element });
            }

            std.debug.print("finished with fields...\n", .{});
            if (try self.reader.reader().readByte() != 0) {
                std.debug.print("warning: invalid end of stream", .{});
            }
            std.debug.print("len {d} read {d}\n", .{ len, self.reader.bytes_read });

            return RawBson{ .document = types.Document.init(try elements.toOwnedSlice()) };
        }

        inline fn readI32(self: *@This()) !i32 {
            return self.reader.reader().readInt(i32, .little);
        }

        inline fn readI8(self: *@This()) !i8 {
            return self.reader.reader().readInt(i8, .little);
        }

        inline fn readCStr(self: *@This()) ![]u8 {
            return (try self.reader.reader().readUntilDelimiterOrEofAlloc(self.arena.allocator(), 0, std.math.maxInt(usize))) orelse "";
        }

        inline fn readI64(self: *@This()) !i64 {
            return self.reader.reader().readInt(i64, .little);
        }

        inline fn readF64(self: *@This()) !f64 {
            // fixme. not working yet
            return @floatFromInt(try self.reader.reader().readInt(u64, .little));
        }

        inline fn readU32(self: *@This()) !u32 {
            return self.reader.reader().readInt(u32, .little);
        }
    };
}
