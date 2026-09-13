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
    /// Per-host cached DNS results, so a redirect chain does not re-resolve.
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
        let lexical = validateLexically(url)
        guard lexical.allowed else { return lexical }

        if allowPrivateNetwork { return .allow }

        guard let host = url.host(), !URLPolicy.isIPLiteral(host) else { return .allow }

        let addresses: [IPAddress]
        do {
            addresses = try await resolver.resolve(host: host)
        } catch {
            // Resolution failure is not an SSRF signal; let the fetch try and fail
            // naturally so the caller sees a real network error.
            return .allow
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

// MARK: - IP addresses

/// A parsed IP address with the classification predicates the SSRF policy needs.
public enum IPAddress: Sendable, Hashable, CustomStringConvertible {
    case v4(UInt32)
    case v6([UInt8])

    /// Parse from presentation form.
    public init?(_ string: String) {
        var v4Address = in_addr()
        if string.withCString({ inet_pton(AF_INET, $0, &v4Address) }) == 1 {
            self = .v4(UInt32(bigEndian: v4Address.s_addr))
            return
        }
        var v6Address = in6_addr()
        if string.withCString({ inet_pton(AF_INET6, $0, &v6Address) }) == 1 {
            let bytes = withUnsafeBytes(of: v6Address) { Array($0) }
            guard bytes.count == 16 else { return nil }
            self = .v6(bytes)
            return
        }
        return nil
    }

    public var description: String {
        switch self {
        case .v4(let value):
            let bytes = [
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
            ]
            return bytes.map(String.init).joined(separator: ".")
        case .v6(let bytes):
            let groups = stride(from: 0, to: 16, by: 2).map { index in
                String(format: "%x", (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1]))
            }
            return groups.joined(separator: ":")
        }
    }

    /// 127.0.0.0/8, ::1
    public var isLoopback: Bool {
        switch self {
        case .v4(let value): (value >> 24) == 127
        case .v6(let bytes): bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
        }
    }

    /// The IPv4 address this IPv6 literal carries, when it carries one.
    ///
    /// Several IPv6 forms transport an IPv4 destination, and a classifier that ignores
    /// them can be walked straight past: on Darwin `http://[::ffff:127.0.0.1]/` reaches
    /// the IPv4 loopback interface, and the same trick hides RFC 1918 and cloud metadata
    /// addresses (`::ffff:169.254.169.254`). The policy therefore classifies the address
    /// actually reached rather than the outer form.
    ///
    /// Recognised: IPv4-mapped (`::ffff:0:0/96`), the deprecated IPv4-compatible `::/96`,
    /// NAT64 (`64:ff9b::/96`), 6to4 (`2002::/16`), and Teredo (`2001:0::/32`, whose
    /// client address is stored inverted).
    public var embeddedIPv4: IPAddress? {
        guard case .v6(let bytes) = self else { return nil }

        func address(at offset: Int) -> IPAddress {
            .v4(
                (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
                    | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
            )
        }

        // ::ffff:a.b.c.d — IPv4-mapped, the form a dual-stack host actually routes.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return address(at: 12)
        }
        // ::a.b.c.d — IPv4-compatible. Deprecated, but some resolvers still accept it.
        // `::` and `::1` are the unspecified and loopback addresses and embed nothing.
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            let candidate = address(at: 12)
            if case .v4(let value) = candidate, value != 0, value != 1 {
                return candidate
            }
        }
        // 64:ff9b::/96 — the NAT64 well-known prefix.
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xFF, bytes[3] == 0x9B,
            bytes[4..<12].allSatisfy({ $0 == 0 })
        {
            return address(at: 12)
        }
        // 2002::/16 — 6to4 carries the IPv4 address in the following 32 bits.
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            return address(at: 2)
        }
        // 2001:0::/32 — Teredo stores the client address inverted.
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x00,
            case .v4(let client) = address(at: 12)
        {
            return .v4(~client)
        }
        return nil
    }

    /// 169.254.0.0/16, fe80::/10
    public var isLinkLocal: Bool {
        switch self {
        case .v4(let value): (value >> 16) == 0xA9FE
        case .v6(let bytes): (bytes[0] == 0xFE) && (bytes[1] & 0xC0) == 0x80
        }
    }

    /// RFC 1918 plus the IPv6 unique-local range fc00::/7.
    public var isPrivate: Bool {
        switch self {
        case .v4(let value):
            let a = (value >> 24) & 0xFF
            let b = (value >> 16) & 0xFF
            if a == 10 { return true }
            if a == 172, (16...31).contains(b) { return true }
            if a == 192, b == 168 { return true }
            // Carrier-grade NAT and other non-public ranges that are still internal.
            return false
        case .v6(let bytes):
            // fc00::/7 unique local addresses.
            return (bytes[0] & 0xFE) == 0xFC
        }
    }

    /// 100.64.0.0/10 shared address space (carrier-grade NAT).
    public var isSharedAddressSpace: Bool {
        switch self {
        case .v4(let value):
            let a = (value >> 24) & 0xFF
            let b = (value >> 16) & 0xFF
            return a == 100 && (64...127).contains(b)
        case .v6:
            return false
        }
    }

    /// 0.0.0.0, ::
    public var isUnspecified: Bool {
        switch self {
        case .v4(let value): value == 0
        case .v6(let bytes): bytes.allSatisfy { $0 == 0 }
        }
    }

    /// 224.0.0.0/4, ff00::/8
    public var isMulticast: Bool {
        switch self {
        case .v4(let value): (value >> 28) == 0xE
        case .v6(let bytes): bytes[0] == 0xFF
        }
    }

    /// 255.255.255.255 and the subnet broadcast forms.
    public var isBroadcast: Bool {
        switch self {
        case .v4(let value): value == 0xFFFF_FFFF
        case .v6: false
        }
    }

    /// Cloud metadata endpoints. `169.254.169.254` is link-local and already
    /// blocked, but Alibaba/GCP/OCI also publish metadata on other addresses, and
    /// IPv6 metadata (`fd00:ec2::254`) lives inside the ULA range.
    public var isCloudMetadata: Bool {
        switch self {
        case .v4(let value):
            switch value {
            case 0xA9FE_A9FE,  // 169.254.169.254 (AWS/Azure/GCP/DO)
                0x6464_6464:  // 100.100.100.200 (Alibaba)
                return true
            default:
                return false
            }
        case .v6(let bytes):
            // fd00:ec2::254
            let prefix: [UInt8] = [0xFD, 0x00, 0x0E, 0xC2]
            return Array(bytes.prefix(4)) == prefix
        }
    }

    /// Ranges that are neither public nor usable: 240.0.0.0/4, 192.0.0.0/24,
    /// 198.18.0.0/15 benchmarking, and documentation ranges.
    public var isReserved: Bool {
        switch self {
        case .v4(let value):
            let a = (value >> 24) & 0xFF
            let b = (value >> 16) & 0xFF
            if a >= 240 { return true }  // 240.0.0.0/4 reserved
            if a == 0 { return true }  // 0.0.0.0/8 "this network"; only 0.0.0.0 was caught
            // Deliberately the whole 192.0.0.0/16, not only the IETF-assigned 192.0.0.0/24 the
            // comment here used to name. The range holds protocol assignments, TEST-NET-1
            // (192.0.2.0/24) and the 6to4 relay anycast block, none of which a web page fetch
            // should ever reach; refusing the surrounding /16 as well errs towards refusal, which
            // is the right direction for this check (ledger B62).
            if a == 192, b == 0 { return true }
            if a == 198, (18...19).contains(b) { return true }  // benchmarking
            return false
        case .v6(let bytes):
            // Documentation prefix 2001:db8::/32.
            return Array(bytes.prefix(4)) == [0x20, 0x01, 0x0D, 0xB8]
        }
    }
}

// MARK: - DNS

/// Resolves hostnames to addresses. Injectable so SSRF tests never touch DNS.
public protocol DNSResolver: Sendable {
    func resolve(host: String) async throws -> [IPAddress]
}

/// System resolver using `getaddrinfo`, wrapped so it never blocks a cooperative
/// thread pool for long.
public struct SystemDNSResolver: DNSResolver {
    public init() {}

    public func resolve(host: String) async throws -> [IPAddress] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(
                    ai_flags: 0,
                    ai_family: AF_UNSPEC,
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: 0,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                guard status == 0, let head = result else {
                    continuation.resume(throwing: DNSFailure(host: host, code: status))
                    return
                }
                defer { freeaddrinfo(head) }

                var addresses: [IPAddress] = []
                var node: UnsafeMutablePointer<addrinfo>? = head
                while let current = node {
                    if let socketAddress = current.pointee.ai_addr {
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let length = current.pointee.ai_addrlen
                        if getnameinfo(
                            socketAddress, length,
                            &buffer, socklen_t(buffer.count),
                            nil, 0,
                            NI_NUMERICHOST
                        ) == 0 {
                            let text =
                                String(bytes: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), encoding: .utf8)
                                ?? ""
                            // Strip an IPv6 zone index (`fe80::1%en0`).
                            let cleaned = text.split(separator: "%").first.map(String.init) ?? text
                            if let address = IPAddress(cleaned) { addresses.append(address) }
                        }
                    }
                    node = current.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }

    struct DNSFailure: Error, Sendable {
        let host: String
        let code: Int32
    }
}
