import Foundation
import XCTest

@testable import WebSearchCore

/// Rank fusion and deduplication.
///
/// These assertions encode the central reliability claim of the design: a result
/// found by two independent providers must outrank one found by a single provider,
/// and an aggregator must not double-count a source it merely resells.
final class RankFusionTests: XCTestCase {

    private func response(
        _ provider: ProviderID,
        _ entries: [(String, String)],
        upstream: [String] = []
    ) -> ProviderSearchResponse {
        var seen: Set<String> = []
        var results: [SearchResult] = []
        for (index, entry) in entries.enumerated() {
            if let result = ResultNormalizer.make(
                provider: provider,
                rank: index + 1,
                title: entry.0,
                urlString: entry.1,
                snippet: nil,
                request: Fixtures.request(),
                seenKeys: &seen
            ) {
                results.append(result)
            }
        }
        return ProviderSearchResponse(
            provider: provider,
            results: results,
            upstreamEngines: upstream
        )
    }

    func testDuplicateURLsCollapseIntoOneResultWithMergedProvenance() {
        let fused = RankFusion.fuse(
            responses: [
                response(.tavily, [("Shared", "https://example.com/shared")]),
                response(.brave, [("Shared", "https://example.com/shared?utm_source=x")]),
            ],
            limit: 10
        )
        XCTAssertEqual(fused.results.count, 1)
        XCTAssertEqual(Set(fused.results[0].sources), Set([.tavily, .brave]))
    }

    func testCorroboratedResultOutranksSingleProviderResult() {
        // Brave ranks "corroborated" second but Tavily also reports it first;
        // "solo" is Tavily's top hit but nobody else confirms it.
        let fused = RankFusion.fuse(
            responses: [
                response(.tavily, [
                    ("Solo", "https://solo.example.com/only"),
                    ("Corroborated", "https://both.example.com/page"),
                ]),
                response(.brave, [
                    ("Corroborated", "https://both.example.com/page"),
                    ("Other", "https://other.example.com/x"),
                ]),
            ],
            limit: 10
        )
        XCTAssertEqual(fused.results.first?.title, "Corroborated")
    }

    func testProviderRankIsTheBestRankAchieved() {
        let fused = RankFusion.fuse(
            responses: [
                response(.brave, [("Page", "https://example.com/p")]),
                response(.tavily, [
                    ("Filler", "https://example.com/filler"),
                    ("Filler2", "https://example.com/filler2"),
                    ("Page", "https://example.com/p"),
                ]),
            ],
            limit: 10
        )
        let page = fused.results.first { $0.url.path == "/p" }
        XCTAssertNotNil(page)
        // Brave returned it first, so the fused record must report rank 1.
        XCTAssertEqual(page?.providerRank, 1)
        XCTAssertEqual(page?.provider, .brave)
    }

    func testSameProviderListingDuplicateURLOnlyVotesOnce() {
        let duplicate = response(.tavily, [
            ("Page", "https://example.com/p"),
            ("Page again", "https://example.com/p?utm_source=x"),
        ])
        // The normalizer already drops the intra-provider duplicate.
        XCTAssertEqual(duplicate.results.count, 1)

        let fused = RankFusion.fuse(responses: [duplicate], limit: 10)
        let diagnostics = fused.diagnostics.first { $0.canonicalURL.path == "/p" }
        XCTAssertEqual(diagnostics?.providers, [.tavily])
    }

    func testAggregatorAloneIsDiscountedAgainstIndependentIndex() {
        // SearXNG is an aggregator; Brave is an independent index. Same URL from both
        // must not score as two independent confirmations.
        let fused = RankFusion.fuse(
            responses: [
                response(.brave, [("BraveOnly", "https://a.example.com/1")]),
                response(
                    .searxng,
                    [("BraveOnly", "https://a.example.com/1")],
                    upstream: ["brave"]
                ),
            ],
            limit: 10,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 0)
        )
        let diagnostics = fused.diagnostics.first { $0.canonicalURL.path == "/1" }
        XCTAssertNotNil(diagnostics)
        // One independent family (brave) plus the meta family: corroboration requires
        // two families, so this must not be flagged as independent corroboration.
        XCTAssertEqual(Set(diagnostics!.providers), Set([.brave, .searxng]))
    }

    func testTwoIndependentProvidersBothRankAboveAggregatorOnlyResult() {
        let fused = RankFusion.fuse(
            responses: [
                response(.tavily, [("Independent", "https://ind.example.com/x")]),
                response(.brave, [("Independent", "https://ind.example.com/x")]),
                response(.openWebSearch, [("Aggregated", "https://agg.example.com/y")]),
            ],
            limit: 10,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 0)
        )
        XCTAssertEqual(fused.results.first?.url.host(), "ind.example.com")
    }

    func testScrapersAreDownWeighted() {
        // DuckDuckGo is a scraper; Mojeek is an independent index. With equal ranks,
        // the independent index must win through the weight difference.
        let fused = RankFusion.fuse(
            responses: [
                response(.mojeek, [("Independent", "https://m.example.com/1")]),
                response(.duckDuckGo, [("Scraped", "https://d.example.com/2")]),
            ],
            limit: 10,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 0)
        )
        XCTAssertEqual(fused.results.first?.url.host(), "m.example.com")
    }

    func testLimitIsRespected() {
        // Distinct hosts, so the per-domain diversity cap cannot be what limits this.
        let entries = (1...10).map { ("Result \($0)", "https://host\($0).example.com/page") }
        let fused = RankFusion.fuse(responses: [response(.tavily, entries)], limit: 3)
        XCTAssertEqual(fused.results.count, 3)
    }

    func testPerDomainDiversityCapsSingleDomainResults() {
        let entries = (1...5).map { ("Result \($0)", "https://example.com/\($0)") }
        let fused = RankFusion.fuse(
            responses: [response(.tavily, entries)],
            limit: 5,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 2)
        )
        XCTAssertEqual(fused.results.count, 2, "one domain must not fill the whole result set")
    }

    func testDiversityCappingBackfillsFromOtherDomains() {
        let entries = [
            ("A1", "https://a.example.com/1"),
            ("A2", "https://a.example.com/2"),
            ("A3", "https://a.example.com/3"),
            ("B1", "https://b.example.com/1"),
        ]
        let fused = RankFusion.fuse(
            responses: [response(.tavily, entries)],
            limit: 3,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 2)
        )
        XCTAssertEqual(fused.results.count, 3)
        XCTAssertTrue(fused.results.contains { $0.url.host() == "b.example.com" })
    }

    func testEmptyInputProducesEmptyOutput() {
        let fused = RankFusion.fuse(responses: [], limit: 5)
        XCTAssertTrue(fused.results.isEmpty)
        XCTAssertTrue(fused.diagnostics.isEmpty)
    }

    func testFusionIsDeterministic() {
        let build = {
            RankFusion.fuse(
                responses: [
                    self.response(.tavily, [("A", "https://a.com/1"), ("B", "https://b.com/1")]),
                    self.response(.brave, [("B", "https://b.com/1"), ("C", "https://c.com/1")]),
                ],
                limit: 10
            ).results.map(\.url.absoluteString)
        }
        XCTAssertEqual(build(), build())
    }

    func testRichestSnippetAndEarliestDateArePreserved() {
        var seen: Set<String> = []
        let short = ResultNormalizer.make(
            provider: .tavily,
            rank: 1,
            title: "T",
            urlString: "https://example.com/p",
            snippet: "short",
            publishedAt: Date(timeIntervalSince1970: 2000),
            request: Fixtures.request(),
            seenKeys: &seen
        )!
        var seen2: Set<String> = []
        let rich = ResultNormalizer.make(
            provider: .brave,
            rank: 1,
            title: "T",
            urlString: "https://example.com/p",
            snippet: "a much longer and more informative snippet",
            publishedAt: Date(timeIntervalSince1970: 1000),
            request: Fixtures.request(),
            seenKeys: &seen2
        )!

        let fused = RankFusion.fuse(
            responses: [
                ProviderSearchResponse(provider: .tavily, results: [short]),
                ProviderSearchResponse(provider: .brave, results: [rich]),
            ],
            limit: 5
        )
        XCTAssertEqual(fused.results.count, 1)
        XCTAssertEqual(fused.results[0].snippet, "a much longer and more informative snippet")
        XCTAssertEqual(fused.results[0].publishedAt, Date(timeIntervalSince1970: 1000))
    }
}

/// Circuit breaker state machine.
final class CircuitBreakerTests: XCTestCase {

    func testStartsClosedAndAllowsRequests() async {
        let breaker = CircuitBreaker(clock: TestClock())
        let allowed = await breaker.shouldAttempt()
        XCTAssertTrue(allowed)
        let snapshot = await breaker.snapshot()
        XCTAssertEqual(snapshot.state, .closed)
    }

    func testOpensAfterThresholdConsecutiveTransientFailures() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            policy: .init(failureThreshold: 3, cooldown: .seconds(30)),
            clock: clock
        )
        for _ in 0..<3 {
            await breaker.recordFailure(category: .timeout, message: "timeout")
        }
        let snapshot = await breaker.snapshot()
        XCTAssertEqual(snapshot.state, .open)
        let allowed = await breaker.shouldAttempt()
        XCTAssertFalse(allowed, "an open breaker must skip the provider")
    }

    func testConfigurationFailuresDoNotOpenTheBreaker() async {
        let breaker = CircuitBreaker(
            policy: .init(failureThreshold: 1, cooldown: .seconds(30)),
            clock: TestClock()
        )
        // A bad key must keep reporting its real error rather than hiding behind an
        // open breaker.
        for _ in 0..<5 {
            await breaker.recordFailure(category: .authentication, message: "bad key")
        }
        let snapshot = await breaker.snapshot()
        XCTAssertEqual(snapshot.state, .closed)
        XCTAssertEqual(snapshot.consecutiveFailures, 0)
        XCTAssertEqual(snapshot.totalFailures, 5)
        XCTAssertEqual(snapshot.lastFailureCategory, .authentication)
    }

    func testHalfOpenAllowsExactlyOneProbeAfterCooldown() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            policy: .init(failureThreshold: 1, cooldown: .seconds(30)),
            clock: clock
        )
        await breaker.recordFailure(category: .network, message: "boom")
        var state = await breaker.snapshot()
        XCTAssertEqual(state.state, .open)

        clock.advance(by: .seconds(31))

        let firstProbe = await breaker.shouldAttempt()
        XCTAssertTrue(firstProbe)
        let secondProbe = await breaker.shouldAttempt()
        XCTAssertFalse(secondProbe, "only one probe may be in flight")

        state = await breaker.snapshot()
        XCTAssertEqual(state.state, .halfOpen)
    }

    func testSuccessfulProbeClosesTheBreaker() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            policy: .init(failureThreshold: 1, cooldown: .seconds(10)),
            clock: clock
        )
        await breaker.recordFailure(category: .serverError, message: "500")
        clock.advance(by: .seconds(11))
        _ = await breaker.shouldAttempt()
        await breaker.recordSuccess()

        let snapshot = await breaker.snapshot()
        XCTAssertEqual(snapshot.state, .closed)
        XCTAssertEqual(snapshot.consecutiveFailures, 0)
    }

    func testFailedProbeReopensWithFreshCooldown() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            policy: .init(failureThreshold: 1, cooldown: .seconds(10)),
            clock: clock
        )
        await breaker.recordFailure(category: .serverError, message: "500")
        clock.advance(by: .seconds(11))
        _ = await breaker.shouldAttempt()
        await breaker.recordFailure(category: .timeout, message: "still down")

        var snapshot = await breaker.snapshot()
        XCTAssertEqual(snapshot.state, .open)

        // The cooldown restarted, so it must still be open shortly afterwards.
        clock.advance(by: .seconds(5))
        let allowed = await breaker.shouldAttempt()
        XCTAssertFalse(allowed)
        snapshot = await breaker.snapshot()
        XCTAssertEqual(snapshot.state, .open)
    }

    func testSuccessResetsConsecutiveFailureCount() async {
        let breaker = CircuitBreaker(
            policy: .init(failureThreshold: 3, cooldown: .seconds(30)),
            clock: TestClock()
        )
        await breaker.recordFailure(category: .timeout, message: "1")
        await breaker.recordFailure(category: .timeout, message: "2")
        await breaker.recordSuccess()
        await breaker.recordFailure(category: .timeout, message: "3")

        let snapshot = await breaker.snapshot()
        // Two failures then a success then one failure is not three consecutive.
        XCTAssertEqual(snapshot.state, .closed)
        XCTAssertEqual(snapshot.consecutiveFailures, 1)
    }

    func testResetClearsEverything() async {
        let breaker = CircuitBreaker(
            policy: .init(failureThreshold: 1, cooldown: .seconds(30)),
            clock: TestClock()
        )
        await breaker.recordFailure(category: .timeout, message: "boom")
        await breaker.reset()
        let snapshot = await breaker.snapshot()
        XCTAssertEqual(snapshot.state, .closed)
        XCTAssertEqual(snapshot.totalFailures, 0)
        XCTAssertNil(snapshot.lastFailure)
    }
}

/// Rate limiter behaviour.
final class RateLimiterTests: XCTestCase {

    func testBurstIsConsumedThenDenied() async {
        let limiter = RateLimiter(
            policy: .init(burst: 2, requestsPerMinute: 60),
            clock: TestClock()
        )
        let first = await limiter.tryAcquire()
        let second = await limiter.tryAcquire()
        let third = await limiter.tryAcquire()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertFalse(third, "a burst of 2 must not allow a third immediate request")
    }

    func testTokensRefillOverTime() async {
        let clock = TestClock()
        let limiter = RateLimiter(
            policy: .init(burst: 1, requestsPerMinute: 60),
            clock: clock
        )
        let first = await limiter.tryAcquire()
        XCTAssertTrue(first)
        let second = await limiter.tryAcquire()
        XCTAssertFalse(second)
        // 60 requests/minute is one per second.
        clock.advance(by: .seconds(1))
        let third = await limiter.tryAcquire()
        XCTAssertTrue(third)
    }

    func testTimeUntilAvailableReportsAWait() async {
        let limiter = RateLimiter(
            policy: .init(burst: 1, requestsPerMinute: 60),
            clock: TestClock()
        )
        let immediately = await limiter.timeUntilAvailable()
        XCTAssertNil(immediately)
        _ = await limiter.tryAcquire()
        let wait = await limiter.timeUntilAvailable()
        XCTAssertNotNil(wait)
        XCTAssertGreaterThan(wait?.milliseconds ?? 0, 0)
    }

    func testMinimumIntervalEnforcesSpacing() async {
        let clock = TestClock()
        let limiter = RateLimiter(
            policy: .init(burst: 5, requestsPerMinute: 600, minimumInterval: .milliseconds(1500)),
            clock: clock
        )
        let first = await limiter.tryAcquire()
        XCTAssertTrue(first)
        let second = await limiter.tryAcquire()
        XCTAssertFalse(second, "minimum interval must gate back-to-back calls")
        clock.advance(by: .milliseconds(1600))
        let third = await limiter.tryAcquire()
        XCTAssertTrue(third)
    }

    func testScraperPolicyIsStricterThanAPIPolicy() {
        XCTAssertLessThan(RateLimiter.Policy.scraper.requestsPerMinute, RateLimiter.Policy.apiDefault.requestsPerMinute)
        XCTAssertNotNil(RateLimiter.Policy.scraper.minimumInterval)
        XCTAssertNil(RateLimiter.Policy.apiDefault.minimumInterval)
    }
}

/// Search cache behaviour.
final class SearchCacheTests: XCTestCase {

    private func makeResponse(_ query: String) -> SearchResponse {
        let result = SearchResult(
            title: "T",
            url: URL(string: "https://example.com/a")!,
            provider: .tavily,
            providerRank: 1
        )
        return SearchResponse(query: query, results: [result], providersUsed: [.tavily])
    }

    func testStoresAndRetrievesWithinTTL() async {
        let cache = SearchCache(clock: TestClock())
        let key = SearchCache.Key(request: Fixtures.request("swift"), providers: [.tavily])
        await cache.store(makeResponse("swift"), for: key, ttl: .seconds(60))

        let hit = await cache.get(key)
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit!.servedFromCache)
    }

    func testExpiresAfterTTL() async {
        let clock = TestClock()
        let cache = SearchCache(clock: clock)
        let key = SearchCache.Key(request: Fixtures.request("swift"), providers: [.tavily])
        await cache.store(makeResponse("swift"), for: key, ttl: .seconds(30))

        clock.advance(by: .seconds(31))
        let expired = await cache.get(key)
        XCTAssertNil(expired)
    }

    func testKeyIncludesModeFiltersAndProviderSet() {
        let base = SearchCache.Key(request: Fixtures.request("q", mode: .fast), providers: [.tavily])
        let otherMode = SearchCache.Key(
            request: Fixtures.request("q", mode: .thorough),
            providers: [.tavily]
        )
        let otherProviders = SearchCache.Key(
            request: Fixtures.request("q", mode: .fast),
            providers: [.brave]
        )
        var filtered = Fixtures.request("q", mode: .fast)
        filtered.excludeDomains = ["spam.example.com"]
        let otherFilters = SearchCache.Key(request: filtered, providers: [.tavily])

        XCTAssertNotEqual(base, otherMode)
        XCTAssertNotEqual(base, otherProviders)
        XCTAssertNotEqual(base, otherFilters)
    }

    func testKeyIgnoresResultCountOfTheProviderBudget() {
        var first = Fixtures.request("q")
        first.providerResultBudget = 8
        var second = Fixtures.request("q")
        second.providerResultBudget = 16
        // The provider fan-out budget must not change cache identity.
        XCTAssertEqual(
            SearchCache.Key(request: first, providers: [.tavily]),
            SearchCache.Key(request: second, providers: [.tavily])
        )
    }

    func testEmptyResponsesAreNotCached() async {
        let cache = SearchCache(clock: TestClock())
        let key = SearchCache.Key(request: Fixtures.request("nothing"), providers: [.tavily])
        let empty = SearchResponse(query: "nothing", results: [], providersUsed: [.tavily])
        await cache.store(empty, for: key, ttl: .seconds(60))
        let retrieved = await cache.get(key)
        XCTAssertNil(retrieved, "a transient empty result must not be pinned")
    }

    func testZeroTTLDisablesCaching() async {
        let cache = SearchCache(clock: TestClock())
        let key = SearchCache.Key(request: Fixtures.request("q"), providers: [.tavily])
        await cache.store(makeResponse("q"), for: key, ttl: .seconds(0))
        let retrieved = await cache.get(key)
        XCTAssertNil(retrieved)
    }

    func testStatsTrackHitsAndMisses() async {
        let cache = SearchCache(clock: TestClock())
        let key = SearchCache.Key(request: Fixtures.request("q"), providers: [.tavily])
        await cache.store(makeResponse("q"), for: key, ttl: .seconds(60))
        _ = await cache.get(key)
        _ = await cache.get(SearchCache.Key(digest: "absent"))

        let stats = await cache.stats()
        XCTAssertEqual(stats.hits, 1)
        XCTAssertEqual(stats.misses, 1)
    }

    func testCapacityEvictionKeepsCacheBounded() async {
        let cache = SearchCache(capacity: 8, clock: TestClock())
        for index in 0..<20 {
            let key = SearchCache.Key(
                request: Fixtures.request("query \(index)"),
                providers: [.tavily]
            )
            await cache.store(makeResponse("query \(index)"), for: key, ttl: .seconds(600))
        }
        let stats = await cache.stats()
        XCTAssertLessThanOrEqual(stats.entries, 8)
    }
}
