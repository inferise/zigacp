//! One agent's conversation as a pane: folded from its client's record, scrolled, drawn.
//!
//! What every screen that shows an ACP conversation repeats, and nothing else:
//! the `Conversation` folded from a `Client.Session`'s record, where the view
//! sits (following the foot, or anchored on a row), and the rows drawn for the
//! room it is given. The screen around it keeps the prompt, the menus, the
//! status line and the keyboard; it hands the pane the scroll keys
//! (`handleScrollKey`) and asks it which permission answer a key means
//! (`permissionAnswer`). A screen of several agents keeps one pane per agent,
//! so each keeps its own place.

const std = @import("std");
const log = std.log.scoped(.acp_tui_chat_pane);
const mod = @import("module.zig");

/// Where a scroll lands.
pub const ScrollTarget = union(enum) {
    /// At the foot, following what arrives.
    follow,
    /// With this row at the top.
    line: usize,
};

/// One agent's conversation, its place in it, and how it is drawn.
pub const ChatPane = struct {
    const Self = @This();

    /// Rows moved by a shifted arrow.
    pub const scroll_step: isize = 3;

    /// How a frame draws the pane.
    pub const DrawOptions = struct {
        /// The widget the surface reports as its own: the screen's, which keeps focus.
        owner: mod.zigtui.Widget,
        /// The heading of the agent's turns.
        agent: []const u8,
        /// Whether tool calls show their input and output.
        expanded: bool = false,
        /// Whether a turn is running; a line at the foot says so.
        working: bool = false,
        /// Entries drawn ahead of the conversation: what came before this client's record.
        before: []const mod.zigtui.TranscriptEntry = &.{},
        /// The line shown when there is nothing at all.
        empty: []const u8 = "  nothing yet — send a prompt",
    };

    allocator: std.mem.Allocator,
    /// What the agent said, folded from the record.
    conversation: mod.Conversation,
    /// Whose record was folded; a different one starts the conversation over. Compared, never dereferenced.
    source: ?*const anyopaque = null,
    /// The record position folded up to.
    next: usize = 0,

    /// Rows the pane had at the last draw.
    rows: u16 = 0,
    /// Rows the conversation took at the last draw.
    total: usize = 0,
    /// Whether the view keeps to the foot.
    following: bool = true,
    /// The row at the top while not following.
    scroll_line: usize = 0,
    /// The row the last draw put at the top, where a scroll that starts while following carries on from.
    last_top_line: usize = 0,

    /// Creates an empty pane.
    ///
    /// Parameters:
    /// - `allocator`: backs the conversation.
    ///
    /// Return: the pane; `deinit` frees it.
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .conversation = mod.Conversation.init(allocator) };
    }

    /// Frees the conversation.
    ///
    /// Parameters:
    /// - `self`: the pane.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        self.conversation.deinit();
    }

    // -------------------------------------------------------------------------
    // The record

    /// Names whose record the pane folds; a different one than before starts the conversation over.
    ///
    /// Parameters:
    /// - `self`: the pane.
    /// - `source`: the client, or anything that identifies its record; compared, never dereferenced.
    ///
    /// Return: nothing.
    pub fn follows(self: *Self, source: *const anyopaque) void {
        if (self.source == source) return;
        self.conversation.clear();
        self.source = source;
        self.next = 0;
    }

    /// Folds a page of the record read from `next` into the conversation.
    ///
    /// Parameters:
    /// - `self`: the pane.
    /// - `arena`: scratch for the notes' parse.
    /// - `page`: the page; one that restarted, or ends before `next`, replaces everything folded.
    ///
    /// Return: nothing; propagates allocation failure; an update it cannot draw is skipped.
    pub fn fold(self: *Self, arena: std.mem.Allocator, page: mod.acp.Client.RecordPage) std.mem.Allocator.Error!void {
        if (page.restarted or page.next < self.next) self.conversation.clear();
        for (page.entries) |entry| {
            // The client's own lines ride in the record as `{"note":…}`.
            if (std.mem.startsWith(u8, entry, "{\"note\":")) {
                const note = std.json.parseFromSliceLeaky(struct { note: []const u8 }, arena, entry, .{}) catch continue;
                try self.conversation.addNote(note.note);
                continue;
            }
            self.conversation.applyJson(entry) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => log.debug("an update not drawn [{t}]", .{err}),
            };
        }
        self.next = page.next;
    }

    /// Folds what a client recorded since the last fold.
    ///
    /// Parameters:
    /// - `self`: the pane.
    /// - `arena`: the frame's arena, for the record's copies.
    /// - `client`: the agent's client.
    ///
    /// Return: nothing; propagates allocation failure; a record that cannot be read leaves the conversation as it was.
    pub fn foldClient(self: *Self, arena: std.mem.Allocator, client: *mod.acp.Client.Session) std.mem.Allocator.Error!void {
        self.follows(client);
        const page = client.recordSince(arena, self.next) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        try self.fold(arena, page);
    }

    // -------------------------------------------------------------------------
    // Keys

    /// Takes a scroll key: page up and down, shifted arrows, home and end.
    ///
    /// Parameters:
    /// - `self`: the pane.
    /// - `key`: the key.
    ///
    /// Return: true when it was a scroll key.
    pub fn handleScrollKey(self: *Self, key: mod.zigtui.Key) bool {
        const page: isize = @intCast(@max(self.rows, 1));
        if (key.matches(mod.zigtui.Key.page_up, .{})) {
            self.scrollBy(-page);
        } else if (key.matches(mod.zigtui.Key.page_down, .{})) {
            self.scrollBy(page);
        } else if (key.matches(mod.zigtui.Key.up, .{ .shift = true })) {
            self.scrollBy(-scroll_step);
        } else if (key.matches(mod.zigtui.Key.down, .{ .shift = true })) {
            self.scrollBy(scroll_step);
        } else if (key.matches(mod.zigtui.Key.home, .{})) {
            self.scrollBy(std.math.minInt(isize));
        } else if (key.matches(mod.zigtui.Key.end, .{})) {
            self.follow();
        } else return false;
        return true;
    }

    /// The permission answer a key gives: `y` once, `a` always, `n` no.
    ///
    /// Parameters:
    /// - `key`: the key.
    ///
    /// Return: the answer, or null for any other key.
    pub fn permissionAnswer(key: mod.zigtui.Key) ?mod.acp.Client.Answer {
        if (key.matches('y', .{})) return .allowOnce;
        if (key.matches('a', .{})) return .allowAlways;
        if (key.matches('n', .{})) return .rejectOnce;
        return null;
    }

    /// The hints a permission question carries on the status line.
    pub const permission_hints = [_]mod.zigtui.KeyHint{ .{ .key = "y", .action = "yes" }, .{ .key = "a", .action = "always" }, .{ .key = "n", .action = "no" } };

    // -------------------------------------------------------------------------
    // Scrolling

    /// Scrolls the view by `delta` rows, resuming follow at the foot.
    ///
    /// Parameters:
    /// - `self`: the pane.
    /// - `delta`: rows to move; negative is towards the start.
    ///
    /// Return: nothing.
    pub fn scrollBy(self: *Self, delta: isize) void {
        // A scroll that starts while following carries on from where the view is, which only the last draw knows.
        const from = if (self.following) self.last_top_line else self.scroll_line;
        // Counted so a view whose last row is at the foot counts as at the foot.
        switch (scrollTarget(from, delta, self.total -| self.rows + 1, self.following)) {
            .follow => self.follow(),
            .line => |line| {
                self.following = false;
                self.scroll_line = line;
            },
        }
    }

    /// Returns the view to its foot and keeps it there.
    ///
    /// Parameters:
    /// - `self`: the pane.
    ///
    /// Return: nothing.
    pub fn follow(self: *Self) void {
        self.following = true;
        self.scroll_line = 0;
    }

    /// Computes where a scroll lands.
    ///
    /// Parameters:
    /// - `from`: the row currently at the top.
    /// - `delta`: rows to move; negative is towards the start.
    /// - `total_lines`: how many rows the conversation has.
    /// - `following`: whether the view keeps to the foot.
    ///
    /// Return: where the view should sit.
    pub fn scrollTarget(from: usize, delta: isize, total_lines: usize, following: bool) ScrollTarget {
        if (following and delta >= 0) return .follow;
        // Following with the first row at the top: it all fits, and leaving the foot would show nothing new.
        if (following and from == 0) return .follow;

        const signed_from: isize = @intCast(@min(from, std.math.maxInt(isize)));
        // Saturating addition: `Home` passes `minInt`, which has no positive counterpart to subtract.
        const moved = signed_from +| delta;
        if (moved <= 0) return .{ .line = 0 };

        const target: usize = @intCast(moved);
        if (target + 1 >= total_lines) return .follow;
        return .{ .line = target };
    }

    // -------------------------------------------------------------------------
    // Drawing

    /// Draws the conversation into the room the context gives: the foot while following, an anchored row while not.
    ///
    /// Parameters:
    /// - `self`: the pane.
    /// - `ctx`: the draw context; its maximum is the pane's size.
    /// - `options`: what to draw around the conversation.
    ///
    /// Return: the surface; propagates allocation failure.
    pub fn draw(self: *Self, ctx: mod.zigtui.DrawContext, options: DrawOptions) std.mem.Allocator.Error!mod.zigtui.Surface {
        const size = ctx.max.size();
        self.rows = size.height;

        const view = mod.ConversationView{ .conversation = &self.conversation, .agent = options.agent, .expanded = options.expanded };
        var entries: std.ArrayList(mod.zigtui.TranscriptEntry) = .empty;
        try entries.appendSlice(ctx.arena, options.before);
        try entries.appendSlice(ctx.arena, try view.entries(ctx.arena));
        if (options.working) try entries.append(ctx.arena, .{ .text = "working… (esc cancels)", .role = .warningText });
        const lines: []const []const mod.zigtui.TextSpan = if (entries.items.len == 0)
            try ctx.arena.dupe([]const mod.zigtui.TextSpan, &.{try ctx.arena.dupe(mod.zigtui.TextSpan, &.{.{ .text = options.empty, .style = mod.zigtui.Theme.secondaryText.style() }})})
        else
            try (mod.zigtui.TranscriptView{ .entries = entries.items }).lines(ctx.arena, size.width);

        self.total = lines.len;
        const top = if (self.following) lines.len -| size.height else @min(self.scroll_line, lines.len -| 1);
        self.last_top_line = top;
        const shown = lines[top..@min(lines.len, top + size.height)];

        const children = try ctx.arena.alloc(mod.zigtui.SubSurface, shown.len);
        for (shown, children, 0..) |spans, *child, r| {
            const text = try ctx.arena.create(mod.zigtui.vxfw.RichText);
            text.* = .{ .text = spans, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
            const row: mod.zigtui.Size = .{ .width = size.width, .height = 1 };
            child.* = .{ .origin = .{ .row = @intCast(r), .col = 0 }, .surface = try text.widget().draw(ctx.withConstraints(row, .fromSize(row))) };
        }
        return .{ .size = size, .widget = options.owner, .buffer = &.{}, .children = children };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ChatPane);
}

test "scrolling up from the foot carries on from where the view is" {
    // Following, so the starting point is the row the last draw put at the top.
    try std.testing.expectEqual(@as(usize, 37), ChatPane.scrollTarget(40, -3, 100, true).line);
}

test "scrolling down while following stays at the foot" {
    try std.testing.expectEqual(ScrollTarget.follow, ChatPane.scrollTarget(40, 3, 100, true));
}

test "scrolling past the end resumes following rather than stopping short" {
    // `End` and "page down until it stops" arrive at the same place.
    try std.testing.expectEqual(ScrollTarget.follow, ChatPane.scrollTarget(95, 10, 100, false));
}

test "scrolling to the top clamps at the first row" {
    try std.testing.expectEqual(@as(usize, 0), ChatPane.scrollTarget(40, std.math.minInt(isize), 100, false).line);
}

test "scrolling up a conversation that fits stays at the foot" {
    try std.testing.expectEqual(ScrollTarget.follow, ChatPane.scrollTarget(0, -3, 1, true));
}

test "scrolling up from a scrolled view moves from where it sits" {
    try std.testing.expectEqual(@as(usize, 6), ChatPane.scrollTarget(10, -4, 100, false).line);
}

test "a page folds notes and updates, and a restarted one starts the conversation over" {
    const allocator = std.testing.allocator;
    var pane = ChatPane.init(allocator);
    defer pane.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var source: u8 = 0;
    pane.follows(&source);
    try pane.fold(arena, .{ .entries = &.{
        "{\"note\":\"started\"}",
        "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hello\"}}",
    }, .next = 2, .restarted = false });
    try std.testing.expectEqual(@as(usize, 2), pane.next);
    try std.testing.expectEqual(@as(usize, 2), pane.conversation.items.items.len);

    try pane.fold(arena, .{ .entries = &.{"{\"note\":\"again\"}"}, .next = 1, .restarted = true });
    try std.testing.expectEqual(@as(usize, 1), pane.conversation.items.items.len);

    // Another source's record starts over from its beginning.
    var other: u8 = 0;
    pane.follows(&other);
    try std.testing.expectEqual(@as(usize, 0), pane.next);
    try std.testing.expectEqual(@as(usize, 0), pane.conversation.items.items.len);
}

test "the permission keys are y, a and n, and nothing else" {
    try std.testing.expectEqual(mod.acp.Client.Answer.allowOnce, ChatPane.permissionAnswer(.{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(mod.acp.Client.Answer.allowAlways, ChatPane.permissionAnswer(.{ .codepoint = 'a' }).?);
    try std.testing.expectEqual(mod.acp.Client.Answer.rejectOnce, ChatPane.permissionAnswer(.{ .codepoint = 'n' }).?);
    try std.testing.expect(ChatPane.permissionAnswer(.{ .codepoint = 'x' }) == null);
}
