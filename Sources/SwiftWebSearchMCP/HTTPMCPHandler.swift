import Foundation
import Logging
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix
import WebSearchCore
import os

/// Converts NIO HTTP parts into SDK requests and writes the SDK's response back.
final class HTTPMCPHandler: ChannelInboundHandler, @unchecked Sendable {
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
    /// long-lived SSE response from being treated as an idle connection.
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
            // reallocates immediately.
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
            // is legitimately long-lived, so the idle bound stops applying here.
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
    /// rather than a silently shared session.
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
        //
        // The body is derived from the process, not asserted by it. See `HealthReport`.
        if path == "/health", method == .GET || method == .HEAD {
            let report = await host.health()
            return PreparedResponse(
                status: report.ready ? .ok : .serviceUnavailable,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: method == .HEAD ? nil : HTTPMCPHost.encode(report)
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
final class SSEStreamRelay: @unchecked Sendable {
    private let channel: Channel
    private let log: Log

    init(channel: Channel, log: Log) {
        self.channel = channel
        self.log = log
    }

    /// Consume the stream and write each frame as a chunk, then close.
    ///
    /// The relay ends when the *client* goes away, not only when the stream does. Without that, a task
    /// parked in `for try await frame in stream` waited for a next frame that, for a long-lived MCP
    /// session stream, may never arrive: a disconnected client left a suspended task holding the
    /// channel and the stream, and the session it belonged to could not make progress.
    /// `closeFuture` is NIO's own signal and completes on every close path, including a peer that
    /// vanished mid-response.
    func relay(_ stream: AsyncThrowingStream<Data, Swift.Error>) {
        let log = self.log

        let relay = Task {
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
            } catch is CancellationError {
                // The client disconnected: there is no one to finish the response for, and the
                // session's own teardown is what cleans up. Reaching this instead of hanging is the
                // whole point.
                log.debug("SSE client disconnected; relay stopped")
            } catch {
                log.debug("SSE stream ended with an error", metadata: ["error": "\(error)"])
                _ = try? await close().get()
            }
        }
        channel.closeFuture.whenComplete { _ in relay.cancel() }
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
