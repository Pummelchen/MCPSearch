import Foundation
import XCTest

@testable import WebSearchCore

/// The response charset, which was discarded before decoding.
///
/// `mimeType(from:)` keeps only the part before `;`, so the `charset` parameter never reached the
/// decoder and the body fell straight to UTF-8-then-Latin-1. Latin-1 cannot fail, so a page served
/// as windows-1251, Shift_JIS or GBK was silently decoded into mojibake — wrong characters
/// presented as success, with no warning and no truncation flag.
final class CharsetDecodingTests: XCTestCase {
    private let cyrillic = "Привет мир"

    func testTheDeclaredCharsetIsUsed() throws {
        let body = try XCTUnwrap(cyrillic.data(using: .windowsCP1251))

        let decoded = DirectHTTPFetcher.decodeText(
            body,
            contentType: "text/html; charset=windows-1251"
        )

        XCTAssertEqual(decoded, cyrillic)
        // The fallback really would have got it wrong, which is why the parameter matters rather
        // than being a cosmetic detail.
        XCTAssertNotEqual(String(data: body, encoding: .isoLatin1), cyrillic)
    }

    /// A quoted charset, which servers emit just as often as the bare form.
    func testAQuotedCharsetIsRead() throws {
        let body = try XCTUnwrap(cyrillic.data(using: .windowsCP1251))

        let decoded = DirectHTTPFetcher.decodeText(
            body,
            contentType: "text/html; charset=\"windows-1251\""
        )

        XCTAssertEqual(decoded, cyrillic)
    }

    /// With no charset in the header, the document's own declaration is honoured rather than falling
    /// to Latin-1, which never fails and therefore never reports that it guessed wrong.
    func testTheDocumentsOwnDeclarationIsUsed() throws {
        let markup = "<html><head><meta charset=\"windows-1251\"></head><body>\(cyrillic)</body></html>"
        let body = try XCTUnwrap(markup.data(using: .windowsCP1251))

        let decoded = DirectHTTPFetcher.decodeText(body, contentType: "text/html")

        XCTAssertTrue(decoded.contains(cyrillic), decoded)
    }

    /// And the last resort is unchanged: a body that declares nothing is still decoded rather than
    /// refused, because an approximate page beats an error.
    func testAnUndeclaredBodyStillDecodes() {
        let decoded = DirectHTTPFetcher.decodeText(Data("plain ascii".utf8), contentType: "text/plain")

        XCTAssertEqual(decoded, "plain ascii")
    }
}
