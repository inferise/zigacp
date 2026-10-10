//! CLI barrel for `acp-trace-viewer`, the terminal viewer for captured traces.
//!
//! `cli/` takes `zigtui` and `zigstorage`, and nothing in `src/` depends on it:
//! the toolkit stays out of the library. Every file here reaches both through
//! this barrel.

const std = @import("std");
const builtin = @import("builtin");

pub const is_debug = builtin.mode == .debug;

/// The terminal toolkit: `zigtui`'s components and, re-exported through it,
/// every `zigvaxis` declaration.
pub const tui = @import("zigtui");
/// Disk access, for reading the trace file.
pub const zigstorage = @import("zigstorage");

pub const Trace = @import("trace.zig").Trace;
pub const TraceEntry = @import("trace.zig").TraceEntry;
pub const TraceDirection = @import("trace.zig").TraceDirection;
pub const TraceViewer = @import("trace_viewer.zig").TraceViewer;

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
}
