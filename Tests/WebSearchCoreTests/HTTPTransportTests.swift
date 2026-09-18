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
///
/// Internal rather than file-private so `HTTPMCPHostLifecycleTests` drives the same client
/// instead of growing a second copy of it.
struct RawHTTP {
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
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw Failure.connect(String(cString: strerror(errno))) }

        // The Host header is a parameter because it is exactly what the DNS-rebinding validator
        // decides on; a test cannot exercise that decision without choosing it.
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
                return Darwin.send(fd, base.advanced(by: offset), payload.count - offset, 0)
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

    // MARK: Descriptor-level helpers, for the connection-bound tests
    //
    // `request` writes a whole exchange, which is exactly what a test of a *partial* or
    // *absent* request must not do. These hand the caller the descriptor instead.

    /// Open a loopback connection and hand the descriptor to the caller.
    static func connect(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(String(cString: strerror(errno))) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw Failure.connect(detail)
        }
        return fd
    }

    /// Send raw bytes on a descriptor `connect` returned.
    static func send(fd: Int32, text: String) throws {
        try sendAll(fd: fd, payload: Data(text.utf8))
    }

    /// Read until the response head is complete, or fail after the deadline.
    static func readHead(fd: Int32, milliseconds: Int32) throws -> String {
        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while raw.range(of: Data("\r\n\r\n".utf8)) == nil {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, milliseconds) > 0 else {
                throw Failure.malformed("no response head within \(milliseconds) ms")
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                throw Failure.malformed("connection closed before a response head arrived")
            }
            raw.append(contentsOf: buffer[0..<count])
        }
        return String(bytes: raw, encoding: .utf8) ?? "<not valid UTF-8>"
    }

    /// True when the peer closed the connection within the window.
    ///
    /// Data that arrives first is consumed and the wait continues, so this answers "did the
    /// server hang up", not "is there anything to read".
    static func waitForEndOfStream(fd: Int32, milliseconds: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1_000)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = Int32((deadline.timeIntervalSinceNow * 1_000).rounded(.up))
            if remaining <= 0 { return false }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, remaining)
            if ready <= 0 { return false }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 { return true }
            if count < 0 { return errno != EAGAIN && errno != EINTR }
        }
    }

    /// Which of `fds` the peer has closed by the end of one shared wait.
    ///
    /// One sleep for all of them: waiting per descriptor would multiply the window by the
    /// number of connections.
    static func closedDescriptors(_ fds: [Int32], afterMilliseconds: Int32) -> [Int32] {
        usleep(useconds_t(afterMilliseconds) * 1_000)
        var closed: [Int32] = []
        for fd in fds {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 0) > 0 else { continue }
            var byte: UInt8 = 0
            if recv(fd, &byte, 1, 0) <= 0 { closed.append(fd) }
        }
        return closed
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

final class HTTPTransportTests: XCTestCase {
    var process: Process?
    /// Replaced for every attempt: a pipe belongs to the child it was attached to.
    private var stdoutPipe = Pipe()
    private var stderrPipe = Pipe()
    var port: UInt16 = 0

    override func tearDown() {
        stopServer()
        super.tearDown()
    }

    // MARK: - Harness

    /// Ask the kernel for a free loopback port, so no fixed port is ever bound.
    ///
    /// The port is free *when it is chosen*, not reserved: the probe socket closes before the child
    /// binds, so anything on the machine can take it in that window. That is why `startServer`
    /// retries with a fresh port rather than assuming the kernel held this one.
    ///
    /// Internal for `HTTPMCPHostLifecycleTests`, which needs the same "a free port, briefly" helper
    static func freeLoopbackPort() throws -> UInt16 {
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

    func startServer(
        extraArguments: [String] = [],
        extraEnvironment: [String: String] = [:]
    ) throws {
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
            for (key, value) in extraEnvironment {
                environment[key] = value
            }
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
    func initializeSession(
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
    func initializeBody() throws -> Data {
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

    func toolsListBody() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]
        )
    }

    static let mcpHeaders = [
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    ]

    /// Extract the JSON-RPC object from either a bare JSON body or a chunked SSE stream.
    ///
    /// The stateful transport streams even `initialize` as Server-Sent Events, so the
    /// final `data: {...}` frame is the message; a client that only understood a bare
    /// JSON body would fail on a working server.
    static func jsonMessage(from body: String) -> String {
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

    /// `/health` must describe the process, not assert a claim about it.
    ///
    /// This test used to pin the body to the exact string `{"status":"ok"}` — which is what the
    /// endpoint returned from a literal. That made the check the facade's accomplice: it passed
    /// for a body that was identical whether every provider was dead or the process had bricked
    /// after binding its port. The assertions below are the ones a literal cannot satisfy: the
    /// reported version has to come from `VERSION`, and the provider counts have to come from the
    /// live registry.
    func testHealthEndpointReportsTheProcessRatherThanAConstant() throws {
        try startServer()

        let response = try RawHTTP.request(port: port, method: "GET", path: "/health")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json; charset=utf-8")

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: String]
        )
        XCTAssertEqual(object["status"], "ok")
        // Derived, not declared: a hardcoded body cannot carry the version this binary was built
        // from, which is the same identity `initialize` reports and RELEASE.md §1.3 enforces.
        XCTAssertEqual(object["version"], BuildVersion.value)
        let total = try XCTUnwrap(object["providers_total"].flatMap(Int.init))
        let configured = try XCTUnwrap(object["providers_configured"].flatMap(Int.init))
        XCTAssertGreaterThan(total, 0, "the registry always has providers to report")
        XCTAssertGreaterThan(configured, 0, "a usable install has at least one provider configured")
        XCTAssertLessThanOrEqual(configured, total)

        // HEAD is supported for probes that do not want a body.
        let head = try RawHTTP.request(port: port, method: "HEAD", path: "/health")
        XCTAssertEqual(head.status, 200)
        XCTAssertTrue(head.body.isEmpty)
    }

}
