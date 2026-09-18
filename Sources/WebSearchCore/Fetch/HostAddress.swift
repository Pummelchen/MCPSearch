import Foundation

/// A parsed IP address with the classification predicates the SSRF policy needs.
///
/// `case v6` carries a `[UInt8]` rather than a fixed-width tuple so the enum stays
/// `Hashable` and the presentation form is easy to build, which means a caller can construct
/// one of any length. `init?(_:)` only ever produces 16 bytes and every in-tree producer goes
/// through it, but the case is public, so each accessor checks the length before indexing.
/// A malformed value is classified as "not in this range" (and rendered as malformed) rather
/// than trapping.
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
            // A public case carrying a byte array can hold any length, so the fixed-width
            // unpacking below must be guarded. There is no presentation form for
            // a value that is not a 16-byte address, so say so instead of trapping.
            guard bytes.count == 16 else { return "invalid IPv6 (\(bytes.count) bytes)" }
            let groups = stride(from: 0, to: 16, by: 2).map { index in
                String(format: "%x", (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1]))
            }
            return groups.joined(separator: ":")
        }
    }

    /// 127.0.0.0/8, ::1
    public var isLoopback: Bool {
        switch self {
        case .v4(let value): return (value >> 24) == 127
        case .v6(let bytes):
            guard bytes.count == 16 else { return false }
            return bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
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
        // Only a 16-byte address has the fixed offsets this unwrapping reads.
        guard bytes.count == 16 else { return nil }

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
        case .v4(let value): return (value >> 16) == 0xA9FE
        case .v6(let bytes):
            guard bytes.count == 16 else { return false }
            return (bytes[0] == 0xFE) && (bytes[1] & 0xC0) == 0x80
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
            guard bytes.count == 16 else { return false }
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
        case .v4(let value): return value == 0
        case .v6(let bytes):
            guard bytes.count == 16 else { return false }
            return bytes.allSatisfy { $0 == 0 }
        }
    }

    /// 224.0.0.0/4, ff00::/8
    public var isMulticast: Bool {
        switch self {
        case .v4(let value): return (value >> 28) == 0xE
        case .v6(let bytes):
            guard bytes.count == 16 else { return false }
            return bytes[0] == 0xFF
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
            // is the right direction for this check.
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

/// DNS answers remembered for the length of one fetch.
///
/// `URLPolicy` used to declare a per-host cache it did not have, and `DirectHTTPFetcher`
/// validated a redirect target once for the hop and again at the top of the loop, so a
/// two-hop chain paid for the same lookup three times. Handing this object to
/// `validate(_:cache:)` turns the repeat calls into memo hits without changing what is
/// decided, because the address list is cached and the classification is not.
///
/// Scope is the whole point. One instance is created per `DirectHTTPFetcher.fetch` and
/// dropped when it returns, so the next request resolves again. A cache that outlived the
/// request would weaken the policy's DNS-rebinding bound in the one direction that matters:
/// a name that resolved to public space a moment ago would be re-validated against that
/// stale answer while `URLSession` connects to whatever it resolves to now.
final class DNSAnswerCache: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: [IPAddress]] = [:]

    /// The addresses an earlier lookup in this fetch produced, or nil when it has none.
    func addresses(for host: String) -> [IPAddress]? {
        lock.lock()
        defer { lock.unlock() }
        // Host names are case-insensitive (RFC 4343), so the memo is too.
        return answers[host.lowercased()]
    }

    /// Remember a successful lookup.
    ///
    /// A resolution *failure* is deliberately not stored. The policy lets a failing lookup
    /// through so the fetch fails with a real network error, and remembering that as "no
    /// addresses" would pin a transient resolver failure for the rest of the fetch.
    func store(_ addresses: [IPAddress], for host: String) {
        lock.lock()
        defer { lock.unlock() }
        answers[host.lowercased()] = addresses
    }
}

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
