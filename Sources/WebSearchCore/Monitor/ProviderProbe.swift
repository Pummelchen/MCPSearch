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
        configuration.providerOrder
    }

    /// Whether a provider has what it needs to run.
    ///
    /// Deliberately not "may the monitor use it": `SEARCH_DISABLED_PROVIDERS` is a separate
    /// question (`isEnabled`), and conflating the two made the dashboard label a provider the
    /// server refuses to use as ready.
    public func isConfigured(_ id: ProviderID) -> Bool {
        registry.isConfigured(id)
    }

    /// Whether the operator has left this provider switched on.
    public func isEnabled(_ id: ProviderID) -> Bool {
        registry.isEnabled(id)
    }

    /// Whether this run may probe the provider at all: switched on and holding its inputs.
    ///
    /// This is the monitor's copy of the server's eligibility rule, so a disabled provider is
    /// neither labelled ready nor sent a real search that spends a credit the server would
    /// never have spent.
    public func mayProbe(_ id: ProviderID) -> Bool {
        isEnabled(id) && isConfigured(id)
    }

    /// The providers this run will probe: the configured display order minus everything the
    /// operator disabled and everything without inputs.
    ///
    /// The monitor probes through here rather than filtering at the call site, so the set is
    /// asserted by a test instead of re-derived by reading the refresh loop.
    public func probeableTargets() -> [ProviderID] {
        probeTargets().filter { mayProbe($0) }
    }

    /// The variables that would make an inactive provider run, from the one enablement
    /// authority.
    ///
    /// Configuration-dependent on purpose: `parallel` needs the flag *and* an endpoint, and the
    /// hint names whichever this configuration is missing rather than always the flag.
    public func setupHint(for id: ProviderID) -> String {
        ProviderEnablement.assignmentList(for: id, in: configuration)
    }

    /// Probe one provider once.
    ///
    /// The query rotates through a small cheap set so repeated probes do not all hit the
    /// same cached page upstream, while result counts stay comparable between refreshes.
    public func probe(_ id: ProviderID, query: String) async -> ProbeOutcome {
        // Checked here as well as in `probeableTargets`, because `probe` is public and a
        // direct call must not spend a request on a provider the server refuses to use
        guard isEnabled(id) else {
            return .failure(error: "disabled via SEARCH_DISABLED_PROVIDERS", category: .notConfigured)
        }
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
