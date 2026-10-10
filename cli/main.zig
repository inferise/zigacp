const std = @import("std");
const log = std.log.scoped(.acp_trace_viewer_main);
const cli = @import("module.zig");

/// Log configuration for the executable.
///
/// The viewer owns the terminal, so anything written to stderr while it runs
/// corrupts the display, the debug entry traces included. Errors only.
pub const std_options: std.Options = .{
    .log_level = .err,
};

/// Restores the terminal before the default panic handler runs, so a crash
/// inside a draw call does not leave the shell in raw mode.
pub const panic = cli.tui.Panic;

/// Entry point for `acp-trace-viewer <trace-file>`.
///
/// Parameters:
/// - `init`: the runtime's allocator, IO, arguments and environment.
///
/// Return: nothing; exits 2 without a trace file and 1 when it cannot be read, else propagates terminal failures.
pub fn main(init: std.process.Init) !void {
    log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        log.err("usage: acp-trace-viewer <trace-file>", .{});
        std.process.exit(2);
    }

    // Read before the terminal is taken, so a missing file is reported where it can be read.
    // A status rather than an error keeps a stack trace off an ordinary situation.
    var trace = cli.Trace.init(init.gpa, init.io, init.minimal.environ, args[1]) catch |err| {
        log.err("cannot read {s}: {t}", .{ args[1], err });
        std.process.exit(1);
    };
    defer trace.deinit();

    // The root widget's address is its userdata: it must not move during the run.
    var viewer: cli.TraceViewer = .init(&trace);
    try cli.tui.Session.run(init.io, init.gpa, init.environ_map, viewer.widget());
}
