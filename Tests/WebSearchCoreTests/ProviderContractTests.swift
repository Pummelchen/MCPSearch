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
    ///
    /// - Parameters:
    ///   - authenticationStatus: The status this vendor uses to refuse a request.
    ///   - authenticationCategory: The category the adapter must map that refusal to.
    ///     Defaults to `.authentication`; DuckDuckGo is the one exception because it
    ///     is a credential-free scraper, so a refusal is a transient provider block
    ///     rather than a configuration problem.
    private func assertFailureTaxonomy(
        makeProvider: (MockHTTPClient) -> any SearchProvider,
        provider: ProviderID,
        authenticationStatus: Int,
        rateLimitStatus: Int,
        serverErrorStatus: Int,
        authenticationCategory: ProviderFailure.FailureCategory = .authentication,
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
                authenticationCategory,
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

    /// Regression: `published_date` is snake_case while the DTO maps its keys explicitly.
    ///
    /// Decoding with `.convertFromSnakeCase` rewrites the incoming key to
    /// `publishedDate` before the explicit `CodingKeys` are consulted, so the field
    /// silently decoded to nil. The original happy-path fixture omitted the field
    /// entirely, which is why the bug survived every stub-based test: a live search with
    /// a recency filter was the first thing to expose it.
    func testTavilyDecodesSnakeCasePublishedDate() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            """
            {
              "query": "swift release notes",
              "results": [
                {"title":"Swift 6.3 Released","url":"https://swift.org/blog/6-3/",
                 "content":"Release notes.","score":0.88,
                 "published_date":"Tue, 24 Mar 2026 10:00:00 GMT"},
                {"title":"Undated result","url":"https://example.com/undated",
                 "content":"No date.","published_date":null}
              ]
            }
            """
        )
        let provider = TavilyProvider(
            apiKey: "tvly-secret",
            http: http,
            configuration: configuration
        )
        let response = try await provider.search(Fixtures.request("swift release notes"))

        XCTAssertEqual(response.results.count, 2)

        // Tavily emits RFC 1123, not ISO 8601.
        let dated = try XCTUnwrap(
            response.results.first?.publishedAt,
            "published_date must decode; nil here means the snake-case strategy was applied"
        )
        let expected = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "UTC"),
            year: 2026, month: 3, day: 24, hour: 10
        ).date
        XCTAssertEqual(dated, expected)

        // An explicit null must stay nil rather than failing the whole decode.
        XCTAssertNil(response.results.last?.publishedAt)
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

    /// Brave must satisfy the shared taxonomy, so a dropped 401/429/5xx branch fails a
    /// test rather than surviving on the vendor-specific 422 quirk alone.
    func testBraveTaxonomy() async {
        await assertFailureTaxonomy(
            makeProvider: { BraveProvider(apiKey: "k", http: $0, configuration: self.configuration) },
            provider: .brave,
            authenticationStatus: 401,
            rateLimitStatus: 429,
            serverErrorStatus: 503
        )
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
        // The key travels in the query string, so it must not *also* appear in a header
        // or body that a diagnostic could surface.
        http.assertNoCredentialLeak("mojeek-secret")
    }

    func testMojeekBadKeyInside200ResponseIsAuthentication() async {
        // Mojeek returns HTTP 200 with an error string for an invalid key.
        let http = MockHTTPClient()
        http.respondJSON(
            #"{"response":{"status":"Access Denied: invalid key/password","head":{},"results":[]}}"#
        )
        do {
            _ = try await MojeekProvider(
                apiKey: "mojeek-bad-key-0001",
                http: http,
                configuration: configuration
            ).search(Fixtures.request())
            XCTFail("expected authentication failure")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .authentication)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        http.assertNoCredentialLeak("mojeek-bad-key-0001")
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

    /// Mojeek's documented quirk is HTTP 403 for a missing key, so the taxonomy uses
    /// 403 for the authentication arm rather than the generic 401.
    func testMojeekTaxonomy() async {
        await assertFailureTaxonomy(
            makeProvider: { MojeekProvider(apiKey: "k", http: $0, configuration: self.configuration) },
            provider: .mojeek,
            authenticationStatus: 403,
            rateLimitStatus: 429,
            serverErrorStatus: 503
        )
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

    /// Exa answers a missing key with 402 and an invalid one with 401; both are the
    /// authentication arm of the shared taxonomy.
    func testExaTaxonomy() async {
        await assertFailureTaxonomy(
            makeProvider: { ExaProvider(apiKey: "k", http: $0, configuration: self.configuration) },
            provider: .exa,
            authenticationStatus: 401,
            rateLimitStatus: 429,
            serverErrorStatus: 503
        )
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

    /// SearXNG's 403 means "JSON disabled" (its own quirk, asserted separately), so
    /// the taxonomy's authentication arm uses 401.
    func testSearXNGTaxonomy() async {
        await assertFailureTaxonomy(
            makeProvider: {
                SearXNGProvider(
                    baseURL: URL(string: "https://searx.example.com")!,
                    http: $0,
                    configuration: self.configuration
                )
            },
            provider: .searxng,
            authenticationStatus: 401,
            rateLimitStatus: 429,
            serverErrorStatus: 503
        )
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

    /// DuckDuckGo is a credential-free scraper, so it has no authentication case: a
    /// refusal is a transient upstream block, not a configuration problem. Every other
    /// arm of the taxonomy must still hold.
    func testDuckDuckGoTaxonomy() async {
        await assertFailureTaxonomy(
            makeProvider: {
                DuckDuckGoProvider(
                    http: $0,
                    configuration: Fixtures.configuration(enableScrapers: true),
                    scrapersEnabled: true
                )
            },
            provider: .duckDuckGo,
            authenticationStatus: 403,
            rateLimitStatus: 429,
            serverErrorStatus: 503,
            authenticationCategory: .serverError
        )
    }

    // MARK: - Startpage (scraper, opt-in)

    /// A realistic Startpage results page: both containers use the documented
    /// `w-gl__result` / `w-gl__result-title` / `w-gl__description` markup, plus one
    /// navigation link that must not be mistaken for a result.
    private static let startpageHTML = """
        <html><head><title>swift concurrency - Startpage</title></head><body>
        <header><a href="/preferences">Preferences</a></header>
        <section id="main">
          <div class="w-gl__result">
            <a class="w-gl__result-title" href="https://swift.org/documentation/concurrency/">
              Swift Concurrency Documentation</a>
            <p class="w-gl__description">Structured concurrency keeps tasks scoped.</p>
          </div>
          <div class="w-gl__result">
            <a class="w-gl__result-title" href="https://example.com/swift-actors">
              Actors and isolation in Swift</a>
            <p class="w-gl__description">How actor isolation prevents data races.</p>
          </div>
          <div class="w-gl__result">
            <a class="w-gl__result-title" href="https://www.startpage.com/sp/redirect">
              Startpage internal link</a>
            <p class="w-gl__description">Must be excluded.</p>
          </div>
        </section>
        </body></html>
        """

    private func startpageProvider(
        http: MockHTTPClient,
        recency: Recency = .any,
        locale: LocaleHint? = nil
    ) async throws -> ProviderSearchResponse {
        var request = Fixtures.request("swift concurrency")
        request.recency = recency
        request.locale = locale
        return try await StartpageProvider(
            http: http,
            configuration: Fixtures.configuration(enableScrapers: true),
            scrapersEnabled: true
        ).search(request)
    }

    func testStartpageHappyPath() async throws {
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/html; charset=utf-8"],
                body: Data(Self.startpageHTML.utf8),
                url: request.url
            )
        }
        let response = try await startpageProvider(http: http)

        assertNormalizedResults(response, provider: .startpage)
        XCTAssertEqual(response.results.count, 2, "the Startpage-internal link must be excluded")
        XCTAssertEqual(
            response.results[0].url.absoluteString,
            "https://swift.org/documentation/concurrency/"
        )
        XCTAssertTrue(
            response.results[0].snippet?.contains("Structured concurrency") ?? false
        )
        XCTAssertTrue(response.warnings.contains { $0.contains("undocumented HTML") })

        let url = try XCTUnwrap(http.requests.first?.url.absoluteString)
        XCTAssertTrue(url.contains("startpage.com/sp/search"), url)
        XCTAssertTrue(url.contains("query=swift"), url)
    }

    func testStartpageMapsRecencyAndLanguage() async throws {
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/html"],
                body: Data(Self.startpageHTML.utf8),
                url: request.url
            )
        }
        _ = try await startpageProvider(
            http: http,
            recency: .week,
            locale: LocaleHint("en-US")
        )
        let url = try XCTUnwrap(http.requests.first?.url.absoluteString)
        XCTAssertTrue(url.contains("with_date=w"), url)
        XCTAssertTrue(url.contains("language=en"), url)
    }

    /// Startpage fronts automated access with a proof-of-work interstitial; the
    /// challenge page must be reported as unavailable, never parsed as results.
    func testStartpageChallengePageIsAProviderFailure() async {
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/html"],
                body: Data(
                    "<html><body><h1>Verifying your request</h1>"
                        .appending("<p>Anubis proof of work in progress.</p></body></html>")
                        .utf8
                ),
                url: request.url
            )
        }
        do {
            _ = try await startpageProvider(http: http)
            XCTFail("a challenge page must not be parsed as results")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .serverError)
            XCTAssertTrue(error.category.isTransient)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStartpageForbiddenAndRateLimitedStatuses() async {
        for (status, category) in [(403, ProviderFailure.FailureCategory.serverError), (429, .rateLimited)] {
            let http = MockHTTPClient()
            http.onAny { request in
                HTTPResponse(statusCode: status, headers: [:], body: Data(), url: request.url)
            }
            do {
                _ = try await startpageProvider(http: http)
                XCTFail("HTTP \(status) must not yield results")
            } catch let error as SearchError {
                XCTAssertEqual(error.category, category, "HTTP \(status)")
            } catch {
                XCTFail("unexpected error for \(status): \(error)")
            }
        }
    }

    func testStartpageIsNotConfiguredWithoutTheScraperOptIn() async {
        let provider = StartpageProvider(
            http: MockHTTPClient(),
            configuration: Fixtures.configuration(),
            scrapersEnabled: false
        )
        XCTAssertFalse(provider.isConfigured)
        do {
            _ = try await provider.search(Fixtures.request())
            XCTFail("expected notConfigured")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .notConfigured)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Open Web Search (aggregator)

    private func openWebSearchProvider(
        _ json: String,
        status: Int = 200
    ) -> (OpenWebSearchProvider, MockHTTPClient) {
        let http = MockHTTPClient()
        http.respondJSON(json, status: status)
        let provider = OpenWebSearchProvider(
            endpoint: URL(string: "https://aggregator.example.com/api")!,
            http: http,
            configuration: configuration
        )
        return (provider, http)
    }

    /// The three common envelope keys and the success-envelope variant are accepted.
    func testOpenWebSearchAcceptsEveryEnvelopeShape() async throws {
        let item =
            #"{"title":"Aggregated result","url":"https://example.com/aggregated","snippet":"Text.","engine":"brave"}"#
        let shapes = [
            "results": #"{"results":[\#(item)]}"#,
            "data": #"{"data":[\#(item)]}"#,
            "items": #"{"items":[\#(item)]}"#,
            "success envelope": #"{"success":true,"results":[\#(item)]}"#,
        ]

        for (name, json) in shapes {
            let (provider, http) = openWebSearchProvider(json)
            let response = try await provider.search(Fixtures.request("aggregated"))
            assertNormalizedResults(response, provider: .openWebSearch)
            XCTAssertEqual(response.results.count, 1, name)
            XCTAssertEqual(response.upstreamEngines, ["brave"], name)

            let url = try XCTUnwrap(http.requests.first?.url.absoluteString, name)
            XCTAssertTrue(url.contains("query=aggregated"), "\(name): \(url)")
            XCTAssertTrue(url.contains("q=aggregated"), "\(name): \(url)")
            XCTAssertTrue(url.contains("limit="), "\(name): \(url)")
        }
    }

    /// A bare top-level JSON array is one of the shapes the adapter documents, and it used to
    /// fail: the response type was a synthesised `Decodable`, so only the envelope decoded and
    /// an array body was reported as a malformed response.
    func testOpenWebSearchAcceptsABareTopLevelArray() async throws {
        // The adapter documents "several common shapes"; a synthesised Decodable could only
        // read the envelope, so this body shape used to fail as a malformed response.
        let (provider, _) = openWebSearchProvider(
            #"[{"title":"Bare array","url":"https://example.com/bare","snippet":"Text."}]"#
        )
        let response = try await provider.search(Fixtures.request())
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results.first?.title, "Bare array")
        XCTAssertEqual(response.results.first?.url.absoluteString, "https://example.com/bare")
    }

    /// The wire contract is undocumented, so alternate anchor/snippet keys and unknown
    /// fields must be tolerated rather than producing junk or failing.
    func testOpenWebSearchParsesAlternateKeysDefensively() async throws {
        let (provider, _) = openWebSearchProvider(
            """
            {"data":[
              {"title":"Alt keys","link":"https://example.com/alt","description":"Alt snippet.",
               "rank":3,"engines":["duckduckgo","brave"],"score":1.5,
               "published":"2024-01-15T00:00:00Z","unknown_field":{"nested":true}},
              {"no_url_here":"ignored","title":"Dropped"}
            ]}
            """
        )
        let response = try await provider.search(Fixtures.request())
        XCTAssertEqual(response.results.count, 1, "an item without a URL must be dropped")
        let result = response.results[0]
        XCTAssertEqual(result.url.absoluteString, "https://example.com/alt")
        XCTAssertEqual(result.snippet, "Alt snippet.")
        XCTAssertEqual(result.providerRank, 3)
        XCTAssertEqual(result.providerScore, 1.5)
        XCTAssertNotNil(result.publishedAt)
        XCTAssertEqual(Set(response.upstreamEngines), Set(["duckduckgo", "brave"]))
    }

    func testOpenWebSearchTreatsAnEmptyEnvelopeAsSuccessButAnUnrecognizableBodyAsMalformed() async throws {
        // A genuinely empty query is `200 {"results":[]}`, which is not a malformed body.
        let (empty, _) = openWebSearchProvider(#"{"results":[]}"#)
        let emptyResponse = try await empty.search(Fixtures.request())
        XCTAssertTrue(emptyResponse.results.isEmpty)

        let (successOnly, _) = openWebSearchProvider(#"{"success":true}"#)
        let successOnlyResponse = try await successOnly.search(Fixtures.request())
        XCTAssertTrue(successOnlyResponse.results.isEmpty)

        // `{}` carries no recognised envelope and no success flag.
        let (unrecognizable, _) = openWebSearchProvider("{}")
        do {
            _ = try await unrecognizable.search(Fixtures.request())
            XCTFail("an unrecognizable body must fail cleanly")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .malformedResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // A wrong type inside a recognised key is malformed, not an empty success.
        let (wrongType, _) = openWebSearchProvider(#"{"results":"not an array"}"#)
        do {
            _ = try await wrongType.search(Fixtures.request())
            XCTFail("a mistyped envelope must fail cleanly")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .malformedResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOpenWebSearchTaxonomy() async {
        await assertFailureTaxonomy(
            makeProvider: {
                OpenWebSearchProvider(
                    endpoint: URL(string: "https://aggregator.example.com/api")!,
                    http: $0,
                    configuration: self.configuration
                )
            },
            provider: .openWebSearch,
            authenticationStatus: 401,
            rateLimitStatus: 429,
            serverErrorStatus: 503
        )
    }

    func testOpenWebSearchWarnsWhenUpstreamEnginesAreAbsent() async throws {
        let (provider, _) = openWebSearchProvider(
            #"{"results":[{"title":"No engines","url":"https://example.com/x"}]}"#
        )
        let response = try await provider.search(Fixtures.request())
        XCTAssertTrue(response.upstreamEngines.isEmpty)
        XCTAssertTrue(response.warnings.contains { $0.contains("upstream engines") })
    }

    // MARK: - Parallel MCP (upstream MCP client)

    /// A scripted Parallel MCP endpoint.
    ///
    /// Every Parallel message shares the `parallel.mcp` request label, so the stub
    /// dispatches on the JSON-RPC `method` in the recorded body instead.
    private func makeParallelStub(
        toolName: String = "web_search",
        announcesMaxResults: Bool = true,
        sessionID: String? = "sess-1",
        initializeStatus: Int = 200,
        toolResponse: @escaping @Sendable (Int) -> HTTPResponse
    ) -> MockHTTPClient {
        let http = MockHTTPClient()
        let properties = announcesMaxResults ? #"{"max_results":{"type":"number"}}"# : "{}"
        http.onAny { request in
            let body =
                (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) })
                as? [String: Any] ?? [:]
            let method = body["method"] as? String ?? ""
            let id = body["id"] as? Int ?? 0

            var headers = ["content-type": "application/json"]
            if let sessionID { headers["MCP-Session-Id"] = sessionID }

            switch method {
            case "initialize":
                guard initializeStatus == 200 else {
                    return HTTPResponse(
                        statusCode: initializeStatus,
                        headers: [:],
                        body: Data(),
                        url: request.url
                    )
                }
                let json =
                    #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"Parallel","version":"1.0.0"}}}"#
                return HTTPResponse(
                    statusCode: 200,
                    headers: headers,
                    body: Data(json.utf8),
                    url: request.url
                )
            case "notifications/initialized":
                return HTTPResponse(statusCode: 202, headers: [:], body: Data(), url: request.url)
            case "tools/list":
                let json =
                    #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"\#(toolName)","inputSchema":{"type":"object","properties":\#(properties)}}]}}"#
                return HTTPResponse(
                    statusCode: 200,
                    headers: headers,
                    body: Data(json.utf8),
                    url: request.url
                )
            default:
                return toolResponse(id)
            }
        }
        return http
    }

    private func parallelProvider(_ http: MockHTTPClient) -> ParallelMCPProvider {
        ParallelMCPProvider(
            endpoint: URL(string: "https://parallel.example.com/mcp")!,
            http: http,
            configuration: configuration,
            enabled: true
        )
    }

    private func rpcMethod(_ request: MockHTTPClient.Recorded) -> String {
        rpcBody(request)["method"] as? String ?? ""
    }

    private func rpcBody(_ request: MockHTTPClient.Recorded) -> [String: Any] {
        guard let body = request.body,
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func textToolResponse(_ id: Int, text: String) -> HTTPResponse {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["content": [["type": "text", "text": text]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return HTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: data,
            url: URL(string: "https://parallel.example.com/mcp")!
        )
    }

    /// The full MCP-over-HTTP handshake: initialize, notifications/initialized,
    /// tools/list discovery, then a tools/call whose text content is mapped onto
    /// normalized results.
    func testParallelMCPHandshakeDiscoveryAndToolCall() async throws {
        let toolText =
            #"{"results":[{"title":"Swift Concurrency","url":"https://example.com/swift","excerpts":["Actors isolate state.","Sendable is checked."],"publish_date":"2024-01-15T00:00:00Z"},{"title":"Other","link":"https://example.com/other","snippet":"Other snippet."}]}"#
        let http = makeParallelStub { id in
            Self.textToolResponse(id, text: toolText)
        }
        let response = try await parallelProvider(http).search(Fixtures.request("swift concurrency"))

        assertNormalizedResults(response, provider: .parallel)
        XCTAssertEqual(response.upstreamEngines, ["parallel"])
        XCTAssertEqual(response.results[0].snippet, "Actors isolate state.")
        XCTAssertNotNil(response.results[0].publishedAt)
        XCTAssertEqual(response.results[1].url.absoluteString, "https://example.com/other")
        XCTAssertEqual(response.results[1].snippet, "Other snippet.")

        // Exact JSON-RPC sequence.
        XCTAssertEqual(
            http.requests.map(rpcMethod),
            ["initialize", "notifications/initialized", "tools/list", "tools/call"]
        )

        // The session id issued by initialize is echoed on every later message, and the
        // request that creates the session must not carry one.
        XCTAssertNil(http.requests[0].headers["MCP-Session-Id"])
        XCTAssertEqual(http.requests[1].headers["MCP-Session-Id"], "sess-1")
        XCTAssertEqual(http.requests[3].headers["MCP-Session-Id"], "sess-1")

        let initialize = rpcBody(http.requests[0])
        let initializeParams = try XCTUnwrap(initialize["params"] as? [String: Any])
        XCTAssertEqual(initializeParams["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil(initializeParams["clientInfo"])

        let call = rpcBody(http.requests[3])
        let callParams = try XCTUnwrap(call["params"] as? [String: Any])
        XCTAssertEqual(callParams["name"] as? String, "web_search")
        let arguments = try XCTUnwrap(callParams["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["objective"] as? String, "swift concurrency")
        XCTAssertEqual(arguments["search_queries"] as? [String], ["swift concurrency"])
        XCTAssertNotNil(arguments["session_id"] as? String)
        XCTAssertEqual(arguments["model_name"] as? String, "SwiftWebSearchMCP")
        XCTAssertEqual(
            arguments["max_results"] as? Int,
            Fixtures.request("swift concurrency").providerResultBudget
        )
    }

    /// The transport may answer with pre-formatted Server-Sent Events; the last
    /// complete JSON-RPC object on the stream is the response.
    func testParallelMCPAcceptsAnSSEResponse() async throws {
        let http = makeParallelStub { id in
            let envelope: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "structuredContent": [
                        "results": [
                            [
                                "title": "SSE result",
                                "url": "https://example.com/sse",
                                "excerpts": ["Rendered remotely."],
                            ]
                        ]
                    ]
                ],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
            let json = String(decoding: data, as: UTF8.self)
            let sse = "event: message\ndata: \(json)\n\n"
            return HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/event-stream"],
                body: Data(sse.utf8),
                url: URL(string: "https://parallel.example.com/mcp")!
            )
        }
        let response = try await parallelProvider(http).search(Fixtures.request("sse"))

        assertNormalizedResults(response, provider: .parallel)
        XCTAssertEqual(response.results[0].url.absoluteString, "https://example.com/sse")
        XCTAssertEqual(response.results[0].snippet, "Rendered remotely.")
    }

    /// `max_results` is only sent when the discovered tool actually declares it.
    func testParallelMCPOmitsMaxResultsWhenTheToolDoesNotDeclareIt() async throws {
        let http = makeParallelStub(toolName: "search", announcesMaxResults: false) { id in
            Self.textToolResponse(id, text: #"{"results":[{"title":"A","url":"https://example.com/a"}]}"#)
        }
        _ = try await parallelProvider(http).search(Fixtures.request())

        let call = rpcBody(http.requests[3])
        let callParams = try XCTUnwrap(call["params"] as? [String: Any])
        XCTAssertEqual(callParams["name"] as? String, "search")
        let arguments = try XCTUnwrap(callParams["arguments"] as? [String: Any])
        XCTAssertNil(arguments["max_results"])
    }

    /// A server that exposes no preferred name still gets discovered by the
    /// `search` substring fallback.
    func testParallelMCPDiscoversANonPreferredSearchTool() async throws {
        let http = makeParallelStub(toolName: "custom_web_search", announcesMaxResults: false) { id in
            Self.textToolResponse(id, text: #"{"results":[{"title":"A","url":"https://example.com/a"}]}"#)
        }
        _ = try await parallelProvider(http).search(Fixtures.request())
        let call = rpcBody(http.requests[3])
        XCTAssertEqual((call["params"] as? [String: Any])?["name"] as? String, "custom_web_search")
    }

    /// A JSON-RPC error on `tools/call` maps to the shared taxonomy: an unknown tool
    /// is a configuration problem while any other error is a provider failure.
    func testParallelMCPMapsJSONRPCErrors() async {
        for (code, category) in [(-32601, ProviderFailure.FailureCategory.unsupportedRequest), (-32603, .serverError)] {
            let http = makeParallelStub { id in
                let envelope: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": ["code": code, "message": "boom"],
                ]
                let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: data,
                    url: URL(string: "https://parallel.example.com/mcp")!
                )
            }
            do {
                _ = try await parallelProvider(http).search(Fixtures.request())
                XCTFail("error \(code) must not produce results")
            } catch let error as SearchError {
                XCTAssertEqual(error.category, category, "error \(code)")
            } catch {
                XCTFail("unexpected error for \(code): \(error)")
            }
        }
    }

    func testParallelMCPTransportStatusesMapToTheSharedTaxonomy() async {
        for (status, category) in [
            (401, ProviderFailure.FailureCategory.authentication),
            (403, .authentication),
            (429, .rateLimited),
            (503, .serverError),
        ] {
            let http = makeParallelStub(initializeStatus: status) { id in
                Self.textToolResponse(id, text: "{}")
            }
            do {
                _ = try await parallelProvider(http).search(Fixtures.request())
                XCTFail("HTTP \(status) must not produce results")
            } catch let error as SearchError {
                XCTAssertEqual(error.category, category, "HTTP \(status)")
            } catch {
                XCTFail("unexpected error for \(status): \(error)")
            }
        }
    }

    /// A body that is not JSON at all must fail cleanly rather than being parsed.
    func testParallelMCPMalformedToolResultFailsCleanly() async {
        let http = makeParallelStub { _ in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain"],
                body: Data("<html>not json</html>".utf8),
                url: URL(string: "https://parallel.example.com/mcp")!
            )
        }
        do {
            _ = try await parallelProvider(http).search(Fixtures.request())
            XCTFail("a non-JSON body must fail cleanly")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .malformedResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testParallelMCPExtractJSONHandlesBareAndSSEFramings() {
        XCTAssertEqual(ParallelMCPProvider.extractJSON(from: #"  {"a":1}  "#), #"{"a":1}"#)
        XCTAssertEqual(
            ParallelMCPProvider.extractJSON(from: "event: message\ndata: {\"a\":1}\n\ndata: {\"b\":2}\n\n"),
            #"{"b":2}"#
        )
        // Nothing recognizable is returned unchanged so the caller fails cleanly.
        XCTAssertEqual(ParallelMCPProvider.extractJSON(from: "<html>"), "<html>")
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
