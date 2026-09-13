import Foundation
import XCTest

@testable import WebSearchCore

/// The byte cap must be enforced **while** a body arrives, not after it has all been buffered.
///
/// `URLSession.data(for:)` accumulates the complete body first, so the old post-hoc check bounded
/// what the process kept, not what it allocated: a page that streams without end — one
/// `web_open` call against a hostile URL, or one misbehaving upstream — drove peak memory past
/// the cap and could take the server down (ledger B07).
///
/// The discriminating tests declare a `Content-Length` far larger than the bytes the server ever
/// sends, then hold the connection open. A reader that waits for the declared length ends in a
/// transport error (`networkConnectionLost` or similar); a reader that stops at its cap reports
/// the cap instead — so the assertion is on the *error*, with no timing assertion anywhere.
final class BoundedBodyTests: XCTestCase {

    private static let cap = 8 * 1024
    /// Declared body size and drip size are both far past the cap, so the reader must stop early.
    private static let endless = LoopbackServer.Response(
        status: 200,
        headers: ["Content-Type": "text/html"],
        // 512 KB of body, but 50 MB declared and never sent, then the connection is held open and
        // finally dropped. The first 64 KB chunk already carries more than the cap.
        body: String(repeating: "A", count: 512 * 1024),
        delayMilliseconds: 0,
        drip: .init(
            chunkBytes: 64 * 1024,
            pauseMilliseconds: 0,
            holdOpenSeconds: 3,
            declaredBytes: 50 * 1024 * 1024
        )
    )

    private func makeClient() -> URLSessionHTTPClient {
        var configured = Fixtures.configuration()
        configured.maxRetryAttempts = 1
        configured.requestTimeout = .seconds(30)
        return URLSessionHTTPClient(configuration: configured, log: .disabled)
    }

    func testHTTPClientStopsAtTheCapWhileTheBodyIsStillArriving() async throws {
        let server = try LoopbackServer(responses: [Self.endless])

        do {
            let response = try await makeClient().send(
                .get(server.baseURL, label: "bounded"),
                maxBytes: Self.cap
            )
            XCTFail("an endless body must not be returned: \(response.body.count) bytes")
        } catch let error as HTTPError {
            guard case .responseTooLarge(_, let limit) = error else {
                return XCTFail(
                    "expected responseTooLarge from the cap, got \(error) — a reader that waits "
                        + "for the declared Content-Length fails in the transport instead"
                )
            }
            XCTAssertEqual(limit, Self.cap)
        }
    }

    func testDirectFetcherStopsAtTheCapWhileTheBodyIsStillArriving() async throws {
        let server = try LoopbackServer(responses: [Self.endless])
        // The fetcher's cap comes from configuration (10 MiB by default), so it is lowered to the
        // same 8 KiB here. Its own 10 s timeout would otherwise be the thing that fires, which is
        // exactly the difference under test.
        var configured = Fixtures.configuration()
        configured.maxFetchedPageBytes = Self.cap
        let fetcher = DirectHTTPFetcher(
            configuration: configured,
            policy: URLPolicy(allowPrivateNetwork: true),
            log: .disabled
        )

        do {
            let result = try await fetcher.fetch(
                FetchRequest(url: server.baseURL),
                maxRedirects: 2,
                allowedContentTypePrefixes: ["text/"],
                maxCharacters: 12_000
            )
            XCTFail("an endless body must not be returned: \(result.text.count) characters")
        } catch let error as SearchError {
            guard case .extractionFailed = error else {
                return XCTFail(
                    "expected extractionFailed from the cap, got \(error) — a reader that waits "
                        + "for the declared Content-Length fails in the transport instead"
                )
            }
        }
    }

    /// The ordinary case still works, and a body at the cap is still accepted.
    func testABodyAtTheCapIsAcceptedAndOneByteMoreIsNot() async throws {
        let atCap = try LoopbackServer(responses: [
            LoopbackServer.Response(status: 200, body: String(repeating: "x", count: 1024))
        ])
        let response = try await makeClient().send(
            .get(atCap.baseURL, label: "at-cap"),
            maxBytes: 1024
        )
        XCTAssertEqual(response.body.count, 1024)

        let overCap = try LoopbackServer(responses: [
            LoopbackServer.Response(status: 200, body: String(repeating: "x", count: 1025))
        ])
        do {
            _ = try await makeClient().send(.get(overCap.baseURL, label: "over-cap"), maxBytes: 1024)
            XCTFail("a body one byte over the cap must be rejected")
        } catch let error as HTTPError {
            guard case .responseTooLarge(_, let limit) = error else {
                return XCTFail("expected responseTooLarge, got \(error)")
            }
            XCTAssertEqual(limit, 1024)
        }
    }
}
