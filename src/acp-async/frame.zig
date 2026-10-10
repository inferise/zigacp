//! Newline-delimited JSON-RPC framing.
//!
//! Each frame is one JSON object terminated by a single `\n`. The framer
//! accumulates incoming bytes in an internal buffer and yields complete
//! frames as they arrive; partial input stays buffered for the next read.
//!
//! Embedded newlines inside JSON strings are illegal at the framing layer
//! (peers must emit each message on one line). We don't try to recover —
//! a stray newline is treated as a frame boundary, and the broken half
//! parses as `error.InvalidMessage` at the next layer.

const std = @import("std");
const log = std.log.scoped(.acp_framer);

pub const Framer = struct {
    /// The longest frame kept; the bytes of a longer one are dropped up to its
    /// newline, with a warning, so one runaway line cannot grow the buffer
    /// without bound. The same bound as `FileTransport.max_frame_len`.
    pub const max_frame_len = 16 * 1024 * 1024;

    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    /// Set while the bytes of an over-long frame are being dropped.
    discarding: bool = false,

    pub fn init(allocator: std.mem.Allocator) Framer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Framer) void {
        self.buffer.deinit(self.allocator);
    }

    /// Feed raw bytes from the transport into the framer.
    pub fn feed(self: *Framer, bytes: []const u8) !void {
        var rest = bytes;
        if (self.discarding) {
            const newline = std.mem.findScalar(u8, rest, '\n') orelse return;
            self.discarding = false;
            rest = rest[newline + 1 ..];
        }
        try self.buffer.appendSlice(self.allocator, rest);
        // Only the unterminated tail can be over-long: whole frames before it
        // are taken by `next`.
        const tail_start = if (std.mem.findScalarLast(u8, self.buffer.items, '\n')) |at| at + 1 else 0;
        if (self.buffer.items.len - tail_start > max_frame_len) {
            log.warn("dropping a frame longer than {d} bytes", .{max_frame_len});
            self.buffer.shrinkRetainingCapacity(tail_start);
            self.discarding = true;
        }
    }

    /// Try to extract one complete frame. Returns `null` if the buffer
    /// doesn't yet contain a `\n`. The returned slice is owned by the
    /// caller (allocated via the framer's allocator).
    pub fn next(self: *Framer) !?[]u8 {
        const idx = std.mem.findScalar(u8, self.buffer.items, '\n') orelse return null;
        // Slice off the frame, including any trailing `\r` for tolerance.
        const end = if (idx > 0 and self.buffer.items[idx - 1] == '\r') idx - 1 else idx;
        const owned = try self.allocator.dupe(u8, self.buffer.items[0..end]);
        // Shift remaining bytes left.
        const remaining = self.buffer.items.len - (idx + 1);
        std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[idx + 1 ..]);
        self.buffer.shrinkRetainingCapacity(remaining);
        return owned;
    }

    /// Encode a frame: append `\n` and write to `writer`.
    pub fn writeFrame(writer: anytype, bytes: []const u8) !void {
        try writer.writeAll(bytes);
        try writer.writeByte('\n');
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Framer yields nothing on empty buffer" {
    var f = Framer.init(std.testing.allocator);
    defer f.deinit();
    try std.testing.expect((try f.next()) == null);
}

test "Framer holds partial frames until newline arrives" {
    var f = Framer.init(std.testing.allocator);
    defer f.deinit();
    try f.feed("{\"x\":1");
    try std.testing.expect((try f.next()) == null);
    try f.feed("}\n");
    const got = try f.next();
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualStrings("{\"x\":1}", got.?);
}

test "Framer yields multiple frames in one feed" {
    var f = Framer.init(std.testing.allocator);
    defer f.deinit();
    try f.feed("{\"a\":1}\n{\"b\":2}\n");
    const a = try f.next();
    defer std.testing.allocator.free(a.?);
    try std.testing.expectEqualStrings("{\"a\":1}", a.?);
    const b = try f.next();
    defer std.testing.allocator.free(b.?);
    try std.testing.expectEqualStrings("{\"b\":2}", b.?);
    try std.testing.expect((try f.next()) == null);
}

test "Framer tolerates CRLF" {
    var f = Framer.init(std.testing.allocator);
    defer f.deinit();
    try f.feed("{\"x\":1}\r\n");
    const got = try f.next();
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualStrings("{\"x\":1}", got.?);
}

test "Framer.writeFrame appends newline" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try Framer.writeFrame(&aw.writer, "{\"x\":1}");
    try std.testing.expectEqualStrings("{\"x\":1}\n", aw.written());
}

test "Framer drops an over-long frame and carries on at the next line" {
    // The drop is warned about by design; keep that out of the test output.
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;

    var f = Framer.init(std.testing.allocator);
    defer f.deinit();
    const long = try std.testing.allocator.alloc(u8, Framer.max_frame_len + 1);
    defer std.testing.allocator.free(long);
    @memset(long, 'x');
    try f.feed("{\"a\":1}\n");
    try f.feed(long);
    try f.feed("more of it\n{\"b\":2}\n");
    const a = try f.next();
    defer std.testing.allocator.free(a.?);
    try std.testing.expectEqualStrings("{\"a\":1}", a.?);
    const b = try f.next();
    defer std.testing.allocator.free(b.?);
    try std.testing.expectEqualStrings("{\"b\":2}", b.?);
}
