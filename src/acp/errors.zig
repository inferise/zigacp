//! The single error set used at every package boundary.

pub const AcpError = error{
    /// Wire-level parse failure: malformed JSON or unexpected shape.
    InvalidMessage,
    /// JSON-RPC method not recognised by the routing aggregate.
    MethodNotFound,
    /// Params didn't match the expected schema for the named method.
    InvalidParams,
    /// The peer returned an error response for a request we sent.
    PeerError,
    /// Transport read returned EOF mid-frame or while waiting for a response.
    TransportClosed,
    /// Transport write or read failed for a non-EOF reason.
    TransportFailed,
    /// Session id didn't correspond to an open session.
    SessionNotFound,
    /// The agent behind the session has exited, so nothing can be asked of it until it is started again.
    AgentGone,
    /// The agent will not open a session until it is signed in to; the host answers with `authenticate`.
    AuthRequired,
    /// Allocator returned OOM.
    OutOfMemory,
};
