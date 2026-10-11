//! Session client example: one agent, one session, one turn, through the barrel.
//!
//! What a front end writes: an agent served in-process (`acp.Client.Seam`), a
//! `Client.Session` on the other end that has shaken hands and opened a
//! session, a prompt sent, and the agent's reply read back. The agent here is
//! zigacp's scripted `acp.Test.EchoAgent`; a harness's `AcpAgent` drops in for
//! it unchanged.

const std = @import("std");
const log = std.log.scoped(.acp_cookbook_session_client);
const acp = @import("zigacp");

pub fn main(init: std.process.Init) !void {
    log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

    var agent = try acp.Test.EchoAgent.init(init.gpa);
    defer agent.deinit();

    const seam = try acp.Client.Seam(acp.Test.EchoAgent).start(init.gpa, init.io, &agent, "echo", "Echo", .none, init.environ_map, ".", .{});
    defer seam.deinit();

    const stop = try seam.client.prompt("hello from the session client");
    const reply = try seam.client.liveText(init.gpa);
    defer init.gpa.free(reply);

    var buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try stdout.interface.print("session {s} -> {t}\n{s}\n", .{ seam.client.sessionId(), stop, reply });
    try stdout.interface.flush();
}
