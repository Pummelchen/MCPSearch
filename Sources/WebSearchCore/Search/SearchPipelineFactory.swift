import Foundation

/// Composition root for the search pipeline.
///
/// This is the single place that knows how to turn configuration into concrete
/// providers, rate limits and fusion state. Keeping it out of the MCP layer is what
/// lets the MCP layer know almost nothing about any vendor.
public enum SearchPipelineFactory {

    /// Everything the tools need.
    public struct Pipeline: Sendable {
        public let registry: ProviderRegistry
        public let health: ProviderHealth
        public let cache: SearchCache
        public let orchestrator: SearchOrchestrator
        public let fetcher: WebFetcher
        /// Grounded answer synthesis. Always present; check `isConfigured` before use.
        /// It is not a search provider and never takes part in provider selection.
        public let synthesizer: AnswerSynthesizer
        public let configuration: AppConfiguration
    }

    /// Build the pipeline from configuration.
    public static func make(
        configuration: AppConfiguration,
        http: any HTTPClient,
        log: Log = .disabled,
        clock: any Clock = SystemClock()
    ) -> Pipeline {
        let health = ProviderHealth(clock: clock)
        var providers: [any SearchProvider] = []

        // Each provider gets a rate policy appropriate to how tolerant the upstream is
        // of bursts. Opt-in scrapers are throttled hard on purpose.
        func register(
            _ provider: any SearchProvider,
            rate: RateLimiter.Policy = .apiDefault
        ) {
            providers.append(provider)
            Task { await health.register(provider.id, ratePolicy: rate) }
        }

        if let key = configuration.tavilyAPIKey, !key.isEmpty {
            register(
                TavilyProvider(
                    apiKey: key,
                    http: http,
                    configuration: configuration,
                    log: log
                )
            )
        } else {
            Task { await health.setNote("Set TAVILY_API_KEY to enable.", for: .tavily) }
        }

        if let key = configuration.braveAPIKey, !key.isEmpty {
            register(
                BraveProvider(
                    apiKey: key,
                    http: http,
                    configuration: configuration,
                    log: log
                )
            )
        } else {
            Task { await health.setNote("Set BRAVE_SEARCH_API_KEY to enable.", for: .brave) }
        }

        if let key = configuration.mojeekAPIKey, !key.isEmpty {
            register(
                MojeekProvider(
                    apiKey: key,
                    http: http,
                    configuration: configuration,
                    log: log
                )
            )
        } else {
            Task { await health.setNote("Set MOJEEK_API_KEY to enable.", for: .mojeek) }
        }

        if let key = configuration.exaAPIKey, !key.isEmpty {
            register(
                ExaProvider(
                    apiKey: key,
                    http: http,
                    configuration: configuration,
                    log: log
                )
            )
        } else {
            Task { await health.setNote("Set EXA_API_KEY to enable.", for: .exa) }
        }

        if let baseURL = configuration.searxngBaseURL {
            register(
                SearXNGProvider(
                    baseURL: baseURL,
                    http: http,
                    configuration: configuration,
                    log: log
                ),
                rate: .selfHosted
            )
        } else {
            Task {
                await health.setNote(
                    "Set SEARXNG_BASE_URL to a self-hosted instance with JSON enabled.",
                    for: .searxng
                )
            }
        }

        if let endpoint = configuration.openWebSearchURL {
            register(
                OpenWebSearchProvider(
                    endpoint: endpoint,
                    http: http,
                    configuration: configuration,
                    log: log
                )
            )
        } else {
            Task {
                await health.setNote(
                    "Set OPEN_WEB_SEARCH_URL to an aggregation endpoint to enable.",
                    for: .openWebSearch
                )
            }
        }

        // Scrapers are constructed regardless of the flag so that the status tool can
        // explain *why* they are inert, but they report themselves as unconfigured
        // unless explicitly enabled.
        register(
            DuckDuckGoProvider(
                http: http,
                configuration: configuration,
                scrapersEnabled: configuration.enableScrapers,
                log: log
            ),
            rate: .scraper
        )
        register(
            StartpageProvider(
                http: http,
                configuration: configuration,
                scrapersEnabled: configuration.enableScrapers,
                log: log
            ),
            rate: .scraper
        )

        if let endpoint = configuration.parallelMCPURL {
            register(
                ParallelMCPProvider(
                    endpoint: endpoint,
                    http: http,
                    configuration: configuration,
                    enabled: configuration.enableParallel,
                    log: log
                )
            )
        }

        if let key = configuration.jinaAPIKey, !key.isEmpty {
            register(
                JinaSearchProvider(
                    apiKey: key,
                    http: http,
                    configuration: configuration,
                    log: log
                ),
                rate: .apiDefault
            )
        }

        let registry = ProviderRegistry(
            providers: providers,
            configuration: configuration
        )

        let cache = SearchCache(clock: clock)

        let orchestrator = SearchOrchestrator(
            registry: registry,
            health: health,
            cache: cache,
            configuration: configuration,
            clock: clock,
            log: log
        )

        // The fetch path is independent of the search providers; it only needs the
        // SSRF policy and, optionally, the Jina Reader fallback.
        let urlPolicy = URLPolicy(
            allowPrivateNetwork: configuration.allowPrivateNetworkFetch
        )
        let direct = DirectHTTPFetcher(
            configuration: configuration,
            policy: urlPolicy,
            log: log
        )
        let jina: JinaReaderFetcher? =
            configuration.enableJinaReaderFallback
            ? JinaReaderFetcher(
                apiKey: configuration.jinaAPIKey,
                http: http,
                configuration: configuration,
                log: log
            )
            : nil

        let fetcher = WebFetcher(direct: direct, jina: jina, log: log)

        // Synthesis shares the fetched-results contract but not the provider path: it is
        // wired from configuration only, so adding a key can never change which
        // providers search or how results are fused.
        let synthesizer = AnswerSynthesizer(
            configuration: configuration,
            http: http,
            log: log
        )

        return Pipeline(
            registry: registry,
            health: health,
            cache: cache,
            orchestrator: orchestrator,
            fetcher: fetcher,
            synthesizer: synthesizer,
            configuration: configuration
        )
    }
}
