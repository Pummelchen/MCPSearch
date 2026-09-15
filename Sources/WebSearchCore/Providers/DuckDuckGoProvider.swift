import Foundation
import SwiftSoup

/// DuckDuckGo — best-effort public-search adapter, **disabled by default**.
///
/// This is an escape hatch for when no supported API or SearXNG route is available.
/// The public HTML interface is not an API contract: selectors change, bot challenges
/// appear, and regional behaviour differs. Enable it only with
/// `SEARCH_ENABLE_SCRAPERS=true`, and treat any result as lower confidence than an API
/// provider. Ranking does not express that: every provider carries the same fusion weight
/// on purpose, because a weight ratio wider than the reachable rank ratio lets one
/// provider's whole list outrank another's. Scrapers are held back by being opt-in, rate
/// limited and off by default, not by a scoring penalty.
public struct DuckDuckGoProvider: SearchProvider {
    public let id: ProviderID = .duckDuckGo
    /// Registry weight for rank fusion. Deliberately the same as every other provider;
    /// see the note above for why scrapers are not down-weighted here.
    public let fusionWeight: Double = 1.0

    private let http: any HTTPClient
    private let configuration: AppConfiguration
    private let scrapersEnabled: Bool
    private let log: Log

    public static let endpoint = URL(string: "https://html.duckduckgo.com/html/")!

    /// Result containers, most specific first.
    public static let containerSelectors = [
        "div.result", "div.web-result", "div.results_links", "article[data-testid=result]",
        "div[data-testid=result]", "li.result",
    ]
    public static let linkSelectors = [
        "a.result__a", "h2 a", "a.result-link", "a[data-testid=result-title-a]",
    ]
    public static let snippetSelectors = [
        "a.result__snippet", ".result__snippet", "td.result-snippet", ".result-snippet",
        "[data-result=snippet]", "div.result__body + div",
    ]

    public init(
        http: any HTTPClient,
        configuration: AppConfiguration,
        scrapersEnabled: Bool,
        log: Log = .disabled
    ) {
        self.http = http
        self.configuration = configuration
        self.scrapersEnabled = scrapersEnabled
        self.log = log
    }

    public var isConfigured: Bool { scrapersEnabled }

    public func search(_ request: SearchRequest) async throws -> ProviderSearchResponse {
        guard scrapersEnabled else {
            throw SearchError.notConfigured(.duckDuckGo)
        }

        let started = DispatchTime.now().uptimeNanoseconds

        guard
            var components = URLComponents(
                url: DuckDuckGoProvider.endpoint,
                resolvingAgainstBaseURL: false
            )
        else {
            throw SearchError.unsupportedRequest(.duckDuckGo, "could not build request URL")
        }
        var items = [URLQueryItem(name: "q", value: request.normalizedQuery)]
        // `kl` is DDG's region hint; it is best-effort and undocumented.
        if let hint = DuckDuckGoProvider.localeHint(for: request.locale) {
            items.append(URLQueryItem(name: "kl", value: hint))
        }
        if let df = DuckDuckGoProvider.dateFilter(for: request.recency) {
            items.append(URLQueryItem(name: "df", value: df))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw SearchError.unsupportedRequest(.duckDuckGo, "could not build request URL")
        }

        let response = try await http.send(
            HTTPRequest.get(
                url,
                headers: [
                    "Accept": "text/html,application/xhtml+xml",
                    "Accept-Language": "en-US,en;q=0.9",
                ],
                label: "duckduckgo.search"
            ),
            maxBytes: configuration.maxSearchResponseBytes
        )

        if response.statusCode == 429 {
            throw SearchError.rateLimited(.duckDuckGo, retryAfter: nil)
        }
        // DuckDuckGo answers automated requests with HTTP 202 and an "anomaly modal"
        // challenge page rather than 403, so the status must be checked explicitly.
        if response.statusCode == 202 {
            throw SearchError.providerUnavailable(.duckDuckGo)
        }
        guard response.isSuccess else {
            throw SearchError.providerUnavailable(.duckDuckGo)
        }

        let page = try ScraperSupport.parse(
            html: response.text(),
            containerSelectors: DuckDuckGoProvider.containerSelectors,
            linkSelectors: DuckDuckGoProvider.linkSelectors,
            snippetSelectors: DuckDuckGoProvider.snippetSelectors,
            base: "https://duckduckgo.com",
            // DDG's own hosts appear in navigation and redirect wrappers.
            excludeHosts: ["duckduckgo.com", "duck.co"],
            provider: .duckDuckGo
        )

        // A challenge page and a genuine empty result set need different handling.
        if page.detectedBlock == .botChallenge {
            throw SearchError.providerUnavailable(.duckDuckGo)
        }
        if page.results.isEmpty {
            throw SearchError.malformedResponse(.duckDuckGo)
        }

        var seen: Set<String> = []
        var results: [SearchResult] = []
        for (index, item) in page.results.enumerated() {
            guard
                let result = ResultNormalizer.make(
                    provider: .duckDuckGo,
                    rank: index + 1,
                    title: item.title,
                    urlString: item.url,
                    snippet: item.snippet,
                    request: request,
                    seenKeys: &seen
                )
            else { continue }
            results.append(result)
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        log.debug(
            "DuckDuckGo scrape complete",
            metadata: ["results": "\(results.count)", "latency_ms": "\(elapsed)"]
        )

        return ProviderSearchResponse(
            provider: .duckDuckGo,
            results: results,
            latencyMilliseconds: elapsed,
            warnings: ["DuckDuckGo results come from an undocumented HTML interface."]
        )
    }

    /// DDG's `df` date filter values.
    /// DDG's `kl` value for a locale hint: `region-language` (`us-en`, `de-de`).
    ///
    /// The hint is best-effort and undocumented, but both parts are needed: sending the region in
    /// both positions produced `us-us`, which is not a `kl` value at all (ledger B60). A locale
    /// without a region has no hint to send, so none is.
    static func localeHint(for locale: LocaleHint?) -> String? {
        guard let locale, let region = locale.region, !region.isEmpty, !locale.language.isEmpty
        else { return nil }
        return "\(region.lowercased())-\(locale.language.lowercased())"
    }

    static func dateFilter(for recency: Recency) -> String? {
        switch recency {
        case .any: nil
        case .day: "d"
        case .week: "w"
        case .month: "m"
        case .year: "y"
        }
    }
}
