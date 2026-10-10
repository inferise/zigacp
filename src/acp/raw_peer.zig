//! JSON-RPC 2.0 over a `Transport`, keeping every value raw.
//!
//! A proxy needs its peer's messages as `std.json.Value`: results carry fields
//! and `_meta` extensions to relay or lift, and errors are relayed as they
//! came. `Connection.request` decodes into a type and turns an error reply
//! into `error.PeerError`. So this peer returns the **whole parsed frame**,
//! which owns everything the caller reads, and the caller `deinit`s it.
//!
//! Otherwise it behaves like `Connection`: `request` sends, then reads frames
//! until its answer arrives, dispatching the peer's requests and notifications
//! met on the way to the handlers set here. A request with no handler, or
//! one the handler does not know, is answered `method_not_found`, never left
//! unanswered, because an unanswered request stalls the peer.

const std = @import("std");
const log = std.log.scoped(.acp_raw_peer);
const mod = @import("module.zig");
const schema = @import("acp-schema");

/// One parsed message, owning everything its accessors return.
pub const RawMessage = struct {
    const Self = @This();

    parsed: std.json.Parsed(std.json.Value),

    /// Releases the message and every value read from it.
    ///
    /// Parameters:
    /// - `self`: the message.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        self.parsed.deinit();
    }

    /// Borrows a top-level member.
    ///
    /// Parameters:
    /// - `self`: the message.
    /// - `key`: `result`, `error`, `params`, `method` or `id`.
    ///
    /// Return: the member, borrowed from the message; null when absent.
    pub fn get(self: *const Self, key: []const u8) ?std.json.Value {
        return switch (self.parsed.value) {
            .object => |object| object.get(key),
            else => null,
        };
    }

    /// Borrows the result of a successful response.
    ///
    /// Parameters:
    /// - `self`: the message.
    ///
    /// Return: the result, borrowed; `error.PeerError` on an error reply; `error.InvalidMessage` if neither.
    pub fn result(self: *const Self) error{ PeerError, InvalidMessage }!std.json.Value {
        if (self.get("error") != null) return error.PeerError;
        return self.get("result") orelse error.InvalidMessage;
    }
};

/// A JSON-RPC peer over one transport.
pub const RawPeer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    transport: mod.Transport,
    next_id: i64 = 1,
    /// Answers the peer's requests. Without one, every request is answered
    /// `method_not_found`.
    request_handler: ?mod.RequestHandler = null,
    /// Consumes the peer's notifications. Without one, they are dropped.
    notification_handler: ?mod.NotificationHandler = null,

    /// Builds a peer over a transport.
    ///
    /// Parameters:
    /// - `allocator`: backs every frame and message; stored.
    /// - `transport`: the channel; borrowed, the caller closes it.
    ///
    /// Return: the peer; never fails (error union by convention).
    pub fn init(allocator: std.mem.Allocator, transport: mod.Transport) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return Self{ .allocator = allocator, .transport = transport };
    }

    /// Releases the peer.
    ///
    /// Parameters:
    /// - `self`: the peer.
    ///
    /// Return: nothing; the transport is the caller's.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        _ = self;
    }

    /// Sends a request and waits for its answer, dispatching peer messages met on the way.
    ///
    /// Parameters:
    /// - `self`: the peer.
    /// - `method`: the method.
    /// - `params`: anything `std.json.Stringify` accepts, including a `std.json.Value`.
    ///
    /// Return: the response, caller `deinit`s it; propagates transport failures and `error.InvalidMessage`.
    pub fn request(self: *Self, method: []const u8, params: anytype) !RawMessage {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const id = try self.sendRequest(method, params);

        // Peer requests met before the answer are dispatched here, so the peer
        // can ask for a permission mid-turn and still be answered.
        while (true) {
            var message = try self.readMessage();
            var keep = false;
            defer if (!keep) message.deinit();

            const method_value = message.get("method");
            const id_value = message.get("id");

            if (method_value == null) {
                if (id_value) |value| {
                    if (value == .integer and value.integer == id) {
                        keep = true;
                        return message;
                    }
                }
                log.warn("dropping a response nobody is waiting for", .{});
                continue;
            }

            const name = switch (method_value.?) {
                .string => |s| s,
                else => return error.InvalidMessage,
            };
            if (id_value) |value| {
                try self.dispatchRequest(value, name, message.get("params") orelse .null);
            } else {
                self.dispatchNotification(name, message.get("params") orelse .null);
            }
        }
    }

    /// Sends a request without waiting, for a caller that matches the answer by id elsewhere.
    ///
    /// Parameters:
    /// - `self`: the peer.
    /// - `method`: the method.
    /// - `params`: anything `std.json.Stringify` accepts.
    ///
    /// Return: the request's id; propagates transport failures.
    pub fn sendRequest(self: *Self, method: []const u8, params: anytype) !i64 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const id = self.next_id;
        self.next_id += 1;

        var buffer: std.Io.Writer.Allocating = .init(self.allocator);
        defer buffer.deinit();
        const writer = &buffer.writer;
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
        try std.json.Stringify.value(method, .{}, writer);
        try writer.writeAll(",\"params\":");
        try std.json.Stringify.value(params, mod.wire_options, writer);
        try writer.writeAll("}");
        try self.transport.writeFrame(.{ .bytes = buffer.written() });
        return id;
    }

    /// Sends a notification.
    ///
    /// Parameters:
    /// - `self`: the peer.
    /// - `method`: the method.
    /// - `params`: anything `std.json.Stringify` accepts.
    ///
    /// Return: nothing; propagates transport failures.
    pub fn notify(self: *Self, method: []const u8, params: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var buffer: std.Io.Writer.Allocating = .init(self.allocator);
        defer buffer.deinit();
        const writer = &buffer.writer;
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
        try std.json.Stringify.value(method, .{}, writer);
        try writer.writeAll(",\"params\":");
        try std.json.Stringify.value(params, mod.wire_options, writer);
        try writer.writeAll("}");
        try self.transport.writeFrame(.{ .bytes = buffer.written() });
    }

    /// Reads and parses one frame.
    ///
    /// Parameters:
    /// - `self`: the peer.
    ///
    /// Return: the message, caller `deinit`s it; `error.TransportClosed` at end; `error.InvalidMessage`.
    pub fn readMessage(self: *Self) !RawMessage {
        const frame = try self.transport.readFrame(self.allocator);
        defer self.allocator.free(frame);
        return parseMessage(self.allocator, frame);
    }

    /// Parses one frame into an owned message.
    ///
    /// Parameters:
    /// - `allocator`: backs the message.
    /// - `frame`: the bytes; copied.
    ///
    /// Return: the message, caller `deinit`s it; `error.InvalidMessage` when not a JSON object.
    pub fn parseMessage(allocator: std.mem.Allocator, frame: []const u8) !RawMessage {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, frame, .{ .allocate = .alloc_always }) catch
            return error.InvalidMessage;
        if (parsed.value != .object) {
            parsed.deinit();
            return error.InvalidMessage;
        }
        return RawMessage{ .parsed = parsed };
    }

    /// Answers one request from the peer.
    ///
    /// Parameters:
    /// - `self`: the peer.
    /// - `id`: the request's id, echoed back.
    /// - `method`: the method.
    /// - `params`: the parameters; borrowed.
    ///
    /// Return: nothing; propagates transport failures.
    fn dispatchRequest(self: *Self, id: std.json.Value, method: []const u8, params: std.json.Value) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // Every request gets an answer, handler failures included: an
        // unanswered request stalls the peer.
        const handler = self.request_handler orelse return self.writeError(id, schema.@"error".method_not_found, "method not found");

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const answer = handler.handle(arena.allocator(), method, params) catch |err| switch (err) {
            error.MethodNotFound => {
                log.warn("answering {s} with method_not_found", .{method});
                return self.writeError(id, schema.@"error".method_not_found, "method not found");
            },
            error.InvalidParams => return self.writeError(id, schema.@"error".invalid_params, "invalid params"),
            else => return self.writeError(id, schema.@"error".internal_error, "internal error"),
        };

        try self.writeResult(id, answer);
    }

    /// Answers one of the peer's requests with a result.
    ///
    /// Parameters:
    /// - `self`: the peer.
    /// - `id`: the request's id, echoed back as it came.
    /// - `result`: anything `std.json.Stringify` accepts.
    ///
    /// Return: nothing; propagates transport failures.
    pub fn writeResult(self: *Self, id: std.json.Value, result: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var buffer: std.Io.Writer.Allocating = .init(self.allocator);
        defer buffer.deinit();
        const writer = &buffer.writer;
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.writeAll(",\"result\":");
        try std.json.Stringify.value(result, mod.wire_options, writer);
        try writer.writeAll("}");
        try self.transport.writeFrame(.{ .bytes = buffer.written() });
    }

    /// Hands one of the peer's notifications to the handler.
    ///
    /// Parameters:
    /// - `self`: the peer.
    /// - `method`: the method.
    /// - `params`: the parameters; borrowed.
    ///
    /// Return: nothing.
    fn dispatchNotification(self: *Self, method: []const u8, params: std.json.Value) void {
        const handler = self.notification_handler orelse return;
        // Failures are only logged: a notification has no reply to carry them.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        handler.handle(arena.allocator(), method, params) catch |err| {
            log.warn("notification handler failed for {s} [{t}]", .{ method, err });
        };
    }

    /// Answers one of the peer's requests with an error.
    ///
    /// Parameters:
    /// - `self`: the peer.
    /// - `id`: the request id being answered.
    /// - `code`: the JSON-RPC error code.
    /// - `message`: the error text.
    ///
    /// Return: nothing; propagates transport failures.
    pub fn writeError(self: *Self, id: std.json.Value, code: i32, message: []const u8) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var buffer: std.Io.Writer.Allocating = .init(self.allocator);
        defer buffer.deinit();
        const writer = &buffer.writer;
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
        try std.json.Stringify.value(message, .{}, writer);
        try writer.writeAll("}}");
        try self.transport.writeFrame(.{ .bytes = buffer.written() });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RawPeer);
    std.testing.refAllDecls(RawMessage);
}

test "rpc returns a result that outlives the read that produced it" {
    // The value must stay valid until the caller releases the message.
    const allocator = std.testing.allocator;
    var peer = mod.ScriptedPeer{ .allocator = allocator, .replies = &.{
        \\{"jsonrpc":"2.0","id":1,"result":{"sessionId":"s-1","_meta":{"x":[1,2]}}}
    } };
    defer peer.deinit();

    var rpc = try RawPeer.init(allocator, peer.transport());
    defer rpc.deinit();

    var response = try rpc.request("session/new", .{ .cwd = "/tmp" });
    defer response.deinit();
    const result = try response.result();
    try std.testing.expectEqualStrings("s-1", result.object.get("sessionId").?.string);
}

test "rpc answers the peer's unhandled requests instead of leaving them hanging" {
    const allocator = std.testing.allocator;
    var peer = mod.ScriptedPeer{ .allocator = allocator, .replies = &.{
        \\{"jsonrpc":"2.0","id":"g-7","method":"_example/ask","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{}}
    } };
    defer peer.deinit();

    var rpc = try RawPeer.init(allocator, peer.transport());
    defer rpc.deinit();

    var response = try rpc.request("session/prompt", .{});
    defer response.deinit();

    // The first frame out is the prompt; the second answers the peer's request, by its own id.
    try std.testing.expectEqual(@as(usize, 2), peer.sent.items.len);
    try std.testing.expect(std.mem.find(u8, peer.sent.items[1], "\"id\":\"g-7\"") != null);
    try std.testing.expect(std.mem.find(u8, peer.sent.items[1], "-32601") != null);
}

test "rpc keeps the peer's error for relaying" {
    const allocator = std.testing.allocator;
    var peer = mod.ScriptedPeer{ .allocator = allocator, .replies = &.{
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"usage limit reached"}}
    } };
    defer peer.deinit();

    var rpc = try RawPeer.init(allocator, peer.transport());
    defer rpc.deinit();

    var response = try rpc.request("session/prompt", .{});
    defer response.deinit();
    try std.testing.expectError(error.PeerError, response.result());
    try std.testing.expectEqualStrings("usage limit reached", response.get("error").?.object.get("message").?.string);
}
