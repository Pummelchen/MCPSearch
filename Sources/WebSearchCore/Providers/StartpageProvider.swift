import Foundation
import SwiftSoup

/// Startpage — best-effort adapter over a Google-derived public interface,
/// **disabled by default**.
///
/// Startpage is kept as a *separate* provider ID from DuckDuckGo because it draws on
/// a different index and therefore provides different coverage, while its
/// `SourceFamily` is recorded as `.google` so the fusion layer does not treat it as
/// independent evidence alongside another Google-derived source.
///
/// Its markup is not an API contract and it is aggressive about automated access, so
/// this adapter is best-effort by design.
public struct StartpageProvider: SearchProvider {
    public let id: ProviderID = .startpage
    public let fusionWeight: Double = 1.0

    private let http: any HTTPClient
    private let configuration: AppConfiguration
    private let scrapersEnabled: Bool
    private let log: Log

    public static let endpoint = URL(string: "https://www.startpage.com/sp/search")!

    public static let containerSelectors = [
        "div.w-gl__result", "div.result", "div.w-gl__result-item",
        "section#main div.result", "div.search-result",
    ]
    public static let linkSelectors = [
        "a.w-gl__result-title", "a.result-link", "h3 a", "h2 a", "a.result-title",
    ]
    public static let snippetSelectors = [
        "p.w-gl__description", "span.w-gl__description", ".description",
        ".result-description", ".w-gl__result-description",
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
            throw SearchError.notConfigured(.startpage)
        }

        let started = DispatchTime.now().uptimeNanoseconds

        guard
            var components = URLComponents(
                url: StartpageProvider.endpoint,
                resolvingAgainstBaseURL: false
            )
        else {
            throw SearchError.unsupportedRequest(.startpage, "could not build request URL")
        }
        var items = [URLQueryItem(name: "query", value: request.normalizedQuery)]
        if let locale = request.locale {
            items.append(URLQueryItem(name: "language", value: locale.language))
        }
        if let withDate = StartpageProvider.dateFilter(for: request.recency) {
            items.append(URLQueryItem(name: "with_date", value: withDate))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw SearchError.unsupportedRequest(.startpage, "could not build request URL")
        }

        let response = try await http.send(
            HTTPRequest.get(
                url,
                headers: [
                    "Accept": "text/html,application/xhtml+xml",
                    "Accept-Language": "en-US,en;q=0.9",
                ],
                label: "startpage.search"
            ),
            maxBytes: configuration.maxSearchResponseBytes
        )

        if response.statusCode == 429 {
            throw SearchError.rateLimited(.startpage, retryAfter: nil)
        }
        // Startpage fronts automated access with challenges; a 403 is expected here
        // rather than exceptional.
        if response.statusCode == 403 {
            throw SearchError.providerUnavailable(.startpage)
        }
        guard response.isSuccess else {
            throw SearchError.providerUnavailable(.startpage)
        }

        let html = response.text()
        if ScraperSupport.detectChallenge(in: html) {
            throw SearchError.providerUnavailable(.startpage)
        }

        let page = try ScraperSupport.parse(
            html: html,
            containerSelectors: StartpageProvider.containerSelectors,
            linkSelectors: StartpageProvider.linkSelectors,
            snippetSelectors: StartpageProvider.snippetSelectors,
            base: "https://www.startpage.com",
            excludeHosts: ["startpage.com"],
            provider: .startpage
        )

        if page.results.isEmpty {
            throw SearchError.malformedResponse(.startpage)
        }

        var seen: Set<String> = []
        var results: [SearchResult] = []
        for (index, item) in page.results.enumerated() {
            guard
                let result = ResultNormalizer.make(
                    provider: .startpage,
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
            "Startpage scrape complete",
            metadata: ["results": "\(results.count)", "latency_ms": "\(elapsed)"]
        )

        return ProviderSearchResponse(
            provider: .startpage,
            results: results,
            latencyMilliseconds: elapsed,
            warnings: ["Startpage results come from an undocumented HTML interface."]
        )
    }

    /// Startpage's `with_date` values.
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
