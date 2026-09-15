import Foundation

/// A snapshot of everything the dashboard displays for one refresh cycle.
///
/// Immutable: each cycle builds a new model and the renderer draws it, so there is no
/// shared mutable state between the probing tasks and the display.
public struct MonitorModel: Sendable {
    public var startedAt: Date
    public var refreshedAt: Date
    public var cycleDuration: Duration
    public var nodes: [NodeStatus]
    public var providers: [ProviderStatus]
    public var warnings: [String]

    /// Total wall-clock time since the monitor started.
    public var uptime: TimeInterval { refreshedAt.timeIntervalSince(startedAt) }

    public var healthyNodes: Int { nodes.filter { $0.state == .up }.count }
    public var healthyProviders: Int { providers.filter { $0.state == .healthy }.count }

    public init(
        startedAt: Date,
        refreshedAt: Date,
        cycleDuration: Duration,
        nodes: [NodeStatus],
        providers: [ProviderStatus],
        warnings: [String]
    ) {
        self.startedAt = startedAt
        self.refreshedAt = refreshedAt
        self.cycleDuration = cycleDuration
        self.nodes = nodes
        self.providers = providers
        self.warnings = warnings
    }
}

// MARK: - Nodes

/// A SearXNG instance running on a machine, reached over the network.
public struct NodeStatus: Sendable, Identifiable {
    public enum State: Sendable, Equatable {
        case checking
        /// Answered and returned results.
        case up
        /// Answered but returned nothing usable, or refused.
        case degraded
        case down

        public var label: String {
            switch self {
            case .checking: "····"
            case .up: "UP"
            case .degraded: "DEGRADED"
            case .down: "DOWN"
            }
        }
    }

    public var id: String { name }
    public var name: String
    /// Where the instance lives, for display.
    public var endpoint: String
    public var state: State
    public var latencyMilliseconds: Int?
    public var resultCount: Int
    /// Engines that actually contributed to the probe query.
    public var engines: [String]
    /// Engines the instance reported as failing, with their reason.
    public var unavailableEngines: [String]
    public var error: String?
    public var checks: Int
    public var failures: Int
    public var lastSuccessAt: Date?

    public var successRate: Double {
        checks == 0 ? 0 : Double(checks - failures) / Double(checks)
    }

    public static func pending(name: String, endpoint: String) -> NodeStatus {
        NodeStatus(
            name: name,
            endpoint: endpoint,
            state: .checking,
            latencyMilliseconds: nil,
            resultCount: 0,
            engines: [],
            unavailableEngines: [],
            error: nil,
            checks: 0,
            failures: 0,
            lastSuccessAt: nil
        )
    }

    /// Fold a new probe result into the running counters.
    public func applying(_ probe: NodeProbe.Result) -> NodeStatus {
        var updated = self
        updated.checks += 1
        updated.latencyMilliseconds = probe.latencyMilliseconds
        updated.state = probe.state
        updated.resultCount = probe.resultCount
        updated.engines = probe.engines
        updated.unavailableEngines = probe.unavailableEngines
        updated.error = probe.error
        if probe.state == .up {
            updated.lastSuccessAt = Date()
        } else {
            updated.failures += 1
        }
        return updated
    }
}

// MARK: - Providers

/// A search provider configured in the local server.
public struct ProviderStatus: Sendable, Identifiable {
    public enum State: Sendable, Equatable {
        case configuredButIdle
        case healthy
        case failing
        case notConfigured
        /// The operator switched this provider off, so the monitor does not probe it.
        ///
        /// B78 deleted this case because nothing produced it; B76 owns the producer and
        /// reintroduces it here with its semantics — a provider listed in
        /// `SEARCH_DISABLED_PROVIDERS` is shown as switched off rather than as ready to
        /// probe, which is what a dashboard agreeing with server eligibility means.
        case unavailable

        public var label: String {
            switch self {
            case .configuredButIdle: "IDLE"
            case .healthy: "OK"
            case .failing: "FAIL"
            case .notConfigured: "NO KEY"
            case .unavailable: "OFF"
            }
        }
    }

    public var id: ProviderID { provider }
    public var provider: ProviderID
    public var displayName: String
    /// "index", "aggregator", "scraper" — why the provider is weighted as it is.
    public var kind: String
    /// Credential or endpoint the provider needs, shown when it is unconfigured.
    public var setupHint: String
    public var state: State
    public var lastLatencyMilliseconds: Int?
    public var lastResultCount: Int
    public var probes: Int
    public var successes: Int
    public var failures: Int
    public var lastError: String?
    public var lastErrorCategory: ProviderFailure.FailureCategory?
    public var lastSuccessAt: Date?

    public var averageLatencyMilliseconds: Int? {
        guard successes > 0, let total = latencyTotal else { return nil }
        return total / successes
    }

    /// Sum of successful latencies, kept for the mean.
    public var latencyTotal: Int?

    public var successRate: Double {
        let attempted = successes + failures
        return attempted == 0 ? 0 : Double(successes) / Double(attempted)
    }

    public var isConfigured: Bool { state != .notConfigured }

    /// Whether the run expects this provider to serve: it holds its inputs and the operator
    /// has not switched it off.
    ///
    /// `NO KEY` and `OFF` are both expected states rather than failures, so a health check
    /// that counts providers must not treat a deliberately disabled one as a problem
    /// (ledger B76, used by the monitor's exit status from ledger B46).
    public var isInService: Bool { state != .notConfigured && state != .unavailable }

    public static func pending(
        provider: ProviderID,
        configured: Bool,
        enabled: Bool = true,
        hint: String
    ) -> ProviderStatus {
        ProviderStatus(
            provider: provider,
            displayName: provider.displayName,
            kind: ProviderStatus.kind(of: provider),
            setupHint: hint,
            // Being switched off is reported ahead of a missing credential: it is the
            // reason the provider will not run, and it is the operator's own doing.
            state: !enabled ? .unavailable : (configured ? .configuredButIdle : .notConfigured),
            lastLatencyMilliseconds: nil,
            lastResultCount: 0,
            probes: 0,
            successes: 0,
            failures: 0,
            lastError: nil,
            lastErrorCategory: nil,
            lastSuccessAt: nil,
            latencyTotal: nil
        )
    }

    public static func kind(of provider: ProviderID) -> String {
        if provider.isExperimentalScraper { return "scraper" }
        if provider.isAggregator { return "aggregator" }
        return provider.sourceFamily.isIndependentIndex ? "index" : "search"
    }

    /// Fold a probe outcome into the running counters.
    public func applying(_ outcome: ProbeOutcome) -> ProviderStatus {
        var updated = self
        updated.probes += 1
        updated.lastLatencyMilliseconds = outcome.latencyMilliseconds
        updated.lastResultCount = outcome.resultCount
        updated.lastError = outcome.error
        updated.lastErrorCategory = outcome.category

        if outcome.succeeded {
            updated.successes += 1
            updated.state = .healthy
            updated.lastSuccessAt = Date()
            if let latency = outcome.latencyMilliseconds {
                updated.latencyTotal = (updated.latencyTotal ?? 0) + latency
            }
        } else {
            updated.failures += 1
            updated.state = .failing
        }
        return updated
    }
}

/// The result of probing one provider once.
public struct ProbeOutcome: Sendable {
    public var succeeded: Bool
    public var latencyMilliseconds: Int?
    public var resultCount: Int
    public var error: String?
    public var category: ProviderFailure.FailureCategory?

    public static func success(latencyMilliseconds: Int, resultCount: Int) -> ProbeOutcome {
        ProbeOutcome(
            succeeded: true,
            latencyMilliseconds: latencyMilliseconds,
            resultCount: resultCount,
            error: nil,
            category: nil
        )
    }

    public static func failure(
        error: String,
        category: ProviderFailure.FailureCategory?,
        latencyMilliseconds: Int? = nil
    ) -> ProbeOutcome {
        ProbeOutcome(
            succeeded: false,
            latencyMilliseconds: latencyMilliseconds,
            resultCount: 0,
            error: error,
            category: category
        )
    }
}
