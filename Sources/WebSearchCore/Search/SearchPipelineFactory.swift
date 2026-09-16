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
        var providers: [any SearchProvider] = []
        var registrations: [ProviderHealth.Registration] = []
        var notes: [ProviderID: String] = [:]

        // Each provider gets a rate policy appropriate to how tolerant the upstream is
        // of bursts. Opt-in scrapers are throttled hard on purpose.
        //
        // Registration is collected here and applied when the health actor is created
        // rather than through a detached `Task`. The previous form returned a pipeline
        // whose breakers and limiters might not exist yet, so a request arriving in that
        // window bypassed both.
        func register(
            _ provider: any SearchProvider,
            rate: RateLimiter.Policy = .apiDefault
        ) {
            providers.append(provider)
            registrations.append(
                ProviderHealth.Registration(provider: provider.id, ratePolicy: rate)
            )
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

        // Why a provider is inert is derived from the one enablement authority rather than
        // written per provider, so the status tool, the tool error text, the monitor and the
        // startup inventory cannot disagree. Deriving it after registration also
        // gives the scraper and Parallel entries a note, which they never had.
        for id in configuration.providerOrder
        where !ProviderEnablement.isSatisfied(id, in: configuration) {
            notes[id] = ProviderEnablement.instruction(for: id, in: configuration)
        }

        let health = ProviderHealth(
            clock: clock,
            registrations: registrations,
            notes: notes
        )

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

        let fetcher = makeFetcher(configuration: configuration, http: http, log: log)

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
    /// The page fetcher: direct first, the reader as the sanctioned fallback.
    ///
    /// Separate from `make` so the composition root stays readable, and because the fetch path
    /// is independent of the search providers — it needs only the SSRF policy, the optional
    /// reader, and a deadline.
    private static func makeFetcher(
        configuration: AppConfiguration,
        http: HTTPClient,
        log: Log
    ) -> WebFetcher {
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

        // The fetch deadline scales with the request timeout (three times it, at least 15 s):
        // a deployment that raises SEARCH_REQUEST_TIMEOUT_MS for slow origins gets a
        // proportionally patient page fetch, and the default 10 s gives the documented 30 s.
        return WebFetcher(
            direct: direct,
            policy: WebFetcher.Policy(
                totalTimeout: max(configuration.requestTimeout * 3, .seconds(15))
            ),
            jina: jina,
            log: log
        )
    }

}
