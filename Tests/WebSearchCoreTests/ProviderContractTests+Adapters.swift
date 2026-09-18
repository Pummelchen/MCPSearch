import Foundation
import XCTest
@testable import WebSearchCore

extension ProviderContractTests {

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

    func startpageProvider(
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

}
