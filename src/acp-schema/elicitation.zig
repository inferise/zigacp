//! Elicitation: an agent asks the person, through the client, for structured input.
//!
//! Stable since ACP schema 1.21. An agent sends `elicitation/create` only to a
//! client that advertised `clientCapabilities.elicitation` for the mode it
//! uses: a form (`requestedSchema`, a JSON Schema of the fields) or a URL to
//! open (`url`, closed later by `elicitation/complete`). A form or URL request
//! is tied to a session (`sessionId`, optionally a `toolCallId`), or to a
//! request outside one (`requestId`, during sign-in, say).
//!
//! The request is one flat struct: its fields are the union of the modes' and
//! the scopes', and the ones a mode does not use are left out on the wire.

const std = @import("std");
const log = std.log.scoped(.acp_schema_elicitation);
const mod = @import("module.zig");

/// `elicitation/create`: agent → client request.
pub const method_elicitation_create: []const u8 = "elicitation/create";
/// `elicitation/complete`: agent → client notification closing a URL elicitation.
pub const method_elicitation_complete: []const u8 = "elicitation/complete";

/// What the person did with an elicitation.
pub const ElicitationAction = enum {
    /// Answered; `content` holds the form's fields.
    accept,
    /// Said no.
    decline,
    /// Dismissed it without deciding.
    cancel,
    /// An action this build does not know.
    other,

    pub fn jsonStringify(self: ElicitationAction, jw: anytype) !void {
        try jw.write(@tagName(self));
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ElicitationAction {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer switch (token) {
            .allocated_number, .allocated_string => |s| allocator.free(s),
            else => {},
        };
        const slice = switch (token) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return std.meta.stringToEnum(ElicitationAction, slice) orelse .other;
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !ElicitationAction {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(ElicitationAction, source.string) orelse .other;
    }
};

/// `elicitation/create`'s params, every mode's and scope's fields in one struct.
pub const CreateElicitationRequest = struct {
    /// `form` or `url`; anything else is a custom mode, `_`-prefixed.
    mode: []const u8,
    /// What the person is asked, as they read it.
    message: []const u8,
    /// Session scope: the session it belongs to.
    sessionId: ?mod.agent.SessionId = null,
    /// Session scope: the tool call it concerns, when there is one.
    toolCallId: ?mod.ToolCallId = null,
    /// Request scope: the request it belongs to, outside any session.
    requestId: ?mod.RequestId = null,
    /// Form mode: a JSON Schema of the fields.
    requestedSchema: ?mod.RawValue = null,
    /// URL mode: names the elicitation for `elicitation/complete`.
    elicitationId: ?[]const u8 = null,
    /// URL mode: the page to open.
    url: ?[]const u8 = null,
    _meta: ?mod.RawValue = null,
};

/// `elicitation/create`'s answer.
pub const CreateElicitationResponse = struct {
    action: ElicitationAction,
    /// The form's fields, by name, when the person accepted a form.
    content: ?mod.RawValue = null,
    _meta: ?mod.RawValue = null,
};

/// `elicitation/complete`'s params: a URL elicitation is over.
pub const CompleteElicitationNotification = struct {
    elicitationId: []const u8,
    _meta: ?mod.RawValue = null,
};

/// `clientCapabilities.elicitation`: the modes a client renders. A mode present is a mode offered.
pub const ElicitationCapabilities = struct {
    form: ?ElicitationModeCapabilities = null,
    url: ?ElicitationModeCapabilities = null,
    _meta: ?mod.RawValue = null,
};

/// One elicitation mode's capability marker: `{}` offers it.
pub const ElicitationModeCapabilities = struct {
    _meta: ?mod.RawValue = null,
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    log.debug("elicitation types referenced", .{});
}

test "a form elicitation round-trips with its schema and session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\{"mode":"form","message":"Which colour?","sessionId":"s-1","requestedSchema":{"type":"object","properties":{"answer":{"type":"string","enum":["red","blue"]}}}}
    ;
    const parsed = try std.json.parseFromSliceLeaky(CreateElicitationRequest, arena, src, .{});
    try std.testing.expectEqualStrings("form", parsed.mode);
    try std.testing.expectEqualStrings("s-1", parsed.sessionId.?.value);
    try std.testing.expect(parsed.url == null);
    const back = try std.json.Stringify.valueAlloc(arena, parsed, .{ .emit_null_optional_fields = false });
    try std.testing.expect(std.mem.find(u8, back, "\"url\"") == null);
    try std.testing.expect(std.mem.find(u8, back, "\"enum\":[\"red\",\"blue\"]") != null);
}

test "an answer's action reads, an unknown one included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const accepted = try std.json.parseFromSliceLeaky(CreateElicitationResponse, arena, "{\"action\":\"accept\",\"content\":{\"answer\":\"blue\"}}", .{});
    try std.testing.expectEqual(ElicitationAction.accept, accepted.action);
    try std.testing.expectEqualStrings("blue", accepted.content.?.value.object.get("answer").?.string);
    const declined = try std.json.parseFromSliceLeaky(CreateElicitationResponse, arena, "{\"action\":\"decline\"}", .{});
    try std.testing.expect(declined.content == null);
    const odd = try std.json.parseFromSliceLeaky(CreateElicitationResponse, arena, "{\"action\":\"_snooze\"}", .{});
    try std.testing.expectEqual(ElicitationAction.other, odd.action);
}
