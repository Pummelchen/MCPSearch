import Foundation
import XCTest
@testable import WebSearchCore

extension HTTPTransportTests {

    func testInitializeIssuesASessionAndNegotiatesTheProtocolVersion() throws {
        try startServer()
        let (session, response) = try initializeSession()

        XCTAssertFalse(session.isEmpty)
        let object =
            try JSONSerialization.jsonObject(
                with: Data(Self.jsonMessage(from: response.body).utf8)
            ) as? [String: Any]
        let result = try XCTUnwrap(object?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "SwiftWebSearchMCP")
    }

    /// Every non-initialize request is answered as chunked Server-Sent Events, so the
    /// relay that frames and writes the SDK's stream is covered here rather than only in
    /// the Python smoke script.
    func testToolsListOverSSEStreamsTheToolInventory() throws {
        try startServer()
        let (session, _) = try initializeSession()

        let response = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders.merging(["Mcp-Session-Id": session]) { _, new in new },
            body: try toolsListBody()
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "text/event-stream")
        let object =
            try JSONSerialization.jsonObject(
                with: Data(Self.jsonMessage(from: response.body).utf8)
            ) as? [String: Any]
        let result = try XCTUnwrap(object?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(
            Set(tools.compactMap { $0["name"] as? String }),
            Set(["web_search", "web_open", "web_answer", "web_search_status"])
        )
    }

    // MARK: - Negative cases

    func testARequestWithoutASessionIsRefused() throws {
        try startServer()
        _ = try initializeSession()

        let response = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders,
            body: try toolsListBody()
        )
        XCTAssertGreaterThanOrEqual(
            response.status,
            400,
            "a request that carries no session id must be refused rather than served"
        )
        XCTAssertNotEqual(response.status, 200)
    }

    func testCrossOriginRequestIsRefusedButLoopbackOriginIsServed() throws {
        try startServer()
        let (session, _) = try initializeSession()

        let foreign = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders.merging(["Origin": "https://evil.example.com"]) { _, new in new }
                .merging(["Mcp-Session-Id": session]) { _, new in new },
            body: try toolsListBody()
        )
        XCTAssertEqual(
            foreign.status,
            403,
            "a browser page on another origin must not be able to drive this server"
        )

        // A name that merely starts with `127.` is not this machine, even though the hand-rolled
        // check used to accept it.
        let prefixed = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders
                .merging(["Origin": "http://127.0.0.1.attacker.example"]) { _, new in new }
                .merging(["Mcp-Session-Id": session]) { _, new in new },
            body: try toolsListBody()
        )
        XCTAssertEqual(
            prefixed.status,
            403,
            "a host name that starts with 127. is not a loopback origin"
        )

        // A loopback Origin is not cross-origin and must still be served.
        let local = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders
                .merging(["Origin": "http://127.0.0.1:\(port)"]) { _, new in new }
                .merging(["Mcp-Session-Id": session]) { _, new in new },
            body: try toolsListBody()
        )
        XCTAssertEqual(local.status, 200)
    }

    /// A deployment's own host name is served; an attacker's name is still refused.
    ///
    /// The validator was hard-coded to `127.0.0.1`/`localhost`/`[::1]`, so the documented
    /// `--host` plus TLS-proxy deployment answered every request with `421 Misdirected Request`
    /// before MCP handling ran. The allow-list is derived from the configuration now, and stays
    /// exact-match, so a browser page that resolves an attacker name to this machine still fails
    func testConfiguredPublicHostIsServedWhileAForeignHostIsRefused() throws {
        try startServer(extraArguments: ["--http-allowed-host", "search.example.com"])

        let allowed = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders,
            host: "search.example.com:\(port)",
            body: try initializeBody()
        )
        XCTAssertEqual(
            allowed.status,
            200,
            "the host the deployment declared must reach MCP: \(allowed.body)"
        )
        XCTAssertNotNil(allowed.headers["mcp-session-id"])

        let rebound = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders,
            host: "attacker.example.com:\(port)",
            body: try initializeBody()
        )
        XCTAssertEqual(
            rebound.status,
            421,
            "a name an attacker resolved to this machine must still be refused"
        )
    }

    func testOversizedBodyIsRefusedWithPayloadTooLarge() throws {
        try startServer()

        // Larger than HTTPRequestBodyPolicy.maximumBodyBytes (1 MiB). The body is sent without
        // a session on purpose: the cap is enforced in the network layer before the SDK
        // ever sees the request.
        let oversized = Data(repeating: UInt8(ascii: "x"), count: (1 << 20) + 4096)
        let response = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders,
            body: oversized
        )
        XCTAssertEqual(response.status, 413)
        XCTAssertTrue(response.body.contains("too large"), response.body)
    }

    func testUnknownPathIsNotFoundAndASessionlessNonInitializeIsBadRequest() throws {
        try startServer()

        let missing = try RawHTTP.request(port: port, method: "GET", path: "/nope")
        XCTAssertEqual(missing.status, 404)
        XCTAssertTrue(missing.body.contains("/mcp"), missing.body)

        // No session and not an `initialize`: the server must say which of the two is wrong.
        // It used to answer 405 with `Allow: POST`, which described the single-transport
        // design rather than the protocol.
        let sessionless = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders,
            body: try toolsListBody()
        )
        XCTAssertEqual(sessionless.status, 400)
        XCTAssertTrue(sessionless.body.contains("initialize"), sessionless.body)

        let unknownSession = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders.merging(["Mcp-Session-Id": "not-a-session"]) { _, new in new },
            body: try toolsListBody()
        )
        XCTAssertEqual(unknownSession.status, 404)
        XCTAssertTrue(unknownSession.body.contains("unknown"), unknownSession.body)
    }

    // MARK: - Sessions

    /// The transport used to be one per process, so a second client could never initialize
    /// (the SDK answers `400 Session already initialized`) for the life of the process. Two
    /// independent clients must now both work, with different session ids.
    func testTwoClientsEachGetTheirOwnSession() throws {
        try startServer()
        let (first, _) = try initializeSession()
        let (second, _) = try initializeSession()

        XCTAssertNotEqual(first, second, "each initialize must issue its own session id")

        for (label, session) in [("first", first), ("second", second)] {
            let response = try RawHTTP.request(
                port: port,
                method: "POST",
                path: "/mcp",
                headers: Self.mcpHeaders.merging(["Mcp-Session-Id": session]) { _, new in new },
                body: try toolsListBody()
            )
            XCTAssertEqual(response.status, 200, "\(label) client must be served")
            let object =
                try JSONSerialization.jsonObject(
                    with: Data(Self.jsonMessage(from: response.body).utf8)
                ) as? [String: Any]
            let result = try XCTUnwrap(object?["result"] as? [String: Any], label)
            XCTAssertNotNil(result["tools"] as? [[String: Any]], label)
        }
    }

    /// `DELETE` must reach the transport and release the session, so the same process can
    /// serve a client that reconnects with a new one.
}
