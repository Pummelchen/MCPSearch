import Foundation

/// Normalization helpers shared by every provider adapter.
///
/// Providers differ in almost everything — field names, whether a snippet is
/// called `content` or `description`, whether dates are epoch or RFC 3339 — but the
/// orchestrator only ever sees `SearchResult`. This type is the single place where
/// that translation happens, so each adapter stays small and uniform.
public enum ResultNormalizer {

    /// Build a normalized result, applying domain filters and cleaning text.
    ///
    /// - Returns: nil when the result must be dropped (unusable URL, filtered
    ///   domain, or duplicate within the same provider response).
    public static func make(
        provider: ProviderID,
        rank: Int,
        title: String?,
        urlString: String?,
        snippet: String?,
        publishedAt: Date? = nil,
        score: Double? = nil,
        content: String? = nil,
        upstreamEngines: [String]? = nil,
        request: SearchRequest,
        seenKeys: inout Set<String>
    ) -> SearchResult? {
        guard let rawURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty,
            let url = normalizedURL(from: rawURL),
            let host = url.host(), !host.isEmpty
        else { return nil }

        guard passesDomainFilters(url: url, host: host, request: request) else {
            return nil
        }

        let canonical = URLCanonicalizer.canonicalize(url)
        let key = canonical.absoluteString
        // A provider that lists the same page twice must not vote twice.
        guard seenKeys.insert(key).inserted else { return nil }

        let cleanTitle = cleanText(title) ?? host
        let cleanSnippet = cleanText(snippet)
        let cleanContent = content.flatMap { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return SearchResult(
            title: cleanTitle,
            url: url,
            snippet: cleanSnippet,
            publishedAt: publishedAt,
            provider: provider,
            providerRank: rank,
            providerScore: score,
            content: cleanContent,
            canonicalURL: canonical,
            upstreamEngines: upstreamEngines
        )
    }

    /// Turn a provider-supplied URL string into an absolute, web-only URL.
    ///
    /// Providers occasionally return protocol-relative (`//example.com/x`) or
    /// schemeless (`example.com/x`) links; both are repaired here.
    public static func normalizedURL(from raw: String) -> URL? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip control characters that sometimes survive JSON decoding.
        candidate = candidate.replacingOccurrences(
            of: "[\u{0}-\u{1F}\u{7F}]",
            with: "",
            options: .regularExpression
        )
        guard !candidate.isEmpty else { return nil }

        if candidate.hasPrefix("//") {
            candidate = "https:" + candidate
        } else if !candidate.contains("://") {
            candidate = "https://" + candidate
        }

        guard let url = URL(string: candidate),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host(), !host.isEmpty,
            // A repaired URL must not carry credentials. `mailto:someone@example.com` has no
            // `://`, so the repair prefixed `https://` and produced
            // `https://mailto:someone@example.com`: the provider's scheme became userinfo and the
            // link pointed at an unrelated host. `URLPolicy` refuses credentials before any fetch,
            // so rejecting them here keeps this function's "absolute, web-only" contract honest
            // instead of handing a caller a URL that can only be refused later (ledger B34).
            url.user == nil, url.password == nil
        else { return nil }

        return url
    }

    /// Apply include/exclude domain filters.
    ///
    /// Include filters are a preference the *provider* should have applied, but we
    /// re-check locally so a provider that ignores the filter cannot leak results
    /// the caller explicitly excluded.
    public static func passesDomainFilters(
        url: URL,
        host: String,
        request: SearchRequest
    ) -> Bool {
        for excluded in request.excludeDomains
        where URLCanonicalizer.host(host, matchesDomain: excluded) {
            return false
        }
        guard !request.includeDomains.isEmpty else { return true }
        for included in request.includeDomains
        where URLCanonicalizer.host(host, matchesDomain: included) {
            return true
        }
        return false
    }

    /// Collapse whitespace, strip HTML tags and decode the handful of entities that
    /// realistically appear in search snippets.
    public static func cleanText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var text = raw
        if text.contains("<") {
            text = stripHTMLTags(text)
        }
        text = decodeCommonEntities(text)
        text = text.collapsedWhitespace
        return text.isEmpty ? nil : text
    }

    /// Remove tags without pulling in a parser: provider snippets contain at most a
    /// few `<b>`/`<em>` highlight tags.
    static func stripHTMLTags(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        var insideTag = false
        for character in input {
            if character == "<" {
                insideTag = true
            } else if character == ">" {
                insideTag = false
                output.append(" ")
            } else if !insideTag {
                output.append(character)
            }
        }
        return output
    }

    static func decodeCommonEntities(_ input: String) -> String {
        var output = input
        let replacements: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&ldquo;", "“"), ("&rdquo;", "”"),
        ]
        for (entity, value) in replacements where output.contains(entity) {
            output = output.replacingOccurrences(of: entity, with: value)
        }
        return output
    }

}
