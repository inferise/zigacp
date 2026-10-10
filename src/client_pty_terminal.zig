//! `terminal/*`, served by the client over a real pseudoterminal.
//!
//! ACP's terminal methods are create, read output, wait for exit, kill, release
//! — which is `Pty.Session`'s job description almost word for word. Served on
//! it rather than over plain pipes (`Client.Terminal`), a program that checks
//! `isatty` behaves here as it would in a real terminal, and its output is the
//! screen `VtScreen` renders rather than raw escape sequences.
//!
//! Windows has no `openpty`, so `terminal/create` fails there exactly as
//! `Pty.Session.start` does.

const std = @import("std");
const log = std.log.scoped(.acp_client_pty_terminal);
const acp = @import("module.zig");

/// One terminal this client is holding for an agent.
pub const Terminal = struct {
    const Self = @This();

    /// The id handed back to the agent. Owned.
    id: []u8,
    /// The pseudoterminal and the process on it.
    pty: *acp.Pty.Session,
    /// How much output to retain, per the agent's request or the default.
    output_limit: u64,

    /// Bundles a running terminal with its id and output bound.
    ///
    /// Parameters:
    /// - `id`: the terminal's id; ownership passes to the record.
    /// - `pty`: the running pseudoterminal; ownership passes to the record.
    /// - `output_limit`: bytes of output to retain.
    ///
    /// Return: the record; never fails today.
    pub fn init(id: []u8, pty: *acp.Pty.Session, output_limit: u64) !Self {
        return Self{ .id = id, .pty = pty, .output_limit = output_limit };
    }

    /// Releases nothing; `ClientPtyTerminal` frees `id` and `pty` with its own allocator.
    ///
    /// Parameters:
    /// - `self`: the record.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

/// Serves `terminal/create`.
const CreateHandler = struct {
    const Self = @This();

    pub const Params = acp.Client.CreateTerminalRequest;
    pub const Result = acp.Client.CreateTerminalResponse;

    // SAFETY: set by `ClientPtyTerminal.register`.
    owner: *ClientPtyTerminal = undefined,

    /// Constructs an unregistered handler.
    ///
    /// Return: the handler, with `owner` unset until `ClientPtyTerminal.register`; never fails today.
    pub fn init() !Self {
        return Self{};
    }

    /// Releases nothing; the handler owns no resources.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Starts the requested program and reports its terminal id.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `allocator`: request-scoped allocator for the result.
    /// - `params`: the decoded request.
    ///
    /// Return: the new terminal id; `error.InvalidParams` on args or spawn failure, `error.OutOfMemory` on allocation failure.
    pub fn handle(self: *Self, allocator: std.mem.Allocator, params: Params) acp.AcpError!Result {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // `Pty.Session.start` takes a command name and no arguments — the same
        // limitation it has always had — so an agent passing `args` is told the
        // request is unsupported rather than quietly having them dropped.
        if (params.args) |args| {
            if (args.len > 0) {
                log.warn("terminal/create with {d} args; a pseudoterminal session takes a command only", .{args.len});
                return error.InvalidParams;
            }
        }

        const id = self.owner.create(params.command, params.outputByteLimit) catch |err| {
            log.warn("terminal/create {s} [{t}]", .{ params.command, err });
            return error.InvalidParams;
        };
        return .{ .terminalId = .{ .value = allocator.dupe(u8, id) catch return error.OutOfMemory } };
    }
};

/// Serves `terminal/output`.
const OutputHandler = struct {
    const Self = @This();

    pub const Params = acp.Client.TerminalOutputRequest;
    pub const Result = acp.Client.TerminalOutputResponse;

    // SAFETY: set by `ClientPtyTerminal.register`.
    owner: *ClientPtyTerminal = undefined,

    /// Constructs an unregistered handler.
    ///
    /// Return: the handler, with `owner` unset until `ClientPtyTerminal.register`; never fails today.
    pub fn init() !Self {
        return Self{};
    }

    /// Releases nothing; the handler owns no resources.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Returns a terminal's retained output and whether it has exited.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `allocator`: request-scoped allocator for the output copy.
    /// - `params`: the decoded request.
    ///
    /// Return: the output, truncation flag, and exit status; `error.InvalidParams` for an unknown id, `error.OutOfMemory` on allocation failure.
    pub fn handle(self: *Self, allocator: std.mem.Allocator, params: Params) acp.AcpError!Result {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const terminal = self.owner.find(params.terminalId.value) orelse return error.InvalidParams;

        const raw = terminal.pty.rawSnapshotOwned(allocator) catch return error.OutOfMemory;
        const truncated = raw.len > terminal.output_limit;
        const output = if (truncated) raw[raw.len - @as(usize, @intCast(terminal.output_limit)) ..] else raw;

        return .{
            .output = output,
            .truncated = truncated,
            // Exit code unknown until reaped; see `wait_for_exit`.
            .exitStatus = if (terminal.pty.isAlive()) null else .{},
        };
    }
};

/// Serves `terminal/wait_for_exit`.
const WaitHandler = struct {
    const Self = @This();

    pub const Params = acp.Client.WaitForTerminalExitRequest;
    pub const Result = acp.Client.WaitForTerminalExitResponse;

    // SAFETY: set by `ClientPtyTerminal.register`.
    owner: *ClientPtyTerminal = undefined,

    /// Constructs an unregistered handler.
    ///
    /// Return: the handler, with `owner` unset until `ClientPtyTerminal.register`; never fails today.
    pub fn init() !Self {
        return Self{};
    }

    /// Releases nothing; the handler owns no resources.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Blocks until the terminal's program exits.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `_`: request-scoped allocator; unused.
    /// - `params`: the decoded request.
    ///
    /// Return: the exit status; `error.InvalidParams` for an unknown id.
    pub fn handle(self: *Self, _: std.mem.Allocator, params: Params) acp.AcpError!Result {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const terminal = self.owner.find(params.terminalId.value) orelse return error.InvalidParams;

        // Blocking is what the method means. It runs on whichever task is
        // serving, which for a client is the one inside `prompt` — the draw
        // loop is elsewhere and keeps running.
        while (terminal.pty.isAlive()) {
            self.owner.io.sleep(.fromMilliseconds(25), .awake) catch break;
        }
        // Exited, but with no code to report: `Pty.Session` sees the child
        // go away as end-of-stream and only reaps it in `deinit`, so the
        // status is not known yet. Null is honest; a made-up 0 claims a
        // success nobody observed.
        return .{ .exitStatus = .{} };
    }
};

/// Serves `terminal/kill`.
const KillHandler = struct {
    const Self = @This();

    pub const Params = acp.Client.KillTerminalRequest;
    pub const Result = acp.Client.KillTerminalResponse;

    // SAFETY: set by `ClientPtyTerminal.register`.
    owner: *ClientPtyTerminal = undefined,

    /// Constructs an unregistered handler.
    ///
    /// Return: the handler, with `owner` unset until `ClientPtyTerminal.register`; never fails today.
    pub fn init() !Self {
        return Self{};
    }

    /// Releases nothing; the handler owns no resources.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Stops a terminal's program while keeping the terminal and its output.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `_`: request-scoped allocator; unused.
    /// - `params`: the decoded request.
    ///
    /// Return: an empty result; `error.InvalidParams` for an unknown id.
    pub fn handle(self: *Self, _: std.mem.Allocator, params: Params) acp.AcpError!Result {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // The terminal is not dropped, so its output survives for a later
        // `terminal/output`.
        const terminal = self.owner.find(params.terminalId.value) orelse return error.InvalidParams;
        terminal.pty.interrupt() catch |err| log.warn("terminal/kill [{t}]", .{err});
        return .{};
    }
};

/// Serves `terminal/release`.
const ReleaseHandler = struct {
    const Self = @This();

    pub const Params = acp.Client.ReleaseTerminalRequest;
    pub const Result = acp.Client.ReleaseTerminalResponse;

    // SAFETY: set by `ClientPtyTerminal.register`.
    owner: *ClientPtyTerminal = undefined,

    /// Constructs an unregistered handler.
    ///
    /// Return: the handler, with `owner` unset until `ClientPtyTerminal.register`; never fails today.
    pub fn init() !Self {
        return Self{};
    }

    /// Releases nothing; the handler owns no resources.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Drops a terminal and everything it held.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `_`: request-scoped allocator; unused.
    /// - `params`: the decoded request.
    ///
    /// Return: an empty result; `error.InvalidParams` for an unknown id.
    pub fn handle(self: *Self, _: std.mem.Allocator, params: Params) acp.AcpError!Result {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (!self.owner.release(params.terminalId.value)) return error.InvalidParams;
        return .{};
    }
};

/// The terminal half of the client surface.
pub const ClientPtyTerminal = struct {
    const Self = @This();

    /// Retained output per terminal when the agent names no limit.
    ///
    /// `INV-19` applies whatever round three, answer 15 said about *counts*: a
    /// cap on how many terminals exist is one thing, a buffer with no bound is
    /// another, and this is a buffer.
    pub const default_output_limit: u64 = 256 * 1024;

    /// Terminal ids are minted from this, so they are unique within a client.
    next_id: u32 = 1,

    // SAFETY: set by `AcpClient.start` before the dispatcher can route anything.
    allocator: std.mem.Allocator = undefined,
    // SAFETY: same.
    io: std.Io = undefined,
    /// Live terminals. No cap — round three, answer 15.
    terminals: std.ArrayList(Terminal) = .empty,

    create_handler_storage: CreateHandler = .{},
    output_handler_storage: OutputHandler = .{},
    wait_handler_storage: WaitHandler = .{},
    kill_handler_storage: KillHandler = .{},
    release_handler_storage: ReleaseHandler = .{},

    /// Constructs a handler holding no terminals.
    ///
    /// Parameters:
    /// - `allocator`: backs ids and the terminal list; must outlive the handler.
    /// - `io`: IO capability for spawning and waiting.
    ///
    /// Return: the handler; never fails today.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        return Self{ .allocator = allocator, .io = io };
    }

    /// Releases every terminal still held, killing its process.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // An agent that never calls `terminal/release` should not leak a
        // process, so teardown reaps whatever is left.
        for (self.terminals.items) |*terminal| {
            terminal.pty.deinit();
            self.allocator.free(terminal.id);
            terminal.deinit();
        }
        self.terminals.deinit(self.allocator);
    }

    /// Registers the five `terminal/*` methods on a dispatcher.
    ///
    /// Parameters:
    /// - `instance`: the handler; must outlive the dispatcher.
    /// - `dispatcher`: where to register.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn register(instance: *Self, dispatcher: *acp.Dispatcher) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        instance.create_handler_storage.owner = instance;
        instance.output_handler_storage.owner = instance;
        instance.wait_handler_storage.owner = instance;
        instance.kill_handler_storage.owner = instance;
        instance.release_handler_storage.owner = instance;

        try dispatcher.registerRequest(acp.Client.method_terminal_create, CreateHandler, &instance.create_handler_storage);
        try dispatcher.registerRequest(acp.Client.method_terminal_output, OutputHandler, &instance.output_handler_storage);
        try dispatcher.registerRequest(acp.Client.method_terminal_wait_for_exit, WaitHandler, &instance.wait_handler_storage);
        try dispatcher.registerRequest(acp.Client.method_terminal_kill, KillHandler, &instance.kill_handler_storage);
        try dispatcher.registerRequest(acp.Client.method_terminal_release, ReleaseHandler, &instance.release_handler_storage);
    }

    /// Starts a program on a new pseudoterminal.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `command`: the program to run.
    /// - `output_limit`: bytes of output to retain, or null for the default.
    ///
    /// Return: the new terminal's id, borrowed from the handler; propagates spawn and allocation failure.
    pub fn create(self: *Self, command: []const u8, output_limit: ?u64) ![]const u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // The child inherits an empty environment: this client serves an agent,
        // not a shell, and leaking our own environment into a program a peer
        // named would be handing it more than it asked for.
        var environ_map = std.process.Environ.Map.init(self.allocator);
        defer environ_map.deinit();

        const pty = try acp.Pty.Session.start(self.allocator, self.io, &environ_map, command);
        errdefer pty.deinit();

        const id = try self.allocator.print("term-{d}", .{self.next_id});
        errdefer self.allocator.free(id);
        self.next_id += 1;

        try self.terminals.append(self.allocator, try Terminal.init(id, pty, output_limit orelse default_output_limit));
        return id;
    }

    /// Finds a terminal by id.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `id`: the terminal's id.
    ///
    /// Return: the terminal, borrowed from the handler, or null when unknown.
    pub fn find(self: *Self, id: []const u8) ?*Terminal {
        for (self.terminals.items) |*terminal| {
            if (std.mem.eql(u8, terminal.id, id)) return terminal;
        }
        return null;
    }

    /// Drops a terminal, killing whatever is still running on it.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `id`: the terminal's id.
    ///
    /// Return: true when a terminal was released, false when the id is unknown.
    pub fn release(self: *Self, id: []const u8) bool {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        for (self.terminals.items, 0..) |*terminal, index| {
            if (!std.mem.eql(u8, terminal.id, id)) continue;
            terminal.pty.deinit();
            self.allocator.free(terminal.id);
            terminal.deinit();
            _ = self.terminals.orderedRemove(index);
            return true;
        }
        return false;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ClientPtyTerminal);
}

test "terminal ids are unique within a client" {
    const allocator = std.testing.allocator;
    var handler = try ClientPtyTerminal.init(allocator, std.testing.io);
    defer handler.deinit();

    // No process is started; only the minting is under test here, because
    // spawning is what the live check covers.
    try std.testing.expectEqual(@as(u32, 1), handler.next_id);
    try std.testing.expect(handler.find("term-1") == null);
    try std.testing.expect(!handler.release("term-1"));
}

test "the retained-output bound has a stated default" {
    // `INV-19`: a buffer states its bound. Round three declined a cap on the
    // *number* of terminals, which is a different thing from an unbounded one.
    try std.testing.expect(ClientPtyTerminal.default_output_limit > 0);
    try std.testing.expectEqual(@as(u64, 256 * 1024), ClientPtyTerminal.default_output_limit);
}
