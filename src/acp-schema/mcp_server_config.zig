//! External MCP servers a client asks the agent to bridge into a session.
//!
//! ACP v1 has three shapes: stdio (`command`, `args`, `env`, and no `type`),
//! and `http` / `sse` (`type`, `url`, `headers`). Each is its own variant with
//! its own required fields, so a stdio server always has a command and a
//! network server always has a URL. A shape this revision doesn't know lands in
//! `unknown` rather than failing the whole `session/new`, so an agent skips a
//! server it can't bridge instead of refusing the session over it.
//!
//! These are the wire types and their codec only; what an agent does with a
//! server lives in `acp-mcp`.

const std = @import("std");
const log = std.log.scoped(.acp_schema_mcp_server_config);
const mod = @import("module.zig");

/// A name/value pair: an environment variable for stdio, a header for HTTP / SSE.
pub const McpEnv = struct {
    const Self = @This();

    name: []const u8,
    value: []const u8,
};

/// An MCP server the agent launches as a subprocess and speaks to over its stdio.
pub const McpServerStdio = struct {
    const Self = @This();

    name: []const u8,
    /// The executable.
    command: []const u8,
    args: []const []const u8 = &.{},
    env: []const McpEnv = &.{},
};

/// An MCP server the agent reaches over the network, as Streamable HTTP or SSE.
pub const McpServerRemote = struct {
    const Self = @This();

    name: []const u8,
    /// Where the server listens.
    url: []const u8,
    headers: []const McpEnv = &.{},
};

/// One MCP server, tagged on the wire by `type` (absent for stdio).
pub const McpServerConfig = union(enum) {
    const Self = @This();

    stdio: McpServerStdio,
    http: McpServerRemote,
    sse: McpServerRemote,
    /// Forward-compat: a transport this revision doesn't model, or an entry missing what its shape requires.
    unknown: mod.RawValue,

    /// Parses a variant's payload from everything but `type`.
    ///
    /// Parameters:
    /// - `T`: the payload type.
    /// - `allocator`: owns everything parsed.
    /// - `source`: the server object.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the payload, or null when the object doesn't fit the shape; propagates allocation failure.
    fn parseVariant(comptime T: type, allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) error{OutOfMemory}!?T {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var fields: std.json.ObjectMap = .empty;
        try fields.ensureTotalCapacity(allocator, source.object.count());
        var it = source.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "type")) continue;
            fields.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        }
        return std.json.parseFromValueLeaky(T, allocator, .{ .object = fields }, options) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
    }

    /// Keeps an entry this revision can't bridge, so the session still opens without it.
    ///
    /// Parameters:
    /// - `source`: the server object.
    /// - `kind`: its transport, as the wire named it.
    ///
    /// Return: the `unknown` variant.
    fn keepUnknown(source: std.json.Value, kind: []const u8) Self {
        log.debug("{s}:{d} :: {s} [type={s}]", .{ @src().file, @src().line, @src().fn_name, kind });

        return .{ .unknown = .{ .value = source } };
    }

    /// Writes a network server with its `type` ahead of its fields.
    ///
    /// Parameters:
    /// - `jw`: the JSON writer.
    /// - `kind`: the wire `type`.
    /// - `remote`: the server.
    ///
    /// Return: nothing; propagates the writer's failure.
    fn writeRemote(jw: anytype, comptime kind: []const u8, remote: *const McpServerRemote) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(kind);
        try jw.objectField("name");
        try jw.write(remote.name);
        try jw.objectField("url");
        try jw.write(remote.url);
        try jw.objectField("headers");
        try jw.write(remote.headers);
        try jw.endObject();
    }

    /// Writes the server in its wire shape, with `type` first for a network server.
    ///
    /// Parameters:
    /// - `self`: the server.
    /// - `jw`: the JSON writer.
    ///
    /// Return: nothing; propagates the writer's failure.
    pub fn jsonStringify(self: *const Self, jw: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        switch (self.*) {
            .stdio => |*s| try jw.write(s.*),
            .http => |*r| try writeRemote(jw, "http", r),
            .sse => |*r| try writeRemote(jw, "sse", r),
            .unknown => |raw| try jw.write(raw),
        }
    }

    /// Parses one server from a token stream.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the token stream.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the server; propagates a parse failure.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, value, options);
    }

    /// Parses one server from a JSON value, routing on `type`.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the JSON value.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the server, `unknown` for a shape this revision can't bridge; `error.UnexpectedToken` when it isn't an object.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (source != .object) return error.UnexpectedToken;

        const kind: []const u8 = if (source.object.get("type")) |t| switch (t) {
            .string => |s| s,
            else => return .{ .unknown = .{ .value = source } },
        } else "stdio";

        if (std.mem.eql(u8, kind, "stdio")) {
            const stdio = try parseVariant(McpServerStdio, allocator, source, options) orelse return keepUnknown(source, kind);
            return .{ .stdio = stdio };
        }
        if (std.mem.eql(u8, kind, "http")) {
            const remote = try parseVariant(McpServerRemote, allocator, source, options) orelse return keepUnknown(source, kind);
            return .{ .http = remote };
        }
        if (std.mem.eql(u8, kind, "sse")) {
            const remote = try parseVariant(McpServerRemote, allocator, source, options) orelse return keepUnknown(source, kind);
            return .{ .sse = remote };
        }
        return keepUnknown(source, kind);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "a stdio server parses without a type" {
    const src =
        \\{"name":"git","command":"mcp-git","args":["--repo","."],"env":[{"name":"K","value":"v"}]}
    ;
    const parsed = try std.json.parseFromSlice(McpServerConfig, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("mcp-git", parsed.value.stdio.command);
    try std.testing.expectEqualStrings("v", parsed.value.stdio.env[0].value);
}

test "an HTTP server parses beside a stdio one" {
    const src =
        \\[{"type":"http","name":"inferise","url":"http://127.0.0.1:4000/mcp","headers":[{"name":"Authorization","value":"Bearer t"}]},{"name":"git","command":"mcp-git"}]
    ;
    const parsed = try std.json.parseFromSlice([]const McpServerConfig, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Bearer t", parsed.value[0].http.headers[0].value);
    try std.testing.expectEqualStrings("mcp-git", parsed.value[1].stdio.command);
    try std.testing.expectEqual(@as(usize, 0), parsed.value[1].stdio.args.len);
}

test "an unknown transport or a stdio entry with no command is kept, not refused" {
    const src =
        \\[{"type":"ws","name":"later","url":"ws://x"},{"name":"broken"}]
    ;
    const parsed = try std.json.parseFromSlice([]const McpServerConfig, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value[0] == .unknown);
    try std.testing.expect(parsed.value[1] == .unknown);
}

test "an SSE server round-trips with its type" {
    const server: McpServerConfig = .{ .sse = .{ .name = "s", .url = "http://h/sse" } };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, server, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"type\":\"sse\",\"name\":\"s\",\"url\":\"http://h/sse\",\"headers\":[]}", out);

    const back = try std.json.parseFromSlice(McpServerConfig, std.testing.allocator, out, .{});
    defer back.deinit();
    try std.testing.expectEqualStrings("http://h/sse", back.value.sse.url);
}
