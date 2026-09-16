import Foundation
import XCTest

/// The `ToolHandlers` cancellation arms, driven through a real MCP session.
///
/// A caller's cancellation propagates as a `CancellationError` instead of a provider failure, and
/// the tool layer answers each such arm with a fixed "cancelled" message. Nothing drove those arms:
/// reaching one needs a request that is still in flight when the client sends
/// `notifications/cancelled`, and the other harnesses never send it. The messages were therefore
/// asserted nowhere.
///
/// A test that merely cancelled and accepted *any* error would be a vacuous assertion, so each test
/// below asserts the exact message and that the failure message the arm is meant to replace did not
/// arrive.
///
/// All four arms are reachable and covered here. The fourth — the synthesis arm in `webAnswer` —
/// used to be dead: `AnswerSynthesizer.complete` folded every transport error into
/// `SearchError.synthesisFailed`, so a cancelled synthesis never arrived at `ToolHandlers` as a
/// `CancellationError`. Synthesis now propagates cancellation the way search and fetch do, and the
/// test below is the measurement that proves the arm runs: before that change the same call
/// returned a *success* result carrying the search results and `Answer synthesis failed: The
/// synthesis request failed.`, never the cancelled error.
final class ToolCancellationTests: XCTestCase {

    // MARK: - Harness

    /// A page the server never finishes.
    ///
    /// `Content-Length` declares far more than is sent and the connection is then held open, so
    /// the fetch or search is still in flight when the cancellation notification arrives.
    private static let stalled = LoopbackServer.Response(
        status: 200,
        headers: ["Content-Type": "text/html"],
        body: "<html><body><p>never delivered</p></body></html>",
        drip: .init(
            chunkBytes: 1,
            pauseMilliseconds: 0,
            holdOpenSeconds: 10,
            declaredBytes: 8 * 1024 * 1024
        )
    )

    private func startInitializedServer(environment: [String: String]) throws -> ServerProcess {
        let server = ServerProcess(
            binary: try ServerTestSupport.binaryURL(),
            environment: environment
        )
        try server.start()
        try server.send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "ToolCancellationTests", "version": "1.0.0"],
            ],
        ])
        _ = try server.readResponse(id: 1)
        try server.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return server
    }

    /// Wait until the stub has seen the request.
    ///
    /// That is also the point at which the server has recorded the in-flight handler task the
    /// cancellation notification cancels: the SDK stores the task before the handler can issue
    /// its first request. Without the ordering the notification could be read as "unknown
    /// request" and the call would run to the provider budget instead.
    private func waitUntilTheStubWasCalled(
        _ stub: LoopbackServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let deadline = Date().addingTimeInterval(5)
        while stub.requestCount == 0 {
            guard Date() < deadline else {
                return XCTFail("the stub provider was never called", file: file, line: line)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func cancel(_ id: Int, on server: ServerProcess) throws {
        try server.send([
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": id, "reason": "the client went away"],
        ])
    }

    /// The error text the caller sees, asserting first that the result *is* an error.
    private func errorText(_ response: [String: Any]) throws -> String {
        let result = try XCTUnwrap(response["result"] as? [String: Any], "\(response)")
        XCTAssertEqual(result["isError"] as? Bool, true, "\(response)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - web_search

    func testACancelledWebSearchSaysCancelledRatherThanBlamingEveryProvider() throws {
        let stub = try LoopbackServer(responses: [Self.stalled])
        let server = try startInitializedServer(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            "SEARCH_LOG_LEVEL": "warning",
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": [
                "name": "web_search",
                "arguments": ["query": "swift concurrency", "mode": "fast"],
            ],
        ])
        try waitUntilTheStubWasCalled(stub)
        try cancel(10, on: server)

        let text = try errorText(try server.readResponse(id: 10))
        XCTAssertEqual(text, "Search cancelled.")
        // The defect the arm exists to prevent: without it the cancellation falls to the
        // provider-failure or generic arm and the caller is told the search failed.
        XCTAssertFalse(
            text.contains("failed"),
            "a cancelled search must not be reported as a failure: \(text)"
        )
    }

    // MARK: - web_open

    func testACancelledWebOpenSaysCancelledRatherThanReportingAFetchFailure() throws {
        let stub = try LoopbackServer(responses: [Self.stalled])
        // The stub is loopback, so the SSRF policy has to be told this deployment permits it;
        // that flag is the only reason a test can point web_open at a scripted origin.
        let server = try startInitializedServer(environment: [
            "SEARCH_ALLOW_PRIVATE_NETWORK": "true",
            "SEARCH_LOG_LEVEL": "warning",
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/call",
            "params": [
                "name": "web_open",
                "arguments": ["url": stub.baseURL.absoluteString, "max_characters": 12_000],
            ],
        ])
        try waitUntilTheStubWasCalled(stub)
        try cancel(11, on: server)

        let text = try errorText(try server.readResponse(id: 11))
        XCTAssertEqual(text, "Fetch cancelled.")
        XCTAssertFalse(
            text.contains("Could not fetch"),
            "a cancelled fetch must not be reported as a fetch failure: \(text)"
        )
        XCTAssertFalse(text.contains("failed"), "\(text)")
    }

    // MARK: - web_answer, search phase

    /// The search half of `web_answer` runs the same pipeline as `web_search`, and its arm has to
    /// answer the same way: a cancellation is not a reason to synthesise from partial results.
    func testACancelledWebAnswerSearchPhaseSaysCancelled() throws {
        let stub = try LoopbackServer(responses: [Self.stalled])
        let server = try startInitializedServer(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            "SEARCH_LOG_LEVEL": "warning",
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 12,
            "method": "tools/call",
            "params": [
                "name": "web_answer",
                "arguments": ["query": "why did unix fail", "mode": "fast"],
            ],
        ])
        try waitUntilTheStubWasCalled(stub)
        try cancel(12, on: server)

        let text = try errorText(try server.readResponse(id: 12))
        XCTAssertEqual(text, "Search cancelled.")
        XCTAssertFalse(
            text.contains("failed"),
            "a cancelled search must not be reported as a failure: \(text)"
        )
    }

    // MARK: - web_answer, synthesis phase

    /// The synthesis half of `web_answer` must answer a cancellation the way the search and fetch
    /// halves do, rather than swallowing it into a synthesis failure.
    ///
    /// The search phase is served by a stub that answers immediately, so the request the
    /// cancellation interrupts is the synthesis one. That is why the wait is on the synthesis stub
    /// rather than on the search stub: it is the point at which the server is provably inside
    /// `synthesize`.
    func testACancelledWebAnswerSynthesisPhaseSaysCancelled() throws {
        let search = try LoopbackServer(responses: [
            .init(
                status: 200,
                body: """
                    {"query":"why did unix fail","results":[
                      {"url":"https://example.com/unix-decline","title":"Why Unix declined",
                       "content":"Unix declined for a documented reason.","engine":"brave"}
                    ],"answers":[],"corrections":[],"infoboxes":[],"suggestions":[],
                    "unresponsive_engines":[]}
                    """
            )
        ])
        // The answering model never finishes, so the call is still in flight when the client
        // cancels. A `.drip` response is what makes that state reachable without a real vendor.
        let synthesis = try LoopbackServer(responses: [Self.stalled])
        let server = try startInitializedServer(environment: [
            "SEARXNG_BASE_URL": search.baseURL.absoluteString,
            "DEEPSEEK_BASE_URL": synthesis.baseURL.absoluteString,
            "DEEPSEEK_API_KEY": "synthetic-synthesis-key-for-cancellation-tests",
            "SEARCH_LOG_LEVEL": "warning",
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 13,
            "method": "tools/call",
            "params": [
                "name": "web_answer",
                "arguments": ["query": "why did unix fail", "mode": "fast"],
            ],
        ])
        try waitUntilTheStubWasCalled(synthesis)
        XCTAssertGreaterThan(
            search.requestCount,
            0,
            "the search phase has to have answered before synthesis can be in flight"
        )
        try cancel(13, on: server)

        let text = try errorText(try server.readResponse(id: 13))
        XCTAssertEqual(text, "Answer synthesis cancelled.")
        // The defect this arm exists to prevent: without it the cancellation falls to the
        // synthesis-failure arm, which returns a *success* result carrying the documents and a
        // warning that synthesis failed.
        XCTAssertFalse(
            text.contains("synthesis failed"),
            "a cancelled synthesis must not be reported as a synthesis failure: \(text)"
        )
    }
}
