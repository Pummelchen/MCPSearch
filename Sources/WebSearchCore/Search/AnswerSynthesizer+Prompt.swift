import Foundation

extension AnswerSynthesizer {

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

            // Title and body both come from the page; the URL is ours only in the sense that a
            // provider supplied it, so none of the three is trusted with our delimiters.
            let block =
                "[\(index)] \(Self.sanitiseFences(result.title))\n"
                + "URL: \(Self.sanitiseFences(result.url.absoluteString))\n"
                + "\(Self.sanitiseFences(clipped))"
            if used + block.count > totalBudget, !blocks.isEmpty {
                // Still name the remaining results so citation numbers stay aligned
                // with the list the caller sees; only their text is omitted.
                // Sanitised exactly like the full block above. These two lines were the one place a
                // page-supplied string entered the corpus raw, so a title carrying a fence delimiter could
                // close the block and put instructions outside it — the injection the comment above says
                // the three fields must not be trusted with.
                blocks.append(
                    "[\(index)] \(Self.sanitiseFences(result.title))\n"
                        + "URL: \(Self.sanitiseFences(result.url.absoluteString))\n"
                        + "(omitted for length)"
                )
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
    /// empty match list, i.e. "everything validated".
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
        // documentation promised it could not.
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
