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
/// - **An `enum` on a nullable property must list null too.** `type` and `enum` are
///   conjunctive in JSON Schema, so a value must satisfy both: an `enum` that names the
///   choices without null makes the null this required-list convention depends on an
///  invalid value. The schema lint enforces the pairing.
/// - **No `format` keyword.** OpenAI rejects anything outside a nine-value allowlist
///   (`date-time`, `time`, `date`, `duration`, `email`, `hostname`, `ipv4`, `ipv6`,
///   `uuid`); `format: "uri"` is a hard error, so URL shape is described in prose and
///   validated server-side.
/// - **No `default` keyword.** It is not a supported keyword and is rejected outright
///   on some OpenAI-compatible deployments. Defaults live in the description text and
///   are applied by the argument parser.
/// - **No `oneOf` / `allOf` / `not`.** Combinators, if ever needed, must be `anyOf`.
/// - **Zero-argument tools still declare `properties` and `required`** (as an empty object and
///   an empty array); an object schema with no `properties` key is rejected, and an absent
///   `required` is not the same contract as an empty one.
/// - **A tool that mirrors another tool's arguments declares the same constraints, not
///   copies of them.** `web_answer` runs the same discovery pass as `web_search`, so the
///   shared properties come from one definition and the schema lint compares them; a
///  hand-maintained copy had already lost `provider`'s `enum`.
/// - The root is always a closed object, never a union.
public enum ToolSchemas {
    public static let searchToolName = "web_search"
    public static let openToolName = "web_open"
    public static let statusToolName = "web_search_status"
    public static let answerToolName = "web_answer"

    /// The `provider` discovery argument, spelled once for both search tools.
    ///
    /// `web_answer` runs the same discovery pass as `web_search`, and the two tools
    /// must not teach a client two different sets of legal ids. An earlier hand-written
    /// copy on `web_answer` silently lost its `enum`, so a strict `tools/list` consumer
    /// could not discover the accepted ids for that tool at all. Deriving
    /// the list from `ProviderID.allCases` also removes the second failure mode a shared
    /// literal would keep: a provider added to the core enum but forgotten here would be
    /// rejected by this file's own advertised contract.
    ///
    /// `auto` is not a `ProviderID`; it is the sentinel both argument parsers translate
    /// into "let the orchestrator choose". `null` belongs to the list because the
    /// property is a nullable union and the schema's own lint requires an `enum` to
    /// admit every value its `type` admits.
    private static var providerDiscoverySchema: Value {
        .object([
            "description": .string(
                "Force a single search provider by id, or \"auto\" (default) to select "
                    + "automatically"
            ),
            "enum": .array(
                [.string("auto")]
                    + ProviderID.allCases.map { Value.string($0.rawValue) }
                    + [.null]
            ),
            "type": .array([.string("string"), .string("null")]),
        ])
    }

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
                    // `enum` and `type` are conjunctive in JSON Schema, so a null the
                    // union advertises must appear here too: this property is required,
                    // and null is how a strict client asks for the default.
                    "enum": ["any", "day", "week", "month", "year", Value.null],
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
                "provider": Self.providerDiscoverySchema,
                "mode": [
                    "type": ["string", "null"],
                    // `enum` and `type` are conjunctive in JSON Schema, so a null the
                    // union advertises must appear here too: this property is required,
                    // and null is how a strict client asks for the default.
                    "enum": ["fast", "balanced", "thorough", Value.null],
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
                    // `enum` and `type` are conjunctive in JSON Schema, so a null the
                    // union advertises must appear here too: this property is required,
                    // and null is how a strict client asks for the default.
                    "enum": ["any", "day", "week", "month", "year", Value.null],
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
                    // `enum` and `type` are conjunctive in JSON Schema, so a null the
                    // union advertises must appear here too: this property is required,
                    // and null is how a strict client asks for the default.
                    "enum": ["fast", "balanced", "thorough", Value.null],
                    "description": "Search depth before answering; default \"balanced\"",
                ],
                "provider": Self.providerDiscoverySchema,
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
            // A zero-argument tool still declares `properties` and `required`: an object
            // schema with no `properties` key at all is rejected by strict validation, and
            // the schema lint requires every object to carry an explicit `required` list
            // rather than reading an absent one as empty.
            "properties": Value.object([:]),
            "required": [],
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
