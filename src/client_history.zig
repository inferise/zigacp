//! Where a client keeps a session's finished turns: the caller's store, behind a vtable.
//!
//! A client streams one turn at a time and hands each finished one over in a
//! single call, so several sessions streaming at once never interleave their
//! deltas in a shared store. What the store is — a transcript on disk, a list in
//! memory, nothing at all — is the caller's.

const std = @import("std");
const log = std.log.scoped(.acp_client_history);
const acp = @import("module.zig");

/// The store a client hands its finished turns and notes to.
pub const ClientHistory = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Keeps one finished turn: the prompt and the reply, as text.
        append: *const fn (ctx: *anyopaque, text: []const u8) std.mem.Allocator.Error!void,
        /// Keeps one line the client says itself, such as a model switch.
        note: *const fn (ctx: *anyopaque, text: []const u8) std.mem.Allocator.Error!void,
        /// Replaces everything kept with the turns an agent replayed on `session/load`.
        replace: *const fn (ctx: *anyopaque, texts: []const []const u8) std.mem.Allocator.Error!void,
    };

    /// A history that keeps nothing, for a client whose agent replays its sessions or a caller that keeps none.
    // SAFETY: none of its functions reads the context.
    pub const none: Self = .{ .ptr = undefined, .vtable = &.{ .append = discard, .note = discard, .replace = discardAll } };

    /// Keeps one finished turn.
    ///
    /// Parameters:
    /// - `self`: the history.
    /// - `text`: the turn; borrowed for the call.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn append(self: Self, text: []const u8) std.mem.Allocator.Error!void {
        return self.vtable.append(self.ptr, text);
    }

    /// Keeps one line the client says itself.
    ///
    /// Parameters:
    /// - `self`: the history.
    /// - `text`: the line; borrowed for the call.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn note(self: Self, text: []const u8) std.mem.Allocator.Error!void {
        return self.vtable.note(self.ptr, text);
    }

    /// Replaces everything kept with replayed turns.
    ///
    /// Parameters:
    /// - `self`: the history.
    /// - `texts`: the turns, oldest first; borrowed for the call.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn replace(self: Self, texts: []const []const u8) std.mem.Allocator.Error!void {
        return self.vtable.replace(self.ptr, texts);
    }

    fn discard(ctx: *anyopaque, text: []const u8) std.mem.Allocator.Error!void {
        _ = ctx;
        _ = text;
    }

    fn discardAll(ctx: *anyopaque, texts: []const []const u8) std.mem.Allocator.Error!void {
        _ = ctx;
        _ = texts;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ClientHistory);
    // The logger ZIGSTYLE asks every file for; this file has nothing to log.
    _ = log;
}

test "a history is called through its vtable, and none keeps nothing" {
    const Kept = struct {
        const Self = @This();

        turns: usize = 0,
        notes: usize = 0,
        replaced: usize = 0,

        fn append(ctx: *anyopaque, text: []const u8) std.mem.Allocator.Error!void {
            _ = text;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.turns += 1;
        }

        fn note(ctx: *anyopaque, text: []const u8) std.mem.Allocator.Error!void {
            _ = text;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.notes += 1;
        }

        fn replace(ctx: *anyopaque, texts: []const []const u8) std.mem.Allocator.Error!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.replaced = texts.len;
        }
    };

    var kept = Kept{};
    const history = ClientHistory{ .ptr = &kept, .vtable = &.{ .append = Kept.append, .note = Kept.note, .replace = Kept.replace } };
    try history.append("hi");
    try history.note("switched");
    try history.replace(&.{ "a", "b" });
    try std.testing.expectEqual(@as(usize, 1), kept.turns);
    try std.testing.expectEqual(@as(usize, 1), kept.notes);
    try std.testing.expectEqual(@as(usize, 2), kept.replaced);

    try ClientHistory.none.append("dropped");
    try std.testing.expect(acp.Client.History == ClientHistory);
}
