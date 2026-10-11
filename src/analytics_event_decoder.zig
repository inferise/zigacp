//! What happened, read off the frames between a client and one agent.
//!
//! A `TapTransport` reports raw frames; this turns them into events — a session
//! opened, a turn started and ended, a tool ran, a permission was asked and
//! answered, the agent's state changed. It pairs each request with its reply by
//! id, separately per direction, because requests run both ways: the client asks
//! the agent to prompt, the agent asks the client for permission.
//!
//! Frames are read from the client's side: `sent` went to the agent, `received`
//! came from it. A frame that does not parse, or that names nothing the decoder
//! tracks, yields no events — the decoder watches and never objects.
//!
//! An agent's state is `busy` while a prompt awaits its reply, `waiting` while a
//! permission request or an `ask_user` call awaits the user (which outranks
//! busy), `exited` once its session is closed or the transport is gone, and
//! `idle` otherwise. Only the protocol decides it; the agent's text never does.
//!
//! Not safe across tasks: the caller serialises `feed`, `noteAsk` and `finish`.

const std = @import("std");
const log = std.log.scoped(.acp_analytics_event_decoder);
const acp = @import("module.zig");

/// What an agent is doing, as far as the protocol shows.
pub const AgentState = enum {
    idle,
    busy,
    waiting,
    exited,
};

/// One thing that happened. Every slice borrows the arena `feed` was given.
pub const AnalyticsEvent = union(enum) {
    sessionOpened: struct {
        session_id: []const u8,
        /// True for `session/load`, false for `session/new`.
        loaded: bool,
    },
    sessionClosed: struct {
        session_id: []const u8,
    },
    turnStarted: struct {
        session_id: []const u8,
        turn: u32,
        /// The prompt's first text block, whole; null when it has none.
        prompt: ?[]const u8,
    },
    turnEnded: struct {
        session_id: []const u8,
        turn: u32,
        /// False for a turn the agent started itself (`_inferise/run_ended`).
        prompted: bool,
        /// The ACP stop reason, or null when the prompt failed.
        stop_reason: ?[]const u8,
        /// The error's message when the prompt failed.
        error_message: ?[]const u8,
        /// From the prompt to its reply; null for an unprompted turn.
        duration_ns: ?u64,
        /// One usage shape across agents (`UsageNormalizer`).
        usage: std.json.Value,
        /// The agent's text for the turn, cut to the decoder's text limit.
        reply: []const u8,
    },
    toolStarted: struct {
        session_id: []const u8,
        tool_call_id: []const u8,
        /// The tool's own name when the agent reports one (`_meta.inferise.tool`), else its title.
        name: []const u8,
        /// The MCP server the tool belongs to; null for a built-in tool.
        server: ?[]const u8,
        kind: ?[]const u8,
        title: []const u8,
        input: ?std.json.Value,
    },
    toolEnded: struct {
        session_id: []const u8,
        tool_call_id: []const u8,
        name: []const u8,
        server: ?[]const u8,
        /// `completed` or `failed`.
        status: []const u8,
        /// From the tool's first report to its last; null when its start was never seen.
        duration_ns: ?u64,
        output: ?std.json.Value,
    },
    permissionAsked: struct {
        session_id: []const u8,
        tool_call_id: ?[]const u8,
        title: ?[]const u8,
    },
    permissionAnswered: struct {
        session_id: []const u8,
        tool_call_id: ?[]const u8,
        /// The chosen option's id, `cancelled`, or `error` when the reply was one.
        outcome: []const u8,
        wait_ns: u64,
    },
    stateChanged: struct {
        session_id: []const u8,
        from: AgentState,
        to: AgentState,
    },
};

/// What a request was, so its reply can be read.
const PendingKind = enum {
    sessionNew,
    sessionLoad,
    sessionPrompt,
    sessionClose,
    permission,
    other,
};

/// A request awaiting its reply. Owns its strings.
const PendingRequest = struct {
    const Self = @This();

    kind: PendingKind,
    /// The session the request named, if any.
    session_id: ?[]u8 = null,
    /// For a permission request: the tool call it is about.
    tool_call_id: ?[]u8 = null,
    /// When the request crossed.
    at: std.Io.Timestamp,

    /// Releases every owned string.
    ///
    /// Parameters:
    /// - `self`: the request.
    /// - `allocator`: the one that allocated it.
    ///
    /// Return: nothing.
    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.session_id) |text| allocator.free(text);
        if (self.tool_call_id) |text| allocator.free(text);
    }
};

/// A tool call between its first report and its last. Owns its strings.
const ToolTrack = struct {
    const Self = @This();

    name: []u8,
    server: ?[]u8 = null,
    started: std.Io.Timestamp,

    /// Releases every owned string.
    ///
    /// Parameters:
    /// - `self`: the track.
    /// - `allocator`: the one that allocated it.
    ///
    /// Return: nothing.
    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.server) |text| allocator.free(text);
    }
};

/// What the decoder keeps for one session.
const DecoderSession = struct {
    const Self = @This();

    /// The turn in progress or last ended; zero before the first prompt.
    turn: u32 = 0,
    /// When the prompt in flight was sent; null when none is.
    turn_started: ?std.Io.Timestamp = null,
    /// Set while `session/load` awaits its reply; the history it replays is not news.
    loading: bool = false,
    closed: bool = false,
    permissions_open: u32 = 0,
    asks_open: u32 = 0,
    state: AgentState = .idle,
    /// The last `usage_update`, for an agent whose replies carry no figures of their own.
    usage: acp.Relay.UsageFallback = .{},
    /// The agent's text this turn, up to the decoder's text limit.
    reply: std.ArrayList(u8) = .empty,
    /// Tool calls started and not yet ended, by tool call id. Keys owned.
    tools: std.StringHashMapUnmanaged(ToolTrack) = .empty,

    /// Releases the session's buffers and tool calls.
    ///
    /// Parameters:
    /// - `self`: the session.
    /// - `allocator`: the one that allocated them.
    ///
    /// Return: nothing.
    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.reply.deinit(allocator);
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        self.tools.deinit(allocator);
    }
};

/// Reads events off one agent's frames.
pub const AnalyticsEventDecoder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// How much of each turn's reply text to keep; zero keeps none.
    text_limit: usize,
    /// Sessions by id. Keys and values owned.
    sessions: std.StringHashMapUnmanaged(*DecoderSession) = .empty,
    /// The client's requests awaiting the agent, by the id's JSON text. Keys owned.
    pending_sent: std.StringHashMapUnmanaged(PendingRequest) = .empty,
    /// The agent's requests awaiting the client, keyed the same way. Keys owned.
    pending_received: std.StringHashMapUnmanaged(PendingRequest) = .empty,

    /// Creates a decoder with nothing seen.
    ///
    /// Parameters:
    /// - `allocator`: backs every table; must outlive the decoder.
    /// - `text_limit`: bytes of each turn's reply text to keep; zero keeps none.
    ///
    /// Return: the decoder, caller calls `deinit`; allocation failure propagates.
    pub fn init(allocator: std.mem.Allocator, text_limit: usize) acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return Self{
            .allocator = allocator,
            .text_limit = text_limit,
        };
    }

    /// Releases every table.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var sessions = self.sessions.iterator();
        while (sessions.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit(self.allocator);
        freeTable(self.allocator, &self.pending_sent);
        freeTable(self.allocator, &self.pending_received);
    }

    /// Reads one frame and returns what it shows.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-frame scratch; owns the events and everything they point at.
    /// - `frame`: the frame and which way it went; only `direction`, `at` and `bytes` are read.
    ///
    /// Return: the events, in order, possibly none; propagates allocation failure.
    pub fn feed(self: *Self, arena: std.mem.Allocator, frame: acp.Analytics.Frame) acp.AcpError![]const AnalyticsEvent {
        var events: std.ArrayList(AnalyticsEvent) = .empty;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, frame.bytes, .{}) catch return &.{};
        if (root != .object) return &.{};
        const object = root.object;

        const id = object.get("id");
        if (stringOf(object.get("method"))) |method| {
            const params = object.get("params");
            switch (frame.direction) {
                .sent => try self.onSentMessage(arena, &events, method, id, params, frame.at),
                .received => try self.onReceivedMessage(arena, &events, method, id, params, frame.at),
            }
        } else if (id) |value| {
            switch (frame.direction) {
                .received => try self.onAgentReply(arena, &events, value, object, frame.at),
                .sent => try self.onReplyToAgent(arena, &events, value, object, frame.at),
            }
        }
        return events.toOwnedSlice(arena);
    }

    /// Notes an `ask_user` call opening or closing, which the frames do not carry.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-call scratch; owns the events.
    /// - `session_id`: the session the call came from.
    /// - `open`: true when the question was put, false when it was answered.
    ///
    /// Return: the state change, if any; propagates allocation failure.
    pub fn noteAsk(self: *Self, arena: std.mem.Allocator, session_id: []const u8, open: bool) acp.AcpError![]const AnalyticsEvent {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var events: std.ArrayList(AnalyticsEvent) = .empty;
        const session = self.sessions.get(session_id) orelse return &.{};
        if (open) session.asks_open += 1 else session.asks_open -|= 1;
        try self.updateState(arena, &events, session_id, session);
        return events.toOwnedSlice(arena);
    }

    /// Ends every session still open, for a transport that has gone.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-call scratch; owns the events.
    ///
    /// Return: each open session's close and state change; propagates allocation failure.
    pub fn finish(self: *Self, arena: std.mem.Allocator) acp.AcpError![]const AnalyticsEvent {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var events: std.ArrayList(AnalyticsEvent) = .empty;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.closed) continue;
            try self.closeSession(arena, &events, entry.key_ptr.*, entry.value_ptr.*);
        }
        return events.toOwnedSlice(arena);
    }

    /// Returns a session's current turn.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `session_id`: the session.
    ///
    /// Return: the turn in progress or last ended; zero for a session with no prompt or none seen.
    pub fn turnOf(self: *const Self, session_id: []const u8) u32 {
        const session = self.sessions.get(session_id) orelse return 0;
        return session.turn;
    }

    /// Returns the figures a session's last `usage_update` carried.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `session_id`: the session.
    ///
    /// Return: the figures, zero when none were seen.
    pub fn usageOf(self: *const Self, session_id: []const u8) acp.Relay.UsageFallback {
        const session = self.sessions.get(session_id) orelse return .{};
        return session.usage;
    }

    /// Returns a session's state.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `session_id`: the session.
    ///
    /// Return: the state, or null for a session never seen.
    pub fn stateOf(self: *const Self, session_id: []const u8) ?AgentState {
        const session = self.sessions.get(session_id) orelse return null;
        return session.state;
    }

    /// Reads a request or notification the client sent.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-frame scratch.
    /// - `events`: where events go.
    /// - `method`: the method.
    /// - `id`: the request's id, or null for a notification.
    /// - `params`: the params, or null.
    /// - `at`: when it crossed.
    ///
    /// Return: nothing; propagates allocation failure.
    fn onSentMessage(self: *Self, arena: std.mem.Allocator, events: *std.ArrayList(AnalyticsEvent), method: []const u8, id: ?std.json.Value, params: ?std.json.Value, at: std.Io.Timestamp) !void {
        const sid = if (params) |p| sessionIdOf(p) else null;
        var kind: PendingKind = .other;

        if (std.mem.eql(u8, method, acp.Agent.method_session_prompt)) {
            kind = .sessionPrompt;
            if (sid) |name| {
                const session = try self.sessionFor(name);
                session.turn += 1;
                session.turn_started = at;
                session.reply.clearRetainingCapacity();
                try events.append(arena, .{ .turnStarted = .{ .session_id = name, .turn = session.turn, .prompt = if (params) |p| firstText(p) else null } });
                try self.updateState(arena, events, name, session);
            }
        } else if (std.mem.eql(u8, method, acp.Agent.method_session_new)) {
            kind = .sessionNew;
        } else if (std.mem.eql(u8, method, acp.Agent.method_session_load)) {
            kind = .sessionLoad;
            if (sid) |name| {
                const session = try self.sessionFor(name);
                session.loading = true;
                session.closed = false;
            }
        } else if (std.mem.eql(u8, method, acp.Agent.method_session_close)) {
            kind = .sessionClose;
        }

        if (id) |value| try self.remember(&self.pending_sent, arena, value, .{ .kind = kind, .at = at }, sid, null);
    }

    /// Reads a request or notification the agent sent.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-frame scratch.
    /// - `events`: where events go.
    /// - `method`: the method.
    /// - `id`: the request's id, or null for a notification.
    /// - `params`: the params, or null.
    /// - `at`: when it crossed.
    ///
    /// Return: nothing; propagates allocation failure.
    fn onReceivedMessage(self: *Self, arena: std.mem.Allocator, events: *std.ArrayList(AnalyticsEvent), method: []const u8, id: ?std.json.Value, params: ?std.json.Value, at: std.Io.Timestamp) !void {
        const sid = if (params) |p| sessionIdOf(p) else null;

        if (id) |value| {
            if (std.mem.eql(u8, method, acp.Client.method_session_request_permission)) {
                const call = if (params) |p| objectOf(p.object.get("toolCall")) else null;
                const tool_call_id = if (call) |c| stringOf(c.get("toolCallId")) else null;
                try self.remember(&self.pending_received, arena, value, .{ .kind = .permission, .at = at }, sid, tool_call_id);
                if (sid) |name| {
                    const session = try self.sessionFor(name);
                    session.permissions_open += 1;
                    try events.append(arena, .{ .permissionAsked = .{ .session_id = name, .tool_call_id = tool_call_id, .title = if (call) |c| stringOf(c.get("title")) else null } });
                    try self.updateState(arena, events, name, session);
                }
            } else {
                try self.remember(&self.pending_received, arena, value, .{ .kind = .other, .at = at }, sid, null);
            }
            return;
        }

        const name = sid orelse return;
        if (std.mem.eql(u8, method, acp.Agent.method_session_update)) {
            const session = try self.sessionFor(name);
            // History a `session/load` replays happened before; it is not news.
            if (session.loading) return;
            const update = objectOf(params.?.object.get("update")) orelse return;
            try self.onUpdate(arena, events, name, session, update, at);
        } else if (std.mem.eql(u8, method, acp.Inferise.method_run_ended)) {
            // A turn the agent started itself, ending without a prompt to answer.
            const session = try self.sessionFor(name);
            try events.append(arena, .{ .turnEnded = .{
                .session_id = name,
                .turn = session.turn,
                .prompted = false,
                .stop_reason = stringOf(params.?.object.get("stopReason")),
                .error_message = null,
                .duration_ns = null,
                .usage = try usageFrom(arena, params.?, session),
                .reply = "",
            } });
        }
    }

    /// Reads one `session/update`.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-frame scratch.
    /// - `events`: where events go.
    /// - `sid`: the session.
    /// - `session`: its state.
    /// - `update`: the update object.
    /// - `at`: when it crossed.
    ///
    /// Return: nothing; propagates allocation failure.
    fn onUpdate(self: *Self, arena: std.mem.Allocator, events: *std.ArrayList(AnalyticsEvent), sid: []const u8, session: *DecoderSession, update: std.json.ObjectMap, at: std.Io.Timestamp) !void {
        const kind = stringOf(update.get("sessionUpdate")) orelse return;

        if (std.mem.eql(u8, kind, "agent_message_chunk")) {
            const content = objectOf(update.get("content")) orelse return;
            const text = stringOf(content.get("text")) orelse return;
            const room = self.text_limit -| session.reply.items.len;
            if (room > 0) try session.reply.appendSlice(self.allocator, utf8Prefix(text, room));
        } else if (std.mem.eql(u8, kind, "usage_update")) {
            session.usage.used = unsignedOf(update.get("used"));
            session.usage.size = unsignedOf(update.get("size"));
            if (objectOf(update.get("cost"))) |cost| session.usage.cost_usd = floatOf(cost.get("amount"));
        } else if (std.mem.eql(u8, kind, "tool_call")) {
            try self.onToolCall(arena, events, sid, session, update, at);
        } else if (std.mem.eql(u8, kind, "tool_call_update")) {
            const status = stringOf(update.get("status")) orelse return;
            if (isFinal(status)) try self.endTool(arena, events, sid, session, update, status, at);
        }
    }

    /// Reads a `tool_call` update: a tool starting, or one reported already done.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-frame scratch.
    /// - `events`: where events go.
    /// - `sid`: the session.
    /// - `session`: its state.
    /// - `update`: the update object.
    /// - `at`: when it crossed.
    ///
    /// Return: nothing; propagates allocation failure.
    fn onToolCall(self: *Self, arena: std.mem.Allocator, events: *std.ArrayList(AnalyticsEvent), sid: []const u8, session: *DecoderSession, update: std.json.ObjectMap, at: std.Io.Timestamp) !void {
        const tool_call_id = stringOf(update.get("toolCallId")) orelse return;
        const title = stringOf(update.get("title")) orelse "";
        const reported = toolMetaOf(update);
        const name = reported.name orelse title;

        const slot = try session.tools.getOrPut(self.allocator, tool_call_id);
        if (!slot.found_existing) {
            errdefer session.tools.removeByPtr(slot.key_ptr);
            const key = try self.allocator.dupe(u8, tool_call_id);
            errdefer self.allocator.free(key);
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const owned_server = if (reported.server) |text| try self.allocator.dupe(u8, text) else null;
            slot.key_ptr.* = key;
            slot.value_ptr.* = .{ .name = owned_name, .server = owned_server, .started = at };
        }
        try events.append(arena, .{ .toolStarted = .{
            .session_id = sid,
            .tool_call_id = tool_call_id,
            .name = name,
            .server = reported.server,
            .kind = stringOf(update.get("kind")),
            .title = title,
            .input = update.get("rawInput"),
        } });

        if (stringOf(update.get("status"))) |status| if (isFinal(status)) try self.endTool(arena, events, sid, session, update, status, at);
    }

    /// Ends a tool call, reporting how long it ran when its start was seen.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-frame scratch.
    /// - `events`: where events go.
    /// - `sid`: the session.
    /// - `session`: its state.
    /// - `update`: the update reporting the end.
    /// - `status`: `completed` or `failed`.
    /// - `at`: when it crossed.
    ///
    /// Return: nothing; propagates allocation failure.
    fn endTool(self: *Self, arena: std.mem.Allocator, events: *std.ArrayList(AnalyticsEvent), sid: []const u8, session: *DecoderSession, update: std.json.ObjectMap, status: []const u8, at: std.Io.Timestamp) !void {
        const tool_call_id = stringOf(update.get("toolCallId")) orelse return;
        const reported = toolMetaOf(update);

        var name: []const u8 = reported.name orelse stringOf(update.get("title")) orelse "";
        var server: ?[]const u8 = reported.server;
        var duration: ?u64 = null;
        if (session.tools.fetchRemove(tool_call_id)) |removed| {
            var track = removed.value;
            defer track.deinit(self.allocator);
            defer self.allocator.free(removed.key);
            name = try arena.dupe(u8, track.name);
            if (track.server) |text| server = try arena.dupe(u8, text);
            duration = nanosBetween(track.started, at);
        }
        try events.append(arena, .{
            .toolEnded = .{
                .session_id = sid,
                .tool_call_id = tool_call_id,
                .name = name,
                .server = server,
                .status = status,
                .duration_ns = duration,
                // `rawOutput` is meant for a program; an agent that sends only the
                // `content` it shows a person still has its output read from there.
                .output = update.get("rawOutput") orelse try contentText(arena, update),
            },
        });
    }

    /// Reads the agent's reply to one of the client's requests.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-frame scratch.
    /// - `events`: where events go.
    /// - `id`: the reply's id.
    /// - `object`: the reply.
    /// - `at`: when it crossed.
    ///
    /// Return: nothing; propagates allocation failure.
    fn onAgentReply(self: *Self, arena: std.mem.Allocator, events: *std.ArrayList(AnalyticsEvent), id: std.json.Value, object: std.json.ObjectMap, at: std.Io.Timestamp) !void {
        var pending = (try self.forget(&self.pending_sent, arena, id)) orelse return;
        defer pending.deinit(self.allocator);
        const result = object.get("result");

        switch (pending.kind) {
            .sessionNew => {
                const sid = sessionIdOf(result orelse return) orelse return;
                _ = try self.sessionFor(sid);
                try events.append(arena, .{ .sessionOpened = .{ .session_id = sid, .loaded = false } });
            },
            .sessionLoad => {
                const sid = try arena.dupe(u8, pending.session_id orelse return);
                const session = try self.sessionFor(sid);
                session.loading = false;
                if (result != null) try events.append(arena, .{ .sessionOpened = .{ .session_id = sid, .loaded = true } });
            },
            .sessionPrompt => {
                const sid = try arena.dupe(u8, pending.session_id orelse return);
                const session = try self.sessionFor(sid);
                const failure = objectOf(object.get("error"));
                try events.append(arena, .{ .turnEnded = .{
                    .session_id = sid,
                    .turn = session.turn,
                    .prompted = true,
                    .stop_reason = if (result) |r| (if (r == .object) stringOf(r.object.get("stopReason")) else null) else null,
                    .error_message = if (failure) |f| stringOf(f.get("message")) else null,
                    .duration_ns = if (session.turn_started) |started| nanosBetween(started, at) else null,
                    .usage = try usageFrom(arena, result orelse .null, session),
                    .reply = try arena.dupe(u8, session.reply.items),
                } });
                session.turn_started = null;
                try self.updateState(arena, events, sid, session);
            },
            .sessionClose => {
                if (result == null) return;
                const sid = try arena.dupe(u8, pending.session_id orelse return);
                const session = try self.sessionFor(sid);
                if (!session.closed) try self.closeSession(arena, events, sid, session);
            },
            .permission, .other => {},
        }
    }

    /// Reads the client's reply to one of the agent's requests.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-frame scratch.
    /// - `events`: where events go.
    /// - `id`: the reply's id.
    /// - `object`: the reply.
    /// - `at`: when it crossed.
    ///
    /// Return: nothing; propagates allocation failure.
    fn onReplyToAgent(self: *Self, arena: std.mem.Allocator, events: *std.ArrayList(AnalyticsEvent), id: std.json.Value, object: std.json.ObjectMap, at: std.Io.Timestamp) !void {
        var pending = (try self.forget(&self.pending_received, arena, id)) orelse return;
        defer pending.deinit(self.allocator);
        if (pending.kind != .permission) return;
        const sid = try arena.dupe(u8, pending.session_id orelse return);
        const session = try self.sessionFor(sid);
        session.permissions_open -|= 1;

        var outcome: []const u8 = "error";
        if (objectOf(object.get("result"))) |result| if (objectOf(result.get("outcome"))) |chosen| {
            const how = stringOf(chosen.get("outcome")) orelse "";
            outcome = if (std.mem.eql(u8, how, "selected")) stringOf(chosen.get("optionId")) orelse "selected" else how;
        };
        try events.append(arena, .{ .permissionAnswered = .{
            .session_id = sid,
            .tool_call_id = if (pending.tool_call_id) |text| try arena.dupe(u8, text) else null,
            .outcome = outcome,
            .wait_ns = nanosBetween(pending.at, at),
        } });
        try self.updateState(arena, events, sid, session);
    }

    /// Marks a session closed and reports it.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-call scratch.
    /// - `events`: where events go.
    /// - `sid`: the session; must outlive the events.
    /// - `session`: its state.
    ///
    /// Return: nothing; propagates allocation failure.
    fn closeSession(self: *Self, arena: std.mem.Allocator, events: *std.ArrayList(AnalyticsEvent), sid: []const u8, session: *DecoderSession) !void {
        const name = try arena.dupe(u8, sid);
        session.closed = true;
        session.turn_started = null;
        try events.append(arena, .{ .sessionClosed = .{ .session_id = name } });
        try self.updateState(arena, events, name, session);
    }

    /// Recomputes a session's state and reports a change.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `arena`: per-call scratch.
    /// - `events`: where events go.
    /// - `sid`: the session; must outlive the events.
    /// - `session`: its state.
    ///
    /// Return: nothing; propagates allocation failure.
    fn updateState(self: *Self, arena: std.mem.Allocator, events: *std.ArrayList(AnalyticsEvent), sid: []const u8, session: *DecoderSession) !void {
        _ = self;
        const now: AgentState = if (session.closed)
            .exited
        else if (session.permissions_open > 0 or session.asks_open > 0)
            .waiting
        else if (session.turn_started != null)
            .busy
        else
            .idle;
        if (now == session.state) return;
        try events.append(arena, .{ .stateChanged = .{ .session_id = sid, .from = session.state, .to = now } });
        session.state = now;
    }

    /// Returns a session's state, creating it the first time the session is named.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `sid`: the session id; copied when new.
    ///
    /// Return: the session, owned by the decoder; propagates allocation failure.
    fn sessionFor(self: *Self, sid: []const u8) !*DecoderSession {
        const slot = try self.sessions.getOrPut(self.allocator, sid);
        if (slot.found_existing) return slot.value_ptr.*;
        errdefer self.sessions.removeByPtr(slot.key_ptr);
        const key = try self.allocator.dupe(u8, sid);
        errdefer self.allocator.free(key);
        const session = try self.allocator.create(DecoderSession);
        session.* = .{};
        slot.key_ptr.* = key;
        slot.value_ptr.* = session;
        return session;
    }

    /// Builds the normalized usage for a turn's end.
    ///
    /// Parameters:
    /// - `arena`: per-frame scratch; owns the result.
    /// - `carrier`: the reply's `result`, or `_inferise/run_ended`'s params.
    /// - `session`: the session, for its `usage_update` fallback.
    ///
    /// Return: the usage object; propagates allocation failure.
    fn usageFrom(arena: std.mem.Allocator, carrier: std.json.Value, session: *DecoderSession) !std.json.Value {
        const meta: ?std.json.Value = if (carrier == .object) carrier.object.get("_meta") else null;
        return acp.Relay.UsageNormalizer.normalize(arena, meta, session.usage);
    }

    /// Reads the tool's name — ACP's own `name`, else `_meta.inferise.tool.name` — and its MCP server.
    ///
    /// Parameters:
    /// - `update`: the tool update.
    ///
    /// Return: the name and server, each null when not reported.
    fn toolMetaOf(update: std.json.ObjectMap) struct { name: ?[]const u8, server: ?[]const u8 } {
        const named = stringOf(update.get("name"));
        const meta = objectOf(update.get("_meta")) orelse return .{ .name = named, .server = null };
        const ours = objectOf(meta.get(acp.Inferise.key)) orelse return .{ .name = named, .server = null };
        const tool = objectOf(ours.get(acp.Inferise.tool)) orelse return .{ .name = named, .server = null };
        return .{ .name = named orelse stringOf(tool.get("name")), .server = stringOf(tool.get("server")) };
    }

    /// Records a request as pending under its id.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `table`: the table of the side that asked.
    /// - `arena`: per-frame scratch, for the id's text.
    /// - `id`: the request's id.
    /// - `request`: what to remember, without its strings.
    /// - `session_id`: the session it named, or null; copied.
    /// - `tool_call_id`: the tool call it concerns, or null; copied.
    ///
    /// Return: nothing; propagates allocation failure.
    fn remember(self: *Self, table: *std.StringHashMapUnmanaged(PendingRequest), arena: std.mem.Allocator, id: std.json.Value, request: PendingRequest, session_id: ?[]const u8, tool_call_id: ?[]const u8) !void {
        var owned = request;
        errdefer owned.deinit(self.allocator);
        if (session_id) |text| owned.session_id = try self.allocator.dupe(u8, text);
        if (tool_call_id) |text| owned.tool_call_id = try self.allocator.dupe(u8, text);

        const text = try std.json.Stringify.valueAlloc(arena, id, .{});
        const slot = try table.getOrPut(self.allocator, text);
        if (slot.found_existing) {
            // A reused id before its reply: the older request can no longer be matched.
            slot.value_ptr.deinit(self.allocator);
        } else {
            slot.key_ptr.* = self.allocator.dupe(u8, text) catch |err| {
                table.removeByPtr(slot.key_ptr);
                return err;
            };
        }
        slot.value_ptr.* = owned;
    }

    /// Takes a pending request out of a table by the id its reply carries.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `table`: the table of the side that asked.
    /// - `arena`: per-frame scratch, for the id's text.
    /// - `id`: the reply's id.
    ///
    /// Return: the request, caller-owned, or null when none matches; propagates allocation failure.
    fn forget(self: *Self, table: *std.StringHashMapUnmanaged(PendingRequest), arena: std.mem.Allocator, id: std.json.Value) !?PendingRequest {
        const text = try std.json.Stringify.valueAlloc(arena, id, .{});
        const removed = table.fetchRemove(text) orelse return null;
        self.allocator.free(removed.key);
        return removed.value;
    }

    /// Frees a table's keys and pending requests.
    ///
    /// Parameters:
    /// - `allocator`: the one that allocated them.
    /// - `table`: the table.
    ///
    /// Return: nothing.
    fn freeTable(allocator: std.mem.Allocator, table: *std.StringHashMapUnmanaged(PendingRequest)) void {
        var it = table.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        table.deinit(allocator);
    }

    /// Joins the text of a tool update's `content` blocks, for an agent that sends no `rawOutput`.
    ///
    /// Parameters:
    /// - `arena`: owns the result.
    /// - `update`: the tool update.
    ///
    /// Return: the text as a string value, or null when the content holds none; propagates allocation failure.
    fn contentText(arena: std.mem.Allocator, update: std.json.ObjectMap) !?std.json.Value {
        const content = update.get("content") orelse return null;
        if (content != .array) return null;
        var text: std.ArrayList(u8) = .empty;
        for (content.array.items) |entry| {
            // A `content` entry wraps a content block; a `diff` or `terminal` entry carries no text.
            const wrapper = objectOf(entry) orelse continue;
            const block = objectOf(wrapper.get("content")) orelse continue;
            const body = stringOf(block.get("text")) orelse continue;
            if (text.items.len > 0) try text.append(arena, '\n');
            try text.appendSlice(arena, body);
        }
        if (text.items.len == 0) return null;
        return .{ .string = text.items };
    }

    /// Reports whether a tool status is one a tool call ends on.
    ///
    /// Parameters:
    /// - `status`: the status.
    ///
    /// Return: true for `completed` and `failed`.
    fn isFinal(status: []const u8) bool {
        return std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed");
    }

    /// Reads the first text block of a prompt's params.
    ///
    /// Parameters:
    /// - `params`: the `session/prompt` params.
    ///
    /// Return: the text, borrowed; null when there is none.
    fn firstText(params: std.json.Value) ?[]const u8 {
        if (params != .object) return null;
        const prompt = params.object.get("prompt") orelse return null;
        if (prompt != .array) return null;
        for (prompt.array.items) |block| {
            const fields = objectOf(block) orelse continue;
            const kind = stringOf(fields.get("type")) orelse continue;
            if (std.mem.eql(u8, kind, "text")) return stringOf(fields.get("text"));
        }
        return null;
    }

    /// Returns the longest prefix of a UTF-8 string within a byte budget, never splitting a character.
    ///
    /// Parameters:
    /// - `text`: the string.
    /// - `budget`: the most bytes to keep.
    ///
    /// Return: the prefix, borrowed.
    pub fn utf8Prefix(text: []const u8, budget: usize) []const u8 {
        if (text.len <= budget) return text;
        var end = budget;
        while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
        return text[0..end];
    }

    /// Returns the nanoseconds from one time to another, zero if the clock went backwards.
    ///
    /// Parameters:
    /// - `from`: the earlier time.
    /// - `to`: the later time.
    ///
    /// Return: the gap in nanoseconds.
    fn nanosBetween(from: std.Io.Timestamp, to: std.Io.Timestamp) u64 {
        const gap = to.nanoseconds - from.nanoseconds;
        if (gap <= 0) return 0;
        return @intCast(@min(gap, std.math.maxInt(u64)));
    }

    /// Reads `sessionId` off a params or result object.
    ///
    /// Parameters:
    /// - `value`: the object.
    ///
    /// Return: the id, borrowed; null when absent.
    fn sessionIdOf(value: std.json.Value) ?[]const u8 {
        const fields = objectOf(value) orelse return null;
        return stringOf(fields.get("sessionId"));
    }

    /// Reads an object value.
    ///
    /// Parameters:
    /// - `value`: the value, or null.
    ///
    /// Return: the object, borrowed; null when absent or not an object.
    fn objectOf(value: ?std.json.Value) ?std.json.ObjectMap {
        const present = value orelse return null;
        return if (present == .object) present.object else null;
    }

    /// Reads a string value.
    ///
    /// Parameters:
    /// - `value`: the value, or null.
    ///
    /// Return: the string, borrowed; null when absent or not a string.
    fn stringOf(value: ?std.json.Value) ?[]const u8 {
        const present = value orelse return null;
        return if (present == .string) present.string else null;
    }

    /// Reads a non-negative integer value.
    ///
    /// Parameters:
    /// - `value`: the value, or null.
    ///
    /// Return: the integer; zero when absent, negative or not an integer.
    fn unsignedOf(value: ?std.json.Value) u64 {
        const present = value orelse return 0;
        return if (present == .integer and present.integer > 0) @intCast(present.integer) else 0;
    }

    /// Reads a number value.
    ///
    /// Parameters:
    /// - `value`: the value, or null.
    ///
    /// Return: the number; null when absent or not a number.
    fn floatOf(value: ?std.json.Value) ?f64 {
        const present = value orelse return null;
        return switch (present) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

/// A session recorded as `SessionLog` writes it — one frame per line with who
/// sent it — covering a turn with a built-in tool behind a permission, an MCP
/// tool that fails, the agent's text, a `usage_update` and the reply's own figures.
const recorded_session =
    \\{"ts":1000,"from":"client","turn":0,"frame":{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}}
    \\{"ts":1010,"from":"agent","turn":0,"frame":{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}}
    \\{"ts":1020,"from":"client","turn":0,"frame":{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/work","mcpServers":[]}}}
    \\{"ts":1030,"from":"agent","turn":0,"frame":{"jsonrpc":"2.0","id":1,"result":{"sessionId":"s1"}}}
    \\{"ts":2000,"from":"client","turn":1,"frame":{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"s1","prompt":[{"type":"text","text":"List the files"}]}}}
    \\{"ts":2050,"from":"agent","turn":1,"frame":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"ls -la","kind":"execute","status":"pending","rawInput":{"command":"ls -la"},"_meta":{"inferise":{"tool":{"name":"Bash","agent":"claude"}}}}}}}
    \\{"ts":2100,"from":"agent","turn":1,"frame":{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"ls -la"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}}
    \\{"ts":2400,"from":"client","turn":1,"frame":{"jsonrpc":"2.0","id":"p1","result":{"outcome":{"outcome":"selected","optionId":"allow"}}}}
    \\{"ts":2500,"from":"agent","turn":1,"frame":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","rawOutput":"a.txt b.txt"}}}}
    \\{"ts":2600,"from":"agent","turn":1,"frame":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t2","title":"search docs","kind":"other","status":"in_progress","_meta":{"inferise":{"tool":{"name":"search","server":"docs","agent":"claude"}}}}}}}
    \\{"ts":2700,"from":"agent","turn":1,"frame":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"t2","status":"failed"}}}}
    \\{"ts":2800,"from":"agent","turn":1,"frame":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Two files: a.txt and b.txt."}}}}}
    \\{"ts":2900,"from":"agent","turn":1,"frame":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"usage_update","used":900,"size":1000}}}}
    \\{"ts":3000,"from":"agent","turn":1,"frame":{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn","_meta":{"inferise":{"usage":{"inputTokens":5,"outputTokens":7,"contextTokens":21383,"contextWindow":200000}}}}}}
;

/// Feeds a recorded session to a decoder, line by line, collecting every event.
///
/// Parameters:
/// - `decoder`: the decoder.
/// - `arena`: owns the events.
/// - `jsonl`: the record, one `SessionLog` line per frame.
///
/// Return: every event in order; propagates parse and allocation failures.
fn replay(decoder: *AnalyticsEventDecoder, arena: std.mem.Allocator, jsonl: []const u8) ![]const AnalyticsEvent {
    var all: std.ArrayList(AnalyticsEvent) = .empty;
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const entry = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        const from = entry.object.get("from").?.string;
        const ts: i96 = entry.object.get("ts").?.integer;
        const bytes = try std.json.Stringify.valueAlloc(arena, entry.object.get("frame").?, .{});
        const events = try decoder.feed(arena, .{
            .source = "claude",
            .direction = if (std.mem.eql(u8, from, "client")) .sent else .received,
            .sequence = 0,
            .at = .{ .nanoseconds = ts * std.time.ns_per_ms },
            .bytes = bytes,
        });
        try all.appendSlice(arena, events);
    }
    return all.items;
}

/// Feeds one frame read from the client's side.
///
/// Parameters:
/// - `decoder`: the decoder.
/// - `arena`: owns the events.
/// - `direction`: which way it went.
/// - `bytes`: the frame.
///
/// Return: the events; propagates allocation failure.
fn feedOne(decoder: *AnalyticsEventDecoder, arena: std.mem.Allocator, direction: acp.Analytics.Direction, bytes: []const u8) ![]const AnalyticsEvent {
    return decoder.feed(arena, .{ .source = "test", .direction = direction, .sequence = 0, .at = .{ .nanoseconds = 0 }, .bytes = bytes });
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(AnalyticsEventDecoder);
}

test "a recorded turn replays as sessions, turns, tools, permissions and states, in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var decoder = try AnalyticsEventDecoder.init(std.testing.allocator, 80);
    defer decoder.deinit();

    const events = try replay(&decoder, arena, recorded_session);

    const expected = [_]std.meta.Tag(AnalyticsEvent){
        .sessionOpened,
        .turnStarted,
        .stateChanged, // idle → busy
        .toolStarted,
        .permissionAsked,
        .stateChanged, // busy → waiting
        .permissionAnswered,
        .stateChanged, // waiting → busy
        .toolEnded,
        .toolStarted,
        .toolEnded,
        .turnEnded,
        .stateChanged, // busy → idle
    };
    try std.testing.expectEqual(expected.len, events.len);
    for (expected, events) |tag, event| try std.testing.expectEqual(tag, std.meta.activeTag(event));

    try std.testing.expectEqualStrings("s1", events[0].sessionOpened.session_id);
    try std.testing.expectEqualStrings("List the files", events[1].turnStarted.prompt.?);
    try std.testing.expectEqual(AgentState.busy, events[2].stateChanged.to);

    // The agent's own name for the tool, not its title.
    try std.testing.expectEqualStrings("Bash", events[3].toolStarted.name);
    try std.testing.expectEqualStrings("ls -la", events[3].toolStarted.title);
    try std.testing.expectEqualStrings("ls -la", events[3].toolStarted.input.?.object.get("command").?.string);
    try std.testing.expectEqual(@as(?[]const u8, null), events[3].toolStarted.server);

    try std.testing.expectEqual(AgentState.waiting, events[5].stateChanged.to);
    try std.testing.expectEqualStrings("allow", events[6].permissionAnswered.outcome);
    try std.testing.expectEqual(@as(u64, 300 * std.time.ns_per_ms), events[6].permissionAnswered.wait_ns);

    try std.testing.expectEqualStrings("Bash", events[8].toolEnded.name);
    try std.testing.expectEqualStrings("completed", events[8].toolEnded.status);
    try std.testing.expectEqual(@as(?u64, 450 * std.time.ns_per_ms), events[8].toolEnded.duration_ns);
    try std.testing.expectEqualStrings("a.txt b.txt", events[8].toolEnded.output.?.string);

    // An MCP tool: one whose server is named.
    try std.testing.expectEqualStrings("docs", events[9].toolStarted.server.?);
    try std.testing.expectEqualStrings("failed", events[10].toolEnded.status);
    try std.testing.expectEqualStrings("docs", events[10].toolEnded.server.?);

    const ended = events[11].turnEnded;
    try std.testing.expectEqual(@as(u32, 1), ended.turn);
    try std.testing.expect(ended.prompted);
    try std.testing.expectEqualStrings("end_turn", ended.stop_reason.?);
    try std.testing.expectEqual(@as(?u64, 1000 * std.time.ns_per_ms), ended.duration_ns);
    try std.testing.expectEqualStrings("Two files: a.txt and b.txt.", ended.reply);
    try std.testing.expectEqual(@as(i64, 21383), ended.usage.object.get("contextTokens").?.integer);
    try std.testing.expectEqual(AgentState.idle, events[12].stateChanged.to);

    try std.testing.expectEqual(@as(u32, 1), decoder.turnOf("s1"));
    try std.testing.expectEqual(@as(u64, 900), decoder.usageOf("s1").used);
}

test "the reply text is cut to the limit on a character boundary, and a zero limit keeps none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var short = try AnalyticsEventDecoder.init(std.testing.allocator, 2);
    defer short.deinit();
    var none = try AnalyticsEventDecoder.init(std.testing.allocator, 0);
    defer none.deinit();

    // "héllo": the `é` is bytes 1 and 2, so a two-byte limit would split it.
    const frames = [_]struct { acp.Analytics.Direction, []const u8 }{
        .{ .sent, "{\"id\":1,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\",\"prompt\":[]}}" },
        .{ .received, "{\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"h\\u00e9llo\"}}}}" },
        .{ .received, "{\"id\":1,\"result\":{\"stopReason\":\"end_turn\"}}" },
    };
    var short_reply: []const u8 = "";
    var none_reply: []const u8 = "unset";
    for (frames) |frame| {
        for (try feedOne(&short, arena, frame[0], frame[1])) |event| if (event == .turnEnded) {
            short_reply = event.turnEnded.reply;
        };
        for (try feedOne(&none, arena, frame[0], frame[1])) |event| if (event == .turnEnded) {
            none_reply = event.turnEnded.reply;
        };
    }
    try std.testing.expectEqualStrings("h", short_reply);
    try std.testing.expectEqualStrings("", none_reply);
}

test "history replayed by session/load is not reported, and the load opens the session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var decoder = try AnalyticsEventDecoder.init(std.testing.allocator, 0);
    defer decoder.deinit();

    try std.testing.expectEqual(@as(usize, 0), (try feedOne(&decoder, arena, .sent, "{\"id\":5,\"method\":\"session/load\",\"params\":{\"sessionId\":\"old\",\"cwd\":\"/w\"}}")).len);
    const replayed = try feedOne(&decoder, arena, .received, "{\"method\":\"session/update\",\"params\":{\"sessionId\":\"old\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t\",\"title\":\"x\"}}}");
    try std.testing.expectEqual(@as(usize, 0), replayed.len);

    const loaded = try feedOne(&decoder, arena, .received, "{\"id\":5,\"result\":{}}");
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expect(loaded[0].sessionOpened.loaded);

    const live = try feedOne(&decoder, arena, .received, "{\"method\":\"session/update\",\"params\":{\"sessionId\":\"old\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t\",\"title\":\"x\"}}}");
    try std.testing.expectEqual(@as(usize, 1), live.len);
}

test "a failed prompt ends its turn with the error, and an unprompted turn ends without a duration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var decoder = try AnalyticsEventDecoder.init(std.testing.allocator, 0);
    defer decoder.deinit();

    _ = try feedOne(&decoder, arena, .sent, "{\"id\":1,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\",\"prompt\":[]}}");
    const failed = try feedOne(&decoder, arena, .received, "{\"id\":1,\"error\":{\"code\":-32603,\"message\":\"Not logged in\"}}");
    try std.testing.expectEqual(@as(?[]const u8, null), failed[0].turnEnded.stop_reason);
    try std.testing.expectEqualStrings("Not logged in", failed[0].turnEnded.error_message.?);
    try std.testing.expectEqual(AgentState.idle, decoder.stateOf("s").?);

    const background = try feedOne(&decoder, arena, .received, "{\"method\":\"_inferise/run_ended\",\"params\":{\"sessionId\":\"s\",\"stopReason\":\"end_turn\",\"_meta\":{\"inferise\":{\"usage\":{\"contextTokens\":22000,\"contextWindow\":200000}}}}}");
    try std.testing.expect(!background[0].turnEnded.prompted);
    try std.testing.expectEqual(@as(?u64, null), background[0].turnEnded.duration_ns);
    try std.testing.expectEqual(@as(i64, 22000), background[0].turnEnded.usage.object.get("contextTokens").?.integer);
}

test "an ask outranks a running turn, and a closed or abandoned session has exited" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var decoder = try AnalyticsEventDecoder.init(std.testing.allocator, 0);
    defer decoder.deinit();

    _ = try feedOne(&decoder, arena, .received, "{\"id\":1,\"result\":{\"sessionId\":\"unasked\"}}");
    _ = try feedOne(&decoder, arena, .sent, "{\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":\"/w\"}}");
    _ = try feedOne(&decoder, arena, .received, "{\"id\":1,\"result\":{\"sessionId\":\"a\"}}");
    _ = try feedOne(&decoder, arena, .sent, "{\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"a\",\"prompt\":[]}}");
    try std.testing.expectEqual(AgentState.busy, decoder.stateOf("a").?);
    // A reply nobody asked for opens nothing.
    try std.testing.expectEqual(@as(?AgentState, null), decoder.stateOf("unasked"));

    _ = try decoder.noteAsk(arena, "a", true);
    try std.testing.expectEqual(AgentState.waiting, decoder.stateOf("a").?);
    _ = try decoder.noteAsk(arena, "a", false);
    try std.testing.expectEqual(AgentState.busy, decoder.stateOf("a").?);

    _ = try feedOne(&decoder, arena, .sent, "{\"id\":3,\"method\":\"session/close\",\"params\":{\"sessionId\":\"a\"}}");
    const closed = try feedOne(&decoder, arena, .received, "{\"id\":3,\"result\":{}}");
    try std.testing.expectEqual(@as(usize, 2), closed.len);
    try std.testing.expectEqualStrings("a", closed[0].sessionClosed.session_id);
    try std.testing.expectEqual(AgentState.exited, closed[1].stateChanged.to);

    _ = try feedOne(&decoder, arena, .sent, "{\"id\":4,\"method\":\"session/new\",\"params\":{\"cwd\":\"/w\"}}");
    _ = try feedOne(&decoder, arena, .received, "{\"id\":4,\"result\":{\"sessionId\":\"b\"}}");
    const gone = try decoder.finish(arena);
    // Only `b` was still open.
    try std.testing.expectEqual(@as(usize, 2), gone.len);
    try std.testing.expectEqualStrings("b", gone[0].sessionClosed.session_id);
}

test "a frame that is not JSON-RPC yields nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var decoder = try AnalyticsEventDecoder.init(std.testing.allocator, 0);
    defer decoder.deinit();

    try std.testing.expectEqual(@as(usize, 0), (try feedOne(&decoder, arena, .received, "not json")).len);
    try std.testing.expectEqual(@as(usize, 0), (try feedOne(&decoder, arena, .received, "[1,2]")).len);
    try std.testing.expectEqual(@as(usize, 0), (try feedOne(&decoder, arena, .sent, "{\"id\":9,\"result\":{}}")).len);
}

test "a tool that reports its output only as content still has it read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var decoder = try AnalyticsEventDecoder.init(std.testing.allocator, 80);
    defer decoder.deinit();

    // As a native ACP agent sends it: no `rawOutput`, the text in `content`
    // blocks, and a diff that carries none.
    _ = try feedOne(&decoder, arena, .received, "{\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t\",\"title\":\"grep\"}}}");
    const ended = try feedOne(&decoder, arena, .received, "{\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t\",\"status\":\"completed\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"one\"}},{\"type\":\"diff\",\"path\":\"a\",\"newText\":\"x\"},{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"two\"}}]}}}");
    try std.testing.expectEqualStrings("one\ntwo", ended[0].toolEnded.output.?.string);

    // With neither, there is no output rather than an empty one.
    _ = try feedOne(&decoder, arena, .received, "{\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"u\",\"title\":\"x\"}}}");
    const bare = try feedOne(&decoder, arena, .received, "{\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"u\",\"status\":\"failed\"}}}");
    try std.testing.expectEqual(@as(?std.json.Value, null), bare[0].toolEnded.output);
}

test "a tool's name is ACP's own field, its server still from _meta.inferise" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var decoder = try AnalyticsEventDecoder.init(std.testing.allocator, 80);
    defer decoder.deinit();

    const started = try feedOne(&decoder, arena, .received, "{\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t\",\"title\":\"search zig\",\"name\":\"search\",\"_meta\":{\"inferise\":{\"tool\":{\"server\":\"docs\",\"agent\":\"claude\"}}}}}}");
    try std.testing.expectEqualStrings("search", started[0].toolStarted.name);
    try std.testing.expectEqualStrings("docs", started[0].toolStarted.server.?);

    // An agent from before ACP had the field still names it under `_meta.inferise.tool`.
    const older = try feedOne(&decoder, arena, .received, "{\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"u\",\"title\":\"ls\",\"_meta\":{\"inferise\":{\"tool\":{\"name\":\"Bash\",\"agent\":\"claude\"}}}}}}");
    try std.testing.expectEqualStrings("Bash", older[0].toolStarted.name);
}
