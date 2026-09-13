import CryptoKit
import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Structured logging that **always** writes to stderr, never stdout.
///
/// On a stdio MCP deployment stdout carries JSON-RPC framing, so a single stray
/// `print` corrupts the protocol stream. This logger is the only sanctioned output
/// path for diagnostics.
public struct Log: Sendable {
    public let level: LogLevel
    /// When false, queries are logged as a stable hash instead of verbatim.
    public let logQueries: Bool
    private let sink: @Sendable (String) -> Void

    public init(
        level: LogLevel = .info,
        logQueries: Bool = false,
        sink: (@Sendable (String) -> Void)? = nil
    ) {
        self.level = level
        self.logQueries = logQueries
        self.sink = sink ?? Log.standardErrorSink
    }

    /// A logger that discards everything, for tests.
    public static let disabled = Log(level: .none, logQueries: false) { _ in }

    /// Default sink: one line per event, written atomically to fd 2.
    public static let standardErrorSink: @Sendable (String) -> Void = { line in
        var text = line
        text.append("\n")
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(2, base + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    // MARK: - Levels

    public func trace(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        emit(.trace, message(), metadata: metadata)
    }

    public func debug(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        emit(.debug, message(), metadata: metadata)
    }

    public func info(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        emit(.info, message(), metadata: metadata)
    }

    public func warning(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        emit(.warning, message(), metadata: metadata)
    }

    public func error(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        emit(.error, message(), metadata: metadata)
    }

    public func emit(_ level: LogLevel, _ message: String, metadata: [String: String] = [:]) {
        guard level >= self.level, self.level != .none else { return }
        var line = Log.timestamp()
        line += " level=\(level.rawValue)"
        line += " msg=\"\(Log.escape(message))\""
        // Sort keys so output is deterministic and diffable.
        for key in metadata.keys.sorted() {
            guard let value = metadata[key] else { continue }
            line += " \(key)=\"\(Log.escape(value))\""
        }
        sink(line)
    }

    // MARK: - Helpers

    /// Render a query for logging: a per-process correlation id unless explicitly opted in.
    public func queryDescription(_ query: String) -> String {
        logQueries ? query : Log.hash(query)
    }

    /// Key for `hash`, generated once in memory and never persisted or logged.
    ///
    /// Because the key is per process, a correlation id is reproducible within a run but not
    /// across restarts — an accepted cost of the design, and the reason the doc below no longer
    /// promises a stable value (ledger B85).
    private static let queryHashKey = SymmetricKey(size: .bits256)

    /// A keyed correlation id for a query, short enough to keep a log line readable.
    ///
    /// This used to be an unkeyed FNV-1a and was documented as non-reversible. That was false:
    /// search queries are low-entropy natural language, so anyone holding a log line could
    /// confirm or recover a candidate by hashing a dictionary against the same public function
    /// (`hash("swift concurrency")` was a one-line offline check). HMAC-SHA-256 under
    /// `queryHashKey`, truncated to 64 bits, makes a dictionary attack require the key, which
    /// lives only in this process's memory. The `q` + hex shape is unchanged, so existing log
    /// consumers see the same field (ledger B85).
    public static func hash(_ value: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: queryHashKey)
        var truncated: UInt64 = 0
        for byte in mac.prefix(8) {
            truncated = (truncated << 8) | UInt64(byte)
        }
        return "q" + String(truncated, radix: 16)
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// Escape a value so a single log line stays a single line.
    /// Render a value so a diagnostic is one line *and* inert.
    ///
    /// The escape set used to be the three whitespace controls plus quote and backslash, which kept
    /// the line intact but let every other control character through: a query containing `ESC[2J`
    /// or a C1 byte reached the operator's terminal and was executed there (ledger B51). Every `Cc`
    /// and `Cf` scalar is now escaped — `\u{1B}`, `\u{9B}` — so the value stays readable and cannot
    /// drive anything.
    static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                for scalar in character.unicodeScalars {
                    switch scalar.properties.generalCategory {
                    case .control, .format:
                        escaped += String(format: "\\u{%02X}", scalar.value)
                    default:
                        escaped.append(Character(scalar))
                    }
                }
            }
        }
        return escaped
    }
}

// MARK: - Retry-After parsing

/// Parses the `Retry-After` header, which may be either delta-seconds or an
/// HTTP-date. Returns nil when absent or unparseable.
public enum RetryAfter {
    /// Longest delay this type will represent: one day.
    ///
    /// Callers clamp further for their own policy (`HTTPPolicy.maxRetryAfter` defaults to five
    /// seconds), so this bound is not the usable limit — it exists because the value arrives
    /// from an upstream response and `Int(seconds * 1000)` traps on a large or non-finite
    /// `Double`. `Retry-After: 1e30`, or a JSON body field of `1e33`, killed the process before
    /// this check.
    public static let maximumSeconds: TimeInterval = 24 * 60 * 60

    public static func parse(_ value: String?) -> Duration? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw) {
            return boundedDuration(seconds: seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return boundedDuration(seconds: date.timeIntervalSinceNow)
    }

    /// Convert seconds from an untrusted source into a `Duration`, or nil when meaningless.
    ///
    /// Non-finite input (`inf`, `nan`) has no sensible delay and is reported as absent, which
    /// makes the caller fall back to its own backoff. Finite input is clamped into
    /// `0...maximumSeconds` before the multiply, so the `Int` conversion cannot trap.
    static func boundedDuration(seconds: TimeInterval) -> Duration? {
        guard seconds.isFinite else { return nil }
        let clamped = min(max(0, seconds), maximumSeconds)
        return .milliseconds(Int(clamped * 1000))
    }
}
