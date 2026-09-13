import Foundation

// MARK: - Result types

/// A grounded answer plus the sources it actually rested on.
public struct SynthesizedAnswer: Sendable, Hashable, Codable {
    /// Prose answer in markdown, with `[n]` markers referring to `citations`.
    public var text: String
    /// Only the results the answer actually cited, in first-citation order.
    ///
    /// Returned rather than the full result list so a caller can verify every claim
    /// against exactly what the model was given, without guessing which sources it
    /// used. An answer that cites nothing yields an empty array.
    public var citations: [Citation]
    /// Model that produced the answer, e.g. `deepseek-flash`.
    public var model: String
    /// Set when the answer is not a normal synthesis: currently only `"insufficient"`,
    /// meaning the model reported that the supplied results do not answer the question.
    ///
    /// This is a **success**, not an error. Grounding is only worth anything if the
    /// model is allowed to say "the sources do not support this", and that case must be
    /// distinguishable from an answer so a caller does not treat an abstention as
    /// content.
    public var status: String?
    public var elapsedMilliseconds: Int
    public var inputTokens: Int?
    public var outputTokens: Int?

    public var isInsufficient: Bool { status == "insufficient" }

    public init(
        text: String,
        citations: [Citation],
        model: String,
        status: String? = nil,
        elapsedMilliseconds: Int = 0,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        self.text = text
        self.citations = citations
        self.model = model
        self.status = status
        self.elapsedMilliseconds = elapsedMilliseconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// One cited source, renumbered to be contiguous from 1.
    public struct Citation: Sendable, Hashable, Codable {
        /// Marker used in `text`, after renumbering.
        public var index: Int
        /// Index the model was originally shown, before any renumbering.
        public var sourceIndex: Int
        public var title: String
        public var url: URL
        public var sources: [ProviderID]

        public init(
            index: Int,
            sourceIndex: Int,
            title: String,
            url: URL,
            sources: [ProviderID]
        ) {
            self.index = index
            self.sourceIndex = sourceIndex
            self.title = title
            self.url = url
            self.sources = sources
        }
    }
}

// MARK: - Synthesizer

/// Turns search results into a cited answer using a generative model.
///
/// ## Why this is not a search provider
///
/// The model behind this has **no web access**. Asked "why did Unix fail the TOP500
/// list" without grounding it will produce a confident narrative from stale training
/// data; asked for a current price it cannot know. A search provider must return real
/// documents, so this deliberately is not one. It is given **only** results that real
/// providers already fetched, and is instructed to answer from those alone. The
/// failure mode is therefore abstention, not invention.
///
/// Nothing here participates in provider selection, fusion or ranking, and
/// `SEARCH_PROVIDER_ORDER` is unaffected by whether a key is present.
///
/// ## Robustness notes that shaped this implementation
///
/// Measured against `deepseek-flash` (DeepSeek-V4.1-Flash):
///
/// - **Thinking mode can return an empty answer.** The reasoning pass shares the
///   output-token budget, so with the default `high` effort the model can emit
///   `finish_reason: "length"` with `content` empty and only `reasoning_content`
///   populated — an HTTP 200 carrying no answer. Reasoning is therefore off by
///   default, and an empty completion is retried once with it explicitly disabled
///   rather than surfaced as an empty answer.
/// - **The visible answer is what matters**, so `reasoning_content` is never treated
///   as the answer.
/// - **Citations are validated, not trusted.** Markers are checked against the
///   supplied range, and `http(s)` links in the prose are checked against the supplied
///   results' URLs; anything that matches neither is stripped from the text and the
///   answer is flagged. The guarantee is bounded by that: a link the model writes in
///   some other form (a bare hostname, a non-`http` scheme, a shortened URL) is not
///   recognised as a link at all, so it is neither validated nor presented as a
///   citation. The structured `citations` array is the authoritative list.
public struct AnswerSynthesizer: Sendable {
    /// System prompt. Kept in one place so tests can assert the grounding rules.
    public static let systemPrompt = """
        You are a research assistant embedded in a search tool.

        You will be given numbered SEARCH RESULTS and a QUESTION. Answer the QUESTION \
        using ONLY facts stated in those results.

        Rules:
        1. Cite the results you rely on with bracketed numbers matching the list, \
        e.g. [2][4]. Place a marker immediately after each claim it supports.
        2. Never cite a number that is not in the list. Never invent or guess a URL.
        3. Do not use prior knowledge or anything the results do not state. If the \
        results do not answer the question, begin your reply with exactly \
        "INSUFFICIENT:" and then explain briefly what is missing. Do not fill the gap \
        with a guess.
        4. Be concise: at most 6 sentences unless the question demands more detail.
        5. Write prose. Do not repeat the result list back verbatim.
        """

    /// Marker the model uses to declare the sources insufficient.
    public static let insufficientMarker = "INSUFFICIENT:"

    /// Default cap on how much of each result is sent. Snippets are short already;
    /// inline content can be long, and the whole corpus has to fit one request.
    public static let defaultPerResultCharacterBudget = 1_200
    /// Default cap on the assembled corpus.
    public static let defaultTotalCharacterBudget = 14_000

    private let apiKey: String?
    private let baseURL: URL
    private let model: String
    private let timeout: Duration
    private let enableReasoning: Bool
    private let http: any HTTPClient
    private let perResultCharacterBudget: Int
    private let totalCharacterBudget: Int
    private let log: Log

    public init(
        apiKey: String?,
        baseURL: URL,
        model: String,
        timeout: Duration,
        enableReasoning: Bool = false,
        http: any HTTPClient,
        perResultCharacterBudget: Int = AnswerSynthesizer.defaultPerResultCharacterBudget,
        totalCharacterBudget: Int = AnswerSynthesizer.defaultTotalCharacterBudget,
        log: Log = .disabled
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.enableReasoning = enableReasoning
        self.http = http
        self.perResultCharacterBudget = max(200, perResultCharacterBudget)
        self.totalCharacterBudget = max(1_000, totalCharacterBudget)
        self.log = log
    }

    /// Convenience initialiser from configuration.
    public init(
        configuration: AppConfiguration,
        http: any HTTPClient,
        log: Log = .disabled
    ) {
        self.init(
            apiKey: configuration.deepSeekAPIKey,
            baseURL: configuration.deepSeekBaseURL
                ?? URL(string: "https://api.deepseek.com/v1")!,
            model: configuration.deepSeekModel,
            timeout: configuration.synthesisTimeout,
            enableReasoning: configuration.enableSynthesisReasoning,
            http: http,
            log: log
        )
    }

    public var isConfigured: Bool {
        guard let apiKey else { return false }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Produce a grounded answer from `results`.
    ///
    /// - Throws: `SearchError.synthesisFailed` when the model cannot be reached or
    ///   returns nothing usable. A refusal (`INSUFFICIENT:`) is **not** an error: it is
    ///   returned with `status == "insufficient"`.
    public func synthesize(
        query: String,
        results: [SearchResult],
        locale: String? = nil
    ) async throws -> SynthesizedAnswer {
        guard isConfigured else {
            throw SearchError.synthesisFailed(
                "No synthesis model is configured. Set DEEPSEEK_API_KEY to enable it."
            )
        }
        guard !results.isEmpty else {
            throw SearchError.synthesisFailed("There are no search results to answer from.")
        }

        let corpus = Self.buildCorpus(
            results,
            perResultBudget: perResultCharacterBudget,
            totalBudget: totalCharacterBudget
        )
        let question = Self.buildQuestion(query, locale: locale)
        let prompt = "SEARCH RESULTS:\n\(corpus)\n\n\(question)"

        let started = DispatchTime.now().uptimeNanoseconds

        // The empty-answer retry below is why the first attempt is not the only one.
        var completion = try await complete(prompt: prompt, allowReasoning: enableReasoning)
        if completion.text.isEmpty, enableReasoning {
            log.debug("Synthesis returned no visible answer; retrying without reasoning")
            completion = try await complete(prompt: prompt, allowReasoning: false)
        }

        let raw = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw SearchError.synthesisFailed(
                "The synthesis model returned no answer (finish reason: "
                    + "\(completion.finishReason ?? "unknown"))."
            )
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        let isInsufficient = raw.hasPrefix(Self.insufficientMarker)
        let body =
            isInsufficient
            ? String(raw.dropFirst(Self.insufficientMarker.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : raw

        let validated = Self.validateCitations(
            body,
            resultCount: results.count,
            results: results
        )

        log.debug(
            "Answer synthesis complete",
            metadata: [
                "model": model,
                "results": "\(results.count)",
                "cited": "\(validated.citations.count)",
                "stripped_markers": "\(validated.strippedMarkers)",
                "elapsed_ms": "\(elapsed)",
            ]
        )

        // A marker that pointed nowhere is worth surfacing rather than hiding: it is
        // the one signal that the model tried to cite something it was not given.
        var text = validated.text
        if validated.strippedMarkers > 0 {
            text +=
                "\n\n> Note: \(validated.strippedMarkers) citation marker(s) in the "
                + "model's answer did not match a supplied result and were removed."
        }
        if validated.strippedLinks > 0 {
            text +=
                "\n\n> Note: \(validated.strippedLinks) link(s) in the model's answer did not "
                + "match a fetched result and were removed."
        }

        return SynthesizedAnswer(
            text: text,
            citations: validated.citations,
            model: model,
            status: isInsufficient ? "insufficient" : nil,
            elapsedMilliseconds: elapsed,
            inputTokens: completion.inputTokens,
            outputTokens: completion.outputTokens
        )
    }

    // MARK: Request

    struct Completion {
        var text: String
        var finishReason: String?
        var inputTokens: Int?
        var outputTokens: Int?
    }

    private func complete(prompt: String, allowReasoning: Bool) async throws -> Completion {
        guard let apiKey else {
            throw SearchError.synthesisFailed("No synthesis model is configured.")
        }

        let endpoint = baseURL.appendingPathComponent("chat/completions")
        let body = Self.requestBody(
            model: model,
            systemPrompt: Self.systemPrompt,
            prompt: prompt,
            allowReasoning: allowReasoning
        )

        let response: HTTPResponse
        do {
            response = try await http.send(
                HTTPRequest.post(
                    endpoint,
                    headers: [
                        "Authorization": "Bearer \(apiKey)",
                        "Content-Type": "application/json",
                        "Accept": "application/json",
                    ],
                    body: body,
                    label: "deepseek.synthesize",
                    // Generative traffic: the shared search timeout is far too short.
                    timeout: timeout
                ),
                maxBytes: 4 * 1024 * 1024
            )
        } catch let error as SearchError {
            throw error
        } catch {
            throw SearchError.synthesisFailed(Self.describe(error))
        }

        switch response.statusCode {
        case 200..<300:
            break
        case 401, 403:
            // Deliberately does not echo the response body: it can echo the key back.
            throw SearchError.synthesisFailed(
                "The synthesis model rejected the configured credentials."
            )
        case 429:
            throw SearchError.synthesisFailed(
                "The synthesis model rate limited the request; retry shortly."
            )
        default:
            throw SearchError.synthesisFailed(
                "The synthesis model returned HTTP \(response.statusCode)."
            )
        }

        guard let decoded = try? JSONCoding.decoder().decode(ChatCompletion.self, from: response.body)
        else {
            throw SearchError.synthesisFailed("The synthesis model returned unparseable JSON.")
        }
        if let apiError = decoded.error {
            throw SearchError.synthesisFailed(
                "The synthesis model reported an error: \(apiError.message ?? apiError.type ?? "unknown")"
            )
        }
        guard let choice = decoded.choices?.first else {
            throw SearchError.synthesisFailed("The synthesis model returned no choices.")
        }

        return Completion(
            // Only `content` is the answer. `reasoning_content` is the model thinking
            // aloud and must never be shown as the result.
            text: choice.message?.content ?? "",
            finishReason: choice.finishReason,
            inputTokens: decoded.usage?.promptTokens,
            outputTokens: decoded.usage?.completionTokens
        )
    }

    /// Build the JSON body. Extracted so the thinking-mode contract can be asserted
    /// in a test without a network call.
    static func requestBody(
        model: String,
        systemPrompt: String,
        prompt: String,
        allowReasoning: Bool,
        maxTokens: Int = 4_000
    ) -> Data {
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt],
            ],
            "max_tokens": maxTokens,
            "stream": false,
            // Thinking is toggled explicitly in both directions: the API default is
            // *enabled*, so omitting this would silently opt into the mode that can
            // consume the whole budget and return an empty answer.
            "thinking": ["type": allowReasoning ? "enabled" : "disabled"],
        ]
        if allowReasoning {
            // `medium` maps to `high` server-side; low is the cheapest useful setting.
            payload["reasoning_effort"] = "low"
        }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data()
    }

    // MARK: Prompt assembly

    /// Render the numbered corpus the model cites against.
    static func buildCorpus(
        _ results: [SearchResult],
        perResultBudget: Int,
        totalBudget: Int
    ) -> String {
        var blocks: [String] = []
        var used = 0

        for (offset, result) in results.enumerated() {
            let index = offset + 1
            // Prefer the snippet: it is written as a summary and is far less likely to
            // contain the prompt-injection text that untrusted page bodies can carry.
            let detail = (result.snippet?.isEmpty == false ? result.snippet : result.content) ?? ""
            let clipped = clip(detail, to: perResultBudget)

            let block = "[\(index)] \(result.title)\nURL: \(result.url.absoluteString)\n\(clipped)"
            if used + block.count > totalBudget, !blocks.isEmpty {
                // Still name the remaining results so citation numbers stay aligned
                // with the list the caller sees; only their text is omitted.
                blocks.append("[\(index)] \(result.title)\nURL: \(result.url.absoluteString)\n(omitted for length)")
                continue
            }
            used += block.count
            blocks.append(block)
        }

        return blocks.joined(separator: "\n\n")
    }

    static func buildQuestion(_ query: String, locale: String?) -> String {
        var question = "QUESTION: \(query)"
        if let locale, !locale.isEmpty {
            question += "\nAnswer in the language implied by locale \(locale)."
        }
        return question
    }

    static func clip(_ text: String, to limit: Int) -> String {
        let collapsed =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    // MARK: Citation validation

    struct ValidatedCitations {
        var text: String
        var citations: [SynthesizedAnswer.Citation]
        /// Markers that referenced an index outside the supplied range.
        var strippedMarkers: Int
        /// `http(s)` links in the prose that matched no supplied result.
        var strippedLinks: Int
    }

    /// Compiled once, and a failure here is a programming error rather than a silent
    /// no-validation: `try?` per call plus `?? []` meant an uncompilable pattern returned an
    /// empty match list, i.e. "everything validated" (ledger B26).
    private static func compile(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("\(pattern) is not a valid regular expression")
        }
        return regex
    }

    static let markerPattern = compile(#"\[(\d{1,3})\]"#)
    /// Matches `http(s)` URLs in prose, including inside a Markdown link target.
    static let linkPattern = compile(#"https?://[^\s<>()\[\]"']+"#)

    /// Lowercased and without trailing slashes: enough to compare a link in prose with a
    /// supplied result, and deliberately not a general URL normaliser. A link that differs by
    /// more than that (a query, a fragment, a different path) counts as a different link.
    static func comparableURL(_ raw: String) -> String {
        var text = raw.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// Validate `[n]` markers against the supplied results.
    ///
    /// Valid markers are kept and renumbered to be contiguous; invalid ones are
    /// removed from the text and counted. Renumbering means a caller can render
    /// `citations` directly without knowing which subset the model chose.
    static func validateCitations(
        _ text: String,
        resultCount: Int,
        results: [SearchResult]
    ) -> ValidatedCitations {
        let matches = markerPattern.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )

        // First pass: which indices are valid, in order of appearance.
        var order: [Int] = []
        var invalidCount = 0
        for match in matches {
            guard let range = Range(match.range(at: 1), in: text),
                let number = Int(text[range])
            else { continue }
            if number >= 1, number <= resultCount {
                if !order.contains(number) { order.append(number) }
            } else {
                invalidCount += 1
            }
        }

        // Renumber: first-referenced supplied result becomes 1.
        var renumbering: [Int: Int] = [:]
        for (position, original) in order.enumerated() {
            renumbering[original] = position + 1
        }

        var citations: [SynthesizedAnswer.Citation] = []
        for original in order {
            let result = results[original - 1]
            citations.append(
                SynthesizedAnswer.Citation(
                    index: renumbering[original] ?? original,
                    sourceIndex: original,
                    title: result.title,
                    url: result.url,
                    sources: result.sources
                )
            )
        }

        // Rewrite the text so its markers match the renumbered citations, dropping
        // any marker that referenced nothing supplied.
        var rewritten = ""
        var cursor = text.startIndex
        for match in matches {
            guard let full = Range(match.range, in: text),
                let digits = Range(match.range(at: 1), in: text),
                let number = Int(text[digits])
            else { continue }
            rewritten += text[cursor..<full.lowerBound]
            if let mapped = renumbering[number] {
                rewritten += "[\(mapped)]"
            }
            // Invalid markers vanish here.
            cursor = full.upperBound
        }
        rewritten += text[cursor..<text.endIndex]

        // Links get the same treatment as markers. A model that writes a URL the corpus does
        // not contain is asserting a source it was never given, and the tool's own
        // documentation promised it could not (ledger B26).
        let supplied = Set(results.map { comparableURL($0.url.absoluteString) })
        var strippedLinks = 0
        var withLinks = ""
        var linkCursor = rewritten.startIndex
        let linkMatches = linkPattern.matches(
            in: rewritten,
            range: NSRange(rewritten.startIndex..<rewritten.endIndex, in: rewritten)
        )
        for match in linkMatches {
            guard let range = Range(match.range, in: rewritten) else { continue }
            let token = String(rewritten[range])
            withLinks += rewritten[linkCursor..<range.lowerBound]
            if supplied.contains(comparableURL(token)) {
                withLinks += token
            } else {
                strippedLinks += 1
                withLinks += "[link removed: not one of the fetched results]"
            }
            linkCursor = range.upperBound
        }
        withLinks += rewritten[linkCursor..<rewritten.endIndex]

        return ValidatedCitations(
            text: withLinks.trimmingCharacters(in: .whitespacesAndNewlines),
            citations: citations,
            strippedMarkers: invalidCount,
            strippedLinks: strippedLinks
        )
    }

    static func describe(_ error: any Error) -> String {
        if let searchError = error as? SearchError { return searchError.safeDescription }
        if error is CancellationError { return "The request was cancelled." }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "The synthesis model timed out."
            case .cancelled: return "The request was cancelled."
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                .dnsLookupFailed, .cannotFindHost:
                return "The synthesis model could not be reached."
            default:
                // Curated rather than `localizedDescription`, which can echo the URL.
                return "The synthesis request failed."
            }
        }
        return "The synthesis request failed."
    }
}

// MARK: - Wire types

/// Minimal decoding of the OpenAI-compatible chat-completions response.
///
/// Only the fields actually used are modelled, and `reasoning_content` is decoded
/// separately from `content` so the two can never be confused.
struct ChatCompletion: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
        }

        let message: Message?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    struct APIError: Decodable {
        let message: String?
        let type: String?
    }

    let choices: [Choice]?
    let usage: Usage?
    let error: APIError?
}
