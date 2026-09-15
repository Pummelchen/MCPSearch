import Foundation
import WebSearchCore
import XCTest

/// The text half of a tool result, driven through the built executable.
///
/// `ToolOutputFormatter` lives in the `SwiftWebSearchMCP` executable target, which the
/// `WebSearchCoreTests` module cannot import — a unit test of `searchText`/`statusText` is not
/// expressible here. These tests therefore reach the formatter the way a client does, over a real
/// stdio MCP session against a loopback provider stub, which is the same route
/// `StdioServerTests` and `SchemaCompatibilityTests` take (ledger B100).
///
/// A separate file because `StdioServerTests.swift` sits close to SwiftLint's 1458-line
/// `file_length` ceiling; this is the split pattern B96 and B54 used.
final class ToolOutputFormatterTests: XCTestCase {

    // MARK: - Harness

    private func server(environment: [String: String]) throws -> ServerProcess {
        let process = ServerProcess(binary: try ServerTestSupport.binaryURL(), environment: environment)
        try process.start()
        try process.send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "ToolOutputFormatterTests", "version": "1.0.0"],
            ],
        ])
        let response = try process.readResponse(id: 1)
        XCTAssertNotNil(response["result"], "initialize failed: \(response)")
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return process
    }

    /// The concatenated text blocks of a tool result.
    private func text(of result: [String: Any]) throws -> String {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// A SearXNG JSON body with the given `results` array contents.
    private static func searchBody(resultsJSON: String) -> String {
        """
        {"query":"q","results":[\(resultsJSON)],"answers":[],"corrections":[],"infoboxes":[],
         "suggestions":[],"unresponsive_engines":[]}
        """
    }

    // MARK: - web_search text

    /// An all-empty search is a tool error, not the formatter's "No results." line.
    ///
    /// `searchText`'s `response.results.isEmpty` branch is unreachable through this executable:
    /// `SearchOrchestrator.search` throws `providersFailed`/`temporarilyUnavailable` before it
    /// constructs a response with no results, `SearchResponse` has exactly one construction site,
    /// and `SearchCache.store` refuses a response without usable results — so a cached empty one
    /// cannot exist either. This test pins the reachable behaviour so a change that made the
    /// empty rendering reachable would be noticed (ledger B100).
    func testAnAllEmptySearchIsAToolErrorNotAnEmptyRendering() throws {
        let stub = try LoopbackServer(responses: [
            .init(status: 200, body: Self.searchBody(resultsJSON: ""))
        ])
        let server = try server(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            // Caching would make a second call in this file serve the first body.
            "SEARCH_CACHE_TTL_SECONDS": "0",
        ])
        defer { server.stop() }

        let response = try server.call(
            id: 2,
            tool: "web_search",
            arguments: ["query": "empty result set", "mode": "fast"]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true, "\(result)")
        let rendered = try text(of: result)
        XCTAssertFalse(
            rendered.contains("No results."),
            "the empty rendering is the formatter's, and this path must not reach it: \(rendered)"
        )
        XCTAssertTrue(
            rendered.lowercased().contains("failed"),
            "the caller must be told the search failed: \(rendered)"
        )
    }

    /// A long snippet is clipped to `maximumSnippet` and marked with an ellipsis, so one verbose
    /// page cannot dominate the text an agent reads (ledger B100).
    func testLongSnippetIsClippedWithAnEllipsis() throws {
        let sentence = String(repeating: "x", count: 500)
        let stub = try LoopbackServer(responses: [
            .init(
                status: 200,
                body: Self.searchBody(
                    resultsJSON: """
                        {"url":"https://example.com/long","title":"Long page",
                         "content":"\(sentence)","engine":"brave"}
                        """
                )
            )
        ])
        let server = try server(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            "SEARCH_CACHE_TTL_SECONDS": "0",
        ])
        defer { server.stop() }

        let response = try server.call(
            id: 3,
            tool: "web_search",
            arguments: ["query": "long snippet", "mode": "fast"]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let rendered = try text(of: result)

        guard let snippetLine = rendered.split(separator: "\n").first(where: { $0.hasPrefix("Snippet: ") })
        else {
            return XCTFail("no snippet line in: \(rendered)")
        }
        let snippet = String(snippetLine.dropFirst("Snippet: ".count))
        XCTAssertTrue(snippet.hasSuffix("…"), "the clip must be marked: \(snippet.suffix(5))")
        // 400 characters plus the ellipsis.
        XCTAssertEqual(
            snippet.count,
            401,
            "the snippet must be clipped to the formatter's 400-character budget, got \(snippet.count)"
        )
        XCTAssertTrue(
            sentence.hasPrefix(String(snippet.dropLast())),
            "the kept text must be the head of the source snippet"
        )
        XCTAssertFalse(rendered.contains(sentence), "the full 500-character body must not survive")
    }

    /// A partial failure keeps its results and names the provider that did not answer, so a
    /// degraded search is not presented as a complete one (ledger B100).
    func testAFailedProviderIsListedInTheText() throws {
        // `open_web_search` has `isConfigured == true` unconditionally and its endpoint is
        // operator-supplied, so its failure can be made deterministic by pointing it at a port
        // that is certainly not listening rather than at a second response from the stub.
        let stub = try LoopbackServer(responses: [
            .init(
                status: 200,
                body: Self.searchBody(
                    resultsJSON: """
                        {"url":"https://example.com/ok","title":"OK page","content":"body",
                         "engine":"brave"}
                        """
                )
            )
        ])
        let deadEndpoint = try LoopbackServer(responses: [.init(status: 200, body: "{}")])
            .baseURL.absoluteString
        // `LoopbackServer` closes its listener in `deinit` and its accept thread captures `self`
        // weakly, so the reference above is the only owner: by the time the server below is
        // started the port refuses connections, which is the deterministic failure this test
        // needs. (A second response from the stub would race the concurrent fan-out instead.)

        let server = try server(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            "OPEN_WEB_SEARCH_URL": deadEndpoint,
            "SEARCH_PROVIDER_ORDER": "searxng,open_web_search",
            "SEARCH_CACHE_TTL_SECONDS": "0",
        ])
        defer { server.stop() }

        // `balanced` selects two direct providers, which is what gives the fan-out one healthy
        // provider and one that cannot connect. `fast` would select only SearXNG.
        let response = try server.call(
            id: 4,
            tool: "web_search",
            arguments: ["query": "partial failure", "mode": "balanced"]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "one provider answered: \(result)")

        let rendered = try text(of: result)
        XCTAssertTrue(
            rendered.contains("Unavailable providers: open_web_search"),
            "the failed provider must be named in the text: \(rendered)"
        )
        XCTAssertTrue(rendered.contains("[1] OK page"), rendered)
    }

    // MARK: - web_search_status text

    /// The diagnostic line carries the request counters, a non-closed circuit and the last error.
    ///
    /// The existing status test asserted only the structured payload, so `statusText`'s
    /// counters/circuit/error branches had never run (ledger B100).
    func testStatusTextCarriesCountersAndTheLastError() throws {
        // A 500 makes the provider fail without a second provider to mask it, so the state the
        // status call reads has a real failure on it.
        let stub = try LoopbackServer(responses: [
            .init(status: 500, body: "upstream exploded")
        ])
        let server = try server(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            "SEARCH_PROVIDER_ORDER": "searxng",
            "SEARCH_CACHE_TTL_SECONDS": "0",
        ])
        defer { server.stop() }

        let search = try server.call(
            id: 5,
            tool: "web_search",
            arguments: ["query": "force a failure", "mode": "fast"]
        )
        let searchResult = try XCTUnwrap(search["result"] as? [String: Any])
        XCTAssertEqual(
            searchResult["isError"] as? Bool, true,
            "a sole provider failing must be a tool error: \(searchResult)"
        )

        let status = try server.call(
            id: 6,
            tool: "web_search_status",
            arguments: [String: Any]()
        )
        let statusResult = try XCTUnwrap(status["result"] as? [String: Any])
        let rendered = try text(of: statusResult)

        guard let line = rendered.split(separator: "\n").first(where: { $0.contains("- searxng:") })
        else {
            return XCTFail("no searxng line in: \(rendered)")
        }
        // The counters must carry the failure, not merely be present: `requests=0 failed=0`
        // would satisfy a substring check while the failure branch never ran.
        func counter(_ name: String) -> Int? {
            guard let range = line.range(of: "\(name)=") else { return nil }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            return Int(digits)
        }
        XCTAssertGreaterThanOrEqual(counter("requests") ?? 0, 1, "\(line)")
        XCTAssertGreaterThanOrEqual(
            counter("failed") ?? 0, 1,
            "the failed counter must be non-zero: \(line)"
        )
        XCTAssertTrue(
            rendered.contains("last error:"),
            "the provider's last error must be rendered: \(rendered)"
        )
        XCTAssertTrue(rendered.contains("Cache: 0 entries"), rendered)
    }
}
