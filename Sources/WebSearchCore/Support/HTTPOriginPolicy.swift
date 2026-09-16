import Foundation

/// The `Host`/`Origin` allow-list for the Streamable HTTP transport.
///
/// The MCP SDK's `OriginValidator.localhost(port:)` matches `127.0.0.1`, `localhost` and `[::1]`
/// with the configured port, exactly. That is right for the default loopback bind and wrong for
/// every deployment beyond it: `--host <lan-or-tailscale-address>`, documented as the remote
/// path with a TLS-terminating proxy in front, sends its own address in `Host`, and the
/// loopback-only list answered those requests with `421 Misdirected Request` before MCP handling
/// ever ran.
///
/// The allow-list is derived from the configured bind address and port instead. It stays an
/// exact-match list — a name an attacker's page resolves to this machine is still refused — so
/// DNS-rebinding protection is preserved rather than disabled.
public struct HTTPOriginPolicy: Sendable, Equatable {
    /// Values accepted in the `Host` header, as `host:port` or, for a proxied deployment that
    /// terminates TLS on the default port, a bare `host`.
    public var hosts: [String]
    /// Values accepted in the `Origin` header: `http://` for every authority, plus `https://`
    /// for the authorities an operator declared with `--http-allowed-host`.
    public var origins: [String]

    public init(hosts: [String], origins: [String]) {
        self.hosts = hosts
        self.origins = origins
    }
}

extension HTTPTransportConfiguration {

    /// Hosts that mean "every interface", for which no single address names the deployment.
    static let wildcardHosts: Set<String> = ["0.0.0.0", "::", "[::]", "*"]

    /// The allow-list this configuration implies, read from the machine's own interfaces.
    public var originPolicy: HTTPOriginPolicy {
        originPolicy(localAddresses: LocalInterfaces.addresses())
    }

    /// The allow-list, with the machine's local addresses supplied by the caller.
    ///
    /// They are a parameter rather than a lookup so the policy stays pure and testable: the
    /// wildcard-bind case needs to know which addresses this machine answers on, and a test must
    /// not depend on the addresses the test host happens to have.
    public func originPolicy(localAddresses: [String]) -> HTTPOriginPolicy {
        // Loopback is always accepted: the documented remote setup binds a specific address or
        // every interface, and a local client (Claude Desktop, a probe, the health check) still
        // reaches the server on 127.0.0.1.
        var hosts = loopbackAuthorities
        if Self.wildcardHosts.contains(host) {
            for address in localAddresses {
                hosts += Self.acceptedForms(of: address, port: port, includingBare: true)
            }
        } else if !isLoopback {
            hosts += Self.acceptedForms(of: host, port: port, includingBare: true)
        }

        var secureForms: [String] = []
        for entry in additionalAllowedHosts {
            let declared = Self.parseAdditionalHost(entry, defaultPort: port)
            hosts += declared.forms
            if declared.isSecure { secureForms += declared.forms }
        }

        let accepted = Self.uniqued(hosts)
        return HTTPOriginPolicy(
            hosts: accepted,
            origins: accepted.map { "http://\($0)" }
                + Self.uniqued(secureForms).map { "https://\($0)" }
        )
    }

    /// The three forms the SDK's own loopback validator accepts, unchanged.
    var loopbackAuthorities: [String] {
        ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
    }

    /// The authorities an address is accepted as: always with the port, and — because a proxy
    /// that terminates TLS forwards the public name with no port — the bare address too.
    static func acceptedForms(
        of address: String,
        port: Int,
        includingBare: Bool
    ) -> [String] {
        let authority = bracketed(address) + ":\(port)"
        return includingBare ? [authority, bracketed(address)] : [authority]
    }

    /// Bracket a bare IPv6 literal so it can appear in a `Host` header.
    static func bracketed(_ address: String) -> String {
        if address.hasPrefix("[") || !address.contains(":") { return address }
        return "[\(address)]"
    }

    /// Split an `--http-allowed-host` entry into the authorities it accepts.
    ///
    /// Accepts a bare host, `host:port`, `[v6]:port` or a full origin such as
    /// `https://search.example.com`. An entry with an explicit port is taken verbatim, because
    /// the operator said which port the public name arrives on; otherwise the configured port is
    /// appended and the bare name accepted as well.
    ///
    /// A declared host is assumed to sit behind a TLS-terminating proxy — the deployment this
    /// flag exists for — so its `https://` origin is accepted too, unless the entry spells out
    /// `http://`. Only browser callers send an `Origin`, and server-to-server clients send none,
    /// which is why the remote path worked without this list at all.
    static func parseAdditionalHost(
        _ entry: String,
        defaultPort: Int
    ) -> (forms: [String], isSecure: Bool) {
        var value = entry.trimmingCharacters(in: .whitespaces)
        var isSecure = true
        if let separator = value.range(of: "://") {
            isSecure = value[value.startIndex..<separator.lowerBound].lowercased() != "http"
            value = String(value[separator.upperBound...])
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !value.isEmpty else { return ([], isSecure) }
        guard !hasExplicitPort(value) else { return ([value], isSecure) }
        return (acceptedForms(of: value, port: defaultPort, includingBare: true), isSecure)
    }

    /// Whether a host or authority already carries a port.
    static func hasExplicitPort(_ value: String) -> Bool {
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return false }
            let rest = value[value.index(after: close)...]
            return rest.hasPrefix(":") && rest.dropFirst().allSatisfy(\.isNumber)
        }
        let parts = value.split(separator: ":")
        return parts.count == 2 && !parts[1].isEmpty && parts[1].allSatisfy(\.isNumber)
    }

    /// Drop later duplicates while keeping the first occurrence, so the list stays readable.
    static func uniqued(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
