import Foundation
import MCP
import WebSearchCore

/// Renders tool results for MCP.
///
/// Every result carries both a compact textual form (for clients that surface only
/// text) and structured content (for clients that understand it). The text form is
/// deliberately terse: an agent needs source material, not provider JSON.
public enum ToolOutputFormatter {

    /// A stable ISO 8601 timestamp.
    ///
    /// The formatter is fully qualified because the bare name resolves to the
    /// CoreFoundation type in this context, which has a different API.
    public static func timestamp(_ date: Date) -> String {
        let formatter: Foundation.ISO8601DateFormatter = Foundation.ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = Foundation.TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: web_search

    public static func searchText(_ response: SearchResponse, maximumSnippet: Int = 400) -> String {
        var lines: [String] = []

        if response.results.isEmpty {
            lines.append("No results.")
        }

        for (index, result) in response.results.enumerated() {
            lines.append("[\(index + 1)] \(result.title)")
            lines.append("URL: \(result.url.absoluteString)")
            if let snippet = result.snippet, !snippet.isEmpty {
                let clipped =
                    snippet.count > maximumSnippet
                    ? String(snippet.prefix(maximumSnippet)) + "…"
                    : snippet
                lines.append("Snippet: \(clipped)")
            }
            if let published = result.publishedAt {
                lines.append("Published: \(timestamp(published))")
            }
            lines.append("Sources: \(result.sources.map(\.rawValue).joined(separator: ", "))")
            lines.append("")
        }

        if !response.providersFailed.isEmpty {
            lines.append(
                "Unavailable providers: "
                    + response.providersFailed
                    .map { "\($0.provider.rawValue) (\($0.category.rawValue))" }
                    .joined(separator: ", ")
            )
        }
        for warning in response.warnings where !warning.isEmpty {
            lines.append("Note: \(warning)")
        }
        if response.servedFromCache {
            lines.append("Note: served from local cache.")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func searchStructured(_ response: SearchResponse) -> Value {
        var results: [Value] = []
        results.reserveCapacity(response.results.count)
        for (index, result) in response.results.enumerated() {
            var entry: [String: Value] = [
                "rank": .int(index + 1),
                "title": .string(result.title),
                "url": .string(result.url.absoluteString),
                "sources": .array(result.sources.map { Value.string($0.rawValue) }),
            ]
            entry["snippet"] = result.snippet.map { Value.string($0) } ?? .null
            entry["published_at"] =
                result.publishedAt.map { Value.string(timestamp($0)) } ?? .null
            results.append(.object(entry))
        }

        var failures: [Value] = []
        failures.reserveCapacity(response.providersFailed.count)
        for failure in response.providersFailed {
            failures.append(
                .object([
                    "provider": .string(failure.provider.rawValue),
                    "category": .string(failure.category.rawValue),
                    "message": .string(failure.message),
                ])
            )
        }

        return .object([
            "query": .string(response.query),
            "results": .array(results),
            "providers_used": .array(response.providersUsed.map { Value.string($0.rawValue) }),
            "providers_failed": .array(failures),
            "warnings": .array(response.warnings.map { Value.string($0) }),
            "retrieved_at": .string(timestamp(response.retrievedAt)),
            "elapsed_ms": .int(response.elapsedMilliseconds),
            "served_from_cache": .bool(response.servedFromCache),
        ])
    }

    // MARK: web_answer

    /// Text rendering for `web_answer`.
    ///
    /// The answer comes first because that is what a caller asked for; sources follow
    /// so every `[n]` marker is resolvable without a second call.
    public static func answerText(
        _ response: SearchResponse,
        answer: SynthesizedAnswer?,
        warning: String?
    ) -> String {
        var lines: [String] = []

        if let answer {
            if answer.isInsufficient {
                lines.append("INSUFFICIENT — the search results do not answer this question.")
                lines.append("")
            }
            lines.append(answer.text)
            lines.append("")

            if answer.citations.isEmpty {
                lines.append("Sources: none cited.")
            } else {
                lines.append("Sources:")
                for citation in answer.citations {
                    lines.append("[\(citation.index)] \(citation.title)")
                    lines.append("    \(citation.url.absoluteString)")
                }
            }
            lines.append("")
            lines.append(
                "Answered by \(answer.model) from \(response.results.count) search "
                    + "result(s); the model has no web access and saw only these."
            )
        }

        if let warning, !warning.isEmpty {
            lines.append("")
            lines.append("Note: \(warning)")
        }

        if answer == nil {
            // No prose: fall back to the ordinary result listing so the call is still
            // useful rather than empty.
            lines.append(searchText(response))
        } else if !response.providersFailed.isEmpty {
            lines.append(
                "Unavailable providers: "
                    + response.providersFailed
                    .map { "\($0.provider.rawValue) (\($0.category.rawValue))" }
                    .joined(separator: ", ")
            )
        }

        for note in response.warnings where !note.isEmpty {
            lines.append("Note: \(note)")
        }
        if response.servedFromCache {
            lines.append("Note: search results served from local cache.")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func answerStructured(
        _ response: SearchResponse,
        answer: SynthesizedAnswer?,
        warning: String?,
        elapsedMilliseconds: Int
    ) -> Value {
        var citations: [Value] = []
        if let answer {
            citations.reserveCapacity(answer.citations.count)
            for citation in answer.citations {
                citations.append(
                    .object([
                        "index": .int(citation.index),
                        "title": .string(citation.title),
                        "url": .string(citation.url.absoluteString),
                        "sources": .array(citation.sources.map { Value.string($0.rawValue) }),
                    ])
                )
            }
        }

        var failures: [Value] = []
        failures.reserveCapacity(response.providersFailed.count)
        for failure in response.providersFailed {
            failures.append(
                .object([
                    "provider": .string(failure.provider.rawValue),
                    "category": .string(failure.category.rawValue),
                    "message": .string(failure.message),
                ])
            )
        }

        var warnings = response.warnings
        if let warning, !warning.isEmpty { warnings.append(warning) }

        // "answered" / "insufficient" / "results_only" — the last meaning the search
        // worked but no model produced prose, which a caller must not mistake for an
        // empty answer.
        let status: String
        if let answer {
            status = answer.isInsufficient ? "insufficient" : "answered"
        } else {
            status = "results_only"
        }

        return .object([
            "query": .string(response.query),
            "status": .string(status),
            "model": answer.map { Value.string($0.model) } ?? .null,
            "citations": .array(citations),
            "answer_characters": .int(answer?.text.count ?? 0),
            "results_considered": .int(response.results.count),
            "providers_used": .array(response.providersUsed.map { Value.string($0.rawValue) }),
            "providers_failed": .array(failures),
            "warnings": .array(warnings.map { Value.string($0) }),
            "retrieved_at": .string(timestamp(response.retrievedAt)),
            "elapsed_ms": .int(elapsedMilliseconds),
            "synthesis_ms": answer.map { Value.int($0.elapsedMilliseconds) } ?? .null,
            "served_from_cache": .bool(response.servedFromCache),
        ])
    }

    // MARK: web_open

    public static func openText(_ result: FetchResult) -> String {
        var header: [String] = []
        // The extracted body almost always opens with the page title, so synthesising a
        // heading for it printed the title twice on nearly every page.
        if let title = result.title, !title.isEmpty, !result.textAlreadyOpensWithTitle {
            header.append("# \(title)")
        }
        header.append("URL: \(result.finalURL.absoluteString)")
        header.append("Status: \(result.statusCode) (\(result.method.rawValue))")
        if result.truncated {
            header.append("Note: content was truncated.")
        }
        for warning in result.warnings where !warning.isEmpty {
            header.append("Note: \(warning)")
        }
        return header.joined(separator: "\n") + "\n\n" + result.text
    }

    /// Structured form of `web_open`.
    ///
    /// The readable text is **not** repeated here; it is carried once in the text
    /// content block. `text_characters` reports its length so a caller can detect
    /// truncation, and every property declared in the output schema is always present
    /// (absent optionals are explicit `null`) so the payload satisfies a closed schema.
    public static func openStructured(_ result: FetchResult, requestedURL: URL) -> Value {
        Value.object([
            "url": .string(requestedURL.absoluteString),
            "final_url": .string(result.finalURL.absoluteString),
            "status": .int(result.statusCode),
            "title": result.title.map { Value.string($0) } ?? .null,
            "content_type": result.contentType.map { Value.string($0) } ?? .null,
            "extraction_method": .string(result.method.rawValue),
            "truncated": .bool(result.truncated),
            "text_characters": .int(result.text.count),
            "warnings": .array(result.warnings.map { Value.string($0) }),
        ])
    }

    // MARK: web_search_status

    public static func statusStructured(
        states: [ProviderHealth.ProviderState],
        cache: SearchCache.Stats,
        configuration: AppConfiguration
    ) -> Value {
        var providers: [Value] = []
        providers.reserveCapacity(states.count)
        for state in states {
            // Every property is always emitted, using explicit nulls where a value is
            // absent, so the payload matches the closed output schema exactly.
            let fields: [String: Value] = [
                "provider": .string(state.provider.rawValue),
                "status": .string(state.status.rawValue),
                "configured": .bool(state.configured),
                "is_aggregator": .bool(state.provider.isAggregator),
                "is_experimental_scraper": .bool(state.provider.isExperimentalScraper),
                "source_family": .string(state.provider.sourceFamily.rawValue),
                "circuit_state": .string(state.circuit.state.rawValue),
                "requests": .int(state.totalRequests),
                "successes": .int(state.successes),
                "failures": .int(state.failures),
                "last_result_count": .int(state.lastResultCount),
                "average_latency_ms": .int(state.averageLatencyMilliseconds),
                "last_error": state.lastError.map { Value.string($0) } ?? .null,
                "last_error_category":
                    state.lastErrorCategory.map { Value.string($0.rawValue) } ?? .null,
                "last_success_at":
                    state.lastSuccessAt.map { Value.string(timestamp($0)) } ?? .null,
                "note": state.note.map { Value.string($0) } ?? .null,
            ]
            providers.append(.object(fields))
        }

        let cacheValue = Value.object([
            "entries": .int(cache.entries),
            "hits": .int(cache.hits),
            "misses": .int(cache.misses),
            "ttl_seconds": .int(Int(configuration.cacheTTL.seconds)),
        ])

        return .object([
            "providers": .array(providers),
            "cache": cacheValue,
            "scrapers_enabled": .bool(configuration.enableScrapers),
            "parallel_enabled": .bool(configuration.enableParallel),
            "provider_order": .array(
                configuration.providerOrder.map { Value.string($0.rawValue) }
            ),
        ])
    }

    public static func statusText(
        states: [ProviderHealth.ProviderState],
        cache: SearchCache.Stats
    ) -> String {
        var lines = ["Provider status:"]
        for state in states {
            var line = "- \(state.provider.rawValue): \(state.status.rawValue)"
            line += " [\(state.provider.sourceFamily.rawValue)]"
            if state.totalRequests > 0 {
                line += " requests=\(state.totalRequests) ok=\(state.successes)"
                line += " failed=\(state.failures)"
            }
            if state.circuit.state != .closed {
                line += " circuit=\(state.circuit.state.rawValue)"
            }
            lines.append(line)
            if let note = state.note {
                lines.append("    \(note)")
            }
            if let lastError = state.lastError {
                lines.append("    last error: \(lastError)")
            }
        }
        lines.append("Cache: \(cache.entries) entries, \(cache.hits) hits, \(cache.misses) misses")
        return lines.joined(separator: "\n")
    }
}
