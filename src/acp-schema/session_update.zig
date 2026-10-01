//! One streamed update an agent emits during a prompt, tagged on the wire by `sessionUpdate`.
//!
//! The Zig variants are camelCase; the wire tags stay ACP's snake_case strings,
//! which `jsonStringify` / `jsonParseFromValue` spell out explicitly.

const std = @import("std");
const log = std.log.scoped(.acp_schema_session_update);
const mod = @import("module.zig");

/// The payload of a message or thought chunk.
pub const ContentChunk = struct {
    const Self = @This();

    content: mod.ContentBlock,
};

/// The payload of a `plan` update.
pub const PlanWrapper = struct {
    const Self = @This();

    plan: mod.Plan,
};

/// The `available_commands_update` payload: every command the agent now accepts.
pub const AvailableCommandsUpdate = struct {
    const Self = @This();

    available_commands: []const mod.AvailableCommand,

    /// Writes the struct under its camelCase wire keys.
    ///
    /// Parameters:
    /// - `self`: the struct.
    /// - `jw`: the JSON writer.
    ///
    /// Return: nothing; propagates the writer's failure.
    pub fn jsonStringify(self: *const Self, jw: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try mod.WireCase.stringify(Self, self, jw);
    }

    /// Parses the struct from a token stream keyed by wire names.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the token stream.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the struct; propagates a parse failure.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return mod.WireCase.parse(Self, allocator, source, options);
    }

    /// Parses the struct from a JSON value keyed by wire names.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the JSON value.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the struct; propagates a parse failure.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return mod.WireCase.parseFromValue(Self, allocator, source, options);
    }
};

/// The `current_mode_update` payload: the mode the session has moved to.
pub const CurrentModeUpdate = struct {
    const Self = @This();

    current_mode_id: []const u8,

    /// Writes the struct under its camelCase wire keys.
    ///
    /// Parameters:
    /// - `self`: the struct.
    /// - `jw`: the JSON writer.
    ///
    /// Return: nothing; propagates the writer's failure.
    pub fn jsonStringify(self: *const Self, jw: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try mod.WireCase.stringify(Self, self, jw);
    }

    /// Parses the struct from a token stream keyed by wire names.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the token stream.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the struct; propagates a parse failure.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return mod.WireCase.parse(Self, allocator, source, options);
    }

    /// Parses the struct from a JSON value keyed by wire names.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the JSON value.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the struct; propagates a parse failure.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return mod.WireCase.parseFromValue(Self, allocator, source, options);
    }
};

/// The `config_option_update` payload: every config option, after one changed.
pub const ConfigOptionUpdate = struct {
    const Self = @This();

    config_options: []const mod.SessionConfigOption,

    /// Writes the struct under its camelCase wire keys.
    ///
    /// Parameters:
    /// - `self`: the struct.
    /// - `jw`: the JSON writer.
    ///
    /// Return: nothing; propagates the writer's failure.
    pub fn jsonStringify(self: *const Self, jw: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try mod.WireCase.stringify(Self, self, jw);
    }

    /// Parses the struct from a token stream keyed by wire names.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the token stream.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the struct; propagates a parse failure.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return mod.WireCase.parse(Self, allocator, source, options);
    }

    /// Parses the struct from a JSON value keyed by wire names.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the JSON value.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the struct; propagates a parse failure.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return mod.WireCase.parseFromValue(Self, allocator, source, options);
    }
};

/// The `session_info_update` payload: session metadata that changed.
pub const SessionInfoUpdate = struct {
    const Self = @This();

    title: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,

    /// Writes the struct under its camelCase wire keys.
    ///
    /// Parameters:
    /// - `self`: the struct.
    /// - `jw`: the JSON writer.
    ///
    /// Return: nothing; propagates the writer's failure.
    pub fn jsonStringify(self: *const Self, jw: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try mod.WireCase.stringify(Self, self, jw);
    }

    /// Parses the struct from a token stream keyed by wire names.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the token stream.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the struct; propagates a parse failure.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return mod.WireCase.parse(Self, allocator, source, options);
    }

    /// Parses the struct from a JSON value keyed by wire names.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the JSON value.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the struct; propagates a parse failure.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return mod.WireCase.parseFromValue(Self, allocator, source, options);
    }
};

/// One streamed update emitted by the agent during a prompt.
pub const SessionUpdate = union(enum) {
    const Self = @This();

    userMessageChunk: ContentChunk,
    agentMessageChunk: ContentChunk,
    agentThoughtChunk: ContentChunk,
    toolCall: mod.ToolCall,
    toolCallUpdate: mod.ToolCallUpdate,
    plan: PlanWrapper,
    availableCommandsUpdate: AvailableCommandsUpdate,
    currentModeUpdate: CurrentModeUpdate,
    configOptionUpdate: ConfigOptionUpdate,
    sessionInfoUpdate: SessionInfoUpdate,
    /// Unstable, behind `-Dunstable_session_usage`; uninhabited without it, so the tag parses as `unknown`.
    usageUpdate: if (mod.usage_update.enabled) mod.usage_update.UsageUpdate else noreturn,
    /// Forward-compat: unknown variants from peers running newer revisions.
    unknown: mod.RawValue,

    /// The variants whose payload fields sit beside the tag, with their wire tags.
    const flat_variants = .{
        .{ "tool_call", "toolCall" },
        .{ "tool_call_update", "toolCallUpdate" },
        .{ "available_commands_update", "availableCommandsUpdate" },
        .{ "current_mode_update", "currentModeUpdate" },
        .{ "config_option_update", "configOptionUpdate" },
        .{ "session_info_update", "sessionInfoUpdate" },
        .{ "usage_update", "usageUpdate" },
    };

    /// Writes a chunk variant: its tag, then its content block.
    ///
    /// Parameters:
    /// - `jw`: the JSON writer.
    /// - `tag`: the wire tag.
    /// - `content`: the chunk's content.
    ///
    /// Return: nothing; propagates the writer's failure.
    fn writeChunk(jw: anytype, comptime tag: []const u8, content: *const mod.ContentBlock) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try jw.beginObject();
        try jw.objectField("sessionUpdate");
        try jw.write(tag);
        try jw.objectField("content");
        try jw.write(content.*);
        try jw.endObject();
    }

    /// Writes a flat variant: its tag, then every payload field under its wire key, skipping null optionals.
    ///
    /// Parameters:
    /// - `jw`: the JSON writer.
    /// - `tag`: the wire tag.
    /// - `payload`: the variant's payload.
    ///
    /// Return: nothing; propagates the writer's failure.
    fn writeFlat(jw: anytype, comptime tag: []const u8, payload: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try jw.beginObject();
        try jw.objectField("sessionUpdate");
        try jw.write(tag);
        const T = @TypeOf(payload.*);
        inline for (@typeInfo(T).@"struct".fields) |field| {
            const v = @field(payload.*, field.name);
            const skip = @typeInfo(field.type) == .optional and v == null;
            if (!skip) {
                try jw.objectField(comptime mod.WireCase.key(field.name));
                try jw.write(v);
            }
        }
        try jw.endObject();
    }

    /// Writes a plan variant: its tag, then the plan's entries.
    ///
    /// Parameters:
    /// - `jw`: the JSON writer.
    /// - `plan`: the plan.
    ///
    /// Return: nothing; propagates the writer's failure.
    fn writePlan(jw: anytype, plan: *const mod.Plan) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try jw.beginObject();
        try jw.objectField("sessionUpdate");
        try jw.write("plan");
        try jw.objectField("entries");
        try jw.write(plan.entries);
        try jw.endObject();
    }

    /// Copies an update object without its `sessionUpdate` tag, leaving only the payload's fields.
    ///
    /// Parameters:
    /// - `allocator`: owns the copy.
    /// - `source`: the update object.
    ///
    /// Return: the payload object; propagates allocation failure.
    fn stripTag(allocator: std.mem.Allocator, source: std.json.Value) !std.json.Value {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var copy: std.json.ObjectMap = .empty;
        try copy.ensureTotalCapacity(allocator, source.object.count());
        var it = source.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "sessionUpdate")) continue;
            copy.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        }
        return .{ .object = copy };
    }

    /// Looks up a flat variant's wire tag.
    ///
    /// Comptime-only, so it cannot trace its entry the way runtime functions do.
    ///
    /// Parameters:
    /// - `variant`: the Zig variant name.
    ///
    /// Return: the wire tag; a compile error for a variant that isn't flat.
    fn wireTag(comptime variant: []const u8) []const u8 {
        inline for (flat_variants) |entry| {
            if (comptime std.mem.eql(u8, entry[1], variant)) return entry[0];
        }
        @compileError("not a flat SessionUpdate variant: " ++ variant);
    }

    /// Writes the update in its wire shape, tag first.
    ///
    /// Parameters:
    /// - `self`: the update.
    /// - `jw`: the JSON writer.
    ///
    /// Return: nothing; propagates the writer's failure.
    pub fn jsonStringify(self: *const Self, jw: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        switch (self.*) {
            .userMessageChunk => |*c| try writeChunk(jw, "user_message_chunk", &c.content),
            .agentMessageChunk => |*c| try writeChunk(jw, "agent_message_chunk", &c.content),
            .agentThoughtChunk => |*c| try writeChunk(jw, "agent_thought_chunk", &c.content),
            .plan => |*p| try writePlan(jw, &p.plan),
            .unknown => |raw| try jw.write(raw),
            inline else => |*payload, variant| {
                if (comptime @TypeOf(payload.*) == noreturn) unreachable;
                const tag = comptime wireTag(@tagName(variant));
                try writeFlat(jw, tag, payload);
            },
        }
    }

    /// Parses one update from a token stream.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the token stream.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the update; propagates a parse failure.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    /// Parses one update from a JSON value, routing on `sessionUpdate`.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the JSON value.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the update, `unknown` for a tag this revision doesn't model; `error.MissingField` without a tag.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (source != .object) return error.UnexpectedToken;
        const tag_v = source.object.get("sessionUpdate") orelse return error.MissingField;
        if (tag_v != .string) return error.UnexpectedToken;
        const tag = tag_v.string;

        if (std.mem.eql(u8, tag, "user_message_chunk") or
            std.mem.eql(u8, tag, "agent_message_chunk") or
            std.mem.eql(u8, tag, "agent_thought_chunk"))
        {
            const content_v = source.object.get("content") orelse return error.MissingField;
            const cb = try std.json.parseFromValueLeaky(mod.ContentBlock, allocator, content_v, options);
            const chunk: ContentChunk = .{ .content = cb };
            if (std.mem.eql(u8, tag, "user_message_chunk")) return .{ .userMessageChunk = chunk };
            if (std.mem.eql(u8, tag, "agent_message_chunk")) return .{ .agentMessageChunk = chunk };
            return .{ .agentThoughtChunk = chunk };
        }

        if (std.mem.eql(u8, tag, "plan")) {
            const entries_v = source.object.get("entries") orelse return error.MissingField;
            var entries: std.json.ObjectMap = .empty;
            try entries.ensureTotalCapacity(allocator, 1);
            entries.putAssumeCapacity("entries", entries_v);
            const plan = try std.json.parseFromValueLeaky(mod.Plan, allocator, .{ .object = entries }, options);
            return .{ .plan = .{ .plan = plan } };
        }

        // The flat variants: every field but the tag belongs to the payload.
        inline for (flat_variants) |variant| {
            if (comptime @FieldType(Self, variant[1]) == noreturn) continue;
            if (std.mem.eql(u8, tag, variant[0])) {
                const Payload = @FieldType(Self, variant[1]);
                const inner = try stripTag(allocator, source);
                const payload = try std.json.parseFromValueLeaky(Payload, allocator, inner, options);
                return @unionInit(Self, variant[1], payload);
            }
        }

        return .{ .unknown = .{ .value = source } };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "a message chunk round-trips under its wire tag" {
    const src =
        \\{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}
    ;
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.agentMessageChunk.content == .text);

    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sessionUpdate\":\"agent_message_chunk\"") != null);
}

test "user and thought chunks pick their own variants" {
    const user = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, "{\"sessionUpdate\":\"user_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"q?\"}}", .{});
    defer user.deinit();
    try std.testing.expect(user.value == .userMessageChunk);

    const thought = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"…\"}}", .{});
    defer thought.deinit();
    try std.testing.expect(thought.value == .agentThoughtChunk);
}

test "a tool call inlines its fields" {
    const src =
        \\{"sessionUpdate":"tool_call","toolCallId":"c1","title":"reading","kind":"read","status":"pending"}
    ;
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("c1", parsed.value.toolCall.toolCallId.value);

    const update = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"c1\",\"status\":\"completed\"}", .{});
    defer update.deinit();
    try std.testing.expect(update.value == .toolCallUpdate);
}

test "a plan keeps its entries" {
    const src =
        \\{"sessionUpdate":"plan","entries":[{"content":"step","status":"pending","priority":"medium"}]}
    ;
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.plan.plan.entries.len);
}

test "an unknown tag survives" {
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, "{\"sessionUpdate\":\"future_kind\",\"x\":1}", .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .unknown);
}

test "the stable v1 status variants decode" {
    const cases = [_]struct { src: []const u8, tag: std.meta.Tag(SessionUpdate) }{
        .{ .src = "{\"sessionUpdate\":\"current_mode_update\",\"currentModeId\":\"plan\"}", .tag = .currentModeUpdate },
        .{ .src = "{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":[{\"name\":\"compact\",\"description\":\"Summarise the context\"}]}", .tag = .availableCommandsUpdate },
        .{ .src = "{\"sessionUpdate\":\"session_info_update\",\"title\":\"Fix the build\",\"updatedAt\":\"2026-10-01T00:00:00Z\"}", .tag = .sessionInfoUpdate },
        .{ .src = "{\"sessionUpdate\":\"config_option_update\",\"configOptions\":[]}", .tag = .configOptionUpdate },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, case.src, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.tag, std.meta.activeTag(parsed.value));
    }
}

test "a usage update round-trips flat, omitting an absent cost" {
    if (!mod.usage_update.enabled) return error.SkipZigTest;
    const u: SessionUpdate = .{ .usageUpdate = .{ .used = 53000, .size = 200000 } };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, u, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"sessionUpdate\":\"usage_update\",\"used\":53000,\"size\":200000}", out);

    const back = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, out, .{});
    defer back.deinit();
    try std.testing.expectEqual(@as(u64, 200000), back.value.usageUpdate.size);
}

test "a mode change writes its camelCase key under its snake_case tag" {
    const u: SessionUpdate = .{ .currentModeUpdate = .{ .current_mode_id = "plan" } };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, u, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"sessionUpdate\":\"current_mode_update\",\"currentModeId\":\"plan\"}", out);
}

test "a usage update is unknown unless the unstable flag is on" {
    const src =
        \\{"sessionUpdate":"usage_update","used":1,"size":2}
    ;
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(mod.usage_update.enabled, parsed.value != .unknown);
}
