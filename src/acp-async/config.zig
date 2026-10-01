//! Runtime settings for the transports in this package.
//!
//! Every value has a default that suits an editor talking to one agent; a host
//! that needs otherwise sets the field after `init`, before handing the config
//! to a transport. Transports borrow the config, so it must outlive them.

const std = @import("std");
const log = std.log.scoped(.acp_async_config);

/// Transport settings, borrowed by every transport built from them.
pub const Config = struct {
    const Self = @This();

    /// Frames a transport queues unread before it refuses more. A peer flooding
    /// frames nobody reads is a bug, and one that eats memory silently is worse
    /// than one that says so.
    max_queued_frames: usize = 1024,

    /// Creates a config holding every default.
    ///
    /// Return: the config, caller stores it and calls `deinit`; never fails today.
    pub fn init() !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        const self = Self{};
        return self;
    }

    /// Releases the config.
    ///
    /// Parameters:
    /// - `self`: the config.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });

        _ = self;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "a config starts at its defaults and takes an override" {
    var config = try Config.init();
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 1024), config.max_queued_frames);

    config.max_queued_frames = 8;
    try std.testing.expectEqual(@as(usize, 8), config.max_queued_frames);
}
