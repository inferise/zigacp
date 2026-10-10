const std = @import("std");
const log = std.log.scoped(.acp_pty_session);
const acp = @import("module.zig");
const builtin = @import("builtin");

/// Both ends of a freshly allocated pseudoterminal: for a caller that spawns
/// its own program on one, with its own arguments, directory and process group.
pub const PtyPair = struct {
    const Self = @This();

    /// Parent end: writes reach the child's stdin, reads return its output.
    master: std.Io.File,
    /// Child end, handed to the spawned process as all three of its streams.
    slave: std.Io.File,

    /// Bundles the two ends of a pseudoterminal.
    ///
    /// Parameters:
    /// - `master`: the parent end; ownership passes to the pair.
    /// - `slave`: the child end; ownership passes to the pair.
    ///
    /// Return: the pair; never fails today.
    fn init(master: std.Io.File, slave: std.Io.File) !Self {
        return Self{ .master = master, .slave = slave };
    }

    /// Opens a pseudoterminal of a given size.
    ///
    /// Parameters:
    /// - `columns`: its width in cells.
    /// - `rows`: its height in cells.
    ///
    /// Return: both ends, caller closes each; `error.PtyOpenFailed`, or `error.PtyUnsupported` on Windows.
    pub fn open(columns: u16, rows: u16) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return Pty.open(.{ .row = rows, .col = columns, .xpixel = 0, .ypixel = 0 });
    }

    /// Releases nothing; `PtySession.start` closes each end at the point it is done with it.
    ///
    /// Parameters:
    /// - `self`: the pair.
    ///
    /// Return: nothing.
    fn deinit(self: *Self) void {
        _ = self;
    }
};

/// Pseudoterminal allocation, which only POSIX offers.
///
/// Selected at compile time rather than branched on inside `open`, because an
/// `extern "c"` declaration forces a libc dependency on every target that
/// compiles it — and Windows would pay that cost for a symbol it does not have.
/// Its equivalent is ConPTY, a different API this demo does not implement.
///
/// `std.posix.winsize` is used throughout because `std.Io` has no window-size type.
const Pty = switch (builtin.os.tag) {
    .windows => struct {
        const Self = @This();

        /// Reports that this platform has no pseudoterminal.
        ///
        /// Parameters:
        /// - `size`: unused.
        ///
        /// Return: always `error.PtyUnsupported`.
        fn open(size: std.posix.winsize) !PtyPair {
            _ = size;
            return error.PtyUnsupported;
        }

        /// Reports that this platform has no pseudoterminal to resize.
        ///
        /// Parameters:
        /// - `master`: unused.
        /// - `child`: unused.
        /// - `size`: unused.
        ///
        /// Return: always `error.PtyUnsupported`.
        fn resize(master: std.Io.File, child: std.process.Child.Id, size: std.posix.winsize) !void {
            _ = master;
            _ = child;
            _ = size;
            return error.PtyUnsupported;
        }
    },
    else => struct {
        const Self = @This();

        // Zig's standard library has no pseudoterminal API, and this is
        // irreplaceable rather than merely convenient (ZIGSTYLE §B.4.c): an
        // interactive CLI checks `isatty` and refuses its interactive mode when
        // handed a plain pipe. On Darwin it lives in libSystem; elsewhere
        // `build.zig` links libc to resolve it.

        /// `openpty(3)`: allocates a pseudoterminal pair.
        ///
        /// Parameters:
        /// - `amaster`: receives the parent end's descriptor.
        /// - `aslave`: receives the child end's descriptor.
        /// - `name`: receives the slave's path, or null to skip.
        /// - `termp`: initial terminal attributes, or null for defaults.
        /// - `winp`: initial window size, or null.
        ///
        /// Return: zero on success, nonzero on failure.
        extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const std.posix.winsize) c_int;

        /// Allocates a pseudoterminal and returns both of its ends.
        ///
        /// Parameters:
        /// - `size`: the initial window size.
        ///
        /// Return: both ends, blocking; `error.PtyOpenFailed` when allocation is refused.
        fn open(size: std.posix.winsize) !PtyPair {
            // SAFETY: written by `openpty`, and read only when it reports success.
            var master_fd: c_int = undefined;
            // SAFETY: same.
            var slave_fd: c_int = undefined;
            if (openpty(&master_fd, &slave_fd, null, null, &size) != 0) return error.PtyOpenFailed;

            // Both ends stay blocking: the child expects that of its stdio, and
            // the pump's reads rely on it.
            return PtyPair.init(
                .{ .handle = @intCast(master_fd), .flags = .{ .nonblocking = false } },
                .{ .handle = @intCast(slave_fd), .flags = .{ .nonblocking = false } },
            );
        }

        /// `TIOCSWINSZ`. Zig declares it for Linux but not for Darwin, where only
        /// the matching *get* is spelled out, so the BSD encoding is reproduced
        /// here: the write bit, the payload's size, the group letter, and the
        /// request number, which is what `_IOW('t', 103, struct winsize)` packs.
        const set_window_size: u32 = if (@hasDecl(std.posix.T, "IOCSWINSZ"))
            std.posix.T.IOCSWINSZ
        else
            0x80000000 | (@as(u32, @sizeOf(std.posix.winsize)) << 16) | ('t' << 8) | 103;

        /// Resizes an open pseudoterminal and signals the child that it changed.
        ///
        /// Parameters:
        /// - `master`: the parent end of the pseudoterminal.
        /// - `child`: the process to signal.
        /// - `size`: the new window size.
        ///
        /// Return: nothing; `error.PtyResizeFailed` when the ioctl is refused (signal failures are only logged).
        fn resize(master: std.Io.File, child: std.process.Child.Id, size: std.posix.winsize) !void {
            // `ioctl` and signals have no `std.Io` equivalent (ZIGSTYLE §B.4.c).
            //
            // The request sets its top bit, so it does not fit the positive
            // half of the `c_int` that `ioctl` declares its second parameter as.
            const request: c_int = @bitCast(set_window_size);
            if (std.c.ioctl(master.handle, request, &size) != 0) return error.PtyResizeFailed;

            // The ioctl alone only changes what `TIOCGWINSZ` reports; a program
            // re-reads it on `SIGWINCH`. The kernel would raise that on the
            // terminal's foreground process group, but there is none: making one
            // needs `setsid` + `TIOCSCTTY` between fork and exec, which
            // `std.process.spawn` cannot do. So the signal is delivered by hand,
            // and a failure is logged rather than returned — the size is right
            // either way.
            std.posix.kill(child, .WINCH) catch |err| {
                log.warn("could not tell the session it was resized [{t}]", .{err});
            };
        }
    },
};

/// A run of raw terminal bytes, and the offset that follows it.
///
/// The offset is returned rather than derived, because it is not always the
/// requested one plus the run's length: a reader that asks for bytes the ring
/// has already dropped is answered with the oldest it still holds, and has to
/// learn where that left it.
pub const RawSlice = struct {
    const Self = @This();

    /// The bytes; owned by whoever asked for them.
    bytes: []u8,
    /// Total bytes the terminal had produced once these had been read.
    offset: usize,

    /// Bundles a run of bytes with the offset that follows it.
    ///
    /// Parameters:
    /// - `bytes`: the run; ownership passes to the slice's holder.
    /// - `offset`: total bytes produced once the run was read.
    ///
    /// Return: the slice; never fails today.
    pub fn init(bytes: []u8, offset: usize) !Self {
        return Self{ .bytes = bytes, .offset = offset };
    }

    /// Releases nothing; the holder frees `bytes` with the allocator it passed to `rawSince`.
    ///
    /// Parameters:
    /// - `self`: the slice.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

/// A CLI running on a pseudoterminal, and what it has printed.
///
/// The first of three layers, and the only one that touches the operating
/// system: this produces the bytes, `VtDecoder` says what they ask for, and
/// `VtScreen` is the screen they ask about. Reach for it when a program has to
/// be run the way a terminal would run it rather than behind a pipe — an
/// interactive CLI checks `isatty` and refuses its interactive mode otherwise.
///
/// `Client.PtyTerminal` serves ACP's `terminal/*` methods on it, so an agent
/// asking its client to run a command gets a real terminal.
///
/// Both readings of the output are kept. `raw` is the bytes untouched, for a
/// consumer with a real emulator to render; `screen` is what `VtDecoder` and
/// `VtScreen` make of the same bytes, for one without.
pub const PtySession = struct {
    const Self = @This();

    /// Refuse anything larger in one write.
    pub const max_prompt_len = 32 * 1024;

    /// End of text, the byte a terminal sends for Ctrl-C.
    const etx: u8 = 0x03;

    /// Escape, the byte a terminal sends for the Esc key.
    const esc: u8 = 0x1b;

    /// How long the CLI is given to act on `SIGTERM` before `SIGKILL`. Long
    /// enough for a graceful exit, short enough that quitting feels immediate.
    const terminate_grace_ms: u64 = 200;

    /// Ring the raw stream down to this when it grows past twice the size, so a
    /// long session cannot grow without bound.
    const raw_limit = 256 * 1024;

    /// Size the terminal starts at, replaced by the browser's own the moment a
    /// page measures its terminal pane. Only the fallback matters: the CLI lays
    /// its output out to fit, and a size it never hears about again would wrap
    /// every line against a pane of a different width.
    pub const initial_columns: u16 = 120;
    pub const initial_rows: u16 = 40;

    /// Terminal the CLI is told it is talking to. It has to name a real
    /// terminfo entry the CLI recognises, and it has to match what the page's
    /// emulator implements — xterm.js implements xterm's.
    const terminal_type = "xterm-256color";

    allocator: std.mem.Allocator,
    io: std.Io,
    /// Parent end of the pseudoterminal: writes reach the CLI's stdin, reads
    /// return whatever it printed.
    master: std.Io.File,
    child: std.process.Child,
    /// Raw bytes exactly as the terminal produced them: what the page's emulator
    /// renders, and what the decoder's output is compared against.
    raw: std.ArrayList(u8) = .empty,
    /// How many bytes the ring has already dropped off the front of `raw`.
    ///
    /// Added to `raw.items.len` this is the total the terminal has ever
    /// produced, which is the offset a reader resumes from. A reader cannot
    /// resume from a plain index into `raw`, because a trim renumbers every one
    /// of them.
    raw_base: usize = 0,
    /// The same bytes as a screen, which is the only reading of them that can
    /// represent a program painting by cursor address. Owns its own decoder.
    screen: acp.Pty.VtScreen,
    /// Guards `raw` and `screen` between the pump task and HTTP handlers.
    mutex: std.Io.Mutex = .init,
    /// Cleared when the pump sees end of stream.
    alive: std.atomic.Value(bool) = .init(true),
    /// Reader task for the master side.
    group: std.Io.Group = .init,

    /// Starts a CLI on a new pseudoterminal and begins capturing its output.
    ///
    /// Parameters:
    /// - `allocator`: backs the session and its buffers; must outlive it.
    /// - `io`: IO capability for spawning and reading.
    /// - `environ_map`: full child environment; borrowed, and `TERM` is set on it.
    /// - `command`: the CLI to run.
    ///
    /// Return: the running session, heap-owned until `deinit`; `error.PtyOpenFailed`, `error.PtyUnsupported`, or the spawn error.
    pub fn start(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, command: []const u8) !*Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const pty = try Pty.open(.{ .row = initial_rows, .col = initial_columns, .xpixel = 0, .ypixel = 0 });
        const master = pty.master;
        const slave = pty.slave;
        errdefer master.close(io);

        // The page runs a terminal emulator, so the CLI is asked for the real
        // thing. This used to say "dumb", because a linear transcript cannot
        // represent a screen and the CLI's line-oriented fallback was the only
        // output that survived being stripped of its escapes; an emulator
        // renders the screen instead, and a dumb terminal would deny it colour,
        // cursor addressing, and the full-screen interface it exists to show.
        try environ_map.put("TERM", terminal_type);

        // The child gets the slave end as all three streams, so `isatty` holds
        // and it starts its interactive interface.
        var child = std.process.spawn(io, .{
            .argv = &.{command},
            .environ_map = environ_map,
            .stdin = .{ .file = slave },
            .stdout = .{ .file = slave },
            .stderr = .{ .file = slave },
        }) catch |err| {
            slave.close(io);
            return err;
        };
        errdefer _ = child.kill(io);

        // The parent has no use for the slave end, and holding it open would
        // stop reads from ever seeing end of stream when the child exits.
        slave.close(io);

        var screen = try acp.Pty.VtScreen.init(allocator, initial_columns, initial_rows);
        errdefer screen.deinit();

        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .io = io,
            .master = master,
            .child = child,
            .screen = screen,
        };

        self.group.concurrent(io, pumpLoop, .{self}) catch {
            self.group.async(io, pumpLoop, .{self});
        };

        log.info("interactive session started", .{});
        return self;
    }

    /// Stops the CLI and releases everything the session owns, including itself.
    ///
    /// Parameters:
    /// - `self`: the session to tear down; invalid afterwards.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.alive.store(false, .release);

        // The order below is the only one that terminates, and both of the
        // obvious ones deadlock.
        //
        // `Child.kill` sends `SIGTERM` and then *waits* for the child, so it
        // never returns for a program that handles the signal and keeps
        // running — an interactive CLI is exactly that. And closing the master
        // first blocks instead, because the pump task is sitting in a read on
        // it. So: signal without waiting, let the pump's read end on its own
        // now that the child is gone, join it, and only then close and reap.
        //
        // `SIGTERM` first because a CLI may have state worth flushing, then
        // `SIGKILL` because nothing here can afford to wait on whether it did.
        //
        // POSIX-only, and guarded rather than branched inside `Pty`: Windows has
        // no signals and no pseudoterminal either, so `open` has already refused
        // and there is nothing running to stop. `std.posix.kill` because `std.Io`
        // has no signal API.
        if (builtin.os.tag != .windows) {
            if (self.child.id) |pid| {
                std.posix.kill(pid, .TERM) catch |err| {
                    log.debug("could not ask the session to stop [{t}]", .{err});
                };
                self.io.sleep(.fromMilliseconds(terminate_grace_ms), .awake) catch |err| {
                    log.debug("the session's grace period was cut short [{t}]", .{err});
                };
                std.posix.kill(pid, .KILL) catch |err| {
                    log.debug("could not stop the session [{t}]", .{err});
                };
            }
        }

        // The child is gone, so the pump's read on the master ends and the task
        // returns; this joins it.
        self.group.cancel(self.io);

        // Safe only now that nothing is reading it.
        self.master.close(self.io);

        // Reaps. The child is already dead, so this returns at once.
        _ = self.child.kill(self.io);
        self.screen.deinit();
        self.raw.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Writes a prompt to the CLI and submits it.
    ///
    /// Parameters:
    /// - `self`: the running session.
    /// - `prompt`: text to send; borrowed.
    ///
    /// Return: nothing; `error.EmptyPrompt`, `error.PromptTooLong`, `error.SessionClosed`, or a write/allocation failure.
    pub fn send(self: *Self, prompt: []const u8) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (prompt.len == 0) return error.EmptyPrompt;
        if (prompt.len > max_prompt_len) return error.PromptTooLong;
        if (!self.alive.load(.acquire)) return error.SessionClosed;

        var payload: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload.deinit();

        const multiline = std.mem.findScalar(u8, prompt, '\n') != null or
            std.mem.findScalar(u8, prompt, '\r') != null;

        // Ported from `send_to_terminal`; each step prevents a specific failure:
        // 1. Line endings are normalized so the trailing CR is the *only* submit
        //    byte — the CLI treats a bare CR at its prompt as Enter.
        // 2. Multi-line text is wrapped in bracketed-paste markers so embedded
        //    newlines arrive as one literal block, not a submit per line.
        // 3. The submit CR goes *after* the closing marker, so it still submits.
        if (multiline) try payload.writer.writeAll("\x1b[200~");
        try writeNormalized(&payload.writer, prompt);
        if (multiline) try payload.writer.writeAll("\x1b[201~");
        try payload.writer.writeAll("\r");

        log.debug("sending {d} byte(s) to the session", .{payload.written().len});
        try self.master.writeStreamingAll(self.io, payload.written());
    }

    /// Sends Ctrl-C to the CLI as a keystroke.
    ///
    /// Parameters:
    /// - `self`: the running session.
    ///
    /// Return: nothing; `error.SessionClosed` when the CLI has exited, or a write failure.
    pub fn interrupt(self: *Self) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        // A keystroke, not `SIGINT`: the child has no controlling terminal
        // (`std.process.spawn` cannot `setsid`), so the line discipline has no
        // foreground group to signal, and a raw-mode CLI reads its own keys.
        return self.sendControl(etx);
    }

    /// Sends the Esc key to the CLI.
    ///
    /// Parameters:
    /// - `self`: the running session.
    ///
    /// Return: nothing; `error.SessionClosed` when the CLI has exited, or a write failure.
    pub fn escape(self: *Self) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return self.sendControl(esc);
    }

    /// Renders what is currently on the session's screen as text.
    ///
    /// Parameters:
    /// - `self`: the session.
    /// - `allocator`: owns the returned text.
    ///
    /// Return: the screen text, caller-owned; propagates lock and allocation failure.
    pub fn snapshotOwned(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // A terminal repaints in place, so overwritten lines are gone rather
        // than kept above their replacement.
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.screen.renderOwned(allocator);
    }

    /// Copies all raw terminal bytes still retained.
    ///
    /// Parameters:
    /// - `self`: the session.
    /// - `allocator`: owns the returned copy.
    ///
    /// Return: the raw bytes, caller-owned; propagates lock and allocation failure.
    pub fn rawSnapshotOwned(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return allocator.dupe(u8, self.raw.items);
    }

    /// Copies the raw terminal bytes produced after `offset`.
    ///
    /// Parameters:
    /// - `self`: the session.
    /// - `allocator`: owns the returned bytes.
    /// - `offset`: total bytes the reader has already seen; `0` for everything retained.
    ///
    /// Return: the new bytes (caller-owned) and the offset to resume from; propagates lock and allocation failure.
    pub fn rawSinceOwned(self: *Self, allocator: std.mem.Allocator, offset: usize) !RawSlice {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // An emulator is fed a stream, not a snapshot: replaying bytes it has
        // rendered would re-run their escapes. Asking only for what is new also
        // keeps a multi-byte character or escape whole across two reads.
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const total = self.raw_base + self.raw.items.len;
        // A reader that fell behind the ring gets the oldest bytes still held.
        // It has lost the bytes between, and its emulator will render the first
        // of these mid-sequence; there is nothing left to hand it instead.
        const from = @max(offset, self.raw_base);
        if (from >= total) return .{ .bytes = &.{}, .offset = total };

        return .{ .bytes = try allocator.dupe(u8, self.raw.items[from - self.raw_base ..]), .offset = total };
    }

    /// Resizes the terminal and its screen model.
    ///
    /// Parameters:
    /// - `self`: the running session.
    /// - `columns`: visible columns; at least one.
    /// - `rows`: visible rows; at least one.
    ///
    /// Return: nothing; `error.SessionClosed` when the CLI has exited, or the resize/allocation failure.
    pub fn resize(self: *Self, columns: u16, rows: u16) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (!self.alive.load(.acquire)) return error.SessionClosed;

        const child = self.child.id orelse return error.SessionClosed;
        try Pty.resize(self.master, child, .{
            .row = @max(1, rows),
            .col = @max(1, columns),
            .xpixel = 0,
            .ypixel = 0,
        });

        // The screen has to agree with the terminal it is modelling, or every
        // line the CLI now writes for the new width wraps at the old one.
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.screen.resize(columns, rows);

        log.debug("terminal resized to {d}x{d}", .{ columns, rows });
    }

    /// Reports whether the CLI is still running.
    ///
    /// Parameters:
    /// - `self`: the session to check.
    ///
    /// Return: true while the CLI is running.
    pub fn isAlive(self: *Self) bool {
        return self.alive.load(.acquire);
    }

    /// Writes one control byte to the CLI unmodified.
    ///
    /// Parameters:
    /// - `self`: the running session.
    /// - `byte`: the byte a terminal would send for the key.
    ///
    /// Return: nothing; `error.SessionClosed` when the CLI has exited, or a write failure.
    fn sendControl(self: *Self, byte: u8) !void {
        // Not through `send`: its normalisation, bracketed paste and submit CR
        // are right for a prompt and wrong for a forwarded key.
        if (!self.alive.load(.acquire)) return error.SessionClosed;
        try self.master.writeStreamingAll(self.io, &.{byte});
    }

    /// Writes text with every CRLF or bare CR collapsed to a single LF.
    ///
    /// Parameters:
    /// - `writer`: destination for the normalized text.
    /// - `text`: the text to write.
    ///
    /// Return: nothing; propagates writer errors.
    fn writeNormalized(writer: *std.Io.Writer, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\r') {
                // Swallow the LF of a CRLF pair so it becomes one newline.
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
                try writer.writeAll("\n");
            } else {
                try writer.writeByte(text[i]);
            }
        }
    }

    /// Reads the terminal until the CLI exits, recording everything it prints.
    ///
    /// Parameters:
    /// - `self`: the session to read from.
    ///
    /// Return: nothing.
    fn pumpLoop(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // SAFETY: only the prefix copied from the reader's buffer is read.
        var chunk: [8 * 1024]u8 = undefined;
        // SAFETY: owned by `file_reader`, which fills it before exposing any byte.
        var read_buffer: [8 * 1024]u8 = undefined;
        var file_reader = self.master.readerStreaming(self.io, &read_buffer);
        const reader = &file_reader.interface;

        while (self.alive.load(.acquire)) {
            reader.fillMore() catch {
                // The CLI exited, or the terminal went away.
                break;
            };
            const available = reader.buffered();
            if (available.len == 0) continue;

            @memcpy(chunk[0..@min(chunk.len, available.len)], available[0..@min(chunk.len, available.len)]);
            const taken = @min(chunk.len, available.len);
            reader.toss(taken);

            self.append(chunk[0..taken]) catch |err| {
                log.warn("could not record session output [{t}]", .{err});
            };
        }

        self.alive.store(false, .release);
        log.info("interactive session ended", .{});
    }

    /// Records output both raw and painted onto the screen.
    ///
    /// Parameters:
    /// - `self`: the session recording the output.
    /// - `bytes`: raw terminal output; borrowed.
    ///
    /// Return: nothing; propagates lock and allocation failure.
    fn append(self: *Self, bytes: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.raw.appendSlice(self.allocator, bytes);
        try self.screen.write(bytes);

        // Only the raw stream needs trimming. The screen is a fixed grid, so it
        // is already bounded by the size of the terminal.
        if (self.raw.items.len > raw_limit * 2) {
            const dropped = self.raw.items.len - raw_limit;
            std.mem.copyForwards(u8, self.raw.items[0..raw_limit], self.raw.items[dropped..]);
            self.raw.shrinkRetainingCapacity(raw_limit);
            self.raw_base += dropped;
        }
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(PtySession);
}

test "a prompt's line endings collapse so only the trailing return submits" {
    const allocator = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // A bare CR or a CRLF inside the text would submit the prompt early, which
    // is the failure the bracketed-paste wrapping exists to prevent.
    try PtySession.writeNormalized(&out.writer, "one\r\ntwo\rthree\nfour");

    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour", out.written());
}

test "text without line endings is passed through untouched" {
    const allocator = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try PtySession.writeNormalized(&out.writer, "no line endings here");

    try std.testing.expectEqualStrings("no line endings here", out.written());
}

test "a pair carries what the child end writes to the parent end" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const pair = try PtyPair.open(80, 24);
    defer pair.master.close(io);
    defer pair.slave.close(io);

    try pair.slave.writeStreamingAll(io, "ok\n");
    // SAFETY: filled by the read below before it is compared.
    var buffer: [16]u8 = undefined;
    const n = try pair.master.readStreaming(io, &.{&buffer});
    try std.testing.expect(std.mem.startsWith(u8, buffer[0..n], "ok"));
}
