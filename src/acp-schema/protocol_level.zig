//! Protocol-level control messages, served by either side.
//!
//! `$/cancel_request` asks the peer to stop work on one of its pending
//! requests. ACP stabilized it on 2026-06-29; it was once behind
//! `-Dunstable_cancel_request`, under a draft shape (`id`, `reason`).

const std = @import("std");
const RequestId = @import("rpc.zig").RequestId;
const RawValue = @import("serde_util.zig").RawValue;

pub const method_cancel_request: []const u8 = "$/cancel_request";

/// Asks the peer to cancel a request it has not answered yet; a notification.
pub const CancelRequestNotification = struct {
    /// The id of the request to cancel.
    requestId: RequestId,
    /// Extension data, namespaced by whoever adds it (`_meta.<name>`).
    _meta: ?RawValue = null,
};

// -----------------------------------------------------------------------------
// Unit Tests

test "a cancel request names the request by id" {
    const src =
        \\{"requestId":7}
    ;
    const parsed = try std.json.parseFromSlice(CancelRequestNotification, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 7), parsed.value.requestId.integer);
}
