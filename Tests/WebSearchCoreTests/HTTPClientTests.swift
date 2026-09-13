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
        /// Delay before responding, for timeout tests.
        var delayMilliseconds: Int = 0
        /// Send the body in pieces and then hold the connection open without finishing it.
        ///
        /// `Content-Length` still declares the whole `body`, so a client that waits for the
        /// complete body waits until it gives up — which is what a hostile, endless page looks
        /// like. Used to prove a byte cap is enforced *during* the transfer (ledger B07).
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

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }

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
            let declaredBytes = response.drip?.declaredBytes ?? response.body.utf8.count
            headers += "Content-Length: \(declaredBytes)\r\n"
            headers += "Connection: close\r\n"
            for (name, value) in response.headers {
                headers += "\(name): \(value)\r\n"
            }
            headers += "\r\n"

            let payload = Array((headers + response.body).utf8)
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
    }
}

/// Transport-level retry, timeout and size policy.
final class HTTPClientTests: XCTestCase {

    private func makeClient(
        configuration: AppConfiguration,
        maxRetries: Int
    ) -> URLSessionHTTPClient {
        var configured = configuration
        configured.maxRetryAttempts = maxRetries
        configured.requestTimeout = .seconds(5)
        return URLSessionHTTPClient(configuration: configured, log: .disabled)
    }

    func testSucceedsOnFirstAttemptWithoutRetrying() async throws {
        let server = try LoopbackServer(responses: [.init(status: 200, body: #"{"ok":true}"#)])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 2)

        let response = try await client.send(.get(server.baseURL, label: "test"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testRetriesTransientServerErrorForIdempotentRequest() async throws {
        let server = try LoopbackServer(responses: [
            .init(status: 503, body: "unavailable"),
            .init(status: 503, body: "unavailable"),
            .init(status: 200, body: #"{"ok":true}"#),
        ])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 2)

        let response = try await client.send(.get(server.baseURL, label: "test"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(server.requestCount, 3, "expected two retries then success")
    }

    func testGivesUpAfterMaxAttempts() async throws {
        let server = try LoopbackServer(responses: [.init(status: 503, body: "down")])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 1)

        let response = try await client.send(.get(server.baseURL, label: "test"))
        // The client returns the last response rather than throwing, so the provider
        // layer classifies it.
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(server.requestCount, 2, "one initial attempt plus one retry")
    }

    func testDoesNotRetryNonTransientClientError() async throws {
        let server = try LoopbackServer(responses: [.init(status: 400, body: "bad request")])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 3)

        let response = try await client.send(.get(server.baseURL, label: "test"))
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(server.requestCount, 1, "4xx other than 408/425/429 must not be retried")
    }

    func testDoesNotRetryNonIdempotentRequest() async throws {
        // POST may have already had an effect, so a transient failure must not be
        // replayed. This matters because Tavily and Exa search via POST and each
        // retry costs credits.
        let server = try LoopbackServer(responses: [.init(status: 503, body: "down")])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 3)

        let response = try await client.send(
            .post(server.baseURL, headers: [:], body: Data("{}".utf8), label: "test")
        )
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testHonorsRetryAfterHeader() async throws {
        let server = try LoopbackServer(responses: [
            .init(status: 429, headers: ["Content-Type": "application/json", "Retry-After": "1"], body: "slow down"),
            .init(status: 200, body: #"{"ok":true}"#),
        ])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 2)

        let started = DispatchTime.now().uptimeNanoseconds
        let response = try await client.send(.get(server.baseURL, label: "test"))
        let elapsedMilliseconds = Int(
            (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertGreaterThanOrEqual(
            elapsedMilliseconds,
            900,
            "the client must wait for the indicated Retry-After"
        )
    }

    func testEnforcesResponseSizeLimit() async throws {
        let bigBody = String(repeating: "x", count: 10_000)
        let server = try LoopbackServer(responses: [.init(status: 200, body: bigBody)])
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 0)

        do {
            _ = try await client.send(.get(server.baseURL, label: "test"), maxBytes: 1_000)
            XCTFail("expected the size limit to be enforced")
        } catch let error as HTTPError {
            guard case .responseTooLarge = error else {
                return XCTFail("expected responseTooLarge, got \(error)")
            }
            XCTAssertFalse(error.isTransient, "an oversized body is not retryable")
        }
    }

    func testTransportFailureIsTransient() async throws {
        // Port 1 on loopback is not listening, so the connection is refused.
        let client = makeClient(configuration: Fixtures.configuration(), maxRetries: 0)
        let unreachable = URL(string: "http://127.0.0.1:1/")!

        do {
            _ = try await client.send(.get(unreachable, label: "test"))
            XCTFail("expected a connection failure")
        } catch let error as HTTPError {
            XCTAssertTrue(error.isTransient)
        }
    }

    func testCancellationPropagatesAsCancelled() async throws {
        let server = try LoopbackServer(responses: [.init(status: 200, body: "{}", delayMilliseconds: 3_000)])
        var configuration = Fixtures.configuration()
        configuration.requestTimeout = .seconds(10)
        let client = URLSessionHTTPClient(configuration: configuration, log: .disabled)

        let task = Task {
            try await client.send(.get(server.baseURL, label: "test"))
        }
        // Give the request time to reach the server, then cancel.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            XCTFail("expected cancellation")
        case .failure(let error):
            XCTAssertTrue(
                error is CancellationError || (error as? HTTPError) != nil,
                "cancellation must surface as an error, got \(error)"
            )
        }
    }

    func testHeaderLookupIsCaseInsensitive() {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["retry-after": "5"],
            body: Data(),
            url: URL(string: "https://example.com")!
        )
        XCTAssertEqual(response.header("Retry-After"), "5")
        XCTAssertEqual(response.header("RETRY-AFTER"), "5")
        XCTAssertNil(response.header("absent"))
    }

    func testTextDecodingFallsBackToLatin1() {
        // 0xE9 is `é` in Latin-1 but invalid UTF-8, so a UTF-8-only decode would
        // wrongly produce an empty string.
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data([0x63, 0x61, 0x66, 0xE9]),
            url: URL(string: "https://example.com")!
        )
        XCTAssertEqual(response.text(), "café")
    }
}
