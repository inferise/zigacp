//! Draws a `Conversation`: who said what, each tool call a line.
//!
//! ```
//! You
//!   list the files
//!
//!   · Looking around.
//!
//!   ⚙ ls -la  ✓
//!
//! Claude
//!   One file.
//! ```
//!
//! A tool call is one line — its title and a status mark — until `expanded`,
//! when its input, its output and the files it changed follow, indented. The
//! drawing is `TranscriptView`'s: this only says what each entry is.

const std = @import("std");
const log = std.log.scoped(.acp_tui_conversation_view);
const mod = @import("module.zig");

/// A conversation as entries a `TranscriptView` draws.
///
/// No event handler: the owner decides when to expand, and keeps the
/// conversation for as long as the frame draws it.
pub const ConversationView = struct {
    const Self = @This();

    /// Most of a tool's input or output shown when expanded; longer is cut with `…`.
    pub const max_detail = 2000;

    conversation: *const mod.Conversation,
    /// The heading over the person's messages.
    person: []const u8 = "You",
    /// The heading over the agent's.
    agent: []const u8 = "Agent",
    /// Show each tool call's input, output and changed files.
    expanded: bool = false,

    /// The conversation's entries, in order.
    ///
    /// Parameters:
    /// - `self`: the view.
    /// - `arena`: owns the entries; their text is borrowed from the conversation where it is not built here.
    ///
    /// Return: the entries; propagates allocation failure.
    pub fn entries(self: *const Self, arena: std.mem.Allocator) std.mem.Allocator.Error![]const mod.zigtui.TranscriptEntry {
        var out: std.ArrayList(mod.zigtui.TranscriptEntry) = .empty;
        for (self.conversation.items.items) |item| switch (item) {
            .message => |message| try out.append(arena, .{
                .heading = if (message.role == .person) self.person else self.agent,
                .heading_role = if (message.role == .person) .keyHint else .titleText,
                .text = std.mem.trim(u8, message.text, "\n"),
            }),
            .thought => |text| try out.append(arena, .{ .text = try std.fmt.allocPrint(arena, "· {s}", .{std.mem.trim(u8, text, " \n")}), .role = .secondaryText }),
            .tool => |tool| try out.append(arena, .{ .text = try self.toolText(arena, tool), .role = toolRole(tool.status) }),
            .note => |text| try out.append(arena, .{ .text = text, .role = .secondaryText }),
            .plan => |steps| {
                var text: std.ArrayList(u8) = .empty;
                for (steps, 0..) |step, index| {
                    if (index > 0) try text.append(arena, '\n');
                    try text.print(arena, "{s} {s}", .{ planMark(step.status), step.content });
                }
                try out.append(arena, .{ .heading = "Plan", .heading_role = .subtitleText, .text = text.items, .role = .secondaryText });
            },
        };
        return out.items;
    }

    /// The view as a widget, drawn by `TranscriptView` over the entries.
    ///
    /// Parameters:
    /// - `self`: the view.
    /// - `arena`: the frame arena; owns the entries and the transcript.
    ///
    /// Return: the widget, with no event handler; propagates allocation failure.
    pub fn widget(self: *const Self, arena: std.mem.Allocator) std.mem.Allocator.Error!mod.zigtui.Widget {
        const view = try arena.create(mod.zigtui.TranscriptView);
        view.* = .{ .entries = try self.entries(arena) };
        return view.widget();
    }

    /// A tool call's line, and its details when expanded.
    ///
    /// Parameters:
    /// - `self`: the view.
    /// - `arena`: owns the text.
    /// - `tool`: the call.
    ///
    /// Return: the text; propagates allocation failure.
    fn toolText(self: *const Self, arena: std.mem.Allocator, tool: mod.ToolItem) std.mem.Allocator.Error![]const u8 {
        var text: std.ArrayList(u8) = .empty;
        try text.print(arena, "⚙ {s}  {s}", .{ tool.title, statusMark(tool.status) });
        if (!self.expanded) return text.items;
        if (tool.input.len > 0) try text.print(arena, "\n  in:  {s}", .{cut(tool.input)});
        if (tool.output.len > 0) try text.print(arena, "\n  out: {s}", .{cut(std.mem.trim(u8, tool.output, "\n"))});
        for (tool.diffs) |path| try text.print(arena, "\n  ± {s}", .{path});
        return text.items;
    }

    /// Text kept to `max_detail` bytes, cut at a character boundary.
    ///
    /// Parameters:
    /// - `text`: the text.
    ///
    /// Return: the text or its head; the caller appends nothing for the cut, as `TranscriptView` wraps it.
    fn cut(text: []const u8) []const u8 {
        if (text.len <= max_detail) return text;
        var end: usize = max_detail;
        while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
        return text[0..end];
    }

    /// A tool call's status as one mark.
    ///
    /// Parameters:
    /// - `status`: the status.
    ///
    /// Return: the mark.
    fn statusMark(status: mod.acp.ToolCallStatus) []const u8 {
        return switch (status) {
            .pending => "…",
            .in_progress => "●",
            .completed => "✓",
            .failed => "✗",
        };
    }

    /// The role a tool call's line is drawn in.
    ///
    /// Parameters:
    /// - `status`: the call's status.
    ///
    /// Return: the theme role.
    fn toolRole(status: mod.acp.ToolCallStatus) mod.zigtui.Theme {
        return switch (status) {
            .failed => .errorText,
            .completed => .secondaryText,
            .pending, .in_progress => .primaryText,
        };
    }

    /// A plan step's status as one mark.
    ///
    /// Parameters:
    /// - `status`: the step's status.
    ///
    /// Return: the mark.
    fn planMark(status: @FieldType(mod.acp.PlanEntry, "status")) []const u8 {
        return switch (status) {
            .pending => "☐",
            .in_progress => "◐",
            .completed => "☑",
        };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ConversationView);
    // The logger ZIGSTYLE asks every file for; this file has nothing to log.
    _ = log;
}

test "a conversation reads as who said what, each tool call one line until expanded" {
    var conversation = mod.Conversation.init(std.testing.allocator);
    defer conversation.deinit();
    const updates = [_][]const u8{
        \\{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"list the files"}}
        ,
        \\{"sessionUpdate":"tool_call","toolCallId":"t1","title":"ls -la","status":"completed","rawInput":{"command":"ls"},"rawOutput":"a.txt\n"}
        ,
        \\{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"One file."}}
        ,
        \\{"sessionUpdate":"plan","entries":[{"content":"answer","status":"in_progress","priority":"medium"}]}
    };
    for (updates) |update| try conversation.applyJson(update);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var view = ConversationView{ .conversation = &conversation, .agent = "Claude" };
    const collapsed = try view.entries(arena);
    try std.testing.expectEqual(@as(usize, 4), collapsed.len);
    try std.testing.expectEqualStrings("You", collapsed[0].heading);
    try std.testing.expectEqualStrings("⚙ ls -la  ✓", collapsed[1].text);
    try std.testing.expectEqualStrings("Claude", collapsed[2].heading);
    try std.testing.expectEqualStrings("One file.", collapsed[2].text);
    try std.testing.expectEqualStrings("◐ answer", collapsed[3].text);

    view.expanded = true;
    const open = try view.entries(arena);
    try std.testing.expectEqualStrings("⚙ ls -la  ✓\n  in:  {\"command\":\"ls\"}\n  out: a.txt", open[1].text);

    // It draws as a transcript does.
    _ = try view.widget(arena);
}
