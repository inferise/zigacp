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
//! queue exactly as `FrameTransport` does. Readiness is decided by the queue,
//! never by the OS, which keeps this portable — there is no `poll(2)` on a
//! Windows pipe.
//!
//! Writes go straight to the output handle under their own mutex: every frame
//! is one line, and two tasks writing at once must not interleave halves.
//!
//! Heap-allocated because the reader task borrows it; `deinit` cancels that
//! task (a blocked read is a cancelation point) before anything is freed.

const std = @import("std");
const log = std.log.scoped(.acp_stdio_transport);
const acp = @import("acp");
const Framer = @import("frame.zig").Framer;

/// A file-handle transport whose reads can be polled.
pub const StdioTransport = struct {
    const Self = @This();

    /// Refuse to queue more than this. A peer flooding frames nobody reads is a
    /// bug, and one that eats memory silently is worse than one that says so.
    pub const max_queued_frames = 1024;

    allocator: std.mem.Allocator,
    io: std.Io,
    /// Where frames arrive from; owned by the reader task once started.
    reader: std.Io.File,
    /// Where frames are written.
    writer: std.Io.File,
    /// When true both handles close on `deinit`. False for the process's own stdio.
    own_handles: bool,
    /// Guards `inbound` and `closed`.
    mutex: std.Io.Mutex = .init,
    /// Signalled whenever a frame is queued or the transport closes.
    arrival: std.Io.Condition = .init,
    /// Serialises writers so frames never interleave.
    write_mutex: std.Io.Mutex = .init,
    /// Whole frames read but not yet taken.
    inbound: std.ArrayList([]u8) = .empty,
    /// Set on EOF, a read failure, or `close`.
    closed: bool = false,
    /// The reader task. Exactly one releaser, which is `deinit`.
    reader_group: std.Io.Group = .init,
    /// Whether the reader task was started, so `deinit` knows to cancel it.
    started: bool = false,

    /// Creates a transport over two handles; call `start` before reading.
    ///
    /// Parameters:
    /// - `allocator`: owns the transport and every queued frame; must outlive it.
    /// - `io`: IO capability for the reader task, locks and handle I/O.
    /// - `reader`: the handle frames are read from.
    /// - `writer`: the handle frames are written to.
    /// - `own_handles`: whether `deinit` closes both handles.
    ///
    /// Return: the transport at a stable address, caller calls `deinit`; propagates allocation failure.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, reader: std.Io.File, writer: std.Io.File, own_handles: bool) !*Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const self = try allocator.create(Self);
        self.* = Self{ .allocator = allocator, .io = io, .reader = reader, .writer = writer, .own_handles = own_handles };
        return self;
    }

    /// Stops the reader task, frees every queued frame, and frees the transport.
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
        self.allocator.destroy(self);
    }

    /// Starts the reader task; frames queue from here on.
    ///
    /// Parameters:
    /// - `self`: the transport.
    ///
    /// Return: nothing; `error.ConcurrencyUnavailable` when the IO implementation cannot run a task alongside the caller.
    pub fn start(self: *Self) std.Io.ConcurrentError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // `concurrent`, never `async`: `async` may run the loop inline, and a
        // reader that never returns would then never hand control back.
        try self.reader_group.concurrent(self.io, readLoop, .{self});
        self.started = true;
    }

    /// Returns the vtable view the connection drives.
    ///
    /// Parameters:
    /// - `self`: the transport.
    ///
    /// Return: the transport, borrowing `self`.
    pub fn transport(self: *Self) acp.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Marks the transport closed and wakes every waiter; idempotent.
    ///
    /// Parameters:
    /// - `self`: the transport.
    ///
    /// Return: nothing.
    pub fn close(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return;
        self.closed = true;
        self.arrival.broadcast(self.io);
    }

    /// Reads the input handle until it ends, queueing every whole frame.
    ///
    /// Parameters:
    /// - `self`: the transport.
    ///
    /// Return: nothing; a read failure or cancelation closes the transport rather than propagating.
    fn readLoop(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var framer = Framer.init(self.allocator);
        defer framer.deinit();

        // SAFETY: filled by each read before any byte of it is used.
        var chunk: [4096]u8 = undefined;
        while (true) {
            // A peer hanging up surfaces as `EndOfStream` and a teardown as
            // `Canceled`; both are ordinary endings, not failures.
            const n = self.reader.readStreaming(self.io, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream, error.Canceled => break,
                else => {
                    log.warn("read failed; closing [{s}]", .{@errorName(err)});
                    break;
                },
            };
            if (n == 0) break;

            framer.feed(chunk[0..n]) catch break;
            while (framer.next() catch null) |frame| {
                self.push(frame) catch |err| {
                    self.allocator.free(frame);
                    log.err("dropping inbound frame [{s}]", .{@errorName(err)});
                };
            }
        }
        self.close();
    }

    /// Queues a frame for the reading side, taking ownership of it.
    ///
    /// Parameters:
    /// - `self`: the transport.
    /// - `frame`: the frame, allocated with `self.allocator`; owned by the queue on success.
    ///
    /// Return: nothing; `error.TransportFailed` when the queue is full, or allocation failure.
    fn push(self: *Self, frame: []u8) acp.AcpError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.inbound.items.len >= max_queued_frames) {
            log.err("{d} frames queued and unread; the reader is not serving", .{self.inbound.items.len});
            return error.TransportFailed;
        }
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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.inbound.items.len == 0) {
            // Closed is checked *after* the queue, so frames the peer wrote
            // before hanging up are still delivered.
            if (self.closed) return error.TransportClosed;
            if (!wait) return null;
            self.arrival.waitUncancelable(self.io, &self.mutex);
        }

        const frame = self.inbound.orderedRemove(0);
        defer self.allocator.free(frame);
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
    /// Return: nothing; `error.TransportClosed` once closed, `error.TransportFailed` when the write fails.
    fn writeFrame(ctx: *anyopaque, frame: acp.Frame) acp.AcpError!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);

        if (self.closed) return error.TransportClosed;
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

    const stdio = try StdioTransport.init(allocator, io, child.stdout.?, child.stdin.?, false);
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

    const stdio = try StdioTransport.init(allocator, io, child.stdout.?, child.stdin.?, false);
    try stdio.start();
    const t = stdio.transport();

    try std.testing.expectEqual(@as(?[]u8, null), try t.tryReadFrame(allocator));

    // Tearing down while the reader is blocked on a live peer must not hang:
    // this is the cancelation path, not the EOF path.
    stdio.deinit();
    child.stdin.?.close(io);
    child.stdin = null;
}

test "a closed transport refuses writes and reports closure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Never started: close alone must be enough to stop every caller.
    const stdio = try StdioTransport.init(allocator, io, std.Io.File.stdin(), std.Io.File.stdout(), false);
    defer stdio.deinit();

    stdio.close();
    const t = stdio.transport();
    try std.testing.expectError(error.TransportClosed, t.writeFrame(.{ .bytes = "x" }));
    try std.testing.expectError(error.TransportClosed, t.readFrame(allocator));
    try std.testing.expectError(error.TransportClosed, t.tryReadFrame(allocator));
}
