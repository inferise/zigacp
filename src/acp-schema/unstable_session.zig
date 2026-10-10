//! Unstable Client → Agent session methods.
//!
//! Each method is gated behind its own build flag — the wire shape
//! upstream is still in flux and shouldn't appear in the stable
//! public surface. `session/fork` is still a draft; `session/set_model`
//! was dropped from ACP in favour of a `model` config option, and stays
//! here only for a peer that still sends it. `logout`, `session/resume`
//! and `session/close` were stabilized and live in `agent.zig`. The `types` namespace expands to an empty struct
//! when its flag is off, so disabled methods add no symbols.

const std = @import("std");
const build_options = @import("build_options");
const SessionId = @import("agent.zig").SessionId;

// ---------------------------------------------------------------------------
// session/fork — gated by unstable_session_fork
// ---------------------------------------------------------------------------

pub const fork_enabled = build_options.unstable_session_fork;

const fork_impl = struct {
    pub const method_session_fork: []const u8 = "session/fork";
    pub const ForkSessionRequest = struct {
        sessionId: SessionId,
    };
    pub const ForkSessionResponse = struct {
        sessionId: SessionId,
    };
};

pub const fork = if (fork_enabled) fork_impl else struct {};

// ---------------------------------------------------------------------------
// session/set_model — gated by unstable_session_model
// ---------------------------------------------------------------------------

pub const set_model_enabled = build_options.unstable_session_model;

const set_model_impl = struct {
    pub const method_session_set_model: []const u8 = "session/set_model";
    pub const SetModelRequest = struct {
        sessionId: SessionId,
        modelId: []const u8,
    };
    pub const SetModelResponse = struct {};
};

pub const set_model = if (set_model_enabled) set_model_impl else struct {};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ForkSessionRequest round-trip when enabled" {
    if (!fork_enabled) return error.SkipZigTest;
    const src = "{\"sessionId\":\"s1\"}";
    const parsed = try std.json.parseFromSlice(fork.ForkSessionRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("s1", parsed.value.sessionId.value);
}

test "SetModelRequest round-trip when enabled" {
    if (!set_model_enabled) return error.SkipZigTest;
    const src = "{\"sessionId\":\"s1\",\"modelId\":\"opus-4\"}";
    const parsed = try std.json.parseFromSlice(set_model.SetModelRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("opus-4", parsed.value.modelId);
}
