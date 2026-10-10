//! An agent served on one end of an in-process transport, the other end free
//! for a client.
//!
//! Every harness and host stood this up by hand: a transport pair, a
//! connection for the agent, a task serving it, and a teardown in the one order
//! that strands no task — close the pair so the serve task sees end of stream,
//! join it, and only then free what it touched. `LocalSeam` is that assembly
//! once. What talks on the client end stays the caller's.
//!
//! The agent type needs `attach(*acp.Connection) void` and
//! `serve() acp.AcpError!void`, which every harness's `AcpAgent` has.

const std = @import("std");
const log = std.log.scoped(.acp_local_seam);
const mod = @import("module.zig");
const acp = @import("acp");

/// Builds the seam type for one agent type.
///
/// Parameters:
/// - `Agent`: the agent; has `attach(*acp.Connection) void` and `serve() acp.AcpError!void`.
///
/// Return: the seam type.
pub fn LocalSeam(comptime Agent: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        pair: *mod.FrameTransport,
        /// The connection the agent serves on; the agent borrows it.
        connection: acp.Connection,
        agent: *Agent,
        /// The serve task. Exactly one releaser: `stop`.
        group: std.Io.Group = .init,
        stopped: bool = false,

        /// Serves an agent on one end of a new in-process pair.
        ///
        /// Parameters:
        /// - `allocator`: backs the seam; must outlive it.
        /// - `io`: IO capability for the serve task; stored.
        /// - `agent`: the agent; borrowed, and the caller frees it after `stop`.
        ///
        /// Return: the seam at a stable address, caller calls `deinit`; propagates allocation failure.
        pub fn start(allocator: std.mem.Allocator, io: std.Io, agent: *Agent) !*Self {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            const pair = try mod.FrameTransport.init(allocator, io);
            errdefer pair.deinit();
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .io = io,
                .pair = pair,
                .connection = acp.Connection.init(allocator, pair.agentTransport()),
                .agent = agent,
            };
            agent.attach(&self.connection);
            // `concurrent`, not `async`: the latter may serve right here, before
            // a client exists to talk to it.
            self.group.concurrent(io, serve, .{agent}) catch {
                self.group.async(io, serve, .{agent});
            };
            return self;
        }

        /// The end a client talks on.
        ///
        /// Parameters:
        /// - `self`: the seam.
        ///
        /// Return: the transport, valid until `deinit`.
        pub fn clientTransport(self: *Self) acp.Transport {
            return self.pair.clientTransport();
        }

        /// Closes the pair and waits for the agent to stop serving.
        ///
        /// Parameters:
        /// - `self`: the seam.
        ///
        /// Return: nothing; a second call does nothing.
        pub fn stop(self: *Self) void {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            if (self.stopped) return;
            self.stopped = true;
            self.pair.close();
            self.group.await(self.io) catch |err| log.warn("agent task did not join cleanly [{t}]", .{err});
        }

        /// Stops the agent if it still serves, then frees the pair and the seam.
        ///
        /// Parameters:
        /// - `self`: the seam; invalid afterwards. Free the client before, and the agent after.
        ///
        /// Return: nothing.
        pub fn deinit(self: *Self) void {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            self.stop();
            self.pair.deinit();
            self.allocator.destroy(self);
        }

        /// Serves the agent until the pair closes; the seam's task body.
        ///
        /// Parameters:
        /// - `agent`: the agent; borrowed.
        ///
        /// Return: nothing; failures other than closure are logged.
        fn serve(agent: *Agent) void {
            agent.serve() catch |err| switch (err) {
                error.TransportClosed => {},
                else => log.warn("agent stopped serving [{t}]", .{err}),
            };
        }
    };
}

// -----------------------------------------------------------------------------
// Unit Tests

/// An agent that answers `ping` with `pong`.
const PingAgent = struct {
    const Self = @This();

    dispatcher: acp.Dispatcher,
    // SAFETY: set by `attach` before `serve`.
    connection: *acp.Connection = undefined,

    fn ping(self: *Self, _: std.mem.Allocator, _: struct {}) acp.AcpError!struct { pong: bool } {
        _ = self;
        return .{ .pong = true };
    }

    pub fn attach(self: *Self, connection: *acp.Connection) void {
        self.connection = connection;
        connection.setRequestHandler(self.dispatcher.requestHandler());
    }

    pub fn serve(self: *Self) acp.AcpError!void {
        return self.connection.serve();
    }
};

test "a local seam serves its agent to a client and tears down in order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var agent = PingAgent{ .dispatcher = acp.Dispatcher.init(allocator) };
    defer agent.dispatcher.deinit();
    try agent.dispatcher.registerRequestFn("ping", &agent, PingAgent.ping);

    const seam = try LocalSeam(PingAgent).start(allocator, io, &agent);
    defer seam.deinit();

    var client = acp.Connection.init(allocator, seam.clientTransport());
    const answer = try client.request(struct { pong: bool }, "ping", struct {}{});
    defer answer.deinit();
    try std.testing.expect(answer.value.pong);

    seam.stop();
}
