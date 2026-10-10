const std = @import("std");
const log = std.log.scoped(.acp_vt_screen);
const acp = @import("module.zig");

/// The part of the screen an erase applies to.
///
/// `ESC[J` and `ESC[K` share their parameter's meaning — 0 forward from the
/// cursor, 1 back to the start, 2 the whole thing — so they share this rather
/// than each reading the number again.
const EraseExtent = enum {
    /// From the cursor to the end, cursor included.
    toEnd,
    /// From the start to the cursor, cursor included.
    toStart,
    /// The whole line, or the whole screen.
    all,

    /// Maps an erase sequence's raw parameter to an extent.
    ///
    /// Parameters:
    /// - `value`: the raw parameter, zero included.
    ///
    /// Return: the extent; unrecognised values erase forward.
    fn fromParam(value: u16) EraseExtent {
        return switch (value) {
            1 => .toStart,
            // 3 is "display and scrollback"; there is no scrollback here, so it
            // is the same as 2.
            2, 3 => .all,
            else => .toEnd,
        };
    }
};

/// A character grid painted by a terminal byte stream.
///
/// `VtDecoder` says what the stream asked for; this is the screen it was asking
/// about. The pair is the whole emulator: a stream that positions its cursor,
/// erases regions, and repaints in place cannot be understood without somewhere
/// to paint, and a linear transcript is not that — it has no second dimension,
/// so a repaint appends instead of replacing and text placed by column arrives
/// with its spacing gone.
///
/// What it models is the visible screen and nothing else. There is no
/// scrollback: lines scrolled off the top are gone, because the point is to
/// answer "what is on screen now". Colour and the other attributes are decoded
/// and dropped — this is a grid of characters, and a consumer that wants
/// styling wants a different type.
///
/// Two behaviours are deliberately not implemented, and a stream that uses them
/// renders wrongly rather than partially: the alternate screen buffer
/// (`ESC[?1049h`), and scrolling regions (`ESC[r`). Both change what a scroll
/// means, and neither appears in the CLI output this was built to read.
pub const VtScreen = struct {
    const Self = @This();

    /// What an unwritten cell holds.
    const blank: u21 = ' ';

    /// Substituted for a byte that is not valid UTF-8, so one bad byte costs one
    /// cell rather than desynchronising the rest of the run.
    const replacement: u21 = 0xFFFD;

    /// Columns between tab stops. The VT default, and not configurable by any
    /// sequence this handles.
    const tab_width: u16 = 8;

    /// Refuse a size beyond this on either axis. A resize arrives from outside
    /// the process, and the grid it asks for is allocated.
    pub const max_dimension: u16 = 1000;

    allocator: std.mem.Allocator,
    /// Grid of `rows * columns` characters, row-major.
    cells: []u21,
    columns: u16,
    rows: u16,
    cursor_row: u16 = 0,
    /// May equal `columns`, which means the last column has been written and the
    /// next character wraps. A cursor *move* never leaves it there; only writing
    /// does, which is what makes the wrap happen on the next character rather
    /// than immediately — a line that exactly fills the screen must not push the
    /// next one down before anything is written to it.
    cursor_column: u16 = 0,
    /// Cursor position stashed by `ESC 7`, restored by `ESC 8`.
    saved_row: u16 = 0,
    saved_column: u16 = 0,
    /// Bytes of a character the previous run ended in the middle of. A run ends
    /// wherever the reader happened to stop, which is not necessarily on a
    /// character boundary.
    partial: [4]u8 = @splat(0),
    partial_len: u3 = 0,
    /// Incremental decoder; its state carries across writes.
    decoder: acp.Pty.VtDecoder = .{},

    /// Creates a blank screen of the given size.
    ///
    /// Parameters:
    /// - `allocator`: backs the grid; must outlive the screen.
    /// - `columns`: visible columns; clamped to `1..max_dimension`.
    /// - `rows`: visible rows; clamped to `1..max_dimension`.
    ///
    /// Return: a blank screen; propagates allocation failure.
    pub fn init(allocator: std.mem.Allocator, columns: u16, rows: u16) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const width = std.math.clamp(columns, 1, max_dimension);
        const height = std.math.clamp(rows, 1, max_dimension);

        const cells = try allocator.alloc(u21, @as(usize, width) * height);
        @memset(cells, blank);

        return Self{ .allocator = allocator, .cells = cells, .columns = width, .rows = height };
    }

    /// Releases the grid.
    ///
    /// Parameters:
    /// - `self`: the screen to tear down.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
    }

    /// Paints a chunk of terminal output onto the screen.
    ///
    /// Parameters:
    /// - `self`: the screen to paint on.
    /// - `bytes`: raw terminal output; may split a sequence or character.
    ///
    /// Return: nothing; propagates decoder failures (none today).
    pub fn write(self: *Self, bytes: []const u8) !void {
        try self.decoder.decode(bytes, self, apply);
    }

    /// Changes the screen's size, keeping the top-left content that still fits.
    ///
    /// Parameters:
    /// - `self`: the screen to resize.
    /// - `columns`: new column count; clamped as in `init`.
    /// - `rows`: new row count; clamped as in `init`.
    ///
    /// Return: nothing; propagates allocation failure, leaving the previous size intact.
    pub fn resize(self: *Self, columns: u16, rows: u16) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const width = std.math.clamp(columns, 1, max_dimension);
        const height = std.math.clamp(rows, 1, max_dimension);
        if (width == self.columns and height == self.rows) return;

        // The top-left is kept because the program redraws after a resize
        // anyway; holding the old content only avoids a flash of blank screen.
        const cells = try self.blankGrid(width, height);
        errdefer self.allocator.free(cells);

        const kept_rows = @min(self.rows, height);
        const kept_columns = @min(self.columns, width);
        for (0..kept_rows) |row| {
            const source = self.cells[row * self.columns ..][0..kept_columns];
            @memcpy(cells[row * width ..][0..kept_columns], source);
        }

        self.allocator.free(self.cells);
        self.cells = cells;
        self.columns = width;
        self.rows = height;
        self.cursor_row = @min(self.cursor_row, height - 1);
        self.cursor_column = @min(self.cursor_column, width);
        log.debug("screen resized to {d}x{d}", .{ width, height });
    }

    /// Renders the visible screen as text.
    ///
    /// Parameters:
    /// - `self`: the screen to render.
    /// - `allocator`: owns the returned text.
    ///
    /// Return: `\n`-separated UTF-8 lines with trailing blanks trimmed, caller-owned; propagates allocation failure.
    pub fn renderOwned(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        // SAFETY: filled by `utf8Encode` before each read of its prefix.
        var encoded: [4]u8 = undefined;
        var pending_newlines: usize = 0;

        for (0..self.rows) |row| {
            const line = self.cells[row * self.columns ..][0..self.columns];
            // Trailing blanks go: the grid is blank-padded by construction, and
            // rendering the padding would make every line terminal-wide.
            const end = trimmedLength(line);
            if (end == 0) {
                // Held back rather than written, so a blank row between two
                // written ones survives but a run of them at the foot does not.
                pending_newlines += 1;
                continue;
            }

            for (0..pending_newlines) |_| try out.writer.writeByte('\n');
            pending_newlines = 1;

            for (line[0..end]) |codepoint| {
                const length = std.unicode.utf8Encode(codepoint, &encoded) catch {
                    try out.writer.writeByte('?');
                    continue;
                };
                try out.writer.writeAll(encoded[0..length]);
            }
        }

        return out.toOwnedSlice();
    }

    /// Blanks the whole screen and homes the cursor.
    ///
    /// Parameters:
    /// - `self`: the screen to clear.
    ///
    /// Return: nothing.
    pub fn clear(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        @memset(self.cells, blank);
        self.cursor_row = 0;
        self.cursor_column = 0;
    }

    /// Allocates a grid filled with blanks.
    ///
    /// Parameters:
    /// - `self`: the screen whose allocator owns the grid.
    /// - `columns`: column count.
    /// - `rows`: row count.
    ///
    /// Return: the grid, owned by `self.allocator`; propagates allocation failure.
    fn blankGrid(self: *const Self, columns: u16, rows: u16) ![]u21 {
        const cells = try self.allocator.alloc(u21, @as(usize, columns) * rows);
        @memset(cells, blank);
        return cells;
    }

    /// Measures a row up to its last non-blank cell.
    ///
    /// Parameters:
    /// - `line`: the row's cells.
    ///
    /// Return: the length without trailing blanks; zero for a blank row.
    fn trimmedLength(line: []const u21) usize {
        var end = line.len;
        while (end > 0 and line[end - 1] == blank) end -= 1;
        return end;
    }

    /// Applies one decoded event to the screen; the decoder's `emit` callback.
    ///
    /// Parameters:
    /// - `self`: the screen to paint on.
    /// - `event`: the decoded event.
    ///
    /// Return: nothing; never fails, the error union is the callback's.
    fn apply(self: *Self, event: acp.Pty.VtEvent) anyerror!void {
        switch (event) {
            .text => |text| self.putText(text),
            .lineFeed => self.lineFeed(),
            // A carriage return is the workhorse of in-place repainting: it
            // returns to column zero so the same row can be written again.
            .carriageReturn => self.cursor_column = 0,
            .backspace => if (self.cursor_column > 0) {
                self.cursor_column -= 1;
            },
            .tab => self.tab(),
            .csi => |csi| self.applyCsi(csi),
            .escape => |final| self.applyEscape(final),
            // A bell is audible, and a window title is not on the screen.
            .bell, .osc => {},
        }
    }

    /// Writes a run of printable text at the cursor.
    ///
    /// Parameters:
    /// - `self`: the screen to write on.
    /// - `text`: the run; may begin or end mid-character.
    ///
    /// Return: nothing.
    fn putText(self: *Self, text: []const u8) void {
        var rest = text;

        // Finish the character the previous run ended inside.
        while (self.partial_len > 0 and rest.len > 0) {
            const needed = std.unicode.utf8ByteSequenceLength(self.partial[0]) catch {
                self.partial_len = 0;
                self.putCodepoint(replacement);
                break;
            };
            self.partial[self.partial_len] = rest[0];
            self.partial_len += 1;
            rest = rest[1..];

            if (self.partial_len == needed) {
                self.putCodepoint(std.unicode.utf8Decode(self.partial[0..needed]) catch replacement);
                self.partial_len = 0;
            }
        }

        var index: usize = 0;
        while (index < rest.len) {
            const length = std.unicode.utf8ByteSequenceLength(rest[index]) catch {
                self.putCodepoint(replacement);
                index += 1;
                continue;
            };

            // The run stops mid-character; hold the bytes for the next one.
            if (index + length > rest.len) {
                const tail = rest[index..];
                @memcpy(self.partial[0..tail.len], tail);
                self.partial_len = @intCast(tail.len);
                return;
            }

            self.putCodepoint(std.unicode.utf8Decode(rest[index..][0..length]) catch replacement);
            index += length;
        }
    }

    /// Writes one character at the cursor and advances it.
    ///
    /// Parameters:
    /// - `self`: the screen to write on.
    /// - `codepoint`: the character to write.
    ///
    /// Return: nothing.
    fn putCodepoint(self: *Self, codepoint: u21) void {
        // Every character takes one column: wrong for double-width ranges, right
        // for the Latin text, box drawing and symbols a CLI actually emits.

        // The deferred wrap from the last character written to the final column.
        if (self.cursor_column >= self.columns) {
            self.cursor_column = 0;
            self.lineFeed();
        }

        self.cells[@as(usize, self.cursor_row) * self.columns + self.cursor_column] = codepoint;
        self.cursor_column += 1;
    }

    /// Moves the cursor down one row, scrolling at the bottom.
    ///
    /// Parameters:
    /// - `self`: the screen to move on.
    ///
    /// Return: nothing.
    fn lineFeed(self: *Self) void {
        // The column is left alone: a pseudoterminal turns `\n` into `\r\n`, so
        // the return arrives as its own event and homing here would do it twice.
        if (self.cursor_row + 1 < self.rows) {
            self.cursor_row += 1;
            return;
        }
        self.scrollUp(1);
    }

    /// Advances the cursor to the next tab stop.
    ///
    /// Parameters:
    /// - `self`: the screen to move on.
    ///
    /// Return: nothing.
    fn tab(self: *Self) void {
        const next = (self.cursor_column / tab_width + 1) * tab_width;
        self.cursor_column = @min(next, self.columns - 1);
    }

    /// Moves every row up, blanking the rows that enter at the bottom.
    ///
    /// Parameters:
    /// - `self`: the screen to scroll.
    /// - `count`: rows to scroll by; at or beyond the height clears the screen.
    ///
    /// Return: nothing.
    fn scrollUp(self: *Self, count: u16) void {
        if (count >= self.rows) {
            @memset(self.cells, blank);
            return;
        }

        const moved = @as(usize, self.rows - count) * self.columns;
        std.mem.copyForwards(u21, self.cells[0..moved], self.cells[@as(usize, count) * self.columns ..]);
        @memset(self.cells[moved..], blank);
    }

    /// Moves every row down, blanking the rows that enter at the top.
    ///
    /// Parameters:
    /// - `self`: the screen to scroll.
    /// - `count`: rows to scroll by; at or beyond the height clears the screen.
    ///
    /// Return: nothing.
    fn scrollDown(self: *Self, count: u16) void {
        if (count >= self.rows) {
            @memset(self.cells, blank);
            return;
        }

        const moved = @as(usize, self.rows - count) * self.columns;
        std.mem.copyBackwards(u21, self.cells[@as(usize, count) * self.columns ..], self.cells[0..moved]);
        @memset(self.cells[0 .. @as(usize, count) * self.columns], blank);
    }

    /// Applies a two-byte escape sequence.
    ///
    /// Parameters:
    /// - `self`: the screen to act on.
    /// - `final`: the sequence's final byte.
    ///
    /// Return: nothing; unrecognised escapes are ignored.
    fn applyEscape(self: *Self, final: u8) void {
        switch (final) {
            // RIS: reset to initial state.
            'c' => self.clear(),
            // DECSC / DECRC: save and restore the cursor.
            '7' => {
                self.saved_row = self.cursor_row;
                self.saved_column = self.cursor_column;
            },
            '8' => {
                self.cursor_row = @min(self.saved_row, self.rows - 1);
                self.cursor_column = @min(self.saved_column, self.columns);
            },
            // IND: down one row, scrolling at the bottom.
            'D' => self.lineFeed(),
            // RI: up one row, scrolling at the top.
            'M' => if (self.cursor_row > 0) {
                self.cursor_row -= 1;
            } else {
                self.scrollDown(1);
            },
            else => {},
        }
    }

    /// Applies a CSI sequence.
    ///
    /// Parameters:
    /// - `self`: the screen to act on.
    /// - `csi`: the decoded sequence.
    ///
    /// Return: nothing; unrecognised sequences are ignored.
    fn applyCsi(self: *Self, csi: acp.Pty.Csi) void {
        // Private sequences set modes — cursor visibility, bracketed paste, the
        // alternate screen — and none of them paints.
        if (csi.private != null) return;

        switch (csi.final) {
            // CUU / CUD / CUF / CUB: relative cursor movement.
            'A' => self.cursor_row -|= @intCast(csi.param(0, 1)),
            'B' => self.cursor_row = @min(self.cursor_row +| csi.param(0, 1), self.rows - 1),
            'C' => self.cursor_column = @min(self.cursor_column +| csi.param(0, 1), self.columns - 1),
            'D' => self.cursor_column -|= @intCast(csi.param(0, 1)),
            // CNL / CPL: rows down or up, and back to column zero.
            'E' => {
                self.cursor_row = @min(self.cursor_row +| csi.param(0, 1), self.rows - 1);
                self.cursor_column = 0;
            },
            'F' => {
                self.cursor_row -|= @intCast(csi.param(0, 1));
                self.cursor_column = 0;
            },
            // CHA / VPA: absolute column, absolute row. One-based on the wire.
            'G' => self.cursor_column = @min(csi.param(0, 1) - 1, self.columns - 1),
            'd' => self.cursor_row = @min(csi.param(0, 1) - 1, self.rows - 1),
            // CUP / HVP: absolute position. This is how a full-screen interface
            // lays itself out, and ignoring it is what welds its words together.
            'H', 'f' => {
                self.cursor_row = @min(csi.param(0, 1) - 1, self.rows - 1);
                self.cursor_column = @min(csi.param(1, 1) - 1, self.columns - 1);
            },
            // ED / EL: erase in display, erase in line.
            'J' => self.eraseDisplay(EraseExtent.fromParam(csi.rawParam(0, 0))),
            'K' => self.eraseLine(EraseExtent.fromParam(csi.rawParam(0, 0))),
            // IL / DL: insert and delete whole rows.
            'L' => self.insertLines(csi.param(0, 1)),
            'M' => self.deleteLines(csi.param(0, 1)),
            // DCH / ICH: delete and insert characters within the row.
            'P' => self.deleteCharacters(csi.param(0, 1)),
            '@' => self.insertCharacters(csi.param(0, 1)),
            // ECH: blank characters without moving anything.
            'X' => self.eraseCharacters(csi.param(0, 1)),
            // SU / SD: scroll the screen.
            'S' => self.scrollUp(csi.param(0, 1)),
            'T' => self.scrollDown(csi.param(0, 1)),
            // SGR ('m') and the rest set attributes or modes this grid does not
            // carry.
            else => {},
        }
    }

    /// Erases part of the screen relative to the cursor.
    ///
    /// Parameters:
    /// - `self`: the screen to erase on.
    /// - `extent`: which part to erase.
    ///
    /// Return: nothing.
    fn eraseDisplay(self: *Self, extent: EraseExtent) void {
        const cursor = @as(usize, self.cursor_row) * self.columns + @min(self.cursor_column, self.columns - 1);
        switch (extent) {
            .toEnd => @memset(self.cells[cursor..], blank),
            .toStart => @memset(self.cells[0 .. cursor + 1], blank),
            .all => @memset(self.cells, blank),
        }
    }

    /// Erases part of the cursor's row.
    ///
    /// Parameters:
    /// - `self`: the screen to erase on.
    /// - `extent`: which part to erase.
    ///
    /// Return: nothing.
    fn eraseLine(self: *Self, extent: EraseExtent) void {
        const line = self.cells[@as(usize, self.cursor_row) * self.columns ..][0..self.columns];
        const column = @min(self.cursor_column, self.columns - 1);
        switch (extent) {
            .toEnd => @memset(line[column..], blank),
            .toStart => @memset(line[0 .. column + 1], blank),
            .all => @memset(line, blank),
        }
    }

    /// Blanks characters from the cursor without shifting the row.
    ///
    /// Parameters:
    /// - `self`: the screen to erase on.
    /// - `count`: characters to blank.
    ///
    /// Return: nothing.
    fn eraseCharacters(self: *Self, count: u16) void {
        const line = self.cells[@as(usize, self.cursor_row) * self.columns ..][0..self.columns];
        const column = @min(self.cursor_column, self.columns - 1);
        const end = @min(@as(usize, column) + count, line.len);
        @memset(line[column..end], blank);
    }

    /// Deletes characters at the cursor, pulling the rest of the row left.
    ///
    /// Parameters:
    /// - `self`: the screen to edit.
    /// - `count`: characters to delete.
    ///
    /// Return: nothing.
    fn deleteCharacters(self: *Self, count: u16) void {
        const line = self.cells[@as(usize, self.cursor_row) * self.columns ..][0..self.columns];
        const column = @min(self.cursor_column, self.columns - 1);
        const removed = @min(@as(usize, count), line.len - column);

        std.mem.copyForwards(u21, line[column .. line.len - removed], line[column + removed ..]);
        @memset(line[line.len - removed ..], blank);
    }

    /// Inserts blanks at the cursor, pushing the rest of the row right.
    ///
    /// Parameters:
    /// - `self`: the screen to edit.
    /// - `count`: blanks to insert.
    ///
    /// Return: nothing.
    fn insertCharacters(self: *Self, count: u16) void {
        const line = self.cells[@as(usize, self.cursor_row) * self.columns ..][0..self.columns];
        const column = @min(self.cursor_column, self.columns - 1);
        const added = @min(@as(usize, count), line.len - column);

        std.mem.copyBackwards(u21, line[column + added ..], line[column .. line.len - added]);
        @memset(line[column .. column + added], blank);
    }

    /// Inserts blank rows at the cursor, pushing the rows below down.
    ///
    /// Parameters:
    /// - `self`: the screen to edit.
    /// - `count`: rows to insert.
    ///
    /// Return: nothing.
    fn insertLines(self: *Self, count: u16) void {
        const below = self.rows - self.cursor_row;
        const added = @min(count, below);
        const region = self.cells[@as(usize, self.cursor_row) * self.columns ..];
        const moved = @as(usize, below - added) * self.columns;

        std.mem.copyBackwards(u21, region[@as(usize, added) * self.columns ..], region[0..moved]);
        @memset(region[0 .. @as(usize, added) * self.columns], blank);
    }

    /// Deletes rows at the cursor, pulling the rows below up.
    ///
    /// Parameters:
    /// - `self`: the screen to edit.
    /// - `count`: rows to delete.
    ///
    /// Return: nothing.
    fn deleteLines(self: *Self, count: u16) void {
        const below = self.rows - self.cursor_row;
        const removed = @min(count, below);
        const region = self.cells[@as(usize, self.cursor_row) * self.columns ..];
        const moved = @as(usize, below - removed) * self.columns;

        std.mem.copyForwards(u21, region[0..moved], region[@as(usize, removed) * self.columns ..]);
        @memset(region[moved..], blank);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(VtScreen);
}

/// Renders a fresh screen after writing `bytes` to it.
///
/// Parameters:
/// - `allocator`: backs the screen and owns the returned text.
/// - `columns`: screen width.
/// - `rows`: screen height.
/// - `bytes`: terminal output to paint.
///
/// Return: the rendered text, caller-owned; propagates allocation failure.
fn renderAfterOwned(allocator: std.mem.Allocator, columns: u16, rows: u16, bytes: []const u8) ![]u8 {
    var screen = try VtScreen.init(allocator, columns, rows);
    defer screen.deinit();

    try screen.write(bytes);
    return screen.renderOwned(allocator);
}

test "absolute positioning keeps the spacing between placed words" {
    const allocator = std.testing.allocator;
    // The exact failure a linear transcript produces: "PTY" and "OK" placed by
    // column, arriving as "PTYOK".
    const text = try renderAfterOwned(allocator, 20, 3, "\x1b[1;1HPTY\x1b[1;7HOK");
    defer allocator.free(text);

    try std.testing.expectEqualStrings("PTY   OK", text);
}

test "a carriage-return repaint replaces the line rather than stacking it" {
    const allocator = std.testing.allocator;
    const text = try renderAfterOwned(allocator, 20, 3, "\r/ Working\r- Working\r| Done   ");
    defer allocator.free(text);

    try std.testing.expectEqualStrings("| Done", text);
}

test "a repainted block replaces what it covers" {
    const allocator = std.testing.allocator;
    const text = try renderAfterOwned(
        allocator,
        24,
        4,
        "\x1b[1;1Hfirst A\r\n\x1b[2;1Hfirst B\x1b[1;1Hsecond A\x1b[2;1Hsecond B",
    );
    defer allocator.free(text);

    try std.testing.expectEqualStrings("second A\nsecond B", text);
}

test "erase in display clears forward from the cursor" {
    const allocator = std.testing.allocator;
    const text = try renderAfterOwned(allocator, 10, 3, "keep\r\n\x1b[2;1Hgone\x1b[2;1H\x1b[0J");
    defer allocator.free(text);

    try std.testing.expectEqualStrings("keep", text);
}

test "erase in line clears back to the start" {
    const allocator = std.testing.allocator;
    const text = try renderAfterOwned(allocator, 12, 2, "abcdefgh\x1b[1;4H\x1b[1K");
    defer allocator.free(text);

    try std.testing.expectEqualStrings("    efgh", text);
}

test "text wraps at the last column, and only once written past" {
    const allocator = std.testing.allocator;
    // Exactly five characters on a five-column screen must not push a line.
    const exact = try renderAfterOwned(allocator, 5, 3, "abcde");
    defer allocator.free(exact);
    try std.testing.expectEqualStrings("abcde", exact);

    const over = try renderAfterOwned(allocator, 5, 3, "abcdefg");
    defer allocator.free(over);
    try std.testing.expectEqualStrings("abcde\nfg", over);
}

test "the screen scrolls when the last row fills" {
    const allocator = std.testing.allocator;
    const text = try renderAfterOwned(allocator, 6, 3, "one\r\ntwo\r\nthree\r\nfour");
    defer allocator.free(text);

    try std.testing.expectEqualStrings("two\nthree\nfour", text);
}

test "a character split across two writes is reassembled" {
    const allocator = std.testing.allocator;
    var screen = try VtScreen.init(allocator, 10, 2);
    defer screen.deinit();

    // "✓" is E2 9C 93; cut it after its first byte.
    try screen.write("ok \xe2");
    try screen.write("\x9c\x93 go");

    const text = try screen.renderOwned(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("ok ✓ go", text);
}

test "a sequence split across two writes still applies" {
    const allocator = std.testing.allocator;
    var screen = try VtScreen.init(allocator, 12, 2);
    defer screen.deinit();

    try screen.write("abc\x1b[1");
    try screen.write(";1Hxy");

    const text = try screen.renderOwned(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("xyc", text);
}

test "insert and delete characters shift the rest of the row" {
    const allocator = std.testing.allocator;
    const deleted = try renderAfterOwned(allocator, 10, 2, "abcdef\x1b[1;2H\x1b[2P");
    defer allocator.free(deleted);
    try std.testing.expectEqualStrings("adef", deleted);

    const inserted = try renderAfterOwned(allocator, 10, 2, "abcdef\x1b[1;2H\x1b[2@");
    defer allocator.free(inserted);
    try std.testing.expectEqualStrings("a  bcdef", inserted);
}

test "insert and delete lines shift the rows below" {
    const allocator = std.testing.allocator;
    const deleted = try renderAfterOwned(allocator, 8, 4, "a\r\nb\r\nc\x1b[2;1H\x1b[1M");
    defer allocator.free(deleted);
    try std.testing.expectEqualStrings("a\nc", deleted);

    const inserted = try renderAfterOwned(allocator, 8, 4, "a\r\nb\x1b[2;1H\x1b[1L");
    defer allocator.free(inserted);
    try std.testing.expectEqualStrings("a\n\nb", inserted);
}

test "blank rows between content survive but trailing ones do not" {
    const allocator = std.testing.allocator;
    const text = try renderAfterOwned(allocator, 8, 6, "top\x1b[3;1Hmiddle");
    defer allocator.free(text);

    try std.testing.expectEqualStrings("top\n\nmiddle", text);
}

test "resize keeps what still fits and clamps the cursor" {
    const allocator = std.testing.allocator;
    var screen = try VtScreen.init(allocator, 20, 4);
    defer screen.deinit();

    try screen.write("hello world");
    try screen.resize(8, 2);

    const text = try screen.renderOwned(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello wo", text);
    try std.testing.expect(screen.cursor_column <= screen.columns);
    try std.testing.expect(screen.cursor_row < screen.rows);
}

test "a private sequence paints nothing" {
    const allocator = std.testing.allocator;
    // Cursor hide, bracketed paste, alternate screen: all modes, no painting.
    const text = try renderAfterOwned(allocator, 12, 2, "\x1b[?25lkeep\x1b[?2004h\x1b[?1049h");
    defer allocator.free(text);

    try std.testing.expectEqualStrings("keep", text);
}

test "an oversized screen is refused rather than allocated" {
    const allocator = std.testing.allocator;
    var screen = try VtScreen.init(allocator, 60000, 60000);
    defer screen.deinit();

    try std.testing.expectEqual(VtScreen.max_dimension, screen.columns);
    try std.testing.expectEqual(VtScreen.max_dimension, screen.rows);
}
