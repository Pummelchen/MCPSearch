import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Transport-agnostic messages

/// An outbound HTTP request. Providers build these; they never touch URLSession
/// directly, which keeps retry, timeout and size policy in one place.
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// Stable label used in logs, e.g. `tavily.search`.
    public var label: String
    /// Overrides the shared request timeout for this call only.
    ///
    /// Search endpoints answer in a second or two, so the default is deliberately
    /// short. A generative model is a different traffic class: it can legitimately
    /// take tens of seconds, and clipping it at the search timeout would turn a
    /// slow success into a spurious failure.
    public var timeout: Duration?

    public init(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        label: String = "http",
        timeout: Duration? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.label = label
        self.timeout = timeout
    }

    public static func get(
        _ url: URL,
        headers: [String: String] = [:],
        label: String = "http",
        timeout: Duration? = nil
    ) -> HTTPRequest {
        HTTPRequest(method: "GET", url: url, headers: headers, label: label, timeout: timeout)
    }

    public static func post(
        _ url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        label: String = "http",
        timeout: Duration? = nil
    ) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            url: url,
            headers: headers,
            body: body,
            label: label,
            timeout: timeout
        )
    }

    /// Whether this request may safely be retried.
    public var isIdempotent: Bool {
        method == "GET" || method == "HEAD" || method == "PUT" || method == "DELETE"
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    /// The final URL after redirects.
    public let url: URL

    public init(statusCode: Int, headers: [String: String], body: Data, url: URL) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.url = url
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        let lowered = name.lowercased()
        if let direct = headers[lowered] { return direct }
        for (key, value) in headers where key.lowercased() == lowered { return value }
        return nil
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// Decode the body as UTF-8 text, falling back to Latin-1 so a mislabelled
    /// page does not become "malformed".
    public func text() -> String {
        if let string = String(data: body, encoding: .utf8) { return string }
        if let string = String(data: body, encoding: .isoLatin1) { return string }
        return ""
    }
}

// MARK: - Errors

/// Transport-level failures, before any provider interpretation.
public enum HTTPError: Error, Sendable, Hashable {
    case timedOut(label: String)
    case cancelled(label: String)
    case connectionFailed(label: String, reason: String)
    case responseTooLarge(label: String, limit: Int)
    case invalidURL(String)
    case transportFailure(label: String, reason: String)

    public var isTransient: Bool {
        switch self {
        case .timedOut, .connectionFailed, .transportFailure: true
        case .cancelled, .responseTooLarge, .invalidURL: false
        }
    }
}

// MARK: - Policy

/// Retry and size policy shared by every provider.
public struct HTTPPolicy: Sendable, Hashable {
    /// Status codes worth retrying: transient server and throttling conditions.
    /// Notably this excludes every other 4xx, because 400/401/403 mean the request
    /// or the credentials are wrong and retrying only wastes quota.
    public static let retryableStatusCodes: Set<Int> = [408, 425, 429, 500, 502, 503, 504]

    public var requestTimeout: Duration
    public var maxAttempts: Int
    /// Base delays between attempts; jitter is added on top.
    public var backoffSchedule: [Duration]
    /// Upper bound on a `Retry-After` we are willing to honour, so a hostile or
    /// confused server cannot stall the whole search budget.
    public var maxRetryAfter: Duration

    public init(
        requestTimeout: Duration = .seconds(10),
        maxAttempts: Int = 3,
        backoffSchedule: [Duration] = [.milliseconds(200), .milliseconds(500)],
        maxRetryAfter: Duration = .seconds(5)
    ) {
        self.requestTimeout = requestTimeout
        self.maxAttempts = max(1, maxAttempts)
        self.backoffSchedule = backoffSchedule
        self.maxRetryAfter = maxRetryAfter
    }

    /// Attempts = 1 initial try + configured retries.
    public static func standard(_ configuration: AppConfiguration) -> HTTPPolicy {
        HTTPPolicy(
            requestTimeout: configuration.requestTimeout,
            maxAttempts: configuration.maxRetryAttempts + 1
        )
    }

    /// Backoff delay for a given attempt index (0-based: the first retry is 0).
    public func backoff(forRetryIndex index: Int) -> Duration {
        guard !backoffSchedule.isEmpty else { return .milliseconds(200) }
        let base = backoffSchedule[min(index, backoffSchedule.count - 1)]
        // Full jitter across [0.5x, 1.5x] keeps thundering herds apart while
        // remaining bounded and testable.
        let factor = Double.random(in: 0.5...1.5)
        return .milliseconds(max(1, Int(Double(base.milliseconds) * factor)))
    }
}

// MARK: - Client

/// The one shared HTTP abstraction. Providers depend on this protocol so they can
/// be tested against a stub transport with no network access.
public protocol HTTPClient: Sendable {
    /// Send a request, applying retry/backoff/size policy.
    /// - Parameter maxBytes: hard cap on the response body size.
    func send(_ request: HTTPRequest, maxBytes: Int) async throws -> HTTPResponse
}

extension HTTPClient {
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await send(request, maxBytes: 4 * 1024 * 1024)
    }
}

/// URLSession-backed client.
///
/// All mutable state lives in the session, which is itself thread-safe, so this is
/// an immutable `Sendable` value rather than an actor. That avoids serializing
/// concurrent provider calls behind a single actor.
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let policy: HTTPPolicy
    private let log: Log
    private let userAgent: String

    public init(
        configuration: AppConfiguration,
        log: Log = .disabled,
        session: URLSession? = nil
    ) {
        self.policy = HTTPPolicy.standard(configuration)
        self.log = log
        self.userAgent = configuration.userAgent

        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest =
                configuration.requestTimeout.seconds
            sessionConfiguration.timeoutIntervalForResource =
                URLSessionHTTPClient.resourceTimeout(for: configuration)
            // Use the platform proxy/credential machinery but never a shared cookie jar:
            // this process must not carry state between unrelated searches.
            sessionConfiguration.httpCookieAcceptPolicy = .never
            sessionConfiguration.httpShouldSetCookies = false
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    /// Total time one response may take, from the longest per-request budget this client can be
    /// asked to honour.
    ///
    /// `timeoutIntervalForResource` is a *total* cap, not an inactivity one, so deriving it from
    /// the ordinary request timeout meant it silently cut off every longer override: the 45 s
    /// synthesis budget died at 30 s, and `SEARCH_SYNTHESIS_TIMEOUT_MS` above 30 000 had no
    /// effect at all. The inactivity timeout still bounds a stalled transfer; this
    /// one only has to clear the largest budget the caller can ask for.
    ///
    /// Exposed as a pure function so the relationship is testable without waiting 30 seconds.
    public static func resourceTimeout(for configuration: AppConfiguration) -> TimeInterval {
        let longestBudget = max(
            configuration.requestTimeout.seconds,
            configuration.synthesisTimeout.seconds
        )
        // Twice the budget plus a fixed margin: one budget for the request itself, room for a
        // retry to finish inside the same cap, and enough slack that a slow but healthy
        // response is never mistaken for a hang.
        return longestBudget * 2 + 30
    }

    public func send(_ request: HTTPRequest, maxBytes: Int) async throws -> HTTPResponse {
        var attempt = 0
        var retryIndex = 0

        while true {
            try Task.checkCancellation()
            attempt += 1

            do {
                let response = try await perform(request, maxBytes: maxBytes)
                if HTTPPolicy.retryableStatusCodes.contains(response.statusCode),
                    request.isIdempotent,
                    attempt < policy.maxAttempts
                {
                    let retryAfter = RetryAfter.parse(response.header("Retry-After"))
                    let delay = min(
                        retryAfter ?? policy.backoff(forRetryIndex: retryIndex),
                        policy.maxRetryAfter
                    )
                    log.debug(
                        "Retrying request after retryable status",
                        metadata: [
                            "label": request.label,
                            "status": "\(response.statusCode)",
                            "attempt": "\(attempt)",
                            "delay_ms": "\(delay.milliseconds)",
                            "honored_retry_after": "\(retryAfter != nil)",
                        ]
                    )
                    retryIndex += 1
                    try await Task.sleep(for: delay)
                    continue
                }
                return response
            } catch let error as HTTPError {
                guard error.isTransient,
                    request.isIdempotent,
                    attempt < policy.maxAttempts
                else { throw error }

                let delay = policy.backoff(forRetryIndex: retryIndex)
                log.debug(
                    "Retrying request after transport failure",
                    metadata: [
                        "label": request.label,
                        "attempt": "\(attempt)",
                        "delay_ms": "\(delay.milliseconds)",
                    ]
                )
                retryIndex += 1
                try await Task.sleep(for: delay)
                continue
            }
        }
    }

    /// One network round trip. Cancellation of the calling task cancels the
    /// URLSession task, so an aborted search does not keep sockets open.
    private func perform(_ request: HTTPRequest, maxBytes: Int) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = (request.timeout ?? policy.requestTimeout).seconds
        if urlRequest.value(forHTTPHeaderField: "User-Agent") == nil {
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response): (Data, URLResponse)
        do {
            // The cap is enforced while the body arrives. `data(for:)` buffers the whole
            // response first, which let one endless body exhaust memory before any check
            // could run.
            (data, response) = try await BoundedResponseBody.read(
                session,
                urlRequest,
                limit: maxBytes
            )
        } catch let error as URLError {
            throw HTTPError.from(urlError: error, label: request.label)
        } catch let error as ResponseBodyTooLarge {
            throw HTTPError.responseTooLarge(label: request.label, limit: error.limit)
        } catch is CancellationError {
            throw HTTPError.cancelled(label: request.label)
        } catch {
            throw HTTPError.transportFailure(
                label: request.label,
                reason: error.localizedDescription
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.transportFailure(
                label: request.label,
                reason: "Non-HTTP response"
            )
        }

        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }

        return HTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data,
            url: httpResponse.url ?? request.url
        )
    }
}

extension HTTPError {
    /// Map a URLError onto our transport error taxonomy.
    public static func from(urlError: URLError, label: String) -> HTTPError {
        switch urlError.code {
        case .timedOut:
            .timedOut(label: label)
        case .cancelled:
            .cancelled(label: label)
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .networkConnectionLost, .notConnectedToInternet, .secureConnectionFailed,
            .serverCertificateUntrusted, .serverCertificateHasBadDate:
            .connectionFailed(label: label, reason: reason(for: urlError.code))
        default:
            .transportFailure(label: label, reason: reason(for: urlError.code))
        }
    }

    /// A stable, credential-free description of a transport failure.
    ///
    /// Deliberately not `URLError.localizedDescription`. That string is platform-supplied,
    /// it can carry the failing URL, and Mojeek authenticates through a query parameter —
    /// so a URL in a diagnostic is a credential in a diagnostic. The numeric code stays
    /// available for an operator who needs to look the failure up.
    public static func reason(for code: URLError.Code) -> String {
        switch code {
        case .timedOut: "the request timed out"
        case .cancelled: "the request was cancelled"
        case .cannotConnectToHost: "could not connect to the host"
        case .cannotFindHost, .dnsLookupFailed: "the host could not be resolved"
        case .networkConnectionLost: "the network connection was lost"
        case .notConnectedToInternet: "no network connection is available"
        case .secureConnectionFailed: "the TLS handshake failed"
        case .serverCertificateUntrusted: "the server certificate is not trusted"
        case .serverCertificateHasBadDate: "the server certificate is expired or not yet valid"
        case .serverCertificateHasUnknownRoot: "the server certificate has an unknown root"
        case .serverCertificateNotYetValid: "the server certificate is not yet valid"
        case .clientCertificateRejected: "the client certificate was rejected"
        case .clientCertificateRequired: "the server required a client certificate"
        case .badURL, .unsupportedURL: "the transport rejected the request URL"
        case .userAuthenticationRequired, .userCancelledAuthentication:
            "the transport required authentication"
        case .dataNotAllowed: "the transport is not permitted to make this request"
        case .cannotLoadFromNetwork: "the resource could not be loaded from the network"
        case .redirectToNonExistentLocation: "the server redirected to a missing location"
        case .httpTooManyRedirects: "the server redirected too many times"
        default: "the transport reported error \(code.rawValue)"
        }
    }
}
