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

    /// The transport must not depend on where the flags appear.
    ///
    /// Each HTTP flag used to select the HTTP transport as it was parsed, so
    /// `--transport stdio --port 9000` served HTTP while `--port 9000 --transport stdio`
    /// served stdio. Same flags, different server.
    func testTransportChoiceDoesNotDependOnArgumentOrder() throws {
        let before = try ServerOptions.parse(["--transport", "http", "--port", "9300"])
        let after = try ServerOptions.parse(["--port", "9300", "--transport", "http"])
        XCTAssertEqual(before.transport, after.transport)
        XCTAssertEqual(before.httpConfiguration?.port, 9300)
        XCTAssertEqual(after.httpConfiguration?.port, 9300)
    }

    /// An explicit stdio request combined with HTTP-only options is a contradiction, not
    /// something to resolve silently in either direction.
    func testExplicitStdioWithHTTPOptionsIsRejected() {
        for arguments in [
            ["--transport", "stdio", "--port", "9000"],
            ["--port", "9000", "--transport", "stdio"],
            ["--transport=stdio", "--host", "0.0.0.0"],
            ["--http-path", "/x", "--transport", "stdio"],
        ] {
            XCTAssertThrowsError(
                try ServerOptions.parse(arguments),
                "\(arguments) asks for two different transports"
            ) { error in
                guard case ServerOptions.OptionError.conflictingArguments = error else {
                    return XCTFail("expected conflictingArguments, got \(error)")
                }
            }
        }
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

    /// A flag is not a value for the HTTP options either.
    ///
    /// `--host --http-path /x` used to take "--http-path" as the host and fail later at bind time
    /// (ledger B75).
    func testAnHTTPOptionDoesNotTakeTheNextFlagAsItsValue() {
        assertRejects(["--host", "--http-path", "/x"], expecting: .missingValue("--host"))
        assertRejects(["--port", "--host", "127.0.0.1"], expecting: .missingValue("--port"))
    }

    func testBoundaryPortsAreAccepted() throws {
        XCTAssertEqual(try ServerOptions.parse(["--port", "1"]).httpConfiguration?.port, 1)
        XCTAssertEqual(
            try ServerOptions.parse(["--port", "65535"]).httpConfiguration?.port,
            65535
        )
    }

    func testMissingValuesAreRejected() {
        for flag in ServerOptions.Flag.allCases where flag.takesValue {
            assertRejects([flag.canonicalName], expecting: .missingValue(flag.canonicalName))
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

    /// The usage text must document every flag the parser accepts, so `--help` cannot drift from
    /// the parser.
    ///
    /// The check is driven by the parser's own tables rather than a hand-written list, and it
    /// matches whole tokens rather than substrings. The previous version asserted four hard-coded
    /// names, so it passed no matter how the parser grew; a substring check would be little
    /// better, because `-h` is a substring of `--http-allowed-host` and so would pass without the
    /// alias ever being documented (ledger B114).
    func testUsageDocumentsEveryFlagTheParserAccepts() {
        let tokens = usageTokens()
        for flag in ServerOptions.Flag.allCases {
            for name in flag.names {
                XCTAssertTrue(
                    tokens.contains(name),
                    "usage text is missing \(name)"
                )
            }
        }
        for name in ServerOptions.TransportName.allCases.map(\.rawValue) {
            XCTAssertTrue(
                tokens.contains(name),
                "usage text is missing the --transport value \(name)"
            )
        }
        XCTAssertTrue(
            ServerOptions.usage.contains("--flag=value"),
            "usage text must document the --flag=value spelling"
        )
    }

    /// Every flag in the documented table is one the parser accepts.
    func testEveryDocumentedFlagIsAcceptedByTheParser() throws {
        for flag in ServerOptions.Flag.allCases {
            let arguments =
                sampleValue(for: flag).map { [flag.canonicalName, $0] } ?? [flag.canonicalName]
            XCTAssertNoThrow(try ServerOptions.parse(arguments), "\(arguments) should parse")
        }
    }

    /// Every value-taking flag accepts both `--flag value` and `--flag=value`.
    func testEveryValueFlagAcceptsBothSpellings() throws {
        for flag in ServerOptions.Flag.allCases {
            guard let value = sampleValue(for: flag) else { continue }
            let spaced = try ServerOptions.parse([flag.canonicalName, value])
            let inline = try ServerOptions.parse(["\(flag.canonicalName)=\(value)"])
            XCTAssertEqual(
                spaced.transport,
                inline.transport,
                "\(flag.canonicalName) behaves differently in its two spellings"
            )
        }
    }

    /// `--http-allowed-host` is a host name, not an address, so whitespace-only is a typo.
    func testEmptyAllowedHostIsRejected() {
        assertRejects(
            ["--http-allowed-host", "   "],
            expecting: .invalidValue(
                flag: "--http-allowed-host",
                value: "   ",
                expected: "a host name such as search.example.com"
            )
        )
    }

    // MARK: - Origin policy

    /// The default bind keeps exactly the SDK's loopback allow-list.
    ///
    /// A loopback server must not start accepting a LAN address just because one exists.
    func testLoopbackBindAcceptsOnlyTheLoopbackAuthorities() {
        let policy = HTTPTransportConfiguration().originPolicy(localAddresses: ["192.168.1.5"])
        XCTAssertEqual(
            policy.hosts,
            ["127.0.0.1:8080", "localhost:8080", "[::1]:8080"]
        )
        XCTAssertEqual(
            policy.origins,
            ["http://127.0.0.1:8080", "http://localhost:8080", "http://[::1]:8080"]
        )
    }

    /// A specific bind address is the deployment's own address and must be accepted.
    ///
    /// Hard-coding loopback answered the documented remote setup with `421 Misdirected Request`
    /// (ledger B21).
    func testNonLoopbackBindAcceptsItsOwnAddressAndStillRefusesOthers() {
        let policy = HTTPTransportConfiguration(host: "192.168.1.5", port: 9000)
            .originPolicy(localAddresses: [])
        XCTAssertTrue(policy.hosts.contains("192.168.1.5:9000"))
        XCTAssertTrue(policy.hosts.contains("192.168.1.5"), "a proxy may forward the bare name")
        XCTAssertTrue(policy.origins.contains("http://192.168.1.5:9000"))
        XCTAssertTrue(policy.hosts.contains("127.0.0.1:9000"), "local clients keep working")
        XCTAssertFalse(policy.hosts.contains { $0.contains("attacker") })
    }

    /// A wildcard bind answers on every interface, so each of the machine's addresses is named.
    func testWildcardBindAcceptsTheMachinesOwnAddresses() {
        let policy = HTTPTransportConfiguration(host: "0.0.0.0", port: 8080)
            .originPolicy(localAddresses: ["192.168.1.5", "100.64.0.9", "fe80::1"])
        XCTAssertTrue(policy.hosts.contains("192.168.1.5:8080"))
        XCTAssertTrue(policy.hosts.contains("100.64.0.9:8080"))
        XCTAssertTrue(
            policy.hosts.contains("[fe80::1]:8080"),
            "an IPv6 literal is bracketed in a Host header"
        )
        XCTAssertFalse(policy.hosts.contains("0.0.0.0:8080"), "the wildcard itself is not a Host")
    }

    /// `--http-allowed-host` names the public host a TLS-terminating proxy forwards.
    func testAllowedHostFlagAddsThePublicNameAndItsSecureOrigin() throws {
        let options = try ServerOptions.parse([
            "--host", "127.0.0.1",
            "--http-allowed-host", "search.example.com",
            "--http-allowed-host", "https://mcp.example.com:8443",
        ])
        let configuration = try XCTUnwrap(options.httpConfiguration)
        let policy = configuration.originPolicy(localAddresses: [])
        XCTAssertTrue(policy.hosts.contains("search.example.com:8080"))
        XCTAssertTrue(policy.hosts.contains("search.example.com"))
        XCTAssertTrue(policy.origins.contains("http://search.example.com:8080"))
        XCTAssertTrue(policy.origins.contains("https://search.example.com:8080"))
        XCTAssertTrue(
            policy.hosts.contains("mcp.example.com:8443"),
            "an explicit port is taken verbatim"
        )
        XCTAssertTrue(policy.origins.contains("https://mcp.example.com:8443"))
        XCTAssertFalse(policy.origins.contains("https://mcp.example.com:8080"))
    }

    /// The flag selects the HTTP transport like the other HTTP settings.
    func testAllowedHostImpliesHTTP() throws {
        let options = try ServerOptions.parse(["--http-allowed-host", "search.example.com"])
        XCTAssertEqual(options.httpConfiguration?.additionalAllowedHosts, ["search.example.com"])
    }

    // MARK: - Helper

    /// The whitespace-separated words of the usage text, with trailing `,`/`.` stripped.
    ///
    /// Tokens rather than substrings: `-h` occurs inside `--http-allowed-host`, so a raw
    /// containment check would bless an undocumented short alias (ledger B114).
    private func usageTokens() -> Set<String> {
        Set(
            ServerOptions.usage
                .split(whereSeparator: { $0.isWhitespace })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.")) }
        )
    }

    /// A value the parser accepts for a value-taking flag, or nil for the valueless `--help`.
    ///
    /// The switch is deliberately exhaustive without a `default`: adding a flag to
    /// `ServerOptions.Flag` fails to compile here until the test supplies a value for it, which is
    /// what keeps the table-driven checks above honest (ledger B114).
    private func sampleValue(for flag: ServerOptions.Flag) -> String? {
        switch flag {
        case .help: nil
        case .transport: "http"
        case .port: "9000"
        case .host: "127.0.0.1"
        case .httpAllowedHost: "search.example.com"
        case .httpPath: "/x"
        }
    }

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
