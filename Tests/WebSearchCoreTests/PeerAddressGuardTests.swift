import Foundation
import XCTest

@testable import WebSearchCore

/// The check that stands in for address pinning.
///
/// `URLSession` cannot be told to connect to the address the SSRF policy validated, so the fetcher reads
/// the address the connection actually used off the task metrics and refuses the body when it was not
/// one the policy resolved.
///
/// Driving a real DNS rebinding needs a resolver that lies to the policy and tells the truth to the
/// connection — the attack itself — so the divergence is injected at the seam instead:
/// `perform(_:validated:)` takes the validated set as an argument, and these tests hand it an address
/// this machine demonstrably is not serving from.
///
/// **Covered here:** everything after the resolver — a real socket, the real task metrics, the
/// comparison, and both outcomes. **Not covered:** the resolver disagreeing with itself, which is the
/// part no test in this repository can arrange without controlling DNS.
final class PeerAddressGuardTests: XCTestCase {
    /// example.com's address. Not this machine, and not what the loopback server answers on.
    private static let elsewhere = "93.184.216.34"

    private func fetcher() -> DirectHTTPFetcher {
        DirectHTTPFetcher(
            configuration: Fixtures.configuration(),
            policy: URLPolicy(allowPrivateNetwork: true),
            log: .disabled
        )
    }

    private func request(_ server: LoopbackServer) -> HTTPRequest {
        HTTPRequest.get(server.baseURL, label: "peer-address-test")
    }

    /// The ordinary case: the peer is one the policy validated, so the body is returned.
    ///
    /// This is the no-false-refusal half. A check that could not return a body would pass the test
    /// below and break every fetch in production.
    func testABodyFromAValidatedPeerIsReturned() async throws {
        let server = try LoopbackServer(responses: [.init(status: 200, body: "hello")])
        let validated = [try XCTUnwrap(IPAddress("127.0.0.1"))]

        let response = try await fetcher().perform(request(server), validated: validated)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("hello".utf8))
    }

    /// The case the check exists for: a peer the policy did not validate, refused.
    ///
    /// The connection succeeds and the body arrives — the refusal is not the network failing, which is
    /// the whole distinction this mitigation rests on.
    func testABodyFromAnUnvalidatedPeerIsRefused() async throws {
        let server = try LoopbackServer(responses: [.init(status: 200, body: "hello")])
        let validated = [try XCTUnwrap(IPAddress(Self.elsewhere))]

        do {
            let response = try await fetcher().perform(request(server), validated: validated)
            XCTFail(
                "a body from \(Self.elsewhere)'s policy check was returned: HTTP \(response.statusCode), "
                    + "\(response.body.count) bytes"
            )
        } catch let error as SearchError {
            guard case .fetchFailed(_, let reason) = error else {
                return XCTFail("expected fetchFailed, got \(error)")
            }
            XCTAssertTrue(
                reason.contains("did not validate"),
                "the refusal should say what it is: \(reason)"
            )
        }
    }

    /// No validated addresses: the check does not apply and an allowed fetch is not refused.
    ///
    /// This is the branch that keeps `SEARCH_ALLOW_PRIVATE_NETWORK`, IP literals and names that did not
    /// resolve working — the cases where the policy made no address judgement to check against.
    func testAnEmptyValidatedSetSkipsTheCheck() async throws {
        let server = try LoopbackServer(responses: [.init(status: 200, body: "hello")])

        let response = try await fetcher().perform(request(server), validated: [])

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("hello".utf8))
    }
}
