//! The agent end of a relay, whichever kind of agent it is.
//!
//! An agent linked into this process is served by `LocalSeam` on one end of an
//! in-process pair, and the relay holds the other. A native ACP agent is a child
//! process: the relay speaks to its stdio through a `StdioTransport`. Either
//! way the relay sees one `Transport` and cannot tell which it has, which is
//! what lets one relay front every agent.
//!
//! Teardown is the fiddly part: the agent is told to stop before anything
//! waiting on it is joined, or the join waits forever. A linked agent is the
//! caller's, borrowed and freed by the caller after `deinit`.

const std = @import("std");
const log = std.log.scoped(.acp_relay_downstream);
const acp = @import("module.zig");

/// A child ACP agent to spawn: its command line and environment.
pub const ChildCommand = struct {
    /// What a log line calls it.
    name: []const u8,
    /// The program and its arguments; borrowed for the call.
    argv: []const []const u8,
    /// The environment it runs in; borrowed for the call.
    environ_map: *const std.process.Environ.Map,
};

/// A child ACP agent and the transport over its stdio.
const ChildEnd = struct {
    const Self = @This();

    child: std.process.Child,
    /// The transport's settings; `stdio` borrows it, so it lives beside it.
    config: acp.Config,
    /// Reads the child's stdout and writes its stdin.
    stdio: acp.StdioTransport,
    /// Whether the child's stdin has been closed, so it is closed once.
    closed_input: bool = false,
};

/// The agent behind a relay: one linked in, of type `Agent`, or a child.
pub fn RelayDownstream(comptime Agent: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        end: union(enum) {
            linked: *acp.LocalSeam(Agent),
            child: ChildEnd,
        },
        /// The relay's side of the agent's transport, wrapped when frames are observed; null when they are not.
        tap: ?acp.Analytics.TapTransport = null,

        /// Serves an agent linked into this process.
        ///
        /// Parameters:
        /// - `allocator`: backs the pair; must outlive it.
        /// - `io`: IO capability for the serve task.
        /// - `agent`: the agent; borrowed, must outlive the downstream.
        /// - `observer`: where every frame between relay and agent is reported, or null for none; borrowed, must outlive the downstream.
        /// - `label`: what the tap reports frames under; copied.
        ///
        /// Return: the downstream at a stable address, caller calls `deinit`; propagates allocation failure.
        pub fn startLinked(allocator: std.mem.Allocator, io: std.Io, agent: *Agent, observer: ?acp.Analytics.Observer, label: []const u8) acp.AcpError!*Self {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const local = acp.LocalSeam(Agent).start(allocator, io, agent) catch return error.OutOfMemory;
            self.* = .{ .allocator = allocator, .io = io, .end = .{ .linked = local } };
            try self.watch(observer, label);
            return self;
        }

        /// Spawns a native ACP agent and speaks to it over its stdio.
        ///
        /// Parameters:
        /// - `allocator`: backs the transport; must outlive it.
        /// - `io`: IO capability for spawning and the reader task.
        /// - `command`: what to run and in what environment; borrowed for the call.
        /// - `observer`: where every frame between relay and agent is reported, or null for none; borrowed, must outlive the downstream.
        /// - `label`: what the tap reports frames under; copied.
        ///
        /// Return: the downstream at a stable address, caller calls `deinit`; `error.AgentGone` when the child cannot be spawned or read.
        pub fn startChild(allocator: std.mem.Allocator, io: std.Io, command: ChildCommand, observer: ?acp.Analytics.Observer, label: []const u8) acp.AcpError!*Self {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            // Stderr goes where ours goes — the host's log — so an agent that
            // fails to start says why somewhere a person can read it.
            var child = std.process.spawn(io, .{ .argv = command.argv, .environ_map = command.environ_map, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit }) catch |err| {
                log.warn("{s} did not start [{t}]", .{ command.name, err });
                return error.AgentGone;
            };
            errdefer _ = child.kill(io);

            const config = acp.Config.init() catch return error.TransportFailed;
            // SAFETY: `stdio` is set just below, in place, once `config` sits at its final address.
            self.* = .{ .allocator = allocator, .io = io, .end = .{ .child = .{ .child = child, .config = config, .stdio = undefined } } };
            const end = &self.end.child;
            errdefer end.config.deinit();
            end.stdio = acp.StdioTransport.init(allocator, io, &end.config, child.stdout.?, child.stdin.?, false) catch return error.TransportFailed;
            errdefer end.stdio.deinit();
            end.stdio.start() catch return error.TransportFailed;
            log.info("started {s} ({s})", .{ command.name, command.argv[0] });

            try self.watch(observer, label);
            return self;
        }

        /// Tells the agent to stop, then releases it and frees `self`; a linked agent is the caller's to free.
        ///
        /// Parameters:
        /// - `self`: the downstream; invalid afterwards.
        ///
        /// Return: nothing; never fails.
        pub fn deinit(self: *Self) void {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            self.close();
            switch (self.end) {
                .linked => |local| local.deinit(),
                .child => |*end| {
                    // The reader first: it is blocked on the child's stdout, and the
                    // kill below closes that handle out from under it.
                    end.stdio.deinit();
                    end.config.deinit();
                    _ = end.child.kill(self.io);
                },
            }
            if (self.tap) |*tap| tap.deinit();
            self.allocator.destroy(self);
        }

        /// Returns the transport the relay speaks to the agent on.
        ///
        /// Parameters:
        /// - `self`: the downstream.
        ///
        /// Return: the transport, borrowing `self`.
        pub fn transport(self: *Self) acp.Transport {
            if (self.tap) |*tap| return tap.transport();
            return self.rawTransport();
        }

        /// Asks the agent to finish, without waiting for it; idempotent.
        ///
        /// Parameters:
        /// - `self`: the downstream.
        ///
        /// Return: nothing.
        pub fn close(self: *Self) void {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            // A linked agent sees its transport close and stops serving; a child
            // sees end of input, which is how an ACP agent is told its client has gone.
            switch (self.end) {
                .linked => |local| local.pair.close(),
                .child => |*end| {
                    end.stdio.close();
                    if (end.closed_input) return;
                    end.closed_input = true;
                    // The child owns the handle; detach it after closing so the kill
                    // in `deinit` does not close the same descriptor twice.
                    if (end.child.stdin) |file| {
                        file.close(self.io);
                        end.child.stdin = null;
                    }
                },
            }
        }

        /// Returns the agent's own transport, untapped.
        ///
        /// Parameters:
        /// - `self`: the downstream.
        ///
        /// Return: the transport, borrowing `self`.
        fn rawTransport(self: *Self) acp.Transport {
            return switch (self.end) {
                .linked => |local| local.clientTransport(),
                .child => |*end| end.stdio.transport(),
            };
        }

        /// Wraps the agent's transport in a tap when there is an observer.
        ///
        /// Parameters:
        /// - `self`: the downstream; torn down when the tap cannot be made.
        /// - `observer`: the observer, or null for none.
        /// - `label`: what frames are reported under; copied.
        ///
        /// Return: nothing; propagates allocation failure after tearing `self` down.
        fn watch(self: *Self, observer: ?acp.Analytics.Observer, label: []const u8) acp.AcpError!void {
            const watching = observer orelse return;
            // Tapped on the relay's side, so the frames are the ones the agent
            // actually saw — after the relay's rewriting.
            self.tap = acp.Analytics.TapTransport.init(self.allocator, self.io, self.rawTransport(), watching, label) catch {
                self.deinit();
                return error.OutOfMemory;
            };
        }
    };
}

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
}

test "a native agent is a child on stdio: frames round-trip and teardown does not hang" {
    // `cat` stands in for an ACP agent: whatever the relay writes comes back,
    // which is enough to prove the pipes, the reader task and the teardown order.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var environ_map = try std.testing.environ.createMap(allocator);
    defer environ_map.deinit();

    var counter = acp.Analytics.FrameCounter{};
    const downstream = try RelayDownstream(acp.Test.EchoAgent).startChild(allocator, io, .{ .name = "cat", .argv = &.{"/bin/cat"}, .environ_map = &environ_map }, counter.observer(), "cat");
    defer downstream.deinit();

    const t = downstream.transport();
    try t.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}" });
    const echoed = try t.readFrame(allocator);
    defer allocator.free(echoed);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", echoed);
    // The tap saw the frame go out and come back, once each.
    try std.testing.expectEqual(@as(usize, 1), counter.sent.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), counter.received.load(.monotonic));
}

test "a linked agent answers initialize through the relay's end" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var agent = try acp.Test.EchoAgent.init(allocator);
    defer agent.deinit();
    var counter = acp.Analytics.FrameCounter{};
    const downstream = try RelayDownstream(acp.Test.EchoAgent).startLinked(allocator, io, &agent, counter.observer(), "echo");
    defer downstream.deinit();

    var connection = acp.Connection.init(allocator, downstream.transport());
    const handshake = try connection.request(acp.Agent.InitializeResponse, acp.Agent.method_initialize, acp.Agent.InitializeRequest{ .protocolVersion = acp.ProtocolVersion.V1 });
    defer handshake.deinit();
    try std.testing.expectEqual(acp.ProtocolVersion.V1.value, handshake.value.protocolVersion.value);
    try std.testing.expectEqual(@as(usize, 1), counter.sent.load(.monotonic));
}
