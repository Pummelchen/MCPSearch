import Foundation
import XCTest

@testable import WebSearchCore

final class FetchFallbackTests: XCTestCase {

    let configuration = Fixtures.configuration()

    func directFetcher(allowPrivateNetwork: Bool) -> DirectHTTPFetcher {
        // The loopback test server is on 127.0.0.1, which the SSRF policy refuses by
        // design; the opt-in is what makes it reachable, exactly as in
        // `FetchBehaviorTests`.
        DirectHTTPFetcher(
            configuration: configuration,
            policy: URLPolicy(allowPrivateNetwork: allowPrivateNetwork),
            log: .disabled
        )
    }

    func jinaFetcher(_ http: MockHTTPClient) -> JinaReaderFetcher {
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

    func thinHTML() -> String {
        "<html><head><title>Thin</title></head><body><article><p>Short.</p></article></body></html>"
    }

    func htmlServer(_ html: String) throws -> LoopbackServer {
        try LoopbackServer(responses: [
            .init(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: html
            )
        ])
    }

    /// Text long enough to satisfy any `minimumUsefulCharacters`.
    func renderedText() -> String {
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

    /// An extraction that produced no text is a failure, not a success carrying nothing.
    ///
    /// The fallback returned `directResult` whenever it existed, including when its text was empty —
    /// which is what a script-only document, a JS-only page or an empty `text/plain` body produces.
    /// `web_open` then reported success with `text_characters: 0` and the real reason was discarded,
    /// so a caller could not tell "this page has no text" from "every extraction path failed"
    /// .
    func testAnEmptyExtractionIsAFailureRatherThanASuccess() async throws {
        let server = try htmlServer(
            "<html><head><title>Script only</title></head>"
                + "<body><script>var x = 1;</script></body></html>"
        )
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: true),
            jina: nil,
            log: .disabled
        )

        do {
            let result = try await fetcher.open(FetchRequest(url: server.baseURL))
            XCTFail(
                "an extraction with no text must not be reported as success "
                    + "(\(result.text.count) characters)"
            )
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .malformedResponse, "\(error)")
        }
    }

    /// A page served in a non-UTF-8 charset must reach the extractor as the right characters.
    ///
    /// `mimeType(from:)` keeps only the part before `;`, so the `charset` parameter was discarded and
    /// the body fell straight to UTF-8-then-Latin-1. Latin-1 cannot fail, so a windows-1251 page was
    /// silently decoded into mojibake: wrong characters presented as success, with no warning and no
    /// truncation flag. This drives the whole fetch, not the decoder, so it can show the before-state
    /// .
    func testAPageInADeclaredNonUTF8CharsetIsDecodedCorrectly() async throws {
        let greeting = "Привет мир"
        let html = "<html><head><title>Кодировка</title></head><body><p>\(greeting)</p></body></html>"
        let body = try XCTUnwrap(html.data(using: .windowsCP1251))
        let server = try LoopbackServer(responses: [
            .init(
                status: 200,
                headers: ["Content-Type": "text/html; charset=windows-1251"],
                body: "",
                bodyData: body
            )
        ])
        let fetcher = directFetcher(allowPrivateNetwork: true)

        let result = try await fetcher.fetch(
            FetchRequest(url: server.baseURL),
            maxRedirects: 5,
            allowedContentTypePrefixes: ["text/"],
            maxCharacters: 12_000
        )

        XCTAssertTrue(result.text.contains(greeting), "expected \(greeting) in: \(result.text)")
        XCTAssertFalse(result.text.contains("Ð"), "the body was decoded as Latin-1: \(result.text)")
    }

    /// A cancelled caller must see the cancellation, not a fallback result.
    ///
    /// The broad catch on the reader path turned `CancellationError` into "the reader was
    /// unavailable; here is the native extraction", so a caller that had already gone away received a
    /// successful-looking result and the cancellation was absorbed — the work it reports on was done
    /// for nobody.
    func testACancelledReaderIsNotTurnedIntoAFallbackResult() async throws {
        let server = try htmlServer(thinHTML())
        let jinaHTTP = MockHTTPClient()
        jinaHTTP.on("jina.reader") { _ in throw CancellationError() }
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: true),
            jina: jinaFetcher(jinaHTTP),
            log: .disabled
        )

        do {
            let result = try await fetcher.open(FetchRequest(url: server.baseURL))
            XCTFail("a cancelled fetch returned \(result.method) instead of propagating")
        } catch {
            // The cancellation may arrive wrapped; what must not happen is a returned result.
            XCTAssertTrue(
                error is CancellationError || "\(error)".lowercased().contains("cancel"),
                "expected a cancellation, got \(error)"
            )
        }
    }

    /// A target URL carrying a credential must not be handed to the third-party reader.
    ///
    /// The reader takes the target URL verbatim, so everything in it goes to `r.jina.ai` — a service
    /// this repository does not control and that necessarily logs what it fetches. The existing
    /// thin-page test is the positive control: with an ordinary URL the reader *is* consulted, so
    /// this test's empty request list is the fix and not a broken fixture.
    func testACredentialBearingURLIsNotForwardedToTheReader() async throws {
        let server = try htmlServer(thinHTML())
        let jinaHTTP = MockHTTPClient()
        jinaHTTP.respondJSON(#"{"data":"rendered"}"#)
        let fetcher = WebFetcher(
            direct: directFetcher(allowPrivateNetwork: true),
            jina: jinaFetcher(jinaHTTP),
            log: .disabled
        )
        let url = try XCTUnwrap(
            URL(string: server.baseURL.absoluteString + "?token=super-secret-value")
        )

        let result = try await fetcher.open(FetchRequest(url: url))

        XCTAssertTrue(
            jinaHTTP.requests.isEmpty,
            "the reader was consulted with a credential in the URL: "
                + "\(jinaHTTP.requests.map(\.url.absoluteString))"
        )
        XCTAssertEqual(result.method, .htmlExtraction)
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
        // The URL left the machine, so the caller must be told which third party fetched it.
        // `reader.invalid` stands in for `r.jina.ai` here.
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
    /// reader was consulted at all.
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
    /// had fetched the URL.
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
    /// `/page%3Fq=…` — a different resource, usually a 404.
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
    /// so the call could hang forever.
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
}
