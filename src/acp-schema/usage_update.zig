//! A session's token occupancy and, optionally, what it has cost so far.
//!
//! Stable since ACP stabilized `usage_update` (2026-06-05); it was once
//! behind `-Dunstable_session_usage`.

const std = @import("std");
const log = std.log.scoped(.acp_schema_usage_update);
const mod = @import("module.zig");

/// What a session has cost so far.
pub const UsageCost = struct {
    const Self = @This();

    amount: f64,
    /// ISO 4217, e.g. "USD".
    currency: []const u8,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

/// The `usage_update` payload.
pub const UsageUpdate = struct {
    const Self = @This();

    /// Tokens currently in context.
    used: u64,
    /// The context window's size in tokens.
    size: u64,
    cost: ?UsageCost = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,

    /// Returns how much of the context window is in use.
    ///
    /// Parameters:
    /// - `self`: the update.
    ///
    /// Return: `used / size` in [0, 1] for a sane update; 0 when the window size is unknown (0).
    pub fn fraction(self: *const Self) f64 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (self.size == 0) return 0;
        return @as(f64, @floatFromInt(self.used)) / @as(f64, @floatFromInt(self.size));
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "usage reports the share of the window in use" {
    const src =
        \\{"used":50000,"size":200000,"cost":{"amount":0.06,"currency":"USD"}}
    ;
    const parsed = try std.json.parseFromSlice(UsageUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 0.25), parsed.value.fraction());
    try std.testing.expectEqualStrings("USD", parsed.value.cost.?.currency);
}
