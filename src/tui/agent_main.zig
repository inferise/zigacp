//! What a harness executable does once its own flags are handled: a screen, or ACP on stdio.
//!
//! Every harness ships one executable that is two things. Run in a terminal it
//! is a chat with its agent (`AgentChat`); launched by a host it is an ACP agent
//! on stdin and stdout. The launch rule decides which, the same for every
//! harness:
//!
//! - `app acp` (or the older `app --acp`): ACP on stdio, always.
//! - `app` with stdin and stdout both pipes: ACP on stdio, as a host launches it.
//! - `app` on a terminal: the screen.
//! - `app` with only one end a terminal (`app | less`): neither; it says why.
//!
//! The harness keeps its own flags (`--setup`, `--login`, `--help`) and hands
//! everything else here. Its `std_options.logFn` is `zigtui.LogRing.logFn`, so
//! records go to the screen's log while the screen is up and to stderr — never
//! stdout, which carries the protocol — otherwise.

const std = @import("std");
const log = std.log.scoped(.acp_tui_agent_main);
const mod = @import("module.zig");

/// What a launch should do.
pub const Launch = enum {
    /// The chat screen on this terminal.
    screen,
    /// ACP on stdin and stdout.
    acp,
    /// A bare launch with only one end a terminal: neither can run.
    noTerminal,
    /// Arguments that are not the launch rule's: the harness's to handle, or its usage.
    other,

    /// Decides a launch from the arguments after the program name and which ends are terminals.
    ///
    /// Parameters:
    /// - `args`: the arguments after the program name.
    /// - `stdin_tty`: whether stdin is a terminal.
    /// - `stdout_tty`: whether stdout is a terminal.
    ///
    /// Return: the launch.
    pub fn decide(args: []const []const u8, stdin_tty: bool, stdout_tty: bool) Launch {
        if (args.len > 0) {
            const first = args[0];
            if (args.len == 1 and (std.mem.eql(u8, first, "acp") or std.mem.eql(u8, first, "--acp"))) return .acp;
            return .other;
        }
        // A host launches an agent on pipes, never a terminal, and a screen
        // cannot run without one anyway.
        if (!stdin_tty and !stdout_tty) return .acp;
        if (stdin_tty and stdout_tty) return .screen;
        return .noTerminal;
    }
};

/// The two ways a harness executable runs its agent, over the agent type it links.
///
/// The agent needs what `LocalSeam` needs — `attach(*Connection) void` and
/// `serve() AcpError!void` — and `deinit() void`; every harness's `AcpAgent` has them.
pub fn AgentMain(comptime Agent: type) type {
    return struct {
        const Self = @This();

        /// What the harness says about itself, and how it starts its agent.
        pub const Spec = struct {
            /// The agent's name as a person reads it (`Claude`).
            title: []const u8,
            /// The agent's short name, for logs (`claude`).
            label: []const u8,
            /// The executable's name, for the sentence a bad launch prints (`zigclaude`).
            program: []const u8,
            /// Starts the agent; the caller `deinit`s it.
            start: *const fn (init: std.process.Init, context: ?*anyopaque) mod.acp.AcpError!*Agent,
            /// Passed to `start`: what the harness holds for the agent's whole life, or null.
            context: ?*anyopaque = null,
        };

        /// Runs the launch rule over the arguments the harness did not take.
        ///
        /// Parameters:
        /// - `init`: process capabilities.
        /// - `spec`: the harness.
        /// - `args`: the arguments after the program name.
        ///
        /// Return: true when the launch was the rule's and has run; false for `other`, which is the harness's to handle; propagates the agent's and the terminal's failures.
        pub fn run(init: std.process.Init, spec: Spec, args: []const []const u8) mod.acp.AcpError!bool {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            const stdin_tty = std.Io.File.stdin().isTty(init.io) catch false;
            const stdout_tty = std.Io.File.stdout().isTty(init.io) catch false;
            switch (Launch.decide(args, stdin_tty, stdout_tty)) {
                .other => return false,
                .noTerminal => {
                    tell(init, "{s} needs a terminal for its screen; run `{s} acp` to serve ACP on stdio instead.\n", .{ spec.program, spec.program });
                    return error.TransportFailed;
                },
                .acp => {
                    const agent = try spec.start(init, spec.context);
                    defer agent.deinit();
                    try serveStdio(init, agent);
                },
                .screen => {
                    const agent = try spec.start(init, spec.context);
                    defer agent.deinit();
                    try runScreen(init, spec, agent);
                },
            }
            return true;
        }

        /// Serves one ACP connection over stdin and stdout until the host closes it.
        ///
        /// Parameters:
        /// - `init`: process capabilities.
        /// - `agent`: the agent; borrowed.
        ///
        /// Return: nothing once the host has gone; propagates transport failures.
        pub fn serveStdio(init: std.process.Init, agent: *Agent) mod.acp.AcpError!void {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            var config = mod.acp.Config.init() catch return error.TransportFailed;
            defer config.deinit();
            var stdio = mod.acp.StdioTransport.init(init.gpa, init.io, &config, std.Io.File.stdin(), std.Io.File.stdout(), false) catch return error.TransportFailed;
            defer stdio.deinit();
            stdio.start() catch return error.TransportFailed;

            var connection = mod.acp.Connection.init(init.gpa, stdio.transport());
            agent.attach(&connection);
            agent.serve() catch |err| switch (err) {
                error.TransportClosed => {},
                else => return err,
            };
        }

        /// Runs the chat screen over the agent, served in-process.
        ///
        /// Parameters:
        /// - `init`: process capabilities.
        /// - `spec`: the harness.
        /// - `agent`: the agent; borrowed.
        ///
        /// Return: nothing once the person quits; propagates the handshake's and the terminal's failures.
        pub fn runScreen(init: std.process.Init, spec: Spec, agent: *Agent) mod.acp.AcpError!void {
            log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

            // Absolute: an agent may refuse a relative working directory.
            const cwd = std.process.currentPathAlloc(init.io, init.gpa) catch return error.OutOfMemory;
            defer init.gpa.free(cwd);

            // The session is opened by the screen, so the wait is drawn rather than a terminal that has not come up.
            const seam = try mod.acp.Client.Seam(Agent).start(init.gpa, init.io, agent, spec.label, spec.title, .none, init.environ_map, cwd, .{ .open_session = false });
            defer seam.deinit();

            var chat = try mod.AgentChat.init(init.gpa, init.io, seam.client, spec.title, cwd, init.environ_map);
            defer chat.deinit();
            try chat.run(init.environ_map);
        }

        /// Writes one sentence to stderr, where a person running the program reads it.
        ///
        /// Parameters:
        /// - `init`: process capabilities.
        /// - `format`: the sentence's format.
        /// - `args`: its arguments.
        ///
        /// Return: nothing; a failed write is logged.
        fn tell(init: std.process.Init, comptime format: []const u8, args: anytype) void {
            // SAFETY: filled by the writer before it is flushed.
            var buffer: [512]u8 = undefined;
            var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
            stderr.interface.print(format, args) catch |err| log.warn("not said [{t}]", .{err});
            stderr.interface.flush() catch |err| log.warn("not said [{t}]", .{err});
        }
    };
}

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(AgentMain(mod.acp.Test.EchoAgent));
}

test "the launch rule: acp always serves, pipes serve, a terminal draws, half a terminal does neither" {
    try std.testing.expectEqual(Launch.acp, Launch.decide(&.{"acp"}, true, true));
    try std.testing.expectEqual(Launch.acp, Launch.decide(&.{"--acp"}, false, false));
    try std.testing.expectEqual(Launch.acp, Launch.decide(&.{}, false, false));
    try std.testing.expectEqual(Launch.screen, Launch.decide(&.{}, true, true));
    try std.testing.expectEqual(Launch.noTerminal, Launch.decide(&.{}, true, false));
    try std.testing.expectEqual(Launch.noTerminal, Launch.decide(&.{}, false, true));
    // Anything else is the harness's: its own flags, or its usage.
    try std.testing.expectEqual(Launch.other, Launch.decide(&.{"--setup"}, true, true));
    try std.testing.expectEqual(Launch.other, Launch.decide(&.{ "acp", "extra" }, false, false));
}
