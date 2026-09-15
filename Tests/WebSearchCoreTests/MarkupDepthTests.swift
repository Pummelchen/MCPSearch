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

    /// An unterminated raw-text element swallows the rest of the document.
    ///
    /// `skipRawText` returns `end` when no closing tag exists, and every raw-text fixture in this
    /// file closed its element, so that branch was only reachable through markup that also
    /// happened to pass `containsMarkup`. A browser treats everything after an unclosed
    /// `<script>` as script text, so the thousands of `<div>`s inside it are not elements and
    /// must not count — even though the same text without the opening tag is rejected by the
    /// very next assertion (ledger B93).
    func testUnterminatedRawTextSwallowsTheRestOfTheDocument() {
        let unterminated = "<script>" + Self.nested(20_000)
        XCTAssertGreaterThanOrEqual(
            Self.nested(20_000).utf8.count, 90_000,
            "the fixture must be full of markup, or the branch is not under test"
        )
        XCTAssertFalse(
            MarkupDepth.exceedsLimit(unterminated),
            "raw text that never closes holds no elements, so it cannot nest"
        )
        // The control: the same markup without the raw-text opening tag is rejected. Without
        // this, the assertion above would also pass if `scan` simply stopped early.
        XCTAssertTrue(MarkupDepth.exceedsLimit(Self.nested(20_000)))
    }

    /// No-raw-text fixture with no closing tag *and* markup after the opening tag, so the
    /// scanner reaches `skipRawText`'s unterminated return rather than tripping earlier.
    func testUnterminatedRawTextIsSkippedRatherThanScanned() {
        // Exactly the limit in real elements, then an unclosed raw-text element whose content
        // would be rejected on its own. The result is `false` only if the scanner skipped to the
        // end of the input instead of scanning that content (ledger B93).
        let html = Self.nested(MarkupDepth.maximumNesting) + "<style>" + Self.nested(20_000)
        XCTAssertFalse(
            MarkupDepth.exceedsLimit(html),
            "the markup inside the unclosed style element is raw text, not nesting"
        )
        // The control: the same 20 000 levels without the raw-text opening tag are rejected.
        XCTAssertTrue(MarkupDepth.exceedsLimit(Self.nested(20_000)))
    }

    /// A direct scan over a non-contiguous byte view must agree with the contiguous path.
    ///
    /// `exceedsLimit` scans `String.utf8` in place when it can and falls back to
    /// `Array(html.utf8)[...]` when it cannot (`MarkupDepth.swift:34-40`). The fallback is a
    /// different code path over a different `RandomAccessCollection`, and `scan` is internal, so
    /// it is pinned directly by handing it a `ArraySlice` — the same type the fallback builds.
    /// This mirrors the B93 expectation that the fallback be exercised without depending on a
    /// string layout the compiler may change (ledger B93).
    func testScanOverANonContiguousByteViewAgreesWithTheContiguousPath() {
        let deepMarkup = Self.nested(MarkupDepth.maximumNesting + 1)
        let shallowMarkup = Self.nested(MarkupDepth.maximumNesting)

        XCTAssertTrue(MarkupDepth.exceedsLimit(deepMarkup))
        XCTAssertFalse(MarkupDepth.exceedsLimit(shallowMarkup))

        // `Array(...)[...]` is an `ArraySlice<UInt8>`: contiguous storage, but a non-zero
        // `startIndex` in general and not the same collection type as `UnsafeBufferPointer`.
        let copiedBytes = Array(deepMarkup.utf8)
        XCTAssertTrue(MarkupDepth.scan(copiedBytes[...], limit: MarkupDepth.maximumNesting))
        XCTAssertFalse(
            MarkupDepth.scan(Array(shallowMarkup.utf8)[...], limit: MarkupDepth.maximumNesting)
        )

        // A slice that starts partway into a buffer is what a non-contiguous view can produce;
        // the scanner must honour the slice's own indices rather than assume they start at
        // zero. `Array(html.utf8)[...]` happens to have `startIndex == 0`, so the assertion
        // uses `dropFirst`, which does not.
        let padded = Array("padding".utf8) + copiedBytes
        let offsetSlice = padded.dropFirst("padding".utf8.count)
        XCTAssertEqual(offsetSlice.startIndex, "padding".utf8.count, "the slice must be offset")
        XCTAssertTrue(MarkupDepth.scan(offsetSlice, limit: MarkupDepth.maximumNesting))
    }

    /// The projection of `markupDepthExceeded` onto the shared taxonomy and the model-visible
    /// string.
    ///
    /// The four existing `markupDepthExceeded` assertions all compare the case value itself. The
    /// category, the provider scope and `safeDescription` — what `web_search_status` and the tool
    /// error actually render — were unpinned, so a case with no category or a message that
    /// dropped the limit would have gone unnoticed (ledger B93).
    func testMarkupDepthExceededProjectsOntoTheSharedTaxonomy() {
        let error = SearchError.markupDepthExceeded(512)
        XCTAssertEqual(error.category, .malformedResponse)
        XCTAssertNil(error.provider, "the depth guard is not provider-scoped")
        XCTAssertEqual(
            error.safeDescription,
            "The markup nests more than 512 elements deep, which cannot be parsed safely."
        )
        // The limit is carried through rather than hard-coded, so a message that dropped the
        // actual bound would fail here.
        XCTAssertTrue(
            SearchError.markupDepthExceeded(4_096).safeDescription.contains("4096")
        )
    }

    /// The end-to-end contract: `web_open` on a deeply nested page is a tool error, not a
    /// successful extraction and not a crash.
    ///
    /// Every other `markupDepthExceeded` test calls `HTMLExtractor` directly or asserts the
    /// thrown case. Nothing pinned what a model actually receives, which is the reason the guard
    /// exists: the pre-fix failure mode was process death that took every connected client with
    /// it (ledger A01/B93).
    func testWebOpenOnADeeplyNestedPageIsAToolError() throws {
        let page = try LoopbackServer(responses: [
            .init(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: "<html><body>" + Self.nested(20_000) + "</body></html>"
            )
        ])

        let server = ServerProcess(
            binary: try ServerTestSupport.binaryURL(),
            environment: [
                // The loopback page is on 127.0.0.1, which the SSRF policy refuses by design.
                "SEARCH_ALLOW_PRIVATE_NETWORK": "1"
            ]
        )
        try server.start()
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 90,
            "method": "tools/call",
            "params": ["name": "web_open", "arguments": ["url": page.baseURL.absoluteString]],
        ])
        let response = try server.readResponse(id: 90)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true, "\(result)")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(
            text.contains("nests more than 512 elements deep"),
            "the model must be told why the page was refused: \(text)"
        )
        XCTAssertGreaterThan(page.requestCount, 0, "the page must actually have been fetched")
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
