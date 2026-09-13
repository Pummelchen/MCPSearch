import Foundation
import XCTest

@testable import WebSearchCore

/// A DNS resolver whose answers are controlled by the test.
struct StubDNSResolver: DNSResolver {
    let table: [String: [String]]
    var failure: Bool = false

    func resolve(host: String) async throws -> [IPAddress] {
        if failure { throw StubFailure() }
        let addresses = table[host.lowercased()] ?? []
        return addresses.compactMap(IPAddress.init)
    }

    struct StubFailure: Error, Sendable {}
}

/// The SSRF boundary for `web_open`.
///
/// These are security tests: a model supplies the URL, so anything that reaches a
/// private address, a metadata service or a non-web scheme is a vulnerability.
final class URLPolicyTests: XCTestCase {

    private func policy(
        allowPrivate: Bool = false,
        resolving hosts: [String: [String]] = [:]
    ) -> URLPolicy {
        URLPolicy(
            allowPrivateNetwork: allowPrivate,
            resolver: StubDNSResolver(table: hosts)
        )
    }

    // MARK: Schemes

    func testRejectsNonWebSchemes() {
        let subject = policy()
        for raw in [
            "file:///etc/passwd",
            "data:text/html,<script>alert(1)</script>",
            "javascript:alert(1)",
            "ftp://example.com/file",
            "gopher://example.com/",
            // Deliberately insecure, and deliberately never opened: this list is the set of URLs
            // the policy must *reject*, so the fixture has to contain them (ledger A09).
            // nosemgrep: javascript.lang.security.detect-insecure-websocket.detect-insecure-websocket
            "ws://example.com/socket",
        ] {
            let decision = subject.validateLexically(URL(string: raw)!)
            XCTAssertFalse(decision.allowed, "\(raw) must be rejected")
        }
    }

    func testAcceptsOrdinaryPublicHTTPAndHTTPS() {
        let subject = policy()
        XCTAssertTrue(subject.validateLexically(URL(string: "https://example.com/a")!).allowed)
        XCTAssertTrue(subject.validateLexically(URL(string: "http://example.com/a")!).allowed)
    }

    // MARK: Hostnames

    func testRejectsLoopbackNamesAndTheirTricks() {
        let subject = policy()
        for raw in [
            "http://localhost/",
            "http://localhost:8080/admin",
            "http://localhost./",
            "http://LOCALHOST/x",
            "http://foo.localhost/",
            "http://metadata.google.internal/computeMetadata/v1/",
            "http://instance-data/latest/meta-data/",
        ] {
            XCTAssertFalse(
                subject.validateLexically(URL(string: raw)!).allowed,
                "\(raw) must be rejected"
            )
        }
    }

    func testRejectsInternalNameSuffixes() {
        let subject = policy()
        for raw in ["http://wiki.internal/", "http://printer.local/", "http://x.corp/"] {
            XCTAssertFalse(subject.validateLexically(URL(string: raw)!).allowed, "\(raw)")
        }
    }

    func testRejectsBareHostnamesWithoutADot() {
        let subject = policy()
        XCTAssertFalse(subject.validateLexically(URL(string: "http://intranet/")!).allowed)
    }

    func testRejectsCredentialsInURL() {
        let subject = policy()
        let decision = subject.validateLexically(URL(string: "https://user:pw@example.com/")!)
        XCTAssertFalse(decision.allowed)
    }

    // MARK: IP literals

    func testRejectsLoopbackAndPrivateIPLiterals() {
        let subject = policy()
        for raw in [
            "http://127.0.0.1/",
            "http://127.0.0.1:9200/",
            "http://127.1.2.3/",
            "http://10.0.0.5/",
            "http://172.16.4.4/",
            "http://172.31.255.255/",
            "http://192.168.1.1/",
            "http://169.254.169.254/latest/meta-data/",
            "http://0.0.0.0/",
            "http://0.0.0.1/",
            "http://255.255.255.255/",
            "http://100.100.100.200/",
            "http://224.0.0.1/",
            "http://240.0.0.1/",
            "http://[::1]/",
            "http://[fe80::1]/",
            "http://[fc00::1]/",
            "http://[fd00:ec2::254]/",
        ] {
            XCTAssertFalse(
                subject.validateLexically(URL(string: raw)!).allowed,
                "\(raw) must be rejected as non-public"
            )
        }
    }

    func testRejectsObfuscatedIntegerAndHexForms() {
        let subject = policy()
        // Resolvers sometimes accept these; the policy must not.
        for raw in ["http://2130706433/", "http://0x7f000001/", "http://0177.0.0.1/"] {
            XCTAssertFalse(
                subject.validateLexically(URL(string: raw)!).allowed,
                "\(raw) must be rejected"
            )
        }
    }

    func testAcceptsPublicIPLiterals() {
        let subject = policy()
        XCTAssertTrue(subject.validateLexically(URL(string: "http://93.184.216.34/")!).allowed)
        XCTAssertTrue(subject.validateLexically(URL(string: "http://[2606:2800:220:1::1]/")!).allowed)
    }

    func testRejectsIPv6LiteralsThatEmbedANonPublicIPv4Address() {
        let subject = policy()
        // Every one of these carries an IPv4 destination inside an IPv6 literal. Judging
        // only the outer form walks straight past the policy: `::ffff:127.0.0.1` reaches
        // the IPv4 loopback interface on Darwin, and the mapped form hides metadata and
        // RFC 1918 addresses just as well.
        for raw in [
            "http://[::ffff:127.0.0.1]/",
            "http://[::ffff:127.0.0.1]:9200/",
            "http://[::ffff:10.0.0.5]/",
            "http://[::ffff:172.16.4.4]/",
            "http://[::ffff:192.168.1.1]/",
            "http://[::ffff:169.254.169.254]/latest/meta-data/",
            "http://[::ffff:100.100.100.200]/",
            "http://[::ffff:100.64.0.1]/",
            "http://[::ffff:0.0.0.0]/",
            "http://[::ffff:224.0.0.1]/",
            "http://[::127.0.0.1]/",  // deprecated IPv4-compatible form
            "http://[64:ff9b::7f00:1]/",  // NAT64 -> 127.0.0.1
            "http://[64:ff9b::a00:5]/",  // NAT64 -> 10.0.0.5
            "http://[2002:7f00:1::]/",  // 6to4 -> 127.0.0.1
            "http://[2002:a00:5::]/",  // 6to4 -> 10.0.0.5
            "http://[2001:0:0:0:0:0:80ff:fffe]/",  // Teredo -> 127.0.0.1, inverted
        ] {
            XCTAssertFalse(
                subject.validateLexically(URL(string: raw)!).allowed,
                "\(raw) embeds a non-public IPv4 address and must be rejected"
            )
        }
    }

    func testAcceptsPublicIPv4MappedLiterals() {
        let subject = policy()
        // The fix must not over-block: an embedded address that is genuinely public stays
        // fetchable, whatever transport form carries it.
        for raw in [
            "http://[::ffff:93.184.216.34]/",
            "http://[64:ff9b::5db8:d822]/",  // NAT64 -> 93.184.216.34
            "http://[2002:5db8:d822::]/",  // 6to4 -> 93.184.216.34
        ] {
            XCTAssertTrue(
                subject.validateLexically(URL(string: raw)!).allowed,
                "\(raw) embeds a public IPv4 address and must remain fetchable"
            )
        }
    }

    func testEmbeddedIPv4UnwrapsEveryTransportForm() {
        XCTAssertEqual(IPAddress("::ffff:127.0.0.1")?.embeddedIPv4?.description, "127.0.0.1")
        XCTAssertEqual(IPAddress("::ffff:10.0.0.5")?.embeddedIPv4?.description, "10.0.0.5")
        XCTAssertEqual(IPAddress("::127.0.0.1")?.embeddedIPv4?.description, "127.0.0.1")
        XCTAssertEqual(IPAddress("64:ff9b::7f00:1")?.embeddedIPv4?.description, "127.0.0.1")
        XCTAssertEqual(IPAddress("2002:7f00:1::")?.embeddedIPv4?.description, "127.0.0.1")
        XCTAssertEqual(
            IPAddress("2001:0:0:0:0:0:80ff:fffe")?.embeddedIPv4?.description,
            "127.0.0.1"
        )
        // Nothing is embedded in these, so nothing may be unwrapped.
        XCTAssertNil(IPAddress("2606:2800:220:1::1")?.embeddedIPv4)
        XCTAssertNil(IPAddress("::1")?.embeddedIPv4)
        XCTAssertNil(IPAddress("::")?.embeddedIPv4)
        XCTAssertNil(IPAddress("93.184.216.34")?.embeddedIPv4)
    }

    func testRejectsHostnameResolvingToAnEmbeddedNonPublicIPv4Address() async {
        let subject = policy(resolving: ["mapped.example.com": ["::ffff:127.0.0.1"]])
        let decision = await subject.validate(URL(string: "https://mapped.example.com/")!)
        XCTAssertFalse(decision.allowed)
        XCTAssertTrue(decision.reason?.contains("embeds") ?? false, "\(decision.reason ?? "nil")")
    }

    // MARK: Resolution

    func testRejectsHostnameThatResolvesToPrivateAddress() async {
        // The classic bypass: a public-looking name pointing at internal space.
        let subject = policy(resolving: ["evil.example.com": ["10.0.0.5"]])
        let decision = await subject.validate(URL(string: "https://evil.example.com/")!)
        XCTAssertFalse(decision.allowed)
        XCTAssertTrue(decision.reason?.contains("private") ?? false)
    }

    func testRejectsHostnameResolvingToMetadataAddress() async {
        let subject = policy(resolving: ["sneaky.example.com": ["169.254.169.254"]])
        let decision = await subject.validate(URL(string: "https://sneaky.example.com/")!)
        XCTAssertFalse(decision.allowed)
    }

    func testRejectsWhenAnyResolvedAddressIsPrivate() async {
        // A name with both a public and a private answer must be rejected outright.
        let subject = policy(resolving: ["mixed.example.com": ["93.184.216.34", "192.168.0.1"]])
        let decision = await subject.validate(URL(string: "https://mixed.example.com/")!)
        XCTAssertFalse(decision.allowed)
    }

    func testAllowsHostnameThatResolvesOnlyToPublicAddresses() async {
        let subject = policy(resolving: ["good.example.com": ["93.184.216.34", "2606:2800::1"]])
        let decision = await subject.validate(URL(string: "https://good.example.com/")!)
        XCTAssertTrue(decision.allowed, decision.reason ?? "")
    }

    func testResolutionFailureDoesNotBecomeAnSSRFDenial() async {
        // A transient DNS failure must surface as a network error, not a policy block.
        let subject = URLPolicy(
            allowPrivateNetwork: false,
            resolver: StubDNSResolver(table: [:], failure: true)
        )
        let decision = await subject.validate(URL(string: "https://unresolvable.example.com/")!)
        XCTAssertTrue(decision.allowed)
    }

    func testPrivateNetworkOptInAllowsInternalTargets() async {
        let subject = policy(allowPrivate: true, resolving: ["wiki.corp": ["10.1.2.3"]])
        let decision = await subject.validate(URL(string: "http://wiki.corp/")!)
        XCTAssertTrue(decision.allowed)
        // Even with the opt-in, non-web schemes stay blocked.
        XCTAssertFalse(subject.validateLexically(URL(string: "file:///etc/passwd")!).allowed)
    }

    // MARK: IP classification

    func testIPAddressClassification() {
        XCTAssertEqual(IPAddress("127.0.0.1")?.isLoopback, true)
        XCTAssertEqual(IPAddress("::1")?.isLoopback, true)
        XCTAssertEqual(IPAddress("10.1.1.1")?.isPrivate, true)
        XCTAssertEqual(IPAddress("172.16.0.1")?.isPrivate, true)
        XCTAssertEqual(IPAddress("172.32.0.1")?.isPrivate, false)
        XCTAssertEqual(IPAddress("192.168.1.1")?.isPrivate, true)
        XCTAssertEqual(IPAddress("169.254.1.1")?.isLinkLocal, true)
        XCTAssertEqual(IPAddress("224.0.0.1")?.isMulticast, true)
        XCTAssertEqual(IPAddress("93.184.216.34")?.isPrivate, false)
        XCTAssertEqual(IPAddress("93.184.216.34")?.isLoopback, false)
        XCTAssertNil(IPAddress("not-an-ip"))
    }

    func testIPAddressRoundTripsItsDescription() {
        XCTAssertEqual(IPAddress("93.184.216.34")?.description, "93.184.216.34")
        XCTAssertEqual(IPAddress("10.0.0.1")?.description, "10.0.0.1")
    }

    func testIPLiteralDetectionIsStrict() {
        XCTAssertTrue(URLPolicy.isIPLiteral("127.0.0.1"))
        XCTAssertTrue(URLPolicy.isIPLiteral("::1"))
        // Deliberately not treated as literals, because the lexical validator must
        // reject them rather than interpret them.
        XCTAssertFalse(URLPolicy.isIPLiteral("2130706433"))
        XCTAssertFalse(URLPolicy.isIPLiteral("0x7f000001"))
        XCTAssertFalse(URLPolicy.isIPLiteral("1.2.3"))
    }
}
