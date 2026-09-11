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

    // MARK: Policy

    /// Provider preference order for `provider = auto`.
    public var providerOrder: [ProviderID]
    /// Manual overrides applied on top of the default order.
    public var providerEnabled: [ProviderID: Bool]
    public var defaultMaxResults: Int
    public var fastTimeout: Duration
    public var balancedTimeout: Duration
    public var thoroughTimeout: Duration
    public var enableScrapers: Bool
    public var enableParallel: Bool
    public var enableJinaReaderFallback: Bool
    public var cacheTTL: Duration

    // MARK: HTTP

    public var connectTimeout: Duration
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
        providerOrder: [ProviderID] = AppConfiguration.defaultProviderOrder,
        providerEnabled: [ProviderID: Bool] = [:],
        defaultMaxResults: Int = 8,
        fastTimeout: Duration = .milliseconds(12_000),
        balancedTimeout: Duration = .milliseconds(15_000),
        thoroughTimeout: Duration = .milliseconds(20_000),
        enableScrapers: Bool = false,
        enableParallel: Bool = false,
        enableJinaReaderFallback: Bool = true,
        cacheTTL: Duration = .seconds(120),
        connectTimeout: Duration = .seconds(3),
        requestTimeout: Duration = .seconds(10),
        maxSearchResponseBytes: Int = 4 * 1024 * 1024,
        maxFetchedPageBytes: Int = 10 * 1024 * 1024,
        userAgent: String = "SwiftWebSearchMCP/1.0 (+https://example.invalid/project)",
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
        self.connectTimeout = connectTimeout
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

extension AppConfiguration {
    /// Configuration keys, mapped to environment variable names.
    public enum Key: String, CaseIterable, Sendable {
        case tavilyAPIKey = "TAVILY_API_KEY"
        case braveAPIKey = "BRAVE_SEARCH_API_KEY"
        case mojeekAPIKey = "MOJEEK_API_KEY"
        case exaAPIKey = "EXA_API_KEY"
        case jinaAPIKey = "JINA_API_KEY"
        case searxngBaseURL = "SEARXNG_BASE_URL"
        case openWebSearchURL = "OPEN_WEB_SEARCH_URL"
        case parallelMCPURL = "PARALLEL_MCP_URL"
        case providerOrder = "SEARCH_PROVIDER_ORDER"
        case disabledProviders = "SEARCH_DISABLED_PROVIDERS"
        case maxResults = "SEARCH_MAX_RESULTS"
        case fastTimeout = "SEARCH_FAST_TIMEOUT_MS"
        case balancedTimeout = "SEARCH_BALANCED_TIMEOUT_MS"
        case thoroughTimeout = "SEARCH_THOROUGH_TIMEOUT_MS"
        case enableScrapers = "SEARCH_ENABLE_SCRAPERS"
        case enableParallel = "SEARCH_ENABLE_PARALLEL"
        case enableJinaReader = "SEARCH_ENABLE_JINA_READER"
        case cacheTTL = "SEARCH_CACHE_TTL_SECONDS"
        case connectTimeout = "SEARCH_CONNECT_TIMEOUT_MS"
        case requestTimeout = "SEARCH_REQUEST_TIMEOUT_MS"
        case maxRetries = "SEARCH_MAX_RETRIES"
        case allowPrivateNetwork = "SEARCH_ALLOW_PRIVATE_NETWORK"
        case logLevel = "SEARCH_LOG_LEVEL"
        case logQueries = "SEARCH_LOG_QUERIES"
        case userAgent = "SEARCH_USER_AGENT"
        case configFile = "SEARCH_CONFIG_FILE"
    }

    /// Load configuration from an optional config file plus environment variables.
    ///
    /// - Parameters:
    ///   - environment: Environment dictionary (injectable for tests).
    ///   - configFileURL: Explicit config file. When nil, `SEARCH_CONFIG_FILE` is
    ///     consulted, falling back to a `config.env` next to the executable.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configFileURL: URL? = nil
    ) -> AppConfiguration {
        var values: [String: String] = [:]

        let fileURL =
            configFileURL
            ?? environment[Key.configFile.rawValue].flatMap { URL(fileURLWithPath: $0) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        if let fileURL, let contents = try? String(contentsOf: fileURL, encoding: .utf8) {
            for (key, value) in parseDotEnv(contents) {
                values[key] = value
            }
        }

        // Environment wins over the config file.
        for key in Key.allCases {
            if let value = environment[key.rawValue], !value.isEmpty {
                values[key.rawValue] = value
            }
        }

        return parse(values)
    }

    /// Parse a resolved key/value map into a configuration. Kept pure so it can be
    /// unit tested without touching the process environment.
    public static func parse(_ values: [String: String]) -> AppConfiguration {
        func string(_ key: Key) -> String? {
            guard let raw = values[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { return nil }
            return raw
        }

        func int(_ key: Key) -> Int? {
            guard let raw = string(key) else { return nil }
            return Int(raw)
        }

        func bool(_ key: Key) -> Bool? {
            guard let raw = string(key)?.lowercased() else { return nil }
            switch raw {
            case "1", "true", "yes", "on", "enabled": return true
            case "0", "false", "no", "off", "disabled": return false
            default: return nil
            }
        }

        func url(_ key: Key) -> URL? {
            guard let raw = string(key) else { return nil }
            return URL(string: raw)
        }

        var configuration = AppConfiguration()

        configuration.tavilyAPIKey = string(.tavilyAPIKey)
        configuration.braveAPIKey = string(.braveAPIKey)
        configuration.mojeekAPIKey = string(.mojeekAPIKey)
        configuration.exaAPIKey = string(.exaAPIKey)
        configuration.jinaAPIKey = string(.jinaAPIKey)
        configuration.searxngBaseURL = url(.searxngBaseURL)
        configuration.openWebSearchURL = url(.openWebSearchURL)

        if let parallel = url(.parallelMCPURL) {
            configuration.parallelMCPURL = parallel
        } else if values[Key.parallelMCPURL.rawValue]?.isEmpty == true {
            configuration.parallelMCPURL = nil
        }

        if let order = string(.providerOrder) {
            let parsed = order
                .split(separator: ",")
                .compactMap { ProviderID(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
            if !parsed.isEmpty {
                // Keep every known provider reachable even if the operator only
                // listed some of them, preserving their stated order first.
                var seen = Set(parsed)
                var full = parsed
                // Append the remaining *search* providers so an operator cannot
                // accidentally make one unreachable. `jina` is deliberately excluded:
                // it is a fetch/extraction provider and never participates in search.
                for provider in defaultProviderOrder
                where !seen.contains(provider) && provider.isSearchProvider {
                    full.append(provider)
                    seen.insert(provider)
                }
                configuration.providerOrder = full
            }
        }

        if let disabled = string(.disabledProviders) {
            for name in disabled.split(separator: ",") {
                let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
                if let provider = ProviderID(rawValue: trimmed) {
                    configuration.providerEnabled[provider] = false
                }
            }
        }

        if let maxResults = int(.maxResults) {
            configuration.defaultMaxResults = min(max(1, maxResults), 20)
        }
        if let ms = int(.fastTimeout) { configuration.fastTimeout = .milliseconds(max(1_000, ms)) }
        if let ms = int(.balancedTimeout) {
            configuration.balancedTimeout = .milliseconds(max(1_000, ms))
        }
        if let ms = int(.thoroughTimeout) {
            configuration.thoroughTimeout = .milliseconds(max(1_000, ms))
        }
        if let enabled = bool(.enableScrapers) { configuration.enableScrapers = enabled }
        if let enabled = bool(.enableParallel) { configuration.enableParallel = enabled }
        if let enabled = bool(.enableJinaReader) { configuration.enableJinaReaderFallback = enabled }
        if let seconds = int(.cacheTTL) {
            configuration.cacheTTL = .seconds(max(0, seconds))
        }
        if let ms = int(.connectTimeout) {
            configuration.connectTimeout = .milliseconds(max(100, ms))
        }
        if let ms = int(.requestTimeout) {
            configuration.requestTimeout = .milliseconds(max(100, ms))
        }
        if let retries = int(.maxRetries) {
            configuration.maxRetryAttempts = min(max(0, retries), 5)
        }
        if let allowed = bool(.allowPrivateNetwork) {
            configuration.allowPrivateNetworkFetch = allowed
        }
        if let raw = string(.logLevel), let level = LogLevel(rawValue: raw.lowercased()) {
            configuration.logLevel = level
        }
        if let enabled = bool(.logQueries) { configuration.logQueries = enabled }
        if let agent = string(.userAgent) { configuration.userAgent = agent }

        return configuration
    }

    /// Minimal `KEY=VALUE` parser supporting `#` comments and optional quotes.
    /// Not a full dotenv implementation; deliberately dependency-free.
    static func parseDotEnv(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                    || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }
}
