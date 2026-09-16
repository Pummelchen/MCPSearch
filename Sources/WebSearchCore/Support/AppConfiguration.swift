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
    public private(set) var issues: [ConfigurationIssue] = []

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
        case deepSeekAPIKey = "DEEPSEEK_API_KEY"
        case deepSeekBaseURL = "DEEPSEEK_BASE_URL"
        case deepSeekModel = "DEEPSEEK_MODEL"
        case synthesisTimeout = "SEARCH_SYNTHESIS_TIMEOUT_MS"
        case enableReasoning = "SEARCH_SYNTHESIS_REASONING"
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
    ///     consulted; with neither, only the environment is read. There is deliberately no
    ///     implicit `config.env` next to the executable: a second, silent configuration
    ///     source is a surprise in a server whose credentials are meant to be explicit.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configFileURL: URL? = nil
    ) -> AppConfiguration {
        var values: [String: String] = [:]
        var issues: [ConfigurationIssue] = []

        // A config file that was asked for and is not there is a configuration error, not
        // "no config file": silently falling back to the environment is how a mistyped path
        // turns into a server with no providers and no diagnostic.
        var fileURL = configFileURL
        if fileURL == nil, let requested = environment[Key.configFile.rawValue],
            !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let candidate = URL(fileURLWithPath: requested)
            if FileManager.default.fileExists(atPath: candidate.path) {
                fileURL = candidate
            } else {
                issues.append(
                    ConfigurationIssue(
                        kind: .unreadableConfigFile,
                        key: Key.configFile.rawValue,
                        detail: "\(requested) does not exist"
                    )
                )
            }
        }

        if let fileURL {
            if let contents = try? String(contentsOf: fileURL, encoding: .utf8) {
                for (key, value) in parseDotEnv(contents) {
                    values[key] = value
                }
            } else {
                issues.append(
                    ConfigurationIssue(
                        kind: .unreadableConfigFile,
                        key: Key.configFile.rawValue,
                        detail: "\(fileURL.path) exists but could not be read"
                    )
                )
            }
        }

        // Environment wins over the config file.
        for key in Key.allCases {
            if let value = environment[key.rawValue], !value.isEmpty {
                values[key.rawValue] = value
            }
        }

        // An explicitly empty value in the *environment* is how an operator removes a default that
        // needs nothing else configured: `PARALLEL_MCP_URL=`. `load` copies environment entries only
        // when they are non-empty (an empty variable is not a setting) and `parseDotEnv` drops empty
        // values, so the branch in `parse` that clears the built-in Parallel endpoint could never
        // run. Carried for this key only, because it is the only key with a non-nil
        // default that an operator would want to remove.
        if let raw = environment[Key.parallelMCPURL.rawValue], raw.isEmpty {
            values[Key.parallelMCPURL.rawValue] = ""
        }

        var configuration = parse(values)
        // The file problem is reported first: it explains why other values may be missing.
        configuration.issues = issues + configuration.issues
        return configuration
    }

    /// Parse a resolved key/value map into a configuration. Kept pure so it can be
    /// unit tested without touching the process environment.
    public static func parse(_ values: [String: String]) -> AppConfiguration {
        var issues: [ConfigurationIssue] = []

        func record(_ kind: ConfigurationIssue.Kind, _ key: Key, _ detail: String) {
            issues.append(
                ConfigurationIssue(kind: kind, key: key.rawValue, detail: detail)
            )
        }

        func string(_ key: Key) -> String? {
            guard let raw = values[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty
            else { return nil }
            return raw
        }

        func int(_ key: Key) -> Int? {
            guard let raw = string(key) else { return nil }
            guard let value = Int(raw) else {
                record(.unparseableValue, key, "'\(raw)' is not a whole number")
                return nil
            }
            return value
        }

        func bool(_ key: Key) -> Bool? {
            guard let raw = string(key)?.lowercased() else { return nil }
            switch raw {
            case "1", "true", "yes", "on", "enabled": return true
            case "0", "false", "no", "off", "disabled": return false
            default:
                record(.unparseableValue, key, "'\(raw)' is not a yes/no value")
                return nil
            }
        }

        /// An absolute `http(s)` URL with a host.
        ///
        /// `URL(string:)` is not a validator — it accepts `searx.example.com` as a *relative*
        /// URL and returns nil for other typos — so a schemeless endpoint used to be accepted
        /// and then produced requests against a relative path.
        func url(_ key: Key) -> URL? {
            guard let raw = string(key) else { return nil }
            guard let parsed = URL(string: raw), let scheme = parsed.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                let host = parsed.host(), !host.isEmpty
            else {
                record(.invalidURL, key, "'\(raw)' is not an http(s) URL with a host")
                return nil
            }
            return parsed
        }

        var configuration = AppConfiguration()

        configuration.tavilyAPIKey = string(.tavilyAPIKey)
        configuration.braveAPIKey = string(.braveAPIKey)
        configuration.mojeekAPIKey = string(.mojeekAPIKey)
        configuration.exaAPIKey = string(.exaAPIKey)
        configuration.jinaAPIKey = string(.jinaAPIKey)
        configuration.searxngBaseURL = url(.searxngBaseURL)
        configuration.openWebSearchURL = url(.openWebSearchURL)

        // Answer synthesis is opt-in and entirely separate from provider selection:
        // setting a key must not change which providers search.
        configuration.deepSeekAPIKey = string(.deepSeekAPIKey)
        if let base = url(.deepSeekBaseURL) {
            configuration.deepSeekBaseURL = base
        }
        if let model = string(.deepSeekModel) {
            configuration.deepSeekModel = model
        }
        if let timeout = int(.synthesisTimeout), timeout > 0 {
            configuration.synthesisTimeout = .milliseconds(timeout)
        }
        if let reasoning = bool(.enableReasoning) {
            configuration.enableSynthesisReasoning = reasoning
        }

        if let parallel = url(.parallelMCPURL) {
            configuration.parallelMCPURL = parallel
        } else if values[Key.parallelMCPURL.rawValue]?.isEmpty == true {
            configuration.parallelMCPURL = nil
        }

        if let order = string(.providerOrder) {
            let parsed =
                order
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
                where !seen.contains(provider) {
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
        if let ms = int(.requestTimeout) {
            configuration.requestTimeout = .milliseconds(max(100, ms))
        }
        if let retries = int(.maxRetries) {
            configuration.maxRetryAttempts = min(max(0, retries), 5)
        }
        if let allowed = bool(.allowPrivateNetwork) {
            configuration.allowPrivateNetworkFetch = allowed
        }
        if let raw = string(.logLevel) {
            configuration.applyLogLevel(raw) { issues.append($0) }
        }
        if let enabled = bool(.logQueries) { configuration.logQueries = enabled }
        if let agent = string(.userAgent) { configuration.userAgent = agent }

        configuration.issues = issues
        return configuration
    }

    /// Apply `SEARCH_LOG_LEVEL`, reporting a value that is not one of the known levels.
    ///
    /// Separate from `parse` so the diagnostic does not add a branch to a function that is
    /// already at the complexity ratchet.
    private mutating func applyLogLevel(
        _ raw: String,
        reporting issue: (ConfigurationIssue) -> Void
    ) {
        if let level = LogLevel(rawValue: raw.lowercased()) {
            logLevel = level
        } else {
            issue(
                ConfigurationIssue(
                    kind: .unparseableValue,
                    key: Key.logLevel.rawValue,
                    detail: "'\(raw)' is not one of "
                        + LogLevel.allCases.map(\.rawValue).joined(separator: ", ")
                )
            )
        }
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
