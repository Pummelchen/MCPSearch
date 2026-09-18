import Foundation
import WebSearchCore
import XCTest

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

    /// Run the executable to completion and capture its exit status and streams.
    ///
    /// `--help` and a rejected flag both exit before a transport is served, so this is a one-shot
    /// process rather than an MCP session. The output is at most a few kilobytes — far below the
    /// pipe buffer — so draining the pipes after `waitUntilExit` cannot deadlock the child.
    private func runToCompletion(
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try binaryURL()
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Hermetic exactly like the MCP harness: no ambient provider credential or config path.
        var merged: [String: String] = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ]
        for key in ServerTestSupport.providerEnvironmentVariables {
            merged.removeValue(forKey: key)
        }
        for (key, value) in environment { merged[key] = value }
        process.environment = ServerTestSupport.childEnvironment(base: merged)

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(bytes: stdoutData, encoding: .utf8) ?? "<not valid UTF-8>",
            String(bytes: stderrData, encoding: .utf8) ?? "<not valid UTF-8>"
        )
    }

    // MARK: - Harness

    /// The subprocess harness is shared with `ErrorReportingTests` and
    /// `SchemaCompatibilityTests`; see `ServerProcess` in `TestSupport.swift`. One copy means
    /// the deadline below cannot be enforced in one harness and skipped in another.

    /// The harness deadline must be a real bound, even while the child is alive and silent.
    ///
    /// The read loop used to block in `FileHandle.availableData`, so the check
    /// `while Date() < deadline` could only run after a read returned: a server that never
    /// wrote hung the run instead of failing it, and the 15 s/20 s deadline these harnesses
    /// advertise was never enforced. The child here is a shell that writes a
    /// partial line and then holds the pipe open, so this can only pass if the deadline
    /// preempts a blocked read.
    func testHarnessDeadlinePreemptsABlockedRead() throws {
        let binary = URL(fileURLWithPath: "/bin/sh")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: binary.path),
            "the deadline probe needs a shell to stand in for a wedged server"
        )
        let server = ServerProcess(
            binary: binary,
            arguments: ["-c", "printf 'partial line with no newline'; sleep 60"]
        )
        try server.start()
        defer { server.stop() }

        let started = Date()
        XCTAssertThrowsError(try server.readResponse(id: 1, timeout: 0.3)) { error in
            XCTAssertEqual(
                String(describing: error),
                "timed out waiting for a response",
                "a silent child must raise the harness timeout, not block"
            )
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            10,
            "the read returned only because the deadline fired, not because the child exited"
        )
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
    func startInitializedServer(
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

    // MARK: - Command line before configuration

    /// `--help` must be answered from the command line alone.
    ///
    /// Configuration used to be loaded and validated before `argv` was parsed, so a mistyped
    /// `SEARCH_CONFIG_FILE` made `--help` exit 2 with "Refusing to start" and print no usage at
    /// all.
    func testHelpSucceedsEvenWhenTheConfigurationFileIsUnreadable() throws {
        let result = try runToCompletion(
            arguments: ["--help"],
            environment: ["SEARCH_CONFIG_FILE": "/nonexistent/audit-missing-config.env"]
        )
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(
            result.stdout.contains("USAGE"),
            "usage did not reach stdout: \(result.stdout)"
        )
        XCTAssertFalse(
            result.stderr.contains("Refusing to start"),
            "a help request must not depend on the environment: \(result.stderr)"
        )
    }

    /// An invalid flag is reported before the configuration is validated or any client is built.
    ///
    /// The same fatal `SEARCH_CONFIG_FILE` is in the environment, so a process that loaded
    /// configuration first would report only the config problem and never the typo.
    func testInvalidFlagIsReportedBeforeConfigurationIsValidated() throws {
        let result = try runToCompletion(
            arguments: ["--not-a-flag"],
            environment: ["SEARCH_CONFIG_FILE": "/nonexistent/audit-missing-config.env"]
        )
        XCTAssertEqual(result.status, 2, "stdout: \(result.stdout)")
        XCTAssertTrue(
            result.stderr.contains("Unknown argument: --not-a-flag"),
            "the argument error must win over the configuration error: \(result.stderr)"
        )
        XCTAssertFalse(result.stderr.contains("Refusing to start"), result.stderr)
    }

    /// A help request must not load configuration at all, so it emits no startup diagnostics.
    func testHelpDoesNotLoadConfiguration() throws {
        let result = try runToCompletion(arguments: ["--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(
            result.stderr.contains("Starting"),
            "help loaded configuration and logged startup: \(result.stderr)"
        )
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
        // The list may also carry JSON null, because the property is a nullable union;
        // only the string entries name a provider. Reading the list as `[Any]` rather
        // than `[String]` keeps this test about which *providers* are advertised, which
        // is its subject, instead of about whether anything else is present.
        let enumEntries = try XCTUnwrap(provider["enum"] as? [Any])
        for entry in enumEntries {
            XCTAssertTrue(
                entry is String || entry is NSNull,
                "the provider enum may only contain ids and null, found \(entry)"
            )
        }
        let enumValues = enumEntries.compactMap { $0 as? String }

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

    /// `web_open` can send the target URL to a third-party rendering service, so the
    /// model-visible description must say so before the call is made. It used to describe only
    /// a vague "rendering service" and never said the URL left the machine.
    func testWebOpenDescriptionDisclosesTheThirdPartyReader() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        try server.send(["jsonrpc": "2.0", "id": 71, "method": "tools/list"])
        let response = try server.readResponse(id: 71)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let open = try XCTUnwrap(tools.first { $0["name"] as? String == "web_open" })
        let description = try XCTUnwrap(open["description"] as? String)

        XCTAssertTrue(description.contains("r.jina.ai"), description)
        XCTAssertTrue(
            description.lowercased().contains("third-party"),
            "the description must disclose the third party: \(description)"
        )
        XCTAssertTrue(
            description.lowercased().contains("remotely"),
            "the description must say the URL is fetched remotely: \(description)"
        )
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
        // The list is built from the one enablement authority, so it names every provider's
        // variable rather than the two the hand-written message happened to know.
        for variable in [
            "BRAVE_SEARCH_API_KEY", "MOJEEK_API_KEY", "EXA_API_KEY", "SEARXNG_BASE_URL",
            "OPEN_WEB_SEARCH_URL", "SEARCH_ENABLE_SCRAPERS=true", "PARALLEL_MCP_URL",
        ] {
            XCTAssertTrue(
                text.contains(variable),
                "the no-provider message omits \(variable): \(text)"
            )
        }
    }

    /// `parallel` needs a flag *and* an endpoint, so the tool error must name the input this
    /// configuration is missing.
    ///
    /// With the flag on and `PARALLEL_MCP_URL` emptied, the error used to advise
    /// `SEARCH_ENABLE_PARALLEL=true` — a setting the operator had already applied — while the
    /// server's own startup comment recorded that an emptied URL is what registers no adapter
    func testParallelWithoutAnEndpointIsToldToSetTheEndpointNotTheFlag() throws {
        let server = try startInitializedServer(environment: [
            "SEARCH_ENABLE_PARALLEL": "true",
            // An explicitly empty value is how an operator removes the built-in endpoint.
            "PARALLEL_MCP_URL": "",
        ])
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": [
                "name": "web_search",
                "arguments": ["query": "swift concurrency", "provider": "parallel"],
            ],
        ])
        let response = try server.readResponse(id: 4)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("PARALLEL_MCP_URL"), text)
        XCTAssertFalse(
            text.contains("SEARCH_ENABLE_PARALLEL"),
            "the flag is already on, so naming it is not actionable: \(text)"
        )
    }

}
