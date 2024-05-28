const std = @import("std");

pub fn decode(allocator: std.mem.Allocator, hexEncoded: []const u8) ![]u8 {
    var bytes = try std.ArrayList(u8).initCapacity(allocator, hexEncoded.len / 2);
    for (hexEncoded, 0..) |_, i| {
        if ((i % 2) == 0) {
            const byteValue = try std.fmt.parseInt(u8, hexEncoded[i..][0..2], 16);
            bytes.appendAssumeCapacity(byteValue);
        }
    }
    return try bytes.toOwnedSlice();
}
