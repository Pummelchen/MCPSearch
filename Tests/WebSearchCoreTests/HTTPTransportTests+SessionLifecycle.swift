import Foundation
import XCTest
@testable import WebSearchCore

extension HTTPTransportTests {

    func testDeletingASessionReleasesItAndAllowsReconnecting() throws {
        try startServer()
        let (session, _) = try initializeSession()

        let released = try RawHTTP.request(
            port: port,
            method: "DELETE",
            path: "/mcp",
            headers: Self.mcpHeaders.merging(["Mcp-Session-Id": session]) { _, new in new }
        )
        XCTAssertEqual(released.status, 200, "the SDK acknowledges termination with 200")

        let afterRelease = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders.merging(["Mcp-Session-Id": session]) { _, new in new },
            body: try toolsListBody()
        )
        XCTAssertEqual(afterRelease.status, 404, "a released session must not be served")

        // The point of releasing: the process can serve the next client.
        let (reconnected, _) = try initializeSession()
        XCTAssertNotEqual(reconnected, session)
        let served = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders.merging(["Mcp-Session-Id": reconnected]) { _, new in new },
            body: try toolsListBody()
        )
        XCTAssertEqual(served.status, 200)
    }

    // MARK: - Connection bounds

    /// A connection that never sends a request is closed after the request budget, and the
    /// listener is unharmed. `SEARCH_REQUEST_TIMEOUT_MS` is the inbound budget as well as the
    /// outbound one, which is what makes this test fast.
    func testAnIdleConnectionIsClosedAndTheListenerKeepsServing() throws {
        try startServer(extraEnvironment: ["SEARCH_REQUEST_TIMEOUT_MS": "400"])

        let idle = try RawHTTP.connect(port: port)
        defer { close(idle) }

        XCTAssertTrue(
            RawHTTP.waitForEndOfStream(fd: idle, milliseconds: 5_000),
            "a connection that never completes a request must be closed after the request budget"
        )

        let health = try RawHTTP.request(port: port, method: "GET", path: "/health")
        XCTAssertEqual(health.status, 200, "the listener must keep serving after closing an idle peer")
    }

    /// The slowloris shape: a request whose headers never end. The deadline is armed when the
    /// channel becomes active, before a header is parsed, so this case is covered too.
    func testAPartialRequestIsClosedBeforeItCompletes() throws {
        try startServer(extraEnvironment: ["SEARCH_REQUEST_TIMEOUT_MS": "400"])

        let slow = try RawHTTP.connect(port: port)
        defer { close(slow) }
        try RawHTTP.send(fd: slow, text: "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n")

        XCTAssertTrue(
            RawHTTP.waitForEndOfStream(fd: slow, milliseconds: 5_000),
            "a request that never ends must be closed after the request budget"
        )
    }

    /// A standalone SSE stream is a *completed* request with a long-lived response, not an idle
    /// connection: the deadline is disarmed when the request ends, so the stream outlives the
    /// request budget several times over.
    func testAStandaloneSSEStreamOutlivesTheRequestBudget() throws {
        try startServer(extraEnvironment: ["SEARCH_REQUEST_TIMEOUT_MS": "400"])
        let (session, _) = try initializeSession()

        let stream = try RawHTTP.connect(port: port)
        defer { close(stream) }
        try RawHTTP.send(
            fd: stream,
            text: "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
                + "Accept: text/event-stream\r\nMcp-Session-Id: \(session)\r\n\r\n"
        )

        let head = try RawHTTP.readHead(fd: stream, milliseconds: 5_000)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), head)
        XCTAssertTrue(head.lowercased().contains("text/event-stream"), head)

        XCTAssertFalse(
            RawHTTP.waitForEndOfStream(fd: stream, milliseconds: 2_000),
            "a completed request's streaming response must not be closed as an idle connection"
        )
    }

    /// Connections beyond the listener's bound are refused rather than held. Eighty is
    /// deliberately more than the bound, and fewer than the request budget allows, so the only
    /// reason any of them closes inside the window is the bound itself.
    func testConnectionsBeyondTheListenerBoundAreRefused() throws {
        try startServer()

        var descriptors: [Int32] = []
        for _ in 0..<80 {
            descriptors.append(try RawHTTP.connect(port: port))
        }
        defer { for fd in descriptors { close(fd) } }

        let closed = RawHTTP.closedDescriptors(descriptors, afterMilliseconds: 2_000)
        XCTAssertFalse(closed.isEmpty, "the listener must refuse connections past its bound")

        // Release the held connections — they count against the bound, so a health request now
        // would be refused too — and wait for the listener to notice.
        for fd in descriptors { close(fd) }
        descriptors = []
        var health: RawHTTP.Response?
        for _ in 0..<40 {
            health = try? RawHTTP.request(port: port, method: "GET", path: "/health")
            if health?.status == 200 { break }
            usleep(50_000)
        }
        XCTAssertEqual(
            health?.status,
            200,
            "the listener must serve again once the refused peers are gone"
        )
    }
}
