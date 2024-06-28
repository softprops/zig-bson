const std = @import("std");
const bson = @import("root.zig");

const benchmark = @import("benchmark");

// bench hello world comparison
test "bench read" {
    try benchmark.main(.{}, struct {
        pub fn jsonRead(b: *benchmark.B) !void {
            // Setup is not timed
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();

            while (b.step()) { // Number of iterations is automatically adjusted for accurate timing
                defer _ = arena.reset(.retain_capacity);

                const parsed = try std.json.parseFromSlice(struct { foo: []const u8 }, arena.allocator(),
                    \\{"foo":"bar"}
                , .{});
                defer parsed.deinit();

                // `use` is a helper that calls `std.mem.doNotOptimizeAway`
                b.use(parsed.value);
            }
        }

        pub fn bsonRead(b: *benchmark.B) !void {
            // Setup is not timed
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var fbs = std.io.fixedBufferStream(&[_]u8{ 18, 0, 0, 0, 2, 102, 111, 111, 0, 4, 0, 0, 0, 98, 97, 114, 0, 0 });
            while (b.step()) {
                defer _ = arena.reset(.retain_capacity);
                defer fbs.reset();

                var rdr = bson.reader(arena.allocator(), fbs.reader());
                defer rdr.deinit();
                const value = try rdr.read();

                // `use` is a helper that calls `std.mem.doNotOptimizeAway`
                b.use(value);
            }
        }
    })();
}

test "bench write" {
    try benchmark.main(.{}, struct {
        // Benchmarks are just public functions
        pub fn jsonWrite(b: *benchmark.B) !void {
            // Setup is not timed
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            while (b.step()) { // Number of iterations is automatically adjusted for accurate timing
                defer _ = arena.reset(.retain_capacity);

                var buf = std.ArrayList(u8).init(arena.allocator());
                try std.json.stringify(struct { foo: []const u8 }{ .foo = "bar" }, .{}, buf.writer());

                // `use` is a helper that calls `std.mem.doNotOptimizeAway`
                b.use(buf.items);
            }
        }

        pub fn bsonWrite(b: *benchmark.B) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            while (b.step()) {
                defer _ = arena.reset(.retain_capacity);

                var buf = std.ArrayList(u8).init(arena.allocator());
                var wtr = bson.writer(arena.allocator(), buf.writer());
                defer wtr.deinit();
                try wtr.write(bson.types.RawBson.document(
                    &.{
                        .{ "foo", bson.types.RawBson.string("bar") },
                    },
                ));

                b.use(buf.items);
            }
        }
    })();
}
