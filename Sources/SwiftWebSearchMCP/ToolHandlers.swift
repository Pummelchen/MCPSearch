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
            // Note: `try` is required here even though the payload is already a `Value`.
            // Swift ranks `CallTool.Result`'s generic Codable initializer ahead of the
            // `Value`-taking one for this call shape, and that initializer throws.
            let structured = ToolOutputFormatter.searchStructured(response)
            return try! CallTool.Result(
                content: [
                    .text(
                        text: ToolOutputFormatter.searchText(response),
                        annotations: nil,
                        _meta: nil
                    )
                ],
                structuredContent: structured,
                isError: false
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
            let structured = ToolOutputFormatter.openStructured(result, requestedURL: url)
            return try! CallTool.Result(
                content: [
                    .text(text: ToolOutputFormatter.openText(result), annotations: nil, _meta: nil)
                ],
                structuredContent: structured,
                isError: false
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
        } catch {
            return Self.error("Fetch failed: \(error.localizedDescription)")
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
        return try! CallTool.Result(
            content: [
                .text(
                    text: ToolOutputFormatter.statusText(states: states, cache: cache),
                    annotations: nil,
                    _meta: nil
                )
            ],
            structuredContent: structured,
            isError: false
        )
    }

    // MARK: - Helpers

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
        case .jina: "Set JINA_API_KEY."
        }
    }

    /// Build an error result with both text and a minimal structured payload.
    static func error(_ message: String) -> CallTool.Result {
        try! CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            structuredContent: .object(["error": .string(message)]),
            isError: true
        )
    }
}
