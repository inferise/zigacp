//! Shared JSON codec helpers for schema types.
//!
//! Kept intentionally small: helpers are added as later phases discover real
//! needs, not speculatively.

const std = @import("std");

/// A wrapper around `std.json.Value` that preserves an arbitrary JSON payload
/// without forcing the schema to commit to a concrete shape. Used for
/// extension envelopes and forward-compat `unknown` variants.
pub const RawValue = struct {
    value: std.json.Value,

    pub fn jsonStringify(self: RawValue, jw: anytype) !void {
        try jw.write(self.value);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !RawValue {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return .{ .value = v };
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !RawValue {
        _ = options;
        // Copied, not borrowed: the caller's allocator owns everything parsed,
        // and the source is often a frame freed as soon as the parse returns.
        return .{ .value = try cloneValue(allocator, source) };
    }
};

/// Copies a JSON value, every string and container included, into `allocator`.
///
/// Parameters:
/// - `allocator`: owns the copy.
/// - `source`: the value; only read.
///
/// Return: the copy; propagates allocation failure.
pub fn cloneValue(allocator: std.mem.Allocator, source: std.json.Value) error{OutOfMemory}!std.json.Value {
    return switch (source) {
        .null, .bool, .integer, .float => source,
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |array| blk: {
            var copy = try std.json.Array.initCapacity(allocator, array.items.len);
            for (array.items) |item| copy.appendAssumeCapacity(try cloneValue(allocator, item));
            break :blk .{ .array = copy };
        },
        .object => |object| blk: {
            var copy: std.json.ObjectMap = .empty;
            try copy.ensureTotalCapacity(allocator, object.count());
            var it = object.iterator();
            while (it.next()) |entry| {
                copy.putAssumeCapacity(try allocator.dupe(u8, entry.key_ptr.*), try cloneValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = copy };
        },
    };
}

test "RawValue round-trips arbitrary JSON" {
    const src = "{\"a\":1,\"b\":[true,null,\"x\"]}";
    const parsed = try std.json.parseFromSlice(RawValue, std.testing.allocator, src, .{});
    defer parsed.deinit();
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(out);
    const a = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, src, .{});
    defer a.deinit();
    const b = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer b.deinit();
    try std.testing.expectEqual(a.value.object.count(), b.value.object.count());
}

test "a RawValue parsed from a value outlives the value it came from" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"k\":[\"v\",1]}", .{});
    const raw = try std.json.parseFromValueLeaky(RawValue, arena_state.allocator(), source.value, .{});
    source.deinit();
    try std.testing.expectEqualStrings("v", raw.value.object.get("k").?.array.items[0].string);
}
