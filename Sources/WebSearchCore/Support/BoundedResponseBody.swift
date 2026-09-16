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
