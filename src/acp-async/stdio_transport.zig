//! A pollable transport over a pair of file handles.
//!
//! `FileTransport` reads the handle on demand, so it cannot answer "is anything
//! waiting?" without blocking — and an agent inside a blocking `session/prompt`
//! handler has to ask exactly that between polls, or a `session/cancel` (or the
//! client's answer to a permission request) sits unread until the turn it was
//! meant to affect has already finished. That is the one thing a process-to-
//! process seam needs that the in-process `FrameTransport` already has.
//!
//! So a reader task owns the input handle: it frames whatever arrives and queues
//! whole frames behind a mutex, and `read_frame` / `try_read_frame` pop that
//! queue exactly as `FrameTransport` does. A full queue stalls the reader until
//! a frame is taken, so a slow consumer pushes back on the peer through the
//! pipe instead of losing frames. Readiness is decided by the queue,
//! never by the OS, which keeps this portable — there is no `poll(2)` on a
//! Windows pipe.
//!
//! Writes go straight to the output handle under their own mutex: every frame
//! is one line, and two tasks writing at once must not interleave halves. The
//! two directions end independently: the peer closing its output ends reads
//! once the queue drains, but replies to frames already queued still go out.
//!
//! The reader task borrows the transport, so it must not move once `start` has
//! run; `deinit` cancels that task (a blocked read is a cancelation point)
//! before anything is freed.

const std = @import("std");
const log = std.log.scoped(.acp_stdio_transport);
const mod = @import("module.zig");
const acp = @import("acp");

/// A file-handle transport whose reads can be polled.
pub const StdioTransport = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    /// Runtime settings, borrowed; must outlive the transport.
    config: *const mod.Config,
    /// Where frames arrive from; read only by the reader task once started.
    reader: std.Io.File,
    /// Where frames are written.
    writer: std.Io.File,
    /// When true both handles close on `deinit`. False for the process's own stdio.
    own_handles: bool,
    /// Guards `inbound`, `closed` and `input_ended`.
    mutex: std.Io.Mutex = .init,
    /// Signalled whenever a frame is queued, the input ends, or the transport closes.
    arrival: std.Io.Condition = .init,
    /// Signalled whenever a frame is taken or the transport closes, so a reader stalled on a full queue resumes.
    space: std.Io.Condition = .init,
    /// Serialises writers so frames never interleave.
    write_mutex: std.Io.Mutex = .init,
    /// Whole frames read but not yet taken.
    inbound: std.ArrayList([]u8) = .empty,
    /// Set by `close`: both directions are finished.
    closed: bool = false,
    /// Set when the input reaches EOF or fails: reads end once the queue drains, writes carry on.
    input_ended: bool = false,
    /// The reader task. Exactly one releaser, which is `deinit`.
    reader_group: std.Io.Group = .init,
    /// Whether the reader task was started, so `deinit` knows to cancel it.
    started: bool = false,

    /// Creates a transport over two handles; call `start` before reading.
    ///
    /// Parameters:
    /// - `allocator`: owns the transport and every queued frame; must outlive it.
    /// - `io`: IO capability for the reader task, locks and handle I/O.
    /// - `config`: runtime settings, borrowed; must outlive the transport.
    /// - `reader`: the handle frames are read from.
    /// - `writer`: the handle frames are written to.
    /// - `own_handles`: whether `deinit` closes both handles.
    ///
    /// Return: the transport, caller stores it and calls `deinit`; never fails today.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: *const mod.Config, reader: std.Io.File, writer: std.Io.File, own_handles: bool) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const self = Self{ .allocator = allocator, .io = io, .config = config, .reader = reader, .writer = writer, .own_handles = own_handles };
        return self;
    }

    /// Stops the reader task, frees every queued frame, and closes owned handles.
    ///
    /// Parameters:
    /// - `self`: the transport; invalid after this call.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.close();
        // A read blocked on a peer that never hangs up would otherwise hold
        // `deinit` forever; cancelation interrupts it.
        if (self.started) self.reader_group.cancel(self.io);

        for (self.inbound.items) |frame| self.allocator.free(frame);
        self.inbound.deinit(self.allocator);
        if (self.own_handles) {
            self.reader.close(self.io);
            self.writer.close(self.io);
        }
    }

    /// Starts the reader task; frames queue from here on.
    ///
    /// Parameters:
    /// - `self`: the transport; must stay at this address until `deinit`.
    ///
    /// Return: nothing; `error.TransportFailed` when the IO implementation cannot run a task alongside the caller.
    pub fn start(self: *Self) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // `concurrent`, never `async`: `async` may run the loop inline, and a
        // reader that never returns would then never hand control back.
        self.reader_group.concurrent(self.io, readLoop, .{self}) catch |err| {
            log.err("cannot start the reader task [{s}]", .{@errorName(err)});
            return error.TransportFailed;
        };
        self.started = true;
    }

    /// Returns the vtable view the connection drives.
    ///
    /// Parameters:
    /// - `self`: the transport.
    ///
    /// Return: the transport, borrowing `self`.
    pub fn transport(self: *Self) acp.Transport {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Marks the transport closed and wakes every waiter; idempotent.
    ///
    /// Parameters:
    /// - `self`: the transport.
    ///
    /// Return: nothing.
    pub fn close(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return;
        self.closed = true;
        self.arrival.broadcast(self.io);
        self.space.broadcast(self.io);
    }

    /// Reports whether `close` has run; the input ending does not count.
    ///
    /// Parameters:
    /// - `self`: the transport.
    ///
    /// Return: true once the transport has been closed.
    fn isClosed(self: *Self) bool {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        return self.closed;
    }

    /// Reads the input handle until it ends, queueing every whole frame.
    ///
    /// Parameters:
    /// - `self`: the transport.
    ///
    /// Return: nothing; EOF, a read or framing failure, or a closed transport ends the input rather than propagating.
    fn readLoop(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        defer self.endInput();

        var framer = mod.Framer.init(self.allocator);
        defer framer.deinit();

        // SAFETY: filled by each read before any byte of it is used.
        var chunk: [4096]u8 = undefined;
        while (true) {
            // A peer hanging up surfaces as `EndOfStream` and a teardown as
            // `Canceled`; both are ordinary endings, not failures.
            const n = self.reader.readStreaming(self.io, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream, error.Canceled => return,
                else => {
                    log.warn("read failed; ending input [{s}]", .{@errorName(err)});
                    return;
                },
            };
            if (n == 0) return;

            framer.feed(chunk[0..n]) catch |err| {
                log.err("cannot buffer input; ending input [{s}]", .{@errorName(err)});
                return;
            };
            while (true) {
                const frame = framer.next() catch |err| {
                    log.err("cannot frame input; ending input [{s}]", .{@errorName(err)});
                    return;
                } orelse break;
                // A frame that can't be queued is never dropped quietly: the
                // input ends, so a reader waiting on it sees the transport
                // close instead of waiting for a reply that will never come.
                self.push(frame) catch |err| {
                    self.allocator.free(frame);
                    if (err != error.TransportClosed) log.err("cannot queue a frame; ending input [{s}]", .{@errorName(err)});
                    return;
                };
            }
        }
    }

    /// Marks the input finished and wakes every reader; writes are unaffected.
    ///
    /// Parameters:
    /// - `self`: the transport.
    ///
    /// Return: nothing.
    fn endInput(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.input_ended = true;
        self.arrival.broadcast(self.io);
    }

    /// Queues a frame for the reading side, taking ownership of it; waits while the queue is full.
    ///
    /// Parameters:
    /// - `self`: the transport.
    /// - `frame`: the frame, allocated with `self.allocator`; owned by the queue on success.
    ///
    /// Return: nothing; `error.TransportClosed` when the transport closes first, or allocation failure.
    fn push(self: *Self, frame: []u8) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Backpressure: stop reading until a frame is taken. The peer's writes
        // then block on the full pipe, which is the pipe's own flow control.
        while (self.inbound.items.len >= self.config.max_queued_frames and !self.closed) {
            self.space.waitUncancelable(self.io, &self.mutex);
        }
        if (self.closed) return error.TransportClosed;
        self.inbound.append(self.allocator, frame) catch return error.OutOfMemory;
        self.arrival.broadcast(self.io);
    }

    /// Takes the oldest queued frame, waiting for one only when asked to.
    ///
    /// Parameters:
    /// - `self`: the transport.
    /// - `allocator`: owns the returned frame.
    /// - `wait`: whether to block until a frame arrives.
    ///
    /// Return: the frame, caller-owned, or null when none is queued and `wait` is false; `error.TransportClosed` once drained and closed.
    fn take(self: *Self, allocator: std.mem.Allocator, wait: bool) acp.AcpError!?[]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.inbound.items.len == 0) {
            // Checked *after* the queue, so frames the peer wrote before
            // hanging up are still delivered.
            if (self.closed or self.input_ended) return error.TransportClosed;
            if (!wait) return null;
            self.arrival.waitUncancelable(self.io, &self.mutex);
        }

        const frame = self.inbound.orderedRemove(0);
        defer self.allocator.free(frame);
        self.space.signal(self.io);
        return allocator.dupe(u8, frame) catch return error.OutOfMemory;
    }

    const vtable: acp.Transport.VTable = .{
        .write_frame = writeFrame,
        .read_frame = readFrame,
        .try_read_frame = tryReadFrame,
        .close = closeTransport,
    };

    /// Vtable entry that writes one frame as one line.
    ///
    /// Parameters:
    /// - `ctx`: the transport.
    /// - `frame`: the frame to write.
    ///
    /// Return: nothing; `error.TransportClosed` once `close` has run, `error.TransportFailed` when the write fails.
    fn writeFrame(ctx: *anyopaque, frame: acp.Frame) acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const self: *Self = @ptrCast(@alignCast(ctx));

        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);

        if (self.isClosed()) return error.TransportClosed;
        self.writer.writeStreamingAll(self.io, frame.bytes) catch |err| {
            log.err("write payload failed [{s}]", .{@errorName(err)});
            return error.TransportFailed;
        };
        self.writer.writeStreamingAll(self.io, "\n") catch |err| {
            log.err("write delimiter failed [{s}]", .{@errorName(err)});
            return error.TransportFailed;
        };
    }

    /// Vtable entry that blocks for the next frame.
    ///
    /// Parameters:
    /// - `ctx`: the transport.
    /// - `allocator`: owns the returned frame.
    ///
    /// Return: the frame, caller-owned; `error.TransportClosed` once drained and closed.
    fn readFrame(ctx: *anyopaque, allocator: std.mem.Allocator) acp.AcpError![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const self: *Self = @ptrCast(@alignCast(ctx));
        return (try self.take(allocator, true)).?;
    }

    /// Vtable entry that reads a queued frame without waiting.
    ///
    /// Parameters:
    /// - `ctx`: the transport.
    /// - `allocator`: owns the returned frame.
    ///
    /// Return: the frame, caller-owned, or null when none is queued; `error.TransportClosed` once drained and closed.
    fn tryReadFrame(ctx: *anyopaque, allocator: std.mem.Allocator) acp.AcpError!?[]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.take(allocator, false);
    }

    /// Vtable entry that closes the transport.
    ///
    /// Parameters:
    /// - `ctx`: the transport.
    ///
    /// Return: nothing.
    fn closeTransport(ctx: *anyopaque) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const self: *Self = @ptrCast(@alignCast(ctx));
        self.close();
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(StdioTransport);
}

test "frames round-trip through a real process's stdio" {
    // `cat` is the smallest real peer: whatever the transport writes to its
    // stdin comes back on its stdout, so this exercises framing, the reader
    // task, and both handles end to end.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var child = try std.process.spawn(io, .{ .argv = &.{"/bin/cat"}, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
    defer _ = child.wait(io) catch {};

    var config = try mod.Config.init();
    defer config.deinit();
    var stdio = try StdioTransport.init(allocator, io, &config, child.stdout.?, child.stdin.?, false);
    defer stdio.deinit();
    try stdio.start();
    const t = stdio.transport();

    try std.testing.expect(t.canPoll());
    try t.writeFrame(.{ .bytes = "{\"n\":1}" });
    try t.writeFrame(.{ .bytes = "{\"n\":2}" });

    const first = try t.readFrame(allocator);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("{\"n\":1}", first);

    const second = try t.readFrame(allocator);
    defer allocator.free(second);
    try std.testing.expectEqualStrings("{\"n\":2}", second);

    // Hanging up `cat`'s stdin ends its stdout, which the reader must report
    // as a closed transport rather than a hang.
    child.stdin.?.close(io);
    child.stdin = null;
    try std.testing.expectError(error.TransportClosed, t.readFrame(allocator));
}

test "a poll returns null while nothing has arrived" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var child = try std.process.spawn(io, .{ .argv = &.{"/bin/cat"}, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
    defer _ = child.wait(io) catch {};

    // Runs after `stdio.deinit`: `cat` still holds its stdin open while the
    // transport tears down, so the reader is cancelled rather than seeing EOF.
    defer {
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var config = try mod.Config.init();
    defer config.deinit();
    var stdio = try StdioTransport.init(allocator, io, &config, child.stdout.?, child.stdin.?, false);
    // Tearing down while the reader is blocked on a live peer must not hang:
    // this is the cancelation path, not the EOF path.
    defer stdio.deinit();
    try stdio.start();
    const t = stdio.transport();

    try std.testing.expectEqual(@as(?[]u8, null), try t.tryReadFrame(allocator));
}

test "a closed transport refuses writes and reports closure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Never started: close alone must be enough to stop every caller.
    var config = try mod.Config.init();
    defer config.deinit();
    var stdio = try StdioTransport.init(allocator, io, &config, std.Io.File.stdin(), std.Io.File.stdout(), false);
    defer stdio.deinit();

    stdio.close();
    const t = stdio.transport();
    try std.testing.expectError(error.TransportClosed, t.writeFrame(.{ .bytes = "x" }));
    try std.testing.expectError(error.TransportClosed, t.readFrame(allocator));
    try std.testing.expectError(error.TransportClosed, t.tryReadFrame(allocator));
}

test "a reply still goes out after the peer has stopped sending" {
    // The peer writes one request, closes its stdout, and keeps reading its
    // stdin: exactly a client that half-closes after its last request.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "printf '{\"id\":1}\\n'; exec 1>&-; cat >/dev/null" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer _ = child.wait(io) catch {};
    defer {
        child.stdin.?.close(io);
        child.stdin = null;
    }

    var config = try mod.Config.init();
    defer config.deinit();
    var stdio = try StdioTransport.init(allocator, io, &config, child.stdout.?, child.stdin.?, false);
    defer stdio.deinit();
    try stdio.start();
    const t = stdio.transport();

    const request = try t.readFrame(allocator);
    defer allocator.free(request);
    try std.testing.expectEqualStrings("{\"id\":1}", request);
    // The input has ended — the next read says so — but the output is still open.
    try std.testing.expectError(error.TransportClosed, t.readFrame(allocator));
    try t.writeFrame(.{ .bytes = "{\"id\":1,\"result\":{}}" });
}

test "a full queue holds the reader back instead of dropping frames" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var child = try std.process.spawn(io, .{ .argv = &.{"/bin/cat"}, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
    defer _ = child.wait(io) catch {};

    var config = try mod.Config.init();
    defer config.deinit();
    config.max_queued_frames = 1;
    var stdio = try StdioTransport.init(allocator, io, &config, child.stdout.?, child.stdin.?, false);
    defer stdio.deinit();
    try stdio.start();
    const t = stdio.transport();

    // Three frames against a queue of one: the old transport kept the first
    // and discarded the rest, so the second read would wait forever.
    try t.writeFrame(.{ .bytes = "{\"n\":1}" });
    try t.writeFrame(.{ .bytes = "{\"n\":2}" });
    try t.writeFrame(.{ .bytes = "{\"n\":3}" });
    for ([_][]const u8{ "{\"n\":1}", "{\"n\":2}", "{\"n\":3}" }) |want| {
        const got = try t.readFrame(allocator);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(want, got);
    }

    child.stdin.?.close(io);
    child.stdin = null;
    try std.testing.expectError(error.TransportClosed, t.readFrame(allocator));
}
