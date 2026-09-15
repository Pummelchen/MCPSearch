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
///   is on receiving the request, so a streaming response is never treated as idle (ledger B90).
/// - **One session per client, and as many clients as connect.** The SDK's stateful
///   transport is single-session and one-shot: it refuses a second `initialize` and, once
///   terminated, answers 404 forever. This host therefore keeps a registry of sessions,
///   creating a fresh `Server` + transport pair per `initialize` and routing every later
///   request by the `Mcp-Session-Id` the SDK issues — `DELETE` included, which releases the
///   session (ledger B03).
///
/// A separate port serves a plain liveness check at `/health`, so a container or proxy
/// can probe the process without speaking MCP.
final class HTTPMCPHost: @unchecked Sendable {
    /// Builds and starts the MCP server for one session.
    ///
    /// Every session needs its own `Server`, because `Server.start(transport:)` binds one
    /// transport for the life of that server.
    typealias SessionFactory = @Sendable (StatefulHTTPServerTransport) async throws -> Server

    private let configuration: HTTPTransportConfiguration
    /// The `Host`/`Origin` allow-list the validation pipeline was built with, kept so the
    /// startup log can name it: a 421 is otherwise a puzzle for an operator (ledger B21).
    private let originPolicy: HTTPOriginPolicy
    private let makeServer: SessionFactory
    private let log: Log
    private let group: EventLoopGroup
    private let validationPipeline: any HTTPRequestValidationPipeline
    /// How long a connection may stay open without completing a request.
    ///
    /// The bound is on *receiving a request*, not on the exchange: it is disarmed the moment the
    /// request ends, so a response that legitimately streams (an SSE session stream) is never
    /// mistaken for an idle connection (ledger B90).
    private let requestCompletionTimeout: Duration
    private var channel: Channel?

    /// Most child connections this listener holds at once.
    ///
    /// swift-nio 2.102 has no `ChannelOptions.maxConnections`, and the package deliberately
    /// depends only on NIOCore/NIOPosix/NIOHTTP1, so `IdleStateHandler` is not available either.
    /// Both bounds are therefore enforced by this type: the counter below refuses a connection
    /// once the limit is reached, and `HTTPMCPHandler` closes one that does not complete its
    /// request in time. Sockets cannot be refused before `accept`, but a refused connection
    /// costs one descriptor for one event-loop turn instead of living until the peer gives up
    /// (ledger B90).
    static let maximumConnections = 64

    /// Live child channels, so the accept path can refuse a connection beyond the bound.
    private let liveConnections = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Live sessions, keyed by the id the SDK issued. Lock-guarded rather than actor-isolated
    /// because the request path is entered from NIO handlers.
    private let sessions = OSAllocatedUnfairLock<[String: SessionContext]>(initialState: [:])

    /// Resumed by `stop()` so `waitUntilStopped()` can park the process.
    private let shutdown = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

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
        log: Log
    ) {
        self.configuration = configuration
        self.makeServer = makeServer
        self.requestCompletionTimeout = requestCompletionTimeout
        self.log = log
        // The same validation for every session: origin, Accept, content type, protocol
        // version and session header. Origin validation costs nothing for server-to-server
        // callers and stops a browser page from driving the server.
        // Derived from the configured bind address rather than hard-coded to loopback: the
        // documented remote deployment puts a TLS proxy in front of `--host`, and every request
        // it forwarded carried the deployment's own address in `Host` (ledger B21).
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
    /// shared session (ledger B03).
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
            return .error(statusCode: 500, .internalError("Could not start an MCP session."))
        }
    }

    /// Release a session, if it is still registered.
    private func closeSession(id: String) async {
        guard let session = sessions.withLock({ $0.removeValue(forKey: id) }) else { return }
        await session.transport.disconnect()
        await session.server.stop()
        log.info("HTTP session released", metadata: ["sessions": "\(sessions.withLock { $0.count })"])
    }

    /// Number of live sessions, for tests.
    var sessionCount: Int { sessions.withLock { $0.count } }

    /// Count a new child channel and report how many are live now.
    ///
    /// Called from `HTTPMCPHandler.channelActive`; the matching release is in `channelInactive`,
    /// which NIO fires for every channel that became active (ledger B90).
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
        if let channel {
            try? await channel.close().get()
        }
        // Release every session's server and transport before the event loop group goes away.
        let live = sessions.withLock { dictionary -> [SessionContext] in
            let values = Array(dictionary.values)
            dictionary.removeAll()
            return values
        }
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

/// Converts NIO HTTP parts into SDK requests and writes the SDK's response back.
private final class HTTPMCPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let configuration: HTTPTransportConfiguration
    private let host: HTTPMCPHost
    private let requestCompletionTimeout: Duration
    private let log: Log

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer = ByteBuffer()
    /// Closes a connection that has not finished its request in time.
    ///
    /// Armed when the channel becomes active — before any header has been parsed, so a peer that
    /// trickles a request line is covered — and disarmed by `end`, which is what keeps a
    /// long-lived SSE response from being treated as an idle connection (ledger B90).
    private var requestDeadline: Scheduled<Void>?
    /// Set once a response has been written for the request in flight.
    ///
    /// An oversized body keeps streaming after it is rejected, and each further part used
    /// to trip the cap again and write a second response, which violates HTTP framing even
    /// though the connection closes afterwards.
    private var didRespond = false

    init(
        configuration: HTTPTransportConfiguration,
        host: HTTPMCPHost,
        requestCompletionTimeout: Duration,
        log: Log
    ) {
        self.configuration = configuration
        self.host = host
        self.requestCompletionTimeout = requestCompletionTimeout
        self.log = log
    }

    func channelActive(context: ChannelHandlerContext) {
        let live = host.registerConnection()
        context.fireChannelActive()
        guard live <= HTTPMCPHost.maximumConnections else {
            log.warning(
                "Refused an HTTP connection: the listener is at its concurrent-connection limit",
                metadata: ["limit": "\(HTTPMCPHost.maximumConnections)"]
            )
            // `channelInactive` follows and releases the count, so it is not released here.
            context.close(promise: nil)
            return
        }
        let channel = context.channel
        // `Duration` carries seconds plus attoseconds; NIO schedules in nanoseconds. The
        // arithmetic is exact and avoids the trap a Double conversion would bring.
        let components = requestCompletionTimeout.components
        let timeout = TimeAmount.nanoseconds(
            components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        )
        let log = self.log
        let timeoutDescription = "\(requestCompletionTimeout)"
        requestDeadline = context.eventLoop.scheduleTask(in: timeout) {
            log.warning(
                "Closing an HTTP connection that did not complete a request in time",
                metadata: ["timeout": timeoutDescription]
            )
            channel.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        requestDeadline?.cancel()
        requestDeadline = nil
        host.releaseConnection()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Responding through the channel rather than the context keeps the write path
        // free of a non-Sendable capture, which strict concurrency rejects.
        let channel = context.channel
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            bodyBuffer.clear()
            didRespond = false
            // A small fixed reservation, owned by `HTTPRequestBodyPolicy`. Reserving the
            // declared `Content-Length` meant a head-only request held up to 1 MiB per
            // connection before any body arrived, because `ByteBuffer.reserveCapacity`
            // reallocates immediately (ledger B79).
            let declaredLength = head.headers.first(name: "content-length").flatMap(Int.init)
            bodyBuffer.reserveCapacity(
                HTTPRequestBodyPolicy.reservationCapacity(
                    declaredContentLength: declaredLength
                )
            )

        case .body(var buffer):
            guard !didRespond else { return }
            bodyBuffer.writeBuffer(&buffer)
            if bodyBuffer.readableBytes > HTTPRequestBodyPolicy.maximumBodyBytes {
                didRespond = true
                requestHead = nil
                bodyBuffer.clear()
                respond(
                    to: channel,
                    status: .payloadTooLarge,
                    contentType: "text/plain; charset=utf-8",
                    body: Data("Request body too large".utf8)
                )
            }

        case .end:
            // The request is complete. Whatever happens next is a response, and an SSE response
            // is legitimately long-lived, so the idle bound stops applying here (ledger B90).
            requestDeadline?.cancel()
            requestDeadline = nil
            guard let head = requestHead else { return }
            requestHead = nil
            let body =
                bodyBuffer.readableBytes > 0
                ? Data(bodyBuffer.readableBytesView)
                : nil
            bodyBuffer.clear()

            let handler = self
            let host = self.host
            let log = self.log
            let eventLoop = context.eventLoop
            let channel = context.channel

            // MCP request handling is async; hop off the event loop. The completion runs
            // back on the event loop, where writing through the channel is safe. A
            // ChannelHandlerContext must not be captured here: it is not Sendable and may
            // outlive the handler by one turn.
            eventLoop.makeFutureWithTask {
                await handler.dispatch(
                    head: head,
                    body: body,
                    host: host,
                    log: log
                )
            }.whenComplete { result in
                eventLoop.execute {
                    switch result {
                    case .success(let response):
                        handler.write(response, to: channel)
                    case .failure(let error):
                        log.error("HTTP request handling failed", metadata: ["error": "\(error)"])
                        handler.respond(
                            to: channel,
                            status: .internalServerError,
                            contentType: "text/plain; charset=utf-8",
                            body: Data("Internal error".utf8)
                        )
                    }
                }
            }
        }
    }

    /// A prepared response.
    ///
    /// The stateful transport answers `initialize` with a complete JSON body but
    /// streams every other request as pre-formatted Server-Sent Events. Relaying that
    /// stream is what keeps an MCP session usable over HTTP, so it is modelled
    /// explicitly rather than collapsed into an empty body.
    private struct PreparedResponse {
        var status: HTTPResponseStatus
        var headers: [(String, String)]
        var body: Data?
        var stream: AsyncThrowingStream<Data, Swift.Error>?

        init(
            status: HTTPResponseStatus,
            headers: [(String, String)],
            body: Data? = nil,
            stream: AsyncThrowingStream<Data, Swift.Error>? = nil
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.stream = stream
        }
    }

    /// Route and handle one request.
    ///
    /// A request that carries a known `Mcp-Session-Id` goes to that session's transport,
    /// whatever its method — `POST` for messages, `GET` for the server-sent stream the SDK
    /// offers, `DELETE` to release the session. A request without one may only be a POST
    /// carrying `initialize`, which creates a session; anything else is a client error
    /// rather than a silently shared session (ledger B03).
    private func dispatch(
        head: HTTPRequestHead,
        body: Data?,
        host: HTTPMCPHost,
        log: Log
    ) async -> PreparedResponse {
        let method = head.method
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri

        // Liveness probe, deliberately outside the MCP endpoint so a proxy can check
        // the process without an MCP handshake.
        if path == "/health", method == .GET || method == .HEAD {
            return PreparedResponse(
                status: .ok,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: method == .HEAD ? nil : Data(#"{"status":"ok"}"#.utf8)
            )
        }

        guard path == configuration.path else {
            return PreparedResponse(
                status: .notFound,
                headers: [("Content-Type", "text/plain; charset=utf-8")],
                body: Data("Not Found. The MCP endpoint is \(configuration.path)".utf8)
            )
        }

        // Origin validation: a browser page must not be able to drive this server. Both
        // vendors call server-to-server, so an Origin header is unexpected; if one is
        // present it must be loopback.
        if let origin = head.headers.first(name: "Origin"), !origin.isEmpty {
            guard LoopbackOrigin.isLoopback(origin) else {
                log.warning("Rejected request from a non-loopback Origin")
                return PreparedResponse(
                    status: .forbidden,
                    headers: [("Content-Type", "text/plain; charset=utf-8")],
                    body: Data("Forbidden: cross-origin requests are not accepted.".utf8)
                )
            }
        }

        // Translate headers into the SDK's dictionary form.
        var headers: [String: String] = [:]
        // Preserve the first occurrence, matching HTTP semantics for these fields.
        for header in head.headers where headers[header.name] == nil {
            headers[header.name] = header.value
        }

        let request = MCP.HTTPRequest(
            method: method.rawValue,
            headers: headers,
            body: body,
            path: path
        )

        // Session routing, including creating a session for an `initialize`, is the host's
        // business; this layer only speaks HTTP.
        return HTTPMCPHandler.prepare(
            await host.handle(request: request, method: method, body: body, log: log)
        )
    }

    /// Convert the SDK's response into status, headers, body and optional stream.
    private static func prepare(_ response: MCP.HTTPResponse) -> PreparedResponse {
        var headers: [(String, String)] = []
        for (name, value) in response.headers {
            headers.append((name, value))
        }

        switch response {
        case .accepted:
            return PreparedResponse(status: .accepted, headers: headers, body: nil)
        case .ok:
            return PreparedResponse(status: .ok, headers: headers, body: nil)
        case .data(let data, _):
            return PreparedResponse(status: .ok, headers: headers, body: data)
        case .stream(let stream, _):
            // Relay the SDK's pre-formatted Server-Sent Events verbatim. The transport
            // finishes the stream once the response for this request has been produced,
            // so the exchange terminates on its own.
            return PreparedResponse(
                status: .ok,
                headers: headers,
                body: nil,
                stream: stream
            )
        case .error(let statusCode, _, _, _):
            return PreparedResponse(
                status: HTTPResponseStatus(statusCode: statusCode),
                headers: headers,
                body: response.bodyData
            )
        }
    }

    /// Write a response and finish the exchange.
    private func write(_ response: PreparedResponse, to channel: Channel) {
        if let stream = response.stream {
            writeStreamToChannel(stream, response: response, channel: channel)
        } else {
            respond(
                to: channel,
                status: response.status,
                headers: response.headers,
                body: response.body
            )
        }
    }

    /// Relay a Server-Sent Events stream as a chunked response body.
    ///
    /// No `Content-Length` is set, which lets NIO frame the body with chunked transfer
    /// encoding; each SSE frame the transport produces becomes one chunk. The content
    /// type comes from the transport and is `text/event-stream`.
    private func writeStreamToChannel(
        _ stream: AsyncThrowingStream<Data, Swift.Error>,
        response: PreparedResponse,
        channel: Channel
    ) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }
        // The response length is unknown up front; chunked framing is applied for us.
        headers.remove(name: "Content-Length")

        let head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
        channel.writeAndFlush(HTTPServerResponsePart.head(head), promise: nil)

        // Hand the stream to a relay bound to the channel. Keeping the writing out of
        // this handler avoids capturing a ChannelHandlerContext in a @Sendable closure,
        // which is not safe: the context may outlive the handler by one event-loop turn.
        SSEStreamRelay(channel: channel, log: log).relay(stream)
    }

    /// Write a response, defaulting the headers appropriately.
    private func respond(
        to channel: Channel,
        status: HTTPResponseStatus,
        contentType: String? = nil,
        headers extraHeaders: [(String, String)] = [],
        body: Data?
    ) {
        var headers = HTTPHeaders()
        var seenContentType = false
        for (name, value) in extraHeaders {
            if name.lowercased() == "content-type" { seenContentType = true }
            headers.add(name: name, value: value)
        }
        if let contentType, !seenContentType {
            headers.add(name: "Content-Type", value: contentType)
        }
        headers.add(name: "Content-Length", value: String(body?.count ?? 0))
        // This server has no interactive client session to keep alive; closing is the
        // simplest correct framing and avoids a half-open connection lingering.
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)

        if let body, !body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }

        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

// MARK: - Server-Sent Events relay

/// Writes an SSE stream to a channel.
///
/// Exists so the stream path does not capture a `ChannelHandlerContext` in a `@Sendable`
/// closure. Holding the `Channel` and its `EventLoop` is safe: every write is hopped onto
/// the event loop, and the channel is only read for its allocator.
///
/// `@unchecked Sendable` is honest here: the type owns no mutable state, and the channel
/// and event loop it holds are themselves thread-safe.
private final class SSEStreamRelay: @unchecked Sendable {
    private let channel: Channel
    private let log: Log

    init(channel: Channel, log: Log) {
        self.channel = channel
        self.log = log
    }

    /// Consume the stream and write each frame as a chunk, then close.
    func relay(_ stream: AsyncThrowingStream<Data, Swift.Error>) {
        let log = self.log

        Task {
            do {
                for try await frame in stream {
                    do {
                        try await writeFrame(frame).get()
                    } catch {
                        log.debug("SSE frame write failed", metadata: ["error": "\(error)"])
                        break
                    }
                }
                _ = try? await finish().get()
            } catch {
                log.debug("SSE stream ended with an error", metadata: ["error": "\(error)"])
                _ = try? await close().get()
            }
        }
    }

    private func writeFrame(_ frame: Data) -> EventLoopFuture<Void> {
        channel.eventLoop.makeFutureWithTask { [channel] in
            var buffer = channel.allocator.buffer(capacity: frame.count)
            buffer.writeBytes(frame)
            try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        }
    }

    private func finish() -> EventLoopFuture<Void> {
        channel.eventLoop.makeFutureWithTask { [channel] in
            try await channel.writeAndFlush(HTTPServerResponsePart.end(nil))
            try await channel.close()
        }
    }

    private func close() -> EventLoopFuture<Void> {
        channel.eventLoop.makeFutureWithTask { [channel] in
            try await channel.close()
        }
    }
}
