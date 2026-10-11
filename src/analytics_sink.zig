//! Where analytics records go.
//!
//! `Analytics` renders every event as one JSON line and hands it to each sink,
//! with the subagent it belongs to and the event's name, so a sink can file it
//! without parsing it back. Sinks are called from `Analytics`' own task, one
//! record at a time; a sink must not fail — losing a record is its own business
//! to log — because no event is worth stopping the others for.

const std = @import("std");
const log = std.log.scoped(.acp_analytics_sink);

/// Who an agent is, as analytics name it: what its owner and the agent itself said, never a harness's name.
pub const AgentIdentity = struct {
    /// Unique within the run, such as `claude-1`.
    id: []const u8,
    /// The agent's label, such as `claude`.
    label: []const u8,
    /// The agent's version (`agentInfo.version`), when its owner knows it.
    version: ?[]const u8 = null,
};

/// The agent a record belongs to, as a sink sees it. Every slice is borrowed for the call.
pub const AnalyticsSubagent = struct {
    /// Unique within the run, such as `claude-1`.
    id: []const u8,
    /// The agent's label, such as `claude`.
    agent: []const u8,
    /// The agent's version, when known.
    version: ?[]const u8 = null,
    /// The account's name, or null for the agent's own home.
    account: ?[]const u8,
    /// The subagent that spawned this one, or null for one the user started.
    parent: ?[]const u8,
    /// When `Analytics` was told it started.
    started: std.Io.Timestamp,
};

/// A destination for analytics records, as a vtable so any store can be one.
pub const AnalyticsSink = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Takes one record: its subagent, its event name (`turn.ended`) and the whole JSON line, without a newline.
        record: *const fn (ctx: *anyopaque, subagent: AnalyticsSubagent, event: []const u8, line: []const u8) void,
    };

    /// Hands one record to the sink.
    ///
    /// Parameters:
    /// - `self`: the sink.
    /// - `subagent`: the agent the record belongs to; borrowed for the call.
    /// - `event`: the event's name; borrowed for the call.
    /// - `line`: the record as one JSON object; borrowed for the call.
    ///
    /// Return: nothing.
    pub fn record(self: Self, subagent: AnalyticsSubagent, event: []const u8, line: []const u8) void {
        self.vtable.record(self.ptr, subagent, event, line);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(AnalyticsSink);
    // The logger ZIGSTYLE asks every file for; this file has nothing to log.
    _ = log;
}

test "a sink is called through its vtable with the record as given" {
    const Last = struct {
        const Self = @This();

        event: []const u8 = "",
        id: []const u8 = "",

        fn record(ctx: *anyopaque, subagent: AnalyticsSubagent, event: []const u8, line: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.event = event;
            self.id = subagent.id;
            _ = line;
        }

        const vtable = AnalyticsSink.VTable{ .record = record };
    };

    var last = Last{};
    const sink = AnalyticsSink{ .ptr = &last, .vtable = &Last.vtable };
    sink.record(.{ .id = "claude-1", .agent = "claude", .account = null, .parent = null, .started = .{ .nanoseconds = 0 } }, "turn.ended", "{}");
    try std.testing.expectEqualStrings("turn.ended", last.event);
    try std.testing.expectEqualStrings("claude-1", last.id);
}
