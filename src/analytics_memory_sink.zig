//! An `AnalyticsSink` that keeps every record in memory.
//!
//! For the tests, and for a screen that wants live figures without reading a
//! file back. Records arrive on `Analytics`' task and are read on another, so
//! every access goes through one mutex.

const std = @import("std");
const log = std.log.scoped(.acp_analytics_memory_sink);
const acp = @import("module.zig");

/// Keeps each record's event name and line, in arrival order.
pub const AnalyticsMemorySink = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    /// Guards both lists.
    mutex: std.Io.Mutex = .init,
    /// Each record's event name, parallel to `lines`. Owned.
    events: std.ArrayList([]u8) = .empty,
    /// Each record's JSON line. Owned.
    lines: std.ArrayList([]u8) = .empty,

    const vtable = acp.Analytics.Sink.VTable{ .record = record };

    /// Creates an empty sink.
    ///
    /// Parameters:
    /// - `allocator`: owns every kept record.
    /// - `io`: IO capability, for the mutex.
    ///
    /// Return: the sink, caller stores it at a stable address and calls `deinit`; never fails today.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return Self{ .allocator = allocator, .io = io };
    }

    /// Releases every kept record.
    ///
    /// Parameters:
    /// - `self`: the sink.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        for (self.events.items) |text| self.allocator.free(text);
        for (self.lines.items) |text| self.allocator.free(text);
        self.events.deinit(self.allocator);
        self.lines.deinit(self.allocator);
    }

    /// Returns this sink for `Analytics`.
    ///
    /// Parameters:
    /// - `self`: the sink; must not move while in use.
    ///
    /// Return: the sink, borrowing `self`.
    pub fn sink(self: *Self) acp.Analytics.Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Counts the records of one event.
    ///
    /// Parameters:
    /// - `self`: the sink.
    /// - `event`: the event's name, such as `turn.ended`.
    ///
    /// Return: how many have arrived.
    pub fn count(self: *Self, event: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var found: usize = 0;
        for (self.events.items) |name| {
            if (std.mem.eql(u8, name, event)) found += 1;
        }
        return found;
    }

    /// Keeps one record.
    ///
    /// Parameters:
    /// - `ctx`: the sink.
    /// - `subagent`: the agent it belongs to; unused, as the line names it.
    /// - `event`: the event's name; copied.
    /// - `line`: the record; copied.
    ///
    /// Return: nothing; a record that cannot be copied is logged and lost.
    fn record(ctx: *anyopaque, subagent: acp.Analytics.Subagent, event: []const u8, line: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = subagent;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.keep(event, line) catch |err| log.warn("record not kept [{t}]", .{err});
    }

    /// Copies one record onto both lists, or onto neither.
    ///
    /// Parameters:
    /// - `self`: the sink; the caller holds the mutex.
    /// - `event`: the event's name.
    /// - `line`: the record.
    ///
    /// Return: nothing; propagates allocation failure, keeping nothing.
    fn keep(self: *Self, event: []const u8, line: []const u8) !void {
        try self.events.ensureUnusedCapacity(self.allocator, 1);
        try self.lines.ensureUnusedCapacity(self.allocator, 1);
        const event_copy = try self.allocator.dupe(u8, event);
        errdefer self.allocator.free(event_copy);
        const line_copy = try self.allocator.dupe(u8, line);
        self.events.appendAssumeCapacity(event_copy);
        self.lines.appendAssumeCapacity(line_copy);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(AnalyticsMemorySink);
}

test "records are kept in order and counted by event" {
    var memory = try AnalyticsMemorySink.init(std.testing.allocator, std.testing.io);
    defer memory.deinit();
    const sink = memory.sink();
    const subagent = acp.Analytics.Subagent{ .id = "claude-1", .agent = "claude", .account = null, .parent = null, .started = .{ .nanoseconds = 0 } };

    sink.record(subagent, "turn.started", "{\"event\":\"turn.started\"}");
    sink.record(subagent, "turn.ended", "{\"event\":\"turn.ended\"}");
    sink.record(subagent, "turn.started", "{\"event\":\"turn.started\"}");

    try std.testing.expectEqual(@as(usize, 2), memory.count("turn.started"));
    try std.testing.expectEqual(@as(usize, 1), memory.count("turn.ended"));
    try std.testing.expectEqualStrings("{\"event\":\"turn.ended\"}", memory.lines.items[1]);
}
