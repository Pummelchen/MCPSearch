import Foundation
import XCTest

@testable import WebSearchCore

/// Every provider adapter must satisfy the same contract, whatever its wire format.
///
/// These tests drive each adapter against a scripted transport, so they verify
/// normalization, error classification and credential hygiene without any network.
final class ProviderContractTests: XCTestCase {

    private let configuration = Fixtures.configuration()

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Assert the shared success contract for any provider.
    private func assertNormalizedResults(
        _ response: ProviderSearchResponse,
        provider: ProviderID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(response.provider, provider, file: file, line: line)
        XCTAssertFalse(response.results.isEmpty, "expected results", file: file, line: line)
        for result in response.results {
            XCTAssertEqual(result.provider, provider, file: file, line: line)
            XCTAssertGreaterThan(result.providerRank, 0, file: file, line: line)
            XCTAssertTrue(
                result.url.scheme == "http" || result.url.scheme == "https",
                "results must be web URLs",
                file: file,
                line: line
            )
            XCTAssertFalse(result.title.isEmpty, file: file, line: line)
            XCTAssertFalse(result.canonicalURL.absoluteString.isEmpty, file: file, line: line)
            XCTAssertEqual(result.sources, [provider], file: file, line: line)
        }
    }

    /// Assert that every adapter classifies the same upstream conditions identically.
    private func assertFailureTaxonomy(
        makeProvider: (MockHTTPClient) -> any SearchProvider,
        provider: ProviderID,
        authenticationStatus: Int,
        rateLimitStatus: Int,
        serverErrorStatus: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // Authentication.
        let authHTTP = MockHTTPClient()
        authHTTP.onAny { request in
            HTTPResponse(
                statusCode: authenticationStatus,
                headers: [:],
                body: Data(#"{"error":"nope"}"#.utf8),
                url: request.url
            )
        }
        do {
            _ = try await makeProvider(authHTTP).search(Fixtures.request())
            XCTFail("expected authentication failure", file: file, line: line)
        } catch let error as SearchError {
            XCTAssertEqual(
                error.category,
                .authentication,
                "\(provider) misclassified auth",
                file: file,
                line: line
            )
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }

        // Rate limiting.
        let rateHTTP = MockHTTPClient()
        rateHTTP.onAny { request in
            HTTPResponse(
                statusCode: rateLimitStatus,
                headers: ["retry-after": "3"],
                body: Data(),
                url: request.url
            )
        }
        do {
            _ = try await makeProvider(rateHTTP).search(Fixtures.request())
            XCTFail("expected rate limit", file: file, line: line)
        } catch let error as SearchError {
            XCTAssertEqual(
                error.category,
                .rateLimited,
                "\(provider) misclassified rate limit",
                file: file,
                line: line
            )
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }

        // Server error.
        let serverHTTP = MockHTTPClient()
        serverHTTP.onAny { request in
            HTTPResponse(statusCode: serverErrorStatus, headers: [:], body: Data(), url: request.url)
        }
        do {
            _ = try await makeProvider(serverHTTP).search(Fixtures.request())
            XCTFail("expected server error", file: file, line: line)
        } catch let error as SearchError {
            XCTAssertTrue(
                error.category.isTransient,
                "\(provider) classified 5xx as non-transient",
                file: file,
                line: line
            )
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }

        // Malformed body: must fail cleanly, never produce junk results.
        let junkHTTP = MockHTTPClient()
        junkHTTP.onAny { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data("this is not json at all".utf8),
                url: request.url
            )
        }
        do {
            _ = try await makeProvider(junkHTTP).search(Fixtures.request())
            XCTFail("expected malformed-response failure", file: file, line: line)
        } catch let error as SearchError {
            XCTAssertEqual(
                error.category,
                .malformedResponse,
                "\(provider) misclassified malformed body",
                file: file,
                line: line
            )
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }

    // MARK: - Tavily

    func testTavilyHappyPath() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            """
            {
              "query": "swift",
              "answer": "Swift is a language.",
              "results": [
                {"title":"Swift.org","url":"https://swift.org/","content":"The Swift language site.","score":0.91},
                {"title":"Docs","url":"https://swift.org/documentation/","content":"Documentation.","score":0.7}
              ]
            }
            """
        )
        let provider = TavilyProvider(
            apiKey: "tvly-secret",
            http: http,
            configuration: configuration
        )
        let response = try await provider.search(Fixtures.request("swift"))

        assertNormalizedResults(response, provider: .tavily)
        XCTAssertEqual(response.answer, "Swift is a language.")
        XCTAssertEqual(response.results[0].providerScore, 0.91)
        XCTAssertEqual(response.results[0].providerRank, 1)

        // Authentication must travel in a header, and never in a query string.
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer tvly-secret")
        XCTAssertFalse(request.url.absoluteString.contains("tvly-secret"))
    }

    func testTavilyMapsRecencyAndDomainsAndOmitsInvalidFields() async throws {
        let http = MockHTTPClient()
        http.respondJSON(#"{"results":[]}"#)

        var request = Fixtures.request("swift")
        request.recency = .week
        request.includeDomains = ["swift.org"]
        request.excludeDomains = ["spam.example.com"]
        request.providerResultBudget = 30

        _ = try await TavilyProvider(
            apiKey: "k",
            http: http,
            configuration: configuration
        ).search(request)

        let body = try XCTUnwrap(http.requests.first?.body)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["time_range"] as? String, "week")
        XCTAssertEqual(json["include_domains"] as? [String], ["swift.org"])
        XCTAssertEqual(json["exclude_domains"] as? [String], ["spam.example.com"])
        XCTAssertEqual(json["max_results"] as? Int, 20, "Tavily caps max_results at 20")
        XCTAssertEqual(json["search_depth"] as? String, "basic")
        // `days` is not part of the current Tavily schema and would be rejected.
        XCTAssertNil(json["days"])
        // A recency filter is only verifiable if the date is requested too.
        XCTAssertEqual(json["include_published_date"] as? Bool, true)
    }

    func testTavilyUsesAdvancedDepthOnlyInThoroughMode() async throws {
        let http = MockHTTPClient()
        http.respondJSON(#"{"results":[]}"#)
        var request = Fixtures.request("swift")
        request.mode = .thorough

        _ = try await TavilyProvider(apiKey: "k", http: http, configuration: configuration)
            .search(request)

        let body = try XCTUnwrap(http.requests.first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        // Advanced costs two credits, so it must not be used casually.
        XCTAssertEqual(json["search_depth"] as? String, "advanced")
    }

    func testTavilyTaxonomy() async {
        await assertFailureTaxonomy(
            makeProvider: { TavilyProvider(apiKey: "k", http: $0, configuration: self.configuration) },
            provider: .tavily,
            authenticationStatus: 401,
            rateLimitStatus: 429,
            serverErrorStatus: 503
        )
    }

    // MARK: - Brave

    func testBraveHappyPath() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            """
            {
              "type": "search",
              "query": {"original": "swift", "altered": "swift"},
              "web": {"type":"search","results":[
                {"title":"Swift.org","url":"https://swift.org/","description":"The Swift site.",
                 "page_age":"2025-04-12T14:22:41","extra_snippets":["More detail here."]}
              ]}
            }
            """
        )
        let provider = BraveProvider(
            apiKey: "brave-secret",
            http: http,
            configuration: configuration
        )
        let response = try await provider.search(Fixtures.request("swift"))

        assertNormalizedResults(response, provider: .brave)
        // The primary description and extra snippets are combined.
        XCTAssertTrue(response.results[0].snippet?.contains("The Swift site.") ?? false)
        XCTAssertTrue(response.results[0].snippet?.contains("More detail here.") ?? false)
        XCTAssertNotNil(response.results[0].publishedAt)

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.headers["X-Subscription-Token"], "brave-secret")
        XCTAssertFalse(request.url.absoluteString.contains("brave-secret"))
        // Brave's count is capped at 20 regardless of what was asked for.
        XCTAssertTrue(request.url.absoluteString.contains("count=20"))
        // Decoration markup must be off so no HTML leaks into model context.
        XCTAssertTrue(request.url.absoluteString.contains("text_decorations=false"))
    }

    func testBraveMapsFreshness() async throws {
        let http = MockHTTPClient()
        http.respondJSON(#"{"web":{"results":[]}}"#)

        for (recency, expected) in [
            (Recency.day, "pd"), (.week, "pw"), (.month, "pm"), (.year, "py"),
        ] {
            var request = Fixtures.request("q")
            request.recency = recency
            _ = try await BraveProvider(apiKey: "k", http: http, configuration: configuration)
                .search(request)
            let url = try XCTUnwrap(http.requests.last?.url.absoluteString)
            XCTAssertTrue(url.contains("freshness=\(expected)"), "\(recency) -> \(expected): \(url)")
        }
    }

    func testBraveInvalidTokenIsReportedAsAuthentication() async {
        // Brave signals a bad key with 422 plus an error code, not 401.
        let http = MockHTTPClient()
        http.respondJSON(
            """
            {"type":"ErrorResponse","error":{"id":"x","status":422,
             "detail":"The provided subscription token is invalid.",
             "meta":{"component":"authentication"},"code":"SUBSCRIPTION_TOKEN_INVALID"}}
            """,
            status: 422
        )
        do {
            _ = try await BraveProvider(apiKey: "bad", http: http, configuration: configuration)
                .search(Fixtures.request())
            XCTFail("expected authentication failure")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .authentication)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBraveOrdinary422IsNotAuthentication() async {
        let http = MockHTTPClient()
        http.respondJSON(
            #"{"type":"ErrorResponse","error":{"status":422,"code":"VALIDATION","detail":"bad param"}}"#,
            status: 422
        )
        do {
            _ = try await BraveProvider(apiKey: "k", http: http, configuration: configuration)
                .search(Fixtures.request())
            XCTFail("expected a non-auth failure")
        } catch let error as SearchError {
            XCTAssertNotEqual(error.category, .authentication)
            XCTAssertEqual(error.category, .unsupportedRequest)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Mojeek

    func testMojeekHappyPathAndQueryParameterAuth() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            """
            {"response":{"status":"OK","head":{"results":2,"start":1,"return":10},
             "results":[
               {"url":"https://www.mojeek.com/","title":"Mojeek","desc":"Independent search.",
                "score":20.3,"timestamp":1184044740},
               {"url":"https://example.org/a","title":"Example","desc":"Another result."}
             ]}}
            """
        )
        let provider = MojeekProvider(
            apiKey: "mojeek-secret",
            http: http,
            configuration: configuration
        )
        let response = try await provider.search(Fixtures.request("mojeek"))

        assertNormalizedResults(response, provider: .mojeek)
        XCTAssertEqual(response.totalEstimatedMatches, 2)
        XCTAssertNotNil(response.results[0].publishedAt)

        let request = try XCTUnwrap(http.requests.first)
        // Mojeek authenticates with a query parameter; the header is ignored.
        XCTAssertTrue(request.url.absoluteString.contains("api_key=mojeek-secret"))
        XCTAssertNil(request.headers["X-Mojeek-Api-Key"])
        // JSON is not the default output format.
        XCTAssertTrue(request.url.absoluteString.contains("fmt=json"))
    }

    func testMojeekBadKeyInside200ResponseIsAuthentication() async {
        // Mojeek returns HTTP 200 with an error string for an invalid key.
        let http = MockHTTPClient()
        http.respondJSON(
            #"{"response":{"status":"Access Denied: invalid key/password","head":{},"results":[]}}"#
        )
        do {
            _ = try await MojeekProvider(
                apiKey: "bad",
                http: http,
                configuration: configuration
            ).search(Fixtures.request())
            XCTFail("expected authentication failure")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .authentication)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMojeekQuotaStatusIsRateLimited() async {
        let http = MockHTTPClient()
        http.respondJSON(
            #"{"response":{"status":"ERROR: Daily Limit Reached","head":{},"results":[]}}"#
        )
        do {
            _ = try await MojeekProvider(apiKey: "k", http: http, configuration: configuration)
                .search(Fixtures.request())
            XCTFail("expected rate limit")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .rateLimited)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMojeekMissingKeyIs403() async {
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(statusCode: 403, headers: [:], body: Data(), url: request.url)
        }
        do {
            _ = try await MojeekProvider(apiKey: "k", http: http, configuration: configuration)
                .search(Fixtures.request())
            XCTFail("expected authentication failure")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .authentication)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Exa

    func testExaHappyPathUsesContentsBlock() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            """
            {"requestId":"abc","results":[
              {"title":"Swift Concurrency","url":"https://example.com/swift",
               "publishedDate":"2023-11-16T01:36:32.547Z",
               "highlights":["Actors provide isolation."],
               "text":"Long body text."}
            ]}
            """
        )
        let provider = ExaProvider(apiKey: "exa-secret", http: http, configuration: configuration)
        let response = try await provider.search(Fixtures.request("swift"))

        assertNormalizedResults(response, provider: .exa)
        XCTAssertEqual(response.results[0].snippet, "Actors provide isolation.")
        XCTAssertNotNil(response.results[0].publishedAt)
        // Exa's current schema has no comparable score.
        XCTAssertNil(response.results[0].providerScore)

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.headers["x-api-key"], "exa-secret")
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "auto")
        // Content controls must live in `contents`, not at the top level.
        XCTAssertNotNil(json["contents"])
        XCTAssertNil(json["highlights"])
        XCTAssertNil(json["text"])
    }

    func testExaMapsRecencyToStartPublishedDate() async throws {
        let http = MockHTTPClient()
        http.respondJSON(#"{"results":[]}"#)
        var request = Fixtures.request("q")
        request.recency = .month

        _ = try await ExaProvider(apiKey: "k", http: http, configuration: configuration)
            .search(request)

        let body = try XCTUnwrap(http.requests.first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let start = try XCTUnwrap(json["startPublishedDate"] as? String)
        XCTAssertTrue(start.contains("T"), "expected an ISO 8601 instant, got \(start)")
        let contents = try XCTUnwrap(json["contents"] as? [String: Any])
        // A live crawl is only justified for an explicit freshness requirement.
        XCTAssertEqual(contents["maxAgeHours"] as? Int, 0)
    }

    func testExaMissingKeyIs402() async {
        // Exa answers a missing key with 402, an invalid one with 401.
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(statusCode: 402, headers: [:], body: Data("{}".utf8), url: request.url)
        }
        do {
            _ = try await ExaProvider(apiKey: "k", http: http, configuration: configuration)
                .search(Fixtures.request())
            XCTFail("expected authentication failure")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .authentication)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testExaInvalidKeyIs401() async {
        let http = MockHTTPClient()
        http.respondJSON(
            #"{"requestId":"x","error":"Invalid API key","tag":"INVALID_API_KEY"}"#,
            status: 401
        )
        do {
            _ = try await ExaProvider(apiKey: "bad", http: http, configuration: configuration)
                .search(Fixtures.request())
            XCTFail("expected authentication failure")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .authentication)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - SearXNG

    func testSearXNGHappyPath() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            """
            {"query":"searxng","results":[
              {"url":"https://docs.searxng.org/","title":"SearXNG Documentation",
               "content":"Self-hosted metasearch.","publishedDate":"2024-01-15T00:00:00",
               "engine":"duckduckgo","engines":["duckduckgo","brave"],"score":3.5},
              {"url":"https://example.com/x","title":"Other","content":"Text.","engine":"brave"}
             ],
             "answers":[],"corrections":[],"infoboxes":[],"suggestions":[],
             "unresponsive_engines":[["google","timeout"]]}
            """
        )
        let provider = SearXNGProvider(
            baseURL: URL(string: "https://searx.example.com")!,
            http: http,
            configuration: configuration
        )
        let response = try await provider.search(Fixtures.request("searxng"))

        assertNormalizedResults(response, provider: .searxng)
        XCTAssertEqual(Set(response.upstreamEngines), Set(["duckduckgo", "brave"]))
        XCTAssertTrue(response.warnings.contains { $0.contains("google") })

        let url = try XCTUnwrap(http.requests.first?.url.absoluteString)
        XCTAssertTrue(url.contains("/search"))
        XCTAssertTrue(url.contains("format=json"))
    }

    func testSearXNGJsonDisabledIsAConfigurationProblemNotTransient() async {
        // Enabled instances refuse format=json with 403 and an HTML body.
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(
                statusCode: 403,
                headers: ["content-type": "text/html"],
                body: Data("<html><body>403 Forbidden</body></html>".utf8),
                url: request.url
            )
        }
        do {
            _ = try await SearXNGProvider(
                baseURL: URL(string: "https://searx.example.com")!,
                http: http,
                configuration: configuration
            ).search(Fixtures.request())
            XCTFail("expected a failure")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .unsupportedRequest)
            XCTAssertFalse(
                error.category.isTransient,
                "a disabled JSON API must not trip the circuit breaker"
            )
            XCTAssertTrue(error.safeDescription.contains("settings.yml"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSearXNGMapsTimeRange() async throws {
        let http = MockHTTPClient()
        http.respondJSON(#"{"results":[]}"#)
        var request = Fixtures.request("q")
        request.recency = .week
        _ = try await SearXNGProvider(
            baseURL: URL(string: "https://searx.example.com")!,
            http: http,
            configuration: configuration
        ).search(request)
        let url = try XCTUnwrap(http.requests.first?.url.absoluteString)
        XCTAssertTrue(url.contains("time_range=week"))
    }

    func testSearXNGHandlesNullablePublishedDate() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            """
            {"results":[{"url":"https://example.com/a","title":"A","content":"c",
             "publishedDate":null,"engine":"brave"}]}
            """
        )
        let response = try await SearXNGProvider(
            baseURL: URL(string: "https://searx.example.com")!,
            http: http,
            configuration: configuration
        ).search(Fixtures.request())
        XCTAssertNil(response.results[0].publishedAt)
    }

    // MARK: - DuckDuckGo (scraper, opt-in)

    func testDuckDuckGoScraperEndToEnd() async throws {
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/html"],
                body: Data(
                    """
                    <html><body><div class="result web-result">
                      <h2 class="result__title"><a class="result__a"
                        href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage">Result title here</a></h2>
                      <a class="result__snippet">A useful snippet for the result.</a>
                    </div></body></html>
                    """.utf8
                ),
                url: request.url
            )
        }
        let provider = DuckDuckGoProvider(
            http: http,
            configuration: Fixtures.configuration(enableScrapers: true),
            scrapersEnabled: true
        )
        let response = try await provider.search(Fixtures.request("test"))
        assertNormalizedResults(response, provider: .duckDuckGo)
        XCTAssertEqual(response.results[0].url.absoluteString, "https://example.com/page")
    }

    func testDuckDuckGoBotChallengeIsAProviderFailure() async {
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(
                statusCode: 202,
                headers: ["content-type": "text/html"],
                body: Data(
                    "<html><body><div class=\"anomaly-modal\">Unfortunately, bots use DuckDuckGo too.</div></body></html>"
                        .utf8
                ),
                url: request.url
            )
        }
        do {
            _ = try await DuckDuckGoProvider(
                http: http,
                configuration: Fixtures.configuration(enableScrapers: true),
                scrapersEnabled: true
            ).search(Fixtures.request())
            XCTFail("a challenge page must not be parsed as results")
        } catch let error as SearchError {
            XCTAssertTrue(error.category.isTransient || error.category == .malformedResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDuckDuckGoChangedMarkupFailsCleanly() async {
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/html"],
                body: Data("<html><body><p>Completely redesigned page.</p></body></html>".utf8),
                url: request.url
            )
        }
        do {
            _ = try await DuckDuckGoProvider(
                http: http,
                configuration: Fixtures.configuration(enableScrapers: true),
                scrapersEnabled: true
            ).search(Fixtures.request())
            XCTFail("unrecognized markup must fail rather than return junk")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .malformedResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Status mapping

    func testHTTPStatusMapperClassifiesCorrectly() {
        func response(_ status: Int, headers: [String: String] = [:]) -> HTTPResponse {
            HTTPResponse(
                statusCode: status,
                headers: headers,
                body: Data(),
                url: URL(string: "https://example.com")!
            )
        }

        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(response(401), provider: .tavily)
        ) { error in
            XCTAssertEqual((error as? SearchError)?.category, .authentication)
        }
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(response(403), provider: .tavily)
        ) { error in
            XCTAssertEqual((error as? SearchError)?.category, .authentication)
        }
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(response(429, headers: ["retry-after": "5"]), provider: .tavily)
        ) { error in
            guard case .rateLimited(_, let retryAfter) = error as? SearchError else {
                return XCTFail("expected rateLimited")
            }
            XCTAssertEqual(retryAfter?.milliseconds, 5000)
        }
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(response(400), provider: .tavily)
        ) { error in
            XCTAssertEqual((error as? SearchError)?.category, .unsupportedRequest)
        }
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(response(503), provider: .tavily)
        ) { error in
            XCTAssertEqual((error as? SearchError)?.category, .serverError)
        }
        XCTAssertNoThrow(try HTTPStatusMapper.validate(response(200), provider: .tavily))
    }

    func testRetryableStatusSetIsDeliberatelyNarrow() {
        // 400/401/403 must never be retried: retrying wastes quota and cannot succeed.
        XCTAssertFalse(HTTPPolicy.retryableStatusCodes.contains(400))
        XCTAssertFalse(HTTPPolicy.retryableStatusCodes.contains(401))
        XCTAssertFalse(HTTPPolicy.retryableStatusCodes.contains(403))
        XCTAssertFalse(HTTPPolicy.retryableStatusCodes.contains(404))
        for status in [408, 425, 429, 500, 502, 503, 504] {
            XCTAssertTrue(HTTPPolicy.retryableStatusCodes.contains(status), "\(status)")
        }
    }

    func testBackoffIsBoundedAndJittered() {
        let policy = HTTPPolicy()
        var seen = Set<Int>()
        for _ in 0..<50 {
            let delay = policy.backoff(forRetryIndex: 0).milliseconds
            // Base 200ms with full jitter across [0.5x, 1.5x].
            XCTAssertGreaterThanOrEqual(delay, 100)
            XCTAssertLessThanOrEqual(delay, 300)
            seen.insert(delay)
        }
        XCTAssertGreaterThan(seen.count, 1, "jitter should vary the delay")
        // The schedule must saturate rather than grow without bound.
        XCTAssertLessThanOrEqual(policy.backoff(forRetryIndex: 99).milliseconds, 750)
    }
}
