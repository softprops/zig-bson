const std = @import("std");
const types = @import("types.zig");
const RawBson = types.RawBson;

/// A Writer serializes BSON to a provided Writer type following the [BSON spec](https://bsonspec.org/spec.html)
pub fn Writer(comptime T: type) type {
    return struct {
        writer: std.io.CountingWriter(T),
        arena: std.heap.ArenaAllocator,

        pub fn init(allocator: std.mem.Allocator, wtr: T) @This() {
            return .{
                .writer = std.io.countingWriter(wtr),
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        /// callers should ensure this is called to free an allocated memory
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        pub fn writeFrom(self: *@This(), data: anytype) !void {
            const raw = try RawBson.from(self.arena.allocator(), data);
            try write(raw.value);
        }

        pub fn write(self: *@This(), bson: RawBson) !void {
            switch (bson) {
                .double => |v| {
                    const bytes: [8]u8 = @bitCast(v.value);
                    try self.writer.writer().writeAll(&bytes);
                },
                .string => |v| try self.writeString(v),
                .document => |v| {
                    var buf = std.ArrayList(u8).init(self.arena.allocator());
                    defer buf.deinit();
                    var docWriter = Writer(@TypeOf(buf.writer())).init(
                        self.arena.allocator(),
                        buf.writer(),
                    );
                    for (v.elements) |elem| {
                        try docWriter.writeInt(i8, elem.@"1".toType().toInt());
                        _ = try docWriter.writeAll(elem.@"0");
                        try docWriter.writeSentinelByte();
                        try docWriter.write(elem.@"1".*);
                    }

                    // we add 5 to account for 1. the 4 byte len itself and 2. 1 extra null byte at the end
                    try self.writeInt(i32, @intCast(buf.items.len + 5));
                    try self.writeAll(try buf.toOwnedSlice());
                    try self.writeSentinelByte();
                },
                .array => |v| {
                    var buf = std.ArrayList(u8).init(self.arena.allocator());
                    defer buf.deinit();
                    var docWriter = Writer(@TypeOf(buf.writer())).init(
                        self.arena.allocator(),
                        buf.writer(),
                    );
                    for (v, 0..) |elem, i| {
                        try docWriter.writeInt(i8, elem.toType().toInt());
                        // keys are elem indexes
                        try std.fmt.format(docWriter.writer.writer(), "{d}", .{i});
                        try docWriter.writeSentinelByte();
                        try docWriter.write(elem);
                    }

                    // we add 5 to account for 1. the 4 byte len itself and 2. 1 extra null byte at the end
                    try self.writeInt(i32, @intCast(buf.items.len + 5));
                    try self.writeAll(try buf.toOwnedSlice());
                    try self.writeSentinelByte();
                },
                .boolean => |v| try self.writeInt(i8, if (v) 1 else 0),
                .regex => |v| {
                    try self.writeCStr(v.pattern);
                    try self.writeCStr(v.options);
                },
                .dbpointer => |v| {
                    try self.writeString(v.ref);
                    try self.write(.{ .object_id = v.id });
                },
                .javascript => |v| try self.writeString(v.value),
                .javascript_with_scope => |v| {
                    try self.writeInt(i32, @intCast(v.value.len));
                    try self.writeString(v.value);
                    try self.write(.{ .document = v.scope });
                },
                .int32 => |v| try self.writeInt(i32, v.value),
                .int64 => |v| try self.writeInt(i64, v.value),
                .decimal128 => {},
                .timestamp => |v| {
                    try self.writeInt(u32, v.increment);
                    try self.writeInt(u32, v.timestamp);
                },
                .binary => |v| {
                    try self.writeInt(i32, @intCast(v.value.len));
                    try self.writeInt(u8, v.subtype.toInt());
                    _ = try self.writeAll(v.value);
                },
                .object_id => |v| try self.writeAll(&v.bytes),
                .datetime => |v| try self.writeInt(i64, v.millis),
                .symbol => |v| try self.writeString(v.value),
                // noops
                .max_key, .min_key, .null, .undefined => {},
            }
        }

        fn writeInt(self: *@This(), comptime INT: type, value: INT) !void {
            try self.writer.writer().writeInt(INT, value, .little);
        }

        fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.writer.writer().writeAll(bytes);
        }

        fn writeString(self: *@This(), value: []const u8) !void {
            try self.writeInt(i32, @intCast(value.len + 1));
            try self.writeAll(value);
            try self.writeSentinelByte();
        }

        fn writeCStr(self: *@This(), value: []const u8) !void {
            try self.writeAll(value);
            try self.writeSentinelByte();
        }

        fn writeSentinelByte(self: *@This()) !void {
            try self.writer.writer().writeByte(0);
        }
    };
}
/// Creates a new BSON writer to serialize documents to an underlying writer
/// Callers should call `deinit()` on after using the writer
pub fn writer(allocator: std.mem.Allocator, underlying: anytype) Writer(@TypeOf(underlying)) {
    return Writer(@TypeOf(underlying)).init(allocator, underlying);
}

test Writer {
    const reader = @import("reader.zig").reader;

    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    var bsonWriter = writer(allocator, buf.writer());
    defer bsonWriter.deinit();

    const doc = try RawBson.createDocument(
        &.{
            .{ "a", types.RawBson.makeString("a") },
            .{ "b", types.RawBson.makeBoolean(true) },
            .{ "c", types.RawBson.makeMinKey() },
            .{ "d", types.RawBson.makeMaxKey() },
            .{ "e", types.RawBson.makeArray(
                &[_]RawBson{
                    RawBson.makeInt32(10),
                    RawBson.makeInt32(11),
                    RawBson.makeInt32(12),
                },
            ) },
            .{ "f", RawBson.makeDatetime(0) },
            .{ "g", RawBson.makeDouble(1.23) },
            .{ "h", try RawBson.makeObjectIdHex("56e1fc72e0c917e9c4714161") },
        },
        allocator
    );
    defer doc.deinit(allocator);
    try bsonWriter.write(doc);
    const written = try buf.toOwnedSlice();
    defer allocator.free(written);
    var fbs = std.io.fixedBufferStream(written);
    const stream = fbs.reader();

    var bsonReader = reader(allocator, stream);
    var rawBson = try bsonReader.read();
    defer rawBson.deinit();
    const actual = try std.json.stringifyAlloc(
        allocator,
        rawBson.value,
        .{},
    );
    defer allocator.free(actual);

    const expected = try std.json.stringifyAlloc(
        allocator,
        doc,
        .{},
    );
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, actual);
}
