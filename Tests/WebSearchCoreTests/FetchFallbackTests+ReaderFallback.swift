import Foundation
import XCTest
@testable import WebSearchCore

extension FetchFallbackTests {

    func testReaderDisabledReturnsTheThinNativeExtractionWithAWarning() async throws {
        let server = try htmlServer(thinHTML())
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: true),
            jina: nil,
            log: .disabled
        )

        let result = try await fetcher.open(FetchRequest(url: server.baseURL))

        XCTAssertEqual(result.method, .htmlExtraction)
        XCTAssertTrue(
            result.warnings.contains { $0.contains("require JavaScript rendering") },
            "\(result.warnings)"
        )
    }

    /// The flag is actually wired through the composition root, so a regression in
    /// `SearchPipelineFactory` is caught rather than just in `WebFetcher`.
    func testSearchPipelineFactoryHonoursTheJinaReaderFlag() async throws {
        let server = try htmlServer(thinHTML())

        // Disabled: the factory must not even construct a reader, so no Jina traffic.
        let disabledHTTP = MockHTTPClient()
        let disabledPipeline = SearchPipelineFactory.make(
            configuration: AppConfiguration.parse([
                "SEARCH_ALLOW_PRIVATE_NETWORK": "true",
                "SEARCH_ENABLE_JINA_READER": "false",
                "JINA_API_KEY": "jina-test-key",
            ]),
            http: disabledHTTP,
            log: .disabled
        )
        let disabledResult = try await disabledPipeline.fetcher.open(
            FetchRequest(url: server.baseURL)
        )
        XCTAssertNotEqual(disabledResult.method, .jinaReader)
        XCTAssertTrue(
            disabledHTTP.requests.isEmpty,
            "SEARCH_ENABLE_JINA_READER=false must disable the reader entirely"
        )

        // Enabled (the default): the same page is rendered by the reader.
        let enabledHTTP = MockHTTPClient()
        let rendered = renderedText()
        enabledHTTP.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain"],
                body: Data(rendered.utf8),
                url: request.url
            )
        }
        let enabledPipeline = SearchPipelineFactory.make(
            configuration: AppConfiguration.parse([
                "SEARCH_ALLOW_PRIVATE_NETWORK": "true",
                "JINA_API_KEY": "jina-test-key",
            ]),
            http: enabledHTTP,
            log: .disabled
        )
        let enabledResult = try await enabledPipeline.fetcher.open(
            FetchRequest(url: server.baseURL)
        )
        XCTAssertEqual(enabledResult.method, .jinaReader)
        XCTAssertFalse(enabledHTTP.requests.isEmpty)
    }

    /// A blocked URL is an active policy decision, so it must never be retried through
    /// the reader — doing so would defeat the SSRF boundary.
    func testBlockedURLIsNeverRetriedThroughTheReader() async throws {
        let server = try htmlServer(thinHTML())
        let jinaHTTP = MockHTTPClient()
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: false),
            jina: jinaFetcher(jinaHTTP),
            log: .disabled
        )

        do {
            _ = try await fetcher.open(FetchRequest(url: server.baseURL))
            XCTFail("a policy denial must throw")
        } catch let error as SearchError {
            guard case .blockedURL = error else {
                return XCTFail("expected blockedURL, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(
            jinaHTTP.requests.isEmpty,
            "an SSRF denial must never be laundered through the reader fallback"
        )
    }

    // MARK: - JinaReaderFetcher

    private func fetchThroughReader(
        _ http: MockHTTPClient,
        url: URL = URL(string: "https://example.com/page")!,
        maxCharacters: Int = 12_000
    ) async throws -> FetchResult {
        try await jinaFetcher(http).fetch(
            FetchRequest(url: url, maxCharacters: maxCharacters),
            maxCharacters: maxCharacters
        )
    }

    func testReaderParsesMarkdownTitleAndBody() async throws {
        let http = MockHTTPClient()
        http.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain; charset=utf-8"],
                body: Data(
                    """
                    Title: Swift Concurrency

                    URL Source: https://swift.org

                    Markdown Content:
                    Body text here.
                    """.utf8
                ),
                url: request.url
            )
        }

        let result = try await fetchThroughReader(http)

        XCTAssertEqual(result.method, .jinaReader)
        XCTAssertEqual(result.title, "Swift Concurrency")
        XCTAssertTrue(result.text.contains("Body text here."))
        XCTAssertEqual(result.finalURL.absoluteString, "https://example.com/page")

        let request = try XCTUnwrap(http.requests.first)
        // Markdown is what a model's context wants, and the key authenticates by header
        // (never a query parameter).
        XCTAssertEqual(request.headers["X-Return-Format"], "markdown")
        XCTAssertEqual(request.headers["Authorization"], "Bearer jina-test-key")
        XCTAssertFalse(request.url.absoluteString.contains("jina-test-key"))
    }

    func testReaderParsesTheJSONEnvelope() async throws {
        let http = MockHTTPClient()
        http.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(
                    """
                    {"code":200,"status":"ok","data":{"title":"JSON Title",
                     "url":"https://example.com/page","content":"Envelope body."}}
                    """.utf8
                ),
                url: request.url
            )
        }

        let result = try await fetchThroughReader(http)

        XCTAssertEqual(result.title, "JSON Title")
        XCTAssertEqual(result.text, "Envelope body.")
    }

    /// The reader's JSON envelope carries the URL it handled, and `final_url` must follow it
    /// rather than echoing the request.
    func testReaderJSONEnvelopeURLBecomesFinalURL() async throws {
        let http = MockHTTPClient()
        http.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(
                    #"{"code":200,"status":"ok","data":{"title":"Resolved","url":"https://example.com/resolved","content":"Envelope body."}}"#
                        .utf8
                ),
                url: request.url
            )
        }

        let result = try await fetchThroughReader(http)

        XCTAssertEqual(result.finalURL.absoluteString, "https://example.com/resolved")
    }

    /// A reported URL that is absent, relative or not `http(s)` must not become `final_url`.
    /// The field is third-party input rendered verbatim as the fetched URL, so the requested
    /// URL is the only trustworthy fallback.
    func testReaderFallsBackToTheRequestedURLWhenTheReportedURLIsUnusable() async throws {
        let unusable: [String?] = [
            nil, "", "example.com/page", "//example.com/page",
            "file:///etc/hosts", "javascript:alert(1)", "https://",
        ]
        for reported in unusable {
            let http = MockHTTPClient()
            let urlField = reported.map { "\"url\":\"\($0)\"," } ?? ""
            http.on("jina.reader") { request in
                HTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: Data(
                        #"{"code":200,"status":"ok","data":{\#(urlField)"title":"T","content":"Body."}}"#
                            .utf8
                    ),
                    url: request.url
                )
            }

            let result = try await fetchThroughReader(http)

            XCTAssertEqual(
                result.finalURL.absoluteString,
                "https://example.com/page",
                "reported \(reported ?? "nil") must fall back to the requested URL"
            )
        }
    }

    func testReader429ReportsTheBodyRetryDelayAsAFetchFailure() async {
        let http = MockHTTPClient()
        http.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 429,
                headers: ["content-type": "application/json"],
                body: Data(#"{"retryAfter":2}"#.utf8),
                url: request.url
            )
        }

        do {
            _ = try await fetchThroughReader(http)
            XCTFail("expected a rate-limit failure")
        } catch let error as SearchError {
            guard case .fetchFailed(_, let reason) = error else {
                return XCTFail("expected fetchFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("rate limited"), reason)
            // The JSON body is authoritative over the header and is reported in ms.
            XCTAssertTrue(reason.contains("2000 ms"), reason)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReaderRejectionIsAFetchFailureAndNamesNoSearchProvider() async {
        let http = MockHTTPClient()
        http.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 401,
                headers: [:],
                body: Data(),
                url: request.url
            )
        }

        do {
            _ = try await fetchThroughReader(http)
            XCTFail("expected a fetch failure")
        } catch let error as SearchError {
            guard case .fetchFailed = error else {
                return XCTFail("expected fetchFailed, got \(error)")
            }
            XCTAssertTrue(error.safeDescription.contains("HTTP 401"), error.safeDescription)
            for name in ["Tavily", "Brave", "Mojeek", "Exa", "SearXNG", "Parallel"] {
                XCTAssertFalse(
                    error.safeDescription.contains(name),
                    "reader failure wrongly mentioned \(name): \(error.safeDescription)"
                )
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReaderEmptyBodyIsAnExtractionFailure() async {
        let http = MockHTTPClient()
        http.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain"],
                body: Data("   \n  \n".utf8),
                url: request.url
            )
        }

        do {
            _ = try await fetchThroughReader(http)
            XCTFail("an empty reader body must not become an empty success")
        } catch let error as SearchError {
            guard case .extractionFailed = error else {
                return XCTFail("expected extractionFailed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReaderTruncatesToTheCharacterBudget() async throws {
        let http = MockHTTPClient()
        http.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain"],
                body: Data("Title: Long\n\n\(String(repeating: "word ", count: 200))".utf8),
                url: request.url
            )
        }

        let result = try await fetchThroughReader(http, maxCharacters: 100)

        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.text.count, 100)
        XCTAssertTrue(
            result.warnings.contains { $0.contains("truncated to 100") },
            "\(result.warnings)"
        )
    }
}
