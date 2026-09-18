import Foundation

/// Mojeek — an independent crawler index, valuable for index diversity.
///
/// Mojeek's API is a paid product with a limited trial rather than a durable free
/// quota, so it is optional rather than a default zero-cost path. It earns its place
/// because it is a genuinely independent crawl, not another reseller.
///
/// Two API quirks are load-bearing and easy to get wrong:
/// - Authentication is an **`api_key` query parameter**, not a header.
/// - An invalid key returns **HTTP 200** with an error string inside
///   `response.status`, so status alone is not enough to detect failure.
public struct MojeekProvider: SearchProvider {
    public let id: ProviderID = .mojeek
    public let fusionWeight: Double = 1.0

    private let apiKey: String
    private let http: any HTTPClient
    private let configuration: AppConfiguration
    private let log: Log

    public static let endpoint = URL(string: "https://api.mojeek.com/search")!
    /// Mojeek's per-page ceiling on entry plans.
    public static let maxResultsPerPage = 40
    /// Documented maximum number of `fi`/`fe` domains.
    public static let maxDomains = 25

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
                url: MojeekProvider.endpoint,
                resolvingAgainstBaseURL: false
            )
        else {
            throw SearchError.unsupportedRequest(.mojeek, "could not build request URL")
        }

        // `fmt` defaults to xml, so it must always be sent explicitly.
        var items: [URLQueryItem] = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "q", value: request.normalizedQuery),
            URLQueryItem(name: "fmt", value: "json"),
            // `s` is a 1-based start offset: 1 is the first result.
            URLQueryItem(name: "s", value: "1"),
            URLQueryItem(
                name: "t",
                value: String(
                    min(MojeekProvider.maxResultsPerPage, max(1, request.providerResultBudget))
                )
            ),
            // Mojeek spells safe search `safe`; `safesearch` does not exist.
            URLQueryItem(name: "safe", value: "1"),
        ]

        if let since = MojeekProvider.sinceValue(for: request.recency) {
            items.append(URLQueryItem(name: "since", value: since))
        }
        if !request.includeDomains.isEmpty {
            items.append(
                URLQueryItem(
                    name: "fi",
                    // Mojeek takes a comma-separated list. A space-joined list is sent as one
                    // malformed domain, so the filter silently does nothing and the caller gets
                    // unfiltered results while believing the filter applied (ledger A0046).
                    value: request.includeDomains.prefix(MojeekProvider.maxDomains)
                        .joined(separator: ",")
                )
            )
        }
        if !request.excludeDomains.isEmpty {
            items.append(
                URLQueryItem(
                    name: "fe",
                    // Comma-separated, like `fi` above.
                    value: request.excludeDomains.prefix(MojeekProvider.maxDomains)
                        .joined(separator: ",")
                )
            )
        }
        components.setQueryItemsEscapingPlus(items)

        guard let url = components.url else {
            throw SearchError.unsupportedRequest(.mojeek, "could not build request URL")
        }

        // The key travels in the query string, so it must never be logged. Only the
        // label is recorded.
        let response = try await http.send(
            HTTPRequest.get(url, headers: ["Accept": "application/json"], label: "mojeek.search"),
            maxBytes: configuration.maxSearchResponseBytes
        )

        guard response.isSuccess else {
            // 403 with an empty body is what Mojeek returns when credentials are
            // missing entirely.
            try HTTPStatusMapper.validate(
                response,
                provider: .mojeek,
                authenticationStatusCodes: [401, 403],
                rateLimitStatusCodes: [429]
            )
            throw SearchError.unsupportedRequest(
                .mojeek,
                "unexpected status HTTP \(response.statusCode)"
            )
        }

        let payload = try response.body.decodeJSON(
            MojeekResponse.self,
            provider: .mojeek,
            using: JSONCoding.decoder()
        )

        // A bad key arrives as HTTP 200 with an error in `response.status`, so the
        // envelope must be inspected before the results are trusted.
        let status = payload.response?.status ?? ""
        if MojeekProvider.isAuthenticationStatus(status) {
            throw SearchError.authenticationRequired(.mojeek)
        }
        if MojeekProvider.isQuotaStatus(status) {
            throw SearchError.rateLimited(.mojeek, retryAfter: nil)
        }
        if !MojeekProvider.isSuccessStatus(status) {
            throw SearchError.providerUnavailable(.mojeek)
        }

        var seen: Set<String> = []
        var results: [SearchResult] = []
        for (index, item) in (payload.response?.results ?? []).enumerated() {
            // Mojeek's `timestamp` is the last-modified time, in epoch seconds.
            let published = item.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            guard
                let result = ResultNormalizer.make(
                    provider: .mojeek,
                    rank: index + 1,
                    title: item.title,
                    urlString: item.url,
                    // Mojeek calls the snippet `desc`, not `description`.
                    snippet: item.desc,
                    publishedAt: published,
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
            "Mojeek search complete",
            metadata: ["results": "\(results.count)", "latency_ms": "\(elapsed)"]
        )

        return ProviderSearchResponse(
            provider: .mojeek,
            results: results,
            totalEstimatedMatches: payload.response?.head?.results,
            latencyMilliseconds: elapsed
        )
    }

    /// Mojeek's `since` filter accepts `day`, `month`, `year`, or a `YYYYMMDD` date.
    /// Note there is no `week` value, so a week window is expressed as a date.
    static func sinceValue(for recency: Recency, now: Date = Date()) -> String? {
        switch recency {
        case .any: nil
        case .day: "day"
        case .week: MojeekProvider.dateString(daysAgo: 7, now: now)
        case .month: "month"
        case .year: "year"
        }
    }

    static func dateString(daysAgo: Int, now: Date = Date()) -> String {
        let date = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func isSuccessStatus(_ status: String) -> Bool {
        status.uppercased().hasPrefix("OK")
    }

    static func isAuthenticationStatus(_ status: String) -> Bool {
        let lowered = status.lowercased()
        return lowered.contains("access denied") || lowered.contains("invalid key")
            || lowered.contains("password") || lowered.contains("permission")
    }

    static func isQuotaStatus(_ status: String) -> Bool {
        let lowered = status.lowercased()
        return lowered.contains("limit") || lowered.contains("quota")
            || lowered.contains("exceed")
    }

    // MARK: - Wire types

    struct MojeekResponse: Decodable {
        let response: Body?

        struct Body: Decodable {
            let status: String?
            let head: Head?
            let results: [Item]?

            /// Only `results` is read: `totalEstimatedMatches` is taken from it. The
            /// cursor fields (`start`, `return`) and the two redundant date spellings
            /// (`date`, `pdate`) carried no value, so they are not decoded at all
            struct Head: Decodable {
                let results: Int?
            }

            struct Item: Decodable {
                let url: String?
                let title: String?
                let desc: String?
                let score: Double?
                /// Last-modified time, epoch seconds. This is the only date Mojeek
                /// returns that is used.
                let timestamp: Int?
            }
        }
    }
}
