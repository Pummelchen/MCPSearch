import Foundation
import XCTest
@testable import WebSearchCore

extension ProviderContractTests {

    func testRetryableStatusSetIsDeliberatelyNarrow() {
        // 400/401/403 must never be retried: retrying wastes quota and cannot succeed.
        XCTAssertFalse(HTTPPolicy.retryableStatusCodes.contains(400))
        XCTAssertFalse(HTTPPolicy.retryableStatusCodes.contains(401))
        XCTAssertFalse(HTTPPolicy.retryableStatusCodes.contains(403))
        XCTAssertFalse(HTTPPolicy.retryableStatusCodes.contains(404))
        for status in [408, 425, 429, 500, 502, 503, 504] {
            XCTAssertTrue(HTTPPolicy.retryableStatusCodes.contains(status), "\(status)")
        }
    }

    func testBackoffIsBoundedAndJittered() {
        let policy = HTTPPolicy()
        var seen = Set<Int>()
        for _ in 0..<50 {
            let delay = policy.backoff(forRetryIndex: 0).milliseconds
            // Base 200ms with full jitter across [0.5x, 1.5x].
            XCTAssertGreaterThanOrEqual(delay, 100)
            XCTAssertLessThanOrEqual(delay, 300)
            seen.insert(delay)
        }
        XCTAssertGreaterThan(seen.count, 1, "jitter should vary the delay")
        // The schedule must saturate rather than grow without bound.
        XCTAssertLessThanOrEqual(policy.backoff(forRetryIndex: 99).milliseconds, 750)
    }
}
