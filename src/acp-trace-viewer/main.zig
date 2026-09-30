//! Trace viewer.
//!
//! Reads a captured trace from a file (one frame per line, prefixed with
//! `< ` or `> ` for direction) and renders it interactively. Up/Down
//! navigate, q quits.
//!
//! The trace file format is what `acp.TraceBuffer` produces when you
//! dump it via the helper in this binary's library shim — keeping the
//! viewer dependency-light means it works against any tool that emits
//! the same line shape.

const std = @import("std");
const vaxis = @import("vaxis");
const zigstorage = @import("zigstorage");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const Direction = enum { outbound, inbound };

const Entry = struct {
    direction: Direction,
    bytes: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args_it.deinit();
    _ = args_it.next();
    const path = args_it.next() orelse std.process.exit(2);

    const entries = try loadTrace(alloc, io, init.minimal.environ, path);
    defer freeTrace(alloc, entries);

    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, alloc, init.environ_map, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    var selected: usize = 0;

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or (key.codepoint == 'c' and key.mods.ctrl)) break;
                if (key.matches(vaxis.Key.up, .{}) and selected > 0) selected -= 1;
                if (key.matches(vaxis.Key.down, .{}) and selected + 1 < entries.len) selected += 1;
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }

        const win = vx.window();
        win.clear();
        try render(win, entries, selected);
        try vx.render(tty.writer());
    }
}

fn loadTrace(alloc: std.mem.Allocator, io: std.Io, environ: std.process.Environ, path: []const u8) ![]Entry {
    const url = try fileUrlOwned(alloc, io, path);
    defer alloc.free(url);

    var node = try zigstorage.Node.init(alloc, io, environ, url);
    defer node.deinit();
    const content = try node.read(.all);
    defer alloc.free(content);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer freeTrace(alloc, entries.items);

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len < 2) continue;
        const dir: Direction = switch (line[0]) {
            '<' => .inbound,
            '>' => .outbound,
            else => continue,
        };
        if (line[1] != ' ') continue;
        const owned = try alloc.dupe(u8, line[2..]);
        try entries.append(alloc, .{ .direction = dir, .bytes = owned });
    }
    return entries.toOwnedSlice(alloc);
}

/// Spells a filesystem path as a `file://` URL, anchoring a relative one at the working directory.
///
/// Parameters:
/// - `alloc`: owns the returned URL.
/// - `io`: IO capability for reading the working directory.
/// - `path`: the path, relative or absolute.
///
/// Return: the URL, caller-owned; propagates working-directory and allocation failures.
fn fileUrlOwned(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    // Joined rather than resolved, so a `..` is left for the filesystem to follow.
    const absolute = if (std.fs.path.isAbsolute(path)) try alloc.dupe(u8, path) else blk: {
        const cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(cwd);
        break :blk try std.fs.path.join(alloc, &.{ cwd, path });
    };
    defer alloc.free(absolute);

    // Percent-encoded by zigstorage's own rule, so any character in a name
    // reaches the filesystem as written; a drive-rooted path needs the third slash.
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(if (std.mem.startsWith(u8, absolute, "/")) "file://" else "file:///");
    try zigstorage.NodeUrl.encodePath(&out.writer, absolute);
    return out.toOwnedSlice();
}

fn freeTrace(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| alloc.free(e.bytes);
    alloc.free(entries);
}

fn render(win: vaxis.Window, entries: []const Entry, selected: usize) !void {
    if (entries.len == 0) {
        _ = win.printSegment(.{ .text = "(empty trace)" }, .{ .row_offset = 0 });
        return;
    }

    const visible_rows: usize = @intCast(@max(@as(i32, @intCast(win.height)) - 2, 1));
    const start = if (selected >= visible_rows) selected - visible_rows + 1 else 0;
    const end = @min(start + visible_rows, entries.len);

    var row: u16 = 0;
    for (entries[start..end], start..) |entry, idx| {
        const arrow = if (entry.direction == .outbound) "->" else "<-";
        const style: vaxis.Style = if (idx == selected)
            .{ .reverse = true }
        else
            .{};

        var buf: [256]u8 = undefined;
        const summary = entry.bytes[0..@min(entry.bytes.len, 200)];
        const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ arrow, summary }) catch arrow;

        _ = win.printSegment(.{ .text = line, .style = style }, .{ .row_offset = row });
        row += 1;
    }

    var status_buf: [128]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, "[{d}/{d}]  ↑/↓ navigate · q quit", .{ selected + 1, entries.len }) catch "";
    _ = win.printSegment(.{ .text = status, .style = .{ .bold = true } }, .{ .row_offset = win.height - 1 });
}
