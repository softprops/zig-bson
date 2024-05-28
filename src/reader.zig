const std = @import("std");
const types = @import("types.zig");
const RawBson = types.RawBson;
const Type = types.Type;

pub fn Reader(comptime T: type) type {
    return struct {
        reader: std.io.CountingReader(T),
        arena: std.heap.ArenaAllocator,

        pub fn init(allocator: std.mem.Allocator, rdr: T) @This() {
            return .{ .reader = std.io.countingReader(rdr), .arena = std.heap.ArenaAllocator.init(allocator) };
        }

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        // https://bsonspec.org/spec.html
        // document = int32 -> e_list -> unsigned_byte(0)
        // e_list = element -> e_list -> ""
        // element = signed_byte(n) -> cstr -> value
        pub fn read(self: *@This()) !RawBson {
            const len = try self.reader.reader().readInt(i32, .little);

            const tpe = Type.fromInt(try self.reader.reader().readInt(i8, .little));

            // read c string, delimited by null (0) byte
            const ename = try self.reader.reader().readUntilDelimiterOrEofAlloc(self.arena.allocator(), 0, std.math.maxInt(usize));
            std.debug.print("ename {?s}\n", .{ename});

            const raw = switch (tpe) {
                .min_key => RawBson{ .min_key = types.MinKey{} },
                .max_key => RawBson{ .max_key = types.MaxKey{} },
                .null => RawBson{ .null = {} },
                .datetime => RawBson{
                    .datetime = types.Datetime.fromMillis(
                        try self.reader.reader().readInt(i64, .little),
                    ),
                },
                .timestamp => RawBson{
                    .timestamp = types.Timestamp.init(
                        try self.reader.reader().readInt(u32, .little),
                        try self.reader.reader().readInt(u32, .little),
                    ),
                },
                .string => blk: {
                    const strLen = try self.reader.reader().readInt(i32, .little);
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
                .object_id => blk: {
                    var bytes: [12]u8 = undefined;
                    const count = try self.reader.reader().read(&bytes);
                    if (count != 12) {
                        std.debug.print("only read {d} objectId bytes", .{count});
                        return error.TooFewObjectIdBytes;
                    }
                    break :blk RawBson{
                        .object_id = try types.ObjectId.fromBytes(&bytes),
                    };
                },
                .int64 => RawBson{
                    .int64 = types.Int64{
                        .value = try self.reader.reader().readInt(i64, .little),
                    },
                },
                .int32 => RawBson{
                    .int32 = types.Int32{
                        .value = try self.reader.reader().readInt(i32, .little),
                    },
                },
                .boolean => RawBson{
                    .boolean = (try self.reader.reader().readInt(i8, .little)) == 1,
                },
                .regex => RawBson{
                    .regex = types.Regex.init(
                        try self.reader.reader().readUntilDelimiterOrEofAlloc(
                            self.arena.allocator(),
                            0,
                            std.math.maxInt(usize),
                        ) orelse "",
                        try self.reader.reader().readUntilDelimiterOrEofAlloc(
                            self.arena.allocator(),
                            0,
                            std.math.maxInt(usize),
                        ) orelse "",
                    ),
                },
                else => {
                    std.debug.print("unsupported type {any}\n", .{tpe});
                    @panic("unsupported type");
                },
            };
            if (try self.reader.reader().readByte() != 0) {
                std.debug.print("invalid end of stream", .{});
            }
            std.debug.print("len {d} read {d}\n", .{ len, self.reader.bytes_read });
            return raw;
        }
    };
}
