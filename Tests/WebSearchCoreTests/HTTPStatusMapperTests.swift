import Foundation
import XCTest

@testable import WebSearchCore

/// `HTTPStatusMapper`: one seam for every provider's HTTP failures.
///
/// Every adapter funnels its response through `validate` and its transport errors through `map`,
/// so a mis-mapping here becomes a wrong health category for a provider that did nothing wrong —
/// or, worse, a request URL with a vendor key in its query string reaching a diagnostic. These
/// tests are table-driven because the contract is a lookup: each case names the input and the exact
/// error that must come out.
///
/// This file also owns `testHTTPStatusMapperClassifiesCorrectly`, which used to sit in
/// `ProviderContractTests`; that file is at SwiftLint's `file_length` ceiling, and a status mapper
/// is not a provider contract.
final class HTTPStatusMapperTests: XCTestCase {

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(
            statusCode: status,
            headers: headers,
            body: Data(),
            url: URL(string: "https://example.com")!
        )
    }

    // MARK: - validate: status codes

    /// The status-to-error contract lives in one table so each row can be seen next to its siblings.
    ///
    /// `422` and the default arm were the two the old test never reached: it covered
    /// 401/403/429/400/503/200 only, so an unmapped status could have been silently accepted.
    /// The `3xx` rows pin the default arm deliberately: `URLSession` follows a
    /// redirect before a provider sees it, so if one ever does surface it must be an actionable
    /// error rather than a success.
    func testValidateMapsEveryStatusClass() {
        let cases: [(status: Int, expected: SearchError, explanation: String)] = [
            (401, .authenticationRequired(.tavily), "bad credentials"),
            (403, .authenticationRequired(.tavily), "forbidden credentials"),
            (
                429,
                .rateLimited(.tavily, retryAfter: nil),
                "throttled without a Retry-After header"
            ),
            (
                400,
                .unsupportedRequest(.tavily, "upstream rejected the request (HTTP 400)"),
                "malformed request"
            ),
            (
                422,
                .unsupportedRequest(.tavily, "upstream rejected the request (HTTP 422)"),
                "semantically invalid request"
            ),
            (500, .providerUnavailable(.tavily), "internal server error"),
            (503, .providerUnavailable(.tavily), "service unavailable"),
            (599, .providerUnavailable(.tavily), "the top of the 5xx range"),
            (
                404,
                .unsupportedRequest(.tavily, "unexpected status HTTP 404"),
                "an unmapped 4xx takes the default arm"
            ),
            (
                418,
                .unsupportedRequest(.tavily, "unexpected status HTTP 418"),
                "a fictional status is still not a provider outage"
            ),
            (
                301,
                .unsupportedRequest(.tavily, "unexpected status HTTP 301"),
                "a redirect that reached a provider is not a success"
            ),
        ]

        for testCase in cases {
            XCTAssertThrowsError(
                try HTTPStatusMapper.validate(response(testCase.status), provider: .tavily),
                "HTTP \(testCase.status) (\(testCase.explanation)) must throw"
            ) { error in
                XCTAssertEqual(
                    error as? SearchError,
                    testCase.expected,
                    "HTTP \(testCase.status) (\(testCase.explanation))"
                )
            }
        }
    }

    /// Every status in `HTTPResponse.isSuccess`'s `200..<300` range passes through untouched.
    ///
    /// 204 is in that range, so a provider that answers "no content" is not misreported as a
    /// failure here; the caller's own body validation owns that case.
    func testValidateAcceptsEveryStatusInTheSuccessRange() throws {
        for status in [200, 201, 202, 204, 299] {
            XCTAssertNoThrow(
                try HTTPStatusMapper.validate(response(status), provider: .tavily),
                "HTTP \(status) is a success"
            )
        }
    }

    /// `Retry-After` travels with the throttling classification, which is what the orchestrator
    /// uses to decide whether waiting is cheaper than failing over.
    func testValidateCarriesRetryAfterForThrottling() {
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(
                response(429, headers: ["retry-after": "5"]),
                provider: .tavily
            )
        ) { error in
            guard case .rateLimited(let provider, let retryAfter) = error as? SearchError else {
                return XCTFail("expected rateLimited, got \(error)")
            }
            XCTAssertEqual(provider, .tavily)
            XCTAssertEqual(retryAfter?.milliseconds, 5_000)
        }
    }

    /// A vendor may use a different status for its own throttling and credential failures, and the
    /// caller-supplied sets must be consulted before the generic 400/422/5xx switch.
    func testValidateHonoursVendorSpecificStatusSets() throws {
        // 418 is used here as a stand-in for a vendor's own "slow down" code.
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(
                response(418),
                provider: .mojeek,
                rateLimitStatusCodes: [418]
            )
        ) { error in
            XCTAssertEqual((error as? SearchError)?.category, .rateLimited)
        }

        // The same status as a credential failure is classified as one.
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(
                response(418),
                provider: .mojeek,
                authenticationStatusCodes: [418]
            )
        ) { error in
            XCTAssertEqual((error as? SearchError)?.category, .authentication)
        }

        // And the default arm still applies when the vendor overrides do not name it.
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(
                response(418),
                provider: .mojeek,
                authenticationStatusCodes: [401],
                rateLimitStatusCodes: [429]
            )
        ) { error in
            XCTAssertEqual((error as? SearchError)?.category, .unsupportedRequest)
        }
    }

    // MARK: - map: transport errors

    /// Every `HTTPError` case must land on the category the orchestrator acts on.
    ///
    /// The only direct `map` test passed a `URLError`, so these arms — how a real transport
    /// timeout, cancellation or oversized body is classified for a provider — were unverified
    func testMapClassifiesEveryHTTPErrorCase() {
        let cases: [(name: String, error: HTTPError, expected: SearchError)] = [
            (
                "timedOut",
                .timedOut(label: "tavily"),
                .timeout(.tavily)
            ),
            (
                "cancelled",
                .cancelled(label: "tavily"),
                .networkFailure(.tavily, "cancelled")
            ),
            (
                "connectionFailed",
                .connectionFailed(label: "tavily", reason: "connection refused"),
                .networkFailure(.tavily, "connection refused")
            ),
            (
                "transportFailure",
                .transportFailure(label: "tavily", reason: "the network connection was lost"),
                .networkFailure(.tavily, "the network connection was lost")
            ),
            (
                "responseTooLarge",
                .responseTooLarge(label: "tavily", limit: 4 * 1024 * 1024),
                .malformedResponse(.tavily)
            ),
            (
                "invalidURL",
                // The detail is URL-shaped and credential-bearing on purpose: `map` must replace
                // it with curated text rather than forward it to the caller.
                .invalidURL("https://api.mojeek.com/search?api_key=tvly-not-real"),
                .unsupportedRequest(.tavily, "the request URL could not be built")
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                HTTPStatusMapper.map(testCase.error, provider: .tavily),
                testCase.expected,
                testCase.name
            )
        }
    }

    /// A `SearchError` is already classified: `map` must not re-wrap it.
    func testMapPassesASearchErrorThroughUnchanged() {
        let original = SearchError.rateLimited(.brave, retryAfter: .seconds(3))
        XCTAssertEqual(HTTPStatusMapper.map(original, provider: .tavily), original)
        XCTAssertEqual(HTTPStatusMapper.map(original, provider: .tavily).provider, .brave)
    }

    /// `CancellationError` is not a `URLError` or an `HTTPError`, and it must not be reported as a
    /// provider fault with a generic description.
    func testMapClassifiesCancellationExplicitly() {
        XCTAssertEqual(
            HTTPStatusMapper.map(CancellationError(), provider: .exa),
            .networkFailure(.exa, "cancelled")
        )
    }

    /// A `URLError` is curated from its code, never from the platform description, because a
    /// `URLError` carries the failing URL and Mojeek's key travels in a query parameter.
    func testMapCuratesURLErrorReasons() {
        let request = URL(string: "https://api.mojeek.com/search?q=swift&api_key=tvly-not-real")!
        let error = URLError(
            .cannotConnectToHost,
            userInfo: [NSURLErrorFailingURLErrorKey: request]
        )

        let mapped = HTTPStatusMapper.map(error, provider: .mojeek)
        XCTAssertEqual(mapped.category, .network)
        XCTAssertTrue(mapped.safeDescription.contains("could not connect"), mapped.safeDescription)
        XCTAssertFalse(mapped.safeDescription.contains("api_key"), mapped.safeDescription)
        XCTAssertFalse(mapped.safeDescription.contains("mojeek.com"), mapped.safeDescription)
    }

    /// Anything else falls back to a network failure carrying the error's own description, which
    /// is the one branch a caller cannot see from the enum.
    func testMapFallsBackToTheGenericNetworkFailure() {
        struct PrivateError: Error, LocalizedError {
            var errorDescription: String? { "a private error description" }
        }

        let mapped = HTTPStatusMapper.map(PrivateError(), provider: .searxng)
        XCTAssertEqual(mapped, .networkFailure(.searxng, "a private error description"))
    }

    // MARK: - map: no request URL in the descriptions that carry one

    /// Every mapped description that the transports produce must be safe to show an operator.
    ///
    /// The URL never appears in the returned `SearchError`, whichever arm produced it.
    ///
    /// `HTTPError.invalidURL` is included: its detail is free-form, so `map` curates the
    /// caller-facing text from the case instead of forwarding whatever the transport wrote. Before
    /// that, a URL-shaped detail was echoed with any credential in it.
    func testMappedDescriptionsNeverEchoARequestURL() {
        let secretURL = URL(string: "https://api.mojeek.com/search?api_key=tvly-not-real")!
        let errors: [(name: String, error: any Error)] = [
            ("URLError", URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: secretURL])),
            ("HTTPError.connectionFailed", HTTPError.connectionFailed(label: "mojeek", reason: "connection refused")),
            ("HTTPError.transportFailure", HTTPError.transportFailure(label: "mojeek", reason: "connection reset")),
            ("HTTPError.invalidURL", HTTPError.invalidURL(secretURL.absoluteString)),
        ]

        for testCase in errors {
            let description = HTTPStatusMapper.map(testCase.error, provider: .mojeek).safeDescription
            XCTAssertFalse(description.contains("api_key"), "\(testCase.name): \(description)")
            XCTAssertFalse(description.contains("tvly-not-real"), "\(testCase.name): \(description)")
            XCTAssertFalse(description.contains("mojeek.com"), "\(testCase.name): \(description)")
        }
    }

    /// The original status-mapping coverage, kept intact and moved here because
    /// `ProviderContractTests` is at its file-length ceiling.
    func testHTTPStatusMapperClassifiesCorrectly() {
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(response(401), provider: .tavily)
        ) { error in
            XCTAssertEqual((error as? SearchError)?.category, .authentication)
        }
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(response(403), provider: .tavily)
        ) { error in
            XCTAssertEqual((error as? SearchError)?.category, .authentication)
        }
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(response(429, headers: ["retry-after": "5"]), provider: .tavily)
        ) { error in
            guard case .rateLimited(_, let retryAfter) = error as? SearchError else {
                return XCTFail("expected rateLimited")
            }
            XCTAssertEqual(retryAfter?.milliseconds, 5000)
        }
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(response(400), provider: .tavily)
        ) { error in
            XCTAssertEqual((error as? SearchError)?.category, .unsupportedRequest)
        }
        XCTAssertThrowsError(
            try HTTPStatusMapper.validate(response(503), provider: .tavily)
        ) { error in
            XCTAssertEqual((error as? SearchError)?.category, .serverError)
        }
        XCTAssertNoThrow(try HTTPStatusMapper.validate(response(200), provider: .tavily))
    }
}
