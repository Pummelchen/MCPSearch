import Foundation

/// Provider-local token-bucket rate limiter.
///
/// The server treats a provider's published limit as a **ceiling, not a quota to
/// spend**. The bucket is deliberately conservative: it smooths bursts and refuses
/// to start work it cannot complete inside the run's budget, rather than trying to
/// consume an entire free tier.
public actor RateLimiter {
    public struct Policy: Sendable, Hashable {
        /// Bucket capacity — the largest burst allowed.
        public var burst: Int
        /// Sustained refill rate, in requests per minute.
        public var requestsPerMinute: Double
        /// Hard floor between consecutive requests, for scrapers whose public
        /// endpoints react badly to rapid calls.
        public var minimumInterval: Duration?

        public init(
            burst: Int = 3,
            requestsPerMinute: Double = 60,
            minimumInterval: Duration? = nil
        ) {
            self.burst = max(1, burst)
            self.requestsPerMinute = max(0.001, requestsPerMinute)
            self.minimumInterval = minimumInterval
        }

        /// Native JSON APIs, comfortably provisioned.
        public static let apiDefault = Policy(burst: 4, requestsPerMinute: 60)

        /// Opt-in HTML scrapers: slow, serialized and easy to get blocked.
        public static let scraper = Policy(
            burst: 1,
            requestsPerMinute: 10,
            minimumInterval: .milliseconds(1_500)
        )

        /// Self-hosted SearXNG: no vendor quota, but the instance is usually small.
        public static let selfHosted = Policy(
            burst: 2,
            requestsPerMinute: 30,
            minimumInterval: .milliseconds(500)
        )
    }

    public struct Snapshot: Sendable, Hashable {
        public let availableTokens: Double
        public let burst: Int
        public let requestsPerMinute: Double
        public let totalAcquired: Int
        public let totalDenied: Int
        public let lastAcquireAt: Date?
    }

    private let policy: Policy
    private let clock: any Clock
    private var tokens: Double
    private var lastRefill: Date
    private var lastAcquire: Date?
    private var totalAcquired = 0
    private var totalDenied = 0

    public init(policy: Policy = .apiDefault, clock: any Clock = SystemClock()) {
        self.policy = policy
        self.clock = clock
        self.tokens = Double(policy.burst)
        self.lastRefill = clock.now()
    }

    /// Try to take a token. Returns false when the caller should skip this provider
    /// rather than wait — waiting would eat the whole search budget.
    public func tryAcquire() -> Bool {
        refill()
        guard tokens >= 1 else {
            totalDenied += 1
            return false
        }
        if let minimumInterval = policy.minimumInterval, let lastAcquire {
            let elapsed = clock.now().timeIntervalSince(lastAcquire)
            guard elapsed >= minimumInterval.seconds else {
                totalDenied += 1
                return false
            }
        }
        tokens -= 1
        let now = clock.now()
        lastAcquire = now
        totalAcquired += 1
        return true
    }

    /// Time until at least one token is available, or nil when one is available now.
    public func timeUntilAvailable() -> Duration? {
        refill()
        if tokens >= 1 {
            if let minimumInterval = policy.minimumInterval, let lastAcquire {
                let elapsed = clock.now().timeIntervalSince(lastAcquire)
                let remaining = minimumInterval.seconds - elapsed
                if remaining > 0 { return .milliseconds(Int(remaining * 1000)) }
            }
            return nil
        }
        let missing = 1 - tokens
        let secondsPerToken = 60.0 / policy.requestsPerMinute
        return .milliseconds(Int((missing * secondsPerToken * 1000).rounded(.up)))
    }

    public func snapshot() -> Snapshot {
        refill()
        return Snapshot(
            availableTokens: tokens,
            burst: policy.burst,
            requestsPerMinute: policy.requestsPerMinute,
            totalAcquired: totalAcquired,
            totalDenied: totalDenied,
            lastAcquireAt: lastAcquire
        )
    }

    private func refill() {
        let now = clock.now()
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        let perSecond = policy.requestsPerMinute / 60.0
        tokens = min(Double(policy.burst), tokens + elapsed * perSecond)
        lastRefill = now
    }
}
