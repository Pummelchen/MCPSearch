import Foundation
import XCTest
@testable import WebSearchCore

extension ProviderContractTests {

    func testStartpageForbiddenAndRateLimitedStatuses() async {
        for (status, category) in [(403, ProviderFailure.FailureCategory.serverError), (429, .rateLimited)] {
            let http = MockHTTPClient()
            http.onAny { request in
                HTTPResponse(statusCode: status, headers: [:], body: Data(), url: request.url)
            }
            do {
                _ = try await startpageProvider(http: http)
                XCTFail("HTTP \(status) must not yield results")
            } catch let error as SearchError {
                XCTAssertEqual(error.category, category, "HTTP \(status)")
            } catch {
                XCTFail("unexpected error for \(status): \(error)")
            }
        }
    }

    func testStartpageIsNotConfiguredWithoutTheScraperOptIn() async {
        let provider = StartpageProvider(
            http: MockHTTPClient(),
            configuration: Fixtures.configuration(),
            scrapersEnabled: false
        )
        XCTAssertFalse(provider.isConfigured)
        do {
            _ = try await provider.search(Fixtures.request())
            XCTFail("expected notConfigured")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .notConfigured)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Open Web Search (aggregator)

    private func openWebSearchProvider(
        _ json: String,
        status: Int = 200
    ) -> (OpenWebSearchProvider, MockHTTPClient) {
        let http = MockHTTPClient()
        http.respondJSON(json, status: status)
        let provider = OpenWebSearchProvider(
            endpoint: URL(string: "https://aggregator.example.com/api")!,
            http: http,
            configuration: configuration
        )
        return (provider, http)
    }

    /// The three common envelope keys and the success-envelope variant are accepted.
    func testOpenWebSearchAcceptsEveryEnvelopeShape() async throws {
        let item =
            #"{"title":"Aggregated result","url":"https://example.com/aggregated","snippet":"Text.","engine":"brave"}"#
        let shapes = [
            "results": #"{"results":[\#(item)]}"#,
            "data": #"{"data":[\#(item)]}"#,
            "items": #"{"items":[\#(item)]}"#,
            "success envelope": #"{"success":true,"results":[\#(item)]}"#,
        ]

        for (name, json) in shapes {
            let (provider, http) = openWebSearchProvider(json)
            let response = try await provider.search(Fixtures.request("aggregated"))
            assertNormalizedResults(response, provider: .openWebSearch)
            XCTAssertEqual(response.results.count, 1, name)
            XCTAssertEqual(response.upstreamEngines, ["brave"], name)

            let url = try XCTUnwrap(http.requests.first?.url.absoluteString, name)
            XCTAssertTrue(url.contains("query=aggregated"), "\(name): \(url)")
            XCTAssertTrue(url.contains("q=aggregated"), "\(name): \(url)")
            XCTAssertTrue(url.contains("limit="), "\(name): \(url)")
        }
    }

    /// A bare top-level JSON array is one of the shapes the adapter documents, and it used to
    /// fail: the response type was a synthesised `Decodable`, so only the envelope decoded and
    /// an array body was reported as a malformed response.
    func testOpenWebSearchAcceptsABareTopLevelArray() async throws {
        // The adapter documents "several common shapes"; a synthesised Decodable could only
        // read the envelope, so this body shape used to fail as a malformed response.
        let (provider, _) = openWebSearchProvider(
            #"[{"title":"Bare array","url":"https://example.com/bare","snippet":"Text."}]"#
        )
        let response = try await provider.search(Fixtures.request())
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results.first?.title, "Bare array")
        XCTAssertEqual(response.results.first?.url.absoluteString, "https://example.com/bare")
    }

    /// The wire contract is undocumented, so alternate anchor/snippet keys and unknown
    /// fields must be tolerated rather than producing junk or failing.
    func testOpenWebSearchParsesAlternateKeysDefensively() async throws {
        let (provider, _) = openWebSearchProvider(
            """
            {"data":[
              {"title":"Alt keys","link":"https://example.com/alt","description":"Alt snippet.",
               "rank":3,"engines":["duckduckgo","brave"],"score":1.5,
               "published":"2024-01-15T00:00:00Z","unknown_field":{"nested":true}},
              {"no_url_here":"ignored","title":"Dropped"}
            ]}
            """
        )
        let response = try await provider.search(Fixtures.request())
        XCTAssertEqual(response.results.count, 1, "an item without a URL must be dropped")
        let result = response.results[0]
        XCTAssertEqual(result.url.absoluteString, "https://example.com/alt")
        XCTAssertEqual(result.snippet, "Alt snippet.")
        XCTAssertEqual(result.providerRank, 3)
        XCTAssertEqual(result.providerScore, 1.5)
        XCTAssertNotNil(result.publishedAt)
        XCTAssertEqual(Set(response.upstreamEngines), Set(["duckduckgo", "brave"]))
    }

    func testOpenWebSearchTreatsAnEmptyEnvelopeAsSuccessButAnUnrecognizableBodyAsMalformed() async throws {
        // A genuinely empty query is `200 {"results":[]}`, which is not a malformed body.
        let (empty, _) = openWebSearchProvider(#"{"results":[]}"#)
        let emptyResponse = try await empty.search(Fixtures.request())
        XCTAssertTrue(emptyResponse.results.isEmpty)

        let (successOnly, _) = openWebSearchProvider(#"{"success":true}"#)
        let successOnlyResponse = try await successOnly.search(Fixtures.request())
        XCTAssertTrue(successOnlyResponse.results.isEmpty)

        // `{}` carries no recognised envelope and no success flag.
        let (unrecognizable, _) = openWebSearchProvider("{}")
        do {
            _ = try await unrecognizable.search(Fixtures.request())
            XCTFail("an unrecognizable body must fail cleanly")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .malformedResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // A wrong type inside a recognised key is malformed, not an empty success.
        let (wrongType, _) = openWebSearchProvider(#"{"results":"not an array"}"#)
        do {
            _ = try await wrongType.search(Fixtures.request())
            XCTFail("a mistyped envelope must fail cleanly")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .malformedResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOpenWebSearchTaxonomy() async {
        await assertFailureTaxonomy(
            makeProvider: {
                OpenWebSearchProvider(
                    endpoint: URL(string: "https://aggregator.example.com/api")!,
                    http: $0,
                    configuration: self.configuration
                )
            },
            provider: .openWebSearch,
            authenticationStatus: 401,
            rateLimitStatus: 429,
            serverErrorStatus: 503
        )
    }

    func testOpenWebSearchWarnsWhenUpstreamEnginesAreAbsent() async throws {
        let (provider, _) = openWebSearchProvider(
            #"{"results":[{"title":"No engines","url":"https://example.com/x"}]}"#
        )
        let response = try await provider.search(Fixtures.request())
        XCTAssertTrue(response.upstreamEngines.isEmpty)
        XCTAssertTrue(response.warnings.contains { $0.contains("upstream engines") })
    }

    // MARK: - Parallel MCP (upstream MCP client)

    /// A scripted Parallel MCP endpoint.
    ///
    /// Every Parallel message shares the `parallel.mcp` request label, so the stub
    /// dispatches on the JSON-RPC `method` in the recorded body instead.
    private func makeParallelStub(
        toolName: String = "web_search",
        announcesMaxResults: Bool = true,
        sessionID: String? = "sess-1",
        initializeStatus: Int = 200,
        toolResponse: @escaping @Sendable (Int) -> HTTPResponse
    ) -> MockHTTPClient {
        let http = MockHTTPClient()
        let properties = announcesMaxResults ? #"{"max_results":{"type":"number"}}"# : "{}"
        http.onAny { request in
            let body =
                (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) })
                as? [String: Any] ?? [:]
            let method = body["method"] as? String ?? ""
            let id = body["id"] as? Int ?? 0

            var headers = ["content-type": "application/json"]
            if let sessionID { headers["MCP-Session-Id"] = sessionID }

            switch method {
            case "initialize":
                guard initializeStatus == 200 else {
                    return HTTPResponse(
                        statusCode: initializeStatus,
                        headers: [:],
                        body: Data(),
                        url: request.url
                    )
                }
                let json =
                    #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"Parallel","version":"1.0.0"}}}"#
                return HTTPResponse(
                    statusCode: 200,
                    headers: headers,
                    body: Data(json.utf8),
                    url: request.url
                )
            case "notifications/initialized":
                return HTTPResponse(statusCode: 202, headers: [:], body: Data(), url: request.url)
            case "tools/list":
                let json =
                    #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"\#(toolName)","inputSchema":{"type":"object","properties":\#(properties)}}]}}"#
                return HTTPResponse(
                    statusCode: 200,
                    headers: headers,
                    body: Data(json.utf8),
                    url: request.url
                )
            default:
                return toolResponse(id)
            }
        }
        return http
    }

    private func parallelProvider(_ http: MockHTTPClient) -> ParallelMCPProvider {
        ParallelMCPProvider(
            endpoint: URL(string: "https://parallel.example.com/mcp")!,
            http: http,
            configuration: configuration,
            enabled: true
        )
    }

    private func rpcMethod(_ request: MockHTTPClient.Recorded) -> String {
        rpcBody(request)["method"] as? String ?? ""
    }

    private func rpcBody(_ request: MockHTTPClient.Recorded) -> [String: Any] {
        guard let body = request.body,
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func textToolResponse(_ id: Int, text: String) -> HTTPResponse {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["content": [["type": "text", "text": text]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return HTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: data,
            url: URL(string: "https://parallel.example.com/mcp")!
        )
    }

    /// The full MCP-over-HTTP handshake: initialize, notifications/initialized,
    /// tools/list discovery, then a tools/call whose text content is mapped onto
    /// normalized results.
    func testParallelMCPHandshakeDiscoveryAndToolCall() async throws {
        let toolText =
            #"{"results":[{"title":"Swift Concurrency","url":"https://example.com/swift","excerpts":["Actors isolate state.","Sendable is checked."],"publish_date":"2024-01-15T00:00:00Z"},{"title":"Other","link":"https://example.com/other","snippet":"Other snippet."}]}"#
        let http = makeParallelStub { id in
            Self.textToolResponse(id, text: toolText)
        }
        let response = try await parallelProvider(http).search(Fixtures.request("swift concurrency"))

        assertNormalizedResults(response, provider: .parallel)
        XCTAssertEqual(response.upstreamEngines, ["parallel"])
        XCTAssertEqual(response.results[0].snippet, "Actors isolate state.")
        XCTAssertNotNil(response.results[0].publishedAt)
        XCTAssertEqual(response.results[1].url.absoluteString, "https://example.com/other")
        XCTAssertEqual(response.results[1].snippet, "Other snippet.")

        // Exact JSON-RPC sequence.
        XCTAssertEqual(
            http.requests.map(rpcMethod),
            ["initialize", "notifications/initialized", "tools/list", "tools/call"]
        )

        // The session id issued by initialize is echoed on every later message, and the
        // request that creates the session must not carry one.
        XCTAssertNil(http.requests[0].headers["MCP-Session-Id"])
        XCTAssertEqual(http.requests[1].headers["MCP-Session-Id"], "sess-1")
        XCTAssertEqual(http.requests[3].headers["MCP-Session-Id"], "sess-1")

        let initialize = rpcBody(http.requests[0])
        let initializeParams = try XCTUnwrap(initialize["params"] as? [String: Any])
        XCTAssertEqual(initializeParams["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil(initializeParams["clientInfo"])

        let call = rpcBody(http.requests[3])
        let callParams = try XCTUnwrap(call["params"] as? [String: Any])
        XCTAssertEqual(callParams["name"] as? String, "web_search")
        let arguments = try XCTUnwrap(callParams["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["objective"] as? String, "swift concurrency")
        XCTAssertEqual(arguments["search_queries"] as? [String], ["swift concurrency"])
        XCTAssertNotNil(arguments["session_id"] as? String)
        XCTAssertEqual(arguments["model_name"] as? String, "SwiftWebSearchMCP")
        XCTAssertEqual(
            arguments["max_results"] as? Int,
            Fixtures.request("swift concurrency").providerResultBudget
        )
    }

    /// The transport may answer with pre-formatted Server-Sent Events; the last
    /// complete JSON-RPC object on the stream is the response.
    func testParallelMCPAcceptsAnSSEResponse() async throws {
        let http = makeParallelStub { id in
            let envelope: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "structuredContent": [
                        "results": [
                            [
                                "title": "SSE result",
                                "url": "https://example.com/sse",
                                "excerpts": ["Rendered remotely."],
                            ]
                        ]
                    ]
                ],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
            let json = (String(bytes: data, encoding: .utf8) ?? "<not valid UTF-8>")
            let sse = "event: message\ndata: \(json)\n\n"
            return HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/event-stream"],
                body: Data(sse.utf8),
                url: URL(string: "https://parallel.example.com/mcp")!
            )
        }
        let response = try await parallelProvider(http).search(Fixtures.request("sse"))

        assertNormalizedResults(response, provider: .parallel)
        XCTAssertEqual(response.results[0].url.absoluteString, "https://example.com/sse")
        XCTAssertEqual(response.results[0].snippet, "Rendered remotely.")
    }

    /// `max_results` is only sent when the discovered tool actually declares it.
    func testParallelMCPOmitsMaxResultsWhenTheToolDoesNotDeclareIt() async throws {
        let http = makeParallelStub(toolName: "search", announcesMaxResults: false) { id in
            Self.textToolResponse(id, text: #"{"results":[{"title":"A","url":"https://example.com/a"}]}"#)
        }
        _ = try await parallelProvider(http).search(Fixtures.request())

        let call = rpcBody(http.requests[3])
        let callParams = try XCTUnwrap(call["params"] as? [String: Any])
        XCTAssertEqual(callParams["name"] as? String, "search")
        let arguments = try XCTUnwrap(callParams["arguments"] as? [String: Any])
        XCTAssertNil(arguments["max_results"])
    }

    /// A server that exposes no preferred name still gets discovered by the
    /// `search` substring fallback.
    func testParallelMCPDiscoversANonPreferredSearchTool() async throws {
        let http = makeParallelStub(toolName: "custom_web_search", announcesMaxResults: false) { id in
            Self.textToolResponse(id, text: #"{"results":[{"title":"A","url":"https://example.com/a"}]}"#)
        }
        _ = try await parallelProvider(http).search(Fixtures.request())
        let call = rpcBody(http.requests[3])
        XCTAssertEqual((call["params"] as? [String: Any])?["name"] as? String, "custom_web_search")
    }

    /// A JSON-RPC error on `tools/call` maps to the shared taxonomy: an unknown tool
    /// is a configuration problem while any other error is a provider failure.
    func testParallelMCPMapsJSONRPCErrors() async {
        for (code, category) in [(-32601, ProviderFailure.FailureCategory.unsupportedRequest), (-32603, .serverError)] {
            let http = makeParallelStub { id in
                let envelope: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": ["code": code, "message": "boom"],
                ]
                let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: data,
                    url: URL(string: "https://parallel.example.com/mcp")!
                )
            }
            do {
                _ = try await parallelProvider(http).search(Fixtures.request())
                XCTFail("error \(code) must not produce results")
            } catch let error as SearchError {
                XCTAssertEqual(error.category, category, "error \(code)")
            } catch {
                XCTFail("unexpected error for \(code): \(error)")
            }
        }
    }

    func testParallelMCPTransportStatusesMapToTheSharedTaxonomy() async {
        for (status, category) in [
            (401, ProviderFailure.FailureCategory.authentication),
            (403, .authentication),
            (429, .rateLimited),
            (503, .serverError),
        ] {
            let http = makeParallelStub(initializeStatus: status) { id in
                Self.textToolResponse(id, text: "{}")
            }
            do {
                _ = try await parallelProvider(http).search(Fixtures.request())
                XCTFail("HTTP \(status) must not produce results")
            } catch let error as SearchError {
                XCTAssertEqual(error.category, category, "HTTP \(status)")
            } catch {
                XCTFail("unexpected error for \(status): \(error)")
            }
        }
    }

    /// A body that is not JSON at all must fail cleanly rather than being parsed.
    func testParallelMCPMalformedToolResultFailsCleanly() async {
        let http = makeParallelStub { _ in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain"],
                body: Data("<html>not json</html>".utf8),
                url: URL(string: "https://parallel.example.com/mcp")!
            )
        }
        do {
            _ = try await parallelProvider(http).search(Fixtures.request())
            XCTFail("a non-JSON body must fail cleanly")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .malformedResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testParallelMCPExtractJSONHandlesBareAndSSEFramings() {
        XCTAssertEqual(ParallelMCPProvider.extractJSON(from: #"  {"a":1}  "#), #"{"a":1}"#)
        XCTAssertEqual(
            ParallelMCPProvider.extractJSON(from: "event: message\ndata: {\"a\":1}\n\ndata: {\"b\":2}\n\n"),
            #"{"b":2}"#
        )
        // Nothing recognizable is returned unchanged so the caller fails cleanly.
        XCTAssertEqual(ParallelMCPProvider.extractJSON(from: "<html>"), "<html>")
    }

    // MARK: - Status mapping
    //
    // `testHTTPStatusMapperClassifiesCorrectly` moved to `HTTPStatusMapperTests`, which owns the
    // whole status/transport contract. This file is at SwiftLint's `file_length` ceiling, and the
    // move is a straight relocation: the body was not changed.

}
