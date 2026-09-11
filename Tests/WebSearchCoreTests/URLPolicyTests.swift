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
