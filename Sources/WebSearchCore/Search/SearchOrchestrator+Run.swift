import Foundation

extension SearchOrchestrator {

    /// Whether an error means the caller went away, rather than the provider failing.
    ///
    /// In-flight cancellation surfaces as `HTTPError.cancelled`, not `CancellationError` — the
    /// codebase records exactly that at `AnswerSynthesizer.swift`. Catching only
    /// `CancellationError` therefore let the transport's shape fall through to the generic arm,
    /// where `HTTPStatusMapper` maps it to `.networkFailure`, whose `.network` category is
    /// transient, so `ProviderHealth.recordFailure` charged it to the provider: three client
    /// disconnects opened a breaker on a provider that had never failed, and the half-open probe
    /// the attempt had claimed was never given back.
    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case HTTPError.cancelled = error { return true }
        return false
    }

    /// Run one provider, translating every failure mode into a failure record rather
    /// than an exception, so one bad provider never aborts the fan-out.

    func runSingle(
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
        } catch let error where Self.isCancellation(error) {
            // The request was claimed from the breaker before the call and produced no outcome, so
            // the claim is given back rather than recorded as a provider failure: a caller that
            // goes away says nothing about the provider. Without this a cancelled request left the
            // breaker half-open with a claim nobody releases, and the provider was never tried
            // again.
            await health.releaseProbe(id)
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

    func fuse(
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

    func remainingBudget(deadline: Duration, started: UInt64) -> Duration? {
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
