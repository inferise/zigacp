//! A read-only view over one MCP server a client asked the agent to bridge.

const std = @import("std");
const log = std.log.scoped(.acp_mcp_server);
const mod = @import("module.zig");

/// One MCP server from `session/new` or `session/load`, borrowed from the request.
pub const McpServer = struct {
    const Self = @This();

    /// The server as the wire described it; borrowed, must outlive the view.
    config: *const mod.schema.McpServerConfig,

    /// Creates a view over one server.
    ///
    /// Parameters:
    /// - `config`: the server; borrowed, must outlive the view.
    ///
    /// Return: the view, caller stores it and calls `deinit`; never fails today.
    pub fn init(config: *const mod.schema.McpServerConfig) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const self = Self{ .config = config };
        return self;
    }

    /// Releases the view; the server it borrows is untouched.
    ///
    /// Parameters:
    /// - `self`: the view.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        _ = self;
    }

    /// Returns the server's name.
    ///
    /// Parameters:
    /// - `self`: the view.
    ///
    /// Return: the name, or null for an `unknown` entry that carries no string `name`.
    pub fn name(self: *const Self) ?[]const u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return switch (self.config.*) {
            .stdio => |s| s.name,
            .http, .sse => |r| r.name,
            .unknown => |raw| blk: {
                if (raw.value != .object) break :blk null;
                const v = raw.value.object.get("name") orelse break :blk null;
                break :blk if (v == .string) v.string else null;
            },
        };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "every shape answers its name, and an unknown one when it has a string name" {
    const allocator = std.testing.allocator;
    const src =
        \\[{"name":"git","command":"mcp-git"},{"type":"http","name":"web","url":"http://h/mcp"},{"type":"ws","name":"later"},{"type":"ws"}]
    ;
    const parsed = try std.json.parseFromSlice([]const mod.schema.McpServerConfig, allocator, src, .{});
    defer parsed.deinit();

    const expected = [_]?[]const u8{ "git", "web", "later", null };
    for (parsed.value, expected) |*config, want| {
        var server = try McpServer.init(config);
        defer server.deinit();
        if (want) |w| try std.testing.expectEqualStrings(w, server.name().?) else try std.testing.expect(server.name() == null);
    }
}
