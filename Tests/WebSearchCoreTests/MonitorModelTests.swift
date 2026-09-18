import Foundation
import XCTest

@testable import WebSearchCore

/// Metric accumulation.
final class MonitorModelTests: XCTestCase {

    func testNodeCountersAccumulateAcrossProbes() {
        var status = NodeStatus.pending(name: "node1", endpoint: "http://node1:8888")
        XCTAssertEqual(status.checks, 0)
        XCTAssertEqual(status.successRate, 0, "a node never probed has no success rate")

        // Two successes and one failure.
        status = status.applying(
            NodeProbe.Result(
                state: .up, latencyMilliseconds: 100, resultCount: 25,
                engines: ["brave"], unavailableEngines: [], error: nil)
        )
        status = status.applying(
            NodeProbe.Result(
                state: .up, latencyMilliseconds: 200, resultCount: 25,
                engines: ["brave"], unavailableEngines: [], error: nil)
        )
        status = status.applying(
            NodeProbe.Result(
                state: .down, latencyMilliseconds: nil, resultCount: 0,
                engines: [], unavailableEngines: [], error: "unreachable")
        )

        XCTAssertEqual(status.checks, 3)
        XCTAssertEqual(status.failures, 1)
        XCTAssertEqual(status.state, .down)
        XCTAssertEqual(status.successRate, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(status.latencyMilliseconds, nil)
        XCTAssertNotNil(status.lastSuccessAt)
    }

    func testProviderCountersAndAverageLatency() {
        var status = ProviderStatus.pending(provider: .tavily, configured: true, hint: "TAVILY_API_KEY")

        status = status.applying(.success(latencyMilliseconds: 1000, resultCount: 5))
        status = status.applying(.success(latencyMilliseconds: 3000, resultCount: 4))
        status = status.applying(.failure(error: "boom", category: .serverError, latencyMilliseconds: 500))

        XCTAssertEqual(status.probes, 3)
        XCTAssertEqual(status.successes, 2)
        XCTAssertEqual(status.failures, 1)
        XCTAssertEqual(status.state, .failing, "the most recent outcome decides the state")
        XCTAssertEqual(status.successRate, 2.0 / 3.0, accuracy: 0.0001)
        // Average is over successful probes only, so a slow failure cannot skew it.
        XCTAssertEqual(status.averageLatencyMilliseconds, 2000)
        XCTAssertEqual(status.lastError, "boom")
        XCTAssertEqual(status.lastErrorCategory, .serverError)
    }

    func testProviderRecoversAndShowsHealthyAgain() {
        var status = ProviderStatus.pending(provider: .tavily, configured: true, hint: "")
        status = status.applying(.failure(error: "down", category: .serverError))
        XCTAssertEqual(status.state, .failing)
        status = status.applying(.success(latencyMilliseconds: 800, resultCount: 5))
        XCTAssertEqual(status.state, .healthy)
        XCTAssertEqual(status.lastError, nil, "a recovery clears the stale error")
    }

    func testProviderKindClassification() {
        // The kind column explains why a provider is weighted the way it is.
        XCTAssertEqual(ProviderStatus.kind(of: .tavily), "index")
        XCTAssertEqual(ProviderStatus.kind(of: .brave), "index")
        XCTAssertEqual(ProviderStatus.kind(of: .duckDuckGo), "scraper")
        XCTAssertEqual(ProviderStatus.kind(of: .startpage), "scraper")
        XCTAssertEqual(ProviderStatus.kind(of: .searxng), "aggregator")
        XCTAssertEqual(ProviderStatus.kind(of: .parallel), "aggregator")
    }

    /// A provider the operator disabled is unavailable, not ready and not "no key": the two
    /// reasons a provider is inert are distinct, and only one of them is a credential
    /// problem.
    func testPendingProviderDistinguishesDisabledFromUnconfigured() {
        let ready = ProviderStatus.pending(
            provider: .tavily,
            configured: true,
            hint: "TAVILY_API_KEY"
        )
        XCTAssertEqual(ready.state, .configuredButIdle)
        XCTAssertEqual(ready.state.label, "IDLE")
        XCTAssertTrue(ready.isInService)

        let keyless = ProviderStatus.pending(
            provider: .tavily,
            configured: false,
            hint: "TAVILY_API_KEY"
        )
        XCTAssertEqual(keyless.state, .notConfigured)
        XCTAssertEqual(keyless.state.label, "NO KEY")
        XCTAssertFalse(keyless.isInService)

        let disabled = ProviderStatus.pending(
            provider: .tavily,
            configured: true,
            enabled: false,
            hint: "TAVILY_API_KEY"
        )
        XCTAssertEqual(disabled.state, .unavailable)
        XCTAssertEqual(disabled.state.label, "OFF")
        XCTAssertFalse(disabled.isInService, "a switched-off provider is not a failure to count")

        let disabledKeyless = ProviderStatus.pending(
            provider: .tavily,
            configured: false,
            enabled: false,
            hint: "TAVILY_API_KEY"
        )
        XCTAssertEqual(
            disabledKeyless.state, .unavailable,
            "being switched off is reported ahead of a missing credential"
        )
    }
}
