//! A host's own MCP server, offered to one session.
//!
//! An offer is two things in a `session/new` or `session/load` request: the
//! server in `mcpServers` (HTTP, with a bearer token naming the session), and
//! the server trusted in `_meta.inferise.trustedMcpServers` — since reporting
//! progress, asking a question or starting a subagent is nothing an operator
//! should have to approve. A relay and a client both offer it, through `put`.

const std = @import("std");
const log = std.log.scoped(.acp_mcp_offer);
const acp = @import("module.zig");

/// A host's MCP server, offered to a session: where it is and the bearer token naming the session.
pub const McpOffer = struct {
    const Self = @This();

    /// The server's URL. Borrowed for the call that offers it.
    url: []const u8,
    /// The bearer token the session's calls carry. Borrowed for the call that offers it.
    token: []const u8,

    /// The `mcpServers` entry for the offer.
    ///
    /// Parameters:
    /// - `self`: the offer.
    /// - `arena`: owns the header text.
    ///
    /// Return: an HTTP server named `acp.Inferise.mcp_server` carrying the bearer token; propagates allocation failure.
    pub fn server(self: *const Self, arena: std.mem.Allocator) acp.AcpError!acp.Agent.McpServerConfig {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const headers = try arena.alloc(acp.Agent.McpEnv, 1);
        headers[0] = .{ .name = "Authorization", .value = try arena.print("Bearer {s}", .{self.token}) };
        return .{ .http = .{ .name = acp.Inferise.mcp_server, .url = self.url, .headers = headers } };
    }

    /// Adds the server to a request's `mcpServers` and trusts it in `_meta.inferise`.
    ///
    /// Every agent reads `_meta.inferise.trustedMcpServers` (Claude as
    /// `mcp__inferise`, which allows every tool the server provides, Codex by
    /// server name); a native agent that does not ignores it.
    ///
    /// Parameters:
    /// - `self`: the offer.
    /// - `arena`: owns everything added.
    /// - `params`: the request's params, extended in place; servers and trust already there are kept.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn put(self: *const Self, arena: std.mem.Allocator, params: *std.json.ObjectMap) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const entry = try std.json.Stringify.valueAlloc(arena, try self.server(arena), acp.wire_options);
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, entry, .{}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidMessage,
        };
        try (try listIn(arena, params, "mcpServers")).append(value);

        // Added to whatever the host already trusts, never in place of it.
        const meta = try objectIn(arena, params, "_meta");
        const shared = try objectIn(arena, meta, acp.Inferise.key);
        try appendUnique(try listIn(arena, shared, acp.Inferise.trusted_mcp_servers), acp.Inferise.mcp_server);
    }

    fn listIn(arena: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8) !*std.json.Array {
        const slot = try object.getOrPut(arena, key);
        if (!slot.found_existing or slot.value_ptr.* != .array) slot.value_ptr.* = .{ .array = std.json.Array.init(arena) };
        return &slot.value_ptr.array;
    }

    /// The object an object holds under a key, putting an empty one there when it holds none.
    ///
    /// Parameters:
    /// - `arena`: owns anything put.
    /// - `object`: the object.
    /// - `key`: the member.
    ///
    /// Return: the inner object, in place; propagates allocation failure.
    fn objectIn(arena: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8) !*std.json.ObjectMap {
        const slot = try object.getOrPut(arena, key);
        if (!slot.found_existing or slot.value_ptr.* != .object) slot.value_ptr.* = .{ .object = .empty };
        return &slot.value_ptr.object;
    }

    /// Appends a string to an array unless the array already holds it.
    ///
    /// Parameters:
    /// - `array`: the array, grown in place.
    /// - `text`: the string; borrowed for the array's lifetime.
    ///
    /// Return: nothing; propagates allocation failure.
    fn appendUnique(array: *std.json.Array, text: []const u8) !void {
        for (array.items) |item| if (item == .string and std.mem.eql(u8, item.string, text)) return;
        try array.append(.{ .string = text });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(McpOffer);
}

test "an offer adds its server beside the host's, and trusts it in _meta.inferise" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const offer = McpOffer{ .url = "http://127.0.0.1:4000/mcp", .token = "t0k" };

    var claude = (try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"cwd\":\".\",\"mcpServers\":[{\"name\":\"git\",\"command\":\"mcp-git\"}],\"_meta\":{\"inferise\":{\"trustedMcpServers\":[\"git\"]}}}", .{})).object;
    try offer.put(arena, &claude);
    try offer.put(arena, &claude);
    const servers = claude.get("mcpServers").?.array.items;
    try std.testing.expectEqualStrings("http", servers[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("Bearer t0k", servers[1].object.get("headers").?.array.items[0].object.get("value").?.string);
    const trusted = claude.get("_meta").?.object.get("inferise").?.object.get("trustedMcpServers").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), trusted.len);
    try std.testing.expectEqualStrings("git", trusted[0].string);
    try std.testing.expectEqualStrings(acp.Inferise.mcp_server, trusted[1].string);
    try std.testing.expect(claude.get("_meta").?.object.get("zigclaude") == null);

    var native: std.json.ObjectMap = .empty;
    try offer.put(arena, &native);
    try std.testing.expectEqual(@as(usize, 1), native.get("_meta").?.object.get("inferise").?.object.get("trustedMcpServers").?.array.items.len);
}
