//! Session settings a client can change mid-session, such as the model.
//!
//! ACP's stable shape is `select`, whose options come either as one flat list
//! or as named groups. Any other shape — the unstable `boolean` one, or a newer
//! revision's — and any `select` this revision can't read land in `unknown`,
//! so a single unfamiliar option never fails the `session/new` carrying it.
//! `category` is an open string (`mode`, `model`, `model_config`,
//! `thought_level`, or anything else).

const std = @import("std");
const log = std.log.scoped(.acp_schema_session_config_option);
const mod = @import("module.zig");

/// One value a select option can take.
pub const SessionConfigSelectOption = struct {
    const Self = @This();

    value: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

/// A named group of select values.
pub const SessionConfigSelectGroup = struct {
    const Self = @This();

    group: []const u8,
    name: []const u8,
    options: []const SessionConfigSelectOption,
};

/// A select option's values: one flat list, or named groups.
pub const SessionConfigSelectOptions = union(enum) {
    const Self = @This();

    ungrouped: []const SessionConfigSelectOption,
    grouped: []const SessionConfigSelectGroup,

    /// Writes the values as the JSON array they arrived as.
    ///
    /// Parameters:
    /// - `self`: the values.
    /// - `jw`: the JSON writer.
    ///
    /// Return: nothing; propagates the writer's failure.
    pub fn jsonStringify(self: *const Self, jw: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        switch (self.*) {
            .ungrouped => |values| try jw.write(values),
            .grouped => |groups| try jw.write(groups),
        }
    }

    /// Parses the values from a token stream.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the token stream.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the values; propagates a parse failure.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, value, options);
    }

    /// Parses the values from a JSON array; a first entry carrying `group` makes the list grouped.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the JSON array.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the values; `error.UnexpectedToken` when it isn't an array, or a parse failure.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (source != .array) return error.UnexpectedToken;
        const items = source.array.items;
        const grouped = items.len > 0 and items[0] == .object and items[0].object.get("group") != null;
        if (grouped) return .{ .grouped = try std.json.parseFromValueLeaky([]const SessionConfigSelectGroup, allocator, source, options) };
        return .{ .ungrouped = try std.json.parseFromValueLeaky([]const SessionConfigSelectOption, allocator, source, options) };
    }
};

/// A `select` option: one value chosen from a list.
pub const SessionConfigSelect = struct {
    const Self = @This();

    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    category: ?[]const u8 = null,
    current_value: []const u8,
    options: SessionConfigSelectOptions,

    /// Reports whether `value` is one the option offers, in any group.
    ///
    /// Parameters:
    /// - `self`: the option.
    /// - `value`: the candidate value.
    ///
    /// Return: true when some value of `options` is `value`.
    pub fn offers(self: *const Self, value: []const u8) bool {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        switch (self.options) {
            .ungrouped => |values| return Self.listOffers(values, value),
            .grouped => |groups| {
                for (groups) |group| {
                    if (Self.listOffers(group.options, value)) return true;
                }
                return false;
            },
        }
    }

    /// Reports whether one flat list holds `value`.
    ///
    /// Parameters:
    /// - `values`: the list.
    /// - `value`: the candidate value.
    ///
    /// Return: true when some entry carries `value`.
    fn listOffers(values: []const SessionConfigSelectOption, value: []const u8) bool {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        for (values) |option| {
            if (std.mem.eql(u8, option.value, value)) return true;
        }
        return false;
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

/// A session setting the client can change, tagged on the wire by `type`.
pub const SessionConfigOption = union(enum) {
    const Self = @This();

    select: SessionConfigSelect,
    /// Forward-compat: a shape this revision doesn't model, or a `select` it can't read.
    unknown: mod.RawValue,

    /// Parses a `select` from everything but `type`.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the option object.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the select, or null when the object doesn't fit the shape; propagates allocation failure.
    fn parseSelect(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) error{OutOfMemory}!?SessionConfigSelect {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var fields: std.json.ObjectMap = .empty;
        try fields.ensureTotalCapacity(allocator, source.object.count());
        var it = source.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "type")) continue;
            fields.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        }
        return std.json.parseFromValueLeaky(SessionConfigSelect, allocator, .{ .object = fields }, options) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                log.warn("keeping an unreadable select option as unknown [{s}]", .{@errorName(err)});
                return null;
            },
        };
    }

    /// Writes the option in its wire shape, with `type` first.
    ///
    /// Parameters:
    /// - `self`: the option.
    /// - `jw`: the JSON writer.
    ///
    /// Return: nothing; propagates the writer's failure.
    pub fn jsonStringify(self: *const Self, jw: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        switch (self.*) {
            .select => |*select| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("select");
                try mod.WireCase.stringifyFields(SessionConfigSelect, select, jw);
                try jw.endObject();
            },
            .unknown => |raw| try jw.write(raw),
        }
    }

    /// Parses one option from a token stream.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the token stream.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the option; propagates a parse failure.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, value, options);
    }

    /// Parses one option from a JSON value, routing on `type`.
    ///
    /// Parameters:
    /// - `allocator`: owns everything parsed.
    /// - `source`: the JSON value.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the option, `unknown` for a shape this revision can't read; `error.UnexpectedToken` when it isn't an object.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (source != .object) return error.UnexpectedToken;
        const kind = source.object.get("type") orelse return .{ .unknown = .{ .value = source } };
        if (kind == .string and std.mem.eql(u8, kind.string, "select")) {
            if (try parseSelect(allocator, source, options)) |select| return .{ .select = select };
        }
        return .{ .unknown = .{ .value = source } };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "a flat model option parses and knows its values" {
    const src =
        \\{"id":"model","name":"Model","category":"model","type":"select","currentValue":"sonnet","options":[{"value":"sonnet","name":"Sonnet"},{"value":"opus","name":"Opus"}]}
    ;
    const parsed = try std.json.parseFromSlice(SessionConfigOption, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("sonnet", parsed.value.select.current_value);
    try std.testing.expect(parsed.value.select.offers("opus"));
    try std.testing.expect(!parsed.value.select.offers("haiku"));
}

test "grouped options parse and are searched across groups" {
    const src =
        \\{"id":"model","name":"Model","type":"select","currentValue":"b","options":[{"group":"fast","name":"Fast","options":[{"value":"a","name":"A"}]},{"group":"deep","name":"Deep","options":[{"value":"b","name":"B"}]}]}
    ;
    const parsed = try std.json.parseFromSlice(SessionConfigOption, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("deep", parsed.value.select.options.grouped[1].group);
    try std.testing.expect(parsed.value.select.offers("b"));
}

test "a boolean or malformed option is kept as unknown, not refused" {
    // The malformed select is warned about by design; keep that out of the test output.
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;

    const src =
        \\[{"id":"fast","name":"Fast","type":"boolean","currentValue":true},{"id":"m","name":"M","type":"select","options":[]}]
    ;
    const parsed = try std.json.parseFromSlice([]const SessionConfigOption, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value[0] == .unknown);
    try std.testing.expect(parsed.value[1] == .unknown);
}

test "a select round-trips with its type first" {
    const values = [_]SessionConfigSelectOption{.{ .value = "a", .name = "A" }};
    const option: SessionConfigOption = .{ .select = .{ .id = "m", .name = "M", .current_value = "a", .options = .{ .ungrouped = &values } } };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, option, .{ .emit_null_optional_fields = false });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"type\":\"select\",\"id\":\"m\",\"name\":\"M\",\"currentValue\":\"a\",\"options\":[{\"value\":\"a\",\"name\":\"A\"}]}", out);

    const back = try std.json.parseFromSlice(SessionConfigOption, std.testing.allocator, out, .{});
    defer back.deinit();
    try std.testing.expectEqualStrings("a", back.value.select.options.ungrouped[0].value);
}
