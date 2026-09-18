import Foundation
import XCTest

@testable import WebSearchCore

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
