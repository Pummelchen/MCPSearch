import Foundation
import XCTest

@testable import WebSearchCore

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

    func testScraperPolicyIsStricterThanAPIPolicy() throws {
        XCTAssertLessThan(RateLimiter.Policy.scraper.requestsPerMinute, RateLimiter.Policy.apiDefault.requestsPerMinute)
        XCTAssertNotNil(RateLimiter.Policy.scraper.minimumInterval)
        XCTAssertNil(RateLimiter.Policy.apiDefault.minimumInterval)
    }
}
