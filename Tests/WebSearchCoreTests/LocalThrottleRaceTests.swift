import Foundation
import XCTest

@testable import WebSearchCore

/// The local-throttle boundary, made deterministic.
final class LocalThrottleRaceTests: XCTestCase {

    /// A single-provider search whose throttle clears between the orchestrator's two reads must
    /// still return results.
    ///
    /// The orchestrator reads the clock when `authorize` denies and again when it estimates the
    /// remaining wait. On a real clock the interval can elapse between those reads, so the
    /// estimate comes back nil — "available now" — and treating that as "cannot wait" returns the
    /// stale denial and loses the search. `CreepingClock` moves time 1 ms per read, so the
    /// boundary is crossed every run: after the priming acquire, the authorising read is 7 ms
    /// behind the interval and the wait-estimating read is 11 ms behind.
    func testALocalThrottleThatClearsBetweenReadsStillReturnsResults() async throws {
        let clock = CreepingClock(step: .milliseconds(1))
        let health = ProviderHealth(clock: clock)
        // Burst two and a fast refill keep the token bucket out of the way, so only the minimum
        // interval may refuse and the test exercises the boundary rather than the token estimate.
        await health.register(
            .tavily,
            ratePolicy: RateLimiter.Policy(
                burst: 2,
                requestsPerMinute: 600,
                minimumInterval: .milliseconds(8)
            )
        )
        // Spend one token and stamp `lastAcquire` immediately before the search.
        _ = await health.authorize(.tavily)

        let configuration = Fixtures.configuration(providerOrder: [.tavily])
        let tavily = MockSearchProvider.returning(
            .tavily,
            results: [("T", "https://t.example.com/1", nil)]
        )
        let orchestrator = SearchOrchestrator(
            registry: ProviderRegistry(providers: [tavily], configuration: configuration),
            health: health,
            cache: SearchCache(clock: clock),
            configuration: configuration,
            clock: clock
        )

        let response = try await orchestrator.search(Fixtures.request(mode: .fast))

        XCTAssertEqual(
            tavily.callCount,
            1,
            "the throttle had cleared, so the provider must be called"
        )
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.providersUsed, [.tavily])
        XCTAssertTrue(response.providersFailed.isEmpty)
    }

    /// The wait estimate must never be shorter than the true minimum-interval remainder.
    func testTimeUntilAvailableRoundsTheMinimumIntervalUp() async {
        let clock = TestClock()
        let limiter = RateLimiter(
            policy: .init(
                burst: 2,
                requestsPerMinute: 600,
                minimumInterval: .milliseconds(1_500)
            ),
            clock: clock
        )
        _ = await limiter.tryAcquire()
        // Half a millisecond short of the interval. Truncating this remainder yields
        // `.milliseconds(0)`, which tells a caller to retry before the threshold.
        clock.advance(by: .microseconds(1_499_500))

        let wait = await limiter.timeUntilAvailable()

        guard let wait else {
            return XCTFail("a 0.5 ms remainder must still be reported as a wait")
        }
        XCTAssertGreaterThanOrEqual(
            wait.seconds,
            0.0005,
            "a truncated estimate wakes before the interval, so the wait must round up"
        )
        XCTAssertGreaterThan(wait.milliseconds, 0)
    }

    /// An elapsed minimum interval is "available now": nil, never a zero-length wait.
    func testTimeUntilAvailableReturnsNilWhenTheMinimumIntervalHasElapsed() async {
        let clock = TestClock()
        let limiter = RateLimiter(
            policy: .init(
                burst: 2,
                requestsPerMinute: 600,
                minimumInterval: .milliseconds(1_500)
            ),
            clock: clock
        )
        _ = await limiter.tryAcquire()
        clock.advance(by: .milliseconds(1_500))

        let wait = await limiter.timeUntilAvailable()

        XCTAssertNil(wait, "an elapsed interval is available now, not a 0 ms wait")
    }
}
