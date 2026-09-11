import Foundation
import XCTest

@testable import WebSearchCore

/// Command-line parsing for the transport selection.
///
/// A typo in a flag must fail loudly rather than silently starting the wrong transport,
/// so these tests focus as much on rejection as on acceptance.
final class TransportConfigurationTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultsToStdio() throws {
        let options = try ServerOptions.parse([])
        XCTAssertEqual(options.transport, .stdio)
        XCTAssertFalse(options.wantsHelp)
        XCTAssertNil(options.httpConfiguration)
    }

    /// The default HTTP bind address must be loopback: exposing the server is an
    /// explicit opt-in, and it has no authentication.
    func testHTTPDefaultsBindToLoopback() {
        let configuration = HTTPTransportConfiguration()
        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.port, 8080)
        XCTAssertEqual(configuration.path, "/mcp")
        XCTAssertTrue(configuration.isLoopback)
    }

    func testLoopbackDetection() {
        for host in ["127.0.0.1", "::1", "localhost"] {
            XCTAssertTrue(
                HTTPTransportConfiguration(host: host).isLoopback,
                "\(host) should be treated as loopback"
            )
        }
        for host in ["0.0.0.0", "192.168.1.10", "10.1.2.3", "example.com"] {
            XCTAssertFalse(
                HTTPTransportConfiguration(host: host).isLoopback,
                "\(host) must not be treated as loopback"
            )
        }
    }

    // MARK: - Transport selection

    func testSelectsHTTPTransport() throws {
        let options = try ServerOptions.parse(["--transport", "http"])
        XCTAssertNotNil(options.httpConfiguration)
        XCTAssertEqual(options.httpConfiguration?.port, HTTPTransportConfiguration.defaultPort)
    }

    func testAcceptsTransportAliases() throws {
        for alias in ["http", "streamable-http", "streamable_http", "HTTP"] {
            let options = try ServerOptions.parse(["--transport", alias])
            XCTAssertNotNil(options.httpConfiguration, "\(alias) should select HTTP")
        }
        let stdio = try ServerOptions.parse(["--transport", "stdio"])
        XCTAssertNil(stdio.httpConfiguration)
    }

    /// `--port`, `--host` and `--http-path` imply the HTTP transport, so an operator
    /// does not have to remember to pass `--transport http` as well.
    func testTransportOptionsImplyHTTP() throws {
        let port = try ServerOptions.parse(["--port", "9000"])
        XCTAssertEqual(port.httpConfiguration?.port, 9000)

        let host = try ServerOptions.parse(["--host", "0.0.0.0"])
        XCTAssertEqual(host.httpConfiguration?.host, "0.0.0.0")
        XCTAssertFalse(host.httpConfiguration?.isLoopback ?? true)

        let path = try ServerOptions.parse(["--http-path", "/custom"])
        XCTAssertEqual(path.httpConfiguration?.path, "/custom")
    }

    func testSupportsEqualsSyntax() throws {
        let options = try ServerOptions.parse([
            "--transport=http", "--port=9100", "--host=127.0.0.1", "--http-path=/x",
        ])
        XCTAssertEqual(options.httpConfiguration?.port, 9100)
        XCTAssertEqual(options.httpConfiguration?.path, "/x")
    }

    func testOptionsCombineInAnyOrder() throws {
        let options = try ServerOptions.parse(["--port", "9200", "--transport", "http", "--host", "::1"])
        XCTAssertEqual(options.httpConfiguration?.port, 9200)
        XCTAssertEqual(options.httpConfiguration?.host, "::1")
        XCTAssertTrue(options.httpConfiguration?.isLoopback ?? false)
    }

    /// A path without a leading slash is normalized rather than producing a route that
    /// could never match.
    func testPathIsNormalizedWithLeadingSlash() throws {
        let options = try ServerOptions.parse(["--http-path", "mcp"])
        XCTAssertEqual(options.httpConfiguration?.path, "/mcp")
    }

    // MARK: - Rejection

    func testUnknownArgumentIsRejected() {
        assertRejects(["--nope"], expecting: .unknownArgument("--nope"))
    }

    func testInvalidTransportIsRejected() {
        assertRejects(
            ["--transport", "carrier-pigeon"],
            expecting: .invalidValue(
                flag: "--transport",
                value: "carrier-pigeon",
                expected: "stdio or http"
            )
        )
    }

    func testOutOfRangePortsAreRejected() {
        for port in ["0", "65536", "-1", "abc", ""] {
            assertRejects(
                ["--port", port],
                expecting: .invalidValue(
                    flag: "--port",
                    value: port,
                    expected: "an integer between 1 and 65535"
                )
            )
        }
    }

    func testBoundaryPortsAreAccepted() throws {
        XCTAssertEqual(try ServerOptions.parse(["--port", "1"]).httpConfiguration?.port, 1)
        XCTAssertEqual(
            try ServerOptions.parse(["--port", "65535"]).httpConfiguration?.port,
            65535
        )
    }

    func testMissingValuesAreRejected() {
        for flag in ["--transport", "--port", "--host", "--http-path"] {
            assertRejects([flag], expecting: .missingValue(flag))
        }
    }

    func testEmptyHostIsRejected() {
        assertRejects(
            ["--host", "   "],
            expecting: .invalidValue(
                flag: "--host",
                value: "   ",
                expected: "an interface address such as 127.0.0.1"
            )
        )
    }

    func testHelpIsRecognized() throws {
        XCTAssertTrue(try ServerOptions.parse(["--help"]).wantsHelp)
        XCTAssertTrue(try ServerOptions.parse(["-h"]).wantsHelp)
    }

    /// The usage text must document every supported flag, so `--help` cannot drift from
    /// the parser.
    func testUsageDocumentsEveryFlag() {
        for flag in ["--transport", "--port", "--host", "--http-path"] {
            XCTAssertTrue(
                ServerOptions.usage.contains(flag),
                "usage text is missing \(flag)"
            )
        }
    }

    // MARK: - Helper

    private func assertRejects(
        _ arguments: [String],
        expecting expected: ServerOptions.OptionError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try ServerOptions.parse(arguments)
            XCTFail("expected \(expected) for \(arguments)", file: file, line: line)
        } catch let error as ServerOptions.OptionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }
}
