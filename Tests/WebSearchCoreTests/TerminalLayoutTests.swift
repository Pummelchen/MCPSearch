import Foundation
import XCTest

@testable import WebSearchCore

/// Layout and formatting primitives.
///
/// Column alignment is the whole point of a dashboard, so these are worth testing: a
/// width calculation that ignores ANSI escapes silently breaks every padded column.
final class TerminalLayoutTests: XCTestCase {

    func testDisplayWidthIgnoresEscapeSequences() {
        let styled = "\u{1B}[32mUP\u{1B}[0m"
        XCTAssertEqual(Terminal.displayWidth(styled), 2, "escapes must not count as width")
        XCTAssertEqual(Terminal.displayWidth("UP"), 2)
    }

    func testDisplayWidthCountsWideCharactersAsTwo() {
        // CJK and emoji occupy two terminal columns.
        XCTAssertEqual(Terminal.displayWidth("日本"), 4)
        XCTAssertEqual(Terminal.displayWidth("ab"), 2)
        XCTAssertEqual(Terminal.displayWidth("✓"), 1)
    }

    func testPadAlignsStyledTextCorrectly() {
        let styled = "\u{1B}[32mOK\u{1B}[0m"
        let padded = Terminal.pad(styled, to: 6)
        // Two visible characters plus four spaces, regardless of the escape bytes.
        XCTAssertEqual(Terminal.displayWidth(padded), 6)
    }

    func testPadRightAligns() {
        let padded = Terminal.pad("42", to: 6, alignment: .right)
        XCTAssertEqual(padded, "    42")
        XCTAssertEqual(Terminal.displayWidth(padded), 6)
    }

    func testTruncateAddsEllipsisAndRespectsWidth() {
        let truncated = Terminal.truncate("abcdefghij", to: 5)
        XCTAssertEqual(Terminal.displayWidth(truncated), 5)
        XCTAssertTrue(truncated.hasSuffix("…"))
        XCTAssertTrue(truncated.hasPrefix("abcd"))
    }

    func testTruncateLeavesShortTextAlone() {
        XCTAssertEqual(Terminal.truncate("abc", to: 10), "abc")
    }

    func testTruncateHandlesDegenerateWidths() {
        XCTAssertEqual(Terminal.truncate("abc", to: 0), "")
        XCTAssertEqual(Terminal.truncate("abc", to: 1), "a")
    }

    func testColourCanBeDisabled() {
        XCTAssertEqual(Terminal.colour("x", .green, enabled: false), "x")
        XCTAssertTrue(Terminal.colour("x", .green, enabled: true).contains("\u{1B}[32m"))
    }

    /// Truncating styled text counts only visible characters and never slices an escape.
    ///
    /// The per-character walk treated the escape bytes as width-1 text, so styled lines were cut
    /// short and could end in a bare `ESC` — the start of a sequence the terminal never receives
    /// the end of.
    func testTruncateKeepsEscapeSequencesWhole() {
        let styled = "\u{1B}[31mabcdef\u{1B}[0m"
        let truncated = Terminal.truncate(styled, to: 5)
        XCTAssertEqual(truncated, "\u{1B}[31mabcd…")
        XCTAssertEqual(Terminal.displayWidth(truncated), 5)

        // The reset must survive: a coloured line truncated without it would bleed into the next.
        let mixed = "\u{1B}[31mred\u{1B}[0m and more"
        let truncatedMixed = Terminal.truncate(mixed, to: 7)
        XCTAssertEqual(truncatedMixed, "\u{1B}[31mred\u{1B}[0m an…")
        XCTAssertEqual(Terminal.displayWidth(truncatedMixed), 7)
    }

    /// A one-column budget cannot hold a character *and* an ellipsis, and must still not emit half
    /// an escape sequence.
    func testTruncateToOneColumnDropsLeadingEscapesRatherThanSlicingThem() {
        XCTAssertEqual(Terminal.truncate("\u{1B}[31mabc", to: 1), "a")
    }

    /// Control characters are replaced, never passed to the terminal.
    ///
    /// A terminal executes these bytes: `ESC[2J` clears the screen, `ESC]52;c;…` writes the
    /// clipboard on terminals that allow it. The probe data that reaches the renderer comes
    /// from a SearXNG instance, so it is not text this program authored.
    func testSanitizeReplacesControlCharactersWithAVisiblePlaceholder() {
        let hostile = "brave\u{1B}]52;c;cGF3bmVk\u{07}google\u{9B}31m\n"
        let safe = Terminal.sanitize(hostile)
        XCTAssertFalse(safe.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
        XCTAssertFalse(safe.unicodeScalars.contains { (0x80...0x9F).contains($0.value) })
        XCTAssertEqual(safe, "brave\u{FFFD}]52;c;cGF3bmVk\u{FFFD}google\u{FFFD}31m\u{FFFD}")
    }

    /// Format characters are replaced too: they reorder or hide text without taking a column.
    func testSanitizeStripsFormatCharactersAndLeavesOrdinaryTextAlone() {
        XCTAssertEqual(Terminal.sanitize("google cse"), "google cse")
        XCTAssertEqual(Terminal.sanitize("日本語 ✓ — dash"), "日本語 ✓ — dash")
        XCTAssertEqual(
            Terminal.sanitize("a\u{200B}b\u{202E}c\u{FEFF}d"),
            "a\u{FFFD}b\u{FFFD}c\u{FFFD}d"
        )
    }
}
