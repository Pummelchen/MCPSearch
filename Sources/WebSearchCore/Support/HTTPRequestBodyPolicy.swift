import Foundation

/// Server-side request-body limits for the Streamable HTTP transport.
///
/// The transport's NIO handler sees a request head before any of its body, and that head is
/// written by the peer, so nothing in it may size an allocation.
public enum HTTPRequestBodyPolicy {

    /// Capacity reserved when a request head arrives, before any body byte.
    ///
    /// One page: an ordinary MCP JSON-RPC request fits without a reallocation, and the value is
    /// derived from nothing the peer sent.
    public static let initialCapacity = 4096

    /// Largest accepted request body. MCP requests are small; a search result body is produced
    /// by the server, not received.
    public static let maximumBodyBytes = 1 << 20  // 1 MiB

    /// How much to reserve when a request head arrives.
    ///
    /// The declared length is deliberately **ignored**. `ByteBuffer.reserveCapacity` reallocates
    /// immediately, so sizing the buffer from an untrusted `Content-Length` let a client send a
    /// request head and nothing else and make the process hold up to `maximumBodyBytes` per
    /// connection — a megabyte per connection up to the 64-connection bound — before a single
    /// body byte arrived. The buffer grows as body parts actually arrive and
    /// `maximumBodyBytes` rejects the request when the body exceeds it, so one page is all that
    /// has to be reserved up front.
    ///
    /// The parameter is kept so the decision is visible at the call site: a later change back to
    /// "reserve what the peer declared" has to be made here, where this comment and its test are.
    public static func reservationCapacity(declaredContentLength: Int?) -> Int {
        _ = declaredContentLength
        return initialCapacity
    }
}
