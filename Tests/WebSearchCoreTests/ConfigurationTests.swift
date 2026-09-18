import Foundation
import XCTest

@testable import WebSearchCore

/// Configuration parsing.
final class ConfigurationTests: XCTestCase {

    func testDefaultsStartWithNoCredentials() {
        let configuration = AppConfiguration.parse([:])
        XCTAssertNil(configuration.tavilyAPIKey)
        XCTAssertNil(configuration.braveAPIKey)
        XCTAssertNil(configuration.searxngBaseURL)
        XCTAssertEqual(configuration.defaultMaxResults, 8)
        // Every provider this server defines is on by default, including the ones that need no
        // credential. A provider that cannot serve a query fails over rather than failing the
        // search, so being on costs a request and never a result.
        XCTAssertTrue(configuration.enableScrapers)
        XCTAssertTrue(configuration.enableParallel)
        XCTAssertEqual(configuration.fastTimeout, .milliseconds(12_000))
        XCTAssertEqual(configuration.balancedTimeout, .milliseconds(15_000))
        XCTAssertEqual(configuration.thoroughTimeout, .milliseconds(20_000))
        // Synthesis is opt-in and must not be reachable without an explicit key.
        XCTAssertNil(configuration.deepSeekAPIKey)
    }

    /// Synthesis defaults exist so the tool works once a key is supplied, but they
    /// must never make it *configured*.
    func testSynthesisDefaultsAreInertWithoutAKey() {
        let configuration = AppConfiguration.parse([:])
        XCTAssertEqual(configuration.deepSeekModel, "deepseek-flash")
        XCTAssertEqual(
            configuration.deepSeekBaseURL?.absoluteString,
            "https://api.deepseek.com/v1"
        )
        XCTAssertEqual(configuration.synthesisTimeout, .seconds(45))
        // Off by default: with thinking on, the reasoning pass can consume the whole
        // output budget and return empty content.
        XCTAssertFalse(configuration.enableSynthesisReasoning)
    }

    func testReadsSynthesisEnvironmentVariables() {
        let configuration = AppConfiguration.parse([
            "DEEPSEEK_API_KEY": "sk-abc",
            "DEEPSEEK_BASE_URL": "https://api.example.com/v1",
            "DEEPSEEK_MODEL": "deepseek-v4-pro",
            "SEARCH_SYNTHESIS_TIMEOUT_MS": "90000",
            "SEARCH_SYNTHESIS_REASONING": "true",
        ])

        XCTAssertEqual(configuration.deepSeekAPIKey, "sk-abc")
        XCTAssertEqual(
            configuration.deepSeekBaseURL?.absoluteString,
            "https://api.example.com/v1"
        )
        XCTAssertEqual(configuration.deepSeekModel, "deepseek-v4-pro")
        XCTAssertEqual(configuration.synthesisTimeout, .seconds(90))
        XCTAssertTrue(configuration.enableSynthesisReasoning)
    }

    /// A key alone must not change which providers search: synthesis is layered on
    /// top of the provider pipeline, never part of it.
    func testSynthesisKeyDoesNotAlterProviderSelection() {
        let without = AppConfiguration.parse([:])
        let with = AppConfiguration.parse(["DEEPSEEK_API_KEY": "sk-abc"])

        XCTAssertEqual(without.providerOrder, with.providerOrder)
        XCTAssertEqual(without.providerEnabled, with.providerEnabled)
        XCTAssertEqual(without.defaultMaxResults, with.defaultMaxResults)
        XCTAssertFalse(with.providerOrder.contains { $0.rawValue.contains("deepseek") })
    }

    func testReadsAllDocumentedEnvironmentVariables() {
        let configuration = AppConfiguration.parse([
            "TAVILY_API_KEY": "tvly-abc",
            "BRAVE_SEARCH_API_KEY": "brave-abc",
            "MOJEEK_API_KEY": "mojeek-abc",
            "EXA_API_KEY": "exa-abc",
            "JINA_API_KEY": "jina-abc",
            "SEARXNG_BASE_URL": "https://searx.example.com",
            "OPEN_WEB_SEARCH_URL": "https://aggregate.example.com/search",
            "PARALLEL_MCP_URL": "https://parallel.example.com/mcp",
            "DEEPSEEK_API_KEY": "sk-deepseek-abc",
            "SEARCH_MAX_RESULTS": "5",
            "SEARCH_ENABLE_SCRAPERS": "true",
            "SEARCH_ENABLE_PARALLEL": "1",
            "SEARCH_ENABLE_JINA_READER": "false",
            "SEARCH_CACHE_TTL_SECONDS": "30",
            "SEARCH_FAST_TIMEOUT_MS": "4000",
            "SEARCH_BALANCED_TIMEOUT_MS": "5000",
            "SEARCH_THOROUGH_TIMEOUT_MS": "6000",
            "SEARCH_REQUEST_TIMEOUT_MS": "7000",
            "SEARCH_MAX_RETRIES": "4",
            "SEARCH_USER_AGENT": "TestAgent/9",
            "SEARCH_ALLOW_PRIVATE_NETWORK": "true",
            "SEARCH_LOG_LEVEL": "debug",
            "SEARCH_LOG_QUERIES": "true",
        ])

        XCTAssertEqual(configuration.tavilyAPIKey, "tvly-abc")
        XCTAssertEqual(configuration.braveAPIKey, "brave-abc")
        XCTAssertEqual(configuration.mojeekAPIKey, "mojeek-abc")
        XCTAssertEqual(configuration.exaAPIKey, "exa-abc")
        XCTAssertEqual(configuration.jinaAPIKey, "jina-abc")
        XCTAssertEqual(configuration.searxngBaseURL?.absoluteString, "https://searx.example.com")
        XCTAssertEqual(
            configuration.openWebSearchURL?.absoluteString,
            "https://aggregate.example.com/search"
        )
        XCTAssertEqual(
            configuration.parallelMCPURL?.absoluteString,
            "https://parallel.example.com/mcp"
        )
        XCTAssertEqual(configuration.deepSeekAPIKey, "sk-deepseek-abc")
        XCTAssertEqual(configuration.defaultMaxResults, 5)
        XCTAssertTrue(configuration.enableScrapers)
        XCTAssertTrue(configuration.enableParallel)
        XCTAssertFalse(configuration.enableJinaReaderFallback)
        XCTAssertEqual(configuration.cacheTTL, .seconds(30))
        XCTAssertEqual(configuration.fastTimeout, .milliseconds(4_000))
        XCTAssertEqual(configuration.balancedTimeout, .milliseconds(5_000))
        XCTAssertEqual(configuration.thoroughTimeout, .milliseconds(6_000))
        XCTAssertEqual(configuration.requestTimeout, .milliseconds(7_000))
        XCTAssertEqual(configuration.maxRetryAttempts, 4)
        XCTAssertEqual(configuration.userAgent, "TestAgent/9")
        XCTAssertTrue(configuration.allowPrivateNetworkFetch)
        XCTAssertEqual(configuration.logLevel, .debug)
        XCTAssertTrue(configuration.logQueries)
    }

    /// The default user agent carries the same version the server reports over MCP, because both are
    /// read from `BuildVersion`, which is generated from the repository's `VERSION` file
    /// (RELEASE.md §1.3 — one authoritative value, every other appearance a mirror).
    ///
    /// The default used to be a second, unconnected literal (`SwiftWebSearchMCP/1.0`), so it would
    /// have drifted silently on the next bump. Comparing the whole string means a re-hardcoded value
    /// on either side fails here rather than shipping.
    func testDefaultUserAgentTracksTheBuildVersion() {
        XCTAssertEqual(
            AppConfiguration().userAgent,
            "SwiftWebSearchMCP/\(BuildVersion.value) (+https://example.invalid/project)"
        )
    }

    /// There is deliberately no connect-timeout setting.
    ///
    /// The transport exposes no connect-only deadline, so the knob that used to exist was
    /// read by nothing and promised behaviour the client could not deliver. Pinned here so
    /// it cannot reappear without a way to honour it.
    func testThereIsNoConnectTimeoutSetting() {
        XCTAssertFalse(
            AppConfiguration.Key.allCases.contains { $0.rawValue == "SEARCH_CONNECT_TIMEOUT_MS" },
            "an inert setting must not be documented"
        )
        // An unknown key is ignored rather than fatal, and cannot change the timeout.
        let configuration = AppConfiguration.parse(["SEARCH_CONNECT_TIMEOUT_MS": "250"])
        XCTAssertEqual(configuration.requestTimeout, .seconds(10))
    }

    func testProviderOrderIsConfigurableAndKeepsAllProvidersReachable() {
        let configuration = AppConfiguration.parse([
            "SEARCH_PROVIDER_ORDER": "brave,tavily"
        ])
        XCTAssertEqual(configuration.providerOrder.first, .brave)
        XCTAssertEqual(configuration.providerOrder.dropFirst().first, .tavily)
        // Every search provider must still be present so an operator cannot
        // accidentally make one unreachable, and none may appear twice.
        XCTAssertEqual(Set(configuration.providerOrder), Set(ProviderID.allCases))
        XCTAssertEqual(configuration.providerOrder.count, ProviderID.allCases.count)
    }

    /// A repeated name in the operator's list must not survive into the order.
    ///
    /// `seen` was seeded from the parsed list while the list itself was kept intact, so
    /// `tavily,tavily,brave` produced two Tavily entries: `balanced` fanned out to Tavily twice and
    /// never to Brave, and fusion counted Tavily's results twice because its duplicate guard is per
    /// response. The neighbouring test only ever used a list without repeats, which is why nothing
    /// caught it.
    func testARepeatedProviderNameIsDeduplicated() {
        let configuration = AppConfiguration.parse([
            "SEARCH_PROVIDER_ORDER": "tavily,tavily,brave"
        ])
        XCTAssertEqual(Array(configuration.providerOrder.prefix(2)), [.tavily, .brave])
        XCTAssertEqual(configuration.providerOrder.count, ProviderID.allCases.count)
        XCTAssertEqual(Set(configuration.providerOrder), Set(ProviderID.allCases))
    }

    /// A rejected setting must not be echoed into the diagnostic that gets logged.
    ///
    /// `ConfigurationIssue.detail` promises it "never contains a credential", and this file carried
    /// that promise while interpolating the raw value at three sites. Four keys are URL-typed and
    /// may legitimately carry an embedded token, so a schemeless value with a token in its query —
    /// a realistic operator mistake — was rejected here and then logged verbatim by `main.swift`
    /// .
    func testARejectedValueIsNotEchoedIntoTheDiagnostic() {
        let secret = "s3cr3t-token-value"
        let configuration = AppConfiguration.parse([
            "OPEN_WEB_SEARCH_URL": "search.example.com/mcp?token=\(secret)"
        ])

        let details = configuration.issues.map(\.detail).joined(separator: " | ")
        XCTAssertFalse(details.contains(secret), "the value reached a loggable diagnostic: \(details)")
        XCTAssertFalse(details.contains("search.example.com"), details)
        // The key is still named, and the reason is still stated, which is what an operator needs.
        XCTAssertTrue(
            configuration.issues.contains { $0.key == "OPEN_WEB_SEARCH_URL" },
            "\(configuration.issues)"
        )
        XCTAssertTrue(details.contains("not an http(s) URL"), details)
    }

    func testDisabledProvidersAreParsed() {
        let configuration = AppConfiguration.parse([
            "SEARCH_DISABLED_PROVIDERS": "duckduckgo, startpage"
        ])
        XCTAssertEqual(configuration.providerEnabled[.duckDuckGo], false)
        XCTAssertEqual(configuration.providerEnabled[.startpage], false)
        XCTAssertNil(configuration.providerEnabled[.brave])
    }

    func testInvalidValuesFallBackToDefaults() {
        let configuration = AppConfiguration.parse([
            "SEARCH_MAX_RESULTS": "not-a-number",
            "SEARCH_CACHE_TTL_SECONDS": "-5",
            "SEARCH_LOG_LEVEL": "shout",
        ])
        XCTAssertEqual(configuration.defaultMaxResults, 8)
        XCTAssertEqual(configuration.cacheTTL, .seconds(0))
        XCTAssertEqual(configuration.logLevel, .info)
    }

    func testMaxResultsIsClamped() {
        XCTAssertEqual(AppConfiguration.parse(["SEARCH_MAX_RESULTS": "99"]).defaultMaxResults, 20)
        XCTAssertEqual(AppConfiguration.parse(["SEARCH_MAX_RESULTS": "0"]).defaultMaxResults, 1)
    }

    func testDotEnvParsingHandlesCommentsQuotesAndExport() {
        let parsed = AppConfiguration.parseDotEnv(
            """
            # a comment
            TAVILY_API_KEY=tvly-plain
            BRAVE_SEARCH_API_KEY="brave-quoted"
            export EXA_API_KEY='exa-single'

            SEARCH_MAX_RESULTS=3
            """
        )
        XCTAssertEqual(parsed["TAVILY_API_KEY"], "tvly-plain")
        XCTAssertEqual(parsed["BRAVE_SEARCH_API_KEY"], "brave-quoted")
        XCTAssertEqual(parsed["EXA_API_KEY"], "exa-single")
        XCTAssertEqual(parsed["SEARCH_MAX_RESULTS"], "3")
        XCTAssertNil(parsed["# a comment"])
    }

    /// Environment variables beat the config file, and the file fills what they are silent about.
    ///
    /// The previous version of this test merged a dictionary by hand and then called `parse`, so
    /// `load` — the function the server actually calls — was never executed with a file at all
    func testEnvironmentOverridesConfigFile() throws {
        let file = try writeTemporaryConfig(
            """
            SEARCH_MAX_RESULTS=3
            TAVILY_API_KEY=tvly-from-file
            """
        )
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let configuration = AppConfiguration.load(
            environment: ["SEARCH_MAX_RESULTS": "11"],
            configFileURL: file
        )

        XCTAssertEqual(configuration.defaultMaxResults, 11, "the environment must win")
        XCTAssertEqual(configuration.tavilyAPIKey, "tvly-from-file", "the file fills the rest")
        XCTAssertTrue(configuration.issues.isEmpty, "\(configuration.issues)")
    }

    /// `PARALLEL_MCP_URL=` is how an operator removes the built-in Parallel endpoint.
    ///
    /// The clearing branch in `parse` tests for a present-but-empty value, and `load` drops empty
    /// environment values, so it could never run: the documented-looking way to remove the default
    /// silently kept it.
    func testAnEmptyParallelMCPURLRemovesTheDefault() {
        XCTAssertNotNil(
            AppConfiguration.load(environment: [:], configFileURL: nil).parallelMCPURL,
            "the built-in default is present with no configuration"
        )
        XCTAssertNil(
            AppConfiguration.load(
                environment: ["PARALLEL_MCP_URL": ""],
                configFileURL: nil
            ).parallelMCPURL,
            "an explicitly empty value must clear the default"
        )
    }

    /// `SEARCH_CONFIG_FILE` is the documented way to point at a file, and `load` must read it.
    func testConfigFileNamedByTheEnvironmentIsLoaded() throws {
        let file = try writeTemporaryConfig("SEARCH_MAX_RESULTS=4")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let configuration = AppConfiguration.load(
            environment: ["SEARCH_CONFIG_FILE": file.path],
            configFileURL: nil
        )

        XCTAssertEqual(configuration.defaultMaxResults, 4)
        XCTAssertTrue(configuration.issues.isEmpty, "\(configuration.issues)")
    }

    /// A config file that was asked for and is missing is an issue, not "no config file".
    ///
    /// Nothing exercised the `load` path that produces it; the existing issue tests build the
    /// configuration from a dictionary.
    func testMissingConfigFileIsReportedAsAnIssue() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).env")

        let configuration = AppConfiguration.load(
            environment: ["SEARCH_CONFIG_FILE": missing.path],
            configFileURL: nil
        )

        XCTAssertTrue(
            configuration.issues.contains {
                $0.kind == .unreadableConfigFile && $0.key == AppConfiguration.Key.configFile.rawValue
            },
            "a missing file must be reported: \(configuration.issues)"
        )
    }

    /// A path that exists but cannot be read is reported too, never treated as an empty file.
    func testUnreadableConfigFileIsReportedAsAnIssue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = AppConfiguration.load(environment: [:], configFileURL: directory)

        XCTAssertTrue(
            configuration.issues.contains { $0.kind == .unreadableConfigFile },
            "an unreadable file must be reported: \(configuration.issues)"
        )
    }

    /// A unique temporary dotenv; the caller removes its directory.
    private func writeTemporaryConfig(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcps-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.env")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testUnknownProviderNamesInOrderAreIgnored() throws {
        let configuration = AppConfiguration.parse([
            "SEARCH_PROVIDER_ORDER": "brave,nonsense"
        ])
        XCTAssertEqual(configuration.providerOrder.first, .brave)
        XCTAssertFalse(configuration.providerOrder.contains { $0.rawValue == "nonsense" })
    }
    /// A typo used to be indistinguishable from "not configured": the value was dropped and the
    /// default applied with no diagnostic, which is how an operator ends up with no providers and
    /// no explanation.
    func testUnusableConfiguredValuesAreReported() throws {
        var environment = [
            "SEARCH_REQUEST_TIMEOUT_MS": "lots",
            "SEARCH_LOG_LEVEL": "verbose",
            "SEARCH_ENABLE_SCRAPERS": "maybe",
            "SEARXNG_BASE_URL": "searx.example.com",
        ]
        environment["SEARCH_CONFIG_FILE"] = "/definitely/not/here/config.env"

        let configuration = AppConfiguration.load(environment: environment)

        let byKey = Dictionary(
            grouping: configuration.issues,
            by: \.key
        ).mapValues { $0.map(\.kind) }
        XCTAssertEqual(byKey["SEARCH_CONFIG_FILE"], [.unreadableConfigFile])
        XCTAssertEqual(byKey["SEARCH_REQUEST_TIMEOUT_MS"], [.unparseableValue])
        XCTAssertEqual(byKey["SEARCH_LOG_LEVEL"], [.unparseableValue])
        XCTAssertEqual(byKey["SEARCH_ENABLE_SCRAPERS"], [.unparseableValue])
        XCTAssertEqual(byKey["SEARXNG_BASE_URL"], [.invalidURL])

        // The defaults are used, and the schemeless endpoint is *not* configured — which is the
        // part that matters: a relative URL must never reach a request.
        XCTAssertEqual(configuration.requestTimeout, AppConfiguration().requestTimeout)
        XCTAssertEqual(configuration.logLevel, AppConfiguration().logLevel)
        XCTAssertNil(configuration.searxngBaseURL)
        // The variable was unparseable, so the default applies — and the default is on.
        XCTAssertTrue(configuration.enableScrapers)
    }

    /// A value that is fine must not produce a complaint, and a schemeless URL must be the only
    /// thing rejected about an otherwise valid configuration.
    func testAValidConfigurationReportsNothing() throws {
        var environment = [
            "SEARCH_REQUEST_TIMEOUT_MS": "12000",
            "SEARCH_LOG_LEVEL": "debug",
            "SEARCH_ENABLE_SCRAPERS": "yes",
            "SEARXNG_BASE_URL": "http://127.0.0.1:8888",
        ]
        environment["TAVILY_API_KEY"] = Fixtures.syntheticDeepSeekKey

        let configuration = AppConfiguration.load(environment: environment)

        XCTAssertEqual(configuration.issues, [])
        XCTAssertEqual(configuration.requestTimeout, .milliseconds(12_000))
        XCTAssertEqual(configuration.logLevel, .debug)
        XCTAssertTrue(configuration.enableScrapers)
        XCTAssertEqual(configuration.searxngBaseURL?.absoluteString, "http://127.0.0.1:8888")
    }

    /// A requested-but-missing config file is reported by name; the environment still applies.
    func testAMissingConfigFileIsNamedInTheIssues() throws {
        let configuration = AppConfiguration.load(
            environment: [
                "SEARCH_CONFIG_FILE": "/definitely/not/here/config.env",
                "SEARCH_LOG_LEVEL": "warning",
            ]
        )
        XCTAssertEqual(configuration.issues.count, 1)
        let issue = try XCTUnwrap(configuration.issues.first)
        XCTAssertEqual(issue.kind, .unreadableConfigFile)
        XCTAssertTrue(issue.detail.contains("/definitely/not/here/config.env"), issue.detail)
        XCTAssertEqual(configuration.logLevel, .warning, "the environment still applies")
    }

}
