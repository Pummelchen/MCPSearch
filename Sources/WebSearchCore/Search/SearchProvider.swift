import Foundation

// MARK: - Provider identity

/// Stable identifier for every search backend the server can talk to.
///
/// The raw values are part of the public MCP tool schema (`provider` parameter),
/// so they must not be renamed without a compatibility story.
public enum ProviderID: String, Codable, Sendable, Hashable, CaseIterable {
    case tavily
    case brave
    case mojeek
    case exa
    case searxng
    case openWebSearch = "open_web_search"
    case duckDuckGo = "duckduckgo"
    case startpage
    case parallel
    case jina

    /// Human-readable name, used in diagnostics only.
    public var displayName: String {
        switch self {
        case .tavily: "Tavily"
        case .brave: "Brave Search"
        case .mojeek: "Mojeek"
        case .exa: "Exa"
        case .searxng: "SearXNG"
        case .openWebSearch: "Open Web Search"
        case .duckDuckGo: "DuckDuckGo"
        case .startpage: "Startpage"
        case .parallel: "Parallel Search MCP"
        case .jina: "Jina Search"
        }
    }
}

// MARK: - Source families

/// The upstream index a provider ultimately reads from.
///
/// Two providers in the same family are not independent evidence: a Brave result
/// that also arrives through a SearXNG instance that has Brave enabled must not
/// receive two full votes during rank fusion. The orchestrator uses this to apply
/// a source-family penalty.
public enum SourceFamily: String, Codable, Sendable, Hashable, CaseIterable {
    /// Tavily's own retrieval pipeline.
    case tavily
    /// Brave's independent crawler index.
    case brave
    /// Mojeek's independent crawler index.
    case mojeek
    /// Exa's neural/semantic retrieval.
    case exa
    /// Google-derived results (Startpage fronts Google).
    case google
    /// Crawler indexes reachable through the DuckDuckGo public interface.
    case duckDuckGo
    /// A metasearch layer whose upstream engines are not fully known.
    case meta
    /// A third-party aggregation/MCP service.
    case aggregator
    /// Content-extraction service that also offers search.
    case jina

    /// Whether results from this family come from an independent crawl rather
    /// than a reseller of somebody else's index.
    public var isIndependentIndex: Bool {
        switch self {
        case .brave, .mojeek, .tavily: true
        case .exa, .google, .duckDuckGo, .meta, .aggregator, .jina: false
        }
    }
}

extension ProviderID {
    /// The index family this provider reads from.
    public var sourceFamily: SourceFamily {
        switch self {
        case .tavily: .tavily
        case .brave: .brave
        case .mojeek: .mojeek
        case .exa: .exa
        case .searxng: .meta
        case .openWebSearch: .aggregator
        case .duckDuckGo: .duckDuckGo
        case .startpage: .google
        case .parallel: .aggregator
        case .jina: .jina
        }
    }

    /// Whether this provider aggregates other engines rather than owning an index.
    public var isAggregator: Bool {
        switch self {
        case .searxng, .openWebSearch, .parallel: true
        default: false
        }
    }

    /// Whether this provider relies on undocumented HTML scraping.
    public var isExperimentalScraper: Bool {
        switch self {
        case .duckDuckGo, .startpage: true
        default: false
        }
    }

    /// Whether the provider serves direct web search results.
    /// (`jina` is fetch-oriented; `parallel` is an upstream MCP service.)
    public var isSearchProvider: Bool {
        self != .jina
    }
}

// MARK: - Capabilities

/// Declares which parts of the common request model a provider can honour.
///
/// The orchestrator uses this to avoid passing filters a provider would silently
/// ignore (for example, Mojeek has no domain allow-list), and to decide whether a
/// provider can serve a request at all.
public struct ProviderCapabilities: Sendable, Hashable, Codable {
    /// Provider can restrict/expand results by domain.
    public var supportsIncludeDomains: Bool
    /// Provider can exclude results by domain.
    public var supportsExcludeDomains: Bool
    /// Provider can filter by publication recency.
    public var supportsRecency: Bool
    /// Provider can honour a locale / market hint.
    public var supportsLocale: Bool
    /// Provider returns an AI-generated answer alongside results.
    public var supportsAnswer: Bool
    /// Provider returns page content or highlights inline.
    public var supportsInlineContent: Bool
    /// Provider can return more than one page of results.
    public var supportsPagination: Bool

    public init(
        supportsIncludeDomains: Bool = false,
        supportsExcludeDomains: Bool = false,
        supportsRecency: Bool = false,
        supportsLocale: Bool = false,
        supportsAnswer: Bool = false,
        supportsInlineContent: Bool = false,
        supportsPagination: Bool = false
    ) {
        self.supportsIncludeDomains = supportsIncludeDomains
        self.supportsExcludeDomains = supportsExcludeDomains
        self.supportsRecency = supportsRecency
        self.supportsLocale = supportsLocale
        self.supportsAnswer = supportsAnswer
        self.supportsInlineContent = supportsInlineContent
        self.supportsPagination = supportsPagination
    }

    /// A provider with no optional filters — always usable for a bare query.
    public static let minimal = ProviderCapabilities()
}

// MARK: - The provider protocol

/// The single seam between the orchestrator and any search backend.
///
/// Implementations must be `Sendable` and must not own mutable shared state
/// beyond actors. They must honour task cancellation and must never write to
/// stdout.
public protocol SearchProvider: Sendable {
    /// Stable identifier, also used as the provenance tag on results.
    var id: ProviderID { get }

    /// Human-readable name for diagnostics.
    var displayName: String { get }

    /// What this provider can do with the common request model.
    var capabilities: ProviderCapabilities { get }

    /// Whether the provider has the credentials/endpoint it needs to run.
    var isConfigured: Bool { get }

    /// Relative weight applied during reciprocal rank fusion.
    var fusionWeight: Double { get }

    /// Run one search. Throwing is expected and normal; the orchestrator
    /// converts errors into failover decisions.
    func search(_ request: SearchRequest) async throws -> ProviderSearchResponse
}

extension SearchProvider {
    public var displayName: String { id.displayName }
    public var isConfigured: Bool { true }
    public var fusionWeight: Double { 1.0 }
    public var capabilities: ProviderCapabilities { .minimal }
}
