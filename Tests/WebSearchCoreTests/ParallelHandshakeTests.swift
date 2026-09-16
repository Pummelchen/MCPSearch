import Foundation
import XCTest

@testable import WebSearchCore

/// The Parallel MCP handshake, made deterministic.
///
/// `ParallelMCPProvider` is an actor, and actors are re-entrant across `await`, so the
/// "have I initialised yet" window only exists at a suspension point. These tests hold the
/// transport's `initialize` response open to keep that window open deliberately rather than
/// hoping a real transport's latency exposes it.
final class ParallelHandshakeTests: XCTestCase {

    private let configuration = Fixtures.configuration()

    private func parallelProvider(_ http: any HTTPClient) -> ParallelMCPProvider {
        ParallelMCPProvider(
            endpoint: URL(string: "https://parallel.example.com/mcp")!,
            http: http,
            configuration: configuration,
            enabled: true
        )
    }

    /// Two searches that arrive before the first handshake finishes must share one handshake.
    ///
    /// The gate holds the first `initialize` open, so the second caller provably runs while
    /// `sessionID` is still nil — the window the fix closes. Without the cached handshake
    /// task the second caller sends its own `initialize` immediately, which the transport
    /// records.
    func testParallelMCPHandshakesOnceWhenTwoSearchesRaceOnFirstUse() async throws {
        let http = GatedInitializeHTTPClient()
        let provider = parallelProvider(http)

        let first = Task { try await provider.search(Fixtures.request("first")) }
        await http.waitUntilInitializeIsParked()

        let second = Task {
            // Signal that this caller is running before it enters the actor, so the spin
            // below waits on a task that is already mid-flight rather than one still queued.
            await http.markSecondCallerStarted()
            return try await provider.search(Fixtures.request("second"))
        }
        await http.waitUntilSecondCallerStarted()

        // Let the second caller reach `ensureInitialized`. The defective implementation
        // sends its own `initialize` as soon as it gets the actor; the fixed one parks on
        // the shared handshake task and sends nothing. The handshake stays parked either
        // way, so this spin is only a scheduling grace, not a race being waited out.
        var spins = 0
        var initializeCount = await http.initializeCount
        while initializeCount < 2 && spins < 200 {
            await Task.yield()
            initializeCount = await http.initializeCount
            spins += 1
        }

        XCTAssertEqual(
            initializeCount,
            1,
            "concurrent first use must perform the MCP handshake exactly once"
        )

        await http.releaseInitialize()
        let firstResponse = try await first.value
        let secondResponse = try await second.value

        XCTAssertEqual(firstResponse.results.count, 1)
        XCTAssertEqual(secondResponse.results.count, 1)
        // The whole handshake, not just `initialize`, must happen once.
        let finalInitializeCount = await http.count(of: "initialize")
        let notificationCount = await http.count(of: "notifications/initialized")
        let toolsListCount = await http.count(of: "tools/list")
        let toolCallCount = await http.count(of: "tools/call")
        XCTAssertEqual(finalInitializeCount, 1)
        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(toolsListCount, 1)
        XCTAssertEqual(toolCallCount, 2)
    }
}

/// A transport that holds the first `initialize` open until the test releases it.
///
/// The provider is an actor, so its handshake window only opens when a suspension point is
/// reached; parking the `initialize` response keeps that window open for as long as the test
/// needs, instead of hoping a real transport's latency exposes it. Later
/// `initialize` requests are answered immediately, which is what makes a second handshake
/// observable.
private actor GatedInitializeHTTPClient: HTTPClient {
    private var methods: [String] = []
    private var firstInitializeSeen = false
    private var releaseRequested = false
    private var parked: CheckedContinuation<Void, Never>?
    private var initializeArrived: CheckedContinuation<Void, Never>?
    private var secondCallerSeen = false
    private var secondCallerArrived: CheckedContinuation<Void, Never>?

    var initializeCount: Int { methods.filter { $0 == "initialize" }.count }

    func count(of method: String) -> Int { methods.filter { $0 == method }.count }

    /// Suspends until the first `initialize` has been received and about to park.
    func waitUntilInitializeIsParked() async {
        if firstInitializeSeen { return }
        await withCheckedContinuation { initializeArrived = $0 }
    }

    /// Called by the second caller before it enters the provider, so the test can wait for a
    /// task that is already mid-flight.
    func markSecondCallerStarted() {
        secondCallerSeen = true
        secondCallerArrived?.resume()
        secondCallerArrived = nil
    }

    func waitUntilSecondCallerStarted() async {
        if secondCallerSeen { return }
        await withCheckedContinuation { secondCallerArrived = $0 }
    }

    func releaseInitialize() {
        releaseRequested = true
        parked?.resume()
        parked = nil
    }

    func send(_ request: HTTPRequest, maxBytes: Int) async throws -> HTTPResponse {
        let body =
            (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) })
            as? [String: Any] ?? [:]
        let method = body["method"] as? String ?? ""
        let id = body["id"] as? Int ?? 0
        methods.append(method)

        if method == "initialize" && !firstInitializeSeen {
            firstInitializeSeen = true
            initializeArrived?.resume()
            initializeArrived = nil
            if !releaseRequested {
                await withCheckedContinuation { parked = $0 }
            }
        }

        return Self.response(for: method, id: id, url: request.url)
    }

    private static func response(for method: String, id: Int, url: URL) -> HTTPResponse {
        let headers = ["content-type": "application/json", "MCP-Session-Id": "sess-gated"]
        switch method {
        case "initialize":
            let json =
                #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"Parallel","version":"1.0.0"}}}"#
            return HTTPResponse(
                statusCode: 200, headers: headers, body: Data(json.utf8), url: url
            )
        case "notifications/initialized":
            return HTTPResponse(statusCode: 202, headers: [:], body: Data(), url: url)
        case "tools/list":
            let json =
                #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"web_search","inputSchema":{"type":"object","properties":{"max_results":{"type":"number"}}}}]}}"#
            return HTTPResponse(
                statusCode: 200, headers: headers, body: Data(json.utf8), url: url
            )
        default:
            let text =
                #"{"results":[{"title":"Gated","url":"https://example.com/gated","excerpts":["gated"]}]}"#
            let envelope: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["content": [["type": "text", "text": text]]],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
            return HTTPResponse(statusCode: 200, headers: headers, body: data, url: url)
        }
    }
}
