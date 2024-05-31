const std = @import("std");
const types = @import("types.zig");
const RawBson = types.RawBson;

/// A Reader deserializes BSON bytes from a provided io.Reader
/// into a RawBson type, typically a RawBson.document with embedded BSON types
///
/// see https://bsonspec.org/spec.html
pub fn Reader(comptime T: type) type {
    return struct {
        reader: std.io.CountingReader(T),
        arena: std.heap.ArenaAllocator,

        pub fn init(allocator: std.mem.Allocator, rdr: T) @This() {
            return .{
                .reader = std.io.countingReader(rdr),
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        /// create a new Reader starting where this reader left off, sharing allocation states so that it only needs
        /// freed once
        fn fork(self: *@This()) @This() {
            return init(self.arena.allocator(), self.reader.child_reader);
        }

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        pub fn read(self: *@This()) !RawBson {
            const len = try self.readI32();
            var elements = std.ArrayList(types.Document.Element).init(self.arena.allocator());
            defer elements.deinit();
            std.log.debug("reading doc of len {d} curr count {d}", .{ len, self.reader.bytes_read });

            while (self.reader.bytes_read < len - 1) {
                std.log.debug("bytes read {d}, total bytes {d}", .{ self.reader.bytes_read, len });
                const tpe = types.Type.fromInt(try self.readI8());
                const name = try self.readCStr();
                const element = switch (tpe) {
                    .double => RawBson{
                        .double = types.Double.init(try self.readF64()),
                    },
                    .string => RawBson{
                        .string = try self.readStr(),
                    },
                    .document => blk: {
                        var child = self.fork();
                        const raw = try child.read();
                        // update local read bytes
                        self.reader.bytes_read += child.reader.bytes_read;
                        break :blk raw;
                    },
                    .array => blk: {
                        std.log.debug("forking reader after byte # {d}\n", .{self.reader.bytes_read});
                        var child = self.fork();
                        const raw = try child.read();
                        // update local read bytes
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
                    .binary => blk: {
                        const binLen = try self.readI32();
                        const st = types.SubType.fromInt(try self.readU8());
                        var buf = try std.ArrayList(u8).initCapacity(self.arena.allocator(), @intCast(binLen));
                        defer buf.deinit();
                        try buf.resize(@intCast(binLen));
                        const bytes = try buf.toOwnedSlice();
                        _ = try self.reader.reader().readAll(bytes);
                        break :blk RawBson{ .binary = types.Binary.init(bytes, st) };
                    },
                    .undefined => RawBson{ .undefined = {} },
                    .object_id => blk: {
                        var bytes: [12]u8 = undefined;
                        const count = try self.reader.reader().readAll(&bytes);
                        if (count != 12) {
                            std.log.debug("only read {d} objectId bytes", .{count});
                            return error.TooFewObjectIdBytes;
                        }
                        break :blk RawBson{
                            .object_id = types.ObjectId.fromBytes(bytes),
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
                    .dbpointer => blk: {
                        const ref = try self.readStr();

                        var id_bytes: [12]u8 = undefined;
                        _ = try self.reader.reader().readAll(&id_bytes);

                        break :blk RawBson{
                            .dbpointer = types.DBPointer.init(ref, types.ObjectId.fromBytes(id_bytes)),
                        };
                    },
                    .javascript => blk: {
                        break :blk RawBson{ .javascript = types.JavaScript.init(try self.readStr()) };
                    },
                    .javascript_with_scope => blk: {
                        _ = try self.readI32();
                        const code = try self.readStr();
                        var child = self.fork();
                        const raw = try child.read();
                        self.reader.bytes_read += child.reader.bytes_read;
                        switch (raw) {
                            .document => |doc| break :blk RawBson{
                                .javascript_with_scope = types.JavaScriptWithScope.init(code, doc),
                            },
                            else => unreachable,
                        }
                    },
                    .symbol => blk: {
                        break :blk RawBson{ .symbol = types.Symbol.init(try self.readStr()) };
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
                        _ = try self.reader.reader().readAll(&bytes);
                        break :blk RawBson{
                            .decimal128 = types.Decimal128{
                                .value = bytes,
                            },
                        };
                    },
                    .min_key => RawBson{ .min_key = types.MinKey{} },
                    .max_key => RawBson{ .max_key = types.MaxKey{} },
                };
                try elements.append(.{ .k = name, .v = element });
            }

            std.log.debug("finished with fields...", .{});
            if (try self.reader.reader().readByte() != 0) {
                std.log.err("warning: invalid end of stream", .{});
                return error.InvalidEndOfStream;
            }
            std.log.debug("len {d} read {d}", .{ len, self.reader.bytes_read });

            return RawBson{ .document = types.Document.init(try elements.toOwnedSlice()) };
        }

        inline fn readI32(self: *@This()) !i32 {
            return self.reader.reader().readInt(i32, .little);
        }

        inline fn readI8(self: *@This()) !i8 {
            return self.reader.reader().readInt(i8, .little);
        }

        inline fn readU8(self: *@This()) !u8 {
            return self.reader.reader().readInt(u8, .little);
        }

        inline fn readCStr(self: *@This()) ![]u8 {
            return (try self.reader.reader().readUntilDelimiterOrEofAlloc(self.arena.allocator(), 0, std.math.maxInt(usize))) orelse "";
        }

        inline fn readStr(self: *@This()) ![]u8 {
            const strLen = try self.readI32();
            var buf = try std.ArrayList(u8).initCapacity(
                self.arena.allocator(),
                @intCast(strLen - 1),
            );
            defer buf.deinit();
            try buf.resize(@intCast(strLen - 1));
            var bytes = try buf.toOwnedSlice();
            _ = try self.reader.reader().readAll(
                bytes[0..],
            );
            if (try self.reader.reader().readByte() != 0) {
                return error.NullTerminatorNotFound;
            }
            return bytes;
        }

        inline fn readI64(self: *@This()) !i64 {
            return self.reader.reader().readInt(i64, .little);
        }

        inline fn readF64(self: *@This()) !f64 {
            var bytes: [8]u8 = undefined;
            _ = try self.reader.reader().readAll(&bytes);
            return @bitCast(bytes);
        }

        inline fn readU32(self: *@This()) !u32 {
            return self.reader.reader().readInt(u32, .little);
        }
    };
}
