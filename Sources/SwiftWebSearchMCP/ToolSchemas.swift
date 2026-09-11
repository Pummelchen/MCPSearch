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
public enum ToolSchemas {
    public static let searchToolName = "web_search"
    public static let openToolName = "web_open"
    public static let statusToolName = "web_search_status"

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
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 20,
                    "default": 8,
                    "description": "Maximum number of fused results to return",
                ],
                "recency": [
                    "type": "string",
                    "enum": ["any", "day", "week", "month", "year"],
                    "default": "any",
                    "description": "Restrict results to a publication time window",
                ],
                "include_domains": [
                    "type": "array",
                    "items": ["type": "string"],
                    "maxItems": 20,
                    "description": "Only return results from these domains",
                ],
                "exclude_domains": [
                    "type": "array",
                    "items": ["type": "string"],
                    "maxItems": 20,
                    "description": "Never return results from these domains",
                ],
                "locale": [
                    "type": "string",
                    "description": "Optional locale such as en-US or de-DE",
                ],
                "provider": [
                    "type": "string",
                    "enum": [
                        "auto", "tavily", "brave", "mojeek", "exa", "searxng",
                        "open_web_search", "duckduckgo", "startpage", "parallel",
                    ],
                    "default": "auto",
                    "description": Value.string(
                        "Force a single provider instead of automatic selection"
                    ),
                ],
                "mode": [
                    "type": "string",
                    "enum": ["fast", "balanced", "thorough"],
                    "default": "balanced",
                    "description": Value.string(
                        "fast uses one provider; balanced fuses two; thorough fuses three "
                            + "and may add an aggregator"
                    ),
                ],
            ],
            "required": ["query"],
            "additionalProperties": false,
        ]
    }

    /// Output schema advertised to clients that support structured results.
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
                        "required": ["rank", "title", "url", "sources"],
                    ],
                ],
                "providers_used": ["type": "array", "items": ["type": "string"]],
                "providers_failed": ["type": "array", "items": ["type": "object"]],
                "warnings": ["type": "array", "items": ["type": "string"]],
                "retrieved_at": ["type": "string"],
            ],
            "required": ["query", "results", "providers_used", "retrieved_at"],
        ]
    }

    // MARK: - web_open

    public static var webOpenInput: Value {
        [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "format": "uri",
                    "description": "Absolute http or https URL to fetch",
                ],
                "max_characters": [
                    "type": "integer",
                    "minimum": 1000,
                    "maximum": 50000,
                    "default": 12000,
                    "description": "Maximum number of characters of readable text to return",
                ],
            ],
            "required": ["url"],
            "additionalProperties": false,
        ]
    }

    public static var webOpenOutput: Value {
        [
            "type": "object",
            "properties": [
                "url": ["type": "string"],
                "final_url": ["type": "string"],
                "status": ["type": "integer"],
                "title": ["type": ["string", "null"]],
                "content_type": ["type": ["string", "null"]],
                "text": ["type": "string"],
                "extraction_method": ["type": "string"],
                "truncated": ["type": "boolean"],
                "warnings": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["url", "final_url", "status", "text", "extraction_method"],
        ]
    }

    // MARK: - web_search_status

    public static var statusInput: Value {
        [
            "type": "object",
            "properties": Value.object([:]),
            "additionalProperties": false,
        ]
    }

    public static var statusOutput: Value {
        [
            "type": "object",
            "properties": [
                "providers": ["type": "array", "items": ["type": "object"]],
                "cache": ["type": "object"],
                "scrapers_enabled": ["type": "boolean"],
                "parallel_enabled": ["type": "boolean"],
            ],
            "required": ["providers"],
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

    public static func openStructured(_ result: FetchResult, requestedURL: URL) -> Value {
        var fields: [String: Value] = [
            "url": .string(requestedURL.absoluteString),
            "final_url": .string(result.finalURL.absoluteString),
            "status": .int(result.statusCode),
            "text": .string(result.text),
            "extraction_method": .string(result.method.rawValue),
            "truncated": .bool(result.truncated),
            "warnings": .array(result.warnings.map { Value.string($0) }),
        ]
        fields["title"] = result.title.map { Value.string($0) } ?? .null
        fields["content_type"] = result.contentType.map { Value.string($0) } ?? .null
        return .object(fields)
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
            var fields: [String: Value] = [
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
            ]
            if let lastError = state.lastError {
                fields["last_error"] = .string(lastError)
            }
            if let category = state.lastErrorCategory {
                fields["last_error_category"] = .string(category.rawValue)
            }
            if let note = state.note {
                fields["note"] = .string(note)
            }
            if let lastSuccess = state.lastSuccessAt {
                fields["last_success_at"] = .string(timestamp(lastSuccess))
            }
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
