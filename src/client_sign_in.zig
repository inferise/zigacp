//! Signing an agent's account in, from either front end.
//!
//! The agent does the work (`_inferise/sign_in`): it runs its CLI's own
//! sign-in and says what the person must do — open a page, type a code there,
//! perhaps paste one back. This runs that exchange on a task of its own, over a
//! client that has shaken hands and opened no session (an account that is not
//! signed in could not open one), which the caller's `SignInAgent` starts:
//! starting the agent and its first answer take seconds, and each poll waits a
//! couple more, which no front end's loop can block on. A front end reads
//! `view` each frame and passes a pasted code with `submitCode`.

const std = @import("std");
const log = std.log.scoped(.acp_client_sign_in);
const acp = @import("module.zig");

/// Where a sign-in stands.
pub const SignInPhase = enum {
    /// The agent is starting and has not said what to open yet.
    starting,
    /// The person has a page to open and, perhaps, a code to paste back.
    waiting,
    /// The account is signed in.
    signedIn,
    /// It ended without signing in; the summary says why.
    failed,
};

/// How a sign-in reaches its agent: a client that has shaken hands and opened no session.
///
/// Called on the sign-in's own task, so `connect` may take seconds.
pub const SignInAgent = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Starts the agent, or reuses one, and returns a client that has shaken hands.
        connect: *const fn (ctx: *anyopaque) acp.AcpError!*acp.Client.Session,
        /// Lets go of what `connect` returned, once the exchange is over.
        release: *const fn (ctx: *anyopaque) void,
    };

    /// Returns a client ready to sign in.
    ///
    /// Parameters:
    /// - `self`: the agent.
    ///
    /// Return: the client, borrowed until `release`; propagates the agent's failures.
    pub fn connect(self: Self) acp.AcpError!*acp.Client.Session {
        return self.vtable.connect(self.ptr);
    }

    /// Lets go of the client.
    ///
    /// Parameters:
    /// - `self`: the agent.
    ///
    /// Return: nothing.
    pub fn release(self: Self) void {
        self.vtable.release(self.ptr);
    }
};

/// What a front end shows: a copy, owned by the arena it was asked into.
pub const SignInView = struct {
    const Self = @This();

    phase: SignInPhase,
    /// The account, as the agent will list it; empty for the default before the agent has named it.
    account: []const u8,
    /// The page to open, or empty.
    url: []const u8,
    /// A code to type on that page, or empty.
    user_code: []const u8,
    /// Whether the page hands back a code to paste.
    needs_code: bool,
    /// The agent's last word: why it failed, or what it said; empty when nothing.
    summary: []const u8,
};

/// One sign-in, from the agent's start to its end.
pub const ClientSignIn = struct {
    const Self = @This();

    /// How long to wait between polls; each poll already waits on the agent.
    const poll_gap_ms = 250;

    allocator: std.mem.Allocator,
    io: std.Io,
    /// Reaches the agent; borrowed, must outlive the sign-in.
    agent: SignInAgent,
    /// The agent's short name, for logs. Owned.
    label: []u8,
    /// The account asked for, or null for the default. Owned.
    requested: ?[]u8,
    /// Guards everything below between the task and the front end.
    mutex: std.Io.Mutex = .init,
    /// Owns the strings below.
    arena: std.heap.ArenaAllocator,
    phase: SignInPhase = .starting,
    account: []const u8 = "",
    url: []const u8 = "",
    user_code: []const u8 = "",
    needs_code: bool = false,
    summary: []const u8 = "",
    /// A code the person pasted, waiting for the task to pass it on. Owned by `arena`.
    code: ?[]const u8 = null,
    /// Set by `deinit`: the task cancels the sign-in and stops.
    stopping: std.atomic.Value(bool) = .init(false),
    group: std.Io.Group = .init,

    /// Starts a sign-in on a task of its own; returns at once.
    ///
    /// Parameters:
    /// - `allocator`: backs the sign-in; must outlive it.
    /// - `io`: IO capability for the task.
    /// - `agent`: how the sign-in reaches its agent; borrowed, must outlive the sign-in.
    /// - `label`: the agent's short name, for logs; copied.
    /// - `account`: the account's name, a new name to create it, or null for the default; copied.
    ///
    /// Return: the sign-in, `starting`; `deinit` when done; propagates allocation failure.
    pub fn begin(allocator: std.mem.Allocator, io: std.Io, agent: SignInAgent, label: []const u8, account: ?[]const u8) acp.AcpError!*Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const owned_label = try allocator.dupe(u8, label);
        errdefer allocator.free(owned_label);
        const requested = if (account) |name| try allocator.dupe(u8, name) else null;
        errdefer if (requested) |name| allocator.free(name);
        const self = try allocator.create(Self);
        self.* = .{ .allocator = allocator, .io = io, .agent = agent, .label = owned_label, .requested = requested, .arena = .init(allocator) };
        self.group.concurrent(io, run, .{self}) catch {
            self.group.async(io, run, .{self});
        };
        return self;
    }

    /// Stops the sign-in if it is still running, waits for its task, and frees it.
    ///
    /// Parameters:
    /// - `self`: the sign-in; invalid afterwards.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.stopping.store(true, .release);
        self.group.await(self.io) catch |err| log.warn("the sign-in task did not join cleanly [{t}]", .{err});
        self.arena.deinit();
        if (self.requested) |name| self.allocator.free(name);
        self.allocator.free(self.label);
        self.allocator.destroy(self);
    }

    /// Copies where the sign-in stands.
    ///
    /// Parameters:
    /// - `self`: the sign-in.
    /// - `arena`: owns the copy.
    ///
    /// Return: the view; propagates allocation failure.
    pub fn view(self: *Self, arena: std.mem.Allocator) std.mem.Allocator.Error!SignInView {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .phase = self.phase,
            .account = try arena.dupe(u8, if (self.account.len > 0) self.account else self.requested orelse ""),
            .url = try arena.dupe(u8, self.url),
            .user_code = try arena.dupe(u8, self.user_code),
            .needs_code = self.needs_code,
            .summary = try arena.dupe(u8, self.summary),
        };
    }

    /// Hands the task a code the person pasted, for its next poll.
    ///
    /// Parameters:
    /// - `self`: the sign-in.
    /// - `code`: what the page showed; copied, surrounding whitespace dropped.
    ///
    /// Return: nothing; `error.NotWaiting` before the page is known or after the end; propagates allocation failure.
    pub fn submitCode(self: *Self, code: []const u8) error{ NotWaiting, OutOfMemory }!void {
        const trimmed = std.mem.trim(u8, code, " \t\r\n");
        if (trimmed.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.phase != .waiting) return error.NotWaiting;
        self.code = try self.arena.allocator().dupe(u8, trimmed);
        self.summary = "Checking the code…";
    }

    /// The task: starts the agent, asks it to sign in, and polls until the end or `deinit`.
    ///
    /// Parameters:
    /// - `self`: the sign-in.
    ///
    /// Return: nothing; every failure ends the sign-in as `failed`, with why.
    fn run(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.exchange() catch |err| {
            log.warn("{s} sign-in failed [{t}]", .{ self.label, err });
            self.settle(.failed, switch (err) {
                error.NotOffered => "This agent does not sign accounts in here.",
                error.InvalidParams => "That is not a name this agent can give an account.",
                else => "The agent could not run its sign-in; ^L shows the log.",
            });
        };
    }

    /// The exchange itself, over a session-less client held for its length.
    ///
    /// Parameters:
    /// - `self`: the sign-in.
    ///
    /// Return: nothing once settled; propagates the agent's failures.
    fn exchange(self: *Self) !void {
        const client = try self.agent.connect();
        defer self.agent.release();

        const answer = try client.signIn(self.requested);
        defer answer.deinit();
        const got = answer.value;
        const account: ?[]const u8 = got.account orelse self.requested;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const arena = self.arena.allocator();
            self.account = try arena.dupe(u8, account orelse "");
            self.url = try arena.dupe(u8, got.url orelse "");
            self.user_code = try arena.dupe(u8, got.user_code orelse "");
            self.needs_code = got.needs_code;
            self.summary = try arena.dupe(u8, got.summary orelse "");
            self.phase = .waiting;
        }
        log.info("signing {s} {s} in", .{ self.label, account orelse "(default)" });

        while (!self.stopping.load(.acquire)) {
            const code = self.takeCode();
            const finished = try client.signInFinish(account, code);
            defer finished.deinit();
            if (finished.value.waiting) {
                if (finished.value.summary) |text| self.note(text);
                self.io.sleep(.fromMilliseconds(poll_gap_ms), .awake) catch break;
                continue;
            }
            const said = finished.value.summary orelse "";
            self.settle(if (finished.value.signed_in) .signedIn else .failed, said);
            return;
        }
        client.signInCancel(account) catch |err| log.debug("sign-in not cancelled [{t}]", .{err});
    }

    /// Takes the pasted code, if any.
    ///
    /// Parameters:
    /// - `self`: the sign-in.
    ///
    /// Return: the code, owned by the arena; null when none waits.
    fn takeCode(self: *Self) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        defer self.code = null;
        return self.code;
    }

    /// Keeps what the agent said while waiting.
    ///
    /// Parameters:
    /// - `self`: the sign-in.
    /// - `text`: the agent's words; copied.
    ///
    /// Return: nothing; a copy that cannot be made is dropped.
    fn note(self: *Self, text: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.summary = self.arena.allocator().dupe(u8, text) catch return;
    }

    /// Ends the sign-in.
    ///
    /// Parameters:
    /// - `self`: the sign-in.
    /// - `phase`: `signedIn` or `failed`.
    /// - `text`: what to say; copied.
    ///
    /// Return: nothing.
    fn settle(self: *Self, phase: SignInPhase, text: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.phase = phase;
        self.summary = self.arena.allocator().dupe(u8, text) catch "";
        log.info("{s} sign-in {s}", .{ self.label, @tagName(phase) });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ClientSignIn);
}

test "an agent that cannot be reached ends the sign-in as failed, saying so" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const Gone = struct {
        fn connect(ctx: *anyopaque) acp.AcpError!*acp.Client.Session {
            _ = ctx;
            return error.AgentGone;
        }
        fn release(ctx: *anyopaque) void {
            _ = ctx;
        }
        const vtable: SignInAgent.VTable = .{ .connect = connect, .release = release };
    };
    var unused: u8 = 0;
    const sign_in = try ClientSignIn.begin(allocator, io, .{ .ptr = &unused, .vtable = &Gone.vtable }, "test", null);
    defer sign_in.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var waited: usize = 0;
    var seen = try sign_in.view(arena_state.allocator());
    while (seen.phase == .starting and waited < 200) : (waited += 1) {
        try io.sleep(.fromMilliseconds(50), .awake);
        seen = try sign_in.view(arena_state.allocator());
    }
    try std.testing.expectEqual(SignInPhase.failed, seen.phase);
    try std.testing.expectError(error.NotWaiting, sign_in.submitCode("1234"));
}
