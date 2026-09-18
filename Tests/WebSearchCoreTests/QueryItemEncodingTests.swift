import Foundation
import XCTest

@testable import WebSearchCore

/// Query values containing `+`, which Foundation's `queryItems` setter leaves literal.
///
/// The `.queryItem` allowed mask includes `+` because RFC 3986 lists it as a sub-delimiter, so
/// `q=C++` was sent as written. DuckDuckGo, Startpage and SearXNG are form-style GET endpoints that
/// decode `+` as a space, so the engine received `C` and answered a different question than the one
/// asked (ledger A0050). Six providers built their URL the same way, and nothing asserted the
/// encoding.
final class QueryItemEncodingTests: XCTestCase {
    private let configuration = Fixtures.configuration()

    /// The regression, at the level a user would meet it: the provider's own request URL.
    func testAProviderEscapesAPlusInTheQuery() async throws {
        let http = MockHTTPClient()
        http.respondJSON(#"{"web":{"results":[]}}"#)
        let provider = BraveProvider(
            apiKey: "brave-secret",
            http: http,
            configuration: configuration
        )

        _ = try? await provider.search(SearchRequest(query: "C++ concurrency"))

        let url = try XCTUnwrap(http.requests.first?.url.absoluteString)
        XCTAssertTrue(url.contains("%2B%2B"), "a literal '+' would be read as a space: \(url)")
        XCTAssertFalse(url.contains("C++"), url)
    }

    /// The escape is precise: names and other values are left as Foundation encoded them.
    func testOnlyThePlusIsEscaped() {
        var components = URLComponents(string: "https://example.com/search")
        components?.setQueryItemsEscapingPlus([
            URLQueryItem(name: "q", value: "C++ concurrency"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "domains", value: "a.example,b.example"),
        ])

        let query = try? XCTUnwrap(components?.percentEncodedQuery)
        XCTAssertTrue(query?.contains("q=C%2B%2B") == true, "\(query ?? "")")
        XCTAssertTrue(query?.contains("format=json") == true, "\(query ?? "")")
        // A comma is a legal sub-delimiter too, and this test pins that it is left alone, so the
        // helper does not quietly become a general re-encoder.
        XCTAssertTrue(query?.contains("domains=a.example,b.example") == true, "\(query ?? "")")
    }
}
