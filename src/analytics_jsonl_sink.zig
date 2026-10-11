//! An `AnalyticsSink` that writes one JSONL file per subagent.
//!
//! A run is a directory: `<subagent id>.jsonl` for each agent, one record per
//! line, and `run.json` naming every subagent's agent, account and parent with
//! when it started and ended — rewritten whenever one starts or ends, so it is
//! current even for a run that is cut short.
//!
//! ```
//! <analytics dir>/20261003-142233-1a2b/run.json
//! <analytics dir>/20261003-142233-1a2b/claude-1.jsonl
//! ```
//!
//! Disk access goes through `zigstorage`. A write that fails is logged and the
//! record lost; it never reaches the agent it describes.

const std = @import("std");
const log = std.log.scoped(.acp_analytics_jsonl_sink);
const acp = @import("module.zig");
const zigstorage = @import("zigstorage");

/// One subagent as `run.json` lists it. Owns its strings.
const RosterEntry = struct {
    const Self = @This();

    id: []u8,
    agent: []u8,
    version: ?[]u8 = null,
    account: ?[]u8 = null,
    parent: ?[]u8 = null,
    started_ms: i64,
    ended_ms: ?i64 = null,
    /// Whether its file has been created this run, so later lines append.
    created: bool = false,

    /// Releases every owned string.
    ///
    /// Parameters:
    /// - `self`: the entry.
    /// - `allocator`: the one that allocated it.
    ///
    /// Return: nothing.
    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.agent);
        if (self.version) |text| allocator.free(text);
        if (self.account) |text| allocator.free(text);
        if (self.parent) |text| allocator.free(text);
    }
};

/// Writes each subagent's records to its own file in a run directory.
pub const AnalyticsJsonlSink = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    /// The run's directory, absolute, without a trailing slash. Owned.
    dir: []u8,
    /// The run's id, written into `run.json`. Owned.
    run_id: []u8,
    /// Every subagent seen, in order.
    roster: std.ArrayList(RosterEntry) = .empty,

    const vtable = acp.Analytics.Sink.VTable{ .record = record };

    /// The file naming every subagent of the run.
    pub const roster_file = "run.json";

    /// Creates a sink for one run; nothing is written until the first record.
    ///
    /// Parameters:
    /// - `allocator`: owns the paths and the roster.
    /// - `io`: IO capability for the storage nodes.
    /// - `environ`: the process environment, which `zigstorage` resolves against.
    /// - `base`: the directory runs go under, absolute; copied.
    /// - `run_id`: the run's id, which names its directory; copied.
    ///
    /// Return: the sink, caller stores it at a stable address and calls `deinit`; allocation failure propagates.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, base: []const u8, run_id: []const u8) acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const dir = try allocator.print("{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), run_id });
        errdefer allocator.free(dir);
        return Self{ .allocator = allocator, .io = io, .environ = environ, .dir = dir, .run_id = try allocator.dupe(u8, run_id) };
    }

    /// Releases the roster and paths.
    ///
    /// Parameters:
    /// - `self`: the sink.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        for (self.roster.items) |*entry| entry.deinit(self.allocator);
        self.roster.deinit(self.allocator);
        self.allocator.free(self.dir);
        self.allocator.free(self.run_id);
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

    /// Files one record: the roster first when a subagent starts or ends, then its line.
    ///
    /// Parameters:
    /// - `ctx`: the sink.
    /// - `subagent`: the agent it belongs to.
    /// - `event`: the event's name.
    /// - `line`: the record.
    ///
    /// Return: nothing; a failed write is logged and the record lost.
    fn record(ctx: *anyopaque, subagent: acp.Analytics.Subagent, event: []const u8, line: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const entry = self.entryFor(subagent) catch |err| {
            log.warn("{s}: not on the roster [{t}]", .{ subagent.id, err });
            return;
        };
        if (std.mem.eql(u8, event, "subagent.exited")) entry.ended_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        if (std.mem.eql(u8, event, "subagent.spawned") or std.mem.eql(u8, event, "subagent.exited")) {
            self.writeRoster() catch |err| log.warn("{s} not written [{t}]", .{ roster_file, err });
        }
        self.append(entry, line) catch |err| log.warn("{s}: record not written [{t}]", .{ subagent.id, err });
    }

    /// Returns a subagent's roster entry, adding it the first time it is seen.
    ///
    /// Parameters:
    /// - `self`: the sink.
    /// - `subagent`: the agent.
    ///
    /// Return: the entry, owned by the sink; propagates allocation failure.
    fn entryFor(self: *Self, subagent: acp.Analytics.Subagent) !*RosterEntry {
        for (self.roster.items) |*entry| {
            if (std.mem.eql(u8, entry.id, subagent.id)) return entry;
        }
        const id = try self.allocator.dupe(u8, subagent.id);
        errdefer self.allocator.free(id);
        const agent = try self.allocator.dupe(u8, subagent.agent);
        errdefer self.allocator.free(agent);
        var entry = RosterEntry{ .id = id, .agent = agent, .started_ms = subagent.started.toMilliseconds() };
        errdefer if (entry.version) |text| self.allocator.free(text);
        if (subagent.version) |text| entry.version = try self.allocator.dupe(u8, text);
        errdefer if (entry.account) |text| self.allocator.free(text);
        if (subagent.account) |text| entry.account = try self.allocator.dupe(u8, text);
        errdefer if (entry.parent) |text| self.allocator.free(text);
        if (subagent.parent) |text| entry.parent = try self.allocator.dupe(u8, text);
        try self.roster.append(self.allocator, entry);
        return &self.roster.items[self.roster.items.len - 1];
    }

    /// Appends one line to a subagent's file, creating it on its first line.
    ///
    /// Parameters:
    /// - `self`: the sink.
    /// - `entry`: the subagent's roster entry.
    /// - `line`: the record, without its newline.
    ///
    /// Return: nothing; propagates storage and allocation failures.
    fn append(self: *Self, entry: *RosterEntry, line: []const u8) !void {
        const url = try self.allocator.print("file://{s}/{s}.jsonl", .{ self.dir, entry.id });
        defer self.allocator.free(url);
        const with_newline = try self.allocator.print("{s}\n", .{line});
        defer self.allocator.free(with_newline);

        var node = try zigstorage.Node.init(self.allocator, self.io, self.environ, url);
        defer node.deinit();
        // `append` extends an asset that exists; the first line has to create it.
        if (!entry.created and !(try node.exists())) {
            try node.open();
            try node.append(with_newline);
            try node.save();
        } else {
            try node.append(with_newline);
        }
        entry.created = true;
    }

    /// Rewrites `run.json` from the roster.
    ///
    /// Parameters:
    /// - `self`: the sink.
    ///
    /// Return: nothing; propagates storage and allocation failures.
    fn writeRoster(self: *Self) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false } };
        try json.beginObject();
        try json.objectField("run");
        try json.write(self.run_id);
        try json.objectField("subagents");
        try json.beginArray();
        for (self.roster.items) |entry| {
            try json.write(.{
                .id = entry.id,
                .agent = entry.agent,
                .agentVersion = entry.version,
                .account = entry.account,
                .parent = entry.parent,
                .startedMs = entry.started_ms,
                .endedMs = entry.ended_ms,
            });
        }
        try json.endArray();
        try json.endObject();

        const url = try self.allocator.print("file://{s}/{s}", .{ self.dir, roster_file });
        defer self.allocator.free(url);
        var node = try zigstorage.Node.init(self.allocator, self.io, self.environ, url);
        defer node.deinit();
        try node.open();
        try node.append(out.written());
        try node.save();
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(AnalyticsJsonlSink);
}

test "each subagent's records land in its own file, and run.json names them all" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // SAFETY: filled by `io.random` before any byte of it is read.
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const run_id = try allocator.print("zigacp-test-{s}", .{std.fmt.bytesToHex(raw, .lower)});
    defer allocator.free(run_id);

    var jsonl = try AnalyticsJsonlSink.init(allocator, io, std.testing.environ, "/tmp/", run_id);
    defer jsonl.deinit();
    const sink = jsonl.sink();
    const claude = acp.Analytics.Subagent{ .id = "claude-1", .agent = "claude", .account = "work", .parent = null, .started = .{ .nanoseconds = 5 * std.time.ns_per_ms } };
    const codex = acp.Analytics.Subagent{ .id = "codex-1", .agent = "codex", .account = null, .parent = "claude-1", .started = .{ .nanoseconds = 6 * std.time.ns_per_ms } };

    sink.record(claude, "subagent.spawned", "{\"event\":\"subagent.spawned\"}");
    sink.record(codex, "subagent.spawned", "{\"event\":\"subagent.spawned\"}");
    sink.record(claude, "turn.ended", "{\"event\":\"turn.ended\"}");
    sink.record(claude, "subagent.exited", "{\"event\":\"subagent.exited\"}");

    // Everything the test wrote goes, the directory included.
    const dir_url = try allocator.print("file:///tmp/{s}/", .{run_id});
    defer allocator.free(dir_url);
    var dir_node = try zigstorage.Node.init(allocator, io, std.testing.environ, dir_url);
    defer dir_node.deinit();
    defer dir_node.removeTree() catch {};

    const claude_url = try allocator.print("file:///tmp/{s}/claude-1.jsonl", .{run_id});
    defer allocator.free(claude_url);
    var claude_node = try zigstorage.Node.init(allocator, io, std.testing.environ, claude_url);
    defer claude_node.deinit();
    const claude_body = try claude_node.read(.all);
    defer allocator.free(claude_body);
    try std.testing.expectEqualStrings("{\"event\":\"subagent.spawned\"}\n{\"event\":\"turn.ended\"}\n{\"event\":\"subagent.exited\"}\n", claude_body);

    const codex_url = try allocator.print("file:///tmp/{s}/codex-1.jsonl", .{run_id});
    defer allocator.free(codex_url);
    var codex_node = try zigstorage.Node.init(allocator, io, std.testing.environ, codex_url);
    defer codex_node.deinit();
    const codex_body = try codex_node.read(.all);
    defer allocator.free(codex_body);
    try std.testing.expectEqualStrings("{\"event\":\"subagent.spawned\"}\n", codex_body);

    const roster_url = try allocator.print("file:///tmp/{s}/run.json", .{run_id});
    defer allocator.free(roster_url);
    var roster_node = try zigstorage.Node.init(allocator, io, std.testing.environ, roster_url);
    defer roster_node.deinit();
    const roster_body = try roster_node.read(.all);
    defer allocator.free(roster_body);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, roster_body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(run_id, parsed.value.object.get("run").?.string);
    const subagents = parsed.value.object.get("subagents").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), subagents.len);
    try std.testing.expectEqualStrings("work", subagents[0].object.get("account").?.string);
    try std.testing.expectEqual(@as(i64, 5), subagents[0].object.get("startedMs").?.integer);
    try std.testing.expect(subagents[0].object.get("endedMs") != null);
    try std.testing.expectEqualStrings("claude-1", subagents[1].object.get("parent").?.string);
    try std.testing.expect(subagents[1].object.get("endedMs") == null);
}
