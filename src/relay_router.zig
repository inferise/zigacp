//! A multiplexing proxy's plumbing: one host, any number of agents behind it.
//!
//! A host speaks ACP to the router as to one agent; each agent behind it is a
//! **route**, reached over its own transport (typically the client end of an
//! in-process pair whose other end a `Relay.Proxy` holds). The router moves
//! frames between the host and the routes at the frame level — never a
//! dispatcher that answers one request before reading the next — so turns on
//! different routes run at once. On the way it rewrites what the two sides
//! cannot share:
//!
//! - **Session ids.** The host sees its own session (`host_session`); a route
//!   sees the agent's (`session_id`).
//! - **Request ids, host → route.** A host request the owner forwards is
//!   renumbered into the route's own id space (`reserveLocked`, `send`), and the
//!   route's reply goes back under the host's id.
//! - **Request ids, route → host.** A route's request to the host (a permission,
//!   an elicitation) is renumbered `<prefix><n>`, so two routes' ids never
//!   collide, and the host's reply goes back under the route's own.
//! - **The subagent tag.** Every frame a route sends the host carries
//!   `_meta.inferise.subagent`, the route's name.
//!
//! The owner keeps what is product: which route a prompt goes to, what a frame
//! means for its bookkeeping (`Hooks.frame`, which may rewrite or drop it), and
//! its own requests to a route (`ask`; a turn nobody blocks on is a `detached`
//! waiter). A route that goes away answers the host for everything it owed:
//! a prompt as `cancelled`, anything else as an error.
//!
//! One mutex guards the router and every route; the owner takes the same one
//! for its own tables (`mutex`), and `*Locked` methods expect it held.

const std = @import("std");
const log = std.log.scoped(.acp_relay_router);
const acp = @import("module.zig");

/// A host request sent on to a route, awaiting the route's reply.
const Forward = struct {
    const Self = @This();

    /// The host's id, as JSON text. Owned.
    host_id: []u8,
    /// Whether it is a prompt, whose reply ends one of the route's turns.
    prompt: bool,
};

/// A route's request to the host, awaiting the host's reply.
const Outbound = struct {
    const Self = @This();

    route: *RouterRoute,
    /// The route's own id, as JSON text. Owned.
    original_id: []u8,
};

/// One of the owner's own requests to a route, awaiting its reply.
pub const RouterWaiter = struct {
    const Self = @This();

    /// Set once the route answered, or went away, or the router is closing.
    done: bool = false,
    /// The reply's `result` as JSON text, or null when it failed. Owned by the router's allocator.
    result: ?[]u8 = null,
    /// A turn nobody blocks on: answered, it leaves the route's table and its running count.
    detached: bool = false,

    /// Frees the result.
    ///
    /// Parameters:
    /// - `self`: the waiter.
    /// - `allocator`: the router's allocator.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.result) |text| allocator.free(text);
        self.result = null;
    }
};

/// What becomes of a route's request or notification after the owner has seen it.
pub const RouterDisposition = enum {
    /// To the host, rewritten for it.
    forward,
    /// Nowhere: the owner has dealt with it.
    drop,
};

/// The owner's say over what a route sends; each call reaches the owner's record through `route.context`.
pub const RouterHooks = struct {
    const Self = @This();

    /// Sees a route's request or notification before it goes to the host; may rewrite it in place. Called without the mutex.
    frame: *const fn (route: *RouterRoute, arena: std.mem.Allocator, root: *std.json.Value) acp.AcpError!RouterDisposition,
};

/// One agent behind the router. The owner embeds it, initialises it with `init` and starts it with `RelayRouter.start`.
pub const RouterRoute = struct {
    const Self = @This();

    // SAFETY: set by `init`.
    router: *RelayRouter = undefined,
    /// The owner's own record of this agent, for its hooks. Borrowed.
    // SAFETY: set by `init`.
    context: *anyopaque = undefined,
    /// What the host calls it, and the subagent tag. Borrowed; must outlive the route.
    name: []const u8 = "",
    /// The host's session this route serves. Borrowed; must outlive the route.
    host_session: []const u8 = "",
    /// The route's end of its agent's transport. Borrowed.
    // SAFETY: set by `init`.
    transport: acp.Transport = undefined,
    /// The agent's own session id, once known. Owned by the router's allocator.
    session_id: ?[]u8 = null,
    /// The next id given a request to this route.
    next_id: i64 = 1,
    /// Host requests sent here, by the id the router gave them.
    forwards: std.AutoHashMapUnmanaged(i64, Forward) = .empty,
    /// The owner's own requests, by id.
    waiters: std.AutoHashMapUnmanaged(i64, *RouterWaiter) = .empty,
    /// Prompts sent and not yet answered, the owner's detached turns included.
    running: u32 = 0,
    /// Set once the route went away or the owner ended it.
    ended: bool = false,
    /// The read loop. Exactly one releaser, which is `RelayRouter.awaitRoute`.
    pump: std.Io.Group = .init,

    /// Binds a route to its router and its agent's transport.
    ///
    /// Parameters:
    /// - `router`: the router; borrowed, must outlive the route.
    /// - `context`: the owner's record of the agent, for its hooks; borrowed.
    /// - `name`: the route's name; borrowed, must outlive the route.
    /// - `host_session`: the host session it serves; borrowed, must outlive the route.
    /// - `transport`: the route's end of the agent's transport; borrowed.
    ///
    /// Return: the route; the owner stores it at a stable address, then `RelayRouter.start`s it.
    pub fn init(router: *RelayRouter, context: *anyopaque, name: []const u8, host_session: []const u8, transport: acp.Transport) Self {
        return .{ .router = router, .context = context, .name = name, .host_session = host_session, .transport = transport };
    }

    /// Releases the route's tables; its pump has stopped (`RelayRouter.awaitRoute`).
    ///
    /// Parameters:
    /// - `self`: the route.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        const allocator = self.router.allocator;
        var forwards = self.forwards.valueIterator();
        while (forwards.next()) |forward| allocator.free(forward.host_id);
        self.forwards.deinit(allocator);
        self.waiters.deinit(allocator);
        if (self.session_id) |text| allocator.free(text);
        self.session_id = null;
    }
};

/// The router between one host and its routes.
pub const RelayRouter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    /// The host's transport; borrowed.
    host: acp.Transport,
    /// The prefix of the ids a route's requests to the host are given (`zagent-`). Borrowed.
    prefix: []const u8,
    hooks: RouterHooks,

    /// Guards the router, every route, and whatever the owner keeps beside them.
    mutex: std.Io.Mutex = .init,
    /// Signalled when an owner's request is answered, a route goes away, or the router is closing.
    answered: std.Io.Condition = .init,
    /// Serialises writes to the host, which come from every route's pump.
    host_write: std.Io.Mutex = .init,
    /// Routes' requests to the host, by the id the host saw. Keys owned.
    outbound: std.StringHashMapUnmanaged(Outbound) = .empty,
    /// Numbers outbound ids and anything else the owner needs unique (`nextNumberLocked`).
    next_number: u64 = 1,
    /// Set once the host has gone: nothing waiting gets an answer, nothing new starts.
    closing: bool = false,

    /// Creates a router over the host's transport.
    ///
    /// Parameters:
    /// - `allocator`: backs every table and frame; must be safe across tasks and outlive the router.
    /// - `io`: IO capability for the pumps.
    /// - `host`: the host's transport; borrowed.
    /// - `prefix`: the prefix of the ids routes' requests to the host are given; borrowed.
    /// - `hooks`: the owner's say over routes' frames.
    ///
    /// Return: the router; the owner stores it at a stable address.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, host: acp.Transport, prefix: []const u8, hooks: RouterHooks) acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return .{ .allocator = allocator, .io = io, .host = host, .prefix = prefix, .hooks = hooks };
    }

    /// Frees the outbound table; every route has stopped.
    ///
    /// Parameters:
    /// - `self`: the router.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var outbound = self.outbound.iterator();
        while (outbound.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.original_id);
        }
        self.outbound.deinit(self.allocator);
    }

    /// Starts reading a route.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `route`: the route, initialised and at its final address.
    ///
    /// Return: nothing; `error.TransportFailed` when no task can run it.
    pub fn start(self: *Self, route: *RouterRoute) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // `concurrent`, never `async`: the pump returns only when its route closes.
        route.pump.concurrent(self.io, pumpTask, .{ self, route }) catch return error.TransportFailed;
    }

    /// Waits for a route's pump, after its transport was closed; idempotent.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `route`: the route.
    ///
    /// Return: nothing.
    pub fn awaitRoute(self: *Self, route: *RouterRoute) void {
        route.pump.await(self.io) catch |err| log.warn("{s}'s pump did not stop cleanly [{t}]", .{ route.name, err });
    }

    /// Marks the host gone: everything waiting is released; idempotent.
    ///
    /// Parameters:
    /// - `self`: the router.
    ///
    /// Return: nothing.
    pub fn close(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closing = true;
        self.answered.broadcast(self.io);
    }

    /// The next of the router's numbers; the mutex is held.
    ///
    /// Parameters:
    /// - `self`: the router.
    ///
    /// Return: a number never given before.
    pub fn nextNumberLocked(self: *Self) u64 {
        const number = self.next_number;
        self.next_number += 1;
        return number;
    }

    // -------------------------------------------------------------------------
    // Host → route

    /// Records a host request for a route and gives it the route's next id; the mutex is held.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `route`: the route.
    /// - `host_id`: the host's id for the request.
    /// - `prompt`: whether it is a prompt, counted as a running turn.
    ///
    /// Return: the route's id for it; propagates allocation failure.
    pub fn reserveLocked(self: *Self, route: *RouterRoute, host_id: std.json.Value, prompt: bool) acp.AcpError!i64 {
        const own_id = route.next_id;
        const text = std.json.Stringify.valueAlloc(self.allocator, host_id, .{}) catch return error.OutOfMemory;
        errdefer self.allocator.free(text);
        try route.forwards.put(self.allocator, own_id, .{ .host_id = text, .prompt = prompt });
        route.next_id += 1;
        if (prompt) route.running += 1;
        return own_id;
    }

    /// Takes back a reserved request that was never sent.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `route`: the route.
    /// - `own_id`: the id `reserveLocked` gave.
    ///
    /// Return: nothing.
    pub fn undo(self: *Self, route: *RouterRoute, own_id: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = route.forwards.fetchRemove(own_id) orelse return;
        self.allocator.free(removed.value.host_id);
        if (removed.value.prompt) route.running -|= 1;
    }

    /// Sends a reserved host request on to its route, in the route's session and under the route's id.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `route`: the route.
    /// - `arena`: per-frame scratch.
    /// - `root`: the request frame, rewritten in place.
    /// - `own_id`: the id `reserveLocked` gave.
    ///
    /// Return: nothing; `error.SessionNotFound` when the route has no session; propagates transport failures.
    pub fn send(self: *Self, route: *RouterRoute, arena: std.mem.Allocator, root: *std.json.Value, own_id: i64) acp.AcpError!void {
        const session_id = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk try arena.dupe(u8, route.session_id orelse return error.SessionNotFound);
        };
        if (root.* != .object) return error.InvalidMessage;
        if (root.object.getPtr("params")) |params| if (params.* == .object) try params.object.put(arena, "sessionId", .{ .string = session_id });
        try root.object.put(arena, "id", .{ .integer = own_id });
        try route.transport.writeFrame(.{ .bytes = try json(arena, root.*) });
    }

    /// Passes the host's reply to a route's request back under the route's own id.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `arena`: per-frame scratch.
    /// - `root`: the reply frame, rewritten in place.
    ///
    /// Return: true when it answered a route's request; false for a reply the router did not renumber.
    pub fn answerOutbound(self: *Self, arena: std.mem.Allocator, root: *std.json.Value) acp.AcpError!bool {
        if (root.* != .object) return false;
        const id = root.object.get("id") orelse return false;
        if (id != .string) return false;
        const removed = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk self.outbound.fetchRemove(id.string);
        } orelse return false;
        defer self.allocator.free(removed.key);
        defer self.allocator.free(removed.value.original_id);
        const original = std.json.parseFromSliceLeaky(std.json.Value, arena, removed.value.original_id, .{}) catch return error.OutOfMemory;
        try root.object.put(arena, "id", original);
        removed.value.route.transport.writeFrame(.{ .bytes = try json(arena, root.*) }) catch |err| log.warn("{s} did not get the host's answer [{t}]", .{ removed.value.route.name, err });
        return true;
    }

    /// Answers the host for every request a stopped route will never answer: a prompt as cancelled, anything else as an error.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `arena`: per-frame scratch.
    /// - `route`: the route, stopped.
    ///
    /// Return: nothing; propagates allocation and transport failures.
    pub fn abandon(self: *Self, arena: std.mem.Allocator, route: *RouterRoute) acp.AcpError!void {
        var abandoned: std.ArrayList(Forward) = .empty;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var forwards = route.forwards.valueIterator();
            while (forwards.next()) |forward| try abandoned.append(arena, forward.*);
            route.forwards.clearRetainingCapacity();
            route.running = 0;
        }
        for (abandoned.items) |forward| {
            defer self.allocator.free(forward.host_id);
            const id = std.json.parseFromSliceLeaky(std.json.Value, arena, forward.host_id, .{}) catch return error.OutOfMemory;
            if (forward.prompt) {
                var result: std.json.ObjectMap = .empty;
                try result.put(arena, "stopReason", .{ .string = "cancelled" });
                try self.replyHost(arena, id, .{ .object = result });
            } else {
                try self.replyError(arena, id, acp.ErrorCodes.internal_error, "the agent was closed");
            }
        }
    }

    /// Forgets the requests a route sent the host, for one that is freed before the host answered.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `route`: the route, stopped.
    ///
    /// Return: nothing.
    pub fn dropOutbound(self: *Self, route: *RouterRoute) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            var entries = self.outbound.iterator();
            const key = while (entries.next()) |entry| {
                if (entry.value_ptr.route == route) break entry.key_ptr.*;
            } else break;
            const removed = self.outbound.fetchRemove(key).?;
            self.allocator.free(removed.key);
            self.allocator.free(removed.value.original_id);
        }
    }

    // -------------------------------------------------------------------------
    // The owner's own requests

    /// Sends one of the owner's own requests to a route and waits for its result.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `route`: the route.
    /// - `method`: the method.
    /// - `params`: the params, as JSON text.
    ///
    /// Return: the result as JSON text, caller frees with the router's allocator; `error.PeerError` when it failed, the route went away or the router is closing.
    pub fn ask(self: *Self, route: *RouterRoute, method: []const u8, params: []const u8) acp.AcpError![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var waiter = RouterWaiter{};
        const own_id = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk try self.registerLocked(route, &waiter);
        };
        // However this ends, the waiter leaves the table before it goes out of scope.
        defer {
            self.mutex.lockUncancelable(self.io);
            _ = route.waiters.remove(own_id);
            self.mutex.unlock(self.io);
        }
        const frame = std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{s}}}", .{ own_id, std.json.fmt(method, .{}), params }) catch return error.OutOfMemory;
        defer self.allocator.free(frame);
        try route.transport.writeFrame(.{ .bytes = frame });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!waiter.done and !self.closing) self.answered.waitUncancelable(self.io, &self.mutex);
        return waiter.result orelse error.PeerError;
    }

    /// Lists one of the owner's requests to a route under the route's next id; the mutex is held.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `route`: the route.
    /// - `waiter`: what the reply is kept in; borrowed until it is done and removed. A `detached` one counts as a running turn.
    ///
    /// Return: the id to send it under; propagates allocation failure.
    pub fn registerLocked(self: *Self, route: *RouterRoute, waiter: *RouterWaiter) acp.AcpError!i64 {
        const own_id = route.next_id;
        try route.waiters.put(self.allocator, own_id, waiter);
        route.next_id += 1;
        if (waiter.detached) route.running += 1;
        return own_id;
    }

    /// Takes back one of the owner's requests that was never sent.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `route`: the route.
    /// - `own_id`: the id `registerLocked` gave.
    ///
    /// Return: the waiter, the owner's to free; null when it was not listed.
    pub fn unregister(self: *Self, route: *RouterRoute, own_id: i64) ?*RouterWaiter {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = route.waiters.fetchRemove(own_id) orelse return null;
        if (removed.value.detached) route.running -|= 1;
        return removed.value;
    }

    // -------------------------------------------------------------------------
    // To the host

    /// Writes one frame to the host, one writer at a time.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `frame`: the frame; borrowed.
    ///
    /// Return: nothing; propagates the transport's failure.
    pub fn writeHost(self: *Self, frame: []const u8) acp.AcpError!void {
        self.host_write.lockUncancelable(self.io);
        defer self.host_write.unlock(self.io);
        try self.host.writeFrame(.{ .bytes = frame });
    }

    /// Answers a host request with a result.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `arena`: per-frame scratch.
    /// - `id`: the request's id.
    /// - `result`: the result.
    ///
    /// Return: nothing; propagates allocation and transport failures.
    pub fn replyHost(self: *Self, arena: std.mem.Allocator, id: std.json.Value, result: std.json.Value) acp.AcpError!void {
        try self.writeHost(try json(arena, .{ .jsonrpc = "2.0", .id = id, .result = result }));
    }

    /// Answers a host request with an error.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `arena`: per-frame scratch.
    /// - `id`: the request's id.
    /// - `code`: the JSON-RPC error code.
    /// - `message`: what went wrong.
    ///
    /// Return: nothing; propagates allocation and transport failures.
    pub fn replyError(self: *Self, arena: std.mem.Allocator, id: std.json.Value, code: acp.ErrorCode, message: []const u8) acp.AcpError!void {
        try self.writeHost(try json(arena, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }));
    }

    /// Sends the host a `session/update` in one of its sessions, tagged with the route it is about.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `arena`: per-frame scratch.
    /// - `host_session`: the host's session.
    /// - `update`: the update.
    /// - `subagent`: the route's name, or null for the owner's own.
    ///
    /// Return: nothing; propagates allocation and transport failures.
    pub fn notifyHost(self: *Self, arena: std.mem.Allocator, host_session: []const u8, update: std.json.Value, subagent: ?[]const u8) acp.AcpError!void {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "sessionId", .{ .string = host_session });
        try object.put(arena, "update", update);
        var params: std.json.Value = .{ .object = object };
        if (subagent) |name| try tagSubagent(arena, &params, name);
        try self.writeHost(try json(arena, .{ .jsonrpc = "2.0", .method = acp.Agent.method_session_update, .params = params }));
    }

    /// Adds `_meta.inferise.subagent` to params, beside whatever the agent put under `_meta.inferise`.
    ///
    /// Parameters:
    /// - `arena`: owns anything added.
    /// - `params`: the params, rewritten in place.
    /// - `name`: the route's name.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn tagSubagent(arena: std.mem.Allocator, params: *std.json.Value, name: []const u8) acp.AcpError!void {
        if (params.* != .object) return;
        const meta = try params.object.getOrPut(arena, "_meta");
        if (!meta.found_existing or meta.value_ptr.* != .object) meta.value_ptr.* = .{ .object = .empty };
        const ours = try meta.value_ptr.object.getOrPut(arena, acp.Inferise.key);
        if (!ours.found_existing or ours.value_ptr.* != .object) ours.value_ptr.* = .{ .object = .empty };
        try ours.value_ptr.object.put(arena, acp.Inferise.subagent, .{ .string = name });
    }

    // -------------------------------------------------------------------------
    // From a route

    /// Reads a route until it closes, routing each frame; a task body.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `route`: the route.
    ///
    /// Return: nothing; once the route closes, everything waiting on it is released and the host answered.
    fn pumpTask(self: *Self, route: *RouterRoute) void {
        while (true) {
            const frame = route.transport.readFrame(self.allocator) catch break;
            defer self.allocator.free(frame);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            self.fromRoute(arena.allocator(), route, frame) catch |err| log.warn("a frame from {s} was dropped [{t}]", .{ route.name, err });
        }
        // Gone: its waiters get no answer, and the host's requests to it end.
        const closing = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            route.ended = true;
            var waiters = route.waiters.valueIterator();
            while (waiters.next()) |waiter| waiter.*.done = true;
            self.answered.broadcast(self.io);
            break :blk self.closing;
        };
        // An agent that exits on its own leaves the host's prompts to it unanswered otherwise.
        if (closing) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        self.abandon(arena.allocator(), route) catch |err| log.warn("{s}'s requests were not ended [{t}]", .{ route.name, err });
    }

    /// Routes one frame from a route: a reply to its requester, anything else past the owner to the host.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `arena`: per-frame scratch.
    /// - `route`: the route.
    /// - `frame`: the frame.
    ///
    /// Return: nothing; propagates allocation and transport failures.
    fn fromRoute(self: *Self, arena: std.mem.Allocator, route: *RouterRoute, frame: []const u8) acp.AcpError!void {
        var root = std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{}) catch return;
        if (root != .object) return;
        const id = root.object.get("id");
        const has_method = root.object.get("method") != null;

        if (!has_method) {
            const value = id orelse return;
            if (value != .integer) return;
            return self.answerRoute(arena, route, &root, value.integer);
        }

        if (try self.hooks.frame(route, arena, &root) == .drop) return;

        // A notification or a request for the host: in the host's session, tagged.
        if (root.object.getPtr("params")) |params| if (params.* == .object) {
            if (params.object.get("sessionId") != null) try params.object.put(arena, "sessionId", .{ .string = route.host_session });
            try tagSubagent(arena, params, route.name);
        };
        if (id) |original| {
            const outbound_id = blk: {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                const key = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ self.prefix, self.nextNumberLocked() }) catch return error.OutOfMemory;
                errdefer self.allocator.free(key);
                const original_text = std.json.Stringify.valueAlloc(self.allocator, original, .{}) catch return error.OutOfMemory;
                errdefer self.allocator.free(original_text);
                try self.outbound.put(self.allocator, key, .{ .route = route, .original_id = original_text });
                break :blk try arena.dupe(u8, key);
            };
            try root.object.put(arena, "id", .{ .string = outbound_id });
        }
        try self.writeHost(try json(arena, root));
    }

    /// Delivers a route's reply: to the owner's own request, or to the host under its id.
    ///
    /// Parameters:
    /// - `self`: the router.
    /// - `arena`: per-frame scratch.
    /// - `route`: the route.
    /// - `root`: the reply frame, rewritten in place.
    /// - `own_id`: the id the router gave the request.
    ///
    /// Return: nothing; propagates allocation and transport failures.
    fn answerRoute(self: *Self, arena: std.mem.Allocator, route: *RouterRoute, root: *std.json.Value, own_id: i64) acp.AcpError!void {
        const forward = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (route.waiters.get(own_id)) |waiter| {
                waiter.done = true;
                if (root.object.get("result")) |result| waiter.result = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch return error.OutOfMemory;
                // A turn nobody blocks on leaves the table here, and its running count with it.
                if (waiter.detached) {
                    _ = route.waiters.remove(own_id);
                    route.running -|= 1;
                }
                self.answered.broadcast(self.io);
                return;
            }
            const removed = route.forwards.fetchRemove(own_id) orelse return;
            if (removed.value.prompt) route.running -|= 1;
            break :blk removed.value;
        };
        defer self.allocator.free(forward.host_id);
        const host_id = std.json.parseFromSliceLeaky(std.json.Value, arena, forward.host_id, .{}) catch return error.OutOfMemory;
        try root.object.put(arena, "id", host_id);
        try self.writeHost(try json(arena, root.*));
    }

    /// Writes a value as JSON text.
    ///
    /// Parameters:
    /// - `arena`: owns the text.
    /// - `value`: the value.
    ///
    /// Return: the text; propagates allocation failure.
    fn json(arena: std.mem.Allocator, value: anytype) acp.AcpError![]const u8 {
        return std.json.Stringify.valueAlloc(arena, value, .{}) catch error.OutOfMemory;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RelayRouter);
}

/// An owner for the tests: forwards everything, drops `available_commands_update`.
const TestOwner = struct {
    const Self = @This();

    dropped: usize = 0,

    fn frame(route: *RouterRoute, arena: std.mem.Allocator, root: *std.json.Value) acp.AcpError!RouterDisposition {
        _ = arena;
        const self: *Self = @ptrCast(@alignCast(route.context));
        const params = root.object.get("params") orelse return .forward;
        if (params != .object) return .forward;
        const update = params.object.get("update") orelse return .forward;
        if (update != .object) return .forward;
        const kind = update.object.get("sessionUpdate") orelse return .forward;
        if (kind == .string and std.mem.eql(u8, kind.string, "available_commands_update")) {
            self.dropped += 1;
            return .drop;
        }
        return .forward;
    }

    const hooks: RouterHooks = .{ .frame = frame };
};

test "a host prompt goes to its route renumbered, and the reply and updates come back in the host's terms" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const host_pair = try acp.FrameTransport.init(allocator, io);
    defer host_pair.deinit();
    const agent_pair = try acp.FrameTransport.init(allocator, io);
    defer agent_pair.deinit();

    var owner = TestOwner{};
    var router = try RelayRouter.init(allocator, io, host_pair.agentTransport(), "router-", TestOwner.hooks);
    defer router.deinit();
    var route = RouterRoute.init(&router, &owner, "planner", "group-1", agent_pair.clientTransport());
    route.session_id = try allocator.dupe(u8, "agent-s1");
    defer route.deinit();
    try router.start(&route);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The host's prompt 7, in the host's session.
    var prompt = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"group-1\",\"prompt\":[]}}", .{});
    const own_id = blk: {
        router.mutex.lockUncancelable(io);
        defer router.mutex.unlock(io);
        break :blk try router.reserveLocked(&route, .{ .integer = 7 }, true);
    };
    try router.send(&route, arena, &prompt, own_id);

    const agent = agent_pair.agentTransport();
    const sent = try agent.readFrame(arena);
    try std.testing.expect(std.mem.find(u8, sent, "\"id\":1") != null);
    try std.testing.expect(std.mem.find(u8, sent, "\"sessionId\":\"agent-s1\"") != null);
    try std.testing.expectEqual(@as(u32, 1), route.running);

    // An update in the agent's session reaches the host in the group's, tagged; a dropped one does not.
    try agent.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"agent-s1\",\"update\":{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":[]}}}" });
    try agent.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"agent-s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hi\"}}}}" });
    // A permission request, renumbered for the host.
    try agent.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"agent-s1\"}}" });
    const host = host_pair.clientTransport();
    const update = try host.readFrame(arena);
    try std.testing.expect(std.mem.find(u8, update, "\"sessionId\":\"group-1\"") != null);
    try std.testing.expect(std.mem.find(u8, update, "\"subagent\":\"planner\"") != null);
    const asked = try host.readFrame(arena);
    try std.testing.expect(std.mem.find(u8, asked, "\"id\":\"router-1\"") != null);
    try std.testing.expectEqual(@as(usize, 1), owner.dropped);

    // The host's answer goes back under the agent's own id.
    var answer = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"jsonrpc\":\"2.0\",\"id\":\"router-1\",\"result\":{}}", .{});
    try std.testing.expect(try router.answerOutbound(arena, &answer));
    try std.testing.expect(std.mem.find(u8, try agent.readFrame(arena), "\"id\":40") != null);

    // The turn's end goes back under the host's id, and the turn is no longer running.
    try agent.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"stopReason\":\"end_turn\"}}" });
    const ended = try host.readFrame(arena);
    try std.testing.expect(std.mem.find(u8, ended, "\"id\":7") != null);

    agent_pair.close();
    router.awaitRoute(&route);
    try std.testing.expectEqual(@as(u32, 0), route.running);
    try std.testing.expect(route.ended);
}

test "an owner's question is answered, and a route that goes away answers the host for its prompts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const host_pair = try acp.FrameTransport.init(allocator, io);
    defer host_pair.deinit();
    const agent_pair = try acp.FrameTransport.init(allocator, io);
    defer agent_pair.deinit();

    var owner = TestOwner{};
    var router = try RelayRouter.init(allocator, io, host_pair.agentTransport(), "router-", TestOwner.hooks);
    defer router.deinit();
    var route = RouterRoute.init(&router, &owner, "coder", "group-2", agent_pair.clientTransport());
    defer route.deinit();
    try router.start(&route);

    // The agent end: answers the first request it reads, then hangs up.
    const Agent = struct {
        fn serve(transport: acp.Transport) void {
            const frame = transport.readFrame(std.testing.allocator) catch return;
            std.testing.allocator.free(frame);
            transport.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"s-9\"}}" }) catch return;
        }
    };
    var agent_task: std.Io.Group = .init;
    try agent_task.concurrent(io, Agent.serve, .{agent_pair.agentTransport()});
    const opened = try router.ask(&route, "session/new", "{\"cwd\":\".\"}");
    defer allocator.free(opened);
    try std.testing.expectEqualStrings("{\"sessionId\":\"s-9\"}", opened);
    try agent_task.await(io);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    {
        router.mutex.lockUncancelable(io);
        defer router.mutex.unlock(io);
        _ = try router.reserveLocked(&route, .{ .integer = 3 }, true);
    }
    agent_pair.close();
    router.awaitRoute(&route);
    const cancelled = try host_pair.clientTransport().readFrame(arena);
    try std.testing.expect(std.mem.find(u8, cancelled, "\"id\":3") != null);
    try std.testing.expect(std.mem.find(u8, cancelled, "\"stopReason\":\"cancelled\"") != null);
}
