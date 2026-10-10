//! Conductor: composes proxies between a client and an agent.
//!
//! The package exposes the data structures: a chain of request,
//! notification and reply interceptors, and a `Pairing` that matches each
//! reply to the request it answers, one table per direction. Wiring them to
//! live transports at both ends is left to whoever embeds the conductor —
//! they own the transports and the lifecycle.

const std = @import("std");

pub const interceptor = @import("interceptor.zig");
pub const RequestInterceptor = interceptor.RequestInterceptor;
pub const NotificationInterceptor = interceptor.NotificationInterceptor;
pub const RequestContext = interceptor.RequestContext;
pub const NotificationContext = interceptor.NotificationContext;
pub const RequestOutcome = interceptor.RequestOutcome;
pub const NotificationOutcome = interceptor.NotificationOutcome;
pub const Direction = interceptor.Direction;
pub const ReplyInterceptor = interceptor.ReplyInterceptor;
pub const ReplyContext = interceptor.ReplyContext;
pub const ReplyOutcome = interceptor.ReplyOutcome;

pub const pairing = @import("pairing.zig");
pub const Pairing = pairing.Pairing;

pub const chain = @import("chain.zig");
pub const Chain = chain.Chain;

test {
    std.testing.refAllDecls(@This());
}
