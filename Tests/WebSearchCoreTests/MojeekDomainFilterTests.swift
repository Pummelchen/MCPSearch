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
