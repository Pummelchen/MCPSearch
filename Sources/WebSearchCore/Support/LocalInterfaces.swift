import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The addresses this machine's own interfaces carry.
///
/// Only the Streamable HTTP origin policy needs them, and only for a wildcard bind
/// (`--host 0.0.0.0`): the operator asked to answer on every interface, so no single address
/// names the deployment and the allow-list has to name each one instead (ledger B21).
public enum LocalInterfaces {

    /// Every non-loopback IPv4 and IPv6 address of an interface that is up.
    ///
    /// Loopback is excluded because the origin policy already accepts it explicitly, and zone
    /// suffixes (`fe80::1%en0`) are stripped because a `Host` header never carries them.
    public static func addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp, !isLoopback, let address = interface.pointee.ifa_addr,
                let text = numericHost(address), !found.contains(text)
            {
                found.append(text)
            }
            cursor = interface.pointee.ifa_next
        }
        return found
    }

    /// The numeric form of a socket address, or nil for a family this does not describe.
    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        // The length has to match the family: getnameinfo reads the address it is told about,
        // and a sockaddr_in6 is longer than a plain sockaddr.
        let length: socklen_t
        switch Int32(address.pointee.sa_family) {
        case AF_INET: length = socklen_t(MemoryLayout<sockaddr_in>.size)
        case AF_INET6: length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        default: return nil
        }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            length,
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        // `String(cString:)` is deprecated; the buffer is NUL-terminated, so drop everything
        // from the terminator on and decode what is left.
        let text =
            String(bytes: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), encoding: .utf8) ?? ""
        return text.split(separator: "%").first.map(String.init)
    }
}
