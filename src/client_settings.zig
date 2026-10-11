//! What a session can be switched between: its modes and its config options.
//!
//! An agent reports both when a session opens or reopens — `modes` and
//! `configOptions` — and again whenever they change (`current_mode_update`,
//! `config_option_update`, a `session/set_config_option` reply). This keeps the
//! latest of each, copied, so a front end can list them and the client can tell
//! a choice the agent offers from one it does not. The `model` select is also
//! kept apart (`models`), which is the one the terminal UI's picker switches;
//! the web console offers every option, selects and booleans alike.

const std = @import("std");
const log = std.log.scoped(.acp_client_settings);
const acp = @import("module.zig");

/// One choice: what goes on the wire, and what a person reads.
pub const SettingsChoice = struct {
    const Self = @This();

    /// The mode id or model value.
    id: []const u8,
    name: []const u8,
};

/// One config option as last reported: a select's choices, or a boolean's value.
pub const SettingsOption = struct {
    const Self = @This();

    id: []const u8,
    name: []const u8,
    description: []const u8 = "",
    /// True for a boolean option; its value is `enabled`. False for a select; its value is `current`.
    is_boolean: bool = false,
    /// A select's current value.
    current: []const u8 = "",
    /// A boolean's current value.
    enabled: bool = false,
    /// A select's choices, groups flattened.
    choices: []const SettingsChoice = &.{},
};

/// A session's modes and config options, as last reported. Every slice is owned by `arena`.
pub const ClientSettings = struct {
    const Self = @This();

    /// The category ACP gives a model select.
    pub const model_category = "model";

    arena: std.heap.ArenaAllocator,
    modes: []const SettingsChoice = &.{},
    /// The current mode's id, or empty when the agent has no modes.
    current_mode: []const u8 = "",
    /// The model select's config id, or empty when the agent offers no model choice.
    model_option: []const u8 = "",
    models: []const SettingsChoice = &.{},
    /// The current model's value, or empty when there is no model choice.
    current_model: []const u8 = "",
    /// Every config option the agent offers, the model select among them, in its order.
    options: []const SettingsOption = &.{},

    /// Creates empty settings.
    ///
    /// Parameters:
    /// - `allocator`: backs every copy.
    ///
    /// Return: the settings; caller calls `deinit`.
    pub fn init(allocator: std.mem.Allocator) acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return Self{ .arena = .init(allocator) };
    }

    /// Releases every copy.
    ///
    /// Parameters:
    /// - `self`: the settings.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.arena.deinit();
    }

    /// Replaces everything with what a session reported on opening.
    ///
    /// Parameters:
    /// - `self`: the settings.
    /// - `modes`: the session's modes, or null when it has none.
    /// - `options`: its config options, or null when it has none.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn replace(self: *Self, modes: ?acp.Agent.SessionModeState, options: ?[]const acp.Agent.SessionConfigOption) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        _ = self.arena.reset(.retain_capacity);
        self.* = .{ .arena = self.arena };
        if (modes) |state| {
            const arena = self.arena.allocator();
            const list = try arena.alloc(SettingsChoice, state.available_modes.len);
            for (state.available_modes, list) |mode, *choice| choice.* = .{ .id = try arena.dupe(u8, mode.id), .name = try arena.dupe(u8, mode.name) };
            self.modes = list;
            self.current_mode = try arena.dupe(u8, state.current_mode_id);
        }
        if (options) |list| try self.takeOptions(list);
    }

    /// Takes a changed set of config options, keeping the modes.
    ///
    /// Parameters:
    /// - `self`: the settings.
    /// - `options`: every option after the change.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn takeOptions(self: *Self, options: []const acp.Agent.SessionConfigOption) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // The arena only grows here; a session changes its options a handful of times.
        const arena = self.arena.allocator();
        var kept: std.ArrayList(SettingsOption) = .empty;
        var model_found = false;
        for (options) |option| switch (option) {
            .boolean => |boolean| try kept.append(arena, .{
                .id = try arena.dupe(u8, boolean.id),
                .name = try arena.dupe(u8, boolean.name),
                .description = try arena.dupe(u8, boolean.description orelse ""),
                .is_boolean = true,
                .enabled = boolean.current_value,
            }),
            .select => |select| {
                var list: std.ArrayList(SettingsChoice) = .empty;
                switch (select.options) {
                    .ungrouped => |values| for (values) |value| try list.append(arena, .{ .id = try arena.dupe(u8, value.value), .name = try arena.dupe(u8, value.name) }),
                    .grouped => |groups| for (groups) |group| for (group.options) |value| try list.append(arena, .{ .id = try arena.dupe(u8, value.value), .name = try arena.dupe(u8, value.name) }),
                }
                const kept_option = SettingsOption{
                    .id = try arena.dupe(u8, select.id),
                    .name = try arena.dupe(u8, select.name),
                    .description = try arena.dupe(u8, select.description orelse ""),
                    .current = try arena.dupe(u8, select.current_value),
                    .choices = list.items,
                };
                try kept.append(arena, kept_option);

                const is_model = if (select.category) |category| std.mem.eql(u8, category, model_category) else std.mem.eql(u8, select.id, model_category);
                if (is_model and !model_found) {
                    model_found = true;
                    self.model_option = kept_option.id;
                    self.models = kept_option.choices;
                    self.current_model = kept_option.current;
                }
            },
            // An option of a type this build does not know cannot be offered.
            .unknown => {},
        };
        self.options = kept.items;
    }

    /// Records a mode change.
    ///
    /// Parameters:
    /// - `self`: the settings.
    /// - `mode_id`: the mode now current.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn takeMode(self: *Self, mode_id: []const u8) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.current_mode = try self.arena.allocator().dupe(u8, mode_id);
    }

    /// Reports whether a mode is one the session offers.
    ///
    /// Parameters:
    /// - `self`: the settings.
    /// - `mode_id`: the candidate.
    ///
    /// Return: true when offered.
    pub fn offersMode(self: *const Self, mode_id: []const u8) bool {
        for (self.modes) |mode| if (std.mem.eql(u8, mode.id, mode_id)) return true;
        return false;
    }

    /// Reports whether a model is one the session offers.
    ///
    /// Parameters:
    /// - `self`: the settings.
    /// - `value`: the candidate.
    ///
    /// Return: true when offered.
    pub fn offersModel(self: *const Self, value: []const u8) bool {
        for (self.models) |model| if (std.mem.eql(u8, model.id, value)) return true;
        return false;
    }

    /// Finds a config option the session offers.
    ///
    /// Parameters:
    /// - `self`: the settings.
    /// - `id`: the option's id.
    ///
    /// Return: the option, borrowed; null when the session offers none by that id.
    pub fn findOption(self: *const Self, id: []const u8) ?SettingsOption {
        for (self.options) |option| if (std.mem.eql(u8, option.id, id)) return option;
        return null;
    }

    /// The name a person reads for a choice.
    ///
    /// Parameters:
    /// - `choices`: the modes or the models.
    /// - `id`: the choice's id.
    ///
    /// Return: its name, or `id` itself when it is not listed.
    pub fn nameOf(choices: []const SettingsChoice, id: []const u8) []const u8 {
        for (choices) |choice| if (std.mem.eql(u8, choice.id, id)) return choice.name;
        return id;
    }

    /// Copies the settings for a reader that must not hold the client's lock.
    ///
    /// Parameters:
    /// - `self`: the settings.
    /// - `allocator`: owns the copy; an arena in practice.
    ///
    /// Return: the copy, whose `arena` is unused; propagates allocation failure.
    pub fn copy(self: *const Self, allocator: std.mem.Allocator) acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var out = Self{ .arena = .init(allocator) };
        out.modes = try copyChoices(allocator, self.modes);
        out.current_mode = try allocator.dupe(u8, self.current_mode);
        out.model_option = try allocator.dupe(u8, self.model_option);
        out.models = try copyChoices(allocator, self.models);
        out.current_model = try allocator.dupe(u8, self.current_model);
        const options = try allocator.alloc(SettingsOption, self.options.len);
        for (self.options, options) |option, *copied| copied.* = .{
            .id = try allocator.dupe(u8, option.id),
            .name = try allocator.dupe(u8, option.name),
            .description = try allocator.dupe(u8, option.description),
            .is_boolean = option.is_boolean,
            .current = try allocator.dupe(u8, option.current),
            .enabled = option.enabled,
            .choices = try copyChoices(allocator, option.choices),
        };
        out.options = options;
        return out;
    }

    /// Copies a list of choices.
    ///
    /// Parameters:
    /// - `allocator`: owns the copy.
    /// - `choices`: the list.
    ///
    /// Return: the copy; propagates allocation failure.
    fn copyChoices(allocator: std.mem.Allocator, choices: []const SettingsChoice) ![]const SettingsChoice {
        const list = try allocator.alloc(SettingsChoice, choices.len);
        for (choices, list) |choice, *out| out.* = .{ .id = try allocator.dupe(u8, choice.id), .name = try allocator.dupe(u8, choice.name) };
        return list;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ClientSettings);
}

test "a session's modes, its model select, and every other option are kept" {
    const allocator = std.testing.allocator;
    const opened = try std.json.parseFromSlice(acp.Agent.NewSessionResponse, allocator,
        \\{"sessionId":"s","modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Ask"},{"id":"plan","name":"Plan"}]},
        \\ "configOptions":[{"type":"boolean","id":"fast","name":"Fast","currentValue":true},
        \\  {"type":"select","id":"model","name":"Model","category":"model","currentValue":"sonnet","options":[{"value":"sonnet","name":"Sonnet"},{"value":"opus","name":"Opus"}]}]}
    , .{});
    defer opened.deinit();

    var settings = try ClientSettings.init(allocator);
    defer settings.deinit();
    try settings.replace(opened.value.modes, opened.value.config_options);

    try std.testing.expectEqual(@as(usize, 2), settings.modes.len);
    try std.testing.expectEqualStrings("default", settings.current_mode);
    try std.testing.expect(settings.offersMode("plan") and !settings.offersMode("yolo"));
    try std.testing.expectEqualStrings("model", settings.model_option);
    try std.testing.expectEqualStrings("Opus", ClientSettings.nameOf(settings.models, "opus"));
    try std.testing.expect(settings.offersModel("opus"));
    // The boolean is kept beside the model, in the agent's order.
    try std.testing.expectEqual(@as(usize, 2), settings.options.len);
    try std.testing.expect(settings.findOption("fast").?.is_boolean and settings.findOption("fast").?.enabled);
    try std.testing.expectEqual(@as(usize, 2), settings.findOption("model").?.choices.len);

    try settings.takeMode("plan");
    try std.testing.expectEqualStrings("plan", settings.current_mode);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const copied = try settings.copy(arena_state.allocator());
    try std.testing.expectEqualStrings("sonnet", copied.current_model);
    try std.testing.expectEqualStrings("Fast", copied.findOption("fast").?.name);

    // A reopen with nothing to offer clears both.
    try settings.replace(null, null);
    try std.testing.expectEqual(@as(usize, 0), settings.models.len);
    try std.testing.expectEqual(@as(usize, 0), settings.options.len);
    try std.testing.expectEqualStrings("", settings.current_mode);
}
