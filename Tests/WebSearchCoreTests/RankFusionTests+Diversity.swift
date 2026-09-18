import Foundation
import XCTest
@testable import WebSearchCore

extension RankFusionTests {

    func testAggregatorDiscountFallsBackToResponseLevelWithoutPerResultEngines() {
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
        let aggregator = ProviderSearchResponse(
            provider: .searxng,
            results: [
                SearchResult(
                    title: "Resold",
                    url: URL(string: "https://resold.example.com/")!,
                    provider: .searxng,
                    providerRank: 1
                ),
                SearchResult(
                    title: "Fresh",
                    url: URL(string: "https://fresh.example.com/")!,
                    provider: .searxng,
                    providerRank: 2
                ),
            ],
            upstreamEngines: ["brave"]
        )

        let fused = RankFusion.fuse(
            responses: [brave, aggregator],
            limit: 10,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 0)
        )
        let scores = Dictionary(
            uniqueKeysWithValues: fused.diagnostics.map {
                ($0.canonicalURL.absoluteString, $0.score)
            }
        )

        XCTAssertEqual(
            scores["https://resold.example.com/"] ?? 0,
            (1.0 / 61.0) + (0.7 / 61.0),
            accuracy: 0.0001,
            "without per-result engines the response-level list discounts the resold page"
        )
        XCTAssertEqual(
            scores["https://fresh.example.com/"] ?? 0,
            0.7 / 62.0,
            accuracy: 0.0001,
            "without per-result engines the response-level list applies to every result"
        )
    }

    /// Reselling a family that is not an independent index is not duplicating an owned index.
    ///
    /// Startpage and DuckDuckGo are themselves resellers, so a SearXNG response that only used
    /// Google has not duplicated an index the way a second Brave would. The per-result path has
    /// always required `isIndependentIndex`; the response-level fallback must agree, or the
    /// answer depends on which level the adapter happened to report engines at.
    func testResponseLevelDiscountIgnoresNonIndependentFamilies() {
        let startpage = ProviderSearchResponse(
            provider: .startpage,
            results: [
                SearchResult(
                    title: "Google page",
                    url: URL(string: "https://g.example.com/")!,
                    provider: .startpage,
                    providerRank: 1
                )
            ]
        )
        let aggregator = ProviderSearchResponse(
            provider: .searxng,
            results: [
                SearchResult(
                    title: "Fresh",
                    url: URL(string: "https://fresh.example.com/")!,
                    provider: .searxng,
                    providerRank: 1
                )
            ],
            upstreamEngines: ["google"]
        )

        let fused = RankFusion.fuse(
            responses: [startpage, aggregator],
            limit: 10,
            configuration: RankFusion.Configuration(maxResultsPerDomain: 0)
        )
        XCTAssertEqual(
            fused.diagnostics.first { $0.canonicalURL.absoluteString == "https://fresh.example.com/" }?
                .score ?? 0,
            1.0 / 61.0,
            accuracy: 0.0001,
            "reselling a non-independent family must not discount the aggregator"
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

        // A response-level hit on a family that is not an independent index is not a
        // duplicated owned index, matching the per-result test.
        let nonIndependent = response(
            .searxng,
            [("S", "https://s.example.com/1")],
            upstream: ["google"]
        )
        XCTAssertFalse(
            RankFusion.resellsIndexAlreadyOwned(
                response: nonIndependent,
                ownedFamilies: [.google]
            )
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

    func testRichestSnippetAndEarliestDateArePreserved() throws {
        var seen: Set<String> = []
        let short = try XCTUnwrap(
            ResultNormalizer.make(
                provider: .tavily,
                rank: 1,
                title: "T",
                urlString: "https://example.com/p",
                snippet: "short",
                publishedAt: Date(timeIntervalSince1970: 2000),
                request: Fixtures.request(),
                seenKeys: &seen
            ))
        var seen2: Set<String> = []
        let rich = try XCTUnwrap(
            ResultNormalizer.make(
                provider: .brave,
                rank: 1,
                title: "T",
                urlString: "https://example.com/p",
                snippet: "a much longer and more informative snippet",
                publishedAt: Date(timeIntervalSince1970: 1000),
                request: Fixtures.request(),
                seenKeys: &seen2
            ))

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
