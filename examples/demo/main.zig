/// a round trip example
const std = @import("std");
const bson = @import("bson");
const RawBson = bson.types.RawBson;
const Document = bson.types.Document;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const doc = try RawBson.createDocument(
        &.{
            .{ "hello", RawBson.string("world") },
        },
        allocator
    );

    // RawBson.createDocument allocates memory to store the name and Bson value
    // so it needs to be freed
    defer doc.deinit(allocator);

    // write a document to a byte buffer
    const bytes = try serialize(allocator, doc);
    defer allocator.free(bytes);
    std.debug.print("{s}", .{std.fmt.fmtSliceHexLower(bytes)});

    // read it back
    const Example = struct {
        hello: []const u8,
    };
    var read = try deserialize(allocator, bytes, Example);
    defer read.deinit();
    std.debug.print("deserialized hello '{s}'!", .{read.value.hello});
}

fn deserialize(allocator: std.mem.Allocator, bytes: []const u8, comptime Into: type) !bson.Owned(Into) {
    var fbs = std.io.fixedBufferStream(bytes);
    var reader = bson.reader(allocator, fbs.reader());
    return try reader.readInto(Into);
}

fn serialize(allocator: std.mem.Allocator, doc: RawBson) ![]const u8 {
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
