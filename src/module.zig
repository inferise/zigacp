//! The zigacp barrel: one namespace over `acp`, `acp-schema` and
//! `acp-async`.
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
//! that serves it — `acp.Agent` for `initialize` and `session/*`, `acp.Client`
//! for `fs/*`, `terminal/*` and `session/request_permission` — and the unstable
//! session/close under `acp.SessionClose`. `acp-test` and `acp-conductor`
//! are not re-exported: nothing downstream uses them.
//!
//! Beside the re-exports, the barrel holds shared implementations that sit
//! above the protocol: `acp.Client.Fs` serves the client's filesystem methods.
//!
//! Only what is consumed is listed. A new consumer adds the symbol here rather
//! than importing the underlying module beside the barrel.

const std = @import("std");
const acp = @import("acp");
const schema = @import("acp-schema");
const acp_async = @import("acp-async");

// -----------------------------------------------------------------------------
// Connection (acp)

pub const Connection = acp.Connection;
pub const Dispatcher = acp.Dispatcher;
pub const RequestHandler = acp.RequestHandler;
pub const NotificationHandler = acp.NotificationHandler;
pub const AcpError = acp.AcpError;

// -----------------------------------------------------------------------------
// Transports (acp, acp-async)

/// The interface every transport implements; a `Connection` takes one.
pub const Transport = acp.Transport;
pub const Frame = acp.Frame;
/// An in-process pair whose reads block until a frame arrives.
pub const FrameTransport = acp_async.FrameTransport;

// -----------------------------------------------------------------------------
// Shared schema (acp-schema)

pub const ProtocolVersion = schema.ProtocolVersion;
pub const ContentBlock = schema.ContentBlock;
pub const PlanEntry = schema.PlanEntry;
pub const ToolKind = schema.ToolKind;
pub const ToolCallStatus = schema.ToolCallStatus;
pub const ToolCallUpdate = schema.ToolCallUpdate;

// -----------------------------------------------------------------------------
// Agent methods: client → agent (acp-schema `agent`)

/// What an agent serves: its methods and their request and response types.
pub const Agent = struct {
    pub const method_initialize = schema.agent.method_initialize;
    pub const method_session_new = schema.agent.method_session_new;
    pub const method_session_load = schema.agent.method_session_load;
    pub const method_session_list = schema.agent.method_session_list;
    pub const method_session_prompt = schema.agent.method_session_prompt;
    pub const method_session_cancel = schema.agent.method_session_cancel;
    pub const method_session_update = schema.agent.method_session_update;

    pub const InitializeRequest = schema.agent.InitializeRequest;
    pub const InitializeResponse = schema.agent.InitializeResponse;
    pub const NewSessionRequest = schema.agent.NewSessionRequest;
    pub const NewSessionResponse = schema.agent.NewSessionResponse;
    pub const LoadSessionRequest = schema.agent.LoadSessionRequest;
    pub const LoadSessionResponse = schema.agent.LoadSessionResponse;
    pub const ListSessionsRequest = schema.agent.ListSessionsRequest;
    pub const ListSessionsResponse = schema.agent.ListSessionsResponse;
    pub const PromptRequest = schema.agent.PromptRequest;
    pub const CancelNotification = schema.agent.CancelNotification;
    pub const SessionNotification = schema.agent.SessionNotification;
    pub const SessionUpdate = schema.agent.SessionUpdate;
    pub const SessionId = schema.agent.SessionId;
    pub const SessionInfo = schema.agent.SessionInfo;
    pub const StopReason = schema.agent.StopReason;
    pub const McpServerConfig = schema.agent.McpServerConfig;
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

    /// Serves `fs/read_text_file` and `fs/write_text_file` on a client's dispatcher.
    pub const Fs = @import("client_fs.zig").ClientFs;
};

// -----------------------------------------------------------------------------
// Unstable: session/close (acp-schema `unstable_session.close`)
//
// Present only when built with `-Dunstable_session_close=true`; otherwise
// `unstable_session.close` is an empty struct and a reference to any of these
// is a compile error at the use site, which is where it belongs.

/// session/close, which ACP's stable surface does not yet have.
pub const SessionClose = struct {
    pub const method_session_close = schema.unstable_session.close.method_session_close;
    pub const CloseSessionRequest = schema.unstable_session.close.CloseSessionRequest;
    pub const CloseSessionResponse = schema.unstable_session.close.CloseSessionResponse;
};

// -----------------------------------------------------------------------------
// Unit Tests

// `refAllDecls` stops at a namespace's own decls, so the three groups are
// walked explicitly. `SessionClose` does not resolve in a build without the
// flag — zigacp's own default — so it is walked only when the flag is on.
test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Agent);
    std.testing.refAllDecls(Client);
    if (schema.unstable_session.close_enabled) std.testing.refAllDecls(SessionClose);
}
