import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Fetches a single URL and returns readable text.
///
/// Responsibilities are split so each layer is independently testable:
/// - `URLPolicy` decides whether a URL may be fetched at all.
/// - `DirectHTTPFetcher` performs the request and follows redirects *with* policy
///   validation on every hop.
/// - `HTMLExtractor` turns HTML into readable text.
/// - `WebFetcher` orchestrates them and decides when to fall back to Jina Reader.
public protocol PageFetching: Sendable {
    func open(_ request: FetchRequest) async throws -> FetchResult
}

public struct FetchRequest: Sendable, Hashable {
    public var url: URL
    public var maxCharacters: Int
    /// Text shorter than this after extraction is treated as a failed extraction,
    /// which is what triggers the Jina Reader fallback.
    public var minimumUsefulCharacters: Int

    public init(
        url: URL,
        maxCharacters: Int = 12_000,
        minimumUsefulCharacters: Int = 400
    ) {
        self.url = url
        self.maxCharacters = maxCharacters
        self.minimumUsefulCharacters = minimumUsefulCharacters
    }
}

/// The orchestrating fetcher used by the `web_open` tool.
public actor WebFetcher {
    public struct Policy: Sendable, Hashable {
        /// Maximum redirect hops to follow. Each hop is re-validated.
        public var maxRedirects: Int
        /// Content types we will attempt to read as text.
        public var allowedContentTypePrefixes: [String]

        public init(maxRedirects: Int = 5) {
            self.maxRedirects = max(0, maxRedirects)
            self.allowedContentTypePrefixes = [
                "text/", "application/json", "application/xml", "application/xhtml",
                "application/rss+xml", "application/atom+xml", "application/x-yaml",
                "application/javascript", "application/pdf",
            ]
        }
    }

    private let direct: DirectHTTPFetcher
    private let policy: Policy
    private let jina: JinaReaderFetcher?
    private let log: Log

    public init(
        direct: DirectHTTPFetcher,
        policy: Policy = Policy(),
        jina: JinaReaderFetcher? = nil,
        log: Log = .disabled
    ) {
        self.direct = direct
        self.policy = policy
        self.jina = jina
        self.log = log
    }

    public func open(_ request: FetchRequest) async throws -> FetchResult {
        let started = DispatchTime.now().uptimeNanoseconds

        let directResult: FetchResult?
        do {
            directResult = try await direct.fetch(
                request,
                maxRedirects: policy.maxRedirects,
                allowedContentTypePrefixes: policy.allowedContentTypePrefixes,
                maxCharacters: request.maxCharacters
            )
        } catch let error as SearchError {
            // An active denial (blocked URL) must never be retried through another
            // path — that would defeat the SSRF boundary.
            if case .blockedURL = error { throw error }
            directResult = nil
        }

        if let result = directResult,
           result.text.count >= request.minimumUsefulCharacters
        {
            var finalized = result
            finalized.elapsedMilliseconds =
                Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            return finalized
        }

        // Direct extraction was empty, too thin, or failed. Jina Reader renders the
        // page remotely, which is the sanctioned way to handle JS-heavy pages
        // without embedding a headless browser here.
        guard let jina else {
            guard let result = directResult else {
                throw SearchError.extractionFailed(request.url)
            }
            var finalized = result
            finalized.warnings.append(
                "Extracted text is short; the page may require JavaScript rendering."
            )
            finalized.elapsedMilliseconds =
                Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            return finalized
        }

        do {
            let jinaResult = try await jina.fetch(
                request,
                maxCharacters: request.maxCharacters
            )
            var finalized = jinaResult
            if let directResult {
                finalized.warnings.append(
                    "Native extraction produced only \(directResult.text.count) characters; "
                        + "used Jina Reader instead."
                )
            }
            finalized.elapsedMilliseconds =
                Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            return finalized
        } catch {
            log.debug(
                "Jina Reader fallback failed",
                metadata: ["error": "\(type(of: error))"]
            )
            guard let result = directResult else {
                throw SearchError.extractionFailed(request.url)
            }
            var finalized = result
            finalized.warnings.append(
                "Jina Reader fallback was unavailable; returned native extraction."
            )
            finalized.elapsedMilliseconds =
                Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            return finalized
        }
    }
}
