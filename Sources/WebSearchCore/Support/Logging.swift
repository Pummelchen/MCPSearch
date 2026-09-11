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

    /// A logger derived with extra fixed context.
    public func withLevel(_ level: LogLevel) -> Log {
        Log(level: level, logQueries: logQueries, sink: sink)
    }

    // MARK: - Helpers

    /// Render a query for logging: stable hash unless explicitly opted in.
    public func queryDescription(_ query: String) -> String {
        logQueries ? query : Log.hash(query)
    }

    /// Stable, non-reversible short hash for correlating repeated queries without
    /// recording user content.
    public static func hash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "q" + String(hash, radix: 16)
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// Escape a value so a single log line stays a single line.
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
            default: escaped.append(character)
            }
        }
        return escaped
    }
}

// MARK: - Retry-After parsing

/// Parses the `Retry-After` header, which may be either delta-seconds or an
/// HTTP-date. Returns nil when absent or unparseable.
public enum RetryAfter {
    public static func parse(_ value: String?) -> Duration? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw) {
            return .milliseconds(Int(max(0, seconds) * 1000))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        let interval = date.timeIntervalSinceNow
        return .milliseconds(Int(max(0, interval) * 1000))
    }
}
