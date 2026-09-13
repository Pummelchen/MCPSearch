import Foundation
import Logging
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix
import WebSearchCore

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
/// - **No server-initiated streaming.** The SDK's stateless transport answers each
///   request with a complete JSON response, which is what the JSON transport path
///   requires. `text/event-stream` payloads are relayed if the SDK ever produces one.
///
/// A separate port serves a plain liveness check at `/health`, so a container or proxy
/// can probe the process without speaking MCP.
final class HTTPMCPHost: @unchecked Sendable {
    private let configuration: HTTPTransportConfiguration
    private let transport: StatefulHTTPServerTransport
    private let log: Log
    private let group: EventLoopGroup
    private var channel: Channel?

    /// Windows-style CRLF is what HTTP/1.1 requires.
    private static let crlf = "\r\n"

    init(
        configuration: HTTPTransportConfiguration,
        transport: StatefulHTTPServerTransport,
        log: Log
    ) {
        self.configuration = configuration
        self.transport = transport
        self.log = log
        // One thread per core is the NIO default; a search server is I/O bound.
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    /// Start listening. Returns once the socket is bound.
    func start() async throws {
        let configuration = self.configuration
        let transport = self.transport
        let log = self.log

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPMCPHandler(
                            configuration: configuration,
                            transport: transport,
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
        try? await group.shutdownGracefully()
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
    private let transport: StatefulHTTPServerTransport
    private let log: Log

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer = ByteBuffer()
    /// Set once a response has been written for the request in flight.
    ///
    /// An oversized body keeps streaming after it is rejected, and each further part used
    /// to trip the cap again and write a second response, which violates HTTP framing even
    /// though the connection closes afterwards.
    private var didRespond = false

    init(
        configuration: HTTPTransportConfiguration,
        transport: StatefulHTTPServerTransport,
        log: Log
    ) {
        self.configuration = configuration
        self.transport = transport
        self.log = log
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
            // Bound the body so a single request cannot exhaust memory.
            bodyBuffer.reserveCapacity(
                min(head.headers.first(name: "content-length").flatMap(Int.init) ?? 4096, 1 << 20))

        case .body(var buffer):
            guard !didRespond else { return }
            bodyBuffer.writeBuffer(&buffer)
            if bodyBuffer.readableBytes > HTTPMCPHandler.maximumBodyBytes {
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
            guard let head = requestHead else { return }
            requestHead = nil
            let body =
                bodyBuffer.readableBytes > 0
                ? Data(bodyBuffer.readableBytesView)
                : nil
            bodyBuffer.clear()

            let handler = self
            let configuration = self.configuration
            let transport = self.transport
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
                    configuration: configuration,
                    transport: transport,
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

    /// Largest accepted request body. MCP requests are small; a search result body is
    /// produced by the server, not received.
    static let maximumBodyBytes = 1 << 20  // 1 MiB

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
    private func dispatch(
        head: HTTPRequestHead,
        body: Data?,
        configuration: HTTPTransportConfiguration,
        transport: StatefulHTTPServerTransport,
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

        // Only POST is meaningful to the stateless transport; it produces 405 for
        // anything else, but rejecting here keeps the error message clearer.
        guard method == .POST else {
            return PreparedResponse(
                status: .methodNotAllowed,
                headers: [
                    ("Content-Type", "text/plain; charset=utf-8"),
                    ("Allow", "POST"),
                ],
                body: Data("Method Not Allowed. Use POST for MCP messages.".utf8)
            )
        }

        // Origin validation: a browser page must not be able to drive this server. Both
        // vendors call server-to-server, so an Origin header is unexpected; if one is
        // present it must be loopback.
        if let origin = head.headers.first(name: "Origin"), !origin.isEmpty {
            guard HTTPMCPHandler.isLoopbackOrigin(origin) else {
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
        for header in head.headers {
            // Preserve the first occurrence, matching HTTP semantics for these fields.
            if headers[header.name] == nil {
                headers[header.name] = header.value
            }
        }

        let request = MCP.HTTPRequest(
            method: "POST",
            headers: headers,
            body: body,
            path: path
        )

        let response = await transport.handleRequest(request)
        return HTTPMCPHandler.prepare(response)
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

    /// Whether an `Origin` header refers to this machine.
    private static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host() else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
            || host.hasPrefix("127.")
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
