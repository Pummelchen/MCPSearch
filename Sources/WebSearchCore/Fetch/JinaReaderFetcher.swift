import Foundation

/// Jina Reader fallback for pages that resist native extraction.
///
/// Used when a page is JS-heavy or when `HTMLExtractor` produces too little text.
/// This keeps a headless browser out of the core server: rendering happens remotely
/// and only the extracted text comes back.
public struct JinaReaderFetcher: Sendable {
    /// Base for the Reader endpoint; the target URL is appended directly.
    public static let defaultBaseURL = URL(string: "https://r.jina.ai/")!

    /// Without a key, the free unauthenticated path is rate limited, so a modest
    /// interval is enforced locally rather than discovered through 429s.
    public static let unauthenticatedMinimumInterval: Duration = .seconds(1)

    private let baseURL: URL
    private let apiKey: String?
    private let http: any HTTPClient
    private let configuration: AppConfiguration
    private let log: Log

    public init(
        baseURL: URL = JinaReaderFetcher.defaultBaseURL,
        apiKey: String?,
        http: any HTTPClient,
        configuration: AppConfiguration,
        log: Log = .disabled
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.http = http
        self.configuration = configuration
        self.log = log
    }

    /// Fetch a page through Reader and return its text.
    public func fetch(
        _ request: FetchRequest,
        maxCharacters: Int
    ) async throws -> FetchResult {
        let started = DispatchTime.now().uptimeNanoseconds

        // The reader takes the target URL as the *rest of the path*, so it must be appended
        // verbatim. `appendingPathComponent` percent-encodes `?` and `#` into the path, which
        // asked the reader for a different resource — `/page%3Fq=1` instead of `/page?q=1`
        // (ledger B15).
        var readerURL = baseURL.absoluteString
        if !readerURL.hasSuffix("/") { readerURL += "/" }
        guard let target = URL(string: readerURL + request.url.absoluteString) else {
            throw SearchError.invalidRequest("could not build a reader URL for \(request.url)")
        }

        var headers: [String: String] = [
            // Markdown is the most useful shape for a model's context.
            "X-Return-Format": "markdown",
            "Accept": "text/plain, text/markdown;q=0.9, */*;q=0.1",
            // Reader's default cache is fine for a fetch tool; no need to force a
            // fresh render on every call.
            //
            // The advertised budget must fit inside our own. This was a hardcoded 15 while
            // the shared client aborts at `requestTimeout` (10 by default), so the reader's
            // deadline could never apply and the header only misled. One second is left for
            // the response to reach us.
            "X-Timeout": "\(max(1, Int(configuration.requestTimeout.seconds) - 1))",
        ]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        } else {
            // Be a good citizen on the free unauthenticated path.
            try? await Task.sleep(for: JinaReaderFetcher.unauthenticatedMinimumInterval)
        }

        let response = try await http.send(
            HTTPRequest.get(target, headers: headers, label: "jina.reader"),
            maxBytes: configuration.maxFetchedPageBytes
        )

        if response.statusCode == 429 {
            // Reader reports the wait in the JSON body as `retryAfter` (seconds) and
            // also in the `Retry-After` header; the body is authoritative when present.
            let bodyDelay = JinaReaderFetcher.retryAfterFromBody(response.body)
            let wait = bodyDelay ?? RetryAfter.parse(response.header("Retry-After"))
            let detail = wait.map { " Retry in about \($0.milliseconds) ms." } ?? ""
            throw SearchError.fetchFailed(
                request.url,
                reason: "the reader is rate limited.\(detail)"
            )
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            // Scoped to the fetch, not to a search provider: this is a page-extraction
            // fallback, and naming a provider here would be wrong.
            throw SearchError.fetchFailed(
                request.url,
                reason: "the reader rejected the request (HTTP \(response.statusCode))"
            )
        }
        guard response.isSuccess else {
            throw SearchError.extractionFailed(request.url)
        }

        // Reader returns markdown by default. When it is asked for JSON it answers
        // with `{code, status, data:{title,url,content}}`, so both shapes are handled.
        let text: String
        let title: String?
        let contentType = response.header("Content-Type")?.lowercased() ?? ""
        if contentType.contains("json") || response.body.first == UInt8(ascii: "{") {
            let payload = try? JSONCoding.decoder().decode(ReaderResponse.self, from: response.body)
            text = payload?.data?.content ?? ""
            title = payload?.data?.title
        } else {
            text = response.text()
            title = JinaReaderFetcher.leadingTitle(in: text)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SearchError.extractionFailed(request.url)
        }

        let clipped = DirectHTTPFetcher.clip(trimmed, to: maxCharacters)
        // The target URL — including any userinfo, token or signed query the caller chose —
        // has now left this machine and was fetched by a third party. `web_open` accepts
        // authorisation-bearing URLs and the model cannot be relied on to avoid them, so the
        // disclosure travels with every reader result rather than only the thin-native path
        // (ledger B87).
        var warnings: [String] = [
            "Used Jina Reader (\(baseURL.host() ?? baseURL.absoluteString)), "
                + "a third-party service that fetched this URL remotely."
        ]
        if clipped.truncated {
            warnings.append("Content truncated to \(maxCharacters) characters.")
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        log.debug(
            "Jina Reader fetch complete",
            metadata: ["chars": "\(clipped.text.count)", "latency_ms": "\(elapsed)"]
        )

        return FetchResult(
            finalURL: request.url,
            statusCode: response.statusCode,
            contentType: contentType.isEmpty ? "text/markdown" : contentType,
            title: title,
            text: clipped.text,
            method: .jinaReader,
            truncated: clipped.truncated,
            warnings: warnings,
            elapsedMilliseconds: elapsed
        )
    }

    /// Extract `retryAfter` (seconds) from Reader's rate-limit body.
    ///
    /// The value is attacker-influenced (it comes from a third-party service), so it goes
    /// through the same bounded conversion as the `Retry-After` header: a body of
    /// `{"retryAfter": 1e33}` used to trap on the `Double` → `Int` conversion.
    static func retryAfterFromBody(_ body: Data) -> Duration? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let seconds = object["retryAfter"] as? Double
        else { return nil }
        return RetryAfter.boundedDuration(seconds: seconds)
    }

    /// Reader prefixes markdown output with a `Title: ...` line.
    static func leadingTitle(in text: String) -> String? {
        for line in text.split(separator: "\n").prefix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("title:") {
                let value = trimmed.dropFirst("title:".count)
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    struct ReaderResponse: Decodable {
        let code: Int?
        let status: String?
        let data: Data?

        struct Data: Decodable {
            let title: String?
            let url: String?
            let content: String?
        }
    }
}
