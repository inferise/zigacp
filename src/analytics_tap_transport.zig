//! An `acp.Transport` that reports every frame crossing it to a `acp.Analytics.Observer`.
//!
//! The raw seam analytics hang off. Every agent a client talks to — a linked
//! harness over an in-process pair or a native agent over a child's stdio — is
//! reached through an `acp.Transport`, so wrapping that one vtable sees all of
//! it, in both directions, below `acp.Connection`'s decoding.
//!
//! A frame is reported once it has crossed: after a write succeeds, after a read
//! returns. A failed write or read reports nothing. The wrapper offers polling
//! exactly when the transport it wraps does, so `canPoll` answers as before.
//!
//! The transport hands out `self` as its context, so a tap must not move once
//! `transport` has been called.

const std = @import("std");
const log = std.log.scoped(.acp_analytics_tap_transport);
const acp = @import("module.zig");

/// A transport wrapper that observes and forwards.
pub const AnalyticsTapTransport = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    /// The transport every call is forwarded to; borrowed.
    inner: acp.Transport,
    /// Where each crossed frame is reported; borrowed.
    observer: acp.Analytics.Observer,
    /// The label each frame is reported under. Owned.
    source: []u8,
    /// Frames reported so far; the next frame's sequence number.
    sequence: std.atomic.Value(u64) = .init(0),

    const polling_vtable = acp.Transport.VTable{
        .write_frame = writeFrame,
        .read_frame = readFrame,
        .try_read_frame = tryReadFrame,
        .close = close,
    };

    const blocking_vtable = acp.Transport.VTable{
        .write_frame = writeFrame,
        .read_frame = readFrame,
        .close = close,
    };

    /// Creates a tap over a transport.
    ///
    /// Parameters:
    /// - `allocator`: owns the copy of `source`.
    /// - `io`: IO capability, for the timestamps.
    /// - `inner`: the transport to forward to; borrowed, must outlive the tap.
    /// - `observer`: where frames are reported; borrowed, must outlive the tap.
    /// - `source`: the label frames are reported under; copied.
    ///
    /// Return: the tap, caller stores it at a stable address and calls `deinit`; allocation failure propagates.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, inner: acp.Transport, observer: acp.Analytics.Observer, source: []const u8) acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return Self{
            .allocator = allocator,
            .io = io,
            .inner = inner,
            .observer = observer,
            .source = try allocator.dupe(u8, source),
        };
    }

    /// Releases the tap; the wrapped transport is left as it is.
    ///
    /// Parameters:
    /// - `self`: the tap.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.allocator.free(self.source);
    }

    /// Returns the tapped transport to hand to whoever would have used `inner`.
    ///
    /// Parameters:
    /// - `self`: the tap; must not move while the transport is in use.
    ///
    /// Return: the transport, borrowing `self`.
    pub fn transport(self: *Self) acp.Transport {
        return .{ .ptr = self, .vtable = if (self.inner.canPoll()) &polling_vtable else &blocking_vtable };
    }

    /// Writes a frame through the wrapped transport, then reports it.
    ///
    /// Parameters:
    /// - `ctx`: the tap.
    /// - `frame`: the frame to write.
    ///
    /// Return: nothing; the wrapped transport's write error propagates, with nothing reported.
    fn writeFrame(ctx: *anyopaque, frame: acp.Frame) acp.AcpError!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.inner.writeFrame(frame);
        self.report(.sent, frame.bytes);
    }

    /// Reads a frame from the wrapped transport, then reports it.
    ///
    /// Parameters:
    /// - `ctx`: the tap.
    /// - `allocator`: owns the returned frame.
    ///
    /// Return: the frame, caller frees; the wrapped transport's read error propagates, with nothing reported.
    fn readFrame(ctx: *anyopaque, allocator: std.mem.Allocator) acp.AcpError![]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const bytes = try self.inner.readFrame(allocator);
        self.report(.received, bytes);
        return bytes;
    }

    /// Reads a waiting frame from the wrapped transport without blocking, reporting it when there is one.
    ///
    /// Parameters:
    /// - `ctx`: the tap.
    /// - `allocator`: owns the returned frame.
    ///
    /// Return: the frame, caller frees, or null when none is waiting; the wrapped transport's error propagates.
    fn tryReadFrame(ctx: *anyopaque, allocator: std.mem.Allocator) acp.AcpError!?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const bytes = (try self.inner.tryReadFrame(allocator)) orelse return null;
        self.report(.received, bytes);
        return bytes;
    }

    /// Closes the wrapped transport.
    ///
    /// Parameters:
    /// - `ctx`: the tap.
    ///
    /// Return: nothing.
    fn close(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.inner.close();
    }

    /// Reports one crossed frame to the observer.
    ///
    /// Parameters:
    /// - `self`: the tap.
    /// - `direction`: which way it went.
    /// - `bytes`: the frame; borrowed for the call.
    ///
    /// Return: nothing.
    fn report(self: *Self, direction: acp.Analytics.Direction, bytes: []const u8) void {
        self.observer.observe(.{
            .source = self.source,
            .direction = direction,
            .sequence = self.sequence.fetchAdd(1, .monotonic),
            .at = std.Io.Clock.real.now(self.io),
            .bytes = bytes,
        });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

/// Records every frame it is shown, for the tests to inspect. Safe across tasks.
const FrameRecorder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    sent: std.ArrayList([]u8) = .empty,
    received: std.ArrayList([]u8) = .empty,
    sequences: std.ArrayList(u64) = .empty,
    /// Frames that could not be recorded; a test asserting counts fails loudly on any.
    lost: usize = 0,

    const vtable = acp.Analytics.Observer.VTable{ .observe = observe };

    fn deinit(self: *Self) void {
        for (self.sent.items) |frame| self.allocator.free(frame);
        for (self.received.items) |frame| self.allocator.free(frame);
        self.sent.deinit(self.allocator);
        self.received.deinit(self.allocator);
        self.sequences.deinit(self.allocator);
    }

    fn observer(self: *Self) acp.Analytics.Observer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn observe(ctx: *anyopaque, frame: acp.Analytics.Frame) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.record(frame) catch {
            self.lost += 1;
        };
    }

    fn record(self: *Self, frame: acp.Analytics.Frame) !void {
        try self.sequences.ensureUnusedCapacity(self.allocator, 1);
        const list = if (frame.direction == .sent) &self.sent else &self.received;
        try list.ensureUnusedCapacity(self.allocator, 1);
        list.appendAssumeCapacity(try self.allocator.dupe(u8, frame.bytes));
        self.sequences.appendAssumeCapacity(frame.sequence);
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(AnalyticsTapTransport);
}

test "a tap reports each frame once, in both directions, and forwards it untouched" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const pair = try acp.FrameTransport.init(allocator, io);
    defer pair.deinit();
    var recorder = FrameRecorder{ .allocator = allocator, .io = io };
    defer recorder.deinit();
    var tap = try AnalyticsTapTransport.init(allocator, io, pair.clientTransport(), recorder.observer(), "claude");
    defer tap.deinit();
    const tapped = tap.transport();
    const agent = pair.agentTransport();

    try tapped.writeFrame(.{ .bytes = "{\"id\":1,\"method\":\"session/new\"}" });
    const arrived = try agent.readFrame(allocator);
    defer allocator.free(arrived);
    try std.testing.expectEqualStrings("{\"id\":1,\"method\":\"session/new\"}", arrived);

    try agent.writeFrame(.{ .bytes = "{\"id\":1,\"result\":{}}" });
    const answer = try tapped.readFrame(allocator);
    defer allocator.free(answer);
    try std.testing.expectEqualStrings("{\"id\":1,\"result\":{}}", answer);

    try std.testing.expectEqual(@as(usize, 1), recorder.sent.items.len);
    try std.testing.expectEqual(@as(usize, 1), recorder.received.items.len);
    try std.testing.expectEqualStrings("{\"id\":1,\"method\":\"session/new\"}", recorder.sent.items[0]);
    try std.testing.expectEqualStrings("{\"id\":1,\"result\":{}}", recorder.received.items[0]);
    try std.testing.expectEqualSlices(u64, &.{ 0, 1 }, recorder.sequences.items);
    try std.testing.expectEqual(@as(usize, 0), recorder.lost);
}

test "a tap polls exactly when the transport it wraps can, and a poll with nothing waiting reports nothing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const pair = try acp.FrameTransport.init(allocator, io);
    defer pair.deinit();
    var recorder = FrameRecorder{ .allocator = allocator, .io = io };
    defer recorder.deinit();
    var tap = try AnalyticsTapTransport.init(allocator, io, pair.clientTransport(), recorder.observer(), "codex");
    defer tap.deinit();
    const tapped = tap.transport();

    try std.testing.expectEqual(pair.clientTransport().canPoll(), tapped.canPoll());
    if (!tapped.canPoll()) return;

    try std.testing.expectEqual(@as(?[]u8, null), try tapped.tryReadFrame(allocator));
    try pair.agentTransport().writeFrame(.{ .bytes = "{\"method\":\"session/update\"}" });
    const polled = (try tapped.tryReadFrame(allocator)).?;
    defer allocator.free(polled);
    try std.testing.expectEqual(@as(usize, 1), recorder.received.items.len);
}

test "a failed write reports nothing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const pair = try acp.FrameTransport.init(allocator, io);
    defer pair.deinit();
    var recorder = FrameRecorder{ .allocator = allocator, .io = io };
    defer recorder.deinit();
    var tap = try AnalyticsTapTransport.init(allocator, io, pair.clientTransport(), recorder.observer(), "afm");
    defer tap.deinit();
    const tapped = tap.transport();

    tapped.close();
    try std.testing.expectError(error.TransportClosed, tapped.writeFrame(.{ .bytes = "{}" }));
    try std.testing.expectEqual(@as(usize, 0), recorder.sent.items.len);
}
