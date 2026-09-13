import Foundation
import XCTest

@testable import WebSearchCore

/// Regression tests for error-reporting defects.
///
/// These run the real executable over stdio so they exercise the whole path from a
/// provider/fetch failure through the MCP tool result. Every server is started with a
/// **scrubbed environment** so the tests are hermetic: an ambient `TAVILY_API_KEY`
/// exported for normal use must not be able to change the outcome.
final class ErrorReportingTests: XCTestCase {

    // The scrub list is shared with `StdioServerTests` and mirrored by
    // `scripts/mcp_smoke.py`; see `ServerTestSupport.providerEnvironmentVariables`.

    // MARK: - Server harness

    /// The one subprocess harness, shared with every other stdio test file.
    ///
    /// This file used to carry its own 85-line copy: same pipes, same newline framing, same
    /// scrub list, and a read loop with the unenforceable deadline (ledger B70). The copies had
    /// already drifted before being folded together (ledger B71).
    private typealias Server = ServerProcess

    private func startServer(environment: [String: String] = [:]) throws -> Server {
        let binary = try ServerTestSupport.binaryURL()

        let server = Server(binary: binary, environment: environment)
        try server.start()

        try server.send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "ErrorReportingTests", "version": "1.0.0"],
            ],
        ])
        _ = try server.readResponse(id: 1)
        try server.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return server
    }

    private func text(of result: [String: Any]) throws -> String {
        let payload = try XCTUnwrap(result["result"] as? [String: Any])
        let content = try XCTUnwrap(payload["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - Fetch errors must not be attributed to a search provider

    /// A `web_open` failure previously surfaced as "Tavily timed out." even though
    /// `web_open` never contacts a search provider.
    func testFetchFailureIsNotAttributedToASearchProvider() throws {
        let server = try startServer()
        defer { server.stop() }

        // `.invalid` is reserved by RFC 2606 and can never resolve, so this needs no
        // network and fails deterministically.
        let response = try server.call(
            id: 2,
            tool: "web_open",
            arguments: ["url": "https://nonexistent-host.invalid/page"]
        )
        let message = try text(of: response)

        XCTAssertTrue(
            message.contains("Could not fetch"),
            "expected a fetch-scoped error, got: \(message)"
        )
        XCTAssertTrue(
            message.contains("nonexistent-host.invalid"),
            "the error should name the host that failed, got: \(message)"
        )
        // No search provider may be blamed for a direct fetch.
        for name in ["Tavily", "Brave", "Mojeek", "Exa", "SearXNG", "Parallel"] {
            XCTAssertFalse(
                message.contains(name),
                "fetch error wrongly mentioned \(name): \(message)"
            )
        }
        let payload = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(payload["isError"] as? Bool, true)
    }

    /// A blocked URL keeps its own distinct message and must not be reported as a
    /// fetch failure.
    func testBlockedURLIsDistinctFromFetchFailure() throws {
        let server = try startServer()
        defer { server.stop() }

        let response = try server.call(
            id: 3,
            tool: "web_open",
            arguments: ["url": "http://169.254.169.254/latest/meta-data/"]
        )
        let message = try text(of: response)
        XCTAssertTrue(message.contains("Refused"), message)
        XCTAssertFalse(message.contains("Could not fetch"), message)
    }

    // MARK: - Explicit provider selection must not degrade silently

    /// Requesting one provider while a *different* provider is configured must fail
    /// with an error naming the requested provider, not silently fall back to
    /// whichever provider happens to be available.
    func testExplicitUnconfiguredProviderDoesNotSilentlyFallBack() throws {
        // SearXNG is configured, Tavily is not. Auto-selection would happily use
        // SearXNG, which is exactly the silent degradation this guards against.
        let server = try startServer(environment: [
            "SEARXNG_BASE_URL": "https://searx.example.invalid"
        ])
        defer { server.stop() }

        let response = try server.call(
            id: 4,
            tool: "web_search",
            arguments: ["query": "swift", "provider": "tavily", "mode": "fast"]
        )
        let payload = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(payload["isError"] as? Bool, true)

        let message = try text(of: response)
        XCTAssertTrue(
            message.contains("Tavily"),
            "the error must name the requested provider, got: \(message)"
        )
        XCTAssertTrue(
            message.contains("not configured") || message.contains("TAVILY_API_KEY"),
            "the error must explain the configuration gap, got: \(message)"
        )
    }

    /// A configured provider requested explicitly still works.
    func testExplicitConfiguredProviderSucceeds() throws {
        let stub = try LoopbackServer(responses: [
            .init(
                status: 200,
                body: """
                    {"query":"swift","results":[
                      {"url":"https://swift.org/","title":"Swift","content":"Swift.","engine":"brave"}
                    ],"answers":[],"corrections":[],"infoboxes":[],"suggestions":[],
                    "unresponsive_engines":[]}
                    """
            )
        ])
        let server = try startServer(environment: ["SEARXNG_BASE_URL": stub.baseURL.absoluteString])
        defer { server.stop() }

        let response = try server.call(
            id: 5,
            tool: "web_search",
            arguments: ["query": "swift", "provider": "searxng", "mode": "fast"]
        )
        let payload = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(payload["isError"] as? Bool, true)
        XCTAssertGreaterThan(stub.requestCount, 0)
    }

    // MARK: - Result shape

    /// Error results are text-only, which keeps them clear of the SDK's throwing
    /// generic `Codable` initializer.
    func testErrorResultIsTextOnly() throws {
        let server = try startServer()
        defer { server.stop() }

        let response = try server.call(
            id: 6,
            tool: "web_search",
            arguments: ["query": "swift"]
        )
        let payload = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(payload["isError"] as? Bool, true)
        XCTAssertNil(
            payload["structuredContent"],
            "error results should not carry structured content"
        )
        XCTAssertFalse(try text(of: response).isEmpty)
    }

    /// The unconfigured-provider message is stable enough to assert on, and the
    /// server must keep serving after producing errors.
    func testServerRemainsUsableAfterRepeatedErrors() throws {
        let server = try startServer()
        defer { server.stop() }

        for id in 7..<11 {
            let response = try server.call(
                id: id,
                tool: "web_search",
                arguments: ["query": "q\(id)"]
            )
            let payload = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(payload["isError"] as? Bool, true)
        }

        try server.send(["jsonrpc": "2.0", "id": 11, "method": "tools/list"])
        let listing = try server.readResponse(id: 11)
        let result = try XCTUnwrap(listing["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 4)
    }

    // MARK: - Error text hygiene (no server needed)

    /// A transport error must never echo the request URL.
    ///
    /// A `URLError` carries the failing URL in its `userInfo`, and some platforms build a
    /// description from it. Mojeek's credential travels as a query parameter, so echoing
    /// the request would put a live key into `providers_failed` and `web_search_status`.
    func testTransportErrorTextNeverEchoesTheRequestURL() {
        let request = URL(
            string: "https://api.mojeek.com/search?q=swift&api_key=tvly-not-a-real-key-000000"
        )!
        let transportError = URLError(
            .cannotConnectToHost,
            userInfo: [NSURLErrorFailingURLErrorKey: request]
        )

        let failure = ProviderFailure(provider: .mojeek, error: transportError)
        XCTAssertEqual(failure.category, .network)
        XCTAssertFalse(failure.message.contains("api_key"), failure.message)
        XCTAssertFalse(failure.message.contains("tvly-"), failure.message)
        XCTAssertFalse(failure.message.contains("mojeek.com"), failure.message)
        XCTAssertFalse(failure.message.isEmpty)

        // The same guarantee holds for the provider-scoped mapping and the HTTP error.
        let mapped = HTTPStatusMapper.map(transportError, provider: .mojeek)
        XCTAssertFalse(mapped.safeDescription.contains("api_key"), mapped.safeDescription)

        guard
            case .connectionFailed(_, let reason) = HTTPError.from(
                urlError: transportError,
                label: "mojeek"
            )
        else {
            return XCTFail("expected a connection failure")
        }
        XCTAssertFalse(reason.contains("api_key"), reason)
        XCTAssertFalse(reason.contains("mojeek.com"), reason)
    }

    /// The curated reason stays specific enough to diagnose, and identifies an unmapped
    /// code by number rather than by a platform string.
    func testTransportReasonsAreCuratedAndSpecific() {
        XCTAssertEqual(HTTPError.reason(for: .cannotFindHost), "the host could not be resolved")
        XCTAssertEqual(
            HTTPError.reason(for: .networkConnectionLost),
            "the network connection was lost"
        )
        XCTAssertEqual(
            HTTPError.reason(for: URLError.Code(rawValue: -12_345)),
            "the transport reported error -12345"
        )
    }
}
