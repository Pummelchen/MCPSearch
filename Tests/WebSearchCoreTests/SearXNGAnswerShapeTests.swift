import Foundation
import XCTest

@testable import WebSearchCore

/// SearXNG's `answers` field, in the two shapes a real instance can produce.
///
/// This lives in its own file because `ProviderContractTests` sits against the file-length
/// envelope in `.swiftlint.yml`, and the answer shape is a self-contained contract rather than
/// another case in that suite's table.
///
/// The wire type is a list of **objects**: `get_json_response` builds
/// `[answer.as_dict() …]`, and `as_dict()` returns `{"answer": …, "url": …, "engine": …}`.
/// Decoding it as `[String]` did not return nil — `decodeIfPresent` throws `typeMismatch` — so
/// `Data.decodeJSON` reported `.malformedResponse` and the valid `results` beside it were discarded
/// for the whole query. `ProviderContractTests.testSearXNGHappyPath` only ever used
/// `"answers":[]`, which is why nothing caught it.
final class SearXNGAnswerShapeTests: XCTestCase {
    private let configuration = Fixtures.configuration()

    private func provider(_ http: MockHTTPClient) -> SearXNGProvider {
        SearXNGProvider(
            baseURL: URL(string: "https://searx.example.com")!,
            http: http,
            configuration: configuration
        )
    }

    func testAnswersAsObjectsDoNotDiscardTheResults() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            """
            {"query":"capital of France","results":[
              {"url":"https://example.com/paris","title":"Paris","content":"Capital.","engine":"duckduckgo"}
             ],
             "answers":[{"answer":"Paris","url":"https://example.com/paris","engine":"duckduckgo"}],
             "unresponsive_engines":[]}
            """
        )

        let response = try await provider(http).search(Fixtures.request("searxng"))

        XCTAssertEqual(
            response.results.count, 1, "an object-shaped answer must not discard the results"
        )
        XCTAssertEqual(response.answer, "Paris")
    }

    /// Plain strings are still accepted: answers are an optional extra on a response this provider
    /// does not control, so an unrecognised element must never cost the caller its results.
    func testAnswerAsAPlainStringIsStillRead() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            """
            {"query":"capital of France","results":[
              {"url":"https://example.com/paris","title":"Paris","content":"Capital.","engine":"duckduckgo"}
             ],
             "answers":["Paris"],"unresponsive_engines":[]}
            """
        )

        let response = try await provider(http).search(Fixtures.request("searxng"))

        XCTAssertEqual(response.answer, "Paris")
    }

    /// An answer entry the provider cannot read at all is ignored rather than fatal, and the
    /// results still come back. Before the fix this payload failed the whole search.
    func testAnUnreadableAnswerEntryIsIgnored() async throws {
        let http = MockHTTPClient()
        http.respondJSON(
            """
            {"query":"capital of France","results":[
              {"url":"https://example.com/paris","title":"Paris","content":"Capital.","engine":"duckduckgo"}
             ],
             "answers":[{"unexpected":"shape"},42],"unresponsive_engines":[]}
            """
        )

        let response = try await provider(http).search(Fixtures.request("searxng"))

        XCTAssertEqual(response.results.count, 1)
        XCTAssertNil(response.answer)
    }
}
