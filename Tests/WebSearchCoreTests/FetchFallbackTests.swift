import Foundation
import XCTest

@testable import WebSearchCore

/// The fetch fallback chain and the Jina Reader adapter.
///
/// `FetchBehaviorTests` covers `DirectHTTPFetcher`'s own HTTP status handling. These
/// tests cover the decision *above* it: when native extraction is good enough, when the
/// reader is consulted because the native text was too thin, when configuration
/// disables the reader, and the guarantee that an SSRF denial is never laundered
/// through a second fetch path.
final class FetchFallbackTests: XCTestCase {

    private let configuration = Fixtures.configuration()

    private func directFetcher(allowPrivateNetwork: Bool) -> DirectHTTPFetcher {
        // The loopback test server is on 127.0.0.1, which the SSRF policy refuses by
        // design; the opt-in is what makes it reachable, exactly as in
        // `FetchBehaviorTests`.
        DirectHTTPFetcher(
            configuration: configuration,
            policy: URLPolicy(allowPrivateNetwork: allowPrivateNetwork),
            log: .disabled
        )
    }

    private func jinaFetcher(_ http: MockHTTPClient) -> JinaReaderFetcher {
        // A key is always supplied so the unauthenticated 1-second politeness delay is
        // never taken: no test in this suite may sleep for more than 50 ms.
        JinaReaderFetcher(
            baseURL: URL(string: "https://reader.invalid/")!,
            apiKey: "jina-test-key",
            http: http,
            configuration: configuration,
            log: .disabled
        )
    }

    private func longHTML(_ marker: String) -> String {
        let body = String(
            repeating: "\(marker) structured concurrency keeps tasks scoped. ",
            count: 40
        )
        return """
            <html><head><title>\(marker)</title></head>
            <body><nav>menu</nav><article><h1>\(marker)</h1><p>\(body)</p></article>
            <footer>footer</footer></body></html>
            """
    }

    private func thinHTML() -> String {
        "<html><head><title>Thin</title></head><body><article><p>Short.</p></article></body></html>"
    }

    private func htmlServer(_ html: String) throws -> LoopbackServer {
        try LoopbackServer(responses: [
            .init(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: html
            )
        ])
    }

    /// Text long enough to satisfy any `minimumUsefulCharacters`.
    private func renderedText() -> String {
        String(repeating: "Rendered by the reader with plenty of text. ", count: 30)
    }

    // MARK: - WebFetcher fallback

    func testNativeExtractionSucceedsWithoutConsultingTheReader() async throws {
        let server = try htmlServer(longHTML("Native"))
        let jinaHTTP = MockHTTPClient()  // no handler: any call would fail loudly
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: true),
            jina: jinaFetcher(jinaHTTP),
            log: .disabled
        )

        let result = try await fetcher.open(FetchRequest(url: server.baseURL))

        XCTAssertEqual(result.method, .htmlExtraction)
        XCTAssertEqual(result.title, "Native")
        XCTAssertTrue(result.text.lowercased().contains("structured concurrency"))
        XCTAssertTrue(
            jinaHTTP.requests.isEmpty,
            "a good native extraction must not spend a reader call"
        )
    }

    func testThinNativeExtractionFallsBackToTheReader() async throws {
        let server = try htmlServer(thinHTML())
        let jinaHTTP = MockHTTPClient()
        let rendered = renderedText()
        jinaHTTP.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain; charset=utf-8"],
                body: Data("Title: Reader Rendered\n\n\(rendered)".utf8),
                url: request.url
            )
        }
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: true),
            jina: jinaFetcher(jinaHTTP),
            log: .disabled
        )

        let result = try await fetcher.open(FetchRequest(url: server.baseURL))

        XCTAssertEqual(result.method, .jinaReader)
        XCTAssertEqual(result.title, "Reader Rendered")
        XCTAssertTrue(result.text.contains("Rendered by the reader"))
        XCTAssertTrue(
            result.warnings.contains { $0.contains("Native extraction produced only") },
            "\(result.warnings)"
        )
        let request = try XCTUnwrap(jinaHTTP.requests.first)
        XCTAssertEqual(request.label, "jina.reader")
        XCTAssertTrue(request.url.absoluteString.contains("reader.invalid"))
    }

    /// The reader is asked for the *target* URL appended verbatim. `appendingPathComponent`
    /// percent-encoded `?` and `#` into the path, so a URL with a query reached the reader as
    /// `/page%3Fq=…` — a different resource, usually a 404 (ledger B15).
    func testTheReaderIsGivenTheTargetURLVerbatim() async throws {
        let server = try htmlServer(thinHTML())
        let jinaHTTP = MockHTTPClient()
        let rendered = renderedText()
        jinaHTTP.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain; charset=utf-8"],
                body: Data("Title: Verbatim\n\n\(rendered)".utf8),
                url: request.url
            )
        }
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: true),
            jina: jinaFetcher(jinaHTTP),
            log: .disabled
        )

        let target = try XCTUnwrap(
            URL(string: server.baseURL.absoluteString + "page?q=swift+concurrency&lang=en#results")
        )
        _ = try await fetcher.open(FetchRequest(url: target))

        let request = try XCTUnwrap(jinaHTTP.requests.first)
        let readerURL = request.url.absoluteString
        XCTAssertTrue(readerURL.hasPrefix("https://reader.invalid/"), readerURL)
        XCTAssertTrue(
            readerURL.contains("page?q=swift+concurrency&lang=en"),
            "the query must reach the reader intact: \(readerURL)"
        )
        XCTAssertFalse(
            readerURL.contains("%3F"),
            "the query must not be percent-encoded into the path: \(readerURL)"
        )
        XCTAssertFalse(readerURL.contains("%23"), "nor the fragment: \(readerURL)")
    }

    /// `SEARCH_ENABLE_JINA_READER=false` reaches `WebFetcher` as `jina: nil`, so a thin
    /// page is returned as-is with a warning rather than silently spending a reader call.
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
