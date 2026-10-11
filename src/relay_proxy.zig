//! The one place every frame between a host and its agent passes through.
//!
//! A proxy puts one of these in front of each agent it starts — an agent linked
//! in-process or one on a child's stdio — so what the host gets is the same
//! whatever is behind it:
//!
//! - **A record.** Every frame of a session is appended to
//!   `<logDir>/<session id>.jsonl` (`SessionLog`), both directions, with its turn.
//! - **Turns.** Each `session/prompt` opens the next turn, and its reply says which.
//! - **One usage shape.** A prompt's reply gains `_meta.inferise.usage`, built
//!   from the agent's own `_meta.inferise.usage` or, when it sent none, the
//!   session's last `usage_update` — so a host reads one shape rather than one
//!   per agent.
//! - **Instructions.** `_meta.inferise.instructions` on `session/new` goes to an
//!   agent that advertised the inferise extension as `_meta.instructions`; any
//!   other agent, which may not read it, gets them prepended to the session's
//!   first prompt instead.
//! - **A way back.** When the relay hosts an `McpHttpServer`, every session
//!   that can take one is given the `inferise` MCP server, and its tools become
//!   ACP's own messages to the host: `report_progress` a `notice` update, and
//!   `ask_user` an `elicitation/create` form whose accepted `answer` is the
//!   tool's result — each only when the host's `initialize` advertised it
//!   (`session.notices`, `elicitation.form`). The relay answers the agent; the
//!   host's reply is never forwarded.
//!
//! JSON-RPC ids pass through untouched. Requests run both ways — the host asks
//! the agent to prompt, the agent asks the host for permission — so
//! `Conductor.Pairing` keeps one table per direction, and a reply is matched in
//! the table of the side that asked. A frame that does not parse is forwarded
//! as it came: the relay adds, it never stands in the way.

const std = @import("std");
const log = std.log.scoped(.acp_relay_proxy);
const acp = @import("module.zig");
const zigstorage = @import("zigstorage");

/// What a pending request was, so its reply can be handled.
const PendingKind = enum {
    const Self = @This();

    initialize,
    sessionNew,
    sessionLoad,
    sessionPrompt,
    other,

    /// The kind of request a method makes.
    ///
    /// Parameters:
    /// - `method`: the request's method.
    ///
    /// Return: the kind; `other` for any method the relay does not handle itself.
    fn of(method: []const u8) Self {
        if (std.mem.eql(u8, method, acp.Agent.method_initialize)) return .initialize;
        if (std.mem.eql(u8, method, acp.Agent.method_session_new)) return .sessionNew;
        if (std.mem.eql(u8, method, acp.Agent.method_session_load)) return .sessionLoad;
        if (std.mem.eql(u8, method, acp.Agent.method_session_prompt)) return .sessionPrompt;
        return .other;
    }
};

/// A request awaiting its reply. Owns its strings.
const Pending = struct {
    const Self = @This();

    /// The session it concerns, when the request named one.
    session_id: ?[]u8 = null,
    /// For `session/new`: where the session's record goes.
    log_dir: ?[]u8 = null,
    /// For `session/new`: what to prepend to the first prompt.
    instructions: ?[]u8 = null,
    /// For `session/new`: the request itself, held until the reply names the
    /// session it belongs in.
    frame: ?[]u8 = null,
    /// For `session/new`: the MCP bearer token minted for the session.
    token: ?[]u8 = null,

    /// Releases every owned string.
    ///
    /// Parameters:
    /// - `self`: the pending request.
    /// - `allocator`: the one that allocated it.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (self.session_id) |text| allocator.free(text);
        if (self.log_dir) |text| allocator.free(text);
        if (self.instructions) |text| allocator.free(text);
        if (self.frame) |text| allocator.free(text);
        if (self.token) |text| allocator.free(text);
    }
};

/// A pending request matched to its reply.
const Answered = struct {
    const Self = @This();

    /// What the relay kept with the request; owned by whoever took it.
    value: Pending,
    kind: PendingKind,
};

/// An `ask_user` call waiting on the host's reply.
const AskWaiter = struct {
    const Self = @This();

    /// Set once the host has replied, or the relay is closing.
    done: bool = false,
    /// The person's answer, or null when there was none. Owned.
    answer: ?[]u8 = null,
};

/// What the relay keeps for one session.
const RelaySession = struct {
    const Self = @This();

    /// The record, or null when the host named no log directory.
    record: ?acp.Relay.SessionLog = null,
    /// Instructions still to be prepended, cleared once they have been. Owned.
    instructions: ?[]u8 = null,
};

/// What the host put under `_meta.inferise`.
const InferiseMeta = struct {
    const Self = @This();

    log_dir: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
};

/// Relays frames between a host and an agent until either goes away.
pub const RelayProxy = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    /// The host's end: frames read here go to the agent.
    host: acp.Transport,
    /// The agent's end: frames read here go to the host.
    agent: acp.Transport,
    /// Guards the pairing and every session.
    mutex: std.Io.Mutex = .init,
    /// Requests awaiting their reply: host requests travel `forward`, the agent's `reverse`.
    pairing: acp.Conductor.Pairing(Pending),
    /// Sessions by id. Keys and values owned.
    sessions: std.StringHashMapUnmanaged(*RelaySession) = .empty,
    /// What the frames show: each session's turn and the usage its agent last
    /// reported. Fed both directions, under `mutex`, before a frame is handled.
    decoder: acp.Analytics.EventDecoder,
    /// The agent-to-host pump. Exactly one releaser, which is `run`.
    agent_group: std.Io.Group = .init,
    /// The MCP server the relay's tools are served from, or null for none. Borrowed.
    mcp: ?*acp.McpHttpServer = null,
    /// Answers the subagent tools, offered beside the relay's own when set: the
    /// meta-agent's, for an agent that may start agents of its own. Borrowed.
    delegate: ?acp.McpToolHost = null,
    /// What `tools/list` offers: the relay's own tools, plus the delegate's when
    /// there is one. Borrowed; a caller that sets `delegate` sets this to both tables.
    tools: []const acp.McpToolDefinition = &acp.McpRelayTools.table,
    /// Whether the agent takes an HTTP MCP server, as its `initialize` says
    /// (`mcpCapabilities.http`); false until it has, and no session opens before.
    agent_takes_http_mcp: bool = false,
    /// Whether the agent speaks the inferise extension, as its `initialize` says
    /// (`agentCapabilities._meta.inferise`): such an agent takes standing
    /// instructions as `_meta.instructions`; any other gets them in its first prompt.
    agent_speaks_inferise: bool = false,
    /// Whether the host takes form elicitations (`clientCapabilities.elicitation.form`), as its
    /// `initialize` says; `ask_user` is put to the person as `elicitation/create` only then.
    host_elicits: bool = false,
    /// Whether the host shows session notices (`clientCapabilities.session.notices`), as its
    /// `initialize` says; `report_progress` becomes a `notice` update only then.
    host_shows_notices: bool = false,
    /// MCP bearer tokens to the session each was issued for. Keys and values owned;
    /// the value is empty while `session/new` is still awaiting its reply, because
    /// an agent may connect to its servers before it has answered.
    tokens: std.StringHashMapUnmanaged([]u8) = .empty,
    /// `ask_user` calls awaiting the host, by the number in their request id.
    asks: std.AutoHashMapUnmanaged(u64, *AskWaiter) = .empty,
    next_ask: u64 = 1,
    /// Signalled when an ask is answered or the relay is closing.
    answered: std.Io.Condition = .init,
    /// Set once the host has gone; no ask will be answered after it.
    closing: bool = false,

    /// Builds a relay over two transports; nothing moves until `run`.
    ///
    /// Parameters:
    /// - `allocator`: backs the tables and every frame; must outlive the relay.
    /// - `io`: IO capability for the pump task and the records.
    /// - `environ`: the process environment, which `zigstorage` resolves against.
    /// - `host`: the host's transport; borrowed.
    /// - `agent`: the agent's transport; borrowed.
    ///
    /// Return: the relay, caller calls `deinit`; allocation failure propagates.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, host: acp.Transport, agent: acp.Transport) acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return Self{ .allocator = allocator, .io = io, .environ = environ, .host = host, .agent = agent, .pairing = .init(allocator), .decoder = try acp.Analytics.EventDecoder.init(allocator, 0) };
    }

    /// Releases every table and session.
    ///
    /// Parameters:
    /// - `self`: the relay.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        while (self.pairing.takeAny()) |left| {
            var pending = left.value;
            pending.deinit(self.allocator);
            self.allocator.free(left.method);
        }
        self.pairing.deinit();
        var sessions = self.sessions.iterator();
        while (sessions.next()) |entry| {
            const session = entry.value_ptr.*;
            if (session.record) |*record| record.deinit();
            if (session.instructions) |text| self.allocator.free(text);
            self.allocator.destroy(session);
            self.allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit(self.allocator);
        self.decoder.deinit();
        var tokens = self.tokens.iterator();
        while (tokens.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.tokens.deinit(self.allocator);
        // Every ask has returned by now — `run` released them — so only the table is left.
        self.asks.deinit(self.allocator);
    }

    /// The tool host the relay's MCP server answers through.
    ///
    /// Parameters:
    /// - `self`: the relay, at a stable address.
    ///
    /// Return: the host, borrowing `self`.
    pub fn toolHost(self: *Self) acp.McpToolHost {
        return .{ .ptr = self, .vtable = &tool_host_vtable };
    }

    const tool_host_vtable: acp.McpToolHost.VTable = .{ .knows = knowsToken, .call = callTool, .tools = relayTools };

    /// The tools the relay offers its agent: `tools`.
    ///
    /// Parameters:
    /// - `ctx`: the relay.
    ///
    /// Return: the tool table, borrowed.
    fn relayTools(ctx: *anyopaque) []const acp.McpToolDefinition {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.tools;
    }

    /// Reports whether a bearer token is one the relay issued.
    ///
    /// Parameters:
    /// - `ctx`: the relay.
    /// - `token`: the token.
    ///
    /// Return: true when it names a session.
    fn knowsToken(ctx: *anyopaque, token: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.tokens.contains(token);
    }

    /// Runs one of the relay's tools for the session a token belongs to.
    ///
    /// Parameters:
    /// - `ctx`: the relay.
    /// - `arena`: owns the outcome's text.
    /// - `token`: which session is calling.
    /// - `name`: the tool.
    /// - `arguments`: the call's arguments.
    ///
    /// Return: the outcome; `error.TransportClosed` when the server is torn down mid-ask; propagates allocation failure.
    fn callTool(ctx: *anyopaque, arena: std.mem.Allocator, token: []const u8, name: []const u8, arguments: std.json.Value) acp.AcpError!acp.McpToolOutcome {
        const self: *Self = @ptrCast(@alignCast(ctx));
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        if (arguments != .object) return .{ .text = "The arguments must be an object.", .is_error = true };

        if (std.mem.eql(u8, name, acp.McpRelayTools.report_progress)) return self.reportProgress(arena, token, arguments.object) catch |err| toolError(err);
        if (std.mem.eql(u8, name, acp.McpRelayTools.ask_user)) return self.askUser(arena, token, arguments.object) catch |err| toolError(err);
        // The delegate's when there is one; otherwise never offered, and the server refuses them first.
        if (self.delegate) |delegate| return delegate.call(arena, token, name, arguments);
        return .{ .text = "Not available here.", .is_error = true };
    }

    /// Narrows a tool host's failure to the one error set the MCP server takes.
    ///
    /// Parameters:
    /// - `err`: what the tool failed with.
    ///
    /// Return: `OutOfMemory` as itself, a teardown mid-call as `TransportClosed`, anything else as `PeerError`.
    fn toolError(err: anyerror) acp.AcpError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.TransportClosed,
            else => error.PeerError,
        };
    }

    /// Passes the agent's progress report to the host.
    ///
    /// Parameters:
    /// - `self`: the relay.
    /// - `arena`: per-call scratch.
    /// - `token`: which session is reporting.
    /// - `arguments`: `summary`, and optionally `percentComplete` and `confidence`.
    ///
    /// Return: the outcome the agent reads; propagates allocation and transport failures.
    fn reportProgress(self: *Self, arena: std.mem.Allocator, token: []const u8, arguments: std.json.ObjectMap) !acp.McpToolOutcome {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const summary = stringOf(arguments.get("summary")) orelse return .{ .text = "`summary` is required.", .is_error = true };

        const frame = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const sid = self.tokens.get(token) orelse return .{ .text = "This session has ended.", .is_error = true };
            if (sid.len == 0) return .{ .text = "The session is still opening; try again.", .is_error = true };
            // ACP's own `notice`, which a host may only be sent when it advertised it.
            if (!self.host_shows_notices) return .{ .text = "Noted; this host shows no progress." };

            var detail: std.ArrayList(u8) = .empty;
            if (floatOf(arguments.get("percentComplete"))) |value| try detail.print(arena, "{d:.0}% done", .{std.math.clamp(value, 0, 100)});
            if (floatOf(arguments.get("confidence"))) |value| try detail.print(arena, "{s}{d:.0}% confident", .{ if (detail.items.len > 0) ", " else "", std.math.clamp(value, 0, 100) });
            var update: std.json.ObjectMap = .empty;
            try update.put(arena, "sessionUpdate", .{ .string = "notice" });
            try update.put(arena, "severity", .{ .string = "info" });
            try update.put(arena, "title", .{ .string = summary });
            if (detail.items.len > 0) try update.put(arena, "description", .{ .string = detail.items });
            var params: std.json.ObjectMap = .empty;
            try params.put(arena, "sessionId", .{ .string = sid });
            try params.put(arena, "update", .{ .object = update });
            const text = try notificationFrame(arena, acp.Agent.method_session_update, .{ .object = params });
            try self.recordFrame(sid, .agent, text);
            break :blk text;
        };
        try self.host.writeFrame(.{ .bytes = frame });
        return .{ .text = "Recorded." };
    }

    /// Puts the agent's question to the host and waits for the person's answer.
    ///
    /// Parameters:
    /// - `self`: the relay.
    /// - `arena`: per-call scratch; owns the returned text.
    /// - `token`: which session is asking.
    /// - `arguments`: `question`, and optionally `options`.
    ///
    /// Return: the answer as the agent reads it; propagates allocation, transport and cancelation failures.
    fn askUser(self: *Self, arena: std.mem.Allocator, token: []const u8, arguments: std.json.ObjectMap) !acp.McpToolOutcome {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const question = stringOf(arguments.get("question")) orelse return .{ .text = "`question` is required.", .is_error = true };

        var waiter = AskWaiter{};
        const number, const frame = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closing) return .{ .text = "Nobody is there to answer.", .is_error = true };
            const sid = self.tokens.get(token) orelse return .{ .text = "This session has ended.", .is_error = true };
            if (sid.len == 0) return .{ .text = "The session is still opening; try again.", .is_error = true };
            // ACP's own `elicitation/create`, which a host may only be sent when it advertised forms.
            if (!self.host_elicits) return .{ .text = "This host cannot ask the person; decide without them.", .is_error = true };

            const number = self.next_ask;
            self.next_ask += 1;
            // One string field, its choices the options when there are some.
            var answer_schema: std.json.ObjectMap = .empty;
            try answer_schema.put(arena, "type", .{ .string = "string" });
            try answer_schema.put(arena, "title", .{ .string = "Answer" });
            if (arguments.get("options")) |options| if (options == .array and options.array.items.len > 0) try answer_schema.put(arena, "enum", options);
            var properties: std.json.ObjectMap = .empty;
            try properties.put(arena, answer_field, .{ .object = answer_schema });
            var required = std.json.Array.init(arena);
            try required.append(.{ .string = answer_field });
            var schema: std.json.ObjectMap = .empty;
            try schema.put(arena, "type", .{ .string = "object" });
            try schema.put(arena, "properties", .{ .object = properties });
            try schema.put(arena, "required", .{ .array = required });
            var params: std.json.ObjectMap = .empty;
            try params.put(arena, "sessionId", .{ .string = sid });
            try params.put(arena, "mode", .{ .string = "form" });
            try params.put(arena, "message", .{ .string = question });
            try params.put(arena, "requestedSchema", .{ .object = schema });
            const id = try arena.print("{s}{d}", .{ ask_prefix, number });
            const text = try requestFrame(arena, id, acp.Client.method_elicitation_create, .{ .object = params });

            try self.asks.put(self.allocator, number, &waiter);
            try self.recordFrame(sid, .agent, text);
            break :blk .{ number, text };
        };

        // However this ends, the waiter leaves the table before it goes out of scope.
        defer {
            self.mutex.lockUncancelable(self.io);
            _ = self.asks.remove(number);
            self.mutex.unlock(self.io);
            if (waiter.answer) |text| self.allocator.free(text);
        }
        try self.host.writeFrame(.{ .bytes = frame });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Cancelable: tearing the MCP server down must not wait on a person.
        while (!waiter.done) try self.answered.wait(self.io, &self.mutex);

        const answer = waiter.answer orelse return .{ .text = "The person did not answer." };
        return .{ .text = try arena.dupe(u8, answer) };
    }

    /// The prefix of every request id the relay sends the host itself.
    const ask_prefix = "inferise-ask-";
    /// The one field of the form `ask_user` puts to the person.
    const answer_field = "answer";

    /// Reads whether a host's `initialize` params advertise a client capability.
    ///
    /// Parameters:
    /// - `params`: the `initialize` params.
    /// - `path`: the members under `clientCapabilities`, outermost first.
    ///
    /// Return: true when the last member is present and not null.
    fn clientOffers(params: std.json.Value, path: []const []const u8) bool {
        if (params != .object) return false;
        var at = params.object.get("clientCapabilities") orelse return false;
        for (path) |member| {
            if (at != .object) return false;
            at = at.object.get(member) orelse return false;
        }
        return at != .null;
    }

    /// Relays until the host hangs up or the agent goes away.
    ///
    /// Parameters:
    /// - `self`: the relay, at a stable address.
    ///
    /// Return: nothing; `error.ConcurrencyUnavailable` when the pump cannot run beside the caller.
    pub fn run(self: *Self) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.agent_group.concurrent(self.io, pumpAgent, .{self}) catch return error.TransportFailed;
        self.pumpHost();

        // The host has gone: nobody will answer an ask now, so release every one.
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closing = true;
            var asks = self.asks.valueIterator();
            while (asks.next()) |waiter| waiter.*.done = true;
            self.answered.broadcast(self.io);
        }
        // Then tell the agent, and wait for its pump to see it.
        self.agent.close();
        self.agent_group.await(self.io) catch |err| log.warn("agent pump did not stop cleanly [{t}]", .{err});
    }

    /// Carries host frames to the agent until the host's transport closes.
    ///
    /// Parameters:
    /// - `self`: the relay.
    ///
    /// Return: nothing; a failure ends the pump.
    fn pumpHost(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        while (true) {
            const frame = self.host.readFrame(self.allocator) catch |err| {
                if (err != error.TransportClosed) log.warn("host read failed [{t}]", .{err});
                return;
            };
            defer self.allocator.free(frame);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const maybe = self.fromHost(arena.allocator(), frame) catch |err| blk: {
                log.warn("could not inspect a host frame; forwarding it as it came [{t}]", .{err});
                break :blk frame;
            };
            // Null is a reply to the relay's own question: it stops here.
            const out = maybe orelse continue;
            self.agent.writeFrame(.{ .bytes = out }) catch |err| {
                log.warn("agent write failed [{t}]", .{err});
                return;
            };
        }
    }

    /// Carries agent frames to the host until the agent's transport closes.
    ///
    /// Parameters:
    /// - `self`: the relay.
    ///
    /// Return: nothing; when the agent goes, the host's transport is closed too so the process can end.
    fn pumpAgent(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        defer self.host.close();

        while (true) {
            const frame = self.agent.readFrame(self.allocator) catch |err| {
                if (err != error.TransportClosed) log.warn("agent read failed [{t}]", .{err});
                return;
            };
            defer self.allocator.free(frame);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const out = self.fromAgent(arena.allocator(), frame) catch |err| blk: {
                log.warn("could not inspect an agent frame; forwarding it as it came [{t}]", .{err});
                break :blk frame;
            };
            self.host.writeFrame(.{ .bytes = out }) catch |err| {
                log.warn("host write failed [{t}]", .{err});
                return;
            };
        }
    }

    /// Inspects, records and possibly rewrites one host frame.
    ///
    /// Parameters:
    /// - `self`: the relay.
    /// - `arena`: per-frame scratch; the returned bytes may live in it.
    /// - `frame`: the frame as the host sent it.
    ///
    /// Return: the bytes to forward, or null for a reply to the relay's own request; propagates allocation and record failures.
    fn fromHost(self: *Self, arena: std.mem.Allocator, frame: []const u8) !?[]const u8 {
        var root = std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{}) catch return frame;
        if (root != .object) return frame;
        const object = &root.object;

        const method = stringOf(object.get("method"));
        const id = object.get("id");
        var out: []const u8 = frame;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // First, so a prompt's turn is counted before the prompt is recorded.
        _ = try self.decoder.feed(arena, self.crossing(.sent, frame));

        if (method) |name| {
            const params = object.getPtr("params");
            const session_id = if (params) |p| sessionIdOf(p.*) else null;

            const kind = PendingKind.of(name);
            if (kind == .initialize) {
                // What the host can show a person, before any session opens.
                if (params) |p| {
                    self.host_elicits = clientOffers(p.*, &.{ "elicitation", "form" });
                    self.host_shows_notices = clientOffers(p.*, &.{ "session", "notices" });
                }
                if (id) |value| try self.remember(.forward, value, name, .{});
                return out;
            }

            if (kind == .sessionNew or kind == .sessionLoad) {
                const ours = if (params) |p| try self.takeInferiseMeta(arena, p) else InferiseMeta{};
                // A token is only ever bound or dropped by the reply, so a request
                // without an id — which gets none — is offered no tools.
                const token = if (id != null and params != null) try self.offerTools(arena, params.?) else null;
                errdefer if (token) |text| self.dropToken(text);
                out = try std.json.Stringify.valueAlloc(arena, root, .{});
                if (id) |value| {
                    const pending = built: {
                        var pending = Pending{};
                        errdefer pending.deinit(self.allocator);
                        if (token) |text| pending.token = try self.allocator.dupe(u8, text);
                        if (ours.log_dir) |dir| pending.log_dir = try self.allocator.dupe(u8, dir);
                        if (ours.instructions) |text| pending.instructions = try self.allocator.dupe(u8, text);
                        if (session_id) |sid| pending.session_id = try self.allocator.dupe(u8, sid);
                        // Held until the reply says which session it opened — with the
                        // MCP token redacted: the record lands in a user's project, and
                        // a credential has no business there even when it is loopback-only
                        // and dies with the session. The agent still gets the real one.
                        pending.frame = if (token) |text| try std.mem.replaceOwned(u8, self.allocator, out, text, "redacted") else try self.allocator.dupe(u8, out);
                        break :built pending;
                    };
                    // `remember` owns `pending` from here, releasing it on failure.
                    try self.remember(.forward, value, name, pending);
                }
                return out;
            }

            if (kind == .sessionPrompt) {
                if (session_id) |sid| if (self.sessions.get(sid)) |session| {
                    if (session.instructions) |text| {
                        try prependText(arena, params.?, text);
                        self.allocator.free(text);
                        session.instructions = null;
                        out = try std.json.Stringify.valueAlloc(arena, root, .{});
                    }
                };
            }

            if (id) |value| {
                var pending = Pending{};
                if (session_id) |sid| pending.session_id = try self.allocator.dupe(u8, sid);
                try self.remember(.forward, value, name, pending);
            }
            if (session_id) |sid| try self.recordFrame(sid, .client, out);
            return out;
        }

        // A reply to the relay's own question: wake the tool call waiting on it.
        if (id) |value| if (value == .string and std.mem.startsWith(u8, value.string, ask_prefix)) {
            const number = std.fmt.parseInt(u64, value.string[ask_prefix.len..], 10) catch return null;
            const waiter = self.asks.get(number) orelse return null;
            if (!waiter.done) {
                // An accepted form carries the answer under the field the relay asked for.
                if (object.get("result")) |result| if (result == .object) if (stringOf(result.object.get("action"))) |action| if (std.mem.eql(u8, action, "accept")) {
                    if (result.object.get("content")) |content| if (content == .object) if (stringOf(content.object.get(answer_field))) |answer| {
                        waiter.answer = try self.allocator.dupe(u8, answer);
                    };
                };
                waiter.done = true;
                self.answered.broadcast(self.io);
            }
            return null;
        };

        // A reply to something the agent asked — a permission, a file read.
        if (id) |value| {
            if (self.forget(.forward, value)) |answered| {
                var pending = answered.value;
                defer pending.deinit(self.allocator);
                if (pending.session_id) |sid| try self.recordFrame(sid, .client, out);
            }
        }
        return out;
    }

    /// Inspects, records and possibly rewrites one agent frame.
    ///
    /// Parameters:
    /// - `self`: the relay.
    /// - `arena`: per-frame scratch; the returned bytes may live in it.
    /// - `frame`: the frame as the agent sent it.
    ///
    /// Return: the bytes to forward; propagates allocation and record failures.
    fn fromAgent(self: *Self, arena: std.mem.Allocator, frame: []const u8) ![]const u8 {
        var root = std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{}) catch return frame;
        if (root != .object) return frame;
        const object = &root.object;

        const method = stringOf(object.get("method"));
        const id = object.get("id");

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = try self.decoder.feed(arena, self.crossing(.received, frame));

        if (method) |name| {
            const session_id = if (object.get("params")) |p| sessionIdOf(p) else null;
            if (id) |value| {
                var pending = Pending{};
                if (session_id) |sid| pending.session_id = try self.allocator.dupe(u8, sid);
                try self.remember(.reverse, value, name, pending);
            } else if (std.mem.eql(u8, name, acp.Inferise.method_run_ended)) {
                // A turn the agent started itself ends here rather than in a reply,
                // and carries the same usage a reply would.
                if (session_id) |sid| if (self.sessions.contains(sid)) {
                    const out = self.annotateUsage(arena, &root, "params", sid) catch frame;
                    try self.recordFrame(sid, .agent, out);
                    return out;
                };
            }
            if (session_id) |sid| try self.recordFrame(sid, .agent, frame);
            return frame;
        }

        const value = id orelse return frame;
        const answered = self.forget(.reverse, value) orelse return frame;
        var pending = answered.value;
        defer pending.deinit(self.allocator);

        switch (answered.kind) {
            .initialize => {
                // Every agent says whether it takes HTTP MCP servers, and whether it
                // speaks the inferise extension, before any session opens.
                self.agent_takes_http_mcp = takesHttpMcp(object.get("result"));
                self.agent_speaks_inferise = speaksInferise(object.get("result"));
                return frame;
            },
            .sessionNew, .sessionLoad => {
                const result = object.get("result");
                const named = pending.session_id orelse (if (result) |r| sessionIdOf(r) else null);
                // The token was honoured from the moment it was minted. A refused
                // session's token dies here, before a refused `session/new` — which
                // names no session — returns below.
                if (pending.token) |token| if (result == null or named == null) self.dropToken(token);
                const sid = named orelse return frame;
                const session = try self.openSession(sid, pending.log_dir, pending.instructions);
                // An opened session's token now names it.
                if (pending.token) |token| if (result != null) if (self.tokens.getPtr(token)) |slot| {
                    const value_copy = try self.allocator.dupe(u8, sid);
                    self.allocator.free(slot.*);
                    slot.* = value_copy;
                };
                if (pending.frame) |request| {
                    if (session.record) |*record| record.append(.client, self.decoder.turnOf(sid), request) catch |err| log.warn("record write failed [{t}]", .{err});
                }
                try self.recordFrame(sid, .agent, frame);
                return frame;
            },
            .sessionPrompt => {
                const sid = pending.session_id orelse return frame;
                if (!self.sessions.contains(sid)) return frame;
                const out = self.annotateUsage(arena, &root, "result", sid) catch frame;
                try self.recordFrame(sid, .agent, out);
                return out;
            },
            .other => {
                if (pending.session_id) |sid| try self.recordFrame(sid, .agent, frame);
                return frame;
            },
        }
    }

    /// Takes `_meta.inferise` off a session request and hands the agent what it needs of it.
    ///
    /// Parameters:
    /// - `self`: the relay.
    /// - `arena`: per-frame scratch.
    /// - `params`: the request's params, rewritten in place.
    ///
    /// Return: what was under the key; propagates allocation failure.
    fn takeInferiseMeta(self: *Self, arena: std.mem.Allocator, params: *std.json.Value) !InferiseMeta {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // The key is the relay's, so the agent never sees it.
        if (params.* != .object) return .{};
        const meta = params.object.getPtr("_meta") orelse return .{};
        if (meta.* != .object) return .{};
        const removed = meta.object.fetchSwapRemove(acp.Inferise.key) orelse return .{};
        const ours = removed.value;
        if (ours != .object) return .{};

        var found = InferiseMeta{
            .log_dir = stringOf(ours.object.get(acp.Inferise.log_dir)),
            .instructions = stringOf(ours.object.get(acp.Inferise.instructions)),
        };
        // An inferise agent takes standing instructions as `_meta.instructions`
        // (S11), unless the host already put some there; any other agent may not
        // read it, so it gets them ahead of its first prompt instead.
        if (found.instructions) |text| if (self.agent_speaks_inferise) {
            if (meta.object.get(acp.Meta.instructions) == null) try meta.object.put(arena, acp.Meta.instructions, .{ .string = text });
            found.instructions = null;
        };
        // What the agent itself reads of the key goes back to it, in the one
        // shape every agent takes (`acp.Inferise.SessionMeta`): the account, the
        // log directory — so its own log lands beside the relay's record rather
        // than in the working directory — and the servers it may trust.
        var forwarded: std.json.ObjectMap = .empty;
        for ([_][]const u8{ acp.Inferise.account, acp.Inferise.log_dir, acp.Inferise.trusted_mcp_servers }) |member| {
            if (ours.object.get(member)) |value| try forwarded.put(arena, member, value);
        }
        if (forwarded.count() > 0) try meta.object.put(arena, acp.Inferise.key, .{ .object = forwarded });
        if (meta.object.count() == 0) _ = params.object.swapRemove("_meta");
        return found;
    }

    /// Gives a session the relay's MCP server, when there is one and the agent can take it.
    ///
    /// Parameters:
    /// - `self`: the relay; the caller holds the mutex.
    /// - `arena`: per-frame scratch; owns the token.
    /// - `params`: the session request's params, rewritten in place.
    ///
    /// Return: the token minted for the session, or null when no server was offered; propagates allocation failure.
    fn offerTools(self: *Self, arena: std.mem.Allocator, params: *std.json.Value) !?[]const u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const server = self.mcp orelse return null;
        if (!self.agent_takes_http_mcp or params.* != .object) return null;

        // SAFETY: filled by `io.random` before any byte of it is read.
        var raw: [16]u8 = undefined;
        self.io.random(&raw);
        const token = try arena.dupe(u8, &std.fmt.bytesToHex(raw, .lower));

        // Honoured at once, bound to no session yet: OpenCode connects to its
        // servers while handling `session/new`, before its reply names the session.
        {
            const key = try self.allocator.dupe(u8, token);
            errdefer self.allocator.free(key);
            const unbound = try self.allocator.alloc(u8, 0);
            errdefer self.allocator.free(unbound);
            try self.tokens.put(self.allocator, key, unbound);
        }

        const offer = acp.McpOffer{ .url = try server.url(arena), .token = token };
        try offer.put(arena, &params.object);
        return token;
    }

    /// Withdraws a minted MCP token, so a call carrying it is refused.
    ///
    /// Parameters:
    /// - `self`: the relay; the caller holds the mutex.
    /// - `token`: the token to withdraw; a token not held is ignored.
    ///
    /// Return: nothing.
    fn dropToken(self: *Self, token: []const u8) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const removed = self.tokens.fetchRemove(token) orelse return;
        self.allocator.free(removed.key);
        self.allocator.free(removed.value);
    }

    /// Reads whether an agent's `initialize` reply advertises the inferise extension.
    ///
    /// Parameters:
    /// - `result`: the reply's result, or null.
    ///
    /// Return: true only when `agentCapabilities._meta.inferise` is an object.
    fn speaksInferise(result: ?std.json.Value) bool {
        const r = result orelse return false;
        if (r != .object) return false;
        const capabilities = r.object.get("agentCapabilities") orelse return false;
        if (capabilities != .object) return false;
        const meta = capabilities.object.get("_meta") orelse return false;
        if (meta != .object) return false;
        const ours = meta.object.get(acp.Inferise.key) orelse return false;
        return ours == .object;
    }

    /// Reads whether an agent's `initialize` reply says it takes HTTP MCP servers.
    ///
    /// Parameters:
    /// - `result`: the reply's result, or null.
    ///
    /// Return: true only for an explicit `agentCapabilities.mcpCapabilities.http: true`.
    fn takesHttpMcp(result: ?std.json.Value) bool {
        const r = result orelse return false;
        if (r != .object) return false;
        const capabilities = r.object.get("agentCapabilities") orelse return false;
        if (capabilities != .object) return false;
        const mcp = capabilities.object.get("mcpCapabilities") orelse return false;
        if (mcp != .object) return false;
        const http = mcp.object.get("http") orelse return false;
        return http == .bool and http.bool;
    }

    /// A JSON-RPC notification's text.
    ///
    /// Parameters:
    /// - `arena`: owns the text.
    /// - `method`: the method.
    /// - `params`: the params.
    ///
    /// Return: the frame; propagates allocation failure.
    fn notificationFrame(arena: std.mem.Allocator, method: []const u8, params: std.json.Value) ![]const u8 {
        var root: std.json.ObjectMap = .empty;
        try root.put(arena, "jsonrpc", .{ .string = "2.0" });
        try root.put(arena, "method", .{ .string = method });
        try root.put(arena, "params", params);
        return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = root }, .{});
    }

    /// A JSON-RPC request's text.
    ///
    /// Parameters:
    /// - `arena`: owns the text.
    /// - `id`: the request id.
    /// - `method`: the method.
    /// - `params`: the params.
    ///
    /// Return: the frame; propagates allocation failure.
    fn requestFrame(arena: std.mem.Allocator, id: []const u8, method: []const u8, params: std.json.Value) ![]const u8 {
        var root: std.json.ObjectMap = .empty;
        try root.put(arena, "jsonrpc", .{ .string = "2.0" });
        try root.put(arena, "id", .{ .string = id });
        try root.put(arena, "method", .{ .string = method });
        try root.put(arena, "params", params);
        return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = root }, .{});
    }

    /// Opens the relay's view of a session, or returns the one already open.
    ///
    /// Parameters:
    /// - `self`: the relay; the caller holds the mutex.
    /// - `sid`: the session's id; copied.
    /// - `log_dir`: where its record goes, or null for none.
    /// - `instructions`: what to prepend to its first prompt, or null; copied.
    ///
    /// Return: the session; propagates allocation failure.
    fn openSession(self: *Self, sid: []const u8, log_dir: ?[]const u8, instructions: ?[]const u8) !*RelaySession {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (self.sessions.get(sid)) |existing| return existing;

        const key = try self.allocator.dupe(u8, sid);
        errdefer self.allocator.free(key);
        const session = try self.allocator.create(RelaySession);
        errdefer self.allocator.destroy(session);
        session.* = .{};
        if (log_dir) |dir| session.record = try acp.Relay.SessionLog.init(self.allocator, self.io, self.environ, dir, sid);
        errdefer if (session.record) |*record| record.deinit();
        if (instructions) |text| session.instructions = try self.allocator.dupe(u8, text);
        try self.sessions.put(self.allocator, key, session);
        return session;
    }

    /// Appends a frame to its session's record, when the session keeps one.
    ///
    /// Parameters:
    /// - `self`: the relay; the caller holds the mutex.
    /// - `sid`: the session.
    /// - `origin`: which side sent the frame.
    /// - `frame`: the frame, as forwarded.
    ///
    /// Return: nothing; never fails today, typed to allow it.
    fn recordFrame(self: *Self, sid: []const u8, origin: acp.Relay.SessionLogOrigin, frame: []const u8) !void {
        const session = self.sessions.get(sid) orelse return;
        // A write that fails is logged rather than returned: losing a line of the
        // record must never cost the host its reply.
        if (session.record) |*record_log| {
            record_log.append(origin, self.decoder.turnOf(sid), frame) catch |err| log.warn("record write failed [{t}]", .{err});
        }
    }

    /// Describes a frame crossing the relay's agent side, for the decoder.
    ///
    /// Parameters:
    /// - `self`: the relay.
    /// - `direction`: `sent` toward the agent, `received` from it.
    /// - `bytes`: the frame; borrowed for the call.
    ///
    /// Return: the frame as the decoder reads it.
    fn crossing(self: *Self, direction: acp.Analytics.Direction, bytes: []const u8) acp.Analytics.Frame {
        return .{ .source = "relay", .direction = direction, .sequence = 0, .at = std.Io.Clock.real.now(self.io), .bytes = bytes };
    }

    /// Adds `_meta.inferise` — the turn and one usage shape — to a prompt's reply or a `_inferise/run_ended`.
    ///
    /// Parameters:
    /// - `self`: the relay.
    /// - `arena`: per-frame scratch; owns the returned bytes.
    /// - `root`: the frame, rewritten in place.
    /// - `slot`: the member carrying the turn's end — `result` or `params`.
    /// - `sid`: the session it belongs to.
    ///
    /// Return: the frame's new bytes; propagates allocation failure.
    fn annotateUsage(self: *Self, arena: std.mem.Allocator, root: *std.json.Value, slot: []const u8, sid: []const u8) ![]const u8 {
        const result = root.object.getPtr(slot) orelse return error.NoResult;
        if (result.* != .object) return error.NoResult;
        const meta_slot = try result.object.getOrPut(arena, "_meta");
        if (!meta_slot.found_existing or meta_slot.value_ptr.* != .object) meta_slot.value_ptr.* = .{ .object = .empty };
        const meta = &meta_slot.value_ptr.object;

        // Merged into what the agent already said under the key — its failure
        // sentence, say — rather than replacing it.
        const usage = try acp.Relay.UsageNormalizer.normalize(arena, .{ .object = meta.* }, self.decoder.usageOf(sid));
        const slot_inferise = try meta.getOrPut(arena, acp.Inferise.key);
        if (!slot_inferise.found_existing or slot_inferise.value_ptr.* != .object) slot_inferise.value_ptr.* = .{ .object = .empty };
        try slot_inferise.value_ptr.object.put(arena, "turn", .{ .integer = self.decoder.turnOf(sid) });
        try slot_inferise.value_ptr.object.put(arena, "usage", usage);
        return std.json.Stringify.valueAlloc(arena, root.*, .{});
    }

    /// Records a request as pending under its id.
    ///
    /// Parameters:
    /// - `self`: the relay; the caller holds the mutex.
    /// - `direction`: `forward` for the host's request, `reverse` for the agent's.
    /// - `id`: the request's id.
    /// - `method`: the request's method.
    /// - `pending`: what to keep with it; owned by the relay from here, released on failure.
    ///
    /// Return: nothing; propagates allocation failure and an id that is neither a string nor an integer.
    fn remember(self: *Self, direction: acp.Conductor.Direction, id: std.json.Value, method: []const u8, pending: Pending) !void {
        var owned = pending;
        errdefer owned.deinit(self.allocator);
        // A reused id before its reply: the older request can no longer be matched.
        if (try self.pairing.sent(direction, id, method, owned)) |older| {
            var value = older.value;
            value.deinit(self.allocator);
            self.allocator.free(older.method);
        }
    }

    /// Takes the pending request a reply answers.
    ///
    /// Parameters:
    /// - `self`: the relay; the caller holds the mutex.
    /// - `direction`: which way the reply travels: `forward` from the host, `reverse` from the agent.
    /// - `id`: the reply's id.
    ///
    /// Return: the request, its value caller-owned, or null when none matches.
    fn forget(self: *Self, direction: acp.Conductor.Direction, id: std.json.Value) ?Answered {
        const found = self.pairing.answered(direction, id) orelse return null;
        defer self.allocator.free(found.method);
        return .{ .value = found.value, .kind = PendingKind.of(found.method) };
    }

    /// Puts a text block ahead of a prompt's own.
    ///
    /// Parameters:
    /// - `arena`: per-frame scratch.
    /// - `params`: the `session/prompt` params, rewritten in place.
    /// - `text`: the text to put first; borrowed for the call.
    ///
    /// Return: nothing; propagates allocation failure.
    fn prependText(arena: std.mem.Allocator, params: *std.json.Value, text: []const u8) !void {
        if (params.* != .object) return;
        const prompt = params.object.getPtr("prompt") orelse return;
        if (prompt.* != .array) return;

        var block: std.json.ObjectMap = .empty;
        try block.put(arena, "type", .{ .string = "text" });
        try block.put(arena, "text", .{ .string = try arena.print("{s}\n\n", .{text}) });
        try prompt.array.insert(0, .{ .object = block });
    }

    /// Reads `sessionId` off a params or result object.
    ///
    /// Parameters:
    /// - `value`: the object.
    ///
    /// Return: the id, borrowed; null when absent.
    fn sessionIdOf(value: std.json.Value) ?[]const u8 {
        if (value != .object) return null;
        return stringOf(value.object.get("sessionId"));
    }

    /// Reads a string value.
    ///
    /// Parameters:
    /// - `value`: the value, or null.
    ///
    /// Return: the string, borrowed; null when absent or not a string.
    fn stringOf(value: ?std.json.Value) ?[]const u8 {
        const v = value orelse return null;
        return if (v == .string) v.string else null;
    }

    /// Reads a number value.
    ///
    /// Parameters:
    /// - `value`: the value, or null.
    ///
    /// Return: the number, or null when absent or not a number.
    fn floatOf(value: ?std.json.Value) ?f64 {
        const v = value orelse return null;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RelayProxy);
}

/// A scripted agent for the relay test: answers `session/new` and one prompt.
const ScriptedAgent = struct {
    const Self = @This();

    transport: acp.Transport,
    session_id: []const u8,
    /// What the relay forwarded, for the test to inspect afterwards. Owned.
    seen_new: ?[]u8 = null,
    seen_prompt: ?[]u8 = null,

    /// Answers until the relay hangs up.
    ///
    /// Parameters:
    /// - `self`: the agent.
    ///
    /// Return: nothing.
    fn serve(self: *Self) void {
        const allocator = std.testing.allocator;
        while (true) {
            const frame = self.transport.readFrame(allocator) catch return;
            if (std.mem.find(u8, frame, "\"session/new\"") != null) {
                self.seen_new = frame;
                const reply = allocator.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"sessionId\":\"{s}\"}}}}", .{self.session_id}) catch return;
                defer allocator.free(reply);
                self.transport.writeFrame(.{ .bytes = reply }) catch return;
            } else if (std.mem.find(u8, frame, "\"session/prompt\"") != null) {
                self.seen_prompt = frame;
                const update = allocator.print("{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"{s}\",\"update\":{{\"sessionUpdate\":\"usage_update\",\"used\":900,\"size\":1000}}}}}}", .{self.session_id}) catch return;
                defer allocator.free(update);
                self.transport.writeFrame(.{ .bytes = update }) catch return;
                self.transport.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"stopReason\":\"end_turn\",\"_meta\":{\"inferise\":{\"usage\":{\"inputTokens\":5,\"outputTokens\":7,\"costUsd\":0.01,\"contextTokens\":21383,\"contextWindow\":200000,\"windows\":[{\"id\":\"five_hour\",\"usedPercent\":25,\"resetsAt\":1790475600,\"windowMinutes\":300}]}}}}}" }) catch return;
                // Then a turn the agent starts itself — a background agent reporting back.
                const ended = allocator.print("{{\"jsonrpc\":\"2.0\",\"method\":\"_inferise/run_ended\",\"params\":{{\"sessionId\":\"{s}\",\"stopReason\":\"end_turn\",\"_meta\":{{\"inferise\":{{\"usage\":{{\"inputTokens\":3,\"outputTokens\":4,\"contextTokens\":22000,\"contextWindow\":200000}}}}}}}}}}", .{self.session_id}) catch return;
                defer allocator.free(ended);
                self.transport.writeFrame(.{ .bytes = ended }) catch return;
            } else allocator.free(frame);
        }
    }
};

test "the relay strips its own meta, hands an inferise agent its instructions, annotates the reply and keeps a record" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // SAFETY: filled by `io.random` before any byte of it is read.
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    const session_id = try allocator.print("relay-test-{s}", .{hex});
    defer allocator.free(session_id);

    const host_pair = try acp.FrameTransport.init(allocator, io);
    defer host_pair.deinit();
    const agent_pair = try acp.FrameTransport.init(allocator, io);
    defer agent_pair.deinit();

    var agent = ScriptedAgent{ .transport = agent_pair.agentTransport(), .session_id = session_id };
    defer if (agent.seen_new) |f| allocator.free(f);
    defer if (agent.seen_prompt) |f| allocator.free(f);
    var agent_group: std.Io.Group = .init;
    try agent_group.concurrent(io, ScriptedAgent.serve, .{&agent});

    var relay = try RelayProxy.init(allocator, io, std.testing.environ, host_pair.agentTransport(), agent_pair.clientTransport());
    defer relay.deinit();
    relay.agent_speaks_inferise = true;
    var relay_group: std.Io.Group = .init;
    try relay_group.concurrent(io, runForTest, .{&relay});

    const host = host_pair.clientTransport();
    try host.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":\".\",\"_meta\":{\"inferise\":{\"logDir\":\"/tmp\",\"instructions\":\"Be brief.\"}}}}" });
    const opened = try host.readFrame(allocator);
    allocator.free(opened);

    const prompt = try allocator.print("{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{{\"sessionId\":\"{s}\",\"prompt\":[{{\"type\":\"text\",\"text\":\"hi\"}}]}}}}", .{session_id});
    defer allocator.free(prompt);
    try host.writeFrame(.{ .bytes = prompt });
    const update = try host.readFrame(allocator);
    allocator.free(update);
    const reply = try host.readFrame(allocator);
    defer allocator.free(reply);
    const ended = try host.readFrame(allocator);
    defer allocator.free(ended);

    host_pair.close();
    try relay_group.await(io);
    try agent_group.await(io);

    // The agent got the log directory in the one shape every agent reads, and
    // nothing else of the relay's key; no legacy copy under its own.
    try std.testing.expect(std.mem.find(u8, agent.seen_new.?, "\"inferise\":{\"logDir\":\"/tmp\"}") != null);
    try std.testing.expect(std.mem.find(u8, agent.seen_new.?, "\"zigclaude\"") == null);
    // An inferise agent takes the instructions as `_meta.instructions`, so the prompt goes as sent.
    try std.testing.expect(std.mem.find(u8, agent.seen_new.?, "\"instructions\":\"Be brief.\"") != null);
    try std.testing.expect(std.mem.find(u8, agent.seen_prompt.?, "Be brief.") == null);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, reply, .{});
    defer parsed.deinit();
    const inferise = parsed.value.object.get("result").?.object.get("_meta").?.object.get("inferise").?.object;
    try std.testing.expectEqual(@as(i64, 1), inferise.get("turn").?.integer);
    const usage = inferise.get("usage").?.object;
    try std.testing.expectEqual(@as(i64, 21383), usage.get("contextTokens").?.integer);
    const window = usage.get("windows").?.array.items[0].object;
    // JSON has one number type: 25.0 goes out as `25`, and a host reads either.
    const used = window.get("usedPercent").?;
    try std.testing.expectEqual(@as(f64, 25), switch (used) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => return error.NotANumber,
    });

    // A turn the agent started itself ends with the same usage a reply carries.
    const ended_parsed = try std.json.parseFromSlice(std.json.Value, allocator, ended, .{});
    defer ended_parsed.deinit();
    const ended_usage = ended_parsed.value.object.get("params").?.object.get("_meta").?.object.get("inferise").?.object.get("usage").?.object;
    try std.testing.expectEqual(@as(i64, 22000), ended_usage.get("contextTokens").?.integer);

    const url = try allocator.print("file:///tmp/{s}.jsonl", .{session_id});
    defer allocator.free(url);
    var node = try zigstorage.Node.init(allocator, io, std.testing.environ, url);
    defer node.deinit();
    defer node.remove() catch {};
    const body = try node.read(.all);
    defer allocator.free(body);
    // new request, its reply, the prompt, the update, the annotated reply, the annotated run end.
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, body, "\n"));
    // The turn joins whatever the agent already said under the key, after it.
    try std.testing.expect(std.mem.find(u8, body, "\"inferise\":{") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"turn\":1") != null);
}

test "a tap on the relay's agent side sees each frame of a turn exactly once" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const session_id = "tapped-session";

    const host_pair = try acp.FrameTransport.init(allocator, io);
    defer host_pair.deinit();
    const agent_pair = try acp.FrameTransport.init(allocator, io);
    defer agent_pair.deinit();
    var agent = ScriptedAgent{ .transport = agent_pair.agentTransport(), .session_id = session_id };
    defer if (agent.seen_new) |f| allocator.free(f);
    defer if (agent.seen_prompt) |f| allocator.free(f);
    var agent_group: std.Io.Group = .init;
    try agent_group.concurrent(io, ScriptedAgent.serve, .{&agent});

    var counter = acp.Analytics.FrameCounter{};
    var tap = try acp.Analytics.TapTransport.init(allocator, io, agent_pair.clientTransport(), counter.observer(), "claude");
    defer tap.deinit();
    var relay = try RelayProxy.init(allocator, io, std.testing.environ, host_pair.agentTransport(), tap.transport());
    defer relay.deinit();
    relay.agent_speaks_inferise = true;
    var relay_group: std.Io.Group = .init;
    try relay_group.concurrent(io, runForTest, .{&relay});

    const host = host_pair.clientTransport();
    try host.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":\".\"}}" });
    const opened = try host.readFrame(allocator);
    allocator.free(opened);
    try host.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"tapped-session\",\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}}" });
    // The update, the reply, and the turn the agent ends on its own.
    for (0..3) |_| {
        const frame = try host.readFrame(allocator);
        allocator.free(frame);
    }

    host_pair.close();
    try relay_group.await(io);
    try agent_group.await(io);

    // Out: `session/new` and `session/prompt`. Back: their two replies, the
    // update and `_inferise/run_ended`.
    try std.testing.expectEqual(@as(usize, 2), counter.sent.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 4), counter.received.load(.monotonic));
}

test "the session record never holds the MCP token the agent was given" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // SAFETY: filled by `io.random` before any byte of it is read.
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const session_id = try allocator.print("redact-test-{s}", .{std.fmt.bytesToHex(raw, .lower)});
    defer allocator.free(session_id);

    const host_pair = try acp.FrameTransport.init(allocator, io);
    defer host_pair.deinit();
    const agent_pair = try acp.FrameTransport.init(allocator, io);
    defer agent_pair.deinit();
    var agent = ScriptedAgent{ .transport = agent_pair.agentTransport(), .session_id = session_id };
    defer if (agent.seen_new) |f| allocator.free(f);
    defer if (agent.seen_prompt) |f| allocator.free(f);
    var agent_group: std.Io.Group = .init;
    try agent_group.concurrent(io, ScriptedAgent.serve, .{&agent});

    var relay = try RelayProxy.init(allocator, io, std.testing.environ, host_pair.agentTransport(), agent_pair.clientTransport());
    defer relay.deinit();
    relay.agent_speaks_inferise = true;
    // What Claude's `initialize` says; this test sends none, so it is stated here.
    relay.agent_takes_http_mcp = true;
    const mcp = try acp.McpHttpServer.init(allocator, io, relay.toolHost(), .{ .name = acp.Inferise.mcp_server, .version = "0.0.0-test" });
    defer mcp.deinit();
    relay.mcp = mcp;
    var relay_group: std.Io.Group = .init;
    try relay_group.concurrent(io, runForTest, .{&relay});

    const host = host_pair.clientTransport();
    try host.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":\".\",\"_meta\":{\"inferise\":{\"logDir\":\"/tmp\"}}}}" });
    const opened = try host.readFrame(allocator);
    allocator.free(opened);
    host_pair.close();
    try relay_group.await(io);
    try agent_group.await(io);

    // The agent got a working token…
    const bearer = std.mem.find(u8, agent.seen_new.?, "Bearer ").? + "Bearer ".len;
    const token = agent.seen_new.?[bearer .. bearer + 32];
    try std.testing.expect(!std.mem.eql(u8, token, "redacted"));

    // …and the record on disk does not have it.
    const url = try allocator.print("file:///tmp/{s}.jsonl", .{session_id});
    defer allocator.free(url);
    var node = try zigstorage.Node.init(allocator, io, std.testing.environ, url);
    defer node.deinit();
    defer node.remove() catch {};
    const body = try node.read(.all);
    defer allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, token) == null);
    try std.testing.expect(std.mem.find(u8, body, "Bearer redacted") != null);
}

/// A tool call made from a test task, and what came back.
const ToolCallForTest = struct {
    relay: *RelayProxy,
    token: []const u8,
    tool: []const u8,
    arguments: []const u8,
    /// The outcome's text. Owned.
    result: ?[]u8 = null,

    /// Makes the call.
    ///
    /// Parameters:
    /// - `self`: the call.
    ///
    /// Return: nothing.
    fn run(self: *ToolCallForTest) void {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const arguments = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), self.arguments, .{}) catch return;
        const outcome = self.relay.toolHost().call(arena.allocator(), self.token, self.tool, arguments) catch return;
        self.result = std.testing.allocator.dupe(u8, outcome.text) catch null;
    }
};

test "the relay's tools become messages to the host, and the host's answer comes back as the result" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const host_pair = try acp.FrameTransport.init(allocator, io);
    defer host_pair.deinit();
    const agent_pair = try acp.FrameTransport.init(allocator, io);
    defer agent_pair.deinit();

    var relay = try RelayProxy.init(allocator, io, std.testing.environ, host_pair.agentTransport(), agent_pair.clientTransport());
    defer relay.deinit();
    relay.agent_speaks_inferise = true;
    // What a host that shows notices and renders forms says in its `initialize`.
    relay.host_elicits = true;
    relay.host_shows_notices = true;
    // A session and its token, as `session/new`'s reply would have left them.
    try relay.tokens.put(allocator, try allocator.dupe(u8, "tok"), try allocator.dupe(u8, "s1"));
    try std.testing.expect(relay.toolHost().knows("tok"));
    try std.testing.expect(!relay.toolHost().knows("other"));

    var relay_group: std.Io.Group = .init;
    try relay_group.concurrent(io, runForTest, .{&relay});
    const host = host_pair.clientTransport();

    var progress = ToolCallForTest{ .relay = &relay, .token = "tok", .tool = acp.McpRelayTools.report_progress, .arguments = "{\"summary\":\"halfway\",\"percentComplete\":50,\"confidence\":140}" };
    progress.run();
    defer if (progress.result) |text| allocator.free(text);
    try std.testing.expectEqualStrings("Recorded.", progress.result.?);
    const note = try host.readFrame(allocator);
    defer allocator.free(note);
    // ACP's own `notice`, the summary its title.
    try std.testing.expect(std.mem.find(u8, note, "\"method\":\"session/update\"") != null);
    try std.testing.expect(std.mem.find(u8, note, "\"sessionUpdate\":\"notice\"") != null);
    try std.testing.expect(std.mem.find(u8, note, "\"title\":\"halfway\"") != null);
    // Confidence is a percentage; a model's 140 is clamped rather than passed on.
    try std.testing.expect(std.mem.find(u8, note, "50% done, 100% confident") != null);

    var ask = ToolCallForTest{ .relay = &relay, .token = "tok", .tool = acp.McpRelayTools.ask_user, .arguments = "{\"question\":\"Ship it?\",\"options\":[\"yes\",\"no\"]}" };
    var ask_group: std.Io.Group = .init;
    try ask_group.concurrent(io, ToolCallForTest.run, .{&ask});
    const question = try host.readFrame(allocator);
    defer allocator.free(question);
    // ACP's own `elicitation/create`: a form of one field, the options its choices.
    try std.testing.expect(std.mem.find(u8, question, "\"id\":\"inferise-ask-1\",\"method\":\"elicitation/create\"") != null);
    try std.testing.expect(std.mem.find(u8, question, "\"mode\":\"form\"") != null);
    try std.testing.expect(std.mem.find(u8, question, "\"enum\":[\"yes\",\"no\"]") != null);

    try host.writeFrame(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":\"inferise-ask-1\",\"result\":{\"action\":\"accept\",\"content\":{\"answer\":\"yes\"}}}" });
    try ask_group.await(io);
    defer if (ask.result) |text| allocator.free(text);
    try std.testing.expectEqualStrings("yes", ask.result.?);

    host_pair.close();
    try relay_group.await(io);
    // The host's reply was the relay's to consume: the agent never saw it. The
    // relay closed the agent's end on the way out, and a closed pair delivers
    // anything still queued before it says so — so closure means nothing was sent.
    try std.testing.expectError(error.TransportClosed, agent_pair.agentTransport().tryReadFrame(allocator));
}

test "a host that advertised neither notices nor forms is sent neither" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const host_pair = try acp.FrameTransport.init(allocator, io);
    defer host_pair.deinit();
    const agent_pair = try acp.FrameTransport.init(allocator, io);
    defer agent_pair.deinit();
    var relay = try RelayProxy.init(allocator, io, std.testing.environ, host_pair.agentTransport(), agent_pair.clientTransport());
    defer relay.deinit();
    try relay.tokens.put(allocator, try allocator.dupe(u8, "tok"), try allocator.dupe(u8, "s1"));

    var progress = ToolCallForTest{ .relay = &relay, .token = "tok", .tool = acp.McpRelayTools.report_progress, .arguments = "{\"summary\":\"halfway\"}" };
    progress.run();
    defer if (progress.result) |text| allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, progress.result.?, "Noted"));
    var ask = ToolCallForTest{ .relay = &relay, .token = "tok", .tool = acp.McpRelayTools.ask_user, .arguments = "{\"question\":\"Ship it?\"}" };
    ask.run();
    defer if (ask.result) |text| allocator.free(text);
    try std.testing.expect(std.mem.find(u8, ask.result.?, "cannot ask") != null);
    // Nothing reached the host.
    try std.testing.expectEqual(@as(?[]u8, null), try host_pair.clientTransport().tryReadFrame(allocator));
}

test "the relay trusts its server beside the ones the host already trusts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const host_pair = try acp.FrameTransport.init(allocator, io);
    defer host_pair.deinit();
    const agent_pair = try acp.FrameTransport.init(allocator, io);
    defer agent_pair.deinit();
    var relay = try RelayProxy.init(allocator, io, std.testing.environ, host_pair.agentTransport(), agent_pair.clientTransport());
    defer relay.deinit();
    relay.agent_speaks_inferise = true;
    const mcp = try acp.McpHttpServer.init(allocator, io, relay.toolHost(), .{ .name = acp.Inferise.mcp_server, .version = "0.0.0-test" });
    defer mcp.deinit();
    relay.mcp = mcp;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const out = (try relay.fromHost(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":\".\",\"_meta\":{\"inferise\":{\"trustedMcpServers\":[\"git\",\"inferise\"]}}}}")).?;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const trusted = parsed.value.object.get("params").?.object.get("_meta").?.object.get("inferise").?.object.get("trustedMcpServers").?.array.items;
    // The host's own entry is kept, and one it already had is not repeated.
    try std.testing.expectEqual(@as(usize, 2), trusted.len);
    try std.testing.expectEqualStrings("git", trusted[0].string);
    try std.testing.expectEqualStrings("inferise", trusted[1].string);
}

test "a refused session's token is withdrawn, and a request without an id is minted none" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const host_pair = try acp.FrameTransport.init(allocator, io);
    defer host_pair.deinit();
    const agent_pair = try acp.FrameTransport.init(allocator, io);
    defer agent_pair.deinit();
    var relay = try RelayProxy.init(allocator, io, std.testing.environ, host_pair.agentTransport(), agent_pair.clientTransport());
    defer relay.deinit();
    relay.agent_speaks_inferise = true;
    // What Claude's `initialize` says; this test sends none, so it is stated here.
    relay.agent_takes_http_mcp = true;
    const mcp = try acp.McpHttpServer.init(allocator, io, relay.toolHost(), .{ .name = acp.Inferise.mcp_server, .version = "0.0.0-test" });
    defer mcp.deinit();
    relay.mcp = mcp;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try relay.fromHost(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"method\":\"session/new\",\"params\":{\"cwd\":\".\"}}");
    try std.testing.expectEqual(@as(u32, 0), relay.tokens.count());

    _ = try relay.fromHost(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session/new\",\"params\":{\"cwd\":\".\"}}");
    try std.testing.expectEqual(@as(u32, 1), relay.tokens.count());
    _ = try relay.fromAgent(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32000,\"message\":\"auth_required\"}}");
    try std.testing.expectEqual(@as(u32, 0), relay.tokens.count());
}

/// Runs the relay for a test and swallows the error there is no one to report to.
///
/// Parameters:
/// - `relay`: the relay to run.
///
/// Return: nothing.
fn runForTest(relay: *RelayProxy) void {
    relay.run() catch |err| log.warn("test relay stopped [{t}]", .{err});
}

test "a native agent, which may not read _meta.instructions, gets them ahead of its first prompt" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const host_pair = try acp.FrameTransport.init(allocator, io);
    defer host_pair.deinit();
    const agent_pair = try acp.FrameTransport.init(allocator, io);
    defer agent_pair.deinit();
    var relay = try RelayProxy.init(allocator, io, std.testing.environ, host_pair.agentTransport(), agent_pair.clientTransport());
    defer relay.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const opening = (try relay.fromHost(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":\".\",\"_meta\":{\"inferise\":{\"instructions\":\"Be brief.\"}}}}")).?;
    try std.testing.expect(std.mem.find(u8, opening, "instructions") == null);
    _ = try relay.fromAgent(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"n-1\"}}");

    const prompt = (try relay.fromHost(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"n-1\",\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}}")).?;
    const first = std.mem.find(u8, prompt, "Be brief.").?;
    try std.testing.expect(first < std.mem.find(u8, prompt, "\"hi\"").?);
}

test "an agent behind the relay answers a host's whole turn, numbered and with one usage shape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var agent = try acp.Test.EchoAgent.init(allocator);
    defer agent.deinit();
    const downstream = try acp.Relay.Downstream(acp.Test.EchoAgent).startLinked(allocator, io, &agent, null, "echo");
    defer downstream.deinit();

    const host_pair = try acp.FrameTransport.init(allocator, io);
    defer host_pair.deinit();
    var relay = try RelayProxy.init(allocator, io, std.testing.environ, host_pair.agentTransport(), downstream.transport());
    defer relay.deinit();
    var relay_group: std.Io.Group = .init;
    try relay_group.concurrent(io, runForTest, .{&relay});
    defer {
        host_pair.close();
        relay_group.await(io) catch {};
    }

    var host = acp.Connection.init(allocator, host_pair.clientTransport());
    const hello = try host.request(acp.Agent.InitializeResponse, acp.Agent.method_initialize, acp.Agent.InitializeRequest{ .protocolVersion = acp.ProtocolVersion.V1 });
    defer hello.deinit();
    // The relay learned from the reply that this agent speaks the inferise extension.
    try std.testing.expect(relay.agent_speaks_inferise);

    const opened = try host.request(acp.Agent.NewSessionResponse, acp.Agent.method_session_new, acp.Agent.NewSessionRequest{ .cwd = "." });
    defer opened.deinit();
    const ended = try host.request(acp.Agent.PromptResponse, acp.Agent.method_session_prompt, acp.Agent.PromptRequest{
        .sessionId = opened.value.session_id,
        .prompt = &.{.{ .text = .{ .text = "hi" } }},
    });
    defer ended.deinit();
    try std.testing.expectEqual(acp.Agent.StopReason.end_turn, ended.value.stopReason);
    const ours = ended.value._meta.?.value.object.get(acp.Inferise.key).?.object;
    try std.testing.expectEqual(@as(i64, 1), ours.get(acp.Inferise.turn).?.integer);
    try std.testing.expect(ours.get(acp.Inferise.usage).?.object.get("windows") != null);
}
