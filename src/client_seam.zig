//! Both halves of one agent's seam, stood up in one process.
//!
//! The assembly a front end would otherwise write: an agent served on one end
//! of an in-process pair (`LocalSeam`), a `Client.Session` on the other, an
//! optional analytics tap between them, and a session opened — new, reopened,
//! or none at all for a client that only asks about accounts. Torn down in the
//! one order that strands no task: the pair is closed so the agent's serve task
//! ends, the client goes, then the pair.
//!
//! There is no subprocess and no socket between the halves; the calls are
//! JSON-RPC framed and dispatched all the same, because `Transport` is a vtable.
//!
//! The agent is the caller's: borrowed, and freed by the caller after `deinit`.
//! It needs what `LocalSeam` needs, `attach(*Connection) void` and
//! `serve() AcpError!void`, which every harness's `AcpAgent` has.

const std = @import("std");
const log = std.log.scoped(.acp_client_seam);
const acp = @import("module.zig");

/// How a seam's session is opened, beyond which agent and where.
pub const SeamOptions = struct {
    const Self = @This();

    /// The account's directory, or null for the inherited one; borrowed for the call.
    home: ?[]const u8 = null,
    /// The account's name, or null for the agent's default; borrowed for the call.
    name: ?[]const u8 = null,
    /// Where every frame between client and agent is reported, or null for none; borrowed, must outlive the seam.
    observer: ?acp.Analytics.Observer = null,
    /// A stored session to reopen with `session/load`, or null to open a new one; borrowed for the call.
    resume_id: ?[]const u8 = null,
    /// The host's MCP server to offer a new session, or null for none; borrowed for the call.
    mcp: ?acp.McpOffer = null,
    /// Open a session; false to stop after the handshake, for asking about accounts or signing one in.
    open_session: bool = true,
};

/// A connected client and agent, and everything holding them together.
pub fn ClientSeam(comptime Agent: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        /// The agent served on one end of an in-process pair; the client holds the other.
        local: *acp.LocalSeam(Agent),
        /// What a front end draws.
        client: *acp.Client.Session,
        /// The client's side of the pair, wrapped when frames are observed; null when they are not.
        tap: ?acp.Analytics.TapTransport = null,

        /// Serves an agent with a connected client and opens a session on it.
        ///
        /// Parameters:
        /// - `allocator`: backs both halves; must outlive the seam.
        /// - `io`: IO capability for the serve task and the client.
        /// - `agent`: the agent; borrowed, must outlive the seam.
        /// - `label`: the agent's short name, for logs and the tap; borrowed, must outlive the seam.
        /// - `title`: the agent's name as a person reads it; borrowed, must outlive the seam.
        /// - `history`: where finished turns go; borrowed, must outlive the seam.
        /// - `environ_map`: the environment `terminal/*` commands run in; borrowed for the call.
        /// - `cwd`: the working directory the session runs in; borrowed for the call.
        /// - `options`: the account, the observer, a session to reopen, the MCP offer.
        ///
        /// Return: a heap seam at a stable address, caller calls `deinit`; propagates the handshake's and the session's failures.
        pub fn start(allocator: std.mem.Allocator, io: std.Io, agent: *Agent, label: []const u8, title: []const u8, history: acp.Client.History, environ_map: *const std.process.Environ.Map, cwd: []const u8, options: SeamOptions) acp.AcpError!*Self {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            // SAFETY: both set below, before anything reads them.
            self.* = .{ .allocator = allocator, .io = io, .local = undefined, .client = undefined };
            self.local = acp.LocalSeam(Agent).start(allocator, io, agent) catch return error.OutOfMemory;
            // Stops the serve task before `self` is freed under it.
            errdefer self.local.deinit();

            // Tapped on the client's side, so every frame of the session is seen
            // once, labelled with the agent it belongs to.
            if (options.observer) |watching| self.tap = try acp.Analytics.TapTransport.init(allocator, io, self.local.clientTransport(), watching, label);
            errdefer if (self.tap) |*tap| tap.deinit();
            const client_transport = if (self.tap) |*tap| tap.transport() else self.local.clientTransport();

            self.client = acp.Client.Session.start(allocator, io, client_transport, label, title, history, environ_map) catch |err| return narrow(err);
            // Stopped first, as in `deinit`, so the client's own reader is not left blocked.
            errdefer {
                self.local.stop();
                self.client.deinit();
            }

            const opened = if (!options.open_session)
                self.client.handshakeOnly()
            else if (options.resume_id) |session_id|
                self.client.resumeAs(cwd, session_id, options.home, options.name, options.mcp)
            else
                self.client.connectAs(cwd, options.home, options.name, options.mcp);
            opened catch |err| return narrow(err);
            return self;
        }

        /// Stops the agent's serve task and releases both halves; the agent itself is the caller's.
        ///
        /// Parameters:
        /// - `self`: the seam to tear down; invalid afterwards.
        ///
        /// Return: nothing; never fails.
        pub fn deinit(self: *Self) void {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            // The serve task stops before anything it touches is freed.
            self.local.stop();
            self.client.deinit();
            if (self.tap) |*tap| tap.deinit();
            self.local.deinit();
            self.allocator.destroy(self);
        }

        /// Narrows a client failure to the one error set that crosses the package boundary.
        ///
        /// Parameters:
        /// - `err`: what the client failed with.
        ///
        /// Return: the error as `AcpError`; one outside it as `PeerError`.
        fn narrow(err: anyerror) acp.AcpError {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidMessage => error.InvalidMessage,
                error.MethodNotFound => error.MethodNotFound,
                error.InvalidParams => error.InvalidParams,
                error.TransportClosed => error.TransportClosed,
                error.TransportFailed => error.TransportFailed,
                error.SessionNotFound => error.SessionNotFound,
                error.AgentGone => error.AgentGone,
                else => blk: {
                    log.warn("seam did not open [{t}]", .{err});
                    break :blk error.PeerError;
                },
            };
        }
    };
}

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
}

test "a seam shakes hands with its agent and opens no session when asked not to" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var agent = try acp.Test.EchoAgent.init(allocator);
    defer agent.deinit();
    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();

    var counter = acp.Analytics.FrameCounter{};
    const seam = try ClientSeam(acp.Test.EchoAgent).start(allocator, io, &agent, "echo", "Echo", .none, &environ_map, ".", .{ .open_session = false, .observer = counter.observer() });
    defer seam.deinit();
    try std.testing.expect(seam.client.isAlive());
    try std.testing.expectEqual(@as(usize, 1), counter.sent.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), counter.received.load(.monotonic));
}

test "a seam opens a session and streams a turn into the client" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var agent = try acp.Test.EchoAgent.init(allocator);
    defer agent.deinit();
    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();

    const seam = try ClientSeam(acp.Test.EchoAgent).start(allocator, io, &agent, "echo", "Echo", .none, &environ_map, ".", .{});
    defer seam.deinit();
    _ = try seam.client.prompt("count the birds");
    const live = try seam.client.liveText(allocator);
    defer allocator.free(live);
    try std.testing.expect(std.mem.find(u8, live, "echo: count the birds") != null);
}
