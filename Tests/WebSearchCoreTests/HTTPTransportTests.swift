import Foundation
import XCTest

@testable import WebSearchCore

/// A synchronous, dependency-free HTTP/1.1 client for driving the server's
/// Streamable HTTP transport over a real loopback socket.
///
/// Deliberately raw rather than `URLSession`-based: the tests need to send an
/// oversized body that the server refuses mid-stream, and to inspect the exact status
/// line, headers and framing without a client library "helpfully" retrying or
/// normalising them away.
private struct RawHTTP {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    enum Failure: Error, CustomStringConvertible {
        case socket(String)
        case connect(String)
        case malformed(String)

        var description: String {
            switch self {
            case .socket(let detail): "socket failed: \(detail)"
            case .connect(let detail): "connect failed: \(detail)"
            case .malformed(let detail): "malformed HTTP response: \(detail)"
            }
        }
    }

    static func request(
        port: UInt16,
        method: String,
        path: String,
        headers: [String: String] = [:],
        host: String? = nil,
        body: Data? = nil,
        connectTimeout: TimeInterval = 5,
        readTimeoutMilliseconds: Int32 = 10_000
    ) throws -> Response {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(String(cString: strerror(errno))) }
        defer { close(fd) }

        // The body-cap test expects the server to close mid-send. Without SO_NOSIGPIPE
        // the process would die from SIGPIPE instead of surfacing EPIPE.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var receiveTimeout = timeval(tv_sec: Int(connectTimeout), tv_usec: 0)
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw Failure.connect(String(cString: strerror(errno))) }

        // The Host header is a parameter because it is exactly what the DNS-rebinding validator
        // decides on; a test cannot exercise that decision without choosing it (ledger B21).
        let hostHeader = host ?? "127.0.0.1:\(port)"
        var request = "\(method) \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nConnection: close\r\n"
        var effective = headers
        if let body { effective["Content-Length"] = String(body.count) }
        for (name, value) in effective.sorted(by: { $0.key < $1.key }) {
            request += "\(name): \(value)\r\n"
        }
        request += "\r\n"

        var payload = Data(request.utf8)
        if let body { payload.append(body) }
        try sendAll(fd: fd, payload: payload)

        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, readTimeoutMilliseconds)
            if ready <= 0 { break }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            raw.append(contentsOf: buffer[0..<count])
        }
        return try parse(raw)
    }

    private static func sendAll(fd: Int32, payload: Data) throws {
        var offset = 0
        while offset < payload.count {
            let sent = payload.withUnsafeBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return send(fd, base.advanced(by: offset), payload.count - offset, 0)
            }
            if sent <= 0 {
                // The server closed after refusing the body; whatever it wrote first is
                // still readable, so this is not an error.
                if errno == EPIPE || errno == ECONNRESET { return }
                throw Failure.socket(String(cString: strerror(errno)))
            }
            offset += sent
        }
    }

    private static func parse(_ raw: Data) throws -> Response {
        let text = (String(bytes: raw, encoding: .utf8) ?? "<not valid UTF-8>")
        guard let separator = text.range(of: "\r\n\r\n") else {
            throw Failure.malformed("no header terminator in \(text.prefix(120))")
        }
        let head = String(text[text.startIndex..<separator.lowerBound])
        var bodyText = String(text[separator.upperBound...])

        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else { throw Failure.malformed("empty response") }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw Failure.malformed("bad status line: \(statusLine)")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] == nil { headers[name] = value }
        }

        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            bodyText = dechunk(bodyText)
        }
        return Response(status: status, headers: headers, body: bodyText)
    }

    private static func dechunk(_ text: String) -> String {
        var remaining = Substring(text)
        var pieces: [String] = []
        while let lineEnd = remaining.range(of: "\r\n") {
            let sizeField = remaining[remaining.startIndex..<lineEnd.lowerBound]
                .split(separator: ";")[0]
            guard let size = Int(sizeField, radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            guard let end = remaining.index(start, offsetBy: size, limitedBy: remaining.endIndex)
            else { break }
            pieces.append(String(remaining[start..<end]))
            remaining = remaining[end...]
            if let next = remaining.range(of: "\r\n") { remaining = remaining[next.upperBound...] }
        }
        return pieces.joined()
    }
}

/// The Streamable HTTP transport, exercised over a real loopback socket.
///
/// `HTTPMCPHost` lives in the `SwiftWebSearchMCP` executable target, which this test
/// target cannot import: adding a dependency on it would mean editing `Package.swift`,
/// which is outside the scope of this change. Exactly as `StdioServerTests` does for
/// stdio, these tests therefore start the **built executable** in HTTP mode and speak
/// HTTP to it. Nothing here reaches the network beyond loopback.
final class HTTPTransportTests: XCTestCase {
    private var process: Process?
    /// Replaced for every attempt: a pipe belongs to the child it was attached to.
    private var stdoutPipe = Pipe()
    private var stderrPipe = Pipe()
    private var port: UInt16 = 0

    override func tearDown() {
        stopServer()
        super.tearDown()
    }

    // MARK: - Harness

    /// Ask the kernel for a free loopback port, so no fixed port is ever bound.
    ///
    /// The port is free *when it is chosen*, not reserved: the probe socket closes before the child
    /// binds, so anything on the machine can take it in that window. That is why `startServer`
    /// retries with a fresh port rather than assuming the kernel held this one (ledger B20).
    private static func freeLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RawHTTP.Failure.socket("could not create a probe socket") }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // Qualified: `NSObject` (and therefore `XCTestCase`) has a `bind` method
                // from Cocoa bindings, which would otherwise shadow the syscall.
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw RawHTTP.Failure.socket("could not bind a probe socket") }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return UInt16(bigEndian: actual.sin_port)
    }

    private func startServer(extraArguments: [String] = []) throws {
        let binary = try ServerTestSupport.binaryURL()
        var lastFailure = ""

        // Three attempts: one lost race is plausible, three in a row means something else is wrong
        // and the error below reports it.
        for _ in 1...3 {
            port = try Self.freeLoopbackPort()
            stdoutPipe = Pipe()
            stderrPipe = Pipe()

            let process = Process()
            process.executableURL = binary
            process.arguments =
                ["--transport", "http", "--port", String(port)] + extraArguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Hermetic, exactly like the stdio harness: no ambient provider credentials.
            var environment = [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            ]
            for key in ServerTestSupport.providerEnvironmentVariables {
                environment.removeValue(forKey: key)
            }
            environment["SEARCH_LOG_LEVEL"] = "warning"
            process.environment = ServerTestSupport.childEnvironment(base: environment)

            try process.run()
            self.process = process

            if let failure = waitForHealth(process) {
                lastFailure = failure
                stopServer()
                continue
            }
            return
        }

        throw RawHTTP.Failure.connect(
            "server did not become healthy on three free ports (last: \(lastFailure))"
        )
    }

    /// Poll `/health` until the child answers. Returns a description of the failure, or nil.
    ///
    /// 50 ms is the longest sleep this suite permits.
    private func waitForHealth(_ process: Process) -> String? {
        for _ in 0..<200 {
            guard process.isRunning else {
                return "server exited before becoming healthy; stderr: \(stderrText())"
            }
            if let response = try? RawHTTP.request(port: port, method: "GET", path: "/health"),
                response.status == 200
            {
                return nil
            }
            usleep(50_000)
        }
        return "server did not become healthy on port \(port); stderr: \(stderrText())"
    }

    private func stopServer() {
        if let process {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        process = nil
    }

    private func stderrText() -> String {
        (String(bytes: stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? "<not valid UTF-8>")
    }

    /// Perform the initialize handshake and return the session id it issued.
    private func initializeSession(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (session: String, response: RawHTTP.Response) {
        let body = try initializeBody()
        let response = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ],
            body: body
        )
        XCTAssertEqual(response.status, 200, "initialize over HTTP", file: file, line: line)
        let session = try XCTUnwrap(
            response.headers["mcp-session-id"],
            "initialize must issue an Mcp-Session-Id header",
            file: file,
            line: line
        )
        return (session, response)
    }

    /// A JSON-RPC `initialize` request, the only request that may create a session.
    private func initializeBody() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "HTTPTransportTests", "version": "1.0.0"],
                ],
            ]
        )
    }

    private func toolsListBody() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]
        )
    }

    private static let mcpHeaders = [
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    ]

    /// Extract the JSON-RPC object from either a bare JSON body or a chunked SSE stream.
    ///
    /// The stateful transport streams even `initialize` as Server-Sent Events, so the
    /// final `data: {...}` frame is the message; a client that only understood a bare
    /// JSON body would fail on a working server.
    private static func jsonMessage(from body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return trimmed }
        for line in trimmed.split(separator: "\n").reversed() {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard stripped.hasPrefix("data:") else { continue }
            let payload = stripped.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.hasPrefix("{") { return payload }
        }
        return trimmed
    }

    // MARK: - Liveness

    func testHealthEndpointAnswersTheDocumentedBody() throws {
        try startServer()

        let response = try RawHTTP.request(port: port, method: "GET", path: "/health")
        XCTAssertEqual(response.status, 200)
        // The exact body a container or proxy probe is documented to see.
        XCTAssertEqual(response.body, #"{"status":"ok"}"#)
        XCTAssertEqual(response.headers["content-type"], "application/json; charset=utf-8")

        // HEAD is supported for probes that do not want a body.
        let head = try RawHTTP.request(port: port, method: "HEAD", path: "/health")
        XCTAssertEqual(head.status, 200)
        XCTAssertTrue(head.body.isEmpty)
    }

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
        // check used to accept it (ledger B42).
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
    /// (ledger B21).
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

        // Larger than HTTPMCPHandler.maximumBodyBytes (1 MiB). The body is sent without
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
        // design rather than the protocol (ledger B03).
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
    /// independent clients must now both work, with different session ids (ledger B03).
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
    /// serve a client that reconnects with a new one (ledger B03).
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
}
