//! A blocking in-process transport pair.
//!
//! `acp-test`'s `PipePair` is a deterministic fixture: its `readFrame` returns
//! `TransportClosed` when the queue is empty rather than waiting. That is
//! exactly right for a test that drives both ends by hand, and exactly wrong for
//! a client and an agent running concurrently in one process — the client would
//! see its own empty inbox as a closed connection.
//!
//! So an in-process seam gets a transport that **blocks**: two queues, a mutex and a
//! condition. `acp.Transport` is a vtable, which is what makes this a
//! construction detail rather than a redesign — swapping in `FileTransport` over
//! stdio later changes one line and nothing else. Promoted from zigclaude,
//! zigcodex and ziggrok, which each carried an identical copy.
//!
//! Frames are owned by the queue between `writeFrame` and `readFrame`. A closed
//! end wakes every waiter so nothing is left blocked on a peer that has gone.

const std = @import("std");
const log = std.log.scoped(.acp_frame_transport);
const acp = @import("acp");

/// Which side of the pair an end sits on.
const Side = enum { client, agent };

/// One end, as the vtable sees it.
const End = struct {
    const Self = @This();

    pair: *FrameTransport,
    side: Side,

    /// Builds an end on one side of a pair.
    ///
    /// Parameters:
    /// - `pair`: the owning pair; borrowed, must outlive the end.
    /// - `side`: which side this end is.
    ///
    /// Return: the end; never fails.
    pub fn init(pair: *FrameTransport, side: Side) !Self {
        return .{ .pair = pair, .side = side };
    }

    /// Releases the end.
    ///
    /// Parameters:
    /// - `self`: the end.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

/// Two ends of one in-process connection.
pub const FrameTransport = struct {
    const Self = @This();

    /// Refuse a queue longer than this. A peer that never reads is a bug, and a
    /// bug that eats memory silently is worse than one that says so.
    pub const max_queued_frames = 1024;

    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Signalled whenever a frame is queued or an end closes.
    arrival: std.Io.Condition = .init,
    /// Frames written by the client, waiting for the agent.
    to_agent: std.ArrayList([]u8) = .empty,
    /// Frames written by the agent, waiting for the client.
    to_client: std.ArrayList([]u8) = .empty,
    closed: bool = false,

    // SAFETY: set by `init` once `self` is at its final address.
    client_end: End = undefined,
    // SAFETY: set by `init` once `self` is at its final address.
    agent_end: End = undefined,

    /// Creates a heap-allocated, connected pair.
    ///
    /// Parameters:
    /// - `allocator`: owns the pair and queued frames; must outlive the pair.
    /// - `io`: IO capability for the mutex and condition.
    ///
    /// Return: the pair at a stable address, caller calls `deinit`; propagates allocation failure.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const self = try allocator.create(Self);
        self.* = Self{ .allocator = allocator, .io = io };
        self.client_end = .{ .pair = self, .side = .client };
        self.agent_end = .{ .pair = self, .side = .agent };
        return self;
    }

    /// Closes the pair, frees every queued frame, and frees the pair.
    ///
    /// Parameters:
    /// - `self`: the pair; invalid after this call.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.close();
        for (self.to_agent.items) |frame| self.allocator.free(frame);
        for (self.to_client.items) |frame| self.allocator.free(frame);
        self.to_agent.deinit(self.allocator);
        self.to_client.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Returns the end a client connects through.
    ///
    /// Parameters:
    /// - `self`: the pair.
    ///
    /// Return: the client transport, borrowing the pair.
    pub fn clientTransport(self: *Self) acp.Transport {
        return .{ .ptr = &self.client_end, .vtable = &vtable };
    }

    /// Returns the end an agent serves on.
    ///
    /// Parameters:
    /// - `self`: the pair.
    ///
    /// Return: the agent transport, borrowing the pair.
    pub fn agentTransport(self: *Self) acp.Transport {
        return .{ .ptr = &self.agent_end, .vtable = &vtable };
    }

    /// Closes both ends and wakes every waiter; idempotent.
    ///
    /// Parameters:
    /// - `self`: the pair.
    ///
    /// Return: nothing.
    pub fn close(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Idempotent: teardown reaches here from a front end quitting, an
        // agent's transport failing, and `deinit`.
        if (self.closed) return;
        self.closed = true;
        // Every waiter, not one: both ends may be blocked in `readFrame`, and a
        // single wake would leave the other there forever.
        self.arrival.broadcast(self.io);
    }

    /// Queues a frame for the other side.
    ///
    /// Parameters:
    /// - `self`: the pair.
    /// - `side`: the writing side.
    /// - `bytes`: the frame; copied.
    ///
    /// Return: nothing; `error.TransportClosed` once closed, `error.TransportFailed` when the queue is full, or allocation failure.
    fn push(self: *Self, side: Side, bytes: []const u8) acp.AcpError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return error.TransportClosed;

        const queue = switch (side) {
            .client => &self.to_agent,
            .agent => &self.to_client,
        };
        if (queue.items.len >= max_queued_frames) {
            log.err("{d} frames queued and unread; the peer is not serving", .{queue.items.len});
            return error.TransportFailed;
        }

        const owned = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        queue.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return error.OutOfMemory;
        };
        self.arrival.broadcast(self.io);
    }

    /// Takes a frame addressed to `side` without waiting.
    ///
    /// Parameters:
    /// - `self`: the pair.
    /// - `side`: the reading side.
    /// - `allocator`: owns the returned frame.
    ///
    /// Return: the frame, caller-owned, or null when none is queued; `error.TransportClosed` once drained and closed.
    fn tryPop(self: *Self, side: Side, allocator: std.mem.Allocator) acp.AcpError!?[]u8 {
        // Never waits, so a handler mid-turn can service the connection
        // without giving up the turn it is running.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const queue = switch (side) {
            .client => &self.to_client,
            .agent => &self.to_agent,
        };

        if (queue.items.len == 0) {
            // Closed is checked *after* the queue, as in `pop`: frames already
            // written by a peer that has since gone are still delivered.
            if (self.closed) return error.TransportClosed;
            return null;
        }

        const frame = queue.orderedRemove(0);
        defer self.allocator.free(frame);
        return allocator.dupe(u8, frame) catch return error.OutOfMemory;
    }

    /// Blocks until a frame addressed to `side` arrives.
    ///
    /// Parameters:
    /// - `self`: the pair.
    /// - `side`: the reading side.
    /// - `allocator`: owns the returned frame.
    ///
    /// Return: the frame, caller-owned; `error.TransportClosed` once drained and closed.
    fn pop(self: *Self, side: Side, allocator: std.mem.Allocator) acp.AcpError![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const queue = switch (side) {
            .client => &self.to_client,
            .agent => &self.to_agent,
        };

        while (queue.items.len == 0) {
            // Closed is checked *after* the queue, so frames already written by
            // a peer that has since gone are still delivered.
            if (self.closed) return error.TransportClosed;
            self.arrival.waitUncancelable(self.io, &self.mutex);
        }

        const frame = queue.orderedRemove(0);
        defer self.allocator.free(frame);
        return allocator.dupe(u8, frame) catch return error.OutOfMemory;
    }

    const vtable: acp.Transport.VTable = .{
        .write_frame = writeFrame,
        .read_frame = readFrame,
        .try_read_frame = tryReadFrame,
        .close = closeEnd,
    };

    /// Vtable entry that queues a frame for the peer.
    ///
    /// Parameters:
    /// - `ctx`: the writing `End`.
    /// - `frame`: the frame; copied.
    ///
    /// Return: nothing; propagates `push` errors.
    fn writeFrame(ctx: *anyopaque, frame: acp.Frame) acp.AcpError!void {
        const end: *End = @ptrCast(@alignCast(ctx));
        return end.pair.push(end.side, frame.bytes);
    }

    /// Vtable entry that blocks for the next frame.
    ///
    /// Parameters:
    /// - `ctx`: the reading `End`.
    /// - `allocator`: owns the returned frame.
    ///
    /// Return: the frame, caller-owned; propagates `pop` errors.
    fn readFrame(ctx: *anyopaque, allocator: std.mem.Allocator) acp.AcpError![]u8 {
        const end: *End = @ptrCast(@alignCast(ctx));
        return end.pair.pop(end.side, allocator);
    }

    /// Vtable entry that reads a queued frame without waiting.
    ///
    /// Parameters:
    /// - `ctx`: the reading `End`.
    /// - `allocator`: owns the returned frame.
    ///
    /// Return: the frame, caller-owned, or null when none is queued; propagates `tryPop` errors.
    fn tryReadFrame(ctx: *anyopaque, allocator: std.mem.Allocator) acp.AcpError!?[]u8 {
        const end: *End = @ptrCast(@alignCast(ctx));
        return end.pair.tryPop(end.side, allocator);
    }

    /// Vtable entry that closes the pair from either end.
    ///
    /// Parameters:
    /// - `ctx`: the closing `End`.
    ///
    /// Return: nothing.
    fn closeEnd(ctx: *anyopaque) void {
        const end: *End = @ptrCast(@alignCast(ctx));
        end.pair.close();
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(FrameTransport);
}

test "a frame written by one end is read by the other" {
    const allocator = std.testing.allocator;
    const pair = try FrameTransport.init(allocator, std.testing.io);
    defer pair.deinit();

    const client = pair.clientTransport();
    const agent = pair.agentTransport();

    try client.writeFrame(.{ .bytes = "{\"from\":\"client\"}" });
    const at_agent = try agent.readFrame(allocator);
    defer allocator.free(at_agent);
    try std.testing.expectEqualStrings("{\"from\":\"client\"}", at_agent);

    try agent.writeFrame(.{ .bytes = "{\"from\":\"agent\"}" });
    const at_client = try client.readFrame(allocator);
    defer allocator.free(at_client);
    try std.testing.expectEqualStrings("{\"from\":\"agent\"}", at_client);
}

test "frames arrive in the order they were written" {
    const allocator = std.testing.allocator;
    const pair = try FrameTransport.init(allocator, std.testing.io);
    defer pair.deinit();

    const client = pair.clientTransport();
    const agent = pair.agentTransport();

    for ([_][]const u8{ "one", "two", "three" }) |frame| {
        try client.writeFrame(.{ .bytes = frame });
    }
    for ([_][]const u8{ "one", "two", "three" }) |expected| {
        const got = try agent.readFrame(allocator);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(expected, got);
    }
}

test "a closed pair reports closure rather than blocking forever" {
    const allocator = std.testing.allocator;
    const pair = try FrameTransport.init(allocator, std.testing.io);
    defer pair.deinit();

    pair.close();

    // This is the behaviour `PipePair` cannot give us: an *empty* queue waits,
    // but a *closed* pair reports it — so a client never mistakes silence for a
    // hangup.
    try std.testing.expectError(error.TransportClosed, pair.agentTransport().readFrame(allocator));
    try std.testing.expectError(error.TransportClosed, pair.clientTransport().writeFrame(.{ .bytes = "x" }));
}

test "frames already queued survive the peer closing" {
    const allocator = std.testing.allocator;
    const pair = try FrameTransport.init(allocator, std.testing.io);
    defer pair.deinit();

    try pair.clientTransport().writeFrame(.{ .bytes = "last words" });
    pair.close();

    // Closed is checked after the queue, so nothing already written is lost.
    const got = try pair.agentTransport().readFrame(allocator);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("last words", got);

    try std.testing.expectError(error.TransportClosed, pair.agentTransport().readFrame(allocator));
}

test "closing is idempotent and reachable from either end" {
    const allocator = std.testing.allocator;
    const pair = try FrameTransport.init(allocator, std.testing.io);
    defer pair.deinit();

    pair.clientTransport().close();
    pair.agentTransport().close();
    pair.close();

    try std.testing.expectError(error.TransportClosed, pair.clientTransport().readFrame(allocator));
}

test "a non-blocking read returns null when empty and the frame when queued" {
    const allocator = std.testing.allocator;
    const pair = try FrameTransport.init(allocator, std.testing.io);
    defer pair.deinit();

    const agent = pair.agentTransport();
    try std.testing.expect(agent.canPoll());
    try std.testing.expectEqual(@as(?[]u8, null), try agent.tryReadFrame(allocator));

    try pair.clientTransport().writeFrame(.{ .bytes = "ready" });
    const got = (try agent.tryReadFrame(allocator)).?;
    defer allocator.free(got);
    try std.testing.expectEqualStrings("ready", got);

    pair.close();
    try std.testing.expectError(error.TransportClosed, agent.tryReadFrame(allocator));
}
