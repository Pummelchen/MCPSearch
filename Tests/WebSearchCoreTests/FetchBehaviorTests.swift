import Foundation
import XCTest

@testable import WebSearchCore

/// `web_open`'s direct fetch path, exercised against a real socket.
///
/// These tests exist because the HTTP status path was the hole left after the earlier
/// attribution fix: only a DNS failure was covered, so `web_open` could still report an
/// HTTP 403 on an unrelated page as a Tavily network failure. There was also no test at
/// all for a fetch that succeeds.
final class FetchBehaviorTests: XCTestCase {

    private func makeFetcher() -> DirectHTTPFetcher {
        // The loopback test server is on 127.0.0.1, which the SSRF policy refuses by
        // design. The opt-in is what makes it reachable, exactly as it would be for a
        // deliberately internal deployment.
        DirectHTTPFetcher(
            configuration: Fixtures.configuration(),
            policy: URLPolicy(allowPrivateNetwork: true),
            log: .disabled
        )
    }

    private func fetch(_ server: LoopbackServer) async throws -> FetchResult {
        try await makeFetcher().fetch(
            FetchRequest(url: server.baseURL),
            maxRedirects: 5,
            allowedContentTypePrefixes: ["text/", "application/json"],
            maxCharacters: 12_000
        )
    }

    func testNonSuccessStatusIsReportedAsAFetchFailure() async throws {
        let server = try LoopbackServer(responses: [.init(status: 403, body: "denied")])

        do {
            _ = try await fetch(server)
            XCTFail("expected a fetch failure")
        } catch let error as SearchError {
            guard case .fetchFailed(let url, let reason) = error else {
                return XCTFail("a 403 must be a fetch failure, got \(error)")
            }
            XCTAssertEqual(url, server.baseURL)
            XCTAssertTrue(reason.contains("403"), reason)
            // No search provider may be named: this request never involved one.
            for name in ["Tavily", "Brave", "Mojeek", "Exa", "SearXNG", "Parallel"] {
                XCTAssertFalse(
                    error.safeDescription.contains(name),
                    "fetch error wrongly mentioned \(name): \(error.safeDescription)"
                )
            }
        }
    }

    func testMissingPageKeepsItsOwnDistinctError() async throws {
        let server = try LoopbackServer(responses: [.init(status: 404, body: "gone")])

        do {
            _ = try await fetch(server)
            XCTFail("expected a failure")
        } catch let error as SearchError {
            guard case .extractionFailed = error else {
                return XCTFail("a 404 is an extraction failure, got \(error)")
            }
        }
    }

    func testSuccessfulHTMLFetchProducesReadableText() async throws {
        let body = String(repeating: "Structured concurrency keeps tasks scoped. ", count: 20)
        let html = """
            <html><head><title>Swift Concurrency</title></head>
            <body><nav>menu</nav><article><h1>Swift Concurrency</h1>
            <p>\(body)</p>
            </article><footer>footer</footer></body></html>
            """
        let server = try LoopbackServer(responses: [
            .init(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: html
            )
        ])

        let result = try await fetch(server)

        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.method, .htmlExtraction)
        XCTAssertEqual(result.title, "Swift Concurrency")
        XCTAssertTrue(result.text.contains("Structured concurrency"), result.text)
        XCTAssertFalse(result.text.contains("menu"), "navigation must be removed")
        XCTAssertFalse(result.truncated)
    }

    /// The renderer uses this to decide whether a synthesised `# Title` heading would just
    /// repeat the first line of the body, which it did on nearly every page.
    func testTextAlreadyOpeningWithTheTitleIsDetected() {
        func result(title: String?, text: String) -> FetchResult {
            FetchResult(
                finalURL: URL(string: "https://example.com/")!,
                statusCode: 200,
                contentType: "text/html",
                title: title,
                text: text,
                method: .htmlExtraction,
                truncated: false
            )
        }

        XCTAssertTrue(
            result(title: "Swift Concurrency", text: "Swift Concurrency\nBody text")
                .textAlreadyOpensWithTitle
        )
        XCTAssertTrue(
            result(title: "Swift Concurrency", text: "# swift concurrency\nBody text")
                .textAlreadyOpensWithTitle,
            "a heading marker and different casing are still the same title"
        )
        XCTAssertFalse(
            result(title: "Swift Concurrency", text: "Introduction\nBody text")
                .textAlreadyOpensWithTitle,
            "a body that opens with something else still wants the heading"
        )
        XCTAssertFalse(
            result(title: nil, text: "Swift Concurrency\nBody text").textAlreadyOpensWithTitle
        )
        XCTAssertFalse(
            result(title: "Swift Concurrency", text: "").textAlreadyOpensWithTitle
        )
    }
}
