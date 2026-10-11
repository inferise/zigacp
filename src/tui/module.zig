//! The `acp-tui` barrel: a terminal UI for one ACP agent, on `zigtui`.
//!
//! zigacp's protocol module never imports a UI; this module does, and only a
//! consumer that asks for `acp-tui` compiles `zigtui` and `zigvaxis`. It holds
//! what draws an ACP conversation — `Conversation` folds an agent's
//! `session/update`s, `ConversationView` draws them, `ChatPane` scrolls one
//! for a screen — and the single-agent screen built from them.

const std = @import("std");
const builtin = @import("builtin");

pub const is_debug = builtin.mode == .debug;

/// The protocol, for the types a conversation folds.
pub const acp = @import("zigacp");
/// The terminal toolkit, which re-exports every `zigvaxis` declaration.
pub const zigtui = @import("zigtui");

// -----------------------------------------------------------------------------
// Conversation

pub const Conversation = @import("conversation.zig").Conversation;
pub const ConversationItem = @import("conversation.zig").ConversationItem;
pub const ConversationRole = @import("conversation.zig").ConversationRole;
pub const ToolItem = @import("conversation.zig").ToolItem;
pub const PlanStep = @import("conversation.zig").PlanStep;
pub const ConversationView = @import("conversation_view.zig").ConversationView;

// -----------------------------------------------------------------------------
// The screen

/// One agent's conversation as a pane: folded from its client's record, scrolled, drawn.
pub const ChatPane = @import("chat_pane.zig").ChatPane;
/// Where a pane's scroll lands.
pub const ScrollTarget = @import("chat_pane.zig").ScrollTarget;
/// The terminal screen for one ACP agent: conversation, prompt, and what the agent advertised.
pub const AgentChat = @import("agent_chat.zig").AgentChat;
/// What a harness executable does once its own flags are handled: the screen, or ACP on stdio.
pub const AgentMain = @import("agent_main.zig").AgentMain;
/// What a launch should do, decided from the arguments and which ends are terminals.
pub const Launch = @import("agent_main.zig").Launch;

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
}
