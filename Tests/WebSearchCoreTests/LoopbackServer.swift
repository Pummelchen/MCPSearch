import Foundation
import XCTest

@testable import WebSearchCore

/// A tiny loopback HTTP server.
///
/// Exists so retry, timeout and cancellation behaviour can be verified against a
/// real socket instead of a mock that would simply encode the same assumptions the
/// client already makes.
final class LoopbackServer: @unchecked Sendable {
    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: String = "{}"
        /// The body as raw bytes, when it is not valid UTF-8.
        ///
        /// `body` is a `String`, so it reaches the wire as UTF-8 no matter what `Content-Type`
        /// claims. A page served in windows-1251, Shift_JIS or GBK therefore could not be represented
        /// at all, which is why the charset handling had no test that went through a fetch: there was
        /// no way to serve such a page. When set, this wins and `body` is ignored.
        var bodyData: Data?
        /// Delay before responding, for timeout tests.
        var delayMilliseconds: Int = 0
        /// Send the body in pieces and then hold the connection open without finishing it.
        ///
        /// `Content-Length` still declares the whole `body`, so a client that waits for the
        /// complete body waits until it gives up — which is what a hostile, endless page looks
        /// like. Used to prove a byte cap is enforced *during* the transfer.
        var drip: Drip?

        struct Drip: Sendable {
            var chunkBytes: Int
            var pauseMilliseconds: Int
            /// How long to hold the unfinished connection open, in seconds.
            var holdOpenSeconds: Int
            /// `Content-Length` to declare, when it should be larger than `body`.
            ///
            /// Declaring more than is ever sent is what makes the body *incomplete*: a reader
            /// that insists on the declared length ends in a transport error, while a reader
            /// that stops at its byte cap reports the cap. That difference is the test.
            var declaredBytes: Int?
        }
    }

    private let socketFD: Int32
    public let port: UInt16
    private let queue = DispatchQueue(label: "loopback.server", attributes: .concurrent)
    private let lock = NSLock()
    private var responses: [Response]
    private var _requestCount = 0
    /// Body bytes this server has handed to the socket.
    ///
    /// The drip loop stops when `send` reports the peer is gone, so this is how a test can tell
    /// whether a client that stopped reading also closed the connection — the difference between a
    /// transfer that was capped and one that was merely abandoned.
    private var _bytesSent = 0
    private var _requestMethods: [String] = []
    private var _requestPaths: [String] = []
    private var running = true

    init(responses: [Response]) throws {
        self.responses = responses
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketCreationFailed }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // let the kernel choose a free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw ServerError.bindFailed
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw ServerError.listenFailed
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &length)
            }
        }

        self.socketFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)
        guard let baseURL = URL(string: "http://127.0.0.1:\(self.port)/") else {
            throw ServerError.invalidBaseURL(port: self.port)
        }
        self.baseURL = baseURL

        // Accept connections on a background thread for the server's lifetime.
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    deinit {
        lock.lock()
        running = false
        lock.unlock()
        close(socketFD)
    }

    /// The server's base URL, built once in the initialiser.
    ///
    /// A computed property cannot `try`, so the force-unwrap here could not become an `XCTUnwrap`
    /// without making every one of its readers throwing. Building it in `init`, which already throws,
    /// turns the impossible case into a reportable error instead of a crash.
    let baseURL: URL

    var bytesSent: Int {
        lock.lock()
        defer { lock.unlock() }
        return _bytesSent
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }

    var requestMethods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requestMethods
    }

    var requestPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requestPaths
    }

    private func nextResponse() -> Response {
        lock.lock()
        defer { lock.unlock() }
        if responses.count > 1 {
            return responses.removeFirst()
        }
        return responses.first ?? Response()
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let stillRunning = running
            lock.unlock()
            guard stillRunning else { return }

            var clientAddress = sockaddr()
            var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(socketFD, &clientAddress, &clientLength)
            // `send` to a socket the peer has closed raises SIGPIPE, whose default disposition is to
            // terminate the process — so a client that stops reading at a byte cap killed the whole
            // test run with signal 13 instead of the server's loop seeing the failure. `SO_NOSIGPIPE`
            // is the macOS way to make that write return an error, which is what the drip loop's
            // `if sent <= 0 { break }` is written to handle.
            var noSIGPIPE: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSIGPIPE,
                socklen_t(MemoryLayout<Int32>.size)
            )
            guard client >= 0 else { return }

            // Read the request line so the test can assert on method and path.
            var buffer = [UInt8](repeating: 0, count: 8192)
            let read = recv(client, &buffer, buffer.count, 0)
            if read > 0, let text = String(bytes: buffer[0..<read], encoding: .utf8) {
                let requestLine = text.split(separator: "\r\n").first.map(String.init) ?? ""
                let parts = requestLine.split(separator: " ")
                lock.lock()
                _requestCount += 1
                if parts.count >= 2 {
                    _requestMethods.append(String(parts[0]))
                    _requestPaths.append(String(parts[1]))
                }
                lock.unlock()
            }

            let response = nextResponse()
            if response.delayMilliseconds > 0 {
                Thread.sleep(forTimeInterval: Double(response.delayMilliseconds) / 1000.0)
            }

            var headers = "HTTP/1.1 \(response.status) \(LoopbackServer.reason(response.status))\r\n"
            let bodyBytes = response.bodyData ?? Data(response.body.utf8)
            let declaredBytes = response.drip?.declaredBytes ?? bodyBytes.count
            headers += "Content-Length: \(declaredBytes)\r\n"
            headers += "Connection: close\r\n"
            for (name, value) in response.headers {
                headers += "\(name): \(value)\r\n"
            }
            headers += "\r\n"

            let payload = Array(headers.utf8) + Array(bodyBytes)
            if let drip = response.drip {
                let headerBytes = Array(headers.utf8)
                var offset = 0
                // Headers first, so the client sees Content-Length and starts reading a body.
                _ = headerBytes.withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count, 0) }
                while offset < payload.count {
                    let end = min(offset + drip.chunkBytes, payload.count)
                    let chunk = Array(payload[offset..<end])
                    let sent = chunk.withUnsafeBufferPointer {
                        send(client, $0.baseAddress, $0.count, 0)
                    }
                    if sent <= 0 { break }
                    lock.lock()
                    _bytesSent += sent
                    lock.unlock()
                    offset = end
                    if drip.pauseMilliseconds > 0 {
                        Thread.sleep(forTimeInterval: Double(drip.pauseMilliseconds) / 1000)
                    }
                }
                // Hold the connection open unfinished, so a client that insists on the declared
                // Content-Length cannot make progress. Reading returns once the peer gives up.
                let deadline = Date().addingTimeInterval(Double(drip.holdOpenSeconds))
                var scratch = [UInt8](repeating: 0, count: 1024)
                while Date() < deadline, recv(client, &scratch, scratch.count, 0) > 0 {}
                close(client)
                continue
            }
            _ = payload.withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count, 0) }
            close(client)
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    enum ServerError: Error {
        case socketCreationFailed
        case bindFailed
        case listenFailed
        case invalidBaseURL(port: UInt16)
    }
}

/// Transport-level retry, timeout and size policy.
