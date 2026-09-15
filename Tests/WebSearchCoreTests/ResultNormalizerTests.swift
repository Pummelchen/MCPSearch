import Foundation
import XCTest

@testable import WebSearchCore

/// The repairs applied to whatever a provider hands back.
///
/// Providers return schemeless and protocol-relative links, snippets with `<b>` highlight tags and
/// HTML entities, and occasionally control characters that survived JSON decoding. Everything here
/// is a documented behaviour of `ResultNormalizer` that no test touched (ledger B34); `make` was
/// covered indirectly by the fusion tests, these entry points were not.
final class ResultNormalizerTests: XCTestCase {

    // MARK: - URL repair

    func testProtocolRelativeURLsBecomeHTTPS() {
        XCTAssertEqual(
            ResultNormalizer.normalizedURL(from: "//example.com/x")?.absoluteString,
            "https://example.com/x"
        )
    }

    func testSchemelessURLsBecomeHTTPS() {
        XCTAssertEqual(
            ResultNormalizer.normalizedURL(from: "example.com/x")?.absoluteString,
            "https://example.com/x"
        )
    }

    /// Control characters sometimes survive JSON decoding; stripping them must repair the URL
    /// rather than reject it, because the rest of the string is a usable link.
    func testEmbeddedControlCharactersAreStripped() {
        let repaired = ResultNormalizer.normalizedURL(from: "https://exa\u{0}mple.com/x\u{1F}")
        XCTAssertEqual(repaired?.absoluteString, "https://example.com/x")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(
            ResultNormalizer.normalizedURL(from: "  https://example.com/x\n")?.absoluteString,
            "https://example.com/x"
        )
    }

    /// Only the web is reachable through the fetcher, so anything else is not a result URL.
    func testNonWebSchemesAndUnusableStringsAreRejected() {
        for raw in [
            "javascript:alert(1)",
            "ftp://example.com/x",
            "mailto:someone@example.com",
            "https://",
            "   ",
            "",
            "//",
        ] {
            XCTAssertNil(ResultNormalizer.normalizedURL(from: raw), "\(raw.debugDescription) must be rejected")
        }
    }

    // MARK: - Text cleaning

    func testCleanTextReturnsNilForNothingUsable() {
        XCTAssertNil(ResultNormalizer.cleanText(nil))
        XCTAssertNil(ResultNormalizer.cleanText(""))
        XCTAssertNil(ResultNormalizer.cleanText("   \n\t "))
        XCTAssertNil(ResultNormalizer.cleanText("<b></b>"))
    }

    /// Highlight tags are the only markup provider snippets carry, so they are stripped without a
    /// parser. The space appended at every closing `>` is what keeps words apart.
    func testCleanTextStripsHighlightTags() {
        XCTAssertEqual(ResultNormalizer.cleanText("<b>bold</b> and <em>emphasised</em>"), "bold and emphasised")
        XCTAssertEqual(ResultNormalizer.cleanText("no markup at all"), "no markup at all")
    }

    /// An unterminated tag swallows the rest of the snippet: that is the documented trade-off of a
    /// tag stripper that is not a parser, and pinning it here stops a future change from silently
    /// altering what a snippet looks like.
    func testCleanTextDropsEverythingAfterAnUnterminatedTag() {
        XCTAssertEqual(ResultNormalizer.cleanText("kept <b dropped"), "kept")
    }

    func testCleanTextDecodesCommonEntities() {
        XCTAssertEqual(
            ResultNormalizer.cleanText("fish &amp; chips &mdash; &quot;fresh&quot;"),
            "fish & chips — \"fresh\""
        )
        XCTAssertEqual(
            ResultNormalizer.cleanText("it&#39;s&nbsp;here&hellip;"),
            "it's here…"
        )
    }

    func testCleanTextCollapsesWhitespace() {
        XCTAssertEqual(ResultNormalizer.cleanText("  a   b\n\nc\t d  "), "a b c d")
    }

    // MARK: - The exposed helpers

    func testStripHTMLTagsKeepsTextAndSeparatesWords() {
        XCTAssertEqual(ResultNormalizer.stripHTMLTags("one<br>two"), "one two")
    }

    func testDecodeCommonEntitiesLeavesUnknownEntitiesAlone() {
        XCTAssertEqual(ResultNormalizer.decodeCommonEntities("&unknown; &amp;"), "&unknown; &")
    }

    /// Decoding happens once: an escaped entity must not become live markup.
    ///
    /// The decoder replaced sequentially over its own output, so `&amp;lt;` decoded twice — the
    /// `&amp;` produced `&`, and the `&lt;` that created was then decoded to a live `<`. A snippet
    /// carrying escaped markup could therefore inject markup into whatever consumed the text
    /// (ledger B63).
    func testDecodeCommonEntitiesDoesNotDecodeTwice() {
        XCTAssertEqual(ResultNormalizer.decodeCommonEntities("&amp;lt;b&amp;gt;"), "&lt;b&gt;")
        XCTAssertEqual(ResultNormalizer.decodeCommonEntities("&amp;amp;"), "&amp;")
        // A literal ampersand with no entity after it stays as it is.
        XCTAssertEqual(ResultNormalizer.decodeCommonEntities("fish & chips"), "fish & chips")
        XCTAssertEqual(ResultNormalizer.decodeCommonEntities("100% &more; text"), "100% &more; text")
    }
}
