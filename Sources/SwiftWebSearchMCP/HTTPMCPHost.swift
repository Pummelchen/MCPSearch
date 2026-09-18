import Foundation
import Logging
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix
import WebSearchCore
import os

/// A minimal, correct HTTP/1.1 server that fronts the MCP SDK's Streamable HTTP
/// transport.
///
/// The SDK owns MCP-over-HTTP semantics — JSON-RPC framing, session headers, protocol
/// version validation, `Accept` negotiation, method routing — and exposes them as
/// `handleRequest(HTTPRequest) -> HTTPResponse`. This type is only the network layer
/// beneath that: it accepts connections, parses HTTP, forwards requests, and writes the
/// resulting response back.
///
/// Scope and deliberate limits:
///
/// - **Loopback by default.** Binding elsewhere is an explicit opt-in, and the server
///   warns at startup because it has no authentication.
/// - **No TLS.** The intended production shape is a TLS-terminating reverse proxy in
///   front; both OpenAI and Anthropic require an `https://` connector URL, so a public
///   deployment must terminate TLS somewhere.
/// - **No OAuth.** Both vendors prefer OAuth for remote servers; this serves the
///   no-auth case, which is the documented behaviour for anonymous endpoints.
/// - **No server-initiated streaming.** Responses are complete JSON bodies; if the SDK
///   produces a `text/event-stream` payload it is relayed verbatim rather than re-framed.
/// - **Bounded connections.** The listener holds at most `maximumConnections` child channels and
///   closes one that does not complete a request within the configured request budget. The bound
///  is on receiving the request, so a streaming response is never treated as idle.
/// - **One session per client, and as many clients as connect.** The SDK's stateful
///   transport is single-session and one-shot: it refuses a second `initialize` and, once
///   terminated, answers 404 forever. This host therefore keeps a registry of sessions,
///   creating a fresh `Server` + transport pair per `initialize` and routing every later
///   request by the `Mcp-Session-Id` the SDK issues — `DELETE` included, which releases the
///  session.
///
/// A separate port serves a plain liveness check at `/health`, so a container or proxy
/// can probe the process without speaking MCP.
final class HTTPMCPHost: @unchecked Sendable {
    /// Builds and starts the MCP server for one session.
    ///
    /// Every session needs its own `Server`, because `Server.start(transport:)` binds one
    /// transport for the life of that server.
    typealias SessionFactory = @Sendable (StatefulHTTPServerTransport) async throws -> Server

    /// What `/health` reports about this process.
    ///
    /// It used to return a hardcoded `{"status":"ok"}` from a literal, which told a supervisor
    /// nothing: the answer was identical whether every provider was dead or not, so a process that
    /// had bound the port and then bricked still looked healthy. The host now asks whoever built it,
    /// so the body describes the process instead of asserting a claim about it.
    struct HealthReport: Sendable {
        /// Whether this process can serve a search at all. False answers 503, which is what a
        /// supervisor should act on.
        var ready: Bool
        /// Facts for an operator or supervisor. Values are strings so the body cannot fail to encode.
        var details: [String: String]
    }

    /// Supplies the current health. Async because the state it reads is actor-isolated.
    typealias HealthSource = @Sendable () async -> HealthReport

    /// The `/health` body.
    ///
    /// `JSONSerialization` cannot fail on `[String: String]`, so the fallback is unreachable; it is
    /// `degraded` rather than `ok` so that even an impossible encoding failure cannot report health
    /// that was never observed.
    static func encode(_ report: HealthReport) -> Data {
        var payload: [String: String] = report.details
        payload["status"] = report.ready ? "ok" : "degraded"
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data(#"{"status":"degraded","reason":"health body could not be encoded"}"#.utf8)
    }

    let configuration: HTTPTransportConfiguration
    /// The `Host`/`Origin` allow-list the validation pipeline was built with, kept so the
    /// startup log can name it: a 421 is otherwise a puzzle for an operator.
    private let originPolicy: HTTPOriginPolicy
    private let makeServer: SessionFactory
    let log: Log
    /// `fileprivate` because the request handler is a separate type in this file and is the
    /// only reader.
    let health: HealthSource
    private let group: EventLoopGroup
    private let validationPipeline: any HTTPRequestValidationPipeline
    /// How long a connection may stay open without completing a request.
    ///
    /// The bound is on *receiving a request*, not on the exchange: it is disarmed the moment the
    /// request ends, so a response that legitimately streams (an SSE session stream) is never
    /// mistaken for an idle connection.
    let requestCompletionTimeout: Duration
    var channel: Channel?

    /// Most child connections this listener holds at once.
    ///
    /// swift-nio 2.102 has no `ChannelOptions.maxConnections`, and the package deliberately
    /// depends only on NIOCore/NIOPosix/NIOHTTP1, so `IdleStateHandler` is not available either.
    /// Both bounds are therefore enforced by this type: the counter below refuses a connection
    /// once the limit is reached, and `HTTPMCPHandler` closes one that does not complete its
    /// request in time. Sockets cannot be refused before `accept`, but a refused connection
    /// costs one descriptor for one event-loop turn instead of living until the peer gives up
    static let maximumConnections = 64

    /// Live child channels, so the accept path can refuse a connection beyond the bound.
    private let liveConnections = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Live sessions, keyed by the id the SDK issued. Lock-guarded rather than actor-isolated
    /// because the request path is entered from NIO handlers.
    private let sessions = OSAllocatedUnfairLock<[String: SessionContext]>(initialState: [:])

    /// The most sessions this host keeps at once.
    ///
    /// `initialize` creates a session and only `DELETE` releases it, so without a bound an
    /// unauthenticated client could open sessions until the process exhausted memory — each one
    /// holding a `Server` and a transport. Sixty-four is far more than the handful of clients this
    /// host is for, and small enough that the worst case is bounded.
    static let defaultMaximumLiveSessions = 64

    /// Reserved session slots, counting sessions that are being created as well as live ones.
    ///
    /// A plain `sessions.count` check would be a race: two concurrent `initialize` requests both read
    /// a count below the cap and both insert. Reserving a slot under the lock before the work starts
    /// makes the bound exact rather than approximate.
    private let liveSessions = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// The cap in force for this host, injectable so a test can reach it with a handful of
    /// sessions rather than sixty-five.
    private let maximumLiveSessions: Int

    /// Take a slot, or report that the host is full.
    private func reserveSessionSlot() -> Bool {
        liveSessions.withLock { live in
            guard live < maximumLiveSessions else { return false }
            live += 1
            return true
        }
    }

    private func releaseSessionSlot() {
        liveSessions.withLock { live in
            if live > 0 { live -= 1 }
        }
    }

    /// Resumed by `stop()` so `waitUntilStopped()` can park the process.
    private let shutdown = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    /// Whether `stop()` has already run.
    ///
    /// Shutdown is requested from the signal path *and* from the task parked in `waitUntilStopped()`,
    /// so it runs twice. The second call re-entered `group.shutdownGracefully()` and looked for a
    /// continuation that the first call had already resumed and cleared — the process then neither
    /// exited nor served, which is why the signal handler could not simply be added.
    private let hasStopped = OSAllocatedUnfairLock<Bool>(initialState: false)

    struct SessionContext: Sendable {
        let server: Server
        let transport: StatefulHTTPServerTransport
    }

    /// Fixed ids: the host has to know a session's id before its transport issues one.
    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    /// Windows-style CRLF is what HTTP/1.1 requires.
    private static let crlf = "\r\n"

    init(
        configuration: HTTPTransportConfiguration,
        makeServer: @escaping SessionFactory,
        requestCompletionTimeout: Duration,
        health: @escaping HealthSource,
        maximumLiveSessions: Int = HTTPMCPHost.defaultMaximumLiveSessions,
        log: Log
    ) {
        self.configuration = configuration
        self.makeServer = makeServer
        self.requestCompletionTimeout = requestCompletionTimeout
        self.health = health
        self.maximumLiveSessions = maximumLiveSessions
        self.log = log
        // The same validation for every session: origin, Accept, content type, protocol
        // version and session header. Origin validation costs nothing for server-to-server
        // callers and stops a browser page from driving the server.
        // Derived from the configured bind address rather than hard-coded to loopback: the
        // documented remote deployment puts a TLS proxy in front of `--host`, and every request
        // it forwarded carried the deployment's own address in `Host`.
        let policy = configuration.originPolicy
        self.originPolicy = policy
        self.validationPipeline = StandardValidationPipeline(validators: [
            OriginValidator(allowedHosts: policy.hosts, allowedOrigins: policy.origins),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])
        // One thread per core is the NIO default; a search server is I/O bound.
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    /// Route one request: to its session when it names one, or into a new session when it is
    /// an `initialize`.
    ///
    /// A request that carries a known `Mcp-Session-Id` goes to that session's transport,
    /// whatever the method — `POST` for messages, `GET` for the server-sent stream the SDK
    /// offers, `DELETE` to release the session. A request without a usable session may only be
    /// a POST carrying `initialize`; anything else is a client error rather than a silently
    /// shared session.
    func handle(
        request: MCP.HTTPRequest,
        method: HTTPMethod,
        body: Data?,
        log: Log
    ) async -> MCP.HTTPResponse {
        // `request.header(_:)` is the SDK's case-insensitive accessor: a client may send
        // `Mcp-Session-Id` in any casing, and HTTP header names are case-insensitive.
        if let sessionID = request.header(HTTPHeaderName.sessionID),
            let session = sessions.withLock({ $0[sessionID] })
        {
            let response = await session.transport.handleRequest(request)
            if method == .DELETE, case .ok = response {
                await closeSession(id: sessionID)
            }
            return response
        }

        guard method == .POST, HTTPMCPHost.isInitializeRequest(body) else {
            // Say which of the two is wrong instead of answering 405, which said nothing
            // about sessions at all.
            guard request.header(HTTPHeaderName.sessionID) == nil else {
                return .error(
                    statusCode: 404,
                    .invalidRequest(
                        "Not Found: session is unknown or has been released. Initialize again."
                    )
                )
            }
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: a POST carrying initialize is required to start a session.")
            )
        }

        return await createSession(request: request, log: log)
    }

    /// Whether the body is a single JSON-RPC `initialize` request.
    ///
    /// Parsed here rather than asked of the SDK, because the host has to decide *before* it has
    /// a transport whether this request may create a session.
    private static func isInitializeRequest(_ body: Data?) -> Bool {
        guard let body, !body.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        return object["method"] as? String == "initialize"
    }

    /// Create a session's `Server` and transport, then hand it this request.
    private func createSession(request: MCP.HTTPRequest, log: Log) async -> MCP.HTTPResponse {
        guard reserveSessionSlot() else {
            log.error(
                "refusing a new HTTP session",
                metadata: ["cap": "\(maximumLiveSessions)"]
            )
            return .error(statusCode: 503, .internalError("Too many live MCP sessions."))
        }
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline,
            logger: Logger(label: "mcp.transport.http")
        )

        do {
            let server = try await makeServer(transport)
            sessions.withLock { $0[sessionID] = SessionContext(server: server, transport: transport) }
            let response = await transport.handleRequest(request)
            if case .error = response {
                // The initialize itself was refused (protocol version, Accept, Origin…): do
                // not keep a session nobody can use.
                await closeSession(id: sessionID)
            }
            return response
        } catch {
            log.error("HTTP session could not be started", metadata: ["error": "\(error)"])
            await transport.disconnect()
            // The slot was reserved before the work began and no session was registered, so nothing
            // else will release it.
            releaseSessionSlot()
            return .error(statusCode: 500, .internalError("Could not start an MCP session."))
        }
    }

    /// Release a session, if it is still registered.
    private func closeSession(id: String) async {
        guard let session = sessions.withLock({ $0.removeValue(forKey: id) }) else { return }
        releaseSessionSlot()
        await session.transport.disconnect()
        await session.server.stop()
        log.info("HTTP session released", metadata: ["sessions": "\(sessions.withLock { $0.count })"])
    }

    /// Number of live sessions, for tests.
    var sessionCount: Int { sessions.withLock { $0.count } }

    /// Count a new child channel and report how many are live now.
    ///
    /// Called from `HTTPMCPHandler.channelActive`; the matching release is in `channelInactive`,
    /// which NIO fires for every channel that became active.
    func registerConnection() -> Int {
        liveConnections.withLock { live in
            live += 1
            return live
        }
    }

    /// Release a child channel that has closed.
    func releaseConnection() {
        liveConnections.withLock { $0 -= 1 }
    }

    /// Park until `stop()` is called, so the process lives while sessions come and go.
    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            shutdown.withLock { $0 = continuation }
        }
    }

    /// Start listening. Returns once the socket is bound.
    func start() async throws {
        let configuration = self.configuration
        let log = self.log
        let host = self
        let requestCompletionTimeout = self.requestCompletionTimeout

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPMCPHandler(
                            configuration: configuration,
                            host: host,
                            requestCompletionTimeout: requestCompletionTimeout,
                            log: log
                        )
                    )
                }
            }

        do {
            channel = try await bootstrap.bind(host: configuration.host, port: configuration.port)
                .get()
        } catch {
            throw HTTPHostError.bindFailed(
                host: configuration.host,
                port: configuration.port,
                reason: String(describing: error)
            )
        }

        let boundPort = channel?.localAddress?.port ?? configuration.port
        log.info(
            "Streamable HTTP transport listening",
            metadata: [
                "url": "http://\(configuration.host):\(boundPort)\(configuration.path)",
                "health": "http://\(configuration.host):\(boundPort)/health",
                "loopback_only": "\(configuration.isLoopback)",
                "allowed_hosts": originPolicy.hosts.joined(separator: ", "),
            ]
        )

        if !configuration.isLoopback {
            log.warning(
                "HTTP transport is bound to a non-loopback address and has no "
                    + "authentication. Put a TLS-terminating reverse proxy in front and "
                    + "restrict access, or bind 127.0.0.1 and use an SSH tunnel."
            )
        }
    }

    /// Stop listening and release resources.
    func stop() async {
        // Once only, whichever caller gets here first.
        let firstCall = hasStopped.withLock { stopped -> Bool in
            if stopped { return false }
            stopped = true
            return true
        }
        guard firstCall else { return }

        if let channel {
            try? await channel.close().get()
        }
        // Release every session's server and transport before the event loop group goes away.
        let live = sessions.withLock { dictionary -> [SessionContext] in
            let values = Array(dictionary.values)
            dictionary.removeAll()
            return values
        }
        // The sweep bypasses `closeSession`, so it releases the slots itself; otherwise the counter
        // would stay above zero for the life of the process.
        liveSessions.withLock { $0 = 0 }
        for session in live {
            await session.transport.disconnect()
            await session.server.stop()
        }
        try? await group.shutdownGracefully()
        shutdown.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }
    }
}

/// Errors raised while starting the HTTP host.
enum HTTPHostError: Error, CustomStringConvertible {
    case bindFailed(host: String, port: Int, reason: String)

    var description: String {
        switch self {
        case .bindFailed(let host, let port, let reason):
            "Could not bind \(host):\(port) — \(reason)"
        }
    }
}

// MARK: - Channel handler
