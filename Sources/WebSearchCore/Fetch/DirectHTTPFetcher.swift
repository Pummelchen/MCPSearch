import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Performs the actual HTTP fetch for `web_open`, following redirects **manually**
/// so that every hop is validated by `URLPolicy`.
///
/// Automatic redirect following is deliberately disabled: a validated public URL
/// that redirects to `http://169.254.169.254/` would otherwise walk straight past
/// the SSRF boundary.
public final class DirectHTTPFetcher: @unchecked Sendable {
    private let delegate: NoRedirectDelegate
    private let session: URLSession
    private let policy: URLPolicy
    private let userAgent: String
    private let maxBytes: Int
    private let requestTimeout: Duration
    private let log: Log

    public init(
        configuration: AppConfiguration,
        policy: URLPolicy,
        log: Log = .disabled
    ) {
        self.policy = policy
        self.userAgent = configuration.userAgent
        self.maxBytes = configuration.maxFetchedPageBytes
        self.requestTimeout = configuration.requestTimeout
        self.log = log

        // A dedicated session that refuses to follow redirects on its own.
        let delegate = NoRedirectDelegate()
        self.delegate = delegate
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout.seconds
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    /// Fetch a URL, validating the URL policy on the initial request and on every
    /// redirect hop.
    public func fetch(
        _ request: FetchRequest,
        maxRedirects: Int,
        allowedContentTypePrefixes: [String],
        maxCharacters: Int
    ) async throws -> FetchResult {
        var currentURL = request.url
        var redirectsFollowed = 0
        var redirectNotes: [String] = []

        while true {
            try Task.checkCancellation()

            // Layer 2 validation: resolves DNS and rejects private destinations.
            let decision = await policy.validate(currentURL)
            guard decision.allowed else {
                throw SearchError.blockedURL(currentURL)
            }

            let httpRequest = HTTPRequest.get(
                currentURL,
                headers: [
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,"
                        + "application/json;q=0.9,text/plain;q=0.8,*/*;q=0.1",
                    "Accept-Language": "en-US,en;q=0.9",
                ],
                label: "web_open"
            )

            let response = try await perform(httpRequest)

            // Handle redirects ourselves, validating each destination.
            if (300..<400).contains(response.statusCode),
                let location = response.header("Location")
            {
                guard redirectsFollowed < maxRedirects else {
                    throw SearchError.extractionFailed(request.url)
                }
                guard let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL
                else {
                    throw SearchError.extractionFailed(request.url)
                }
                // Re-validate before continuing; the loop re-checks at the top too,
                // but failing fast gives a clearer decision point.
                let hopDecision = await policy.validate(nextURL)
                guard hopDecision.allowed else {
                    throw SearchError.blockedURL(nextURL)
                }
                redirectNotes.append("Followed redirect to \(nextURL.host() ?? "unknown host").")
                currentURL = nextURL
                redirectsFollowed += 1
                continue
            }

            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 404 {
                    throw SearchError.extractionFailed(currentURL)
                }
                // Never blame a search provider here: `web_open` connects to the target
                // itself, so naming a provider in this message is simply wrong.
                throw SearchError.fetchFailed(
                    currentURL,
                    reason: "upstream returned HTTP \(response.statusCode)"
                )
            }

            let contentType = response.header("Content-Type")
            let mimeType = DirectHTTPFetcher.mimeType(from: contentType)

            guard let mimeType,
                DirectHTTPFetcher.isTextual(
                    mimeType,
                    allowedPrefixes: allowedContentTypePrefixes
                )
            else {
                throw SearchError.extractionFailed(currentURL)
            }

            let body = response.body
            let extraction: HTMLDocument.Extraction
            if mimeType.contains("html") || mimeType.contains("xhtml") {
                let html =
                    String(data: body, encoding: .utf8)
                    ?? String(data: body, encoding: .isoLatin1)
                    ?? ""
                extraction = try HTMLExtractor.extract(html: html)
            } else {
                let text =
                    String(data: body, encoding: .utf8)
                    ?? String(data: body, encoding: .isoLatin1)
                    ?? ""
                extraction = HTMLDocument.Extraction(
                    title: nil,
                    text: text
                )
            }

            let clipped = DirectHTTPFetcher.clip(extraction.text, to: maxCharacters)

            var warnings = redirectNotes
            if clipped.truncated {
                warnings.append(
                    "Content truncated to \(maxCharacters) characters."
                )
            }

            return FetchResult(
                finalURL: currentURL,
                statusCode: response.statusCode,
                contentType: contentType,
                title: extraction.title,
                text: clipped.text,
                method: mimeType.contains("html") ? .htmlExtraction : .rawText,
                truncated: clipped.truncated,
                warnings: warnings
            )
        }
    }

    // MARK: - Transport

    private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = requestTimeout.seconds
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response): (Data, URLResponse)
        do {
            // Capped during the transfer, not after it: a page the model asked to open can
            // stream for as long as it likes, and `data(for:)` would buffer all of it first
            // (ledger B07).
            (data, response) = try await BoundedResponseBody.read(
                session,
                urlRequest,
                limit: maxBytes
            )
        } catch let error as URLError {
            // These are fetch failures, not search-provider failures: `web_open`
            // connects straight to the target host, so the error is scoped to the URL
            // rather than attributed to whichever provider happens to be first.
            switch error.code {
            case .timedOut:
                throw SearchError.fetchFailed(request.url, reason: "request timed out")
            case .cancelled:
                // The caller cancelled. Reporting this as a fetch failure would let the layer
                // above read it as "the direct fetch did not work" and start a *second*
                // outbound request — the Jina fallback — for a caller that has gone away
                // (ledger B04).
                throw CancellationError()
            default:
                throw SearchError.fetchFailed(
                    request.url,
                    reason: HTTPError.reason(for: error.code)
                )
            }
        } catch is ResponseBodyTooLarge {
            // Same shape as the old post-hoc cap check: the page is too large to extract.
            throw SearchError.extractionFailed(request.url)
        } catch is CancellationError {
            throw CancellationError()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchError.extractionFailed(request.url)
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

    // MARK: - Helpers

    static func mimeType(from contentType: String?) -> String? {
        contentType?
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    static func isTextual(_ mimeType: String, allowedPrefixes: [String]) -> Bool {
        allowedPrefixes.contains { mimeType.hasPrefix($0) }
    }

    /// Clip to a character budget on a word boundary where possible, reporting
    /// whether anything was dropped.
    static func clip(_ text: String, to limit: Int) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        let end = text.index(text.startIndex, offsetBy: limit)
        let prefix = String(text[text.startIndex..<end])
        // Prefer cutting at the last whitespace so we do not split a word in half.
        if let lastSpace = prefix.lastIndex(where: { $0.isWhitespace }),
            prefix.distance(from: prefix.startIndex, to: lastSpace) > limit / 2
        {
            return (String(prefix[prefix.startIndex..<lastSpace]), true)
        }
        return (prefix, true)
    }
}

/// Prevents URLSession from following redirects behind our back.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Returning nil hands the 3xx response back to us for manual validation.
        completionHandler(nil)
    }
}
