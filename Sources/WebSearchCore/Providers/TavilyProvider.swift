import Foundation

/// Tavily — AI-oriented web search. The primary provider when configured.
///
/// Tavily's own relevance score is preserved on each result for display, but fusion
/// is rank-based; the score is never compared against another vendor's.
public struct TavilyProvider: SearchProvider {
    public let id: ProviderID = .tavily
    /// Registry weight for rank fusion.
    ///
    /// Deliberately 1.0. The fusion score is `weight / (k + rank)`, so a weight ratio
    /// wider than the reachable rank ratio `(k + maxRank) / (k + 1)` — only about 1.07
    /// for five results at `k = 60` — lets one provider's *entire* list outrank
    /// another's, and fusion stops merging by rank. Provider quality is expressed
    /// through the source-family, aggregation and corroboration signals instead, which
    /// do not have that failure mode.
    public nonisolated let fusionWeight: Double = 1.0

    private let apiKey: String
    private let http: any HTTPClient
    private let configuration: AppConfiguration
    private let log: Log

    public static let endpoint = URL(string: "https://api.tavily.com/search")!

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
        let body = try JSONCoding.encoder().encode(SearchBody(request: request, deep: request.mode.allowsDeepSearch))

        var httpRequest = HTTPRequest.post(
            TavilyProvider.endpoint,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                // Tavily returns JSON; ask for it explicitly rather than relying on
                // content negotiation defaults.
                "Accept": "application/json",
            ],
            body: body,
            label: "tavily.search"
        )
        httpRequest.headers["User-Agent"] = configuration.userAgent

        let response = try await http.send(
            httpRequest,
            maxBytes: configuration.maxSearchResponseBytes
        )

        try HTTPStatusMapper.validate(
            response,
            provider: .tavily,
            authenticationStatusCodes: [401, 403],
            rateLimitStatusCodes: [429]
        )

        // Decoded with default keys, NOT `.convertFromSnakeCase`. The DTO declares
        // explicit `CodingKeys` for the snake_case fields (`published_date`), and a
        // snake-case strategy converts the incoming key to `publishedDate` *before*
        // matching those keys — so the field silently decodes to nil. Every multi-word
        // field here has an explicit mapping, so the strategy must stay off.
        let payload = try response.body.decodeJSON(
            TavilyResponse.self,
            provider: .tavily,
            using: JSONCoding.decoder()
        )

        var seen: Set<String> = []
        var results: [SearchResult] = []
        for (index, item) in payload.results.enumerated() {
            guard
                let result = ResultNormalizer.make(
                    provider: .tavily,
                    rank: index + 1,
                    title: item.title,
                    urlString: item.url,
                    snippet: item.content,
                    publishedAt: item.publishedDate.flatMap(JSONCoding.date(from:)),
                    score: item.score,
                    content: nil,
                    request: request,
                    seenKeys: &seen
                )
            else { continue }
            results.append(result)
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        log.debug(
            "Tavily search complete",
            metadata: ["results": "\(results.count)", "latency_ms": "\(elapsed)"]
        )

        return ProviderSearchResponse(
            provider: .tavily,
            results: results,
            answer: payload.answer.flatMap { $0.isEmpty ? nil : $0 },
            latencyMilliseconds: elapsed
        )
    }

    // MARK: - Wire types

    struct SearchBody: Encodable {
        let query: String
        let maxResults: Int
        let searchDepth: String
        let topic: String
        var timeRange: String?
        /// Tavily only returns `published_date` when asked, so a recency filter is
        /// only verifiable if we also request the date.
        var includePublishedDate: Bool?
        var includeDomains: [String]?
        var excludeDomains: [String]?
        let includeAnswer: Bool

        enum CodingKeys: String, CodingKey {
            case query
            case maxResults = "max_results"
            case searchDepth = "search_depth"
            case topic
            case timeRange = "time_range"
            case includePublishedDate = "include_published_date"
            case includeDomains = "include_domains"
            case excludeDomains = "exclude_domains"
            case includeAnswer = "include_answer"
        }

        init(request: SearchRequest, deep: Bool) {
            self.query = request.normalizedQuery
            self.maxResults = min(max(1, request.providerResultBudget), 20)
            // `basic` costs one credit; `advanced` costs two, so only an explicit
            // thorough search may request it.
            self.searchDepth = deep ? "advanced" : "basic"
            self.topic = "general"
            // Tavily accepts day/week/month/year directly; `any` omits the field.
            // Tavily has no `days` parameter: unknown fields are rejected with 400.
            self.timeRange = request.recency.isFiltering ? request.recency.rawValue : nil
            self.includePublishedDate = request.recency.isFiltering ? true : nil
            self.includeDomains = request.includeDomains.isEmpty ? nil : request.includeDomains
            self.excludeDomains = request.excludeDomains.isEmpty ? nil : request.excludeDomains
            // Answers materially increase the value of a fast search for an agent.
            self.includeAnswer = true
        }
    }

    /// Tavily writes snake_case, and every multi-word field is mapped explicitly here.
    ///
    /// Because the mapping is explicit, this type must be decoded with default keys:
    /// `.convertFromSnakeCase` would rewrite `published_date` to `publishedDate` before
    /// these keys are consulted, leaving the field nil.
    ///
    /// The envelope's echoed `query` is not read by any code path and is not decoded
    /// (ledger B66).
    struct TavilyResponse: Decodable {
        let answer: String?
        let results: [Item]

        struct Item: Decodable {
            let title: String?
            let url: String?
            let content: String?
            let score: Double?
            /// RFC 1123-style (`Tue, 11 Mar 2025 17:00:00 GMT`), which
            /// `JSONCoding.date(from:)` handles.
            let publishedDate: String?

            enum CodingKeys: String, CodingKey {
                case title, url, content, score
                case publishedDate = "published_date"
            }
        }
    }
}
