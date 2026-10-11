//! A scripted ACP agent served in-process, for tests and demos of a client.
//!
//! It names no model and runs no tool: a prompt is answered by streaming
//! `echo: <prompt>` back as one `agent_message_chunk`, and the turn ends with
//! `_meta.inferise.usage`. A prompt that starts with `ask ` first asks the
//! client's permission, and the reply says what was chosen. It advertises the
//! inferise extension's `status`, two modes (`default`, `plan`) and the boolean
//! config option `alwaysApprove`, so every part a client draws from an
//! advertisement has something to draw.
//!
//! It satisfies `LocalSeam`'s contract: `attach(*Connection) void` and
//! `serve() AcpError!void`.

const std = @import("std");
const log = std.log.scoped(.acp_test_echo_agent);
const acp = @import("module.zig");

/// A scripted agent: echoes each prompt, asks permission when told to.
pub const TestEchoAgent = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    dispatcher: acp.Dispatcher,
    /// Set by `attach`; the connection the agent writes its updates on.
    connection: ?*acp.Connection = null,
    /// Numbers sessions, `echo-1` onward. Touched only on the serve task.
    next_session: u32 = 1,
    /// Whether `alwaysApprove` is on; touched only on the serve task.
    always_approve: bool = false,
    /// The current mode; static.
    mode: []const u8 = "default",

    /// Creates the agent and registers every method it serves.
    ///
    /// Parameters:
    /// - `allocator`: backs the dispatcher.
    ///
    /// Return: the agent; caller calls `attach`, `serve` (through `LocalSeam`) and `deinit`.
    pub fn init(allocator: std.mem.Allocator) acp.AcpError!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        return .{ .allocator = allocator, .dispatcher = acp.Dispatcher.init(allocator) };
    }

    /// Releases the dispatcher.
    ///
    /// Parameters:
    /// - `self`: the agent.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.dispatcher.deinit();
    }

    /// Binds the agent to the connection it serves on.
    ///
    /// Parameters:
    /// - `self`: the agent, at a stable address.
    /// - `connection`: the agent's end; borrowed, must outlive serving.
    ///
    /// Return: nothing; a method that cannot be registered is logged and left unserved.
    pub fn attach(self: *Self, connection: *acp.Connection) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        self.connection = connection;
        self.register() catch |err| log.warn("echo agent not fully registered [{t}]", .{err});
        connection.setRequestHandler(self.dispatcher.requestHandler());
        connection.setNotificationHandler(self.dispatcher.notificationHandler());
    }

    /// Serves until the client goes.
    ///
    /// Parameters:
    /// - `self`: the agent, attached.
    ///
    /// Return: nothing once the transport closes; propagates other transport failures.
    pub fn serve(self: *Self) acp.AcpError!void {
        const connection = self.connection orelse return error.TransportClosed;
        return connection.serve();
    }

    fn register(self: *Self) !void {
        try self.dispatcher.registerRequestFn(acp.Agent.method_initialize, self, initialize);
        try self.dispatcher.registerRequestFn(acp.Agent.method_session_new, self, newSession);
        try self.dispatcher.registerRequestFn(acp.Agent.method_session_prompt, self, prompt);
        try self.dispatcher.registerRequestFn(acp.Agent.method_session_set_mode, self, setMode);
        try self.dispatcher.registerRequestFn(acp.Agent.method_session_set_config_option, self, setOption);
        try self.dispatcher.registerRequestFn(acp.Inferise.method_status, self, status);
        try self.dispatcher.registerNotificationFn(acp.Agent.method_session_cancel, self, cancel);
    }

    fn initialize(self: *Self, arena: std.mem.Allocator, params: acp.Agent.InitializeRequest) acp.AcpError!acp.Agent.InitializeResponse {
        _ = self;
        _ = params;
        return .{
            .protocolVersion = acp.ProtocolVersion.V1,
            .agentInfo = .{ .name = "echo", .title = "Echo", .version = "1.0.0" },
            .agentCapabilities = .{ ._meta = try acp.Meta.of(arena, acp.Inferise.key, acp.Inferise.Capabilities{ .status = true }) },
        };
    }

    fn newSession(self: *Self, arena: std.mem.Allocator, params: acp.Agent.NewSessionRequest) acp.AcpError!acp.Agent.NewSessionResponse {
        _ = params;
        const id = try std.fmt.allocPrint(arena, "echo-{d}", .{self.next_session});
        self.next_session += 1;
        const modes = try arena.dupe(acp.Agent.SessionMode, &.{ .{ .id = "default", .name = "Ask" }, .{ .id = "plan", .name = "Plan" } });
        const options = try arena.dupe(acp.Agent.SessionConfigOption, &.{.{ .boolean = .{ .id = "alwaysApprove", .name = "Always approve", .current_value = self.always_approve } }});
        return .{ .session_id = .{ .value = id }, .modes = .{ .current_mode_id = self.mode, .available_modes = modes }, .config_options = options };
    }

    fn prompt(self: *Self, arena: std.mem.Allocator, params: acp.Agent.PromptRequest) acp.AcpError!acp.Agent.PromptResponse {
        const connection = self.connection orelse return error.TransportClosed;
        var text: std.ArrayList(u8) = .empty;
        for (params.prompt) |block| if (block == .text) try text.appendSlice(arena, block.text.text);

        var reply = try std.fmt.allocPrint(arena, "echo: {s}", .{text.items});
        if (std.mem.startsWith(u8, text.items, "ask ") and !self.always_approve) {
            const options = [_]acp.Client.PermissionOption{
                .{ .optionId = "yes", .name = "Allow", .kind = .allow_once },
                .{ .optionId = "no", .name = "Reject", .kind = .reject_once },
            };
            const answer = try connection.request(acp.Client.RequestPermissionResponse, acp.Client.method_session_request_permission, acp.Client.RequestPermissionRequest{
                .sessionId = params.sessionId,
                .toolCall = .{ .toolCallId = .{ .value = "echo-ask" }, .title = text.items[4..] },
                .options = &options,
            });
            defer answer.deinit();
            const chosen = switch (answer.value.outcome) {
                .selected => |selected| try arena.dupe(u8, selected.optionId),
                .cancelled => "cancelled",
            };
            reply = try std.fmt.allocPrint(arena, "{s} ({s})", .{ reply, chosen });
        }

        try connection.notify(acp.Agent.method_session_update, acp.Agent.SessionNotification{
            .sessionId = params.sessionId,
            .update = .{ .agentMessageChunk = .{ .content = .{ .text = .{ .text = reply } } } },
        });
        const usage = acp.Inferise.TurnUsage{ .wall_ms = 1, .input_tokens = text.items.len, .output_tokens = reply.len };
        return .{ .stopReason = .end_turn, ._meta = try acp.Meta.of(arena, acp.Inferise.key, acp.Inferise.TurnMeta{ .usage = usage }) };
    }

    fn setMode(self: *Self, arena: std.mem.Allocator, params: acp.Agent.SetModeRequest) acp.AcpError!acp.Agent.SetModeResponse {
        _ = arena;
        if (std.mem.eql(u8, params.modeId, "default")) self.mode = "default" else if (std.mem.eql(u8, params.modeId, "plan")) self.mode = "plan" else return error.InvalidParams;
        return .{};
    }

    fn setOption(self: *Self, arena: std.mem.Allocator, params: acp.Agent.SetConfigOptionRequest) acp.AcpError!acp.Agent.SetConfigOptionResponse {
        if (!std.mem.eql(u8, params.config_id, "alwaysApprove") or params.value.value != .bool) return error.InvalidParams;
        self.always_approve = params.value.value.bool;
        const options = try arena.dupe(acp.Agent.SessionConfigOption, &.{.{ .boolean = .{ .id = "alwaysApprove", .name = "Always approve", .current_value = self.always_approve } }});
        return .{ .config_options = options };
    }

    fn status(self: *Self, arena: std.mem.Allocator, params: acp.Inferise.StatusRequest) acp.AcpError!acp.Inferise.StatusResponse {
        _ = params;
        const fields = try arena.dupe(acp.Inferise.StatusField, &.{.{ .label = "Mode", .value = self.mode }});
        return .{ .fields = fields };
    }

    fn cancel(self: *Self, arena: std.mem.Allocator, params: acp.Agent.CancelNotification) acp.AcpError!void {
        _ = self;
        _ = arena;
        _ = params;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(TestEchoAgent);
}

test "the echo agent answers the handshake and echoes a prompt" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var agent = try TestEchoAgent.init(allocator);
    defer agent.deinit();
    const seam = try acp.LocalSeam(TestEchoAgent).start(allocator, io, &agent);
    defer seam.deinit();

    var client = acp.Connection.init(allocator, seam.clientTransport());
    const hello = try client.request(acp.Agent.InitializeResponse, acp.Agent.method_initialize, acp.Agent.InitializeRequest{ .protocolVersion = acp.ProtocolVersion.V1 });
    defer hello.deinit();
    try std.testing.expectEqualStrings("echo", hello.value.agentInfo.?.name);
    const served = (try acp.Meta.read(acp.Inferise.Capabilities, allocator, hello.value.agentCapabilities.?._meta, acp.Inferise.key)).?;
    try std.testing.expect(served.status);
    seam.stop();
}
