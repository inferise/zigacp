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
    /// Allocator returned OOM.
    OutOfMemory,
    /// The agent did not advertise what was asked of it (an `_inferise/*` method, images, reopening a session).
    NotOffered,
    /// Refused while a turn runs: a setting, a second prompt.
    TurnInFlight,
    /// A prompt with nothing in it.
    EmptyPrompt,
    /// A prompt with images to an agent that takes none.
    ImagesNotTaken,
    /// Asked of a client before it has opened a session.
    NoSession,
    /// A code handed to a sign-in that is not waiting for one.
    NotWaiting,
    /// Disk or another store refused a read or a write.
    StorageFailed,
};
