import Foundation
import MCP
import WebSearchCore

/// JSON Schemas and argument parsing for the MCP tool surface.
///
/// Two rules shape this file:
/// 1. Provider-specific parameters never appear in the public schema. Only concepts
///    that map cleanly across every provider are exposed.
/// 2. The server never trusts client input, so every argument is validated here
///    before it reaches the orchestrator.
///
/// ## Cross-client schema discipline
///
/// The advertised schemas are written to be accepted by the strictest mainstream
/// consumers, because a schema that one client rejects can break the whole request.
/// Verified requirements that shape every schema below:
///
/// - **`additionalProperties: false` on every object.** OpenAI *requires* this under
///   strict mode; the most common real-world "MCP server breaks OpenAI" failure is a
///   *missing* one. It is not a risk to be removed.
/// - **Every declared property must also appear in `required`.** Optionality is
///   expressed as a **nullable type** (`["string", "null"]`), which OpenAI supports
///   under strict mode and documents as the idiom for optional fields. Clients that
///   are not strict simply omit the argument.
/// - **No `format` keyword.** OpenAI rejects anything outside a nine-value allowlist
///   (`date-time`, `time`, `date`, `duration`, `email`, `hostname`, `ipv4`, `ipv6`,
///   `uuid`); `format: "uri"` is a hard error, so URL shape is described in prose and
///   validated server-side.
/// - **No `default` keyword.** It is not a supported keyword and is rejected outright
///   on some OpenAI-compatible deployments. Defaults live in the description text and
///   are applied by the argument parser.
/// - **No `oneOf` / `allOf` / `not`.** Combinators, if ever needed, must be `anyOf`.
/// - **Zero-argument tools still declare `properties`** (as an empty object); an object
///   schema with no `properties` key is rejected.
/// - The root is always a closed object, never a union.
public enum ToolSchemas {
    public static let searchToolName = "web_search"
    public static let openToolName = "web_open"
    public static let statusToolName = "web_search_status"
    public static let answerToolName = "web_answer"

    // MARK: - web_search

    public static var webSearchInput: Value {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Natural-language or keyword web search query",
                ],
                "max_results": [
                    // Optional in the schema; expressed as nullable rather than omitted
                    // from `required`, because strict consumers require every property
                    // to be listed. Absent or null resolves to the default (8).
                    "type": ["integer", "null"],
                    "minimum": 1,
                    "maximum": 20,
                    "description": "Maximum number of fused results to return; 1-20, default 8",
                ],
                "recency": [
                    "type": ["string", "null"],
                    "enum": ["any", "day", "week", "month", "year"],
                    "description": "Publication time window; default \"any\"",
                ],
                "include_domains": [
                    "type": ["array", "null"],
                    "items": ["type": "string"],
                    "maxItems": 20,
                    "description": "Only return results from these domains; at most 20",
                ],
                "exclude_domains": [
                    "type": ["array", "null"],
                    "items": ["type": "string"],
                    "maxItems": 20,
                    "description": "Never return results from these domains; at most 20",
                ],
                "locale": [
                    "type": ["string", "null"],
                    "description": "Optional locale such as en-US or de-DE",
                ],
                "provider": [
                    "type": ["string", "null"],
                    "enum": [
                        "auto", "tavily", "brave", "mojeek", "exa", "searxng",
                        "open_web_search", "duckduckgo", "startpage", "parallel",
                    ],
                    "description": Value.string(
                        "Force a single provider instead of automatic selection; "
                            + "default \"auto\""
                    ),
                ],
                "mode": [
                    "type": ["string", "null"],
                    "enum": ["fast", "balanced", "thorough"],
                    "description": Value.string(
                        "fast uses one provider; balanced fuses two; thorough fuses three "
                            + "and may add an aggregator; default \"balanced\""
                    ),
                ],
            ],
            "required": [
                "query", "max_results", "recency", "include_domains", "exclude_domains",
                "locale", "provider", "mode",
            ],
            "additionalProperties": false,
        ]
    }

    /// Output schema advertised to clients that support structured results.
    ///
    /// This describes `structuredContent` exactly, and is closed with
    /// `additionalProperties: false` with a complete `required` list, so it survives
    /// strict validation. Note that neither OpenAI nor Anthropic surfaces a tool's
    /// `outputSchema` to the model; the matching text block is what reaches it, and
    /// this schema is documentation plus a contract for hosts that read it.
    ///
    /// The full page text is deliberately **not** duplicated here: it is carried once,
    /// in the text content block. Duplicating it previously doubled `web_open`
    /// payloads to roughly 25 000 characters, which is at the ceiling of what some
    /// hosts accept for a single tool result.
    public static var webSearchOutput: Value {
        [
            "type": "object",
            "properties": [
                "query": ["type": "string"],
                "results": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "rank": ["type": "integer"],
                            "title": ["type": "string"],
                            "url": ["type": "string"],
                            "snippet": ["type": ["string", "null"]],
                            "published_at": ["type": ["string", "null"]],
                            "sources": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": [
                            "rank", "title", "url", "snippet", "published_at", "sources",
                        ],
                        "additionalProperties": false,
                    ],
                ],
                "providers_used": ["type": "array", "items": ["type": "string"]],
                "providers_failed": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "provider": ["type": "string"],
                            "category": ["type": "string"],
                            "message": ["type": "string"],
                        ],
                        "required": ["provider", "category", "message"],
                        "additionalProperties": false,
                    ],
                ],
                "warnings": ["type": "array", "items": ["type": "string"]],
                "retrieved_at": ["type": "string"],
                "elapsed_ms": ["type": "integer"],
                "served_from_cache": ["type": "boolean"],
            ],
            "required": [
                "query", "results", "providers_used", "providers_failed", "warnings",
                "retrieved_at", "elapsed_ms", "served_from_cache",
            ],
            "additionalProperties": false,
        ]
    }

    // MARK: - web_open

    public static var webOpenInput: Value {
        [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    // No `format: "uri"`: that keyword is rejected by OpenAI's schema
                    // validation. Only public http/https URLs are accepted, which the
                    // SSRF policy enforces server-side.
                    "description": "Absolute http or https URL of a public page to fetch",
                ],
                "max_characters": [
                    "type": ["integer", "null"],
                    "minimum": 1000,
                    "maximum": 50000,
                    "description": Value.string(
                        "Maximum readable characters to return; 1000-50000, default 12000"
                    ),
                ],
            ],
            "required": ["url", "max_characters"],
            "additionalProperties": false,
        ]
    }

    /// Output schema for `web_open`.
    ///
    /// The readable text itself lives in the text content block rather than here, so it
    /// is transmitted exactly once. `text_characters` reports its size, which is what a
    /// caller needs in order to detect truncation without re-reading the payload.
    public static var webOpenOutput: Value {
        [
            "type": "object",
            "properties": [
                "url": ["type": "string"],
                "final_url": ["type": "string"],
                "status": ["type": "integer"],
                "title": ["type": ["string", "null"]],
                "content_type": ["type": ["string", "null"]],
                "extraction_method": ["type": "string"],
                "truncated": ["type": "boolean"],
                "text_characters": ["type": "integer"],
                "warnings": ["type": "array", "items": ["type": "string"]],
            ],
            "required": [
                "url", "final_url", "status", "title", "content_type",
                "extraction_method", "truncated", "text_characters", "warnings",
            ],
            "additionalProperties": false,
        ]
    }

    // MARK: - web_answer

    /// Input schema for `web_answer`.
    ///
    /// Deliberately mirrors `web_search`'s discovery arguments: the tool performs a
    /// real search first, then has a model answer from those results. It accepts no
    /// model-selection or prompt arguments, so a caller cannot turn it into a
    /// general-purpose LLM endpoint.
    public static var webAnswerInput: Value {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Question to answer from live web search results",
                ],
                "max_results": [
                    "type": ["integer", "null"],
                    "minimum": 1,
                    "maximum": 20,
                    "description": "Maximum search results to ground the answer in; 1-20, default 8",
                ],
                "recency": [
                    "type": ["string", "null"],
                    "enum": ["any", "day", "week", "month", "year"],
                    "description": "Publication time window; default \"any\"",
                ],
                "include_domains": [
                    "type": ["array", "null"],
                    "items": ["type": "string"],
                    "maxItems": 20,
                    "description": "Only ground the answer in these domains; at most 20",
                ],
                "exclude_domains": [
                    "type": ["array", "null"],
                    "items": ["type": "string"],
                    "maxItems": 20,
                    "description": "Never ground the answer in these domains; at most 20",
                ],
                "locale": [
                    "type": ["string", "null"],
                    "description": "Optional locale such as en-US or de-DE",
                ],
                "mode": [
                    "type": ["string", "null"],
                    "enum": ["fast", "balanced", "thorough"],
                    "description": "Search depth before answering; default \"balanced\"",
                ],
                "provider": [
                    "type": ["string", "null"],
                    "description": Value.string(
                        "Force one search provider by id, or \"auto\" (default) to "
                            + "select automatically"
                    ),
                ],
            ],
            "required": [
                "query", "max_results", "recency", "include_domains", "exclude_domains",
                "locale", "mode", "provider",
            ],
            "additionalProperties": false,
        ]
    }

    /// Output schema for `web_answer`.
    ///
    /// The prose lives in the text content block, so it is sent once; here only the
    /// citation sources the answer actually used are carried, plus the search
    /// provenance that produced them.
    public static var webAnswerOutput: Value {
        [
            "type": "object",
            "properties": [
                "query": ["type": "string"],
                "status": ["type": "string"],
                "model": ["type": ["string", "null"]],
                "citations": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "index": ["type": "integer"],
                            "title": ["type": "string"],
                            "url": ["type": "string"],
                            "sources": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": ["index", "title", "url", "sources"],
                        "additionalProperties": false,
                    ],
                ],
                "answer_characters": ["type": "integer"],
                "results_considered": ["type": "integer"],
                "providers_used": ["type": "array", "items": ["type": "string"]],
                "providers_failed": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "provider": ["type": "string"],
                            "category": ["type": "string"],
                            "message": ["type": "string"],
                        ],
                        "required": ["provider", "category", "message"],
                        "additionalProperties": false,
                    ],
                ],
                "warnings": ["type": "array", "items": ["type": "string"]],
                "retrieved_at": ["type": "string"],
                "elapsed_ms": ["type": "integer"],
                "synthesis_ms": ["type": ["integer", "null"]],
                "served_from_cache": ["type": "boolean"],
            ],
            "required": [
                "query", "status", "model", "citations", "answer_characters",
                "results_considered", "providers_used", "providers_failed", "warnings",
                "retrieved_at", "elapsed_ms", "synthesis_ms", "served_from_cache",
            ],
            "additionalProperties": false,
        ]
    }

    // MARK: - web_search_status

    public static var statusInput: Value {
        [
            "type": "object",
            // A zero-argument tool still declares `properties`. An object schema with no
            // `properties` key at all is rejected by strict validation.
            "properties": Value.object([:]),
            "additionalProperties": false,
        ]
    }

    public static var statusOutput: Value {
        [
            "type": "object",
            "properties": [
                "providers": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "provider": ["type": "string"],
                            "status": ["type": "string"],
                            "configured": ["type": "boolean"],
                            "is_aggregator": ["type": "boolean"],
                            "is_experimental_scraper": ["type": "boolean"],
                            "source_family": ["type": "string"],
                            "circuit_state": ["type": "string"],
                            "requests": ["type": "integer"],
                            "successes": ["type": "integer"],
                            "failures": ["type": "integer"],
                            "last_result_count": ["type": "integer"],
                            "average_latency_ms": ["type": "integer"],
                            "last_error": ["type": ["string", "null"]],
                            "last_error_category": ["type": ["string", "null"]],
                            "last_success_at": ["type": ["string", "null"]],
                            "note": ["type": ["string", "null"]],
                        ],
                        "required": [
                            "provider", "status", "configured", "is_aggregator",
                            "is_experimental_scraper", "source_family", "circuit_state",
                            "requests", "successes", "failures", "last_result_count",
                            "average_latency_ms", "last_error", "last_error_category",
                            "last_success_at", "note",
                        ],
                        "additionalProperties": false,
                    ],
                ],
                "cache": [
                    "type": "object",
                    "properties": [
                        "entries": ["type": "integer"],
                        "hits": ["type": "integer"],
                        "misses": ["type": "integer"],
                        "ttl_seconds": ["type": "integer"],
                    ],
                    "required": ["entries", "hits", "misses", "ttl_seconds"],
                    "additionalProperties": false,
                ],
                "scrapers_enabled": ["type": "boolean"],
                "parallel_enabled": ["type": "boolean"],
                "provider_order": ["type": "array", "items": ["type": "string"]],
            ],
            "required": [
                "providers", "cache", "scrapers_enabled", "parallel_enabled",
                "provider_order",
            ],
            "additionalProperties": false,
        ]
    }
}

// MARK: - Argument parsing

/// A validated view over MCP tool arguments.
///
/// Errors are thrown as `ArgumentError` and converted into `isError` tool results so
/// a model gets an actionable message rather than a protocol-level failure.
public struct ToolArguments: Sendable {
    private let raw: [String: Value]

    public init(_ raw: [String: Value]?) {
        self.raw = raw ?? [:]
    }

    public struct ArgumentError: Error, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    public func string(_ name: String) throws -> String? {
        guard let value = raw[name], !value.isNull else { return nil }
        guard let text = value.stringValue else {
            throw ArgumentError("`\(name)` must be a string")
        }
        return text
    }

    public func requiredString(_ name: String) throws -> String {
        guard let value = try string(name)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            throw ArgumentError("`\(name)` is required and must be a non-empty string")
        }
        return value
    }

    public func int(_ name: String) throws -> Int? {
        guard let value = raw[name], !value.isNull else { return nil }
        if let integer = value.intValue { return integer }
        // Tolerate a numeric string: some clients serialize numbers as strings.
        if let text = value.stringValue, let integer = Int(text) { return integer }
        throw ArgumentError("`\(name)` must be an integer")
    }

    public func bool(_ name: String) throws -> Bool? {
        guard let value = raw[name], !value.isNull else { return nil }
        guard let flag = value.boolValue else {
            throw ArgumentError("`\(name)` must be a boolean")
        }
        return flag
    }

    public func stringArray(_ name: String, maxItems: Int) throws -> [String] {
        guard let value = raw[name], !value.isNull else { return [] }
        guard let elements = value.arrayValue else {
            throw ArgumentError("`\(name)` must be an array of strings")
        }
        guard elements.count <= maxItems else {
            throw ArgumentError("`\(name)` accepts at most \(maxItems) entries")
        }
        var result: [String] = []
        for element in elements {
            guard let text = element.stringValue else {
                throw ArgumentError("`\(name)` must contain only strings")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }

    public func enumValue<T: RawRepresentable>(
        _ name: String,
        as type: T.Type = T.self,
        default fallback: T
    ) throws -> T where T.RawValue == String {
        guard let text = try string(name) else { return fallback }
        guard let parsed = T(rawValue: text.lowercased()) else {
            throw ArgumentError("`\(name)` must be one of the documented values")
        }
        return parsed
    }
}

// MARK: - Response formatting

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
        if let title = result.title, !title.isEmpty {
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
