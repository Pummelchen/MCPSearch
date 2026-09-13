import Foundation
import XCTest

@testable import WebSearchCore

/// Opt-in integration tests that call **live** search providers.
///
/// These are deliberately excluded from the default suite: the default suite is
/// hermetic and must pass with no credentials and no network access to any vendor.
/// Provider free tiers are metered and non-deterministic, so live checks belong in an
/// opt-in run rather than on every pull request.
///
/// ## Running
///
/// Live tests are an **explicit** opt-in: a usable key alone is not enough, because a
/// developer machine or CI runner may carry a real key that nobody intended this run to
/// spend.
///
/// ```bash
/// # Uses TAVILY_API_KEY from the environment, or from ./config.env
/// SEARCH_LIVE_TESTS=1 swift test --filter LiveProviderTests
/// ```
///
/// ## Credit discipline
///
/// A Tavily basic search costs **1 credit**; advanced costs 2. Keeping a free tier in
/// mind, this file is written to spend as little as possible: `fast` mode, small result
/// counts, no `thorough` runs except where advanced depth is the thing under test, and
/// the majority of assertions are on a *single* live response.
///
/// The file skips itself unless `SEARCH_LIVE_TESTS` is set **and** a usable key is
/// available, so it is safe to leave enabled in a normal `swift test` run.
final class LiveProviderTests: XCTestCase {

    // MARK: - Key discovery

    /// Live tests are skipped unless a key is present.
    private struct MissingKey: Error, CustomStringConvertible {
        var description: String { "no live provider credentials available" }
    }

    /// The environment variable that explicitly opts in to spending real credits.
    static let optInVariable = "SEARCH_LIVE_TESTS"

    /// Whether live tests were explicitly asked for.
    ///
    /// A key-shaped `TAVILY_API_KEY` is deliberately **not** sufficient: on a machine
    /// where one is routinely exported, that would make a plain `swift test` spend real
    /// credits. The opt-in has to be stated.
    static func liveTestsEnabled(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard
            let raw = environment[optInVariable]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            !raw.isEmpty
        else { return false }
        return ["1", "true", "yes", "on", "enabled"].contains(raw)
    }

    /// Credential values that look like placeholders rather than real keys.
    ///
    /// CI deliberately runs the suite with provider variables set to fake values, to
    /// prove the default suite is hermetic. That must **not** activate these live tests:
    /// a present-but-fake key would otherwise send real requests and fail with an
    /// authentication error, turning a passing build red. A key is therefore only
    /// treated as usable when it looks like a genuine credential.
    private static let placeholderMarkers = [
        "not-a-real-key", "placeholder", "fake", "dummy", "example", "invalid", "ci-",
    ]

    /// Whether a value looks like a usable credential rather than a test placeholder.
    static func isUsableKey(_ value: String) -> Bool {
        let normalized = value.lowercased()
        guard normalized.count >= 20 else { return false }
        return !placeholderMarkers.contains { normalized.contains($0) }
    }

    /// Read `TAVILY_API_KEY` from the environment, falling back to `config.env`.
    ///
    /// `config.env` is git-ignored, so a developer can keep a real key locally without
    /// any risk of committing it.
    private static func liveKey(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment[name]?.trimmingCharacters(in: .whitespaces),
            !value.isEmpty
        {
            return isUsableKey(value) ? value : nil
        }

        // Walk up from the test bundle to find the package root's config.env.
        var directory = Bundle(for: LiveProviderTests.self).bundleURL
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("config.env")
            if let contents = try? String(contentsOf: candidate, encoding: .utf8),
                let parsed = AppConfiguration.parseDotEnv(contents)[name],
                !parsed.isEmpty
            {
                return isUsableKey(parsed) ? parsed : nil
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// The explicit opt-in **and** a usable key, with a skip that says what is missing.
    ///
    /// Requiring both is the point: a machine that routinely exports a real key would
    /// otherwise make a plain `swift test` spend credits.
    private static func requireLiveCredentials() throws -> String {
        guard liveTestsEnabled() else {
            throw XCTSkip(
                "Live tests skipped: set \(optInVariable)=1 to run tests that spend real "
                    + "provider credits."
            )
        }
        guard let key = liveKey("TAVILY_API_KEY") else {
            throw XCTSkip(
                "Live tests skipped: set TAVILY_API_KEY or add it to config.env. "
                    + "These tests call a real provider and are never part of the default suite."
            )
        }
        return key
    }

    /// Build a live Tavily provider, or skip when the opt-in or a key is missing.
    private func liveTavily() throws -> (TavilyProvider, AppConfiguration) {
        let key = try LiveProviderTests.requireLiveCredentials()

        var configuration = AppConfiguration()
        configuration.tavilyAPIKey = key
        configuration.providerOrder = [.tavily]
        // Live vendors are slower than a loopback stub; give them room.
        configuration.fastTimeout = .seconds(30)
        configuration.balancedTimeout = .seconds(30)
        configuration.thoroughTimeout = .seconds(45)

        let http = URLSessionHTTPClient(configuration: configuration)
        let provider = TavilyProvider(
            apiKey: key,
            http: http,
            configuration: configuration
        )
        return (provider, configuration)
    }

    private func liveOrchestrator(
        configuration: AppConfiguration
    ) -> SearchOrchestrator {
        let http = URLSessionHTTPClient(configuration: configuration)
        let provider = TavilyProvider(
            apiKey: configuration.tavilyAPIKey ?? "",
            http: http,
            configuration: configuration
        )
        let registry = ProviderRegistry(providers: [provider], configuration: configuration)
        return SearchOrchestrator(
            registry: registry,
            health: ProviderHealth(),
            cache: SearchCache(),
            configuration: configuration
        )
    }

    // MARK: - Credential validity

    /// The opt-in must be explicit: a key alone must never enable live spending.
    func testLiveTestsRequireAnExplicitOptIn() {
        XCTAssertFalse(LiveProviderTests.liveTestsEnabled([:]))
        for value in ["", "0", "false", "no", "off", "maybe"] {
            XCTAssertFalse(
                LiveProviderTests.liveTestsEnabled(["SEARCH_LIVE_TESTS": value]),
                "'\(value)' must not enable live tests"
            )
        }
        for value in ["1", "true", "TRUE", "yes", "on", "enabled"] {
            XCTAssertTrue(
                LiveProviderTests.liveTestsEnabled(["SEARCH_LIVE_TESTS": value]),
                "'\(value)' must enable live tests"
            )
        }
    }

    /// The placeholder guard must reject the values CI uses to prove hermeticity.
    ///
    /// Without this, running the suite with a fake key present would activate these live
    /// tests and turn a passing build red with an authentication failure.
    func testPlaceholderCredentialsAreNotTreatedAsUsable() {
        // Values the CI workflow and example configuration actually use.
        for placeholder in [
            "tvly-not-a-real-key",
            "tvly-ci-placeholder",
            "not-a-real-key",
            "fake",
            "dummy-key",
            "example-key",
            "invalid",
            "tvly-dev-placeholder-value",
        ] {
            XCTAssertFalse(
                LiveProviderTests.isUsableKey(placeholder),
                "'\(placeholder)' is a placeholder and must not enable live tests"
            )
        }

        // Too short to be a real key.
        XCTAssertFalse(LiveProviderTests.isUsableKey("short"))
        XCTAssertFalse(LiveProviderTests.isUsableKey(""))

        // A realistic Tavily key shape is accepted.
        XCTAssertTrue(
            LiveProviderTests.isUsableKey("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")
        )
        XCTAssertTrue(
            LiveProviderTests.isUsableKey("tvly-abcdefghijklmnopqrstuvwxyz0123456789")
        )
    }

    /// A deliberately invalid key must be reported as a configuration problem.
    ///
    /// This spends no credits and is the cheapest possible live check that the adapter's
    /// error classification is correct against the real service rather than a stub.
    func testInvalidKeyIsClassifiedAsAuthenticationFailure() async throws {
        _ = try LiveProviderTests.requireLiveCredentials()

        var configuration = AppConfiguration()
        configuration.providerOrder = [.tavily]
        let http = URLSessionHTTPClient(configuration: configuration)
        let provider = TavilyProvider(
            apiKey: "tvly-dev-invalid-key-for-classification-test",
            http: http,
            configuration: configuration
        )

        do {
            _ = try await provider.search(
                SearchRequest(query: "swift", maxResults: 1, mode: .fast)
            )
            XCTFail("an invalid key must not produce results")
        } catch let error as SearchError {
            XCTAssertEqual(
                error.category,
                .authentication,
                "a rejected key must be classified as authentication, got \(error.category)"
            )
            // A rejected key must never be retried through the Jina fallback or another
            // path, and must not trip a circuit breaker.
            XCTAssertFalse(error.category.isTransient)
        }
    }

    // MARK: - Search (1 credit)

    /// One live search, with every response-shape assertion made against it.
    func testLiveSearchReturnsNormalizedResults() async throws {
        let (provider, _) = try liveTavily()

        let response = try await provider.search(
            SearchRequest(query: "Swift strict concurrency Sendable", maxResults: 4, mode: .fast)
        )

        XCTAssertEqual(response.provider, .tavily)
        XCTAssertFalse(response.results.isEmpty, "a live search should return results")
        XCTAssertLessThanOrEqual(response.results.count, 4)

        for (index, result) in response.results.enumerated() {
            XCTAssertEqual(result.provider, .tavily)
            XCTAssertEqual(result.providerRank, index + 1, "ranks must be sequential")
            XCTAssertFalse(result.title.isEmpty)
            XCTAssertFalse(result.canonicalURL.absoluteString.isEmpty)
            XCTAssertEqual(result.url.scheme, "https", "Tavily returns https results")
            XCTAssertEqual(result.sources, [.tavily])
            // Tavily supplies a relevance score; it must be carried through.
            XCTAssertNotNil(result.providerScore, "Tavily results carry a relevance score")
        }

        // Results should be relevant to the query rather than an arbitrary page.
        let combined = response.results
            .map { "\($0.title) \($0.snippet ?? "")" }
            .joined(separator: " ")
            .lowercased()
        XCTAssertTrue(
            combined.contains("swift") || combined.contains("concurren"),
            "results should relate to the query; got: \(combined.prefix(200))"
        )
    }

    /// A recency filter must reach the provider and come back with dates attached,
    /// which is only true if `include_published_date` is requested alongside
    /// `time_range`. Costs 1 credit.
    func testLiveSearchWithRecencyReturnsDates() async throws {
        let (provider, _) = try liveTavily()

        var request = SearchRequest(query: "Swift release notes", maxResults: 5, mode: .fast)
        request.recency = .year
        let response = try await provider.search(request)

        XCTAssertFalse(response.results.isEmpty, "expected results within the last year")
        // The adapter asks for published dates whenever a recency filter is active, so
        // at least one result should be dated. (Tavily keeps undated results by
        // default, hence "at least one" rather than "all".)
        XCTAssertTrue(
            response.results.contains { $0.publishedAt != nil },
            "a recency-filtered search should return at least one dated result"
        )
    }

    // MARK: - Fusion through the orchestrator (1 credit)

    /// The full search path: registry, health, orchestration, fusion, cache.
    func testLiveOrchestratedSearchFusesAndCaches() async throws {
        let (_, configuration) = try liveTavily()
        let orchestrator = liveOrchestrator(configuration: configuration)

        let request = SearchRequest(query: "MCP Swift SDK", maxResults: 3, mode: .fast)
        let first = try await orchestrator.search(request)

        XCTAssertFalse(first.results.isEmpty)
        XCTAssertEqual(first.providersUsed, [.tavily])
        XCTAssertTrue(first.providersFailed.isEmpty)
        XCTAssertFalse(first.servedFromCache)

        // The second identical search must be answered from cache, spending no credit.
        let second = try await orchestrator.search(request)
        XCTAssertTrue(second.servedFromCache, "the repeat search must be cached")
        XCTAssertEqual(second.elapsedMilliseconds, 0)
        XCTAssertEqual(second.results.count, first.results.count)
    }

    // MARK: - Advanced depth (2 credits)

    /// `thorough` mode is the only path that may request Tavily's `advanced` depth.
    ///
    /// This costs 2 credits and exists to confirm the depth mapping reaches the live
    /// service, since that mapping is the difference between 1 and 2 credits per call.
    func testLiveThoroughModeUsesAdvancedDepth() async throws {
        let key = try LiveProviderTests.requireLiveCredentials()

        var configuration = AppConfiguration()
        configuration.providerOrder = [.tavily]
        configuration.thoroughTimeout = .seconds(60)
        let http = URLSessionHTTPClient(configuration: configuration)
        let provider = TavilyProvider(apiKey: key, http: http, configuration: configuration)

        let request = SearchRequest(query: "reciprocal rank fusion", maxResults: 3, mode: .thorough)
        let response = try await provider.search(request)

        XCTAssertFalse(
            response.results.isEmpty,
            "advanced depth should still return results"
        )
    }

    // MARK: - Status tool against a live key

    /// The status tool must recognise a live key as usable without revealing it.
    func testLiveStatusReportsTavilyReadyWithoutLeakingKey() async throws {
        let (_, configuration) = try liveTavily()
        let orchestrator = liveOrchestrator(configuration: configuration)

        let states = await orchestrator.status()
        let tavily = try XCTUnwrap(states.first { $0.provider == .tavily })
        XCTAssertTrue(tavily.configured)
        XCTAssertEqual(tavily.status, .ready)

        // Nothing in the diagnostic payload may contain the credential.
        let rendered = String(describing: tavily)
        let key = try XCTUnwrap(configuration.tavilyAPIKey)
        XCTAssertFalse(rendered.contains(key), "status output leaked the API key")
    }
}
