import Foundation
import XCTest

@testable import WebSearchCore

// MARK: - Server under test

/// Shared support for tests that launch the built `SwiftWebSearchMCP` executable.
///
/// The provider environment scrub list lives here so the two Swift server harnesses
/// cannot drift from each other *or* from `scripts/mcp_smoke.py`, which mirrors it.
enum ServerTestSupport {
    /// Every documented provider and synthesis environment variable.
    ///
    /// Mirrored verbatim by `SCRUBBED_VARIABLES` in `scripts/mcp_smoke.py`. When this
    /// list changes, update the Python tuple in the same commit.
    static let providerEnvironmentVariables = [
        "TAVILY_API_KEY", "BRAVE_SEARCH_API_KEY", "MOJEEK_API_KEY", "EXA_API_KEY",
        "JINA_API_KEY", "SEARXNG_BASE_URL", "OPEN_WEB_SEARCH_URL", "PARALLEL_MCP_URL",
        "SEARCH_ENABLE_SCRAPERS", "SEARCH_ENABLE_PARALLEL", "SEARCH_DISABLED_PROVIDERS",
        "SEARCH_PROVIDER_ORDER", "SEARCH_CONFIG_FILE",
        // Synthesis credentials belong here for the same reason as the search keys: a
        // developer with DEEPSEEK_API_KEY exported would otherwise make the
        // "synthesis is unconfigured" test perform a live, billed request.
        "DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "DEEPSEEK_MODEL",
        "SEARCH_SYNTHESIS_TIMEOUT_MS", "SEARCH_SYNTHESIS_REASONING",
    ]

    /// Whether this run is CI, where missing end-to-end coverage must be a failure.
    static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    /// Environment for a spawned server or monitor process.
    ///
    /// `swift test --enable-code-coverage` instruments every target and hands the *test*
    /// process a profile path through `LLVM_PROFILE_FILE`. A child that inherits that setting
    /// writes its counters into the same file and corrupts both, so for as long as the
    /// subprocesses ran with the inherited value the MCP surface measured **0 %** while being
    /// thoroughly exercised. Each child now gets its own file, and the coverage
    /// step merges every profile in the directory.
    ///
    /// `%c` puts the profiling runtime in continuous mode, which is what makes this work for a
    /// *terminated* child: the runtime normally flushes at exit, and these harnesses stop their
    /// server with a signal, so an at-exit-only profile is written empty. `%p` keeps two
    /// children started in the same second from colliding.
    static func childEnvironment(base: [String: String] = [:]) -> [String: String] {
        var environment = base
        if let parent = ProcessInfo.processInfo.environment["LLVM_PROFILE_FILE"], !parent.isEmpty {
            let directory = URL(fileURLWithPath: parent).deletingLastPathComponent()
            let name = "child-\(UUID().uuidString.prefix(8))-%c-%p.profraw"
            environment["LLVM_PROFILE_FILE"] = directory.appendingPathComponent(name).path
        }
        return environment
    }

    /// Locate the executable `swift build` produced next to the test bundle.
    ///
    /// A missing binary means the end-to-end coverage did not run at all. Locally that
    /// stays a skip so a partial checkout still builds, but in CI it is a failure: a
    /// green run with no end-to-end coverage is exactly the silent-skip failure mode
    /// this helper exists to prevent.
    static func binaryURL() throws -> URL {
        let bundleDirectory = Bundle(for: ServerTestSupportAnchor.self).bundleURL
            .deletingLastPathComponent()
        let candidate = bundleDirectory.appendingPathComponent("SwiftWebSearchMCP")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            if isCI {
                throw MissingServerBinary(path: candidate.path)
            }
            throw XCTSkip(
                "Server executable not found at \(candidate.path); run `swift build` first."
            )
        }
        return candidate
    }

    /// Thrown (rather than skipped) in CI so the run is red.
    struct MissingServerBinary: Error, CustomStringConvertible {
        let path: String

        var description: String {
            "Server executable not found at \(path); run `swift build` first. "
                + "This is a failure rather than a skip because CI is set: missing "
                + "end-to-end coverage must not be reported as a green run."
        }
    }
}

/// Anchor so `Bundle(for:)` resolves to the test bundle from a static helper.
private final class ServerTestSupportAnchor {}

// MARK: - Newline-JSON subprocess harness

/// Why a harness read ended without a response.
enum ServerTestError: Error, CustomStringConvertible {
    case timeout
    case malformedResponse(String)
    case unexpectedEOF(stderr: String)

    var description: String {
        switch self {
        case .timeout: "timed out waiting for a response"
        case .malformedResponse(let text): "malformed JSON-RPC line: \(text)"
        case .unexpectedEOF(let stderr): "server exited early; stderr: \(stderr)"
        }
    }
}

/// The stderr a child produced, accumulated as it is produced.
///
/// A separate box rather than fields on the harness because the readability handler that fills
/// it is `@Sendable` and must not reach back into the non-`Sendable` harness. The lock is the
/// only point of contact between the reader queue and the test thread.
private final class StderrCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Reached EOF, so no further bytes can arrive.
    let drained = DispatchGroup()

    init(pipe: Pipe) {
        drained.enter()
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drained.leave()
                return
            }
            lock.withLock { buffer.append(chunk) }
        }
    }

    /// Everything the child wrote to stderr before it exited.
    ///
    /// A bounded wait: the background reader delivers what the child flushed, and a child that is
    /// still alive keeps the pipe open, so an unbounded wait would hang the way the read loop
    /// once did. Two seconds is far longer than a pipe read needs; it costs a test nothing
    /// because the reader signals the group as soon as the data lands.
    func text() -> String {
        _ = drained.wait(timeout: .now() + 2)
        let data = lock.withLock { buffer }
        return String(bytes: data, encoding: .utf8) ?? "<not valid UTF-8>"
    }
}

/// One running subprocess spoken to with newline-delimited JSON, stdout to stdin.
///
/// The single harness for every stdio test. Three hand-copied versions of this used to live in
/// `StdioServerTests`, `ErrorReportingTests` and `SchemaCompatibilityTests`, and had already
/// drifted: the `SchemaCompatibilityTests` copy declared a `failure` that dropped the stderr
/// payload, and its `process.standardError = Pipe()` was never read, so an early exit reported
/// the bare words `unexpectedExit` with no diagnostic. The shared environment
/// scrub list had been factored out; the framing, the deadline and the stderr capture had not.
///
/// The deadline is enforced at the read, not merely checked between reads. The loop this
/// replaces was `while Date() < deadline { … availableData }`, and `availableData` blocks
/// until data arrives or the pipe reaches EOF, so a wedged server that still held the write
/// end hung the suite indefinitely while the 15 s/20 s "timeout" it advertised never fired.
/// Each read now `poll`s the descriptor first, so the bound is real.
final class ServerProcess {
    let process = Process()
    /// The write end is held as a stored property because `Process.standardInput` owns the
    /// pipe, not the handle, and the harness closes this handle to signal end of input.
    let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = Data()
    /// The stderr stream, accumulated by a background reader for the life of the harness.
    private let stderrCapture: StderrCapture

    /// Start a child with a scrubbed environment.
    ///
    /// Hermetic on purpose: starting from PATH alone and removing every documented provider
    /// variable means an ambient `TAVILY_API_KEY`/`BRAVE_SEARCH_API_KEY` — exactly what the
    /// README tells a user to export — cannot make a stub-provider test contact the live vendor
    /// and report a false failure.
    init(
        binary: URL,
        environment: [String: String] = [:],
        arguments: [String] = []
    ) {
        process.executableURL = binary
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var merged: [String: String] = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ]
        for key in ServerTestSupport.providerEnvironmentVariables {
            merged.removeValue(forKey: key)
        }
        // Scrubbing the credentials is not enough any more. Providers that need no credential —
        // the scrapers, and SearXNG at whatever the ambient environment points at — are **on by
        // default**, so a test that names no environment still has a live search path, and the
        // suite silently acquires a network dependency. A test that wants one asks for it.
        merged[AppConfiguration.Key.enableScrapers.rawValue] = "false"
        merged[AppConfiguration.Key.enableParallel.rawValue] = "false"
        for (key, value) in environment { merged[key] = value }
        process.environment = ServerTestSupport.childEnvironment(base: merged)

        // Every call site used to leave stderr unread until something had already gone wrong,
        // which is exactly when its diagnostics are needed. Draining it as it is produced also
        // means a child that writes more to stderr than the pipe can hold cannot wedge on the
        // write.
        stderrCapture = StderrCapture(pipe: stderrPipe)
    }

    /// Stop the stderr reader and release the pipe.
    deinit {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    func start() throws {
        try process.run()
    }

    func send(_ object: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: object)
        line.append(UInt8(ascii: "\n"))
        stdinPipe.fileHandleForWriting.write(line)
    }

    /// Send one JSON-RPC request and read the response that carries `id`.
    ///
    /// The convenience the `ErrorReportingTests` copy had and the other two did not; folding it
    /// in is what lets that file drop its whole private harness.
    func call(id: Int, tool: String, arguments: [String: Any]) throws -> [String: Any] {
        try send([
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ])
        return try readResponse(id: id)
    }

    /// Read one JSON object from stdout, blocking until a full line arrives.
    ///
    /// The wait blocks in `poll` with the remaining budget rather than in `availableData`, so
    /// expiry throws even while the child is alive and silent. `poll` is restarted on `EINTR`
    /// for the time that is left, so a signal does not silently reset the bound.
    func readMessage(timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            // Serve any complete line already buffered: a poll after the deadline would
            // discard an answer that had already arrived.
            if let newlineIndex = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex]
                stdoutBuffer = Data(stdoutBuffer[stdoutBuffer.index(after: newlineIndex)...])
                if lineData.isEmpty { continue }
                guard
                    let object = try JSONSerialization.jsonObject(with: Data(lineData))
                        as? [String: Any]
                else {
                    throw ServerTestError.malformedResponse(
                        String(bytes: lineData, encoding: .utf8) ?? "<not valid UTF-8>"
                    )
                }
                return object
            }

            // Rounded up so a sub-millisecond remainder still polls once rather than
            // expiring early; a negative remainder is discarded by `guard`.
            let remaining = Int32((deadline.timeIntervalSinceNow * 1_000).rounded(.up))
            guard remaining > 0 else { throw ServerTestError.timeout }

            var descriptor = pollfd(
                fd: stdoutPipe.fileHandleForReading.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let ready = poll(&descriptor, 1, remaining)
            if ready == 0 { throw ServerTestError.timeout }
            if ready < 0 {
                if errno == EINTR { continue }
                throw ServerTestError.timeout
            }

            let chunk = stdoutPipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                // EOF: the process exited without answering.
                throw ServerTestError.unexpectedEOF(stderr: stderrText())
            }
            stdoutBuffer.append(chunk)
        }
    }

    /// Read messages until one has the requested JSON-RPC id.
    ///
    /// One deadline covers the whole call, so a stream of notifications cannot extend it.
    func readResponse(id: Int, timeout: TimeInterval = 15) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ServerTestError.timeout }
            let message = try readMessage(timeout: remaining)
            if let messageID = message["id"] as? Int, messageID == id { return message }
            // Notifications are skipped; this server sends none, but tolerate them.
        }
    }

    /// Everything the child wrote to stderr before it exited.
    ///
    /// Waiting for the background reader to reach EOF is what makes this the *complete* stream
    /// rather than whatever happened to have arrived: the reader is the only consumer, and it
    /// signals the group at EOF. The wait is bounded because the child is often still alive when
    /// a test inspects its diagnostics — a live MCP session keeps stdout and stderr open until
    /// `stop()` — so an unbounded wait here would hang exactly the way the read loop did.
    func stderrText() -> String {
        stderrCapture.text()
    }

    func stop() {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        // The reader signals its group at EOF; if the process was already gone the handler can
        // be the only thing still holding the read end, so tear it down rather than leave a
        // handler alive on a pipe that no longer has a writer.
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }
}

// MARK: - Mock transport
