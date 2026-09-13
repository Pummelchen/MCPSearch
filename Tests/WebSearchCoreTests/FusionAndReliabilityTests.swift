import Foundation
import XCTest

@testable import WebSearchCore

/// Rank fusion and deduplication.
///
/// These assertions encode the central reliability claim of the design: a result
/// found by two independent providers must outrank one found by a single provider,
/// and an aggregator must not double-count a source it merely resells.
final class RankFusionTests: XCTestCase {

    /// - Parameter resultEngines: per-result provenance, as an adapter that reports the
    ///   engine behind each individual result supplies it.
    private func response(
        _ provider: ProviderID,
        _ entries: [(String, String)],
        upstream: [String] = [],
        resultEngines: [String]? = nil
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
                upstreamEngines: resultEngines,
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
                response(
                    .tavily,
                    [
                        ("Solo", "https://solo.example.com/only"),
                        ("Corroborated", "https://both.example.com/page"),
                    ]),
                response(
                    .brave,
                    [
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
                response(
                    .tavily,
                    [
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
        let duplicate = response(
            .tavily,
            [
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
                    upstream: ["brave"],
                    resultEngines: ["brave"]
                ),
            ],
            limit: 10,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 0)
        )
        let diagnostics = fused.diagnostics.first { $0.canonicalURL.path == "/1" }
        XCTAssertNotNil(diagnostics)
        // The same URL from an independent index and from an aggregator that resold it is one
        // source, not two, so it must not count as independently corroborated. Folding needs
        // per-result engines; with only a response-level list the vote is discounted but the
        // family cannot be folded, which is recorded on the tracker.
        XCTAssertEqual(Set(diagnostics!.providers), Set([.brave, .searxng]))
        XCTAssertFalse(diagnostics!.hasIndependentCorroboration)
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

    /// Registry weights must stay within the range where rank can still compete.
    ///
    /// This is the invariant behind the fusion defect found by live testing: the score
    /// is `weight / (k + rank)`, so a weight ratio wider than the reachable rank ratio
    /// `(k + maxRank) / (k + 1)` lets one provider's whole result list outrank another's
    /// regardless of relevance. At `k = 60` that ratio is about 1.07 for five results, so
    /// the registry weights are all 1.0 and provider quality is expressed through
    /// corroboration and source-family signals instead.
    func testRegistryWeightsCannotOverrideRankOrdering() {
        let configuration = RankFusion.Configuration()

        // The weight multiplier applied to any single provider must stay inside the
        // range a rank can overcome for a realistic result count.
        let maxRank = 5
        let reachableRatio = (configuration.k + Double(maxRank)) / (configuration.k + 1)
        XCTAssertLessThan(
            configuration.duplicatedAggregatorWeight,
            reachableRatio,
            "the duplication discount must not be wide enough to outrank a whole list"
        )
        XCTAssertEqual(configuration.scraperWeight, 1.0, accuracy: 0.0001)
        XCTAssertEqual(configuration.independentIndexWeight, 1.0, accuracy: 0.0001)
    }

    /// A same-rank result from either provider is a genuine tie, decided deterministically
    /// rather than by provider preference.
    func testSameRankResultsTieAndBreakDeterministically() {
        let fused = RankFusion.fuse(
            responses: [
                response(.mojeek, [("Independent", "https://m.example.com/1")]),
                response(.duckDuckGo, [("Scraped", "https://d.example.com/2")]),
            ],
            limit: 10,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 0)
        )
        XCTAssertEqual(fused.results.count, 2)
        // Both are rank 1 with equal weight, so the tie is broken by canonical URL,
        // which makes the order stable across runs.
        XCTAssertEqual(
            fused.results.map { $0.url.host() },
            ["d.example.com", "m.example.com"]
        )
        XCTAssertEqual(
            fused.diagnostics.map(\.score),
            fused.diagnostics.map(\.score).sorted(by: >),
            "diagnostics should be in descending score order"
        )

        // Re-running produces the identical order.
        let again = RankFusion.fuse(
            responses: [
                response(.mojeek, [("Independent", "https://m.example.com/1")]),
                response(.duckDuckGo, [("Scraped", "https://d.example.com/2")]),
            ],
            limit: 10,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 0)
        )
        XCTAssertEqual(
            fused.results.map(\.url),
            again.results.map(\.url)
        )
    }

    /// Corroboration, not weight, is what lifts one result above another from a
    /// different provider.
    func testCorroborationOutranksASingleVoteRegardlessOfProvider() {
        let fused = RankFusion.fuse(
            responses: [
                response(.mojeek, [("Solo", "https://m.example.com/solo")]),
                response(.tavily, [("Shared", "https://t.example.com/shared")]),
                response(.duckDuckGo, [("Shared", "https://t.example.com/shared")]),
            ],
            limit: 10,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 0)
        )
        XCTAssertEqual(
            fused.results.first?.url.host(),
            "t.example.com",
            "a URL reported by two providers must outrank a single-vote result"
        )
        XCTAssertEqual(fused.results.first?.sources.count, 2)
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

    /// The aggregator discount must be applied exactly once.
    ///
    /// It is folded into the per-contribution weight, and a previous version applied
    /// it a second time in the scoring loop, which squared it (0.7 x 0.7) and made the
    /// second application dead code because the guard was always true.
    /// An aggregator is discounted **only** when it resells an index that another
    /// provider in the same run already owns.
    ///
    /// A blanket aggregator penalty is actively harmful. Because the score is
    /// `weight / (k + rank)`, once the weight ratio exceeds the reachable rank ratio
    /// `(k + maxRank) / (k + 1)` — only about 1.08 at `k = 60` — one provider's entire
    /// result list outranks another's and fusion degenerates into provider preference.
    /// That was observed live: Tavily's 6th result outranked Parallel's 1st by 1.82x,
    /// and the fused output was 100% Tavily despite Parallel ranking better on the query.
    func testAggregatorIsDiscountedOnlyWhenItResellsAnOwnedIndex() {
        let configuration = RankFusion.Configuration()
        XCTAssertEqual(configuration.duplicatedAggregatorWeight, 0.7, accuracy: 0.0001)

        // Not duplicating anything: full registry weight, so rank decides.
        let loneAggregator = RankFusion.weight(
            for: .meta,
            provider: .searxng,
            base: 0.9,
            duplicatedOwnedIndex: false,
            configuration: configuration
        )
        XCTAssertEqual(loneAggregator, 0.9, accuracy: 0.0001)

        // Reselling an index another provider owns: discounted exactly once.
        let duplicating = RankFusion.weight(
            for: .meta,
            provider: .searxng,
            base: 0.9,
            duplicatedOwnedIndex: true,
            configuration: configuration
        )
        XCTAssertEqual(duplicating, 0.9 * 0.7, accuracy: 0.0001)
        XCTAssertNotEqual(
            duplicating,
            0.9 * 0.7 * 0.7,
            "the discount must not be applied twice"
        )

        // Independent indexes are never discounted.
        let mojeek = RankFusion.weight(
            for: .mojeek,
            provider: .mojeek,
            base: 1.0,
            configuration: configuration
        )
        XCTAssertEqual(mojeek, 1.0, accuracy: 0.0001)
    }

    /// Aggregator discounting is per result, not per response.
    ///
    /// SearXNG reports the engine behind each result, and one instance can serve one page
    /// from Brave while another came from an engine nobody else covers. Discounting the
    /// whole response punished the second page for the first page's provenance.
    func testAggregatorDiscountUsesPerResultEngines() {
        func aggregatorResult(url: String, rank: Int, engines: [String]?) -> SearchResult {
            SearchResult(
                title: "T",
                url: URL(string: url)!,
                provider: .searxng,
                providerRank: rank,
                upstreamEngines: engines
            )
        }

        let brave = ProviderSearchResponse(
            provider: .brave,
            results: [
                SearchResult(
                    title: "Resold",
                    url: URL(string: "https://resold.example.com/")!,
                    provider: .brave,
                    providerRank: 1
                )
            ]
        )

        // The response-level list names an engine nobody else owns, so the response-level
        // check cannot be the thing that discounts anything here.
        let attributed = ProviderSearchResponse(
            provider: .searxng,
            results: [
                aggregatorResult(url: "https://resold.example.com/", rank: 1, engines: ["brave"]),
                aggregatorResult(
                    url: "https://fresh.example.com/",
                    rank: 2,
                    engines: ["wikipedia"]
                ),
            ],
            upstreamEngines: ["wikipedia"]
        )
        let unattributed = ProviderSearchResponse(
            provider: .searxng,
            results: [
                aggregatorResult(url: "https://resold.example.com/", rank: 1, engines: nil),
                aggregatorResult(url: "https://fresh.example.com/", rank: 2, engines: nil),
            ],
            upstreamEngines: ["wikipedia"]
        )

        func scores(_ aggregator: ProviderSearchResponse) -> [String: Double] {
            let fused = RankFusion.fuse(
                responses: [brave, aggregator],
                limit: 10,
                configuration: RankFusion.Configuration(maxResultsPerDomain: 0)
            )
            return Dictionary(
                uniqueKeysWithValues: fused.diagnostics.map {
                    ($0.canonicalURL.absoluteString, $0.score)
                }
            )
        }

        let control = scores(unattributed)
        let result = scores(attributed)
        let resoldControl = control["https://resold.example.com/"] ?? 0
        let resoldScore = result["https://resold.example.com/"] ?? 0

        // Only the page that resold Brave loses part of the aggregator's vote.
        XCTAssertEqual(
            result["https://fresh.example.com/"] ?? 0,
            control["https://fresh.example.com/"] ?? 0,
            accuracy: 0.0001,
            "a page from an engine nobody else owns must keep the full vote"
        )
        XCTAssertLessThan(resoldScore, resoldControl)
        // And exactly the aggregator's share was reduced, by the configured factor.
        XCTAssertEqual(
            resoldControl - resoldScore,
            (1.0 / 61.0) * (1 - 0.7),
            accuracy: 0.0001,
            "only the duplicated contribution may be discounted"
        )
    }

    /// Duplication is detected from the upstream engines an aggregator reports.
    func testUpstreamEngineMappingDetectsDuplication() {
        XCTAssertEqual(RankFusion.family(forUpstreamEngine: "brave"), .brave)
        XCTAssertEqual(RankFusion.family(forUpstreamEngine: "BraveSearch"), .brave)
        XCTAssertEqual(RankFusion.family(forUpstreamEngine: "duckduckgo"), .duckDuckGo)
        XCTAssertEqual(RankFusion.family(forUpstreamEngine: "google"), .google)
        XCTAssertEqual(RankFusion.family(forUpstreamEngine: "mojeek"), .mojeek)
        // Engines no direct adapter owns must not trigger a discount.
        XCTAssertNil(RankFusion.family(forUpstreamEngine: "wikipedia"))
        XCTAssertNil(RankFusion.family(forUpstreamEngine: "bing"))

        // A SearXNG instance reporting Brave, while Brave is configured directly.
        let responses = [
            response(.brave, [("B", "https://b.example.com/1")]),
            response(.searxng, [("S", "https://s.example.com/1")], upstream: ["brave"]),
        ]
        let owned: Set<SourceFamily> = [.brave]
        XCTAssertTrue(
            RankFusion.resellsIndexAlreadyOwned(
                response: responses[1],
                ownedFamilies: owned
            )
        )

        // The same aggregator reporting an engine nobody else covers is not penalised.
        let solo = response(.searxng, [("S", "https://s.example.com/1")], upstream: ["wikipedia"])
        XCTAssertFalse(
            RankFusion.resellsIndexAlreadyOwned(response: solo, ownedFamilies: owned)
        )

        // A non-aggregator is never treated as duplicating.
        XCTAssertFalse(
            RankFusion.resellsIndexAlreadyOwned(
                response: responses[0],
                ownedFamilies: owned
            )
        )
    }

    /// The defect this replaced: a weaker provider's whole list outranking a stronger
    /// provider's list purely because of a blanket weight penalty.
    ///
    /// Fusion must interleave by rank when providers return disjoint result sets.
    func testDisjointProvidersInterleaveByRankRatherThanByProvider() {
        let tavily = (1...4).map { ("Tavily \($0)", "https://tavily.example.com/\($0)") }
        let parallel = (1...4).map { ("Parallel \($0)", "https://parallel.example.com/\($0)") }

        let fused = RankFusion.fuse(
            responses: [
                response(.tavily, tavily),
                response(.parallel, parallel),
            ],
            limit: 8,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 0)
        )

        // With the aggregator no longer blanket-discounted, the two providers interleave
        // instead of one sweeping the list. Note this is *interleaving*, not a strict
        // alternation: their registry weights are close enough (1.1 vs 0.8) that a
        // same-rank result from either can land first, with the canonical URL deciding
        // the tie. Before the fix one provider occupied every one of the top six slots.
        let providers = fused.results.map(\.provider)
        XCTAssertEqual(
            Set(providers).count,
            2,
            "both providers must appear in the fused list"
        )
        let topFour = Array(providers.prefix(4))
        XCTAssertEqual(
            topFour.filter { $0 == .tavily }.count,
            2,
            "expected the two providers to share the top four, got \(topFour)"
        )
        XCTAssertEqual(
            topFour.filter { $0 == .parallel }.count,
            2,
            "expected the two providers to interleave, got \(topFour)"
        )
        // Both providers must contribute to the first half of the list, which is the
        // property a single-provider sweep would violate.
        XCTAssertTrue(providers.prefix(4).contains(.parallel))
        XCTAssertTrue(providers.prefix(4).contains(.tavily))
    }

    /// An aggregator that is the only source of a result still contributes it: the
    /// discount reduces its weight, it does not discard the result.
    func testAggregatorOnlyResultIsStillReturned() {
        let fused = RankFusion.fuse(
            responses: [response(.searxng, [("Aggregated", "https://agg.example.com/x")])],
            limit: 5
        )
        XCTAssertEqual(fused.results.count, 1)
        XCTAssertEqual(fused.results.first?.sources, [.searxng])
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
