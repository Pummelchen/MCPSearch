import Foundation
import MCP
import WebSearchCore

/// Implements the three MCP tools.
///
/// This layer knows about MCP and about the neutral `WebSearchCore` request/response
/// model. It knows nothing about any search vendor, which is what lets a provider be
/// added or removed without touching the tool surface.
struct ToolHandlers: Sendable {
    let pipeline: SearchPipelineFactory.Pipeline
    let log: Log

    init(pipeline: SearchPipelineFactory.Pipeline, log: Log) {
        self.pipeline = pipeline
        self.log = log
    }

    // MARK: - web_search

    func webSearch(_ arguments: [String: Value]?) async -> CallTool.Result {
        let args = ToolArguments(arguments)

        let query: String
        let maxResults: Int
        let recency: Recency
        let includeDomains: [String]
        let excludeDomains: [String]
        let locale: LocaleHint?
        let provider: ProviderID?
        let mode: SearchMode

        do {
            query = try args.requiredString("query")
            // Clamp rather than reject: a client asking for 50 results still gets a
            // useful answer, capped at the documented maximum.
            maxResults = min(max(1, try args.int("max_results") ?? pipeline.configuration.defaultMaxResults), 20)
            recency = try args.enumValue("recency", default: .any)
            includeDomains = try args.stringArray("include_domains", maxItems: 20)
            excludeDomains = try args.stringArray("exclude_domains", maxItems: 20)
            mode = try args.enumValue("mode", default: .balanced)

            if let rawLocale = try args.string("locale") {
                guard let parsed = LocaleHint(rawLocale) else {
                    return Self.error("`locale` must look like en-US or de-DE")
                }
                locale = parsed
            } else {
                locale = nil
            }

            let rawProvider = try args.string("provider") ?? "auto"
            if rawProvider.lowercased() == "auto" {
                provider = nil
            } else if let parsed = ProviderID(rawValue: rawProvider.lowercased()) {
                provider = parsed
            } else {
                return Self.error(
                    "`provider` must be one of: auto, "
                        + ProviderID.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
        } catch let error as ToolArguments.ArgumentError {
            return Self.error(error.message)
        } catch {
            return Self.error("Invalid arguments.")
        }

        let request = SearchRequest(
            query: query,
            maxResults: maxResults,
            recency: recency,
            includeDomains: includeDomains,
            excludeDomains: excludeDomains,
            locale: locale,
            mode: mode
        )

        do {
            let response = try await pipeline.orchestrator.search(
                request,
                requestedProvider: provider
            )
            // The payload is built as an explicitly typed `Value` and routed through
            // `Self.success`; see that helper for why this cannot be spelled with the
            // non-throwing initializer directly.
            return try Self.success(
                text: ToolOutputFormatter.searchText(response),
                structured: ToolOutputFormatter.searchStructured(response)
            )
        } catch is CancellationError {
            // Cancellation is a protocol-level event, not a tool failure to explain.
            return Self.error("Search cancelled.")
        } catch let error as SearchError {
            log.warning(
                "web_search failed",
                metadata: [
                    "query": log.queryDescription(query),
                    "category": error.category.rawValue,
                ]
            )
            return Self.error(errorMessage(for: error))
        } catch let error as ToolOutputError {
            // The search itself succeeded; only the structured payload failed to
            // encode. Report that plainly instead of blaming the search.
            log.error("web_search structured payload could not be encoded")
            return Self.error("Search succeeded but its result could not be encoded: \(error)")
        } catch {
            log.error("web_search failed unexpectedly")
            return Self.error("Search failed: \(error.localizedDescription)")
        }
    }

    // MARK: - web_open

    func webOpen(_ arguments: [String: Value]?) async -> CallTool.Result {
        let args = ToolArguments(arguments)

        let rawURL: String
        let maxCharacters: Int
        do {
            rawURL = try args.requiredString("url")
            maxCharacters = min(max(1_000, try args.int("max_characters") ?? 12_000), 50_000)
        } catch let error as ToolArguments.ArgumentError {
            return Self.error(error.message)
        } catch {
            return Self.error("Invalid arguments.")
        }

        guard let url = URL(string: rawURL) else {
            return Self.error("`url` must be a valid absolute URL")
        }

        do {
            let result = try await pipeline.fetcher.open(
                FetchRequest(url: url, maxCharacters: maxCharacters)
            )
            return try Self.success(
                text: ToolOutputFormatter.openText(result),
                structured: ToolOutputFormatter.openStructured(result, requestedURL: url)
            )
        } catch is CancellationError {
            return Self.error("Fetch cancelled.")
        } catch let error as SearchError {
            log.warning(
                "web_open failed",
                metadata: [
                    "host": url.host() ?? "unknown",
                    "category": error.category.rawValue,
                ]
            )
            return Self.error(errorMessage(for: error))
        } catch let error as ToolOutputError {
            log.error("web_open structured payload could not be encoded")
            return Self.error("Fetch succeeded but its result could not be encoded: \(error)")
        } catch {
            return Self.error("Fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - web_answer

    /// Search, then answer from what was found.
    ///
    /// The search half is the ordinary pipeline, so provider failover, fusion,
    /// caching and rate limiting all behave exactly as they do for `web_search`.
    /// Synthesis is layered strictly *after* results exist, which is what keeps a
    /// model with no web access from inventing them.
    ///
    /// A synthesis failure does **not** discard the search: the results are still
    /// returned, marked as unanswerable, because a caller can act on documents even
    /// when no prose summary could be produced.
    func webAnswer(_ arguments: [String: Value]?) async -> CallTool.Result {
        let args = ToolArguments(arguments)

        let query: String
        let maxResults: Int
        let recency: Recency
        let includeDomains: [String]
        let excludeDomains: [String]
        let locale: LocaleHint?
        let provider: ProviderID?
        let mode: SearchMode

        do {
            query = try args.requiredString("query")
            maxResults = min(max(1, try args.int("max_results") ?? pipeline.configuration.defaultMaxResults), 20)
            recency = try args.enumValue("recency", default: .any)
            includeDomains = try args.stringArray("include_domains", maxItems: 20)
            excludeDomains = try args.stringArray("exclude_domains", maxItems: 20)
            mode = try args.enumValue("mode", default: .balanced)

            if let rawLocale = try args.string("locale") {
                guard let parsed = LocaleHint(rawLocale) else {
                    return Self.error("`locale` must look like en-US or de-DE")
                }
                locale = parsed
            } else {
                locale = nil
            }

            let rawProvider = try args.string("provider") ?? "auto"
            if rawProvider.lowercased() == "auto" {
                provider = nil
            } else if let parsed = ProviderID(rawValue: rawProvider.lowercased()) {
                provider = parsed
            } else {
                return Self.error(
                    "`provider` must be one of: auto, "
                        + ProviderID.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
        } catch let error as ToolArguments.ArgumentError {
            return Self.error(error.message)
        } catch {
            return Self.error("Invalid arguments.")
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let request = SearchRequest(
            query: query,
            maxResults: maxResults,
            recency: recency,
            includeDomains: includeDomains,
            excludeDomains: excludeDomains,
            locale: locale,
            mode: mode
        )

        // Search first. Failures here are ordinary search failures.
        let response: SearchResponse
        do {
            response = try await pipeline.orchestrator.search(
                request,
                requestedProvider: provider
            )
        } catch is CancellationError {
            return Self.error("Search cancelled.")
        } catch let error as SearchError {
            log.warning(
                "web_answer search phase failed",
                metadata: [
                    "query": log.queryDescription(query),
                    "category": error.category.rawValue,
                ]
            )
            return Self.error(errorMessage(for: error))
        } catch {
            return Self.error("Search failed: \(error.localizedDescription)")
        }

        // Then answer from exactly those results.
        var synthesisWarning: String?
        var answer: SynthesizedAnswer?
        if pipeline.synthesizer.isConfigured {
            do {
                answer = try await pipeline.synthesizer.synthesize(
                    query: query,
                    results: response.results,
                    locale: locale?.identifier
                )
            } catch is CancellationError {
                return Self.error("Answer synthesis cancelled.")
            } catch let error as SearchError {
                log.warning(
                    "web_answer synthesis failed",
                    metadata: ["query": log.queryDescription(query)]
                )
                // Keep the search results; only the prose is missing.
                synthesisWarning = error.safeDescription
            } catch {
                synthesisWarning = "Answer synthesis failed."
            }
        } else {
            synthesisWarning = "No synthesis model is configured (set DEEPSEEK_API_KEY); "
                + "returning search results only."
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)

        do {
            return try Self.success(
                text: ToolOutputFormatter.answerText(
                    response,
                    answer: answer,
                    warning: synthesisWarning
                ),
                structured: ToolOutputFormatter.answerStructured(
                    response,
                    answer: answer,
                    warning: synthesisWarning,
                    elapsedMilliseconds: elapsed
                )
            )
        } catch let error as ToolOutputError {
            log.error("web_answer structured payload could not be encoded")
            return Self.error("Answer succeeded but its result could not be encoded: \(error)")
        } catch {
            return Self.error("Answer failed: \(error.localizedDescription)")
        }
    }

    // MARK: - web_search_status
    func status(_ arguments: [String: Value]?) async -> CallTool.Result {
        let states = await pipeline.orchestrator.status()
        let cache = await pipeline.orchestrator.cacheStats()

        let structured = ToolOutputFormatter.statusStructured(
            states: states,
            cache: cache,
            configuration: pipeline.configuration
        )
        do {
            return try Self.success(
                text: ToolOutputFormatter.statusText(states: states, cache: cache),
                structured: structured
            )
        } catch let error as ToolOutputError {
            log.error("web_search_status payload could not be encoded")
            return Self.error("Status could not be encoded: \(error)")
        } catch {
            return Self.error("Status failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Build a successful tool result carrying both a compact text form and
    /// structured content.
    ///
    /// - Throws: `ToolOutputError.encodingFailed` if the structured payload cannot be
    ///   encoded. Callers translate that into an error result, so a failure here
    ///   degrades to a tool error instead of crashing the server.
    ///
    /// - Note: The `try` is unavoidable. `CallTool.Result` declares both a
    ///   `structuredContent: Value?` initializer and a generic
    ///   `init<Output: Codable>(structuredContent: Output)`. Because `Value` itself
    ///   conforms to `Codable`, Swift always ranks the generic (throwing) overload
    ///   ahead of the non-generic one, so the non-throwing overload is unreachable
    ///   from Swift for any `Value`. Routing through one documented place keeps the
    ///   failure handling explicit rather than scattered as `try!` at each call site.
    static func success(text: String, structured: Value) throws -> CallTool.Result {
        do {
            return try CallTool.Result(
                content: [.text(text: text, annotations: nil, _meta: nil)],
                structuredContent: structured,
                isError: false
            )
        } catch {
            // Normalize to one error type so callers have a single case to handle.
            throw ToolOutputError.encodingFailed(String(describing: error))
        }
    }

    /// Turn a `SearchError` into an actionable tool message.
    ///
    /// Messages explain what the operator should change, because the usual consumer of
    /// this text is a model that will relay it to a human.
    func errorMessage(for error: SearchError) -> String {
        switch error {
        case .invalidRequest(let detail):
            detail
        case .allProvidersFailed:
            "All eligible search providers failed. Run web_search_status for per-provider "
                + "detail."
        case .providersFailed(let failures):
            // The reasons are already phrased for a human, so surface them directly
            // rather than making the caller run a second diagnostic call.
            SearchError.describe(failures)
        case .authenticationRequired(let provider):
            "\(provider.displayName) rejected the configured credentials. Check the API key."
        case .notConfigured(let provider):
            "\(provider.displayName) is not configured. "
                + unconfiguredHint(for: provider)
        case .unsupportedRequest(let provider, let detail):
            "\(provider.displayName) cannot serve this request: \(detail)"
        case .rateLimited(let provider, let retryAfter):
            if let retryAfter {
                "\(provider.displayName) is rate limited; retry in about "
                    + "\(max(1, retryAfter.milliseconds / 1000))s."
            } else {
                "\(provider.displayName) is rate limited. Try again shortly or use another provider."
            }
        case .blockedURL(let url):
            "Refused to fetch \(url.host() ?? "that URL"): only public http/https URLs are "
                + "allowed."
        case .timeout(let provider):
            "\(provider.displayName) timed out."
        case .fetchFailed(let url, let reason):
            "Could not fetch \(url.host() ?? "that URL"): \(reason)"
        case .extractionFailed(let url):
            "Could not extract readable content from \(url.host() ?? "that URL")."
        default:
            error.safeDescription
        }
    }

    private func unconfiguredHint(for provider: ProviderID) -> String {
        switch provider {
        case .tavily: "Set TAVILY_API_KEY."
        case .brave: "Set BRAVE_SEARCH_API_KEY."
        case .mojeek: "Set MOJEEK_API_KEY."
        case .exa: "Set EXA_API_KEY."
        case .searxng: "Set SEARXNG_BASE_URL to an instance with JSON output enabled."
        case .openWebSearch: "Set OPEN_WEB_SEARCH_URL."
        case .duckDuckGo, .startpage: "Set SEARCH_ENABLE_SCRAPERS=true to enable scrapers."
        case .parallel: "Set SEARCH_ENABLE_PARALLEL=true to enable the upstream MCP provider."
        }
    }

    /// Build an error result.
    ///
    /// Deliberately text-only: an error result carries no structured payload, which
    /// avoids the `Codable`-overload problem described on `success` entirely and keeps
    /// this path free of `try`.
    static func error(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

/// Failure to build a tool result payload.
enum ToolOutputError: Error, Sendable {
    /// The structured content could not be encoded.
    case encodingFailed(String)
}
