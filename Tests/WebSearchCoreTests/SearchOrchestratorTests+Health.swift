import Foundation
import XCTest
@testable import WebSearchCore

extension SearchOrchestratorTests {

    func testOpenCircuitBreakerSkipsTheProviderWithoutCallingIt() async throws {
        let clock = TestClock()
        let health = ProviderHealth(clock: clock)
        await health.register(.brave)
        // Trip the breaker with transient failures.
        for _ in 0..<3 {
            await health.recordFailure(
                .brave,
                failure: ProviderFailure(provider: .brave, category: .serverError, message: "500")
            )
        }
        // No sleep here: `recordFailure` awaits the breaker before it returns
        // (`ProviderHealth.recordFailure`), which `FusionAndReliabilityTests` asserts directly.
        // A 60 ms sleep used to stand in for a detached task that no longer exists;
        // a reader who trusted that comment would reintroduce the race it described.

        let brave = MockSearchProvider.returning(.brave, results: [("B", "https://b.example.com/1", nil)])
        let tavily = MockSearchProvider.returning(.tavily, results: [("T", "https://t.example.com/1", nil)])
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [tavily, brave],
            configuration: Fixtures.configuration(),
            health: health,
            clock: clock
        )

        let response = try await orchestrator.search(Fixtures.request(mode: .balanced))

        XCTAssertEqual(brave.callCount, 0, "an open breaker must skip the provider entirely")
        XCTAssertEqual(response.providersUsed, [.tavily])
        XCTAssertTrue(response.providersFailed.contains { $0.category == .circuitOpen })
    }

    /// A cancelled request must give back the half-open probe it claimed.
    ///
    /// The claim is taken inside `authorize` and was released only by `recordSuccess` /
    /// `recordFailure`. The cancellation path records no health outcome, correctly — a caller that
    /// goes away says nothing about the provider — so the claim leaked, the breaker stayed
    /// half-open with a claim nobody held, and the provider was never tried again.
    func testACancelledRequestReleasesTheHalfOpenProbe() async throws {
        let clock = TestClock()
        let health = ProviderHealth(clock: clock)
        await health.register(
            .tavily,
            breakerPolicy: .init(failureThreshold: 1, cooldown: .seconds(30))
        )
        await health.recordFailure(
            .tavily,
            failure: ProviderFailure(provider: .tavily, category: .serverError, message: "500")
        )
        clock.advance(by: .seconds(31))

        let cancelling = MockSearchProvider(id: .tavily) { _ in throw CancellationError() }
        // A second, healthy provider so the search itself completes: the cancellation of one
        // provider is a partial failure, not an error for the whole fan-out.
        let healthy = MockSearchProvider.returning(
            .brave,
            results: [("B", "https://b.example.com/1", nil)]
        )
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [cancelling, healthy],
            configuration: Fixtures.configuration(providerOrder: [.tavily, .brave]),
            health: health,
            clock: clock
        )

        let response = try await orchestrator.search(Fixtures.request(mode: .balanced))

        XCTAssertEqual(cancelling.callCount, 1, "the half-open probe was spent on this call")
        XCTAssertTrue(
            response.providersFailed.contains { $0.category == .cancelled },
            "\(response.providersFailed)"
        )

        // Claimable again: the attempt that was cancelled gave the probe back. Before the fix this
        // returned a `.circuitOpen` refusal, and every later search skipped the provider for good.
        let next = await health.authorize(.tavily)
        XCTAssertNil(next, "the probe must have been released, got \(next as Any)")
    }

    /// The transport's cancellation shape must be treated as cancellation, not as provider failure.
    ///
    /// In-flight cancellation surfaces as `HTTPError.cancelled`, not `CancellationError` — this
    /// codebase records exactly that at `AnswerSynthesizer.swift`. Catching only
    /// `CancellationError` let the transport's shape fall into the generic arm, where
    /// `HTTPStatusMapper` called it a transient network failure and `recordFailure` charged it to
    /// the breaker: three client disconnects opened a breaker on a provider that never failed, and
    /// the half-open probe the attempt had claimed was never given back.
    func testATransportCancellationIsNotChargedToTheBreaker() async throws {
        let clock = TestClock()
        let health = ProviderHealth(clock: clock)
        await health.register(
            .tavily,
            breakerPolicy: .init(failureThreshold: 1, cooldown: .seconds(30))
        )
        await health.recordFailure(
            .tavily,
            failure: ProviderFailure(provider: .tavily, category: .serverError, message: "500")
        )
        clock.advance(by: .seconds(31))

        // The transport's shape, not `CancellationError`: this is what a dropped connection throws.
        let cancelling = MockSearchProvider(id: .tavily) { _ in throw HTTPError.cancelled(label: "test") }
        let healthy = MockSearchProvider.returning(
            .brave,
            results: [("B", "https://b.example.com/1", nil)]
        )
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [cancelling, healthy],
            configuration: Fixtures.configuration(providerOrder: [.tavily, .brave]),
            health: health,
            clock: clock
        )

        let response = try await orchestrator.search(Fixtures.request(mode: .balanced))

        XCTAssertTrue(
            response.providersFailed.contains { $0.category == .cancelled },
            "a caller that goes away says nothing about the provider: \(response.providersFailed)"
        )
        // Released, not charged: before the fix the generic arm recorded a transient failure here,
        // which both reopened the breaker and left the claimed probe held.
        let next = await health.authorize(.tavily)
        XCTAssertNil(next, "the probe must have been released, got \(next as Any)")
    }

    func testProviderThatHangsIsCutOffByTheTimeBudget() async throws {
        var configuration = Fixtures.configuration()
        configuration.balancedTimeout = .milliseconds(300)
        configuration.fastTimeout = .milliseconds(300)
        let hanging = MockSearchProvider.hanging(.tavily)
        let fast = MockSearchProvider.returning(.brave, results: [("B", "https://b.example.com/1", nil)])

        // A shared cache keeps the second call from re-running the whole fan-out.
        let registry = ProviderRegistry(
            providers: [hanging, fast],
            configuration: configuration
        )
        let cache = SearchCache()
        let health = ProviderHealth()
        let orchestrator = SearchOrchestrator(
            registry: registry,
            health: health,
            cache: cache,
            configuration: configuration
        )

        let started = DispatchTime.now().uptimeNanoseconds
        let response = try await orchestrator.search(Fixtures.request(mode: .balanced))
        let elapsedMilliseconds = Int(
            (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        )

        // The contract is what the caller sees: the hang is reported as a timeout and the
        // responsive provider's results still come back. The wall-clock bound below only catches
        // a sentinel that never fires at all (the stub hangs for 60 s), so it is deliberately
        // loose — a tight bound measures the CI runner's scheduler, not this code.
        XCTAssertEqual(response.results.count, 1, "the responsive provider's results survive")
        XCTAssertTrue(response.providersFailed.contains { $0.category == .timeout })
        XCTAssertLessThan(
            elapsedMilliseconds,
            10_000,
            "the time budget must bound the call rather than wait out the hanging provider"
        )
    }

    /// A provider that already reported a *failure* must not be charged a second, synthetic
    /// deadline failure. Before this test the failed provider appeared twice in
    /// `providers_failed`, the count was inflated, and its real error was overwritten by a
    /// deadline it did not cause.
    func testABudgetExpiryChargesOnlyTheProvidersThatDidNotReport() async throws {
        var configuration = Fixtures.configuration()
        configuration.balancedTimeout = .milliseconds(300)
        configuration.fastTimeout = .milliseconds(300)
        // Fails immediately with a real error, well before the deadline.
        let failing = MockSearchProvider.failing(.tavily, with: .providerUnavailable(.tavily))
        // Still running when the budget expires.
        let hanging = MockSearchProvider.hanging(.brave)

        let registry = ProviderRegistry(providers: [failing, hanging], configuration: configuration)
        let health = ProviderHealth()
        let orchestrator = SearchOrchestrator(
            registry: registry,
            health: health,
            cache: SearchCache(),
            configuration: configuration
        )

        // Nothing succeeds, so the search reports the failures rather than a result set.
        let failures: [ProviderFailure]
        do {
            _ = try await orchestrator.search(Fixtures.request(mode: .balanced))
            XCTFail("a search in which every provider failed must report the failures")
            return
        } catch let error as SearchError {
            guard case .providersFailed(let reported) = error else {
                XCTFail("expected providersFailed, got \(error)")
                return
            }
            failures = reported
        }

        let tavilyFailures = failures.filter { $0.provider == .tavily }
        XCTAssertEqual(tavilyFailures.count, 1, "one failure is one report: \(tavilyFailures)")
        XCTAssertEqual(
            tavilyFailures.first?.category,
            .serverError,
            "its own error must survive; the deadline was not its fault"
        )
        // The provider that did not report is the one the deadline is charged to.
        XCTAssertEqual(
            failures.filter { $0.provider == .brave && $0.category == .timeout }.count,
            1
        )
        XCTAssertEqual(
            failures.count,
            2,
            "one real failure plus one deadline: \(failures.map(\.provider))"
        )
    }

    /// A provider's own "answer" is vendor text this tool never fetched; the warning channel must
    /// say so rather than presenting it as a neutral note, and must not let a provider flood the
    /// caller's context.
    func testAProviderAnswerIsMarkedUntrustedAndClipped() async throws {
        let inner = MockSearchProvider.returning(
            .tavily,
            results: [("T", "https://t.example.com/1", "s")]
        )
        let provider = MockSearchProvider(id: .tavily) { request in
            var response = try await inner.search(request)
            response.answer = String(repeating: "injected instruction ", count: 40)
            return response
        }
        let (orchestrator, _, _) = makeOrchestrator(providers: [provider])

        let response = try await orchestrator.search(Fixtures.request(mode: .fast))

        let warning = try XCTUnwrap(response.warnings.first { $0.contains("supplied answer") })
        XCTAssertTrue(warning.contains("untrusted, not fetched"), warning)
        XCTAssertTrue(warning.contains("…"), "the vendor text must be clipped: \(warning)")
        XCTAssertLessThan(warning.count, 400, warning)
    }

    // MARK: Caching

    func testSecondIdenticalSearchIsServedFromCache() async throws {
        let tavily = MockSearchProvider.returning(.tavily, results: [("T", "https://t.example.com/1", nil)])
        let (orchestrator, _, _) = makeOrchestrator(providers: [tavily])

        let first = try await orchestrator.search(Fixtures.request(mode: .fast))
        let second = try await orchestrator.search(Fixtures.request(mode: .fast))

        XCTAssertFalse(first.servedFromCache)
        XCTAssertTrue(second.servedFromCache)
        XCTAssertEqual(tavily.callCount, 1, "the second call must not hit the provider")
    }

    func testCacheExpiryTriggersAFreshCall() async throws {
        let clock = TestClock()
        let tavily = MockSearchProvider.returning(.tavily, results: [("T", "https://t.example.com/1", nil)])
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [tavily],
            configuration: Fixtures.configuration(cacheTTL: .seconds(30)),
            clock: clock
        )

        _ = try await orchestrator.search(Fixtures.request(mode: .fast))
        clock.advance(by: .seconds(31))
        let second = try await orchestrator.search(Fixtures.request(mode: .fast))

        XCTAssertFalse(second.servedFromCache)
        XCTAssertEqual(tavily.callCount, 2)
    }

    func testDifferentModesUseDifferentCacheEntries() async throws {
        let tavily = MockSearchProvider.returning(.tavily, results: [("T", "https://t.example.com/1", nil)])
        let (orchestrator, _, _) = makeOrchestrator(providers: [tavily])

        _ = try await orchestrator.search(Fixtures.request(mode: .fast))
        _ = try await orchestrator.search(Fixtures.request(mode: .balanced))
        // Different provider sets produce different answers, so they must not alias.
        XCTAssertEqual(tavily.callCount, 2)
    }

    func testFailuresAreNotCached() async throws {
        let flaky = MockSearchProvider(id: .tavily) { _ in
            throw SearchError.providerUnavailable(.tavily)
        }
        let (orchestrator, _, _) = makeOrchestrator(providers: [flaky])

        for _ in 0..<2 {
            do {
                _ = try await orchestrator.search(Fixtures.request(mode: .fast))
                XCTFail("expected failure")
            } catch {
                // expected
            }
        }
        // A failed attempt must not be remembered as an answer.
        XCTAssertEqual(flaky.callCount, 2)
    }

    // MARK: Normalization and filtering

    func testExcludedDomainsAreRemovedEvenIfTheProviderIgnoresTheFilter() async throws {
        // A provider that returns everything regardless of the request filters.
        let sloppy = MockSearchProvider(id: .tavily) { request in
            var seen: Set<String> = []
            var results: [SearchResult] = []
            for (index, url) in [
                "https://spam.example.com/1", "https://good.example.com/1",
            ].enumerated() {
                if let result = ResultNormalizer.make(
                    provider: .tavily,
                    rank: index + 1,
                    title: "T",
                    urlString: url,
                    snippet: nil,
                    request: request,
                    seenKeys: &seen
                ) {
                    results.append(result)
                }
            }
            return ProviderSearchResponse(provider: .tavily, results: results)
        }

        var request = Fixtures.request(mode: .fast)
        request.excludeDomains = ["spam.example.com"]
        let (orchestrator, _, _) = makeOrchestrator(providers: [sloppy])

        let response = try await orchestrator.search(request)
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results.first?.url.host(), "good.example.com")
    }

    func testIncludeDomainsRestrictResultsLocally() async throws {
        let sloppy = MockSearchProvider(id: .tavily) { request in
            var seen: Set<String> = []
            var results: [SearchResult] = []
            for (index, url) in [
                "https://unwanted.example.com/1", "https://wanted.example.com/1",
            ].enumerated() {
                if let result = ResultNormalizer.make(
                    provider: .tavily,
                    rank: index + 1,
                    title: "T",
                    urlString: url,
                    snippet: nil,
                    request: request,
                    seenKeys: &seen
                ) {
                    results.append(result)
                }
            }
            return ProviderSearchResponse(provider: .tavily, results: results)
        }

        var request = Fixtures.request(mode: .fast)
        request.includeDomains = ["wanted.example.com"]
        let (orchestrator, _, _) = makeOrchestrator(providers: [sloppy])

        let response = try await orchestrator.search(request)
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results.first?.url.host(), "wanted.example.com")
    }

    func testProvidersReceiveALargerBudgetThanTheFinalResultLimit() async throws {
        // Fusion needs surplus material to deduplicate against.
        let capturing = MockSearchProvider(id: .tavily) { _ in
            ProviderSearchResponse(
                provider: .tavily,
                results: [
                    SearchResult(
                        title: "T",
                        url: URL(string: "https://example.com/1")!,
                        provider: .tavily,
                        providerRank: 1
                    )
                ]
            )
        }
        let (orchestrator, _, _) = makeOrchestrator(providers: [capturing])
        _ = try await orchestrator.search(Fixtures.request(maxResults: 3, mode: .fast))
        XCTAssertEqual(capturing.callCount, 1)
        // 3 requested results must reach the provider as a budget of 6 — that surplus is the
        // entire contract this test is named for, so asserting only that the call succeeded
        // proved nothing.
        let request = try XCTUnwrap(capturing.requests.first)
        XCTAssertEqual(request.maxResults, 3)
        XCTAssertEqual(request.providerResultBudget, 6)
        XCTAssertGreaterThan(
            request.providerResultBudget,
            request.maxResults,
            "fusion needs more material than the caller asked to return"
        )
    }

    // MARK: Diagnostics

    func testStatusReportsConfigurationGapsWithActionableNotes() async {
        let brave = MockSearchProvider(
            id: .brave,
            configured: false,
            outcome: { _ in throw SearchError.notConfigured(.brave) }
        )
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [brave],
            configuration: Fixtures.configuration(providerOrder: [.brave])
        )

        let states = await orchestrator.status()
        let braveState = states.first { $0.provider == .brave }
        XCTAssertEqual(braveState?.status, .notConfigured)
        XCTAssertEqual(braveState?.configured, false)
        XCTAssertNotNil(braveState?.note)
    }

    /// `status()` must project both counters, and the failing provider must actually be run.
    ///
    /// This used `fast`, which selects exactly one provider, so `brave` was never called:
    /// `XCTAssertEqual(brave?.failures, 0)` held whether or not `ProviderHealth.recordFailure`
    /// incremented anything, and the failure path through `status()` was never observed at all.
    /// `balanced` selects both `tavily` and `brave`, and the search still succeeds
    /// because one provider answered.
    func testStatusCountsSuccessesAndFailures() async throws {
        let good = MockSearchProvider.returning(.tavily, results: [("T", "https://t.example.com/1", nil)])
        let bad = MockSearchProvider.failing(.brave, with: .providerUnavailable(.brave))
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [good, bad],
            configuration: Fixtures.configuration(providerOrder: [.tavily, .brave])
        )

        let response = try await orchestrator.search(Fixtures.request(mode: .balanced))

        // Both providers were spent, and the failed one is reported to the caller.
        XCTAssertEqual(good.callCount, 1)
        XCTAssertEqual(bad.callCount, 1, "the failing provider must really have been selected")
        XCTAssertEqual(response.providersUsed, [.tavily])
        XCTAssertEqual(
            response.providersFailed.map(\.provider),
            [.brave],
            "the failure must reach the response, not only the counters"
        )

        let states = await orchestrator.status()
        let tavily = states.first { $0.provider == .tavily }
        let brave = states.first { $0.provider == .brave }

        XCTAssertEqual(tavily?.successes, 1)
        XCTAssertEqual(tavily?.failures, 0)
        XCTAssertNotNil(tavily?.lastSuccessAt)

        // The counters `ProviderHealthTests` only checks at the actor now have to survive the
        // projection into the diagnostic tool.
        XCTAssertEqual(brave?.failures, 1)
        XCTAssertEqual(brave?.successes, 0)
        XCTAssertEqual(brave?.lastErrorCategory, .serverError)
        XCTAssertEqual(brave?.lastError, "Brave Search is temporarily unavailable.")
        XCTAssertNotNil(brave?.lastFailureAt)

        // A provider that failed once has not earned a circuit, and the configuration is
        // complete, so both are still selectable.
        XCTAssertEqual(tavily?.status, .ready)
        XCTAssertEqual(brave?.status, .ready)
        XCTAssertEqual(tavily?.totalRequests, 1)
        XCTAssertEqual(brave?.totalRequests, 1)
    }

}
