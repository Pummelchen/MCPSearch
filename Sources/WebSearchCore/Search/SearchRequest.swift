import Foundation

// MARK: - Recency

/// Provider-neutral freshness filter, mapped by each adapter onto whatever the
/// vendor supports.
public enum Recency: String, Codable, Sendable, Hashable, CaseIterable {
    case any
    case day
    case week
    case month
    case year

    /// Number of days this window covers, used for providers that take a date
    /// range or a day count rather than an enum.
    public var approximateDays: Int? {
        switch self {
        case .any: nil
        case .day: 1
        case .week: 7
        case .month: 31
        case .year: 365
        }
    }

    public var isFiltering: Bool { self != .any }
}

// MARK: - Search mode

/// How much work a single `web_search` call is allowed to do.
public enum SearchMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// One provider, lowest latency.
    case fast
    /// Up to two independent providers, fused.
    case balanced
    /// Up to three providers plus optional aggregator coverage.
    case thorough

    /// Maximum number of direct providers to query concurrently.
    public var maxDirectProviders: Int {
        switch self {
        case .fast: 1
        case .balanced: 2
        case .thorough: 3
        }
    }

    /// Whether the mode permits spending an extra call on an aggregator once the
    /// direct providers have not produced enough independent coverage.
    public var allowsAggregatorCoverage: Bool {
        self == .thorough
    }

    /// Whether the mode permits a provider to use its expensive/depth mode.
    /// Tavily's `advanced` depth costs more credits, so only `thorough` may use it.
    public var allowsDeepSearch: Bool {
        self == .thorough
    }
}

// MARK: - Locale

/// A lightweight BCP-47-ish locale split into the two parts providers actually want.
public struct LocaleHint: Sendable, Hashable, Codable {
    /// e.g. `en`
    public let language: String
    /// e.g. `US`
    public let region: String?

    public init(language: String, region: String? = nil) {
        self.language = language
        self.region = region
    }

    /// Parse `en-US`, `en_US`, or `en`.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let first = parts.first, !first.isEmpty else { return nil }
        self.language = String(first).lowercased()
        if parts.count > 1 {
            let region = String(parts[1]).uppercased()
            self.region = region.count == 2 ? region : nil
        } else {
            self.region = nil
        }
    }

    /// `en-US` / `en`
    public var identifier: String {
        if let region { "\(language)-\(region)" } else { language }
    }
}

// MARK: - Request

/// The normalized search request handed to every provider.
public struct SearchRequest: Sendable, Hashable, Codable {
    public var query: String
    public var maxResults: Int
    public var recency: Recency
    public var includeDomains: [String]
    public var excludeDomains: [String]
    public var locale: LocaleHint?
    public var mode: SearchMode
    /// How many results this particular provider should return. Defaults to
    /// `maxResults`; the orchestrator may ask for more per provider than it finally
    /// returns so fusion has material to work with.
    public var providerResultBudget: Int

    public init(
        query: String,
        maxResults: Int = 8,
        recency: Recency = .any,
        includeDomains: [String] = [],
        excludeDomains: [String] = [],
        locale: LocaleHint? = nil,
        mode: SearchMode = .balanced,
        providerResultBudget: Int? = nil
    ) {
        self.query = query
        self.maxResults = maxResults
        self.recency = recency
        self.includeDomains = includeDomains
        self.excludeDomains = excludeDomains
        self.locale = locale
        self.mode = mode
        self.providerResultBudget = providerResultBudget ?? maxResults
    }

    /// The query with collapsed whitespace, used for cache keys and logging.
    public var normalizedQuery: String {
        query.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A copy of the request scoped to one provider's result budget.
    public func scoped(to budget: Int) -> SearchRequest {
        var copy = self
        copy.providerResultBudget = max(1, budget)
        return copy
    }
}

// MARK: - Search-run bookkeeping

/// Why a provider did not contribute to a response.
public struct ProviderFailure: Sendable, Hashable, Codable {
    public let provider: ProviderID
    public let category: FailureCategory
    public let message: String

    public init(provider: ProviderID, category: FailureCategory, message: String) {
        self.provider = provider
        self.category = category
        self.message = message
    }

    /// Coarse failure classification, stable across providers so the orchestrator
    /// can decide between retry, circuit-break and configuration error.
    public enum FailureCategory: String, Sendable, Hashable, Codable {
        case notConfigured = "not_configured"
        case authentication = "authentication"
        case rateLimited = "rate_limited"
        case timeout
        case network
        case serverError = "server_error"
        case malformedResponse = "malformed_response"
        case unsupportedRequest = "unsupported_request"
        case circuitOpen = "circuit_open"
        case cancelled
        case unknown

        /// Whether this failure is the provider's fault but likely temporary.
        public var isTransient: Bool {
            switch self {
            case .rateLimited, .timeout, .network, .serverError: true
            default: false
            }
        }

        /// Whether an operator needs to fix configuration rather than wait.
        public var isConfiguration: Bool {
            switch self {
            case .notConfigured, .authentication: true
            default: false
            }
        }
    }
}
