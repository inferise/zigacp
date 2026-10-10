const std = @import("std");
const log = std.log.scoped(.acp_trace_viewer);
const cli = @import("module.zig");

/// The trace viewer's screen: every frame of a `Trace` on its own row, a `›`
/// cursor on one, and a status line at the foot. `↑↓` move the cursor;
/// `q`, `esc` or `ctrl+c` quit.
///
/// The root widget of the `Session`: keep it at one address for the whole run.
pub const TraceViewer = struct {
    const Self = @This();

    /// Rows the status line takes at the foot.
    const footer_height: u16 = 1;

    trace: *const cli.Trace,
    /// The frame under the cursor.
    cursor: usize = 0,
    /// The first frame drawn last frame, so the window scrolls only as far as the cursor needs.
    top: usize = 0,

    /// A viewer over a trace.
    ///
    /// Parameters:
    /// - `trace`: the frames; borrowed for the viewer's life.
    ///
    /// Return: the viewer, cursor on the first frame.
    pub fn init(trace: *const cli.Trace) Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return .{ .trace = trace };
    }

    /// The viewer as the session's root widget.
    ///
    /// Parameters:
    /// - `self`: the viewer, at its final address.
    ///
    /// Return: the widget.
    pub fn widget(self: *Self) cli.tui.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    /// Moves the cursor or quits on a key.
    ///
    /// Parameters:
    /// - `self`: the viewer.
    /// - `ctx`: the event context.
    /// - `key`: the key pressed.
    ///
    /// Return: nothing; propagates the runtime's errors.
    pub fn handleKey(self: *Self, ctx: *cli.tui.EventContext, key: cli.tui.Key) anyerror!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        if (key.matches('q', .{}) or key.matches(cli.tui.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            ctx.quit = true;
            return;
        }
        if (key.matches(cli.tui.Key.up, .{}) and self.cursor > 0) {
            self.cursor -= 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(cli.tui.Key.down, .{}) and self.cursor + 1 < self.trace.entries.len) {
            self.cursor += 1;
            return ctx.consumeAndRedraw();
        }
    }

    // -------------------------------------------------------------------------
    // Runtime callbacks

    /// Takes the focus at start and routes keys to `handleKey`.
    ///
    /// Parameters:
    /// - `ptr`: the viewer, as opaque userdata.
    /// - `ctx`: the event context.
    /// - `event`: the event.
    ///
    /// Return: nothing; propagates the runtime's errors.
    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *cli.tui.EventContext, event: cli.tui.vxfw.Event) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => return ctx.requestFocus(self.widget()),
            .key_press => |key| return self.handleKey(ctx, key),
            else => {},
        }
    }

    /// Draws the frames that fit, then the status line.
    ///
    /// Parameters:
    /// - `ptr`: the viewer, as opaque userdata.
    /// - `ctx`: the frame's draw context.
    ///
    /// Return: the viewer's surface; propagates allocation failures.
    fn typeErasedDrawFn(ptr: *anyopaque, ctx: cli.tui.DrawContext) std.mem.Allocator.Error!cli.tui.Surface {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        if (max.width == 0 or max.height == 0) return .empty(self.widget());

        var kids: std.ArrayList(cli.tui.SubSurface) = .empty;
        const room: usize = max.height -| footer_height;
        const row_size: cli.tui.Size = .{ .width = max.width, .height = 1 };
        const entries = self.trace.entries;

        if (entries.len == 0) {
            const empty = try ctx.arena.create(cli.tui.vxfw.RichText);
            empty.* = .{ .text = &.{.{ .text = "(empty trace)", .style = cli.tui.Theme.secondaryText.style() }}, .softwrap = false, .overflow = .ellipsis };
            try kids.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = try empty.widget().draw(ctx.withConstraints(row_size, .fromSize(row_size))) });
        }

        self.top = cli.tui.RowCursor.follow(self.top, self.cursor, entries.len, room);
        const end = @min(self.top + room, entries.len);
        for (entries[self.top..end], self.top..) |entry, index| {
            const row = try ctx.arena.create(cli.tui.vxfw.RichText);
            row.* = .{ .text = try rowSpans(ctx, entry, index == self.cursor), .softwrap = false, .overflow = .ellipsis };
            try kids.append(ctx.arena, .{
                .origin = .{ .row = @intCast(index - self.top), .col = 0 },
                .surface = try row.widget().draw(ctx.withConstraints(row_size, .fromSize(row_size))),
            });
        }

        const footer = try ctx.arena.create(cli.tui.vxfw.RichText);
        footer.* = .{ .text = try self.footerSpans(ctx.arena), .softwrap = false, .overflow = .ellipsis };
        try kids.append(ctx.arena, .{
            .origin = .{ .row = max.height -| footer_height, .col = 0 },
            .surface = try footer.widget().draw(ctx.withConstraints(row_size, .fromSize(row_size))),
        });

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = try kids.toOwnedSlice(ctx.arena),
        };
    }

    // -------------------------------------------------------------------------
    // Drawing

    /// One frame's row: the cursor marker, the direction arrow and the frame,
    /// cut to the width (one cell over, so the row ellipsizes) and sanitized.
    ///
    /// Parameters:
    /// - `ctx`: the draw context; its arena owns the spans.
    /// - `entry`: the frame.
    /// - `here`: whether the cursor is on it.
    ///
    /// Return: the spans; propagates allocation failures.
    fn rowSpans(ctx: cli.tui.DrawContext, entry: cli.TraceEntry, here: bool) std.mem.Allocator.Error![]const cli.tui.TextSpan {
        const marker = cli.tui.RowCursor.marker(here);
        const arrow = if (entry.direction == .outbound) "→ " else "← ";
        const lead = cli.tui.TextWidth.of(marker.text) + cli.tui.TextWidth.of(arrow);
        // Frames run to megabytes: only the part that can show is measured and cleaned.
        const width: usize = ctx.max.width orelse 0;
        const shown = entry.bytes[0..cli.tui.TextWidth.fit(entry.bytes, (width -| lead) + 1)];

        const spans = try ctx.arena.alloc(cli.tui.TextSpan, 3);
        spans[0] = marker;
        spans[1] = .{ .text = arrow, .style = cli.tui.Theme.secondaryText.style() };
        spans[2] = .{ .text = try cli.tui.TextSanitizer.clean(ctx.arena, shown), .style = .{ .fg = cli.tui.Theme.primaryText.color(), .bold = here } };
        return spans;
    }

    /// The status line: the cursor's position, then the key hints.
    ///
    /// Parameters:
    /// - `self`: the viewer.
    /// - `allocator`: owns the spans; the frame arena.
    ///
    /// Return: the spans; propagates allocation failures.
    fn footerSpans(self: *const Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const cli.tui.TextSpan {
        const count = self.trace.entries.len;
        const position = try allocator.print("{d}/{d}  ", .{ if (count == 0) 0 else self.cursor + 1, count });
        const hints = try (cli.tui.StatusLine{ .hints = &.{ .{ .key = "↑↓", .action = "frame" }, .{ .key = "q", .action = "quit" } } }).spans(allocator);

        const spans = try allocator.alloc(cli.tui.TextSpan, hints.len + 1);
        spans[0] = .{ .text = position, .style = cli.tui.Theme.secondaryText.style() };
        @memcpy(spans[1..], hints);
        return spans;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
}

/// Presses a key on the viewer as the runtime would.
///
/// Parameters:
/// - `viewer`: the viewer under test.
/// - `ctx`: the event context.
/// - `codepoint`: the key pressed.
///
/// Return: nothing; propagates the handler's errors.
fn press(viewer: *TraceViewer, ctx: *cli.tui.EventContext, codepoint: u21) !void {
    ctx.consume_event = false;
    try TraceViewer.typeErasedEventHandler(viewer, ctx, .{ .key_press = .{ .codepoint = codepoint } });
}

test "trace viewer moves the cursor within the trace and quits on q" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: cli.tui.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    var trace = try cli.Trace.parse(std.testing.allocator, "> a\n< b\n");
    defer trace.deinit();
    var viewer: TraceViewer = .init(&trace);

    try press(&viewer, &ctx, cli.tui.Key.up);
    try std.testing.expectEqual(0, viewer.cursor);
    try press(&viewer, &ctx, cli.tui.Key.down);
    try press(&viewer, &ctx, cli.tui.Key.down);
    try std.testing.expectEqual(1, viewer.cursor);
    try std.testing.expect(!ctx.quit);
    try press(&viewer, &ctx, 'q');
    try std.testing.expect(ctx.quit);
}

test "trace viewer keeps the cursor in view and sanitizes frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    for (0..50) |i| try content.print(std.testing.allocator, "> {{\"id\":{d},\"escape\":\"\x1b[31m\"}}\n", .{i});
    var trace = try cli.Trace.parse(std.testing.allocator, content.items);
    defer trace.deinit();
    var viewer: TraceViewer = .init(&trace);
    viewer.cursor = 40;

    cli.tui.DrawContext.init(.unicode);
    const ctx: cli.tui.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 0, .height = 0 },
        .max = .{ .width = 80, .height = 24 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try viewer.widget().draw(ctx);
    try std.testing.expectEqual(cli.tui.Size{ .width = 80, .height = 24 }, surface.size);
    // 23 rows above the status line, the last of them the cursor's.
    try std.testing.expectEqual(18, viewer.top);
    try std.testing.expectEqual(24, surface.children.len);

    const spans = try TraceViewer.rowSpans(ctx, trace.entries[0], false);
    try std.testing.expect(std.mem.findScalar(u8, spans[2].text, 0x1b) == null);
}

test "trace viewer draws an empty trace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var trace = try cli.Trace.parse(std.testing.allocator, "");
    defer trace.deinit();
    var viewer: TraceViewer = .init(&trace);

    cli.tui.DrawContext.init(.unicode);
    const ctx: cli.tui.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 0, .height = 0 },
        .max = .{ .width = 40, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try viewer.widget().draw(ctx);
    try std.testing.expectEqual(2, surface.children.len);
    try std.testing.expectEqualStrings("0/0  ", (try viewer.footerSpans(arena.allocator()))[0].text);
}
