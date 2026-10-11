//! The terminal screen for one ACP agent: its conversation, a prompt, and what it advertised.
//!
//! ```
//!  Claude · opus · plan                                       ← the agent, its model and mode
//!  You
//!    list the files
//!  Claude
//!    ⚙ ls -la  ✓
//!    One file.
//! ┌ Ask ─────────────────────────────────────────────────────┐
//! │ _                                                        │
//! └──────────────────────────────────────────── enter: send ─┘
//!  claude  ^O menu · ^T open tools · ^L log · ^Q quit        ← the status line
//! ```
//!
//! The screen talks to one `Client.Session` and draws only what the agent
//! advertised or sent: the model and mode pickers when the session reported
//! them, its boolean options, `_inferise/status`, its extensions, accounts and
//! sign-in each only when `initialize` offered them. Nothing here names an agent.
//!
//! **Never block the draw loop.** A prompt runs on the client's own task. Work
//! that waits on the agent — opening the session, switching a setting, asking
//! for status — is held in `deferred` until a frame saying so is painted, then
//! run on the next tick. A sign-in runs on a task of its own (`Client.SignIn`).
//!
//! The root widget keeps focus and routes every key: the menu while it is open,
//! `y`/`a`/`n` while the agent waits on a permission, the scroll keys, and the
//! prompt for everything else.

const std = @import("std");
const log = std.log.scoped(.acp_tui_agent_chat);
const mod = @import("module.zig");

/// Work that waits on the agent, held until a frame announcing it is painted.
const Deferred = union(enum) {
    /// Open the session; at start, and again with Enter after a failure.
    openSession,
    /// Switch to this mode; the id is in `deferred_text`.
    setMode,
    /// Switch to this model; the value is in `deferred_text`.
    setModel,
    /// Turn a boolean option on or off; its id is in `deferred_text`.
    toggleOption: bool,
    /// Ask for `_inferise/status` and show it.
    status,
    /// List the agent's accounts and show them.
    accounts,
    /// Run an advertised extension; its index, with any input in `deferred_text`.
    extension: usize,
};

/// What a menu entry does when chosen.
const MenuAction = union(enum) {
    /// List the session's models.
    models,
    /// List the session's modes.
    modes,
    /// Toggle a boolean option, by index in the session's options.
    toggle: usize,
    /// Ask for status.
    status,
    /// Run an extension, by index in the offer.
    extension: usize,
    /// List accounts.
    accounts,
    /// Sign the default account in, or a named one.
    signIn: ?[]const u8,
    /// Ask for a new account's name, then sign it in.
    signInNew,
    /// Pick this mode, by id.
    pickMode: []const u8,
    /// Pick this model, by value.
    pickModel: []const u8,
    /// Nothing: an information line.
    none,
    /// Show the log.
    showLog,
    /// Leave.
    quit,
};

/// Which list the menu shows.
const MenuLevel = enum { closed, root, models, modes, info };

/// What the input box is asking for.
const Asking = enum { none, extensionInput, accountName };

/// Reaches the screen's own client for a sign-in: no agent is started.
const OwnClient = struct {
    const Self = @This();

    client: *mod.acp.Client.Session,

    const vtable: mod.acp.Client.SignInAgent.VTable = .{ .connect = connect, .release = release };

    fn connect(ctx: *anyopaque) mod.acp.AcpError!*mod.acp.Client.Session {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.client;
    }

    fn release(ctx: *anyopaque) void {
        _ = ctx;
    }
};

/// The single-agent screen; the root widget of a `vxfw.App`.
pub const AgentChat = struct {
    const Self = @This();

    /// How often the screen is repainted while nothing else asks.
    const tick_ms: u32 = 150;
    /// Buffer the terminal's own writes go through.
    const tty_buffer_size = 8 * 1024;
    /// Rows the prompt spends on its border, title and hint.
    const prompt_chrome_rows: u16 = 5;
    /// Lines of text the prompt shows before it stops growing.
    const prompt_max_lines: u16 = 8;
    /// Longest notice kept.
    const notice_len = 200;
    /// Rows moved by a shifted arrow.
    const scroll_step: isize = 3;

    allocator: std.mem.Allocator,
    io: std.Io,
    /// The agent's session. Borrowed; must outlive the screen.
    client: *mod.acp.Client.Session,
    /// The agent's name as a person reads it. Borrowed.
    title: []const u8,
    /// The working directory the session opens in. Borrowed.
    cwd: []const u8,

    /// Whether a session is open; until it is, Enter opens one.
    session_open: bool = false,
    /// What the agent said, folded from the client's record as it is drawn.
    conversation: mod.Conversation,
    /// The record position folded up to.
    record_next: usize = 0,
    /// Whether tool calls show their input and output; `^T` switches it.
    tools_open: bool = false,

    prompt: mod.zigtui.TextEditor,
    clipboard: mod.zigtui.Clipboard,
    log_ring: mod.zigtui.LogRing,
    log_visible: bool = false,
    log_popup: mod.zigtui.Popup = .{},

    menu_level: MenuLevel = .closed,
    picker: mod.zigtui.ListPicker,
    /// What each listed choice does, beside `picker`'s choices; owned by `menu_arena`.
    menu_actions: []const MenuAction = &.{},
    menu_arena: std.heap.ArenaAllocator,
    /// One typed answer: an extension's input, or a new account's name.
    input: mod.zigtui.InputModal,
    asking: Asking = .none,
    /// The extension the input box answers for.
    asking_extension: usize = 0,

    deferred: ?Deferred = null,
    /// The text a deferred switch or extension carries; owned.
    deferred_text: std.ArrayList(u8) = .empty,
    /// A sign-in in progress; owned; null when none.
    sign_in: ?*mod.acp.Client.SignIn = null,
    own_client: OwnClient,

    /// A sentence for the person, shown in the status line until the next key.
    notice: [notice_len]u8 = @splat(0),
    notice_size: usize = 0,
    notice_problem: bool = false,

    /// Rows of the conversation pane at the last draw.
    conversation_rows: u16 = 0,
    conversation_total: usize = 0,
    following: bool = true,
    scroll_line: usize = 0,
    last_top_line: usize = 0,
    /// Set by `^Q` or Quit; the next event ends the app.
    quitting: bool = false,

    /// Creates the screen over a client that has shaken hands.
    ///
    /// Parameters:
    /// - `allocator`: backs the prompt, the menu, the conversation and the log.
    /// - `io`: IO capability for the terminal, the clipboard and the sign-in task.
    /// - `client`: the agent's session; borrowed, must outlive the screen.
    /// - `title`: the agent's name as a person reads it; borrowed.
    /// - `cwd`: the working directory the session opens in; borrowed.
    /// - `environ_map`: the environment, which the clipboard reads; borrowed.
    ///
    /// Return: the screen, caller stores it at a stable address and calls `deinit`; propagates allocation failure.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, client: *mod.acp.Client.Session, title: []const u8, cwd: []const u8, environ_map: *std.process.Environ.Map) mod.acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        var prompt = mod.zigtui.TextEditor.init(allocator);
        errdefer prompt.deinit();
        prompt.submit_on_enter = true;
        prompt.verb = "send";
        try prompt.open("", "");
        var clipboard = mod.zigtui.Clipboard.init(allocator, io, environ_map) catch return error.OutOfMemory;
        errdefer clipboard.deinit();
        var log_ring = mod.zigtui.LogRing.init(allocator, io) catch return error.OutOfMemory;
        errdefer log_ring.deinit();

        return .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .title = title,
            .cwd = cwd,
            .conversation = mod.Conversation.init(allocator),
            .prompt = prompt,
            .clipboard = clipboard,
            .log_ring = log_ring,
            .picker = mod.zigtui.ListPicker.init(allocator),
            .menu_arena = std.heap.ArenaAllocator.init(allocator),
            .input = mod.zigtui.InputModal.init(allocator),
            .own_client = .{ .client = client },
            .deferred = .openSession,
        };
    }

    /// Releases everything the screen owns; the client stays the caller's.
    ///
    /// Parameters:
    /// - `self`: the screen.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        if (self.sign_in) |running| running.deinit();
        self.deferred_text.deinit(self.allocator);
        self.input.deinit();
        self.menu_arena.deinit();
        self.picker.deinit();
        self.log_ring.deinit();
        self.clipboard.deinit();
        self.prompt.deinit();
        self.conversation.deinit();
    }

    /// Takes over the terminal and runs the screen until the person quits.
    ///
    /// Parameters:
    /// - `self`: the screen; it must not move until this returns.
    /// - `environ_map`: the environment `zigvaxis` reads for `TERM`; borrowed.
    ///
    /// Return: nothing once the screen comes down; `error.TransportFailed` when the terminal cannot be taken.
    pub fn run(self: *Self, environ_map: *std.process.Environ.Map) mod.acp.AcpError!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // SAFETY: the Tty writes into it before it ever reads it back.
        var tty_buffer: [tty_buffer_size]u8 = undefined;
        var app = mod.zigtui.vxfw.App.init(self.io, self.allocator, environ_map, &tty_buffer) catch |err| {
            log.err("the terminal could not be taken [{t}]", .{err});
            return error.TransportFailed;
        };
        defer app.deinit();
        // After `app.deinit` in order of registration, so it runs first: the
        // alt-screen exit is written but not flushed by `zigvaxis` itself.
        defer {
            app.vx.resetState(app.tty.writer()) catch |err| log.warn("terminal not reset [{t}]", .{err});
            app.tty.writer().flush() catch |err| log.warn("terminal not restored cleanly [{t}]", .{err});
        }
        mod.zigtui.Theme.prepare(&app.vx);

        // From here until the terminal is handed back, a log record written to
        // stderr would land on top of whatever was just drawn.
        self.log_ring.install();
        defer mod.zigtui.LogRing.uninstall();

        app.run(self.widget(), .{}) catch |err| {
            log.err("the screen stopped [{t}]", .{err});
            return error.TransportFailed;
        };
    }

    /// The screen as the app's root widget.
    ///
    /// Parameters:
    /// - `self`: the screen, at its final address.
    ///
    /// Return: the widget.
    pub fn widget(self: *Self) mod.zigtui.Widget {
        return .{ .userdata = self, .eventHandler = typeErasedEventHandler, .drawFn = typeErasedDrawFn };
    }

    // -------------------------------------------------------------------------
    // Events

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *mod.zigtui.EventContext, event: mod.zigtui.vxfw.Event) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                try ctx.requestFocus(self.widget());
                try ctx.tick(tick_ms, self.widget());
            },
            .tick => {
                self.onTick();
                if (self.quitting) {
                    ctx.quit = true;
                    return;
                }
                try ctx.tick(tick_ms, self.widget());
                ctx.redraw = true;
            },
            .key_press => |key| {
                try self.handleKey(ctx, key);
                if (self.quitting) ctx.quit = true;
                ctx.consumeAndRedraw();
            },
            else => {},
        }
    }

    /// Runs deferred work once its frame has been painted.
    ///
    /// Parameters:
    /// - `self`: the screen.
    ///
    /// Return: nothing.
    pub fn onTick(self: *Self) void {
        self.pollSignIn();
        if (self.deferred) |work| {
            self.deferred = null;
            self.runDeferred(work);
        }
    }

    /// Routes one key: the overlays first, then permissions, scrolling, and the prompt.
    ///
    /// Parameters:
    /// - `self`: the screen.
    /// - `ctx`: the event context, for the clipboard and the input box.
    /// - `key`: the key.
    ///
    /// Return: nothing; propagates the input box's failures.
    pub fn handleKey(self: *Self, ctx: *mod.zigtui.EventContext, key: mod.zigtui.Key) !void {
        if (key.matches('q', .{ .ctrl = true })) {
            self.quitting = true;
            return;
        }
        // Any key answers the last notice.
        self.notice_size = 0;

        if (self.asking != .none) {
            switch (try self.input.handleKey(ctx, key)) {
                .open => {},
                .cancelled => self.closeInput(),
                .submitted => try self.takeInput(),
            }
            return;
        }
        if (self.menu_level != .closed) {
            switch (self.picker.handleKey(key)) {
                .open => {},
                .cancelled => self.menuBack(),
                .submitted => try self.chooseMenu(),
            }
            return;
        }
        if (self.log_visible) {
            if (key.matches(mod.zigtui.Key.escape, .{}) or key.matches('l', .{ .ctrl = true })) {
                self.log_visible = false;
                return;
            }
        }

        if (key.matches('o', .{ .ctrl = true })) return self.openMenu();
        if (key.matches('l', .{ .ctrl = true })) {
            self.log_visible = !self.log_visible;
            return;
        }
        if (key.matches('t', .{ .ctrl = true })) {
            self.tools_open = !self.tools_open;
            return;
        }

        // The agent is blocked until a permission is answered, so it takes the
        // keyboard — but only `y`, `a` and `n`, and only while it waits.
        if (self.client.isAwaitingPermission()) {
            if (key.matches('y', .{})) return self.client.answerPermission(.allowOnce);
            if (key.matches('a', .{})) return self.client.answerPermission(.allowAlways);
            if (key.matches('n', .{})) return self.client.answerPermission(.rejectOnce);
        }

        if (key.matches(mod.zigtui.Key.page_up, .{})) return self.scrollBy(-@as(isize, @intCast(@max(self.conversation_rows, 1))));
        if (key.matches(mod.zigtui.Key.page_down, .{})) return self.scrollBy(@intCast(@max(self.conversation_rows, 1)));
        if (key.matches(mod.zigtui.Key.up, .{ .shift = true })) return self.scrollBy(-scroll_step);
        if (key.matches(mod.zigtui.Key.down, .{ .shift = true })) return self.scrollBy(scroll_step);
        if (key.matches(mod.zigtui.Key.home, .{})) return self.scrollBy(std.math.minInt(isize));
        if (key.matches(mod.zigtui.Key.end, .{})) return self.follow();

        // `Esc` and `^C` cancel a running turn; otherwise they are the prompt's.
        if (key.matches(mod.zigtui.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            if (self.sign_in != null) return self.stopSignIn();
            if (self.client.isWorking()) return self.client.requestCancel();
        }

        switch (try self.prompt.handleKey(key)) {
            .open, .cancelled => {},
            .saved => try self.submit(),
            .copied => {
                const route = self.clipboard.copy(self.prompt.clipped.items);
                if (route == .terminal) try ctx.copyToClipboard(self.prompt.clipped.items);
                self.prompt.notice = "copied";
            },
        }
    }

    /// Sends the prompt's text, or opens the session when there is none.
    ///
    /// Parameters:
    /// - `self`: the screen.
    ///
    /// Return: nothing; propagates allocation failure; a refused send is told to the person.
    pub fn submit(self: *Self) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        // While a sign-in waits for a pasted code, the prompt takes it.
        if (self.sign_in) |running| {
            running.submitCode(self.prompt.text()) catch |err| self.say(true, "the code was not passed on [{t}]", .{err});
            try self.prompt.open("", "");
            return;
        }
        if (!self.session_open) {
            self.deferred = .openSession;
            return;
        }
        const text = self.prompt.text();
        if (text.len == 0) return;
        // `send` puts the turn on a task of its own; `prompt` would block the screen for all of it.
        self.client.send(text) catch |err| {
            self.say(true, "not sent [{t}]", .{err});
            return;
        };
        try self.prompt.open("", "");
        self.follow();
    }

    // -------------------------------------------------------------------------
    // The menu

    /// Opens the menu at its root, listing only what the agent advertised or reported.
    ///
    /// Parameters:
    /// - `self`: the screen.
    ///
    /// Return: nothing; a listing that cannot be built is logged and the menu stays closed.
    pub fn openMenu(self: *Self) void {
        self.listRoot() catch |err| {
            log.warn("menu not listed [{t}]", .{err});
            return;
        };
        self.menu_level = .root;
        self.picker.open();
    }

    fn listRoot(self: *Self) !void {
        _ = self.menu_arena.reset(.retain_capacity);
        const arena = self.menu_arena.allocator();
        var names: std.ArrayList(mod.zigtui.ListChoice) = .empty;
        var actions: std.ArrayList(MenuAction) = .empty;
        const busy: ?[]const u8 = if (self.client.isWorking()) "wait for the turn to end" else null;

        const settings = try self.client.sessionSettings(arena);
        if (settings.models.len > 0) {
            try names.append(arena, .{ .name = "Model…", .note = mod.acp.Client.Settings.nameOf(settings.models, settings.current_model), .refusal = busy });
            try actions.append(arena, .models);
        }
        if (settings.modes.len > 0) {
            try names.append(arena, .{ .name = "Mode…", .note = mod.acp.Client.Settings.nameOf(settings.modes, settings.current_mode), .refusal = busy });
            try actions.append(arena, .modes);
        }
        for (settings.options, 0..) |option, index| {
            if (!option.is_boolean) continue;
            try names.append(arena, .{ .name = option.name, .note = if (option.enabled) "on" else "off", .refusal = busy });
            try actions.append(arena, .{ .toggle = index });
        }
        const offer = self.client.offer;
        if (offer.status) {
            try names.append(arena, .{ .name = "Status" });
            try actions.append(arena, .status);
        }
        for (offer.extensions, 0..) |extension, index| {
            const needs_session = extension.scope == .session and !self.session_open;
            try names.append(arena, .{ .name = extension.label, .refusal = if (needs_session) "no session yet" else busy });
            try actions.append(arena, .{ .extension = index });
        }
        if (offer.accounts) {
            try names.append(arena, .{ .name = "Accounts…" });
            try actions.append(arena, .accounts);
        } else if (offer.sign_in) {
            try names.append(arena, .{ .name = "Sign in", .refusal = busy });
            try actions.append(arena, .{ .signIn = null });
        }
        try names.append(arena, .{ .name = "Show log" });
        try actions.append(arena, .showLog);
        try names.append(arena, .{ .name = "Quit" });
        try actions.append(arena, .quit);

        self.menu_actions = actions.items;
        self.picker.setChoices(.{ .lead = self.title }, names.items);
    }

    fn listSettings(self: *Self, level: MenuLevel) !void {
        _ = self.menu_arena.reset(.retain_capacity);
        const arena = self.menu_arena.allocator();
        const settings = try self.client.sessionSettings(arena);
        const choices = if (level == .models) settings.models else settings.modes;
        const current = if (level == .models) settings.current_model else settings.current_mode;
        const names = try arena.alloc(mod.zigtui.ListChoice, choices.len);
        const actions = try arena.alloc(MenuAction, choices.len);
        for (choices, names, actions) |choice, *name, *action| {
            name.* = .{ .name = choice.name, .note = if (std.mem.eql(u8, choice.id, current)) "current" else null };
            action.* = if (level == .models) .{ .pickModel = choice.id } else .{ .pickMode = choice.id };
        }
        self.menu_actions = actions;
        self.picker.setChoices(.{ .lead = if (level == .models) "Model" else "Mode" }, names);
        self.picker.open();
        self.menu_level = level;
    }

    /// Shows lines of information in the menu, each a choice that does nothing.
    ///
    /// Parameters:
    /// - `self`: the screen.
    /// - `heading`: the list's heading; copied.
    /// - `lines`: what to show; copied.
    /// - `extra`: further choices that do something, after the lines; their names copied.
    ///
    /// Return: nothing; propagates allocation failure.
    fn showInfo(self: *Self, heading: []const u8, lines: []const []const u8, extra: []const struct { []const u8, MenuAction }) !void {
        _ = self.menu_arena.reset(.retain_capacity);
        const arena = self.menu_arena.allocator();
        const names = try arena.alloc(mod.zigtui.ListChoice, lines.len + extra.len);
        const actions = try arena.alloc(MenuAction, lines.len + extra.len);
        for (lines, 0..) |line, index| {
            names[index] = .{ .name = try arena.dupe(u8, line) };
            actions[index] = .none;
        }
        for (extra, lines.len..) |entry, index| {
            names[index] = .{ .name = try arena.dupe(u8, entry[0]) };
            actions[index] = switch (entry[1]) {
                .signIn => |name| .{ .signIn = if (name) |text| try arena.dupe(u8, text) else null },
                else => entry[1],
            };
        }
        self.menu_actions = actions;
        self.picker.setChoices(.{ .lead = try arena.dupe(u8, heading) }, names);
        self.picker.open();
        self.menu_level = .info;
    }

    fn menuBack(self: *Self) void {
        switch (self.menu_level) {
            .models, .modes, .info => self.openMenu(),
            .root, .closed => self.menu_level = .closed,
        }
    }

    fn chooseMenu(self: *Self) !void {
        const index = self.picker.cursor;
        if (index >= self.menu_actions.len) return;
        const action = self.menu_actions[index];
        switch (action) {
            .models => return self.listSettings(.models),
            .modes => return self.listSettings(.modes),
            .none => return,
            else => {},
        }
        self.menu_level = .closed;
        switch (action) {
            .toggle => |option_index| {
                const settings = try self.client.sessionSettings(self.menu_arena.allocator());
                if (option_index >= settings.options.len) return;
                const option = settings.options[option_index];
                try self.holdText(option.id);
                self.deferred = .{ .toggleOption = !option.enabled };
            },
            .pickMode => |id| {
                try self.holdText(id);
                self.deferred = .setMode;
            },
            .pickModel => |value| {
                try self.holdText(value);
                self.deferred = .setModel;
            },
            .status => self.deferred = .status,
            .accounts => self.deferred = .accounts,
            .extension => |extension_index| {
                const extension = self.client.offer.extensions[extension_index];
                if (extension.input) |question| {
                    self.asking = .extensionInput;
                    self.asking_extension = extension_index;
                    try self.input.open(.{ .heading = extension.label, .label = question, .verb = "run" }, null);
                    return;
                }
                self.deferred_text.clearRetainingCapacity();
                self.deferred = .{ .extension = extension_index };
            },
            .signIn => |name| self.beginSignIn(name),
            .signInNew => {
                self.asking = .accountName;
                try self.input.open(.{ .heading = "Sign in", .label = "Account name", .verb = "sign in" }, null);
            },
            .showLog => self.log_visible = true,
            .quit => self.quitting = true,
            .models, .modes, .none => {},
        }
    }

    fn closeInput(self: *Self) void {
        self.input.close();
        self.asking = .none;
    }

    fn takeInput(self: *Self) !void {
        const asked = self.asking;
        const value = try self.input.value(self.allocator);
        defer self.allocator.free(value);
        self.closeInput();
        switch (asked) {
            .extensionInput => {
                try self.holdText(value);
                self.deferred = .{ .extension = self.asking_extension };
            },
            .accountName => self.beginSignIn(value),
            .none => {},
        }
    }

    fn holdText(self: *Self, text: []const u8) !void {
        self.deferred_text.clearRetainingCapacity();
        try self.deferred_text.appendSlice(self.allocator, text);
    }

    // -------------------------------------------------------------------------
    // What the screen does

    /// Carries out work that waits on the agent, now that a frame says so.
    ///
    /// Parameters:
    /// - `self`: the screen.
    /// - `work`: what to do.
    ///
    /// Return: nothing; a failure is told to the person, not fatal.
    pub fn runDeferred(self: *Self, work: Deferred) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const text = self.deferred_text.items;
        switch (work) {
            .openSession => {
                self.client.connectAs(self.cwd, null, null, null) catch |err| {
                    log.err("{s}: no session [{t}]", .{ self.title, err });
                    const hint: []const u8 = if (self.client.offer.sign_in) " — ^O signs in" else "";
                    self.say(true, "{s} opened no session [{t}]{s}; Enter tries again", .{ self.title, err, hint });
                    return;
                };
                self.session_open = true;
            },
            .setMode => self.client.setMode(text) catch |err| self.say(true, "mode stays as it was [{t}]", .{err}),
            .setModel => self.client.setModel(text) catch |err| self.say(true, "model stays as it was [{t}]", .{err}),
            .toggleOption => |enabled| self.client.setOption(text, .{ .enabled = enabled }) catch |err| self.say(true, "{s} stays as it was [{t}]", .{ text, err }),
            .status => self.showStatus() catch |err| self.say(true, "no status [{t}]", .{err}),
            .accounts => self.showAccounts() catch |err| self.say(true, "no accounts listed [{t}]", .{err}),
            .extension => |index| self.runExtension(index, if (text.len > 0) text else null),
        }
    }

    fn showStatus(self: *Self) !void {
        const answer = try self.client.status();
        defer answer.deinit();
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(self.allocator);
        const arena = answer.arena.allocator();
        if (answer.value.cli) |version| try lines.append(self.allocator, try std.fmt.allocPrint(arena, "CLI  {s}", .{version}));
        if (answer.value.account) |account| try lines.append(self.allocator, try std.fmt.allocPrint(arena, "Account  {s}", .{account}));
        for (answer.value.fields) |field| try lines.append(self.allocator, try std.fmt.allocPrint(arena, "{s}  {s}", .{ field.label, field.value }));
        try self.showInfo("Status", lines.items, &.{});
    }

    fn showAccounts(self: *Self) !void {
        const answer = try self.client.accounts();
        defer answer.deinit();
        const arena = answer.arena.allocator();
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(self.allocator);
        var extra: std.ArrayList(struct { []const u8, MenuAction }) = .empty;
        defer extra.deinit(self.allocator);
        for (answer.value.accounts) |account| {
            const marks = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ account.name, if (account.is_default) "  (default)" else "", if (account.signed_in) "  signed in" else "  not signed in" });
            if (self.client.offer.sign_in and !account.signed_in) {
                try extra.append(self.allocator, .{ try std.fmt.allocPrint(arena, "Sign in {s}", .{account.name}), .{ .signIn = account.name } });
            } else try lines.append(self.allocator, marks);
        }
        if (self.client.offer.sign_in) try extra.append(self.allocator, .{ "Sign in another account…", .signInNew });
        try self.showInfo("Accounts", lines.items, extra.items);
    }

    fn runExtension(self: *Self, index: usize, input: ?[]const u8) void {
        if (index >= self.client.offer.extensions.len) return;
        const extension = self.client.offer.extensions[index];
        const answer = self.client.runExtension(extension.method, input) catch |err| {
            self.say(true, "{s} failed [{t}]", .{ extension.label, err });
            return;
        };
        defer answer.deinit();
        self.say(false, "{s}: {s}", .{ extension.label, answer.value.summary orelse "done" });
    }

    /// Starts signing an account in over the screen's own client.
    ///
    /// Parameters:
    /// - `self`: the screen.
    /// - `account`: the account's name, or null for the default; copied.
    ///
    /// Return: nothing; a refusal is told to the person.
    fn beginSignIn(self: *Self, account: ?[]const u8) void {
        if (self.sign_in != null) return self.say(true, "a sign-in is already running", .{});
        if (self.client.isWorking()) return self.say(true, "wait for the turn to end", .{});
        self.sign_in = mod.acp.Client.SignIn.begin(self.allocator, self.io, .{ .ptr = &self.own_client, .vtable = &OwnClient.vtable }, self.title, account) catch |err| {
            self.say(true, "the sign-in did not start [{t}]", .{err});
            return;
        };
    }

    fn pollSignIn(self: *Self) void {
        const running = self.sign_in orelse return;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const seen = running.view(arena_state.allocator()) catch return;
        switch (seen.phase) {
            .starting, .waiting => return,
            .signedIn => self.say(false, "{s} is signed in", .{if (seen.account.len > 0) seen.account else self.title}),
            .failed => self.say(true, "not signed in: {s}", .{if (seen.summary.len > 0) seen.summary else "the sign-in ended"}),
        }
        running.deinit();
        self.sign_in = null;
        // A session refused for want of an account is tried again at once.
        if (!self.session_open and seen.phase == .signedIn) self.deferred = .openSession;
    }

    fn stopSignIn(self: *Self) void {
        if (self.sign_in) |running| running.deinit();
        self.sign_in = null;
        self.say(false, "sign-in cancelled", .{});
    }

    /// Keeps one sentence for the status line.
    ///
    /// Parameters:
    /// - `self`: the screen.
    /// - `problem`: true when something went wrong.
    /// - `format`: the sentence's format.
    /// - `args`: its arguments.
    ///
    /// Return: nothing; a sentence too long is cut.
    fn say(self: *Self, problem: bool, comptime format: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.notice, format, args) catch self.notice[0..];
        self.notice_size = written.len;
        self.notice_problem = problem;
    }

    // -------------------------------------------------------------------------
    // Scrolling

    fn scrollBy(self: *Self, delta: isize) void {
        const from = if (self.following) self.last_top_line else self.scroll_line;
        const total = self.conversation_total -| self.conversation_rows + 1;
        if (self.following and delta >= 0) return self.follow();
        const signed_from: isize = @intCast(@min(from, std.math.maxInt(isize)));
        const moved = signed_from +| delta;
        if (moved <= 0) {
            self.following = false;
            self.scroll_line = 0;
            return;
        }
        const target: usize = @intCast(moved);
        if (target + 1 >= total) return self.follow();
        self.following = false;
        self.scroll_line = target;
    }

    fn follow(self: *Self) void {
        self.following = true;
        self.scroll_line = 0;
    }

    // -------------------------------------------------------------------------
    // Drawing

    /// Brings the conversation up to date with the client's record.
    ///
    /// Parameters:
    /// - `self`: the screen.
    /// - `arena`: the frame's arena, for the record's copies.
    ///
    /// Return: nothing; propagates allocation failure.
    pub fn fold(self: *Self, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
        const page = self.client.recordSince(arena, self.record_next) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        if (page.restarted) self.conversation.clear();
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
        self.record_next = page.next;
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: mod.zigtui.DrawContext) std.mem.Allocator.Error!mod.zigtui.Surface {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        if (max.width == 0 or max.height < 3) return .empty(self.widget());

        var kids: std.ArrayList(mod.zigtui.SubSurface) = .empty;
        const prompt_height = @min(self.promptHeight(), max.height -| 2);
        const talk: mod.zigtui.Size = .{ .width = max.width, .height = max.height -| prompt_height -| 2 };

        // The head: the agent, its model and its mode.
        try kids.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawLine(ctx, max.width, try self.headSpans(ctx.arena)) });
        try kids.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 0 }, .surface = try self.drawConversation(ctx.withConstraints(talk, .fromSize(talk)), talk) });

        self.prompt.label = if (self.sign_in != null) "Code" else if (self.session_open) "Ask" else "Enter opens the session";
        self.prompt.name = self.title;
        self.prompt.max_width = max.width;
        self.prompt.max_height = prompt_height;
        const asking: mod.zigtui.Size = .{ .width = max.width, .height = prompt_height };
        const prompt_surface = try self.prompt.draw(ctx.withConstraints(asking, .fromSize(asking)));
        const prompt_row: u16 = 1 + talk.height;
        try kids.append(ctx.arena, .{ .origin = .{ .row = @intCast(prompt_row), .col = 0 }, .surface = prompt_surface });
        try kids.append(ctx.arena, .{ .origin = .{ .row = @intCast(max.height - 1), .col = 0 }, .surface = try self.drawLine(ctx, max.width, try self.statusSpans(ctx.arena)) });

        const body: mod.zigtui.Size = .{ .width = max.width, .height = max.height -| 1 };
        if (self.log_visible) {
            const room: mod.zigtui.Size = .{ .width = body.width -| 4, .height = body.height / 2 };
            const records = try ctx.arena.create(mod.zigtui.LogView);
            records.* = .{ .ring = &self.log_ring, .rule = false };
            self.log_popup.top = std.math.maxInt(u16);
            const shown = try self.log_popup.draw(ctx.withConstraints(.{}, .fromSize(room)), records.widget());
            try kids.append(ctx.arena, mod.zigtui.Overlay.center(shown, body));
        }
        var overlay_at: ?mod.zigtui.SubSurface = null;
        if (self.asking != .none) {
            overlay_at = mod.zigtui.Overlay.center(try self.input.draw(ctx.withConstraints(.{}, .fromSize(body))), body);
        } else if (self.menu_level != .closed) {
            overlay_at = mod.zigtui.Overlay.center(try self.picker.draw(ctx.withConstraints(.{}, .fromSize(body))), body);
        }
        if (overlay_at) |placed| try kids.append(ctx.arena, placed);

        // The root keeps focus, so the field being typed into reports its cursor here.
        const cursor = if (self.asking != .none)
            mod.zigtui.Overlay.liftCursor(overlay_at.?.surface, overlay_at.?.origin.row, overlay_at.?.origin.col, max)
        else if (self.menu_level == .closed)
            mod.zigtui.Overlay.liftCursor(prompt_surface, prompt_row, 0, max)
        else
            null;

        return .{ .size = max, .widget = self.widget(), .cursor = cursor, .buffer = &.{}, .children = try kids.toOwnedSlice(ctx.arena) };
    }

    fn drawLine(self: *Self, ctx: mod.zigtui.DrawContext, width: u16, spans: []const mod.zigtui.TextSpan) std.mem.Allocator.Error!mod.zigtui.Surface {
        _ = self;
        const line = try ctx.arena.create(mod.zigtui.vxfw.RichText);
        line.* = .{ .text = spans, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        return line.widget().draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    }

    fn promptHeight(self: *const Self) u16 {
        const lines: u16 = @intCast(@min(std.mem.count(u8, self.prompt.draft.items, "\n") + 1, prompt_max_lines));
        return lines + prompt_chrome_rows;
    }

    fn drawConversation(self: *Self, ctx: mod.zigtui.DrawContext, size: mod.zigtui.Size) std.mem.Allocator.Error!mod.zigtui.Surface {
        self.conversation_rows = size.height;
        try self.fold(ctx.arena);

        const view = mod.ConversationView{ .conversation = &self.conversation, .agent = self.title, .expanded = self.tools_open };
        var entries: std.ArrayList(mod.zigtui.TranscriptEntry) = .empty;
        try entries.appendSlice(ctx.arena, try view.entries(ctx.arena));
        if (self.client.isWorking()) try entries.append(ctx.arena, .{ .text = "working… (esc cancels)", .role = .warningText });
        const rows: []const []const mod.zigtui.TextSpan = if (entries.items.len == 0)
            try ctx.arena.dupe([]const mod.zigtui.TextSpan, &.{try ctx.arena.dupe(mod.zigtui.TextSpan, &.{.{
                .text = if (self.session_open) "  nothing yet — send a prompt" else "  opening a session…",
                .style = mod.zigtui.Theme.secondaryText.style(),
            }})})
        else
            try (mod.zigtui.TranscriptView{ .entries = entries.items }).lines(ctx.arena, size.width);

        self.conversation_total = rows.len;
        const top = if (self.following) rows.len -| size.height else @min(self.scroll_line, rows.len -| 1);
        self.last_top_line = top;
        const shown = rows[top..@min(rows.len, top + size.height)];

        const children = try ctx.arena.alloc(mod.zigtui.SubSurface, shown.len);
        for (shown, 0..) |spans, r| {
            children[r] = .{ .origin = .{ .row = @intCast(r), .col = 0 }, .surface = try self.drawLine(ctx, size.width, spans) };
        }
        return .{ .size = size, .widget = self.widget(), .buffer = &.{}, .children = children };
    }

    /// The head line: the agent, and the model and mode the session reported.
    ///
    /// Parameters:
    /// - `self`: the screen.
    /// - `arena`: owns the spans.
    ///
    /// Return: the spans; propagates allocation failure.
    pub fn headSpans(self: *Self, arena: std.mem.Allocator) std.mem.Allocator.Error![]const mod.zigtui.TextSpan {
        var spans: std.ArrayList(mod.zigtui.TextSpan) = .empty;
        try spans.append(arena, .{ .text = try std.fmt.allocPrint(arena, " {s}", .{self.title}), .style = .{ .fg = mod.zigtui.Theme.titleText.color(), .bold = true } });
        const settings = self.client.sessionSettings(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return spans.items,
        };
        if (settings.current_model.len > 0) try spans.append(arena, .{ .text = try std.fmt.allocPrint(arena, " · {s}", .{mod.acp.Client.Settings.nameOf(settings.models, settings.current_model)}), .style = mod.zigtui.Theme.secondaryText.style() });
        if (settings.current_mode.len > 0) try spans.append(arena, .{ .text = try std.fmt.allocPrint(arena, " · {s}", .{mod.acp.Client.Settings.nameOf(settings.modes, settings.current_mode)}), .style = mod.zigtui.Theme.secondaryText.style() });
        if (try self.client.lastUsage(arena)) |usage| {
            if (usage.context_tokens) |used| try spans.append(arena, .{ .text = try std.fmt.allocPrint(arena, " · {d} in context", .{used}), .style = mod.zigtui.Theme.secondaryText.style() });
        }
        return spans.items;
    }

    /// The status line: a permission, a sign-in, deferred work, a notice, or the keys.
    ///
    /// Parameters:
    /// - `self`: the screen.
    /// - `arena`: owns the spans.
    ///
    /// Return: the spans; propagates allocation failure.
    pub fn statusSpans(self: *Self, arena: std.mem.Allocator) std.mem.Allocator.Error![]const mod.zigtui.TextSpan {
        if (self.deferred) |work| {
            const said: []const u8 = switch (work) {
                .openSession => try std.fmt.allocPrint(arena, "Opening a {s} session…", .{self.title}),
                .setMode, .setModel, .toggleOption => "Switching…",
                .status => "Asking for status…",
                .accounts => "Listing accounts…",
                .extension => "Running…",
            };
            return (mod.zigtui.StatusLine{ .mode = "working", .notice = .{ .text = said } }).spans(arena);
        }

        if (self.client.isAwaitingPermission()) {
            const summary = self.client.permissionSummary(arena) catch null;
            const question = try std.fmt.allocPrint(arena, "Allow {s}?  ", .{(summary orelse null) orelse "this tool"});
            const hints = [_]mod.zigtui.KeyHint{ .{ .key = "y", .action = "yes" }, .{ .key = "a", .action = "always" }, .{ .key = "n", .action = "no" } };
            return lead(arena, question, try (mod.zigtui.StatusLine{ .hints = &hints }).spans(arena));
        }

        if (self.sign_in) |running| {
            const seen = try running.view(arena);
            const who = if (seen.account.len > 0) seen.account else "the default account";
            const said = switch (seen.phase) {
                .starting => try std.fmt.allocPrint(arena, "Signing {s} in…", .{who}),
                else => if (seen.url.len == 0)
                    try std.fmt.allocPrint(arena, "{s}: {s}", .{ who, seen.summary })
                else
                    try std.fmt.allocPrint(arena, "Sign {s} in at {s}{s}{s}{s}", .{ who, seen.url, if (seen.user_code.len > 0) " with code " else "", seen.user_code, if (seen.needs_code) " — paste the code it shows and press Enter" else "" }),
            };
            const hints = [_]mod.zigtui.KeyHint{.{ .key = "esc", .action = "cancel" }};
            return lead(arena, said, try (mod.zigtui.StatusLine{ .mode = "  ", .hints = &hints }).spans(arena));
        }

        if (self.notice_size > 0) {
            return (mod.zigtui.StatusLine{ .mode = self.title, .notice = .{ .text = try arena.dupe(u8, self.notice[0..self.notice_size]), .problem = self.notice_problem } }).spans(arena);
        }

        const hints = [_]mod.zigtui.KeyHint{
            .{ .key = "^O", .action = "menu" },
            .{ .key = "^T", .action = if (self.tools_open) "close tools" else "open tools" },
            .{ .key = "^L", .action = "log" },
            .{ .key = "^Q", .action = "quit" },
        };
        const keys = try (mod.zigtui.StatusLine{ .mode = self.title, .hints = &hints }).spans(arena);
        if (self.following) return keys;
        const scrolled = try arena.alloc(mod.zigtui.TextSpan, keys.len + 1);
        @memcpy(scrolled[0..keys.len], keys);
        scrolled[keys.len] = .{ .text = "  ⇡ scrolled (End follows)", .style = mod.zigtui.Theme.warningText.style() };
        return scrolled;
    }

    fn lead(arena: std.mem.Allocator, question: []const u8, rest: []const mod.zigtui.TextSpan) std.mem.Allocator.Error![]const mod.zigtui.TextSpan {
        const spans = try arena.alloc(mod.zigtui.TextSpan, rest.len + 1);
        spans[0] = .{ .text = question, .style = .{ .fg = mod.zigtui.Theme.keyHint.color(), .bold = true } };
        @memcpy(spans[1..], rest);
        return spans;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(AgentChat);
}

/// Waits for a client's turn to end.
///
/// Parameters:
/// - `io`: IO capability, for the sleep.
/// - `client`: the client.
///
/// Return: nothing once idle; `error.Timeout` after a few seconds.
fn untilIdle(io: std.Io, client: *mod.acp.Client.Session) !void {
    var waited: usize = 0;
    while (client.isWorking()) : (waited += 1) {
        if (waited > 400) return error.Timeout;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
}

/// Reports whether any span holds a piece of text.
///
/// Parameters:
/// - `spans`: the spans.
/// - `part`: the text looked for.
///
/// Return: true when one span contains it.
fn spansHave(spans: []const mod.zigtui.TextSpan, part: []const u8) bool {
    for (spans) |span| if (std.mem.find(u8, span.text, part) != null) return true;
    return false;
}

test "the screen opens a session, sends a prompt and folds the reply, with no terminal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var agent = try mod.acp.Test.EchoAgent.init(allocator);
    defer agent.deinit();
    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    const seam = try mod.acp.Client.Seam(mod.acp.Test.EchoAgent).start(allocator, io, &agent, "echo", "Echo", .none, &environ_map, ".", .{ .open_session = false });
    defer seam.deinit();

    var chat = try AgentChat.init(allocator, io, seam.client, "Echo", ".", &environ_map);
    defer chat.deinit();

    // The first tick opens the session the first frame announced.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(spansHave(try chat.statusSpans(arena), "Opening an Echo session") or spansHave(try chat.statusSpans(arena), "Opening a Echo session"));
    chat.onTick();
    try std.testing.expect(chat.session_open);

    try chat.prompt.open("", "count the birds");
    try chat.submit();
    try untilIdle(io, seam.client);
    try chat.fold(arena);
    const view = mod.ConversationView{ .conversation = &chat.conversation, .agent = "Echo" };
    const entries = try view.entries(arena);
    var found = false;
    for (entries) |entry| {
        if (std.mem.find(u8, entry.text, "echo: count the birds") != null) found = true;
    }
    try std.testing.expect(found);
}

test "the menu lists only what the agent advertised, and a mode switch waits for its frame" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var agent = try mod.acp.Test.EchoAgent.init(allocator);
    defer agent.deinit();
    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    const seam = try mod.acp.Client.Seam(mod.acp.Test.EchoAgent).start(allocator, io, &agent, "echo", "Echo", .none, &environ_map, ".", .{ .open_session = false });
    defer seam.deinit();
    var chat = try AgentChat.init(allocator, io, seam.client, "Echo", ".", &environ_map);
    defer chat.deinit();
    chat.onTick();

    chat.openMenu();
    try std.testing.expectEqual(MenuLevel.root, chat.menu_level);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(allocator);
    for (chat.picker.choices.items) |choice| {
        try names.appendSlice(allocator, choice.name);
        try names.append(allocator, '|');
    }
    // Modes and the boolean option the session reported, status as advertised; no accounts, no sign-in.
    try std.testing.expectEqualStrings("Mode…|Always approve|Status|Show log|Quit|", names.items);

    // Mode… lists the modes; choosing Plan defers the switch to the next tick.
    chat.picker.cursor = 0;
    try chat.chooseMenu();
    try std.testing.expectEqual(MenuLevel.modes, chat.menu_level);
    chat.picker.cursor = 1;
    try chat.chooseMenu();
    try std.testing.expect(chat.deferred != null);
    chat.onTick();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const settings = try seam.client.sessionSettings(arena_state.allocator());
    try std.testing.expectEqualStrings("plan", settings.current_mode);
}

test "a permission the agent asks for is answered from the keyboard's choices" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var agent = try mod.acp.Test.EchoAgent.init(allocator);
    defer agent.deinit();
    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    const seam = try mod.acp.Client.Seam(mod.acp.Test.EchoAgent).start(allocator, io, &agent, "echo", "Echo", .none, &environ_map, ".", .{ .open_session = false });
    defer seam.deinit();
    var chat = try AgentChat.init(allocator, io, seam.client, "Echo", ".", &environ_map);
    defer chat.deinit();
    chat.onTick();

    try chat.prompt.open("", "ask delete the files");
    try chat.submit();
    var waited: usize = 0;
    while (!seam.client.isAwaitingPermission()) : (waited += 1) {
        if (waited > 400) return error.Timeout;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Answered before anything is checked, so a failed check cannot leave the agent blocked.
    const asked = spansHave(try chat.statusSpans(arena), "Allow delete the files?");
    seam.client.answerPermission(.rejectOnce);
    try std.testing.expect(asked);
    try untilIdle(io, seam.client);
    const live = try seam.client.liveText(allocator);
    defer allocator.free(live);
    try std.testing.expect(std.mem.find(u8, live, "(no)") != null);
}
