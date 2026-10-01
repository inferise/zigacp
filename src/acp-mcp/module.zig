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

test {
    std.testing.refAllDecls(@This());
}
