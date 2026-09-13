import Foundation
import SwiftSoup
import XCTest

@testable import WebSearchCore

/// HTML extraction.
///
/// These fixtures are deliberately realistic: the failure mode that matters is
/// keeping navigation and cookie banners, or discarding the actual article.
final class HTMLExtractorTests: XCTestCase {

    private let articlePage = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <title>Swift 6.3 Concurrency Changes</title>
          <link rel="canonical" href="https://example.com/articles/swift-63">
          <style>body { color: red } .hidden { display: none }</style>
          <script>window.analytics = { track: function(){} };</script>
        </head>
        <body>
          <header id="site-header"><nav class="navigation"><a href="/">Home</a></nav></header>
          <div class="cookie-consent-banner">We use cookies. Accept all?</div>
          <div class="advert-container"><a href="https://ads.example.com">Buy now</a></div>
          <main>
            <article class="post-content">
              <h1>Swift 6.3 Concurrency Changes</h1>
              <p>Swift 6.3 refines strict concurrency checking.</p>
              <p>Actors remain the primary isolation primitive.</p>
              <ul><li>Sendable checking improved</li><li>Better diagnostics</li></ul>
            </article>
          </main>
          <aside class="related-posts"><h3>Related</h3><a href="/other">Other post</a></aside>
          <div class="newsletter-signup">Subscribe to our newsletter</div>
          <footer class="site-footer"><p>&copy; 2026 Example Inc.</p></footer>
        </body>
        </html>
        """

    func testExtractsTitle() throws {
        let extraction = try HTMLExtractor.extract(html: articlePage)
        XCTAssertEqual(extraction.title, "Swift 6.3 Concurrency Changes")
    }

    func testKeepsArticleProse() throws {
        let text = try HTMLExtractor.extract(html: articlePage).text
        XCTAssertTrue(text.contains("Swift 6.3 refines strict concurrency checking"))
        XCTAssertTrue(text.contains("Actors remain the primary isolation primitive"))
        XCTAssertTrue(text.contains("Sendable checking improved"))
    }

    func testRemovesScriptsStylesAndNavigation() throws {
        let text = try HTMLExtractor.extract(html: articlePage).text
        XCTAssertFalse(text.contains("window.analytics"), "script content must be removed")
        XCTAssertFalse(text.contains("color: red"), "style content must be removed")
        XCTAssertFalse(text.contains("We use cookies"), "cookie banner must be removed")
        XCTAssertFalse(text.contains("Buy now"), "advert must be removed")
        XCTAssertFalse(text.contains("Subscribe to our newsletter"), "newsletter must be removed")
        XCTAssertFalse(text.contains("2026 Example Inc"), "footer must be removed")
        XCTAssertFalse(text.contains("Related"), "related sidebar must be removed")
    }

    func testPreservesHeadingAndListStructure() throws {
        let text = try HTMLExtractor.extract(html: articlePage).text
        XCTAssertTrue(text.contains("#") == false, "raw markdown markers are not synthesized")
        XCTAssertTrue(text.contains("Swift 6.3 Concurrency Changes"))
        // List items keep a visible bullet so the structure survives flattening.
        XCTAssertTrue(text.contains("– Sendable checking improved"))
    }

    func testRemovesHiddenElements() throws {
        let html = """
            <html><body><main>
            <p>Visible content that should definitely be kept in the output.</p>
            <div style="display: none">Hidden secret text</div>
            <div hidden>Also hidden</div>
            </main></body></html>
            """
        let text = try HTMLExtractor.extract(html: html).text
        XCTAssertTrue(text.contains("Visible content"))
        XCTAssertFalse(text.contains("Hidden secret text"))
        XCTAssertFalse(text.contains("Also hidden"))
    }

    func testFallsBackToBodyWhenNoSemanticContainer() throws {
        let html = """
            <html><head><title>Plain</title></head><body>
            <p>Some ordinary prose in a page with no semantic structure at all.</p>
            </body></html>
            """
        let text = try HTMLExtractor.extract(html: html).text
        XCTAssertTrue(text.contains("Some ordinary prose"))
    }

    func testBoilerplateMatchingIsTokenBasedNotSubstring() throws {
        // `navy` must not match `nav`, and `innovate` must not be treated as chrome.
        let html = """
            <html><body><main>
            <div class="navy-theme">The navy blue design is intentional.</div>
            <p>We innovate constantly in our approach to software.</p>
            </main></body></html>
            """
        let text = try HTMLExtractor.extract(html: html).text
        XCTAssertTrue(text.contains("navy blue design"), "a `nav` prefix match must not delete content")
        XCTAssertTrue(text.contains("innovate constantly"))
    }

    func testDecodesEntitiesAndCollapsesWhitespace() throws {
        let html = """
            <html><body><main><p>Tom &amp; Jerry&nbsp;said   &quot;hello&quot;</p></main></body></html>
            """
        let text = try HTMLExtractor.extract(html: html).text
        XCTAssertTrue(text.contains("Tom & Jerry said \"hello\""))
    }

    func testHandlesEmptyDocument() throws {
        let extraction = try HTMLExtractor.extract(html: "")
        XCTAssertNil(extraction.title)
        XCTAssertTrue(extraction.text.isEmpty)
    }

    func testNormalizeWhitespaceLimitsBlankLines() {
        let normalized = HTMLExtractor.normalizeWhitespace("a\n\n\n\nb\n\nc")
        XCTAssertEqual(normalized, "a\n\nb\n\nc")
    }

    func testClipReportsTruncationOnWordBoundary() {
        let text = String(repeating: "word ", count: 100)
        let clipped = DirectHTTPFetcher.clip(text, to: 50)
        XCTAssertTrue(clipped.truncated)
        XCTAssertLessThanOrEqual(clipped.text.count, 50)
        XCTAssertFalse(clipped.text.hasSuffix(" "))

        let short = DirectHTTPFetcher.clip("short text", to: 50)
        XCTAssertFalse(short.truncated)
        XCTAssertEqual(short.text, "short text")
    }
    /// Hyphenated chrome markers must actually match.
    ///
    /// The matcher tokenised class names by splitting on every non-alphanumeric character,
    /// hyphens included, so `class="side-bar"` became `["side", "bar"]` and could never equal the
    /// `side-bar` marker; the clause that looked for a hyphen after the marker was unreachable for
    /// the same reason (ledger B61).
    func testHyphenatedBoilerplateMarkersAreRemoved() throws {
        let page = """
            <html><body>
              <div class="side-bar"><p>Chrome text that must not survive.</p></div>
              <div class="site-header"><p>More chrome.</p></div>
              <main><article class="post-content">
                <p>Real article text, long enough to be worth keeping as the content root.</p>
                <p>Second paragraph so the container wins the density comparison.</p>
              </article></main>
            </body></html>
            """

        let extraction = try HTMLExtractor.extract(html: page)

        XCTAssertTrue(extraction.text.contains("Real article text"))
        XCTAssertFalse(extraction.text.contains("Chrome text"), extraction.text)
        XCTAssertFalse(extraction.text.contains("More chrome"), extraction.text)
    }

    /// A page that nests its containers must not cost quadratic work.
    ///
    /// `preferredContentRoot` scores each candidate with `Element.text()`, which walks the whole
    /// subtree, and a container's text includes everything inside it — so a candidate nested in
    /// another can never outscore it, and scoring it re-walked text already counted. Markup can
    /// force that: 500 nested `.entry-content` containers inside a `.content` div, each level
    /// carrying its own paragraph, is 1.8 MB of HTML, and the scoring pass used to build the text
    /// of every one of them — about 450 MB of copying for a page whose real content is 1.8 MB
    /// (ledger B28). Only maximal candidates are scored now, and their subtrees are disjoint.
    ///
    /// The document is parsed outside the timed region: this is about the scoring pass, and a
    /// timing assertion over the whole pipeline would mostly measure SwiftSoup's parser.
    func testDeeplyNestedContainersDoNotCostQuadraticTime() throws {
        // Just under `MarkupDepth.maximumNesting` (512), so the document is one the extractor
        // accepts: the cost under test is scoring, not the nesting guard.
        let depth = 500
        let level =
            "<p>" + String(repeating: "some article text that repeats here ", count: 200) + "</p>"
        let html =
            "<html><body><div class=\"content\">"
            + String(repeating: "<div class=\"entry-content\">" + level, count: depth)
            + String(repeating: "</div>", count: depth)
            + "</div></body></html>"
        let document = try SwiftSoup.parse(html)

        let started = ContinuousClock.now
        let root = HTMLExtractor.preferredContentRoot(in: document)
        let elapsed = ContinuousClock.now - started

        XCTAssertEqual(try root?.className(), "content", "the outermost container wins")
        XCTAssertLessThan(
            elapsed,
            .seconds(1),
            "scoring nested containers re-walks their subtrees: took \(elapsed)"
        )
    }

}

/// Scraper parsing, driven by stored markup rather than the network.
final class ScraperTests: XCTestCase {

    /// Realistic DuckDuckGo html endpoint markup, including the redirect wrapper.
    private let duckDuckGoHTML = """
        <!DOCTYPE html>
        <html><body>
        <div id="links" class="results">
          <div class="result results_links results_links_deep web-result">
            <div class="links_main links_deep result__body">
              <h2 class="result__title">
                <a rel="nofollow" class="result__a"
                   href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fgithub.com%2Fmodelcontextprotocol%2Fswift%2Dsdk&amp;rut=abc123">
                   swift-sdk: The official Swift SDK
                </a>
              </h2>
              <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fgithub.com%2Fmodelcontextprotocol%2Fswift%2Dsdk">
                An <b>official</b> Swift implementation of the Model Context Protocol.
              </a>
              <div class="result__extras"><div class="result__extras__url">github.com</div></div>
            </div>
          </div>
          <div class="result results_links results_links_deep web-result">
            <div class="links_main links_deep result__body">
              <h2 class="result__title">
                <a rel="nofollow" class="result__a" href="https://swift.org/documentation/">Swift Documentation</a>
              </h2>
              <a class="result__snippet">Official language documentation and guides for Swift.</a>
            </div>
          </div>
        </div>
        </body></html>
        """

    func testParsesDuckDuckGoResultsAndUnwrapsRedirects() throws {
        let page = try ScraperSupport.parse(
            html: duckDuckGoHTML,
            containerSelectors: DuckDuckGoProvider.containerSelectors,
            linkSelectors: DuckDuckGoProvider.linkSelectors,
            snippetSelectors: DuckDuckGoProvider.snippetSelectors,
            base: "https://duckduckgo.com",
            excludeHosts: ["duckduckgo.com"],
            provider: .duckDuckGo
        )

        XCTAssertEqual(page.results.count, 2)
        // The wrapper URL must never reach a model.
        XCTAssertEqual(
            page.results[0].url,
            "https://github.com/modelcontextprotocol/swift-sdk"
        )
        XCTAssertEqual(page.results[0].title, "swift-sdk: The official Swift SDK")
        XCTAssertTrue(page.results[0].snippet?.contains("official Swift implementation") ?? false)
        XCTAssertEqual(page.results[1].url, "https://swift.org/documentation/")
    }

    func testDetectsDuckDuckGoBotChallenge() throws {
        let challenge = """
            <html><body>
            <div class="anomaly-modal">
              <div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div>
              <p>Please complete the following challenge to confirm this search was made by a human.</p>
              <p>Select all squares containing a duck:</p>
            </div>
            </body></html>
            """
        let page = try ScraperSupport.parse(
            html: challenge,
            containerSelectors: DuckDuckGoProvider.containerSelectors,
            linkSelectors: DuckDuckGoProvider.linkSelectors,
            snippetSelectors: DuckDuckGoProvider.snippetSelectors,
            base: "https://duckduckgo.com",
            excludeHosts: ["duckduckgo.com"],
            provider: .duckDuckGo
        )
        XCTAssertEqual(page.detectedBlock, .botChallenge)
        XCTAssertTrue(page.results.isEmpty)
    }

    func testDetectsStartpageAnubisChallenge() throws {
        let challenge = """
            <html><body><script id="anubis_challenge" type="application/json">{}</script>
            <p>Verifying your request... Loading...</p>
            </body></html>
            """
        let page = try ScraperSupport.parse(
            html: challenge,
            containerSelectors: StartpageProvider.containerSelectors,
            linkSelectors: StartpageProvider.linkSelectors,
            snippetSelectors: StartpageProvider.snippetSelectors,
            base: "https://www.startpage.com",
            excludeHosts: ["startpage.com"],
            provider: .startpage
        )
        XCTAssertEqual(page.detectedBlock, .botChallenge)
    }

    func testStructuralFallbackFindsResultLikeAnchors() throws {
        // Unknown markup: the parser must still degrade usefully rather than fail.
        let unknown = """
            <html><body>
            <div class="totally-new-layout">
              <a href="https://example.com/a-genuine-result">A genuinely useful result title</a>
              <a href="https://example.com/another-result">Another reasonably long result title</a>
              <a href="/short">no</a>
            </div>
            </body></html>
            """
        let page = try ScraperSupport.parse(
            html: unknown,
            containerSelectors: ["div.nonexistent"],
            linkSelectors: ["a.nonexistent"],
            snippetSelectors: ["span.nonexistent"],
            base: "https://example.com",
            excludeHosts: [],
            provider: .duckDuckGo
        )
        XCTAssertEqual(page.results.count, 2)
        XCTAssertEqual(page.results[0].url, "https://example.com/a-genuine-result")
    }

    /// The DuckDuckGo region hint is `region-language`, not the region twice.
    ///
    /// `kl=us-us` is not a value DDG defines; the language was available and discarded, so the hint
    /// was wrong for every query that carried a region (ledger B60).
    func testDuckDuckGoLocaleHintIsRegionLanguage() {
        XCTAssertEqual(DuckDuckGoProvider.localeHint(for: LocaleHint("en-US")), "us-en")
        XCTAssertEqual(DuckDuckGoProvider.localeHint(for: LocaleHint("de-DE")), "de-de")
        XCTAssertNil(
            DuckDuckGoProvider.localeHint(for: LocaleHint("en")),
            "a locale without a region has no hint to send"
        )
        XCTAssertNil(DuckDuckGoProvider.localeHint(for: nil))
    }

    func testExcludeHostsFiltersEngineOwnHosts() throws {
        let html = """
            <html><body>
            <a href="https://duckduckgo.com/about">About DuckDuckGo and its privacy policy</a>
            <a href="https://example.com/real">A real external result about searching</a>
            </body></html>
            """
        let page = try ScraperSupport.parse(
            html: html,
            containerSelectors: [],
            linkSelectors: [],
            snippetSelectors: [],
            base: "https://duckduckgo.com",
            excludeHosts: ["duckduckgo.com"],
            provider: .duckDuckGo
        )
        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(page.results[0].url, "https://example.com/real")
    }

    func testUnwrapRedirectFallsBackWhenNoTarget() {
        let direct = "https://example.com/page"
        XCTAssertEqual(ScraperSupport.unwrapRedirect(direct), direct)
        XCTAssertEqual(
            ScraperSupport.unwrapRedirect("//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fx&rut=1"),
            "https://example.com/x"
        )
    }

    func testScrapersReportUnconfiguredWhenDisabled() async {
        let http = MockHTTPClient()
        let configuration = Fixtures.configuration(enableScrapers: false)
        let duck = DuckDuckGoProvider(
            http: http,
            configuration: configuration,
            scrapersEnabled: false
        )
        let startpage = StartpageProvider(
            http: http,
            configuration: configuration,
            scrapersEnabled: false
        )
        XCTAssertFalse(duck.isConfigured)
        XCTAssertFalse(startpage.isConfigured)

        do {
            _ = try await duck.search(Fixtures.request())
            XCTFail("scraper must refuse to run when disabled")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .notConfigured)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        // Nothing may reach the network.
        XCTAssertTrue(http.requests.isEmpty)
    }

}
