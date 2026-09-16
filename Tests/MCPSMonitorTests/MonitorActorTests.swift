import Foundation
import WebSearchCore
import XCTest

@testable import MCPSMonitor

/// The `Monitor` actor's refresh cycle.
///
/// `init(options:)` builds a live `URLSession` client and reads this machine's environment, so
/// every probe it makes is against whatever the operator happens to have running (usually
/// nothing) and every result is the same "unreachable". These tests take the seam
/// `Monitor.init(options:configuration:http:log:)` instead, so the transport is scripted and the
/// assertion is about the actor's own logic: the probe gate, the counter folding and the warning
/// aggregation.
final class MonitorActorTests: XCTestCase {

    // MARK: - Fixtures

    /// Scripted JSON per SearXNG endpoint.
    private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: String]
        private let fallback: String

        init(handlers: [String: String], fallback: String = #"{"results":[]}"#) {
            self.handlers = handlers
            self.fallback = fallback
        }

        func send(_ request: HTTPRequest, maxBytes: Int) async throws -> HTTPResponse {
            let key = request.url.absoluteString
            let body = lock.withLock { handlers[key] ?? fallback }
            return HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(body.utf8),
                url: request.url
            )
        }
    }

    private static let key = "sk-000000000000000000000000"

    /// A configuration with one keyed provider, so `probeableTargets` has exactly one entry.
    private func configuration() -> AppConfiguration {
        AppConfiguration(
            tavilyAPIKey: Self.key,
            providerOrder: [.tavily, .brave],
            enableScrapers: false,
            enableParallel: false
        )
    }

    private func target(_ name: String, _ port: Int) -> NodeProbe.Target {
        NodeProbe.Target(
            name: name,
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            isLocal: port == 1111
        )
    }

    private func endpoint(_ port: Int) -> String {
        "http://127.0.0.1:\(port)/search?q=swift%20concurrency&format=json"
    }

    private func options(nodes: [NodeProbe.Target], probeProviders: Bool) -> Options {
        Options(
            nodes: nodes,
            interval: .seconds(10),
            probeProviders: probeProviders,
            useColour: false,
            showEngines: true,
            iterations: 1,
            probeQueries: ProbeQueries()
        )
    }

    /// A 200 body with one result is `.up`; an empty result list is `.degraded`.
    private func payload(up: Bool, unavailable: String) -> String {
        let engines = up ? #"{"engine":"google"}"# : ""
        return #"{"results":[\#(engines)],"unresponsive_engines":[\#(unavailable)]}"#
    }

    // MARK: - Probe gating

    /// The dashboard populates on the first refresh, and a later unattended refresh must not
    /// spend a provider credit. Node health is still checked, because that is free — only the
    /// provider probe is gated, which is what the contract `Options.shouldProbeProviders` states.
    func testTheFirstRefreshProbesProvidersAndALaterOneDoesNot() async {
        let monitor = Monitor(
            options: options(nodes: [target("this-mac", 1111)], probeProviders: false),
            configuration: configuration(),
            http: StubHTTPClient(handlers: [endpoint(1111): payload(up: true, unavailable: "")]),
            log: .disabled
        )

        let first = await monitor.refresh(forceProbeProviders: false)
        let second = await monitor.refresh(forceProbeProviders: false)

        let firstTavily = first.providers.first { $0.provider == .tavily }
        let secondTavily = second.providers.first { $0.provider == .tavily }
        XCTAssertEqual(firstTavily?.probes, 1, "the first pass populates the dashboard")
        XCTAssertEqual(firstTavily?.state, .healthy)
        XCTAssertEqual(
            secondTavily?.probes, 1,
            "an unattended refresh must not spend a second credit"
        )
        XCTAssertEqual(first.nodes.first?.checks, 1)
        XCTAssertEqual(second.nodes.first?.checks, 2, "node probing is free and continues")
    }

    /// The gate itself, observed through the actor: a forced probe is the operator asking for
    /// one, and it runs the provider again.
    func testAForcedProbeRunsTheProviderAgain() async {
        let monitor = Monitor(
            options: options(nodes: [], probeProviders: false),
            configuration: configuration(),
            http: StubHTTPClient(handlers: [:]),
            log: .disabled
        )

        _ = await monitor.refresh(forceProbeProviders: false)
        let second = await monitor.refresh(forceProbeProviders: false)
        let forced = await monitor.refresh(forceProbeProviders: true)

        XCTAssertEqual(second.providers.first { $0.provider == .tavily }?.probes, 1)
        XCTAssertEqual(
            forced.providers.first { $0.provider == .tavily }?.probes, 2,
            "a forced probe is the operator asking for one"
        )
    }

    /// A refresh with no nodes is still a refresh: the counters are untouched and the model
    /// comes back rather than hanging on an empty task group.
    func testRefreshWithoutNodesIsANoOpNotAFailure() async {
        let monitor = Monitor(
            options: options(nodes: [], probeProviders: false),
            configuration: configuration(),
            http: StubHTTPClient(handlers: [:]),
            log: .disabled
        )
        let model = await monitor.refresh(forceProbeProviders: false)
        XCTAssertTrue(model.nodes.isEmpty)
    }

    // MARK: - Counter folding

    /// A node result folds into the running `checks`/`failures` counters, and the state the
    /// dashboard shows is the latest probe's.
    func testNodeResultsFoldIntoTheCounters() async {
        let nodes = [target("this-mac", 1111), target("node1", 2222)]
        let client = StubHTTPClient(handlers: [
            endpoint(1111): payload(up: true, unavailable: ""),
            endpoint(2222): payload(up: false, unavailable: ""),
        ])
        let monitor = Monitor(
            options: options(nodes: nodes, probeProviders: false),
            configuration: configuration(),
            http: client,
            log: .disabled
        )

        let model = await monitor.refresh(forceProbeProviders: false)
        let up = try? XCTUnwrap(model.nodes.first { $0.name == "this-mac" })
        let degraded = try? XCTUnwrap(model.nodes.first { $0.name == "node1" })

        XCTAssertEqual(up?.state, .up)
        XCTAssertEqual(up?.checks, 1)
        XCTAssertEqual(up?.failures, 0)
        XCTAssertEqual(up?.resultCount, 1)
        XCTAssertEqual(
            degraded?.state, .degraded,
            "an instance that answers with no results cannot serve a search"
        )
        XCTAssertEqual(degraded?.checks, 1)
        XCTAssertEqual(degraded?.failures, 1, "a degraded answer is a failed check")
    }

    /// The counters accumulate across refreshes rather than being replaced, and a provider
    /// that answered stays healthy on the pass that does not re-probe it.
    func testCountersAccumulateAcrossRefreshes() async {
        let nodes = [target("this-mac", 1111)]
        let client = StubHTTPClient(handlers: [
            endpoint(1111): payload(up: false, unavailable: "")
        ])
        let monitor = Monitor(
            options: options(nodes: nodes, probeProviders: false),
            configuration: configuration(),
            http: client,
            log: .disabled
        )

        _ = await monitor.refresh(forceProbeProviders: false)
        let second = await monitor.refresh(forceProbeProviders: false)

        XCTAssertEqual(second.nodes.first?.checks, 2)
        XCTAssertEqual(second.nodes.first?.failures, 2)
        XCTAssertEqual(second.providers.first { $0.provider == .tavily }?.probes, 1)
        XCTAssertEqual(
            second.providers.first { $0.provider == .tavily }?.state, .healthy,
            "a provider keeps the state its last probe gave it"
        )
    }

    // MARK: - Warnings

    /// The three operator warnings are aggregated from the model, not from one node's view:
    /// a down node, an engine failing on at least half the fleet, and providers with no
    /// credentials.
    func testWarningsAggregateAcrossNodesAndProviders() async {
        let unavailable = #"["duckduckgo","CAPTCHA"]"#
        let nodes = [target("this-mac", 1111), target("node1", 2222), target("node2", 3333)]
        let client = StubHTTPClient(handlers: [
            endpoint(1111): payload(up: true, unavailable: unavailable),
            endpoint(2222): payload(up: false, unavailable: unavailable),
            // 3333 keeps the stub's default: an empty, degraded answer with no engines.
        ])
        // A transport that refuses the third probe, so the node reads `.down`.
        let monitor = Monitor(
            options: options(nodes: nodes, probeProviders: false),
            configuration: configuration(),
            http: FailingEndpointClient(failing: endpoint(3333), underlying: client),
            log: .disabled
        )

        let model = await monitor.refresh(forceProbeProviders: false)

        XCTAssertEqual(model.nodes.first { $0.name == "node2" }?.state, .down)
        XCTAssertTrue(
            model.warnings.contains { $0.contains("1 node(s) unreachable") && $0.contains("node2") },
            "a down node is named: \(model.warnings)"
        )
        XCTAssertTrue(
            model.warnings.contains { $0.contains("engine 'duckduckgo' unavailable on 2 node(s)") },
            "an engine failing on half the fleet is called out once: \(model.warnings)"
        )
        XCTAssertFalse(
            model.warnings.contains { $0.contains("'brave'") },
            "an engine failing on one node is below the threshold: \(model.warnings)"
        )
        XCTAssertTrue(
            model.warnings.contains { $0.contains("1 provider(s) have no credentials") },
            "Brave has no key in this configuration: \(model.warnings)"
        )
        XCTAssertFalse(
            model.warnings.contains { $0.contains("TAVILY") },
            "a keyed provider must not be part of the credential warning: \(model.warnings)"
        )
    }

    /// A single node whose sole engine fails produces no engine warning: the threshold is
    /// `max(2, nodes/2)`, so one node cannot make an engine look fleet-wide broken.
    func testASingleFailingEngineDoesNotWarn() async {
        let nodes = [target("this-mac", 1111)]
        let client = StubHTTPClient(handlers: [
            endpoint(1111): payload(up: true, unavailable: #"["duckduckgo","CAPTCHA"]"#)
        ])
        let monitor = Monitor(
            options: options(nodes: nodes, probeProviders: false),
            configuration: configuration(),
            http: client,
            log: .disabled
        )

        let model = await monitor.refresh(forceProbeProviders: false)
        XCTAssertFalse(
            model.warnings.contains { $0.contains("unavailable on") },
            "one node is not a pattern: \(model.warnings)"
        )
    }

    // MARK: - Cycle wait

    /// The sleep is sliced so a key press is noticed promptly; `requestRefresh` cuts it short
    /// instead of the loop waiting out the whole interval.
    func testRequestRefreshEndsTheWaitEarly() async {
        let monitor = Monitor(
            options: options(nodes: [], probeProviders: false),
            configuration: configuration(),
            http: StubHTTPClient(handlers: [:]),
            log: .disabled
        )
        await monitor.requestRefresh()

        let started = Date()
        await monitor.waitForNextCycle(.seconds(30))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 5, "a refresh request must not wait out the interval")
    }

    /// With no request, the wait ends near its deadline: the slice loop does not spin shorter
    /// than asked for.
    func testTheWaitHonoursAShortInterval() async {
        let monitor = Monitor(
            options: options(nodes: [], probeProviders: false),
            configuration: configuration(),
            http: StubHTTPClient(handlers: [:]),
            log: .disabled
        )
        let started = Date()
        await monitor.waitForNextCycle(.milliseconds(300))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.2)
        XCTAssertLessThan(elapsed, 3)
    }
}

/// A client that fails one endpoint and delegates every other to another client.
private final class FailingEndpointClient: HTTPClient, @unchecked Sendable {
    private let failing: String
    private let underlying: any HTTPClient

    init(failing: String, underlying: any HTTPClient) {
        self.failing = failing
        self.underlying = underlying
    }

    func send(_ request: HTTPRequest, maxBytes: Int) async throws -> HTTPResponse {
        if request.url.absoluteString == failing {
            throw HTTPError.transportFailure(label: request.label, reason: "connection refused")
        }
        return try await underlying.send(request, maxBytes: maxBytes)
    }
}
