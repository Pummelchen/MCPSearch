import Foundation
import XCTest

@testable import WebSearchCore

/// Timing utilities.
final class DurationTests: XCTestCase {
    func testSecondsConversion() {
        XCTAssertEqual(Duration.milliseconds(1500).seconds, 1.5, accuracy: 0.0001)
        XCTAssertEqual(Duration.seconds(2).milliseconds, 2000)
    }

    /// The nanosecond-to-millisecond conversion, driven by a clock we control.
    ///
    /// The old version measured the real clock immediately after starting it and asserted the
    /// result was non-negative — a division of an unsigned delta, which no implementation of that
    /// signature can violate. The name promised nanosecond handling that was never exercised
    func testElapsedMillisecondsConvertsANanosecondDelta() {
        let clock = TestClock()
        let start = clock.uptimeNanoseconds()
        XCTAssertEqual(clock.elapsedMilliseconds(since: start), 0, "no time has passed")

        clock.advance(by: .milliseconds(1_500))
        XCTAssertEqual(clock.elapsedMilliseconds(since: start), 1_500)

        // Sub-second remainders are truncated, not rounded up.
        clock.advance(by: .milliseconds(400))
        XCTAssertEqual(clock.elapsedMilliseconds(since: start), 1_900)
    }

    func testTestClockAdvances() {
        let clock = TestClock()
        let before = clock.now()
        clock.advance(by: .seconds(45))
        XCTAssertEqual(clock.now().timeIntervalSince(before), 45, accuracy: 0.001)
    }

    func testRetryAfterParsesSecondsAndHTTPDate() {
        XCTAssertEqual(RetryAfter.parse("2")?.milliseconds, 2000)
        XCTAssertNil(RetryAfter.parse(nil))
        XCTAssertNil(RetryAfter.parse("not-a-date"))
        // An HTTP-date in the past must clamp to zero rather than go negative.
        let past = RetryAfter.parse("Wed, 21 Oct 2015 07:28:00 GMT")
        XCTAssertEqual(past?.milliseconds, 0)
    }

    /// `Retry-After` comes from an upstream response, so it is untrusted input. A value large
    /// enough to overflow `Int` used to trap the process in `Int(seconds * 1000)`:
    /// `Retry-After: 1e30` from any provider, or from a rate-limited Jina response, killed every
    /// connected client. Finite values are clamped, non-finite ones are treated as absent so the
    /// caller falls back to its own backoff.
    func testRetryAfterBoundsHostileValuesInsteadOfTrapping() {
        XCTAssertEqual(RetryAfter.parse("1e30")?.milliseconds, 86_400_000)
        XCTAssertEqual(RetryAfter.parse("\(RetryAfter.maximumSeconds * 2)")?.milliseconds, 86_400_000)
        XCTAssertNil(RetryAfter.parse("inf"))
        XCTAssertNil(RetryAfter.parse("-inf"))
        XCTAssertNil(RetryAfter.parse("nan"))
        // A negative delta was already clamped to zero; it must stay there.
        XCTAssertEqual(RetryAfter.parse("-5")?.milliseconds, 0)
        // The ordinary case is unchanged.
        XCTAssertEqual(RetryAfter.parse("7")?.milliseconds, 7000)
    }

    func testJinaRetryAfterBodyIsBoundedByTheSameRule() {
        XCTAssertNil(JinaReaderFetcher.retryAfterFromBody(Data(#"{"retryAfter": "soon"}"#.utf8)))
        XCTAssertNil(JinaReaderFetcher.retryAfterFromBody(Data(#"{"retryAfter": null}"#.utf8)))
        XCTAssertEqual(
            JinaReaderFetcher.retryAfterFromBody(Data(#"{"retryAfter": 1e33}"#.utf8))?.milliseconds,
            86_400_000
        )
        XCTAssertEqual(
            JinaReaderFetcher.retryAfterFromBody(Data(#"{"retryAfter": 3}"#.utf8))?.milliseconds,
            3000
        )
    }
}
