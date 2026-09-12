import Foundation

// MARK: - Result

/// One normalized search result.
///
/// `provider`/`providerRank` are rewritten during fusion: the merged result keeps
/// the *best* (lowest) rank it achieved and lists every provider that returned it
/// in `sources`.
public struct SearchResult: Sendable, Hashable, Codable {
    public var title: String
    public var url: URL
    public var snippet: String?
    public var publishedAt: Date?
    /// The provider that supplied the version of this result being reported.
    public var provider: ProviderID
    /// 1-based rank within the supplying provider's own result list.
    public var providerRank: Int
    /// The provider's own relevance score. **Never compare across providers** —
    /// scores are not on a shared scale. Fusion is rank-based.
    public var providerScore: Double?
    /// Inline page content/highlights when the provider supplies it.
    public var content: String?
    /// Canonical form of `url`, used as the deduplication key.
    public var canonicalURL: URL
    /// Every provider that returned this result, best-ranked first.
    public var sources: [ProviderID]

    public init(
        title: String,
        url: URL,
        snippet: String? = nil,
        publishedAt: Date? = nil,
        provider: ProviderID,
        providerRank: Int,
        providerScore: Double? = nil,
        content: String? = nil,
        canonicalURL: URL? = nil,
        sources: [ProviderID]? = nil
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.publishedAt = publishedAt
        self.provider = provider
        self.providerRank = providerRank
        self.providerScore = providerScore
        self.content = content
        self.canonicalURL = canonicalURL ?? URLCanonicalizer.canonicalize(url)
        self.sources = sources ?? [provider]
    }

    public static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.canonicalURL == rhs.canonicalURL
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalURL)
    }
}

// MARK: - Provider-level response

/// What a single provider returned for a single request.
public struct ProviderSearchResponse: Sendable, Hashable, Codable {
    public let provider: ProviderID
    public var results: [SearchResult]
    /// Provider-supplied direct answer, when the vendor offers one.
    public var answer: String?
    /// Number of results the provider claimed to have, when it says.
    public var totalEstimatedMatches: Int?
    /// Upstream engines the aggregator actually used, when it reports them.
    /// Used for source-family deduplication and provenance.
    public var upstreamEngines: [String]
    public var latencyMilliseconds: Int
    public var warnings: [String]

    public init(
        provider: ProviderID,
        results: [SearchResult],
        answer: String? = nil,
        totalEstimatedMatches: Int? = nil,
        upstreamEngines: [String] = [],
        latencyMilliseconds: Int = 0,
        warnings: [String] = []
    ) {
        self.provider = provider
        self.results = results
        self.answer = answer
        self.totalEstimatedMatches = totalEstimatedMatches
        self.upstreamEngines = upstreamEngines
        self.latencyMilliseconds = latencyMilliseconds
        self.warnings = warnings
    }
}

// MARK: - Fused response

/// The fused, deduplicated answer to one `web_search` call.
public struct SearchResponse: Sendable, Hashable, Codable {
    public let query: String
    public var results: [SearchResult]
    public var providersUsed: [ProviderID]
    public var providersFailed: [ProviderFailure]
    public var retrievedAt: Date
    public var elapsedMilliseconds: Int
    public var warnings: [String]
    /// True when the result set came from cache rather than the network.
    public var servedFromCache: Bool

    public init(
        query: String,
        results: [SearchResult],
        providersUsed: [ProviderID],
        providersFailed: [ProviderFailure] = [],
        retrievedAt: Date = Date(),
        elapsedMilliseconds: Int = 0,
        warnings: [String] = [],
        servedFromCache: Bool = false
    ) {
        self.query = query
        self.results = results
        self.providersUsed = providersUsed
        self.providersFailed = providersFailed
        self.retrievedAt = retrievedAt
        self.elapsedMilliseconds = elapsedMilliseconds
        self.warnings = warnings
        self.servedFromCache = servedFromCache
    }

    /// Whether any usable result exists. Drives `isError` on the MCP response.
    public var hasUsableResults: Bool { !results.isEmpty }
}

// MARK: - Fetch result

/// Outcome of `web_open`.
public struct FetchResult: Sendable, Hashable, Codable {
    /// The URL actually fetched, after redirects.
    public let finalURL: URL
    public let statusCode: Int
    public let contentType: String?
    public let title: String?
    public let text: String
    /// How the readable text was produced.
    public let method: ExtractionMethod
    public let truncated: Bool
    /// Warnings accumulated by the fetch pipeline; mutable so the orchestrating
    /// fetcher can append fallback notes.
    public var warnings: [String]
    public var elapsedMilliseconds: Int

    public init(
        finalURL: URL,
        statusCode: Int,
        contentType: String?,
        title: String?,
        text: String,
        method: ExtractionMethod,
        truncated: Bool,
        warnings: [String] = [],
        elapsedMilliseconds: Int = 0
    ) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.contentType = contentType
        self.title = title
        self.text = text
        self.method = method
        self.truncated = truncated
        self.warnings = warnings
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    /// Which extraction path produced the text.
    public enum ExtractionMethod: String, Sendable, Hashable, Codable {
        /// Plain text/JSON/XML body returned as-is.
        case rawText = "raw_text"
        /// SwiftSoup readability-style extraction from HTML.
        case htmlExtraction = "html_extraction"
        /// Jina Reader fallback for JS-heavy or extraction-resistant pages.
        case jinaReader = "jina_reader"
    }

    /// Whether the readable text already opens with the document title.
    ///
    /// A rendered result used to print a synthesised `# Title` heading above a body that
    /// almost always begins with that same title, so the title appeared twice on nearly
    /// every page. Callers use this to decide whether the heading adds anything.
    ///
    /// The comparison ignores case, diacritics and surrounding whitespace, and tolerates a
    /// leading Markdown or plain heading marker on either side.
    public var textAlreadyOpensWithTitle: Bool {
        guard let title, !title.isEmpty else { return false }
        let firstLine =
            text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let normalizedLine = FetchResult.strippingHeadingMarkers(firstLine)
        let normalizedTitle = FetchResult.strippingHeadingMarkers(title)
        guard !normalizedLine.isEmpty, !normalizedTitle.isEmpty else { return false }
        return normalizedLine.compare(
            normalizedTitle,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    /// Trim whitespace and any leading `#` characters from a single line.
    private static func strippingHeadingMarkers(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        while trimmed.hasPrefix("#") {
            trimmed.removeFirst()
        }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }
}
