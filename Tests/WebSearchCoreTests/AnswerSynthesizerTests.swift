import Foundation
import XCTest

@testable import WebSearchCore

/// Tests for grounded answer synthesis.
///
/// The point of these tests is the *grounding contract*, not the prose: the model must
/// never be able to introduce a source that was not fetched, and a refusal must be
/// distinguishable from an answer.
final class AnswerSynthesizerTests: XCTestCase {

    // MARK: Fixtures

    private func result(
        _ title: String,
        _ url: String,
        snippet: String? = nil,
        content: String? = nil,
        providers: [ProviderID] = [.tavily]
    ) -> SearchResult {
        SearchResult(
            title: title,
            url: URL(string: url)!,
            snippet: snippet,
            provider: providers.first ?? .tavily,
            providerRank: 1,
            content: content,
            sources: providers
        )
    }

    private var sampleResults: [SearchResult] {
        [
            result(
                "Linux dominates the TOP500",
                "https://example.com/linux-top500",
                snippet: "Virtually every system runs Linux.",
                providers: [.tavily, .brave]
            ),
            result(
                "The long, slow death of commercial Unix",
                "https://example.com/unix-death",
                snippet: "Vendors shipped their own Unix on custom RISC silicon."
            ),
            result(
                "Unrelated page about Nginx",
                "https://example.com/nginx-500",
                snippet: "An Nginx misconfiguration returns HTTP 500."
            ),
        ]
    }

    private func synthesizer(
        _ http: MockHTTPClient,
        key: String? = Fixtures.syntheticDeepSeekKey,
        model: String = "deepseek-flash",
        enableReasoning: Bool = false
    ) -> AnswerSynthesizer {
        AnswerSynthesizer(
            apiKey: key,
            baseURL: URL(string: "https://api.deepseek.com/v1")!,
            model: model,
            timeout: .seconds(45),
            enableReasoning: enableReasoning,
            http: http
        )
    }

    /// Minimal OpenAI-compatible completion body.
    ///
    /// `static` so a `@Sendable` mock handler can call it without capturing the test
    /// case.
    private static func completion(
        _ content: String?,
        finish: String = "stop",
        reasoning: String? = nil
    ) -> String {
        var message: [String: Any] = [:]
        if let content { message["content"] = content }
        if let reasoning { message["reasoning_content"] = reasoning }
        let payload: [String: Any] = [
            "choices": [["message": message, "finish_reason": finish]],
            "usage": ["prompt_tokens": 100, "completion_tokens": 20],
        ]
        // No trapping conversion: an unencodable fixture is a bug in this helper, and the
        // fallback makes that visible in the assertion output instead of killing the runner.
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"error":"unencodable fixture"}"#
    }

    // MARK: Configuration

    func testIsNotConfiguredWithoutAKey() {
        let client = MockHTTPClient()
        XCTAssertFalse(synthesizer(client, key: nil).isConfigured)
        XCTAssertFalse(synthesizer(client, key: "").isConfigured)
        XCTAssertFalse(synthesizer(client, key: "   ").isConfigured)
        XCTAssertTrue(synthesizer(client).isConfigured)
    }

    func testThrowsWhenUnconfiguredRatherThanGuessing() async {
        let client = MockHTTPClient()
        do {
            _ = try await synthesizer(client, key: nil).synthesize(
                query: "q",
                results: sampleResults
            )
            XCTFail("Expected synthesis to refuse without a key")
        } catch let error as SearchError {
            XCTAssertTrue(error.safeDescription.contains("DEEPSEEK_API_KEY"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(client.requests.isEmpty, "No request may be sent without a key")
    }

    func testThrowsOnEmptyResultSet() async {
        let client = MockHTTPClient()
        do {
            _ = try await synthesizer(client).synthesize(query: "q", results: [])
            XCTFail("Expected a refusal to answer with no sources")
        } catch let error as SearchError {
            XCTAssertTrue(error.safeDescription.contains("no search results"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: Request shape

    func testSendsGroundingPromptWithNumberedResults() async throws {
        let client = MockHTTPClient()
        client.respondJSON(Self.completion("Linux dominates [1]."), label: "deepseek.synthesize")

        _ = try await synthesizer(client).synthesize(query: "why linux", results: sampleResults)

        let request = try XCTUnwrap(client.requests(label: "deepseek.synthesize").first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(Fixtures.syntheticDeepSeekKey)")

        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "deepseek-flash")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(system.contains("ONLY facts stated in those results"))
        XCTAssertTrue(system.contains("Never cite a number that is not in the list"))

        let user = try XCTUnwrap(messages.last?["content"] as? String)
        // Every supplied result must be numbered and carry its URL.
        for (index, result) in sampleResults.enumerated() {
            XCTAssertTrue(user.contains("[\(index + 1)] \(result.title)"))
            XCTAssertTrue(user.contains(result.url.absoluteString))
        }
        XCTAssertTrue(user.contains("QUESTION: why linux"))
    }

    /// The API defaults to thinking *enabled*, which can consume the entire output
    /// budget and return `finish_reason: length` with empty content. The request must
    /// therefore disable it explicitly rather than rely on the default.
    func testDisablesThinkingExplicitlyByDefault() async throws {
        let client = MockHTTPClient()
        client.respondJSON(Self.completion("ok"), label: "deepseek.synthesize")
        _ = try await synthesizer(client).synthesize(query: "q", results: sampleResults)

        let body = try XCTUnwrap(client.requests(label: "deepseek.synthesize").first?.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try XCTUnwrap(json["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "disabled")
        XCTAssertNil(json["reasoning_effort"])
    }

    func testEnablesThinkingWhenAsked() async throws {
        let client = MockHTTPClient()
        client.respondJSON(Self.completion("ok"), label: "deepseek.synthesize")
        _ = try await synthesizer(client, enableReasoning: true)
            .synthesize(query: "q", results: sampleResults)

        let body = try XCTUnwrap(client.requests(label: "deepseek.synthesize").first?.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        XCTAssertEqual(json["reasoning_effort"] as? String, "low")
    }

    func testUsesGenerousTimeoutNotTheSearchTimeout() async throws {
        let client = MockHTTPClient()
        client.respondJSON(Self.completion("ok"), label: "deepseek.synthesize")
        _ = try await synthesizer(client).synthesize(query: "q", results: sampleResults)

        let request = try XCTUnwrap(client.requests(label: "deepseek.synthesize").first)
        XCTAssertEqual(request.timeout, .seconds(45))
    }

    // MARK: Parsing the completion

    func testReturnsAnswerWithValidatedCitations() async throws {
        let client = MockHTTPClient()
        client.respondJSON(
            Self.completion("Every system runs Linux [1]. Unix vendors died out [2]."),
            label: "deepseek.synthesize"
        )

        let answer = try await synthesizer(client)
            .synthesize(query: "q", results: sampleResults)

        XCTAssertEqual(answer.model, "deepseek-flash")
        XCTAssertEqual(answer.citations.count, 2)
        XCTAssertEqual(answer.citations[0].url.absoluteString, "https://example.com/linux-top500")
        XCTAssertEqual(answer.citations[1].url.absoluteString, "https://example.com/unix-death")
        XCTAssertEqual(answer.status, nil)
        XCTAssertFalse(answer.isInsufficient)
    }

    /// `reasoning_content` is the model thinking aloud. It must never become the
    /// answer, even when `content` is empty.
    func testReasoningContentIsNeverTheAnswer() async throws {
        let client = MockHTTPClient()
        client.respondJSON(
            Self.completion(nil, finish: "length", reasoning: "Let me consider [1] and [2]..."),
            label: "deepseek.synthesize"
        )

        do {
            _ = try await synthesizer(client).synthesize(query: "q", results: sampleResults)
            XCTFail("Empty content must not be returned as an answer")
        } catch let error as SearchError {
            XCTAssertTrue(error.safeDescription.contains("no answer"))
            XCTAssertTrue(error.safeDescription.contains("length"))
        }
    }

    /// With reasoning enabled an empty first attempt is retried with it disabled,
    /// because that is the actionable fix for the truncation above.
    func testRetriesWithoutReasoningWhenTheFirstAttemptIsEmpty() async throws {
        let client = MockHTTPClient()
        let attempts = LockedCounter()
        client.on("deepseek.synthesize") { request in
            let body = try XCTUnwrap(request.body)
            let json = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let thinking = (json["thinking"] as? [String: Any])?["type"] as? String
            let count = attempts.increment()
            let text =
                count == 1
                ? Self.completion(nil, finish: "length", reasoning: "thinking...")
                : Self.completion("Recovered answer [1].")
            _ = thinking
            return HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(text.utf8),
                url: request.url
            )
        }

        let answer = try await synthesizer(client, enableReasoning: true)
            .synthesize(query: "q", results: sampleResults)

        XCTAssertEqual(attempts.value, 2)
        XCTAssertTrue(answer.text.contains("Recovered answer"))
        XCTAssertEqual(answer.citations.count, 1)
    }

    func testRefusalIsReportedAsInsufficientNotAsAnAnswer() async throws {
        let client = MockHTTPClient()
        client.respondJSON(
            Self.completion("INSUFFICIENT: the results discuss Linux but never say why Unix failed."),
            label: "deepseek.synthesize"
        )

        let answer = try await synthesizer(client)
            .synthesize(query: "q", results: sampleResults)

        XCTAssertTrue(answer.isInsufficient)
        XCTAssertEqual(answer.status, "insufficient")
        // The marker itself is stripped; the explanation is kept.
        XCTAssertFalse(answer.text.contains("INSUFFICIENT:"))
        XCTAssertTrue(answer.text.contains("never say why Unix failed"))
    }

    // MARK: Citation validation

    func testStripsCitationsThatReferenceNothingSupplied() async throws {
        let client = MockHTTPClient()
        client.respondJSON(
            Self.completion("A claim [1] and an invented one [9]."),
            label: "deepseek.synthesize"
        )

        let answer = try await synthesizer(client)
            .synthesize(query: "q", results: sampleResults)

        XCTAssertEqual(answer.citations.count, 1)
        XCTAssertFalse(answer.text.contains("[9]"), "A marker to a non-existent source must be removed")
        XCTAssertTrue(answer.text.contains("[1]"))
        XCTAssertTrue(
            answer.text.contains("did not match a supplied result"),
            "Stripping a citation must be disclosed, not silent"
        )
    }

    func testRenumbersCitationsToBeContiguous() async throws {
        let client = MockHTTPClient()
        // The model cites 2 then 1: the answer's own numbering must follow first use.
        client.respondJSON(
            Self.completion("First [2] then [1]."),
            label: "deepseek.synthesize"
        )

        let answer = try await synthesizer(client)
            .synthesize(query: "q", results: sampleResults)

        XCTAssertEqual(answer.citations.map(\.index), [1, 2])
        XCTAssertEqual(answer.citations.map(\.sourceIndex), [2, 1])
        XCTAssertEqual(answer.citations[0].url.absoluteString, "https://example.com/unix-death")
        XCTAssertTrue(answer.text.contains("First [1] then [2]"))
    }

    func testAnswerWithNoCitationsIsAllowed() async throws {
        let client = MockHTTPClient()
        client.respondJSON(
            Self.completion("The results do not address this question at all."),
            label: "deepseek.synthesize"
        )

        let answer = try await synthesizer(client)
            .synthesize(query: "q", results: sampleResults)

        XCTAssertTrue(answer.citations.isEmpty)
        XCTAssertFalse(answer.isInsufficient, "No citations is not the same as a refusal")
    }

    /// Pure-function coverage of the validator, including boundaries.
    func testValidatorBoundaries() {
        let results = sampleResults

        let low = AnswerSynthesizer.validateCitations(
            "[0] and [1]",
            resultCount: results.count,
            results: results
        )
        XCTAssertEqual(low.citations.map(\.sourceIndex), [1], "[0] is out of range")
        XCTAssertEqual(low.strippedMarkers, 1)

        let high = AnswerSynthesizer.validateCitations(
            "[3] then [4]",
            resultCount: results.count,
            results: results
        )
        XCTAssertEqual(high.citations.map(\.sourceIndex), [3])
        XCTAssertEqual(high.strippedMarkers, 1)

        let repeated = AnswerSynthesizer.validateCitations(
            "[2][2][2]",
            resultCount: results.count,
            results: results
        )
        XCTAssertEqual(repeated.citations.count, 1, "A repeated marker cites one source")

        let none = AnswerSynthesizer.validateCitations(
            "no markers here",
            resultCount: results.count,
            results: results
        )
        XCTAssertTrue(none.citations.isEmpty)
        XCTAssertEqual(none.strippedMarkers, 0)
    }

    // MARK: Corpus assembly

    func testCorpusPrefersSnippetOverPageContent() {
        let withBoth = result(
            "T",
            "https://example.com/a",
            snippet: "the snippet",
            content: "much longer page body"
        )
        let corpus = AnswerSynthesizer.buildCorpus(
            [withBoth],
            perResultBudget: 1_000,
            totalBudget: 10_000
        )
        XCTAssertTrue(corpus.contains("the snippet"))
        XCTAssertFalse(corpus.contains("much longer page body"))
    }

    func testCorpusClipsLongContentAndKeepsNumberingAligned() {
        let long = String(repeating: "x", count: 5_000)
        let results = [
            result("First", "https://example.com/1", snippet: long),
            result("Second", "https://example.com/2", snippet: long),
        ]
        let corpus = AnswerSynthesizer.buildCorpus(
            results,
            perResultBudget: 100,
            totalBudget: 250
        )
        // Both results stay numbered so the model's markers still map to the list.
        XCTAssertTrue(corpus.contains("[1] First"))
        XCTAssertTrue(corpus.contains("[2] Second"))
        XCTAssertTrue(corpus.contains("omitted for length"))
    }

    // MARK: Link validation

    /// Markers were validated; `http(s)` links in the prose were not, so the tool's documented
    /// promise — "a model cannot cite a source that was never fetched" — did not hold for a URL
    /// written out in full (ledger B26).
    func testLinksToResultsTheCorpusDoesNotContainAreRemoved() throws {
        let text = """
            Linux dominates the list [1], and see https://evil.example/login for more.
            The authoritative page is [the docs](https://example.com/unix-death) though.
            """
        let validated = AnswerSynthesizer.validateCitations(
            text,
            resultCount: sampleResults.count,
            results: sampleResults
        )

        XCTAssertFalse(
            validated.text.contains("evil.example"),
            "a link no result contains must be removed: \(validated.text)"
        )
        XCTAssertTrue(
            validated.text.contains("[link removed: not one of the fetched results]"),
            validated.text
        )
        XCTAssertTrue(
            validated.text.contains("https://example.com/unix-death"),
            "a link that *is* a supplied result must survive: \(validated.text)"
        )
        XCTAssertEqual(validated.strippedLinks, 1)
        XCTAssertEqual(validated.strippedMarkers, 0)
    }

    /// The visible text of a link stays; only the unverified target goes.
    func testOnlyTheUnverifiedLinkTargetIsRemoved() throws {
        let validated = AnswerSynthesizer.validateCitations(
            "[the docs](https://evil.example/x)",
            resultCount: sampleResults.count,
            results: sampleResults
        )
        XCTAssertTrue(validated.text.contains("the docs"), validated.text)
        XCTAssertFalse(validated.text.contains("evil.example"), validated.text)
    }

    /// Trailing slashes and case are not a difference; anything else is.
    func testLinkComparisonIsDeliberatelyNarrow() {
        XCTAssertEqual(
            AnswerSynthesizer.comparableURL("HTTPS://Example.COM/Page/"),
            AnswerSynthesizer.comparableURL("https://example.com/Page")
        )
        XCTAssertNotEqual(
            AnswerSynthesizer.comparableURL("https://example.com/page?q=1"),
            AnswerSynthesizer.comparableURL("https://example.com/page")
        )
    }

    /// A failed pattern must not read as "everything validated", which is what
    /// `try? … ?? []` did (ledger B26).
    func testTheValidationPatternsCompile() {
        XCTAssertEqual(AnswerSynthesizer.markerPattern.numberOfCaptureGroups, 1)
        XCTAssertEqual(AnswerSynthesizer.linkPattern.numberOfCaptureGroups, 0)
        let matches = AnswerSynthesizer.linkPattern.matches(
            in: "see https://example.com/a?b=1 and http://x.example/c",
            range: NSRange(
                "see https://example.com/a?b=1 and http://x.example/c".startIndex...,
                in: "see https://example.com/a?b=1 and http://x.example/c"
            )
        )
        XCTAssertEqual(matches.count, 2)
    }

    /// The removed-link count reaches the answer text, the same way markers do.
    func testTheStrippedLinkCountIsReportedInTheAnswer() async throws {
        let client = MockHTTPClient()
        client.respondJSON(
            Self.completion("See https://evil.example/login for the details."),
            label: "deepseek.synthesize"
        )
        let answer = try await synthesizer(client).synthesize(
            query: "q",
            results: sampleResults
        )
        XCTAssertFalse(answer.text.contains("evil.example"), answer.text)
        XCTAssertTrue(
            answer.text.contains("link(s) in the model's answer did not match a fetched result"),
            answer.text
        )
    }

    // MARK: Error mapping

    func testAuthenticationFailureDoesNotEchoTheResponseBody() async throws {
        let client = MockHTTPClient()
        client.respondJSON(
            #"{"error":{"message":"Invalid key \#(Fixtures.syntheticDeepSeekKey)"}}"#,
            status: 401,
            label: "deepseek.synthesize"
        )

        do {
            _ = try await synthesizer(client).synthesize(query: "q", results: sampleResults)
            XCTFail("Expected an authentication failure")
        } catch let error as SearchError {
            XCTAssertTrue(error.safeDescription.contains("rejected the configured credentials"))
            XCTAssertFalse(
                error.safeDescription.contains(Fixtures.syntheticDeepSeekKey),
                "The key must never be echoed from a vendor body"
            )
            XCTAssertFalse(
                error.safeDescription.contains("Invalid key"),
                "The vendor's error text must not be relayed verbatim"
            )
        }
    }

    /// The credential must travel in the `Authorization` header and nowhere else —
    /// never in the URL or body, where it could reach a log or a cache.
    func testCredentialNeverAppearsOutsideTheAuthorizationHeader() async throws {
        let client = MockHTTPClient()
        client.respondJSON(Self.completion("ok"), label: "deepseek.synthesize")
        _ = try await synthesizer(client).synthesize(query: "q", results: sampleResults)

        let request = try XCTUnwrap(client.requests(label: "deepseek.synthesize").first)
        let key = Fixtures.syntheticDeepSeekKey
        XCTAssertFalse(request.url.absoluteString.contains(key))
        if let body = request.body {
            XCTAssertFalse((String(bytes: body, encoding: .utf8) ?? "<not valid UTF-8>").contains(key))
        }
        XCTAssertEqual(
            request.headers.filter { $0.value.contains(key) }.keys.sorted(),
            ["Authorization"]
        )
    }

    func testRateLimitFailureIsActionable() async throws {
        let client = MockHTTPClient()
        client.respondJSON(#"{"error":{"message":"slow down"}}"#, status: 429, label: "deepseek.synthesize")
        do {
            _ = try await synthesizer(client).synthesize(query: "q", results: sampleResults)
            XCTFail("Expected a rate-limit failure")
        } catch let error as SearchError {
            XCTAssertTrue(error.safeDescription.contains("rate limited"))
        }
    }

    func testMalformedJSONFailsCleanly() async throws {
        let client = MockHTTPClient()
        client.respondJSON("not json at all", label: "deepseek.synthesize")
        do {
            _ = try await synthesizer(client).synthesize(query: "q", results: sampleResults)
            XCTFail("Expected a parse failure")
        } catch let error as SearchError {
            XCTAssertTrue(error.safeDescription.contains("unparseable JSON"))
        }
    }

    func testVendorErrorObjectIsSurfaced() async throws {
        let client = MockHTTPClient()
        client.respondJSON(
            #"{"error":{"message":"model overloaded","type":"server_error"}}"#,
            label: "deepseek.synthesize")
        do {
            _ = try await synthesizer(client).synthesize(query: "q", results: sampleResults)
            XCTFail("Expected a vendor error")
        } catch let error as SearchError {
            XCTAssertTrue(error.safeDescription.contains("model overloaded"))
        }
    }
}

/// Small mutable counter for asserting retry behaviour.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
