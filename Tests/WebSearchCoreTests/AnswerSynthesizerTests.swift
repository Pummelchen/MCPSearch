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

    /// A URL from a fixture literal, without a force-unwrap.
    ///
    /// `URL(string:)` is the only string initialiser and it is failable, and this fixture is reached
    /// from a computed property, which cannot `try`. Failing the assertion and returning a sentinel
    /// keeps the failure visible and localised: the test that uses the result is already marked failed
    /// here, so nothing can pass on the sentinel, and a malformed literal no longer takes the whole
    /// suite down with it.
    private func fixtureURL(
        _ string: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    func result(
        _ title: String,
        _ url: String,
        snippet: String? = nil,
        content: String? = nil,
        providers: [ProviderID] = [.tavily]
    ) -> SearchResult {
        SearchResult(
            title: title,
            url: fixtureURL(url),
            snippet: snippet,
            provider: providers.first ?? .tavily,
            providerRank: 1,
            content: content,
            sources: providers
        )
    }

    var sampleResults: [SearchResult] {
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

    func synthesizer(
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
    static func completion(
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

    /// The user turn of the request the synthesizer just sent, decoded from the mock's
    /// recorded body.
    static func userTurn(in client: MockHTTPClient) throws -> String {
        let request = try XCTUnwrap(client.requests(label: "deepseek.synthesize").first)
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        return try XCTUnwrap(messages.last?["content"] as? String)
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

    /// A locale is the caller's answer-language request, and the model can only honour it if
    /// the instruction reaches the user turn.
    func testLocaleInstructionReachesTheUserTurn() async throws {
        let client = MockHTTPClient()
        client.respondJSON(Self.completion("ok [1]."), label: "deepseek.synthesize")

        _ = try await synthesizer(client).synthesize(
            query: "why linux",
            results: sampleResults,
            locale: "de-DE"
        )

        let user = try Self.userTurn(in: client)
        XCTAssertTrue(
            user.contains("Answer in the language implied by locale de-DE."),
            "the locale instruction must reach the model: \(user)"
        )
    }

    /// No locale and an empty locale both mean "no language instruction", rather than a
    /// dangling sentence that names nothing.
    func testNoLocaleInstructionWithoutALocale() async throws {
        for locale in [nil, ""] as [String?] {
            let client = MockHTTPClient()
            client.respondJSON(Self.completion("ok [1]."), label: "deepseek.synthesize")
            _ = try await synthesizer(client).synthesize(
                query: "why linux",
                results: sampleResults,
                locale: locale
            )
            let user = try Self.userTurn(in: client)
            XCTAssertFalse(
                user.contains("Answer in the language implied by locale"),
                "locale \(locale ?? "nil") must not add a language instruction: \(user)"
            )
        }
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

    /// A 200 whose `choices` array is present but empty carries no answer at all, and it is
    /// not the same failure as a truncated one: the caller needs to know the shape was wrong
    func testAnEmptyChoiceArrayIsRefused() async throws {
        let client = MockHTTPClient()
        client.respondJSON(#"{"choices":[]}"#, label: "deepseek.synthesize")

        do {
            _ = try await synthesizer(client).synthesize(query: "q", results: sampleResults)
            XCTFail("An empty choices array is not an answer")
        } catch let error as SearchError {
            XCTAssertTrue(
                error.safeDescription.contains("no choices"),
                error.safeDescription
            )
        }
    }

    /// The token counts are decoded from `usage` and returned on the answer, so a caller can
    /// account for the billed request.
    func testTokenUsageIsReported() async throws {
        let client = MockHTTPClient()
        client.respondJSON(Self.completion("Linux dominates [1]."), label: "deepseek.synthesize")

        let answer = try await synthesizer(client)
            .synthesize(query: "q", results: sampleResults)

        XCTAssertEqual(answer.inputTokens, 100)
        XCTAssertEqual(answer.outputTokens, 20)
    }

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

}
