//! Typed request dispatch.
//!
//! Wraps a string-keyed `RequestHandler` so callers can register
//! per-method handlers with concrete param/result types. The wrapper
//! parses the inbound `std.json.Value` into the declared param type,
//! invokes the typed handler, and serialises the result back into
//! `std.json.Value` against the dispatcher's arena.

const std = @import("std");
const AcpError = @import("errors.zig").AcpError;
const handler_mod = @import("handler.zig");
const RequestHandler = handler_mod.RequestHandler;
const NotificationHandler = handler_mod.NotificationHandler;

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    request_entries: std.ArrayList(RequestEntry) = .empty,
    notification_entries: std.ArrayList(NotificationEntry) = .empty,

    pub const RequestEntry = struct {
        method: []const u8,
        ptr: *anyopaque,
        thunk: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, params: std.json.Value) AcpError!std.json.Value,
    };

    pub const NotificationEntry = struct {
        method: []const u8,
        ptr: *anyopaque,
        thunk: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, params: std.json.Value) AcpError!void,
    };

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.request_entries.deinit(self.allocator);
        self.notification_entries.deinit(self.allocator);
    }

    /// Register a typed request handler.
    ///
    /// `Handler` is an instance type that defines `pub const Params = ...`,
    /// `pub const Result = ...`, and `pub fn handle(self, allocator,
    /// params: Params) AcpError!Result`.
    pub fn registerRequest(self: *Dispatcher, method: []const u8, comptime Handler: type, instance: *Handler) !void {
        const Thunk = struct {
            fn invoke(ctx: *anyopaque, allocator: std.mem.Allocator, params: std.json.Value) AcpError!std.json.Value {
                const inst: *Handler = @ptrCast(@alignCast(ctx));
                const parsed = std.json.parseFromValueLeaky(
                    Handler.Params,
                    allocator,
                    params,
                    .{ .ignore_unknown_fields = true },
                ) catch return error.InvalidParams;
                const result = try inst.handle(allocator, parsed);
                return marshal(allocator, result);
            }
        };
        try self.request_entries.append(self.allocator, .{
            .method = method,
            .ptr = instance,
            .thunk = Thunk.invoke,
        });
    }

    pub fn registerNotification(self: *Dispatcher, method: []const u8, comptime Handler: type, instance: *Handler) !void {
        const Thunk = struct {
            fn invoke(ctx: *anyopaque, allocator: std.mem.Allocator, params: std.json.Value) AcpError!void {
                const inst: *Handler = @ptrCast(@alignCast(ctx));
                const parsed = std.json.parseFromValueLeaky(
                    Handler.Params,
                    allocator,
                    params,
                    .{ .ignore_unknown_fields = true },
                ) catch return error.InvalidParams;
                try inst.handle(allocator, parsed);
            }
        };
        try self.notification_entries.append(self.allocator, .{
            .method = method,
            .ptr = instance,
            .thunk = Thunk.invoke,
        });
    }

    /// Register a request handler as a context and a function, with no handler type.
    ///
    /// `f` is `fn (@TypeOf(context), std.mem.Allocator, Params) AcpError!Result`;
    /// `Params` and `Result` are read from its signature. `context` is a pointer
    /// the dispatcher keeps, and the params are decoded leniently.
    pub fn registerRequestFn(self: *Dispatcher, method: []const u8, context: anytype, comptime f: anytype) !void {
        const Params = ParamsOf(@TypeOf(context), f);
        const Thunk = struct {
            fn invoke(ctx: *anyopaque, allocator: std.mem.Allocator, params: std.json.Value) AcpError!std.json.Value {
                const parsed = std.json.parseFromValueLeaky(Params, allocator, params, .{ .ignore_unknown_fields = true }) catch return error.InvalidParams;
                const result = try f(@as(@TypeOf(context), @ptrCast(@alignCast(ctx))), allocator, parsed);
                return marshal(allocator, result);
            }
        };
        try self.request_entries.append(self.allocator, .{
            .method = method,
            .ptr = @ptrCast(@constCast(context)),
            .thunk = Thunk.invoke,
        });
    }

    /// Register a notification handler as a context and a function, with no handler type.
    ///
    /// `f` is `fn (@TypeOf(context), std.mem.Allocator, Params) AcpError!void`.
    pub fn registerNotificationFn(self: *Dispatcher, method: []const u8, context: anytype, comptime f: anytype) !void {
        const Params = ParamsOf(@TypeOf(context), f);
        const Thunk = struct {
            fn invoke(ctx: *anyopaque, allocator: std.mem.Allocator, params: std.json.Value) AcpError!void {
                const parsed = std.json.parseFromValueLeaky(Params, allocator, params, .{ .ignore_unknown_fields = true }) catch return error.InvalidParams;
                try f(@as(@TypeOf(context), @ptrCast(@alignCast(ctx))), allocator, parsed);
            }
        };
        try self.notification_entries.append(self.allocator, .{
            .method = method,
            .ptr = @ptrCast(@constCast(context)),
            .thunk = Thunk.invoke,
        });
    }

    /// View of this dispatcher as a `RequestHandler` for `Connection.setRequestHandler`.
    pub fn requestHandler(self: *Dispatcher) RequestHandler {
        return .{ .ptr = self, .vtable = &request_vtable };
    }

    /// View of this dispatcher as a `NotificationHandler` for `Connection.setNotificationHandler`.
    pub fn notificationHandler(self: *Dispatcher) NotificationHandler {
        return .{ .ptr = self, .vtable = &notification_vtable };
    }

    fn handleRequest(ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) AcpError!std.json.Value {
        const self: *Dispatcher = @ptrCast(@alignCast(ctx));
        for (self.request_entries.items) |entry| {
            if (std.mem.eql(u8, entry.method, method)) {
                return entry.thunk(entry.ptr, allocator, params);
            }
        }
        return error.MethodNotFound;
    }

    fn handleNotification(ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) AcpError!void {
        const self: *Dispatcher = @ptrCast(@alignCast(ctx));
        for (self.notification_entries.items) |entry| {
            if (std.mem.eql(u8, entry.method, method)) {
                return entry.thunk(entry.ptr, allocator, params);
            }
        }
        // Unhandled notifications are silently dropped — that's the
        // JSON-RPC contract for notifications.
    }
};

/// The params type of a handler function taking `(Context, std.mem.Allocator, Params)`.
fn ParamsOf(comptime Context: type, comptime f: anytype) type {
    if (@typeInfo(Context) != .pointer) @compileError("a handler's context must be a pointer");
    const info = @typeInfo(@TypeOf(f)).@"fn";
    if (info.param_types.len != 3) @compileError("a handler takes (context, allocator, params)");
    return info.param_types[2].?;
}

const request_vtable: RequestHandler.VTable = .{ .handle = Dispatcher.handleRequest };
const notification_vtable: NotificationHandler.VTable = .{ .handle = Dispatcher.handleNotification };

/// Stringify a value into a `std.json.Value` whose payload lives in
/// `allocator` (typically the per-dispatch arena).
pub fn marshal(allocator: std.mem.Allocator, value: anytype) AcpError!std.json.Value {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    // Unset optionals are left out, as `Connection` leaves them out of params.
    std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &buf.writer) catch return error.OutOfMemory;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, buf.written(), .{}) catch
        return error.InvalidMessage;
    return parsed;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const EchoHandler = struct {
    last_seen: ?i64 = null,

    pub const Params = struct { n: i64 };
    pub const Result = struct { n: i64 };

    pub fn handle(self: *EchoHandler, _: std.mem.Allocator, params: Params) AcpError!Result {
        self.last_seen = params.n;
        return .{ .n = params.n + 1 };
    }
};

const PingHandler = struct {
    count: u32 = 0,

    pub const Params = struct { tag: []const u8 };

    pub fn handle(self: *PingHandler, _: std.mem.Allocator, params: Params) AcpError!void {
        _ = params;
        self.count += 1;
    }
};

test "Dispatcher routes typed request" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    var h: EchoHandler = .{};
    try d.registerRequest("echo", EchoHandler, &h);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"n\":5}", .{});
    const handler = d.requestHandler();
    const result = try handler.handle(arena.allocator(), "echo", params);

    try std.testing.expectEqual(@as(i64, 5), h.last_seen.?);
    try std.testing.expectEqual(@as(i64, 6), result.object.get("n").?.integer);
}

test "Dispatcher returns MethodNotFound for unregistered method" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    const handler = d.requestHandler();
    try std.testing.expectError(error.MethodNotFound, handler.handle(std.testing.allocator, "missing", .null));
}

test "Dispatcher returns InvalidParams when params don't match" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    var h: EchoHandler = .{};
    try d.registerRequest("echo", EchoHandler, &h);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // n is missing
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{}", .{});
    const handler = d.requestHandler();
    try std.testing.expectError(error.InvalidParams, handler.handle(arena.allocator(), "echo", params));
}

test "Dispatcher routes typed notification" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    var h: PingHandler = .{};
    try d.registerNotification("ping", PingHandler, &h);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"tag\":\"x\"}", .{});

    const handler = d.notificationHandler();
    try handler.handle(arena.allocator(), "ping", params);
    try handler.handle(arena.allocator(), "ping", params);

    try std.testing.expectEqual(@as(u32, 2), h.count);
}

test "Dispatcher silently drops unregistered notifications" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    const handler = d.notificationHandler();
    try handler.handle(std.testing.allocator, "no/such", .null);
}

test "a context and a function register without a handler type" {
    const Agent = struct {
        const Self = @This();
        calls: usize = 0,
        fn double(self: *Self, _: std.mem.Allocator, params: struct { n: i64 }) AcpError!struct { n: i64 } {
            self.calls += 1;
            return .{ .n = params.n * 2 };
        }
        fn ping(self: *Self, _: std.mem.Allocator, _: struct {}) AcpError!void {
            self.calls += 1;
        }
    };
    var agent = Agent{};
    var dispatcher = Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    try dispatcher.registerRequestFn("double", &agent, Agent.double);
    try dispatcher.registerNotificationFn("ping", &agent, Agent.ping);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"n\":21}", .{});
    const answer = try dispatcher.requestHandler().handle(arena.allocator(), "double", params);
    try std.testing.expectEqual(@as(i64, 42), answer.object.get("n").?.integer);
    try dispatcher.notificationHandler().handle(arena.allocator(), "ping", .{ .object = .empty });
    try std.testing.expectEqual(@as(usize, 2), agent.calls);
}
