import Foundation
import XCTest

@testable import WebSearchCore

/// The redirect hop is the SSRF boundary for `web_open`, and until this file existed no test in
/// the suite ever returned a 3xx: the manual redirect loop in `DirectHTTPFetcher` — following
/// redirects at all, and re-validating each destination through `URLPolicy` — could be deleted
/// with every other test still green.
///
/// The loopback test server is reachable only because the policy opts into private networks
/// (`allowPrivateNetwork`), and that opt-in switches the *address* checks off by design. The
/// scheme case below is therefore what pins the per-hop policy check end to end, because a
/// `.blockedURL` can only come from that check; the address case is pinned against the policy
/// itself, which is the object the loop calls.
final class FetchRedirectTests: XCTestCase {

    private func makeFetcher() -> DirectHTTPFetcher {
        DirectHTTPFetcher(
            configuration: Fixtures.configuration(),
            policy: URLPolicy(allowPrivateNetwork: true),
            log: .disabled
        )
    }

    private func fetch(_ url: URL, maxRedirects: Int = 5) async throws -> FetchResult {
        try await makeFetcher().fetch(
            FetchRequest(url: url),
            maxRedirects: maxRedirects,
            allowedContentTypePrefixes: ["text/"],
            maxCharacters: 12_000
        )
    }

    private static func page(_ body: String) -> LoopbackServer.Response {
        LoopbackServer.Response(
            status: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: "<html><body><p>\(body)</p></body></html>"
        )
    }

    private static func redirect(to location: String, status: Int = 302) -> LoopbackServer.Response {
        LoopbackServer.Response(
            status: status,
            headers: ["Content-Type": "text/html", "Location": location],
            body: ""
        )
    }

    // MARK: - Following

    func testARedirectIsFollowedAndReported() async throws {
        // The target exists first, so the entry server can name it as an absolute Location.
        let target = try LoopbackServer(responses: [Self.page("final page")])
        let entry = try LoopbackServer(responses: [
            Self.redirect(to: target.baseURL.absoluteString)
        ])

        let result = try await fetch(entry.baseURL)

        XCTAssertEqual(result.finalURL, target.baseURL, "the result must name the page that answered")
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertTrue(result.text.contains("final page"), result.text)
        XCTAssertTrue(
            result.warnings.contains { $0.contains("Followed redirect to") },
            "the hop must be visible to the caller: \(result.warnings)"
        )
        XCTAssertEqual(entry.requestCount, 1)
        XCTAssertEqual(target.requestCount, 1)
    }

    func testARelativeLocationIsResolvedAgainstTheCurrentURL() async throws {
        let server = try LoopbackServer(responses: [
            Self.redirect(to: "/final", status: 301),
            Self.page("relative hop"),
        ])

        let result = try await fetch(server.baseURL)

        XCTAssertTrue(result.text.contains("relative hop"), result.text)
        XCTAssertEqual(result.finalURL, URL(string: "/final", relativeTo: server.baseURL)?.absoluteURL)
        XCTAssertEqual(server.requestPaths, ["/", "/final"])
    }

    func testFollowingStopsAtMaxRedirects() async throws {
        let server = try LoopbackServer(
            responses: Array(repeating: Self.redirect(to: "/loop"), count: 6)
        )

        do {
            _ = try await fetch(server.baseURL, maxRedirects: 2)
            XCTFail("a redirect loop must not be followed past the limit")
        } catch let error as SearchError {
            guard case .extractionFailed = error else {
                return XCTFail("expected extractionFailed, got \(error)")
            }
        }
        // The first request plus the two hops that were allowed; the third is refused before
        // it is made, so a hostile loop costs at most maxRedirects + 1 requests.
        XCTAssertEqual(server.requestCount, 3)
    }

    // MARK: - Re-validating each hop

    /// The pin for the per-hop policy call. A redirect to a URL carrying credentials is denied
    /// by `URLPolicy` unconditionally — before the private-network opt-in is considered — and the
    /// transport *would* happily follow it, so deleting `await policy.validate(nextURL)` from the
    /// redirect loop makes this test fetch the second page and fail.
    func testARedirectToACredentialedURLIsRefusedByTheHopPolicy() async throws {
        // The target server exists only so the redirect can name a real port; it must never be
        // asked for anything, which the final assertion checks.
        let target = try LoopbackServer(responses: [Self.page("should never be reached")])
        let credentialed = try XCTUnwrap(URL(string: "http://user:secret@127.0.0.1:\(target.port)/private"))
        let server = try LoopbackServer(responses: [Self.redirect(to: credentialed.absoluteString)])

        do {
            _ = try await fetch(server.baseURL)
            XCTFail("a hop carrying credentials must be refused, not followed")
        } catch let error as SearchError {
            guard case .blockedURL(let url) = error else {
                return XCTFail("expected blockedURL (a policy denial), got \(error)")
            }
            XCTAssertEqual(url, credentialed)
        }
        XCTAssertEqual(server.requestCount, 1, "the refused hop must not be requested")
        XCTAssertEqual(target.requestCount, 0, "the credentialed hop must never reach the target")
    }

    /// A redirect to `file:` is the one cross-scheme hop that never reaches the manual loop:
    /// `URLSession` handles that scheme itself, refuses the hop internally without consulting
    /// `NoRedirectDelegate`, and reports a file-system transport code with no target URL attached.
    /// `DirectHTTPFetcher` therefore names the policy position for those codes instead of
    /// surfacing the opaque code, and the check that matters stays the same: no local content
    /// comes back. Every other scheme is handed back to the loop and refused by
    /// `URLPolicy` itself — see the test below.
    func testARedirectToAFileURLIsRefusedWithoutReadingTheFile() async throws {
        let readable = URL(fileURLWithPath: "/etc/hosts")
        XCTAssertTrue(
            FileManager.default.isReadableFile(atPath: readable.path),
            "the probe is only meaningful when the target really is readable"
        )
        let server = try LoopbackServer(responses: [
            Self.redirect(to: readable.absoluteString)
        ])

        do {
            let result = try await fetch(server.baseURL)
            XCTFail("a cross-scheme redirect must not produce a page: \(result.text.prefix(80))")
        } catch let error as SearchError {
            guard case .fetchFailed(_, let reason) = error else {
                return XCTFail("expected a transport-level fetch failure, got \(error)")
            }
            XCTAssertEqual(
                reason,
                "the server redirected to a local file, which is not fetched",
                "the refusal must be legible, not an opaque transport code"
            )
            XCTAssertFalse("\(error)".contains("localhost"), "no file content may appear in the error")
            XCTAssertFalse(
                reason.contains("transport reported error"),
                "the raw URLError code must not reach the caller: \(reason)"
            )
        }
        XCTAssertEqual(server.requestCount, 1)
    }

    /// A redirect to a scheme the policy does not fetch is refused by the *same* per-hop policy
    /// call as a redirect to a private address, because the scheme allow-list is applied by
    /// `URLPolicy.validateLexically`. That is the scheme classification the finding asks for, and
    /// it needs no new code for a scheme nobody has seen yet.
    ///
    /// The premise was that these redirects surface as the opaque transport reason
    /// `the transport rejected the request URL`. They do not: `URLSession` consults the redirect
    /// delegate for every scheme except `file:` and hands the 302 back, so the loop validates the
    /// target and denies it — measured, not assumed. Only `file:` is refused beneath this loop,
    /// which is why that one case still maps transport codes.
    func testARedirectToAnUnfetchableSchemeIsRefusedByTheHopPolicy() async throws {
        for target in ["ftp://example.com/file", "data:text/plain,hello"] {
            let server = try LoopbackServer(responses: [Self.redirect(to: target)])
            do {
                let result = try await fetch(server.baseURL)
                XCTFail("a redirect to \(target) must not be fetched: \(result.text.prefix(60))")
            } catch let error as SearchError {
                guard case .blockedURL(let url) = error else {
                    return XCTFail("expected a policy denial for \(target), got \(error)")
                }
                XCTAssertEqual(url.scheme, URL(string: target)?.scheme, "the refusal must name the target")
                XCTAssertFalse(
                    "\(error)".contains("transport rejected"),
                    "the refusal must be a policy decision, not an opaque transport code: \(error)"
                )
            }
            XCTAssertEqual(server.requestCount, 1, "the refused hop must not be requested")
        }
    }

    /// A redirect with no `Location` is a broken response, not content to be extracted.
    func testARedirectWithoutALocationIsAFetchFailure() async throws {
        let server = try LoopbackServer(responses: [
            LoopbackServer.Response(
                status: 307,
                headers: ["Content-Type": "text/html"],
                body: "<html><body><p>who knows where</p></body></html>"
            )
        ])

        do {
            _ = try await fetch(server.baseURL)
            XCTFail("a 307 with no Location must not be returned as a page")
        } catch let error as SearchError {
            guard case .fetchFailed(_, let reason) = error else {
                return XCTFail("expected fetchFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("307"), reason)
        }
    }

    /// The address-level hop check cannot be reached end to end from a loopback server: getting
    /// there needs `allowPrivateNetwork`, which turns the address check off by design. It is
    /// pinned here against the exact policy object the redirect loop calls, so a change that
    /// stopped denying a metadata address would fail in this file rather than in production.
    func testThePolicyRefusesAMetadataHopOnItsOwn() async {
        let decision = await URLPolicy().validate(URL(string: "http://169.254.169.254/latest/meta-data/")!)
        XCTAssertFalse(decision.allowed, "link-local metadata must never be fetched")
        XCTAssertEqual(decision.reason?.contains("169.254.169.254"), true, decision.reason ?? "no reason")
    }
}
