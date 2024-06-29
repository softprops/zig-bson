const std = @import("std");
const types = @import("types.zig");
const RawBson = types.RawBson;

/// A Reader deserializes BSON bytes from a provided Reader type
/// into a RawBson type, typically a RawBson.document with embedded BSON types, following the [BSON spec](https://bsonspec.org/spec.html)
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

        /// callers sure ensure this is called to free an allocated memory
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        pub fn read(self: *@This()) !RawBson {
            const len = try self.readI32();
            var elements = std.ArrayList(types.Document.Element).init(self.arena.allocator());
            defer elements.deinit();
            std.log.debug("reading doc of len {d} curr count {d}", .{ len, self.reader.bytes_read });

            while (self.reader.bytes_read < len - 1) {
                const tpe = types.Type.fromInt(try self.readI8());
                const name = try self.readCStr();
                const element = switch (tpe) {
                    .double => RawBson.double(try self.readF64()),
                    .string => RawBson.string(try self.readStr()),
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
                                var elems = try self.arena.allocator().alloc(RawBson, doc.elements.len);
                                for (doc.elements, 0..) |elem, i| {
                                    elems[i] = elem.@"1";
                                }
                                break :blk RawBson.array(elems);
                            },
                            else => unreachable,
                        }
                    },
                    .binary => blk: {
                        const binLen = try self.readI32();
                        const st = types.SubType.fromInt(try self.readU8());
                        const bytes = try self.arena.allocator().alloc(u8, @intCast(binLen));
                        _ = try self.reader.reader().readAll(bytes);
                        break :blk switch (st) {
                            .binary_old => old: {
                                // binary old has a special case format where the opaque list of bytes
                                // contain a len and an inner opaque list of bytes
                                var fbs = std.io.fixedBufferStream(bytes);
                                var innerReader = fbs.reader();
                                const innerLen = try innerReader.readInt(i32, .little);
                                const innerBytes = try self.arena.allocator().alloc(u8, @intCast(innerLen)); //try innerBuf.toOwnedSlice();
                                _ = try innerReader.readAll(innerBytes);
                                break :old RawBson.binary(innerBytes, st);
                            },
                            else => RawBson{ .binary = types.Binary.init(bytes, st) },
                        };
                    },
                    .undefined => RawBson.undefined(),
                    .object_id => blk: {
                        var bytes: [12]u8 = undefined;
                        _ = try self.reader.reader().readAll(&bytes);
                        break :blk RawBson.objectId(bytes);
                    },
                    .boolean => RawBson.boolean(try self.readI8() == 1),
                    .datetime => RawBson.datetime(try self.readI64()),
                    .null => RawBson.null(),
                    .regex => RawBson.regex(try self.readCStr(), try self.readCStr()),
                    .dbpointer => blk: {
                        const ref = try self.readStr();

                        var id_bytes: [12]u8 = undefined;
                        _ = try self.reader.reader().readAll(&id_bytes);

                        break :blk RawBson{
                            .dbpointer = types.DBPointer.init(ref, types.ObjectId.fromBytes(id_bytes)),
                        };
                    },
                    .javascript => RawBson.javaScript(try self.readStr()),
                    .javascript_with_scope => blk: {
                        _ = try self.readI32();
                        const code = try self.readStr();
                        var child = self.fork();
                        const raw = try child.read();
                        self.reader.bytes_read += child.reader.bytes_read;
                        switch (raw) {
                            .document => |doc| break :blk RawBson.javaScriptWithScope(code, doc),
                            else => unreachable,
                        }
                    },
                    .symbol => RawBson.symbol(try self.readStr()),
                    .int32 => RawBson.int32(try self.readI32()),
                    .timestamp => RawBson.timestamp(try self.readU32(), try self.readU32()),
                    .int64 => RawBson.int64(try self.readI64()),
                    .decimal128 => blk: {
                        var bytes: [16]u8 = undefined;
                        _ = try self.reader.reader().readAll(&bytes);
                        break :blk RawBson.decimal128(bytes);
                    },
                    .min_key => RawBson.minKey(),
                    .max_key => RawBson.maxKey(),
                };
                try elements.append(.{ name, element });
            }

            const lastByte = try self.reader.reader().readByte();
            if (lastByte != 0) {
                std.log.err("warning: invalid end of stream. last byte was {d}", .{lastByte});
                return error.InvalidEndOfStream;
            }
            std.log.debug("len {d} read {d}", .{ len, self.reader.bytes_read });

            return RawBson.document(try elements.toOwnedSlice());
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
            return (try self.reader.reader().readUntilDelimiterAlloc(
                self.arena.allocator(),
                0,
                std.math.maxInt(usize),
            ));
        }

        inline fn readStr(self: *@This()) ![]u8 {
            const strLen = try self.readI32();
            const bytes = try self.arena.allocator().alloc(u8, @intCast(strLen - 1));
            _ = try self.reader.reader().readAll(
                bytes,
            );
            if (try self.reader.reader().readByte() != 0) {
                return error.NullTerminatorNotFound;
            }
            // data should be valid ut8
            if (!std.unicode.utf8ValidateSlice(bytes)) {
                return error.InvalidUtf8;
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

/// Creates a new BSON reader to deserialize documents from bytes provided by an underlying reader
/// Callers should call `deinit()` on after using the reader
pub fn reader(allocator: std.mem.Allocator, underlying: anytype) Reader(@TypeOf(underlying)) {
    return Reader(@TypeOf(underlying)).init(allocator, underlying);
}
