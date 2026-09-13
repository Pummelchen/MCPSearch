import Foundation
import WebSearchCore
import XCTest

/// End-to-end tests that drive the **built executable** over a real MCP stdio session.
///
/// These are the only tests that exercise the whole product: framing, the tool list,
/// argument parsing, the SSE-free JSON-RPC handshake, and the guarantee that stdout
/// carries protocol traffic only.
final class StdioServerTests: XCTestCase {

    // The scrub list is shared with `ErrorReportingTests` and mirrored by
    // `scripts/mcp_smoke.py`; see `ServerTestSupport.providerEnvironmentVariables`.
    // Referencing it directly is what stops the three copies from drifting.

    // MARK: - Process plumbing

    /// Locate the binary that `swift build` produced next to the test bundle.
    ///
    /// Delegates to the shared helper so a missing binary fails in CI instead of
    /// silently skipping the only end-to-end coverage in the package.
    private func binaryURL() throws -> URL {
        try ServerTestSupport.binaryURL()
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

            // Hermetic environment: start from PATH only, then remove every documented
            // provider variable, then apply this test's overrides. Without this, an
            // ambient TAVILY_API_KEY/BRAVE_SEARCH_API_KEY (exactly what the README
            // tells a user to export) would make a stub-provider test contact the live
            // vendor and report a false failure.
            var merged: [String: String] = [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            ]
            for key in ServerTestSupport.providerEnvironmentVariables {
                merged.removeValue(forKey: key)
            }
            for (key, value) in environment { merged[key] = value }
            process.environment = ServerTestSupport.childEnvironment(base: merged)
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
                        throw ServerTestError.malformedResponse(
                            (String(bytes: lineData, encoding: .utf8) ?? "<not valid UTF-8>"))
                    }
                    return object
                }

                let chunk = stdoutPipe.fileHandleForReading.availableData
                if chunk.isEmpty {
                    // EOF: the process exited without answering.
                    throw ServerTestError.unexpectedEOF(
                        stderr: String(bytes: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                            ?? "<not valid UTF-8>"
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
            return (String(bytes: data, encoding: .utf8) ?? "<not valid UTF-8>")
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

    /// The protocol revisions this server build understands.
    ///
    /// Deliberately a local list rather than a value a test sends: the assertion below
    /// is about what the *server* answers, independent of what the client asked for.
    private static let knownProtocolRevisions = [
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25",
    ]

    /// Start a server and send one `initialize` with an explicit requested revision.
    private func startServer(
        requestingProtocolVersion version: String,
        environment: [String: String] = [:]
    ) throws -> (server: ServerProcess, initializeResult: [String: Any]) {
        let binary = try binaryURL()
        let server = ServerProcess(binary: binary, environment: environment)
        try server.start()
        try server.send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": version,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "StdioServerTests", "version": "1.0.0"],
            ],
        ])
        let response = try server.readResponse(id: 1)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        return (server, result)
    }

    /// Start a server, perform the initialize handshake, and return the process.
    private func startInitializedServer(
        environment: [String: String]
    ) throws -> ServerProcess {
        let (server, result) = try startServer(
            requestingProtocolVersion: "2025-06-18",
            environment: environment
        )
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
        // `startInitializedServer` performs a real initialize round trip, asserts the
        // server identity and completes the handshake, so reaching the end without
        // throwing is the assertion. Cleanup is explicit rather than a trailing
        // `defer`, which the compiler notes would execute immediately.
        let server = try startInitializedServer(environment: [:])
        server.stop()
    }

    /// The negotiated revision must be the server's answer, not just an echo of whatever
    /// the test happened to send.
    ///
    /// Nothing previously checked this: most tests send `2025-06-18` and
    /// `SchemaCompatibilityTests` sends `2025-11-25`, so a dependency bump that changed
    /// the negotiated revision would have gone unnoticed.
    func testInitializeNegotiatesTheProtocolRevisionTheServerSupports() throws {
        // A revision the server knows is honoured exactly, so a client is never
        // silently moved to a different revision than it asked for.
        let (echoing, echoed) = try startServer(requestingProtocolVersion: "2025-06-18")
        defer { echoing.stop() }
        XCTAssertEqual(echoed["protocolVersion"] as? String, "2025-06-18")

        // An unrecognised revision falls back to the newest revision this build
        // supports, which is what a model client relying on `initialize` must see.
        let (fallingBack, fallback) = try startServer(requestingProtocolVersion: "1999-01-01")
        defer { fallingBack.stop() }
        let negotiated = try XCTUnwrap(fallback["protocolVersion"] as? String)
        XCTAssertTrue(
            Self.knownProtocolRevisions.contains(negotiated),
            "the server answered with an unknown revision: \(negotiated)"
        )
        XCTAssertEqual(
            negotiated,
            Self.knownProtocolRevisions.max(),
            "an unrecognised request must fall back to the newest supported revision"
        )
    }

    func testToolsListExposesTheDocumentedToolsWithValidSchemas() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        try server.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let response = try server.readResponse(id: 2)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(
            Set(names),
            Set(["web_search", "web_open", "web_answer", "web_search_status"])
        )

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
        XCTAssertEqual(
            Set(schema["required"] as? [String] ?? []),
            Set(properties.keys),
            "every declared property must also be required; optionality is expressed "
                + "as a nullable type so the schema survives strict validation"
        )
        // Provider-specific tuning must not leak into the public contract.
        XCTAssertNil(properties["search_depth"])
        XCTAssertNil(properties["freshness"])
        XCTAssertNil(properties["goggles"])

        let open = try XCTUnwrap(tools.first { $0["name"] as? String == "web_open" })
        let openSchema = try XCTUnwrap(open["inputSchema"] as? [String: Any])
        let openProperties = try XCTUnwrap(openSchema["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(openSchema["required"] as? [String] ?? []),
            Set(openProperties.keys)
        )

        // `web_answer` mirrors the search discovery arguments and must not expose any
        // model-selection knob: it is a grounded search tool, not an LLM passthrough.
        let answer = try XCTUnwrap(tools.first { $0["name"] as? String == "web_answer" })
        let answerSchema = try XCTUnwrap(answer["inputSchema"] as? [String: Any])
        let answerProperties = try XCTUnwrap(answerSchema["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(answerProperties.keys),
            Set([
                "query", "max_results", "recency", "include_domains", "exclude_domains",
                "locale", "mode", "provider",
            ])
        )
        XCTAssertEqual(
            Set(answerSchema["required"] as? [String] ?? []),
            Set(answerProperties.keys)
        )
        for forbidden in ["model", "temperature", "max_tokens", "prompt", "system"] {
            XCTAssertNil(
                answerProperties[forbidden],
                "`\(forbidden)` must not be exposed: it would make this an LLM endpoint"
            )
        }
    }

    /// The advertised `provider` values must exactly match the providers that can
    /// actually serve a search.
    ///
    /// A schema that offers a value which always errors is worse than not offering it,
    /// and a provider missing from the enum is unreachable. `jina` is deliberately
    /// absent: it is a fetch/extraction provider, and asking for it as a search
    /// provider is rejected.
    func testProviderEnumMatchesSelectableProviders() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        try server.send(["jsonrpc": "2.0", "id": 70, "method": "tools/list"])
        let response = try server.readResponse(id: 70)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let search = try XCTUnwrap(tools.first { $0["name"] as? String == "web_search" })
        let schema = try XCTUnwrap(search["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let provider = try XCTUnwrap(properties["provider"] as? [String: Any])
        let enumValues = try XCTUnwrap(provider["enum"] as? [String])

        // Every search-capable provider must be offered, plus `auto`.
        let expected = Set(
            ["auto"] + ProviderID.allCases.map(\.rawValue)
        )
        XCTAssertEqual(
            Set(enumValues),
            expected,
            "the provider enum has drifted from the selectable providers"
        )
        XCTAssertTrue(enumValues.contains("auto"))
        XCTAssertFalse(
            enumValues.contains("jina"),
            "`jina` cannot serve a search and must not be advertised"
        )
        // `default` is not a supported JSON Schema keyword for strict consumers and is
        // rejected outright by some, so the default is documented in the description
        // instead of declared as a keyword.
        XCTAssertNil(provider["default"], "`default` must not appear in the schema")
        let description = try XCTUnwrap(provider["description"] as? String)
        XCTAssertTrue(
            description.contains("auto"),
            "the default provider must be documented in the description"
        )
        // Optionality is expressed as a nullable type, which strict consumers accept.
        XCTAssertEqual(provider["type"] as? [String], ["string", "null"])
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

    // MARK: - web_answer

    /// Shared search-results body used by the synthesis tests.
    private static let answerSearchBody = """
        {"query":"why unix failed","results":[
          {"url":"https://example.com/linux","title":"Linux dominates the TOP500",
           "content":"Virtually every system runs Linux.","engine":"brave"},
          {"url":"https://example.com/unix","title":"The slow death of commercial Unix",
           "content":"Vendors shipped their own Unix on custom RISC silicon.","engine":"brave"}
        ],"answers":[],"corrections":[],"infoboxes":[],"suggestions":[],
        "unresponsive_engines":[]}
        """

    /// The full path: a real search through a stub provider, then a grounded answer
    /// from a stub model, with citations mapped back to the fetched URLs.
    func testWebAnswerReturnsGroundedAnswerWithCitations() throws {
        let completion = """
            {"choices":[{"message":{"content":"Linux runs the list [1]; commercial Unix declined [2]."},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":18}}
            """
        let stub = try LoopbackServer(responses: [
            .init(status: 200, body: Self.answerSearchBody),
            .init(status: 200, body: completion),
        ])

        let server = try startInitializedServer(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            "DEEPSEEK_API_KEY": Fixtures.syntheticDeepSeekKey,
            "DEEPSEEK_BASE_URL": stub.baseURL.absoluteString,
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 20,
            "method": "tools/call",
            "params": [
                "name": "web_answer",
                "arguments": ["query": "why unix failed", "max_results": 5, "mode": "fast"],
            ],
        ])
        let response = try server.readResponse(id: 20)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true)

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["status"] as? String, "answered")
        XCTAssertEqual(structured["model"] as? String, "deepseek-flash")
        XCTAssertEqual(structured["results_considered"] as? Int, 2)

        let citations = try XCTUnwrap(structured["citations"] as? [[String: Any]])
        XCTAssertEqual(citations.count, 2)
        XCTAssertEqual(citations[0]["index"] as? Int, 1)
        XCTAssertEqual(citations[0]["url"] as? String, "https://example.com/linux")
        XCTAssertEqual(citations[0]["sources"] as? [String], ["searxng"])
        XCTAssertEqual(citations[1]["url"] as? String, "https://example.com/unix")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Linux runs the list [1]"))
        XCTAssertTrue(text.contains("https://example.com/linux"))
        XCTAssertTrue(text.contains("no web access"))

        // Both hops must actually have happened.
        XCTAssertTrue(
            stub.requestPaths.contains { $0.contains("/search") },
            "the search endpoint must have been called"
        )
        XCTAssertTrue(
            stub.requestPaths.contains { $0.contains("/chat/completions") },
            "the synthesis endpoint must have been called"
        )
    }

    // MARK: - web_open, the success path

    /// `web_open` returned a rejection in every other test in this file, so its success path —
    /// the handler's `Self.success`, `ToolOutputFormatter.openText` and `openStructured` — was
    /// never executed end to end. Making `webOpen` always fail used to leave the suite green
    /// (ledger B08).
    func testWebOpenReturnsStructuredContentAndTextForARealPage() throws {
        let body = String(
            repeating: "Opening a page returns the readable text of that page. ",
            count: 20
        )
        let page = try LoopbackServer(responses: [
            .init(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: """
                    <html><head><title>Audit Page</title></head>
                    <body><nav>menu</nav><article><p>\(body)</p></article>
                    <footer>footer</footer></body></html>
                    """
            )
        ])

        let server = try startInitializedServer(environment: [
            // The loopback page is on 127.0.0.1, which the SSRF policy refuses by design.
            "SEARCH_ALLOW_PRIVATE_NETWORK": "1"
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 30,
            "method": "tools/call",
            "params": [
                "name": "web_open",
                "arguments": ["url": page.baseURL.absoluteString],
            ],
        ])
        let response = try server.readResponse(id: 30)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(result)")

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["url"] as? String, page.baseURL.absoluteString)
        XCTAssertEqual(structured["final_url"] as? String, page.baseURL.absoluteString)
        XCTAssertEqual(structured["status"] as? Int, 200)
        XCTAssertEqual(structured["title"] as? String, "Audit Page")
        XCTAssertEqual(structured["extraction_method"] as? String, "html_extraction")
        XCTAssertEqual(structured["truncated"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertEqual(
            structured["text_characters"] as? Int,
            text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n").count,
            "text_characters must be the length of the body that follows the header"
        )
        XCTAssertTrue(
            (structured["warnings"] as? [Any])?.isEmpty ?? false,
            "a page that extracts cleanly carries no warnings: \(structured["warnings"] ?? "nil")"
        )

        let parts = text.components(separatedBy: "\n\n")
        let header = parts.first ?? ""
        let bodyText = parts.dropFirst().joined(separator: "\n\n")
        XCTAssertTrue(header.contains("URL: \(page.baseURL.absoluteString)"), header)
        XCTAssertTrue(header.contains("Status: 200 (html_extraction)"), header)
        XCTAssertTrue(header.contains("# Audit Page"), "a title the body does not open with is a heading: \(header)")
        XCTAssertFalse(bodyText.isEmpty)
        XCTAssertTrue(bodyText.contains("readable text of that page"), String(bodyText.prefix(200)))
        XCTAssertEqual(page.requestCount, 1, "the page must actually have been fetched")
    }

    /// The truncation branch: the same page fetched with a 1 000-character budget.
    func testWebOpenReportsTruncationInBothForms() throws {
        let body = String(
            repeating: "Truncation is reported rather than silent. ",
            count: 80
        )
        let page = try LoopbackServer(responses: [
            .init(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: "<html><head><title>Long Page</title></head><body><article><p>\(body)</p></article></body></html>"
            )
        ])

        let server = try startInitializedServer(environment: ["SEARCH_ALLOW_PRIVATE_NETWORK": "1"])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 31,
            "method": "tools/call",
            "params": [
                "name": "web_open",
                "arguments": ["url": page.baseURL.absoluteString, "max_characters": 1_000],
            ],
        ])
        let response = try server.readResponse(id: 31)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(result)")

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["truncated"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let bodyText = text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
        // `clip` cuts at the last whitespace before the budget rather than mid-word, so the
        // body is at most the budget and normally close to it.
        let characters = try XCTUnwrap(structured["text_characters"] as? Int)
        XCTAssertEqual(characters, bodyText.count, "text_characters must match the body")
        XCTAssertLessThanOrEqual(characters, 1_000)
        XCTAssertGreaterThan(characters, 500, "the clip should use most of the budget")
        XCTAssertTrue(text.contains("Note: content was truncated."), String(text.prefix(200)))
    }

    /// The title-dedup branch: when the extracted text already opens with the title, the heading
    /// must not repeat it. That branch was the reason this code exists, and nothing asserted it.
    func testWebOpenDoesNotRepeatATitleTheBodyAlreadyOpensWith() throws {
        let page = try LoopbackServer(responses: [
            .init(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: """
                    <html><head><title>Alpha Page</title></head>
                    <body><article><h1>Alpha Page</h1>
                    <p>Body text that follows the heading and says enough to be extracted.</p>
                    </article></body></html>
                    """
            )
        ])

        let server = try startInitializedServer(environment: ["SEARCH_ALLOW_PRIVATE_NETWORK": "1"])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 32,
            "method": "tools/call",
            "params": [
                "name": "web_open",
                "arguments": ["url": page.baseURL.absoluteString],
            ],
        ])
        let response = try server.readResponse(id: 32)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(result)")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let parts = text.components(separatedBy: "\n\n")
        let header = parts.first ?? ""
        let bodyText = parts.dropFirst().joined(separator: "\n\n")

        XCTAssertTrue(
            bodyText.contains("Alpha Page"),
            "the premise of this test is that the body carries the title: \(String(bodyText.prefix(120)))"
        )
        XCTAssertFalse(
            header.contains("Alpha Page"),
            "the header must not repeat a title the body already opens with: \(header)"
        )
        XCTAssertTrue(header.contains("URL: "), header)
    }

    /// A refusal is a successful result, not an error, and must be distinguishable
    /// from an answer.
    func testWebAnswerReportsInsufficientResultsAsAStatusNotAnError() throws {
        let completion = """
            {"choices":[{"message":{"content":"INSUFFICIENT: the results never explain why."},
            "finish_reason":"stop"}]}
            """
        let stub = try LoopbackServer(responses: [
            .init(status: 200, body: Self.answerSearchBody),
            .init(status: 200, body: completion),
        ])

        let server = try startInitializedServer(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            "DEEPSEEK_API_KEY": Fixtures.syntheticDeepSeekKey,
            "DEEPSEEK_BASE_URL": stub.baseURL.absoluteString,
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 21,
            "method": "tools/call",
            "params": [
                "name": "web_answer",
                "arguments": ["query": "why unix failed", "mode": "fast"],
            ],
        ])
        let response = try server.readResponse(id: 21)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "a refusal is not a failure")

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["status"] as? String, "insufficient")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("INSUFFICIENT"))
        XCTAssertTrue(text.contains("never explain why"))
    }

    /// Without a model credential the tool still returns the search results rather
    /// than failing, and says plainly why there is no prose.
    func testWebAnswerWithoutASynthesisKeyReturnsResultsOnly() throws {
        let stub = try LoopbackServer(responses: [
            .init(status: 200, body: Self.answerSearchBody)
        ])

        let server = try startInitializedServer(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 22,
            "method": "tools/call",
            "params": [
                "name": "web_answer",
                "arguments": ["query": "why unix failed", "mode": "fast"],
            ],
        ])
        let response = try server.readResponse(id: 22)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true)

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["status"] as? String, "results_only")
        XCTAssertEqual(structured["model"] as? NSObject, NSNull(), "no model ran")
        XCTAssertEqual((structured["citations"] as? [Any])?.count, 0)

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("DEEPSEEK_API_KEY"), "the fix must be stated")
        // The search results still reach the caller.
        XCTAssertTrue(text.contains("Linux dominates the TOP500"))

        // Only the search may have been attempted.
        XCTAssertFalse(stub.requestPaths.contains { $0.contains("chat/completions") })
    }

    /// If the model fails, the search results must survive: losing prose is not a
    /// reason to lose the documents.
    func testWebAnswerKeepsResultsWhenSynthesisFails() throws {
        let stub = try LoopbackServer(responses: [
            .init(status: 200, body: Self.answerSearchBody),
            .init(status: 500, body: #"{"error":{"message":"overloaded"}}"#),
        ])

        let server = try startInitializedServer(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            "DEEPSEEK_API_KEY": Fixtures.syntheticDeepSeekKey,
            "DEEPSEEK_BASE_URL": stub.baseURL.absoluteString,
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 23,
            "method": "tools/call",
            "params": [
                "name": "web_answer",
                "arguments": ["query": "why unix failed", "mode": "fast"],
            ],
        ])
        let response = try server.readResponse(id: 23)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true)

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["status"] as? String, "results_only")
        XCTAssertEqual(structured["results_considered"] as? Int, 2)

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Linux dominates the TOP500"))
        XCTAssertTrue(text.contains("HTTP 500"), "the synthesis failure must be reported")
    }

    /// A model that cites a source it was never given must not have that citation
    /// reach the caller.
    func testWebAnswerStripsCitationsToResultsThatWereNeverFetched() throws {
        let completion = """
            {"choices":[{"message":{"content":"Grounded [1] but invented [7]."},
            "finish_reason":"stop"}]}
            """
        let stub = try LoopbackServer(responses: [
            .init(status: 200, body: Self.answerSearchBody),
            .init(status: 200, body: completion),
        ])

        let server = try startInitializedServer(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            "DEEPSEEK_API_KEY": Fixtures.syntheticDeepSeekKey,
            "DEEPSEEK_BASE_URL": stub.baseURL.absoluteString,
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 24,
            "method": "tools/call",
            "params": [
                "name": "web_answer",
                "arguments": ["query": "why unix failed", "mode": "fast"],
            ],
        ])
        let response = try server.readResponse(id: 24)
        let result = try XCTUnwrap(response["result"] as? [String: Any])

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let citations = try XCTUnwrap(structured["citations"] as? [[String: Any]])
        XCTAssertEqual(citations.count, 1, "only the real source may be returned")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertFalse(text.contains("[7]"), "a fabricated citation must not survive")
    }

    func testWebAnswerRejectsAnUnknownProviderArgument() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 25,
            "method": "tools/call",
            "params": [
                "name": "web_answer",
                "arguments": ["query": "q", "provider": "not-a-provider"],
            ],
        ])
        let response = try server.readResponse(id: 25)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("provider"))
    }

    func testWebOpenRejectsDangerousSchemesAndInternalHosts() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        // Every row asserts the *specific* refusal it provokes. The two classes carry different
        // operator actions — a URL that is not absolute is the caller's typo, while a blocked
        // scheme, host or address is a security decision — so accepting any message containing
        // "Refused" as a fallback made the whole `expected` column unenforceable (ledger B18).
        let cases: [(id: Int, url: String, expected: String)] = [
            (10, "file:///etc/passwd", "public http/https"),
            (11, "http://localhost:8080/admin", "public http/https"),
            (12, "http://169.254.169.254/latest/meta-data/", "public http/https"),
            (13, "http://10.0.0.1/", "public http/https"),
            // `URL(string:)` accepts `javascript:alert(1)`: it is a syntactically valid absolute
            // URL, so this is a policy refusal, not a parse failure. The old fallback hid that
            // distinction by passing whichever arm the code happened to take.
            (14, "javascript:alert(1)", "public http/https"),
            // And this is what the other arm looks like: no parseable absolute URL at all.
            (15, "ht tp://x", "valid absolute URL"),
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
                text.contains(testCase.expected),
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
        let stderr =
            (String(bytes: server.stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? "<not valid UTF-8>")
        XCTAssertTrue(
            stderr.contains("SwiftWebSearchMCP"),
            "expected startup diagnostics on stderr, got: \(stderr.prefix(400))"
        )
    }
}
