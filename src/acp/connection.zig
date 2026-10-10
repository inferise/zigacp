//! Synchronous JSON-RPC connection.
//!
//! Owns a transport, a request handler, and a notification handler. Drives
//! the loop in two modes: `serve()` reads frames forever and dispatches them;
//! `request()` sends a request and pumps frames until the matching response
//! arrives, dispatching any incoming requests / notifications in the
//! interim. No threads, no background tasks — the caller drives.

const std = @import("std");
const log = std.log.scoped(.acp_connection);
const mod = @import("module.zig");
const schema = @import("acp-schema");

/// How outgoing params are written. ACP marks most optional fields absent-or-set,
/// not nullable (`additionalDirectories`, `terminal`, `mcpCapabilities`), so an
/// unset optional is left out rather than written as `null`.
pub const wire_options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

/// A JSON-RPC error, as a handler's failure is answered.
pub const ErrorReply = struct {
    const Self = @This();

    code: i32,
    message: []const u8,
};

pub const Connection = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    transport: mod.Transport,
    request_handler: ?mod.RequestHandler = null,
    notification_handler: ?mod.NotificationHandler = null,
    trace: ?*mod.TraceBuffer = null,
    next_id: i64 = 1,

    /// What one turn of `pumpPending` did.
    pub const Pumped = enum {
        /// A frame was read and dispatched.
        dispatched,
        /// Nothing was waiting.
        idle,
        /// This transport cannot be polled; use `pumpOne` or wait some other way.
        unsupported,
    };

    /// Borrow `transport`. The Connection does not take ownership; the
    /// caller is responsible for closing it when the connection ends.
    pub fn init(allocator: std.mem.Allocator, transport: mod.Transport) Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return .{ .allocator = allocator, .transport = transport };
    }

    /// Install the handler invoked for every inbound request. Without one,
    /// requests are answered with method-not-found.
    pub fn setRequestHandler(self: *Self, h: mod.RequestHandler) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.request_handler = h;
    }

    /// Install the handler invoked for every inbound notification. Without
    /// one, notifications are silently dropped (per JSON-RPC).
    pub fn setNotificationHandler(self: *Self, h: mod.NotificationHandler) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.notification_handler = h;
    }

    /// Attach a trace buffer. Every frame the connection writes or reads
    /// is recorded into the buffer with its direction. Diagnostics-only;
    /// trace failures do not propagate.
    pub fn setTraceBuffer(self: *Self, buffer: *mod.TraceBuffer) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.trace = buffer;
    }

    /// Send a notification (no response expected).
    pub fn notify(self: *Self, method: []const u8, params: anytype) mod.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        const w = &buf.writer;

        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":") catch return error.OutOfMemory;
        std.json.Stringify.value(method, .{}, w) catch return error.OutOfMemory;
        w.writeAll(",\"params\":") catch return error.OutOfMemory;
        std.json.Stringify.value(params, wire_options, w) catch return error.OutOfMemory;
        w.writeAll("}") catch return error.OutOfMemory;

        try self.writeTraced(buf.written());
    }

    /// Send a request, then pump frames until the matching response arrives.
    /// Incoming requests and notifications during the wait are dispatched.
    pub fn request(self: *Self, comptime ResultT: type, method: []const u8, params: anytype) mod.AcpError!std.json.Parsed(ResultT) {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const id = self.next_id;
        self.next_id += 1;

        {
            var buf: std.Io.Writer.Allocating = .init(self.allocator);
            defer buf.deinit();
            const w = &buf.writer;
            w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id}) catch return error.OutOfMemory;
            std.json.Stringify.value(method, .{}, w) catch return error.OutOfMemory;
            w.writeAll(",\"params\":") catch return error.OutOfMemory;
            std.json.Stringify.value(params, wire_options, w) catch return error.OutOfMemory;
            w.writeAll("}") catch return error.OutOfMemory;
            try self.writeTraced(buf.written());
        }

        // Pump frames until we see id == our id.
        while (true) {
            const frame_bytes = try self.readTraced();
            defer self.allocator.free(frame_bytes);

            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame_bytes, .{}) catch {
                return error.InvalidMessage;
            };
            defer parsed.deinit();

            const obj = switch (parsed.value) {
                .object => |o| o,
                else => return error.InvalidMessage,
            };

            // Response to our request? Only a frame without a `method` can be:
            // the two peers number their requests independently, so a request
            // the peer sends meanwhile may carry the very id we are waiting on.
            if (obj.get("id")) |id_v| {
                if (obj.get("method") == null and matchId(id_v, id)) {
                    if (obj.get("error")) |err_v| {
                        log.warn("peer error: {f}", .{std.json.fmt(err_v, .{})});
                        return error.PeerError;
                    }
                    const result_v = obj.get("result") orelse return error.InvalidMessage;
                    return ownedResult(ResultT, self.allocator, result_v);
                }
                // Not our response — could be an incoming request from peer.
                if (obj.get("method")) |m_v| {
                    if (m_v != .string) return error.InvalidMessage;
                    try self.dispatchRequest(id_v, m_v.string, obj.get("params") orelse .null);
                    continue;
                }
                // Unknown response id — drop.
                continue;
            }

            // No id: notification.
            if (obj.get("method")) |m_v| {
                if (m_v != .string) return error.InvalidMessage;
                try self.dispatchNotification(m_v.string, obj.get("params") orelse .null);
                continue;
            }

            return error.InvalidMessage;
        }
    }

    /// Read one frame and dispatch it. Returns `error.TransportClosed` on EOF.
    pub fn pumpOne(self: *Self) mod.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const frame_bytes = try self.readTraced();
        defer self.allocator.free(frame_bytes);
        return self.dispatchFrame(frame_bytes);
    }

    /// Dispatch a frame if one is already waiting, without ever blocking.
    ///
    /// For a caller that is itself inside a handler and cannot give the serve
    /// loop back yet: an agent running a turn calls this between polls so a
    /// `session/cancel` arriving mid-turn is read and acted on rather than
    /// sitting unread until the turn it was meant to stop has finished.
    ///
    /// Dispatch is re-entrant, exactly as it already is inside `request`.
    pub fn pumpPending(self: *Self) mod.AcpError!Pumped {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (!self.transport.canPoll()) return .unsupported;

        const frame_bytes = try self.transport.tryReadFrame(self.allocator) orelse return .idle;
        defer self.allocator.free(frame_bytes);

        if (self.trace) |t| t.push(.inbound, frame_bytes) catch |err| {
            log.warn("trace push (inbound) failed: {s}", .{@errorName(err)});
        };

        try self.dispatchFrame(frame_bytes);
        return .dispatched;
    }

    /// Drive `pumpOne` in a loop until the transport closes.
    pub fn serve(self: *Self) mod.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        while (true) {
            self.pumpOne() catch |err| switch (err) {
                error.TransportClosed => return,
                else => return err,
            };
        }
    }

    /// What a handler's failure is answered with: its own code and a message saying what went wrong, so a host can
    /// tell a request it got wrong from an agent that has gone.
    ///
    /// Exhaustive on purpose: a new `AcpError` member has to choose its code here rather than fall into "internal error".
    ///
    /// Parameters:
    /// - `err`: the handler's error.
    ///
    /// Return: the code and message to send.
    pub fn errorReply(err: mod.AcpError) ErrorReply {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return switch (err) {
            error.MethodNotFound => .{ .code = schema.@"error".method_not_found, .message = "method not found" },
            error.InvalidParams => .{ .code = schema.@"error".invalid_params, .message = "invalid params" },
            error.SessionNotFound => .{ .code = schema.@"error".session_not_found, .message = "session not found" },
            error.AgentGone => .{ .code = schema.@"error".agent_gone, .message = "the agent is not running" },
            error.InvalidMessage,
            error.PeerError,
            error.TransportClosed,
            error.TransportFailed,
            error.OutOfMemory,
            => .{ .code = schema.@"error".internal_error, .message = "internal error" },
        };
    }

    fn writeTraced(self: *Self, bytes: []const u8) mod.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (self.trace) |t| t.push(.outbound, bytes) catch |err| {
            log.warn("trace push (outbound) failed: {s}", .{@errorName(err)});
        };
        try self.transport.writeFrame(.{ .bytes = bytes });
    }

    fn readTraced(self: *Self) mod.AcpError![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const bytes = try self.transport.readFrame(self.allocator);
        if (self.trace) |t| t.push(.inbound, bytes) catch |err| {
            log.warn("trace push (inbound) failed: {s}", .{@errorName(err)});
        };
        return bytes;
    }

    /// Parse one frame and route it to the right handler.
    fn dispatchFrame(self: *Self, frame_bytes: []const u8) mod.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame_bytes, .{}) catch {
            return error.InvalidMessage;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidMessage,
        };

        if (obj.get("method")) |m_v| {
            if (m_v != .string) return error.InvalidMessage;
            const params = obj.get("params") orelse .null;
            if (obj.get("id")) |id_v| {
                try self.dispatchRequest(id_v, m_v.string, params);
            } else {
                try self.dispatchNotification(m_v.string, params);
            }
            return;
        }
        // Stray response with no live request — ignore.
    }

    fn dispatchRequest(self: *Self, id_v: std.json.Value, method: []const u8, params: std.json.Value) mod.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const handler = self.request_handler orelse {
            try self.writeError(id_v, schema.@"error".method_not_found, "method not found");
            return;
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const result = handler.handle(arena.allocator(), method, params) catch |err| {
            const reply = errorReply(err);
            try self.writeError(id_v, reply.code, reply.message);
            return;
        };
        try self.writeResult(id_v, result);
    }

    fn dispatchNotification(self: *Self, method: []const u8, params: std.json.Value) mod.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const handler = self.notification_handler orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        handler.handle(arena.allocator(), method, params) catch |err| {
            log.warn("notification handler failed for '{s}': {s}", .{ method, @errorName(err) });
        };
    }

    fn writeResult(self: *Self, id_v: std.json.Value, result: std.json.Value) mod.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        const w = &buf.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return error.OutOfMemory;
        std.json.Stringify.value(id_v, .{}, w) catch return error.OutOfMemory;
        w.writeAll(",\"result\":") catch return error.OutOfMemory;
        std.json.Stringify.value(result, .{}, w) catch return error.OutOfMemory;
        w.writeAll("}") catch return error.OutOfMemory;
        try self.writeTraced(buf.written());
    }

    fn writeError(self: *Self, id_v: std.json.Value, code: i32, message: []const u8) mod.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        const w = &buf.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return error.OutOfMemory;
        std.json.Stringify.value(id_v, .{}, w) catch return error.OutOfMemory;
        w.print(",\"error\":{{\"code\":{d},\"message\":", .{code}) catch return error.OutOfMemory;
        std.json.Stringify.value(message, .{}, w) catch return error.OutOfMemory;
        w.writeAll("}}") catch return error.OutOfMemory;
        try self.writeTraced(buf.written());
    }
};

/// Decodes a reply's result into a value that owns everything it holds.
///
/// Parameters:
/// - `ResultT`: the result's type; a `std.json.Value` or `RawValue` in it is kept whole.
/// - `allocator`: backs the result's arena.
/// - `result_v`: the result, borrowed from a frame about to be freed.
///
/// Return: the result, caller `deinit`s it; `error.InvalidParams` when it does not fit `ResultT`.
fn ownedResult(comptime ResultT: type, allocator: std.mem.Allocator, result_v: std.json.Value) mod.AcpError!std.json.Parsed(ResultT) {
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    // `parseFromValue` copies strings but not a `Value`, which would then point
    // into the frame; decoding from a copy in the result's own arena keeps both.
    const copy = try schema.serde_util.cloneValue(arena.allocator(), result_v);
    // Lenient exactly as inbound params already are (`typed.zig`): a peer
    // adding a field — a newer schema, or its own `_meta` extras — must not
    // turn a good reply into `InvalidParams`.
    const value = std.json.parseFromValueLeaky(ResultT, arena.allocator(), copy, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    return .{ .arena = arena, .value = value };
}

fn matchId(v: std.json.Value, id: i64) bool {
    return switch (v) {
        .integer => |i| i == id,
        else => false,
    };
}

comptime {
    _ = schema;
}

// -----------------------------------------------------------------------------
// Unit Tests

test "a handler's failure is answered with its own code and a message that says what went wrong" {
    try std.testing.expectEqual(@as(i32, -32602), Connection.errorReply(error.InvalidParams).code);
    try std.testing.expectEqual(@as(i32, -32010), Connection.errorReply(error.AgentGone).code);
    try std.testing.expectEqualStrings("the agent is not running", Connection.errorReply(error.AgentGone).message);
    try std.testing.expectEqual(@as(i32, -32002), Connection.errorReply(error.SessionNotFound).code);
    try std.testing.expectEqual(@as(i32, -32603), Connection.errorReply(error.OutOfMemory).code);
}

test "a request's raw result outlives the frame it arrived in" {
    const allocator = std.testing.allocator;
    var peer = mod.ScriptedPeer{ .allocator = allocator, .replies = &.{
        \\{"jsonrpc":"2.0","id":1,"result":{"sessionId":"s-1","_meta":{"x":{"deep":["kept"]}}}}
    } };
    defer peer.deinit();

    var connection = Connection.init(allocator, peer.transport());
    const answer = try connection.request(std.json.Value, "session/new", .{ .cwd = "/tmp" });
    defer answer.deinit();
    const deep = answer.value.object.get("_meta").?.object.get("x").?.object.get("deep").?.array.items[0];
    try std.testing.expectEqualStrings("kept", deep.string);
    // The params went out without null optionals.
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":\"/tmp\"}}", peer.sent.items[0]);
}
