import Foundation

/// Centralized health, rate-limit and failure accounting for every provider.
///
/// The orchestrator consults this before spending a request, so a provider that is
/// known-bad is skipped rather than retried. It is also the data source for the
/// `web_search_status` diagnostic tool.
public actor ProviderHealth {
    /// Coarse availability state shown by the status tool.
    public enum Status: String, Sendable, Hashable, Codable {
        case ready
        case notConfigured = "not_configured"
        case disabled
        case circuitOpen = "circuit_open"
        case probing
        case rateLimited = "rate_limited"
    }

    public struct ProviderState: Sendable, Hashable {
        public let provider: ProviderID
        public let status: Status
        public let configured: Bool
        public let circuit: CircuitBreaker.Snapshot
        public let rateLimit: RateLimiter.Snapshot
        public let successes: Int
        public let failures: Int
        public let totalRequests: Int
        public let lastLatencyMilliseconds: Int
        public let averageLatencyMilliseconds: Int
        public let lastError: String?
        public let lastErrorCategory: ProviderFailure.FailureCategory?
        public let lastSuccessAt: Date?
        public let lastFailureAt: Date?
        public let lastResultCount: Int
        /// Set when the provider is skipped for a reason other than its own health.
        public let note: String?
    }

    private struct Counters {
        var successes = 0
        var failures = 0
        var totalRequests = 0
        var totalLatency = 0
        var lastLatency = 0
        var lastError: String?
        var lastErrorCategory: ProviderFailure.FailureCategory?
        var lastSuccessAt: Date?
        var lastFailureAt: Date?
        var lastResultCount = 0
    }

    private var breakers: [ProviderID: CircuitBreaker] = [:]
    private var limiters: [ProviderID: RateLimiter] = [:]
    private var counters: [ProviderID: Counters] = [:]
    private var notes: [ProviderID: String] = [:]
    private let clock: any Clock

    /// A provider's per-instance policies, applied when the health actor is created.
    ///
    /// Registration happens in the initializer rather than through a detached `Task`, so a
    /// request arriving immediately after construction cannot slip past a breaker or rate
    /// limiter that has not been installed yet.
    public struct Registration: Sendable {
        public let provider: ProviderID
        public let breakerPolicy: CircuitBreaker.Policy
        public let ratePolicy: RateLimiter.Policy

        public init(
            provider: ProviderID,
            breakerPolicy: CircuitBreaker.Policy = .default,
            ratePolicy: RateLimiter.Policy = .apiDefault
        ) {
            self.provider = provider
            self.breakerPolicy = breakerPolicy
            self.ratePolicy = ratePolicy
        }
    }

    public init(
        clock: any Clock = SystemClock(),
        registrations: [Registration] = [],
        notes: [ProviderID: String] = [:]
    ) {
        self.clock = clock
        for registration in registrations {
            breakers[registration.provider] = CircuitBreaker(
                policy: registration.breakerPolicy,
                clock: clock
            )
            limiters[registration.provider] = RateLimiter(
                policy: registration.ratePolicy,
                clock: clock
            )
            counters[registration.provider] = Counters()
        }
        self.notes = notes
    }

    // MARK: - Registration

    /// Register a provider with its own breaker and rate limiter.
    public func register(
        _ provider: ProviderID,
        breakerPolicy: CircuitBreaker.Policy = .default,
        ratePolicy: RateLimiter.Policy = .apiDefault
    ) {
        if breakers[provider] == nil {
            breakers[provider] = CircuitBreaker(policy: breakerPolicy, clock: clock)
        }
        if limiters[provider] == nil {
            limiters[provider] = RateLimiter(policy: ratePolicy, clock: clock)
        }
        if counters[provider] == nil {
            counters[provider] = Counters()
        }
    }

    /// Reserve the right to make one request to this provider.
    ///
    /// - Returns: nil when the request may proceed; otherwise the reason it was
    ///   skipped, as a failure record for the response.
    public func authorize(_ provider: ProviderID) async -> ProviderFailure? {
        if let breaker = breakers[provider] {
            let snapshot = await breaker.snapshot()
            if snapshot.state == .open {
                // `shouldAttempt` performs the cooldown transition; only call it when
                // the breaker claims to be open, to avoid claiming a probe needlessly.
                let allowed = await breaker.shouldAttempt()
                if !allowed {
                    return ProviderFailure(
                        provider: provider,
                        category: .circuitOpen,
                        message:
                            "\(provider.displayName) is temporarily skipped after repeated failures."
                    )
                }
            } else {
                // `.halfOpen` admits exactly one probe: `shouldAttempt` claims it for the first
                // caller and refuses the rest. Discarding that refusal let every concurrent caller
                // through, so a provider recovering from failures took the whole fan-out instead
                // of one request. `.closed` always returns true, so this cannot
                // refuse a healthy provider.
                let allowed = await breaker.shouldAttempt()
                if !allowed {
                    return ProviderFailure(
                        provider: provider,
                        category: .circuitOpen,
                        message:
                            "\(provider.displayName) is being probed after failures; this request "
                            + "is skipped until that probe finishes."
                    )
                }
            }
        }

        if let limiter = limiters[provider] {
            let acquired = await limiter.tryAcquire()
            if !acquired {
                let wait = await limiter.timeUntilAvailable()
                let detail = wait.map { " Retry in about \($0.milliseconds) ms." } ?? ""
                return ProviderFailure(
                    provider: provider,
                    category: .rateLimited,
                    message: "\(provider.displayName) is locally rate limited.\(detail)"
                )
            }
        }

        counters[provider, default: Counters()].totalRequests += 1
        return nil
    }

    /// How long until this provider's local bucket can serve a request.
    ///
    /// Used by the orchestrator to decide whether waiting is cheaper than failing. `nil`
    /// means a token is available now (or no limiter is registered).
    public func localWait(for provider: ProviderID) async -> Duration? {
        await limiters[provider]?.timeUntilAvailable()
    }

    // MARK: - Outcomes

    /// Give back a claimed half-open probe after a request that produced no outcome.
    ///
    /// Used when the caller was cancelled: the probe was claimed, the provider never answered, and
    /// leaving the claim in place would strand the breaker.
    public func releaseProbe(_ provider: ProviderID) async {
        await breakers[provider]?.releaseProbe()
    }

    public func recordSuccess(
        _ provider: ProviderID,
        latencyMilliseconds: Int,
        resultCount: Int
    ) async {
        var counter = counters[provider, default: Counters()]
        counter.successes += 1
        counter.lastLatency = latencyMilliseconds
        counter.totalLatency += latencyMilliseconds
        counter.lastSuccessAt = clock.now()
        counter.lastResultCount = resultCount
        counters[provider] = counter

        if let breaker = breakers[provider] {
            // Awaited, not detached: with a detached task two concurrent searches could
            // deliver a failure before an earlier success, so the consecutive-failure
            // count and the open/close transitions depended on scheduling.
            await breaker.recordSuccess()
        }
    }

    public func recordFailure(_ provider: ProviderID, failure: ProviderFailure) async {
        var counter = counters[provider, default: Counters()]
        counter.failures += 1
        counter.lastError = failure.message
        counter.lastErrorCategory = failure.category
        counter.lastFailureAt = clock.now()
        counters[provider] = counter

        if let breaker = breakers[provider] {
            // Awaited for the same reason as `recordSuccess`: the breaker must observe
            // outcomes in the order the searches produced them.
            await breaker.recordFailure(
                category: failure.category,
                message: failure.message
            )
        }
    }

    /// Record that a provider was still running when the whole-search deadline expired.
    ///
    /// Counted as a failure so `web_search_status` keeps reporting it, but it deliberately
    /// never reaches the breaker. The deadline covers the whole fan-out, so one slow
    /// search would otherwise mark every provider unhealthy at once and open breakers that
    /// no provider earned. A provider that is genuinely too slow fails its own request
    /// timeout first, and that does count.
    public func recordDeadlineExceeded(_ provider: ProviderID, message: String) {
        var counter = counters[provider, default: Counters()]
        counter.failures += 1
        counter.lastError = message
        counter.lastErrorCategory = .timeout
        counter.lastFailureAt = clock.now()
        counters[provider] = counter
    }

    // MARK: - Reporting

    public func state(
        for provider: ProviderID,
        configured: Bool,
        enabled: Bool
    ) async -> ProviderState {
        let circuit =
            await breakers[provider]?.snapshot()
            ?? CircuitBreaker.Snapshot(
                state: .closed,
                consecutiveFailures: 0,
                totalSuccesses: 0,
                totalFailures: 0,
                openedAt: nil,
                lastFailure: nil,
                lastFailureCategory: nil,
                lastSuccessAt: nil,
                probeInFlight: false
            )
        let rate =
            await limiters[provider]?.snapshot()
            ?? RateLimiter.Snapshot(
                availableTokens: 0,
                burst: 0,
                requestsPerMinute: 0,
                totalAcquired: 0,
                totalDenied: 0,
                lastAcquireAt: nil
            )
        let counter = counters[provider] ?? Counters()

        // `timeUntilAvailable()` returns a nested optional because the limiter
        // lookup is itself failable; flatten it explicitly.
        let waitForToken: Duration? =
            if let limiter = limiters[provider] {
                await limiter.timeUntilAvailable()
            } else {
                nil
            }

        let status: Status
        if !configured {
            status = .notConfigured
        } else if !enabled {
            status = .disabled
        } else if circuit.state == .open {
            status = .circuitOpen
        } else if circuit.state == .halfOpen {
            status = .probing
        } else if waitForToken != nil {
            status = .rateLimited
        } else {
            status = .ready
        }

        let average =
            counter.successes > 0 ? counter.totalLatency / counter.successes : 0

        return ProviderState(
            provider: provider,
            status: status,
            configured: configured,
            circuit: circuit,
            rateLimit: rate,
            successes: counter.successes,
            failures: counter.failures,
            totalRequests: counter.totalRequests,
            lastLatencyMilliseconds: counter.lastLatency,
            averageLatencyMilliseconds: average,
            lastError: counter.lastError,
            lastErrorCategory: counter.lastErrorCategory,
            lastSuccessAt: counter.lastSuccessAt,
            lastFailureAt: counter.lastFailureAt,
            lastResultCount: counter.lastResultCount,
            note: notes[provider]
        )
    }
}
