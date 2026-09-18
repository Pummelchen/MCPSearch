import Foundation
import XCTest

@testable import WebSearchCore

// MARK: - Server under test

/// A scripted `HTTPClient` so provider contract tests never touch the network.
///
/// Responses are keyed by the request label, and every request is recorded so tests
/// can assert on URLs, headers and bodies.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
        let label: String
        /// Per-request timeout override, so tests can assert that generative traffic
        /// is not clipped by the short search timeout.
        let timeout: Duration?
    }

    private let lock = NSLock()
    private var _requests: [Recorded] = []

    /// Handlers keyed by label. The first matching handler wins.
    private var handlers: [String: @Sendable (Recorded) throws -> HTTPResponse] = [:]
    /// Fallback used when no label-specific handler exists.
    private var fallback: (@Sendable (Recorded) throws -> HTTPResponse)?

    init() {}

    var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func requests(label: String) -> [Recorded] {
        requests.filter { $0.label == label }
    }

    func on(
        _ label: String,
        _ handler: @escaping @Sendable (Recorded) throws -> HTTPResponse
    ) {
        lock.lock()
        handlers[label] = handler
        lock.unlock()
    }

    func onAny(_ handler: @escaping @Sendable (Recorded) throws -> HTTPResponse) {
        lock.lock()
        fallback = handler
        lock.unlock()
    }

    /// Convenience: answer every request with a JSON body and status.
    func respondJSON(_ json: String, status: Int = 200, label: String? = nil) {
        let handler: @Sendable (Recorded) throws -> HTTPResponse = { request in
            HTTPResponse(
                statusCode: status,
                headers: ["content-type": "application/json"],
                body: Data(json.utf8),
                url: request.url
            )
        }
        if let label {
            on(label, handler)
        } else {
            onAny(handler)
        }
    }

    func send(_ request: HTTPRequest, maxBytes: Int) async throws -> HTTPResponse {
        let recorded = Recorded(
            method: request.method,
            url: request.url,
            headers: request.headers,
            body: request.body,
            label: request.label,
            timeout: request.timeout
        )
        let handler = lock.withLock {
            _requests.append(recorded)
            return handlers[request.label] ?? fallback
        }

        guard let handler else {
            throw HTTPError.transportFailure(
                label: request.label,
                reason: "MockHTTPClient has no handler for \(request.label)"
            )
        }
        return try handler(recorded)
    }

    // MARK: Assertions

    func assertNoCredentialLeak(
        _ secret: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            requests.isEmpty,
            "assertNoCredentialLeak needs at least one recorded request: with none it passed "
                + "without checking anything",
            file: file,
            line: line
        )
        for request in requests {
            let headerValues = request.headers.map { "\($0.key): \($0.value)" }.joined(separator: " ")
            XCTAssertFalse(
                headerValues.contains(secret),
                "credential appeared in headers for \(request.label)",
                file: file,
                line: line
            )
            // A key may legitimately travel in a query string (Mojeek does this), which is why it
            // must never be echoed. This helper checks what the mock can see — the headers and body
            // it recorded; log lines and error descriptions are asserted by the tests that exercise
            // those paths. The comment here used to claim this helper covered them too.
            if let body = request.body, let text = String(data: body, encoding: .utf8) {
                XCTAssertFalse(
                    text.contains(secret),
                    "credential appeared in body for \(request.label)",
                    file: file,
                    line: line
                )
            }
        }
    }
}

// MARK: - Mock provider

/// A provider whose behaviour is scripted per test.
final class MockSearchProvider: SearchProvider, @unchecked Sendable {
    let id: ProviderID
    let fusionWeight: Double
    let configured: Bool

    private let lock = NSLock()
    private var _callCount = 0
    /// Every request the provider was called with, in order, so a test can assert the
    /// contract the orchestrator is supposed to hand it.
    private var _requests: [SearchRequest] = []
    private var outcome: @Sendable (SearchRequest) async throws -> ProviderSearchResponse

    init(
        id: ProviderID,
        fusionWeight: Double = 1.0,
        configured: Bool = true,
        outcome: @escaping @Sendable (SearchRequest) async throws -> ProviderSearchResponse
    ) {
        self.id = id
        self.fusionWeight = fusionWeight
        self.configured = configured
        self.outcome = outcome
    }

    /// A provider that returns fixed results.
    static func returning(
        _ id: ProviderID,
        results: [(title: String, url: String, snippet: String?)],
        fusionWeight: Double = 1.0
    ) -> MockSearchProvider {
        MockSearchProvider(id: id, fusionWeight: fusionWeight) { request in
            var seen: Set<String> = []
            var normalized: [SearchResult] = []
            for (index, item) in results.enumerated() {
                if let result = ResultNormalizer.make(
                    provider: id,
                    rank: index + 1,
                    title: item.title,
                    urlString: item.url,
                    snippet: item.snippet,
                    request: request,
                    seenKeys: &seen
                ) {
                    normalized.append(result)
                }
            }
            return ProviderSearchResponse(provider: id, results: normalized)
        }
    }

    /// A provider that always fails with the given error.
    static func failing(_ id: ProviderID, with error: SearchError) -> MockSearchProvider {
        MockSearchProvider(id: id) { _ in throw error }
    }

    /// A provider that never returns, for timeout tests.
    static func hanging(_ id: ProviderID) -> MockSearchProvider {
        MockSearchProvider(id: id) { _ in
            try await Task.sleep(for: .seconds(60))
            throw SearchError.timeout(id)
        }
    }

    var isConfigured: Bool { configured }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    /// The requests this provider received, oldest first.
    var requests: [SearchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func search(_ request: SearchRequest) async throws -> ProviderSearchResponse {
        // `NSLock.lock()` is unavailable in an async context under Swift 6, so the
        // counter update is scoped with `withLock`.
        let outcome = lock.withLock { () -> @Sendable (SearchRequest) async throws -> ProviderSearchResponse in
            _callCount += 1
            _requests.append(request)
            return self.outcome
        }
        return try await outcome(request)
    }
}

// MARK: - Creeping clock

/// A clock that advances by a fixed step on every `now()` read.
///
/// `TestClock` only moves when a test moves it, so it cannot reproduce a race whose whole shape
/// is "the clock advanced between two reads of it". The orchestrator reads the clock once to
/// decide a provider is throttled and again to estimate the remaining wait, so a clock that
/// creeps on every read deterministically puts those two reads on opposite sides of a
/// `minimumInterval` boundary — the boundary that was intermittent on a real clock.
final class CreepingClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var uptime: UInt64
    private let step: Duration

    init(step: Duration, start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.step = step
        self.current = start
        self.uptime = 0
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = current
        current = current.addingTimeInterval(step.seconds)
        uptime &+= UInt64(max(0, step.seconds) * 1_000_000_000)
        return value
    }

    func uptimeNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return uptime
    }
}

// MARK: - Fixtures

enum Fixtures {

    /// A key-shaped value that is deliberately not a credential.
    ///
    /// The shape is what matters: `AppConfiguration` accepts a key only when it is at least 20
    /// characters long and contains none of its marker words (`placeholder`, `fake`, `example`,
    /// …), so a test that needs "a usable key is configured" must supply something key-shaped.
    /// The body is a run of zeroes, which keeps the full-history secret scan clean: the literal
    /// this replaced (`sk-test-key-…`) was flagged five times by `gitleaks`, and a
    /// synthetic value that trips a scanner only teaches people to ignore the scanner.
    static let syntheticDeepSeekKey = "sk-000000000000000000000000"

    static func configuration(
        // Defaults to the shipped order minus the fetch-only provider, which is what a
        // real deployment resolves to.
        providerOrder: [ProviderID] = AppConfiguration.defaultProviderOrder,
        enableScrapers: Bool = false,
        enableParallel: Bool = false,
        cacheTTL: Duration = .seconds(120),
        fastTimeout: Duration = .seconds(2),
        balancedTimeout: Duration = .seconds(3),
        thoroughTimeout: Duration = .seconds(4)
    ) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.providerOrder = providerOrder
        configuration.enableScrapers = enableScrapers
        configuration.enableParallel = enableParallel
        configuration.cacheTTL = cacheTTL
        configuration.fastTimeout = fastTimeout
        configuration.balancedTimeout = balancedTimeout
        configuration.thoroughTimeout = thoroughTimeout
        // A per-domain cap of 3 keeps results diverse while leaving ranking
        // assertions on distinct hosts unaffected.
        configuration.fusion = RankFusion.Configuration(maxResultsPerDomain: 3)
        return configuration
    }

    static func request(
        _ query: String = "swift concurrency",
        maxResults: Int = 8,
        mode: SearchMode = .balanced
    ) -> SearchRequest {
        SearchRequest(query: query, maxResults: maxResults, mode: mode)
    }
}
