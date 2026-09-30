//! Synchronous JSON-RPC connection.
//!
//! Owns a transport, a request handler, and a notification handler. Drives
//! the loop in two modes: `serve()` reads frames forever and dispatches them;
//! `request()` sends a request and pumps frames until the matching response
//! arrives, dispatching any incoming requests / notifications in the
//! interim. No threads, no background tasks — the caller drives.

const std = @import("std");
const schema = @import("acp-schema");
const AcpError = @import("errors.zig").AcpError;
const Transport = @import("transport.zig").Transport;
const RequestHandler = @import("handler.zig").RequestHandler;
const NotificationHandler = @import("handler.zig").NotificationHandler;
const TraceBuffer = @import("trace.zig").Buffer;

const log = std.log.scoped(.acp_connection);

pub const Connection = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    request_handler: ?RequestHandler = null,
    notification_handler: ?NotificationHandler = null,
    trace: ?*TraceBuffer = null,
    next_id: i64 = 1,

    /// Borrow `transport`. The Connection does not take ownership; the
    /// caller is responsible for closing it when the connection ends.
    pub fn init(allocator: std.mem.Allocator, transport: Transport) Connection {
        return .{ .allocator = allocator, .transport = transport };
    }

    /// Install the handler invoked for every inbound request. Without one,
    /// requests are answered with method-not-found.
    pub fn setRequestHandler(self: *Connection, h: RequestHandler) void {
        self.request_handler = h;
    }

    /// Install the handler invoked for every inbound notification. Without
    /// one, notifications are silently dropped (per JSON-RPC).
    pub fn setNotificationHandler(self: *Connection, h: NotificationHandler) void {
        self.notification_handler = h;
    }

    /// Attach a trace buffer. Every frame the connection writes or reads
    /// is recorded into the buffer with its direction. Diagnostics-only;
    /// trace failures do not propagate.
    pub fn setTraceBuffer(self: *Connection, buffer: *TraceBuffer) void {
        self.trace = buffer;
    }

    fn writeTraced(self: *Connection, bytes: []const u8) AcpError!void {
        if (self.trace) |t| t.push(.outbound, bytes) catch |err| {
            log.warn("trace push (outbound) failed: {s}", .{@errorName(err)});
        };
        try self.transport.writeFrame(.{ .bytes = bytes });
    }

    fn readTraced(self: *Connection) AcpError![]u8 {
        const bytes = try self.transport.readFrame(self.allocator);
        if (self.trace) |t| t.push(.inbound, bytes) catch |err| {
            log.warn("trace push (inbound) failed: {s}", .{@errorName(err)});
        };
        return bytes;
    }

    /// Send a notification (no response expected).
    pub fn notify(self: *Connection, method: []const u8, params: anytype) AcpError!void {
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        const w = &buf.writer;

        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":") catch return error.OutOfMemory;
        std.json.Stringify.value(method, .{}, w) catch return error.OutOfMemory;
        w.writeAll(",\"params\":") catch return error.OutOfMemory;
        std.json.Stringify.value(params, .{}, w) catch return error.OutOfMemory;
        w.writeAll("}") catch return error.OutOfMemory;

        try self.writeTraced(buf.written());
    }

    /// Send a request, then pump frames until the matching response arrives.
    /// Incoming requests and notifications during the wait are dispatched.
    pub fn request(self: *Connection, comptime ResultT: type, method: []const u8, params: anytype) AcpError!std.json.Parsed(ResultT) {
        const id = self.next_id;
        self.next_id += 1;

        {
            var buf: std.Io.Writer.Allocating = .init(self.allocator);
            defer buf.deinit();
            const w = &buf.writer;
            w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id}) catch return error.OutOfMemory;
            std.json.Stringify.value(method, .{}, w) catch return error.OutOfMemory;
            w.writeAll(",\"params\":") catch return error.OutOfMemory;
            std.json.Stringify.value(params, .{}, w) catch return error.OutOfMemory;
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

            // Response to our request?
            if (obj.get("id")) |id_v| {
                if (matchId(id_v, id)) {
                    if (obj.get("error")) |err_v| {
                        log.warn("peer error: {f}", .{std.json.fmt(err_v, .{})});
                        return error.PeerError;
                    }
                    const result_v = obj.get("result") orelse return error.InvalidMessage;
                    // Lenient exactly as inbound params already are (`typed.zig`):
                    // a peer adding a field — a newer schema, or its own `_meta`
                    // extras — must not turn a good reply into `InvalidParams`.
                    return std.json.parseFromValue(ResultT, self.allocator, result_v, .{ .ignore_unknown_fields = true }) catch
                        return error.InvalidParams;
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
    pub fn pumpOne(self: *Connection) AcpError!void {
        const frame_bytes = try self.readTraced();
        defer self.allocator.free(frame_bytes);
        return self.dispatchFrame(frame_bytes);
    }

    /// What one turn of `pumpPending` did.
    pub const Pumped = enum {
        /// A frame was read and dispatched.
        dispatched,
        /// Nothing was waiting.
        idle,
        /// This transport cannot be polled; use `pumpOne` or wait some other way.
        unsupported,
    };

    /// Dispatch a frame if one is already waiting, without ever blocking.
    ///
    /// For a caller that is itself inside a handler and cannot give the serve
    /// loop back yet: an agent running a turn calls this between polls so a
    /// `session/cancel` arriving mid-turn is read and acted on rather than
    /// sitting unread until the turn it was meant to stop has finished.
    ///
    /// Dispatch is re-entrant, exactly as it already is inside `request`.
    pub fn pumpPending(self: *Connection) AcpError!Pumped {
        if (!self.transport.canPoll()) return .unsupported;

        const frame_bytes = try self.transport.tryReadFrame(self.allocator) orelse return .idle;
        defer self.allocator.free(frame_bytes);

        if (self.trace) |t| t.push(.inbound, frame_bytes) catch |err| {
            log.warn("trace push (inbound) failed: {s}", .{@errorName(err)});
        };

        try self.dispatchFrame(frame_bytes);
        return .dispatched;
    }

    /// Parse one frame and route it to the right handler.
    fn dispatchFrame(self: *Connection, frame_bytes: []const u8) AcpError!void {
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

    /// Drive `pumpOne` in a loop until the transport closes.
    pub fn serve(self: *Connection) AcpError!void {
        while (true) {
            self.pumpOne() catch |err| switch (err) {
                error.TransportClosed => return,
                else => return err,
            };
        }
    }

    fn dispatchRequest(self: *Connection, id_v: std.json.Value, method: []const u8, params: std.json.Value) AcpError!void {
        const handler = self.request_handler orelse {
            try self.writeError(id_v, -32601, "method not found");
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

    /// A JSON-RPC error, as a handler's failure is answered.
    pub const ErrorReply = struct {
        code: i32,
        message: []const u8,
    };

    /// Code for a request to a session whose agent has exited — distinct so a host can offer to start it again
    /// rather than read it as a request it got wrong. In the implementation-defined server range.
    pub const code_agent_gone: i32 = -32010;

    /// Code for a session id nothing answers to — ACP's `resource_not_found`.
    pub const code_resource_not_found: i32 = -32002;

    /// What a handler's failure is answered with: its own code and a message saying what went wrong, so a host can
    /// tell a request it got wrong from an agent that has gone.
    ///
    /// Parameters:
    /// - `err`: the handler's error.
    ///
    /// Return: the code and message to send.
    pub fn errorReply(err: anyerror) ErrorReply {
        return switch (err) {
            error.MethodNotFound => .{ .code = -32601, .message = "method not found" },
            error.InvalidParams => .{ .code = -32602, .message = "invalid params" },
            error.SessionNotFound => .{ .code = code_resource_not_found, .message = "session not found" },
            error.AgentGone => .{ .code = code_agent_gone, .message = "the agent is not running" },
            else => .{ .code = -32603, .message = "internal error" },
        };
    }

    fn dispatchNotification(self: *Connection, method: []const u8, params: std.json.Value) AcpError!void {
        const handler = self.notification_handler orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        handler.handle(arena.allocator(), method, params) catch |err| {
            log.warn("notification handler failed for '{s}': {s}", .{ method, @errorName(err) });
        };
    }

    fn writeResult(self: *Connection, id_v: std.json.Value, result: std.json.Value) AcpError!void {
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

    fn writeError(self: *Connection, id_v: std.json.Value, code: i32, message: []const u8) AcpError!void {
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

fn matchId(v: std.json.Value, id: i64) bool {
    return switch (v) {
        .integer => |i| i == id,
        else => false,
    };
}

comptime {
    _ = schema;
}

test "a handler's failure is answered with its own code and a message that says what went wrong" {
    try std.testing.expectEqual(@as(i32, -32602), Connection.errorReply(error.InvalidParams).code);
    try std.testing.expectEqual(Connection.code_agent_gone, Connection.errorReply(error.AgentGone).code);
    try std.testing.expectEqualStrings("the agent is not running", Connection.errorReply(error.AgentGone).message);
    try std.testing.expectEqual(Connection.code_resource_not_found, Connection.errorReply(error.SessionNotFound).code);
    try std.testing.expectEqual(@as(i32, -32603), Connection.errorReply(error.OutOfMemory).code);
}
