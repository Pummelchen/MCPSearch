import Foundation

// MARK: - Errors

/// Stable internal error categories.
///
/// Adapters throw these; the orchestrator maps them onto failover decisions and
/// `ProviderFailure.FailureCategory`. Nothing here is ever surfaced verbatim to a
/// model in a way that could contain credentials.
public enum SearchError: Error, Sendable, Hashable {
    case invalidRequest(String)
    case authenticationRequired(ProviderID)
    case rateLimited(ProviderID, retryAfter: Duration?)
    case providerUnavailable(ProviderID)
    case timeout(ProviderID)
    case malformedResponse(ProviderID)
    case networkFailure(ProviderID, String)
    case notConfigured(ProviderID)
    case unsupportedRequest(ProviderID, String)
    case allProvidersFailed
    /// No provider produced a usable result, with the per-provider reasons attached.
    ///
    /// Carrying the reasons matters most when a single provider was requested
    /// explicitly: "All eligible search providers failed" tells a caller nothing, while
    /// "Startpage is temporarily unavailable" is actionable. The first few reasons are
    /// included in `safeDescription` so the message is useful without a second call to
    /// `web_search_status`.
    case providersFailed([ProviderFailure])
    /// No provider was even attempted, because every candidate was excluded by its
    /// circuit breaker or by the local rate limiter.
    ///
    /// This is transient by construction: the caller should retry, and it must **not**
    /// be reported as an invalid request. A sustained run reaches it legitimately, since
    /// each search spends one request against every provider it fans out to.
    case temporarilyUnavailable([ProviderFailure])
    case blockedURL(URL)
    case extractionFailed(URL)
    /// A page fetch failed for a reason other than policy or extraction, such as a
    /// connection error or a timeout.
    ///
    /// Deliberately *not* provider-scoped: `web_open` connects directly to the target
    /// host, so attributing the failure to a search provider would be misleading (it
    /// previously surfaced as "Tavily timed out" for unrelated hosts).
    case fetchFailed(URL, reason: String)
    /// Grounded answer synthesis failed. Distinct from a search failure: the search
    /// itself succeeded, and its results are still returned alongside this error.
    case synthesisFailed(String)

    /// Coarse category used for logging and health accounting.
    public var category: ProviderFailure.FailureCategory {
        switch self {
        case .invalidRequest: .unsupportedRequest
        case .authenticationRequired: .authentication
        case .rateLimited: .rateLimited
        case .providerUnavailable: .serverError
        case .timeout: .timeout
        case .malformedResponse: .malformedResponse
        case .networkFailure: .network
        case .notConfigured: .notConfigured
        case .unsupportedRequest: .unsupportedRequest
        case .allProvidersFailed, .providersFailed: .unknown
        case .temporarilyUnavailable: .rateLimited
        case .blockedURL: .unsupportedRequest
        case .extractionFailed: .malformedResponse
        case .fetchFailed: .network
        case .synthesisFailed: .unknown
        }
    }

    /// The provider this error belongs to, when it belongs to one.
    public var provider: ProviderID? {
        switch self {
        case .authenticationRequired(let id),
             .rateLimited(let id, _),
             .providerUnavailable(let id),
             .timeout(let id),
             .malformedResponse(let id),
             .networkFailure(let id, _),
             .notConfigured(let id),
             .unsupportedRequest(let id, _):
            id
        case .invalidRequest, .allProvidersFailed, .providersFailed,
             .temporarilyUnavailable, .blockedURL, .extractionFailed, .fetchFailed,
             .synthesisFailed:
            nil
        }
    }

    /// Message safe to show a model or operator. Deliberately excludes headers,
    /// keys and raw bodies.
    public var safeDescription: String {
        switch self {
        case .invalidRequest(let detail):
            "Invalid request: \(detail)"
        case .authenticationRequired(let id):
            "\(id.displayName) rejected the configured credentials."
        case .rateLimited(let id, let retryAfter):
            if let retryAfter {
                "\(id.displayName) rate limited the request; retry after \(retryAfter)."
            } else {
                "\(id.displayName) rate limited the request."
            }
        case .providerUnavailable(let id):
            "\(id.displayName) is temporarily unavailable."
        case .timeout(let id):
            "\(id.displayName) timed out."
        case .malformedResponse(let id):
            "\(id.displayName) returned a response that could not be parsed."
        case .networkFailure(let id, let reason):
            "\(id.displayName) network failure: \(reason)"
        case .notConfigured(let id):
            "\(id.displayName) is not configured."
        case .unsupportedRequest(let id, let detail):
            "\(id.displayName) cannot serve this request: \(detail)"
        case .allProvidersFailed:
            "All eligible search providers failed."
        case .providersFailed(let failures):
            SearchError.describe(failures)
        case .temporarilyUnavailable(let failures):
            "No search provider was attempted: every candidate is temporarily "
                + "unavailable. Retry shortly."
                + (failures.isEmpty ? "" : " " + failures.map(\.message).joined(separator: " "))
        case .blockedURL(let url):
            "Blocked URL: \(url.host() ?? url.absoluteString)"
        case .fetchFailed(let url, let reason):
            "Could not fetch \(url.host() ?? url.absoluteString): \(reason)"
        case .synthesisFailed(let reason):
            "Answer synthesis failed: \(reason)"
        case .extractionFailed(let url):
            "Could not extract readable content from \(url.host() ?? url.absoluteString)."
        }
    }
}

extension SearchError {
    /// Summarise per-provider failures into one actionable sentence.
    ///
    /// Lists every provider when there are few, so a search that degraded across several
    /// providers is fully explained in one message.
    public static func describe(_ failures: [ProviderFailure]) -> String {
        guard !failures.isEmpty else {
            return "All eligible search providers failed."
        }
        let parts = failures.map { failure in
            "\(failure.provider.displayName): \(failure.message)"
        }
        return "No search provider produced results. " + parts.joined(separator: " ")
    }
}

extension ProviderFailure {
    /// Build a failure record from a thrown error, without leaking secrets.
    public init(provider: ProviderID, error: any Error) {
        if let searchError = error as? SearchError {
            self.init(
                provider: provider,
                category: searchError.category,
                message: searchError.safeDescription
            )
        } else if error is CancellationError {
            self.init(provider: provider, category: .cancelled, message: "Request cancelled.")
        } else if let urlError = error as? URLError {
            let category: FailureCategory =
                switch urlError.code {
                case .timedOut: .timeout
                case .cancelled: .cancelled
                case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                     .dnsLookupFailed, .cannotFindHost:
                    .network
                default: .unknown
                }
            self.init(
                provider: provider,
                category: category,
                message: urlError.localizedDescription
            )
        } else {
            self.init(
                provider: provider,
                category: .unknown,
                // `localizedDescription` on arbitrary errors cannot contain our
                // secrets because we never put them in error payloads.
                message: error.localizedDescription
            )
        }
    }
}
