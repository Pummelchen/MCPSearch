import Foundation
import XCTest

@testable import WebSearchCore

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

    func testStoresAndRetrievesWithinTTL() async throws {
        let cache = SearchCache(clock: TestClock())
        let key = SearchCache.Key(request: Fixtures.request("swift"), providers: [.tavily])
        await cache.store(makeResponse("swift"), for: key, ttl: .seconds(60))

        let hit = await cache.get(key)
        XCTAssertNotNil(hit)
        XCTAssertTrue(try XCTUnwrap(hit).servedFromCache)
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

    /// The lazy sweep must not turn "expired" into "still counted".
    ///
    /// `stats().entries` counted only live entries before the sweep became lazy, and it still
    /// does: an entry whose deadline has passed makes the sweep due, so the count is taken after
    /// it is removed.
    func testStatsCountOnlyLiveEntries() async {
        let clock = TestClock()
        let cache = SearchCache(clock: clock)
        let shortKey = SearchCache.Key(request: Fixtures.request("short"), providers: [.tavily])
        let longKey = SearchCache.Key(request: Fixtures.request("long"), providers: [.tavily])
        await cache.store(makeResponse("short"), for: shortKey, ttl: .seconds(10))
        await cache.store(makeResponse("long"), for: longKey, ttl: .seconds(600))

        clock.advance(by: .seconds(20))

        let stats = await cache.stats()
        XCTAssertEqual(stats.entries, 1, "the expired entry must not be counted")
        let expired = await cache.get(shortKey)
        let live = await cache.get(longKey)
        XCTAssertNil(expired, "an expired entry must never be served")
        XCTAssertNotNil(live, "the live entry must survive the sweep")
    }

    /// Expired entries may linger until the next sweep, but they must not hold capacity hostage:
    /// a live store still evicts to the bound, and it must not evict a live entry to make room
    /// for itself while expired ones are still there.
    func testExpiredEntriesDoNotConsumeCapacity() async {
        let clock = TestClock()
        let cache = SearchCache(capacity: 8, clock: clock)
        for index in 0..<8 {
            let key = SearchCache.Key(request: Fixtures.request("old \(index)"), providers: [.tavily])
            await cache.store(makeResponse("old \(index)"), for: key, ttl: .seconds(10))
        }

        clock.advance(by: .seconds(11))

        let liveKey = SearchCache.Key(request: Fixtures.request("live"), providers: [.tavily])
        await cache.store(makeResponse("live"), for: liveKey, ttl: .seconds(600))

        let stats = await cache.stats()
        XCTAssertEqual(stats.entries, 1, "the eight expired entries must not count against capacity")
        let live = await cache.get(liveKey)
        XCTAssertNotNil(live)
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
