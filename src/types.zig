//!
//! All bson types declare implementions of [Canonical Extended JSON formats](https://github.com/mongodb/specifications/blob/master/source/extended-json.md). When
//! using std.json, these implementation will go into effect
//!
const std = @import("std");

/// consists of 12 bytes
///
/// * A 4-byte timestamp, representing the ObjectId's creation, measured in seconds since the Unix epoch
/// * A 5-byte random value generated once per process. This random value is unique to the machine and process.
/// * A 3-byte incrementing counter, initialized to a random value.
/// https://www.mongodb.com/docs/manual/reference/bson-types/#objectid
pub const ObjectId = struct {
    bytes: [12]u8,

    pub fn fromBytes(bytes: [12]u8) @This() {
        return .{ .bytes = bytes };
    }

    pub fn fromHex(encoded: []const u8) !@This() {
        var bytes: [12]u8 = undefined;
        _ = try std.fmt.hexToBytes(&bytes, encoded);
        return fromBytes(bytes);
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.print(
            \\{{"$oid":"{s}"}}
        ,
            .{std.fmt.bytesToHex(self.bytes, .lower)},
        );
    }
};

test ObjectId {
    const allocator = std.testing.allocator;
    const json = try std.json.stringifyAlloc(
        allocator,
        try ObjectId.fromHex("507f1f77bcf86cd799439011"),
        .{},
    );
    defer allocator.free(json);
    try std.testing.expectEqualStrings(
        \\{"$oid":"507f1f77bcf86cd799439011"}
    , json);
}

pub const Datetime = struct {
    millis: i64,
    pub fn fromMillis(millis: i64) @This() {
        return .{ .millis = millis };
    }
    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.print(
            \\{{"$date":{{"$numberLong":"{d}"}}}}
        ,
            .{self.millis},
        );
    }
};

test Datetime {
    const allocator = std.testing.allocator;
    const json = try std.json.stringifyAlloc(
        allocator,
        Datetime.fromMillis(1716919531350804),
        .{},
    );
    defer allocator.free(json);
    try std.testing.expectEqualStrings(
        \\{"$date":{"$numberLong":"1716919531350804"}}
    , json);
}

pub const Regex = struct {
    pattern: []const u8,
    options: []const u8,
    pub fn init(pattern: []const u8, options: []const u8) @This() {
        // todo: validate rules
        return .{ .pattern = pattern, .options = options };
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();
        try out.objectField("$regularExpression");

        try out.beginObject();
        try out.objectField("pattern");
        try out.write(self.pattern);
        try out.objectField("options");
        try out.write(self.options);
        try out.endObject();

        try out.endObject();
    }
};

pub const Timestamp = struct {
    increment: u32,
    timestamp: u32,

    pub fn init(increment: u32, timestamp: u32) @This() {
        return .{ .increment = increment, .timestamp = timestamp };
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.print(
            \\{{"$timestamp":{{"t":{d},"i":{d}}}}}
        ,
            .{ self.timestamp, self.increment },
        );
    }
};

pub const MinKey = struct {
    pub fn jsonStringify(_: @This(), out: anytype) !void {
        try out.print(
            \\{{"$minKey":1}}
        , .{});
    }
};

test "MinKey.jsonStringify" {
    const allocator = std.testing.allocator;
    const json = try std.json.stringifyAlloc(
        allocator,
        MinKey{},
        .{},
    );
    defer allocator.free(json);
    try std.testing.expectEqualStrings(
        \\{"$minKey":1}
    , json);
}

pub const MaxKey = struct {
    pub fn jsonStringify(_: @This(), out: anytype) !void {
        try out.print(
            \\{{"$maxKey":1}}
        , .{});
    }
};

test "MaxKey.jsonStringify" {
    const allocator = std.testing.allocator;
    const json = try std.json.stringifyAlloc(
        allocator,
        MaxKey{},
        .{},
    );
    defer allocator.free(json);
    try std.testing.expectEqualStrings(
        \\{"$maxKey":1}
    , json);
}

pub const Document = struct {
    pub const Element = struct { k: []const u8, v: RawBson };
    elements: []const Element,

    pub fn init(elements: []const Element) @This() {
        return .{ .elements = elements };
    }

    pub fn dupe(self: @This(), allocator: std.mem.Allocator) !@This() {
        const duped = try allocator.dupe(Element, self.elements);
        defer allocator.free(self.elements);
        return init(duped);
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();

        for (self.elements) |elem| {
            try out.objectField(elem.k);
            try out.write(elem.v);
        }

        try out.endObject();
    }
};

pub const Int64 = struct {
    value: i64,
    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.print(
            \\{{"$numberLong":"{d}"}}
        , .{self.value});
    }
};

/// https://github.com/mongodb/specifications/blob/master/source/bson-decimal128/decimal128.md
pub const Decimal128 = struct {
    value: []const u8,
    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.print(
            \\{{"$numberDecimal":"{s}"}}
        , .{self.value});
    }
};

pub const Int32 = struct {
    value: i32,
    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.print(
            \\{{"$numberInt":"{d}"}}
        , .{self.value});
    }
};

pub const Double = struct {
    value: f64,
    pub fn init(value: f64) @This() {
        return .{ .value = value };
    }
    pub fn jsonStringify(self: @This(), out: anytype) !void {
        if (std.math.isNan(self.value)) {
            try out.print(
                \\{{"$numberDouble":"NaN"}}
            , .{});
        } else if (std.math.isPositiveInf(self.value)) {
            std.debug.print("{d} is inf\n", .{self.value});
            try out.print(
                \\{{"$numberDouble":"Infinity"}}
            , .{});
        } else if (std.math.isNegativeInf(self.value)) {
            std.debug.print("{d} is inf\n", .{self.value});
            try out.print(
                \\{{"$numberDouble":"-Infinity"}}
            , .{});
            // fixme: is there a better way to detect no decimal places?
        } else if (@round(self.value) == self.value) {
            try out.print(
                \\{{"$numberDouble":"{d:.1}"}}
            , .{self.value});
        } else {
            std.debug.print("{d} is a normal number\n", .{self.value});
            try out.print(
                \\{{"$numberDouble":"{d}"}}
            , .{self.value});
        }
    }
};

pub const JavaScript = struct {
    value: []const u8,
    pub fn init(value: []const u8) @This() {
        return .{ .value = value };
    }
    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();
        try out.objectField("$code");
        try out.write(self.value);
        try out.endObject();
    }
};

pub const JavaScriptWithScope = struct {
    value: []const u8,
    scope: Document,
    pub fn init(value: []const u8, scope: Document) @This() {
        return .{ .value = value, .scope = scope };
    }
    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();
        try out.objectField("$code");
        try out.write(self.value);
        try out.objectField("$scope");
        try out.write(self.scope);
        try out.endObject();
    }
};

pub const DBPointer = struct {
    ref: []const u8,
    id: ObjectId,
    pub fn init(ref: []const u8, id: ObjectId) @This() {
        return .{ .ref = ref, .id = id };
    }
    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();

        try out.objectField("$dbPointer");

        try out.beginObject();
        try out.objectField("$ref");
        try out.write(self.ref);
        try out.objectField("$id");
        try out.write(self.id);
        try out.endObject();

        try out.endObject();
    }
};

pub const Symbol = struct {
    value: []const u8,
    pub fn init(value: []const u8) @This() {
        return .{ .value = value };
    }
    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();
        try out.objectField("$symbol");
        try out.write(self.value);
        try out.endObject();
    }
};

pub const Binary = struct {
    value: []const u8,
    subtype: SubType,
    pub fn init(value: []const u8, subtype: SubType) @This() {
        return .{ .value = value, .subtype = subtype };
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();
        try out.objectField("$binary");

        try out.beginObject();
        try out.objectField("base64");

        // note: because we only know the len of value at runtime, we can't statically allocate
        // an array and because we're in a place we don't have an allocator, we create one on demand
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        const encoder = std.base64.standard.Encoder;
        var buf = try std.ArrayList(u8).initCapacity(allocator, encoder.calcSize(self.value.len));
        defer buf.deinit();
        try buf.resize(buf.capacity);
        const slice = try buf.toOwnedSlice();
        defer allocator.free(slice);

        try out.write(encoder.encode(slice, self.value));
        try out.objectField("subType");
        try out.write(self.subtype.hex());
        try out.endObject();

        try out.endObject();
    }
};

/// An enumeration of Bson types
pub const RawBson = union(enum) {
    double: Double,
    string: []const u8,
    document: Document,
    array: []const RawBson,
    boolean: bool,
    null: void,
    regex: Regex,
    dbpointer: DBPointer,
    javascript: JavaScript,
    javascript_with_scope: JavaScriptWithScope,
    int32: Int32,
    int64: Int64,
    decimal128: Decimal128,
    timestamp: Timestamp,
    binary: Binary,
    object_id: ObjectId,
    datetime: Datetime,
    symbol: Symbol,
    undefined: void,
    max_key: MaxKey,
    min_key: MinKey,

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        return try switch (self) {
            .double => |v| out.write(v),
            .string => |v| out.write(v),
            .document => |v| out.write(v),
            .array => |v| out.write(v),
            .binary => |v| out.write(v),
            .undefined => out.print("{{\"$undefined\":true}}", .{}),
            .object_id => |v| out.write(v),
            .boolean => |v| out.write(v),
            .datetime => |v| out.write(v),
            .null => out.write(null),
            .regex => |v| out.write(v),
            .javascript => |v| out.write(v),
            .javascript_with_scope => |v| out.write(v),
            .dbpointer => |v| out.write(v),
            .symbol => |v| out.write(v),
            .int32 => |v| out.write(v),
            .timestamp => |v| out.write(v),
            .int64 => |v| out.write(v),
            .decimal128 => |v| out.write(v),
            .min_key => |v| out.write(v),
            .max_key => |v| out.write(v),
        };
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        switch (self) {
            .document => |v| {
                // for (v.elements) |elem| {
                //     elem.v.deinit(allocator);
                // }
                allocator.free(v.elements);
            },
            else => {},
        }
    }
};

test "RawBson.jsonStringify" {
    const allocator = std.testing.allocator;
    const actual = try std.json.stringifyAlloc(allocator, RawBson{
        .min_key = MinKey{},
    }, .{});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(
        \\{"$minKey":1}
    , actual);
}

pub const Type = enum(i8) {
    double = 0x01,
    string = 0x02,
    document = 0x03,
    /// the document for an array is a normal BSON document with integer values for the keys, starting with 0 and continuing sequentially. For example, the array ['red', 'blue'] would be encoded as the document {'0': 'red', '1': 'blue'}. The keys must be in ascending numerical order.
    array = 0x04,
    binary = 0x05,
    /// deprecated
    undefined = 0x06,
    object_id = 0x07,
    boolean = 0x08,
    /// The int64 is UTC milliseconds since the Unix epoch
    datetime = 0x09,
    null = 0x0a,
    regex = 0x0b,
    /// deprecated
    dbpointer = 0x0c,
    javascript = 0x0d,
    /// deprecated
    symbol = 0x0e,
    /// deprecated
    javascript_with_scope = 0x0f,
    int32 = 0x10,
    ///  Special internal type used by MongoDB replication and sharding. First 4 bytes are an increment, second 4 are a timestamp.
    timestamp = 0x11,
    int64 = 0x12,
    decimal128 = 0x13,
    /// Special type which compares lower than all other possible BSON element values.
    min_key = 0xff - 256,
    /// Special type which compares higher than all other possible BSON element values.
    max_key = 0x7f,

    pub fn fromInt(int: i8) @This() {
        return @enumFromInt(int);
    }

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{s}", .{@tagName(self)});
    }
};

pub const SubType = enum(u8) {
    /// This is the most commonly used binary subtype and should be the 'default' for drivers and tools.
    binary = 0x00,
    function = 0x01,
    binary_old = 0x02,
    uuid_old = 0x03,
    uuid = 0x04,
    md5 = 0x05,
    encrypted = 0x06,
    /// Compact storage of BSON data. This data type uses delta and delta-of-delta compression and run-length-encoding for efficient element storage. Also has an encoding for sparse arrays containing missing values.
    compact_column = 0x07,
    sensitve = 0x08,
    // 128 - 255
    user_defined = 0x80,

    pub fn fromInt(int: u8) @This() {
        return @enumFromInt(int);
    }

    fn hex(self: @This()) [2]u8 {
        return std.fmt.bytesToHex([_]u8{@intFromEnum(self)}, .lower);
    }

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{s}", .{@tagName(self)});
    }
};
