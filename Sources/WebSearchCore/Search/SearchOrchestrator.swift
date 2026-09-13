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
        // Timeouts are budgets, not cancellations: the deadline produces partial results.
        // `Task.isCancelled` on the calling task therefore means the caller cancelled, whether
        // that happened before the call or while it was running, and both are propagated as
        // `CancellationError`. Only the pre-call case was handled before, so a cancellation that
        // arrived mid-flight was swallowed into partial results (ledger B04).
        try Task.checkCancellation()
        let budget = configuration.timeout(for: request.mode)

        // Each provider gets a larger budget than the caller asked for, so fusion has
        // enough material to work with after deduplication.
        let providerBudget = min(20, max(request.maxResults * 2, request.maxResults))
        let scopedRequest = request.scoped(to: providerBudget)

        var accumulated: [ProviderSearchResponse] = []
        var failures: [ProviderFailure] = []
        var warnings: [String] = []
        /// How many providers actually reached the network. Counted rather than inferred
        /// from failure categories, because a local token-bucket denial and an upstream
        /// HTTP 429 share the `rateLimited` category.
        var attemptedRequests = 0

        let primary = await runProviders(
            selectedIDs,
            request: scopedRequest,
            deadline: budget
        )
        // A caller that cancelled mid-flight gets the cancellation, not partial results that no
        // one is waiting for. Checked immediately after the fan-out and again before returning.
        try Task.checkCancellation()
        accumulated.append(contentsOf: primary.responses)
        failures.append(contentsOf: primary.failures)
        attemptedRequests += primary.attempted
        var skippedLocally = primary.skippedLocally

        var usedIDs = selectedIDs

        // Refill a slot that a local skip wasted. Selection happens once, before any
        // request, so an open breaker or an empty local token bucket otherwise costs the
        // search a slot even though the next candidate in the same preference order was
        // free. Only providers that were never contacted are replaced: an upstream failure
        // was a real attempt and must not spend a second provider's quota.
        if requestedProvider == nil, !primary.skippedLocally.isEmpty {
            let alreadyTried = Set(usedIDs).union(failures.map(\.provider))
            let refills = registry.refillCandidates(
                excluding: alreadyTried,
                limit: primary.skippedLocally.count
            )
            if !refills.isEmpty,
                let remaining = remainingBudget(deadline: budget, started: started)
            {
                log.debug(
                    "Refilling fan-out slots wasted by local skips",
                    metadata: [
                        "skipped": primary.skippedLocally.map(\.rawValue).joined(separator: ","),
                        "refills": refills.map(\.rawValue).joined(separator: ","),
                    ]
                )
                let refill = await runProviders(
                    refills,
                    request: scopedRequest,
                    deadline: remaining
                )
                accumulated.append(contentsOf: refill.responses)
                failures.append(contentsOf: refill.failures)
                attemptedRequests += refill.attempted
                skippedLocally.append(contentsOf: refill.skippedLocally)
                usedIDs.append(contentsOf: refills)
            }
        }

        // In thorough mode, if the direct providers produced a thin evidence set,
        // spend one more call on an aggregator for extra coverage.
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
                        attemptedRequests += extra.attempted
                        usedIDs.append(contentsOf: extras)
                    }
                }
            }
        }

        // Last resort: when the only reason there is nothing to return is a local throttle,
        // wait it out. Nobody is delayed by this unless the alternative is an empty result,
        // which is why the wait lives here rather than in the first pass. This is the
        // single-provider case the tracker measured: DuckDuckGo alone failed 41 of 50
        // queries once its own throttle was reached.
        if accumulated.isEmpty, !skippedLocally.isEmpty,
            let remaining = remainingBudget(deadline: budget, started: started)
        {
            log.debug(
                "Nothing returned and only local skips to blame; retrying with waiting",
                metadata: ["providers": skippedLocally.map(\.rawValue).joined(separator: ",")]
            )
            let retry = await runProviders(
                skippedLocally,
                request: scopedRequest,
                deadline: remaining,
                allowWaiting: true
            )
            accumulated.append(contentsOf: retry.responses)
            // Replace the earlier skip records instead of adding to them, so a provider is
            // reported once whichever pass finally decided its fate.
            failures.removeAll { skippedLocally.contains($0.provider) }
            failures.append(contentsOf: retry.failures)
            attemptedRequests += retry.attempted
            usedIDs.append(contentsOf: retry.responses.map(\.provider))
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
            // Distinguish "nothing was even attempted" from "everything was tried and
            // failed". The former is a transient local condition - the breaker was open
            // or the local rate limiter had no token - and reporting it as an invalid
            // request told callers their query was at fault. A sustained run reaches
            // this legitimately, because each search spends a request against every
            // provider it fans out to, and the limiter is deliberately conservative.
            //
            // Decided by the count of authorised requests, not by the failure categories:
            // an upstream 429 reaches the caller as `rateLimited` too, and reporting that
            // as "nothing was attempted" hid the provider's real answer.
            if attemptedRequests == 0, !failures.isEmpty {
                throw SearchError.temporarilyUnavailable(failures)
            }
            // Attach the per-provider reasons. With a single explicitly requested
            // provider, "all providers failed" alone tells a caller nothing.
            throw SearchError.providersFailed(failures)
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

        // Last checkpoint: everything above ran on behalf of a caller that may have gone away.
        // Nothing is cached or returned for it.
        try Task.checkCancellation()
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
        /// How many providers were authorised to issue a request.
        ///
        /// This is counted rather than inferred from the failure categories on purpose: a
        /// local token-bucket denial and an upstream HTTP 429 share the `rateLimited`
        /// category, so categories alone cannot tell "the limiter refused everyone" from
        /// "every provider answered with an error".
        var attempted = 0
        /// Providers that were never contacted because a local condition excluded them.
        /// Each one wasted the selection slot it was given and can be refilled.
        var skippedLocally: [ProviderID] = []
    }

    /// Query a set of providers concurrently within one overall deadline.
    ///
    /// The whole fan-out shares a single timeout race, so a slow provider cannot
    /// stretch the tool call beyond its mode's budget.
    private func runProviders(
        _ ids: [ProviderID],
        request: SearchRequest,
        deadline: Duration,
        allowWaiting: Bool = false
    ) async -> FanOutResult {
        guard !ids.isEmpty else { return FanOutResult() }

        return await withTaskGroup(of: FanOutResult.self) { group in
            for id in ids {
                guard let provider = registry.provider(id) else { continue }
                group.addTask { [weak self] in
                    guard let self else { return FanOutResult() }
                    return await self.runSingle(
                        provider,
                        request: request,
                        budget: deadline,
                        allowWaiting: allowWaiting
                    )
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
                aggregate.attempted += partial.attempted
                aggregate.skippedLocally.append(contentsOf: partial.skippedLocally)
                // Every real provider has reported; the budget is no longer relevant.
                if aggregate.responses.count + aggregate.failures.count >= providerTaskCount {
                    group.cancelAll()
                    break
                }
            }

            if budgetExpired {
                // Providers still running when the deadline fired were authorised, so a
                // request really was made: a budget expiry means "we tried", not "nothing
                // was attempted".
                let reported = Set(aggregate.responses.map(\.provider))
                    .union(aggregate.failures.map(\.provider))
                aggregate.attempted += ids.filter { !reported.contains($0) }.count
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
            // Counted, but deliberately not sent to the breaker: the deadline is shared by
            // the whole fan-out, so charging it to every slow provider would open breakers
            // that no provider earned.
            await health.recordDeadlineExceeded(id, message: failure.message)
        }
    }

    /// The longest wait worth spending a budget on when the alternative is no result at all,
    /// and the share of the remaining budget one wait may claim.
    static let maximumLocalWait = Duration.seconds(6)
    static let localWaitBudgetShare = 0.5

    /// Authorise one request, optionally waiting out a local throttle.
    ///
    /// A token bucket denies rather than waits, which is right on the first pass: waiting
    /// there would delay a search that another provider can already answer. It is wrong when
    /// waiting is the only alternative to an empty result, which is why the orchestrator only
    /// sets `allowWaiting` on its last-resort pass. Measured on the tracker: DuckDuckGo alone
    /// failed 41 of 50 queries once its throttle was reached, while the same run with a
    /// second provider produced 241 results.
    ///
    /// The wait is bounded twice — an absolute cap and a share of what is left of the budget —
    /// so a large estimate cannot eat the search.
    private func authorizationAfterBoundedWait(
        _ id: ProviderID,
        budget: Duration,
        allowWaiting: Bool
    ) async -> ProviderFailure? {
        guard let denial = await health.authorize(id) else { return nil }
        guard allowWaiting, denial.category == .rateLimited,
            let wait = await health.localWait(for: id),
            wait <= SearchOrchestrator.maximumLocalWait,
            wait.milliseconds
                <= Int(Double(budget.milliseconds) * SearchOrchestrator.localWaitBudgetShare)
        else {
            return denial
        }

        log.debug(
            "Waiting out a local throttle instead of returning nothing",
            metadata: ["provider": id.rawValue, "wait_ms": "\(wait.milliseconds)"]
        )
        do {
            try await Task.sleep(for: wait)
        } catch {
            // Cancelled while waiting: report the skip rather than the cancellation, so the
            // caller sees the provider's local condition.
            return denial
        }
        return await health.authorize(id)
    }

    /// Run one provider, translating every failure mode into a failure record rather
    /// than an exception, so one bad provider never aborts the fan-out.
    private func runSingle(
        _ provider: any SearchProvider,
        request: SearchRequest,
        budget: Duration,
        allowWaiting: Bool
    ) async -> FanOutResult {
        let id = provider.id
        var result = FanOutResult()

        // Health gate: skip a provider whose breaker is open or whose local bucket is
        // empty, instead of spending latency discovering it again.
        if let denial = await authorizationAfterBoundedWait(
            id,
            budget: budget,
            allowWaiting: allowWaiting
        ) {
            result.failures.append(denial)
            result.skippedLocally.append(id)
            log.debug(
                "Provider skipped",
                metadata: [
                    "provider": id.rawValue,
                    "category": denial.category.rawValue,
                ]
            )
            return result
        }

        // Past the health gate, so a request is really about to be made. Recorded before
        // the call because a failure or a timeout still counts as an attempt.
        result.attempted = 1

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
            if let reason = registry.ineligibleReasons()[id],
                state.status == .notConfigured
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
