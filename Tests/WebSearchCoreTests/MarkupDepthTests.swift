import Foundation
import XCTest

@testable import WebSearchCore

/// Regression tests for ledger item A01: untrusted markup must never terminate the process.
///
/// Before the guard existed, `DuckDuckGoProvider.search` died with SIGBUS at 5 000 nested
/// elements and `HTMLExtractor.extract` at 20 000. Both parse attacker-controlled markup on a
/// Swift concurrency cooperative task, whose stack a recursive parser exhausts; the failure
/// mode is process death, so every connected MCP client loses service. These tests reuse the
/// same inputs and call paths as the pre-fix probes, which means removing the guard makes them
/// crash the runner instead of failing politely.
final class MarkupDepthTests: XCTestCase {

    /// `<div>` repeated `depth` times, the shape used to measure the thresholds.
    private static func nested(_ depth: Int) -> String {
        String(repeating: "<div>", count: depth) + "text"
    }

    // MARK: - Counting nesting

    func testOrdinaryMarkupNestsShallowly() {
        XCTAssertFalse(MarkupDepth.exceedsLimit("<html><body><p>hello</p></body></html>"))
        XCTAssertFalse(MarkupDepth.exceedsLimit(""))
    }

    func testNestingAtTheLimitIsAccepted() {
        XCTAssertFalse(MarkupDepth.exceedsLimit(Self.nested(MarkupDepth.maximumNesting)))
    }

    func testNestingBeyondTheLimitIsRejected() {
        XCTAssertTrue(MarkupDepth.exceedsLimit(Self.nested(MarkupDepth.maximumNesting + 1)))
    }

    func testVoidElementsDoNotNest() {
        XCTAssertFalse(MarkupDepth.exceedsLimit(String(repeating: "<br>", count: 10_000)))
    }

    func testSelfClosingTagsDoNotNest() {
        XCTAssertFalse(
            MarkupDepth.exceedsLimit(String(repeating: "<img src=\"x\"/>", count: 10_000))
        )
    }

    func testCommentsAndDeclarationsDoNotNest() {
        let html =
            "<!doctype html>"
            + String(repeating: "<!-- <div><div><div> -->", count: 5_000)
        XCTAssertFalse(MarkupDepth.exceedsLimit(html))
    }

    func testClosingTagsReturnToTheParent() {
        let html =
            String(repeating: "<div>", count: 400)
            + String(repeating: "</div>", count: 400)
            + String(repeating: "<div>", count: 400)
        XCTAssertFalse(MarkupDepth.exceedsLimit(html))
    }

    func testStrayLessThanSignIsText() {
        XCTAssertFalse(
            MarkupDepth.exceedsLimit(String(repeating: "1 < 2 and 3 > 2; ", count: 5_000))
        )
    }

    func testMarkupInsideAQuotedAttributeIsNotANestedElement() {
        // The `>` closing the tag is inside the quotes, and the `<div>` never leaves them.
        XCTAssertFalse(
            MarkupDepth.exceedsLimit(String(repeating: "<p title=\"<div>\">x</p>", count: 600))
        )
    }

    func testRawTextContentIsNotNesting() {
        // A script bundle full of markup string literals is not a deep document.
        let script = "<script>var t = '" + String(repeating: "<div>", count: 5_000) + "';</script>"
        XCTAssertFalse(MarkupDepth.exceedsLimit(script))
        XCTAssertFalse(MarkupDepth.exceedsLimit("<style>a{content:'<div>'}</style>"))
    }

    func testRealNestingAroundRawTextStillCounts() {
        let html = String(repeating: "<div>", count: 600) + "<script>x</script>"
        XCTAssertTrue(MarkupDepth.exceedsLimit(html))
    }

    func testPathologicalDepthIsRejectedWithoutScanningTheWholeDocument() {
        let html = Self.nested(300_000)
        let started = Date()
        XCTAssertTrue(MarkupDepth.exceedsLimit(html))
        // Early exit: about 1.8 MB of markup, but the scan stops at the cap.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testMarkupSniff() {
        XCTAssertTrue(MarkupDepth.containsMarkup("<p>hi</p>"))
        XCTAssertTrue(MarkupDepth.containsMarkup("<!doctype html><html>"))
        XCTAssertTrue(MarkupDepth.containsMarkup("</div>"))
        XCTAssertFalse(MarkupDepth.containsMarkup(""))
        XCTAssertFalse(MarkupDepth.containsMarkup("this is not json at all"))
        XCTAssertFalse(MarkupDepth.containsMarkup("Too many requests, try again later."))
        // Prose with a stray less-than sign is still prose.
        XCTAssertFalse(MarkupDepth.containsMarkup("2 < 3 and 3 > 2"))
    }

    // MARK: - The scraper path: process death before the fix at 5 000

    /// The same call that killed the process: `DuckDuckGoProvider` on a cooperative task.
    func testDuckDuckGoProviderSurvivesADeeplyNestedResponse() async {
        let body = Data(Self.nested(5_000).utf8)
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/html"],
                body: body,
                url: request.url
            )
        }
        let provider = DuckDuckGoProvider(
            http: http,
            configuration: Fixtures.configuration(enableScrapers: true),
            scrapersEnabled: true
        )
        do {
            _ = try await provider.search(Fixtures.request())
            XCTFail("deeply nested markup must not produce results")
        } catch let error as SearchError {
            XCTAssertEqual(error, .markupDepthExceeded(MarkupDepth.maximumNesting))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A body with no markup at all is reported as a malformed response, not as "no results".
    func testScraperSupportRejectsABodyWithoutMarkup() {
        XCTAssertThrowsError(
            try ScraperSupport.parse(
                html: "this is not json at all",
                containerSelectors: [".result"],
                linkSelectors: ["a"],
                snippetSelectors: [".snippet"],
                base: "https://duckduckgo.com",
                excludeHosts: ["duckduckgo.com"],
                provider: .duckDuckGo
            )
        ) { error in
            XCTAssertEqual(error as? SearchError, .malformedResponse(.duckDuckGo))
        }
    }

    func testScraperSupportRejectsDeeplyNestedMarkup() {
        XCTAssertThrowsError(
            try ScraperSupport.parse(
                html: Self.nested(5_000),
                containerSelectors: [".result"],
                linkSelectors: ["a"],
                snippetSelectors: [".snippet"],
                base: "https://duckduckgo.com",
                excludeHosts: ["duckduckgo.com"],
                provider: .duckDuckGo
            )
        ) { error in
            XCTAssertEqual(error as? SearchError, .markupDepthExceeded(MarkupDepth.maximumNesting))
        }
    }

    // MARK: - The `web_open` path: process death before the fix at 20 000

    func testHTMLExtractorRejectsDeeplyNestedMarkup() {
        XCTAssertThrowsError(try HTMLExtractor.extract(html: Self.nested(20_000))) { error in
            XCTAssertEqual(error as? SearchError, .markupDepthExceeded(MarkupDepth.maximumNesting))
        }
    }

    /// The cap is inclusive, and a document *at* the cap must still be parsed — on the same
    /// kind of cooperative task, where the stack margin is smallest.
    func testMarkupAtTheLimitIsParsedOnACooperativeTask() async throws {
        let html = String(repeating: "<div>", count: MarkupDepth.maximumNesting) + "readable text"
        let extraction = try await Task.detached { try HTMLExtractor.extract(html: html) }.value
        XCTAssertTrue(extraction.text.contains("readable text"))
    }

    func testHTMLExtractorStillExtractsAnOrdinaryPage() throws {
        let html = """
            <html><head><title>Example</title><script>var a = 1;</script></head>
            <body><nav>menu</nav><article><h1>Heading</h1>
            <p>Body text long enough to be worth extracting from the page.</p>
            </article></body></html>
            """
        let extraction = try HTMLExtractor.extract(html: html)
        XCTAssertEqual(extraction.title, "Example")
        XCTAssertTrue(extraction.text.contains("Body text long enough"))
    }
}
