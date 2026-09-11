import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Deterministic URL canonicalization used as the deduplication key.
///
/// Two URLs that a human would call "the same page" must canonicalize to the same
/// string, and no two URLs that identify different resources may collide. The rules
/// are deliberately conservative: we strip known tracking noise and normalize the
/// parts of a URL that are syntactically insignificant, but we never reorder or
/// delete arbitrary query parameters, because many sites encode resource identity
/// in the query string (`?id=`, `?v=`, `?page=`).
public enum URLCanonicalizer {
    /// Query parameters that are pure analytics noise and never identify a resource.
    public static let trackingParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_id", "utm_name", "utm_reader", "utm_referrer", "utm_social",
        "utm_social_type", "utm_brand", "utm_cid", "utm_pubreferrer",
        "gclid", "gclsrc", "dclid", "gbraid", "wbraid",
        "fbclid", "fb_action_ids", "fb_action_types", "fb_source", "fb_ref",
        "mc_cid", "mc_eid",
        "igshid", "twclid", "ttclid", "yclid", "msclkid", "epik", "s_kwcid",
        "ref_src", "ref_url", "referrer", "source",
        "_ga", "_gl", "oly_anon_id", "oly_enc_id", "vero_conv", "vero_id",
        "wickedid", "spm", "scm", "yclid",
    ]

    /// Parameters that must survive canonicalization because they commonly select
    /// the actual resource. Listed for documentation and test clarity.
    public static let identityBearingParameters: Set<String> = [
        "id", "v", "p", "page", "q", "query", "t", "s", "file", "article",
        "story", "post", "item", "doc", "document", "view", "lang", "locale",
    ]

    /// Canonicalize an absolute URL. Returns the input unchanged when it is not a
    /// hierarchical http(s) URL, so non-web schemes are never silently rewritten.
    public static func canonicalize(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }

        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return url }

        // 1. Lowercase the hostname, and strip a single trailing dot (the DNS root).
        if var host = components.host {
            host = host.lowercased()
            if host.hasSuffix("."), host.count > 1 {
                host = String(host.dropLast())
            }
            // IDN hosts: keep them in their punycode form so that the Unicode and
            // ASCII spellings of the same host dedupe together.
            if host.contains(":") {
                // IPv6 literal — leave as-is apart from case folding.
                components.host = host
            } else if let ascii = punycodeHost(host) {
                components.host = ascii
            } else {
                components.host = host
            }
        }

        // 2. Drop the fragment: it never changes the fetched resource.
        components.fragment = nil

        // 3. Drop userinfo — credentials do not identify a resource and must not
        //    end up in dedup keys or logs.
        components.user = nil
        components.password = nil

        // 4. Normalize default ports.
        if let port = components.port {
            if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
                components.port = nil
            }
        }

        // 5. Remove tracking parameters, preserving the relative order and the exact
        //    spelling of everything else.
        if let query = components.percentEncodedQuery, !query.isEmpty {
            let kept = filterQuery(query)
            components.percentEncodedQuery = kept.isEmpty ? nil : kept
        }

        // 6. Normalize the path: percent-encoding case, then trailing slash.
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        path = normalizePercentEncoding(path)
        // Remove a trailing slash unless the path *is* the root. `/a/b/` and `/a/b`
        // are treated as the same document; if a server distinguishes them it will
        // still redirect correctly.
        if path.count > 1, path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        components.percentEncodedPath = path

        return components.url ?? url
    }

    /// Canonicalize to a stable string key.
    public static func key(for url: URL) -> String {
        canonicalize(url).absoluteString
    }

    /// Canonicalize a bare host/domain string used in allow/deny lists.
    public static func normalizeDomain(_ raw: String) -> String {
        var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.hasPrefix("*.") { domain = String(domain.dropFirst(2)) }
        if domain.hasPrefix(".") { domain = String(domain.dropFirst()) }
        if domain.hasSuffix(".") { domain = String(domain.dropLast()) }
        // Tolerate a full URL being pasted into a domain filter.
        if domain.contains("://"), let host = URL(string: domain)?.host() {
            domain = host.lowercased()
        }
        if domain.hasPrefix("www.") { domain = String(domain.dropFirst(4)) }
        return domain
    }

    /// Whether `host` is `domain` itself or a subdomain of it.
    public static func host(_ host: String, matchesDomain domain: String) -> Bool {
        let h = host.lowercased()
        let d = normalizeDomain(domain)
        if d.isEmpty { return false }
        return h == d || h.hasSuffix("." + d)
    }

    // MARK: - Internals

    /// Remove tracking parameters while leaving ordering and spelling intact.
    static func filterQuery(_ percentEncodedQuery: String) -> String {
        let pairs = percentEncodedQuery.split(separator: "&", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        kept.reserveCapacity(pairs.count)
        for pair in pairs where !pair.isEmpty {
            let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let decodedName = name.removingPercentEncoding ?? name
            if trackingParameters.contains(decodedName.lowercased()) { continue }
            kept.append(pair)
        }
        return kept.joined(separator: "&")
    }

    /// Uppercase percent-escapes and escape characters that do not need escaping,
    /// so that `%7e` and `~` produce the same canonical path.
    static func normalizePercentEncoding(_ path: String) -> String {
        guard path.contains("%") else { return path }
        var result = ""
        result.reserveCapacity(path.count)
        var index = path.startIndex
        while index < path.endIndex {
            let character = path[index]
            if character == "%" {
                // A percent escape is three characters: `%` plus two hex digits.
                let next = path.index(index, offsetBy: 3, limitedBy: path.endIndex)
                if let next, path.distance(from: index, to: next) == 3 {
                    let hex = path[path.index(after: index)..<next]
                    if let value = UInt8(hex, radix: 16) {
                        // Unreserved characters per RFC 3986 §2.3 should not be escaped.
                        if isUnreserved(value) {
                            result.append(Character(Unicode.Scalar(value)))
                        } else {
                            result.append("%")
                            result.append(contentsOf: hex.uppercased())
                        }
                        index = next
                        continue
                    }
                }
                result.append(character)
                index = path.index(after: index)
            } else {
                result.append(character)
                index = path.index(after: index)
            }
        }
        return result
    }

    static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            true
        default:
            false
        }
    }

    /// Convert a Unicode host to its ASCII (punycode) form when it contains
    /// non-ASCII characters. Returns nil when no conversion is needed or possible.
    static func punycodeHost(_ host: String) -> String? {
        guard host.contains(where: { !$0.isASCII }) else { return nil }
        return URL(string: "http://\(host)")?.host()
    }
}

extension String {
    /// Collapse all whitespace runs and trim, for stable query hashing.
    public var collapsedWhitespace: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
