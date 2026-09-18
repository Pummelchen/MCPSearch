import Foundation
import XCTest

@testable import WebSearchCore

final class RankFusionTests: XCTestCase {

    /// - Parameter resultEngines: per-result provenance, as an adapter that reports the
    ///   engine behind each individual result supplies it.
    func response(
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

    func testSameProviderListingDuplicateURLOnlyVotesOnce() throws {
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

    func testAggregatorAloneIsDiscountedAgainstIndependentIndex() throws {
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
        XCTAssertEqual(Set(try XCTUnwrap(diagnostics).providers), Set([.brave, .searxng]))
        XCTAssertFalse(try XCTUnwrap(diagnostics).hasIndependentCorroboration)
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
    func testAggregatorIsDiscountedOnlyWhenItResellsAnOwnedIndex() throws {
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
    func testAggregatorDiscountUsesPerResultEngines() throws {
        func aggregatorResult(url: String, rank: Int, engines: [String]?) throws -> SearchResult {
            SearchResult(
                title: "T",
                url: try XCTUnwrap(URL(string: url)),
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
                try aggregatorResult(url: "https://resold.example.com/", rank: 1, engines: ["brave"]),
                try aggregatorResult(
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
                try aggregatorResult(url: "https://resold.example.com/", rank: 1, engines: nil),
                try aggregatorResult(url: "https://fresh.example.com/", rank: 2, engines: nil),
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

    /// The response-level engine list is a fallback, not an override.
    ///
    /// A response can name an owned index at the response level while its individual results
    /// carry their own attribution, and only one of them resold that index. ORing the two levels
    /// discounted every sibling of the one resold page, so two results with different provenance
    /// got the same weight. The per-result attribution must win.
    func testAggregatorDiscountIsPerResultEvenWhenTheResponseNamesAnOwnedIndex() throws {
        func aggregatorResult(url: String, rank: Int, engines: [String]?) throws -> SearchResult {
            SearchResult(
                title: "T",
                url: try XCTUnwrap(URL(string: url)),
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
        // The response-level list names Brave, so the whole-response answer is "yes"; the
        // per-result attribution says the second page came from an engine nobody owns.
        let aggregator = ProviderSearchResponse(
            provider: .searxng,
            results: [
                try aggregatorResult(url: "https://resold.example.com/", rank: 1, engines: ["brave"]),
                try aggregatorResult(
                    url: "https://fresh.example.com/",
                    rank: 2,
                    engines: ["wikipedia"]
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

        // Brave's own vote plus SearXNG's discounted one.
        XCTAssertEqual(
            scores["https://resold.example.com/"] ?? 0,
            (1.0 / 61.0) + (0.7 / 61.0),
            accuracy: 0.0001,
            "the page whose own engines name an owned index must be discounted"
        )
        // The sibling keeps the full aggregator vote: nothing in *its* attribution is owned.
        XCTAssertEqual(
            scores["https://fresh.example.com/"] ?? 0,
            1.0 / 62.0,
            accuracy: 0.0001,
            "a result whose own engines name nobody else's index must keep the full vote"
        )
    }

    /// The response-level list still decides when results carry no attribution at all.
    ///
    /// Adapters that report engines only for the whole response have no finer signal to offer,
    /// so the fallback must remain; otherwise their aggregator vote would never be discounted
}
