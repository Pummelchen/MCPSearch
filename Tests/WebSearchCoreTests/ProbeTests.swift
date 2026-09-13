import Foundation
import XCTest

@testable import WebSearchCore

/// `NodeProbe` — one SearXNG instance's health.
///
/// The distinction the dashboard depends on is "answered but refused/degraded" versus
/// "unreachable": reporting a JSON-disabled instance as *down* sends an operator
/// hunting for a network fault that does not exist.
final class NodeProbeTests: XCTestCase {

    private let target = NodeProbe.Target(
        name: "node1",
        baseURL: URL(string: "http://node1.example.com:8888")!,
        isLocal: false
    )

    private func probe(_ http: MockHTTPClient) async -> NodeProbe.Result {
        await NodeProbe(http: http).probe(target)
    }

    func testProbeReportsUpWithEnginesAndUnavailableEngines() async {
        let http = MockHTTPClient()
        // The key a real instance emits.
        http.respondJSON(
            """
            {"results":[{"engine":"brave","engines":["duckduckgo"]},{"engine":"brave"}],
             "unresponsive_engines":[["google","timeout"],["only-one-element"]]}
            """
        )

        let result = await probe(http)

        XCTAssertEqual(result.state, .up)
        XCTAssertEqual(result.resultCount, 2)
        XCTAssertEqual(result.engines, ["brave", "duckduckgo"])
        // A malformed pair is dropped rather than crashing or rendering "nil".
        XCTAssertEqual(result.unavailableEngines, ["google: timeout"])
        XCTAssertNil(result.error)

        let url = http.requests.first?.url.absoluteString ?? ""
        XCTAssertTrue(url.contains("/search"), url)
        XCTAssertTrue(url.contains("format=json"), url)
    }

    /// The documented SearXNG deployment mistake: JSON not added to `search.formats`.
    /// The instance is up, so this must be `degraded`, with the fix in the message.
    func testJsonDisabledIsDegradedNotDown() async {
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(
                statusCode: 403,
                headers: ["content-type": "text/html"],
                body: Data("<html>403</html>".utf8),
                url: request.url
            )
        }

        let result = await probe(http)

        XCTAssertEqual(result.state, .degraded)
        XCTAssertNotNil(result.latencyMilliseconds)
        let error = result.error ?? ""
        XCTAssertTrue(error.contains("JSON disabled"), error)
        XCTAssertTrue(error.contains("search.formats"), error)
    }

    func testEmptyResultsAreDegraded() async {
        let http = MockHTTPClient()
        http.respondJSON(#"{"results":[],"unresponsive_engines":[]}"#)

        let result = await probe(http)

        XCTAssertEqual(result.state, .degraded)
        XCTAssertEqual(result.resultCount, 0)
        XCTAssertEqual(result.error, "no results returned")
    }

    func testServerErrorIsDegraded() async {
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(statusCode: 500, headers: [:], body: Data(), url: request.url)
        }

        let result = await probe(http)

        XCTAssertEqual(result.state, .degraded)
        XCTAssertEqual(result.error, "HTTP 500")
    }

    func testTransportFailureIsDown() async {
        let http = MockHTTPClient()
        http.onAny { _ in
            throw HTTPError.connectionFailed(label: "node.probe", reason: "connection refused")
        }

        let result = await probe(http)

        XCTAssertEqual(result.state, .down)
        XCTAssertNil(result.latencyMilliseconds)
        XCTAssertNotNil(result.error)
    }

    func testMalformedBodyIsDown() async {
        let http = MockHTTPClient()
        http.respondJSON("this is not json")

        let result = await probe(http)

        XCTAssertEqual(result.state, .down)
        XCTAssertNotNil(result.error)
    }
}

/// `ProviderProbe` — per-provider health through the same code path a search uses.
final class ProviderProbeTests: XCTestCase {

    private func makeProbe(
        _ providers: [any SearchProvider],
        order: [ProviderID]? = nil
    ) -> ProviderProbe {
        let configuration = Fixtures.configuration(
            providerOrder: order ?? AppConfiguration.defaultProviderOrder
        )
        return ProviderProbe(
            registry: ProviderRegistry(providers: providers, configuration: configuration),
            configuration: configuration
        )
    }

    func testProbeReturnsSuccessAndResultCount() async {
        let provider = MockSearchProvider.returning(
            .tavily,
            results: [
                ("A", "https://example.com/a", nil),
                ("B", "https://example.com/b", nil),
            ])
        let probe = makeProbe([provider])

        let outcome = await probe.probe(.tavily, query: "swift concurrency")

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.resultCount, 2)
        XCTAssertNil(outcome.error)
        XCTAssertNil(outcome.category)
        XCTAssertEqual(provider.callCount, 1)
    }

    func testProbeClassifiesAProviderFailure() async {
        let error = SearchError.rateLimited(.brave, retryAfter: .seconds(3))
        let provider = MockSearchProvider.failing(.brave, with: error)
        let probe = makeProbe([provider])

        let outcome = await probe.probe(.brave, query: "swift")

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.category, .rateLimited)
        XCTAssertEqual(outcome.error, error.safeDescription)
    }

    /// An unconfigured provider must be reported with the exact variable to set, and
    /// must never be called (which would spend a request or fail confusingly).
    func testUnconfiguredProviderIsReportedWithItsSetupHint() async {
        let provider = MockSearchProvider(id: .brave, configured: false) { _ in
            ProviderSearchResponse(provider: .brave, results: [])
        }
        let probe = makeProbe([provider])

        let outcome = await probe.probe(.brave, query: "swift")

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.category, .notConfigured)
        XCTAssertTrue(outcome.error?.contains("BRAVE_SEARCH_API_KEY") ?? false, outcome.error ?? "")
        XCTAssertEqual(provider.callCount, 0)
    }

    func testMissingAdapterIsReportedRatherThanCrashing() async {
        let probe = makeProbe([
            MockSearchProvider.returning(.tavily, results: [("A", "https://example.com/a", nil)])
        ])

        let outcome = await probe.probe(.brave, query: "swift")

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.category, .notConfigured)
        XCTAssertEqual(outcome.error, "no adapter registered")
    }

    func testCancellationIsClassifiedAsCancelled() async {
        let provider = MockSearchProvider(id: .tavily) { _ in throw CancellationError() }
        let probe = makeProbe([provider])

        let outcome = await probe.probe(.tavily, query: "swift")

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.category, .cancelled)
        XCTAssertEqual(outcome.error, "cancelled")
    }

    func testProbeTargetsFollowTheConfiguredOrder() {
        let probe = makeProbe([], order: [.exa, .tavily])
        XCTAssertEqual(probe.probeTargets(), [.exa, .tavily])
    }

    func testSetupHintNamesTheRightVariableForEveryProvider() {
        let probe = makeProbe([])
        XCTAssertEqual(probe.setupHint(for: .tavily), "TAVILY_API_KEY")
        XCTAssertEqual(probe.setupHint(for: .brave), "BRAVE_SEARCH_API_KEY")
        XCTAssertEqual(probe.setupHint(for: .mojeek), "MOJEEK_API_KEY")
        XCTAssertEqual(probe.setupHint(for: .exa), "EXA_API_KEY")
        XCTAssertEqual(probe.setupHint(for: .searxng), "SEARXNG_BASE_URL")
        XCTAssertEqual(probe.setupHint(for: .openWebSearch), "OPEN_WEB_SEARCH_URL")
        XCTAssertEqual(probe.setupHint(for: .duckDuckGo), "SEARCH_ENABLE_SCRAPERS=true")
        XCTAssertEqual(probe.setupHint(for: .startpage), "SEARCH_ENABLE_SCRAPERS=true")
        XCTAssertEqual(probe.setupHint(for: .parallel), "SEARCH_ENABLE_PARALLEL=true")
    }

    func testIsConfiguredReflectsTheRegistry() {
        let configured = MockSearchProvider.returning(.tavily, results: [])
        let unconfigured = MockSearchProvider(id: .brave, configured: false) { _ in
            ProviderSearchResponse(provider: .brave, results: [])
        }
        let probe = makeProbe([configured, unconfigured], order: [.tavily, .brave])

        XCTAssertTrue(probe.isConfigured(.tavily))
        XCTAssertFalse(probe.isConfigured(.brave))
        XCTAssertFalse(probe.isConfigured(.exa), "an unregistered adapter is not configured")
    }

    /// The monitor's composition root must read the same environment and wire the same
    /// real adapters as the server, or the dashboard would disagree with the tool.
    func testBuildConfigurationAndRegistryUseTheGivenEnvironment() {
        let configuration = ProviderProbe.buildConfiguration(environment: [
            "TAVILY_API_KEY": "tvly-test-key-000000000000"
        ])
        XCTAssertEqual(configuration.tavilyAPIKey, "tvly-test-key-000000000000")

        let registry = ProviderProbe.buildRegistry(
            configuration: configuration,
            http: MockHTTPClient(),
            log: .disabled
        )
        XCTAssertNotNil(registry.provider(.tavily))
        XCTAssertTrue(registry.isConfigured(.tavily))
        XCTAssertFalse(registry.isConfigured(.brave))
    }
}
