import Foundation

/// Injectable time source. Tests use a controllable clock instead of sleeping, so
/// circuit-breaker and cache-expiry tests are deterministic and instant.
public protocol Clock: Sendable {
    /// The current instant.
    func now() -> Date
    /// Monotonic-ish uptime in seconds, used for latency measurement.
    func uptimeNanoseconds() -> UInt64
}

extension Clock {
    public func elapsedMilliseconds(since start: UInt64) -> Int {
        let delta = uptimeNanoseconds() &- start
        return Int(delta / 1_000_000)
    }
}

/// The real clock.
public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
    public func uptimeNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// A manually advanced clock for tests.
public final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var uptime: UInt64

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
        self.uptime = 0
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func uptimeNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return uptime
    }

    /// Advance the clock.
    public func advance(by duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(duration.seconds)
        uptime &+= UInt64(max(0, duration.seconds) * 1_000_000_000)
    }
}

extension Duration {
    /// Seconds as a Double. `Duration` has no built-in Double accessor.
    public var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Milliseconds as an Int, for metadata and deadlines.
    public var milliseconds: Int {
        Int((seconds * 1000).rounded())
    }
}
