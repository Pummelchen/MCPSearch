import Foundation
import XCTest

@testable import WebSearchCore

/// `web_open`'s direct fetch path, exercised against a real socket.
///
/// These tests exist because the HTTP status path was the hole left after the earlier
/// attribution fix: only a DNS failure was covered, so `web_open` could still report an
/// HTTP 403 on an unrelated page as a Tavily network failure. There was also no test at
/// all for a fetch that succeeds.
final class FetchBehaviorTests: XCTestCase {

    private func makeFetcher() -> DirectHTTPFetcher {
        // The loopback test server is on 127.0.0.1, which the SSRF policy refuses by
        // design. The opt-in is what makes it reachable, exactly as it would be for a
        // deliberately internal deployment.
        DirectHTTPFetcher(
            configuration: Fixtures.configuration(),
            policy: URLPolicy(allowPrivateNetwork: true),
            log: .disabled
        )
    }

    private func fetch(_ server: LoopbackServer) async throws -> FetchResult {
        try await makeFetcher().fetch(
            FetchRequest(url: server.baseURL),
            maxRedirects: 5,
            allowedContentTypePrefixes: ["text/", "application/json"],
            maxCharacters: 12_000
        )
    }

    /// A textual body that is not HTML is returned as raw text: no title, the bytes as sent.
    ///
    /// The branch existed untested, so nothing pinned that a `text/plain` page is *not* run
    /// through the HTML extractor (which would return an empty or mangled document) and that the
    /// title stays absent rather than being invented (ledger B30).
    func testAPlainTextBodyIsReturnedAsRawText() async throws {
        // The body deliberately looks like markup: a plain-text page must reach the caller
        // byte-for-byte, so if this were routed through the HTML extractor the angle-bracket text
        // would be dropped and the whitespace collapsed — which is what the assertion below
        // catches (the first version of this test used a body the two paths agreed on).
        let body = "plain text with <tags> and   double  spaces"
        let server = try LoopbackServer(responses: [
            .init(
                status: 200,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: body
            )
        ])

        let result = try await fetch(server)

        XCTAssertEqual(result.method, .rawText)
        XCTAssertNil(result.title, "a non-HTML body has no title to report")
        XCTAssertEqual(result.text, body, "raw text must not be parsed as markup")
        XCTAssertEqual(result.statusCode, 200)
    }

    /// A non-textual body is refused rather than decoded into mojibake.
    ///
    /// The content-type gate is a security-adjacent control: the earlier fix removed `application/pdf`
    /// from the allow-list because a PDF came back as Latin-1 garbage labelled `raw_text`
    /// (ledger B16). An image must take the same path (ledger B30).
    func testANonTextualContentTypeIsRefused() async throws {
        let server = try LoopbackServer(responses: [
            .init(status: 200, headers: ["Content-Type": "image/png"], body: "not really a png")
        ])

        do {
            _ = try await fetch(server)
            XCTFail("an image must not be returned as readable text")
        } catch let error as SearchError {
            guard case .extractionFailed = error else {
                return XCTFail("an image must be an extraction failure, got \(error)")
            }
        }
    }

    /// The byte cap is enforced during the transfer, so an oversized page is refused, not buffered.
    ///
    /// `BoundedResponseBody.read` enforces `maxFetchedPageBytes` mid-stream (ledger B07), and the
    /// rejection surfaces as `.extractionFailed` — the same shape the post-hoc cap check used to
    /// produce. Nothing exercised that mapping (ledger B30).
    func testAPageLargerThanTheConfiguredCapIsRefused() async throws {
        var configuration = Fixtures.configuration()
        configuration.maxFetchedPageBytes = 1_024
        let fetcher = DirectHTTPFetcher(
            configuration: configuration,
            policy: URLPolicy(allowPrivateNetwork: true),
            log: .disabled
        )
        let server = try LoopbackServer(responses: [
            .init(status: 200, body: String(repeating: "x", count: 4_096))
        ])

        do {
            _ = try await fetcher.fetch(
                FetchRequest(url: server.baseURL),
                maxRedirects: 5,
                allowedContentTypePrefixes: ["text/", "application/json"],
                maxCharacters: 12_000
            )
            XCTFail("a page over the cap must be refused")
        } catch let error as SearchError {
            guard case .extractionFailed = error else {
                return XCTFail("a page over the cap must be an extraction failure, got \(error)")
            }
        }
    }

    /// A timeout is the URL's failure, never a search provider's.
    ///
    /// The mapping from `URLError.timedOut` to a URL-scoped failure is what keeps `web_open` from
    /// blaming Tavily for a slow origin — the same attribution rule as the 403 test above, and the
    /// branch had no test (ledger B30).
    func testATimeoutIsScopedToTheURL() async throws {
        var configuration = Fixtures.configuration()
        configuration.requestTimeout = .milliseconds(300)
        let fetcher = DirectHTTPFetcher(
            configuration: configuration,
            policy: URLPolicy(allowPrivateNetwork: true),
            log: .disabled
        )
        let server = try LoopbackServer(responses: [
            .init(status: 200, body: "too late", delayMilliseconds: 3_000)
        ])

        do {
            _ = try await fetcher.fetch(
                FetchRequest(url: server.baseURL),
                maxRedirects: 5,
                allowedContentTypePrefixes: ["text/", "application/json"],
                maxCharacters: 12_000
            )
            XCTFail("expected a timeout")
        } catch let error as SearchError {
            guard case .fetchFailed(let url, let reason) = error else {
                return XCTFail("a timeout must be a fetch failure, got \(error)")
            }
            XCTAssertEqual(url, server.baseURL)
            XCTAssertTrue(reason.lowercased().contains("timed out"), reason)
            for name in ["Tavily", "Brave", "Mojeek", "Exa", "SearXNG", "Parallel"] {
                XCTAssertFalse(
                    error.safeDescription.contains(name),
                    "a timeout must not mention \(name): \(error.safeDescription)"
                )
            }
        }
    }

    func testNonSuccessStatusIsReportedAsAFetchFailure() async throws {
        let server = try LoopbackServer(responses: [.init(status: 403, body: "denied")])

        do {
            _ = try await fetch(server)
            XCTFail("expected a fetch failure")
        } catch let error as SearchError {
            guard case .fetchFailed(let url, let reason) = error else {
                return XCTFail("a 403 must be a fetch failure, got \(error)")
            }
            XCTAssertEqual(url, server.baseURL)
            XCTAssertTrue(reason.contains("403"), reason)
            // No search provider may be named: this request never involved one.
            for name in ["Tavily", "Brave", "Mojeek", "Exa", "SearXNG", "Parallel"] {
                XCTAssertFalse(
                    error.safeDescription.contains(name),
                    "fetch error wrongly mentioned \(name): \(error.safeDescription)"
                )
            }
        }
    }

    func testMissingPageKeepsItsOwnDistinctError() async throws {
        let server = try LoopbackServer(responses: [.init(status: 404, body: "gone")])

        do {
            _ = try await fetch(server)
            XCTFail("expected a failure")
        } catch let error as SearchError {
            guard case .extractionFailed = error else {
                return XCTFail("a 404 is an extraction failure, got \(error)")
            }
        }
    }

    func testSuccessfulHTMLFetchProducesReadableText() async throws {
        let body = String(repeating: "Structured concurrency keeps tasks scoped. ", count: 20)
        let html = """
            <html><head><title>Swift Concurrency</title></head>
            <body><nav>menu</nav><article><h1>Swift Concurrency</h1>
            <p>\(body)</p>
            </article><footer>footer</footer></body></html>
            """
        let server = try LoopbackServer(responses: [
            .init(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: html
            )
        ])

        let result = try await fetch(server)

        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.method, .htmlExtraction)
        XCTAssertEqual(result.title, "Swift Concurrency")
        XCTAssertTrue(result.text.contains("Structured concurrency"), result.text)
        XCTAssertFalse(result.text.contains("menu"), "navigation must be removed")
        XCTAssertFalse(result.truncated)
    }

    /// The renderer uses this to decide whether a synthesised `# Title` heading would just
    /// repeat the first line of the body, which it did on nearly every page.
    func testTextAlreadyOpeningWithTheTitleIsDetected() {
        func result(title: String?, text: String) -> FetchResult {
            FetchResult(
                finalURL: URL(string: "https://example.com/")!,
                statusCode: 200,
                contentType: "text/html",
                title: title,
                text: text,
                method: .htmlExtraction,
                truncated: false
            )
        }

        XCTAssertTrue(
            result(title: "Swift Concurrency", text: "Swift Concurrency\nBody text")
                .textAlreadyOpensWithTitle
        )
        XCTAssertTrue(
            result(title: "Swift Concurrency", text: "# swift concurrency\nBody text")
                .textAlreadyOpensWithTitle,
            "a heading marker and different casing are still the same title"
        )
        XCTAssertFalse(
            result(title: "Swift Concurrency", text: "Introduction\nBody text")
                .textAlreadyOpensWithTitle,
            "a body that opens with something else still wants the heading"
        )
        XCTAssertFalse(
            result(title: nil, text: "Swift Concurrency\nBody text").textAlreadyOpensWithTitle
        )
        XCTAssertFalse(
            result(title: "Swift Concurrency", text: "").textAlreadyOpensWithTitle
        )
    }
}
