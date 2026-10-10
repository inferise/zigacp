//! A scripted ACP peer for tests: answers from a fixed list of frames and
//! records every frame it is sent.

const std = @import("std");
const log = std.log.scoped(.acp_scripted_peer);
const mod = @import("module.zig");

/// A peer that answers from a script and records what it was sent.
pub const ScriptedPeer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    replies: []const []const u8,
    next: usize = 0,
    sent: std.ArrayList([]u8) = .empty,

    /// Borrows the peer as a transport.
    ///
    /// Parameters:
    /// - `self`: the peer; must outlive the transport.
    ///
    /// Return: the transport.
    pub fn transport(self: *Self) mod.Transport {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Frees what was recorded.
    ///
    /// Parameters:
    /// - `self`: the peer.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        for (self.sent.items) |frame| self.allocator.free(frame);
        self.sent.deinit(self.allocator);
    }

    /// Records one frame the code under test sent.
    ///
    /// Parameters:
    /// - `ctx`: the peer.
    /// - `frame`: the frame; copied.
    ///
    /// Return: nothing; `error.OutOfMemory`.
    fn writeFrame(ctx: *anyopaque, frame: mod.Frame) mod.AcpError!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const copy = self.allocator.dupe(u8, frame.bytes) catch return error.OutOfMemory;
        self.sent.append(self.allocator, copy) catch return error.OutOfMemory;
    }

    /// Hands out the next scripted reply.
    ///
    /// Parameters:
    /// - `ctx`: the peer.
    /// - `allocator`: backs the copy.
    ///
    /// Return: the reply, caller frees it; `error.TransportClosed` when the script is spent.
    fn readFrame(ctx: *anyopaque, allocator: std.mem.Allocator) mod.AcpError![]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.next >= self.replies.len) return error.TransportClosed;
        defer self.next += 1;
        return allocator.dupe(u8, self.replies[self.next]) catch error.OutOfMemory;
    }

    /// Closes the transport; nothing to release.
    ///
    /// Parameters:
    /// - `ctx`: the peer.
    ///
    /// Return: nothing.
    fn close(ctx: *anyopaque) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        _ = ctx;
    }

    const vtable: mod.Transport.VTable = .{ .write_frame = writeFrame, .read_frame = readFrame, .close = close };
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ScriptedPeer);
}
