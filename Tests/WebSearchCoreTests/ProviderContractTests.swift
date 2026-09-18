import Foundation
import XCTest

@testable import WebSearchCore

final class ProviderContractTests: XCTestCase {

    let configuration = Fixtures.configuration()

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Assert the shared success contract for any provider.
    func assertNormalizedResults(
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
    func assertFailureTaxonomy(
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

}
