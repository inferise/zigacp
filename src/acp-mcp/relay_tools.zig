//! The tools a relay offers its agent, as MCP describes them.
//!
//! An agent cannot start a conversation with its host — the host asks, the
//! agent answers. These tools are that way in: an agent calls them like any
//! other MCP tool, and the relay turns each call into ACP's own message to the
//! host, a `notice` update for `report_progress` and an `elicitation/create`
//! form for `ask_user`, each only when the host advertised it. A host that
//! offers tools of its own lists them beside these.

const std = @import("std");
const log = std.log.scoped(.acp_mcp_relay_tools);
const mod = @import("module.zig");

/// The relay's tool table and the names a call is matched by.
pub const RelayTools = struct {
    const Self = @This();

    /// Progress and confidence, reported by the agent itself.
    pub const report_progress = "report_progress";
    /// A question put to the person, answered through the host.
    pub const ask_user = "ask_user";

    /// The relay's tools, in the order `tools/list` lists them.
    pub const table = [_]mod.ToolDefinition{
        .{
            .name = report_progress,
            .description = "Report how far along the current task is and how confident you are that the plan will work. Call it when you finish a step or your confidence changes.",
            .input_schema =
            \\{"type":"object","properties":{"summary":{"type":"string","description":"One sentence: what is done and what comes next."},"percentComplete":{"type":"number","minimum":0,"maximum":100,"description":"How much of the task is done."},"confidence":{"type":"number","minimum":0,"maximum":100,"description":"How confident you are that the plan will succeed."}},"required":["summary"]}
            ,
        },
        .{
            .name = ask_user,
            .description = "Ask the person a question and wait for their answer. Offer options when the answer is one of a few choices.",
            .input_schema =
            \\{"type":"object","properties":{"question":{"type":"string","description":"The question, as the person will read it."},"options":{"type":"array","items":{"type":"string"},"description":"Answers to choose between, when there are only a few."}},"required":["question"]}
            ,
        },
    };

    /// Reports whether a call names one of the relay's tools.
    ///
    /// Parameters:
    /// - `name`: the tool a call named.
    ///
    /// Return: true for `report_progress` and `ask_user`.
    pub fn owns(name: []const u8) bool {
        for (table) |definition| if (std.mem.eql(u8, definition.name, name)) return true;
        return false;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RelayTools);
}

test "every relay tool is listed once, with a schema that parses" {
    for (RelayTools.table, 0..) |definition, index| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, definition.input_schema, .{});
        defer parsed.deinit();
        for (RelayTools.table[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, other.name, definition.name));
        try std.testing.expect(RelayTools.owns(definition.name));
    }
    try std.testing.expect(!RelayTools.owns("spawn_subagent"));
    log.debug("relay tools checked", .{});
}
