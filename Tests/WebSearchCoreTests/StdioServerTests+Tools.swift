import Foundation
import WebSearchCore
import XCTest

extension StdioServerTests {

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

}
