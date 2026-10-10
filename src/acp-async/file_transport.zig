//! File-handle-backed Transport.
//!
//! Wraps a pair of `std.Io.File` handles (typically a process's stdin
//! and stdout, or the two ends of a pipe) and frames JSON-RPC messages
//! over them one line each. Synchronous: reads block until at least one
//! whole frame is available. Suitable for foreground client / agent
//! binaries; subprocess agents use this same transport via `Child`.

const std = @import("std");
const acp = @import("acp");

const Transport = acp.Transport;
const Frame = acp.Frame;
const AcpError = acp.AcpError;

const log = std.log.scoped(.acp_file_transport);

pub const FileTransport = struct {
    /// The largest frame accepted. A tool result can carry a whole file, so
    /// this is generous; it exists to state a bound, not to be reached. A
    /// longer line is dropped with a warning and reading carries on.
    pub const max_frame_len = 16 * 1024 * 1024;
    /// Read buffer; a frame longer than this is assembled across refills.
    const read_buffer_len = 64 * 1024;

    allocator: std.mem.Allocator,
    io: std.Io,
    reader: std.Io.File,
    writer: std.Io.File,
    /// When true the transport closes both handles on `close`. Pass
    /// `false` for stdin / stdout the runtime owns.
    own_handles: bool,
    /// The buffered reader over `reader`, made on the first read.
    input: ?std.Io.File.Reader = null,
    read_buffer: []u8 = &.{},
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, reader: std.Io.File, writer: std.Io.File, own_handles: bool) FileTransport {
        return .{
            .allocator = allocator,
            .io = io,
            .reader = reader,
            .writer = writer,
            .own_handles = own_handles,
        };
    }

    pub fn deinit(self: *FileTransport) void {
        self.allocator.free(self.read_buffer);
        if (self.own_handles) {
            self.reader.close(self.io);
            self.writer.close(self.io);
        }
    }

    pub fn transport(self: *FileTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn writeFrame(ctx: *anyopaque, frame: Frame) AcpError!void {
        const self: *FileTransport = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.TransportClosed;

        self.writer.writeStreamingAll(self.io, frame.bytes) catch |err| {
            log.err("write payload failed: {s}", .{@errorName(err)});
            return error.TransportFailed;
        };
        self.writer.writeStreamingAll(self.io, "\n") catch |err| {
            log.err("write delimiter failed: {s}", .{@errorName(err)});
            return error.TransportFailed;
        };
    }

    /// Reads the next non-empty line as a frame.
    ///
    /// On Zig 0.16 a pipe's end of stream arrives as `error.EndOfStream`, not a
    /// zero-byte read, and it is a clean close: `TransportClosed`, never
    /// `TransportFailed`. A line past `max_frame_len` is dropped, not buffered.
    fn readFrame(ctx: *anyopaque, allocator: std.mem.Allocator) AcpError![]u8 {
        const self: *FileTransport = @ptrCast(@alignCast(ctx));
        if (self.input == null) {
            self.read_buffer = self.allocator.alloc(u8, read_buffer_len) catch return error.OutOfMemory;
            self.input = self.reader.readerStreaming(self.io, self.read_buffer);
        }
        const in = &self.input.?.interface;

        while (true) {
            if (self.closed) return error.TransportClosed;

            var frame: std.Io.Writer.Allocating = .init(allocator);
            errdefer frame.deinit();

            _ = in.streamDelimiterLimit(&frame.writer, '\n', .limited(max_frame_len)) catch |err| switch (err) {
                error.ReadFailed => {
                    log.warn("read failed: {s}", .{@errorName(self.input.?.err orelse error.ReadFailed)});
                    return error.TransportFailed;
                },
                error.WriteFailed => return error.OutOfMemory,
                error.StreamTooLong => {
                    log.warn("dropping a frame longer than {d} bytes", .{max_frame_len});
                    frame.deinit();
                    _ = in.discardDelimiterInclusive('\n') catch {
                        self.closed = true;
                        return error.TransportClosed;
                    };
                    continue;
                },
            };

            // Either the newline is next, or the stream has ended.
            const ended = if (in.takeByte()) |_| false else |err| switch (err) {
                error.EndOfStream => true,
                error.ReadFailed => return error.TransportFailed,
            };
            if (ended) self.closed = true;

            // A peer may end its lines with `\r\n`.
            if (std.mem.endsWith(u8, frame.written(), "\r")) frame.shrinkRetainingCapacity(frame.written().len - 1);
            if (frame.written().len == 0) {
                frame.deinit();
                if (ended) return error.TransportClosed;
                continue;
            }
            return frame.toOwnedSlice() catch error.OutOfMemory;
        }
    }

    fn close(ctx: *anyopaque) void {
        const self: *FileTransport = @ptrCast(@alignCast(ctx));
        // A read already blocked ends only when the peer closes its output.
        self.closed = true;
    }
};

const vtable: Transport.VTable = .{
    .write_frame = FileTransport.writeFrame,
    .read_frame = FileTransport.readFrame,
    .close = FileTransport.close,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "reads frames, skips blank lines and carriage returns, and ends cleanly at end of stream" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The last frame has no trailing newline: the stream ends mid-line.
    try tmp.dir.writeFile(io, .{ .sub_path = "in", .data = "{\"a\":1}\n\n{\"b\":2}\r\n{\"c\":3}" });
    const input = try tmp.dir.openFile(io, "in", .{});
    defer input.close(io);
    const output = try tmp.dir.createFile(io, "out", .{});
    defer output.close(io);

    var file = FileTransport.init(allocator, io, input, output, false);
    defer file.deinit();
    const t = file.transport();

    for ([_][]const u8{ "{\"a\":1}", "{\"b\":2}", "{\"c\":3}" }) |expected| {
        const frame = try t.readFrame(allocator);
        defer allocator.free(frame);
        try std.testing.expectEqualStrings(expected, frame);
    }
    // End of stream is a clean close, not a failure.
    try std.testing.expectError(error.TransportClosed, t.readFrame(allocator));
}

test "a frame past the limit is dropped and reading carries on" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const long = try allocator.alloc(u8, FileTransport.max_frame_len + 10);
    defer allocator.free(long);
    @memset(long, 'x');
    const data = try std.mem.concat(allocator, u8, &.{ long, "\n{\"after\":1}\n" });
    defer allocator.free(data);
    try tmp.dir.writeFile(io, .{ .sub_path = "in", .data = data });
    const input = try tmp.dir.openFile(io, "in", .{});
    defer input.close(io);
    const output = try tmp.dir.createFile(io, "out", .{});
    defer output.close(io);

    // The drop is warned about by design; keep that out of the test output.
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;

    var file = FileTransport.init(allocator, io, input, output, false);
    defer file.deinit();
    const frame = try file.transport().readFrame(allocator);
    defer allocator.free(frame);
    try std.testing.expectEqualStrings("{\"after\":1}", frame);
}
