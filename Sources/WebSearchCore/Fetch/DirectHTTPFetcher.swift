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
        // One DNS memo per fetch. The hop pre-check below and the re-check at the top of the
        // loop are two policy decisions, but they are one lookup, and the next fetch starts
        // with an empty memo.
        let resolutions = DNSAnswerCache()

        while true {
            try Task.checkCancellation()

            // Layer 2 validation: resolves DNS and rejects private destinations.
            let decision = await policy.validate(currentURL, cache: resolutions)
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

            // What the policy resolved for this hop, so the connection can be checked against it.
            let validated = currentURL.host().flatMap { resolutions.addresses(for: $0) } ?? []
            let response = try await perform(httpRequest, validated: validated)

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
                // Re-validate before continuing; the loop re-checks at the top too, but
                // failing fast gives a clearer decision point. Both calls are one DNS lookup
                // for this host, because they share the fetch's memo.
                let hopDecision = await policy.validate(nextURL, cache: resolutions)
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
                let html = DirectHTTPFetcher.decodeText(body, contentType: contentType)
                extraction = try HTMLExtractor.extract(html: html)
            } else {
                let text = DirectHTTPFetcher.decodeText(body, contentType: contentType)
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

    /// Perform one hop and refuse its body if the connection did not honour the policy.
    ///
    /// **Internal rather than private so the refusal can be tested.** A real DNS rebinding needs a
    /// resolver that lies to the policy and tells the truth to the connection, which is the attack
    /// itself and cannot be arranged in a test; taking `validated` as an argument is what lets a test
    /// inject that divergence and drive everything after it — the real socket, the real task metrics,
    /// and this comparison — rather than leaving the check covered only through the decision it
    /// delegates to (ledger A0017, tracker T4).
    func perform(_ request: HTTPRequest, validated: [IPAddress]) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = requestTimeout.seconds
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        // The address the connection actually used, so the response can be refused if it did not come
        // from one the policy validated. `URLSession` gives no way to pin the address, so this is the
        // check that stands in for pinning (ledger A0017).
        let recorder = PeerAddressRecorder()

        let (data, response): (Data, URLResponse)
        do {
            // Capped during the transfer, not after it: a page the model asked to open can
            // stream for as long as it likes, and `data(for:)` would buffer all of it first
            (data, response) = try await BoundedResponseBody.read(
                session,
                urlRequest,
                limit: maxBytes,
                recorder: recorder
            )

            // The address the connection actually used, checked against what the policy resolved.
            // `URLSession` gives no way to pin the address it connects to, so this stands in for
            // pinning: a body from a peer the policy never validated is refused (ledger A0017).
            //
            // Only when the policy resolved addresses. With `allowPrivateNetwork` — every loopback
            // test — an IP literal, or a name that did not resolve, there is nothing the connection
            // could be checked against, and refusing there would break fetches the policy allows.
            if !validated.isEmpty {
                let peers = recorder.addresses
                guard !peers.isEmpty else {
                    // The policy made a judgement and the connection did not confirm it. Failing
                    // closed is deliberate: an unverified connection is what the check exists for.
                    throw SearchError.fetchFailed(
                        request.url,
                        reason: "the connection's address could not be verified"
                    )
                }
                let unvalidated = BoundedResponseBody.unvalidatedPeers(peers, validated: validated)
                guard unvalidated.isEmpty else {
                    throw SearchError.fetchFailed(
                        request.url,
                        reason: "the connection went to "
                            + "\(unvalidated.joined(separator: ", ")), which this URL's policy did not validate"
                    )
                }
            }
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
                throw CancellationError()
            case .fileDoesNotExist, .fileIsDirectory, .noPermissionsToReadFile:
                // `file:` is the only scheme `URLSession` handles itself, so it is the only
                // cross-scheme redirect that does not reach the manual loop: the transport refuses
                // it internally, never calls `willPerformHTTPRedirection`, and reports one of these
                // file-system codes with the *original* URL attached rather than the target. Every
                // other scheme is handed back and denied by the per-hop policy call.
                // Name the policy position instead of leaking the opaque code, and never report
                // local content. The limitation is documented on `URLPolicy`.
                throw SearchError.fetchFailed(
                    request.url,
                    reason: "the server redirected to a local file, which is not fetched"
                )
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

    /// The `charset` parameter of a `Content-Type`, lowercased and unquoted.
    static func charset(from contentType: String?) -> String? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset"
            else { continue }
            let name = pair[1]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                .lowercased()
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// A Foundation encoding for an IANA charset name, or nil when the name is not one.
    static func encoding(for charset: String) -> String.Encoding? {
        let converted = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard converted != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converted))
    }

    /// Decode a body using, in order: the declared charset, then UTF-8, then the charset the markup
    /// declares for itself, then Latin-1.
    ///
    /// `mimeType(from:)` throws away everything after `;`, so the charset parameter was discarded and
    /// decoding fell straight to UTF-8-then-Latin-1. Latin-1 cannot fail, so a page served as
    /// windows-1251, Shift_JIS or GBK was silently decoded into mojibake with no warning and no
    /// truncation flag — wrong characters presented as success (ledger A0012).
    ///
    /// Latin-1 stays as the last resort precisely because it cannot fail: a caller is better served
    /// by an approximate body than by an error, and the order above means it is reached only when
    /// nothing better was declared.
    static func decodeText(_ body: Data, contentType: String?) -> String {
        if let name = charset(from: contentType), let encoding = encoding(for: name),
            let text = String(data: body, encoding: encoding)
        {
            return text
        }
        if let text = String(data: body, encoding: .utf8) { return text }
        if let text = decodeUsingDeclaredMetaCharset(body) { return text }
        return String(data: body, encoding: .isoLatin1) ?? ""
    }

    /// Decode using the charset the document declares for itself, if it declares one.
    ///
    /// Only the first few kilobytes are examined: a `<meta charset>` that appears later than that is
    /// outside what a browser honours, so looking further would find declarations nothing else acts
    /// on.
    private static func decodeUsingDeclaredMetaCharset(_ body: Data) -> String? {
        let head = body.prefix(4_096)
        guard let ascii = String(data: head, encoding: .isoLatin1),
            let marker = ascii.range(of: "charset", options: .caseInsensitive)
        else { return nil }
        let afterMarker = ascii[marker.upperBound...]
        guard let equals = afterMarker.firstIndex(of: "=") else { return nil }
        // `<meta charset="windows-1251">` is the common form, so the opening quote has to be stepped
        // over before the name starts; taking the prefix straight after `=` stops on the quote and
        // yields nothing.
        var value = afterMarker[afterMarker.index(after: equals)...]
        if let first = value.first, first == "\"" || first == "'" {
            value = value.dropFirst()
        }
        let name = String(
            value.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        ).lowercased()
        guard !name.isEmpty, let encoding = encoding(for: name) else { return nil }
        return String(data: body, encoding: encoding)
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
