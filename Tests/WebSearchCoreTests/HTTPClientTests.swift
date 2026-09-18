import Foundation
import XCTest

@testable import WebSearchCore

final class HTTPClientTests: XCTestCase {

    /// The peer address is available by the time the body has been read.
    ///
    /// This is the timing the mitigation rests on. `didFinishCollecting` is delivered when the task
    /// completes, and a check that reads `addresses` too early sees an empty list — which would either
    /// refuse a good response or, worse, pass a bad one as unverifiable. Measured rather than assumed
    /// .
    func testThePeerAddressIsAvailableWhenTheBodyHasBeenRead() async throws {
        let server = try LoopbackServer(responses: [.init(status: 200, body: "hello")])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let recorder = PeerAddressRecorder()

        let (stream, _) = try await session.bytes(
            for: URLRequest(url: server.baseURL),
            delegate: recorder
        )
        var received: [UInt8] = []
        for try await byte in stream { received.append(byte) }

        print(
            "      A0017: collected=\(recorder.hasCollected) addresses=\(recorder.addresses)"
        )
        // Compared as bytes: `String(decoding:as:)` is what `optional_data_string_conversion` flags,
        // and the assertion is about the body having arrived rather than about a conversion.
        XCTAssertEqual(received, Array("hello".utf8))
        XCTAssertTrue(
            recorder.hasCollected,
            "the metrics callback had not fired by the time the body was fully read"
        )
        XCTAssertEqual(
            recorder.addresses.compactMap(BoundedResponseBody.host(ofRemoteAddress:)),
            ["127.0.0.1"]
        )
    }

    /// The comparison that stands in for address pinning.
    ///
    /// The fetcher refuses a body whose peer was not one the policy validated. This is the decision
    /// itself: a peer the policy did not validate must be reported, and a peer that merely *looks*
    /// different — another port, another presentation form of the same IPv6 address — must not be.
    func testUnvalidatedPeers() throws {
        let validated = [
            try XCTUnwrap(IPAddress("93.184.216.34")),
            try XCTUnwrap(IPAddress("2606:2800:220:1:248:1893:25c8:1946")),
        ]

        // Validated peers pass, with a port, without one, and bracketed.
        XCTAssertEqual(BoundedResponseBody.unvalidatedPeers(["93.184.216.34:443"], validated: validated), [])
        XCTAssertEqual(BoundedResponseBody.unvalidatedPeers(["93.184.216.34"], validated: validated), [])
        XCTAssertEqual(
            BoundedResponseBody.unvalidatedPeers(
                ["[2606:2800:220:1:248:1893:25c8:1946]:443"],
                validated: validated
            ),
            []
        )
        // The same address in another presentation form is the same peer, not a stranger.
        XCTAssertEqual(
            BoundedResponseBody.unvalidatedPeers(
                ["[0:0:0:0:0:0:0:1]:80"],
                validated: [try XCTUnwrap(IPAddress("::1"))]
            ),
            []
        )
        // A peer the policy never validated is reported, whole, so the error can name it.
        XCTAssertEqual(
            BoundedResponseBody.unvalidatedPeers(["10.0.0.1:80"], validated: validated),
            ["10.0.0.1:80"]
        )
        // Anything that will not parse counts as unvalidated rather than as a match.
        XCTAssertEqual(
            BoundedResponseBody.unvalidatedPeers(["not-an-address"], validated: validated),
            ["not-an-address"]
        )
        // One bad peer among good ones is still reported.
        XCTAssertEqual(
            BoundedResponseBody.unvalidatedPeers(
                ["93.184.216.34:443", "192.168.1.1:80"],
                validated: validated
            ),
            ["192.168.1.1:80"]
        )
    }

    /// The address is split from its port for both literal forms.
    func testRemoteAddressParsing() {
        XCTAssertEqual(BoundedResponseBody.host(ofRemoteAddress: "93.184.216.34:443"), "93.184.216.34")
        XCTAssertEqual(BoundedResponseBody.host(ofRemoteAddress: "127.0.0.1:8765"), "127.0.0.1")
        XCTAssertEqual(
            BoundedResponseBody.host(ofRemoteAddress: "[2606:2800:220:1:248:1893:25c8:1946]:443"),
            "2606:2800:220:1:248:1893:25c8:1946")
        XCTAssertEqual(BoundedResponseBody.host(ofRemoteAddress: "[::1]:8080"), "::1")
        XCTAssertEqual(BoundedResponseBody.host(ofRemoteAddress: "unexpected"), "unexpected")
        // A bare IPv6 literal ending in digits must not lose its last group to a port split.
        XCTAssertEqual(
            BoundedResponseBody.host(ofRemoteAddress: "2606:2800:220:1:248:1893:25c8:1946"),
            "2606:2800:220:1:248:1893:25c8:1946"
        )
        // A port that is not a number is not a port.
        XCTAssertEqual(BoundedResponseBody.host(ofRemoteAddress: "host:https"), "host:https")
    }

    /// Does a capped transfer also stop the server sending?
    ///
    /// `BoundedResponseBody.read` throws at the cap, which abandons the byte sequence. Whether that
    /// also closes the connection is what the finding recorded as UNSURE: if it does, the server's next
    /// `send` fails and the drip loop stops; if it does not, the server streams the rest of the body
    /// into a socket nobody is reading.
    func testAnOverCapTransferStopsTheServerSending() async throws {
        let chunk = 4 * 1024
        let chunks = 64
        let server = try LoopbackServer(responses: [
            .init(
                status: 200,
                body: String(repeating: "x", count: chunk * chunks),
                drip: .init(chunkBytes: chunk, pauseMilliseconds: 30, holdOpenSeconds: 2)
            )
        ])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let limit = 8 * 1024
        do {
            _ = try await BoundedResponseBody.read(
                session,
                URLRequest(url: server.baseURL),
                limit: limit
            )
            XCTFail("the cap must be enforced")
        } catch is ResponseBodyTooLarge {
            // Expected.
        }

        // Let a server that is still sending have every chance to prove it.
        try await Task.sleep(for: .milliseconds(900))
        let sent = server.bytesSent
        let whole = chunk * chunks
        XCTAssertLessThan(
            sent,
            whole / 4,
            "the server sent \(sent) of \(whole) bytes after the cap was hit at \(limit)"
        )
        print("      A0016: read capped at \(limit); server sent \(sent) of \(whole) bytes")
    }

    private func makeClient(
        configuration: AppConfiguration,
        maxRetries: Int
    ) -> URLSessionHTTPClient {
        var configured = configuration
        configured.maxRetryAttempts = maxRetries
        configured.requestTimeout = .seconds(5)
        return URLSessionHTTPClient(configuration: configured, log: .disabled)
    }

    /// The session's resource timeout is a *total* cap, so it has to clear the largest
    /// per-request budget the client can be asked to honour. It used to be
    /// `max(2 × requestTimeout, 30)`, which silently cut the 45 s synthesis budget off at 30 s
    /// and made `SEARCH_SYNTHESIS_TIMEOUT_MS` above 30 000 inert.
    func testTheResourceTimeoutClearsEveryPerRequestBudget() {
        let shipped = AppConfiguration()
        XCTAssertGreaterThan(
            URLSessionHTTPClient.resourceTimeout(for: shipped),
            shipped.synthesisTimeout.seconds,
            "the default resource timeout must not cap the synthesis budget"
        )

        // A deployment that raises either budget gets a resource timeout that clears it.
        var raised = AppConfiguration()
        raised.synthesisTimeout = .seconds(120)
        XCTAssertGreaterThan(URLSessionHTTPClient.resourceTimeout(for: raised), 120)

        var slowRequests = AppConfiguration()
        slowRequests.requestTimeout = .seconds(300)
        XCTAssertGreaterThan(URLSessionHTTPClient.resourceTimeout(for: slowRequests), 300)

        // And the ordinary case stays bounded rather than becoming unbounded.
        XCTAssertLessThan(URLSessionHTTPClient.resourceTimeout(for: shipped), 600)
    }

    func testSucceedsOnFirstAttemptWithoutRetrying() async throws {
        let server = try LoopbackServer(responses: [.init(status: 200, body: #"{"ok":true}"#)])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 2)

        let response = try await client.send(.get(server.baseURL, label: "test"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testRetriesTransientServerErrorForIdempotentRequest() async throws {
        let server = try LoopbackServer(responses: [
            .init(status: 503, body: "unavailable"),
            .init(status: 503, body: "unavailable"),
            .init(status: 200, body: #"{"ok":true}"#),
        ])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 2)

        let response = try await client.send(.get(server.baseURL, label: "test"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(server.requestCount, 3, "expected two retries then success")
    }

    func testGivesUpAfterMaxAttempts() async throws {
        let server = try LoopbackServer(responses: [.init(status: 503, body: "down")])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 1)

        let response = try await client.send(.get(server.baseURL, label: "test"))
        // The client returns the last response rather than throwing, so the provider
        // layer classifies it.
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(server.requestCount, 2, "one initial attempt plus one retry")
    }

    func testDoesNotRetryNonTransientClientError() async throws {
        let server = try LoopbackServer(responses: [.init(status: 400, body: "bad request")])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 3)

        let response = try await client.send(.get(server.baseURL, label: "test"))
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(server.requestCount, 1, "4xx other than 408/425/429 must not be retried")
    }

    func testDoesNotRetryNonIdempotentRequest() async throws {
        // POST may have already had an effect, so a transient failure must not be
        // replayed. This matters because Tavily and Exa search via POST and each
        // retry costs credits.
        let server = try LoopbackServer(responses: [.init(status: 503, body: "down")])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 3)

        let response = try await client.send(
            .post(server.baseURL, headers: [:], body: Data("{}".utf8), label: "test")
        )
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testHonorsRetryAfterHeader() async throws {
        let server = try LoopbackServer(responses: [
            .init(status: 429, headers: ["Content-Type": "application/json", "Retry-After": "1"], body: "slow down"),
            .init(status: 200, body: #"{"ok":true}"#),
        ])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 2)

        let started = DispatchTime.now().uptimeNanoseconds
        let response = try await client.send(.get(server.baseURL, label: "test"))
        let elapsedMilliseconds = Int(
            (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertGreaterThanOrEqual(
            elapsedMilliseconds,
            900,
            "the client must wait for the indicated Retry-After"
        )
    }

    /// A hostile `Retry-After` must not stall a search.
    ///
    /// `HTTPPolicy.maxRetryAfter` (5 s as shipped) is the cap on the delay the client is willing
    /// to honour, so a 429 carrying `Retry-After: 3600` cannot park a tool call for an hour. No
    /// test covered it: the only header test sends "1", where `min(1 s, 5 s) == 1 s` and the cap
    /// never applies. The send is raced against a bound just above the cap because
    /// an unclamped delay would otherwise hold this test — and CI — for the hour the header asks
    /// for.
    func testAHostileRetryAfterIsClampedToThePolicyMaximum() async throws {
        let server = try LoopbackServer(responses: [
            .init(
                status: 429,
                headers: ["Content-Type": "application/json", "Retry-After": "3600"],
                body: "slow down"
            ),
            .init(status: 200, body: #"{"ok":true}"#),
        ])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 1)
        let cap = HTTPPolicy.standard(Fixtures.configuration()).maxRetryAfter.seconds

        let started = DispatchTime.now().uptimeNanoseconds
        var answered: HTTPResponse?
        try await withThrowingTaskGroup(of: HTTPResponse?.self) { group in
            group.addTask { try await client.send(.get(server.baseURL, label: "test")) }
            group.addTask {
                try await Task.sleep(for: .seconds(cap + 3))
                return nil
            }
            defer { group.cancelAll() }
            for try await first in group {
                answered = first
                break
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        XCTAssertNotNil(
            answered,
            "the 3600 s Retry-After was not clamped: the send outlived the cap by more than 3 s"
        )
        XCTAssertEqual(answered?.statusCode, 200)
        XCTAssertEqual(server.requestCount, 2, "one retry, then the answer")
        XCTAssertGreaterThanOrEqual(
            elapsed,
            cap * 0.9,
            "ignoring Retry-After entirely is not a clamp: the cap itself must still be waited out"
        )
        XCTAssertLessThan(elapsed, cap + 3)
    }

    func testEnforcesResponseSizeLimit() async throws {
        let bigBody = String(repeating: "x", count: 10_000)
        let server = try LoopbackServer(responses: [.init(status: 200, body: bigBody)])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 0)

        do {
            _ = try await client.send(.get(server.baseURL, label: "test"), maxBytes: 1_000)
            XCTFail("expected the size limit to be enforced")
        } catch let error as HTTPError {
            guard case .responseTooLarge = error else {
                return XCTFail("expected responseTooLarge, got \(error)")
            }
            XCTAssertFalse(error.isTransient, "an oversized body is not retryable")
        }
    }

    func testTransportFailureIsTransient() async throws {
        // Port 1 on loopback is not listening, so the connection is refused.
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 0)
        let unreachable = URL(string: "http://127.0.0.1:1/")!

        do {
            _ = try await client.send(.get(unreachable, label: "test"))
            XCTFail("expected a connection failure")
        } catch let error as HTTPError {
            XCTAssertTrue(error.isTransient)
        }
    }

    func testCancellationPropagatesAsCancelled() async throws {
        let server = try LoopbackServer(responses: [.init(status: 200, body: "{}", delayMilliseconds: 3_000)])
        var configuration = Fixtures.configuration()
        configuration.requestTimeout = .seconds(10)
        let client = URLSessionHTTPClient(configuration: configuration, log: .disabled)

        let task = Task {
            try await client.send(.get(server.baseURL, label: "test"))
        }
        // Give the request time to reach the server, then cancel.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            XCTFail("expected cancellation")
        case .failure(let error):
            // Pinning the category, not the existence of an error: `(error as? HTTPError) != nil`
            // is true for every failure this client can produce, so the old assertion could not
            // fail and said nothing about cancellation.
            //
            // Two shapes are legitimate. The transport maps a cancelled URLSession task to
            // `.cancelled`, and the retry loop's own `Task.checkCancellation()` throws a raw
            // `CancellationError`. Everything else — a timeout, a connection failure, a
            // response-too-large — is a misclassification that changes what the operator sees.
            if !(error is CancellationError) {
                XCTAssertEqual(
                    error as? HTTPError,
                    .cancelled(label: "test"),
                    "cancellation must surface as .cancelled for its own request label, got \(error)"
                )
            }
        }
        XCTAssertEqual(
            server.requestCount,
            1,
            "a cancelled request must not be retried: the retry would ignore the caller entirely"
        )
    }

    func testHeaderLookupIsCaseInsensitive() {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["retry-after": "5"],
            body: Data(),
            url: URL(string: "https://example.com")!
        )
        XCTAssertEqual(response.header("Retry-After"), "5")
        XCTAssertEqual(response.header("RETRY-AFTER"), "5")
        XCTAssertNil(response.header("absent"))
    }

    func testTextDecodingFallsBackToLatin1() {
        // 0xE9 is `é` in Latin-1 but invalid UTF-8, so a UTF-8-only decode would
        // wrongly produce an empty string.
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data([0x63, 0x61, 0x66, 0xE9]),
            url: URL(string: "https://example.com")!
        )
        XCTAssertEqual(response.text(), "café")
    }
}
