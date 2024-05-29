/// A [bson](https://bsonspec.org/spec.html) encoding and decoding library
///
/// see also https://www.mongodb.com/resources/basics/json-and-bson
const std = @import("std");

pub const Reader = @import("reader.zig").Reader;

test "bson specs" {
    const testing = std.testing;
    const fs = std.fs;
    const hex = @import("hex.zig");

    const TestSuite = struct {
        /// for test description
        description: []const u8,
        /// hex value of type under test
        bson_type: []const u8,
        /// when validating types this will be the key used to assign the type to
        /// in valid.canonical_extjson
        test_key: ?[]const u8 = null,
        valid: ?[]struct {
            /// test case description
            description: []const u8,
            /// hex encoded bson bytes
            canonical_bson: []const u8,
            /// json representation of decoded bson for validation
            canonical_extjson: []const u8,
            /// relaxed version of the above
            relaxed_extjson: ?[]const u8 = null,
            degenerate_extjson: ?[]const u8 = null,
        } = null,
        decodeErrors: ?[]struct {
            description: []const u8,
            bson: []const u8,
        } = null,
        parseErrors: ?[]struct {
            description: []const u8,
            string: []const u8,
        } = null,
    };

    const allocator = testing.allocator;
    const tests = try fs.Dir.realpathAlloc(
        fs.cwd(),
        allocator,
        "specs/bson-corpus/tests",
    );
    defer allocator.free(tests);
    const specs = try fs.openDirAbsolute(
        tests,
        .{ .iterate = true },
    );
    var walker = try specs.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        // limit tests for now, remove this gate later
        if (!std.mem.endsWith(u8, entry.path, "string.json")) {
            continue;
        }
        const p = try fs.Dir.realpathAlloc(
            specs,
            allocator,
            entry.path,
        );
        defer allocator.free(p);
        var file = try fs.openFileAbsolute(p, .{});
        const buffer = try file.readToEndAlloc(
            allocator,
            std.math.maxInt(usize),
        );
        defer allocator.free(buffer);
        var parsed = try std.json.parseFromSlice(
            TestSuite,
            allocator,
            buffer,
            .{
                .ignore_unknown_fields = true,
            },
        );
        defer parsed.deinit();
        const suite = parsed.value;
        if (suite.valid) |examples| {
            for (examples[0..]) |valid| {
                if (std.mem.count(u8, valid.description, "Regular expression as value of $regex") > 0) {
                    // these tests do not conform to the test_key matches canonical_extjson convention
                    continue;
                }
                std.debug.print("\n{s}: {s}\n", .{ suite.description, valid.description });
                // each of these are essentially a mini document with test_key as a key and some test suite specific bson typed value
                const bson = try hex.decode(allocator, valid.canonical_bson);
                defer allocator.free(bson);

                std.debug.print("raw (bytes) {any}\n", .{bson});

                var stream = std.io.fixedBufferStream(bson);
                var reader = Reader(@TypeOf(stream).Reader).init(allocator, stream.reader());
                defer reader.deinit();

                if (suite.test_key) |_| {
                    const rawBson = try reader.read();

                    const actual = try std.json.stringifyAlloc(
                        allocator,
                        rawBson,
                        .{},
                    );
                    defer allocator.free(actual);

                    // make spacing consistency with zigs `minified` string option output
                    // parse and serialize valid.canonical_extjson to ensure consistent comparison
                    var parsedExpect = try std.json.parseFromSlice(
                        std.json.Value,
                        allocator,
                        valid.canonical_extjson,
                        .{},
                    );
                    defer parsedExpect.deinit();
                    const expect = try std.json.stringifyAlloc(
                        allocator,
                        parsedExpect.value,
                        .{},
                    );
                    defer allocator.free(expect);
                    try std.testing.expectEqualStrings(expect, actual);
                }
            }
        }
    }
}

fn jsonStringifyAny(allocator: std.mem.Allocator, key: []const u8, value: anytype) ![]u8 {
    var jsonStream = std.ArrayList(u8).init(allocator);
    defer jsonStream.deinit();
    var jsonWriter = std.json.writeStream(jsonStream.writer(), .{});
    defer jsonWriter.deinit();
    try jsonWriter.beginObject();
    try jsonWriter.objectField(key);
    try jsonWriter.write(value);
    try jsonWriter.endObject();
    return try jsonStream.toOwnedSlice();
}
