//! The modes an agent can run a session in, such as "plan" or "accept edits".

const std = @import("std");
const log = std.log.scoped(.acp_schema_session_mode_state);
const mod = @import("module.zig");

/// One mode a session can run in.
pub const SessionMode = struct {
    const Self = @This();

    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

/// The modes a session offers and the one it is in.
pub const SessionModeState = struct {
    const Self = @This();

    current_mode_id: []const u8,
    available_modes: []const SessionMode,

    /// Returns the mode the session is in.
    ///
    /// Parameters:
    /// - `self`: the state.
    ///
    /// Return: the current mode, or null when `current_mode_id` names none of `available_modes`.
    pub fn current(self: *const Self) ?SessionMode {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        for (self.available_modes) |mode| {
            if (std.mem.eql(u8, mode.id, self.current_mode_id)) return mode;
        }
        return null;
    }

    /// Writes the struct under its camelCase wire keys.
    ///
    /// Parameters:
    /// - `self`: the struct.
    /// - `jw`: the JSON writer.
    ///
    /// Return: nothing; propagates the writer's failure.
    pub fn jsonStringify(self: *const Self, jw: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try mod.WireCase.stringify(Self, self, jw);
    }

    /// Parses the struct from a token stream keyed by wire names.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the token stream.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the struct; propagates a parse failure.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return mod.WireCase.parse(Self, allocator, source, options);
    }

    /// Parses the struct from a JSON value keyed by wire names.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the JSON value.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the struct; propagates a parse failure.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return mod.WireCase.parseFromValue(Self, allocator, source, options);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "the current mode resolves against those on offer" {
    const src =
        \\{"currentModeId":"plan","availableModes":[{"id":"default","name":"Default"},{"id":"plan","name":"Plan","description":"Read-only"}]}
    ;
    const parsed = try std.json.parseFromSlice(SessionModeState, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Read-only", parsed.value.current().?.description.?);
}

test "the mode state writes camelCase keys" {
    const modes = [_]SessionMode{.{ .id = "plan", .name = "Plan" }};
    const state: SessionModeState = .{ .current_mode_id = "plan", .available_modes = &modes };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, state, .{ .emit_null_optional_fields = false });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"currentModeId\":\"plan\",\"availableModes\":[{\"id\":\"plan\",\"name\":\"Plan\"}]}", out);
}
