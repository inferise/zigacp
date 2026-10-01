//! Maps snake_case Zig field names to ACP's camelCase JSON keys.
//!
//! ZIGSTYLE names fields in snake_case; the ACP wire names them in camelCase.
//! A struct that declares its fields in snake_case routes its `jsonStringify`,
//! `jsonParse` and `jsonParseFromValue` through here, so the Zig side follows
//! the style guide and the wire stays canonical. A name with no underscore maps
//! to itself, so a struct may mix in single-word fields freely.

const std = @import("std");
const log = std.log.scoped(.acp_schema_wire_case);

/// Snake_case-to-camelCase codec for wire structs.
pub const WireCase = struct {
    const Self = @This();

    /// Spells a snake_case field name as its camelCase wire key.
    ///
    /// Comptime-only, so it cannot trace its entry the way runtime functions do.
    ///
    /// Parameters:
    /// - `field_name`: the Zig field name.
    ///
    /// Return: the wire key; `field_name` itself when it has no inner underscore.
    pub fn key(comptime field_name: []const u8) []const u8 {
        comptime {
            var out: []const u8 = "";
            var upper_next = false;
            for (field_name, 0..) |c, i| {
                if (c == '_' and i > 0) {
                    upper_next = true;
                    continue;
                }
                out = out ++ &[_]u8{if (upper_next) std.ascii.toUpper(c) else c};
                upper_next = false;
            }
            return out;
        }
    }

    /// Writes a struct as a JSON object keyed by wire names.
    ///
    /// Parameters:
    /// - `T`: the struct type.
    /// - `value`: the struct.
    /// - `jw`: the JSON writer; its `emit_null_optional_fields` is honoured.
    ///
    /// Return: nothing; propagates the writer's failure.
    pub fn stringify(comptime T: type, value: *const T, jw: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try jw.beginObject();
        try Self.stringifyFields(T, value, jw);
        try jw.endObject();
    }

    /// Writes a struct's fields under their wire names into an object the caller has opened, so a tag can go first.
    ///
    /// Parameters:
    /// - `T`: the struct type.
    /// - `value`: the struct.
    /// - `jw`: the JSON writer, inside an object; its `emit_null_optional_fields` is honoured.
    ///
    /// Return: nothing; propagates the writer's failure.
    pub fn stringifyFields(comptime T: type, value: *const T, jw: anytype) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        inline for (@typeInfo(T).@"struct".fields) |field| {
            const v = @field(value.*, field.name);
            const skip = @typeInfo(field.type) == .optional and v == null and !jw.options.emit_null_optional_fields;
            if (!skip) {
                try jw.objectField(comptime key(field.name));
                try jw.write(v);
            }
        }
    }

    /// Parses a struct from a token stream keyed by wire names.
    ///
    /// Parameters:
    /// - `T`: the struct type.
    /// - `allocator`: owns everything parsed.
    /// - `source`: the token stream.
    /// - `options`: the caller's parse options.
    ///
    /// Return: the struct; propagates a parse failure.
    pub fn parse(comptime T: type, allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !T {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return Self.parseFromValue(T, allocator, value, options);
    }

    /// Parses a struct from a JSON value keyed by wire names.
    ///
    /// Parameters:
    /// - `T`: the struct type.
    /// - `allocator`: owns everything parsed.
    /// - `source`: the JSON value.
    /// - `options`: the caller's parse options; unknown keys fail unless `ignore_unknown_fields`.
    ///
    /// Return: the struct; `error.MissingField` for an absent field with no default, `error.UnknownField` for a stray key.
    pub fn parseFromValue(comptime T: type, allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !T {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (source != .object) return error.UnexpectedToken;
        const fields = @typeInfo(T).@"struct".fields;

        if (!options.ignore_unknown_fields) {
            var it = source.object.iterator();
            while (it.next()) |entry| {
                const known = inline for (fields) |field| {
                    if (std.mem.eql(u8, entry.key_ptr.*, comptime key(field.name))) break true;
                } else false;
                if (!known) return error.UnknownField;
            }
        }

        // SAFETY: every field is assigned below or the parse returns an error first.
        var result: T = undefined;
        inline for (fields) |field| {
            if (source.object.get(comptime key(field.name))) |v| {
                @field(result, field.name) = try std.json.innerParseFromValue(field.type, allocator, v, options);
            } else if (comptime field.defaultValue()) |default| {
                @field(result, field.name) = default;
            } else {
                return error.MissingField;
            }
        }
        return result;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "a snake_case name maps to its camelCase key and a single word to itself" {
    try std.testing.expectEqualStrings("currentModeId", comptime WireCase.key("current_mode_id"));
    try std.testing.expectEqualStrings("name", comptime WireCase.key("name"));
    try std.testing.expectEqualStrings("_meta", comptime WireCase.key("_meta"));
}

test "a wire struct round-trips under camelCase keys" {
    const Probe = struct {
        const Self = @This();

        config_id: []const u8,
        current_value: ?[]const u8 = null,

        pub fn jsonStringify(self: *const Self, jw: anytype) !void {
            try WireCase.stringify(Self, self, jw);
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            return WireCase.parse(Self, allocator, source, options);
        }

        pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
            return WireCase.parseFromValue(Self, allocator, source, options);
        }
    };

    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, Probe{ .config_id = "model" }, .{ .emit_null_optional_fields = false });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"configId\":\"model\"}", out);

    const back = try std.json.parseFromSlice(Probe, std.testing.allocator, "{\"configId\":\"model\",\"currentValue\":\"opus\"}", .{});
    defer back.deinit();
    try std.testing.expectEqualStrings("opus", back.value.current_value.?);

    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Probe, std.testing.allocator, "{\"configId\":\"m\",\"x\":1}", .{}));
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Probe, std.testing.allocator, "{}", .{}));
}
