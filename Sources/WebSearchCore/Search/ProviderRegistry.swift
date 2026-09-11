import Foundation

/// Holds every constructed provider and answers "who can serve this request?".
///
/// The registry is the only place that knows which providers exist. The orchestrator
/// asks it for candidates; the MCP layer asks it for status. Adding or removing a
/// vendor touches this file and one adapter, nothing else.
public struct ProviderRegistry: Sendable {
    private let providers: [ProviderID: any SearchProvider]
    private let configuration: AppConfiguration

    public init(providers: [any SearchProvider], configuration: AppConfiguration) {
        var mapped: [ProviderID: any SearchProvider] = [:]
        for provider in providers {
            mapped[provider.id] = provider
        }
        self.providers = mapped
        self.configuration = configuration
    }

    /// Every known provider, in the configured preference order.
    public var ordered: [any SearchProvider] {
        configuration.providerOrder.compactMap { providers[$0] }
    }

    public func provider(_ id: ProviderID) -> (any SearchProvider)? {
        providers[id]
    }

    public func isEnabled(_ id: ProviderID) -> Bool {
        configuration.providerEnabled[id] ?? true
    }

    public func isConfigured(_ id: ProviderID) -> Bool {
        providers[id]?.isConfigured ?? false
    }

    /// Whether a provider may be used for an automatic selection.
    public func isEligible(_ id: ProviderID) -> Bool {
        guard let provider = providers[id] else { return false }
        guard isEnabled(id), provider.isConfigured else { return false }
        // Scrapers are opt-in because their markup is not a contract.
        if id.isExperimentalScraper, !configuration.enableScrapers { return false }
        if id == .parallel, !configuration.enableParallel { return false }
        if id == .jina { return false }  // fetch-only; never selected for search
        return id.isSearchProvider
    }

    /// Eligible providers in preference order.
    public func eligibleProviders() -> [any SearchProvider] {
        ordered.filter { isEligible($0.id) }
    }

    /// Providers that could serve a request but are excluded, with the reason.
    /// This is what makes `web_search_status` actionable rather than cryptic.
    public func ineligibleReasons() -> [ProviderID: String] {
        var reasons: [ProviderID: String] = [:]
        for id in configuration.providerOrder {
            guard let provider = providers[id] else {
                reasons[id] = "no adapter registered"
                continue
            }
            if !isEnabled(id) {
                reasons[id] = "disabled via SEARCH_DISABLED_PROVIDERS"
            } else if !provider.isConfigured {
                reasons[id] = "no credentials or endpoint configured"
            } else if id.isExperimentalScraper, !configuration.enableScrapers {
                reasons[id] = "scraper disabled; set SEARCH_ENABLE_SCRAPERS=true to enable"
            } else if id == .parallel, !configuration.enableParallel {
                reasons[id] = "disabled; set SEARCH_ENABLE_PARALLEL=true to enable"
            } else if id == .jina {
                reasons[id] = "fetch-only provider, not used for search"
            }
        }
        return reasons
    }

    /// Fusion weight for a provider, used as the RRF input.
    public func fusionWeight(_ id: ProviderID) -> Double {
        providers[id]?.fusionWeight ?? 1.0
    }

    /// All registry fusion weights, as the fusion function expects.
    public var fusionWeights: [ProviderID: Double] {
        var weights: [ProviderID: Double] = [:]
        for (id, provider) in providers {
            weights[id] = provider.fusionWeight
        }
        return weights
    }

    // MARK: - Selection

    public enum Selection: Sendable, Hashable {
        /// Query every candidate concurrently (used by `fast` with one provider and
        /// by explicit provider selection).
        case selected([ProviderID])
        case none
    }

    /// Choose which providers to query for a request.
    ///
    /// Direct providers are preferred over aggregators, because an aggregator is
    /// usually a reseller and would otherwise fill the "independent evidence" slots
    /// with duplicated upstream results.
    public func select(for request: SearchRequest, requested: ProviderID?) throws -> Selection {
        // An explicit provider always takes the explicit path. It must never silently
        // degrade to automatic selection: a caller that forces one provider and gets
        // another cannot tell the difference, and a missing key would look like a
        // successful search.
        if let requested {
            // Explicit selection bypasses policy but not configuration.
            if requested == .jina {
                throw SearchError.unsupportedRequest(
                    requested,
                    "this is a fetch/extraction provider, not a search provider; "
                        + "use the web_open tool instead"
                )
            }
            guard providers[requested] != nil else {
                throw SearchError.notConfigured(requested)
            }
            guard isEnabled(requested) else {
                throw SearchError.unsupportedRequest(requested, "provider is disabled")
            }
            if requested == .parallel, !configuration.enableParallel {
                throw SearchError.unsupportedRequest(
                    requested,
                    "set SEARCH_ENABLE_PARALLEL=true to enable this provider"
                )
            }
            if requested.isExperimentalScraper, !configuration.enableScrapers {
                throw SearchError.unsupportedRequest(
                    requested,
                    "set SEARCH_ENABLE_SCRAPERS=true to enable scraper providers"
                )
            }
            guard isConfigured(requested) else {
                throw SearchError.notConfigured(requested)
            }
            return .selected([requested])
        }

        let eligible = eligibleProviders()
        guard !eligible.isEmpty else { return .none }

        // Tiers, most preferred first. Within a tier the configured order decides.
        // Scrapers are last because their markup is not a contract, and aggregators
        // sit below real indexes because they usually resell one.
        let independent = eligible.filter {
            !$0.id.isAggregator && !$0.id.isExperimentalScraper
                && $0.id.sourceFamily.isIndependentIndex
        }
        let otherDirect = eligible.filter {
            !$0.id.isAggregator && !$0.id.isExperimentalScraper
                && !$0.id.sourceFamily.isIndependentIndex
        }
        let aggregators = eligible.filter { $0.id.isAggregator }
        let scrapers = eligible.filter { $0.id.isExperimentalScraper }

        let budget = request.mode.maxDirectProviders
        var chosen: [ProviderID] = []

        for tier in [independent, otherDirect, aggregators, scrapers] {
            for provider in tier where chosen.count < budget {
                chosen.append(provider.id)
            }
        }

        return chosen.isEmpty ? .none : .selected(chosen)
    }

    /// Aggregators eligible to supply extra coverage in `thorough` mode.
    public func aggregatorCandidates(excluding excluded: Set<ProviderID>) -> [ProviderID] {
        eligibleProviders()
            .filter { $0.id.isAggregator && !excluded.contains($0.id) }
            .map(\.id)
    }
}
