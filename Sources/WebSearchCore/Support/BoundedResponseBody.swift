import Foundation

/// Thrown when a response body grows past the caller's byte cap while it is being read.
///
/// Deliberately not an `HTTPError` or a `SearchError`: the two callers keep their own error
/// taxonomies, and this states the fact they both need — the body exceeded a known limit.
struct ResponseBodyTooLarge: Error, Hashable {
    let limit: Int
}

/// Reads a response body while a hard byte cap is enforced *during* the transfer.
///
/// `URLSession.data(for:)` buffers the whole body before the caller can look at it, so a cap
/// applied afterwards bounds what the process keeps, not what it allocates. A page that streams
/// without end therefore drove peak memory past the cap and could take the server down with it —
/// one `web_open` call against a hostile URL, or one misbehaving upstream. Streaming
/// stops the transfer at the cap instead, so peak allocation is the cap plus one chunk.
///
/// The byte-at-a-time iteration is deliberate: `URLSession.AsyncBytes` has no chunked accessor,
/// and the responses this package reads are tens of kilobytes. The cost only becomes visible on
/// a body that is at the cap, which is exactly the case that used to be unbounded.
/// Records the address each request actually connected to.
///
/// `URLSession` gives no way to pin the address it connects to, so a name whose answer changes between
/// the policy's lookup and the connection — DNS rebinding — lands wherever it likes, and the SSRF
/// policy cannot see it. This is the other half of that check: read the address back off the finished
/// transaction so the caller can refuse a body that came from somewhere it never validated (ledger
/// A0017).
///
/// `@unchecked Sendable` with a lock rather than an actor: the delegate callback is synchronous and
/// arrives on a URLSession queue, and the reader asks for the result from a concurrency task.
final class PeerAddressRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var collected = false

    /// Remote addresses as `host:port`, one per transaction. Empty until the task completes.
    var addresses: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Whether the task has finished reporting, so `addresses` is final rather than merely empty.
    var hasCollected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        // Every redirect hop has its own transaction; the caller cares about all of them, because the
        // policy validates every hop.
        let found = metrics.transactionMetrics.compactMap(\.remoteAddress)
        lock.lock()
        recorded = found
        collected = true
        lock.unlock()
    }
}

extension BoundedResponseBody {
    /// The address part of a `host:port` remote address, without allocating a URL.
    ///
    /// IPv6 literals come bracketed (`[::1]:443`), so the closing bracket is the separator there and
    /// the last colon is the separator otherwise.
    static func host(ofRemoteAddress address: String) -> String {
        if address.hasPrefix("[") {
            guard let closing = address.firstIndex(of: "]") else { return address }
            return String(address[address.index(after: address.startIndex)..<closing])
        }
        // More than one colon and no brackets is a bare IPv6 literal, not `host:port`. Without this,
        // the last colon was treated as a port separator and `2606:…:1946` lost its final group, so a
        // perfectly valid peer looked like one the policy never validated and the response would have
        // been refused (ledger A0017).
        guard address.filter({ $0 == ":" }).count == 1, let colon = address.lastIndex(of: ":")
        else { return address }
        let port = address[address.index(after: colon)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return address }
        return String(address[..<colon])
    }
}

enum BoundedResponseBody {

    /// Read `request`, failing as soon as more than `limit` bytes have arrived.
    ///
    /// - Throws: `ResponseBodyTooLarge` when the cap is passed, and whatever the transport
    ///   throws otherwise (`URLError`, `CancellationError`).
    static func read(
        _ session: URLSession,
        _ request: URLRequest,
        limit: Int
    ) async throws -> (Data, URLResponse) {
        let (stream, response) = try await session.bytes(for: request)
        var body = Data()
        body.reserveCapacity(min(limit, 256 * 1024))
        for try await byte in stream {
            guard body.count < limit else {
                throw ResponseBodyTooLarge(limit: limit)
            }
            body.append(byte)
        }
        return (body, response)
    }
}
