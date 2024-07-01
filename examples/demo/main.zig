/// a round trip example
const std = @import("std");
const bson = @import("bson");
const RawBson = bson.types.RawBson;
const Document = bson.types.Document;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const doc = RawBson.document(
        &.{
            .{ "hello", RawBson.string("world") },
        },
    );
    const bytes = try serialize(allocator, doc);
    defer allocator.free(bytes);
    std.debug.print("{s}", .{std.fmt.fmtSliceHexLower(bytes)});

    // read it back
    var rawBson = try deserialize(allocator, bytes);
    defer rawBson.deinit();
    switch (rawBson.value) {
        .document => |v| {
            if (v.get("hello")) |value| {
                std.debug.print("deserialized hello '{s}'!", .{value});
            }
        },
        else => unreachable,
    }
}

fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !bson.Owned(RawBson) {
    var fbs = std.io.fixedBufferStream(bytes);
    var reader = bson.reader(allocator, fbs.reader());
    return try reader.read();
}

fn serialize(allocator: std.mem.Allocator, doc: RawBson) ![]const u8 {
    // write a document to a byte buffer
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    var writer = bson.writer(
        allocator,
        buf.writer(),
    );
    defer writer.deinit();
    try writer.write(doc);

    return try buf.toOwnedSlice();
}
