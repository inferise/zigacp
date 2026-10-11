//! A front end's view of one agent's ACP session.
//!
//! One of these per live agent. It speaks ACP and never names a harness, so the
//! same code drives every agent — the only thing that varies is which agent is
//! on the far end of its transport, and the label it was given for it.
//!
//! **What it owns, and what it does not.** It owns `live`: the turn being
//! streamed right now, or the last one completed while idle. It does **not** own
//! the history. Several agents may stream at once, and if all appended deltas to
//! one buffer the result would be alternating half-sentences — so the finished
//! turn is handed to the caller's `acp.Client.History` in a single append and
//! the interleaving becomes a question of which turn finished, not which delta
//! arrived.
//!
//! **Direction is pushed, not polled.** Updates arrive as notifications and a
//! permission arrives as a call that must be answered, so the turn is assembled
//! by handlers rather than fetched by a draw loop.
//!
//! Two things stay local rather than travelling. The running `MM:SS` clock is
//! computed from the submit time, because the client knows when it sent and a
//! round trip would buy nothing. And the accounting line is drawn from
//! `_meta.inferise` if the agent sent it — one shape for every agent — and an
//! agent that sent none gets no accounting line rather than a row of zeroes.
//!
//! **A replay is not a turn.** An agent that answers `session/load` by
//! replaying its history as `session/update`s would otherwise have that history
//! drawn as if it were streaming now. Backlog replay is out of contract, so
//! updates that arrive while this client's own `session/load` is in flight are
//! dropped.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.acp_client_session);
const acp = @import("module.zig");

/// What serves `terminal/*`: a pseudoterminal where `openpty` exists, plain pipes on Windows (`README.md`, "Every client").
const ClientTerminal = if (builtin.os.tag == .windows) acp.Client.Terminal else acp.Client.PtyTerminal;

/// One answer the operator may give to a pending permission.
pub const PermissionChoice = struct {
    const Self = @This();

    /// The option id the agent offered. Owned.
    id: []u8,
    kind: acp.Client.PermissionOptionKind,
};

/// A question an agent is blocked on, waiting for the operator.
pub const PendingPermission = struct {
    const Self = @This();

    /// What is being asked about. Owned.
    summary: []u8,
    /// The option ids the agent offered, in the order it offered them. Owned.
    options: [4]?PermissionChoice = @splat(null),
};

/// What the operator chose.
pub const Answer = enum {
    allowOnce,
    allowAlways,
    rejectOnce,
    rejectAlways,
};

/// One slash command the session offers (`available_commands_update`).
pub const SessionCommand = struct {
    const Self = @This();

    name: []const u8,
    description: []const u8,
};

/// One step of the agent's plan (`plan` update).
pub const PlanStep = struct {
    const Self = @This();

    content: []const u8,
    /// `pending`, `in_progress` or `completed`, as ACP spells them.
    status: []const u8,
};

/// How much of its context window the session fills (`usage_update`).
pub const ContextUse = struct {
    const Self = @This();

    used: u64,
    size: u64,
};

/// What a session's agent said beyond its turns: commands, plan, context. Every slice is the caller's copy.
pub const SessionExtras = struct {
    const Self = @This();

    commands: []const SessionCommand = &.{},
    plan: []const PlanStep = &.{},
    context: ?ContextUse = null,
};

/// What the agent's `initialize` offered that a front end draws by.
pub const AgentOffer = struct {
    const Self = @This();

    /// `promptCapabilities.image`: a prompt may carry images.
    images: bool = false,
    /// `loadSession`: a session can be reopened.
    loads_session: bool = false,
    /// `_inferise/status` is served.
    status: bool = false,
    /// `_inferise/accounts` is served.
    accounts: bool = false,
    /// `_inferise/sign_in` and its follow-ups are served.
    sign_in: bool = false,
    /// The agent's advertised actions (`_meta.inferise.extensions`).
    extensions: []const acp.Inferise.Extension = &.{},
};

/// A stretch of a client's conversation record.
pub const RecordPage = struct {
    const Self = @This();

    /// Each entry's JSON: an ACP `session/update`, or `{"note":…}`.
    entries: []const []const u8,
    /// The position after the last entry: where to resume.
    next: usize,
    /// The reader's place was dropped or replaced: what it holds is stale, and `entries` is everything kept.
    restarted: bool,
};

/// An image attached to a prompt, as ACP carries it.
pub const PromptImage = struct {
    const Self = @This();

    mime_type: []const u8,
    /// The image, base64.
    data: []const u8,
};

/// A config option's new value: a select's choice, or a boolean.
pub const OptionValue = union(enum) {
    choice: []const u8,
    enabled: bool,
};

const UpdateHandler = struct {
    const Self = @This();

    // SAFETY: set by `ClientSession.start`.
    client: *ClientSession = undefined,

    pub const Params = acp.Agent.SessionNotification;

    /// Records one session update into the owning client's live turn.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `_`: unused.
    /// - `params`: the notification; borrowed for the call.
    ///
    /// Return: nothing; unmodelled updates are ignored; OutOfMemory on allocation failure.
    pub fn handle(self: *Self, _: std.mem.Allocator, params: Params) acp.AcpError!void {
        const client = self.client;

        client.mutex.lockUncancelable(client.io);
        defer client.mutex.unlock(client.io);

        // Replayed or live, the conversation's record takes it as ACP said it;
        // a plan is both conversation and state.
        client.recordUpdate(params.update) catch return error.OutOfMemory;

        // What the session can be switched between changes whenever the agent
        // says, replay or not.
        switch (params.update) {
            .currentModeUpdate => |update| return client.settings.takeMode(update.current_mode_id) catch error.OutOfMemory,
            .configOptionUpdate => |update| return client.settings.takeOptions(update.config_options) catch error.OutOfMemory,
            // State, not a turn: the latest replaces what came before, replay or not.
            .availableCommandsUpdate => |update| return client.takeCommands(update.available_commands) catch error.OutOfMemory,
            .plan => |update| return client.takePlan(update.plan.entries) catch error.OutOfMemory,
            .usageUpdate => |update| {
                client.context = .{ .used = update.used, .size = update.size };
                return;
            },
            else => {},
        }

        // History an agent replays for our own `session/load` is not a turn
        // happening now: it is gathered as the conversation's past (S8).
        if (client.loading.load(.acquire)) return client.gatherReplay(params.update) catch error.OutOfMemory;

        switch (params.update) {
            .agentMessageChunk => |chunk| switch (chunk.content) {
                .text => |text| client.append(text.text) catch return error.OutOfMemory,
                else => {},
            },
            // Codex streams reasoning separately from its answer; Claude sends
            // none. Drawn distinctly rather than mixed into the reply.
            .agentThoughtChunk => |chunk| switch (chunk.content) {
                .text => |text| {
                    client.append("\n  · ") catch return error.OutOfMemory;
                    client.append(text.text) catch return error.OutOfMemory;
                    client.append("\n") catch return error.OutOfMemory;
                },
                else => {},
            },
            .toolCall => |call| {
                // SAFETY: written by bufPrint before it is read.
                var line: [512]u8 = undefined;
                const rendered = std.fmt.bufPrint(&line, "\n  ⚙ {s}\n", .{call.title}) catch return;
                client.append(rendered) catch return error.OutOfMemory;
                client.appendDiffs(call.content) catch return error.OutOfMemory;
            },
            // A diff often arrives with the call's completion rather than its start.
            .toolCallUpdate => |update| client.appendDiffs(update.content) catch return error.OutOfMemory,
            // Anything a newer agent sends is skipped rather than guessed at.
            else => {},
        }
    }
};

const PermissionHandler = struct {
    const Self = @This();

    // SAFETY: set by `ClientSession.start`.
    client: *ClientSession = undefined,

    pub const Params = acp.Client.RequestPermissionRequest;
    pub const Result = acp.Client.RequestPermissionResponse;

    /// Poses an agent's permission request to the operator and returns the decision.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `allocator`: per-call arena; owns the returned option id.
    /// - `params`: what the agent is asking about; borrowed for the call.
    ///
    /// Return: the chosen option, or cancelled if none matches; OutOfMemory on allocation failure.
    pub fn handle(self: *Self, allocator: std.mem.Allocator, params: Params) acp.AcpError!Result {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const client = self.client;

        // What a person can read: the call's title when the agent sent one, else its id.
        const summary = client.allocator.dupe(u8, params.toolCall.title orelse params.toolCall.toolCallId.value) catch
            return error.OutOfMemory;

        client.mutex.lockUncancelable(client.io);
        defer client.mutex.unlock(client.io);

        var request = PendingPermission{ .summary = summary };
        for (params.options, 0..) |option, index| {
            if (index >= request.options.len) break;
            request.options[index] = .{
                .id = client.allocator.dupe(u8, option.optionId) catch return error.OutOfMemory,
                .kind = option.kind,
            };
        }
        client.pending = request;
        client.answer_given = null;
        client.awaiting.store(true, .release);

        defer {
            client.releasePending(&request);
            client.pending = null;
            client.answer_given = null;
            client.awaiting.store(false, .release);
        }

        while (client.answer_given == null) {
            client.answered.waitUncancelable(client.io, &client.mutex);
        }

        const chosen = client.answer_given.?;
        for (request.options) |maybe| {
            const option = maybe orelse continue;
            if (matches(option.kind, chosen)) {
                return .{ .outcome = .{ .selected = .{
                    .optionId = allocator.dupe(u8, option.id) catch return error.OutOfMemory,
                } } };
            }
        }

        // The agent offered nothing matching what the operator chose, which
        // means refusing is the only honest answer.
        return .{ .outcome = .cancelled };
    }

    /// Tests whether an offered option is the decision the operator picked.
    ///
    /// Parameters:
    /// - `kind`: the option's kind.
    /// - `chosen`: what the operator chose.
    ///
    /// Return: true when they are the same decision.
    fn matches(kind: acp.Client.PermissionOptionKind, chosen: Answer) bool {
        return switch (chosen) {
            .allowOnce => kind == .allow_once,
            .allowAlways => kind == .allow_always,
            .rejectOnce => kind == .reject_once,
            .rejectAlways => kind == .reject_always,
        };
    }
};

/// The client half of one agent's seam.
pub const ClientSession = struct {
    const Self = @This();

    /// The most one turn holds before its front is trimmed. A turn, not a
    /// conversation: the history lives in the transcript and the durable record
    /// lives in the harness's own session log.
    pub const max_live_len = 4 * 1024 * 1024;
    /// Most entries the conversation record keeps.
    pub const max_record = 20_000;

    allocator: std.mem.Allocator,
    io: std.Io,
    /// The agent's short name, for logs and the accounting line (`claude`). Borrowed; outlives the client.
    label: []const u8,
    /// The agent's name as a person reads it, for notes (`Claude`). Borrowed; outlives the client.
    title: []const u8,
    /// Where finished turns go, one append per turn. Borrowed; outlives the client.
    history: acp.Client.History,
    connection: acp.Connection,
    dispatcher: acp.Dispatcher,
    /// Serves `fs/*`. Any path is served as given (`README.md`, "Every client"); AFM's file tools are calls to this.
    fs_handler: acp.Client.Fs,
    /// Serves `terminal/*`; AFM's command tool is calls to this.
    terminal_handler: ClientTerminal,

    /// Guards `live`, `pending`, `usage`, `account` and `settings` between the task
    /// running a prompt and whoever is drawing.
    mutex: std.Io.Mutex = .init,

    /// The modes and models the session offers and which are current.
    settings: acp.Client.Settings,

    /// The turn being streamed now, or the last one completed. What the agent's
    /// live pane draws, and what is handed to the transcript on completion.
    live: std.ArrayList(u8) = .empty,
    /// The conversation as ACP said it, for a front end to draw: each conversation
    /// `session/update` as its JSON (the person's prompts as `user_message_chunk`),
    /// and the client's own lines — a turn's accounting, a failure — as `{"note":…}`.
    /// Owned; bounded by `max_record`, the oldest dropped.
    record: std.ArrayList([]u8) = .empty,
    /// How many entries the record has dropped off its front: added to an index
    /// into `record`, the absolute position a reader resumes from.
    record_base: usize = 0,

    /// The session this client is driving. Owned, empty until `connect`.
    session_id: []u8 = &.{},
    /// The account this session runs as. Owned, empty for the inherited one.
    account: []u8 = &.{},

    /// True between a prompt going out and its stop reason coming back.
    working: std.atomic.Value(bool) = .init(false),
    /// Set while a permission request is waiting.
    awaiting: std.atomic.Value(bool) = .init(false),
    /// Set while this client's own `session/load` is in flight, so the history
    /// an agent replays in answer is dropped rather than drawn.
    loading: std.atomic.Value(bool) = .init(false),
    /// The question, while one is outstanding.
    pending: ?PendingPermission = null,

    /// The turns an agent replays during `session/load`, finished ones first. Owned.
    replay_turns: std.ArrayList([]u8) = .empty,
    /// The replayed turn being gathered.
    replay_text: std.ArrayList(u8) = .empty,
    /// Where the replayed turn being gathered is: its prompt, or the reply.
    replay_phase: enum { none, prompt, reply } = .none,
    /// Set by `load` when the agent replayed the session's history.
    history_replayed: bool = false,
    /// Whether the agent's `initialize` said it takes HTTP MCP servers, and so the host's tools.
    takes_http_mcp: bool = false,
    /// Whether the agent's `initialize` said it can reopen a session (`loadSession`).
    loads_session: bool = false,
    /// What `initialize` offered beyond that; its extensions live in `offer_arena`. Fixed after the handshake.
    offer: AgentOffer = .{},
    offer_arena: std.heap.ArenaAllocator,
    /// The session's slash commands, latest first replacing the last; owned by `commands_arena`. Guarded by `mutex`.
    commands: []const SessionCommand = &.{},
    commands_arena: std.heap.ArenaAllocator,
    /// The agent's plan, latest replacing the last; owned by `plan_arena`. Guarded by `mutex`.
    plan: []const PlanStep = &.{},
    plan_arena: std.heap.ArenaAllocator,
    /// The context the session fills, from the agent's latest `usage_update`. Guarded by `mutex`.
    context: ?ContextUse = null,
    /// The operator's answer, once given.
    answer_given: ?Answer = null,
    /// Wakes the permission handler when the operator answers.
    answered: std.Io.Condition = .init,

    /// Cleared once the transport closes or a request fails fatally.
    ///
    /// ACP has no liveness method, so this is inferred from the only evidence
    /// there is: a request that failed because the peer went away. Better than
    /// the `true` a front end would otherwise display forever.
    alive: std.atomic.Value(bool) = .init(true),

    /// Monotonic nanoseconds at the last submit, for the running clock.
    turn_started_ns: u64 = 0,
    /// The newest turn's accounting, or null when the agent sent none; its windows live in `usage_arena`. Guarded by `mutex`.
    usage: ?acp.Inferise.TurnUsage = null,
    usage_arena: std.heap.ArenaAllocator,

    /// Carries `prompt`, which blocks for a whole turn. Exactly one releaser,
    /// which is `deinit`.
    prompt_group: std.Io.Group = .init,
    /// The prompt a task is currently sending. Owned.
    submitted: []u8 = &.{},
    /// The images sent with it; owned by `attached_arena`.
    attached: []const PromptImage = &.{},
    attached_arena: std.heap.ArenaAllocator,

    // Handlers. Each holds a pointer back, so the client must live at a stable
    // address — `start` heap-allocates it.
    update_handler: UpdateHandler = .{},
    permission_handler: PermissionHandler = .{},

    /// Builds a client over a transport and registers what it serves.
    ///
    /// Parameters:
    /// - `allocator`: backs the live buffer and every call; must outlive it.
    /// - `io`: IO capability.
    /// - `transport`: the client end of a connected pair.
    /// - `label`: the agent's short name, for logs; borrowed, must outlive the client.
    /// - `title`: the agent's name as a person reads it, for notes; borrowed, must outlive the client.
    /// - `history`: where finished turns go; borrowed, must outlive the client.
    /// - `environ_map`: the environment `terminal/*` commands run in; borrowed for the call.
    ///
    /// Return: a heap client at a stable address; caller calls `deinit`; propagates alloc failure.
    pub fn start(allocator: std.mem.Allocator, io: std.Io, transport: acp.Transport, label: []const u8, title: []const u8, history: acp.Client.History, environ_map: *const std.process.Environ.Map) acp.AcpError!*Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var fs_handler = try acp.Client.Fs.init(io);
        errdefer fs_handler.deinit();
        var terminal_handler = try newTerminal(allocator, io, environ_map);
        errdefer terminal_handler.deinit();

        self.* = Self{
            .allocator = allocator,
            .io = io,
            .label = label,
            .title = title,
            .history = history,
            .connection = acp.Connection.init(allocator, transport),
            .dispatcher = acp.Dispatcher.init(allocator),
            .fs_handler = fs_handler,
            .terminal_handler = terminal_handler,
            .settings = try acp.Client.Settings.init(allocator),
            .offer_arena = .init(allocator),
            .usage_arena = .init(allocator),
            .commands_arena = .init(allocator),
            .plan_arena = .init(allocator),
            .attached_arena = .init(allocator),
        };

        self.update_handler = .{ .client = self };
        self.permission_handler = .{ .client = self };

        try self.dispatcher.registerNotification(
            acp.Agent.method_session_update,
            UpdateHandler,
            &self.update_handler,
        );
        try self.dispatcher.registerRequest(
            acp.Client.method_session_request_permission,
            PermissionHandler,
            &self.permission_handler,
        );
        // Advertised in `initialize`; an agent only calls what it was offered.
        try self.fs_handler.register(&self.dispatcher);
        try self.terminal_handler.register(&self.dispatcher);

        self.connection.setRequestHandler(self.dispatcher.requestHandler());
        self.connection.setNotificationHandler(self.dispatcher.notificationHandler());
        return self;
    }

    /// Releases the client and everything it accumulated.
    ///
    /// Parameters:
    /// - `self`: the client to tear down; invalid afterwards.
    ///
    /// Return: nothing; never fails; the borrowed transcript survives.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.prompt_group.cancel(self.io);
        if (self.submitted.len > 0) self.allocator.free(self.submitted);
        self.attached_arena.deinit();
        if (self.pending) |*request| self.releasePending(request);
        self.live.deinit(self.allocator);
        for (self.record.items) |entry| self.allocator.free(entry);
        self.record.deinit(self.allocator);
        if (self.account.len > 0) self.allocator.free(self.account);
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        self.settings.deinit();
        self.plan_arena.deinit();
        self.commands_arena.deinit();
        self.offer_arena.deinit();
        self.usage_arena.deinit();
        self.dropReplay();
        self.replay_turns.deinit(self.allocator);
        self.replay_text.deinit(self.allocator);
        self.terminal_handler.deinit();
        self.fs_handler.deinit();
        self.dispatcher.deinit();
        self.allocator.destroy(self);
    }

    /// Builds what serves `terminal/*` on this platform.
    ///
    /// Parameters:
    /// - `allocator`: backs the terminals it runs.
    /// - `io`: IO capability for spawning and reading them.
    /// - `environ_map`: the environment a terminal's command inherits; read on Windows, where commands run on pipes.
    ///
    /// Return: the terminal server; propagates its initialization failure.
    fn newTerminal(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !ClientTerminal {
        return if (builtin.os.tag == .windows) acp.Client.Terminal.init(allocator, io, environ_map) else acp.Client.PtyTerminal.init(allocator, io);
    }

    /// Shakes hands and opens a session on the inherited account.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `cwd`: the working directory the session runs in; borrowed.
    ///
    /// Return: nothing once a session exists; propagates request failures.
    pub fn connect(self: *Self, cwd: []const u8) acp.AcpError!void {
        return self.connectAs(cwd, null, null, null);
    }

    /// Shakes hands and opens a session on a named account.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `cwd`: the working directory to report to the agent.
    /// - `home`: the account's absolute path, or null for the inherited one.
    /// - `name`: what to call it on screen, or null; copied.
    /// - `mcp`: the host's MCP server to offer the session, or null for none; offered only to an agent that takes one.
    ///
    /// Return: nothing on success; propagates transport and protocol errors.
    pub fn connectAs(self: *Self, cwd: []const u8, home: ?[]const u8, name: ?[]const u8, mcp: ?acp.McpOffer) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try self.handshake();

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const params = try sessionParams(arena_state.allocator(), cwd, null, home, name, if (self.takes_http_mcp) mcp else null);
        // Every harness answers in ACP's shape; the `_meta` some add, naming the
        // account they opened on, is ignored, since zigacp decodes leniently.
        const session = try self.openSession(params);
        defer self.allocator.free(session);

        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        self.session_id = try self.allocator.dupe(u8, session);

        if (self.account.len > 0) self.allocator.free(self.account);
        self.account = try self.allocator.dupe(u8, name orelse "");

        log.info("{s} session {s} on {s}", .{
            self.label,
            self.session_id,
            if (self.account.len > 0) self.account else "the inherited account",
        });
    }

    /// Shakes hands and reopens a stored session instead of opening a new one.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `cwd`: the working directory to report to the agent.
    /// - `session_id`: the stored session to reopen; copied.
    /// - `home`: the account's absolute path it was stored under, or null for the inherited one.
    /// - `name`: the account's name, shown on screen and Grok's account; copied.
    /// - `mcp`: the host's MCP server to offer the session again, or null.
    ///
    /// Return: nothing once reopened; propagates transport and protocol errors.
    pub fn resumeAs(self: *Self, cwd: []const u8, session_id: []const u8, home: ?[]const u8, name: ?[]const u8, mcp: ?acp.McpOffer) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try self.handshake();
        try self.load(cwd, session_id, home, name, mcp);

        if (self.account.len > 0) self.allocator.free(self.account);
        self.account = try self.allocator.dupe(u8, name orelse "");
    }

    /// Ends this session and opens one on a different account.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `cwd`: the working directory to report.
    /// - `home`: the account's absolute path.
    /// - `name`: what to call it on screen; copied.
    ///
    /// Return: true when switched, false when already current; error.TurnInFlight mid-turn.
    pub fn switchAccount(self: *Self, cwd: []const u8, home: []const u8, name: []const u8) acp.AcpError!bool {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (std.mem.eql(u8, self.account, name)) return false;
        if (self.isWorking()) return error.TurnInFlight;

        if (self.session_id.len > 0) {
            const Empty = struct {};
            const closed = self.connection.request(
                Empty,
                acp.Agent.method_session_close,
                acp.Agent.CloseSessionRequest{
                    .sessionId = .{ .value = self.session_id },
                },
            ) catch |err| {
                // A session that will not close would otherwise leave a child
                // behind, so this is worth failing on rather than opening a
                // second one beside it.
                log.err("could not close {s} session {s} [{t}]", .{ self.label, self.session_id, err });
                return err;
            };
            closed.deinit();

            self.allocator.free(self.session_id);
            self.session_id = &.{};
        }

        try self.connectAs(cwd, home, name, null);

        // The pane starts empty and says why: an unexplained blank screen reads
        // as lost work.
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.live.clearRetainingCapacity();
            self.usage = null;
        }

        // SAFETY: written by bufPrint before it is read.
        var line: [192]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{s} switched to {s}", .{ self.title, name }) catch return true;
        self.history.note(text) catch |err| {
            log.warn("could not note the switch [{t}]", .{err});
        };
        return true;
    }

    /// Submits a prompt without waiting for the turn.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `text`: the prompt; copied.
    ///
    /// Return: nothing once the task is away; errors if empty, busy, closed, or out of memory.
    pub fn send(self: *Self, text: []const u8) acp.AcpError!void {
        return self.sendWithImages(text, &.{});
    }

    /// Submits a prompt with images attached, without waiting for the turn.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `text`: the prompt; copied.
    /// - `images`: images to send beside it, as ACP image blocks; copied. Refused unless the agent takes images.
    ///
    /// Return: nothing once the task is away; `error.ImagesNotTaken`, or the errors `send` returns.
    pub fn sendWithImages(self: *Self, text: []const u8, images: []const PromptImage) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (text.len == 0) return error.EmptyPrompt;
        if (images.len > 0 and !self.offer.images) return error.ImagesNotTaken;
        if (!self.isAlive()) return error.AgentGone;
        if (self.isWorking()) return error.TurnInFlight;

        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        var attached = std.heap.ArenaAllocator.init(self.allocator);
        errdefer attached.deinit();
        const copies = try attached.allocator().alloc(PromptImage, images.len);
        for (images, copies) |image, *copy| copy.* = .{ .mime_type = try attached.allocator().dupe(u8, image.mime_type), .data = try attached.allocator().dupe(u8, image.data) };

        // Marked working here rather than inside the task: a front end that
        // redraws immediately must not be told the agent is idle.
        self.working.store(true, .release);
        if (self.submitted.len > 0) self.allocator.free(self.submitted);
        self.submitted = owned;
        self.attached_arena.deinit();
        self.attached_arena = attached;
        self.attached = copies;

        self.prompt_group.concurrent(self.io, promptTask, .{ self, owned }) catch {
            self.prompt_group.async(self.io, promptTask, .{ self, owned });
        };
    }

    /// Submits a prompt and blocks for the whole turn; never call it from a draw loop.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `text`: the prompt; borrowed for the call.
    ///
    /// Return: why the turn stopped; propagates request and allocation failures.
    pub fn prompt(self: *Self, text: []const u8) acp.AcpError!acp.Agent.StopReason {
        return self.promptWithImages(text, &.{});
    }

    /// Submits a prompt with images and blocks for the whole turn; never call it from a draw loop.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `text`: the prompt; borrowed for the call.
    /// - `images`: images sent after the text, as ACP image blocks; borrowed for the call.
    ///
    /// Return: why the turn stopped; propagates request and allocation failures.
    pub fn promptWithImages(self: *Self, text: []const u8, images: []const PromptImage) acp.AcpError!acp.Agent.StopReason {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (text.len == 0) return error.EmptyPrompt;
        if (self.session_id.len == 0) return error.NoSession;

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.live.clearRetainingCapacity();
            self.usage = null;
            try self.appendPrompt(text);
            try self.recordJson(.{ .sessionUpdate = "user_message_chunk", .content = .{ .type = "text", .text = text } });
            for (images) |_| try self.recordJson(.{ .sessionUpdate = "user_message_chunk", .content = .{ .type = "text", .text = "\n[image]" } });
        }

        self.turn_started_ns = self.nowNs();
        self.working.store(true, .release);
        defer self.working.store(false, .release);

        var blocks_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer blocks_arena.deinit();
        const blocks = try blocks_arena.allocator().alloc(acp.ContentBlock, 1 + images.len);
        blocks[0] = .{ .text = .{ .text = text } };
        for (images, blocks[1..]) |image, *block| block.* = .{ .image = .{ .data = image.data, .mimeType = image.mime_type } };
        const parsed = self.connection.request(acp.Agent.PromptResponse, acp.Agent.method_session_prompt, acp.Agent.PromptRequest{
            .sessionId = .{ .value = self.session_id },
            .prompt = blocks,
        }) catch |err| {
            if (err == error.TransportClosed) self.alive.store(false, .release);
            self.recordFailure(err);
            return err;
        };
        defer parsed.deinit();

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            // `_meta.inferise`, one shape for every agent; a third-party agent sends none.
            const report = acp.Inferise.readTurn(parsed.arena.allocator(), parsed.value._meta) catch |err| blk: {
                log.warn("_meta.inferise did not fit this build's type [{t}]", .{err});
                break :blk acp.Inferise.TurnMeta{};
            };
            _ = self.usage_arena.reset(.retain_capacity);
            self.usage = if (report.usage) |usage| try usage.clone(self.usage_arena.allocator()) else null;
            // A failed turn is still a result, and the harness's sentence is the reason.
            if (report.failure) |sentence| {
                try self.append("\n  ");
                try self.append(sentence);
                try self.recordNote(sentence);
            }
            // A turn an agent cut short at a refusal says so, or it reads as an empty answer.
            if (report.denied.len > 0) {
                const said = try deniedSentenceOwned(parsed.arena.allocator(), report.denied);
                try self.append("\n  ");
                try self.append(said);
                try self.recordNote(said);
            }
            try self.appendAccounting(parsed.value.stopReason);
        }

        // One append per turn, which is what keeps streaming agents from
        // shredding each other in the shared buffer.
        try self.handOff();

        return parsed.value.stopReason;
    }

    /// Asks the agent to stop the running turn.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: nothing; a failure is logged rather than raised.
    pub fn requestCancel(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (self.session_id.len == 0) return;

        // A notification, not a request: `session/prompt` is already blocked on
        // this connection and `Connection` allows one reader, so a second request
        // would race it and one response would be dropped. A notification only
        // writes, so it is safe from here and needs no task of its own. Failure is
        // only logged because the caller is a keypress.
        self.connection.notify(acp.Agent.method_session_cancel, acp.Agent.CancelNotification{
            .sessionId = .{ .value = self.session_id },
        }) catch |err| {
            log.warn("could not cancel the {s} turn [{t}]", .{ self.label, err });
        };
    }

    /// Resumes a session the agent stored, dropping any history it replays.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `cwd`: the working directory to report.
    /// - `session_id`: the stored session to resume; copied.
    /// - `home`: the Claude or Codex home it was stored under, or null for the inherited one.
    /// - `name`: the Grok account it was stored under, or null for its default; ignored by other agents.
    /// - `mcp`: the host's MCP server to offer the session again, or null.
    ///
    /// Return: nothing once resumed; `error.TurnInFlight` mid-turn; propagates request failures.
    pub fn load(self: *Self, cwd: []const u8, session_id: []const u8, home: ?[]const u8, name: ?[]const u8, mcp: ?acp.McpOffer) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (self.isWorking()) return error.TurnInFlight;

        const owned = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(owned);

        // Raised before the request goes out: the updates it provokes are
        // dispatched on this task, inside `request`, before its result arrives.
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.clearRecord();
        }
        self.loading.store(true, .release);
        defer self.loading.store(false, .release);
        self.history_replayed = false;
        defer self.dropReplay();

        // A session is stored under the account that made it, and its tools are
        // the CLI's to be given again, so a load names both as `session/new` did.
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const params = try sessionParams(arena_state.allocator(), cwd, owned, home, name, if (self.takes_http_mcp) mcp else null);
        const loaded = self.connection.request(acp.Agent.LoadSessionResponse, acp.Agent.method_session_load, params) catch |err| {
            if (err == error.TransportClosed) self.alive.store(false, .release);
            return err;
        };
        defer loaded.deinit();

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.live.clearRetainingCapacity();
            self.usage = null;
            try self.settings.replace(loaded.value.modes, loaded.value.config_options);
        }

        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        self.session_id = owned;

        // The agent's own account of the past replaces the caller's saved copy.
        try self.flushReplay();
        if (self.replay_turns.items.len > 0) {
            try self.history.replace(self.replay_turns.items);
            self.history_replayed = true;
        }
        // ACP's replay is the `session/update`s before the answer: counted as they came, never asked for.
        log.info("{s} resumed session {s}; {d} turns replayed", .{ self.label, self.session_id, self.replay_turns.items.len });
    }

    /// Copies the turn this agent is streaming, or the last one it completed, for drawing.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `allocator`: owns the returned text.
    ///
    /// Return: the turn text plus a running clock while working; caller frees; propagates OOM.
    pub fn liveText(self: *Self, allocator: std.mem.Allocator) acp.AcpError![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        out.writer.writeAll(self.live.items) catch return error.OutOfMemory;

        // Local, not protocol: the client knows when it submitted, so the clock
        // ticks between notifications and costs no round trip.
        if (self.working.load(.acquire)) {
            const elapsed_ms = (self.nowNs() -| self.turn_started_ns) / std.time.ns_per_ms;
            out.writer.print("\n  {d:0>2}:{d:0>2} working…\n", .{
                elapsed_ms / std.time.ms_per_min,
                (elapsed_ms / std.time.ms_per_s) % 60,
            }) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice();
    }

    /// Reports whether the seam is still up.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: false once a request has failed because the peer went away.
    pub fn isAlive(self: *const Self) bool {
        return self.alive.load(.acquire);
    }

    /// Reports whether a turn is in flight.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: true between a prompt going out and its stop reason arriving.
    pub fn isWorking(self: *const Self) bool {
        return self.working.load(.acquire);
    }

    /// Reports whether the operator is being asked to decide something.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: true while a permission request is outstanding.
    pub fn isAwaitingPermission(self: *const Self) bool {
        return self.awaiting.load(.acquire);
    }

    /// Copies the one-line description of the outstanding permission request.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `allocator`: owns the returned string.
    ///
    /// Return: the summary, caller frees; null when nothing is pending; propagates OOM.
    pub fn permissionSummary(self: *Self, allocator: std.mem.Allocator) acp.AcpError!?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const asked = self.pending orelse return null;
        return try allocator.dupe(u8, asked.summary);
    }

    /// Records the operator's answer and wakes the handler waiting on it.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `choice`: what the operator chose.
    ///
    /// Return: nothing; an answer with nothing pending is ignored.
    pub fn answerPermission(self: *Self, choice: Answer) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.pending == null) return;
        self.answer_given = choice;
        self.answered.broadcast(self.io);
    }

    /// Reports the session this client is driving.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: the id, borrowed until the next connect or deinit; empty before `connect`.
    pub fn sessionId(self: *const Self) []const u8 {
        return self.session_id;
    }

    /// Reports the account this session runs as.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: the name, borrowed until the next connect or deinit; empty when inherited.
    pub fn accountName(self: *const Self) []const u8 {
        return self.account;
    }

    /// Reports the newest turn's accounting, if the agent sent any.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `arena`: owns the copy returned, windows included.
    ///
    /// Return: a copy of the accounting, or null when the agent reported none; propagates allocation failure.
    pub fn lastUsage(self: *Self, arena: std.mem.Allocator) std.mem.Allocator.Error!?acp.Inferise.TurnUsage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const usage = self.usage orelse return null;
        return try usage.clone(arena);
    }

    /// Copies the session's modes and models, for drawing.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `allocator`: owns the copy; an arena in practice.
    ///
    /// Return: the copy; propagates allocation failure.
    pub fn sessionSettings(self: *Self, allocator: std.mem.Allocator) acp.AcpError!acp.Client.Settings {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.settings.copy(allocator);
    }

    /// Switches the session to another of the modes it offers.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `mode_id`: the mode.
    ///
    /// Return: nothing once switched; `error.TurnInFlight` mid-turn, `error.NotOffered` for a mode the session lacks, else the request's failure.
    pub fn setMode(self: *Self, mode_id: []const u8) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // The connection is driven by one task at a time, and a turn's task holds it.
        if (self.isWorking()) return error.TurnInFlight;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (!self.settings.offersMode(mode_id)) return error.NotOffered;
        }
        const reply = try self.connection.request(acp.Agent.SetModeResponse, acp.Agent.method_session_set_mode, acp.Agent.SetModeRequest{ .sessionId = .{ .value = self.session_id }, .modeId = mode_id });
        defer reply.deinit();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.settings.takeMode(mode_id);
    }

    /// Switches the session to another of the models it offers.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `value`: the model's value.
    ///
    /// Return: nothing once switched; `error.TurnInFlight` mid-turn, `error.NotOffered` for a model the session lacks, else the request's failure.
    pub fn setModel(self: *Self, value: []const u8) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (self.isWorking()) return error.TurnInFlight;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const option = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (!self.settings.offersModel(value)) return error.NotOffered;
            break :blk try arena_state.allocator().dupe(u8, self.settings.model_option);
        };
        const request = acp.Agent.SetConfigOptionRequest{ .session_id = .{ .value = self.session_id }, .config_id = option, .value = .{ .value = .{ .string = value } } };
        const reply = try self.connection.request(acp.Agent.SetConfigOptionResponse, acp.Agent.method_session_set_config_option, request);
        defer reply.deinit();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Setting one option may change others, so the reply's list replaces the old.
        if (reply.value.config_options) |options| try self.settings.takeOptions(options);
    }

    /// Sets one of the session's config options, a select's choice or a boolean.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `id`: the option.
    /// - `value`: its new value; a choice for a select, `enabled` for a boolean.
    ///
    /// Return: nothing once set; `error.TurnInFlight` mid-turn, `error.NotOffered` for an option or choice the session lacks, else the request's failure.
    pub fn setOption(self: *Self, id: []const u8, value: OptionValue) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // The connection is driven by one task at a time, and a turn's task holds it.
        if (self.isWorking()) return error.TurnInFlight;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const option = self.settings.findOption(id) orelse return error.NotOffered;
            switch (value) {
                .enabled => if (!option.is_boolean) return error.NotOffered,
                .choice => |choice| {
                    if (option.is_boolean) return error.NotOffered;
                    for (option.choices) |offered| {
                        if (std.mem.eql(u8, offered.id, choice)) break;
                    } else return error.NotOffered;
                },
            }
        }
        const wire: std.json.Value = switch (value) {
            .choice => |choice| .{ .string = choice },
            .enabled => |on| .{ .bool = on },
        };
        const request = acp.Agent.SetConfigOptionRequest{ .session_id = .{ .value = self.session_id }, .config_id = id, .value = .{ .value = wire } };
        const reply = try self.connection.request(acp.Agent.SetConfigOptionResponse, acp.Agent.method_session_set_config_option, request);
        defer reply.deinit();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (reply.value.config_options) |options| try self.settings.takeOptions(options);
    }

    /// Asks the agent, in words, what it runs and as whom (`_inferise/status`).
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: the answer, caller calls `deinit`; `error.NotOffered` when the agent did not advertise it, `error.TurnInFlight` mid-turn, else the request's failure.
    pub fn status(self: *Self) acp.AcpError!std.json.Parsed(acp.Inferise.StatusResponse) {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (!self.offer.status) return error.NotOffered;
        if (self.isWorking()) return error.TurnInFlight;
        const request = acp.Inferise.StatusRequest{ .session_id = if (self.session_id.len > 0) .{ .value = self.session_id } else null };
        return self.connection.request(acp.Inferise.StatusResponse, acp.Inferise.method_status, request);
    }

    /// Runs one of the agent's advertised actions.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `method`: the extension's method; must be one the agent advertised.
    /// - `input`: the text it asked for, or null.
    ///
    /// Return: the agent's answer, caller calls `deinit`; `error.NotOffered` for a method not advertised, `error.TurnInFlight` mid-turn, else the request's failure.
    pub fn runExtension(self: *Self, method: []const u8, input: ?[]const u8) acp.AcpError!std.json.Parsed(acp.Inferise.ExtensionResponse) {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const extension = for (self.offer.extensions) |offered| {
            if (std.mem.eql(u8, offered.method, method)) break offered;
        } else return error.NotOffered;
        if (self.isWorking()) return error.TurnInFlight;
        const request = acp.Inferise.ExtensionRequest{
            .session_id = if (extension.scope == .session and self.session_id.len > 0) .{ .value = self.session_id } else null,
            .input = input,
        };
        return self.connection.request(acp.Inferise.ExtensionResponse, extension.method, request);
    }

    /// Asks the agent which accounts it can run as (`_inferise/accounts`).
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: the answer, caller calls `deinit`; `error.NotOffered` when the agent did not advertise it, `error.TurnInFlight` mid-turn, else the request's failure.
    pub fn accounts(self: *Self) acp.AcpError!std.json.Parsed(acp.Inferise.AccountsResponse) {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (!self.offer.accounts) return error.NotOffered;
        if (self.isWorking()) return error.TurnInFlight;
        return self.connection.request(acp.Inferise.AccountsResponse, acp.Inferise.method_accounts, acp.Inferise.AccountsRequest{});
    }

    /// Starts signing an account in (`_inferise/sign_in`).
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `account`: the account's name, a new one to create it, or null for the default.
    ///
    /// Return: what the person must open or type, caller calls `deinit`; `error.NotOffered`, `error.TurnInFlight`, else the request's failure.
    pub fn signIn(self: *Self, account: ?[]const u8) acp.AcpError!std.json.Parsed(acp.Inferise.SignInResponse) {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (!self.offer.sign_in) return error.NotOffered;
        if (self.isWorking()) return error.TurnInFlight;
        return self.connection.request(acp.Inferise.SignInResponse, acp.Inferise.method_sign_in, acp.Inferise.SignInRequest{ .account = account });
    }

    /// Passes a pasted code, and asks whether the sign-in has ended (`_inferise/sign_in_finish`).
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `account`: the account named to `signIn`.
    /// - `code`: what the page showed, or null to only ask.
    ///
    /// Return: the answer, caller calls `deinit`; `error.NotOffered`, else the request's failure.
    pub fn signInFinish(self: *Self, account: ?[]const u8, code: ?[]const u8) acp.AcpError!std.json.Parsed(acp.Inferise.SignInFinishResponse) {
        if (!self.offer.sign_in) return error.NotOffered;
        return self.connection.request(acp.Inferise.SignInFinishResponse, acp.Inferise.method_sign_in_finish, acp.Inferise.SignInFinishRequest{ .account = account, .code = code });
    }

    /// Abandons a sign-in (`_inferise/sign_in_cancel`).
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `account`: the account named to `signIn`.
    ///
    /// Return: nothing; `error.NotOffered`, else the request's failure.
    pub fn signInCancel(self: *Self, account: ?[]const u8) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (!self.offer.sign_in) return error.NotOffered;
        const answer = try self.connection.request(acp.Inferise.SignInCancelResponse, acp.Inferise.method_sign_in_cancel, acp.Inferise.SignInCancelRequest{ .account = account });
        answer.deinit();
    }

    /// Copies the conversation record from a position on.
    ///
    /// Positions are absolute, so a reader resumes where it left off; one whose
    /// position the record has since dropped, or that a replay replaced, is given
    /// everything kept and told to start again (`restarted`).
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `allocator`: owns the copies; an arena in practice.
    /// - `from`: the first position wanted; 0 for everything.
    ///
    /// Return: the entries and the position after them; propagates allocation failure.
    pub fn recordSince(self: *Self, allocator: std.mem.Allocator, from: usize) acp.AcpError!RecordPage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const restarted = from < self.record_base;
        const first = if (restarted) 0 else @min(from - self.record_base, self.record.items.len);
        const kept = self.record.items[first..];
        const copies = try allocator.alloc([]const u8, kept.len);
        for (kept, copies) |entry, *copy| copy.* = try allocator.dupe(u8, entry);
        return .{ .entries = copies, .next = self.record_base + self.record.items.len, .restarted = restarted };
    }

    /// Copies what the session's agent said beyond its turns: commands, plan, context.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `allocator`: owns the copy; an arena in practice.
    ///
    /// Return: the copy; propagates allocation failure.
    pub fn sessionExtras(self: *Self, allocator: std.mem.Allocator) acp.AcpError!SessionExtras {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const commands = try allocator.alloc(SessionCommand, self.commands.len);
        for (self.commands, commands) |command, *copy| copy.* = .{ .name = try allocator.dupe(u8, command.name), .description = try allocator.dupe(u8, command.description) };
        const plan = try allocator.alloc(PlanStep, self.plan.len);
        for (self.plan, plan) |step, *copy| copy.* = .{ .content = try allocator.dupe(u8, step.content), .status = step.status };
        return .{ .commands = commands, .plan = plan, .context = self.context };
    }

    /// Copies the permission question waiting, with the kinds of answer the agent offered.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `allocator`: owns the copy.
    ///
    /// Return: the summary and the offered kinds; null when nothing is waiting; propagates allocation failure.
    pub fn pendingQuestion(self: *Self, allocator: std.mem.Allocator) acp.AcpError!?struct { summary: []u8, kinds: []acp.Client.PermissionOptionKind } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const request = self.pending orelse return null;
        var kinds: std.ArrayList(acp.Client.PermissionOptionKind) = .empty;
        for (request.options) |option| if (option) |choice| try kinds.append(allocator, choice.kind);
        return .{ .summary = try allocator.dupe(u8, request.summary), .kinds = kinds.items };
    }

    /// Replaces the session's slash commands; the caller holds `mutex`.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `commands`: the agent's whole list now.
    ///
    /// Return: nothing; propagates allocation failure.
    fn takeCommands(self: *Self, commands: []const acp.Agent.AvailableCommand) !void {
        _ = self.commands_arena.reset(.retain_capacity);
        const arena = self.commands_arena.allocator();
        const kept = try arena.alloc(SessionCommand, commands.len);
        for (commands, kept) |command, *copy| copy.* = .{ .name = try arena.dupe(u8, command.name), .description = try arena.dupe(u8, command.description) };
        self.commands = kept;
    }

    /// Replaces the agent's plan; the caller holds `mutex`.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `entries`: the whole plan now.
    ///
    /// Return: nothing; propagates allocation failure.
    fn takePlan(self: *Self, entries: []const acp.PlanEntry) !void {
        _ = self.plan_arena.reset(.retain_capacity);
        const arena = self.plan_arena.allocator();
        const kept = try arena.alloc(PlanStep, entries.len);
        for (entries, kept) |entry, *copy| copy.* = .{ .content = try arena.dupe(u8, entry.content), .status = @tagName(entry.status) };
        self.plan = kept;
    }

    /// Notes each file a tool call changes, with how many lines it adds and removes; the caller holds `mutex`.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `content`: the call's or the update's content, or null.
    ///
    /// Return: nothing; propagates allocation failure.
    fn appendDiffs(self: *Self, content: ?[]const acp.ToolCallContent) !void {
        for (content orelse return) |entry| switch (entry) {
            .diff => |diff| {
                // SAFETY: written by bufPrint before it is read.
                var line: [512]u8 = undefined;
                const removed = if (diff.oldText) |old| lineCount(old) else 0;
                const rendered = std.fmt.bufPrint(&line, "    ± {s} (+{d} −{d})\n", .{ diff.path, lineCount(diff.newText), removed }) catch continue;
                try self.append(rendered);
            },
            else => {},
        };
    }

    /// Counts a text's lines, a last line without a newline included.
    ///
    /// Parameters:
    /// - `text`: the text.
    ///
    /// Return: the count; zero for empty text.
    fn lineCount(text: []const u8) usize {
        if (text.len == 0) return 0;
        const breaks = std.mem.count(u8, text, "\n");
        return if (text[text.len - 1] == '\n') breaks else breaks + 1;
    }

    /// Runs one whole turn as the body of the task `send` spawns.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `text`: the prompt; owned by `submitted`.
    ///
    /// Return: nothing; a failed turn is logged and reported into the live buffer.
    fn promptTask(self: *Self, text: []const u8) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        _ = self.promptWithImages(text, self.attached) catch |err| {
            log.warn("{s} turn failed [{t}]", .{ self.label, err });
            self.working.store(false, .release);
            return;
        };
    }

    /// Shakes hands with the agent.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: nothing once the agent has answered; propagates request failures.
    /// Shakes hands and opens no session: for asking an agent about its accounts, or signing one in.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: nothing once the agent has said what it offers; propagates request failures.
    pub fn handshakeOnly(self: *Self) acp.AcpError!void {
        return self.handshake();
    }

    fn handshake(self: *Self) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // ACP's own shape for every harness: what some add — `agentInfo`, a
        // session capability, `_meta` — is ignored, since zigacp decodes leniently.
        // `fs/*` and `terminal/*` are offered because they are served: AFM's
        // tools are calls to them, and a native agent may make the same.
        const answer = self.connection.request(acp.Agent.InitializeResponse, acp.Agent.method_initialize, acp.Agent.InitializeRequest{
            .protocolVersion = acp.ProtocolVersion.V1,
            .clientCapabilities = .{
                .fs = .{ .readTextFile = true, .writeTextFile = true },
                .terminal = true,
            },
        }) catch |err| {
            self.alive.store(false, .release);
            return err;
        };
        defer answer.deinit();
        const capabilities = answer.value.agentCapabilities orelse acp.Agent.AgentCapabilities{};
        const mcp = capabilities.mcpCapabilities orelse acp.Agent.AgentCapabilities.McpCapabilities{};
        self.takes_http_mcp = mcp.http orelse false;
        self.loads_session = capabilities.loadSession orelse false;
        const prompts = capabilities.promptCapabilities orelse acp.Agent.AgentCapabilities.PromptCapabilities{};
        // What an Inferise agent serves beyond ACP; a third-party agent advertises none.
        const ours = acp.Meta.read(acp.Inferise.Capabilities, answer.arena.allocator(), capabilities._meta, acp.Inferise.key) catch |err| blk: {
            log.warn("{s}'s _meta.inferise capabilities did not fit this build's type [{t}]", .{ self.label, err });
            break :blk null;
        } orelse acp.Inferise.Capabilities{};
        const arena = self.offer_arena.allocator();
        const extensions = try arena.alloc(acp.Inferise.Extension, if (ours.extensions) |list| list.len else 0);
        if (ours.extensions) |list| for (list, extensions) |extension, *copy| {
            copy.* = .{
                .method = try arena.dupe(u8, extension.method),
                .label = try arena.dupe(u8, extension.label),
                .scope = extension.scope,
                .input = if (extension.input) |text| try arena.dupe(u8, text) else null,
            };
        };
        self.offer = .{ .images = prompts.image orelse false, .loads_session = self.loads_session, .status = ours.status, .accounts = ours.accounts, .sign_in = ours.signIn, .extensions = extensions };
        log.info("{s} speaks protocol v{d}{s}{s}", .{ self.label, answer.value.protocolVersion.value, if (self.takes_http_mcp) ", takes HTTP MCP servers" else "", if (self.loads_session) ", reopens sessions" else "" });
    }

    /// Builds `session/new` or `session/load` params: the account and the MCP server.
    ///
    /// Parameters:
    /// - `arena`: owns the params.
    /// - `cwd`: the working directory.
    /// - `session_id`: the session to load, or null for `session/new`.
    /// - `home`: the account's path, or null for the inherited one.
    /// - `name`: the account's name, or null for the agent's default.
    /// - `mcp`: the host's MCP server and the session's token, or null for an agent that takes none.
    ///
    /// Return: the params; propagates allocation failure.
    fn sessionParams(arena: std.mem.Allocator, cwd: []const u8, session_id: ?[]const u8, home: ?[]const u8, name: ?[]const u8, mcp: ?acp.McpOffer) !std.json.Value {
        var params: std.json.ObjectMap = .empty;
        if (session_id) |id| try params.put(arena, "sessionId", .{ .string = id });
        try params.put(arena, "cwd", .{ .string = cwd });

        // The account, in the one shape every agent reads: `_meta.inferise.account`.
        // Each maps it onto its own mechanism; AFM has no accounts and ignores it.
        var meta: std.json.ObjectMap = .empty;
        if (home != null or name != null) {
            var account: std.json.ObjectMap = .empty;
            if (home) |path| try account.put(arena, "home", .{ .string = path });
            if (name) |text| try account.put(arena, "name", .{ .string = text });
            var shared: std.json.ObjectMap = .empty;
            try shared.put(arena, acp.Inferise.account, .{ .object = account });
            try meta.put(arena, acp.Inferise.key, .{ .object = shared });
        }

        if (meta.count() > 0) try params.put(arena, "_meta", .{ .object = meta });

        // The server, and the agent told its tools need no approval.
        if (mcp) |offer| try offer.put(arena, &params);
        return .{ .object = params };
    }

    /// Opens a session with the parameters every agent reads.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `params`: the `session/new` params, `cwd` plus any `_meta` naming the account.
    ///
    /// Return: the session id, owned by the caller; propagates request failures.
    fn openSession(self: *Self, params: anytype) ![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const opened = self.connection.request(acp.Agent.NewSessionResponse, acp.Agent.method_session_new, params) catch |err| {
            self.alive.store(false, .release);
            return err;
        };
        defer opened.deinit();
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.settings.replace(opened.value.modes, opened.value.config_options);
        }
        return self.allocator.dupe(u8, opened.value.session_id.value);
    }

    /// Hands the finished turn to the shared transcript.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: nothing on success; propagates allocation failure.
    fn handOff(self: *Self) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const finished = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.live.items.len == 0) return;
            break :blk try self.allocator.dupe(u8, self.live.items);
        };
        defer self.allocator.free(finished);

        try self.history.append(finished);
    }

    /// Gathers one update an agent replays during `session/load` into the past it is rebuilding.
    ///
    /// Parameters:
    /// - `self`: the client; the mutex is held.
    /// - `update`: the replayed update; borrowed for the call.
    ///
    /// Return: nothing; propagates allocation failure.
    fn gatherReplay(self: *Self, update: acp.Agent.SessionUpdate) !void {
        switch (update) {
            .userMessageChunk => |chunk| {
                const text = switch (chunk.content) {
                    .text => |block| block.text,
                    else => return,
                };
                // A prompt after a reply opens the next turn.
                if (self.replay_phase == .reply) try self.flushReplay();
                if (self.replay_phase != .prompt) try self.replay_text.appendSlice(self.allocator, "> ");
                try self.replay_text.appendSlice(self.allocator, text);
                self.replay_phase = .prompt;
            },
            .agentMessageChunk => |chunk| switch (chunk.content) {
                .text => |block| {
                    try self.replayReply();
                    try self.replay_text.appendSlice(self.allocator, block.text);
                },
                else => {},
            },
            .agentThoughtChunk => |chunk| switch (chunk.content) {
                .text => |block| {
                    try self.replayReply();
                    try self.replay_text.print(self.allocator, "\n  · {s}\n", .{block.text});
                },
                else => {},
            },
            .toolCall => |call| {
                try self.replayReply();
                try self.replay_text.print(self.allocator, "\n  ⚙ {s}\n", .{call.title});
            },
            else => {},
        }
    }

    /// Moves the replayed turn being gathered to its reply.
    ///
    /// Parameters:
    /// - `self`: the client; the mutex is held.
    ///
    /// Return: nothing; propagates allocation failure.
    fn replayReply(self: *Self) !void {
        if (self.replay_phase == .prompt) try self.replay_text.append(self.allocator, '\n');
        self.replay_phase = .reply;
    }

    /// Finishes the replayed turn being gathered.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: nothing; propagates allocation failure.
    fn flushReplay(self: *Self) !void {
        self.replay_phase = .none;
        if (self.replay_text.items.len == 0) return;
        const owned = try self.allocator.dupe(u8, self.replay_text.items);
        errdefer self.allocator.free(owned);
        try self.replay_turns.append(self.allocator, owned);
        self.replay_text.clearRetainingCapacity();
    }

    /// Forgets a gathered replay.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: nothing.
    fn dropReplay(self: *Self) void {
        for (self.replay_turns.items) |text| self.allocator.free(text);
        self.replay_turns.clearRetainingCapacity();
        self.replay_text.clearRetainingCapacity();
        self.replay_phase = .none;
    }

    /// Makes a failed turn visible in the live buffer.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `err`: what went wrong.
    ///
    /// Return: nothing; a failure to report a failure is logged and dropped.
    fn recordFailure(self: *Self, err: anyerror) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // SAFETY: written by bufPrint before it is read.
        var line: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "\n  turn failed [{t}]\n", .{err}) catch return;
        self.append(text) catch |append_err| {
            log.warn("could not record the failure [{t}]", .{append_err});
        };
        self.recordNote(std.mem.trim(u8, text, " \n")) catch |record_err| log.warn("could not record the failure [{t}]", .{record_err});
    }

    /// Appends to the live turn, trimming the front when it runs long; caller holds `mutex`.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `text`: what to append; copied.
    ///
    /// Return: nothing on success; propagates allocation failure.
    fn append(self: *Self, text: []const u8) !void {
        try self.live.appendSlice(self.allocator, text);

        if (self.live.items.len > max_live_len) {
            const excess = self.live.items.len - max_live_len;
            // Trimmed at the front, because a turn is read at its foot.
            std.mem.copyForwards(u8, self.live.items, self.live.items[excess..]);
            self.live.shrinkRetainingCapacity(max_live_len);
        }
    }

    /// Opens a turn with the prompt that started it.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `text`: the prompt.
    ///
    /// Return: nothing on success; propagates allocation failure.
    fn appendPrompt(self: *Self, text: []const u8) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try self.append("> ");
        try self.append(text);
        try self.append("\n");
    }

    /// Says what an agent would not do without approval, and how to let it.
    ///
    /// An agent reports each refusal in its own words, which are sometimes JSON
    /// (`{"action":"command","display_name":"RunCommand"}`); its `display_name`
    /// is what a person reads, when it has one.
    ///
    /// Parameters:
    /// - `arena`: owns the sentence.
    /// - `denied`: the refusals, as reported.
    ///
    /// Return: one sentence; propagates allocation failure.
    fn deniedSentenceOwned(arena: std.mem.Allocator, denied: []const []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        out.writer.writeAll("Not done without approval: ") catch return error.OutOfMemory;
        for (denied, 0..) |raw, index| {
            if (index > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
            const Named = struct { display_name: ?[]const u8 = null, action: ?[]const u8 = null };
            const named = std.json.parseFromSliceLeaky(Named, arena, raw, .{ .ignore_unknown_fields = true }) catch Named{};
            out.writer.writeAll(named.display_name orelse named.action orelse raw) catch return error.OutOfMemory;
        }
        out.writer.writeAll(". Turn on Always approve to let it, or ask again.") catch return error.OutOfMemory;
        return out.written();
    }

    /// Closes a turn with its accounting, when there is any to show.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `stop`: why the turn stopped.
    ///
    /// Return: nothing on success; propagates allocation failure.
    fn appendAccounting(self: *Self, stop: acp.Agent.StopReason) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // SAFETY: written by bufPrint or the fixed writer before it is read.
        var line: [256]u8 = undefined;

        const usage = self.usage orelse {
            // The agent sent no `_meta`, so there is nothing to report. Saying
            // why the turn stopped beats a row of zeroes pretending to measure.
            const rendered = std.fmt.bufPrint(&line, "\n  {s}\n", .{@tagName(stop)}) catch return;
            try self.recordNote(@tagName(stop));
            return self.append(rendered);
        };

        var out: std.Io.Writer = .fixed(&line);
        const wall_ms = usage.wall_ms orelse 0;
        out.print("\n  {d}.{d:0>2}s wall", .{
            wall_ms / 1000,
            (wall_ms % 1000) / 10,
        }) catch return;

        // AFM measures neither agent time nor a turn's tokens, and zeroes in
        // their place would claim a measurement nobody took.
        if (usage.measuresTurn()) {
            const agent_ms = usage.agent_ms orelse 0;
            out.print(" · {d}.{d:0>2}s {s} · {d} in", .{
                agent_ms / 1000,
                (agent_ms % 1000) / 10,
                self.label,
                usage.freshInputTokens() orelse 0,
            }) catch return;

            if (usage.cached_input_tokens) |cached| {
                out.print(" (+{d} cached)", .{cached}) catch return;
            }
            out.print(" / {d} out", .{usage.output_tokens orelse 0}) catch return;
        }
        if (usage.context_tokens) |tokens| {
            out.print(" · {d} tokens in context", .{tokens}) catch return;
        }
        if (usage.cost_usd) |cost| {
            out.print(" · ${d:.4}", .{cost}) catch return;
        }
        // A turn that did not simply end says why. An interrupted one reports no
        // agent time and no tokens — there is no result record to take them from
        // — and a row of zeroes with nothing explaining it reads as a failure.
        if (stop != .end_turn) {
            out.print(" · {s}", .{@tagName(stop)}) catch return;
        }
        out.writeAll("\n") catch return;

        try self.append(out.buffered());
        try self.recordNote(std.mem.trim(u8, out.buffered(), " \n"));
    }

    /// Records a conversation update as ACP's JSON; the session's other updates are state, not conversation; caller holds `mutex`.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `update`: the update.
    ///
    /// Return: nothing; propagates allocation failure.
    fn recordUpdate(self: *Self, update: acp.Agent.SessionUpdate) !void {
        switch (update) {
            .userMessageChunk, .agentMessageChunk, .agentThoughtChunk, .toolCall, .toolCallUpdate, .plan => try self.recordJson(update),
            else => {},
        }
    }

    /// Records one of the client's own lines between the agent's updates; caller holds `mutex`.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `text`: the line; copied.
    ///
    /// Return: nothing; propagates allocation failure.
    fn recordNote(self: *Self, text: []const u8) !void {
        try self.recordJson(.{ .note = text });
    }

    /// Appends a value's JSON to the record, dropping the oldest half past the bound; caller holds `mutex`.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `value`: the entry.
    ///
    /// Return: nothing; propagates allocation failure.
    fn recordJson(self: *Self, value: anytype) !void {
        const entry = try std.json.Stringify.valueAlloc(self.allocator, value, acp.wire_options);
        errdefer self.allocator.free(entry);
        if (self.record.items.len >= max_record) {
            const drop = self.record.items.len / 2;
            for (self.record.items[0..drop]) |old| self.allocator.free(old);
            std.mem.copyForwards([]u8, self.record.items[0 .. self.record.items.len - drop], self.record.items[drop..]);
            self.record.shrinkRetainingCapacity(self.record.items.len - drop);
            self.record_base += drop;
        }
        try self.record.append(self.allocator, entry);
    }

    /// Forgets the record, before an agent replays its past into it; caller holds `mutex`.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: nothing.
    fn clearRecord(self: *Self) void {
        self.record_base += self.record.items.len;
        for (self.record.items) |entry| self.allocator.free(entry);
        self.record.clearRetainingCapacity();
    }

    /// Releases a pending permission's owned strings.
    ///
    /// Parameters:
    /// - `self`: the client.
    /// - `request`: the permission to release; its strings are invalid afterwards.
    ///
    /// Return: nothing; never fails.
    fn releasePending(self: *const Self, request: *PendingPermission) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        for (request.options) |maybe| {
            const option = maybe orelse continue;
            self.allocator.free(option.id);
        }
        self.allocator.free(request.summary);
    }

    /// Reads the monotonic clock the running timer measures against.
    ///
    /// Parameters:
    /// - `self`: the client.
    ///
    /// Return: nanoseconds since an arbitrary epoch, never negative.
    fn nowNs(self: *const Self) u64 {
        const raw = std.Io.Clock.awake.now(self.io).nanoseconds;
        if (raw <= 0) return 0;
        return std.math.lossyCast(u64, raw);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ClientSession);
}

/// One prompt result's accounting, read the way `prompt` reads it: zigacp's own type, then `_meta.inferise`.
///
/// Parameters:
/// - `arena`: owns everything parsed.
/// - `json`: the result, as the agent writes it.
///
/// Return: the report; propagates a parse failure.
fn reportOf(arena: std.mem.Allocator, json: []const u8) !acp.Inferise.TurnMeta {
    const parsed = try std.json.parseFromSliceLeaky(acp.Agent.PromptResponse, arena, json, .{});
    return acp.Inferise.readTurn(arena, parsed._meta);
}

test "claude accounting carries a cost and no cache figure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const usage = (try reportOf(arena.allocator(),
        \\{"stopReason":"end_turn","_meta":{"inferise":{"usage":{"wallMs":2630,"agentMs":2100,"inputTokens":4,"outputTokens":109,"costUsd":0.21}}}}
    )).usage.?;

    try std.testing.expectEqual(@as(?u64, 2630), usage.wall_ms);
    try std.testing.expectEqual(@as(?u64, 2100), usage.agent_ms);
    try std.testing.expectEqual(@as(?f64, 0.21), usage.cost_usd);
    try std.testing.expectEqual(@as(?u64, null), usage.cached_input_tokens);

    // With no cache figure the whole input is what was processed.
    try std.testing.expectEqual(@as(?u64, 4), usage.freshInputTokens());
}

test "codex accounting carries a cache figure and no cost" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Captured from a live two-word prompt; `inputTokens` counts the system
    // prompt and every tool definition, which is why the raw figure misleads.
    const usage = (try reportOf(arena.allocator(),
        \\{"stopReason":"end_turn","_meta":{"inferise":{"usage":{"wallMs":2460,"agentMs":2450,"inputTokens":17523,"cachedInputTokens":12928,"outputTokens":5}}}}
    )).usage.?;

    try std.testing.expectEqual(@as(?u64, 2450), usage.agent_ms);
    try std.testing.expectEqual(@as(?u64, 12928), usage.cached_input_tokens);
    try std.testing.expectEqual(@as(?f64, null), usage.cost_usd);
    try std.testing.expectEqual(@as(?u64, 4595), usage.freshInputTokens());
}

test "a cached figure at or above the total does not underflow" {
    const usage = acp.Inferise.TurnUsage{ .input_tokens = 100, .cached_input_tokens = 120 };
    try std.testing.expectEqual(@as(?u64, 0), usage.freshInputTokens());
}

test "an answer matches only the option that means the same thing" {
    const kinds = [_]acp.Client.PermissionOptionKind{ .allow_once, .allow_always, .reject_once, .reject_always };
    const answers = [_]Answer{ .allowOnce, .allowAlways, .rejectOnce, .rejectAlways };

    // Each answer matches exactly one offered kind: answering "allow once" with
    // the "allow always" option would remember a decision nobody made.
    for (answers, 0..) |chosen, index| {
        for (kinds, 0..) |kind, other| {
            const expected = index == other;
            try std.testing.expectEqual(expected, PermissionHandler.matches(kind, chosen));
        }
    }
}

test "afm accounting carries a wall time and the context size, and measures no turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const usage = (try reportOf(arena.allocator(),
        \\{"stopReason":"end_turn","_meta":{"inferise":{"usage":{"wallMs":820,"contextTokens":2602}}}}
    )).usage.?;

    try std.testing.expectEqual(@as(?u64, 820), usage.wall_ms);
    try std.testing.expectEqual(@as(?u64, 2602), usage.context_tokens);
    try std.testing.expect(!usage.measuresTurn());
    try std.testing.expectEqual(@as(?f64, null), usage.cost_usd);
    try std.testing.expectEqual(@as(?u64, null), usage.cached_input_tokens);
}

test "an afm prompt result decodes, a failed turn included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Exactly what `zigafm` answers: a size the OS could not measure is left out.
    const ended = try reportOf(arena.allocator(),
        \\{"stopReason":"end_turn","_meta":{"inferise":{"usage":{"wallMs":820}}}}
    );
    try std.testing.expectEqual(@as(?u64, 820), ended.usage.?.wall_ms);
    try std.testing.expectEqual(@as(?u64, null), ended.usage.?.context_tokens);
    try std.testing.expectEqual(@as(?[]const u8, null), ended.failure);

    // A conversation past the window ends `max_tokens`, with the reason.
    const overflowed = try reportOf(arena.allocator(),
        \\{"stopReason":"max_tokens","_meta":{"inferise":{"usage":{"wallMs":140,"contextTokens":3463},"failure":"the conversation is too long"}}}
    );
    try std.testing.expectEqualStrings("the conversation is too long", overflowed.failure.?);
}

/// A history for the tests: every turn kept in order, replaced wholesale on a replay.
const TestHistory = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    turns: std.ArrayList([]u8) = .empty,

    const vtable: acp.Client.History.VTable = .{ .append = append, .note = append, .replace = replace };

    fn history(self: *Self) acp.Client.History {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *Self) void {
        for (self.turns.items) |text| self.allocator.free(text);
        self.turns.deinit(self.allocator);
    }

    fn append(ctx: *anyopaque, text: []const u8) std.mem.Allocator.Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.turns.append(self.allocator, owned);
    }

    fn replace(ctx: *anyopaque, texts: []const []const u8) std.mem.Allocator.Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        for (self.turns.items) |text| self.allocator.free(text);
        self.turns.clearRetainingCapacity();
        for (texts) |text| try append(ctx, text);
    }
};

test "updates during this client's own load are gathered as the past, not drawn as a turn" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var kept = TestHistory{ .allocator = allocator };
    defer kept.deinit();
    try kept.history().append("a saved copy the replay replaces");

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();

    const transport = try acp.FrameTransport.init(allocator, io);
    defer transport.deinit();

    const client = try ClientSession.start(allocator, io, transport.clientTransport(), "afm", "AFM", kept.history(), &environ_map);
    defer client.deinit();

    const replay = [_]acp.Agent.SessionUpdate{
        .{ .userMessageChunk = .{ .content = .{ .text = .{ .text = "hi" } } } },
        .{ .agentMessageChunk = .{ .content = .{ .text = .{ .text = "hello" } } } },
        .{ .agentMessageChunk = .{ .content = .{ .text = .{ .text = " there" } } } },
        .{ .userMessageChunk = .{ .content = .{ .text = .{ .text = "and?" } } } },
        .{ .agentMessageChunk = .{ .content = .{ .text = .{ .text = "done" } } } },
    };

    // What `load` raises around its request: the replay is gathered, not drawn.
    client.loading.store(true, .release);
    for (replay) |update| try client.update_handler.handle(allocator, .{ .sessionId = .{ .value = "s" }, .update = update });
    try std.testing.expectEqual(@as(usize, 0), client.live.items.len);
    try client.flushReplay();
    try std.testing.expectEqual(@as(usize, 2), client.replay_turns.items.len);
    try std.testing.expectEqualStrings("> hi\nhello there", client.replay_turns.items[0]);
    try std.testing.expectEqualStrings("> and?\ndone", client.replay_turns.items[1]);

    try kept.history().replace(client.replay_turns.items);
    try std.testing.expectEqual(@as(usize, 2), kept.turns.items.len);
    try std.testing.expectEqualStrings("> and?\ndone", kept.turns.items[1]);
    client.dropReplay();

    // Once the load has answered, updates are a turn again.
    client.loading.store(false, .release);
    const streamed = acp.Agent.SessionNotification{
        .sessionId = .{ .value = "live" },
        .update = .{ .agentMessageChunk = .{ .content = .{ .text = .{ .text = "streaming now" } } } },
    };
    try client.update_handler.handle(allocator, streamed);
    try std.testing.expectEqualStrings("streaming now", client.live.items);
}

test "grok's session and prompt results decode, and its usage is unified" {
    const allocator = std.testing.allocator;

    // What `ziggrok` answers: ACP's own shape, its always-approve one of the config options.
    const opened = try std.json.parseFromSlice(acp.Agent.NewSessionResponse, allocator,
        \\{"sessionId":"g1","configOptions":[{"type":"boolean","id":"alwaysApprove","name":"Always approve","currentValue":false}]}
    , .{ .ignore_unknown_fields = true });
    defer opened.deinit();
    try std.testing.expectEqualStrings("g1", opened.value.session_id.value);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const usage = (try reportOf(arena.allocator(),
        \\{"stopReason":"end_turn","_meta":{"inferise":{"usage":{"wallMs":2630,"agentMs":2410,"inputTokens":17623,"cachedInputTokens":1152,"outputTokens":166,"reasoningOutputTokens":165,"costUsd":0.034514,"contextTokens":21300,"contextWindow":500000}}}}
    )).usage.?;
    try std.testing.expectEqual(@as(?u64, 2410), usage.agent_ms);
    try std.testing.expectEqual(@as(?u64, 17623), usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 1152), usage.cached_input_tokens);
    try std.testing.expectEqual(@as(?u64, 21300), usage.context_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.034514), usage.cost_usd.?, 1e-9);
    try std.testing.expect(usage.measuresTurn());

    // A turn grok never got to: only the wall time is real, and grok's reason is shown.
    const refused = try reportOf(arena.allocator(),
        \\{"stopReason":"refusal","_meta":{"inferise":{"usage":{"wallMs":40},"failure":"no usable account"}}}
    );
    try std.testing.expect(!refused.usage.?.measuresTurn());
    try std.testing.expectEqualStrings("no usable account", refused.failure.?);
}

test "gemini's and copilot's prompt results decode, and their usage is unified" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Exactly what each harness writes.
    const from_gemini = (try reportOf(arena.allocator(),
        \\{"stopReason":"end_turn","_meta":{"inferise":{"usage":{"wallMs":2100,"agentMs":1900,"inputTokens":1200,"cachedInputTokens":300,"outputTokens":40,"reasoningOutputTokens":12},"denied":["run_command"]}}}
    )).usage.?;
    try std.testing.expectEqual(@as(?u64, 1900), from_gemini.agent_ms);
    try std.testing.expectEqual(@as(?u64, 1200), from_gemini.input_tokens);
    try std.testing.expect(from_gemini.measuresTurn());

    const from_copilot = (try reportOf(arena.allocator(),
        \\{"stopReason":"end_turn","_meta":{"inferise":{"usage":{"wallMs":3000,"inputTokens":800,"cachedInputTokens":0,"outputTokens":25,"reasoningOutputTokens":0,"contextTokens":9000,"contextWindow":128000}}}}
    )).usage.?;
    try std.testing.expectEqual(@as(?u64, 800), from_copilot.input_tokens);
    try std.testing.expectEqual(@as(?u64, 9000), from_copilot.context_tokens);

    // A turn that never reached the model: only the wall time, and the reason.
    const refused = try reportOf(arena.allocator(),
        \\{"stopReason":"refusal","_meta":{"inferise":{"usage":{"wallMs":20},"failure":"not signed in"}}}
    );
    try std.testing.expect(!refused.usage.?.measuresTurn());
    try std.testing.expectEqualStrings("not signed in", refused.failure.?);

    // What an agent would not do without approval is read too, and said in words a person reads:
    // agy's own JSON by its display name, anything else as written.
    const declined = try reportOf(arena.allocator(),
        \\{"stopReason":"end_turn","_meta":{"inferise":{"denied":["{\"action\":\"command\",\"display_name\":\"RunCommand\"}","write_file"]}}}
    );
    try std.testing.expectEqual(@as(usize, 2), declined.denied.len);
    try std.testing.expectEqualStrings("Not done without approval: RunCommand, write_file. Turn on Always approve to let it, or ask again.", try ClientSession.deniedSentenceOwned(arena.allocator(), declined.denied));
}

test "session params name the account and the tools in each harness's terms, on load as on new" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const offer = acp.McpOffer{ .url = "http://127.0.0.1:1/mcp", .token = "t0k" };

    // A Claude load: the session, its account and the server trusted, all in `_meta.inferise`.
    const claude = (try ClientSession.sessionParams(arena, "/w", "s-1", "/h/.claudework", "work", offer)).object;
    try std.testing.expectEqualStrings("s-1", claude.get("sessionId").?.string);
    const claude_meta = claude.get("_meta").?.object;
    const shared = claude_meta.get("inferise").?.object;
    try std.testing.expectEqualStrings("/h/.claudework", shared.get("account").?.object.get("home").?.string);
    try std.testing.expectEqualStrings(acp.Inferise.mcp_server, shared.get("trustedMcpServers").?.array.items[0].string);
    try std.testing.expect(claude_meta.get("zigclaude") == null);
    try std.testing.expectEqualStrings("Bearer t0k", claude.get("mcpServers").?.array.items[0].object.get("headers").?.array.items[0].object.get("value").?.string);

    // A Codex one on its inherited home: no account named, the server trusted, nothing under its own key.
    const codex = (try ClientSession.sessionParams(arena, "/w", "s-2", null, null, offer)).object;
    const codex_meta = codex.get("_meta").?.object;
    try std.testing.expect(codex_meta.get("inferise").?.object.get("account") == null);
    try std.testing.expectEqualStrings(acp.Inferise.mcp_server, codex_meta.get("inferise").?.object.get("trustedMcpServers").?.array.items[0].string);
    try std.testing.expect(codex_meta.get("zigcodex") == null);

    // Grok by name, in `_meta.inferise` like the others, and nothing under its own key.
    const grok = (try ClientSession.sessionParams(arena, "/w", null, "/h/.grok", "work", offer)).object;
    const grok_meta = grok.get("_meta").?.object;
    try std.testing.expectEqualStrings("work", grok_meta.get("inferise").?.object.get("account").?.object.get("name").?.string);
    try std.testing.expect(grok_meta.get("ziggrok") == null);
    try std.testing.expectEqual(@as(usize, 1), grok.get("mcpServers").?.array.items.len);
    try std.testing.expectEqual(@as(?std.json.Value, null), grok.get("sessionId"));

    // AFM, which takes no MCP server, is given none: nothing but the directory.
    const afm = (try ClientSession.sessionParams(arena, "/w", null, null, null, null)).object;
    try std.testing.expectEqual(@as(usize, 1), afm.count());
}

test "claude's and codex's prompt results keep the context they report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Every field `zigclaude` sends, in `_meta.inferise`'s one shape, a window included.
    const claude = (try reportOf(arena.allocator(),
        \\{"stopReason":"end_turn","_meta":{"inferise":{"usage":{"wallMs":2100,"agentMs":1900,"inputTokens":1200,"outputTokens":40,"costUsd":0.012,"contextTokens":18000,"contextWindow":200000,"windows":[{"id":"five_hour","usedPercent":12,"resetsAt":1790475600,"windowMinutes":300}]}}}}
    )).usage.?;
    try std.testing.expectEqual(@as(?u64, 18000), claude.context_tokens);
    try std.testing.expectEqual(@as(?u64, 300), claude.windows[0].window_minutes);
    try std.testing.expect(claude.measuresTurn());

    // Codex leaves out the context it does not know yet, rather than saying zero.
    const codex = (try reportOf(arena.allocator(),
        \\{"stopReason":"end_turn","_meta":{"inferise":{"usage":{"wallMs":2460,"agentMs":2450,"inputTokens":17523,"cachedInputTokens":12928,"outputTokens":5,"reasoningOutputTokens":0}}}}
    )).usage.?;
    try std.testing.expectEqual(@as(?u64, null), codex.context_tokens);
}

test "commands, the plan and the context are kept as state, and a diff is noted in the turn" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    const transport = try acp.FrameTransport.init(allocator, io);
    defer transport.deinit();
    const client = try ClientSession.start(allocator, io, transport.clientTransport(), "claude", "Claude", acp.Client.History.none, &environ_map);
    defer client.deinit();

    // As the agent writes them, so the wire decoding is exercised too.
    const frames = [_][]const u8{
        \\{"sessionId":"s","update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"compact","description":"Shrink the context"}]}}
        ,
        \\{"sessionId":"s","update":{"sessionUpdate":"plan","entries":[{"content":"Read the file","status":"completed","priority":"high"},{"content":"Fix it","status":"in_progress","priority":"medium"}]}}
        ,
        \\{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":1200,"size":200000}}
        ,
        \\{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","content":[{"type":"diff","path":"/w/a.zig","oldText":"a\nb\n","newText":"a\nb\nc\n"}]}}
        ,
    };
    for (frames) |frame| {
        const parsed = try std.json.parseFromSlice(acp.Agent.SessionNotification, allocator, frame, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try client.update_handler.handle(allocator, parsed.value);
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const extras = try client.sessionExtras(arena_state.allocator());
    try std.testing.expectEqualStrings("compact", extras.commands[0].name);
    try std.testing.expectEqual(@as(usize, 2), extras.plan.len);
    try std.testing.expectEqualStrings("in_progress", extras.plan[1].status);
    try std.testing.expectEqual(@as(u64, 200000), extras.context.?.size);
    try std.testing.expect(std.mem.find(u8, client.live.items, "± /w/a.zig (+3 −2)") != null);

    // The record kept the conversation's updates as ACP's JSON — the plan and
    // the tool update — and none of the session's state.
    const page = try client.recordSince(arena_state.allocator(), 0);
    try std.testing.expectEqual(@as(usize, 2), page.entries.len);
    try std.testing.expect(std.mem.startsWith(u8, page.entries[0], "{\"sessionUpdate\":\"plan\""));
    try std.testing.expect(std.mem.startsWith(u8, page.entries[1], "{\"sessionUpdate\":\"tool_call_update\""));
    // A reader resumes where it stopped; one whose place was dropped starts again.
    {
        client.mutex.lockUncancelable(io);
        defer client.mutex.unlock(io);
        try client.recordNote("1.20s wall");
    }
    const more = try client.recordSince(arena_state.allocator(), page.next);
    try std.testing.expectEqual(@as(usize, 1), more.entries.len);
    try std.testing.expectEqualStrings("{\"note\":\"1.20s wall\"}", more.entries[0]);
    {
        client.mutex.lockUncancelable(io);
        defer client.mutex.unlock(io);
        client.clearRecord();
    }
    const after = try client.recordSince(arena_state.allocator(), more.next - 1);
    try std.testing.expect(after.restarted);
    try std.testing.expectEqual(@as(usize, 0), after.entries.len);

    // Nothing was advertised, so nothing extra may be asked of the agent.
    try std.testing.expectError(error.NotOffered, client.status());
    try std.testing.expectError(error.NotOffered, client.runExtension("_zigafm/trim", "1"));
    try std.testing.expectError(error.ImagesNotTaken, client.sendWithImages("look", &.{.{ .mime_type = "image/png", .data = "AAAA" }}));
}
