//! Client → Agent method surface.
//!
//! Each method's request and response live here. Method names are wire-level
//! constants (the JSON-RPC `method` string). Sub-commits land additional
//! method groups (session/*, terminal/*, etc.) iteratively.

const std = @import("std");
const log = std.log.scoped(.acp_schema_agent);
const mod = @import("module.zig");

// ---------------------------------------------------------------------------
// initialize
// ---------------------------------------------------------------------------

pub const method_initialize: []const u8 = "initialize";

/// Capabilities the client offers to the agent.
pub const ClientCapabilities = struct {
    fs: ?FsCapabilities = null,
    terminal: ?bool = null,

    pub const FsCapabilities = struct {
        readTextFile: ?bool = null,
        writeTextFile: ?bool = null,
    };
};

/// Capabilities the agent reports back to the client.
pub const AgentCapabilities = struct {
    promptCapabilities: ?PromptCapabilities = null,
    loadSession: ?bool = null,

    pub const PromptCapabilities = struct {
        image: ?bool = null,
        audio: ?bool = null,
        embeddedContext: ?bool = null,
    };
};

/// First request a client sends. The agent replies with the highest version
/// it speaks plus its capability set.
pub const InitializeRequest = struct {
    protocolVersion: mod.ProtocolVersion,
    clientCapabilities: ?ClientCapabilities = null,
};

pub const InitializeResponse = struct {
    protocolVersion: mod.ProtocolVersion,
    agentCapabilities: ?AgentCapabilities = null,
    authMethods: ?[]const AuthMethod = null,
};

/// One auth method the agent offers; the client picks one and follows up
/// with `authenticate`.
pub const AuthMethod = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// authenticate
// ---------------------------------------------------------------------------

pub const method_authenticate: []const u8 = "authenticate";

pub const AuthenticateRequest = struct {
    methodId: []const u8,
};

pub const AuthenticateResponse = struct {};

// ---------------------------------------------------------------------------
// session/*
// ---------------------------------------------------------------------------

/// Opaque session identifier minted by the agent on `session/new`.
pub const SessionId = struct {
    value: []const u8,

    pub fn jsonStringify(self: SessionId, jw: anytype) !void {
        try jw.write(self.value);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !SessionId {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const slice = switch (tok) {
            .string => |s| try allocator.dupe(u8, s),
            .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return .{ .value = slice };
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !SessionId {
        if (source != .string) return error.UnexpectedToken;
        return .{ .value = try allocator.dupe(u8, source.string) };
    }
};

pub const method_session_new: []const u8 = "session/new";

pub const NewSessionRequest = struct {
    cwd: []const u8,
    mcpServers: ?[]const mod.McpServerConfig = null,
};

pub const NewSessionResponse = struct {
    const Self = @This();

    session_id: SessionId,
    /// The modes the session can run in and which is current; null when the agent has none.
    modes: ?mod.SessionModeState = null,
    /// Settings the client may change mid-session, such as the model; null when there are none.
    config_options: ?[]const mod.SessionConfigOption = null,

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

pub const method_session_load: []const u8 = "session/load";

pub const LoadSessionRequest = struct {
    sessionId: SessionId,
    cwd: []const u8,
    mcpServers: ?[]const mod.McpServerConfig = null,
};

pub const LoadSessionResponse = struct {
    const Self = @This();

    modes: ?mod.SessionModeState = null,
    config_options: ?[]const mod.SessionConfigOption = null,

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

pub const method_session_prompt: []const u8 = "session/prompt";

pub const PromptRequest = struct {
    sessionId: SessionId,
    prompt: []const mod.ContentBlock,
};

pub const PromptResponse = struct {
    stopReason: StopReason,
};

/// Why the agent stopped producing tokens for this prompt.
pub const StopReason = enum {
    end_turn,
    max_tokens,
    max_turn_requests,
    refusal,
    cancelled,

    pub fn jsonStringify(self: StopReason, jw: anytype) !void {
        try jw.write(@tagName(self));
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !StopReason {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer freeToken(allocator, tok);
        const slice = switch (tok) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return std.meta.stringToEnum(StopReason, slice) orelse error.InvalidEnumTag;
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !StopReason {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(StopReason, source.string) orelse error.InvalidEnumTag;
    }
};

pub const method_session_cancel: []const u8 = "session/cancel";

pub const CancelNotification = struct {
    sessionId: SessionId,
};

pub const method_session_set_mode: []const u8 = "session/set_mode";

pub const SetModeRequest = struct {
    sessionId: SessionId,
    modeId: []const u8,
};

pub const SetModeResponse = struct {};

pub const method_session_list: []const u8 = "session/list";

pub const ListSessionsRequest = struct {};

pub const SessionInfo = struct {
    sessionId: SessionId,
    cwd: []const u8,
};

pub const ListSessionsResponse = struct {
    sessions: []const SessionInfo,
};

pub const method_session_set_config_option: []const u8 = "session/set_config_option";

pub const SetConfigOptionRequest = struct {
    const Self = @This();

    session_id: SessionId,
    config_id: []const u8,
    value: mod.RawValue,

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

/// Every option after the change: setting one may change others (a model
/// switch can narrow the thought levels on offer).
pub const SetConfigOptionResponse = struct {
    const Self = @This();

    config_options: ?[]const mod.SessionConfigOption = null,

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

// session/update is a notification streamed from agent → client during a
// prompt. Each update has a `sessionId` plus a tagged `update` payload
// keyed on `sessionUpdate`.

pub const method_session_update: []const u8 = "session/update";

/// `session/update` notification body: a session id plus one update event.
pub const SessionNotification = struct {
    sessionId: SessionId,
    update: mod.SessionUpdate,
};

fn freeToken(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |s| allocator.free(s),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "InitializeRequest minimal round-trip" {
    const src =
        \\{"protocolVersion":1}
    ;
    const parsed = try std.json.parseFromSlice(InitializeRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 1), parsed.value.protocolVersion.value);
    try std.testing.expect(parsed.value.clientCapabilities == null);
}

test "InitializeRequest with capabilities" {
    const src =
        \\{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":false},"terminal":true}}
    ;
    const parsed = try std.json.parseFromSlice(InitializeRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.clientCapabilities.?.fs.?.readTextFile.?);
    try std.testing.expect(!parsed.value.clientCapabilities.?.fs.?.writeTextFile.?);
    try std.testing.expect(parsed.value.clientCapabilities.?.terminal.?);
}

test "InitializeResponse with auth methods" {
    const src =
        \\{"protocolVersion":1,"agentCapabilities":{"promptCapabilities":{"image":true,"audio":false,"embeddedContext":true},"loadSession":true},"authMethods":[{"id":"oauth","name":"OAuth","description":"Sign in with provider"}]}
    ;
    const parsed = try std.json.parseFromSlice(InitializeResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.authMethods.?.len);
    try std.testing.expectEqualStrings("oauth", parsed.value.authMethods.?[0].id);
    try std.testing.expect(parsed.value.agentCapabilities.?.promptCapabilities.?.image.?);
}

test "AuthenticateRequest round-trip" {
    const src =
        \\{"methodId":"oauth"}
    ;
    const parsed = try std.json.parseFromSlice(AuthenticateRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("oauth", parsed.value.methodId);
}

test "InitializeRequest stringifies omitting null capabilities" {
    const req: InitializeRequest = .{ .protocolVersion = mod.ProtocolVersion.V1 };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, req, .{ .emit_null_optional_fields = false });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"protocolVersion\":1}", out);
}

test "an HTTP MCP server parses beside a stdio one" {
    const src =
        \\{"cwd":"/p","mcpServers":[{"type":"http","name":"inferise","url":"http://127.0.0.1:4000/mcp","headers":[{"name":"Authorization","value":"Bearer t"}]},{"name":"git","command":"mcp-git","args":[],"env":[]}]}
    ;
    const parsed = try std.json.parseFromSlice(NewSessionRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    const servers = parsed.value.mcpServers.?;
    try std.testing.expectEqualStrings("Bearer t", servers[0].http.headers[0].value);
    try std.testing.expectEqualStrings("mcp-git", servers[1].stdio.command);
}

test "NewSessionRequest with mcp servers" {
    const src =
        \\{"cwd":"/home/u/proj","mcpServers":[{"name":"git","command":"mcp-git","args":["--repo","."],"env":[{"name":"K","value":"v"}]}]}
    ;
    const parsed = try std.json.parseFromSlice(NewSessionRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/home/u/proj", parsed.value.cwd);
    try std.testing.expectEqualStrings("git", parsed.value.mcpServers.?[0].stdio.name);
    try std.testing.expectEqualStrings("v", parsed.value.mcpServers.?[0].stdio.env[0].value);
}

test "NewSessionResponse session id round-trip" {
    const src =
        \\{"sessionId":"sess_42"}
    ;
    const parsed = try std.json.parseFromSlice(NewSessionResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("sess_42", parsed.value.session_id.value);
}

test "PromptRequest with text content" {
    const src =
        \\{"sessionId":"s1","prompt":[{"type":"text","text":"hi"}]}
    ;
    const parsed = try std.json.parseFromSlice(PromptRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.prompt.len);
    try std.testing.expect(parsed.value.prompt[0] == .text);
}

test "PromptResponse stop reasons" {
    inline for (.{ "end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled" }) |name| {
        const src = "{\"stopReason\":\"" ++ name ++ "\"}";
        const parsed = try std.json.parseFromSlice(PromptResponse, std.testing.allocator, src, .{});
        defer parsed.deinit();
    }
}

test "CancelNotification carries session id" {
    const src =
        \\{"sessionId":"s1"}
    ;
    const parsed = try std.json.parseFromSlice(CancelNotification, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("s1", parsed.value.sessionId.value);
}

test "SessionNotification carries session id and update" {
    const src =
        \\{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}
    ;
    const parsed = try std.json.parseFromSlice(SessionNotification, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("s1", parsed.value.sessionId.value);
    try std.testing.expect(parsed.value.update == .agentMessageChunk);
}

test "NewSessionResponse carries modes and a model option" {
    const src =
        \\{"sessionId":"s1","modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"},{"id":"plan","name":"Plan","description":"Read-only"}]},
        \\ "configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"sonnet","options":[{"value":"sonnet","name":"Sonnet"},{"value":"opus","name":"Opus"}]}]}
    ;
    const parsed = try std.json.parseFromSlice(NewSessionResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("default", parsed.value.modes.?.current_mode_id);
    try std.testing.expectEqualStrings("Read-only", parsed.value.modes.?.available_modes[1].description.?);
    try std.testing.expectEqualStrings("model", parsed.value.config_options.?[0].select.category.?);
    try std.testing.expectEqualStrings("opus", parsed.value.config_options.?[0].select.options.ungrouped[1].value);
}

test "SetModeRequest" {
    const src =
        \\{"sessionId":"s1","modeId":"reasoning"}
    ;
    const parsed = try std.json.parseFromSlice(SetModeRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("reasoning", parsed.value.modeId);
}
