import Foundation

/// Open Web Search — an **aggregator**, not an index.
///
/// This adapter exists because a multi-engine aggregation endpoint can return broad
/// coverage in one call. It is deliberately kept apart from the direct adapters so
/// that the same underlying source is not double-counted: results carry the
/// `.aggregator` source family, and the fusion layer discounts an aggregator vote that
/// no independent index backs.
///
/// No third-party deployment is hard-coded as a mandatory dependency. The endpoint is
/// operator-supplied via `OPEN_WEB_SEARCH_URL`, and the response parser accepts the
/// several shapes this class of service tends to use.
///
/// - Important: The wire contract here is **not verified against a published
///   specification**. It is written defensively on purpose: unknown fields are
///   ignored, several common key spellings are accepted, and an unrecognizable body
///   fails cleanly rather than producing malformed results. If you point this at a
///   service whose contract differs, the adapter reports a provider failure and the
///   rest of the pipeline is unaffected.
public struct OpenWebSearchProvider: SearchProvider {
    public let id: ProviderID = .openWebSearch
    /// Below a direct index: an aggregator is usually a reseller.
    /// Registry weight for rank fusion.
    ///
    /// Deliberately 1.0. The fusion score is `weight / (k + rank)`, so a weight ratio
    /// wider than the reachable rank ratio `(k + maxRank) / (k + 1)` — only about 1.07
    /// for five results at `k = 60` — lets one provider's *entire* list outrank
    /// another's, and fusion stops merging by rank. Provider quality is expressed
    /// through the source-family, aggregation and corroboration signals instead, which
    /// do not have that failure mode.
    public nonisolated let fusionWeight: Double = 1.0

    private let endpoint: URL
    private let http: any HTTPClient
    private let configuration: AppConfiguration
    private let log: Log

    public init(
        endpoint: URL,
        http: any HTTPClient,
        configuration: AppConfiguration,
        log: Log = .disabled
    ) {
        self.endpoint = endpoint
        self.http = http
        self.configuration = configuration
        self.log = log
    }

    public var isConfigured: Bool { true }

    public func search(_ request: SearchRequest) async throws -> ProviderSearchResponse {
        let started = DispatchTime.now().uptimeNanoseconds

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else {
            throw SearchError.unsupportedRequest(.openWebSearch, "invalid endpoint URL")
        }

        var items = components.queryItems ?? []
        // Common parameter spellings are sent under the names this class of endpoint
        // most often documents.
        items.append(URLQueryItem(name: "query", value: request.normalizedQuery))
        items.append(URLQueryItem(name: "q", value: request.normalizedQuery))
        items.append(URLQueryItem(name: "limit", value: String(request.providerResultBudget)))
        if request.recency.isFiltering {
            items.append(URLQueryItem(name: "recency", value: request.recency.rawValue))
        }
        if let locale = request.locale {
            items.append(URLQueryItem(name: "locale", value: locale.identifier))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw SearchError.unsupportedRequest(.openWebSearch, "invalid endpoint URL")
        }

        let response = try await http.send(
            HTTPRequest.get(
                url,
                headers: ["Accept": "application/json"],
                label: "open_web_search.search"
            ),
            maxBytes: configuration.maxSearchResponseBytes
        )

        try HTTPStatusMapper.validate(
            response,
            provider: .openWebSearch,
            authenticationStatusCodes: [401, 403],
            rateLimitStatusCodes: [429]
        )

        let payload = try response.body.decodeJSON(
            OpenWebSearchResponse.self,
            provider: .openWebSearch,
            using: JSONCoding.decoder()
        )

        let entries = payload.aggregatedItems
        guard !entries.isEmpty || payload.indicatesSuccess else {
            throw SearchError.malformedResponse(.openWebSearch)
        }

        var seen: Set<String> = []
        var results: [SearchResult] = []
        var upstreamEngines: Set<String> = []

        for (index, item) in entries.enumerated() {
            if let engine = item.engine { upstreamEngines.insert(engine) }
            for engine in item.engines ?? [] { upstreamEngines.insert(engine) }

            guard let result = ResultNormalizer.make(
                provider: .openWebSearch,
                rank: item.rank ?? index + 1,
                title: item.title,
                urlString: item.url ?? item.link,
                snippet: item.snippet ?? item.description ?? item.content,
                publishedAt: (item.publishedAt ?? item.published).flatMap(JSONCoding.date(from:)),
                score: item.score,
                content: nil,
                request: request,
                seenKeys: &seen
            ) else { continue }
            results.append(result)
        }

        var warnings: [String] = []
        if upstreamEngines.isEmpty {
            warnings.append(
                "Open Web Search did not report its upstream engines, so its results "
                    + "cannot be attributed to independent sources."
            )
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        log.debug(
            "Open Web Search complete",
            metadata: ["results": "\(results.count)", "latency_ms": "\(elapsed)"]
        )

        return ProviderSearchResponse(
            provider: .openWebSearch,
            results: results,
            upstreamEngines: upstreamEngines.sorted(),
            latencyMilliseconds: elapsed,
            warnings: warnings
        )
    }

    // MARK: - Wire types

    /// Accepts either a bare array of results or an envelope containing one under
    /// `results`, `data`, or `items`.
    ///
    /// Multiple spellings are accepted because no authoritative public contract for a
    /// service of this name could be verified; the adapter is written to fail cleanly
    /// rather than to assume one vendor's exact shape.
    struct OpenWebSearchResponse: Decodable {
        let results: [Item]?
        let data: [Item]?
        let items: [Item]?
        let success: Bool?
        let status: String?
        let query: String?

        var aggregatedItems: [Item] {
            results ?? data ?? items ?? []
        }

        /// Some deployments answer `200 {"results":[]}` for a genuinely empty query,
        /// which is not a malformed response.
        var indicatesSuccess: Bool {
            if success == true { return true }
            if let status, status.lowercased() == "ok" { return true }
            return results != nil || data != nil || items != nil
        }

        struct Item: Decodable {
            let title: String?
            let url: String?
            /// Alternate anchor key used by some aggregators.
            let link: String?
            let snippet: String?
            let description: String?
            let content: String?
            let score: Double?
            let rank: Int?
            let engine: String?
            let engines: [String]?
            let publishedAt: String?
            let published: String?
        }
    }
}
