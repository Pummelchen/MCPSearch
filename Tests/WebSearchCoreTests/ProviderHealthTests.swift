import Foundation
import XCTest

@testable import WebSearchCore

/// Provider health: the breaker, the limiter and the counters that both the orchestrator
/// and `web_search_status` depend on.
///
/// Four invariants live here that used to hold only by luck of scheduling.
final class ProviderHealthTests: XCTestCase {

    /// A pipeline must enforce its limits the instant it is returned.
    ///
    /// Registration used to be fire-and-forget, so a request arriving before the detached
    /// task ran bypassed both the breaker and the rate limiter.
    func testFreshlyBuiltPipelineHasItsLimitsInstalled() async {
        var configuration = Fixtures.configuration(providerOrder: [.tavily])
        configuration.tavilyAPIKey = "tvly-test-key"

        let pipeline = SearchPipelineFactory.make(
            configuration: configuration,
            http: MockHTTPClient(),
            log: .disabled
        )

        // Inspected with no suspension in between: the limits must already exist.
        let state = await pipeline.health.state(for: .tavily, configured: true, enabled: true)
        XCTAssertEqual(state.rateLimit.burst, RateLimiter.Policy.apiDefault.burst)
        XCTAssertGreaterThan(state.rateLimit.burst, 0)

        // And the allowance is enforced from the very first request.
        var denials = 0
        for _ in 0..<(RateLimiter.Policy.apiDefault.burst + 1) {
            // `await` is not allowed in a `where` clause, so count without an `if`.
            let refusal = await pipeline.health.authorize(.tavily)
            denials += refusal == nil ? 0 : 1
        }
        XCTAssertEqual(denials, 1, "only the request past the burst allowance may be refused")
    }

    /// When a record call returns, the breaker has already observed it.
    func testOutcomesReachTheBreakerBeforeRecordReturns() async {
        let health = ProviderHealth(clock: TestClock())
        await health.register(.tavily)
        let failure = ProviderFailure(provider: .tavily, category: .timeout, message: "slow")

        await health.recordFailure(.tavily, failure: failure)
        await health.recordFailure(.tavily, failure: failure)
        var state = await health.state(for: .tavily, configured: true, enabled: true)
        XCTAssertEqual(state.circuit.consecutiveFailures, 2)

        await health.recordSuccess(.tavily, latencyMilliseconds: 10, resultCount: 3)
        state = await health.state(for: .tavily, configured: true, enabled: true)
        XCTAssertEqual(state.circuit.consecutiveFailures, 0)
        XCTAssertEqual(state.circuit.totalSuccesses, 1)
        XCTAssertEqual(state.failures, 2, "the counters still report the failures that happened")
    }

    /// A whole-search deadline is not a provider failure and must not open a breaker.
    ///
    /// The deadline is shared by every provider in the fan-out, so charging it to each of
    /// them opened breakers that no provider earned after a single slow search.
    func testDeadlineExceededDoesNotTripTheBreaker() async {
        let health = ProviderHealth(clock: TestClock())
        await health.register(.tavily)

        for _ in 0..<5 {
            await health.recordDeadlineExceeded(
                .tavily,
                message: "Tavily exceeded the search time budget."
            )
        }

        let state = await health.state(for: .tavily, configured: true, enabled: true)
        XCTAssertEqual(state.circuit.state, .closed)
        XCTAssertEqual(state.circuit.consecutiveFailures, 0)
        XCTAssertEqual(state.failures, 5, "the deadline is still reported to the operator")
        XCTAssertEqual(state.lastErrorCategory, .timeout)
    }

    /// A half-open breaker admits exactly one caller through `ProviderHealth`.
    ///
    /// `authorize` used to discard the breaker's refusal in the half-open state, so every
    /// caller arriving while the probe was in flight was let through: a provider recovering
    /// from failures took the whole fan-out instead of a single request. The refusal has to
    /// reach the orchestrator as the retryable `circuitOpen` failure the breaker intended.
    func testHalfOpenBreakerAdmitsExactlyOneCallerThroughProviderHealth() async {
        let clock = TestClock()
        let health = ProviderHealth(clock: clock)
        await health.register(
            .tavily,
            breakerPolicy: .init(failureThreshold: 1, cooldown: .seconds(30)),
            ratePolicy: .init(burst: 10, requestsPerMinute: 600)
        )

        await health.recordFailure(
            .tavily,
            failure: ProviderFailure(provider: .tavily, category: .network, message: "boom")
        )
        clock.advance(by: .seconds(31))

        let probe = await health.authorize(.tavily)
        XCTAssertNil(probe, "the first caller after the cooldown becomes the probe")

        let duringProbe = await health.authorize(.tavily)
        XCTAssertEqual(
            duringProbe?.category,
            .circuitOpen,
            "a second caller must not join the probe while it is in flight"
        )

        // The refusal must not wedge the provider: once the probe succeeds the breaker closes
        // and callers are admitted again.
        await health.recordSuccess(.tavily, latencyMilliseconds: 5, resultCount: 1)
        let afterRecovery = await health.authorize(.tavily)
        XCTAssertNil(afterRecovery, "a closed breaker admits callers again")
    }
}
