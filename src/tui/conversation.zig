//! A conversation, folded from the Agent Client Protocol's own updates.
//!
//! An ACP agent reports a turn as `session/update`s: message and thought text
//! in chunks, a tool call when it starts and updates as it runs, a plan. A
//! client that keeps them — the person's prompts included, as ACP's own
//! `user_message_chunk` — hands each one to `apply` here, in order, and gets
//! back who said what: consecutive chunks of one speaker joined, each tool call
//! one item whatever its updates said. `ConversationView` draws it.
//!
//! The rest of a session's updates — modes, settings, commands, usage — are not
//! conversation, and are left to the client.

const std = @import("std");
const log = std.log.scoped(.acp_tui_conversation);
const mod = @import("module.zig");

/// Who said a message.
pub const ConversationRole = enum {
    /// The person, through the client.
    person,
    /// The agent.
    agent,
};

/// Where a plan step stands.
pub const PlanStep = struct {
    const Self = @This();

    content: []const u8,
    status: @FieldType(mod.acp.PlanEntry, "status"),
};

/// One tool call, as its updates have described it so far.
pub const ToolItem = struct {
    const Self = @This();

    /// The agent's id for it; owned by the conversation.
    id: []const u8,
    /// What it does, for a person.
    title: []const u8,
    status: mod.acp.ToolCallStatus = .pending,
    /// Its arguments, as compact JSON; empty when not reported.
    input: []const u8 = "",
    /// What it returned: its text content, else its raw output as JSON; empty until reported.
    output: []const u8 = "",
    /// The files it changed, by path.
    diffs: []const []const u8 = &.{},
};

/// One item of a conversation.
pub const ConversationItem = union(enum) {
    /// A message, its chunks joined.
    message: struct { role: ConversationRole, text: []const u8 },
    /// The agent's reasoning, its chunks joined.
    thought: []const u8,
    tool: ToolItem,
    /// The agent's latest plan.
    plan: []const PlanStep,
    /// A line the client adds between the agent's updates: a turn's cost, why it failed.
    note: []const u8,
};

/// A conversation, item by item.
pub const Conversation = struct {
    const Self = @This();

    /// Most bytes of text kept; past it the oldest items are dropped.
    pub const max_bytes = 4 * 1024 * 1024;

    allocator: std.mem.Allocator,
    /// Owns every string; rebuilt from the items kept when the bound is passed.
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(ConversationItem) = .empty,
    /// Text bytes taken, roughly; checked against `max_bytes`.
    bytes: usize = 0,

    /// Starts an empty conversation.
    ///
    /// Parameters:
    /// - `allocator`: backs the items and their text.
    ///
    /// Return: the conversation; never fails.
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .arena = .init(allocator) };
    }

    /// Frees everything.
    ///
    /// Parameters:
    /// - `self`: the conversation.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        self.items.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Forgets every item: the agent is about to replay its past.
    ///
    /// Parameters:
    /// - `self`: the conversation.
    ///
    /// Return: nothing.
    pub fn clear(self: *Self) void {
        self.items.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.bytes = 0;
    }

    /// Folds one update in; one that is not conversation changes nothing.
    ///
    /// Parameters:
    /// - `self`: the conversation.
    /// - `update`: the update; copied.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn apply(self: *Self, update: mod.acp.Agent.SessionUpdate) !void {
        switch (update) {
            .userMessageChunk => |chunk| try self.addText(.{ .person = {} }, chunk.content),
            .agentMessageChunk => |chunk| try self.addText(.{ .agent = {} }, chunk.content),
            .agentThoughtChunk => |chunk| try self.addText(.thought, chunk.content),
            .toolCall => |call| {
                const index = try self.toolIndex(call.toolCallId.value, call.title);
                var tool = &self.items.items[index].tool;
                tool.title = try self.copy(call.title);
                if (call.status) |status| tool.status = status;
                try self.takeTool(tool, call.rawInput, call.rawOutput, call.content);
            },
            .toolCallUpdate => |update_| {
                const index = try self.toolIndex(update_.toolCallId.value, update_.title orelse "tool");
                var tool = &self.items.items[index].tool;
                if (update_.title) |title| tool.title = try self.copy(title);
                if (update_.status) |status| tool.status = status;
                try self.takeTool(tool, update_.rawInput, update_.rawOutput, update_.content);
            },
            .plan => |wrapper| {
                const steps = try self.arena.allocator().alloc(PlanStep, wrapper.plan.entries.len);
                for (wrapper.plan.entries, steps) |entry, *step| step.* = .{ .content = try self.copy(entry.content), .status = entry.status };
                // The latest plan replaces the one before it, in place.
                for (self.items.items) |*item| if (item.* == .plan) {
                    item.* = .{ .plan = steps };
                    return;
                };
                try self.items.append(self.allocator, .{ .plan = steps });
            },
            else => {},
        }
        if (self.bytes > max_bytes) self.trim();
    }

    /// Adds one of the client's own lines after what is there.
    ///
    /// Parameters:
    /// - `self`: the conversation.
    /// - `text`: the line; copied.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn addNote(self: *Self, text: []const u8) !void {
        try self.items.append(self.allocator, .{ .note = try self.copy(text) });
        if (self.bytes > max_bytes) self.trim();
    }

    /// Folds in one update given as ACP JSON (`{"sessionUpdate":…}`).
    ///
    /// Parameters:
    /// - `self`: the conversation.
    /// - `json`: the update's JSON; borrowed.
    ///
    /// Return: nothing; `error.InvalidUpdate` for JSON that is not one; propagates allocation failure.
    pub fn applyJson(self: *Self, json: []const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const update = std.json.parseFromSliceLeaky(mod.acp.Agent.SessionUpdate, scratch.allocator(), json, .{ .ignore_unknown_fields = true }) catch |err| {
            log.debug("not an update [{t}]", .{err});
            return error.InvalidUpdate;
        };
        try self.apply(update);
    }

    /// Which part of a message a chunk extends.
    const Speaker = union(enum) { person, agent, thought };

    /// Adds a chunk's text to the last item when the same speaker said it, else starts one.
    ///
    /// Parameters:
    /// - `self`: the conversation.
    /// - `speaker`: who said it.
    /// - `content`: the chunk; anything but text is noted by its kind.
    ///
    /// Return: nothing; propagates allocation failure.
    fn addText(self: *Self, speaker: Speaker, content: mod.acp.ContentBlock) !void {
        const text: []const u8 = switch (content) {
            .text => |block| block.text,
            .image => "[image]",
            else => "[attachment]",
        };
        const arena = self.arena.allocator();
        self.bytes += text.len;
        if (self.items.items.len > 0) {
            const last = &self.items.items[self.items.items.len - 1];
            switch (speaker) {
                .thought => if (last.* == .thought) {
                    last.* = .{ .thought = try std.mem.concat(arena, u8, &.{ last.thought, text }) };
                    return;
                },
                .person, .agent => if (last.* == .message and last.message.role == roleOf(speaker)) {
                    last.message.text = try std.mem.concat(arena, u8, &.{ last.message.text, text });
                    return;
                },
            }
        }
        const owned = try arena.dupe(u8, text);
        try self.items.append(self.allocator, switch (speaker) {
            .thought => .{ .thought = owned },
            .person, .agent => .{ .message = .{ .role = roleOf(speaker), .text = owned } },
        });
    }

    /// The role a speaker's message has.
    ///
    /// Parameters:
    /// - `speaker`: the person or the agent.
    ///
    /// Return: the role.
    fn roleOf(speaker: Speaker) ConversationRole {
        return if (speaker == .person) .person else .agent;
    }

    /// Finds a tool call's item by id, starting one at the end when it is new.
    ///
    /// Parameters:
    /// - `self`: the conversation.
    /// - `id`: the agent's id for the call.
    /// - `title`: its title, for a new one.
    ///
    /// Return: the item's index; propagates allocation failure.
    fn toolIndex(self: *Self, id: []const u8, title: []const u8) !usize {
        var index = self.items.items.len;
        while (index > 0) {
            index -= 1;
            const item = self.items.items[index];
            if (item == .tool and std.mem.eql(u8, item.tool.id, id)) return index;
        }
        try self.items.append(self.allocator, .{ .tool = .{ .id = try self.copy(id), .title = try self.copy(title) } });
        return self.items.items.len - 1;
    }

    /// Takes what a tool call's update reports: its input, output and changed files.
    ///
    /// Parameters:
    /// - `self`: the conversation.
    /// - `tool`: the item.
    /// - `raw_input`: its arguments, or null.
    /// - `raw_output`: what it returned, or null.
    /// - `content`: its content blocks, or null.
    ///
    /// Return: nothing; propagates allocation failure.
    fn takeTool(self: *Self, tool: *ToolItem, raw_input: ?mod.acp.RawValue, raw_output: ?mod.acp.RawValue, content: ?[]const mod.acp.ToolCallContent) !void {
        const arena = self.arena.allocator();
        if (raw_input) |input| tool.input = try self.compact(input.value);
        var text: std.ArrayList(u8) = .empty;
        var diffs: std.ArrayList([]const u8) = .empty;
        if (content) |blocks| for (blocks) |block| switch (block) {
            .content => |entry| switch (entry.content) {
                .text => |part| try text.appendSlice(arena, part.text),
                else => {},
            },
            .diff => |diff| try diffs.append(arena, try arena.dupe(u8, diff.path)),
        };
        if (text.items.len > 0) {
            tool.output = text.items;
            self.bytes += text.items.len;
        } else if (raw_output) |output| {
            tool.output = if (output.value == .string) try self.copy(output.value.string) else try self.compact(output.value);
        }
        if (diffs.items.len > 0) tool.diffs = diffs.items;
    }

    /// A JSON value as compact text, kept.
    ///
    /// Parameters:
    /// - `self`: the conversation.
    /// - `value`: the value.
    ///
    /// Return: the text; propagates allocation failure.
    fn compact(self: *Self, value: std.json.Value) ![]const u8 {
        const text = try std.json.Stringify.valueAlloc(self.arena.allocator(), value, .{});
        self.bytes += text.len;
        return text;
    }

    /// Copies a string into the arena, counting it.
    ///
    /// Parameters:
    /// - `self`: the conversation.
    /// - `text`: the string.
    ///
    /// Return: the copy; propagates allocation failure.
    fn copy(self: *Self, text: []const u8) ![]const u8 {
        self.bytes += text.len;
        return self.arena.allocator().dupe(u8, text);
    }

    /// Drops the oldest half of the items once the bound is passed.
    ///
    /// The arena is not compacted: a conversation that long is rare, and the
    /// items kept still point into it. Logged so a bound that bites is seen.
    ///
    /// Parameters:
    /// - `self`: the conversation.
    ///
    /// Return: nothing.
    fn trim(self: *Self) void {
        const drop = self.items.items.len / 2;
        if (drop == 0) return;
        std.mem.copyForwards(ConversationItem, self.items.items[0 .. self.items.items.len - drop], self.items.items[drop..]);
        self.items.shrinkRetainingCapacity(self.items.items.len - drop);
        self.bytes /= 2;
        log.info("conversation past {d} bytes; its oldest {d} items dropped", .{ max_bytes, drop });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Conversation);
}

test "chunks of one speaker join, a tool call is one item whatever its updates say, and the plan is replaced" {
    var conversation = Conversation.init(std.testing.allocator);
    defer conversation.deinit();
    const updates = [_][]const u8{
        \\{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"list the files"}}
        ,
        \\{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Looking"}}
        ,
        \\{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":" around."}}
        ,
        \\{"sessionUpdate":"tool_call","toolCallId":"t1","title":"ls -la","kind":"execute","status":"pending","rawInput":{"command":"ls -la"}}
        ,
        \\{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"a.txt"}}]}
        ,
        \\{"sessionUpdate":"plan","entries":[{"content":"look","status":"completed","priority":"medium"}]}
        ,
        \\{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"One "}}
        ,
        \\{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"file."}}
        ,
        \\{"sessionUpdate":"plan","entries":[{"content":"look","status":"completed","priority":"medium"},{"content":"answer","status":"in_progress","priority":"medium"}]}
        ,
        \\{"sessionUpdate":"usage_update","used":10,"size":100}
    };
    for (updates) |update| try conversation.applyJson(update);
    try conversation.addNote("1.20s wall");

    const items = conversation.items.items;
    try std.testing.expectEqual(@as(usize, 6), items.len);
    try std.testing.expectEqualStrings("1.20s wall", items[5].note);
    try std.testing.expectEqual(ConversationRole.person, items[0].message.role);
    try std.testing.expectEqualStrings("Looking around.", items[1].thought);
    try std.testing.expectEqualStrings("ls -la", items[2].tool.title);
    try std.testing.expectEqual(mod.acp.ToolCallStatus.completed, items[2].tool.status);
    try std.testing.expectEqualStrings("{\"command\":\"ls -la\"}", items[2].tool.input);
    try std.testing.expectEqualStrings("a.txt", items[2].tool.output);
    // The second plan took the first's place.
    try std.testing.expectEqual(@as(usize, 2), items[3].plan.len);
    try std.testing.expectEqualStrings("One file.", items[4].message.text);

    try std.testing.expectError(error.InvalidUpdate, conversation.applyJson("{\"nope\":1}"));
    conversation.clear();
    try std.testing.expectEqual(@as(usize, 0), conversation.items.items.len);
}
