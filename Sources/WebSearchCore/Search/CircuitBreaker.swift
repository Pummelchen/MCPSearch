import Foundation

/// Per-provider circuit breaker.
///
/// The objective is simple: a dead provider must never block or slow down an
/// entire tool call. After repeated *transient* failures the provider is skipped
/// entirely until a cooldown elapses, then allowed a single probe request.
///
/// Authentication and configuration errors are tracked separately and deliberately
/// do **not** trip the breaker — retrying them is pointless, but they also should
/// not mask the provider from the status tool.
public actor CircuitBreaker {
    public enum State: String, Sendable, Hashable, Codable {
        /// Normal operation.
        case closed
        /// Skipping requests until the cooldown expires.
        case open
        /// One probe request is permitted.
        case halfOpen = "half_open"
    }

    public struct Snapshot: Sendable, Hashable {
        public let state: State
        public let consecutiveFailures: Int
        public let totalSuccesses: Int
        public let totalFailures: Int
        public let openedAt: Date?
        public let lastFailure: String?
        public let lastFailureCategory: ProviderFailure.FailureCategory?
        public let lastSuccessAt: Date?
        public let probeInFlight: Bool
    }

    public struct Policy: Sendable, Hashable {
        public var failureThreshold: Int
        public var cooldown: Duration
        public var successThresholdToClose: Int

        public init(
            failureThreshold: Int = 3,
            cooldown: Duration = .seconds(30),
            successThresholdToClose: Int = 1
        ) {
            self.failureThreshold = max(1, failureThreshold)
            self.cooldown = cooldown
            self.successThresholdToClose = max(1, successThresholdToClose)
        }

        public static let `default` = Policy()
    }

    private let policy: Policy
    private let clock: any Clock

    private var state: State = .closed
    private var consecutiveFailures = 0
    private var consecutiveSuccesses = 0
    private var totalSuccesses = 0
    private var totalFailures = 0
    private var openedAt: Date?
    private var lastFailure: String?
    private var lastFailureCategory: ProviderFailure.FailureCategory?
    private var lastSuccessAt: Date?
    private var probeInFlight = false

    public init(policy: Policy = .default, clock: any Clock = SystemClock()) {
        self.policy = policy
        self.clock = clock
    }

    /// Whether a request should be attempted right now.
    ///
    /// A half-open probe is claimed by the first caller only, so a burst of
    /// concurrent searches cannot all hammer a recovering provider.
    public func shouldAttempt() -> Bool {
        switch state {
        case .closed:
            return true
        case .open:
            guard let openedAt else { return true }
            let elapsed = clock.now().timeIntervalSince(openedAt)
            if elapsed >= policy.cooldown.seconds {
                state = .halfOpen
                consecutiveSuccesses = 0
                probeInFlight = false
            } else {
                return false
            }
            fallthrough
        case .halfOpen:
            if probeInFlight { return false }
            probeInFlight = true
            return true
        }
    }

    /// Record a successful request.
    public func recordSuccess(at date: Date? = nil) {
        let now = date ?? clock.now()
        totalSuccesses += 1
        consecutiveFailures = 0
        lastSuccessAt = now
        probeInFlight = false
        switch state {
        case .halfOpen:
            consecutiveSuccesses += 1
            if consecutiveSuccesses >= policy.successThresholdToClose {
                close()
            }
        case .closed, .open:
            close()
        }
    }

    /// Give back a claimed half-open probe that produced no outcome.
    ///
    /// A caller that goes away is not a provider failure — the same reasoning that keeps the
    /// whole-search deadline off the breaker — but the probe it claimed must be returned, or the
    /// breaker stays half-open with a claim nobody will ever release and the provider is never
    /// tried again.
    public func releaseProbe() {
        guard state == .halfOpen else { return }
        probeInFlight = false
    }

    /// Record a failed request. Only transient failures count toward opening the
    /// breaker; configuration errors are recorded but never trip it.
    public func recordFailure(
        category: ProviderFailure.FailureCategory,
        message: String,
        at date: Date? = nil
    ) {
        let now = date ?? clock.now()
        totalFailures += 1
        lastFailure = message
        lastFailureCategory = category
        probeInFlight = false

        guard category.isTransient else {
            // A bad key or a schema change is not something waiting will fix.
            // Return to closed so the provider keeps being tried and keeps
            // reporting its real error instead of hiding behind an open breaker.
            if state == .halfOpen { close() }
            return
        }

        consecutiveFailures += 1
        switch state {
        case .closed:
            if consecutiveFailures >= policy.failureThreshold {
                state = .open
                openedAt = now
            }
        case .halfOpen:
            // A failed probe sends us straight back to open with a fresh cooldown.
            state = .open
            openedAt = now
        case .open:
            openedAt = now
        }
    }

    /// Manually force the breaker closed, e.g. after an operator fixes a key.
    public func reset() {
        close()
        totalSuccesses = 0
        totalFailures = 0
        lastFailure = nil
        lastFailureCategory = nil
        lastSuccessAt = nil
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            state: state,
            consecutiveFailures: consecutiveFailures,
            totalSuccesses: totalSuccesses,
            totalFailures: totalFailures,
            openedAt: openedAt,
            lastFailure: lastFailure,
            lastFailureCategory: lastFailureCategory,
            lastSuccessAt: lastSuccessAt,
            probeInFlight: probeInFlight
        )
    }

    private func close() {
        state = .closed
        consecutiveFailures = 0
        consecutiveSuccesses = 0
        openedAt = nil
        probeInFlight = false
    }
}
