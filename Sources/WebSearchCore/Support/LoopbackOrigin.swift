import Foundation

/// Whether an `Origin` header names this machine.
///
/// The HTTP transport accepts a request only when its `Origin` is loopback: the server has no
/// authentication, and a browser page on another site must not be able to drive it. The check lives
/// here rather than in the executable so it can be tested directly; the version it replaces was
/// `host == "127.0.0.1" || host == "::1" || host == "localhost" || host.hasPrefix("127.")`, which
/// accepted `http://127.attacker.example` — a DNS name somebody else can register, not an address
public enum LoopbackOrigin {

    /// Whether `origin` is a loopback origin.
    ///
    /// Accepted: `localhost`, the IPv6 loopback literal, and dotted-quad literals in `127.0.0.0/8`.
    /// Anything else is refused, including forms that resolve to loopback but are not literals
    /// (`http://2130706433`, `http://0x7f.0.0.1`): the SDK's validator already treats hosts as
    /// strings, and accepting alternate spellings here would widen the surface for no benefit.
    public static func isLoopback(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host()?.lowercased(), !host.isEmpty
        else { return false }
        if host == "localhost" || host == "::1" { return true }

        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return parts[0] == "127"
    }
}
