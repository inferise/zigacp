//! One usage shape, whichever agent reported it.
//!
//! An inferise agent reports a turn's accounting in `_meta.inferise.usage`
//! (`acp.Inferise.TurnUsage`); any other ACP agent reports only `usage_update`.
//! Which one arrived is read off the frame, never off which agent sent it, and
//! the relay puts the result beside them in every prompt reply:
//!
//! ```
//! {"contextTokens":21383,"contextWindow":200000,"inputTokens":10,"outputTokens":45,"costUsd":0.017,
//!  "windows":[{"id":"five_hour","label":"5-hour","usedPercent":30,"resetsAt":1790475600,"windowMinutes":300}]}
//! ```
//!
//! A figure nobody reported is absent rather than zero, so a host can tell "no
//! quota to show" from "none left".

const std = @import("std");
const log = std.log.scoped(.acp_relay_usage_normalizer);
const acp = @import("module.zig");

/// What the session's last `usage_update` said, for an agent with no `_meta` of its own.
pub const UsageFallback = struct {
    used: u64 = 0,
    size: u64 = 0,
    cost_usd: ?f64 = null,
};

/// Builds the relay's usage shape.
pub const RelayUsageNormalizer = struct {
    const Self = @This();

    /// Normalizes one reply's accounting.
    ///
    /// Parameters:
    /// - `arena`: owns the returned value.
    /// - `meta`: the reply's whole `_meta`, or null.
    /// - `fallback`: the session's last `usage_update`.
    ///
    /// Return: the usage object; propagates allocation failure.
    pub fn normalize(arena: std.mem.Allocator, meta: ?std.json.Value, fallback: UsageFallback) acp.AcpError!std.json.Value {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var usage: std.json.ObjectMap = .empty;
        var windows = std.json.Array.init(arena);

        // What the agent said in `_meta.inferise.usage`, when it said anything:
        // decided by the frame, so an agent that sends none falls through.
        const reported: ?acp.Inferise.TurnUsage = if (meta) |value| reportedOf(arena, value) else null;
        if (reported) |turn| {
            if (turn.context_tokens) |n| if (n > 0) try usage.put(arena, "contextTokens", .{ .integer = @intCast(n) });
            if (turn.context_window) |n| if (n > 0) try usage.put(arena, "contextWindow", .{ .integer = @intCast(n) });
            if (turn.input_tokens) |n| if (n > 0) try usage.put(arena, "inputTokens", .{ .integer = @intCast(n) });
            if (turn.output_tokens) |n| if (n > 0) try usage.put(arena, "outputTokens", .{ .integer = @intCast(n) });
            if (turn.cost_usd) |cost| if (cost > 0) try usage.put(arena, "costUsd", .{ .float = cost });
            for (turn.windows) |window| try windows.append(try entry(arena, window));
        }

        // An agent that sent no usage, or one that has not learned its window
        // yet: occupancy comes from the last `usage_update` instead.
        if (usage.get("contextWindow") == null and fallback.size > 0) {
            try usage.put(arena, "contextTokens", .{ .integer = @intCast(fallback.used) });
            try usage.put(arena, "contextWindow", .{ .integer = @intCast(fallback.size) });
        }
        if (usage.get("costUsd") == null) if (fallback.cost_usd) |cost| try usage.put(arena, "costUsd", .{ .float = cost });

        try usage.put(arena, "windows", .{ .array = windows });
        return .{ .object = usage };
    }

    /// Names a window by its length, as a person reads it.
    ///
    /// Parameters:
    /// - `arena`: owns the returned text.
    /// - `minutes`: the window's length.
    ///
    /// Return: e.g. `5-hour`, `7-day`, `30-day`; propagates allocation failure.
    pub fn label(arena: std.mem.Allocator, minutes: u64) acp.AcpError![]const u8 {
        if (minutes == 0) return "window";
        if (minutes % (24 * 60) == 0) return arena.print("{d}-day", .{minutes / (24 * 60)});
        if (minutes % 60 == 0) return arena.print("{d}-hour", .{minutes / 60});
        return arena.print("{d}-minute", .{minutes});
    }

    /// Reads `_meta.inferise.usage` off a reply's `_meta`.
    ///
    /// Parameters:
    /// - `arena`: owns what is parsed.
    /// - `meta`: the reply's whole `_meta`.
    ///
    /// Return: the usage, or null when none was sent or it did not fit this build's type.
    fn reportedOf(arena: std.mem.Allocator, meta: std.json.Value) ?acp.Inferise.TurnUsage {
        const turn = acp.Inferise.readTurn(arena, .{ .value = meta }) catch |err| {
            log.warn("_meta.inferise did not fit this build's type [{t}]", .{err});
            return null;
        };
        return turn.usage;
    }

    /// Builds one window entry.
    ///
    /// Parameters:
    /// - `arena`: owns the entry.
    /// - `window`: the window.
    ///
    /// Return: the entry; propagates allocation failure.
    fn entry(arena: std.mem.Allocator, window: acp.Inferise.UsageWindow) !std.json.Value {
        var fields: std.json.ObjectMap = .empty;
        const minutes = window.window_minutes orelse 0;
        try fields.put(arena, "id", .{ .string = window.id });
        try fields.put(arena, "label", .{ .string = window.label orelse try label(arena, minutes) });
        try fields.put(arena, "usedPercent", .{ .float = window.used_percent });
        try fields.put(arena, "resetsAt", if (window.resets_at) |at| .{ .integer = @intCast(at) } else .null);
        if (minutes > 0) try fields.put(arena, "windowMinutes", .{ .integer = @intCast(minutes) });
        return .{ .object = fields };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RelayUsageNormalizer);
}

/// Normalizes `_meta` text for a test and returns the usage object's JSON.
///
/// Parameters:
/// - `arena`: owns everything.
/// - `meta`: the reply's whole `_meta` as JSON text, or null.
/// - `fallback`: the last `usage_update`.
///
/// Return: the normalized JSON text.
fn normalizeText(arena: std.mem.Allocator, meta: ?[]const u8, fallback: UsageFallback) ![]const u8 {
    const value: ?std.json.Value = if (meta) |text| try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) else null;
    return std.json.Stringify.valueAlloc(arena, try RelayUsageNormalizer.normalize(arena, value, fallback), .{});
}

test "an agent's windows keep their ids and gain a label from their length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try normalizeText(arena.allocator(),
        \\{"inferise":{"usage":{"inputTokens":10,"outputTokens":45,"costUsd":0.0176,"contextTokens":21383,"contextWindow":200000,"windows":[{"id":"five_hour","usedPercent":30,"resetsAt":1790475600,"windowMinutes":300},{"id":"seven_day","usedPercent":30,"resetsAt":1790784000,"windowMinutes":10080}]}}}
    , .{});
    try std.testing.expect(std.mem.find(u8, out, "\"contextTokens\":21383,\"contextWindow\":200000") != null);
    try std.testing.expect(std.mem.find(u8, out, "{\"id\":\"five_hour\",\"label\":\"5-hour\",\"usedPercent\":30,\"resetsAt\":1790475600,\"windowMinutes\":300}") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"label\":\"7-day\"") != null);
}

test "an agent's occupancy and cost in USD pass through as reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const meta = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"inferise":{"usage":{"wallMs":10,"contextTokens":21300,"contextWindow":500000,"costUsd":0.034514}}}
    , .{});
    const usage = try RelayUsageNormalizer.normalize(arena, meta, .{});
    try std.testing.expectEqual(@as(i64, 21300), usage.object.get("contextTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 500000), usage.object.get("contextWindow").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 0.034514), usage.object.get("costUsd").?.float, 1e-9);
}

test "Codex's percentage keeps its own length, and a missing reset is null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try normalizeText(arena.allocator(),
        \\{"inferise":{"usage":{"inputTokens":14406,"contextTokens":14406,"contextWindow":258400,"windows":[{"id":"primary","usedPercent":18,"resetsAt":1791211724,"windowMinutes":43200},{"id":"secondary","usedPercent":40,"windowMinutes":300}]}}}
    , .{});
    try std.testing.expect(std.mem.find(u8, out, "\"label\":\"30-day\",\"usedPercent\":18") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"id\":\"secondary\",\"label\":\"5-hour\",\"usedPercent\":40,\"resetsAt\":null") != null);
}

test "a native agent's occupancy and cost come from its last usage_update" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try normalizeText(arena.allocator(), null, .{ .used = 900, .size = 1000, .cost_usd = 0.5 });
    try std.testing.expectEqualStrings("{\"contextTokens\":900,\"contextWindow\":1000,\"costUsd\":0.5,\"windows\":[]}", out);
}

test "nothing reported means nothing claimed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("{\"windows\":[]}", try normalizeText(arena.allocator(), null, .{}));
}
