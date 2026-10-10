//! A CLI's own sign-in, run on a pseudoterminal so a client can relay it.
//!
//! Every agent CLI signs in the same way at heart: it prints a page to open
//! (and maybe a code to type there), perhaps asks for a code the page hands
//! back, and exits 0 once it holds a sign-in. Some only do so on a terminal, so
//! the CLI runs on one (`acp.Pty.Pair`), and its output is kept as plain text —
//! escapes, colours and hyperlink wrappers dropped by `acp.Pty.VtDecoder` — for
//! the agent to read the page and the code out of. The agent writes the pasted
//! code back; the reader task reaps the CLI and records how it ended.
//!
//! What to run and what to read out of it is each agent's; this is the part
//! they share. Nothing here reads a credential: only what the CLI prints.

const std = @import("std");
const log = std.log.scoped(.acp_pty_login);
const acp = @import("module.zig");
const builtin = @import("builtin");

/// How a sign-in run ended, or that it has not.
pub const PtyLoginEnd = enum {
    /// The CLI is still running.
    running,
    /// The CLI exited 0.
    succeeded,
    /// The CLI exited otherwise, or could not be waited for.
    failed,
};

/// One CLI sign-in, running on a pseudoterminal.
pub const PtyLogin = struct {
    const Self = @This();

    /// Most output kept: plenty for a page, a code and an error.
    pub const max_output = 64 * 1024;
    /// Columns the CLI lays its text out for. Wide, so a long URL stays on one line.
    pub const columns: u16 = 1000;
    /// Rows of the pseudoterminal.
    pub const rows: u16 = 50;
    /// How often a wait looks again.
    const poll_ms = 50;
    /// Bytes read from the pseudoterminal at a time.
    const read_chunk = 4096;
    /// How long the CLI gets to stop after `SIGTERM` before `SIGKILL`.
    const kill_grace_ms = 1000;

    allocator: std.mem.Allocator,
    io: std.Io,
    master: std.Io.File,
    process: std.process.Child,
    /// Turns the CLI's bytes into text; used by the reader task only.
    decoder: acp.Pty.VtDecoder,
    /// Guards everything below between the reader task and the agent.
    mutex: std.Io.Mutex = .init,
    /// What the CLI printed, as plain text, bounded. Owned.
    text: std.ArrayList(u8) = .empty,
    end: PtyLoginEnd = .running,
    reader_group: std.Io.Group = .init,

    /// Starts a CLI's sign-in on a new pseudoterminal.
    ///
    /// The child is its own process group, so stopping it stops whatever it
    /// started (a browser opener, a helper). Give it `TERM=dumb` in
    /// `environ_map` for the plainest output.
    ///
    /// Parameters:
    /// - `allocator`: backs the run; stored.
    /// - `io`: IO capability for the child, the pseudoterminal and the reader task.
    /// - `argv`: the command and its arguments; borrowed for the spawn.
    /// - `environ_map`: the child's whole environment; borrowed for the spawn.
    /// - `cwd`: where it runs, or null for this process's directory.
    ///
    /// Return: the run, `destroy` when done; `error.PtyUnsupported` on Windows, `error.PtyOpenFailed`; propagates spawn failures.
    pub fn start(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, environ_map: *const std.process.Environ.Map, cwd: ?[]const u8) !*Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const pty = try acp.Pty.Pair.open(columns, rows);
        errdefer pty.master.close(io);
        const process = std.process.spawn(io, .{
            .argv = argv,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            .environ_map = environ_map,
            .stdin = .{ .file = pty.slave },
            .stdout = .{ .file = pty.slave },
            .stderr = .{ .file = pty.slave },
            .pgid = if (builtin.os.tag == .windows) null else 0,
        }) catch |err| {
            pty.slave.close(io);
            return err;
        };
        // Held open, the slave would keep the master's reads from ever ending.
        pty.slave.close(io);

        const self = try allocator.create(Self);
        self.* = Self{ .allocator = allocator, .io = io, .master = pty.master, .process = process, .decoder = try acp.Pty.VtDecoder.init() };
        self.reader_group.concurrent(io, readLoop, .{self}) catch {
            self.reader_group.async(io, readLoop, .{self});
        };
        log.info("sign-in started: {s}", .{argv[0]});
        return self;
    }

    /// Stops the CLI if it is still running, and frees the run.
    ///
    /// Parameters:
    /// - `self`: the run; invalid afterwards.
    ///
    /// Return: nothing.
    pub fn destroy(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (self.ended() == .running) self.stop();
        // The reader reaps the child, then ends.
        self.reader_group.await(self.io) catch |err| log.warn("the sign-in reader did not join cleanly [{t}]", .{err});
        self.master.close(self.io);
        self.decoder.deinit();
        self.text.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Types a line into the CLI, as a person pasting it and pressing Enter.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `line`: what to type; surrounding whitespace is dropped.
    ///
    /// Return: nothing; `error.EmptyLine`, `error.Ended` once the CLI has exited; propagates write failures.
    pub fn typeLine(self: *Self, line: []const u8) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyLine;
        if (self.ended() != .running) return error.Ended;
        // A carriage return is Enter on a terminal.
        try self.master.writeStreamingAll(self.io, trimmed);
        try self.master.writeStreamingAll(self.io, "\r");
    }

    /// Copies what the CLI has printed so far, as plain text.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `allocator`: allocates the copy.
    ///
    /// Return: the text, caller-owned; propagates allocation failure.
    pub fn textOwned(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return allocator.dupe(u8, self.text.items);
    }

    /// Reports whether the CLI has ended, and how.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: the end, `running` while it runs.
    pub fn ended(self: *Self) PtyLoginEnd {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.end;
    }

    /// Waits until the CLI's output says enough, or it ends, or time runs out.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `context`: forwarded to `ready`.
    /// - `ready`: whether the text so far holds what the caller waits for.
    /// - `timeout_ms`: the longest to wait.
    ///
    /// Return: true once `ready` says so; false when the CLI ended or time ran out first.
    pub fn waitForText(self: *Self, context: anytype, comptime ready: fn (@TypeOf(context), []const u8) bool, timeout_ms: u64) bool {
        var waited: u64 = 0;
        while (true) {
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                if (ready(context, self.text.items)) return true;
                if (self.end != .running) return false;
            }
            if (waited >= timeout_ms) return false;
            self.io.sleep(.fromMilliseconds(poll_ms), .awake) catch return false;
            waited += poll_ms;
        }
    }

    /// Waits for the CLI to end, or for time to run out.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `timeout_ms`: the longest to wait.
    ///
    /// Return: how it ended; `running` when time ran out first.
    pub fn waitForEnd(self: *Self, timeout_ms: u64) PtyLoginEnd {
        var waited: u64 = 0;
        while (true) {
            const now = self.ended();
            if (now != .running or waited >= timeout_ms) return now;
            self.io.sleep(.fromMilliseconds(poll_ms), .awake) catch return now;
            waited += poll_ms;
        }
    }

    /// Finds the text after a label on the same line, as a CLI prints `Label: value`.
    ///
    /// Parameters:
    /// - `text`: the output.
    /// - `label`: what comes before the value.
    ///
    /// Return: the first word after the label, borrowed; null until a whole one follows it.
    pub fn wordAfter(text: []const u8, label: []const u8) ?[]const u8 {
        const at = std.mem.find(u8, text, label) orelse return null;
        const rest = std.mem.trimStart(u8, text[at + label.len ..], " \t");
        const end = std.mem.findAny(u8, rest, " \t\r\n") orelse return null;
        return if (end == 0) null else rest[0..end];
    }

    /// Finds the first whole URL that starts with a prefix.
    ///
    /// Parameters:
    /// - `text`: the output.
    /// - `prefix`: how the URL starts (`https://`).
    ///
    /// Return: the URL, borrowed; null until a whole one is there.
    pub fn urlStarting(text: []const u8, prefix: []const u8) ?[]const u8 {
        const at = std.mem.find(u8, text, prefix) orelse return null;
        const rest = text[at..];
        const end = std.mem.findAny(u8, rest, " \t\r\n") orelse return null;
        return rest[0..end];
    }

    /// Finds the last line that starts with one of a few words, for a failed sign-in's reason.
    ///
    /// Parameters:
    /// - `text`: the output.
    /// - `starts`: what such a line begins with (`Error:`, `Login failed`).
    ///
    /// Return: the line, trimmed and borrowed; null when there is none.
    pub fn lastLineStarting(text: []const u8, starts: []const []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            for (starts) |opening| {
                if (std.mem.startsWith(u8, line, opening)) found = line;
            }
        }
        return found;
    }

    /// Asks the CLI to stop: `SIGTERM` to its group, then `SIGKILL`.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: nothing.
    fn stop(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (builtin.os.tag == .windows) return;
        const pid = self.process.id orelse return;
        // `std.posix.kill` is irreplaceable: `std.Io` has no signal-by-pid.
        std.posix.kill(-pid, .TERM) catch |err| log.debug("SIGTERM failed [{t}]", .{err});
        if (self.waitForEnd(kill_grace_ms) == .running) std.posix.kill(-pid, .KILL) catch |err| log.debug("SIGKILL failed [{t}]", .{err});
    }

    /// Reads the CLI's output until it ends, then reaps it and records how it ended.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: nothing.
    fn readLoop(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // SAFETY: filled by each read before the bytes it returns are used.
        var chunk: [read_chunk]u8 = undefined;
        while (true) {
            // A master reports the slave's last close as an error (EIO on Darwin),
            // not as a zero-byte read: either way, the CLI has finished.
            const n = self.master.readStreaming(self.io, &.{&chunk}) catch break;
            if (n == 0) break;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.decoder.decode(chunk[0..n], self, absorb) catch |err| log.debug("output not kept [{t}]", .{err});
        }

        const term = self.process.wait(self.io) catch |err| blk: {
            log.warn("waiting for the sign-in failed [{t}]", .{err});
            break :blk null;
        };
        const ok = if (term) |t| switch (t) {
            .exited => |code| code == 0,
            else => false,
        } else false;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.end = if (ok) .succeeded else .failed;
        log.info("sign-in {s}", .{if (ok) "succeeded" else "failed"});
    }

    /// Keeps a decoded event's text; the caller holds the mutex.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `event`: what the decoder saw.
    ///
    /// Return: nothing; propagates allocation failure, past the bound nothing is kept.
    fn absorb(self: *Self, event: acp.Pty.VtEvent) anyerror!void {
        const kept: []const u8 = switch (event) {
            .text => |text| text,
            .lineFeed => "\n",
            .tab => " ",
            else => return,
        };
        const room = max_output -| self.text.items.len;
        try self.text.appendSlice(self.allocator, kept[0..@min(room, kept.len)]);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(PtyLogin);
}

test "a label's word, a URL and an error line are read out of a CLI's text" {
    const printed =
        "To sign in, open this URL in your browser:\n  https://example.com/device?x=1\n" ++
        "Then enter this code: ABCD-1234\nWaiting...\nError: first\nLogin failed: expired\n";
    try std.testing.expectEqualStrings("https://example.com/device?x=1", PtyLogin.urlStarting(printed, "https://").?);
    try std.testing.expectEqualStrings("ABCD-1234", PtyLogin.wordAfter(printed, "enter this code:").?);
    try std.testing.expectEqualStrings("Login failed: expired", PtyLogin.lastLineStarting(printed, &.{ "Error:", "Login failed" }).?);

    // Cut mid-word, nothing is there yet.
    try std.testing.expect(PtyLogin.urlStarting("visit https://example.com/de", "https://") == null);
    try std.testing.expect(PtyLogin.wordAfter("enter this code: AB", "enter this code:") == null);
    try std.testing.expect(PtyLogin.lastLineStarting("all fine\n", &.{"Error:"}) == null);
}

/// The test's wait: the prompt has appeared.
fn asksForCode(_: void, text: []const u8) bool {
    return std.mem.find(u8, text, "code>") != null;
}

test "a sign-in on a pseudoterminal shows its page, takes a typed code and ends by its exit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("TERM", "dumb");

    // A stand-in CLI: prints a coloured page, asks for a code, exits 0 only for the right one.
    const script = "printf '\\033[1mvisit\\033[0m https://example.com/x\\ncode> '; read c; [ \"$c\" = 4321 ] && echo ok";
    const login = try PtyLogin.start(allocator, io, &.{ "/bin/sh", "-c", script }, &environ, null);
    defer login.destroy();

    try std.testing.expect(login.waitForText({}, asksForCode, 5000));
    const text = try login.textOwned(allocator);
    defer allocator.free(text);
    // The escapes are gone; the words are there.
    try std.testing.expect(std.mem.find(u8, text, "visit https://example.com/x") != null);
    try std.testing.expectEqualStrings("https://example.com/x", PtyLogin.urlStarting(text, "https://").?);

    try std.testing.expectError(error.EmptyLine, login.typeLine("  "));
    try login.typeLine("4321");
    try std.testing.expectEqual(PtyLoginEnd.succeeded, login.waitForEnd(5000));
    try std.testing.expectError(error.Ended, login.typeLine("again"));
}

test "a sign-in that is abandoned is stopped, and one that exits non-zero failed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    const waiting = try PtyLogin.start(allocator, io, &.{ "/bin/sh", "-c", "sleep 30" }, &environ, null);
    try std.testing.expectEqual(PtyLoginEnd.running, waiting.waitForEnd(100));
    waiting.destroy();

    const refused = try PtyLogin.start(allocator, io, &.{ "/bin/sh", "-c", "echo 'Error: no'; exit 3" }, &environ, null);
    defer refused.destroy();
    try std.testing.expectEqual(PtyLoginEnd.failed, refused.waitForEnd(5000));
    const text = try refused.textOwned(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Error: no", PtyLogin.lastLineStarting(text, &.{"Error:"}).?);
}
