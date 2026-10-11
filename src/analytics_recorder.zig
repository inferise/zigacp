//! Analytics for every agent a client or relay runs.
//!
//! Each agent is registered with `spawned`, under the id its owner gave it
//! (`claude-1`), and gets back an `AgentObserver` bound to it; that observer
//! goes on the agent's `TapTransport`. From then on every frame lands here.
//!
//! The observer is called on whatever task read or wrote the frame — the draw
//! loop's, a prompt's — so it does only what cannot wait: copy the frame onto a
//! bounded queue under a brief lock. A full queue drops the frame and counts it
//! rather than waiting. Everything slow happens on the recorder's own task: each
//! subagent's `AcpEventDecoder` turns frames into events, each event becomes one
//! JSON line, and every sink gets it.
//!
//! Content — the prompt, the agent's reply, a tool's title, arguments and
//! output — is written only when capture is on, and each piece is cut to the
//! content limit. Everything else is metadata and always written.
//!
//! Records are JSON objects with camelCase keys: `ts` (milliseconds since the
//! epoch), `run`, `subagent`, `event`, then the event's own fields.

const std = @import("std");
const log = std.log.scoped(.acp_analytics_recorder);
const acp = @import("module.zig");

/// How analytics behave for one run.
pub const RecorderOptions = struct {
    /// Write prompts, replies and tool content as well as metadata.
    capture_content: bool = true,
    /// Bytes of each piece of content to keep.
    content_limit: usize = 80,
    /// Frames queued and not yet decoded before new ones are dropped.
    queue_limit: usize = 4096,
};

/// A registered agent: its id and the observer to put on its transport.
pub const RecorderWatch = struct {
    /// Unique within the run; owned by the recorder, valid until its `deinit`.
    id: []const u8,
    observer: acp.Analytics.Observer,
};

/// One registered agent and what is kept for it. Owns its strings.
const SubagentRecord = struct {
    const Self = @This();

    /// The analytics it reports to; borrowed.
    recorder: *AnalyticsRecorder,
    id: []u8,
    agent: []u8,
    version: ?[]u8 = null,
    account: ?[]u8 = null,
    parent: ?[]u8 = null,
    started: std.Io.Timestamp,
    /// Read and written only on the drain task.
    decoder: acp.Analytics.EventDecoder,
    /// Frames dropped since the last report. Guarded by the analytics mutex.
    dropped: u64 = 0,
    /// Set once its end has been reported. Drain task only.
    exited: bool = false,

    const observer_vtable = acp.Analytics.Observer.VTable{ .observe = AnalyticsRecorder.observe };

    /// Releases its strings and decoder.
    ///
    /// Parameters:
    /// - `self`: the record.
    /// - `allocator`: the one that allocated it.
    ///
    /// Return: nothing.
    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.decoder.deinit();
        allocator.free(self.id);
        allocator.free(self.agent);
        if (self.version) |text| allocator.free(text);
        if (self.account) |text| allocator.free(text);
        if (self.parent) |text| allocator.free(text);
    }

    /// Returns the record as a sink sees it.
    ///
    /// Parameters:
    /// - `self`: the record.
    ///
    /// Return: the view, borrowing `self`.
    fn view(self: *const Self) acp.Analytics.Subagent {
        return .{ .id = self.id, .agent = self.agent, .version = self.version, .account = self.account, .parent = self.parent, .started = self.started };
    }
};

/// Something for the drain task to do, in the order it happened.
const QueueItem = union(enum) {
    frame: struct {
        subagent: *SubagentRecord,
        direction: acp.Analytics.Direction,
        at: std.Io.Timestamp,
        /// The frame's bytes. Owned.
        bytes: []u8,
    },
    spawned: *SubagentRecord,
    exited: *SubagentRecord,
};

/// Collects every agent's frames and writes them to sinks as events.
pub const AnalyticsRecorder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    /// Names this run in every record. Owned.
    run_id: []u8,
    options: RecorderOptions,
    /// Where records go. Borrowed; the slice and every sink must outlive `self`.
    sinks: []const acp.Analytics.Sink,
    /// Guards `queue`, `queued_frames`, `closing`, `subagents` and each record's `dropped`.
    mutex: std.Io.Mutex = .init,
    /// Signalled when something is queued or `deinit` begins.
    arrival: std.Io.Condition = .init,
    queue: std.ArrayList(QueueItem) = .empty,
    /// Frames in `queue`; lifecycle items are never counted or dropped.
    queued_frames: usize = 0,
    closing: bool = false,
    /// Every agent registered this run, in order. Owned; stable addresses.
    subagents: std.ArrayList(*SubagentRecord) = .empty,
    /// The drain task. Exactly one releaser, which is `deinit`.
    group: std.Io.Group = .init,
    started: bool = false,

    /// Creates analytics for one run; nothing is drained until `start`.
    ///
    /// Parameters:
    /// - `allocator`: backs the queue, the records and every frame copy; must be safe across tasks and outlive `self`.
    /// - `io`: IO capability for the drain task and the timestamps.
    /// - `run_id`: names the run in every record; copied.
    /// - `options`: content capture, its limit and the queue's size.
    /// - `sinks`: where records go; borrowed, must outlive `self`.
    ///
    /// Return: the analytics, caller stores it at a stable address, calls `start`, then `deinit`; allocation failure propagates.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, run_id: []const u8, options: RecorderOptions, sinks: []const acp.Analytics.Sink) acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return Self{
            .allocator = allocator,
            .io = io,
            .run_id = try allocator.dupe(u8, run_id),
            .options = options,
            .sinks = sinks,
        };
    }

    /// Drains what is queued, reports every agent still running as ended, and releases everything.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        self.arrival.broadcast(self.io);
        self.mutex.unlock(self.io);

        // The task drains whatever is left before it returns; without one, the
        // queue is drained here, on the caller's task, so nothing queued is lost.
        if (self.started) self.group.await(self.io) catch |err| {
            log.warn("analytics task did not stop cleanly [{t}]", .{err});
        } else self.drain();

        for (self.subagents.items) |record| if (!record.exited) self.handleExited(record);
        for (self.subagents.items) |record| {
            record.deinit(self.allocator);
            self.allocator.destroy(record);
        }
        self.subagents.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.allocator.free(self.run_id);
    }

    /// Starts the task that decodes frames and feeds the sinks.
    ///
    /// Parameters:
    /// - `self`: the analytics; must not move from here on.
    ///
    /// Return: nothing; propagates the IO implementation's refusal to run a task alongside the caller.
    pub fn start(self: *Self) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // `concurrent`, never `async`: the loop only returns at `deinit`, so
        // running it inline would never hand control back.
        self.group.concurrent(self.io, drain, .{self}) catch return error.TransportFailed;
        self.started = true;
    }

    /// Registers an agent about to start and returns the observer for its transport.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    /// - `identity`: the agent's id, unique within the run as its owner named it, its label and its version; copied.
    /// - `account`: the account's name, or null for the agent's own home; copied.
    /// - `parent`: the spawning subagent's id, or null for one the user started; copied.
    ///
    /// Return: the agent's id and observer, valid until `deinit`; allocation failure propagates.
    pub fn spawned(self: *Self, identity: acp.Analytics.AgentIdentity, account: ?[]const u8, parent: ?[]const u8) acp.AcpError!RecorderWatch {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const record = try self.allocator.create(SubagentRecord);
        errdefer self.allocator.destroy(record);
        const owned_id = try self.allocator.dupe(u8, identity.id);
        errdefer self.allocator.free(owned_id);
        const owned_agent = try self.allocator.dupe(u8, identity.label);
        errdefer self.allocator.free(owned_agent);
        const owned_version = if (identity.version) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (owned_version) |text| self.allocator.free(text);
        const owned_account = if (account) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (owned_account) |text| self.allocator.free(text);
        const owned_parent = if (parent) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (owned_parent) |text| self.allocator.free(text);
        // Past the limit by the redactor's overrun, so a secret the cut would split is still seen whole.
        var decoder = try acp.Analytics.EventDecoder.init(self.allocator, if (self.options.capture_content) self.options.content_limit + acp.Analytics.ContentRedactor.window_overrun else 0);
        errdefer decoder.deinit();

        record.* = .{
            .recorder = self,
            .id = owned_id,
            .agent = owned_agent,
            .version = owned_version,
            .account = owned_account,
            .parent = owned_parent,
            .started = std.Io.Clock.real.now(self.io),
            .decoder = decoder,
        };
        try self.subagents.append(self.allocator, record);
        errdefer _ = self.subagents.pop();
        try self.queue.append(self.allocator, .{ .spawned = record });
        self.arrival.signal(self.io);

        return .{ .id = record.id, .observer = .{ .ptr = record, .vtable = &SubagentRecord.observer_vtable } };
    }

    /// Reports an agent ended; its open sessions are closed and its file finished.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    /// - `id`: the id `spawned` returned.
    ///
    /// Return: nothing; an unknown id is ignored, and a report that cannot be queued is left to `deinit`.
    pub fn exited(self: *Self, id: []const u8) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.subagents.items) |record| {
            if (!std.mem.eql(u8, record.id, id)) continue;
            self.queue.append(self.allocator, .{ .exited = record }) catch |err| {
                log.warn("{s}: end not queued, reported at shutdown [{t}]", .{ id, err });
                return;
            };
            self.arrival.signal(self.io);
            return;
        }
    }

    /// Builds a run id from the time: `20261003-142233-1a2b`, in UTC, with a random tail.
    ///
    /// Parameters:
    /// - `allocator`: owns the result.
    /// - `io`: IO capability, for the clock and the random tail.
    ///
    /// Return: the id, caller frees; allocation failure propagates.
    pub fn runId(allocator: std.mem.Allocator, io: std.Io) acp.AcpError![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const seconds: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toSeconds()));
        const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch.getDaySeconds();
        // SAFETY: filled by `io.random` before it is read.
        var tail: [2]u8 = undefined;
        io.random(&tail);
        return allocator.print("{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{s}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            &std.fmt.bytesToHex(tail, .lower),
        });
    }

    /// Queues one frame from a subagent's transport; called on whichever task moved it.
    ///
    /// Parameters:
    /// - `ctx`: the subagent's record.
    /// - `frame`: the frame; its bytes are copied.
    ///
    /// Return: nothing; a frame that cannot be queued is counted as dropped.
    fn observe(ctx: *anyopaque, frame: acp.Analytics.Frame) void {
        const record: *SubagentRecord = @ptrCast(@alignCast(ctx));
        const self = record.recorder;
        const copy = self.allocator.dupe(u8, frame.bytes) catch null;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const bytes = copy orelse {
            record.dropped += 1;
            return;
        };
        if (self.closing or self.queued_frames >= self.options.queue_limit) {
            record.dropped += 1;
            self.allocator.free(bytes);
            return;
        }
        self.queue.append(self.allocator, .{ .frame = .{ .subagent = record, .direction = frame.direction, .at = frame.at, .bytes = bytes } }) catch {
            record.dropped += 1;
            self.allocator.free(bytes);
            return;
        };
        self.queued_frames += 1;
        self.arrival.signal(self.io);
    }

    /// Takes queued work in batches and handles it, until `deinit` and the queue is empty.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    ///
    /// Return: nothing.
    fn drain(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.queue.items.len == 0 and !self.closing) self.arrival.waitUncancelable(self.io, &self.mutex);
            if (self.queue.items.len == 0) {
                self.mutex.unlock(self.io);
                break;
            }
            var batch = self.queue;
            self.queue = .empty;
            self.queued_frames = 0;
            self.mutex.unlock(self.io);

            for (batch.items) |item| self.handle(item);
            batch.deinit(self.allocator);
            self.reportDrops();
        }
        self.reportDrops();
    }

    /// Handles one queued item.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    /// - `item`: the item; a frame's bytes are freed here.
    ///
    /// Return: nothing.
    fn handle(self: *Self, item: QueueItem) void {
        switch (item) {
            .frame => |frame| {
                defer self.allocator.free(frame.bytes);
                if (frame.subagent.exited) return;
                var arena_state = std.heap.ArenaAllocator.init(self.allocator);
                defer arena_state.deinit();
                const arena = arena_state.allocator();
                const events = frame.subagent.decoder.feed(arena, .{ .source = frame.subagent.id, .direction = frame.direction, .sequence = 0, .at = frame.at, .bytes = frame.bytes }) catch |err| {
                    log.warn("{s}: frame not decoded [{t}]", .{ frame.subagent.id, err });
                    return;
                };
                for (events) |event| self.emitEvent(arena, frame.subagent, frame.at, event);
            },
            .spawned => |record| self.emitLifecycle(record, "subagent.spawned", record.started),
            .exited => |record| if (!record.exited) self.handleExited(record),
        }
    }

    /// Closes what an ended subagent left open and reports its end.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    /// - `record`: the subagent.
    ///
    /// Return: nothing.
    fn handleExited(self: *Self, record: *SubagentRecord) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const now = std.Io.Clock.real.now(self.io);
        const events = record.decoder.finish(arena) catch &.{};
        for (events) |event| self.emitEvent(arena, record, now, event);
        self.emitLifecycle(record, "subagent.exited", now);
        record.exited = true;
    }

    /// Reports every subagent's dropped frames since the last report.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    ///
    /// Return: nothing.
    fn reportDrops(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        const records = self.allocator.dupe(*SubagentRecord, self.subagents.items) catch {
            self.mutex.unlock(self.io);
            return;
        };
        defer self.allocator.free(records);
        const counts = self.allocator.alloc(u64, records.len) catch {
            self.mutex.unlock(self.io);
            return;
        };
        defer self.allocator.free(counts);
        for (records, counts) |record, *count| {
            count.* = record.dropped;
            record.dropped = 0;
        }
        self.mutex.unlock(self.io);

        for (records, counts) |record, count| {
            if (count == 0) continue;
            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();
            const line = self.render(arena_state.allocator(), record, "analytics.dropped", std.Io.Clock.real.now(self.io), .{ .count = count }) catch continue;
            self.deliver(record, "analytics.dropped", line);
        }
    }

    /// Renders and delivers a subagent's start or end.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    /// - `record`: the subagent.
    /// - `event`: `subagent.spawned` or `subagent.exited`.
    /// - `at`: when it happened.
    ///
    /// Return: nothing.
    fn emitLifecycle(self: *Self, record: *SubagentRecord, event: []const u8, at: std.Io.Timestamp) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const line = self.render(arena_state.allocator(), record, event, at, .{
            .agent = record.agent,
            .agentVersion = record.version,
            .account = record.account,
            .parent = record.parent,
        }) catch |err| {
            log.warn("{s}: {s} not rendered [{t}]", .{ record.id, event, err });
            return;
        };
        self.deliver(record, event, line);
    }

    /// Renders and delivers one decoded event.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    /// - `arena`: scratch for the line.
    /// - `record`: the subagent it belongs to.
    /// - `at`: when its frame crossed.
    /// - `event`: the event.
    ///
    /// Return: nothing.
    fn emitEvent(self: *Self, arena: std.mem.Allocator, record: *SubagentRecord, at: std.Io.Timestamp, event: acp.Analytics.Event) void {
        const name = eventName(event);
        const line = self.renderEvent(arena, record, at, event) catch |err| {
            log.warn("{s}: {s} not rendered [{t}]", .{ record.id, name, err });
            return;
        };
        self.deliver(record, name, line);
    }

    /// Renders one decoded event's record, with content cut or left out as the options say.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    /// - `arena`: owns the result.
    /// - `record`: the subagent.
    /// - `at`: when its frame crossed.
    /// - `event`: the event.
    ///
    /// Return: the JSON line; propagates allocation failure.
    fn renderEvent(self: *Self, arena: std.mem.Allocator, record: *SubagentRecord, at: std.Io.Timestamp, event: acp.Analytics.Event) ![]const u8 {
        const name = eventName(event);
        return switch (event) {
            .sessionOpened => |e| self.render(arena, record, name, at, .{ .session = e.session_id, .loaded = e.loaded }),
            .sessionClosed => |e| self.render(arena, record, name, at, .{ .session = e.session_id }),
            .turnStarted => |e| self.render(arena, record, name, at, .{ .session = e.session_id, .turn = e.turn, .prompt = try self.clip(arena, e.prompt) }),
            .turnEnded => |e| self.render(arena, record, name, at, .{
                .session = e.session_id,
                .turn = e.turn,
                .prompted = e.prompted,
                .stopReason = e.stop_reason,
                .@"error" = e.error_message,
                .durationMs = millis(e.duration_ns),
                .usage = e.usage,
                .reply = try self.clip(arena, e.reply),
            }),
            .toolStarted => |e| self.render(arena, record, name, at, .{
                .session = e.session_id,
                .toolCallId = e.tool_call_id,
                .name = e.name,
                .server = e.server,
                .kind = e.kind,
                .title = try self.clip(arena, e.title),
                .input = try self.clipValue(arena, e.input),
            }),
            .toolEnded => |e| self.render(arena, record, name, at, .{
                .session = e.session_id,
                .toolCallId = e.tool_call_id,
                .name = e.name,
                .server = e.server,
                .status = e.status,
                .durationMs = millis(e.duration_ns),
                .output = try self.clipValue(arena, e.output),
            }),
            .permissionAsked => |e| self.render(arena, record, name, at, .{ .session = e.session_id, .toolCallId = e.tool_call_id, .title = try self.clip(arena, e.title) }),
            .permissionAnswered => |e| self.render(arena, record, name, at, .{ .session = e.session_id, .toolCallId = e.tool_call_id, .outcome = e.outcome, .waitMs = millis(e.wait_ns) }),
            .stateChanged => |e| self.render(arena, record, name, at, .{ .session = e.session_id, .from = @tagName(e.from), .to = @tagName(e.to) }),
        };
    }

    /// Renders a record: the common header, then `fields` with null fields left out.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    /// - `arena`: owns the result.
    /// - `record`: the subagent.
    /// - `event`: the event's name.
    /// - `at`: when it happened.
    /// - `fields`: a struct whose fields are the event's own.
    ///
    /// Return: the JSON line; propagates allocation failure.
    fn render(self: *Self, arena: std.mem.Allocator, record: *SubagentRecord, event: []const u8, at: std.Io.Timestamp, fields: anytype) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
        try json.beginObject();
        try json.objectField("ts");
        try json.write(at.toMilliseconds());
        try json.objectField("run");
        try json.write(self.run_id);
        try json.objectField("subagent");
        try json.write(record.id);
        try json.objectField("event");
        try json.write(event);
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |name| {
            const value = @field(fields, name);
            const skip = @typeInfo(@TypeOf(value)) == .optional and value == null;
            if (!skip) {
                try json.objectField(name);
                try json.write(value);
            }
        }
        try json.endObject();
        return out.written();
    }

    /// Hands a record to every sink.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    /// - `record`: the subagent.
    /// - `event`: the event's name.
    /// - `line`: the record.
    ///
    /// Return: nothing.
    fn deliver(self: *Self, record: *SubagentRecord, event: []const u8, line: []const u8) void {
        for (self.sinks) |sink| sink.record(record.view(), event, line);
    }

    /// Masks secrets in a piece of text content and cuts it to the limit, or drops it when content is not captured.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    /// - `arena`: owns the redacted text.
    /// - `text`: the content, or null.
    ///
    /// Return: the redacted prefix; null when not captured or absent; propagates allocation failure.
    fn clip(self: *const Self, arena: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
        if (!self.options.capture_content) return null;
        const present = text orelse return null;
        // Redacted before it is cut, over a little more than is kept, so a
        // secret straddling the cut is replaced whole rather than half-kept.
        const window = acp.Analytics.EventDecoder.utf8Prefix(present, self.options.content_limit + acp.Analytics.ContentRedactor.window_overrun);
        const clean = try acp.Analytics.ContentRedactor.redactAlloc(arena, window);
        return acp.Analytics.EventDecoder.utf8Prefix(clean, self.options.content_limit);
    }

    /// Renders a JSON content value as text and cuts it to the limit, or drops it when content is not captured.
    ///
    /// Parameters:
    /// - `self`: the analytics.
    /// - `arena`: owns the rendering.
    /// - `value`: the content, or null.
    ///
    /// Return: the prefix of its JSON text; null when not captured or absent; propagates allocation failure.
    fn clipValue(self: *const Self, arena: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
        if (!self.options.capture_content) return null;
        const present = value orelse return null;
        // A string is content already; anything else is shown as its JSON.
        const text = if (present == .string) present.string else try std.json.Stringify.valueAlloc(arena, present, .{});
        return self.clip(arena, text);
    }

    /// Converts nanoseconds to whole milliseconds.
    ///
    /// Parameters:
    /// - `nanoseconds`: the duration, or null.
    ///
    /// Return: the milliseconds, or null.
    fn millis(nanoseconds: ?u64) ?u64 {
        const present = nanoseconds orelse return null;
        return present / std.time.ns_per_ms;
    }

    /// Names an event as records spell it.
    ///
    /// Parameters:
    /// - `event`: the event.
    ///
    /// Return: a static name, such as `turn.ended`.
    fn eventName(event: acp.Analytics.Event) []const u8 {
        return switch (event) {
            .sessionOpened => "session.opened",
            .sessionClosed => "session.closed",
            .turnStarted => "turn.started",
            .turnEnded => "turn.ended",
            .toolStarted => "tool.started",
            .toolEnded => "tool.ended",
            .permissionAsked => "permission.asked",
            .permissionAnswered => "permission.answered",
            .stateChanged => "state.changed",
        };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

/// Writes one frame through an observer as a tap would.
///
/// Parameters:
/// - `observer`: the observer.
/// - `direction`: which way it went.
/// - `ms`: when, in milliseconds.
/// - `bytes`: the frame.
///
/// Return: nothing.
fn cross(observer: acp.Analytics.Observer, direction: acp.Analytics.Direction, ms: i96, bytes: []const u8) void {
    observer.observe(.{ .source = "test", .direction = direction, .sequence = 0, .at = .{ .nanoseconds = ms * std.time.ns_per_ms }, .bytes = bytes });
}

/// A short session: opened, one turn whose prompt and reply are longer than the content limit, a tool.
fn crossSession(observer: acp.Analytics.Observer) void {
    cross(observer, .sent, 1000, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":\"/w\"}}");
    cross(observer, .received, 1010, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"s1\"}}");
    cross(observer, .sent, 2000, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s1\",\"prompt\":[{\"type\":\"text\",\"text\":\"Summarise the repository layout\"}]}}");
    cross(observer, .received, 2100, "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"title\":\"ls -la /w\",\"kind\":\"execute\",\"status\":\"completed\",\"rawInput\":{\"command\":\"ls -la /w\"}}}}");
    cross(observer, .received, 2200, "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"It has src and cli.\"}}}}");
    cross(observer, .received, 3000, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"stopReason\":\"end_turn\"}}");
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(AnalyticsRecorder);
}

test "every frame becomes events in order, bracketed by the subagent's start and end, with content cut to the limit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var memory = try acp.Analytics.MemorySink.init(allocator, io);
    defer memory.deinit();
    const sinks = [_]acp.Analytics.Sink{memory.sink()};
    var analytics = try AnalyticsRecorder.init(allocator, io, "run-1", .{ .content_limit = 9 }, &sinks);
    {
        defer analytics.deinit();
        try analytics.start();
        const watch = try analytics.spawned(.{ .id = "claude-1", .label = "claude" }, "work", null);
        try std.testing.expectEqualStrings("claude-1", watch.id);
        crossSession(watch.observer);
        analytics.exited(watch.id);
    }

    const expected = [_][]const u8{
        "subagent.spawned",
        "session.opened",
        "turn.started",
        "state.changed",
        "tool.started",
        "tool.ended",
        "turn.ended",
        "state.changed",
        "session.closed",
        "state.changed",
        "subagent.exited",
    };
    const events = memory.events.items;
    try std.testing.expectEqual(expected.len, events.len);
    for (expected, events) |name, got| try std.testing.expectEqualStrings(name, got);

    const lines = memory.lines.items;
    const spawned = try std.json.parseFromSlice(std.json.Value, allocator, lines[0], .{});
    defer spawned.deinit();
    try std.testing.expectEqualStrings("run-1", spawned.value.object.get("run").?.string);
    try std.testing.expectEqualStrings("claude-1", spawned.value.object.get("subagent").?.string);
    try std.testing.expectEqualStrings("work", spawned.value.object.get("account").?.string);
    // A null field is left out rather than written as null.
    try std.testing.expect(spawned.value.object.get("parent") == null);

    const started = try std.json.parseFromSlice(std.json.Value, allocator, lines[2], .{});
    defer started.deinit();
    try std.testing.expectEqualStrings("Summarise", started.value.object.get("prompt").?.string);
    try std.testing.expectEqual(@as(i64, 2000), started.value.object.get("ts").?.integer);

    const tool = try std.json.parseFromSlice(std.json.Value, allocator, lines[4], .{});
    defer tool.deinit();
    try std.testing.expectEqualStrings("{\"command", tool.value.object.get("input").?.string);

    const ended = try std.json.parseFromSlice(std.json.Value, allocator, lines[6], .{});
    defer ended.deinit();
    try std.testing.expectEqualStrings("It has sr", ended.value.object.get("reply").?.string);
    try std.testing.expectEqual(@as(i64, 1000), ended.value.object.get("durationMs").?.integer);
    try std.testing.expectEqualStrings("end_turn", ended.value.object.get("stopReason").?.string);
}

test "a secret in captured content is redacted, even one the cut would split" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var memory = try acp.Analytics.MemorySink.init(allocator, io);
    defer memory.deinit();
    const sinks = [_]acp.Analytics.Sink{memory.sink()};
    // The key starts inside the limit and ends past it.
    var analytics = try AnalyticsRecorder.init(allocator, io, "run-3", .{ .content_limit = 20 }, &sinks);
    {
        defer analytics.deinit();
        try analytics.start();
        const watch = try analytics.spawned(.{ .id = "claude-1", .label = "claude" }, null, null);
        cross(watch.observer, .sent, 1000, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":\"/w\"}}");
        cross(watch.observer, .received, 1010, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"s1\"}}");
        cross(watch.observer, .sent, 2000, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s1\",\"prompt\":[{\"type\":\"text\",\"text\":\"Use key sk-ant-api03-abcdefghijklmnop please\"}]}}");
        cross(watch.observer, .received, 2200, "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Set PASSWORD=hunter2222 now\"}}}}");
        cross(watch.observer, .received, 3000, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"stopReason\":\"end_turn\"}}");
        analytics.exited(watch.id);
    }

    var prompt: ?[]const u8 = null;
    var reply: ?[]const u8 = null;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    for (memory.events.items, memory.lines.items) |name, line| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), line, .{});
        if (std.mem.eql(u8, name, "turn.started")) prompt = parsed.object.get("prompt").?.string;
        if (std.mem.eql(u8, name, "turn.ended")) reply = parsed.object.get("reply").?.string;
    }
    try std.testing.expectEqualStrings("Use key [redacted] p", prompt.?);
    try std.testing.expectEqualStrings("Set PASSWORD=[redact", reply.?);
}

test "with content capture off, records carry metadata only" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var memory = try acp.Analytics.MemorySink.init(allocator, io);
    defer memory.deinit();
    const sinks = [_]acp.Analytics.Sink{memory.sink()};
    var analytics = try AnalyticsRecorder.init(allocator, io, "run-2", .{ .capture_content = false }, &sinks);
    {
        defer analytics.deinit();
        const watch = try analytics.spawned(.{ .id = "codex-1", .label = "codex" }, null, null);
        crossSession(watch.observer);
    }

    for (memory.lines.items) |line| {
        try std.testing.expect(std.mem.find(u8, line, "\"prompt\"") == null);
        try std.testing.expect(std.mem.find(u8, line, "\"reply\"") == null);
        try std.testing.expect(std.mem.find(u8, line, "\"input\"") == null);
        try std.testing.expect(std.mem.find(u8, line, "\"title\"") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), memory.count("turn.ended"));
    try std.testing.expectEqual(@as(usize, 1), memory.count("tool.ended"));
}

test "a full queue drops frames without waiting, and the drops are reported" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var memory = try acp.Analytics.MemorySink.init(allocator, io);
    defer memory.deinit();
    const sinks = [_]acp.Analytics.Sink{memory.sink()};
    var analytics = try AnalyticsRecorder.init(allocator, io, "run-3", .{ .queue_limit = 2 }, &sinks);
    {
        defer analytics.deinit();
        // Not started: nothing drains, so the queue fills. Every call returns at
        // once all the same — the observer never waits for room.
        const watch = try analytics.spawned(.{ .id = "afm-1", .label = "afm" }, null, null);
        for (0..5) |_| cross(watch.observer, .received, 0, "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{}}");
    }

    try std.testing.expectEqual(@as(usize, 1), memory.count("analytics.dropped"));
    for (memory.events.items, memory.lines.items) |event, line| {
        if (!std.mem.eql(u8, event, "analytics.dropped")) continue;
        try std.testing.expect(std.mem.find(u8, line, "\"count\":3") != null);
    }
}

test "a subagent keeps the id its owner gave it, and a run id reads as a time" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var analytics = try AnalyticsRecorder.init(allocator, io, "run-4", .{}, &.{});
    defer analytics.deinit();
    try std.testing.expectEqualStrings("claude-1", (try analytics.spawned(.{ .id = "claude-1", .label = "claude" }, null, null)).id);
    try std.testing.expectEqualStrings("claude-7", (try analytics.spawned(.{ .id = "claude-7", .label = "claude" }, "other", null)).id);

    const run = try AnalyticsRecorder.runId(allocator, io);
    defer allocator.free(run);
    // `YYYYMMDD-HHMMSS-xxxx`.
    try std.testing.expectEqual(@as(usize, 20), run.len);
    try std.testing.expectEqual(@as(u8, '-'), run[8]);
    try std.testing.expectEqual(@as(u8, '-'), run[15]);
}
