import Foundation

/// All runtime configuration, resolved once at boot from a small optional config
/// file plus environment variables (environment always wins).
///
/// The server must start successfully with **zero** API keys: every credential is
/// optional and providers simply report themselves as unconfigured.
public struct AppConfiguration: Sendable, Hashable {
    // MARK: Credentials & endpoints

    public var tavilyAPIKey: String?
    public var braveAPIKey: String?
    public var mojeekAPIKey: String?
    public var exaAPIKey: String?
    public var jinaAPIKey: String?
    public var searxngBaseURL: URL?
    public var openWebSearchURL: URL?
    public var parallelMCPURL: URL?

    /// Optional credential for grounded answer synthesis.
    ///
    /// This is **not** a search provider. It never sees the user's query on its own:
    /// it only ever receives results that real providers already returned, and is
    /// instructed to answer from those alone. Without it, search works unchanged and
    /// the synthesis tool reports itself unconfigured.
    public var deepSeekAPIKey: String?
    /// OpenAI-compatible base for synthesis. `/chat/completions` is appended.
    public var deepSeekBaseURL: URL?
    /// Model used for synthesis. `deepseek-flash` is DeepSeek-V4.1-Flash.
    public var deepSeekModel: String
    /// Wall-clock budget for one synthesis call. Generous on purpose: this is a
    /// generative request, not a search request.
    public var synthesisTimeout: Duration
    /// Whether synthesis may use the model's thinking mode.
    ///
    /// Off by default: with thinking on, the reasoning pass shares the output-token
    /// budget and can consume all of it, returning `finish_reason: length` with
    /// **empty** content. Measured on `deepseek-flash`, high effort returned
    /// `completion=4000, reasoning=4000, content=""`. Grounded synthesis needs no
    /// chain of thought, so the default trades a little reasoning for a response
    /// that actually arrives.
    public var enableSynthesisReasoning: Bool

    // MARK: Policy

    /// Provider preference order for `provider = auto`.
    public var providerOrder: [ProviderID]
    /// Manual overrides applied on top of the default order.
    public var providerEnabled: [ProviderID: Bool]
    public var defaultMaxResults: Int
    public var fastTimeout: Duration
    public var balancedTimeout: Duration
    public var thoroughTimeout: Duration
    /// Whether the HTML scrapers (DuckDuckGo, Startpage) take part.
    ///
    /// **On by default**, like every other provider. This installation runs every provider it
    /// defines and lets each one report its own condition — missing credential, unreachable,
    /// challenged — rather than pre-selecting a curated subset. A provider that cannot serve a
    /// query fails over instead of failing the search, so having one on costs a request and
    /// never costs a result. Turn it off with `SEARCH_ENABLE_SCRAPERS=false`.
    public var enableScrapers: Bool
    /// Whether the Parallel Search MCP provider takes part. On by default, for the same reason
    /// as `enableScrapers`; `SEARCH_ENABLE_PARALLEL=false` turns it off.
    public var enableParallel: Bool
    public var enableJinaReaderFallback: Bool
    public var cacheTTL: Duration

    // MARK: HTTP

    /// Bound on one request attempt. It covers connection establishment as well as the
    /// wait for data, which is why there is no separate connect-timeout setting: the
    /// transport does not expose a connect-only deadline, and a knob that nothing reads
    /// is worse than no knob.
    public var requestTimeout: Duration
    public var maxSearchResponseBytes: Int
    public var maxFetchedPageBytes: Int
    public var userAgent: String
    public var maxRetryAttempts: Int

    // MARK: Fetch / SSRF

    /// When true, allow fetching hosts that resolve to private address space.
    /// Off by default; only useful for a deliberately internal deployment.
    public var allowPrivateNetworkFetch: Bool

    // MARK: Logging

    /// A configured value that could not be used.
    ///
    /// A typo used to be indistinguishable from "not configured": the value was dropped, the
    /// default applied, and nothing anywhere said so — which is how an operator ends up with an
    /// empty provider list and no explanation.
    public struct ConfigurationIssue: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// `SEARCH_CONFIG_FILE` was set but the file is missing or unreadable.
            case unreadableConfigFile
            /// A value was present but is not of the documented shape.
            case unparseableValue
            /// A URL was present but is not an absolute `http(s)` URL.
            case invalidURL
        }

        public let kind: Kind
        /// The environment variable or file key the value came from.
        public let key: String
        /// What was wrong, phrased for an operator. Never contains a credential.
        public let detail: String

        public var description: String { "\(key): \(detail)" }
    }

    /// Everything that was configured but could not be used, in the order it was found.
    public internal(set) var issues: [ConfigurationIssue] = []

    public var logLevel: LogLevel
    public var logQueries: Bool

    /// Fusion tuning.
    public var fusion: RankFusion.Configuration

    public init(
        tavilyAPIKey: String? = nil,
        braveAPIKey: String? = nil,
        mojeekAPIKey: String? = nil,
        exaAPIKey: String? = nil,
        jinaAPIKey: String? = nil,
        searxngBaseURL: URL? = nil,
        openWebSearchURL: URL? = nil,
        parallelMCPURL: URL? = URL(string: "https://search.parallel.ai/mcp"),
        deepSeekAPIKey: String? = nil,
        deepSeekBaseURL: URL? = URL(string: "https://api.deepseek.com/v1"),
        deepSeekModel: String = "deepseek-flash",
        synthesisTimeout: Duration = .seconds(45),
        enableSynthesisReasoning: Bool = false,
        providerOrder: [ProviderID] = AppConfiguration.defaultProviderOrder,
        providerEnabled: [ProviderID: Bool] = [:],
        defaultMaxResults: Int = 8,
        fastTimeout: Duration = .milliseconds(12_000),
        balancedTimeout: Duration = .milliseconds(15_000),
        thoroughTimeout: Duration = .milliseconds(20_000),
        enableScrapers: Bool = true,
        enableParallel: Bool = true,
        enableJinaReaderFallback: Bool = true,
        cacheTTL: Duration = .seconds(120),
        requestTimeout: Duration = .seconds(10),
        maxSearchResponseBytes: Int = 4 * 1024 * 1024,
        maxFetchedPageBytes: Int = 10 * 1024 * 1024,
        // Derived from the single source rather than a second literal: this used to read
        // `SwiftWebSearchMCP/1.0` and would have quietly disagreed with the version the server
        // reports over MCP (RELEASE.md §1.3).
        userAgent: String = "SwiftWebSearchMCP/\(BuildVersion.value) (+https://example.invalid/project)",
        maxRetryAttempts: Int = 2,
        allowPrivateNetworkFetch: Bool = false,
        logLevel: LogLevel = .info,
        logQueries: Bool = false,
        fusion: RankFusion.Configuration = .default
    ) {
        self.tavilyAPIKey = tavilyAPIKey
        self.braveAPIKey = braveAPIKey
        self.mojeekAPIKey = mojeekAPIKey
        self.exaAPIKey = exaAPIKey
        self.jinaAPIKey = jinaAPIKey
        self.searxngBaseURL = searxngBaseURL
        self.openWebSearchURL = openWebSearchURL
        self.parallelMCPURL = parallelMCPURL
        self.deepSeekAPIKey = deepSeekAPIKey
        self.deepSeekBaseURL = deepSeekBaseURL
        self.deepSeekModel = deepSeekModel
        self.synthesisTimeout = synthesisTimeout
        self.enableSynthesisReasoning = enableSynthesisReasoning
        self.providerOrder = providerOrder
        self.providerEnabled = providerEnabled
        self.defaultMaxResults = defaultMaxResults
        self.fastTimeout = fastTimeout
        self.balancedTimeout = balancedTimeout
        self.thoroughTimeout = thoroughTimeout
        self.enableScrapers = enableScrapers
        self.enableParallel = enableParallel
        self.enableJinaReaderFallback = enableJinaReaderFallback
        self.cacheTTL = cacheTTL
        self.requestTimeout = requestTimeout
        self.maxSearchResponseBytes = maxSearchResponseBytes
        self.maxFetchedPageBytes = maxFetchedPageBytes
        self.userAgent = userAgent
        self.maxRetryAttempts = maxRetryAttempts
        self.allowPrivateNetworkFetch = allowPrivateNetworkFetch
        self.logLevel = logLevel
        self.logQueries = logQueries
        self.fusion = fusion
    }

    /// Default `provider = auto` preference order.
    ///
    /// Direct providers come first, aggregators last, scrapers last of all. Quota,
    /// geography and query mix change what is optimal, so this is configurable via
    /// `SEARCH_PROVIDER_ORDER`.
    public static let defaultProviderOrder: [ProviderID] = [
        .tavily,
        .brave,
        .mojeek,
        .exa,
        .searxng,
        .openWebSearch,
        .duckDuckGo,
        .startpage,
        .parallel,
    ]

    /// The overall wall-clock budget for a search in the given mode.
    public func timeout(for mode: SearchMode) -> Duration {
        switch mode {
        case .fast: fastTimeout
        case .balanced: balancedTimeout
        case .thorough: thoroughTimeout
        }
    }
}

// MARK: - Log level

public enum LogLevel: String, Sendable, Hashable, CaseIterable, Comparable {
    case trace, debug, info, warning, error, none

    private var severity: Int {
        switch self {
        case .trace: 0
        case .debug: 1
        case .info: 2
        case .warning: 3
        case .error: 4
        case .none: 5
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}

// MARK: - Loading
