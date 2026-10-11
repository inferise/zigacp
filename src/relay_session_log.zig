//! One session's protocol record, as JSONL on disk.
//!
//! Every ACP frame that crosses the relay for a session — the host's requests,
//! the agent's updates, both sides' replies — is appended here verbatim, one
//! line each, with who sent it, when, and which turn it belongs to. It is the
//! record of truth a host builds its history from: exact where a screen scrape
//! was lossy, and the same shape whichever agent produced it.
//!
//! ```
//! {"ts":1790000000123,"from":"client","turn":1,"frame":{…the JSON-RPC message…}}
//! ```
//!
//! Append-only and flushed per line, because a turn can be cut short by the
//! process ending and a record should end where the session did. Disk access
//! goes through `zigstorage`, as everything here does.

const std = @import("std");
const log = std.log.scoped(.acp_relay_session_log);
const acp = @import("module.zig");
const zigstorage = @import("zigstorage");

/// Which side of the relay a frame came from.
pub const Origin = enum {
    /// The host: the app driving the agent.
    client,
    /// The agent or harness being driven.
    agent,

    /// The name written to the log.
    ///
    /// Parameters:
    /// - `self`: the origin.
    ///
    /// Return: `client` or `agent`.
    pub fn label(self: Origin) []const u8 {
        return @tagName(self);
    }
};

/// Appends frames for one session to `<dir>/<session id>.jsonl`.
pub const RelaySessionLog = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    /// The file's `file://` URL. Owned.
    url: []u8,
    /// Whether the file is known to exist, so `append` can extend it.
    created: bool = false,

    /// Names the log for a session; nothing touches the disk until the first frame.
    ///
    /// Parameters:
    /// - `allocator`: owns the URL; must outlive the log.
    /// - `io`: IO capability for the writes and the clock.
    /// - `environ`: the process environment, which `zigstorage` resolves against.
    /// - `dir`: the directory the host named; borrowed for the call.
    /// - `session_id`: the ACP session id, which names the file; borrowed for the call.
    ///
    /// Return: the log; propagates allocation failure.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, dir: []const u8, session_id: []const u8) acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const trimmed = std.mem.trimEnd(u8, dir, "/");
        return Self{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .url = try allocator.print("file://{s}/{s}.jsonl", .{ trimmed, session_id }),
        };
    }

    /// Releases the URL.
    ///
    /// Parameters:
    /// - `self`: the log.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.allocator.free(self.url);
    }

    /// Appends one frame as one line.
    ///
    /// Parameters:
    /// - `self`: the log.
    /// - `origin`: which side sent it.
    /// - `turn`: the session's turn when it crossed; zero before the first prompt.
    /// - `frame`: the JSON-RPC message, verbatim; must itself be valid JSON.
    ///
    /// Return: nothing; propagates storage and allocation failures.
    pub fn append(self: *Self, origin: Origin, turn: u32, frame: []const u8) acp.AcpError!void {
        self.write(origin, turn, frame) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => blk: {
                log.warn("session record not written [{t}]", .{err});
                break :blk error.StorageFailed;
            },
        };
    }

    /// Writes one line, creating the file on the first.
    ///
    /// Parameters:
    /// - `self`: the log.
    /// - `origin`: which side sent it.
    /// - `turn`: the session's turn when it crossed.
    /// - `frame`: the JSON-RPC message, verbatim.
    ///
    /// Return: nothing; propagates storage and allocation failures.
    fn write(self: *Self, origin: Origin, turn: u32, frame: []const u8) !void {
        const now_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        const line = try self.allocator.print("{{\"ts\":{d},\"from\":\"{s}\",\"turn\":{d},\"frame\":{s}}}\n", .{ now_ms, origin.label(), turn, frame });
        defer self.allocator.free(line);

        var node = try zigstorage.Node.init(self.allocator, self.io, self.environ, self.url);
        defer node.deinit();

        // `append` extends an asset that exists; the first line has to create it.
        // A session resumed into an existing file keeps what it already holds.
        if (!self.created) {
            if (!(try node.exists())) {
                try node.open();
                try node.append(line);
                try node.save();
                self.created = true;
                return;
            }
            self.created = true;
        }
        try node.append(line);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RelaySessionLog);
}

test "frames land one per line, and a reopened log appends rather than replaces" {
    // Through `zigstorage` like the code under test, into a file named for this
    // run so parallel runs cannot collide; creating a missing directory is
    // `zigstorage`'s promise and is tested there.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // SAFETY: filled by `io.random` before any byte of it is read.
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    const session_id = try allocator.print("zigacp-test-{s}", .{hex});
    defer allocator.free(session_id);

    {
        var session_log = try RelaySessionLog.init(allocator, io, std.testing.environ, "/tmp", session_id);
        defer session_log.deinit();
        try session_log.append(.client, 1, "{\"id\":1,\"method\":\"session/prompt\"}");
        try session_log.append(.agent, 1, "{\"id\":1,\"result\":{\"stopReason\":\"end_turn\"}}");
    }

    var reopened = try RelaySessionLog.init(allocator, io, std.testing.environ, "/tmp", session_id);
    defer reopened.deinit();
    try reopened.append(.client, 2, "{\"id\":2,\"method\":\"session/prompt\"}");

    var node = try zigstorage.Node.init(allocator, io, std.testing.environ, reopened.url);
    defer node.deinit();
    defer node.remove() catch {};
    const body = try node.read(.all);
    defer allocator.free(body);

    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, body, "\n"));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');
    var turns: [3]i64 = @splat(0);
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        turns[index] = parsed.value.object.get("turn").?.integer;
        try std.testing.expect(parsed.value.object.get("frame").? == .object);
    }
    try std.testing.expectEqualSlices(i64, &.{ 1, 1, 2 }, &turns);
}
