import Foundation
import WebSearchCore
import XCTest

extension StdioServerTests {

    func testWebOpenRejectsDangerousSchemesAndInternalHosts() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        // Every row asserts the *specific* refusal it provokes. The two classes carry different
        // operator actions — a URL that is not absolute is the caller's typo, while a blocked
        // scheme, host or address is a security decision — so accepting any message containing
        // "Refused" as a fallback made the whole `expected` column unenforceable.
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

    /// Send one `tools/call` and return what the caller would see.
    private func callTool(
        _ server: ServerProcess,
        id: Int,
        name: String,
        arguments: [String: Any]
    ) throws -> (isError: Bool, text: String, structured: [String: Any]?) {
        try server.send([
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ])
        let response = try server.readResponse(id: id)
        XCTAssertNil(
            response["error"],
            "\(name) with \(arguments) must not be a protocol error"
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (result["isError"] as? Bool == true, text, result["structuredContent"] as? [String: Any])
    }

    /// A search response with `resultCount` distinct-domain results.
    private static func searchBody(resultCount: Int) -> String {
        let results = (1...resultCount).map { index in
            """
            {"url":"https://result\(index).example/doc","title":"Result \(index)",\
            "content":"Body text for result \(index).","engine":"brave"}
            """
        }.joined(separator: ",")
        return "{\"query\":\"q\",\"results\":[\(results)]}"
    }

    /// Every argument guard must name the argument it rejected.
    ///
    /// Only three malformed shapes were covered — a missing `query`, a `max_results` of the wrong
    /// type and an unknown tool — so the array, enum and required-string guards could each regress
    /// into a generic failure, or into a protocol error, without the suite noticing.
    func testToolArgumentGuardsNameTheArgumentTheyReject() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        let cases: [(id: Int, name: String, arguments: [String: Any], expected: String)] = [
            (
                40, "web_search",
                ["query": "ok", "include_domains": (0..<21).map { "d\($0).example" }],
                "include_domains"
            ),
            (41, "web_search", ["query": "ok", "exclude_domains": [1, 2]], "exclude_domains"),
            (42, "web_search", ["query": "ok", "recency": "yesterday"], "recency"),
            (43, "web_search", ["query": "ok", "mode": "quick"], "mode"),
            (44, "web_search", ["query": "   "], "query"),
            (45, "web_open", ["url": "   "], "url"),
        ]
        for testCase in cases {
            let outcome = try callTool(
                server,
                id: testCase.id,
                name: testCase.name,
                arguments: testCase.arguments
            )
            XCTAssertTrue(outcome.isError, "\(testCase.arguments) must be refused")
            XCTAssertTrue(
                outcome.text.contains(testCase.expected),
                "the message must name \(testCase.expected), got: \(outcome.text)"
            )
        }
    }

    /// `web_search` and `web_answer` must parse their shared arguments with one parser.
    ///
    /// The two handlers ran byte-identical *copies* of the discovery block, so one could be
    /// changed and the other left behind without the schema parity lint noticing: that lint
    /// compares the advertised constraints, not the handlers behind them. This
    /// sends the same rejected value to both tools and requires the same error text back.
    func testTheTwoSearchToolsParseTheirSharedArgumentsIdentically() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        let cases: [(id: Int, argument: String, value: Any, expected: String)] = [
            (60, "provider", "bogus", "`provider` must be one of"),
            (62, "locale", "-", "`locale` must look like"),
            (64, "recency", "yesterday", "recency"),
            (66, "mode", "quick", "mode"),
            (68, "max_results", "many", "max_results"),
            (70, "include_domains", "not-an-array", "include_domains"),
            (72, "exclude_domains", (0..<21).map { "d\($0).example" }, "exclude_domains"),
        ]
        for testCase in cases {
            var arguments: [String: Any] = ["query": "swift concurrency"]
            arguments[testCase.argument] = testCase.value

            let search = try callTool(
                server,
                id: testCase.id,
                name: "web_search",
                arguments: arguments
            )
            let answer = try callTool(
                server,
                id: testCase.id + 1,
                name: "web_answer",
                arguments: arguments
            )

            XCTAssertTrue(search.isError, "web_search must refuse \(testCase.value)")
            XCTAssertTrue(answer.isError, "web_answer must refuse \(testCase.value)")
            XCTAssertTrue(
                search.text.contains(testCase.expected),
                "the shared parser must name \(testCase.expected), got: \(search.text)"
            )
            XCTAssertEqual(
                answer.text,
                search.text,
                "web_answer must give the same parse error as web_search for "
                    + "\(testCase.argument)=\(testCase.value)"
            )
        }
    }

    /// The documented clamps are part of the tool contract.
    ///
    /// `max_results` is capped at 20 and floored at 1, and `max_characters` is floored at 1 000.
    /// A clamp that disappeared would silently change what a caller can ask for — or let a model
    /// ask for a fifty-megabyte page — and nothing tested any of them.
    func testToolArgumentClampsAreEnforced() throws {
        let page =
            "<html><body><p>"
            + String(repeating: "long page text ", count: 500)
            + "</p></body></html>"
        let stub = try LoopbackServer(responses: [
            .init(status: 200, body: Self.searchBody(resultCount: 25)),
            .init(status: 200, body: Self.searchBody(resultCount: 25)),
            .init(status: 200, body: page),
        ])
        let server = try startInitializedServer(environment: [
            "SEARXNG_BASE_URL": stub.baseURL.absoluteString,
            // `web_open` fetches the loopback stub, which the SSRF policy refuses by default.
            "SEARCH_ALLOW_PRIVATE_NETWORK": "1",
            // Pin the provider set. This test asserts the result-count clamp, and CI runs the whole
            // suite a second time with placeholder provider credentials present: with Tavily and
            // Brave configured, the balanced fan-out spends its slots on providers that call the
            // real vendor APIs with a bogus key and fail, so the stub's answer — and the clamp
            // assertion — depended on ambient credentials and the network. Disabling everything but
            // SearXNG makes the answer come from the stub alone, in every environment.
            "SEARCH_DISABLED_PROVIDERS":
                "tavily,brave,mojeek,exa,open_web_search,parallel,duckduckgo,startpage",
        ])
        defer { server.stop() }

        let capped = try callTool(
            server,
            id: 50,
            name: "web_search",
            arguments: ["query": "clamp", "max_results": 50]
        )
        let cappedResults = try XCTUnwrap(capped.structured?["results"] as? [[String: Any]])
        XCTAssertEqual(cappedResults.count, 20, "max_results is capped at the documented 20")

        let floored = try callTool(
            server,
            id: 51,
            name: "web_search",
            arguments: ["query": "clamp", "max_results": 0]
        )
        let flooredResults = try XCTUnwrap(floored.structured?["results"] as? [[String: Any]])
        XCTAssertEqual(flooredResults.count, 1, "max_results is floored at 1")

        let pageResult = try callTool(
            server,
            id: 52,
            name: "web_open",
            arguments: ["url": stub.baseURL.absoluteString, "max_characters": 10]
        )
        let characters = try XCTUnwrap(pageResult.structured?["text_characters"] as? Int)
        XCTAssertGreaterThan(characters, 10, "max_characters is floored at 1 000, not honoured at 10")
        XCTAssertLessThanOrEqual(characters, 1_000, "the floored budget is still the cap")
        XCTAssertEqual(pageResult.structured?["truncated"] as? Bool, true)
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
        let stderr = server.stderrText()
        XCTAssertTrue(
            stderr.contains("SwiftWebSearchMCP"),
            "expected startup diagnostics on stderr, got: \(stderr.prefix(400))"
        )
    }

    /// The empty-configuration warning must name every variable that can register a provider.
    ///
    /// It used to name five of the eight, so an operator who had the scraper and open-web-search
    /// paths available was told only about API keys.
    func testEmptyConfigurationWarningNamesEveryProviderVariable() throws {
        let server = try startInitializedServer(environment: [:])
        defer { server.stop() }

        try server.send(["jsonrpc": "2.0", "id": 70, "method": "tools/list"])
        _ = try server.readResponse(id: 70)
        let stderr = server.stderrText()
        for variable in [
            "TAVILY_API_KEY", "BRAVE_SEARCH_API_KEY", "MOJEEK_API_KEY", "EXA_API_KEY",
            "SEARXNG_BASE_URL", "OPEN_WEB_SEARCH_URL", "SEARCH_ENABLE_SCRAPERS",
            "SEARCH_ENABLE_PARALLEL",
        ] {
            XCTAssertTrue(
                stderr.contains(variable),
                "the empty-configuration warning is missing \(variable): \(stderr)"
            )
        }
    }
}
