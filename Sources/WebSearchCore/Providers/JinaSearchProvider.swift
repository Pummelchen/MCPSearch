import Foundation

/// Jina Search (`s.jina.ai`) — optional hosted search with LLM-oriented context.
///
/// Kept separate from `JinaReaderFetcher`, which handles page extraction. This is the
/// search side only, and it is optional because it needs its own key path.
public struct JinaSearchProvider: SearchProvider {
    public let id: ProviderID = .jina
    public let capabilities = ProviderCapabilities(
        supportsIncludeDomains: false,
        supportsExcludeDomains: false,
        supportsRecency: false,
        supportsLocale: false,
        supportsAnswer: false,
        supportsInlineContent: true,
        supportsPagination: false
    )
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

    public static let endpoint = URL(string: "https://s.jina.ai/")!

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

        let target = JinaSearchProvider.endpoint
            .appendingPathComponent(request.normalizedQuery)

        var headers: [String: String] = [
            "Accept": "application/json",
            "X-Respond-With": "no-content",
        ]
        if !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }

        let response = try await http.send(
            HTTPRequest.get(target, headers: headers, label: "jina.search"),
            maxBytes: configuration.maxSearchResponseBytes
        )

        if response.statusCode == 401 || response.statusCode == 403 {
            throw SearchError.authenticationRequired(.jina)
        }
        if response.statusCode == 429 {
            throw SearchError.rateLimited(.jina, retryAfter: nil)
        }
        try HTTPStatusMapper.validate(
            response,
            provider: .jina,
            authenticationStatusCodes: [],
            rateLimitStatusCodes: []
        )

        let payload = try response.body.decodeJSON(
            JinaSearchResponse.self,
            provider: .jina,
            using: JSONCoding.decoder()
        )

        var seen: Set<String> = []
        var results: [SearchResult] = []
        for (index, item) in (payload.data ?? []).enumerated() {
            guard let result = ResultNormalizer.make(
                provider: .jina,
                rank: index + 1,
                title: item.title,
                urlString: item.url,
                snippet: item.description ?? item.content,
                publishedAt: item.publishedTime.flatMap(JSONCoding.date(from:)),
                content: item.content,
                request: request,
                seenKeys: &seen
            ) else { continue }
            results.append(result)
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        log.debug(
            "Jina Search complete",
            metadata: ["results": "\(results.count)", "latency_ms": "\(elapsed)"]
        )

        return ProviderSearchResponse(
            provider: .jina,
            results: results,
            latencyMilliseconds: elapsed
        )
    }

    struct JinaSearchResponse: Decodable {
        let code: Int?
        let status: String?
        let data: [Item]?

        struct Item: Decodable {
            let title: String?
            let url: String?
            let description: String?
            let content: String?
            let publishedTime: String?
        }
    }
}
