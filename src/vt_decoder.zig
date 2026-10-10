const std = @import("std");
const log = std.log.scoped(.acp_vt_decoder);

/// A decoded CSI (Control Sequence Introducer) sequence.
///
/// Parameters are exposed rather than acted upon: this file decides what a
/// sequence *is*, never what it should do to a screen.
pub const Csi = struct {
    const Self = @This();

    /// Final byte, which names the operation: 'H' for cursor position, 'J' for
    /// erase in display, 'm' for graphics rendition, and so on.
    final: u8,
    /// Private-marker byte (`?`, `<`, `=`, `>`) when the sequence carries one.
    private: ?u8,
    /// Intermediate byte (space through `/`) when present.
    intermediate: ?u8,
    /// Numeric parameters, in order. Empty for a bare sequence like `ESC[H`.
    params: []const u16,

    /// Constructs a decoded sequence.
    ///
    /// Parameters:
    /// - `final`: the final byte naming the operation.
    /// - `private`: the private-marker byte, or null.
    /// - `intermediate`: the intermediate byte, or null.
    /// - `params`: the numeric parameters; borrowed.
    ///
    /// Return: the sequence; never fails today.
    pub fn init(final: u8, private: ?u8, intermediate: ?u8, params: []const u16) !Self {
        return Self{ .final = final, .private = private, .intermediate = intermediate, .params = params };
    }

    /// Releases nothing; a sequence borrows its parameters.
    ///
    /// Parameters:
    /// - `self`: the sequence.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Returns a parameter, substituting `fallback` when it is absent or zero.
    ///
    /// Parameters:
    /// - `self`: the sequence.
    /// - `index`: zero-based parameter position.
    /// - `fallback`: value to use when the parameter is absent or zero.
    ///
    /// Return: the parameter, or `fallback`.
    pub fn param(self: Self, index: usize, fallback: u16) u16 {
        // VT parameters are 1-based and an omitted or zero parameter means
        // "use the default", so callers almost never want the raw value.
        if (index >= self.params.len) return fallback;
        return if (self.params[index] == 0) fallback else self.params[index];
    }

    /// Returns a parameter exactly as received, including zero.
    ///
    /// Parameters:
    /// - `self`: the sequence.
    /// - `index`: zero-based parameter position.
    /// - `fallback`: value to use when the parameter is absent.
    ///
    /// Return: the raw parameter, or `fallback` when absent.
    pub fn rawParam(self: Self, index: usize, fallback: u16) u16 {
        // For the few operations where zero is meaningful rather than a
        // request for the default: `ESC[0J` erases forward, `ESC[0m` resets.
        if (index >= self.params.len) return fallback;
        return self.params[index];
    }
};

/// A decoded OSC (Operating System Command), such as a window-title change.
pub const Osc = struct {
    const Self = @This();

    /// Leading numeric command, when the payload starts with one.
    command: ?u16,
    /// Payload after the command and its separator. Borrowed from the
    /// decoder's buffer and only valid during the callback.
    payload: []const u8,

    /// Constructs a decoded command.
    ///
    /// Parameters:
    /// - `command`: the leading numeric command, or null.
    /// - `payload`: the text after the command; borrowed.
    ///
    /// Return: the command; never fails today.
    pub fn init(command: ?u16, payload: []const u8) !Self {
        return Self{ .command = command, .payload = payload };
    }

    /// Releases nothing; a command borrows its payload.
    ///
    /// Parameters:
    /// - `self`: the command.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

/// One decoded item from a terminal byte stream.
///
/// The stream is reduced to printable runs plus the control operations that
/// carry meaning. What a consumer does with them — paint a grid, extract a
/// transcript, diff successive repaints — is deliberately not decided here.
pub const VtEvent = union(enum) {
    const Self = @This();

    /// A run of printable characters. Borrowed from the input slice, so it is
    /// only valid for the duration of the callback.
    text: []const u8,
    /// Move to the next line (LF, 0x0A).
    lineFeed,
    /// Return to column zero (CR, 0x0D). The workhorse of terminal repainting.
    carriageReturn,
    /// Move back one column (BS, 0x08).
    backspace,
    /// Advance to the next tab stop (HT, 0x09).
    tab,
    /// Audible bell (BEL, 0x07).
    bell,
    csi: Csi,
    osc: Osc,
    /// A two-byte escape such as `ESC c` (reset) or `ESC 7` (save cursor).
    escape: u8,
};

/// Incremental decoder for terminal output.
///
/// Reach for this to capture a terminal exchange and re-present it somewhere
/// a terminal cannot go — a web page, a transcript, a structured log. It
/// reports what the stream *asked for* and leaves the consumer to decide what
/// that means, which is what distinguishes it from an emulator: there is no
/// screen, and no opinion about one.
///
/// Feed it whatever chunks arrive, including ones that split a sequence in
/// half; the decoder resumes correctly across calls.
///
/// Allocation-free. Events borrow their bytes and are valid only for the
/// duration of the callback, so anything retained must be copied.
pub const VtDecoder = struct {
    const Self = @This();

    /// Parameters kept per sequence. Real-world CSI sequences use a handful;
    /// the excess is parsed and dropped rather than desynchronising the stream.
    pub const max_params = 16;

    /// Cap on a retained OSC payload. Longer ones are truncated, never grown.
    pub const max_osc_payload = 1024;

    /// Where the scanner is in a sequence.
    const State = enum { ground, escape, csi, osc, oscEscape };

    state: State = .ground,
    params: [max_params]u16 = @splat(0),
    param_count: usize = 0,
    /// Accumulator for the parameter currently being read.
    param_value: u32 = 0,
    /// Distinguishes `ESC[m` (no parameters) from `ESC[0m` (one zero).
    param_started: bool = false,
    private: ?u8 = null,
    intermediate: ?u8 = null,
    osc_buffer: [max_osc_payload]u8 = @splat(0),
    osc_len: usize = 0,
    /// Set when an OSC payload overflowed, so the truncation can be logged once.
    osc_truncated: bool = false,

    /// Constructs a decoder in its initial state.
    ///
    /// Return: the decoder; never fails today.
    pub fn init() !Self {
        return Self{};
    }

    /// Releases nothing; the decoder is allocation-free.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Feeds a chunk of terminal output, emitting one event per decoded item.
    ///
    /// Parameters:
    /// - `self`: the decoder, whose state carries across calls.
    /// - `bytes`: the chunk to decode; may end mid-sequence.
    /// - `context`: opaque value forwarded to `emit`.
    /// - `emit`: receives each decoded event in stream order; events borrow their bytes.
    ///
    /// Return: nothing; propagates whatever `emit` returns.
    pub fn decode(self: *Self, bytes: []const u8, context: anytype, comptime emit: fn (@TypeOf(context), VtEvent) anyerror!void) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            switch (self.state) {
                .ground => {
                    // Take the longest printable run in one go.
                    const start = index;
                    while (index < bytes.len and isPrintable(bytes[index])) index += 1;
                    if (index > start) {
                        try emit(context, .{ .text = bytes[start..index] });
                        continue;
                    }
                    try self.decodeControl(bytes[index], context, emit);
                    index += 1;
                },
                .escape => {
                    self.resetSequence();
                    switch (bytes[index]) {
                        '[' => self.state = .csi,
                        ']' => self.state = .osc,
                        else => |byte| {
                            self.state = .ground;
                            try emit(context, .{ .escape = byte });
                        },
                    }
                    index += 1;
                },
                .csi => {
                    if (try self.decodeCsiByte(bytes[index], context, emit)) self.state = .ground;
                    index += 1;
                },
                .osc => {
                    switch (bytes[index]) {
                        // BEL terminates an OSC.
                        0x07 => {
                            self.state = .ground;
                            try self.emitOsc(context, emit);
                        },
                        // ESC may begin the ST terminator.
                        0x1b => self.state = .oscEscape,
                        else => |byte| self.appendOsc(byte),
                    }
                    index += 1;
                },
                .oscEscape => {
                    if (bytes[index] == '\\') {
                        // ST: ESC \ closes the OSC.
                        self.state = .ground;
                        try self.emitOsc(context, emit);
                    } else {
                        // A stray ESC inside the payload; keep collecting.
                        self.appendOsc(0x1b);
                        self.appendOsc(bytes[index]);
                        self.state = .osc;
                    }
                    index += 1;
                },
            }
        }
    }

    /// Returns the decoder to its initial state, discarding any half-consumed sequence.
    ///
    /// Parameters:
    /// - `self`: the decoder to reset.
    ///
    /// Return: nothing.
    pub fn reset(self: *Self) void {
        self.state = .ground;
        self.resetSequence();
    }

    /// Emits the event for a C0 control byte, or begins an escape sequence.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `byte`: the control byte.
    /// - `context`: value forwarded to `emit`.
    /// - `emit`: receives the decoded event.
    ///
    /// Return: nothing; propagates whatever `emit` returns.
    fn decodeControl(self: *Self, byte: u8, context: anytype, comptime emit: fn (@TypeOf(context), VtEvent) anyerror!void) !void {
        switch (byte) {
            0x1b => self.state = .escape,
            '\n' => try emit(context, .lineFeed),
            '\r' => try emit(context, .carriageReturn),
            0x08 => try emit(context, .backspace),
            '\t' => try emit(context, .tab),
            0x07 => try emit(context, .bell),
            // Every other C0 byte is dropped: nothing downstream can use it and
            // passing it through would corrupt the text.
            else => {},
        }
    }

    /// Consumes one byte of a CSI sequence, emitting the sequence when it completes.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `byte`: the next byte of the sequence.
    /// - `context`: value forwarded to `emit`.
    /// - `emit`: receives the completed sequence.
    ///
    /// Return: true when the sequence is complete or aborted; propagates whatever `emit` returns.
    fn decodeCsiByte(self: *Self, byte: u8, context: anytype, comptime emit: fn (@TypeOf(context), VtEvent) anyerror!void) !bool {
        switch (byte) {
            '0'...'9' => {
                self.param_value = self.param_value *| 10 +| (byte - '0');
                self.param_started = true;
                return false;
            },
            ';' => {
                self.pushParam();
                return false;
            },
            // Private markers only legal before any parameter.
            '?', '<', '=', '>' => {
                if (!self.param_started and self.param_count == 0) self.private = byte;
                return false;
            },
            ' '...'/' => {
                self.intermediate = byte;
                return false;
            },
            '@'...'~' => {
                if (self.param_started) self.pushParam();
                try emit(context, .{ .csi = .{
                    .final = byte,
                    .private = self.private,
                    .intermediate = self.intermediate,
                    .params = self.params[0..self.param_count],
                } });
                return true;
            },
            // Anything else aborts the sequence rather than consuming the
            // stream: a malformed escape should cost one sequence, not the
            // rest of the session.
            else => return true,
        }
    }

    /// Commits the parameter under construction.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    ///
    /// Return: nothing.
    fn pushParam(self: *Self) void {
        if (self.param_count < max_params) {
            self.params[self.param_count] = std.math.lossyCast(u16, self.param_value);
            self.param_count += 1;
        }
        self.param_value = 0;
        self.param_started = false;
    }

    /// Appends a byte to the OSC payload, truncating at `max_osc_payload`.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `byte`: the payload byte to retain.
    ///
    /// Return: nothing.
    fn appendOsc(self: *Self, byte: u8) void {
        if (self.osc_len < self.osc_buffer.len) {
            self.osc_buffer[self.osc_len] = byte;
            self.osc_len += 1;
        } else if (!self.osc_truncated) {
            self.osc_truncated = true;
            log.debug("OSC payload exceeded {d} bytes; truncating", .{max_osc_payload});
        }
    }

    /// Emits the collected OSC with its leading numeric command split off.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    /// - `context`: value forwarded to `emit`.
    /// - `emit`: receives the completed command.
    ///
    /// Return: nothing; propagates whatever `emit` returns.
    fn emitOsc(self: *Self, context: anytype, comptime emit: fn (@TypeOf(context), VtEvent) anyerror!void) !void {
        const payload = self.osc_buffer[0..self.osc_len];

        var command: ?u16 = null;
        var rest = payload;
        if (std.mem.findScalar(u8, payload, ';')) |separator| {
            if (std.fmt.parseInt(u16, payload[0..separator], 10)) |value| {
                command = value;
                rest = payload[separator + 1 ..];
            } else |_| {}
        }

        try emit(context, .{ .osc = .{ .command = command, .payload = rest } });
        self.resetSequence();
    }

    /// Clears per-sequence state, leaving the scanner state alone.
    ///
    /// Parameters:
    /// - `self`: the decoder.
    ///
    /// Return: nothing.
    fn resetSequence(self: *Self) void {
        self.param_count = 0;
        self.param_value = 0;
        self.param_started = false;
        self.private = null;
        self.intermediate = null;
        self.osc_len = 0;
        self.osc_truncated = false;
    }

    /// Reports whether a byte belongs in a text run.
    ///
    /// Parameters:
    /// - `byte`: the byte to classify.
    ///
    /// Return: true when the byte belongs in a text run.
    fn isPrintable(byte: u8) bool {
        // Includes UTF-8 lead and continuation bytes: the decoder works in
        // bytes, so multi-byte characters pass through untouched.
        return byte >= 0x20 and byte != 0x7f;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(VtDecoder);
}

/// Collects events into a readable form so tests can assert on a whole stream.
const Recorder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    /// Constructs an empty recorder.
    ///
    /// Parameters:
    /// - `allocator`: owns every recorded item; must outlive the recorder.
    ///
    /// Return: the recorder; never fails today.
    fn init(allocator: std.mem.Allocator) !Self {
        return Self{ .allocator = allocator };
    }

    /// Frees every recorded item.
    ///
    /// Parameters:
    /// - `self`: the recorder.
    ///
    /// Return: nothing.
    fn deinit(self: *Self) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }

    /// Records one event in readable form; the decoder's `emit` callback.
    ///
    /// Parameters:
    /// - `self`: the recorder.
    /// - `event`: the decoded event.
    ///
    /// Return: nothing; propagates allocation failure.
    fn record(self: *Self, event: VtEvent) anyerror!void {
        // Coalesce adjacent text, so a trace reflects what was decoded rather
        // than how the input happened to be chunked.
        if (event == .text and self.items.items.len > 0) {
            const last = self.items.items[self.items.items.len - 1];
            if (std.mem.startsWith(u8, last, "text:")) {
                const merged = try std.mem.concat(self.allocator, u8, &.{ last, event.text });
                self.allocator.free(last);
                self.items.items[self.items.items.len - 1] = merged;
                return;
            }
        }

        const rendered = switch (event) {
            .text => |text| try self.allocator.print("text:{s}", .{text}),
            .lineFeed => try self.allocator.dupe(u8, "lf"),
            .carriageReturn => try self.allocator.dupe(u8, "cr"),
            .backspace => try self.allocator.dupe(u8, "bs"),
            .tab => try self.allocator.dupe(u8, "tab"),
            .bell => try self.allocator.dupe(u8, "bell"),
            .escape => |byte| try self.allocator.print("esc:{c}", .{byte}),
            .osc => |osc| try self.allocator.print("osc:{?d}:{s}", .{ osc.command, osc.payload }),
            .csi => |csi| blk: {
                var buffer: std.Io.Writer.Allocating = .init(self.allocator);
                defer buffer.deinit();
                try buffer.writer.print("csi:{c}", .{csi.final});
                if (csi.private) |marker| try buffer.writer.print(":private={c}", .{marker});
                for (csi.params) |value| try buffer.writer.print(":{d}", .{value});
                break :blk try self.allocator.dupe(u8, buffer.written());
            },
        };
        try self.items.append(self.allocator, rendered);
    }

    /// Joins the recorded items with spaces.
    ///
    /// Parameters:
    /// - `self`: the recorder.
    ///
    /// Return: the joined trace, caller-owned via `self.allocator`; propagates allocation failure.
    fn joined(self: *Self) ![]u8 {
        return std.mem.join(self.allocator, " ", self.items.items);
    }
};

/// Decodes `input` in one call and renders the event trace.
///
/// Parameters:
/// - `allocator`: owns the returned trace.
/// - `input`: the bytes to decode.
///
/// Return: the space-separated trace, caller-owned; propagates allocation failure.
fn traceOwned(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var recorder = try Recorder.init(allocator);
    defer recorder.deinit();

    var decoder = try VtDecoder.init();
    defer decoder.deinit();
    try decoder.decode(input, &recorder, Recorder.record);
    return recorder.joined();
}

/// Decodes `input` one byte per call and renders the event trace.
///
/// Parameters:
/// - `allocator`: owns the returned trace.
/// - `input`: the bytes to decode.
///
/// Return: the space-separated trace, caller-owned; propagates allocation failure.
fn traceByteByByteOwned(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var recorder = try Recorder.init(allocator);
    defer recorder.deinit();

    var decoder = try VtDecoder.init();
    defer decoder.deinit();
    for (input) |byte| {
        try decoder.decode(&[_]u8{byte}, &recorder, Recorder.record);
    }
    return recorder.joined();
}

test "plain text decodes as a single run" {
    const result = try traceOwned(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("text:hello world", result);
}

test "C0 controls decode to their own events" {
    const result = try traceOwned(std.testing.allocator, "a\r\nb\tc\x08\x07");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("text:a cr lf text:b tab text:c bs bell", result);
}

test "unassigned C0 bytes are dropped rather than emitted as text" {
    // They vanish entirely, leaving the surrounding text contiguous — passing
    // them through would corrupt whatever consumes the decoded stream.
    const result = try traceOwned(std.testing.allocator, "a\x00\x01b");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("text:ab", result);
}

test "CSI parameters decode in order" {
    const result = try traceOwned(std.testing.allocator, "\x1b[1;31m\x1b[2J");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("csi:m:1:31 csi:J:2", result);
}

test "a bare CSI carries no parameters" {
    const result = try traceOwned(std.testing.allocator, "\x1b[H");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("csi:H", result);
}

test "an explicit zero parameter is preserved" {
    // ESC[0m and ESC[m mean the same to a terminal, but they are different
    // sequences and a decoder must not conflate them.
    const result = try traceOwned(std.testing.allocator, "\x1b[0m");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("csi:m:0", result);
}

test "private markers decode separately from parameters" {
    const result = try traceOwned(std.testing.allocator, "\x1b[?25l");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("csi:l:private=?:25", result);
}

test "OSC splits its command from the payload" {
    const result = try traceOwned(std.testing.allocator, "\x1b]0;window title\x07");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("osc:0:window title", result);
}

test "OSC accepts the ST terminator as well as BEL" {
    const result = try traceOwned(std.testing.allocator, "\x1b]2;title\x1b\\rest");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("osc:2:title text:rest", result);
}

test "two-byte escapes decode as themselves" {
    const result = try traceOwned(std.testing.allocator, "\x1bc\x1b7");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("esc:c esc:7", result);
}

test "a sequence split across chunks decodes identically" {
    // The bug this prevents: an ESC[6G cut in half surfaced as literal "6G".
    const input = "before\x1b[6Gafter\x1b]0;title\x07end";

    const whole = try traceOwned(std.testing.allocator, input);
    defer std.testing.allocator.free(whole);
    const split = try traceByteByByteOwned(std.testing.allocator, input);
    defer std.testing.allocator.free(split);

    try std.testing.expectEqualStrings(whole, split);
    try std.testing.expect(std.mem.find(u8, split, "text:6G") == null);
}

test "param and rawParam differ on absent and zero values" {
    var params = [_]u16{ 0, 7 };
    const csi = Csi{ .final = 'm', .private = null, .intermediate = null, .params = &params };

    // Zero means "use the default" for most operations…
    try std.testing.expectEqual(@as(u16, 1), csi.param(0, 1));
    // …but a few need to see it as written.
    try std.testing.expectEqual(@as(u16, 0), csi.rawParam(0, 1));

    try std.testing.expectEqual(@as(u16, 7), csi.param(1, 1));
    try std.testing.expectEqual(@as(u16, 99), csi.param(5, 99));
}

test "excess parameters do not desynchronise the stream" {
    const allocator = std.testing.allocator;
    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();

    try input.writer.writeAll("\x1b[");
    for (0..VtDecoder.max_params + 8) |i| {
        if (i > 0) try input.writer.writeAll(";");
        try input.writer.print("{d}", .{i + 1});
    }
    try input.writer.writeAll("mtail");

    const result = try traceOwned(allocator, input.written());
    defer allocator.free(result);
    try std.testing.expect(std.mem.endsWith(u8, result, "text:tail"));
}

test "a malformed sequence costs one sequence, not the stream" {
    // The NUL aborts the CSI. Everything after it, including the 'm' that
    // would have been the final byte, is ordinary text again — the stream
    // resynchronises immediately instead of being swallowed.
    const result = try traceOwned(std.testing.allocator, "\x1b[1\x00mrecovered");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("text:mrecovered", result);
}

test "UTF-8 passes through untouched" {
    const result = try traceOwned(std.testing.allocator, "caf\u{e9} \u{2713} \u{1f680}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("text:caf\u{e9} \u{2713} \u{1f680}", result);
}

test "reset clears a half-consumed sequence" {
    var recorder = try Recorder.init(std.testing.allocator);
    defer recorder.deinit();

    var decoder = try VtDecoder.init();
    defer decoder.deinit();
    try decoder.decode("\x1b[12", &recorder, Recorder.record);
    decoder.reset();
    try decoder.decode("ok", &recorder, Recorder.record);

    const joined = try recorder.joined();
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("text:ok", joined);
}
