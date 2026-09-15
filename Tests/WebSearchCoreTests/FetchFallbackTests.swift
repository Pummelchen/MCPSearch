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
        // The URL left the machine, so the caller must be told which third party fetched it
        // (ledger B87). `reader.invalid` stands in for `r.jina.ai` here.
        XCTAssertTrue(
            result.warnings.contains {
                $0.contains("third-party") && $0.contains("reader.invalid")
            },
            "the reader result must disclose the third-party remote fetch: \(result.warnings)"
        )
        let request = try XCTUnwrap(jinaHTTP.requests.first)
        XCTAssertEqual(request.label, "jina.reader")
        XCTAssertTrue(request.url.absoluteString.contains("reader.invalid"))
    }

    /// A reader that fails must not lose the native extraction, and must say so.
    ///
    /// The fallback chain's last arm — the reader threw, but the native fetch produced *something*
    /// — had no test: the existing reader-failure tests all start from a direct fetch that
    /// returned nothing. A regression here would either drop a serviceable page or hide that the
    /// reader was consulted at all (ledger B33).
    func testAReaderFailureReturnsTheThinNativeExtractionWithAWarning() async throws {
        let server = try htmlServer(thinHTML())
        let jinaHTTP = MockHTTPClient()
        jinaHTTP.on("jina.reader") { _ in
            throw HTTPError.connectionFailed(label: "jina.reader", reason: "reader is down")
        }
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: true),
            jina: jinaFetcher(jinaHTTP),
            log: .disabled
        )

        let result = try await fetcher.open(FetchRequest(url: server.baseURL))

        XCTAssertEqual(result.method, .htmlExtraction, "the native extraction is what we have")
        XCTAssertEqual(result.title, "Thin")
        XCTAssertTrue(result.text.contains("Short."), result.text)
        XCTAssertTrue(
            result.warnings.contains { $0.contains("Jina Reader fallback was unavailable") },
            "the reader failure must be visible to the caller: \(result.warnings)"
        )
        XCTAssertFalse(
            result.warnings.contains { $0.contains("used Jina Reader instead") },
            "a failed reader was not used: \(result.warnings)"
        )
        XCTAssertEqual(jinaHTTP.requests(label: "jina.reader").count, 1, "the reader was tried once")
    }

    /// When the reader fails and the native fetch failed too, the caller sees the *direct*
    /// reason — a DNS failure or a refused connection, not a generic extraction failure.
    func testAReaderFailureWithNoNativeResultSurfacesTheDirectError() async throws {
        let server = try LoopbackServer(responses: [.init(status: 503, body: "unavailable")])
        let jinaHTTP = MockHTTPClient()
        jinaHTTP.on("jina.reader") { _ in
            throw HTTPError.connectionFailed(label: "jina.reader", reason: "reader is down")
        }
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: true),
            jina: jinaFetcher(jinaHTTP),
            log: .disabled
        )

        do {
            _ = try await fetcher.open(FetchRequest(url: server.baseURL))
            XCTFail("expected both paths to fail")
        } catch let error as SearchError {
            guard case .fetchFailed(let url, let reason) = error else {
                return XCTFail("the direct failure must surface, got \(error)")
            }
            XCTAssertEqual(url, server.baseURL)
            XCTAssertTrue(reason.contains("503"), reason)
        }
    }

    /// The reader is consulted even when the direct fetch failed outright. That path returned
    /// the reader's text with no warning at all, so the caller was never told which third party
    /// had fetched the URL (ledger B87).
    func testAReaderSuccessAfterADirectFailureStillDisclosesTheThirdParty() async throws {
        let server = try LoopbackServer(responses: [.init(status: 503, body: "unavailable")])
        let jinaHTTP = MockHTTPClient()
        let rendered = renderedText()
        jinaHTTP.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain; charset=utf-8"],
                body: Data(rendered.utf8),
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
        XCTAssertTrue(
            result.warnings.contains {
                $0.contains("third-party") && $0.contains("reader.invalid")
            },
            "a reader fetch must disclose the third party on every path: \(result.warnings)"
        )
    }

    /// A PDF is not text. It used to be on the allow-list, so the body was decoded as UTF-8 or
    /// Latin-1 and handed to the model as tens of thousands of characters of `%PDF-1.7 … stream`
    /// gibberish labelled `raw_text`. There is no PDF extraction here, so the direct fetch must
    /// refuse it — and the reader fallback, which renders PDFs remotely, still serves it
    /// (ledger B16).
    func testAPDFIsRefusedByTheDirectFetchButStillReadableByTheReader() async throws {
        // The first bytes of a real PDF, plus a NUL and a high byte: not decodable as text.
        var pdfBytes = Data("%PDF-1.7\n1 0 obj<</Type/Catalog>>stream\n".utf8)
        pdfBytes.append(contentsOf: [0x00, 0x80, 0xFF, 0x0A])
        pdfBytes.append(contentsOf: Data("endstream endobj\n%%EOF\n".utf8))
        // Latin-1 maps every byte, so the body survives the String-typed test server intact
        // enough to be a binary body under a PDF content type.
        let body = try XCTUnwrap(String(bytes: pdfBytes, encoding: .isoLatin1))
        XCTAssertTrue(body.hasPrefix("%PDF-"), "the fixture must look like a PDF")
        let server = try LoopbackServer(responses: [
            LoopbackServer.Response(
                status: 200,
                headers: ["Content-Type": "application/pdf"],
                body: body
            )
        ])

        // Direct: refused, rather than returned as mojibake.
        do {
            let result = try await directFetcher(allowPrivateNetwork: true).fetch(
                FetchRequest(url: server.baseURL),
                maxRedirects: 2,
                allowedContentTypePrefixes: WebFetcher.Policy().allowedContentTypePrefixes,
                maxCharacters: 12_000
            )
            XCTFail(
                "a PDF must not be returned as text: \(result.method.rawValue), "
                    + "\(result.text.count) characters"
            )
        } catch let error as SearchError {
            guard case .extractionFailed = error else {
                return XCTFail("expected extractionFailed for a PDF, got \(error)")
            }
        }

        // The reader renders PDFs remotely, so a configured reader still gets the document.
        let jinaHTTP = MockHTTPClient()
        let rendered = renderedText()
        jinaHTTP.on("jina.reader") { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain; charset=utf-8"],
                body: Data("Title: Rendered PDF\n\n\(rendered)".utf8),
                url: request.url
            )
        }
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: true),
            jina: jinaFetcher(jinaHTTP),
            log: .disabled
        )
        let viaReader = try await fetcher.open(FetchRequest(url: server.baseURL))
        XCTAssertEqual(viaReader.method, .jinaReader)
        XCTAssertTrue(viaReader.text.contains("Rendered by the reader"))
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

    /// A server that dribbles bytes and never finishes must not hold `web_open` open. The
    /// per-request inactivity timeouts never fire on a drip, and there was no total deadline,
    /// so the call could hang forever (ledger B14).
    func testAFetchThatNeverFinishesHitsTheTotalDeadline() async throws {
        let server = try LoopbackServer(responses: [
            LoopbackServer.Response(
                status: 200,
                headers: ["Content-Type": "text/html"],
                // Declares 40 MB, sends 64 KB, then holds the connection for five seconds.
                body: String(repeating: "A", count: 64 * 1024),
                delayMilliseconds: 0,
                drip: .init(
                    chunkBytes: 64 * 1024,
                    pauseMilliseconds: 0,
                    holdOpenSeconds: 5,
                    declaredBytes: 40 * 1024 * 1024
                )
            )
        ])
        // A 400 ms deadline against a five-second hold: the test would take five seconds
        // without the fix, and the error would be the transport's rather than a deadline's.
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: true),
            policy: WebFetcher.Policy(totalTimeout: .milliseconds(400)),
            log: .disabled
        )

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let result = try await fetcher.open(FetchRequest(url: server.baseURL))
            XCTFail("a fetch that never finishes must not return content: \(result.text.count) chars")
        } catch let error as SearchError {
            guard case .fetchFailed(let url, let reason) = error else {
                return XCTFail("expected fetchFailed from the deadline, got \(error)")
            }
            XCTAssertEqual(url, server.baseURL)
            XCTAssertTrue(reason.contains("did not finish"), reason)
        }
        let elapsedMilliseconds = Int(
            (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        )
        XCTAssertLessThan(
            elapsedMilliseconds,
            3_000,
            "the deadline must cut the call off, not the server's five-second hold"
        )
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

    /// The reader's JSON envelope carries the URL it handled, and `final_url` must follow it
    /// rather than echoing the request (ledger B92).
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
    /// URL is the only trustworthy fallback (ledger B92).
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
