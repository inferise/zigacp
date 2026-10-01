//! A command the agent accepts in a prompt, such as `/compact`.

const std = @import("std");
const log = std.log.scoped(.acp_schema_available_command);
const mod = @import("module.zig");

/// One command the agent advertises.
pub const AvailableCommand = struct {
    const Self = @This();

    name: []const u8,
    description: []const u8,
    /// The command's input hint, passed through untouched; its shape is still moving upstream.
    input: ?mod.RawValue = null,

    /// Reports whether the command takes input after its name.
    ///
    /// Parameters:
    /// - `self`: the command.
    ///
    /// Return: true when the agent sent an input hint.
    pub fn takesInput(self: *const Self) bool {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return self.input != null;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "a command with an input hint keeps it untouched" {
    const src =
        \\{"name":"review","description":"Review a change","input":{"hint":"a branch"}}
    ;
    const parsed = try std.json.parseFromSlice(AvailableCommand, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.takesInput());
    try std.testing.expectEqualStrings("a branch", parsed.value.input.?.value.object.get("hint").?.string);
}
