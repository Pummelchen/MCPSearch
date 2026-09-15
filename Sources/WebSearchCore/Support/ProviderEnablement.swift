import Foundation

/// The configuration inputs that enable each search provider — the single authority.
///
/// "Which variable enables me" used to be written out in five places: the pipeline factory's
/// per-provider `notes`, the tool layer's `unconfiguredHint`, `ProviderProbe.setupHint`, the
/// registry's ineligible reasons, and the server's startup inventory. They had already drifted
/// for `parallel`, which needs **two** inputs: the tool told the operator to set
/// `SEARCH_ENABLE_PARALLEL=true` in exactly the state where that flag was already on and the
/// missing input was the endpoint, while the server's own startup comment recorded the opposite
/// (ledger B57). Every consumer now reads this type, so a change to one provider's requirements
/// cannot reach one surface and miss another.
public enum ProviderEnablement {

    /// One environment variable a provider needs before it can serve a search.
    public enum Input: Sendable, Hashable {
        case tavilyAPIKey
        case braveAPIKey
        case mojeekAPIKey
        case exaAPIKey
        case searxngBaseURL
        case openWebSearchURL
        case scrapersEnabled
        case parallelEnabled
        case parallelEndpoint

        /// The variable's name, taken from `AppConfiguration.Key` — already the one place an
        /// environment variable is spelled out.
        public var variableName: String {
            switch self {
            case .tavilyAPIKey: AppConfiguration.Key.tavilyAPIKey.rawValue
            case .braveAPIKey: AppConfiguration.Key.braveAPIKey.rawValue
            case .mojeekAPIKey: AppConfiguration.Key.mojeekAPIKey.rawValue
            case .exaAPIKey: AppConfiguration.Key.exaAPIKey.rawValue
            case .searxngBaseURL: AppConfiguration.Key.searxngBaseURL.rawValue
            case .openWebSearchURL: AppConfiguration.Key.openWebSearchURL.rawValue
            case .scrapersEnabled: AppConfiguration.Key.enableScrapers.rawValue
            case .parallelEnabled: AppConfiguration.Key.enableParallel.rawValue
            case .parallelEndpoint: AppConfiguration.Key.parallelMCPURL.rawValue
            }
        }

        /// Whether the variable is a switch to turn on rather than a value to fill in.
        public var isSwitch: Bool {
            switch self {
            case .scrapersEnabled, .parallelEnabled: true
            default: false
            }
        }

        /// What an operator sets, as it should appear in a message they will act on.
        public var assignment: String {
            isSwitch ? "\(variableName)=true" : variableName
        }

        /// Why the input is needed, when naming the variable is not enough. The SearXNG entry is
        /// the deployment mistake `scripts/searxng_health.py` exists for: the stock image serves
        /// only HTML, so a base URL alone still yields 403s.
        public var purpose: String? {
            switch self {
            case .searxngBaseURL: "to an instance with JSON output enabled"
            case .scrapersEnabled: "to enable scrapers"
            case .parallelEnabled: "to enable the upstream MCP provider"
            case .parallelEndpoint: "to the upstream MCP endpoint"
            default: nil
            }
        }

        /// The complete clause for this input: "TAVILY_API_KEY", "PARALLEL_MCP_URL to the
        /// upstream MCP endpoint".
        var clause: String {
            guard let purpose else { return assignment }
            return "\(assignment) \(purpose)"
        }
    }

    /// Every input `id` needs, in the order an operator should provide them.
    ///
    /// An exhaustive `switch` on purpose: a new `ProviderID` does not compile until its
    /// requirements are stated here.
    public static func inputs(for id: ProviderID) -> [Input] {
        switch id {
        case .tavily: [.tavilyAPIKey]
        case .brave: [.braveAPIKey]
        case .mojeek: [.mojeekAPIKey]
        case .exa: [.exaAPIKey]
        case .searxng: [.searxngBaseURL]
        case .openWebSearch: [.openWebSearchURL]
        case .duckDuckGo, .startpage: [.scrapersEnabled]
        case .parallel: [.parallelEnabled, .parallelEndpoint]
        }
    }

    /// Every input any provider can use, deduplicated in provider order.
    ///
    /// The startup inventory and the "no search provider is configured" error both need the
    /// complete list, and both used to build it from a hand-written copy of the provider table.
    public static var allInputs: [Input] {
        ProviderID.allCases
            .flatMap { inputs(for: $0) }
            .reduce(into: [Input]()) { all, input in
                if !all.contains(input) { all.append(input) }
            }
    }

    /// The inputs `configuration` has not satisfied, in the order to set them.
    public static func missingInputs(
        for id: ProviderID,
        in configuration: AppConfiguration
    ) -> [Input] {
        inputs(for: id).filter { !configuration.satisfies($0) }
    }

    /// Whether every input is present, i.e. whether the provider can run at all.
    public static func isSatisfied(_ id: ProviderID, in configuration: AppConfiguration) -> Bool {
        missingInputs(for: id, in: configuration).isEmpty
    }

    /// The inputs to name in a message.
    ///
    /// A provider that reports itself unusable with every input present has no missing variable
    /// to name, so its full requirement is named rather than producing an empty sentence.
    public static func inputsToName(
        for id: ProviderID,
        in configuration: AppConfiguration
    ) -> [Input] {
        let missing = missingInputs(for: id, in: configuration)
        return missing.isEmpty ? inputs(for: id) : missing
    }

    /// A complete, actionable sentence: "Set X and Y=1 to enable …."
    public static func instruction(for id: ProviderID, in configuration: AppConfiguration) -> String {
        "Set " + inputsToName(for: id, in: configuration).map(\.clause).joined(separator: " and ")
            + "."
    }

    /// The bare assignments, for a surface that supplies its own wording, joined the way a
    /// sentence lists them: `"X and Y=1"`.
    public static func assignmentList(
        for id: ProviderID,
        in configuration: AppConfiguration
    ) -> String {
        inputsToName(for: id, in: configuration).map(\.assignment).joined(separator: " and ")
    }
}

extension AppConfiguration {
    /// Whether one enablement input is present.
    ///
    /// The only place a `ProviderEnablement.Input` is read from configuration, so a provider
    /// reads its value here and nowhere else.
    public func satisfies(_ input: ProviderEnablement.Input) -> Bool {
        switch input {
        case .tavilyAPIKey: tavilyAPIKey?.isEmpty == false
        case .braveAPIKey: braveAPIKey?.isEmpty == false
        case .mojeekAPIKey: mojeekAPIKey?.isEmpty == false
        case .exaAPIKey: exaAPIKey?.isEmpty == false
        case .searxngBaseURL: searxngBaseURL != nil
        case .openWebSearchURL: openWebSearchURL != nil
        case .scrapersEnabled: enableScrapers
        case .parallelEnabled: enableParallel
        case .parallelEndpoint: parallelMCPURL != nil
        }
    }
}
