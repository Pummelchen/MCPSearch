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
        XCTAssertFalse(configuration.enableScrapers)
        XCTAssertEqual(configuration.fastTimeout, .milliseconds(12_000))
        XCTAssertEqual(configuration.balancedTimeout, .milliseconds(15_000))
        XCTAssertEqual(configuration.thoroughTimeout, .milliseconds(20_000))
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
            "SEARCH_MAX_RESULTS": "5",
            "SEARCH_ENABLE_SCRAPERS": "true",
            "SEARCH_ENABLE_PARALLEL": "1",
            "SEARCH_CACHE_TTL_SECONDS": "30",
            "SEARCH_LOG_LEVEL": "debug",
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
        XCTAssertEqual(configuration.defaultMaxResults, 5)
        XCTAssertTrue(configuration.enableScrapers)
        XCTAssertTrue(configuration.enableParallel)
        XCTAssertEqual(configuration.cacheTTL, .seconds(30))
        XCTAssertEqual(configuration.logLevel, .debug)
    }

    func testProviderOrderIsConfigurableAndKeepsAllProvidersReachable() {
        let configuration = AppConfiguration.parse([
            "SEARCH_PROVIDER_ORDER": "brave,tavily"
        ])
        XCTAssertEqual(configuration.providerOrder.first, .brave)
        XCTAssertEqual(configuration.providerOrder.dropFirst().first, .tavily)
        // Every search provider must still be present so an operator cannot
        // accidentally make one unreachable. `jina` is excluded because it is a
        // fetch/extraction provider that never serves search results.
        XCTAssertEqual(
            Set(configuration.providerOrder),
            Set(ProviderID.allCases.filter(\.isSearchProvider))
        )
        XCTAssertFalse(configuration.providerOrder.contains(.jina))
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

    func testEnvironmentOverridesConfigFile() {
        // Simulated by merging manually: file values first, environment second.
        var merged = AppConfiguration.parseDotEnv("SEARCH_MAX_RESULTS=3")
        merged["SEARCH_MAX_RESULTS"] = "11"
        XCTAssertEqual(AppConfiguration.parse(merged).defaultMaxResults, 11)
    }

    func testUnknownProviderNamesInOrderAreIgnored() {
        let configuration = AppConfiguration.parse([
            "SEARCH_PROVIDER_ORDER": "brave,nonsense"
        ])
        XCTAssertEqual(configuration.providerOrder.first, .brave)
        XCTAssertFalse(configuration.providerOrder.contains { $0.rawValue == "nonsense" })
    }
}

/// Timing utilities.
final class DurationTests: XCTestCase {
    func testSecondsConversion() {
        XCTAssertEqual(Duration.milliseconds(1500).seconds, 1.5, accuracy: 0.0001)
        XCTAssertEqual(Duration.seconds(2).milliseconds, 2000)
    }

    func testClockElapsedUsesNanoseconds() {
        let clock = SystemClock()
        let start = clock.uptimeNanoseconds()
        let elapsed = clock.elapsedMilliseconds(since: start)
        XCTAssertGreaterThanOrEqual(elapsed, 0)
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

    func testEscapeKeepsOutputOnOneLine() {
        XCTAssertEqual(Log.escape("a\nb\tc\"d\\e"), "a\\nb\\tc\\\"d\\\\e")
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
}
