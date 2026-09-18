import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// SSRF boundary for `web_open`.
///
/// A model can hand this tool an arbitrary URL, so the URL policy is the only thing
/// standing between the server and the host's internal network. String matching
/// alone is not a defense — `localtest.me`, `127.1`, `0x7f000001` and a public
/// hostname that resolves to `10.0.0.5` all defeat naive checks. This type
/// therefore performs three layers:
///
/// 1. **Lexical validation** — scheme allow-list, hostname block-list, IP literal
///    classification.
/// 2. **Resolution validation** — resolve the hostname and classify *every*
///    returned address, so a DNS name pointing at private space is rejected.
/// 3. **Redirect validation** — the fetcher re-runs both layers on every hop.
///
/// One hop never reaches layer 3, and the limit is worth stating: a redirect to `file:` — the one
/// scheme `URLSession` handles itself — is refused by `URLSession` *beneath* this policy, without
/// consulting the fetch delegate, so no `Decision` is produced for it. The refusal is still a policy
/// position — non-http(s) destinations are never fetched — and `DirectHTTPFetcher` reports it as a
/// fetch failure whose reason says so, rather than as an opaque transport code.
///
/// Every *other* scheme is handed back to the fetcher's loop, which validates the redirect target
/// here: `validateLexically` applies `allowedSchemes`, so an `ftp:`, `data:` or not-yet-invented
/// scheme is denied by the same per-hop call as a private address and needs no new code
public struct URLPolicy: Sendable {
    public struct Decision: Sendable, Hashable {
        public let allowed: Bool
        public let reason: String?

        static let allow = Decision(allowed: true, reason: nil)
        static func deny(_ reason: String) -> Decision {
            Decision(allowed: false, reason: reason)
        }
    }

    /// Schemes `web_open` will ever consider.
    public static let allowedSchemes: Set<String> = ["http", "https"]

    /// Hostnames that must never be fetched, regardless of what DNS says.
    public static let blockedHostnames: Set<String> = [
        "localhost", "localhost.localdomain", "local", "broadcasthost",
        "ip6-localhost", "ip6-loopback", "ip6-localnet", "ip6-mcastprefix",
        "ip6-allnodes", "ip6-allrouters", "ip6-allhosts",
        // Cloud instance metadata services. These are the classic SSRF targets for
        // credential theft.
        "metadata", "metadata.google.internal", "metadata.goog",
        "instance-data", "metadata.azure.com",
    ]

    /// Hostname suffixes that indicate an internal-only name.
    public static let blockedHostnameSuffixes: [String] = [
        ".localhost", ".local", ".internal", ".intranet", ".corp", ".home.arpa",
        ".lan", ".private",
    ]

    /// When true, private/loopback destinations are permitted. Only for a
    /// deliberately internal deployment (e.g. fetching from a company wiki).
    public let allowPrivateNetwork: Bool
    /// Resolves a hostname to every address it answers with.
    ///
    /// Answers are not remembered here. `DirectHTTPFetcher` hands `validate(_:cache:)` one
    /// short-lived cache per fetch, so a redirect chain does not ask twice for a host it has
    /// already checked while a later request still resolves afresh.
    private let resolver: any DNSResolver

    public init(
        allowPrivateNetwork: Bool = false,
        resolver: any DNSResolver = SystemDNSResolver()
    ) {
        self.allowPrivateNetwork = allowPrivateNetwork
        self.resolver = resolver
    }

    // MARK: - Layer 1: lexical

    /// Validate scheme and hostname without any network access.
    public func validateLexically(_ url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased() else {
            return .deny("URL has no scheme")
        }
        guard URLPolicy.allowedSchemes.contains(scheme) else {
            return .deny("Only http and https URLs may be fetched")
        }
        guard let host = url.host(), !host.isEmpty else {
            return .deny("URL has no host")
        }

        // Reject credentials outright: they are a common obfuscation vector and we
        // must never forward them.
        if url.user != nil || url.password != nil {
            return .deny("URLs containing credentials are not fetched")
        }

        let lowered = host.lowercased()

        // A trailing dot bypasses naive equality checks (`localhost.`).
        let withoutTrailingDot = lowered.hasSuffix(".") ? String(lowered.dropLast()) : lowered

        // An explicit private-network opt-in lifts the *name* restrictions as well as
        // the address restrictions, otherwise an internal wiki on a `.corp` name
        // could never be reached even by an operator who asked for it.
        if allowPrivateNetwork {
            return .allow
        }

        if URLPolicy.blockedHostnames.contains(withoutTrailingDot) {
            return .deny("Host \(withoutTrailingDot) is not fetchable")
        }
        for suffix in URLPolicy.blockedHostnameSuffixes
        where withoutTrailingDot.hasSuffix(suffix) {
            return .deny("Host \(withoutTrailingDot) is an internal name")
        }

        // Only allow hostnames that look like ordinary DNS names or IP literals.
        // This rejects exotic forms (hex/octal/dotted-decimal shorthands such as
        // `0x7f.1` or `2130706433`) that resolvers sometimes still accept.
        if URLPolicy.isIPLiteral(withoutTrailingDot) {
            guard let address = IPAddress(withoutTrailingDot) else {
                return .deny("Unparseable IP literal \(withoutTrailingDot)")
            }
            return validate(address: address, host: withoutTrailingDot)
        }

        guard URLPolicy.isPlausibleHostname(withoutTrailingDot) else {
            return .deny("Host \(withoutTrailingDot) is not a valid public hostname")
        }

        return .allow
    }

    // MARK: - Layer 2: resolution

    /// Validate the URL and every address its host resolves to.
    ///
    /// - Important: A hostname that fails to resolve is allowed through to the
    ///   connection attempt rather than denied, because a transient resolver failure
    ///   should surface as a network error. Only a *successful* resolution that
    ///   yields a forbidden address is a denial.
    ///
    /// - Important: The connection is **not** pinned to the address validated here.
    ///   `URLSession` resolves the host again when it connects, so a name whose answer
    ///   changes between the two lookups — a DNS-rebinding attack — can still land on a
    ///   private address. Closing that window needs the validated address bound to the
    ///   connection, which `URLSession` does not expose and which would also break TLS
    ///   certificate validation for the original hostname. The window is one DNS TTL, every
    ///   redirect hop is re-validated, and the residual risk is recorded on the tracker as
    ///   an accepted limitation rather than left implicit.
    public func validate(_ url: URL) async -> Decision {
        // No cache: a caller outside a fetch loop gets a fresh answer every time, which is
        // the behaviour `DirectHTTPFetcher` relies on across requests.
        await validate(url, cache: nil)
    }

    /// Validate the URL, reusing address lookups `cache` already holds.
    ///
    /// The cache stores the *address list*, never the decision: every call still classifies
    /// each address, so a host that answered with private space is denied on every validation
    /// that uses the cache, and a host the cache has not seen is resolved before it is judged.
    /// `DirectHTTPFetcher` creates one cache per fetch and discards it, so the
    /// re-resolution that bounds DNS rebinding survives between requests.
    func validate(_ url: URL, cache: DNSAnswerCache?) async -> Decision {
        let lexical = validateLexically(url)
        guard lexical.allowed else { return lexical }

        if allowPrivateNetwork { return .allow }

        guard let host = url.host(), !URLPolicy.isIPLiteral(host) else { return .allow }

        let addresses: [IPAddress]
        if let cached = cache?.addresses(for: host) {
            addresses = cached
        } else {
            do {
                addresses = try await resolver.resolve(host: host)
            } catch {
                // Resolution failure is not an SSRF signal; let the fetch try and fail
                // naturally so the caller sees a real network error.
                return .allow
            }
            cache?.store(addresses, for: host)
        }

        for address in addresses {
            let decision = validate(address: address, host: host)
            if !decision.allowed { return decision }
        }
        return .allow
    }

    /// Classify a single address. This is the core of the SSRF defense.
    public func validate(address: IPAddress, host: String) -> Decision {
        guard !allowPrivateNetwork else { return .allow }

        if address.isLoopback {
            return .deny("Host \(host) resolves to a loopback address")
        }
        if address.isLinkLocal {
            return .deny("Host \(host) resolves to a link-local address")
        }
        if address.isPrivate {
            return .deny("Host \(host) resolves to a private address")
        }
        if address.isMulticast {
            return .deny("Host \(host) resolves to a multicast address")
        }
        if address.isUnspecified {
            return .deny("Host \(host) resolves to an unspecified address")
        }
        if address.isCloudMetadata {
            return .deny("Host \(host) resolves to a cloud metadata address")
        }
        if address.isBroadcast {
            return .deny("Host \(host) resolves to a broadcast address")
        }
        if address.isSharedAddressSpace {
            return .deny("Host \(host) resolves to shared address space")
        }
        if address.isReserved {
            return .deny("Host \(host) resolves to a reserved address")
        }
        // An IPv6 literal can carry an IPv4 destination — IPv4-mapped, IPv4-compatible,
        // NAT64, 6to4 or Teredo. Judge what it actually reaches, otherwise the outer form
        // walks straight past the policy: `::ffff:127.0.0.1` reaches IPv4 loopback.
        // The native checks above run first, so `::1`, `::` and `fe80::` are already
        // classified and never reach this unwrapping.
        if let embedded = address.embeddedIPv4 {
            let decision = validate(address: embedded, host: host)
            if !decision.allowed {
                return .deny("Host \(host) embeds a non-public address (\(embedded))")
            }
        }
        return .allow
    }

    // MARK: - Helpers

    /// Whether the host is already an IP literal (v4 or v6).
    public static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }  // IPv6
        // Strict dotted-quad only. Deliberately does not accept `1.2.3`,
        // `0x7f000001` or `2130706433`, all of which resolvers may accept.
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                let value = Int(part)
            else { return false }
            return (0...255).contains(value)
        }
    }

    /// A hostname is plausible when every label is alphanumeric/hyphen, labels do
    /// not start or end with a hyphen, and there are no empty labels.
    static func isPlausibleHostname(_ host: String) -> Bool {
        guard host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }  // require a dot: no bare hostnames
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            guard label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { return false }
        }
        // Require an alphabetic TLD so bare integers never reach the resolver.
        guard let tld = labels.last, tld.contains(where: \.isLetter) else { return false }
        return true
    }
}
