import Foundation

/// Maps HTTP status codes onto the shared `SearchError` taxonomy.
///
/// Every adapter funnels its response through this so that a 401 is classified as a
/// configuration problem (which must not trip a circuit breaker) while a 503 is
/// classified as transient (which must).
public enum HTTPStatusMapper {
    /// - Parameters:
    ///   - authenticationStatusCodes: Statuses this vendor uses for bad credentials.
    ///   - rateLimitStatusCodes: Statuses this vendor uses for throttling.
    ///   - notFoundIsEmpty: When true, a 404 is treated as "no results" rather than
    ///     an error. Some endpoints do this for an empty result set.
    public static func validate(
        _ response: HTTPResponse,
        provider: ProviderID,
        authenticationStatusCodes: Set<Int> = [401, 403],
        rateLimitStatusCodes: Set<Int> = [429],
        notFoundIsEmpty: Bool = false
    ) throws {
        guard !response.isSuccess else { return }

        if authenticationStatusCodes.contains(response.statusCode) {
            throw SearchError.authenticationRequired(provider)
        }
        if rateLimitStatusCodes.contains(response.statusCode) {
            throw SearchError.rateLimited(
                provider,
                retryAfter: RetryAfter.parse(response.header("Retry-After"))
            )
        }
        if notFoundIsEmpty, response.statusCode == 404 {
            return
        }
        switch response.statusCode {
        case 400, 422:
            throw SearchError.unsupportedRequest(
                provider,
                "upstream rejected the request (HTTP \(response.statusCode))"
            )
        case 500...599:
            throw SearchError.providerUnavailable(provider)
        default:
            throw SearchError.unsupportedRequest(
                provider,
                "unexpected status HTTP \(response.statusCode)"
            )
        }
    }

    /// Map a transport error onto a provider-scoped `SearchError`.
    public static func map(_ error: any Error, provider: ProviderID) -> SearchError {
        if let searchError = error as? SearchError { return searchError }
        if error is CancellationError { return .networkFailure(provider, "cancelled") }
        if let httpError = error as? HTTPError {
            switch httpError {
            case .timedOut: return .timeout(provider)
            case .cancelled: return .networkFailure(provider, "cancelled")
            case .connectionFailed(_, let reason),
                 .transportFailure(_, let reason):
                return .networkFailure(provider, reason)
            case .responseTooLarge:
                return .malformedResponse(provider)
            case .invalidURL(let detail):
                return .unsupportedRequest(provider, detail)
            }
        }
        if let urlError = error as? URLError {
            // A URL must never reach a diagnostic: Mojeek authenticates through the query
            // string, so a platform description that echoes the request echoes a key.
            return .networkFailure(provider, HTTPError.reason(for: urlError.code))
        }
        return .networkFailure(provider, error.localizedDescription)
    }
}
