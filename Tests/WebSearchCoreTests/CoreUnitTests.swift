import Foundation
import XCTest

@testable import WebSearchCore

/// URL canonicalization and deduplication behaviour.
///
/// The canonical form is the deduplication key, so these tests are the contract that
/// keeps duplicate results from inflating confidence during fusion.
final class URLCanonicalizerTests: XCTestCase {

    func testLowercasesHostAndStripsFragment() {
        let canonical = URLCanonicalizer.canonicalize(
            URL(string: "https://Example.COM/Path/Page#section-3")!
        )
        XCTAssertEqual(canonical.absoluteString, "https://example.com/Path/Page")
    }

    func testRemovesTrackingParametersButKeepsIdentityParameters() {
        let url = URL(
            string: "https://example.com/a?id=42&utm_source=news&utm_campaign=x&gclid=abc&page=2&fbclid=z"
        )!
        let canonical = URLCanonicalizer.canonicalize(url)
        XCTAssertEqual(canonical.absoluteString, "https://example.com/a?id=42&page=2")
    }

    func testPreservesMeaningfulQueryParametersInOrder() {
        let url = URL(string: "https://example.com/search?q=swift&v=6.3&t=all")!
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(url).absoluteString,
            "https://example.com/search?q=swift&v=6.3&t=all"
        )
    }

    func testNormalizesDefaultPorts() {
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(URL(string: "https://example.com:443/x")!)
                .absoluteString,
            "https://example.com/x"
        )
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(URL(string: "http://example.com:80/x")!)
                .absoluteString,
            "http://example.com/x"
        )
        // A non-default port must survive: it can select a different resource.
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(URL(string: "https://example.com:8443/x")!)
                .absoluteString,
            "https://example.com:8443/x"
        )
    }

    func testNormalizesTrailingSlashAndEmptyPath() {
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(URL(string: "https://example.com/a/b/")!)
                .absoluteString,
            "https://example.com/a/b"
        )
        // Bare host and host-with-root-slash must agree.
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(URL(string: "https://example.com")!).absoluteString,
            URLCanonicalizer.canonicalize(URL(string: "https://example.com/")!).absoluteString
        )
    }

    func testNormalizesPercentEncodingCase() {
        let upper = URLCanonicalizer.canonicalize(URL(string: "https://example.com/a%7Eb")!)
        let plain = URLCanonicalizer.canonicalize(URL(string: "https://example.com/a~b")!)
        // `~` is unreserved, so both spellings must collapse to the same key.
        XCTAssertEqual(upper.absoluteString, plain.absoluteString)
    }

    func testStripsUserInfoSoCredentialsNeverReachDedupKeys() {
        let canonical = URLCanonicalizer.canonicalize(
            URL(string: "https://user:secret@example.com/page")!
        )
        XCTAssertEqual(canonical.absoluteString, "https://example.com/page")
    }

    func testLeavesNonHTTPURLsAlone() {
        let fileURL = URL(string: "file:///tmp/secret.txt")!
        XCTAssertEqual(URLCanonicalizer.canonicalize(fileURL), fileURL)
    }

    func testDeduplicatesEquivalentURLs() {
        let variants = [
            "https://Example.com/Article?utm_source=a#top",
            "https://example.com/Article/",
            "http://example.com:80/Article",
            "https://example.com/Article?utm_medium=b",
        ]
        let keys = Set(variants.map { URLCanonicalizer.key(for: URL(string: $0)!) })
        // The http/https pair legitimately differs; everything else must collapse.
        XCTAssertEqual(keys.count, 2, "expected http and https to remain distinct: \(keys)")
    }

    func testDoesNotCollapseDifferentResources() {
        let a = URLCanonicalizer.key(for: URL(string: "https://example.com/a")!)
        let b = URLCanonicalizer.key(for: URL(string: "https://example.com/b")!)
        let c = URLCanonicalizer.key(for: URL(string: "https://other.com/a")!)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: Domain matching

    func testNormalizeDomainHandlesCommonSpellings() {
        XCTAssertEqual(URLCanonicalizer.normalizeDomain("WWW.Example.COM"), "example.com")
        XCTAssertEqual(URLCanonicalizer.normalizeDomain("*.example.com"), "example.com")
        XCTAssertEqual(URLCanonicalizer.normalizeDomain(".example.com"), "example.com")
        XCTAssertEqual(URLCanonicalizer.normalizeDomain("example.com."), "example.com")
        XCTAssertEqual(URLCanonicalizer.normalizeDomain("https://www.example.com/path"), "example.com")
    }

    func testHostMatchesDomainRespectsSubdomainBoundaries() {
        XCTAssertTrue(URLCanonicalizer.host("example.com", matchesDomain: "example.com"))
        XCTAssertTrue(URLCanonicalizer.host("docs.example.com", matchesDomain: "example.com"))
        XCTAssertTrue(URLCanonicalizer.host("docs.example.com", matchesDomain: "www.example.com"))
        // A suffix match must not treat a different registrable domain as included.
        XCTAssertFalse(URLCanonicalizer.host("notexample.com", matchesDomain: "example.com"))
        XCTAssertFalse(URLCanonicalizer.host("example.com.evil.net", matchesDomain: "example.com"))
    }
}

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
    /// caught it (ledger A0034).
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
    /// (ledger A0033).
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

    func testUnknownProviderNamesInOrderAreIgnored() {
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

/// The one authority for "which variable enables me".
final class ProviderEnablementTests: XCTestCase {

    /// Every provider states at least one requirement, and every requirement is an environment
    /// variable `AppConfiguration.Key` already knows about. The `inputs(for:)` switch is
    /// exhaustive, so a new `ProviderID` cannot compile without an entry; this pins that the
    /// entry is not empty and that its name is a real key.
    func testEveryProviderNamesAtLeastOneKnownVariable() {
        let known = Set(AppConfiguration.Key.allCases.map(\.rawValue))
        for id in ProviderID.allCases {
            let inputs = ProviderEnablement.inputs(for: id)
            XCTAssertFalse(inputs.isEmpty, "\(id.rawValue) declares no enablement requirements")
            for input in inputs {
                XCTAssertTrue(
                    known.contains(input.variableName),
                    "\(id.rawValue) names \(input.variableName), which is not an AppConfiguration.Key"
                )
            }
        }
    }

    /// Parallel is the provider that needs two inputs, in the order an operator supplies them:
    /// the switch first, then the endpoint it gates.
    func testParallelRequiresTheFlagAndThenTheEndpoint() {
        XCTAssertEqual(
            ProviderEnablement.inputs(for: .parallel),
            [.parallelEnabled, .parallelEndpoint]
        )
        for id in ProviderID.allCases where id != .parallel {
            XCTAssertEqual(
                ProviderEnablement.inputs(for: id).count, 1,
                "\(id.rawValue) is expected to need exactly one input"
            )
        }
    }

    /// The startup inventory and the "no provider is configured" error read one list,
    /// deduplicated in provider order: the two scrapers share a switch, and Parallel
    /// contributes two inputs.
    func testAllInputsAreDeduplicatedInProviderOrder() {
        let names = ProviderEnablement.allInputs.map(\.variableName)
        XCTAssertEqual(Set(names).count, names.count, "a variable is named twice: \(names)")
        XCTAssertEqual(
            names,
            [
                "TAVILY_API_KEY", "BRAVE_SEARCH_API_KEY", "MOJEEK_API_KEY", "EXA_API_KEY",
                "SEARXNG_BASE_URL", "OPEN_WEB_SEARCH_URL", "SEARCH_ENABLE_SCRAPERS",
                "SEARCH_ENABLE_PARALLEL", "PARALLEL_MCP_URL",
            ]
        )
    }

    /// The drift the finding records: with the flag on and the endpoint absent, the operator
    /// must be told about `PARALLEL_MCP_URL` — advice they have not taken — rather than the
    /// flag they already set.
    func testTheParallelInstructionNamesTheEndpointWhenTheFlagIsOn() {
        var configuration = Fixtures.configuration(enableParallel: true)
        configuration.parallelMCPURL = nil

        XCTAssertEqual(
            ProviderEnablement.missingInputs(for: .parallel, in: configuration),
            [.parallelEndpoint]
        )
        let instruction = ProviderEnablement.instruction(for: .parallel, in: configuration)
        XCTAssertTrue(instruction.contains("PARALLEL_MCP_URL"), instruction)
        XCTAssertFalse(
            instruction.contains("SEARCH_ENABLE_PARALLEL"),
            "the flag is already on, so naming it is not actionable: \(instruction)"
        )
        XCTAssertEqual(instruction, "Set PARALLEL_MCP_URL to the upstream MCP endpoint.")
    }

    func testBothParallelInputsAreNamedWhenNeitherIsPresent() {
        var configuration = Fixtures.configuration(enableParallel: false)
        configuration.parallelMCPURL = nil

        XCTAssertEqual(
            ProviderEnablement.inputsToName(for: .parallel, in: configuration),
            [.parallelEnabled, .parallelEndpoint]
        )
        XCTAssertEqual(
            ProviderEnablement.assignmentList(for: .parallel, in: configuration),
            "SEARCH_ENABLE_PARALLEL=true and PARALLEL_MCP_URL"
        )
    }

    /// Satisfaction is per input, so a provider is usable only when the whole set is present.
    func testSatisfactionTracksEveryInput() {
        var configuration = Fixtures.configuration(enableScrapers: false, enableParallel: true)
        XCTAssertTrue(ProviderEnablement.isSatisfied(.tavily, in: configuration) == false)
        XCTAssertEqual(
            ProviderEnablement.missingInputs(for: .tavily, in: configuration),
            [.tavilyAPIKey]
        )

        configuration.tavilyAPIKey = "tvly-test-key-000000000000"
        XCTAssertTrue(ProviderEnablement.isSatisfied(.tavily, in: configuration))
        // An empty string is not a credential.
        configuration.tavilyAPIKey = ""
        XCTAssertFalse(ProviderEnablement.isSatisfied(.tavily, in: configuration))

        configuration.enableScrapers = true
        XCTAssertTrue(ProviderEnablement.isSatisfied(.duckDuckGo, in: configuration))
        // Parallel has the flag on and the default endpoint present.
        XCTAssertTrue(ProviderEnablement.isSatisfied(.parallel, in: configuration))
    }

    /// The SearXNG guidance survives the consolidation, because naming the variable alone is
    /// the deployment mistake that keeps biting operators.
    func testTheSearxngInstructionKeepsItsJSONGuidance() {
        let configuration = Fixtures.configuration()
        XCTAssertEqual(
            ProviderEnablement.instruction(for: .searxng, in: configuration),
            "Set SEARXNG_BASE_URL to an instance with JSON output enabled."
        )
    }

    /// The status tool, the factory's own notes and the monitor's hint are the same authority
    /// read three times, so all three give the endpoint for this configuration.
    func testTheStatusToolAndTheMonitorHintAgreeForParallel() async {
        var configuration = Fixtures.configuration(enableParallel: true)
        configuration.parallelMCPURL = nil
        let pipeline = SearchPipelineFactory.make(
            configuration: configuration,
            http: MockHTTPClient()
        )
        let expected = ProviderEnablement.instruction(for: .parallel, in: configuration)

        // `web_search_status` overlays the registry's ineligible reason onto the health note,
        // so this is the string an operator actually sees.
        let states = await pipeline.orchestrator.status()
        let parallel = states.first { $0.provider == .parallel }
        XCTAssertEqual(parallel?.note, expected, "web_search_status must give actionable advice")
        XCTAssertTrue(parallel?.note?.contains("PARALLEL_MCP_URL") ?? false, parallel?.note ?? "")

        // The factory's own note (what `ProviderHealth` stores) is derived from the same call.
        let healthNote = await pipeline.health.state(
            for: .parallel,
            configured: pipeline.registry.isConfigured(.parallel),
            enabled: pipeline.registry.isEnabled(.parallel)
        ).note
        XCTAssertEqual(healthNote, expected)

        let probe = ProviderProbe(registry: pipeline.registry, configuration: configuration)
        XCTAssertEqual(probe.setupHint(for: .parallel), "PARALLEL_MCP_URL")
    }
}

/// Timing utilities.
final class DurationTests: XCTestCase {
    func testSecondsConversion() {
        XCTAssertEqual(Duration.milliseconds(1500).seconds, 1.5, accuracy: 0.0001)
        XCTAssertEqual(Duration.seconds(2).milliseconds, 2000)
    }

    /// The nanosecond-to-millisecond conversion, driven by a clock we control.
    ///
    /// The old version measured the real clock immediately after starting it and asserted the
    /// result was non-negative — a division of an unsigned delta, which no implementation of that
    /// signature can violate. The name promised nanosecond handling that was never exercised
    func testElapsedMillisecondsConvertsANanosecondDelta() {
        let clock = TestClock()
        let start = clock.uptimeNanoseconds()
        XCTAssertEqual(clock.elapsedMilliseconds(since: start), 0, "no time has passed")

        clock.advance(by: .milliseconds(1_500))
        XCTAssertEqual(clock.elapsedMilliseconds(since: start), 1_500)

        // Sub-second remainders are truncated, not rounded up.
        clock.advance(by: .milliseconds(400))
        XCTAssertEqual(clock.elapsedMilliseconds(since: start), 1_900)
    }

    func testTestClockAdvances() {
        let clock = TestClock()
        let before = clock.now()
        clock.advance(by: .seconds(45))
        XCTAssertEqual(clock.now().timeIntervalSince(before), 45, accuracy: 0.001)
    }

    func testRetryAfterParsesSecondsAndHTTPDate() {
        XCTAssertEqual(RetryAfter.parse("2")?.milliseconds, 2000)
        XCTAssertNil(RetryAfter.parse(nil))
        XCTAssertNil(RetryAfter.parse("not-a-date"))
        // An HTTP-date in the past must clamp to zero rather than go negative.
        let past = RetryAfter.parse("Wed, 21 Oct 2015 07:28:00 GMT")
        XCTAssertEqual(past?.milliseconds, 0)
    }

    /// `Retry-After` comes from an upstream response, so it is untrusted input. A value large
    /// enough to overflow `Int` used to trap the process in `Int(seconds * 1000)`:
    /// `Retry-After: 1e30` from any provider, or from a rate-limited Jina response, killed every
    /// connected client. Finite values are clamped, non-finite ones are treated as absent so the
    /// caller falls back to its own backoff.
    func testRetryAfterBoundsHostileValuesInsteadOfTrapping() {
        XCTAssertEqual(RetryAfter.parse("1e30")?.milliseconds, 86_400_000)
        XCTAssertEqual(RetryAfter.parse("\(RetryAfter.maximumSeconds * 2)")?.milliseconds, 86_400_000)
        XCTAssertNil(RetryAfter.parse("inf"))
        XCTAssertNil(RetryAfter.parse("-inf"))
        XCTAssertNil(RetryAfter.parse("nan"))
        // A negative delta was already clamped to zero; it must stay there.
        XCTAssertEqual(RetryAfter.parse("-5")?.milliseconds, 0)
        // The ordinary case is unchanged.
        XCTAssertEqual(RetryAfter.parse("7")?.milliseconds, 7000)
    }

    func testJinaRetryAfterBodyIsBoundedByTheSameRule() {
        XCTAssertNil(JinaReaderFetcher.retryAfterFromBody(Data(#"{"retryAfter": "soon"}"#.utf8)))
        XCTAssertNil(JinaReaderFetcher.retryAfterFromBody(Data(#"{"retryAfter": null}"#.utf8)))
        XCTAssertEqual(
            JinaReaderFetcher.retryAfterFromBody(Data(#"{"retryAfter": 1e33}"#.utf8))?.milliseconds,
            86_400_000
        )
        XCTAssertEqual(
            JinaReaderFetcher.retryAfterFromBody(Data(#"{"retryAfter": 3}"#.utf8))?.milliseconds,
            3000
        )
    }
}

/// Logging must never contaminate stdout.
final class LoggingTests: XCTestCase {
    func testQueryIsHashedByDefault() {
        let log = Log(level: .debug, logQueries: false) { _ in }
        let description = log.queryDescription("my secret search terms")
        XCTAssertFalse(description.contains("secret"))
        XCTAssertTrue(description.hasPrefix("q"))
    }

    func testHashIsStableAndNotReversible() {
        XCTAssertEqual(Log.hash("same"), Log.hash("same"))
        XCTAssertNotEqual(Log.hash("a"), Log.hash("b"))
        XCTAssertFalse(Log.hash("query").contains("query"))
    }

    /// The digest must be keyed, not the public FNV-1a it used to be.
    ///
    /// The old value was recomputable by anyone: a log reader could hash a candidate query with
    /// the same public algorithm and confirm it, so the "non-reversible" doc claim was false.
    /// These are the exact FNV-1a outputs the defective function produced, computed independently
    /// of the Swift code; a keyed digest must not reproduce them.
    func testHashIsNotTheUnkeyedFNV1aDigest() {
        let knownFNV1a = [
            "swift concurrency": "q13a54df77317abdf",
            "my secret search terms": "qcdc8b5bd8d3de1dc",
            "query": "qb1068f146c4596c3",
        ]
        for (query, digest) in knownFNV1a {
            XCTAssertNotEqual(
                Log.hash(query),
                digest,
                "hash(\(query)) reproduces the unkeyed FNV-1a digest"
            )
        }
    }

    func testEscapeKeepsOutputOnOneLine() {
        XCTAssertEqual(Log.escape("a\nb\tc\"d\\e"), "a\\nb\\tc\\\"d\\\\e")
    }

    /// A value must not be able to drive the terminal through a diagnostic.
    ///
    /// Keeping the line intact is not enough: `ESC[2J` and the C1 range were passed through, so a
    /// query could clear the screen or move the cursor of whoever was reading stderr.
    func testEscapeMakesControlCharactersInert() {
        let hostile = "q\u{1B}[2J\u{07}\u{9B}31m\u{200B}"
        let escaped = Log.escape(hostile)
        XCTAssertEqual(escaped, "q\\u{1B}[2J\\u{07}\\u{9B}31m\\u{200B}")
        XCTAssertFalse(
            escaped.unicodeScalars.contains {
                $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
            },
            "no control or format scalar may survive: \(escaped.debugDescription)"
        )
    }

    func testLogRespectsLevelThreshold() {
        nonisolated(unsafe) var lines: [String] = []
        let lock = NSLock()
        let log = Log(level: .warning) { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        log.debug("debug message")
        log.info("info message")
        log.warning("warning message")
        lock.lock()
        let captured = lines
        lock.unlock()

        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].contains("warning message"))
    }

    func testDisabledLogEmitsNothing() {
        nonisolated(unsafe) var count = 0
        let log = Log(level: .none) { _ in count += 1 }
        log.error("should not appear")
        XCTAssertEqual(count, 0)
    }

    // MARK: Standard-error queue

    /// The default sink frames each event and hands it to the queue; it must not write to fd 2
    /// itself, because that write is what blocked the logging task.
    func testTheDefaultSinkRoutesFramedLinesThroughTheQueue() {
        nonisolated(unsafe) var written: [String] = []
        let lock = NSLock()
        let queue = StderrQueue(limit: 8) { line in
            lock.lock()
            written.append(line)
            lock.unlock()
        }
        defer { queue.finish() }

        let sink = Log.makeStandardErrorSink(queue: queue)
        sink("first")
        sink("second")
        XCTAssertTrue(queue.flush(), "the queue must drain")

        lock.lock()
        let captured = written
        lock.unlock()
        XCTAssertEqual(captured, ["first\n", "second\n"], "one framed line per call, in order")
    }

    /// A full queue drops the newest line rather than blocking the caller or growing without
    /// bound, and the lines it does write keep their order.
    ///
    /// The writer is parked inside the injected writer closure, which is what makes this
    /// deterministic: `submit` must return while the consumer is stopped, and the drop counter is
    /// observed directly instead of being timed.
    func testAFullQueueDropsInsteadOfBlockingTheCaller() {
        nonisolated(unsafe) var written: [String] = []
        let lock = NSLock()
        let took = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let queue = StderrQueue(limit: 2) { line in
            took.signal()
            release.wait()
            lock.lock()
            written.append(line)
            lock.unlock()
        }
        defer {
            queue.finish()
            for _ in 0..<4 { release.signal() }
        }

        queue.submit("one\n")
        // Wait until the writer holds "one" and is parked, so only the queue's two slots remain.
        XCTAssertEqual(took.wait(timeout: .now() + 5), .success, "the writer thread must start")

        queue.submit("two\n")
        queue.submit("three\n")
        // Full and stopped: this call must return, not wait for the writer.
        queue.submit("four\n")
        XCTAssertEqual(queue.droppedLines, 1, "a full queue must drop the newest line")

        // Release the writer for the drop note, for "two" and for "three"; the last release lets
        // "three" finish, and `flush` then waits for that write rather than for the queue to
        // empty.
        for _ in 0..<3 {
            release.signal()
            XCTAssertEqual(took.wait(timeout: .now() + 5), .success, "the writer must continue")
        }
        release.signal()
        XCTAssertTrue(queue.flush(), "the writer must drain once it is released")

        lock.lock()
        let captured = written
        lock.unlock()
        let dropped = captured.filter { $0.contains("dropped 1 log lines") }
        XCTAssertEqual(dropped.count, 1, "the gap must be reported once: \(captured)")
        XCTAssertEqual(
            captured.filter { !$0.contains("dropped 1 log lines") },
            ["one\n", "two\n", "three\n"],
            "order and framing must survive the queue"
        )
    }
}
