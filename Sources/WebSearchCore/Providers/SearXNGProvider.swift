import Foundation

/// SearXNG — self-hosted metasearch. The best route when the requirement is
/// "no vendor account, no API key, my own infrastructure".
///
/// No public-instance list is shipped: it would be an operational liability, since
/// instances come and go and many disable the JSON API. The operator configures
/// their own base URL.
///
/// The critical operational detail is that SearXNG's shipped `settings.yml` enables
/// only the `html` format, so `format=json` returns **HTTP 403** until the operator
/// adds `json` to `search.formats`. That is a configuration problem, not a
/// transient failure, and it is reported as such rather than retried.
public struct SearXNGProvider: SearchProvider {
    public let id: ProviderID = .searxng
    /// Registry weight for rank fusion.
    ///
    /// Deliberately 1.0. The fusion score is `weight / (k + rank)`, so a weight ratio
    /// wider than the reachable rank ratio `(k + maxRank) / (k + 1)` — only about 1.07
    /// for five results at `k = 60` — lets one provider's *entire* list outrank
    /// another's, and fusion stops merging by rank. Provider quality is expressed
    /// through the source-family, aggregation and corroboration signals instead, which
    /// do not have that failure mode.
    public nonisolated let fusionWeight: Double = 1.0

    private let baseURL: URL
    private let http: any HTTPClient
    private let configuration: AppConfiguration
    private let log: Log

    public init(
        baseURL: URL,
        http: any HTTPClient,
        configuration: AppConfiguration,
        log: Log = .disabled
    ) {
        self.baseURL = baseURL
        self.http = http
        self.configuration = configuration
        self.log = log
    }

    public var isConfigured: Bool { true }

    public func search(_ request: SearchRequest) async throws -> ProviderSearchResponse {
        let started = DispatchTime.now().uptimeNanoseconds

        let endpoint = baseURL.appendingPathComponent("search")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else {
            throw SearchError.unsupportedRequest(.searxng, "invalid SearXNG base URL")
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: request.normalizedQuery),
            URLQueryItem(name: "format", value: "json"),
            // 1 = moderate. SearXNG rejects out-of-range values with 400.
            URLQueryItem(name: "safesearch", value: "1"),
        ]
        if let timeRange = request.recency.searxngValue {
            items.append(URLQueryItem(name: "time_range", value: timeRange))
        }
        if let locale = request.locale {
            items.append(URLQueryItem(name: "language", value: locale.language))
        }
        components.setQueryItemsEscapingPlus(items)

        guard let url = components.url else {
            throw SearchError.unsupportedRequest(.searxng, "invalid SearXNG base URL")
        }

        let response = try await http.send(
            HTTPRequest.get(
                url,
                headers: ["Accept": "application/json"],
                label: "searxng.search"
            ),
            maxBytes: configuration.maxSearchResponseBytes
        )

        // A 403 here is dominated by the "JSON format not enabled" case, which the
        // operator must fix. It is classified as a configuration error so it neither
        // trips the circuit breaker nor looks like a transient outage.
        if response.statusCode == 403 {
            throw SearchError.unsupportedRequest(
                .searxng,
                "the instance refused format=json; add `json` to `search.formats` in "
                    + "the instance's settings.yml"
            )
        }

        try HTTPStatusMapper.validate(
            response,
            provider: .searxng,
            authenticationStatusCodes: [401],
            rateLimitStatusCodes: [429]
        )

        let payload = try response.body.decodeJSON(
            SearXNGResponse.self,
            provider: .searxng,
            using: JSONCoding.decoder()
        )

        var seen: Set<String> = []
        var results: [SearchResult] = []
        var upstreamEngines: Set<String> = []

        for (index, item) in payload.results.enumerated() {
            if let engine = item.engine { upstreamEngines.insert(engine) }
            for engine in item.engines ?? [] { upstreamEngines.insert(engine) }

            guard
                let result = ResultNormalizer.make(
                    provider: .searxng,
                    rank: index + 1,
                    title: item.title,
                    urlString: item.url,
                    snippet: item.content,
                    // `publishedDate` is nullable ISO 8601.
                    publishedAt: item.publishedDate.flatMap(JSONCoding.date(from:)),
                    score: item.score,
                    content: nil,
                    // Per-result provenance: fusion discounts a resold index exactly rather
                    // than treating the whole response as resold.
                    upstreamEngines: Self.engines(of: item),
                    request: request,
                    seenKeys: &seen
                )
            else { continue }
            results.append(result)
        }

        var warnings: [String] = []
        // `unresponsive_engines` is a list of [engine, reason] pairs. Surfacing it
        // explains thin result sets that would otherwise look like a silent failure.
        for entry in payload.unresponsiveEngines ?? [] where entry.count >= 2 {
            warnings.append("SearXNG engine \(entry[0]) was unresponsive: \(entry[1]).")
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        log.debug(
            "SearXNG search complete",
            metadata: [
                "results": "\(results.count)",
                "engines": "\(upstreamEngines.count)",
                "latency_ms": "\(elapsed)",
            ]
        )

        return ProviderSearchResponse(
            provider: .searxng,
            results: results,
            answer: payload.answers?.lazy.compactMap(\.text).first,
            upstreamEngines: upstreamEngines.sorted(),
            latencyMilliseconds: elapsed,
            warnings: warnings
        )
    }

    // MARK: - Wire types

    /// The upstream engines one result came from, deduplicated and stably ordered.
    ///
    /// SearXNG reports `engine` for the primary engine and `engines` for a set upstream.
    /// Fusion uses this to discount a specific resold page rather than a whole response.
    static func engines(of item: SearXNGResponse.Item) -> [String]? {
        var names = Set<String>()
        if let engine = item.engine { names.insert(engine) }
        for engine in item.engines ?? [] { names.insert(engine) }
        return names.isEmpty ? nil : names.sorted()
    }

    /// Current SearXNG master returns exactly these keys. `number_of_results` is
    /// deliberately absent: it is not produced by current releases. The response's
    /// echoed `query` and its `corrections`/`suggestions` lists are not read by any
    /// code path, so they are not decoded either.
    struct SearXNGResponse: Decodable {
        let results: [Item]
        let answers: [Answer]?
        /// Array of `[engineName, errorMessage]` pairs.
        let unresponsiveEngines: [[String]]?

        /// One entry of SearXNG's `answers`.
        ///
        /// The wire type is a list of **objects**: `get_json_response` builds
        /// `[answer.as_dict() for answer in answers]`, and `as_dict()` returns
        /// `{"answer": …, "url": …, "engine": …}`. Decoding it as `[String]` did not merely
        /// return nil on such a payload — `decodeIfPresent` *throws* `typeMismatch` — so
        /// `Data.decodeJSON` turned it into `.malformedResponse(.searxng)` and the valid
        /// `results` beside it were discarded for the whole query. Plain strings are still
        /// accepted because answers are an optional extra on a response this provider does not
        /// control, and an unrecognised element must never cost the caller its results.
        enum Answer: Decodable {
            case text(String)
            case object(String?)

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self = .text(text)
                } else {
                    self = .object(try? container.decode(AnswerObject.self).answer)
                }
            }

            /// The answer text, or nil when the entry carries none.
            var text: String? {
                let value: String? =
                    switch self {
                    case .text(let text): text
                    case .object(let text): text
                    }
                guard let value, !value.isEmpty else { return nil }
                return value
            }

            private struct AnswerObject: Decodable {
                let answer: String?
            }
        }

        /// SearXNG writes snake_case for `unresponsive_engines`, so the mapping is
        /// explicit rather than uniform.
        enum CodingKeys: String, CodingKey {
            case results, answers
            case unresponsiveEngines = "unresponsive_engines"
        }

        struct Item: Decodable {
            let url: String?
            let title: String?
            let content: String?
            /// Nullable ISO 8601.
            let publishedDate: String?
            let engine: String?
            /// A set upstream, so element order is not meaningful.
            let engines: [String]?
            let score: Double?
        }
    }
}

extension Recency {
    /// SearXNG's `time_range`. `week` is accepted by the implementation even though
    /// it is missing from the published documentation.
    var searxngValue: String? {
        switch self {
        case .any: nil
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .year: "year"
        }
    }
}
