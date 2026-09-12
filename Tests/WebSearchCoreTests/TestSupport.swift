import Foundation
import XCTest

@testable import WebSearchCore

// MARK: - Mock transport

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
        for request in requests {
            let headerValues = request.headers.map { "\($0.key): \($0.value)" }.joined(separator: " ")
            XCTAssertFalse(
                headerValues.contains(secret),
                "credential appeared in headers for \(request.label)",
                file: file,
                line: line
            )
            // A key may legitimately travel in a query string (Mojeek does this),
            // which is exactly why it must never be logged; assert the request was
            // recorded but that our *own* diagnostics never echo it.
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

    func search(_ request: SearchRequest) async throws -> ProviderSearchResponse {
        // `NSLock.lock()` is unavailable in an async context under Swift 6, so the
        // counter update is scoped with `withLock`.
        let outcome = lock.withLock { () -> @Sendable (SearchRequest) async throws -> ProviderSearchResponse in
            _callCount += 1
            return self.outcome
        }
        return try await outcome(request)
    }
}

// MARK: - Fixtures

enum Fixtures {
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

/// A `Clock` whose sleep behaviour is instantaneous, for timeout tests that must not
/// actually wait.
struct ImmediateClock: Clock {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { base }
    func uptimeNanoseconds() -> UInt64 { 0 }
}
