import Foundation
import SwiftSoup
import XCTest

@testable import WebSearchCore

/// Regression tests: untrusted markup must never terminate the process.
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

    /// A closing tag that closes nothing must not suppress the depth it does not close.
    ///
    /// The guard's counter decremented on every closing tag, with the comment "a closing tag always
    /// returns to the parent, even if it never matched one". That is false for real HTML: `</p>` with
    /// no open `p` closes nothing, so `<div></p>` repeated nests the `div`s 100 000 deep — 900 KB,
    /// inside the fetch cap — while the counter reads 0 or 1 and the guard never trips. Measured
    /// through `SwiftSoup.parse`, that document did not crash and did not finish within ten minutes
    /// (ledger A0011).
    /// The model's depth against the depth SwiftSoup actually builds.
    ///
    /// A bound is only sound if the model never reads *below* the real tree, and only usable if it is
    /// not far above it. The corpus below is the constructs where the two can diverge: the optional end
    /// tags HTML permits, the adoption-agency elements, tables with implied structure, and foreign
    /// content. Every case asserts soundness, because an under-count is the bypass; tightness is
    /// asserted separately, against the divergence each case was measured at.
    func testTheModelDepthIsNeverBelowTheParsedTree() throws {
        let documents: [(String, String)] = [
            ("nested divs", String(repeating: "<div>", count: 40) + "x" + String(repeating: "</div>", count: 40)),
            ("deep then shallow", String(repeating: "<div>", count: 30) + "</div></div></div><span>y</span>"),
            ("omitted </p>", "<p>one<p>two<p>three<p>four<p>five"),
            ("omitted </li>", "<ul><li>a<li>b<li>c<li>d<li>e</ul>"),
            ("omitted </td></tr>", "<table><tr><td>a<td>b<tr><td>c<td>d</table>"),
            ("omitted </dt><dd>", "<dl><dt>a<dd>b<dt>c<dd>d</dl>"),
            ("select options", "<select><option>a<option>b<option>c</select>"),
            ("mixed ordinary", "<div><ul><li><p>text</p></li></ul></div>"),
            ("adoption agency a", String(repeating: "<a>", count: 20) + "x"),
            ("adoption agency b/i", String(repeating: "<b><i>", count: 20) + "x"),
            ("nobr repeated", String(repeating: "<nobr>", count: 20) + "x"),
            ("headings close each other", "<h1>a<h2>b<h3>c<h4>d<h5>e<h6>f"),
            ("button closes button", "<button>a<button>b<button>c"),
            ("form repeated", "<form><form><form>x"),
            ("svg foreign content", "<svg><g><g><g><text>t</text></g></g></g></svg>"),
            ("math foreign content", "<math><mrow><mrow><mi>x</mi></mrow></mrow></math>"),
            (
                "table sections",
                "<table><caption>c</caption><colgroup><col></colgroup><thead><tr><th>h<tbody><tr><td>d</table>"
            ),
            ("nested tables", "<table><tr><td><table><tr><td><table><tr><td>x</table></table></table>"),
            ("select inside a table", "<table><tr><td><select><option>a<option>b</select></table>"),
            ("stray end tags", "</div></p></span><div>a</div></li></ul>"),
            ("li outside a list", "<li>a<li>b<li>c"),
            ("option outside a select", "<option>a<option>b"),
            ("paragraphs with inline", "<p>a<b>b<i>c</i></b><p>d<em>e</em>"),
            ("deep inline", String(repeating: "<span>", count: 60) + "x" + String(repeating: "</span>", count: 60)),
            (
                "realistic page",
                """
                <div class="page"><header><nav><ul><li><a href="/a">A</a><li><a href="/b">B</a></ul></nav></header>
                <main><article><h1>Title</h1><p>One<p>Two<ul><li>x<li>y</ul>
                <table><tr><th>h<th>h<tbody><tr><td>a<td>b</table>
                <form><label>L<input name="i"></label><button>Go</button></form></article></main>
                <footer><p>f</p></footer></div>
                """
            ),
        ]

        // Divergences measured and accepted. Every other case must be exact.
        let acceptedOverCount: [String: Int] = [
            // A parser ignores a `<form>` start tag while a form is open — a form inside a form creates
            // no element — so the model counts two levels the tree does not have. The markup is
            // invalid, real pages do not contain it, and over-counting is the safe direction.
            "form repeated": 2
        ]

        var exact = 0
        for (label, fragment) in documents {
            // A complete document, so the parser adds no implicit `html`/`body` wrapper. With a bare
            // fragment it always adds two, which the model cannot see: measuring fragments made the
            // model look like it under-counted by a constant 2 when the two levels were the parser's.
            let html = "<!DOCTYPE html><html><head></head><body>" + fragment + "</body></html>"
            let real = try Self.parsedDepth(html)
            let model = MarkupDepth.maximumDepth(html, limit: 100_000)
            if model == real { exact += 1 }
            print("      A0011 \(label): model=\(model) parsed=\(real) delta=\(model - real)")
            XCTAssertGreaterThanOrEqual(
                model,
                real,
                "\(label): the model read \(model) but the parser built \(real) — under-counting is a bypass"
            )
            // Tightness, per case. A lower bound alone would let the model drift upward into a false
            // rejection with no test noticing, which is the failure mode this exercise exists to avoid.
            XCTAssertEqual(
                model - real,
                acceptedOverCount[label] ?? 0,
                "\(label): the model read \(model), the parser built \(real)"
            )
        }
        print("      A0011 exact: \(exact) of \(documents.count)")
    }

    /// What a bare fragment costs on top of the model, which is what the limit is chosen against.
    ///
    /// `web_open` hands a parser a fragment, not a complete document, and the parser inserts an `html`
    /// and a `body` element the bytes never contained and the model cannot see. That constant is the
    /// difference between `maximumNesting` and the tree depth it actually admits (ledger A0011).
    func testAFragmentGainsOnlyTheParsersOwnWrapper() throws {
        let fragments = [
            String(repeating: "<div>", count: 50) + "x" + String(repeating: "</div>", count: 50),
            "<p>one<p>two<p>three<ul><li>a<li>b</ul>",
            "<table><tr><td>a<td>b<tr><td>c</table>",
            "<section><article><h1>t</h1><p>b<p>c</article></section>",
        ]

        for (index, fragment) in fragments.enumerated() {
            let real = try Self.parsedDepth(fragment)
            let model = MarkupDepth.maximumDepth(fragment, limit: 100_000)
            print("      A0011 fragment \(index): model=\(model) parsed=\(real)")
            XCTAssertLessThanOrEqual(
                real - model,
                2,
                "fragment \(index): the parser added \(real - model) levels, more than its html/body pair"
            )
        }
    }

    private static func parsedDepth(_ html: String) throws -> Int {
        let document = try SwiftSoup.parse(html)
        var deepest = 0
        var stack: [(Element, Int)] = [(document, 0)]
        while let (element, depth) = stack.popLast() {
            if depth > deepest { deepest = depth }
            for child in element.children() { stack.append((child, depth + 1)) }
        }
        return deepest
    }

    func testAStrayClosingTagDoesNotSuppressDepth() {
        let bypass = String(repeating: "<div></p>", count: 100_000)

        XCTAssertTrue(
            MarkupDepth.exceedsLimit(bypass),
            "a stray closing tag must not let the guard read shallow"
        )
    }

    /// The other half: a closing tag that *does* match still returns to its parent.
    ///
    /// A stack that simply ignored every closing tag would refuse `<div><span></span></div>` repeated,
    /// which is every ordinary page. This is the control for the test above.
    func testAMatchedClosingTagStillReturnsToItsParent() {
        let ordinary = String(repeating: "<div><span>x</span></div>", count: 400)

        XCTAssertFalse(
            MarkupDepth.exceedsLimit(ordinary),
            "matched closing tags must still return to the parent"
        )
        XCTAssertLessThanOrEqual(MarkupDepth.maximumDepth(ordinary), 2)
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
    /// very next assertion.
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
        // end of the input instead of scanning that content.
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
    /// The fallback is exercised directly, without depending on a
    /// string layout the compiler may change.
    func testScanOverANonContiguousByteViewAgreesWithTheContiguousPath() {
        let deepMarkup = Self.nested(MarkupDepth.maximumNesting + 1)
        let shallowMarkup = Self.nested(MarkupDepth.maximumNesting)

        XCTAssertTrue(MarkupDepth.exceedsLimit(deepMarkup))
        XCTAssertFalse(MarkupDepth.exceedsLimit(shallowMarkup))

        // `Array(...)[...]` is an `ArraySlice<UInt8>`: contiguous storage, but a non-zero
        // `startIndex` in general and not the same collection type as `UnsafeBufferPointer`.
        let copiedBytes = Array(deepMarkup.utf8)
        // `scan` reports the depth it reached rather than a verdict, so the comparison is the
        // verdict. The assertion is unchanged in meaning: deep exceeds, shallow does not.
        XCTAssertGreaterThan(
            MarkupDepth.scan(copiedBytes[...], limit: MarkupDepth.maximumNesting),
            MarkupDepth.maximumNesting
        )
        XCTAssertLessThanOrEqual(
            MarkupDepth.scan(Array(shallowMarkup.utf8)[...], limit: MarkupDepth.maximumNesting),
            MarkupDepth.maximumNesting
        )

        // A slice that starts partway into a buffer is what a non-contiguous view can produce;
        // the scanner must honour the slice's own indices rather than assume they start at
        // zero. `Array(html.utf8)[...]` happens to have `startIndex == 0`, so the assertion
        // uses `dropFirst`, which does not.
        let padded = Array("padding".utf8) + copiedBytes
        let offsetSlice = padded.dropFirst("padding".utf8.count)
        XCTAssertEqual(offsetSlice.startIndex, "padding".utf8.count, "the slice must be offset")
        XCTAssertGreaterThan(
            MarkupDepth.scan(offsetSlice, limit: MarkupDepth.maximumNesting),
            MarkupDepth.maximumNesting
        )
    }

    /// The projection of `markupDepthExceeded` onto the shared taxonomy and the model-visible
    /// string.
    ///
    /// The four existing `markupDepthExceeded` assertions all compare the case value itself. The
    /// category, the provider scope and `safeDescription` — what `web_search_status` and the tool
    /// error actually render — were unpinned, so a case with no category or a message that
    /// dropped the limit would have gone unnoticed.
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
    /// it.
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
