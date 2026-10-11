//! A host's own MCP server, over Streamable HTTP on loopback.
//!
//! Every agent here can reach an HTTP MCP server — Claude through
//! `--mcp-config`, Codex through a thread's `config.mcp_servers`, a native ACP
//! agent through `session/new`'s `mcpServers` — so one listener on
//! `127.0.0.1` serves them all. Each session gets its own bearer token; a
//! request without one that the host issued is refused before it is read.
//!
//! The tools are the host's: it hands the server a table (`ToolDefinition`) and
//! answers each call by name, so the server knows no tool of its own.
//!
//! Only what the tools need is spoken: `initialize`, `tools/list`,
//! `tools/call` and `ping` answer as JSON; notifications are accepted with
//! `202`; `GET` (the optional server-sent stream) is `405`; anything else is a
//! JSON-RPC `method not found`. Observed against Claude Code 2.1.281 — which
//! also sends `server/discover` first and falls back — and Codex 0.153.4.
//!
//! Each connection runs on its own task, because `ask_user` holds its
//! request open until a person answers, and nothing else may wait on that.

const std = @import("std");
const log = std.log.scoped(.acp_mcp_http_server);
const mod = @import("module.zig");
const acp = @import("acp");

/// One tool as `tools/list` returns it.
pub const ToolDefinition = struct {
    /// The name the agent calls it by.
    name: []const u8,
    description: []const u8,
    /// The JSON Schema of the arguments, as text.
    input_schema: []const u8,
};

/// What the server says about itself in `initialize`.
pub const ServerInfo = struct {
    /// The server's name, which an agent also prefixes its tools with (`mcp__<name>__…`).
    name: []const u8,
    version: []const u8,
};

/// What a tool call came back with.
pub const McpToolOutcome = struct {
    /// The text the agent reads as the tool's result.
    text: []const u8,
    /// Whether the call failed, which the agent sees as an error result.
    is_error: bool = false,
};

/// Whoever answers the tools — a relay, or a client offering its own.
pub const McpToolHost = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Whether a bearer token is one this host issued.
        knows: *const fn (ctx: *anyopaque, token: []const u8) bool,
        /// Runs a tool for the session the token belongs to; may block, e.g. on a person.
        call: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, token: []const u8, name: []const u8, arguments: std.json.Value) acp.AcpError!McpToolOutcome,
        /// The tools this host answers, which are all `tools/list` offers.
        tools: *const fn (ctx: *anyopaque) []const ToolDefinition,
    };

    /// Reports whether a token is one the host issued.
    ///
    /// Parameters:
    /// - `self`: the host.
    /// - `token`: the bearer token a request carried.
    ///
    /// Return: true when it names a session.
    pub fn knows(self: Self, token: []const u8) bool {
        return self.vtable.knows(self.ptr, token);
    }

    /// Runs a tool.
    ///
    /// Parameters:
    /// - `self`: the host.
    /// - `arena`: owns the outcome's text.
    /// - `token`: which session is calling.
    /// - `name`: the tool, one the host listed.
    /// - `arguments`: the call's arguments.
    ///
    /// Return: the outcome; propagates the host's failures.
    pub fn call(self: Self, arena: std.mem.Allocator, token: []const u8, name: []const u8, arguments: std.json.Value) acp.AcpError!McpToolOutcome {
        return self.vtable.call(self.ptr, arena, token, name, arguments);
    }

    /// Lists the tools the host answers.
    ///
    /// Parameters:
    /// - `self`: the host.
    ///
    /// Return: the tool table, static.
    pub fn tools(self: Self) []const ToolDefinition {
        return self.vtable.tools(self.ptr);
    }
};

/// The listener and its connections.
pub const McpHttpServer = struct {
    const Self = @This();

    /// The newest protocol revision spoken; an older one a client asks for is echoed.
    pub const protocol_version = "2025-11-25";
    /// Revisions a client may ask for and get back.
    const supported_versions = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26" };
    /// A request body larger than this is refused; tool arguments are short.
    const max_body_len = 1024 * 1024;

    allocator: std.mem.Allocator,
    io: std.Io,
    host: McpToolHost,
    /// What `initialize` answers with; borrowed, must outlive the server.
    info: ServerInfo,
    server: std.Io.net.Server,
    /// The port the kernel chose.
    port: u16,
    /// The accept loop. Exactly one releaser, which is `deinit`.
    accept_group: std.Io.Group = .init,
    /// Every connection's task, cancelled together at `deinit`.
    connection_group: std.Io.Group = .init,

    /// Listens on an ephemeral loopback port; call `start` to accept.
    ///
    /// Parameters:
    /// - `allocator`: backs the server and each request; must outlive it.
    /// - `io`: IO capability for sockets and tasks.
    /// - `host`: who answers the tools; borrowed, must outlive the server.
    /// - `info`: the name and version `initialize` answers with; borrowed, must outlive the server.
    ///
    /// Return: the server at a stable address, caller calls `deinit`; `error.TransportFailed` when it cannot listen.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, host: McpToolHost, info: ServerInfo) acp.AcpError!*Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const address: std.Io.net.IpAddress = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch return error.TransportFailed;
        var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
            log.warn("MCP server cannot listen [{t}]", .{err});
            return error.TransportFailed;
        };
        errdefer server.deinit(io);

        const self = try allocator.create(Self);
        self.* = Self{ .allocator = allocator, .io = io, .host = host, .info = info, .server = server, .port = server.socket.address.getPort() };
        log.info("MCP server listening on 127.0.0.1:{d}", .{self.port});
        return self;
    }

    /// Stops accepting, ends every connection, and frees the server.
    ///
    /// Parameters:
    /// - `self`: the server; invalid afterwards.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // Cancelling interrupts the accept and every connection's read; the
        // listener is closed only once nothing is using it.
        self.accept_group.cancel(self.io);
        self.connection_group.cancel(self.io);
        self.server.deinit(self.io);
        self.allocator.destroy(self);
    }

    /// Starts accepting connections.
    ///
    /// Parameters:
    /// - `self`: the server.
    ///
    /// Return: nothing; `error.TransportFailed` when the accept loop cannot run beside the caller.
    pub fn start(self: *Self) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // `concurrent`, never `async`: the loop returns only at `deinit`.
        self.accept_group.concurrent(self.io, acceptLoop, .{self}) catch return error.TransportFailed;
    }

    /// The URL an agent is given for its session.
    ///
    /// Parameters:
    /// - `self`: the server.
    /// - `arena`: owns the text.
    ///
    /// Return: `http://127.0.0.1:<port>/mcp`; propagates allocation failure.
    pub fn url(self: *const Self, arena: std.mem.Allocator) acp.AcpError![]const u8 {
        return arena.print("http://127.0.0.1:{d}/mcp", .{self.port});
    }

    /// Accepts until the listener is closed or the task is cancelled.
    ///
    /// Parameters:
    /// - `self`: the server.
    ///
    /// Return: nothing.
    fn acceptLoop(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        while (true) {
            const stream = self.server.accept(self.io) catch |err| {
                if (err != error.Canceled) log.warn("accept failed; no more MCP connections [{t}]", .{err});
                return;
            };
            self.connection_group.concurrent(self.io, serveConnection, .{ self, stream }) catch {
                log.warn("no task for an MCP connection; closing it", .{});
                stream.close(self.io);
            };
        }
    }

    /// Serves one connection's requests until it closes.
    ///
    /// Parameters:
    /// - `self`: the server.
    /// - `stream`: the connection; closed on return.
    ///
    /// Return: nothing; a failure ends the connection.
    fn serveConnection(self: *Self, stream: std.Io.net.Stream) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        defer stream.close(self.io);

        // SAFETY: filled by the reader before any byte of it is read.
        var read_buffer: [16 * 1024]u8 = undefined;
        // SAFETY: filled by the writer before it is flushed.
        var write_buffer: [16 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        var writer = stream.writer(self.io, &write_buffer);
        var http = std.http.Server.init(&reader.interface, &writer.interface);

        while (true) {
            var request = http.receiveHead() catch return;
            const keep = request.head.keep_alive;
            self.serveRequest(&request) catch |err| {
                log.warn("MCP request failed [{t}]", .{err});
                return;
            };
            if (!keep) return;
        }
    }

    /// Answers one HTTP request.
    ///
    /// Parameters:
    /// - `self`: the server.
    /// - `request`: the request, head read.
    ///
    /// Return: nothing; propagates write failures.
    fn serveRequest(self: *Self, request: *std.http.Server.Request) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // The token is copied before the body is read: reading invalidates the head.
        const token = try arena.dupe(u8, bearerToken(request) orelse "");
        if (!self.host.knows(token)) return request.respond("", .{ .status = .unauthorized, .keep_alive = false });

        switch (request.head.method) {
            .POST => {},
            .GET => return request.respond("", .{ .status = .method_not_allowed, .extra_headers = &.{.{ .name = "allow", .value = "POST, DELETE" }} }),
            .DELETE => return request.respond("", .{}),
            else => return request.respond("", .{ .status = .method_not_allowed }),
        }

        const length = request.head.content_length orelse 0;
        if (length > max_body_len) return request.respond("", .{ .status = .payload_too_large, .keep_alive = false });
        // SAFETY: the body reader fills it before reading from it.
        var body_buffer: [4096]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buffer);
        const body = try body_reader.allocRemaining(arena, .limited(max_body_len));

        const message = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
            return self.respondJson(request, try errorReply(arena, .null, -32700, "parse error"));
        if (message != .object) return self.respondJson(request, try errorReply(arena, .null, -32600, "invalid request"));

        // A notification — `notifications/initialized`, a cancellation — wants no body.
        const id = message.object.get("id") orelse return request.respond("", .{ .status = .accepted });
        const method = switch (message.object.get("method") orelse .null) {
            .string => |s| s,
            else => return self.respondJson(request, try errorReply(arena, id, -32600, "invalid request")),
        };
        const params = message.object.get("params") orelse .null;
        return self.respondJson(request, try self.dispatch(arena, token, id, method, params));
    }

    /// Answers one JSON-RPC request.
    ///
    /// Parameters:
    /// - `self`: the server.
    /// - `arena`: per-request scratch.
    /// - `token`: which session is asking.
    /// - `id`: the request's id.
    /// - `method`: the method.
    /// - `params`: the params, or null.
    ///
    /// Return: the reply's JSON text; propagates allocation failure.
    fn dispatch(self: *Self, arena: std.mem.Allocator, token: []const u8, id: std.json.Value, method: []const u8, params: std.json.Value) ![]const u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (std.mem.eql(u8, method, "initialize")) {
            const asked = if (params == .object) (if (params.object.get("protocolVersion")) |v| (if (v == .string) v.string else null) else null) else null;
            var version: []const u8 = protocol_version;
            if (asked) |wanted| for (supported_versions) |supported| {
                if (std.mem.eql(u8, supported, wanted)) version = supported;
            };
            return reply(arena, id, try arena.print("{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"{s}\",\"version\":\"{s}\"}}}}", .{ version, self.info.name, self.info.version }));
        }
        if (std.mem.eql(u8, method, "ping")) return reply(arena, id, "{}");
        if (std.mem.eql(u8, method, "tools/list")) return reply(arena, id, try toolList(arena, self.host.tools()));
        if (std.mem.eql(u8, method, "tools/call")) {
            if (params != .object) return errorReply(arena, id, -32602, "invalid params");
            const name = switch (params.object.get("name") orelse .null) {
                .string => |s| s,
                else => return errorReply(arena, id, -32602, "invalid params"),
            };
            // A tool the host does not offer is as unknown as one nobody does.
            const offered = for (self.host.tools()) |definition| {
                if (std.mem.eql(u8, definition.name, name)) break true;
            } else false;
            if (!offered) return errorReply(arena, id, -32602, "unknown tool");
            const arguments = params.object.get("arguments") orelse std.json.Value{ .object = .empty };
            const outcome = self.host.call(arena, token, name, arguments) catch |err| McpToolOutcome{
                .text = try arena.print("The tool failed: {t}", .{err}),
                .is_error = true,
            };
            const text = try std.json.Stringify.valueAlloc(arena, outcome.text, .{});
            return reply(arena, id, try arena.print("{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"isError\":{}}}", .{ text, outcome.is_error }));
        }
        return errorReply(arena, id, -32601, "method not found");
    }

    /// Writes a JSON reply.
    ///
    /// Parameters:
    /// - `self`: the server.
    /// - `request`: the request being answered.
    /// - `body`: the JSON text.
    ///
    /// Return: nothing; propagates write failures.
    fn respondJson(self: *Self, request: *std.http.Server.Request, body: []const u8) !void {
        _ = self;
        return request.respond(body, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }

    /// `tools/list`'s result, from the host's tool table.
    ///
    /// Parameters:
    /// - `arena`: owns the text.
    /// - `table`: the tools the host answers.
    ///
    /// Return: the result's JSON text; propagates allocation failure.
    fn toolList(arena: std.mem.Allocator, table: []const ToolDefinition) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("{\"tools\":[");
        for (table, 0..) |definition, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.print("{{\"name\":\"{s}\",\"description\":", .{definition.name});
            try std.json.Stringify.value(definition.description, .{}, &out.writer);
            try out.writer.print(",\"inputSchema\":{s}}}", .{definition.input_schema});
        }
        try out.writer.writeAll("]}");
        return out.written();
    }

    /// A JSON-RPC result reply.
    ///
    /// Parameters:
    /// - `arena`: owns the text.
    /// - `id`: the request's id.
    /// - `result`: the result's JSON text.
    ///
    /// Return: the reply's JSON text; propagates allocation failure.
    fn reply(arena: std.mem.Allocator, id: std.json.Value, result: []const u8) ![]const u8 {
        return arena.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ try std.json.Stringify.valueAlloc(arena, id, .{}), result });
    }

    /// A JSON-RPC error reply.
    ///
    /// Parameters:
    /// - `arena`: owns the text.
    /// - `id`: the request's id, or null.
    /// - `code`: the error code.
    /// - `message`: what went wrong.
    ///
    /// Return: the reply's JSON text; propagates allocation failure.
    fn errorReply(arena: std.mem.Allocator, id: std.json.Value, code: i32, message: []const u8) ![]const u8 {
        return arena.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ try std.json.Stringify.valueAlloc(arena, id, .{}), code, message });
    }

    /// Reads the bearer token off a request.
    ///
    /// Parameters:
    /// - `request`: the request.
    ///
    /// Return: the token, borrowed from the head; null when absent.
    fn bearerToken(request: *const std.http.Server.Request) ?[]const u8 {
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
            const prefix = "Bearer ";
            if (header.value.len > prefix.len and std.ascii.eqlIgnoreCase(header.value[0..prefix.len], prefix)) return header.value[prefix.len..];
        }
        return null;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(McpHttpServer);
}

/// A host for the server test: one token, and a report that echoes its summary.
const TestHost = struct {
    const valid = "test-token";

    fn knows(_: *anyopaque, token: []const u8) bool {
        return std.mem.eql(u8, token, valid);
    }

    fn call(_: *anyopaque, arena: std.mem.Allocator, _: []const u8, name: []const u8, arguments: std.json.Value) acp.AcpError!McpToolOutcome {
        const summary = arguments.object.get("summary").?.string;
        return .{ .text = try arena.print("{s}: {s}", .{ name, summary }) };
    }

    fn tools(_: *anyopaque) []const ToolDefinition {
        return &mod.RelayTools.table;
    }

    const vtable: McpToolHost.VTable = .{ .knows = knows, .call = call, .tools = tools };
};

/// Sends one HTTP POST and returns the response body.
///
/// Parameters:
/// - `allocator`: owns the body.
/// - `port`: the server's port.
/// - `token`: the bearer token, or null to send none.
/// - `body`: the JSON-RPC message.
///
/// Return: the status and body; propagates connection failures.
fn post(allocator: std.mem.Allocator, port: u16, token: ?[]const u8, body: []const u8) !struct { status: u16, body: []u8 } {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = try .parse("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    // SAFETY: filled by the writer before it is flushed.
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print("POST /mcp HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: application/json\r\nconnection: close\r\ncontent-length: {d}\r\n", .{body.len});
    if (token) |t| try writer.interface.print("authorization: Bearer {s}\r\n", .{t});
    try writer.interface.print("\r\n{s}", .{body});
    try writer.interface.flush();

    // SAFETY: filled by the reader before any byte of it is read.
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const response = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(response);

    const status = try std.fmt.parseInt(u16, response[9..12], 10);
    const split = std.mem.find(u8, response, "\r\n\r\n") orelse return error.NoBody;
    return .{ .status = status, .body = try allocator.dupe(u8, response[split + 4 ..]) };
}

test "the server lists its tools, runs one for a known token, and refuses an unknown one" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var host_state: u8 = 0;
    const server = try McpHttpServer.init(allocator, io, .{ .ptr = &host_state, .vtable = &TestHost.vtable }, .{ .name = "inferise", .version = "0.0.0" });
    defer server.deinit();
    try server.start();

    const refused = try post(allocator, server.port, "wrong", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}");
    defer allocator.free(refused.body);
    try std.testing.expectEqual(@as(u16, 401), refused.status);

    const init_reply = try post(allocator, server.port, TestHost.valid, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}");
    defer allocator.free(init_reply.body);
    try std.testing.expect(std.mem.find(u8, init_reply.body, "\"protocolVersion\":\"2025-06-18\"") != null);

    const listed = try post(allocator, server.port, TestHost.valid, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    defer allocator.free(listed.body);
    try std.testing.expect(std.mem.find(u8, listed.body, "\"name\":\"report_progress\"") != null);
    try std.testing.expect(std.mem.find(u8, listed.body, "\"name\":\"ask_user\"") != null);

    const called = try post(allocator, server.port, TestHost.valid, "{\"jsonrpc\":\"2.0\",\"id\":\"c\",\"method\":\"tools/call\",\"params\":{\"name\":\"report_progress\",\"arguments\":{\"summary\":\"halfway\"}}}");
    defer allocator.free(called.body);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"c\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"report_progress: halfway\"}],\"isError\":false}}", called.body);

    const unknown = try post(allocator, server.port, TestHost.valid, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"server/discover\"}");
    defer allocator.free(unknown.body);
    try std.testing.expect(std.mem.find(u8, unknown.body, "-32601") != null);

    const notified = try post(allocator, server.port, TestHost.valid, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    defer allocator.free(notified.body);
    try std.testing.expectEqual(@as(u16, 202), notified.status);
}
