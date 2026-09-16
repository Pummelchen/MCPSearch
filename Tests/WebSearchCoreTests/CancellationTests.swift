import Foundation
import XCTest

@testable import WebSearchCore

/// Cancellation is a caller decision and must reach the caller unchanged.
///
/// Two behaviours were wrong before these tests existed:
///
/// * the orchestrator propagated a cancellation only when the task was *already* cancelled on
///   entry, so a client that cancelled mid-flight got partial results it would never read;
/// * `DirectHTTPFetcher` turned a cancellation into a `fetchFailed`, which the layer above read
///   as "the direct fetch did not work" and answered by starting a *second* outbound request
///   through Jina Reader — for a caller that had already gone away.
///
/// Budget expiry is deliberately *not* cancellation, and the existing timeout tests cover that it
/// still degrades to partial results.
final class CancellationTests: XCTestCase {

    // MARK: - Orchestrator

    /// A provider that has started but not finished when the cancellation arrives.
    private static func slowProvider(_ id: ProviderID) -> MockSearchProvider {
        let inner = MockSearchProvider.returning(
            id,
            results: [("Slow", "https://slow.example.com/1", "s")]
        )
        return MockSearchProvider(id: id) { request in
            try await Task.sleep(for: .milliseconds(400))
            return try await inner.search(request)
        }
    }

    func testAMidFlightCancellationReachesTheCallerInsteadOfPartialResults() async throws {
        let provider = Self.slowProvider(.tavily)
        let registry = ProviderRegistry(
            providers: [provider],
            configuration: Fixtures.configuration()
        )
        let orchestrator = SearchOrchestrator(
            registry: registry,
            health: ProviderHealth(),
            cache: SearchCache(),
            configuration: Fixtures.configuration(),
            clock: SystemClock()
        )

        let search = Task {
            try await orchestrator.search(Fixtures.request(mode: .fast))
        }
        // Wait until the provider is actually running, so this is a *mid-flight* cancellation
        // rather than one that lands before the call starts.
        while provider.callCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        search.cancel()

        do {
            let response = try await search.value
            XCTFail(
                "a cancelled search must not return results, got \(response.results.count) "
                    + "result(s) from \(response.providersUsed.map(\.rawValue))"
            )
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testACancellationBeforeTheCallStillPropagates() async throws {
        let provider = MockSearchProvider.returning(.tavily, results: [("T", "https://t.example.com/1", nil)])
        let registry = ProviderRegistry(
            providers: [provider],
            configuration: Fixtures.configuration()
        )
        let orchestrator = SearchOrchestrator(
            registry: registry,
            health: ProviderHealth(),
            cache: SearchCache(),
            configuration: Fixtures.configuration(),
            clock: SystemClock()
        )

        let search = Task {
            try await orchestrator.search(Fixtures.request(mode: .fast))
        }
        search.cancel()

        do {
            _ = try await search.value
            XCTFail("a cancelled search must not return results")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    // MARK: - web_open

    /// A server that never finishes the body it declared, so the fetch is still in flight when
    /// the cancellation lands.
    private static let stalled = LoopbackServer.Response(
        status: 200,
        headers: ["Content-Type": "text/html"],
        body: "<html><body><p>never delivered</p></body></html>",
        delayMilliseconds: 0,
        drip: .init(
            chunkBytes: 1,
            pauseMilliseconds: 0,
            holdOpenSeconds: 5,
            declaredBytes: 8 * 1024 * 1024
        )
    )

    func testCancellingADirectFetchPropagatesCancellationRatherThanAFetchFailure() async throws {
        let server = try LoopbackServer(responses: [Self.stalled])
        var configured = Fixtures.configuration()
        configured.maxFetchedPageBytes = 1024
        let fetcher = DirectHTTPFetcher(
            configuration: configured,
            policy: URLPolicy(allowPrivateNetwork: true),
            log: .disabled
        )

        let fetch = Task {
            try await fetcher.fetch(
                FetchRequest(url: server.baseURL),
                maxRedirects: 2,
                allowedContentTypePrefixes: ["text/"],
                maxCharacters: 12_000
            )
        }
        // Give the request time to reach the server, then cancel mid-transfer.
        try await Task.sleep(for: .milliseconds(150))
        fetch.cancel()

        do {
            let result = try await fetch.value
            XCTFail("a cancelled fetch must not return content: \(result.text.prefix(40))")
        } catch is CancellationError {
            // Expected: not a fetchFailed wearing a cancellation message.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    /// The whole point of the fix: a cancelled `web_open` must not start the Jina fallback.
    func testACancelledWebOpenNeverReachesTheJinaFallback() async throws {
        let server = try LoopbackServer(responses: [Self.stalled])
        var configured = Fixtures.configuration()
        configured.maxFetchedPageBytes = 1024
        let jinaHTTP = MockHTTPClient()
        jinaHTTP.onAny { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/markdown"],
                body: Data("# should never be requested".utf8),
                url: request.url
            )
        }
        let fetcher = WebFetcher(
            direct: DirectHTTPFetcher(
                configuration: configured,
                policy: URLPolicy(allowPrivateNetwork: true),
                log: .disabled
            ),
            jina: JinaReaderFetcher(
                baseURL: URL(string: "https://reader.invalid/")!,
                apiKey: "jina-test-key",
                http: jinaHTTP,
                configuration: configured,
                log: .disabled
            ),
            log: .disabled
        )

        let fetch = Task {
            try await fetcher.open(FetchRequest(url: server.baseURL))
        }
        try await Task.sleep(for: .milliseconds(150))
        fetch.cancel()

        do {
            _ = try await fetch.value
            XCTFail("a cancelled fetch must not return content")
        } catch is CancellationError {
            XCTAssertTrue(
                jinaHTTP.requests.isEmpty,
                "a cancelled caller must not cause a second outbound request: \(jinaHTTP.requests)"
            )
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}
