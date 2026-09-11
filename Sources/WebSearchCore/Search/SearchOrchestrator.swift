import Foundation

/// Coordinates provider selection, concurrent execution, failover and fusion.
///
/// Design rule: **one vendor outage must never turn a potentially successful search
/// into a hard tool failure.** A search only fails when no provider can produce a
/// usable result, or when the request itself is invalid.
public actor SearchOrchestrator {
    private let registry: ProviderRegistry
    private let health: ProviderHealth
    private let cache: SearchCache
    private let configuration: AppConfiguration
    private let clock: any Clock
    private let log: Log

    public init(
        registry: ProviderRegistry,
        health: ProviderHealth,
        cache: SearchCache,
        configuration: AppConfiguration,
        clock: any Clock = SystemClock(),
        log: Log = .disabled
    ) {
        self.registry = registry
        self.health = health
        self.cache = cache
        self.configuration = configuration
        self.clock = clock
        self.log = log
    }

    // MARK: - Public entry point

    /// Run a search.
    ///
    /// - Parameter requestedProvider: Restricts the search to one provider, bypassing
    ///   normal policy while keeping its rate limits and failure handling.
    public func search(
        _ request: SearchRequest,
        requestedProvider: ProviderID? = nil
    ) async throws -> SearchResponse {
        guard !request.normalizedQuery.isEmpty else {
            throw SearchError.invalidRequest("query must not be empty")
        }

        let selection = try registry.select(for: request, requested: requestedProvider)
        guard case .selected(let selectedIDs) = selection, !selectedIDs.isEmpty else {
            throw SearchError.invalidRequest(
                "no search provider is configured; set an API key such as TAVILY_API_KEY "
                    + "or configure SEARXNG_BASE_URL"
            )
        }

        let cacheKey = SearchCache.Key(request: request, providers: selectedIDs)
        if let cached = await cache.get(cacheKey) {
            log.debug(
                "Search served from cache",
                metadata: [
                    "providers": selectedIDs.map(\.rawValue).joined(separator: ","),
                    "results": "\(cached.results.count)",
                ]
            )
            return cached
        }

        let started = DispatchTime.now().uptimeNanoseconds
        // The caller's cancellation is separate from our own budget timer: if the MCP
        // client cancels the tool call we propagate `CancellationError`, but if our
        // timer fires we degrade gracefully to partial results.
        let callerCancelledBefore = Task.isCancelled
        let budget = configuration.timeout(for: request.mode)

        // Each provider gets a larger budget than the caller asked for, so fusion has
        // enough material to work with after deduplication.
        let providerBudget = min(20, max(request.maxResults * 2, request.maxResults))
        let scopedRequest = request.scoped(to: providerBudget)

        var accumulated: [ProviderSearchResponse] = []
        var failures: [ProviderFailure] = []
        var warnings: [String] = []

        let primary = await runProviders(
            selectedIDs,
            request: scopedRequest,
            deadline: budget
        )
        if Task.isCancelled, !callerCancelledBefore { /* budget expired, not the caller */ }
        if Task.isCancelled, callerCancelledBefore { throw CancellationError() }
        accumulated.append(contentsOf: primary.responses)
        failures.append(contentsOf: primary.failures)

        // In thorough mode, if the direct providers produced a thin evidence set,
        // spend one more call on an aggregator for extra coverage.
        var usedIDs = selectedIDs
        if request.mode.allowsAggregatorCoverage, requestedProvider == nil {
            let fused = fuse(accumulated, request: request)
            // Require a genuinely thin result set, and only ever consider aggregators
            // that have not already been attempted. Re-querying a provider that already
            // failed would double-count failures and waste its quota.
            let attempted = Set(usedIDs).union(failures.map(\.provider))
            let coverageThreshold = 3
            if fused.count < min(request.maxResults, coverageThreshold) {
                let extras = registry.aggregatorCandidates(excluding: attempted)
                if !extras.isEmpty {
                    log.debug(
                        "Thin result set; trying aggregator coverage",
                        metadata: ["aggregators": extras.map(\.rawValue).joined(separator: ",")]
                    )
                    let remaining = remainingBudget(
                        deadline: budget,
                        started: started
                    )
                    if let remaining {
                        let extra = await runProviders(
                            extras,
                            request: scopedRequest,
                            deadline: remaining
                        )
                        accumulated.append(contentsOf: extra.responses)
                        failures.append(contentsOf: extra.failures)
                        usedIDs.append(contentsOf: extras)
                    }
                }
            }
        }

        let results = fuse(accumulated, request: request)

        // Provider-supplied answers are only useful if the caller can tell where they
        // came from, so each is attributed.
        for response in accumulated {
            if let answer = response.answer, !answer.isEmpty {
                warnings.append("\(response.provider.displayName) answer: \(answer)")
            }
            warnings.append(contentsOf: response.warnings)
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)

        // Only a total failure is an error. Partial success returns results plus the
        // list of providers that failed.
        guard !results.isEmpty else {
            let usableFailures = failures.filter { $0.category != .circuitOpen }
            if usableFailures.isEmpty, !failures.isEmpty {
                throw SearchError.invalidRequest(
                    "all eligible providers were skipped: "
                        + failures.map(\.message).joined(separator: " ")
                )
            }
            throw SearchError.allProvidersFailed
        }

        let usedProviderIDs = accumulated.map(\.provider).reduce(into: [ProviderID]()) { ids, id in
            if !ids.contains(id) { ids.append(id) }
        }

        if !failures.isEmpty {
            warnings.append(
                "\(failures.count) provider(s) failed: "
                    + failures.map { "\($0.provider.rawValue) (\($0.category.rawValue))" }
                        .joined(separator: ", ")
                    + "."
            )
        }

        let response = SearchResponse(
            query: request.normalizedQuery,
            results: results,
            providersUsed: usedProviderIDs,
            providersFailed: failures,
            retrievedAt: clock.now(),
            elapsedMilliseconds: elapsed,
            warnings: warnings,
            servedFromCache: false
        )

        await cache.store(response, for: cacheKey, ttl: configuration.cacheTTL)

        log.info(
            "Search complete",
            metadata: [
                "query": log.queryDescription(request.normalizedQuery),
                "mode": request.mode.rawValue,
                "providers_used": usedProviderIDs.map(\.rawValue).joined(separator: ","),
                "providers_failed": "\(failures.count)",
                "results": "\(results.count)",
                "latency_ms": "\(elapsed)",
            ]
        )

        return response
    }

    // MARK: - Fan-out

    struct FanOutResult: Sendable {
        var responses: [ProviderSearchResponse] = []
        var failures: [ProviderFailure] = []
    }

    /// Query a set of providers concurrently within one overall deadline.
    ///
    /// The whole fan-out shares a single timeout race, so a slow provider cannot
    /// stretch the tool call beyond its mode's budget.
    private func runProviders(
        _ ids: [ProviderID],
        request: SearchRequest,
        deadline: Duration
    ) async -> FanOutResult {
        guard !ids.isEmpty else { return FanOutResult() }

        return await withTaskGroup(of: FanOutResult.self) { group in
            for id in ids {
                guard let provider = registry.provider(id) else { continue }
                group.addTask { [weak self] in
                    guard let self else { return FanOutResult() }
                    return await self.runSingle(provider, request: request)
                }
            }

            // One sentinel task enforces the mode's overall budget. It must not delay
            // completion: `group.next()` returns as soon as the *first* task finishes,
            // and the loop exits once every provider has answered, at which point the
            // still-sleeping sentinel is cancelled.
            group.addTask {
                try? await Task.sleep(for: deadline)
                return FanOutResult(
                    responses: [],
                    failures: [
                        ProviderFailure(
                            provider: .tavily,
                            category: .timeout,
                            message: SearchOrchestrator.budgetSentinel
                        )
                    ]
                )
            }

            var aggregate = FanOutResult()
            // `withTaskGroup` (not the throwing variant) plus a sentinel keeps the
            // budget race from being confused with caller cancellation: a cancelled
            // caller is detected separately via `Task.isCancelled`.
            var budgetExpired = false
            let providerTaskCount = ids.count
            while let partial = await group.next() {
                let isSentinel = partial.failures.contains {
                    $0.message == SearchOrchestrator.budgetSentinel
                }
                if isSentinel {
                    budgetExpired = true
                    group.cancelAll()
                    break
                }
                aggregate.responses.append(contentsOf: partial.responses)
                aggregate.failures.append(contentsOf: partial.failures)
                // Every real provider has reported; the budget is no longer relevant.
                if aggregate.responses.count + aggregate.failures.count >= providerTaskCount {
                    group.cancelAll()
                    break
                }
            }

            if budgetExpired {
                await self.recordBudgetExceeded(
                    ids: ids,
                    answered: aggregate,
                    into: &aggregate
                )
            }
            return aggregate
        }
    }

    /// Marker message identifying the budget timer task's result, so it is never
    /// mistaken for a real provider failure.
    static let budgetSentinel = "internal:search-budget-expired"

    private func recordBudgetExceeded(
        ids: [ProviderID],
        answered: FanOutResult,
        into aggregate: inout FanOutResult
    ) async {
        log.warning("Search time budget exceeded; cancelling slow providers")
        let answeredIDs = Set(answered.responses.map(\.provider))
        for id in ids where !answeredIDs.contains(id) {
            let failure = ProviderFailure(
                provider: id,
                category: .timeout,
                message: "\(id.displayName) exceeded the search time budget."
            )
            aggregate.failures.append(failure)
            await health.recordFailure(id, failure: failure)
        }
    }

    /// Run one provider, translating every failure mode into a failure record rather
    /// than an exception, so one bad provider never aborts the fan-out.
    private func runSingle(
        _ provider: any SearchProvider,
        request: SearchRequest
    ) async -> FanOutResult {
        let id = provider.id
        var result = FanOutResult()

        // Health gate: skip a provider whose breaker is open or whose local bucket is
        // empty, instead of spending latency discovering it again.
        if let denial = await health.authorize(id) {
            result.failures.append(denial)
            log.debug(
                "Provider skipped",
                metadata: [
                    "provider": id.rawValue,
                    "category": denial.category.rawValue,
                ]
            )
            return result
        }

        do {
            try Task.checkCancellation()
            let response = try await provider.search(request)

            // A provider that honours a domain filter must not be trusted blindly;
            // `ResultNormalizer` already re-checks, so anything here is post-filter.
            await health.recordSuccess(
                id,
                latencyMilliseconds: response.latencyMilliseconds,
                resultCount: response.results.count
            )
            result.responses.append(response)
        } catch let error as SearchError {
            let failure = ProviderFailure(provider: id, error: error)
            result.failures.append(failure)
            await health.recordFailure(id, failure: failure)
            log.debug(
                "Provider failed",
                metadata: [
                    "provider": id.rawValue,
                    "category": failure.category.rawValue,
                ]
            )
        } catch is CancellationError {
            result.failures.append(
                ProviderFailure(
                    provider: id,
                    category: .cancelled,
                    message: "Request cancelled."
                )
            )
        } catch {
            let mapped = HTTPStatusMapper.map(error, provider: id)
            let failure = ProviderFailure(provider: id, error: mapped)
            result.failures.append(failure)
            await health.recordFailure(id, failure: failure)
        }

        return result
    }

    // MARK: - Fusion

    private func fuse(
        _ responses: [ProviderSearchResponse],
        request: SearchRequest
    ) -> [SearchResult] {
        guard !responses.isEmpty else { return [] }
        let fused = RankFusion.fuse(
            responses: responses,
            limit: request.maxResults,
            configuration: configuration.fusion,
            providerWeights: registry.fusionWeights
        )
        return fused.results
    }

    private func remainingBudget(deadline: Duration, started: UInt64) -> Duration? {
        let elapsedMilliseconds = Int(
            (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        )
        let remaining = deadline.milliseconds - elapsedMilliseconds
        // Require a usable slice before starting another round trip.
        guard remaining > 1_000 else { return nil }
        return .milliseconds(remaining)
    }

    // MARK: - Diagnostics

    public func status() async -> [ProviderHealth.ProviderState] {
        var states: [ProviderHealth.ProviderState] = []
        for id in configuration.providerOrder {
            let state = await health.state(
                for: id,
                configured: registry.isConfigured(id),
                enabled: registry.isEnabled(id)
            )
            var annotated = state
            if let reason = registry.ineligibleReasons()[id], state.status == .notConfigured
                || state.status == .disabled
            {
                annotated = ProviderHealth.ProviderState(
                    provider: state.provider,
                    status: state.status,
                    configured: state.configured,
                    circuit: state.circuit,
                    rateLimit: state.rateLimit,
                    successes: state.successes,
                    failures: state.failures,
                    totalRequests: state.totalRequests,
                    lastLatencyMilliseconds: state.lastLatencyMilliseconds,
                    averageLatencyMilliseconds: state.averageLatencyMilliseconds,
                    lastError: state.lastError,
                    lastErrorCategory: state.lastErrorCategory,
                    lastSuccessAt: state.lastSuccessAt,
                    lastFailureAt: state.lastFailureAt,
                    lastResultCount: state.lastResultCount,
                    note: reason
                )
            }
            states.append(annotated)
        }
        return states
    }

    public func cacheStats() async -> SearchCache.Stats {
        await cache.stats()
    }
}
