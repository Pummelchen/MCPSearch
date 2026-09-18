import Foundation

/// Brave Search — broad-web search against Brave's own crawler index.
///
/// Brave is treated as a major *independent index* source, not as another view of
/// somebody else's results, which is why its fusion weight is high.
public struct BraveProvider: SearchProvider {
    public let id: ProviderID = .brave
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

    public static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!

    /// Brave's documented maximum for `count`.
    public static let maxCount = 20

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

        guard
            var components = URLComponents(
                url: BraveProvider.endpoint,
                resolvingAgainstBaseURL: false
            )
        else {
            throw SearchError.unsupportedRequest(.brave, "could not build request URL")
        }

        // Brave bills per request, not per result, and its minimum useful page is
        // 20 results. Requesting a full page costs the same as asking for 3, so
        // round up and let fusion discard the surplus.
        let count = min(
            BraveProvider.maxCount,
            max(BraveProvider.minimumUsefulCount, request.providerResultBudget)
        )

        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: request.normalizedQuery),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "result_filter", value: "web"),
            URLQueryItem(name: "extra_snippets", value: "true"),
            // We do our own display formatting; Brave's decoration markers would
            // leak `<strong>`-style markup into model context.
            URLQueryItem(name: "text_decorations", value: "false"),
        ]

        if let freshness = BraveProvider.freshness(for: request.recency) {
            items.append(URLQueryItem(name: "freshness", value: freshness))
        }
        if let locale = request.locale {
            items.append(URLQueryItem(name: "search_lang", value: locale.language))
            if let region = locale.region {
                items.append(URLQueryItem(name: "country", value: region))
                items.append(URLQueryItem(name: "ui_lang", value: locale.identifier))
            }
        }
        components.setQueryItemsEscapingPlus(items)

        guard let url = components.url else {
            throw SearchError.unsupportedRequest(.brave, "could not build request URL")
        }

        let httpRequest = HTTPRequest.get(
            url,
            headers: [
                "X-Subscription-Token": apiKey,
                "Accept": "application/json",
                "Accept-Encoding": "gzip",
                "Cache-Control": "no-cache",
            ],
            label: "brave.search"
        )

        let response = try await http.send(
            httpRequest,
            maxBytes: configuration.maxSearchResponseBytes
        )

        try BraveProvider.validate(response)

        let payload = try response.body.decodeJSON(
            BraveResponse.self,
            provider: .brave,
            using: JSONCoding.decoder()
        )

        var seen: Set<String> = []
        var results: [SearchResult] = []
        for (index, item) in (payload.web?.results ?? []).enumerated() {
            // Brave exposes up to five alternative excerpts. The first is the
            // snippet; the rest are appended only when the primary is thin, to
            // avoid burning context on near-duplicate text.
            let snippet = BraveProvider.composeSnippet(item)
            guard
                let result = ResultNormalizer.make(
                    provider: .brave,
                    rank: index + 1,
                    title: item.title,
                    urlString: item.url,
                    snippet: snippet,
                    publishedAt: item.pageAge.flatMap(JSONCoding.date(from:)),
                    score: nil,
                    content: nil,
                    request: request,
                    seenKeys: &seen
                )
            else { continue }
            results.append(result)
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        log.debug(
            "Brave search complete",
            metadata: ["results": "\(results.count)", "latency_ms": "\(elapsed)"]
        )

        var warnings: [String] = []
        if let altered = payload.query?.altered, altered != payload.query?.original {
            // Brave rewrote the query; worth surfacing because result relevance
            // depends on it.
            warnings.append("Brave interpreted the query as \"\(altered)\".")
        }

        return ProviderSearchResponse(
            provider: .brave,
            results: results,
            totalEstimatedMatches: nil,
            latencyMilliseconds: elapsed,
            warnings: warnings
        )
    }

    /// Brave's cheapest sensible page size. A smaller `count` is not cheaper.
    static let minimumUsefulCount = 20

    /// Map the neutral recency filter onto Brave's `freshness` values.
    static func freshness(for recency: Recency) -> String? {
        switch recency {
        case .any: nil
        case .day: "pd"
        case .week: "pw"
        case .month: "pm"
        case .year: "py"
        }
    }

    /// Combine `description` with any `extra_snippets` that add information.
    static func composeSnippet(_ item: BraveResponse.Web.Result) -> String? {
        var parts: [String] = []
        if let description = item.description, !description.isEmpty {
            parts.append(description)
        }
        for extra in item.extraSnippets ?? [] where !extra.isEmpty {
            // Skip excerpts already contained in what we have.
            if parts.contains(where: { $0.localizedCaseInsensitiveContains(extra) }) { continue }
            parts.append(extra)
            if parts.count >= 3 { break }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Brave signals an invalid key with `422` plus an error code, not with `401`,
    /// so status alone is not enough to classify the failure.
    static func validate(_ response: HTTPResponse) throws {
        if response.isSuccess { return }

        if response.statusCode == 422 {
            let payload = try? JSONCoding.decoder().decode(
                BraveErrorResponse.self,
                from: response.body
            )
            let code = payload?.error?.code?.uppercased() ?? ""
            if code.contains("SUBSCRIPTION_TOKEN")
                || payload?.error?.meta?.component?.lowercased() == "authentication"
            {
                throw SearchError.authenticationRequired(.brave)
            }
            throw SearchError.unsupportedRequest(.brave, "upstream rejected the parameters")
        }

        try HTTPStatusMapper.validate(
            response,
            provider: .brave,
            authenticationStatusCodes: [401, 403],
            rateLimitStatusCodes: [429]
        )
    }

    // MARK: - Wire types

    /// Brave's response `type` and the error body's `id`/`status`/`detail`/`type` are
    /// not read by any code path, so they are not decoded.
    struct BraveResponse: Decodable {
        let query: Query?
        let web: Web?

        struct Query: Decodable {
            let original: String?
            let altered: String?

            enum CodingKeys: String, CodingKey {
                case original, altered
            }
        }

        struct Web: Decodable {
            let results: [Result]?

            struct Result: Decodable {
                let title: String?
                let url: String?
                let description: String?
                /// ISO 8601 without a timezone suffix, e.g. `2025-04-12T14:22:41`.
                let pageAge: String?
                let extraSnippets: [String]?

                /// Brave writes snake_case, and the decoder is configured for default
                /// keys, so every multi-word field needs an explicit mapping. Without
                /// this the property decodes to nil silently.
                enum CodingKeys: String, CodingKey {
                    case title, url, description
                    case pageAge = "page_age"
                    case extraSnippets = "extra_snippets"
                }
            }
        }
    }

    struct BraveErrorResponse: Decodable {
        let error: ErrorBody?

        struct ErrorBody: Decodable {
            let code: String?
            let meta: Meta?

            struct Meta: Decodable {
                let component: String?
            }
        }
    }
}
