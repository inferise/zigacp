//! `terminal/*`, served by the client over plain pipes.
//!
//! ACP lets an agent ask its client to run a command rather than running it
//! itself — which is how an editor shows the command in its own terminal pane
//! and keeps the say over what runs. The five methods are create, read output,
//! wait for exit, kill, and release.
//!
//! A client registers this on its `acp.Dispatcher` to offer them, and advertises
//! `clientCapabilities.terminal` so an agent knows to ask.
//!
//! **No pseudoterminal.** The command runs with piped stdout and stderr, merged
//! into one output in arrival order. A program that checks `isatty` sees a pipe
//! and may behave as it would under a script — no colour, no pager, no prompt.
//! That is the right default for output an agent reads, and it needs nothing
//! from libc that `std.process.spawn` does not already use. zigclaude's
//! `AcpTerminal` is the pty-backed alternative.
//!
//! **Bounded.** Each terminal retains at most `outputByteLimit` bytes, or
//! `default_output_limit` when the agent names none. Past the bound the oldest
//! output is dropped, at a character boundary, and `truncated` says so.
//!
//! **The command runs in its own process group**, so `terminal/kill` reaches
//! whatever it started too: `sh -c "sleep 100"` is two processes, and killing
//! only the shell would leave the pipe open and the output never ending.
//!
//! There is no command policy: whatever the agent names, runs. A client that
//! needs one checks the request before registering this, or asks the user —
//! which is what `session/request_permission` is for.
//!
//! `sessionId` is accepted and ignored. Terminal ids are unique per client, not
//! per session, so one lookup serves every session.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.acp_client_terminal);
const acp = @import("module.zig");

/// One command this client is running for an agent.
///
/// Heap-allocated so its address is stable: the runner task holds a pointer to
/// it for as long as the command runs.
const Run = struct {
    const Self = @This();

    /// The id handed back to the agent. Owned.
    id: []u8,
    /// The process. Its pipes are read by the runner and closed by `wait`.
    child: std.process.Child,
    /// The process group to signal on kill; the child leads it.
    pid: std.process.Child.Id,
    /// Retained output, at most `limit` bytes. Guarded by `mutex`.
    output: std.ArrayList(u8) = .empty,
    /// The retention bound.
    limit: usize,
    /// Whether output was dropped to stay within `limit`. Guarded by `mutex`.
    truncated: bool = false,
    /// How the command ended; valid once `exited` is set.
    exit_status: acp.Client.TerminalExitStatus = .{},
    /// Set once the command has been reaped.
    exited: std.Io.Event = .unset,
    /// Guards `output` and `truncated` against the two pipe readers.
    mutex: std.Io.Mutex = .init,
    /// The runner: drains both pipes, then reaps the command.
    group: std.Io.Group = .init,
    /// Whether the runner was started, and so has to be awaited.
    running: bool = false,
};

/// Serves `terminal/create`.
const CreateHandler = struct {
    const Self = @This();

    // SAFETY: set by `ClientTerminal.register`.
    terminal: *ClientTerminal = undefined,

    pub const Params = acp.Client.CreateTerminalRequest;
    pub const Result = acp.Client.CreateTerminalResponse;

    /// Builds a handler bound to its surface.
    ///
    /// Parameters:
    /// - `terminal`: the surface served; borrowed, must outlive the handler.
    ///
    /// Return: the handler; never fails.
    pub fn init(terminal: *ClientTerminal) !Self {
        return .{ .terminal = terminal };
    }

    /// Releases the handler.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Answers `terminal/create`.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `allocator`: per-call arena; owns the returned id.
    /// - `params`: the command, arguments, environment, directory, and output bound.
    ///
    /// Return: the new terminal's id; `InvalidParams` when the command cannot start.
    pub fn handle(self: *Self, allocator: std.mem.Allocator, params: Params) acp.AcpError!Result {
        const id = self.terminal.create(params.command, params.args orelse &.{}, params.env orelse &.{}, params.cwd, params.outputByteLimit) catch |err| {
            log.warn("terminal/create {s} [{t}]", .{ params.command, err });
            return error.InvalidParams;
        };
        return .{ .terminalId = .{ .value = allocator.dupe(u8, id) catch return error.OutOfMemory } };
    }
};

/// Serves `terminal/output`.
const OutputHandler = struct {
    const Self = @This();

    // SAFETY: set by `ClientTerminal.register`.
    terminal: *ClientTerminal = undefined,

    pub const Params = acp.Client.TerminalOutputRequest;
    pub const Result = acp.Client.TerminalOutputResponse;

    /// Builds a handler bound to its surface.
    ///
    /// Parameters:
    /// - `terminal`: the surface served; borrowed, must outlive the handler.
    ///
    /// Return: the handler; never fails.
    pub fn init(terminal: *ClientTerminal) !Self {
        return .{ .terminal = terminal };
    }

    /// Releases the handler.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Answers `terminal/output`.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `allocator`: per-call arena; owns the returned output.
    /// - `params`: the terminal.
    ///
    /// Return: the retained output and, once it has exited, how; `InvalidParams` for an unknown id.
    pub fn handle(self: *Self, allocator: std.mem.Allocator, params: Params) acp.AcpError!Result {
        return self.terminal.snapshot(allocator, params.terminalId.value) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnknownTerminal => error.InvalidParams,
        };
    }
};

/// Serves `terminal/wait_for_exit`.
const WaitHandler = struct {
    const Self = @This();

    // SAFETY: set by `ClientTerminal.register`.
    terminal: *ClientTerminal = undefined,

    pub const Params = acp.Client.WaitForTerminalExitRequest;
    pub const Result = acp.Client.WaitForTerminalExitResponse;

    /// Builds a handler bound to its surface.
    ///
    /// Parameters:
    /// - `terminal`: the surface served; borrowed, must outlive the handler.
    ///
    /// Return: the handler; never fails.
    pub fn init(terminal: *ClientTerminal) !Self {
        return .{ .terminal = terminal };
    }

    /// Releases the handler.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Answers `terminal/wait_for_exit`, blocking until the command ends.
    ///
    /// Blocking is what the method means. It runs on whichever task is serving
    /// the client's connection, so a client whose connection shares a task with
    /// its screen should serve on another.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `allocator`: per-call arena; owns a signal name.
    /// - `params`: the terminal.
    ///
    /// Return: how the command ended; `InvalidParams` for an unknown id or a cancelled wait.
    pub fn handle(self: *Self, allocator: std.mem.Allocator, params: Params) acp.AcpError!Result {
        const status = self.terminal.waitForExit(allocator, params.terminalId.value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownTerminal, error.Canceled => return error.InvalidParams,
        };
        return .{ .exitStatus = status };
    }
};

/// Serves `terminal/kill`.
const KillHandler = struct {
    const Self = @This();

    // SAFETY: set by `ClientTerminal.register`.
    terminal: *ClientTerminal = undefined,

    pub const Params = acp.Client.KillTerminalRequest;
    pub const Result = acp.Client.KillTerminalResponse;

    /// Builds a handler bound to its surface.
    ///
    /// Parameters:
    /// - `terminal`: the surface served; borrowed, must outlive the handler.
    ///
    /// Return: the handler; never fails.
    pub fn init(terminal: *ClientTerminal) !Self {
        return .{ .terminal = terminal };
    }

    /// Releases the handler.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Answers `terminal/kill`: stops the command and keeps its output.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `allocator`: per-call arena; unused.
    /// - `params`: the terminal.
    ///
    /// Return: an empty result; `InvalidParams` for an unknown id.
    pub fn handle(self: *Self, _: std.mem.Allocator, params: Params) acp.AcpError!Result {
        self.terminal.kill(params.terminalId.value) catch return error.InvalidParams;
        return .{};
    }
};

/// Serves `terminal/release`.
const ReleaseHandler = struct {
    const Self = @This();

    // SAFETY: set by `ClientTerminal.register`.
    terminal: *ClientTerminal = undefined,

    pub const Params = acp.Client.ReleaseTerminalRequest;
    pub const Result = acp.Client.ReleaseTerminalResponse;

    /// Builds a handler bound to its surface.
    ///
    /// Parameters:
    /// - `terminal`: the surface served; borrowed, must outlive the handler.
    ///
    /// Return: the handler; never fails.
    pub fn init(terminal: *ClientTerminal) !Self {
        return .{ .terminal = terminal };
    }

    /// Releases the handler.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Answers `terminal/release`: kills the command if it still runs, and forgets it.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `allocator`: per-call arena; unused.
    /// - `params`: the terminal.
    ///
    /// Return: an empty result; `InvalidParams` for an unknown id.
    pub fn handle(self: *Self, _: std.mem.Allocator, params: Params) acp.AcpError!Result {
        self.terminal.release(params.terminalId.value) catch return error.InvalidParams;
        return .{};
    }
};

/// The terminal half of the client surface.
pub const ClientTerminal = struct {
    const Self = @This();

    /// Retained output per terminal when the agent names no bound. Every buffer
    /// here states its bound, and a command that prints forever must not grow
    /// the client forever.
    pub const default_output_limit: usize = 256 * 1024;

    /// Bytes read from a pipe at a time.
    const read_chunk_len = 4096;

    // SAFETY: set by `init` before the dispatcher can route anything here.
    allocator: std.mem.Allocator = undefined,
    // SAFETY: same.
    io: std.Io = undefined,
    /// The environment every command starts from; the request's `env` is laid over it. Borrowed.
    // SAFETY: same.
    environ_map: *const std.process.Environ.Map = undefined,

    /// Live terminals, each heap-allocated for a stable address. Guarded by
    /// `runs_mutex`, so `killAll` may run on another task than the one serving.
    runs: std.ArrayList(*Run) = .empty,
    runs_mutex: std.Io.Mutex = .init,
    /// Terminal ids are minted from this, so they are unique within a client.
    next_id: u32 = 1,

    create_handler_storage: CreateHandler = .{},
    output_handler_storage: OutputHandler = .{},
    wait_handler_storage: WaitHandler = .{},
    kill_handler_storage: KillHandler = .{},
    release_handler_storage: ReleaseHandler = .{},

    /// Builds the terminal surface.
    ///
    /// Parameters:
    /// - `allocator`: backs every terminal and its output; stored.
    /// - `io`: IO capability for spawning and reading; stored.
    /// - `environ_map`: the environment commands start from; borrowed, must outlive the surface.
    ///
    /// Return: the surface, unregistered until `register`; never fails.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !Self {
        return .{ .allocator = allocator, .io = io, .environ_map = environ_map };
    }

    /// Kills and reaps every terminal still held.
    ///
    /// An agent that never calls `terminal/release` should not leak a process,
    /// so teardown releases whatever is left.
    ///
    /// Parameters:
    /// - `self`: the surface.
    ///
    /// Return: nothing; never fails.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        for (self.runs.items) |run| self.destroyRun(run);
        self.runs.deinit(self.allocator);
    }

    /// Registers the five `terminal/*` methods on a dispatcher.
    ///
    /// Parameters:
    /// - `instance`: the surface; must outlive the dispatcher.
    /// - `dispatcher`: where to register.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn register(instance: *Self, dispatcher: *acp.Dispatcher) !void {
        instance.create_handler_storage.terminal = instance;
        instance.output_handler_storage.terminal = instance;
        instance.wait_handler_storage.terminal = instance;
        instance.kill_handler_storage.terminal = instance;
        instance.release_handler_storage.terminal = instance;
        try dispatcher.registerRequest(acp.Client.method_terminal_create, CreateHandler, &instance.create_handler_storage);
        try dispatcher.registerRequest(acp.Client.method_terminal_output, OutputHandler, &instance.output_handler_storage);
        try dispatcher.registerRequest(acp.Client.method_terminal_wait_for_exit, WaitHandler, &instance.wait_handler_storage);
        try dispatcher.registerRequest(acp.Client.method_terminal_kill, KillHandler, &instance.kill_handler_storage);
        try dispatcher.registerRequest(acp.Client.method_terminal_release, ReleaseHandler, &instance.release_handler_storage);
    }

    /// Starts a command and returns its terminal id.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `command`: the program; resolved on `PATH` when it has no slash.
    /// - `args`: its arguments.
    /// - `env`: variables laid over the surface's environment.
    /// - `cwd`: the directory to run in, or null for the client's own.
    /// - `output_limit`: bytes of output to retain, or null for `default_output_limit`.
    ///
    /// Return: the id, borrowed from the surface until `release`; propagates spawn and allocation failures.
    pub fn create(self: *Self, command: []const u8, args: []const []const u8, env: []const acp.Client.TerminalEnv, cwd: ?[]const u8, output_limit: ?u64) ![]const u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const argv = try self.allocator.alloc([]const u8, args.len + 1);
        defer self.allocator.free(argv);
        argv[0] = command;
        @memcpy(argv[1..], args);

        var environ_map = std.process.Environ.Map.init(self.allocator);
        defer environ_map.deinit();
        var inherited = self.environ_map.iterator();
        while (inherited.next()) |entry| try environ_map.put(entry.key_ptr.*, entry.value_ptr.*);
        for (env) |variable| try environ_map.put(variable.name, variable.value);

        const run = try self.allocator.create(Run);
        errdefer self.allocator.destroy(run);

        const id = try std.fmt.allocPrint(self.allocator, "term-{d}", .{self.next_id});
        errdefer self.allocator.free(id);

        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &environ_map,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            // Its own group, so a kill reaches whatever the command started.
            .pgid = 0,
        });
        errdefer child.kill(self.io);

        run.* = .{
            .id = id,
            .child = child,
            .pid = child.id.?,
            .limit = @intCast(@min(output_limit orelse default_output_limit, std.math.maxInt(usize))),
        };

        {
            self.runs_mutex.lockUncancelable(self.io);
            defer self.runs_mutex.unlock(self.io);
            try self.runs.append(self.allocator, run);
        }
        errdefer self.forget(run);

        try run.group.concurrent(self.io, runCommand, .{ self, run });
        run.running = true;
        self.next_id += 1;

        return id;
    }

    /// Copies out a terminal's retained output, and how it ended if it has.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `allocator`: owns the returned output and signal name.
    /// - `id`: the terminal.
    ///
    /// Return: the output response; `error.UnknownTerminal`, or propagates allocation failure.
    pub fn snapshot(self: *Self, allocator: std.mem.Allocator, id: []const u8) !acp.Client.TerminalOutputResponse {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const run = self.find(id) orelse return error.UnknownTerminal;

        // Read before the lock: once set, nothing else is appended, so an exit
        // seen here is never reported beside output that is still growing.
        const exited = run.exited.isSet();

        run.mutex.lockUncancelable(self.io);
        defer run.mutex.unlock(self.io);

        return .{
            .output = try allocator.dupe(u8, run.output.items),
            .truncated = run.truncated,
            .exitStatus = if (exited) try copyStatus(allocator, run.exit_status) else null,
        };
    }

    /// Blocks until a terminal's command has ended.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `allocator`: owns the returned signal name.
    /// - `id`: the terminal.
    ///
    /// Return: how it ended; `error.UnknownTerminal`, `error.Canceled`, or propagates allocation failure.
    pub fn waitForExit(self: *Self, allocator: std.mem.Allocator, id: []const u8) !acp.Client.TerminalExitStatus {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const run = self.find(id) orelse return error.UnknownTerminal;
        try run.exited.wait(self.io);
        return copyStatus(allocator, run.exit_status);
    }

    /// Stops a terminal's command and everything it started, keeping its output.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `id`: the terminal.
    ///
    /// Return: nothing; `error.UnknownTerminal` for an id this surface does not hold.
    pub fn kill(self: *Self, id: []const u8) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const run = self.find(id) orelse return error.UnknownTerminal;
        signalGroup(run);
    }

    /// Kills a terminal's command if it still runs, then forgets the terminal.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `id`: the terminal; invalid afterwards.
    ///
    /// Return: nothing; `error.UnknownTerminal` for an id this surface does not hold.
    pub fn release(self: *Self, id: []const u8) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const run = self.find(id) orelse return error.UnknownTerminal;
        self.forget(run);
        self.destroyRun(run);
    }

    /// Stops every terminal's command, keeping their output.
    ///
    /// Callable from any task, which is what it is for: a client cancelling a
    /// turn from its UI while the task serving the agent is blocked in
    /// `terminal/wait_for_exit`. Killing the command is what ends that wait.
    ///
    /// Parameters:
    /// - `self`: the surface.
    ///
    /// Return: nothing.
    pub fn killAll(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.runs_mutex.lockUncancelable(self.io);
        defer self.runs_mutex.unlock(self.io);
        for (self.runs.items) |run| {
            if (!run.exited.isSet()) signalGroup(run);
        }
    }

    /// Removes a terminal from the list without freeing it.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `run`: the terminal.
    ///
    /// Return: nothing.
    fn forget(self: *Self, run: *Run) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.runs_mutex.lockUncancelable(self.io);
        defer self.runs_mutex.unlock(self.io);
        for (self.runs.items, 0..) |candidate, index| {
            if (candidate != run) continue;
            _ = self.runs.orderedRemove(index);
            return;
        }
    }

    /// Finds a terminal by id.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `id`: the terminal's id.
    ///
    /// Return: the terminal, or null.
    fn find(self: *Self, id: []const u8) ?*Run {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.runs_mutex.lockUncancelable(self.io);
        defer self.runs_mutex.unlock(self.io);
        for (self.runs.items) |run| {
            if (std.mem.eql(u8, run.id, id)) return run;
        }
        return null;
    }

    /// Kills a terminal if it runs, waits for its runner, and frees it.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `run`: the terminal, already out of `runs`; freed.
    ///
    /// Return: nothing.
    fn destroyRun(self: *Self, run: *Run) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (run.running) {
            if (!run.exited.isSet()) signalGroup(run);
            // The runner reaps the command and returns; nothing else here is
            // cancellable, so an await that is cancelled has nothing to leak.
            run.group.await(self.io) catch |err| log.warn("terminal {s} runner did not join [{t}]", .{ run.id, err });
        }
        if (run.exit_status.signal) |name| self.allocator.free(name);
        run.output.deinit(self.allocator);
        self.allocator.free(run.id);
        self.allocator.destroy(run);
    }

    /// Drains a command's pipes, then reaps it. Runs on its own task.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `run`: the terminal; outlives this task.
    ///
    /// Return: nothing; failures are logged and reported as an unknown exit.
    fn runCommand(self: *Self, run: *Run) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // Both pipes, read at once: a command that fills stderr while this
        // waits on stdout would otherwise block forever.
        var readers: std.Io.Group = .init;
        if (run.child.stderr) |file| {
            readers.concurrent(self.io, drain, .{ self, run, file }) catch |err| {
                log.warn("terminal {s}: no stderr reader [{t}]", .{ run.id, err });
            };
        }
        if (run.child.stdout) |file| self.drain(run, file);
        readers.await(self.io) catch |err| log.warn("terminal {s}: stderr reader did not join [{t}]", .{ run.id, err });

        const term = run.child.wait(self.io) catch |err| blk: {
            log.warn("terminal {s}: wait failed [{t}]", .{ run.id, err });
            run.child.kill(self.io);
            break :blk null;
        };

        if (term) |value| switch (value) {
            .exited => |code| run.exit_status = .{ .exitCode = code },
            .signal => |sig| run.exit_status = .{ .signal = self.allocator.dupe(u8, signalName(sig)) catch null },
            .stopped, .unknown => {},
        };
        run.exited.set(self.io);
    }

    /// Reads one pipe to its end into a terminal's retained output.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `run`: the terminal.
    /// - `file`: the pipe; owned by the child, not closed here.
    ///
    /// Return: nothing; a read failure ends the read and is logged.
    ///
    /// No entry trace: it logs once per task, but its loop is the hot path
    /// and every other function here traces on entry already.
    fn drain(self: *Self, run: *Run, file: std.Io.File) void {
        var buffer: [read_chunk_len]u8 = undefined;
        while (true) {
            const count = file.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => return,
                else => {
                    log.warn("terminal {s}: read failed [{t}]", .{ run.id, err });
                    return;
                },
            };
            if (count == 0) continue;

            run.mutex.lockUncancelable(self.io);
            defer run.mutex.unlock(self.io);
            appendBounded(self.allocator, &run.output, run.limit, buffer[0..count], &run.truncated) catch {
                log.warn("terminal {s}: out of memory; output dropped", .{run.id});
            };
        }
    }

    /// Appends to a buffer, dropping its oldest bytes to stay within a bound.
    ///
    /// The cut lands on a character boundary, as ACP asks, so the retained text
    /// never opens on half a UTF-8 sequence.
    ///
    /// Parameters:
    /// - `allocator`: the buffer's allocator.
    /// - `output`: the buffer.
    /// - `limit`: the most it may hold.
    /// - `bytes`: what to append.
    /// - `truncated`: set when anything is dropped.
    ///
    /// Return: nothing; propagates allocation failure.
    fn appendBounded(allocator: std.mem.Allocator, output: *std.ArrayList(u8), limit: usize, bytes: []const u8, truncated: *bool) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try output.appendSlice(allocator, bytes);
        if (output.items.len <= limit) return;

        var cut = output.items.len - limit;
        while (cut < output.items.len and (output.items[cut] & 0xC0) == 0x80) cut += 1;
        output.replaceRangeAssumeCapacity(0, cut, &.{});
        truncated.* = true;
    }

    /// Copies an exit status so it outlives the terminal it came from.
    ///
    /// Parameters:
    /// - `allocator`: owns the copied signal name.
    /// - `status`: the status.
    ///
    /// Return: the copy; propagates allocation failure.
    fn copyStatus(allocator: std.mem.Allocator, status: acp.Client.TerminalExitStatus) !acp.Client.TerminalExitStatus {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return .{
            .exitCode = status.exitCode,
            .signal = if (status.signal) |name| try allocator.dupe(u8, name) else null,
        };
    }

    /// Sends `SIGKILL` to a terminal's process group.
    ///
    /// `std.posix.kill` is irreplaceable here: `std.Io` has no signal-by-pid,
    /// and `Child.kill` reaches only the leader and needs the `Child` the runner
    /// is waiting on.
    ///
    /// Parameters:
    /// - `run`: the terminal.
    ///
    /// Return: nothing; a failure (the group already gone) is logged.
    fn signalGroup(run: *Run) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (comptime builtin.os.tag == .windows) {
            log.warn("terminal {s}: kill is not supported on Windows", .{run.id});
            return;
        }
        std.posix.kill(-run.pid, .KILL) catch |err| log.debug("terminal {s}: kill [{t}]", .{ run.id, err });
    }

    /// Names a signal the way ACP reports one.
    ///
    /// Parameters:
    /// - `sig`: the signal.
    ///
    /// Return: its `SIG`-prefixed name, static; `SIGUNKNOWN` for one without a name.
    fn signalName(sig: std.posix.SIG) []const u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return switch (sig) {
            .HUP => "SIGHUP",
            .INT => "SIGINT",
            .QUIT => "SIGQUIT",
            .ABRT => "SIGABRT",
            .KILL => "SIGKILL",
            .SEGV => "SIGSEGV",
            .PIPE => "SIGPIPE",
            .ALRM => "SIGALRM",
            .TERM => "SIGTERM",
            else => "SIGUNKNOWN",
        };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ClientTerminal);
}

/// Builds a terminal surface over an empty environment plus `PATH`.
///
/// Parameters:
/// - `environ_map`: the environment to fill; owned by the caller.
///
/// Return: the surface; propagates allocation failure.
fn testTerminal(environ_map: *std.process.Environ.Map) !ClientTerminal {
    try environ_map.put("PATH", "/usr/bin:/bin");
    return ClientTerminal.init(std.testing.allocator, std.testing.io, environ_map);
}

test "a command's output and exit code come back" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    var terminal = try testTerminal(&environ_map);
    defer terminal.deinit();

    const id = try terminal.create("/bin/sh", &.{ "-c", "echo out; echo err 1>&2; exit 3" }, &.{}, null, null);

    const status = try terminal.waitForExit(allocator, id);
    try std.testing.expectEqual(@as(?i32, 3), status.exitCode);

    const output = try terminal.snapshot(allocator, id);
    defer allocator.free(output.output);

    // Merged, in whichever order the two pipes delivered.
    try std.testing.expect(std.mem.indexOf(u8, output.output, "out\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.output, "err\n") != null);
    try std.testing.expect(!output.truncated);
    try std.testing.expectEqual(@as(?i32, 3), output.exitStatus.?.exitCode);

    try terminal.release(id);
    try std.testing.expectError(error.UnknownTerminal, terminal.release(id));
}

test "the request's environment and directory reach the command" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    var terminal = try testTerminal(&environ_map);
    defer terminal.deinit();

    const id = try terminal.create("/bin/sh", &.{ "-c", "printf '%s:' \"$GREETING\"; pwd" }, &.{.{ .name = "GREETING", .value = "hello" }}, "/", null);
    _ = try terminal.waitForExit(allocator, id);

    const output = try terminal.snapshot(allocator, id);
    defer allocator.free(output.output);
    try std.testing.expectEqualStrings("hello:/\n", output.output);
}

test "output past the bound keeps the newest bytes and says so" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    var terminal = try testTerminal(&environ_map);
    defer terminal.deinit();

    const id = try terminal.create("/bin/sh", &.{ "-c", "printf 'abcdefghij'" }, &.{}, null, 4);
    _ = try terminal.waitForExit(allocator, id);

    const output = try terminal.snapshot(allocator, id);
    defer allocator.free(output.output);
    try std.testing.expectEqualStrings("ghij", output.output);
    try std.testing.expect(output.truncated);
}

test "a truncation never splits a character" {
    const allocator = std.testing.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var truncated = false;

    // "é" is two bytes. A three-byte bound would keep its second byte alone,
    // so the cut moves past it instead.
    try ClientTerminal.appendBounded(allocator, &output, 3, "abé" ++ "cd", &truncated);
    try std.testing.expect(truncated);
    try std.testing.expectEqualStrings("cd", output.items);
}

test "kill stops a command and everything it started" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    var terminal = try testTerminal(&environ_map);
    defer terminal.deinit();

    // The shell forks `sleep`, so killing only the shell would leave the pipe
    // open and the wait below blocked for a minute.
    const id = try terminal.create("/bin/sh", &.{ "-c", "echo started; sleep 60; echo never" }, &.{}, null, null);

    try terminal.kill(id);
    const status = try terminal.waitForExit(allocator, id);
    defer if (status.signal) |name| allocator.free(name);
    try std.testing.expectEqualStrings("SIGKILL", status.signal.?);

    // Kill keeps the terminal, and its output, until release.
    const output = try terminal.snapshot(allocator, id);
    defer allocator.free(output.output);
    defer if (output.exitStatus.?.signal) |name| allocator.free(name);
    try std.testing.expect(std.mem.indexOf(u8, output.output, "never") == null);
}

test "teardown reaps a terminal the agent never released" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    var terminal = try testTerminal(&environ_map);

    _ = try terminal.create("/bin/sh", &.{ "-c", "sleep 60" }, &.{}, null, null);

    // std.testing.allocator fails the test if anything here leaks.
    terminal.deinit();
}

test "an unknown terminal is an error, not an empty answer" {
    const allocator = std.testing.allocator;

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    var terminal = try testTerminal(&environ_map);
    defer terminal.deinit();

    try std.testing.expectError(error.UnknownTerminal, terminal.snapshot(allocator, "term-9"));
    try std.testing.expectError(error.UnknownTerminal, terminal.kill("term-9"));
    try std.testing.expectError(error.UnknownTerminal, terminal.waitForExit(allocator, "term-9"));
}

test "a command that cannot start is refused" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    var terminal = try testTerminal(&environ_map);
    defer terminal.deinit();

    try std.testing.expectError(error.FileNotFound, terminal.create("/definitely/not/a/program", &.{}, &.{}, null, null));
    try std.testing.expectEqual(@as(usize, 0), terminal.runs.items.len);
}

test "killAll stops every command and keeps the terminals" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    var terminal = try testTerminal(&environ_map);
    defer terminal.deinit();

    const first = try terminal.create("/bin/sh", &.{ "-c", "sleep 60" }, &.{}, null, null);
    const second = try terminal.create("/bin/sh", &.{ "-c", "sleep 60" }, &.{}, null, null);
    terminal.killAll();

    for ([_][]const u8{ first, second }) |id| {
        const status = try terminal.waitForExit(allocator, id);
        defer if (status.signal) |name| allocator.free(name);
        try std.testing.expectEqualStrings("SIGKILL", status.signal.?);
    }
    try std.testing.expectEqual(@as(usize, 2), terminal.runs.items.len);
}
