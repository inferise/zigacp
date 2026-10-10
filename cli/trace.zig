const std = @import("std");
const log = std.log.scoped(.acp_trace);
const cli = @import("module.zig");

/// Which way a traced frame went, from the side that captured it.
pub const TraceDirection = enum {
    const Self = @This();

    /// Sent: a line prefixed `> `.
    outbound,
    /// Received: a line prefixed `< `.
    inbound,
};

/// One captured frame.
pub const TraceEntry = struct {
    const Self = @This();

    direction: TraceDirection,
    /// The frame as captured, owned by the `Trace`.
    bytes: []const u8,
};

/// A captured trace: one frame per line, each prefixed `< ` or `> ` for its
/// direction. Any other line is skipped, so a tool emitting the same line
/// shape as `acp.TraceBuffer` can be read too.
pub const Trace = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    entries: []TraceEntry,

    /// Reads and parses a trace file.
    ///
    /// Parameters:
    /// - `allocator`: owns the entries.
    /// - `io`: IO capability for reading the file.
    /// - `environ`: the process environment, for zigstorage.
    /// - `path`: the file, relative to the working directory or absolute.
    ///
    /// Return: the trace; propagates read and allocation failures.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, path: []const u8) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const url = try fileUrlOwned(allocator, io, path);
        defer allocator.free(url);

        var node = try cli.zigstorage.Node.init(allocator, io, environ, url);
        defer node.deinit();
        const content = try node.read(.all);
        defer allocator.free(content);

        return parse(allocator, content);
    }

    /// Parses trace text already in memory.
    ///
    /// Parameters:
    /// - `allocator`: owns the entries.
    /// - `content`: the trace text; copied, not borrowed.
    ///
    /// Return: the trace; propagates allocation failures.
    pub fn parse(allocator: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        var entries: std.ArrayList(TraceEntry) = .empty;
        errdefer {
            for (entries.items) |entry| allocator.free(entry.bytes);
            entries.deinit(allocator);
        }

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (line.len < 2 or line[1] != ' ') continue;
            const direction: TraceDirection = switch (line[0]) {
                '<' => .inbound,
                '>' => .outbound,
                else => continue,
            };
            const owned = try allocator.dupe(u8, line[2..]);
            errdefer allocator.free(owned);
            try entries.append(allocator, .{ .direction = direction, .bytes = owned });
        }
        return .{ .allocator = allocator, .entries = try entries.toOwnedSlice(allocator) };
    }

    /// Frees every entry.
    ///
    /// Parameters:
    /// - `self`: the trace; unusable afterwards.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        for (self.entries) |entry| self.allocator.free(entry.bytes);
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Spells a filesystem path as a `file://` URL, anchoring a relative one at the working directory.
///
/// Parameters:
/// - `allocator`: owns the returned URL.
/// - `io`: IO capability for reading the working directory.
/// - `path`: the path, relative or absolute.
///
/// Return: the URL, caller-owned; propagates working-directory and allocation failures.
fn fileUrlOwned(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    // Joined rather than resolved, so a `..` is left for the filesystem to follow.
    const absolute = if (std.Io.Dir.path.isAbsolute(path)) try allocator.dupe(u8, path) else blk: {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        break :blk try std.Io.Dir.path.join(allocator, &.{ cwd, path });
    };
    defer allocator.free(absolute);

    // Percent-encoded by zigstorage's own rule, so any character in a name
    // reaches the filesystem as written; a drive-rooted path needs the third slash.
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(if (std.mem.startsWith(u8, absolute, "/")) "file://" else "file:///");
    try cli.zigstorage.NodeUrl.encodePath(&out.writer, absolute);
    return out.toOwnedSlice();
}

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
}

test "trace parses both directions and skips every other line" {
    var trace = try Trace.parse(std.testing.allocator,
        \\> {"id":1}
        \\
        \\# a comment
        \\<{"no":"space"}
        \\< {"id":1,"result":{}}
        \\>
    );
    defer trace.deinit();

    try std.testing.expectEqual(2, trace.entries.len);
    try std.testing.expectEqual(TraceDirection.outbound, trace.entries[0].direction);
    try std.testing.expectEqualStrings("{\"id\":1}", trace.entries[0].bytes);
    try std.testing.expectEqual(TraceDirection.inbound, trace.entries[1].direction);
    try std.testing.expectEqualStrings("{\"id\":1,\"result\":{}}", trace.entries[1].bytes);
}

test "trace of an empty file has no entries" {
    var trace = try Trace.parse(std.testing.allocator, "");
    defer trace.deinit();
    try std.testing.expectEqual(0, trace.entries.len);
}
