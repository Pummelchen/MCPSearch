import Foundation

/// Weighted Reciprocal Rank Fusion with source-family awareness.
///
/// Provider relevance scores are **not** comparable across vendors: a Tavily score
/// of 0.87 and an Exa score of 0.87 mean different things. Fusion is therefore
/// rank-based, never score-based.
///
/// ```
/// score(result) = Σ  (providerWeight × familyWeight) / (k + providerRank)
/// ```
///
/// Two providers that read the same underlying index are not independent evidence,
/// so an aggregator's vote is discounted unless the same result is *also* reported
/// by a provider in a different source family. This stops one Brave result arriving
/// via a SearXNG instance from looking like two confirmations.
public enum RankFusion {

    // MARK: - Configuration

    public struct Configuration: Sendable, Hashable, Codable {
        /// RRF smoothing constant. 60 is the canonical value from the original
        /// Cormack et al. formulation and is deliberately not tuned per query.
        public var k: Double
        /// Extra weight for providers whose results came from an independent crawl.
        public var independentIndexWeight: Double
        /// Weight multiplier applied to an aggregator that resells an index already
        /// represented in the same run by a provider that owns it.
        ///
        /// This is deliberately **not** a blanket penalty. The score is
        /// `weight / (k + rank)`, so once a weight ratio exceeds the reachable rank ratio
        /// `(k + maxRank) / (k + 1)`, one provider's *entire* result list outranks
        /// another's and fusion stops ordering by relevance, becoming a provider
        /// preference instead. With the default `k = 60` and a page of results that
        /// ratio is only about 1.08, so even a modest penalty is enough to cause it.
        ///
        /// An aggregator is therefore discounted only when it demonstrably resells an
        /// index that another provider in the same run already owns; otherwise its
        /// results compete on rank, which is the point of rank fusion. Search engines
        /// expose no per-result engine attribution through the APIs used here, so that is
        /// detected from the upstream engines the adapter reports.
        public var duplicatedAggregatorWeight: Double
        /// Weight multiplier applied to opt-in HTML scrapers, whose markup is not a
        /// contract and whose ordering is therefore less trustworthy.
        ///
        /// Also 1.0 by default, for the same reason: a lower value would let a scraper's
        /// worst result outrank another provider's best. Scrapers are already opt-in,
        /// rate limited and off by default, so the ranking does not need to punish them
        /// further.
        public var scraperWeight: Double
        /// Maximum number of results any single domain may contribute.
        public var maxResultsPerDomain: Int

        public init(
            k: Double = 60,
            independentIndexWeight: Double = 1.0,
            duplicatedAggregatorWeight: Double = 0.7,
            scraperWeight: Double = 1.0,
            maxResultsPerDomain: Int = 2
        ) {
            self.k = k
            self.independentIndexWeight = independentIndexWeight
            self.duplicatedAggregatorWeight = duplicatedAggregatorWeight
            self.scraperWeight = scraperWeight
            self.maxResultsPerDomain = maxResultsPerDomain
        }

        public static let `default` = Configuration()
    }

    /// Diagnostic record for one fused cluster. Exposed so tests and the status
    /// tool can explain *why* a result ranked where it did.
    public struct ClusterDiagnostics: Sendable, Hashable {
        public let canonicalURL: URL
        public let score: Double
        public let providers: [ProviderID]
        public let families: [SourceFamily]
        /// True when the cluster received at least two votes from different families.
        public let hasIndependentCorroboration: Bool
    }

    // MARK: - Entry point

    /// Fuse provider responses into one deduplicated, ranked result list.
    ///
    /// - Parameters:
    ///   - responses: One response per provider that succeeded.
    ///   - limit: Maximum number of fused results to return.
    ///   - configuration: Fusion tuning.
    ///   - providerWeights: Per-provider fusion weights from the registry.
    /// - Returns: The fused results plus per-cluster diagnostics.
    public static func fuse(
        responses: [ProviderSearchResponse],
        limit: Int,
        configuration: Configuration = .default,
        providerWeights: [ProviderID: Double] = [:]
    ) -> (results: [SearchResult], diagnostics: [ClusterDiagnostics]) {
        guard !responses.isEmpty else { return ([], []) }

        var clusters: [String: Cluster] = [:]
        var order: [String] = []

        // Source families that a provider *owning* an index contributed in this run.
        // Only these can be duplicated by an aggregator.
        let ownedFamilies: Set<SourceFamily> = Set(
            responses
                .filter { !$0.provider.isAggregator }
                .map { $0.provider.sourceFamily }
        )

        for response in responses {
            let provider = response.provider
            let family = provider.sourceFamily
            let base = providerWeights[provider] ?? 1.0
            // Reservations are decided per result as well as per response: an instance can
            // serve one page from Brave and another from Google, and only the resold one
            // should lose the aggregator vote. The response-level answer below is only the
            // fallback for an adapter that cannot attribute engines per result.
            let responseResellsOwnedIndex = RankFusion.resellsIndexAlreadyOwned(
                response: response,
                ownedFamilies: ownedFamilies
            )

            // Guard against a provider listing the same URL twice: only its best
            // rank may contribute, otherwise a duplicated entry would double-vote.
            var bestRankForProvider: [String: Int] = [:]

            for result in response.results {
                let key = URLCanonicalizer.key(for: result.canonicalURL)
                let rank = max(1, result.providerRank)
                if let existing = bestRankForProvider[key], existing <= rank { continue }
                bestRankForProvider[key] = rank

                var cluster =
                    clusters[key]
                    ?? {
                        let fresh = Cluster(canonicalURL: result.canonicalURL)
                        clusters[key] = fresh
                        order.append(key)
                        return fresh
                    }()

                // A resold page belongs to the index it came from, not to the aggregator
                // that relayed it. Without this the same index counts as two families and
                // the cluster looks independently corroborated when it is not.
                let resoldFamily = RankFusion.resoldFamily(
                    result: result,
                    provider: provider,
                    ownedFamilies: ownedFamilies
                )
                let contributionFamily = resoldFamily ?? family

                // A result that carries its own engine attribution is judged on that
                // attribution alone; the response-level list is consulted only when the
                // adapter could not say where this particular result came from. ORing the
                // two asked "did *any* page of this response resell an owned index?", which
                // discounted every sibling of one resold page and defeated the per-result
                // refinement the comment above describes (ledger B109).
                let duplicatedOwnedIndex: Bool
                if result.upstreamEngines == nil {
                    duplicatedOwnedIndex = responseResellsOwnedIndex
                } else {
                    duplicatedOwnedIndex = resoldFamily != nil
                }

                cluster.add(
                    result: result,
                    provider: provider,
                    family: contributionFamily,
                    rank: rank,
                    rawWeight: weight(
                        for: contributionFamily,
                        provider: provider,
                        base: base,
                        duplicatedOwnedIndex: duplicatedOwnedIndex,
                        configuration: configuration
                    )
                )
                clusters[key] = cluster
            }
        }

        var diagnostics: [ClusterDiagnostics] = []
        var scored: [(cluster: Cluster, score: Double, corroborated: Bool)] = []
        scored.reserveCapacity(clusters.count)

        for key in order {
            guard let cluster = clusters[key] else { continue }

            let clusterFamilies = Set(cluster.contributions.map(\.family))
            // A cluster is independently corroborated when it is represented by two or
            // more distinct families, at least one of which owns a real index. This is
            // reported for diagnostics and used as a tie-breaker, not as a score
            // multiplier.
            let independentFamilies = clusterFamilies.filter { $0.isIndependentIndex }
            let corroborated = clusterFamilies.count >= 2 && !independentFamilies.isEmpty

            var total = 0.0
            for contribution in cluster.contributions {
                // The aggregator discount is already folded into `rawWeight` by
                // `weight(for:provider:base:configuration:)`. Applying it again here
                // would square it (0.7 x 0.7), silently double-penalising aggregators.
                total +=
                    contribution.rawWeight
                    / (configuration.k + Double(contribution.rank))
            }

            scored.append((cluster, total, corroborated))
            diagnostics.append(
                ClusterDiagnostics(
                    canonicalURL: cluster.canonicalURL,
                    score: total,
                    providers: cluster.sortedProviders,
                    families: clusterFamilies.sorted { $0.rawValue < $1.rawValue },
                    hasIndependentCorroboration: corroborated
                )
            )
        }

        // Deterministic ordering: score desc, then corroboration, then best rank,
        // then canonical URL. Determinism matters for reproducible tests.
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.corroborated != rhs.corroborated { return lhs.corroborated }
            let lhsBest = lhs.cluster.bestRank
            let rhsBest = rhs.cluster.bestRank
            if lhsBest != rhsBest { return lhsBest < rhsBest }
            return lhs.cluster.canonicalURL.absoluteString < rhs.cluster.canonicalURL.absoluteString
        }

        // Apply per-domain diversity, then trim to the requested limit.
        var perDomainCount: [String: Int] = [:]
        var results: [SearchResult] = []
        results.reserveCapacity(min(limit, scored.count))
        // Clusters rejected only because the limit was already reached. These may be
        // reconsidered when diversity capping leaves room.
        var overflow: [Cluster] = []

        for entry in scored {
            let domain = entry.cluster.canonicalURL.host()?.lowercased() ?? ""
            let count = perDomainCount[domain, default: 0]
            let exceedsDomainCap =
                configuration.maxResultsPerDomain > 0
                && count >= configuration.maxResultsPerDomain

            if exceedsDomainCap {
                // Rejected for diversity, not for capacity: never backfilled.
                continue
            }
            if results.count >= limit {
                overflow.append(entry.cluster)
                continue
            }
            perDomainCount[domain] = count + 1
            results.append(entry.cluster.materialize())
        }

        // Only overflow clusters may backfill, and they are still subject to the
        // per-domain cap — otherwise a single domain could fill the result set via the
        // backfill path.
        if results.count < limit {
            for cluster in overflow where results.count < limit {
                let domain = cluster.canonicalURL.host()?.lowercased() ?? ""
                let count = perDomainCount[domain, default: 0]
                if configuration.maxResultsPerDomain > 0,
                    count >= configuration.maxResultsPerDomain
                {
                    continue
                }
                perDomainCount[domain] = count + 1
                results.append(cluster.materialize())
            }
        }

        // Renumber to final presentation order.
        for index in results.indices {
            results[index].providerRank = index + 1
        }

        return (results, diagnostics)
    }

    /// Whether an aggregator is reselling an index that another provider in this run
    /// already owns.
    ///
    /// Decided from the upstream engines the adapter reports. Engines are matched by
    /// name against the `SourceFamily` they belong to, so an instance that internally
    /// queried Brave is recognised as duplicating a directly-configured Brave, while an
    /// instance querying engines nobody else covers is not penalised.
    ///
    /// This must agree with `resoldFamily`, including its `isIndependentIndex` guard: a
    /// response that only resold a non-independent family (Google, DuckDuckGo) is not
    /// duplicating an owned index, and whether that is noticed must not depend on which
    /// level the adapter happened to report engines at (ledger B109).
    static func resellsIndexAlreadyOwned(
        response: ProviderSearchResponse,
        ownedFamilies: Set<SourceFamily>
    ) -> Bool {
        guard response.provider.isAggregator, !ownedFamilies.isEmpty else { return false }
        for engine in response.upstreamEngines {
            if let family = RankFusion.family(forUpstreamEngine: engine),
                family.isIndependentIndex,
                ownedFamilies.contains(family)
            {
                return true
            }
        }
        return false
    }

    /// The index family this result resells, when it demonstrably resells one that another
    /// provider in the same run already owns.
    ///
    /// SearXNG reports `engine` and `engines` per result, which is finer than the
    /// response-level list: a single instance can serve one page from Brave and another from
    /// Google, and only the resold one is affected. Naming the family rather than returning a
    /// flag lets the contribution be attributed to the index it actually came from, so one
    /// index cannot look like two independent confirmations.
    static func resoldFamily(
        result: SearchResult,
        provider: ProviderID,
        ownedFamilies: Set<SourceFamily>
    ) -> SourceFamily? {
        guard provider.isAggregator, !ownedFamilies.isEmpty,
            let engines = result.upstreamEngines
        else { return nil }
        for engine in engines {
            if let family = RankFusion.family(forUpstreamEngine: engine),
                family.isIndependentIndex,
                ownedFamilies.contains(family)
            {
                return family
            }
        }
        return nil
    }

    /// Map an upstream engine name, as reported by an aggregator, onto its source family.
    ///
    /// Only engines whose owning index is represented by a direct adapter can matter
    /// here; anything else returns nil and is ignored.
    static func family(forUpstreamEngine engine: String) -> SourceFamily? {
        let name = engine.lowercased()
        if name.contains("brave") { return .brave }
        if name.contains("mojeek") { return .mojeek }
        if name.contains("tavily") { return .tavily }
        if name.contains("exa") { return .exa }
        if name.contains("google") || name.contains("startpage") { return .google }
        if name.contains("duckduckgo") || name.contains("ddg") { return .duckDuckGo }
        return nil
    }

    /// Weight applied to one contribution, combining registry weight, source-family
    /// trust and provider class.
    ///
    /// - Parameter duplicatedOwnedIndex: true only when an aggregator is reselling an
    ///   index already owned by another provider in the same run. See
    ///   `Configuration.duplicatedAggregatorWeight` for why this must not be a blanket
    ///   penalty.
    static func weight(
        for family: SourceFamily,
        provider: ProviderID,
        base: Double,
        duplicatedOwnedIndex: Bool = false,
        configuration: Configuration
    ) -> Double {
        var weight = base
        if family.isIndependentIndex {
            weight *= configuration.independentIndexWeight
        }
        if duplicatedOwnedIndex {
            weight *= configuration.duplicatedAggregatorWeight
        }
        if provider.isExperimentalScraper {
            weight *= configuration.scraperWeight
        }
        return weight
    }

    // MARK: - Cluster

    /// One deduplicated URL plus every provider vote for it.
    struct Cluster {
        let canonicalURL: URL
        var contributions: [Contribution] = []
        /// The best available presentation of the result, by (rank, provider trust).
        private var representative: SearchResult?

        init(canonicalURL: URL) {
            self.canonicalURL = canonicalURL
        }

        var bestRank: Int {
            contributions.map(\.rank).min() ?? Int.max
        }

        var sortedProviders: [ProviderID] {
            contributions
                .sorted { $0.rank < $1.rank }
                .map(\.provider)
        }

        mutating func add(
            result: SearchResult,
            provider: ProviderID,
            family: SourceFamily,
            rank: Int,
            rawWeight: Double
        ) {
            contributions.append(
                Contribution(
                    provider: provider,
                    family: family,
                    rank: rank,
                    rawWeight: rawWeight,
                    snippet: result.snippet,
                    content: result.content,
                    publishedAt: result.publishedAt,
                    title: result.title
                )
            )
            mergeRepresentative(with: result, provider: provider, rank: rank)
        }

        /// Pick a representative record. We prefer the best-ranked provider's
        /// metadata, but take the richest snippet and any publication date found,
        /// because providers differ wildly in what they expose.
        private mutating func mergeRepresentative(
            with result: SearchResult,
            provider: ProviderID,
            rank: Int
        ) {
            guard var current = representative else {
                representative = result
                return
            }

            // Prefer the best-ranked provider's title/URL.
            if rank < current.providerRank {
                current.title = result.title.isEmpty ? current.title : result.title
                current.url = result.url
                current.provider = provider
                current.providerRank = rank
            }

            if current.snippet == nil || (result.snippet?.count ?? 0) > (current.snippet?.count ?? 0) {
                current.snippet = result.snippet ?? current.snippet
            }
            if current.content == nil || (result.content?.count ?? 0) > (current.content?.count ?? 0) {
                current.content = result.content ?? current.content
            }
            if let date = result.publishedAt {
                if let existing = current.publishedAt {
                    current.publishedAt = min(existing, date)
                } else {
                    current.publishedAt = date
                }
            }
            if current.title.isEmpty, !result.title.isEmpty {
                current.title = result.title
            }
            representative = current
        }

        /// Produce the final result with merged provenance.
        func materialize() -> SearchResult {
            var result =
                representative
                ?? SearchResult(
                    title: canonicalURL.absoluteString,
                    url: canonicalURL,
                    provider: contributions.first?.provider ?? .tavily,
                    providerRank: bestRank,
                    canonicalURL: canonicalURL
                )
            result.canonicalURL = canonicalURL
            result.sources = sortedProviders
            result.provider = sortedProviders.first ?? result.provider
            result.providerRank = bestRank
            return result
        }
    }

    /// A single provider's vote for a cluster.
    struct Contribution: Sendable, Hashable {
        let provider: ProviderID
        let family: SourceFamily
        let rank: Int
        let rawWeight: Double
        let snippet: String?
        let content: String?
        let publishedAt: Date?
        let title: String
    }
}
