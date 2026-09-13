import Foundation
import os

/// Runs the recursive parse of untrusted markup on a thread with an explicit, large stack.
///
/// `SwiftSoup` walks the document tree recursively, so the stack a parse runs on is part of
/// its safety margin. This package parses attacker-controlled markup from a Swift concurrency
/// cooperative task, whose stack is a fraction of the main thread's: measured, the scraper
/// path died with SIGBUS at 5 000 nested elements there, and under AddressSanitizer — whose
/// instrumented frames are several times larger — even a document at
/// `MarkupDepth.maximumNesting` did. A depth limit therefore needs headroom to spare, and this
/// thread is where it comes from: `stackSize` matches what the main thread gets, so a bounded
/// document parses with the same margin it has in a synchronous test.
///
/// A dedicated thread is the only lever available. The cooperative pool's stack size is fixed
/// and not configurable, and `Thread` is the only Foundation API that sets one. The hop is
/// synchronous because both callers (`ScraperSupport.parse`, `HTMLExtractor.extract`) are
/// synchronous, and it is provably deadlock-free: the parse thread performs no Swift
/// concurrency work, so it cannot be starved by a blocked cooperative thread. It costs one
/// thread creation per parse, tens of microseconds against a network fetch.
enum LargeStackParse {

    /// Stack size for the parse thread: what the main thread gets on this platform, and
    /// roughly sixteen times a cooperative task's stack.
    static let stackSize = 8 << 20

    /// Run `body` on a dedicated thread, returning its value or rethrowing its error.
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        // `OSAllocatedUnfairLock` is `Sendable` and publishes the outcome to the waiting
        // caller safely, so no unchecked conformance is needed anywhere here.
        let outcome = OSAllocatedUnfairLock(initialState: Result<T, any Error>?.none)
        let finished = DispatchSemaphore(value: 0)

        let thread = Thread {
            outcome.withLock { $0 = Result { try body() } }
            finished.signal()
        }
        thread.stackSize = stackSize
        thread.start()

        // Retains `thread` for as long as it can still run: `start()` returns immediately, so
        // releasing the only reference before the thread finished would leave it running with
        // a dangling stack allocation.
        finished.wait()

        guard let result = outcome.withLock({ $0 }) else {
            // Unreachable: `Thread` always runs its block, which stores an outcome before it
            // signals. Thrown rather than trapped so an impossible state stays a clean error.
            throw LargeStackParseError.threadDidNotRun
        }
        return try result.get()
    }
}

/// Failures of the parse-thread plumbing itself, never of the markup.
enum LargeStackParseError: Error {
    /// The parse thread never ran its block.
    case threadDidNotRun
}
