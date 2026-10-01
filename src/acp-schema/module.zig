//! Public surface of the wire-format schema package.

const std = @import("std");

pub const build_options = @import("build_options");

pub const version = @import("version.zig");
pub const ProtocolVersion = version.ProtocolVersion;

pub const serde_util = @import("serde_util.zig");
pub const RawValue = serde_util.RawValue;

pub const rpc = @import("rpc.zig");
pub const RequestId = rpc.RequestId;
pub const Request = rpc.Request;
pub const Response = rpc.Response;
pub const ResponseError = rpc.ResponseError;
pub const Notification = rpc.Notification;
pub const JsonRpcMessage = rpc.JsonRpcMessage;
pub const JSONRPC_VERSION = rpc.JSONRPC_VERSION;

pub const @"error" = @import("error.zig");
pub const Error = @"error".Error;
pub const ErrorCode = @"error".Code;

pub const content = @import("content.zig");
pub const ContentBlock = content.ContentBlock;
pub const TextContent = content.TextContent;
pub const ImageContent = content.ImageContent;
pub const AudioContent = content.AudioContent;
pub const EmbeddedResource = content.EmbeddedResource;
pub const ResourceLink = content.ResourceLink;
pub const ResourceContents = content.ResourceContents;

pub const plan = @import("plan.zig");
pub const Plan = plan.Plan;
pub const PlanEntry = plan.PlanEntry;
pub const PlanEntryStatus = plan.PlanEntryStatus;
pub const Priority = plan.Priority;

pub const ext = @import("ext.zig");
pub const ExtRequest = ext.ExtRequest;
pub const ExtResponse = ext.ExtResponse;
pub const ExtNotification = ext.ExtNotification;

pub const tool_call = @import("tool_call.zig");
pub const ToolCall = tool_call.ToolCall;
pub const ToolCallId = tool_call.ToolCallId;
pub const ToolCallStatus = tool_call.ToolCallStatus;
pub const ToolKind = tool_call.ToolKind;
pub const ToolCallContent = tool_call.ToolCallContent;
pub const ToolCallLocation = tool_call.ToolCallLocation;
pub const ToolCallUpdate = tool_call.ToolCallUpdate;

pub const wire_case = @import("wire_case.zig");
pub const WireCase = wire_case.WireCase;

pub const mcp_server_config = @import("mcp_server_config.zig");
pub const McpServerConfig = mcp_server_config.McpServerConfig;
pub const McpServerStdio = mcp_server_config.McpServerStdio;
pub const McpServerRemote = mcp_server_config.McpServerRemote;
pub const McpEnv = mcp_server_config.McpEnv;

pub const session_mode_state = @import("session_mode_state.zig");
pub const SessionModeState = session_mode_state.SessionModeState;
pub const SessionMode = session_mode_state.SessionMode;

pub const session_config_option = @import("session_config_option.zig");
pub const SessionConfigOption = session_config_option.SessionConfigOption;
pub const SessionConfigSelect = session_config_option.SessionConfigSelect;
pub const SessionConfigSelectOptions = session_config_option.SessionConfigSelectOptions;
pub const SessionConfigSelectGroup = session_config_option.SessionConfigSelectGroup;
pub const SessionConfigSelectOption = session_config_option.SessionConfigSelectOption;

pub const available_command = @import("available_command.zig");
pub const AvailableCommand = available_command.AvailableCommand;

// Unstable: `usage_update.enabled` says whether `SessionUpdate` carries it.
pub const usage_update = @import("usage_update.zig");

pub const session_update = @import("session_update.zig");
pub const SessionUpdate = session_update.SessionUpdate;
pub const ContentChunk = session_update.ContentChunk;
pub const PlanWrapper = session_update.PlanWrapper;
pub const AvailableCommandsUpdate = session_update.AvailableCommandsUpdate;
pub const CurrentModeUpdate = session_update.CurrentModeUpdate;
pub const ConfigOptionUpdate = session_update.ConfigOptionUpdate;
pub const SessionInfoUpdate = session_update.SessionInfoUpdate;

pub const agent = @import("agent.zig");
pub const client = @import("client.zig");

pub const routing = @import("routing.zig");
pub const AgentRequest = routing.AgentRequest;
pub const AgentResponse = routing.AgentResponse;
pub const AgentNotification = routing.AgentNotification;
pub const ClientRequest = routing.ClientRequest;
pub const ClientResponse = routing.ClientResponse;
pub const ClientNotification = routing.ClientNotification;

pub const protocol_level = @import("protocol_level.zig");
pub const elicitation = @import("elicitation.zig");
pub const nes = @import("nes.zig");
pub const unstable_session = @import("unstable_session.zig");

test {
    std.testing.refAllDecls(@This());
}
