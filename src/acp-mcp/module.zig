//! MCP logic above the protocol.
//!
//! ACP carries MCP servers as wire types — `McpServerConfig` and its stdio,
//! HTTP and SSE shapes live in `acp-schema`, because they are part of the ACP
//! spec. Everything an agent or client *does* with those servers lives here,
//! so the schema stays a pure description of the wire.

const std = @import("std");

pub const schema = @import("acp-schema");

pub const mcp_server = @import("mcp_server.zig");
pub const McpServer = mcp_server.McpServer;

pub const McpHttpServer = @import("mcp_http_server.zig").McpHttpServer;
pub const McpToolHost = @import("mcp_http_server.zig").McpToolHost;
pub const McpToolOutcome = @import("mcp_http_server.zig").McpToolOutcome;
pub const ToolDefinition = @import("mcp_http_server.zig").ToolDefinition;
pub const ServerInfo = @import("mcp_http_server.zig").ServerInfo;
pub const RelayTools = @import("relay_tools.zig").RelayTools;

test {
    std.testing.refAllDecls(@This());
}
