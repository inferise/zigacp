//! `fs/read_text_file` and `fs/write_text_file`, served by the client.
//!
//! ACP lets an agent ask its client to touch the filesystem rather than doing it
//! itself — which is how an editor keeps unsaved buffers and an agent's view of
//! a file in step.
//!
//! A client registers this on its `acp.Dispatcher` to offer both methods, and
//! advertises them in `clientCapabilities.fs` so an agent knows to ask. Promoted
//! from zigclaude and zigcodex, which each carried a copy; neither harness's
//! agent calls these methods, so they are held up by the tests here.
//!
//! There is no path policy: absolute paths and `..` are served as given. A
//! client that needs a sandbox must check the path before registering this.
//!
//! `sessionId` is accepted and ignored. A path is a path, and this client serves
//! one working directory regardless of which session asks.

const std = @import("std");
const log = std.log.scoped(.acp_client_fs);
const acp = @import("module.zig");

/// Serves `fs/read_text_file`.
const ReadHandler = struct {
    const Self = @This();

    // SAFETY: set by `ClientFs.register`.
    fs: *ClientFs = undefined,

    pub const Params = acp.Client.ReadTextFileRequest;
    pub const Result = acp.Client.ReadTextFileResponse;

    /// Builds a handler bound to its surface.
    ///
    /// Parameters:
    /// - `fs`: the surface served; borrowed, must outlive the handler.
    ///
    /// Return: the handler; never fails.
    pub fn init(fs: *ClientFs) !Self {
        return .{ .fs = fs };
    }

    /// Releases the handler.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Answers `fs/read_text_file`.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `allocator`: per-call arena; owns the returned text.
    /// - `params`: the path and optional line window.
    ///
    /// Return: the file's text; `InvalidParams` when the read fails.
    pub fn handle(self: *Self, allocator: std.mem.Allocator, params: Params) acp.AcpError!Result {
        const content = self.fs.readTextOwned(allocator, params.path, params.line, params.limit) catch |err| {
            log.warn("fs/read_text_file {s} [{t}]", .{ params.path, err });
            return error.InvalidParams;
        };
        return .{ .content = content };
    }
};

/// Serves `fs/write_text_file`.
const WriteHandler = struct {
    const Self = @This();

    // SAFETY: set by `ClientFs.register`.
    fs: *ClientFs = undefined,

    pub const Params = acp.Client.WriteTextFileRequest;
    pub const Result = acp.Client.WriteTextFileResponse;

    /// Builds a handler bound to its surface.
    ///
    /// Parameters:
    /// - `fs`: the surface served; borrowed, must outlive the handler.
    ///
    /// Return: the handler; never fails.
    pub fn init(fs: *ClientFs) !Self {
        return .{ .fs = fs };
    }

    /// Releases the handler.
    ///
    /// Parameters:
    /// - `self`: the handler.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Answers `fs/write_text_file`.
    ///
    /// Parameters:
    /// - `self`: the handler.
    /// - `allocator`: per-call arena; unused.
    /// - `params`: the path and content.
    ///
    /// Return: an empty result; `InvalidParams` when the write fails.
    pub fn handle(self: *Self, _: std.mem.Allocator, params: Params) acp.AcpError!Result {
        self.fs.writeText(params.path, params.content) catch |err| {
            log.warn("fs/write_text_file {s} [{t}]", .{ params.path, err });
            return error.InvalidParams;
        };
        return .{};
    }
};

/// The filesystem half of the client surface.
pub const ClientFs = struct {
    const Self = @This();

    /// Refuse a file larger than this. Every buffer here states its bound, and
    /// a peer asking for a gigabyte should be told no rather than obeyed.
    pub const max_file_len = 16 * 1024 * 1024;

    // SAFETY: set by `init` (or by the literal in a test) before the dispatcher
    // can route anything to these handlers.
    io: std.Io = undefined,

    read_handler_storage: ReadHandler = .{},
    write_handler_storage: WriteHandler = .{},

    /// Builds the filesystem surface.
    ///
    /// Parameters:
    /// - `io`: IO capability for file access.
    ///
    /// Return: the surface, unregistered until `register`; never fails.
    pub fn init(io: std.Io) !Self {
        return .{ .io = io };
    }

    /// Releases the surface; it owns nothing.
    ///
    /// Parameters:
    /// - `self`: the surface.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Registers `fs/read_text_file` and `fs/write_text_file` on a dispatcher.
    ///
    /// Parameters:
    /// - `instance`: the surface; must outlive the dispatcher.
    /// - `dispatcher`: where to register.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn register(instance: *Self, dispatcher: *acp.Dispatcher) !void {
        instance.read_handler_storage.fs = instance;
        instance.write_handler_storage.fs = instance;
        try dispatcher.registerRequest(acp.Client.method_fs_read_text_file, ReadHandler, &instance.read_handler_storage);
        try dispatcher.registerRequest(acp.Client.method_fs_write_text_file, WriteHandler, &instance.write_handler_storage);
    }

    /// Reads a file, or a window of its lines.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `allocator`: owns the returned text.
    /// - `path`: the file, relative to the working directory or absolute.
    /// - `line`: first line to return, 1-based, or null for the whole file.
    /// - `limit`: maximum line count, or null for the rest.
    ///
    /// Return: the text, caller-owned; propagates read and allocation failures.
    pub fn readTextOwned(self: *Self, allocator: std.mem.Allocator, path: []const u8, line: ?u32, limit: ?u32) ![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const whole = try std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(max_file_len));
        if (line == null and limit == null) return whole;
        defer allocator.free(whole);

        // 1-based, because that is how an editor numbers lines and this method
        // exists for editors.
        const first = if (line) |value| (if (value == 0) 0 else value - 1) else 0;

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();

        var index: u32 = 0;
        var taken: u32 = 0;
        var lines = std.mem.splitScalar(u8, whole, '\n');
        while (lines.next()) |text| : (index += 1) {
            if (index < first) continue;
            if (limit) |max| {
                if (taken >= max) break;
            }
            if (taken > 0) try out.writer.writeByte('\n');
            try out.writer.writeAll(text);
            taken += 1;
        }
        return out.toOwnedSlice();
    }

    /// Writes a file, creating it and any missing parent directories.
    ///
    /// Parameters:
    /// - `self`: the surface.
    /// - `path`: the file to write.
    /// - `content`: the bytes; at most `max_file_len`.
    ///
    /// Return: nothing; `error.FileTooLarge`, or propagates filesystem failures.
    pub fn writeText(self: *Self, path: []const u8, content: []const u8) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (content.len > max_file_len) return error.FileTooLarge;

        if (std.fs.path.dirname(path)) |parent| {
            var dir = try std.Io.Dir.cwd().createDirPathOpen(self.io, parent, .{});
            dir.close(self.io);
        }

        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, content);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ClientFs);
}

/// Builds a scratch path under the test cache, relative to the working directory.
///
/// Parameters:
/// - `allocator`: owns the returned path.
/// - `tmp`: the test's temporary directory.
/// - `name`: the file name inside it.
///
/// Return: the path, caller-owned; propagates allocation failure.
fn tempPathOwned(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "a file written through the client reads back through it" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tempPathOwned(allocator, &tmp, "notes.txt");
    defer allocator.free(path);

    var fs = ClientFs{ .io = std.testing.io };
    try fs.writeText(path, "alpha\nbeta\ngamma\n");

    const whole = try fs.readTextOwned(allocator, path, null, null);
    defer allocator.free(whole);
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", whole);
}

test "a line window returns just that window" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tempPathOwned(allocator, &tmp, "lines.txt");
    defer allocator.free(path);

    var fs = ClientFs{ .io = std.testing.io };
    try fs.writeText(path, "one\ntwo\nthree\nfour\nfive\n");

    // 1-based, as an editor numbers lines.
    const window = try fs.readTextOwned(allocator, path, 2, 2);
    defer allocator.free(window);
    try std.testing.expectEqualStrings("two\nthree", window);

    const tail = try fs.readTextOwned(allocator, path, 4, null);
    defer allocator.free(tail);
    try std.testing.expectEqualStrings("four\nfive\n", tail);
}

test "writing creates missing parent directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tempPathOwned(allocator, &tmp, "nested/deeper/file.txt");
    defer allocator.free(path);

    var fs = ClientFs{ .io = std.testing.io };
    try fs.writeText(path, "made it");

    const back = try fs.readTextOwned(allocator, path, null, null);
    defer allocator.free(back);
    try std.testing.expectEqualStrings("made it", back);
}

test "an oversized write is refused rather than attempted" {
    var fs = ClientFs{ .io = std.testing.io };
    const huge = try std.testing.allocator.alloc(u8, ClientFs.max_file_len + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');

    try std.testing.expectError(error.FileTooLarge, fs.writeText("unused.txt", huge));
}

test "a missing file is an error, not an empty read" {
    const allocator = std.testing.allocator;
    var fs = ClientFs{ .io = std.testing.io };
    try std.testing.expectError(
        error.FileNotFound,
        fs.readTextOwned(allocator, ".zig-cache/tmp/definitely-not-here/nope.txt", null, null),
    );
}
