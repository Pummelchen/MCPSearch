import Foundation
import XCTest

/// End-to-end tests that drive the **built executable** over a real MCP stdio session.
///
/// These are the only tests that exercise the whole product: framing, the tool list,
/// argument parsing, the SSE-free JSON-RPC handshake, and the guarantee that stdout
/// carries protocol traffic only.
final class StdioServerTests: XCTestCase {

    // MARK: - Process plumbing

    /// Locate the binary that `swift build` produced next to the test bundle.
    private func binaryURL() throws -> URL {
        // The test bundle lives in `.build/<triple>/debug/`, alongside the executable.
        let bundleDirectory = Bundle(for: StdioServerTests.self).bundleURL
            .deletingLastPathComponent()
        let candidate = bundleDirectory.appendingPathComponent("SwiftWebSearchMCP")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip(
                "Server executable not found at \(candidate.path); run `swift build` first."
            )
        }
        return candidate
    }

    /// A running server process with newline-delimited JSON-RPC framing.
    private final class ServerProcess {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        private var stdoutBuffer = Data()

        init(binary: URL, environment: [String: String]) {
            process.executableURL = binary
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
        }

        func start() throws {
            try process.run()
        }

        func send(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            var line = data
            line.append(UInt8(ascii: "\n"))
            stdinPipe.fileHandleForWriting.write(line)
        }

        /// Read one JSON object from stdout, blocking until a full line arrives.
        func readMessage(timeout: TimeInterval = 15) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                // Serve any complete line already buffered.
                if let newlineIndex = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex]
                    stdoutBuffer = Data(stdoutBuffer[stdoutBuffer.index(after: newlineIndex)...])
                    if lineData.isEmpty { continue }
                    guard
                        let object = try JSONSerialization.jsonObject(with: Data(lineData))
                            as? [String: Any]
                    else {
                        throw ServerTestError.malformedResponse(String(decoding: lineData, as: UTF8.self))
                    }
                    return object
                }

                let chunk = stdoutPipe.fileHandleForReading.availableData
                if chunk.isEmpty {
                    // EOF: the process exited without answering.
                    throw ServerTestError.unexpectedEOF(
                        stderr: String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    )
                }
                stdoutBuffer.append(chunk)
            }
            throw ServerTestError.timeout
        }

        /// Read messages until one has the requested JSON-RPC id.
        func readResponse(id: Int, timeout: TimeInterval = 15) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let message = try readMessage(timeout: max(0.1, deadline.timeIntervalSinceNow))
                if let messageID = message["id"] as? Int, messageID == id { return message }
                // Notifications are skipped; this server sends none, but tolerate them.
            }
            throw ServerTestError.timeout
        }

        func stderrText() -> String {
            let data = stderrPipe.fileHandleForReading.availableData
            return String(decoding: data, as: UTF8.self)
        }

        func stop() {
            try? stdinPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }
    }

    private enum ServerTestError: Error, CustomStringConvertible {
        case timeout
        case malformedResponse(String)
        case unexpectedEOF(stderr: String)

        var description: String {
            switch self {
            case .timeout: "timed out waiting for a response"
            case .malformedResponse(let text): "malformed JSON-RPC line: \(text)"
            case .unexpectedEOF(let stderr): "server exited early; stderr: \(stderr)"
            }
        }
    }

    /// Start a server, perform the initialize handshake, and return the process.
    private func startInitializedServer(
        environment: [String: String]
    ) throws -> ServerProcess {
        let binary = try binaryURL()
        let server = ServerProcess(binary: binary, environment: environment)
        try server.start()

        try server.send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "StdioServerTests", "version": "1.0.0"],
            ],
        ])

        let response = try server.readResponse(id: 1)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "SwiftWebSearchMCP")

        // Complete the handshake.
        try server.send([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ])
        return server
    }

    // MARK: - Protocol

    func testInitializeHandshakeSucceeds() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }
        // Reaching this point means a real initialize round trip completed.
    }

    func testToolsListExposesTheThreeDocumentedToolsWithValidSchemas() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        try server.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let response = try server.readResponse(id: 2)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), Set(["web_search", "web_open", "web_search_status"]))

        // Every tool must advertise a valid JSON Schema object.
        for tool in tools {
            let name = tool["name"] as? String ?? "?"
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any], "\(name) has no schema")
            XCTAssertEqual(schema["type"] as? String, "object", "\(name)")
            XCTAssertNotNil(schema["properties"] as? [String: Any], "\(name)")
        }

        // The public schema must expose only the documented common model.
        let search = try XCTUnwrap(tools.first { $0["name"] as? String == "web_search" })
        let schema = try XCTUnwrap(search["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(properties.keys),
            Set([
                "query", "max_results", "recency", "include_domains", "exclude_domains",
                "locale", "provider", "mode",
            ])
        )
        XCTAssertEqual(schema["required"] as? [String], ["query"])
        // Provider-specific tuning must not leak into the public contract.
        XCTAssertNil(properties["search_depth"])
        XCTAssertNil(properties["freshness"])
        XCTAssertNil(properties["goggles"])

        let open = try XCTUnwrap(tools.first { $0["name"] as? String == "web_open" })
        let openSchema = try XCTUnwrap(open["inputSchema"] as? [String: Any])
        XCTAssertEqual(openSchema["required"] as? [String], ["url"])
    }

    // MARK: - Tool calls

    func testSearchWithoutAnyProviderFailsActionablyRatherThanCrashing() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": ["name": "web_search", "arguments": ["query": "swift concurrency"]],
        ])
        let response = try server.readResponse(id: 3)
        let result = try XCTUnwrap(response["result"] as? [String: Any])

        // A configuration problem is a tool-level error, not a protocol failure.
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(
            text.contains("TAVILY_API_KEY") || text.contains("not configured"),
            "expected an actionable message, got: \(text)"
        )
    }

    func testSearchAgainstAStubProviderReturnsStructuredAndTextContent() throws {
        // A loopback endpoint stands in for SearXNG, exercising the real HTTP path,
        // normalization, fusion and MCP serialization end to end.
        let stub = try LoopbackServer(responses: [
            .init(
                status: 200,
                body: """
                {"query":"swift concurrency","results":[
                  {"url":"https://swift.org/documentation/concurrency/",
                   "title":"Concurrency | Swift Documentation",
                   "content":"Swift concurrency documentation.","engine":"brave"},
                  {"url":"https://example.com/second",
                   "title":"Second result","content":"Another result.","engine":"duckduckgo"}
                ],"answers":[],"corrections":[],"infoboxes":[],"suggestions":[],
                "unresponsive_engines":[]}
                """
            )
        ])

        let server = try startInitializedServer(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            "SEARCH_LOG_LEVEL": "debug",
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": [
                "name": "web_search",
                "arguments": ["query": "swift concurrency", "max_results": 5, "mode": "fast"],
            ],
        ])
        let response = try server.readResponse(id: 4)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true)

        // Structured content is present for clients that understand it.
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let results = try XCTUnwrap(structured["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0]["url"] as? String, "https://swift.org/documentation/concurrency/")
        XCTAssertEqual(results[0]["rank"] as? Int, 1)
        XCTAssertEqual(results[0]["sources"] as? [String], ["searxng"])
        XCTAssertEqual(structured["providers_used"] as? [String], ["searxng"])

        // A compact text rendering is present for clients that only surface text.
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("[1] Concurrency | Swift Documentation"))
        XCTAssertTrue(text.contains("URL: https://swift.org/documentation/concurrency/"))
        XCTAssertTrue(text.contains("Sources: searxng"))
        XCTAssertFalse(text.contains("\"results\""), "raw provider JSON must not be dumped")

        // The stub must actually have been called.
        XCTAssertGreaterThan(stub.requestCount, 0)
    }

    func testWebOpenRejectsDangerousSchemesAndInternalHosts() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        let cases: [(id: Int, url: String, expected: String)] = [
            (10, "file:///etc/passwd", "public http/https"),
            (11, "http://localhost:8080/admin", "public http/https"),
            (12, "http://169.254.169.254/latest/meta-data/", "public http/https"),
            (13, "http://10.0.0.1/", "public http/https"),
            (14, "javascript:alert(1)", "valid absolute URL"),
        ]

        for testCase in cases {
            try server.send([
                "jsonrpc": "2.0",
                "id": testCase.id,
                "method": "tools/call",
                "params": ["name": "web_open", "arguments": ["url": testCase.url]],
            ])
            let response = try server.readResponse(id: testCase.id)
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(
                result["isError"] as? Bool,
                true,
                "\(testCase.url) must be refused"
            )
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let text = content.compactMap { $0["text"] as? String }.joined()
            XCTAssertTrue(
                text.contains(testCase.expected) || text.contains("Refused"),
                "for \(testCase.url) expected \(testCase.expected), got: \(text)"
            )
        }
    }

    func testStatusToolReportsProviderConfiguration() throws {
        let server = try startInitializedServer(environment: ["SEARXNG_BASE_URL": "https://searx.example.com"])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 20,
            "method": "tools/call",
            "params": ["name": "web_search_status", "arguments": [String: Any]()],
        ])
        let response = try server.readResponse(id: 20)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let providers = try XCTUnwrap(structured["providers"] as? [[String: Any]])

        let searxng = try XCTUnwrap(providers.first { $0["provider"] as? String == "searxng" })
        XCTAssertEqual(searxng["configured"] as? Bool, true)
        XCTAssertEqual(searxng["source_family"] as? String, "meta")

        // Scrapers must report themselves as inert by default, with a reason.
        let duck = try XCTUnwrap(providers.first { $0["provider"] as? String == "duckduckgo" })
        XCTAssertEqual(duck["configured"] as? Bool, false)
        XCTAssertEqual(duck["is_experimental_scraper"] as? Bool, true)

        // No API key material may appear anywhere in a diagnostic payload.
        let serialized = String(describing: structured)
        for marker in ["api_key", "apiKey", "Bearer ", "X-Subscription-Token"] {
            XCTAssertFalse(serialized.contains(marker), "status leaked \(marker)")
        }
    }

    func testMalformedArgumentsProduceAnErrorResultNotAProtocolFailure() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        // Missing the required `query` field.
        try server.send([
            "jsonrpc": "2.0",
            "id": 30,
            "method": "tools/call",
            "params": ["name": "web_search", "arguments": ["max_results": 5]],
        ])
        let response = try server.readResponse(id: 30)
        XCTAssertNil(response["error"], "a bad argument must not be a protocol error")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)

        // A wrong argument type.
        try server.send([
            "jsonrpc": "2.0",
            "id": 31,
            "method": "tools/call",
            "params": [
                "name": "web_search",
                "arguments": ["query": "ok", "max_results": "not-a-number"],
            ],
        ])
        let second = try server.readResponse(id: 31)
        let secondResult = try XCTUnwrap(second["result"] as? [String: Any])
        XCTAssertEqual(secondResult["isError"] as? Bool, true)

        // An unknown tool.
        try server.send([
            "jsonrpc": "2.0",
            "id": 32,
            "method": "tools/call",
            "params": ["name": "does_not_exist", "arguments": [String: Any]()],
        ])
        let third = try server.readResponse(id: 32)
        let thirdResult = try XCTUnwrap(third["result"] as? [String: Any])
        XCTAssertEqual(thirdResult["isError"] as? Bool, true)
    }

    func testServerStaysResponsiveAfterAFailedToolCall() throws {
        // A failure must not poison the session or deadlock the message loop.
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        for id in 40..<44 {
            try server.send([
                "jsonrpc": "2.0",
                "id": id,
                "method": "tools/call",
                "params": ["name": "web_search", "arguments": ["query": "q\(id)"]],
            ])
            let response = try server.readResponse(id: id)
            XCTAssertNotNil(response["result"])
        }

        try server.send(["jsonrpc": "2.0", "id": 50, "method": "tools/list"])
        let response = try server.readResponse(id: 50)
        XCTAssertNotNil(response["result"])
    }

    func testLoggingNeverContaminatesStdout() throws {
        // Diagnostics must go to stderr; stdout is reserved for JSON-RPC framing. If a
        // stray `print` reached stdout, `readResponse` would fail to parse it.
        let server = try startInitializedServer(environment: ["SEARCH_LOG_LEVEL": "trace"])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 60,
            "method": "tools/call",
            "params": ["name": "web_search", "arguments": ["query": "anything"]],
        ])
        // Would throw `malformedResponse` if a log line appeared on stdout.
        let response = try server.readResponse(id: 60)
        XCTAssertNotNil(response["result"])

        // And the operator-facing diagnostics are on stderr.
        try server.send(["jsonrpc": "2.0", "id": 61, "method": "tools/list"])
        _ = try server.readResponse(id: 61)
        let stderr = String(
            decoding: server.stderrPipe.fileHandleForReading.availableData,
            as: UTF8.self
        )
        XCTAssertTrue(
            stderr.contains("SwiftWebSearchMCP"),
            "expected startup diagnostics on stderr, got: \(stderr.prefix(400))"
        )
    }
}
