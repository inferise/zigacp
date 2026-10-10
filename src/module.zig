//! The zigacp barrel: one namespace over `acp`, `acp-schema`, `acp-async`
//! and `acp-mcp`.
//!
//! zigacp is five modules, and a consumer that imports them one by one ends up
//! with `acp.Transport`, `acp_async.FrameTransport` and `schema.agent.StopReason`
//! side by side — three spellings for one protocol, and no way to tell from the
//! name which module a type lives in. This barrel re-exports every symbol the
//! harnesses (zigclaude, zigcodex, ziggrok) consume under its own name, so a
//! consumer imports `zigacp` alone and writes `acp.Transport`,
//! `acp.FrameTransport` and `acp.Agent.StopReason`.
//!
//! The convention: a symbol keeps the name it has in its home module. The
//! connection, the transports and the schema types both sides share sit at the
//! top level; a method and its request and response types sit under the side
//! that serves it — `acp.Agent` for `initialize`, `authenticate`, `logout` and
//! `session/*`, `acp.Client` for `fs/*`, `terminal/*` and
//! `session/request_permission`. The proxy pieces of `acp-conductor` sit
//! under `acp.Conductor`; `acp-test` is not re-exported.
//!
//! Beside the re-exports, the barrel holds shared implementations that sit
//! above the protocol: `acp.Client.Fs` serves the client's filesystem methods,
//! `acp.Client.Terminal` its terminal methods, `acp.Meta` names the `_meta`
//! fields more than one agent honours and reads and writes `_meta`, and
//! `acp.Inferise` names the `_inferise/*` extension every inferise host and
//! agent speaks.
//!
//! Only what is consumed is listed. A new consumer adds the symbol here rather
//! than importing the underlying module beside the barrel.

const std = @import("std");
const acp = @import("acp");
const schema = @import("acp-schema");
const acp_async = @import("acp-async");
const acp_mcp = @import("acp-mcp");
const acp_conductor = @import("acp-conductor");

// -----------------------------------------------------------------------------
// Connection (acp)

pub const Connection = acp.Connection;
pub const Dispatcher = acp.Dispatcher;
pub const RequestHandler = acp.RequestHandler;
pub const NotificationHandler = acp.NotificationHandler;
pub const AcpError = acp.AcpError;
/// How a frame's params or result are written: unset optionals left out, as ACP expects.
pub const wire_options = acp.wire_options;

// -----------------------------------------------------------------------------
// Transports (acp, acp-async)

/// The interface every transport implements; a `Connection` takes one.
pub const Transport = acp.Transport;
pub const Frame = acp.Frame;
/// An in-process pair whose reads block until a frame arrives.
pub const FrameTransport = acp_async.FrameTransport;
/// A file-handle pair (a process's stdio) whose reads can be polled mid-turn.
pub const StdioTransport = acp_async.StdioTransport;
/// Runtime settings a `StdioTransport` borrows.
pub const Config = acp_async.Config;
/// A file-handle pair read on demand, one line a frame, with a bounded frame length.
pub const FileTransport = acp_async.FileTransport;
/// An agent served on one end of an in-process `FrameTransport`; the other end is a client's.
pub const LocalSeam = acp_async.LocalSeam;
/// A JSON-RPC peer that hands back whole parsed messages, for a proxy that relays raw values.
pub const RawPeer = acp.RawPeer;
pub const RawMessage = acp.RawMessage;
/// A transport that answers from a script and records what it is sent, for tests.
pub const ScriptedPeer = acp.ScriptedPeer;

// -----------------------------------------------------------------------------
// Proxying (acp-conductor)

/// What a proxy between a client and an agent is built from.
pub const Conductor = struct {
    /// Which way a frame travels: `forward` toward the agent, `reverse` toward the client.
    pub const Direction = acp_conductor.Direction;
    /// Matches each reply to the request it answers, one table per direction.
    pub const Pairing = acp_conductor.Pairing;
    pub const Chain = acp_conductor.Chain;
    pub const RequestInterceptor = acp_conductor.RequestInterceptor;
    pub const NotificationInterceptor = acp_conductor.NotificationInterceptor;
    pub const ReplyInterceptor = acp_conductor.ReplyInterceptor;
    pub const RequestContext = acp_conductor.RequestContext;
    pub const NotificationContext = acp_conductor.NotificationContext;
    pub const ReplyContext = acp_conductor.ReplyContext;
    pub const RequestOutcome = acp_conductor.RequestOutcome;
    pub const NotificationOutcome = acp_conductor.NotificationOutcome;
    pub const ReplyOutcome = acp_conductor.ReplyOutcome;
};

// -----------------------------------------------------------------------------
// MCP (acp-mcp)

/// A read-only view over one MCP server from `session/new` or `session/load`.
pub const McpServer = acp_mcp.McpServer;

// -----------------------------------------------------------------------------
// Shared schema (acp-schema)

pub const ProtocolVersion = schema.ProtocolVersion;
pub const ContentBlock = schema.ContentBlock;
pub const PlanEntry = schema.PlanEntry;
pub const ToolKind = schema.ToolKind;
pub const ToolCallStatus = schema.ToolCallStatus;
pub const ToolCall = schema.ToolCall;
pub const ToolCallUpdate = schema.ToolCallUpdate;
pub const ToolCallContent = schema.ToolCallContent;
pub const ToolCallLocation = schema.ToolCallLocation;
/// Any JSON value, carried as is: a tool call's `rawInput`, `rawOutput` and `_meta`.
pub const RawValue = schema.RawValue;
/// The `usage_update` session update: context in use, window size, cost so far.
pub const UsageUpdate = schema.UsageUpdate;
pub const UsageCost = schema.UsageCost;

// -----------------------------------------------------------------------------
// JSON-RPC (acp-schema `rpc`, `error`, `protocol_level`)

pub const RequestId = schema.RequestId;
pub const Request = schema.Request;
pub const Response = schema.Response;
pub const ResponseError = schema.ResponseError;
pub const Notification = schema.Notification;
pub const JsonRpcMessage = schema.JsonRpcMessage;
pub const JSONRPC_VERSION = schema.JSONRPC_VERSION;
/// A JSON-RPC error code; the codes ACP and JSON-RPC define are in `ErrorCodes`.
pub const ErrorCode = schema.ErrorCode;
pub const ErrorCodes = schema.@"error";
/// `$/cancel_request`, which either side may send.
pub const method_cancel_request = schema.protocol_level.method_cancel_request;
pub const CancelRequestNotification = schema.CancelRequestNotification;

// -----------------------------------------------------------------------------
// Agent methods: client → agent (acp-schema `agent`)

/// What an agent serves: its methods and their request and response types.
pub const Agent = struct {
    pub const method_initialize = schema.agent.method_initialize;
    pub const method_authenticate = schema.agent.method_authenticate;
    pub const method_logout = schema.agent.method_logout;
    pub const method_session_close = schema.agent.method_session_close;
    pub const method_session_delete = schema.agent.method_session_delete;
    pub const method_session_resume = schema.agent.method_session_resume;
    pub const method_session_new = schema.agent.method_session_new;
    pub const method_session_load = schema.agent.method_session_load;
    pub const method_session_list = schema.agent.method_session_list;
    pub const method_session_prompt = schema.agent.method_session_prompt;
    pub const method_session_cancel = schema.agent.method_session_cancel;
    pub const method_session_update = schema.agent.method_session_update;
    pub const method_session_set_mode = schema.agent.method_session_set_mode;
    pub const method_session_set_config_option = schema.agent.method_session_set_config_option;

    pub const InitializeRequest = schema.agent.InitializeRequest;
    pub const InitializeResponse = schema.agent.InitializeResponse;
    pub const Implementation = schema.agent.Implementation;
    pub const Capability = schema.agent.Capability;
    pub const AgentCapabilities = schema.agent.AgentCapabilities;
    pub const ClientCapabilities = schema.agent.ClientCapabilities;
    pub const AuthMethod = schema.agent.AuthMethod;
    pub const AuthenticateRequest = schema.agent.AuthenticateRequest;
    pub const AuthenticateResponse = schema.agent.AuthenticateResponse;
    pub const LogoutRequest = schema.agent.LogoutRequest;
    pub const LogoutResponse = schema.agent.LogoutResponse;
    pub const CloseSessionRequest = schema.agent.CloseSessionRequest;
    pub const CloseSessionResponse = schema.agent.CloseSessionResponse;
    pub const DeleteSessionRequest = schema.agent.DeleteSessionRequest;
    pub const DeleteSessionResponse = schema.agent.DeleteSessionResponse;
    pub const ResumeSessionRequest = schema.agent.ResumeSessionRequest;
    pub const ResumeSessionResponse = schema.agent.ResumeSessionResponse;
    pub const NewSessionRequest = schema.agent.NewSessionRequest;
    pub const NewSessionResponse = schema.agent.NewSessionResponse;
    pub const LoadSessionRequest = schema.agent.LoadSessionRequest;
    pub const LoadSessionResponse = schema.agent.LoadSessionResponse;
    pub const ListSessionsRequest = schema.agent.ListSessionsRequest;
    pub const ListSessionsResponse = schema.agent.ListSessionsResponse;
    pub const PromptRequest = schema.agent.PromptRequest;
    pub const PromptResponse = schema.agent.PromptResponse;
    pub const CancelNotification = schema.agent.CancelNotification;
    pub const SessionNotification = schema.agent.SessionNotification;
    pub const SessionUpdate = schema.SessionUpdate;
    pub const SessionId = schema.agent.SessionId;
    pub const SessionInfo = schema.agent.SessionInfo;
    pub const StopReason = schema.agent.StopReason;
    pub const McpServerConfig = schema.McpServerConfig;
    pub const McpServerStdio = schema.McpServerStdio;
    pub const McpServerRemote = schema.McpServerRemote;
    pub const McpEnv = schema.McpEnv;
    pub const SetModeRequest = schema.agent.SetModeRequest;
    pub const SetModeResponse = schema.agent.SetModeResponse;
    pub const SetConfigOptionRequest = schema.agent.SetConfigOptionRequest;
    pub const SetConfigOptionResponse = schema.agent.SetConfigOptionResponse;
    pub const SessionMode = schema.SessionMode;
    pub const SessionModeState = schema.SessionModeState;
    pub const SessionConfigOption = schema.SessionConfigOption;
    pub const SessionConfigSelect = schema.SessionConfigSelect;
    pub const SessionConfigSelectOptions = schema.SessionConfigSelectOptions;
    pub const SessionConfigSelectGroup = schema.SessionConfigSelectGroup;
    pub const SessionConfigSelectOption = schema.SessionConfigSelectOption;
    pub const SessionConfigBoolean = schema.SessionConfigBoolean;
    pub const ContentChunk = schema.ContentChunk;
    pub const AvailableCommand = schema.AvailableCommand;
};

// -----------------------------------------------------------------------------
// Client methods: agent → client (acp-schema `client`)

/// What a client serves: its methods and their request and response types.
pub const Client = struct {
    pub const method_session_request_permission = schema.client.method_session_request_permission;
    pub const method_fs_read_text_file = schema.client.method_fs_read_text_file;
    pub const method_fs_write_text_file = schema.client.method_fs_write_text_file;
    pub const method_terminal_create = schema.client.method_terminal_create;
    pub const method_terminal_output = schema.client.method_terminal_output;
    pub const method_terminal_wait_for_exit = schema.client.method_terminal_wait_for_exit;
    pub const method_terminal_kill = schema.client.method_terminal_kill;
    pub const method_terminal_release = schema.client.method_terminal_release;

    pub const RequestPermissionRequest = schema.client.RequestPermissionRequest;
    pub const RequestPermissionResponse = schema.client.RequestPermissionResponse;
    pub const PermissionOption = schema.client.PermissionOption;
    pub const PermissionOptionKind = schema.client.PermissionOptionKind;
    pub const ReadTextFileRequest = schema.client.ReadTextFileRequest;
    pub const ReadTextFileResponse = schema.client.ReadTextFileResponse;
    pub const WriteTextFileRequest = schema.client.WriteTextFileRequest;
    pub const WriteTextFileResponse = schema.client.WriteTextFileResponse;
    pub const CreateTerminalRequest = schema.client.CreateTerminalRequest;
    pub const CreateTerminalResponse = schema.client.CreateTerminalResponse;
    pub const TerminalOutputRequest = schema.client.TerminalOutputRequest;
    pub const TerminalOutputResponse = schema.client.TerminalOutputResponse;
    pub const WaitForTerminalExitRequest = schema.client.WaitForTerminalExitRequest;
    pub const WaitForTerminalExitResponse = schema.client.WaitForTerminalExitResponse;
    pub const KillTerminalRequest = schema.client.KillTerminalRequest;
    pub const KillTerminalResponse = schema.client.KillTerminalResponse;
    pub const ReleaseTerminalRequest = schema.client.ReleaseTerminalRequest;
    pub const ReleaseTerminalResponse = schema.client.ReleaseTerminalResponse;

    pub const TerminalEnv = schema.client.TerminalEnv;
    pub const TerminalExitStatus = schema.client.TerminalExitStatus;

    /// Serves `fs/read_text_file` and `fs/write_text_file` on a client's dispatcher.
    pub const Fs = @import("client_fs.zig").ClientFs;
    /// Serves the five `terminal/*` methods on a client's dispatcher, over plain pipes.
    pub const Terminal = @import("client_terminal.zig").ClientTerminal;
    /// Serves the five `terminal/*` methods on a client's dispatcher, on a pseudoterminal.
    pub const PtyTerminal = @import("client_pty_terminal.zig").ClientPtyTerminal;
};

// -----------------------------------------------------------------------------
// Pseudoterminals

/// A program run the way a terminal runs it, and the screen it draws.
///
/// Three layers: `Session` runs a command on a pseudoterminal and keeps its
/// bytes, `VtDecoder` says what escape sequences those bytes are, and
/// `VtScreen` is the screen they draw. `Client.PtyTerminal` serves ACP's
/// `terminal/*` on it. POSIX only: `Session.start` fails on Windows. `Session`
/// calls libc's `openpty`, so a consumer that uses it links libc
/// (`link_libc = true`); one that does not is unaffected.
pub const Pty = struct {
    pub const Session = @import("pty_session.zig").PtySession;
    /// A bare pseudoterminal pair, for a caller spawning its own program on it.
    pub const Pair = @import("pty_session.zig").PtyPair;
    pub const RawSlice = @import("pty_session.zig").RawSlice;
    pub const VtDecoder = @import("vt_decoder.zig").VtDecoder;
    pub const VtEvent = @import("vt_decoder.zig").VtEvent;
    pub const Csi = @import("vt_decoder.zig").Csi;
    pub const VtScreen = @import("vt_screen.zig").VtScreen;
};

// -----------------------------------------------------------------------------
// `_meta`

/// Reads and writes `_meta`, and names its fields more than one agent honours.
///
/// ACP reserves `_meta` for extensions, and an agent or host namespaces its own
/// under its name (`_meta.<name>`). A field meant to work the same against
/// every agent is not namespaced, and its name lives here so a client and each
/// agent spell it identically.
pub const Meta = struct {
    /// `session/new._meta.instructions`: standing instructions for the session,
    /// as a string. Privileged relative to prompts, so a client never puts
    /// user-supplied text in it. An agent that cannot apply instructions
    /// ignores the field rather than failing the request.
    pub const instructions = "instructions";

    /// Reads one member of `_meta` as a type, ignoring fields the type does not declare.
    ///
    /// Parameters:
    /// - `T`: the member's shape.
    /// - `allocator`: owns what is parsed; an arena in practice.
    /// - `meta`: the `_meta` that arrived, or null.
    /// - `key`: the member, such as a namespace (`"zigexample"`) or a shared field (`instructions`).
    ///
    /// Return: the member, or null when it is absent or null; `error.InvalidParams` when it does not fit `T`.
    pub fn read(comptime T: type, allocator: std.mem.Allocator, meta: ?RawValue, key: []const u8) AcpError!?T {
        const raw = meta orelse return null;
        if (raw.value != .object) return null;
        const member = raw.value.object.get(key) orelse return null;
        if (member == .null) return null;
        return std.json.parseFromValueLeaky(T, allocator, member, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidParams,
        };
    }

    /// Builds a `_meta` holding one member.
    ///
    /// Parameters:
    /// - `allocator`: owns the result; an arena in practice.
    /// - `key`: the member's name, such as the writer's namespace.
    /// - `value`: the member; anything `std.json` can write.
    ///
    /// Return: `{ key: value }`, null optionals left out; propagates allocation failure.
    pub fn of(allocator: std.mem.Allocator, key: []const u8, value: anytype) AcpError!RawValue {
        const bytes = std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false }) catch return error.OutOfMemory;
        const member = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{}) catch return error.OutOfMemory;
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, key, member);
        return .{ .value = .{ .object = object } };
    }
};

// -----------------------------------------------------------------------------
// `_inferise/*`

/// The inferise extension: what an inferise host and the agents it runs say
/// beyond ACP, all under the `_inferise/` method prefix and `_meta.inferise`.
///
/// An agent advertises what it serves in `initialize`'s
/// `agentCapabilities._meta.inferise` (`Capabilities`); a host relies on none
/// of it otherwise.
pub const Inferise = struct {
    /// The `_meta` member every inferise field sits under.
    pub const key = "inferise";

    /// Host → agent notification: adds a message to the turn running now (`InterjectNotification`).
    pub const method_interject = "_inferise/interject";
    /// Agent → host notification: closes a turn the agent started itself (`RunEndedNotification`).
    pub const method_run_ended = "_inferise/run_ended";
    /// Agent → host notification: what runs in the background (`BackgroundTasksNotification`).
    pub const method_background_tasks = "_inferise/background_tasks";
    /// Relay → host notification: a session's own report of its progress (`ProgressNotification`).
    pub const method_progress = "_inferise/progress";
    /// Relay → host request: a question for the person (`AskUserRequest`, answered by `AskUserResponse`).
    pub const method_ask_user = "_inferise/ask_user";

    /// `_meta.inferise.instructions` on `session/new`: the host's standing instructions.
    pub const instructions = "instructions";
    /// `_meta.inferise.logDir` on `session/new`: where the session's record goes.
    pub const log_dir = "logDir";
    /// `_meta.inferise.usage` on a turn's end: one usage shape across agents.
    pub const usage = "usage";
    /// `_meta.inferise.turn` on a turn's end: the turn's number in its session.
    pub const turn = "turn";

    /// `agentCapabilities._meta.inferise`: what the agent serves of this extension.
    pub const Capabilities = struct {
        /// `_inferise/interject` is served: a message sent while a turn runs joins it.
        interject: bool = false,
        /// A turn the agent starts itself is always closed by `_inferise/run_ended`.
        unpromptedTurns: bool = false,
    };

    pub const InterjectNotification = struct {
        sessionId: Agent.SessionId,
        prompt: []const ContentBlock,
    };

    /// The end of an unprompted turn: what a `session/prompt` reply would say.
    pub const RunEndedNotification = struct {
        sessionId: Agent.SessionId,
        stopReason: Agent.StopReason,
        /// The agent's own usage under its namespace, as on a prompt's reply.
        _meta: ?RawValue = null,
    };

    pub const BackgroundTask = struct {
        id: []const u8,
        description: []const u8,
        /// What it is doing right now, when the agent has said.
        activity: ?[]const u8 = null,
        /// The tool call that launched it, when known.
        toolCallId: ?[]const u8 = null,
    };

    pub const BackgroundTasksNotification = struct {
        sessionId: Agent.SessionId,
        tasks: []const BackgroundTask,
    };

    pub const ProgressNotification = struct {
        sessionId: Agent.SessionId,
        summary: []const u8,
        /// 0 to 100.
        percentComplete: ?f64 = null,
        /// 0 to 100.
        confidence: ?f64 = null,
    };

    pub const AskUserRequest = struct {
        sessionId: Agent.SessionId,
        question: []const u8,
        /// Suggested answers; the person may give another.
        options: ?[]const []const u8 = null,
    };

    pub const AskUserResponse = struct {
        /// Null when the person gave none.
        answer: ?[]const u8 = null,
    };
};

// -----------------------------------------------------------------------------
// Unit Tests

// `refAllDecls` stops at a namespace's own decls, so each group is walked explicitly.
test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Agent);
    std.testing.refAllDecls(Client);
    std.testing.refAllDecls(Meta);
    std.testing.refAllDecls(Inferise);
    std.testing.refAllDecls(Conductor);
    std.testing.refAllDecls(Pty);
}

test "a namespace of _meta reads as a type, and absent reads as null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Ours = struct { account: []const u8 };
    const meta = try Meta.of(arena, "zigexample", Ours{ .account = "work" });
    const ours = (try Meta.read(Ours, arena, meta, "zigexample")).?;
    try std.testing.expectEqualStrings("work", ours.account);
    try std.testing.expectEqual(@as(?Ours, null), try Meta.read(Ours, arena, meta, "other"));
    try std.testing.expectEqual(@as(?Ours, null), try Meta.read(Ours, arena, null, "zigexample"));
    try std.testing.expectError(error.InvalidParams, Meta.read(struct { account: u32 }, arena, meta, "zigexample"));
}

test "_meta on a request survives the wire both ways" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request: Agent.NewSessionRequest = .{ .cwd = "/p", .mcpServers = &.{}, ._meta = try Meta.of(arena, Meta.instructions, "be brief") };
    const bytes = try std.json.Stringify.valueAlloc(arena, request, .{ .emit_null_optional_fields = false });
    try std.testing.expectEqualStrings("{\"cwd\":\"/p\",\"mcpServers\":[],\"_meta\":{\"instructions\":\"be brief\"}}", bytes);

    const back = try std.json.parseFromSliceLeaky(Agent.NewSessionRequest, arena, bytes, .{});
    try std.testing.expectEqualStrings("be brief", (try Meta.read([]const u8, arena, back._meta, Meta.instructions)).?);
}

test "an agent's capabilities name its session methods, MCP transports and itself" {
    const src =
        \\{"protocolVersion":1,"agentInfo":{"name":"zigexample","version":"1.2.3"},"agentCapabilities":{"loadSession":true,
        \\ "mcpCapabilities":{"http":true},"sessionCapabilities":{"close":{},"list":{},"resume":{}},"_meta":{"inferise":{"interject":true}}}}
    ;
    const parsed = try std.json.parseFromSlice(Agent.InitializeResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    const capabilities = parsed.value.agentCapabilities.?;
    try std.testing.expectEqualStrings("1.2.3", parsed.value.agentInfo.?.version);
    try std.testing.expect(capabilities.mcpCapabilities.?.http.?);
    try std.testing.expect(capabilities.sessionCapabilities.?.close != null);
    try std.testing.expect(capabilities.sessionCapabilities.?.delete == null);
    const inferise = (try Meta.read(Inferise.Capabilities, std.testing.allocator, capabilities._meta, Inferise.key)).?;
    try std.testing.expect(inferise.interject and !inferise.unpromptedTurns);
}

/// The agent side of the id-collision test: answers `ping` only after asking
/// the client something of its own, with the same request id.
const EchoFirst = struct {
    const Self = @This();

    connection: *Connection,

    fn onRequest(ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) AcpError!std.json.Value {
        _ = params;
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, method, "ping")) return error.MethodNotFound;
        // Both connections are fresh, so this request is id 1 — the same id
        // as the `ping` the client is still waiting on.
        const answer = try self.connection.request(struct { ok: bool }, "question", .{});
        defer answer.deinit();
        return std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"pong\":true}", .{}) catch error.OutOfMemory;
    }

    fn serve(connection: *Connection, failure: *?AcpError) void {
        connection.serve() catch |err| {
            failure.* = err;
        };
    }
};

/// The client side: answers the agent's `question`.
fn answerQuestion(ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) AcpError!std.json.Value {
    _ = ctx;
    _ = params;
    if (!std.mem.eql(u8, method, "question")) return error.MethodNotFound;
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"ok\":true}", .{}) catch error.OutOfMemory;
}

test "a peer's request that shares our pending id is served, not taken for the answer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const pair = try FrameTransport.init(allocator, io);
    defer pair.deinit();

    var agent = Connection.init(allocator, pair.agentTransport());
    var echo = EchoFirst{ .connection = &agent };
    agent.setRequestHandler(.{ .ptr = &echo, .vtable = &.{ .handle = EchoFirst.onRequest } });

    var client = Connection.init(allocator, pair.clientTransport());
    var unused: u8 = 0;
    client.setRequestHandler(.{ .ptr = &unused, .vtable = &.{ .handle = answerQuestion } });

    var failure: ?AcpError = null;
    var serving: std.Io.Group = .init;
    try serving.concurrent(io, EchoFirst.serve, .{ &agent, &failure });

    const answer = try client.request(struct { pong: bool }, "ping", .{});
    defer answer.deinit();
    try std.testing.expect(answer.value.pong);

    pair.close();
    try serving.await(io);
    if (failure) |err| try std.testing.expectEqual(error.TransportClosed, err);
}
