//! Which request a reply answers, tracked per direction.
//!
//! A proxy sits between two peers that number their requests independently,
//! so the same id can be pending in both directions at once: the client's
//! request 1 and the agent's request 1 are different calls. A reply travelling
//! toward the client answers a request that travelled toward the agent, and
//! the other way round. `Pairing` keeps one table per direction and matches a
//! reply in the table of the side that asked, handing back the method and
//! whatever the embedder kept with the request.

const std = @import("std");
const log = std.log.scoped(.acp_conductor_pairing);
const mod = @import("module.zig");

/// Builds a pairing that keeps a `T` with each pending request.
///
/// Parameters:
/// - `T`: what the embedder keeps per request; owned by the pairing until `answered` hands it back.
///
/// Return: the pairing type.
pub fn Pairing(comptime T: type) type {
    return struct {
        const Self = @This();

        /// A request still waiting for its reply.
        pub const Pending = struct {
            /// The request's method; owned by the pairing until handed back, then by the caller.
            method: []u8,
            /// What the embedder kept with it.
            value: T,
        };

        const Table = std.StringHashMapUnmanaged(Pending);

        allocator: std.mem.Allocator,
        /// Requests travelling toward the agent, awaiting the agent's reply.
        forward: Table = .empty,
        /// Requests travelling toward the client, awaiting the client's reply.
        reverse: Table = .empty,

        /// Creates an empty pairing.
        ///
        /// Parameters:
        /// - `allocator`: backs the tables and the keys; must outlive the pairing.
        ///
        /// Return: the pairing; caller calls `deinit`.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Frees the tables. Values still pending are dropped unread; drain them with `takeAny` first if they own memory.
        ///
        /// Parameters:
        /// - `self`: the pairing.
        ///
        /// Return: nothing.
        pub fn deinit(self: *Self) void {
            inline for (.{ &self.forward, &self.reverse }) |side| {
                var it = side.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.method);
                }
                side.deinit(self.allocator);
            }
        }

        /// Records a request on its way, under its id.
        ///
        /// Parameters:
        /// - `self`: the pairing.
        /// - `direction`: which way the request travels.
        /// - `id`: the request's JSON-RPC id, a string or an integer.
        /// - `method`: the request's method; copied.
        /// - `value`: what to keep with it; owned by the pairing from here.
        ///
        /// Return: the older request a reused pending id replaced, caller frees its `method` and value; null normally. `error.InvalidMessage` for an id that is neither, `error.OutOfMemory`; on error `value` stays the caller's.
        pub fn sent(self: *Self, direction: mod.Direction, id: std.json.Value, method: []const u8, value: T) !?Pending {
            const key = try keyOwned(self.allocator, id);
            errdefer self.allocator.free(key);
            const method_copy = try self.allocator.dupe(u8, method);
            errdefer self.allocator.free(method_copy);
            const slot = try self.tableFor(direction).getOrPut(self.allocator, key);
            var replaced: ?Pending = null;
            if (slot.found_existing) {
                log.warn("request id {s} reused while still pending; the older one can no longer be matched", .{key});
                self.allocator.free(key);
                replaced = slot.value_ptr.*;
            }
            slot.value_ptr.* = .{ .method = method_copy, .value = value };
            return replaced;
        }

        /// Matches a reply to the request it answers.
        ///
        /// Parameters:
        /// - `self`: the pairing.
        /// - `direction`: which way the reply travels; it answers a request that travelled the other way.
        /// - `id`: the reply's id.
        ///
        /// Return: the request, caller frees `method` with the pairing's allocator; null for a reply nobody is waiting on.
        pub fn answered(self: *Self, direction: mod.Direction, id: std.json.Value) ?Pending {
            var buffer: [64]u8 = undefined;
            const key = keyInto(&buffer, id) orelse return null;
            const asked: mod.Direction = switch (direction) {
                .forward => .reverse,
                .reverse => .forward,
            };
            const removed = self.tableFor(asked).fetchRemove(key) orelse return null;
            self.allocator.free(removed.key);
            return removed.value;
        }

        /// Takes any one pending request, for draining before `deinit`.
        ///
        /// Parameters:
        /// - `self`: the pairing.
        ///
        /// Return: a request, caller frees `method`; null once both tables are empty.
        pub fn takeAny(self: *Self) ?Pending {
            inline for (.{ &self.forward, &self.reverse }) |side| {
                var it = side.iterator();
                if (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const pending = entry.value_ptr.*;
                    _ = side.remove(key);
                    self.allocator.free(key);
                    return pending;
                }
            }
            return null;
        }

        /// How many requests travelling one way are unanswered.
        ///
        /// Parameters:
        /// - `self`: the pairing.
        /// - `direction`: which way they travelled.
        ///
        /// Return: the count.
        pub fn count(self: *const Self, direction: mod.Direction) usize {
            return switch (direction) {
                .forward => self.forward.count(),
                .reverse => self.reverse.count(),
            };
        }

        fn tableFor(self: *Self, direction: mod.Direction) *Table {
            return switch (direction) {
                .forward => &self.forward,
                .reverse => &self.reverse,
            };
        }
    };
}

/// Spells an id as a key, keeping `1` and `"1"` apart.
///
/// Parameters:
/// - `buffer`: where the key is written.
/// - `id`: the id.
///
/// Return: the key, borrowed from `buffer`; null for an id that is neither a string nor an integer, or too long.
fn keyInto(buffer: []u8, id: std.json.Value) ?[]const u8 {
    return switch (id) {
        .integer => |n| std.mem.print(buffer, "i:{d}", .{n}) catch null,
        .string => |s| std.mem.print(buffer, "s:{s}", .{s}) catch null,
        else => null,
    };
}

/// Spells an id as an owned key.
///
/// Parameters:
/// - `allocator`: owns the key.
/// - `id`: the id.
///
/// Return: the key; `error.InvalidMessage` for an id that is neither a string nor an integer.
fn keyOwned(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    return switch (id) {
        .integer => |n| allocator.print("i:{d}", .{n}),
        .string => |s| allocator.print("s:{s}", .{s}),
        else => error.InvalidMessage,
    };
}

// -----------------------------------------------------------------------------
// Unit Tests

test "the same id pending both ways is matched to the side that asked" {
    const allocator = std.testing.allocator;
    var pairing = Pairing(u8).init(allocator);
    defer pairing.deinit();

    _ = try pairing.sent(.forward, .{ .integer = 1 }, "session/prompt", 'c');
    _ = try pairing.sent(.reverse, .{ .integer = 1 }, "session/request_permission", 'a');

    // The client answers the agent's request 1, travelling forward.
    const permission = pairing.answered(.forward, .{ .integer = 1 }).?;
    defer allocator.free(permission.method);
    try std.testing.expectEqualStrings("session/request_permission", permission.method);
    try std.testing.expectEqual(@as(u8, 'a'), permission.value);

    const prompt = pairing.answered(.reverse, .{ .integer = 1 }).?;
    defer allocator.free(prompt.method);
    try std.testing.expectEqual(@as(u8, 'c'), prompt.value);

    try std.testing.expectEqual(@as(?Pairing(u8).Pending, null), pairing.answered(.reverse, .{ .integer = 1 }));
}

test "a string id and an integer id of the same digits are different requests" {
    const allocator = std.testing.allocator;
    var pairing = Pairing(u8).init(allocator);
    defer pairing.deinit();

    _ = try pairing.sent(.forward, .{ .string = "7" }, "a", 1);
    _ = try pairing.sent(.forward, .{ .integer = 7 }, "b", 2);

    // A reused id hands the older request back.
    const older = (try pairing.sent(.forward, .{ .integer = 7 }, "c", 3)).?;
    defer allocator.free(older.method);
    try std.testing.expectEqual(@as(u8, 2), older.value);
    try std.testing.expectEqual(@as(usize, 2), pairing.count(.forward));

    const c = pairing.answered(.reverse, .{ .integer = 7 }).?;
    defer allocator.free(c.method);
    try std.testing.expectEqualStrings("c", c.method);

    // Left pending: drained before deinit.
    while (pairing.takeAny()) |left| allocator.free(left.method);
}
