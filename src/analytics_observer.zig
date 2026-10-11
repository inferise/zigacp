//! What watches an agent: the sink a `TapTransport` reports each of its frames to.
//!
//! The one place analytics attach to the protocol: every frame between a client
//! or relay and an agent, in either direction, whichever path carried it and whatever
//! agent is behind it. An observer only watches — it cannot change a frame,
//! hold one up, or fail the call that carried it — so a slow or broken observer
//! costs data, never a turn.

const std = @import("std");
const log = std.log.scoped(.acp_analytics_observer);

/// Which way a frame went, seen from the client's side of the transport.
pub const ObservedDirection = enum {
    /// Written by the client, toward the agent.
    sent,
    /// Read by the client, from the agent.
    received,
};

/// One frame that crossed a tapped transport.
pub const ObservedFrame = struct {
    /// Who the frame belongs to: the tap's label for its agent. Borrowed for the call.
    source: []const u8,
    direction: ObservedDirection,
    /// Per-tap count of frames reported before this one, so a consumer can order
    /// frames and notice a gap. Unique per tap; not comparable across taps.
    sequence: u64,
    /// Wall-clock time the frame finished crossing.
    at: std.Io.Timestamp,
    /// The frame's JSON-RPC message. Borrowed for the call; copy to keep.
    bytes: []const u8,
};

/// A sink for observed frames, as a vtable so any consumer can be one.
pub const AnalyticsObserver = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Takes one frame. Called on whichever task read or wrote it — so it
        /// may run on several tasks at once — and must neither block nor fail.
        observe: *const fn (ctx: *anyopaque, frame: ObservedFrame) void,
    };

    /// Hands one frame to the observer.
    ///
    /// Parameters:
    /// - `self`: the observer.
    /// - `frame`: the frame; borrowed for the call.
    ///
    /// Return: nothing.
    pub fn observe(self: Self, frame: ObservedFrame) void {
        self.vtable.observe(self.ptr, frame);
    }
};

/// An observer that counts the frames it is shown in each direction, for tests and live figures. Safe across tasks.
pub const ObservedFrameCounter = struct {
    const Self = @This();

    sent: std.atomic.Value(usize) = .init(0),
    received: std.atomic.Value(usize) = .init(0),

    const vtable = AnalyticsObserver.VTable{ .observe = observe };

    /// Returns this counter as an observer.
    ///
    /// Parameters:
    /// - `self`: the counter; must outlive the observer.
    ///
    /// Return: the observer, borrowing `self`.
    pub fn observer(self: *Self) AnalyticsObserver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn observe(ctx: *anyopaque, frame: ObservedFrame) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const count = if (frame.direction == .sent) &self.sent else &self.received;
        _ = count.fetchAdd(1, .monotonic);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(AnalyticsObserver);
    // The logger ZIGSTYLE asks every file for; this file has nothing to log.
    _ = log;
}

test "an observer is called through its vtable with the frame as given" {
    const Counter = struct {
        const Self = @This();

        count: usize = 0,
        last: ObservedDirection = .sent,

        fn observe(ctx: *anyopaque, frame: ObservedFrame) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.count += 1;
            self.last = frame.direction;
        }

        const vtable = AnalyticsObserver.VTable{ .observe = observe };
    };

    var counter = Counter{};
    const observer = AnalyticsObserver{ .ptr = &counter, .vtable = &Counter.vtable };
    observer.observe(.{ .source = "claude", .direction = .received, .sequence = 0, .at = std.Io.Clock.real.now(std.testing.io), .bytes = "{}" });
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    try std.testing.expectEqual(ObservedDirection.received, counter.last);
}
