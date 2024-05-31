/// A [BSON](https://bsonspec.org/spec.html) encoding and decoding library
///
/// see also https://www.mongodb.com/resources/basics/json-and-bson
const std = @import("std");

pub const Reader = @import("reader.zig").Reader;

test "bson specs" {
    const testing = std.testing;
    const fs = std.fs;

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
        if (!std.mem.endsWith(u8, entry.path, "array.json")) {
            continue;
        }
        var pathBuf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        var file = try fs.openFileAbsolute(
            try fs.Dir.realpath(specs, entry.path, &pathBuf),
            .{},
        );
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
        // todo: test suite.decodeError cases

        // test the valid cases
        if (suite.valid) |examples| {
            for (examples[0..]) |valid| {
                std.debug.print("\n{s}: {s}\n", .{ suite.description, valid.description });
                // each of these are essentially a mini document with test_key as a key and some test suite specific bson typed value
                var bsonBuf: [std.mem.page_size]u8 = undefined;
                const bson = try std.fmt.hexToBytes(&bsonBuf, valid.canonical_bson);

                std.debug.print("raw (bytes) {any}\n", .{bson});

                var stream = std.io.fixedBufferStream(bson);
                var reader = Reader(@TypeOf(stream).Reader).init(
                    allocator,
                    stream.reader(),
                );
                defer reader.deinit();

                if (suite.test_key) |_| {
                    const rawBson = try reader.read();
                    // free here?
                    //defer rawBson.deinit(allocator);

                    const actual = try std.json.stringifyAlloc(
                        allocator,
                        rawBson,
                        .{},
                    );
                    defer allocator.free(actual);

                    const expect = try normalizeJson(
                        allocator,
                        valid.canonical_extjson,
                    );
                    defer allocator.free(expect);
                    std.testing.expectEqualStrings(expect, actual) catch |err| {
                        std.debug.print(
                            "\nfailed on test {s}: {s}\n",
                            .{ suite.description, valid.description },
                        );
                        return err;
                    };
                }
            }
        }
    }
}

// make json spacing consistent with zigs `minified` string option output
// parse and serialize valid.canonical_extjson to ensure consistent comparison
fn normalizeJson(allocator: std.mem.Allocator, provided: []const u8) ![]u8 {
    // make spacing consistent with zigs `minified` string option output
    // parse and serialize valid.canonical_extjson to ensure consistent comparison
    var parsedExpect = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        provided,
        .{},
    );
    defer parsedExpect.deinit();
    return try std.json.stringifyAlloc(
        allocator,
        parsedExpect.value,
        .{},
    );
}
