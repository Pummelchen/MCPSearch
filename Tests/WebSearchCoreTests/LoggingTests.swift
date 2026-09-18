import Foundation
import XCTest

@testable import WebSearchCore

/// Logging must never contaminate stdout.
final class LoggingTests: XCTestCase {
    func testQueryIsHashedByDefault() {
        let log = Log(level: .debug, logQueries: false) { _ in }
        let description = log.queryDescription("my secret search terms")
        XCTAssertFalse(description.contains("secret"))
        XCTAssertTrue(description.hasPrefix("q"))
    }

    func testHashIsStableAndNotReversible() {
        XCTAssertEqual(Log.hash("same"), Log.hash("same"))
        XCTAssertNotEqual(Log.hash("a"), Log.hash("b"))
        XCTAssertFalse(Log.hash("query").contains("query"))
    }

    /// The digest must be keyed, not the public FNV-1a it used to be.
    ///
    /// The old value was recomputable by anyone: a log reader could hash a candidate query with
    /// the same public algorithm and confirm it, so the "non-reversible" doc claim was false.
    /// These are the exact FNV-1a outputs the defective function produced, computed independently
    /// of the Swift code; a keyed digest must not reproduce them.
    func testHashIsNotTheUnkeyedFNV1aDigest() {
        let knownFNV1a = [
            "swift concurrency": "q13a54df77317abdf",
            "my secret search terms": "qcdc8b5bd8d3de1dc",
            "query": "qb1068f146c4596c3",
        ]
        for (query, digest) in knownFNV1a {
            XCTAssertNotEqual(
                Log.hash(query),
                digest,
                "hash(\(query)) reproduces the unkeyed FNV-1a digest"
            )
        }
    }

    func testEscapeKeepsOutputOnOneLine() {
        XCTAssertEqual(Log.escape("a\nb\tc\"d\\e"), "a\\nb\\tc\\\"d\\\\e")
    }

    /// A value must not be able to drive the terminal through a diagnostic.
    ///
    /// Keeping the line intact is not enough: `ESC[2J` and the C1 range were passed through, so a
    /// query could clear the screen or move the cursor of whoever was reading stderr.
    func testEscapeMakesControlCharactersInert() {
        let hostile = "q\u{1B}[2J\u{07}\u{9B}31m\u{200B}"
        let escaped = Log.escape(hostile)
        XCTAssertEqual(escaped, "q\\u{1B}[2J\\u{07}\\u{9B}31m\\u{200B}")
        XCTAssertFalse(
            escaped.unicodeScalars.contains {
                $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
            },
            "no control or format scalar may survive: \(escaped.debugDescription)"
        )
    }

    func testLogRespectsLevelThreshold() {
        nonisolated(unsafe) var lines: [String] = []
        let lock = NSLock()
        let log = Log(level: .warning) { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        log.debug("debug message")
        log.info("info message")
        log.warning("warning message")
        lock.lock()
        let captured = lines
        lock.unlock()

        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].contains("warning message"))
    }

    func testDisabledLogEmitsNothing() {
        nonisolated(unsafe) var count = 0
        let log = Log(level: .none) { _ in count += 1 }
        log.error("should not appear")
        XCTAssertEqual(count, 0)
    }

    // MARK: Standard-error queue

    /// The default sink frames each event and hands it to the queue; it must not write to fd 2
    /// itself, because that write is what blocked the logging task.
    func testTheDefaultSinkRoutesFramedLinesThroughTheQueue() {
        nonisolated(unsafe) var written: [String] = []
        let lock = NSLock()
        let queue = StderrQueue(limit: 8) { line in
            lock.lock()
            written.append(line)
            lock.unlock()
        }
        defer { queue.finish() }

        let sink = Log.makeStandardErrorSink(queue: queue)
        sink("first")
        sink("second")
        XCTAssertTrue(queue.flush(), "the queue must drain")

        lock.lock()
        let captured = written
        lock.unlock()
        XCTAssertEqual(captured, ["first\n", "second\n"], "one framed line per call, in order")
    }

    /// A full queue drops the newest line rather than blocking the caller or growing without
    /// bound, and the lines it does write keep their order.
    ///
    /// The writer is parked inside the injected writer closure, which is what makes this
    /// deterministic: `submit` must return while the consumer is stopped, and the drop counter is
    /// observed directly instead of being timed.
    func testAFullQueueDropsInsteadOfBlockingTheCaller() {
        nonisolated(unsafe) var written: [String] = []
        let lock = NSLock()
        let took = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let queue = StderrQueue(limit: 2) { line in
            took.signal()
            release.wait()
            lock.lock()
            written.append(line)
            lock.unlock()
        }
        defer {
            queue.finish()
            for _ in 0..<4 { release.signal() }
        }

        queue.submit("one\n")
        // Wait until the writer holds "one" and is parked, so only the queue's two slots remain.
        XCTAssertEqual(took.wait(timeout: .now() + 5), .success, "the writer thread must start")

        queue.submit("two\n")
        queue.submit("three\n")
        // Full and stopped: this call must return, not wait for the writer.
        queue.submit("four\n")
        XCTAssertEqual(queue.droppedLines, 1, "a full queue must drop the newest line")

        // Release the writer for the drop note, for "two" and for "three"; the last release lets
        // "three" finish, and `flush` then waits for that write rather than for the queue to
        // empty.
        for _ in 0..<3 {
            release.signal()
            XCTAssertEqual(took.wait(timeout: .now() + 5), .success, "the writer must continue")
        }
        release.signal()
        XCTAssertTrue(queue.flush(), "the writer must drain once it is released")

        lock.lock()
        let captured = written
        lock.unlock()
        let dropped = captured.filter { $0.contains("dropped 1 log lines") }
        XCTAssertEqual(dropped.count, 1, "the gap must be reported once: \(captured)")
        XCTAssertEqual(
            captured.filter { !$0.contains("dropped 1 log lines") },
            ["one\n", "two\n", "three\n"],
            "order and framing must survive the queue"
        )
    }
}
