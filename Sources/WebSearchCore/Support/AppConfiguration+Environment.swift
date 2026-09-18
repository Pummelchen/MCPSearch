import Foundation

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
    /// The operator's stated provider order, deduplicated, with every remaining provider appended
    /// so an operator cannot accidentally make one unreachable.
    ///
    /// Deduplicating the operator's own list matters as much as the appended defaults: a repeated
    /// name used to survive into the order, so the provider held two slots, `balanced` fanned out
    /// to it twice and never to a provider further down, and fusion counted its results twice
    /// because its duplicate guard is per response. `jina` is deliberately absent
    /// from `defaultProviderOrder`: it is a fetch provider and never participates in search.
    private static func resolvedProviderOrder(from raw: String) -> [ProviderID] {
        let parsed =
            raw
            .split(separator: ",")
            .compactMap { ProviderID(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
        guard !parsed.isEmpty else { return [] }

        // `insert` reports whether the element was new, so this deduplicates while preserving the
        // operator's stated order.
        var seen = Set<ProviderID>()
        var full: [ProviderID] = []
        for provider in parsed where seen.insert(provider).inserted {
            full.append(provider)
        }
        for provider in defaultProviderOrder where seen.insert(provider).inserted {
            full.append(provider)
        }
        return full
    }

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
                // The value is deliberately absent. `ConfigurationIssue.detail` promises it "never
                // contains a credential", and this file already carried that promise while
                // interpolating the raw value at three sites. Four keys are URL-typed and may carry
                // an embedded token — a schemeless `host/path?token=...` is rejected here and was
                // logged verbatim by `main.swift`. The key is named, which is what
                // an operator needs to fix it.
                record(.unparseableValue, key, "is not a whole number")
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
                record(.unparseableValue, key, "is not a yes/no value")
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
                record(.invalidURL, key, "is not an http(s) URL with a host")
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
            // Resolved in a helper: the dedup and the append loop are five branches that belong to
            // this question, not to the whole of `parse`, whose cyclomatic complexity the envelope
            // in.swiftlint.yml already sits against.
            let resolved = Self.resolvedProviderOrder(from: order)
            if !resolved.isEmpty { configuration.providerOrder = resolved }
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
