import Foundation

/// Exa — neural/semantic web retrieval, with inline highlights designed for agents.
///
/// Exa is used primarily for semantic retrieval and LLM-oriented highlights rather
/// than as a general keyword index. Highlights are requested by default because they
/// are materially more token-efficient than full page text.
public struct ExaProvider: SearchProvider {
    public let id: ProviderID = .exa
    public let fusionWeight: Double = 1.0

    private let apiKey: String
    private let http: any HTTPClient
    private let configuration: AppConfiguration
    private let log: Log

    public static let endpoint = URL(string: "https://api.exa.ai/search")!

    public init(
        apiKey: String,
        http: any HTTPClient,
        configuration: AppConfiguration,
        log: Log = .disabled
    ) {
        self.apiKey = apiKey
        self.http = http
        self.configuration = configuration
        self.log = log
    }

    public var isConfigured: Bool { !apiKey.isEmpty }

    public func search(_ request: SearchRequest) async throws -> ProviderSearchResponse {
        let started = DispatchTime.now().uptimeNanoseconds

        let body = try JSONCoding.encoder().encode(
            SearchBody(request: request, deep: request.mode.allowsDeepSearch)
        )

        let response = try await http.send(
            HTTPRequest.post(
                ExaProvider.endpoint,
                headers: [
                    "x-api-key": apiKey,
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                ],
                body: body,
                label: "exa.search"
            ),
            maxBytes: configuration.maxSearchResponseBytes
        )

        try ExaProvider.validate(response)

        let payload = try response.body.decodeJSON(
            ExaResponse.self,
            provider: .exa,
            using: JSONCoding.decoder()
        )

        var seen: Set<String> = []
        var results: [SearchResult] = []
        for (index, item) in payload.results.enumerated() {
            // Exa returns no comparable relevance score in the current schema, so
            // only the rank is carried forward.
            guard
                let result = ResultNormalizer.make(
                    provider: .exa,
                    rank: index + 1,
                    title: item.title,
                    urlString: item.url,
                    snippet: ExaProvider.snippet(from: item),
                    publishedAt: item.publishedDate.flatMap(JSONCoding.date(from:)),
                    score: nil,
                    request: request,
                    seenKeys: &seen
                )
            else { continue }
            results.append(result)
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        log.debug(
            "Exa search complete",
            metadata: ["results": "\(results.count)", "latency_ms": "\(elapsed)"]
        )

        return ProviderSearchResponse(
            provider: .exa,
            results: results,
            latencyMilliseconds: elapsed
        )
    }

    /// The first usable highlight.
    ///
    /// `contents.text` is deliberately not requested: full page text is billed per page and
    /// would inflate every search response, while `web_answer` already grounds itself in
    /// summaries. Asking for it later is a deliberate, priced decision rather than a
    /// fallback to a field that is not requested.
    static func snippet(from item: ExaResponse.Item) -> String? {
        item.highlights?.first { !$0.isEmpty }
    }

    /// Exa answers a **missing** key with `402` and an invalid key with `401`, and
    /// both are configuration problems rather than transient failures.
    static func validate(_ response: HTTPResponse) throws {
        if response.isSuccess { return }
        if response.statusCode == 401 || response.statusCode == 402 {
            throw SearchError.authenticationRequired(.exa)
        }
        try HTTPStatusMapper.validate(
            response,
            provider: .exa,
            authenticationStatusCodes: [],
            rateLimitStatusCodes: [429]
        )
    }

    // MARK: - Wire types

    struct SearchBody: Encodable {
        let query: String
        let type: String
        let numResults: Int
        var includeDomains: [String]?
        var excludeDomains: [String]?
        var startPublishedDate: String?
        var userLocation: String?
        let contents: Contents

        struct Contents: Encodable {
            let highlights: Highlights
            var maxAgeHours: Int?

            struct Highlights: Encodable {
                let highlightsPerUrl: Int
            }
        }

        init(request: SearchRequest, deep: Bool) {
            self.query = request.normalizedQuery
            // `auto` lets Exa choose; `deep` is only justified for a thorough search
            // because it costs more and is slower.
            self.type = deep ? "deep" : "auto"
            self.numResults = min(max(1, request.providerResultBudget), 100)
            self.includeDomains = request.includeDomains.isEmpty ? nil : request.includeDomains
            self.excludeDomains = request.excludeDomains.isEmpty ? nil : request.excludeDomains
            self.startPublishedDate = ExaProvider.startPublishedDate(for: request.recency)
            self.userLocation = request.locale?.region
            // Highlights are the token-efficient agent primitive: far cheaper to put
            // in a model's context than full page text.
            self.contents = Contents(
                highlights: Contents.Highlights(highlightsPerUrl: 3),
                // Omitted by default: `0` forces a live crawl, which adds latency.
                // It is only requested for an explicit recency filter.
                maxAgeHours: request.recency.isFiltering ? 0 : nil
            )
        }
    }

    /// Exa takes an absolute `startPublishedDate`, so a relative recency window is
    /// converted to an ISO 8601 instant.
    static func startPublishedDate(for recency: Recency, now: Date = Date()) -> String? {
        guard let days = recency.approximateDays else { return nil }
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: start)
    }

    /// The current Exa schema has no `score`, and `publishedDate` is documented
    /// loosely, so every field is optional here.
    struct ExaResponse: Decodable {
        let requestId: String?
        let results: [Item]
        let resolvedSearchType: String?

        struct Item: Decodable {
            let title: String?
            let url: String?
            let publishedDate: String?
            let author: String?
            let highlights: [String]?
            let summary: String?
        }
    }
}
