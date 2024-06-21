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

    // write a document to a byte buffer
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    var writer = bson.writer(
        allocator,
        buf.writer(),
    );
    defer writer.deinit();
    try writer.write(doc);

    const bytes = try buf.toOwnedSlice();
    defer allocator.free(bytes);
    std.debug.print(
        "{s}",
        .{
            std.fmt.fmtSliceHexLower(bytes),
        },
    );

    // read it back
    var fbs = std.io.fixedBufferStream(bytes);
    var reader = bson.reader(allocator, fbs.reader());
    defer reader.deinit();
    switch (try reader.read()) {
        .document => |v| {
            if (v.get("hello")) |value| {
                std.debug.print(
                    "deserialized hello '{s}'!",
                    .{value},
                );
            }
        },
        else => unreachable,
    }
}
