import Foundation
import XCTest

@testable import WebSearchCore

/// `HTTPMCPHost`'s startup and request-lifecycle arms, driven through the built executable.
///
/// The host lives in the `SwiftWebSearchMCP` executable target, which this test target cannot
/// import — the `RawHTTP` client and the free-port helper are shared with `HTTPTransportTests`
/// rather than copied. Everything here is loopback only.
final class HTTPMCPHostLifecycleTests: XCTestCase {
    private var process: Process?
    private var stderrPipe = Pipe()

    override func tearDown() {
        stopServer()
        super.tearDown()
    }

    // MARK: - Harness

    private func stderrText() -> String {
        String(bytes: stderrPipe.fileHandleForReading.availableData, encoding: .utf8)
            ?? "<not valid UTF-8>"
    }

    private func stopServer() {
        if let process {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        process = nil
    }

    /// Start the built server in HTTP mode and wait for `/health`.
    private func startServer(port: UInt16) throws {
        let process = Process()
        process.executableURL = try ServerTestSupport.binaryURL()
        process.arguments = ["--transport", "http", "--port", String(port)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        var environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        for key in ServerTestSupport.providerEnvironmentVariables {
            environment.removeValue(forKey: key)
        }
        environment["SEARCH_LOG_LEVEL"] = "warning"
        process.environment = ServerTestSupport.childEnvironment(base: environment)

        try process.run()
        self.process = process

        for _ in 0..<200 {
            guard process.isRunning else {
                return XCTFail("server exited before becoming healthy; stderr: \(stderrText())")
            }
            if let response = try? RawHTTP.request(port: port, method: "GET", path: "/health"),
                response.status == 200
            {
                return
            }
            usleep(50_000)
        }
        XCTFail("server did not become healthy; stderr: \(stderrText())")
    }

    private static let mcpHeaders = [
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    ]

    private func initializeBody() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "HTTPMCPHostLifecycleTests", "version": "1.0.0"],
            ],
        ])
    }

    private func toolsListBody() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ])
    }

    private func initializeSession(port: UInt16) throws -> String {
        let response = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders,
            body: try initializeBody()
        )
        XCTAssertEqual(response.status, 200, "initialize over HTTP: \(response.body)")
        return try XCTUnwrap(
            response.headers["mcp-session-id"],
            "initialize must issue an Mcp-Session-Id header"
        )
    }

    // MARK: - Startup failure

    /// A port that is already listening turns `start()`'s bind into `HTTPHostError.bindFailed`,
    /// which `main` logs and exits 1 on. The port is held by this test for the whole attempt, so
    /// the failure is certain rather than a lost race.
    ///
    /// This asserts `bindFailed`'s `description` through the only surface the executable exposes
    /// for it — the startup log line — because the type itself cannot be imported. The expected
    /// text is the documented `Could not bind <host>:<port> — <reason>`.
    func testStartingOnAPortAlreadyInUseExitsWithTheBindError() throws {
        let listening = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listening, 0, "could not create the holder socket")
        defer { close(listening) }
        var reuse: Int32 = 1
        setsockopt(listening, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listening, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0, "could not bind the holder socket")
        XCTAssertEqual(listen(listening, 1), 0, "could not listen on the holder socket")

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listening, $0, &length)
            }
        }
        let port = UInt16(bigEndian: actual.sin_port)

        let process = Process()
        process.executableURL = try ServerTestSupport.binaryURL()
        process.arguments = ["--transport", "http", "--port", String(port)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        var environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        for key in ServerTestSupport.providerEnvironmentVariables {
            environment.removeValue(forKey: key)
        }
        process.environment = ServerTestSupport.childEnvironment(base: environment)

        try process.run()
        process.waitUntilExit()

        let stderr =
            String(
                bytes: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "<not valid UTF-8>"
        XCTAssertEqual(process.terminationStatus, 1, "a failed bind must exit 1: \(stderr)")
        XCTAssertTrue(
            stderr.contains("Could not bind 127.0.0.1:\(port)"),
            "the host and port must name the address that failed: \(stderr)"
        )
        XCTAssertTrue(
            stderr.contains("Address already in use"),
            "the reason must carry the syscall's explanation: \(stderr)"
        )
    }

    // MARK: - Origin acceptance

    /// `localhost` and `[::1]` are loopback origins and must be served, not refused.
    ///
    /// The cross-origin test asserted only a foreign origin and `127.0.0.1`, so the other two arms
    /// of the allow-list had never run. The loopback form is also what a proxy that
    /// rewrites the authority can produce.
    func testLocalhostAndIPv6LoopbackOriginsAreServed() throws {
        let port = try HTTPTransportTests.freeLoopbackPort()
        try startServer(port: port)
        defer { stopServer() }
        let session = try initializeSession(port: port)

        for origin in ["http://localhost:\(port)", "http://[::1]:\(port)"] {
            let response = try RawHTTP.request(
                port: port,
                method: "POST",
                path: "/mcp",
                headers: Self.mcpHeaders
                    .merging(["Origin": origin]) { _, new in new }
                    .merging(["Mcp-Session-Id": session]) { _, new in new },
                body: try toolsListBody()
            )
            XCTAssertEqual(response.status, 200, "\(origin) names this machine: \(response.body)")
        }

        // The control: a name that merely looks local is still refused, so the two 200s above are
        // evidence about the allow-list and not about the check being skipped.
        let foreign = try RawHTTP.request(
            port: port,
            method: "POST",
            path: "/mcp",
            headers: Self.mcpHeaders
                .merging(["Origin": "http://localhost.attacker.example:\(port)"]) { _, new in new }
                .merging(["Mcp-Session-Id": session]) { _, new in new },
            body: try toolsListBody()
        )
        XCTAssertEqual(foreign.status, 403, "a lookalike host must not be accepted")
    }
}
