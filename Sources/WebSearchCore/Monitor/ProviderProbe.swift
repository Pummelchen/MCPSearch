import Foundation

/// Probes every configured provider through the same code path the server uses.
///
/// It calls each `SearchProvider` directly rather than going through the MCP server, so
/// the monitor sees a provider's own latency and error rather than a fused result. That
/// is the point: the dashboard exists to show *which* provider is failing, which a fused
/// answer deliberately hides.
public struct ProviderProbe: Sendable {
    let registry: ProviderRegistry
    let configuration: AppConfiguration
    let log: Log

    public init(registry: ProviderRegistry, configuration: AppConfiguration, log: Log = .disabled) {
        self.registry = registry
        self.configuration = configuration
        self.log = log
    }

    /// Build the set of providers the monitor will show.
    ///
    /// Includes unconfigured providers on purpose: knowing that Brave has no key is
    /// useful, and omitting it would make the dashboard silently incomplete.
    public static func buildConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppConfiguration {
        AppConfiguration.load(environment: environment)
    }

    public static func buildRegistry(
        configuration: AppConfiguration,
        http: any HTTPClient,
        log: Log
    ) -> ProviderRegistry {
        SearchPipelineFactory.make(configuration: configuration, http: http, log: log).registry
    }

    /// Providers in display order: usable first, then unconfigured ones.
    public func probeTargets() -> [ProviderID] {
        configuration.providerOrder.filter { $0.isSearchProvider }
    }

    /// Whether a provider has what it needs to run.
    public func isConfigured(_ id: ProviderID) -> Bool {
        registry.isConfigured(id)
    }

    /// A short hint for an unconfigured provider, matching the server's own wording so
    /// the dashboard and `web_search_status` never disagree.
    public func setupHint(for id: ProviderID) -> String {
        switch id {
        case .tavily: "TAVILY_API_KEY"
        case .brave: "BRAVE_SEARCH_API_KEY"
        case .mojeek: "MOJEEK_API_KEY"
        case .exa: "EXA_API_KEY"
        case .searxng: "SEARXNG_BASE_URL"
        case .openWebSearch: "OPEN_WEB_SEARCH_URL"
        case .duckDuckGo, .startpage: "SEARCH_ENABLE_SCRAPERS=true"
        case .parallel: "SEARCH_ENABLE_PARALLEL=true"
        case .jina: "JINA_API_KEY"
        }
    }

    /// Probe one provider once.
    ///
    /// The query rotates through a small cheap set so repeated probes do not all hit the
    /// same cached page upstream, while result counts stay comparable between refreshes.
    public func probe(_ id: ProviderID, query: String) async -> ProbeOutcome {
        guard let provider = registry.provider(id) else {
            return .failure(error: "no adapter registered", category: .notConfigured)
        }
        guard provider.isConfigured else {
            return .failure(
                error: "not configured — set \(setupHint(for: id))",
                category: .notConfigured
            )
        }

        let request = SearchRequest(
            query: query,
            maxResults: 5,
            // `fast` keeps the probe cheap: one provider, no fusion, and for Tavily it
            // stays on the 1-credit basic depth.
            mode: .fast
        )

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let response = try await provider.search(request)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            return .success(latencyMilliseconds: elapsed, resultCount: response.results.count)
        } catch let error as SearchError {
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            return .failure(
                error: error.safeDescription,
                category: error.category,
                latencyMilliseconds: elapsed
            )
        } catch is CancellationError {
            return .failure(error: "cancelled", category: .cancelled)
        } catch {
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            let mapped = HTTPStatusMapper.map(error, provider: id)
            return .failure(
                error: mapped.safeDescription,
                category: mapped.category,
                latencyMilliseconds: elapsed
            )
        }
    }
}

/// Rotating probe queries.
///
/// Deliberately short and unambiguous: a probe measures availability and latency, not
/// result quality, and a long query would spend provider credits for no extra signal.
public struct ProbeQueries: Sendable {
    private static let all = [
        "swift concurrency",
        "postgres index bloat",
        "rust tokio select",
        "kubernetes pod evicted",
        "http/3 quic deployment",
    ]
    private var index = 0

    public init() {}

    public mutating func next() -> String {
        let query = ProbeQueries.all[index % ProbeQueries.all.count]
        index += 1
        return query
    }
}
