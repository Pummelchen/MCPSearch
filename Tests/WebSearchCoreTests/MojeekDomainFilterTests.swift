import Foundation
import XCTest

@testable import WebSearchCore

/// Mojeek's domain filters, which are a comma-separated list and were not.
///
/// In its own file because `ProviderContractTests` sits against the file-length envelope in
/// `.swiftlint.yml`; adding this test there pushed it past the ceiling, and the ceiling is a number
/// to stay under rather than to raise.
///
/// `docs/provider-api-notes.md:58` records `fi`/`fe` as "comma-separated domain names". The provider
/// joined them with a space, which Mojeek reads as a single malformed domain, so a caller's filter
/// was silently ignored and unfiltered results came back as though it had applied.
final class MojeekDomainFilterTests: XCTestCase {
    private let configuration = Fixtures.configuration()

    /// `timestamp` is present in the response only when `date=1` asks for it, and it defaults to 0.
    ///
    /// The provider read `item.timestamp` but never requested it, so `publishedAt` was always nil.
    /// Mojeek's parameter documentation lists `date` as "Include the last modified date as recognised
    /// by Mojeek", valid `[0|1]`, **default 0**.
    func testTheRequestAsksForTheDateAndUsesWhatComesBack() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            #"{"response":{"status":"OK","results":[{"title":"T","url":"https://example.com/a","desc":"d","timestamp":1700000000}]}}"#
        )
        let provider = MojeekProvider(
            apiKey: "k",
            http: http,
            configuration: Fixtures.configuration()
        )

        let results = try await provider.search(Fixtures.request("swift"))

        let url = try XCTUnwrap(http.requests.first?.url.absoluteString)
        XCTAssertTrue(
            url.contains("date=1"),
            "the response's timestamp is only sent when it is asked for: \(url)"
        )
        // And the field that arrives is used, so the parameter is not merely decorative.
        XCTAssertEqual(
            results.results.first?.publishedAt,
            Date(timeIntervalSince1970: 1_700_000_000),
            "\(String(describing: results.results.first))"
        )
    }

    func testFiltersAreCommaSeparated() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            #"{"response":{"status":"OK","head":{"results":0,"start":1,"return":10},"results":[]}}"#
        )
        let provider = MojeekProvider(
            apiKey: "mojeek-secret",
            http: http,
            configuration: configuration
        )

        _ = try await provider.search(
            SearchRequest(
                query: "swift concurrency",
                includeDomains: ["example.com", "example.org"],
                excludeDomains: ["spam.test"]
            )
        )

        // Compared through `queryItems`, which decodes percent-encoding, so the assertion is about
        // the value Mojeek receives rather than how Foundation chose to escape it.
        let request = try XCTUnwrap(http.requests.first)
        let items = try XCTUnwrap(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(
            items.first { $0.name == "fi" }?.value,
            "example.com,example.org",
            "include domains must be comma-separated"
        )
        XCTAssertEqual(
            items.first { $0.name == "fe" }?.value,
            "spam.test",
            "exclude domains must be comma-separated"
        )
    }
}
