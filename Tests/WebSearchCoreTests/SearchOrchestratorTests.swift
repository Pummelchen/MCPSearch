import Foundation
import XCTest

@testable import WebSearchCore

/// Orchestrator behaviour: selection, fan-out, failover, caching and degradation.
final class SearchOrchestratorTests: XCTestCase {

    private func makeOrchestrator(
        providers: [any SearchProvider],
        configuration: AppConfiguration = Fixtures.configuration(),
        health: ProviderHealth? = nil,
        clock: any Clock = SystemClock()
    ) -> (SearchOrchestrator, ProviderHealth, SearchCache) {
        let registry = ProviderRegistry(providers: providers, configuration: configuration)
        let resolvedHealth = health ?? ProviderHealth(clock: clock)
        let cache = SearchCache(clock: clock)
        let orchestrator = SearchOrchestrator(
            registry: registry,
            health: resolvedHealth,
            cache: cache,
            configuration: configuration,
            clock: clock
        )
        return (orchestrator, resolvedHealth, cache)
    }

    // MARK: Selection

    func testFastModeCallsExactlyOneProvider() async throws {
        let tavily = MockSearchProvider.returning(
            .tavily,
            results: [("T", "https://t.example.com/1", "s")]
        )
        let brave = MockSearchProvider.returning(
            .brave,
            results: [("B", "https://b.example.com/1", "s")]
        )
        let (orchestrator, _, _) = makeOrchestrator(providers: [tavily, brave])

        let response = try await orchestrator.search(Fixtures.request(mode: .fast))

        XCTAssertEqual(response.providersUsed, [.tavily])
        XCTAssertEqual(tavily.callCount, 1)
        XCTAssertEqual(brave.callCount, 0, "fast mode must not spend a second provider")
    }

    func testBalancedModeFansOutToTwoProviders() async throws {
        let providers = ProviderID.allCases.prefix(3).map {
            MockSearchProvider.returning($0, results: [("R", "https://\($0.rawValue).example.com/1", nil)])
        }
        let (orchestrator, _, _) = makeOrchestrator(providers: Array(providers))

        let response = try await orchestrator.search(Fixtures.request(mode: .balanced))

        XCTAssertEqual(response.providersUsed.count, 2)
    }

    func testThoroughModeFansOutToThreeProviders() async throws {
        let providers = ProviderID.allCases.prefix(4).map {
            MockSearchProvider.returning($0, results: [("R", "https://\($0.rawValue).example.com/1", nil)])
        }
        let (orchestrator, _, _) = makeOrchestrator(providers: Array(providers))

        let response = try await orchestrator.search(Fixtures.request(mode: .thorough))

        XCTAssertEqual(response.providersUsed.count, 3)
    }

    func testIndependentIndexesArePreferredOverAggregatorsInAutoSelection() async throws {
        // Config order puts the aggregator first, but auto-selection must still pick
        // the direct index, because an aggregator is usually a reseller.
        var configuration = Fixtures.configuration()
        configuration.providerOrder = [.searxng, .mojeek]
        let searxng = MockSearchProvider.returning(.searxng, results: [("S", "https://s.example.com/1", nil)])
        let mojeek = MockSearchProvider.returning(.mojeek, results: [("M", "https://m.example.com/1", nil)])

        let (orchestrator, _, _) = makeOrchestrator(
            providers: [searxng, mojeek],
            configuration: configuration
        )
        let response = try await orchestrator.search(Fixtures.request(mode: .fast))

        XCTAssertEqual(response.providersUsed, [.mojeek])
    }

    func testExplicitProviderBypassesSelectionPolicy() async throws {
        let tavily = MockSearchProvider.returning(.tavily, results: [("T", "https://t.example.com/1", nil)])
        let brave = MockSearchProvider.returning(.brave, results: [("B", "https://b.example.com/1", nil)])
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [tavily, brave], configuration: Fixtures.configuration())

        let response = try await orchestrator.search(
            Fixtures.request(mode: .fast),
            requestedProvider: .brave
        )

        XCTAssertEqual(response.providersUsed, [.brave])
        XCTAssertEqual(tavily.callCount, 0)
        XCTAssertEqual(brave.callCount, 1)
    }

    func testExplicitUnconfiguredProviderReturnsAClearError() async {
        // Brave is registered but has no credentials.
        let brave = MockSearchProvider(
            id: .brave,
            configured: false,
            outcome: { _ in throw SearchError.notConfigured(.brave) }
        )
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [brave],
            configuration: Fixtures.configuration(providerOrder: [.brave])
        )

        do {
            _ = try await orchestrator.search(
                Fixtures.request(),
                requestedProvider: .brave
            )
            XCTFail("expected a not-configured error")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .notConfigured)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDisabledProviderCannotBeSelectedExplicitly() async {
        var configuration = Fixtures.configuration(enableScrapers: true)
        configuration.providerEnabled[.duckDuckGo] = false
        let duck = MockSearchProvider.returning(.duckDuckGo, results: [])
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [duck],
            configuration: configuration
        )

        do {
            _ = try await orchestrator.search(Fixtures.request(), requestedProvider: .duckDuckGo)
            XCTFail("expected the disabled provider to be refused")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .unsupportedRequest)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNoConfiguredProviderProducesAnActionableError() async {
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [],
            configuration: Fixtures.configuration(providerOrder: [.tavily])
        )
        do {
            _ = try await orchestrator.search(Fixtures.request())
            XCTFail("expected an error when nothing is configured")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .unsupportedRequest)
            XCTAssertTrue(error.safeDescription.contains("TAVILY_API_KEY"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testScrapersAreExcludedUnlessExplicitlyEnabled() async throws {
        let mojeek = MockSearchProvider.returning(.mojeek, results: [("M", "https://m.example.com/1", nil)])
        let duck = MockSearchProvider.returning(.duckDuckGo, results: [("D", "https://d.example.com/1", nil)])
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [mojeek, duck],
            configuration: Fixtures.configuration(enableScrapers: false)
        )

        let response = try await orchestrator.search(Fixtures.request(mode: .thorough))
        XCTAssertFalse(response.providersUsed.contains(.duckDuckGo))
        XCTAssertEqual(duck.callCount, 0)
    }

    func testEmptyQueryIsRejected() async {
        let tavily = MockSearchProvider.returning(.tavily, results: [])
        let (orchestrator, _, _) = makeOrchestrator(providers: [tavily])
        do {
            _ = try await orchestrator.search(SearchRequest(query: "   "))
            XCTFail("expected an invalid-request error")
        } catch let error as SearchError {
            if case .invalidRequest = error {
            } else {
                XCTFail("expected invalidRequest, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Failover

    func testOneProviderFailingStillReturnsResults() async throws {
        let good = MockSearchProvider.returning(.tavily, results: [("Good", "https://good.example.com/1", "s")])
        let bad = MockSearchProvider.failing(.brave, with: .providerUnavailable(.brave))
        let (orchestrator, _, _) = makeOrchestrator(providers: [good, bad])

        let response = try await orchestrator.search(Fixtures.request(mode: .balanced))

        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.providersUsed, [.tavily])
        XCTAssertEqual(response.providersFailed.count, 1)
        XCTAssertEqual(response.providersFailed.first?.provider, .brave)
        XCTAssertTrue(response.warnings.contains { $0.contains("brave") })
    }

    func testRateLimitedProviderIsReportedAndOthersContinue() async throws {
        let good = MockSearchProvider.returning(.tavily, results: [("Good", "https://good.example.com/1", nil)])
        let limited = MockSearchProvider.failing(.brave, with: .rateLimited(.brave, retryAfter: .seconds(5)))
        let (orchestrator, _, _) = makeOrchestrator(providers: [good, limited])

        let response = try await orchestrator.search(Fixtures.request(mode: .balanced))

        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.providersFailed.first?.category, .rateLimited)
    }

    func testAllProvidersFailingThrowsAllProvidersFailed() async {
        let a = MockSearchProvider.failing(.tavily, with: .providerUnavailable(.tavily))
        let b = MockSearchProvider.failing(.brave, with: .timeout(.brave))
        let (orchestrator, _, _) = makeOrchestrator(providers: [a, b])

        do {
            _ = try await orchestrator.search(Fixtures.request(mode: .balanced))
            XCTFail("expected a failure")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .unknown)
            // The per-provider reasons must travel with the error: with a single
            // explicitly requested provider, "all providers failed" alone is useless.
            guard case .providersFailed(let failures) = error else {
                return XCTFail("expected providersFailed, got \(error)")
            }
            XCTAssertEqual(failures.count, 2)
            XCTAssertEqual(Set(failures.map(\.provider)), Set([.tavily, .brave]))
            // And the rendered message must name them.
            let message = error.safeDescription
            XCTAssertTrue(message.contains("Tavily"), message)
            XCTAssertTrue(message.contains("Brave"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// An upstream throttle or rejection is the provider's answer, not a local refusal.
    ///
    /// `rateLimited` and `authenticationRequired` are produced by purely local conditions
    /// as well as by upstream responses, so the orchestrator must not read the category to
    /// decide whether anything was attempted. It did: an all-429 search was reported as
    /// "nothing was attempted" and the providers' real answers were hidden.
    func testUpstreamErrorsAreNeverReportedAsNothingAttempted() async {
        let makeFailures: [(ProviderID) -> SearchError] = [
            { .rateLimited($0, retryAfter: .seconds(5)) },
            { .authenticationRequired($0) },
        ]

        for makeFailure in makeFailures {
            let a = MockSearchProvider.failing(.tavily, with: makeFailure(.tavily))
            let b = MockSearchProvider.failing(.brave, with: makeFailure(.brave))
            let (orchestrator, _, _) = makeOrchestrator(providers: [a, b])

            do {
                _ = try await orchestrator.search(Fixtures.request(mode: .balanced))
                XCTFail("expected a failure for \(makeFailure(.tavily))")
            } catch let error as SearchError {
                guard case .providersFailed(let failures) = error else {
                    return XCTFail(
                        "an upstream error must surface as providersFailed, got \(error)"
                    )
                }
                XCTAssertEqual(failures.count, 2)
                XCTAssertEqual(Set(failures.map(\.provider)), Set([.tavily, .brave]))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// A sustained run must not report a transient local rate limit as an invalid
    /// request.
    ///
    /// Found by a 50-query soak: the local token bucket briefly refused *every* provider
    /// because each search spends one request per provider it fans out to, and the
    /// orchestrator reported "all eligible providers were skipped" as an
    /// `invalidRequest`, implying the query was at fault. It is a retryable condition.
    func testProvidersSkippedByLocalLimitsAreReportedAsTemporarilyUnavailable() async {
        let clock = TestClock()
        let health = ProviderHealth(clock: clock)
        // Exhaust a single-token bucket so the very first search is refused locally.
        await health.register(
            .tavily,
            ratePolicy: RateLimiter.Policy(burst: 1, requestsPerMinute: 0.001)
        )
        let provider = MockSearchProvider.returning(
            .tavily,
            results: [("T", "https://t.example.com/1", nil)]
        )
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [provider],
            configuration: Fixtures.configuration(providerOrder: [.tavily]),
            health: health,
            clock: clock
        )

        // Consume the only token deterministically rather than relying on the first
        // search having reached the provider.
        _ = await health.authorize(.tavily)

        do {
            _ = try await orchestrator.search(Fixtures.request(mode: .fast))
            XCTFail("expected the search to be refused locally")
        } catch let error as SearchError {
            guard case .temporarilyUnavailable = error else {
                return XCTFail(
                    "a local rate limit is transient and must not be reported as "
                        + "\(error); invalidRequest would blame the caller"
                )
            }
            XCTAssertEqual(error.category, .rateLimited)
            let message = error.safeDescription
            XCTAssertTrue(
                message.lowercased().contains("retry"),
                "the message should tell the caller to retry: \(message)"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A provider skipped locally must not cost the search its fan-out slot.
    ///
    /// Selection happens before any request is made, so an open breaker or an empty local
    /// bucket used to waste the slot even though the next candidate in the same preference
    /// order was free. Measured: DuckDuckGo contributed 0 of 50 queries in a balanced soak
    /// because Tavily and Parallel outranked it, and one of them was skipped.
    func testALocallySkippedProviderIsReplacedByTheNextCandidate() async throws {
        let clock = TestClock()
        let health = ProviderHealth(clock: clock)
        // Exhaust Tavily's bucket so it is skipped without a request being made.
        await health.register(
            .tavily,
            ratePolicy: RateLimiter.Policy(burst: 1, requestsPerMinute: 0.001)
        )
        _ = await health.authorize(.tavily)

        let tavily = MockSearchProvider.returning(
            .tavily,
            results: [("T", "https://t.example.com/1", nil)]
        )
        let brave = MockSearchProvider.returning(
            .brave,
            results: [("B", "https://b.example.com/1", nil)]
        )
        let mojeek = MockSearchProvider.returning(
            .mojeek,
            results: [("M", "https://m.example.com/1", nil)]
        )

        let (orchestrator, _, _) = makeOrchestrator(
            providers: [tavily, brave, mojeek],
            configuration: Fixtures.configuration(providerOrder: [.tavily, .brave, .mojeek]),
            health: health,
            clock: clock
        )

        let response = try await orchestrator.search(Fixtures.request(mode: .balanced))

        XCTAssertEqual(tavily.callCount, 0, "a locally skipped provider must not be called")
        XCTAssertEqual(brave.callCount, 1)
        XCTAssertEqual(
            mojeek.callCount,
            1,
            "the wasted slot must be refilled from the next candidate"
        )
        XCTAssertTrue(response.providersUsed.contains(.mojeek))
        XCTAssertEqual(response.providersFailed.map(\.provider), [.tavily])
    }

    /// A brief local throttle must not become a hard failure.
    ///
    /// The token bucket denies rather than waits, which is right when another provider can
    /// answer. Measured on the tracker: DuckDuckGo alone failed 41 of 50 queries once its
    /// throttle was reached, while the same run with a second provider produced 241 results.
    func testAShortLocalThrottleIsWaitedOutRatherThanFailing() async throws {
        // A real clock on purpose: the wait has to actually refill the bucket, which a
        // frozen test clock would never do.
        let health = ProviderHealth()
        // One token and a 100 ms refill: a real throttle, and obviously cheaper to wait out
        // than to return nothing.
        await health.register(
            .tavily,
            ratePolicy: RateLimiter.Policy(burst: 1, requestsPerMinute: 600)
        )
        // Spend the burst token so the next request has to wait out the refill.
        _ = await health.authorize(.tavily)

        let tavily = MockSearchProvider.returning(
            .tavily,
            results: [("T", "https://t.example.com/1", nil)]
        )
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [tavily],
            configuration: Fixtures.configuration(providerOrder: [.tavily]),
            health: health
        )

        let response = try await orchestrator.search(Fixtures.request(mode: .fast))

        XCTAssertEqual(tavily.callCount, 1, "the provider must be consulted after the wait")
        XCTAssertEqual(response.results.count, 1)
        XCTAssertTrue(response.providersFailed.isEmpty)
    }

    /// A throttle the budget cannot afford is reported, not waited out.
    func testALongLocalThrottleIsReportedRatherThanWaitedOut() async {
        let clock = TestClock()
        let health = ProviderHealth(clock: clock)
        await health.register(
            .tavily,
            ratePolicy: RateLimiter.Policy(
                burst: 1,
                requestsPerMinute: 0.001,
                minimumInterval: .seconds(30)
            )
        )
        _ = await health.authorize(.tavily)

        let tavily = MockSearchProvider.returning(
            .tavily,
            results: [("T", "https://t.example.com/1", nil)]
        )
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [tavily],
            configuration: Fixtures.configuration(
                providerOrder: [.tavily],
                fastTimeout: .seconds(2)
            ),
            health: health,
            clock: clock
        )

        do {
            _ = try await orchestrator.search(Fixtures.request(mode: .fast))
            XCTFail("expected the search to be refused locally")
        } catch let error as SearchError {
            guard case .temporarilyUnavailable = error else {
                return XCTFail("expected temporarilyUnavailable, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(tavily.callCount, 0, "a 30 s wait is not worth the search budget")
    }

    /// A single explicitly requested provider that fails must say why, rather than
    /// reporting a generic "all providers failed".
    func testExplicitProviderFailureExplainsTheReason() async {
        var configuration = Fixtures.configuration(providerOrder: [.startpage])
        configuration.enableScrapers = true
        let startpage = MockSearchProvider.failing(
            .startpage,
            with: .providerUnavailable(.startpage)
        )
        let (orchestrator, _, _) = makeOrchestrator(
            providers: [startpage],
            configuration: configuration
        )

        do {
            _ = try await orchestrator.search(
                Fixtures.request(mode: .fast),
                requestedProvider: .startpage
            )
            XCTFail("expected a failure")
        } catch let error as SearchError {
            let message = error.safeDescription
            XCTAssertTrue(
                message.contains("Startpage"),
                "the message must name the provider that failed, got: \(message)"
            )
            XCTAssertFalse(
                message.contains("All eligible search providers failed"),
                "a single-provider failure should not be reported generically: \(message)"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

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
        // The state update happens in a detached task inside recordFailure.
        try await Task.sleep(for: .milliseconds(60))

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

        XCTAssertLessThan(elapsedMilliseconds, 2_000, "the time budget must bound the call")
        XCTAssertEqual(response.results.count, 1, "the responsive provider's results survive")
        XCTAssertTrue(response.providersFailed.contains { $0.category == .timeout })
    }

    /// A provider that already reported a *failure* must not be charged a second, synthetic
    /// deadline failure. Before this test the failed provider appeared twice in
    /// `providers_failed`, the count was inflated, and its real error was overwritten by a
    /// deadline it did not cause (ledger B12).
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
    /// caller's context (ledger B27).
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
        // proved nothing (ledger B19).
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

    func testStatusCountsSuccessesAndFailures() async throws {
        let good = MockSearchProvider.returning(.tavily, results: [("T", "https://t.example.com/1", nil)])
        let bad = MockSearchProvider.failing(.brave, with: .providerUnavailable(.brave))
        let (orchestrator, _, _) = makeOrchestrator(providers: [good, bad])

        // `fast` uses exactly one provider, keeping the counters unambiguous.
        _ = try await orchestrator.search(Fixtures.request(mode: .fast))
        let states = await orchestrator.status()

        let tavily = states.first { $0.provider == .tavily }
        let brave = states.first { $0.provider == .brave }
        XCTAssertEqual(tavily?.successes, 1)
        XCTAssertEqual(brave?.failures, 0)
        XCTAssertNotNil(tavily?.lastSuccessAt)
    }
}
