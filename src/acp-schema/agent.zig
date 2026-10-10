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

/// Who is on the other end: `clientInfo` in `initialize`, `agentInfo` in its reply.
pub const Implementation = struct {
    /// Programmatic name.
    name: []const u8,
    /// Name for display; `name` stands in when null.
    title: ?[]const u8 = null,
    version: []const u8,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

/// A capability with nothing to configure: present means served.
pub const Capability = struct {
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

/// Capabilities the client offers to the agent.
pub const ClientCapabilities = struct {
    fs: ?FsCapabilities = null,
    terminal: ?bool = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,

    pub const FsCapabilities = struct {
        readTextFile: ?bool = null,
        writeTextFile: ?bool = null,
        /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
        _meta: ?mod.RawValue = null,
    };
};

/// Capabilities the agent reports back to the client.
pub const AgentCapabilities = struct {
    promptCapabilities: ?PromptCapabilities = null,
    loadSession: ?bool = null,
    /// The MCP transports beyond stdio that `mcpServers` may name.
    mcpCapabilities: ?McpCapabilities = null,
    /// The `session/*` methods served beyond `new`, `prompt` and `cancel`.
    sessionCapabilities: ?SessionCapabilities = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,

    pub const PromptCapabilities = struct {
        image: ?bool = null,
        audio: ?bool = null,
        embeddedContext: ?bool = null,
        /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
        _meta: ?mod.RawValue = null,
    };

    pub const McpCapabilities = struct {
        http: ?bool = null,
        sse: ?bool = null,
        /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
        _meta: ?mod.RawValue = null,
    };

    /// Each present member means its method is served.
    pub const SessionCapabilities = struct {
        list: ?Capability = null,
        delete: ?Capability = null,
        /// `additionalDirectories` is honoured on `session/new`, `session/load` and `session/resume`.
        additionalDirectories: ?Capability = null,
        @"resume": ?Capability = null,
        close: ?Capability = null,
        /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
        _meta: ?mod.RawValue = null,
    };
};

/// First request a client sends. The agent replies with the highest version
/// it speaks plus its capability set.
pub const InitializeRequest = struct {
    protocolVersion: mod.ProtocolVersion,
    clientCapabilities: ?ClientCapabilities = null,
    clientInfo: ?Implementation = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const InitializeResponse = struct {
    protocolVersion: mod.ProtocolVersion,
    agentCapabilities: ?AgentCapabilities = null,
    authMethods: ?[]const AuthMethod = null,
    agentInfo: ?Implementation = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

/// One auth method the agent offers; the client picks one and follows up
/// with `authenticate`.
pub const AuthMethod = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

// ---------------------------------------------------------------------------
// authenticate
// ---------------------------------------------------------------------------

pub const method_authenticate: []const u8 = "authenticate";

pub const AuthenticateRequest = struct {
    methodId: []const u8,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const AuthenticateResponse = struct {
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const method_logout: []const u8 = "logout";

/// Ends the client's sign-in with the agent; served when `agentCapabilities.auth.logout` is offered.
pub const LogoutRequest = struct {
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const LogoutResponse = struct {
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

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
    /// More roots beside `cwd`; sent only to an agent offering `sessionCapabilities.additionalDirectories`.
    additionalDirectories: ?[]const []const u8 = null,
    mcpServers: ?[]const mod.McpServerConfig = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const NewSessionResponse = struct {
    const Self = @This();

    session_id: SessionId,
    /// The modes the session can run in and which is current; null when the agent has none.
    modes: ?mod.SessionModeState = null,
    /// Settings the client may change mid-session, such as the model; null when there are none.
    config_options: ?[]const mod.SessionConfigOption = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,

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
    /// More roots beside `cwd`; sent only to an agent offering `sessionCapabilities.additionalDirectories`.
    additionalDirectories: ?[]const []const u8 = null,
    mcpServers: ?[]const mod.McpServerConfig = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const LoadSessionResponse = struct {
    const Self = @This();

    modes: ?mod.SessionModeState = null,
    config_options: ?[]const mod.SessionConfigOption = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,

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
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const PromptResponse = struct {
    stopReason: StopReason,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
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
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const method_session_set_mode: []const u8 = "session/set_mode";

pub const SetModeRequest = struct {
    sessionId: SessionId,
    modeId: []const u8,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const SetModeResponse = struct {
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const method_session_list: []const u8 = "session/list";

pub const ListSessionsRequest = struct {
    /// Only sessions under this directory; every session when null.
    cwd: ?[]const u8 = null,
    /// Where the previous page ended: its `nextCursor`.
    cursor: ?[]const u8 = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const SessionInfo = struct {
    sessionId: SessionId,
    cwd: []const u8,
    additionalDirectories: ?[]const []const u8 = null,
    title: ?[]const u8 = null,
    /// ISO 8601.
    updatedAt: ?[]const u8 = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const ListSessionsResponse = struct {
    sessions: []const SessionInfo,
    /// Present when more sessions follow; pass it back as `cursor`.
    nextCursor: ?[]const u8 = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const method_session_close: []const u8 = "session/close";

/// Ends a session, cancelling any turn it is running; served when `sessionCapabilities.close` is offered.
pub const CloseSessionRequest = struct {
    sessionId: SessionId,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const CloseSessionResponse = struct {
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const method_session_delete: []const u8 = "session/delete";

/// Forgets a stored session; served when `sessionCapabilities.delete` is offered.
pub const DeleteSessionRequest = struct {
    sessionId: SessionId,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const DeleteSessionResponse = struct {
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

pub const method_session_resume: []const u8 = "session/resume";

/// Reopens a session without replaying its history; served when `sessionCapabilities.resume` is offered.
pub const ResumeSessionRequest = struct {
    sessionId: SessionId,
    cwd: []const u8,
    /// More roots beside `cwd`; sent only to an agent offering `sessionCapabilities.additionalDirectories`.
    additionalDirectories: ?[]const []const u8 = null,
    mcpServers: ?[]const mod.McpServerConfig = null,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
};

/// A resumed session's modes and settings: the shape `session/load` answers with.
pub const ResumeSessionResponse = LoadSessionResponse;

pub const method_session_set_config_option: []const u8 = "session/set_config_option";

pub const SetConfigOptionRequest = struct {
    const Self = @This();

    session_id: SessionId,
    config_id: []const u8,
    value: mod.RawValue,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,

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
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,

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
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?mod.RawValue = null,
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

// The replies each inferise harness writes (zigclaude, zigcodex, ziggrok,
// ziggemini, zigcopilot, zigafm), decoded strictly: a key the schema does not
// declare fails the parse, so these pin that the schema carries all of them.
test "every harness's initialize, session/new, session/load and session/prompt replies decode strictly" {
    const initialize = [_][]const u8{
        \\{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true,"audio":false,"embeddedContext":true},"_meta":{"inferise":{"interject":true,"unpromptedTurns":true}}}}
        ,
        \\{"protocolVersion":1,"agentCapabilities":{"promptCapabilities":{"image":true,"audio":false,"embeddedContext":true},"loadSession":true}}
        ,
        \\{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":false},"sessionCapabilities":{"close":{}}},"agentInfo":{"name":"ziggrok","version":"0.0.3"},"authMethods":[]}
        ,
        \\{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":false},"sessionCapabilities":{"close":{}}},"agentInfo":{"name":"zigafm","version":"1.0.0"},"authMethods":[],"_meta":{"zigafm":{"availability":"available"}}}
    };
    for (initialize) |src| {
        const parsed = try std.json.parseFromSlice(InitializeResponse, std.testing.allocator, src, .{});
        parsed.deinit();
    }

    const opened = [_][]const u8{
        \\{"sessionId":"3f2b8c1e","modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Ask","description":"Ask before anything that is not a read"},{"id":"plan","name":"Plan"}]},"configOptions":[{"type":"select","id":"model","name":"Model","category":"model","currentValue":"default","options":[{"value":"default","name":"Default","description":"Whatever this account defaults to"},{"value":"opus","name":"Opus"}]}]}
        ,
        \\{"sessionId":"a1b2c3d4","_meta":{"ziggrok":{"account":"grok","alwaysApprove":false,"grokVersion":"0.1.42","contextTokens":256000,"contextUsed":11200}}}
        ,
        \\{"sessionId":"zg-9f3a1c0b7e2d4a56","_meta":{"ziggemini":{"account":"antigravity","alwaysApprove":false,"agyVersion":"1.4.2"}}}
        ,
        \\{"sessionId":"7c9e6679-7425-40de-944b-e07fc1f90ae7"}
    };
    for (opened) |src| {
        const parsed = try std.json.parseFromSlice(NewSessionResponse, std.testing.allocator, src, .{});
        parsed.deinit();
    }

    const loaded = [_][]const u8{
        \\{"modes":{"currentModeId":"readOnly","availableModes":[{"id":"readOnly","name":"Read only"}]},"configOptions":[]}
        ,
        \\{"_meta":{"zigcopilot":{"account":"copilot","alwaysApprove":false,"copilotVersion":"0.0.330","contextTokens":128000,"contextUsed":11100}}}
        ,
        \\{"_meta":{"zigafm":{"turns":3,"instructions":"Answer briefly."}}}
    };
    for (loaded) |src| {
        const parsed = try std.json.parseFromSlice(LoadSessionResponse, std.testing.allocator, src, .{});
        parsed.deinit();
    }

    const prompted = [_][]const u8{
        \\{"stopReason":"end_turn","_meta":{"zigclaude":{"wallMs":8421,"claudeMs":7930,"inputTokens":15234,"outputTokens":612,"costUsd":0.0412,"contextTokens":48211,"contextWindow":200000,"rateLimits":{"fiveHour":{"utilization":0.23,"resetsAt":1791320400}}}}}
        ,
        \\{"stopReason":"end_turn","_meta":{"zigcodex":{"wallMs":12040,"codexMs":11800,"inputTokens":24310,"cachedInputTokens":18000,"outputTokens":845,"reasoningOutputTokens":320,"contextTokens":25155,"contextWindow":272000}}}
        ,
        \\{"stopReason":"end_turn","_meta":{"ziggemini":{"wallMs":7400,"agyMs":7100,"deniedActions":["write_file /p/a.txt"],"conversationId":"conv-1"}}}
        ,
        \\{"stopReason":"refusal","_meta":{"zigafm":{"wallMs":310,"tokens":null,"status":"contextOverflow","error":"The conversation no longer fits the context window."}}}
    };
    for (prompted) |src| {
        const parsed = try std.json.parseFromSlice(PromptResponse, std.testing.allocator, src, .{});
        parsed.deinit();
    }

    const listed = [_][]const u8{
        \\{"sessions":[{"sessionId":"01a09dd4","cwd":"."}]}
        ,
        \\{"sessions":[{"sessionId":"7c9e6679","cwd":"/p","title":"Summarize this file","updatedAt":"2026-10-06T14:03:22Z"}]}
    };
    for (listed) |src| {
        const parsed = try std.json.parseFromSlice(ListSessionsResponse, std.testing.allocator, src, .{});
        parsed.deinit();
    }
}
