import Foundation

/// Which transport the server listens on.
///
/// stdio is the default and the right choice for local clients that launch the server
/// as a subprocess. Streamable HTTP exists for the remote connectors used by OpenAI's
/// Responses API and Anthropic's API, which cannot reach a stdio server.
public enum TransportMode: Sendable, Equatable {
    case stdio
    case http(HTTPTransportConfiguration)

    /// Parsed from `--transport`; defaults to stdio.
    public static let defaultMode: TransportMode = .stdio
}

/// Settings for the Streamable HTTP transport.
public struct HTTPTransportConfiguration: Sendable, Equatable {
    /// Interface to bind. Loopback by default: exposing this server to a network
    /// requires an explicit opt-in and is documented as needing TLS in front.
    public var host: String
    public var port: Int
    /// MCP endpoint path.
    public var path: String
    /// Extra host names this deployment answers to, from `--http-allowed-host`.
    ///
    /// A TLS-terminating proxy forwards the public name it was reached on, which need not be
    /// the address the server binds, so the operator declares it here (ledger B21).
    public var additionalAllowedHosts: [String] = []

    public static let defaultHost = "127.0.0.1"
    public static let defaultPort = 8080
    public static let defaultPath = "/mcp"

    public init(host: String = defaultHost, port: Int = defaultPort, path: String = defaultPath) {
        self.host = host
        self.port = port
        self.path = path
    }

    /// Whether the bind address is loopback.
    ///
    /// Used to decide whether startup should warn about network exposure.
    public var isLoopback: Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }
}

// MARK: - Command line

/// Parsed command-line options.
public struct ServerOptions: Sendable {
    public var transport: TransportMode
    /// Set when the user asked for `--help`.
    public var wantsHelp: Bool = false

    public static let usage = """
        SwiftWebSearchMCP — MCP server for public-web search.

        USAGE
          SwiftWebSearchMCP [options]

        TRANSPORT
          --transport <stdio|http>   Transport to serve on. Default: stdio.
          --port <n>                 HTTP port. Default: \(HTTPTransportConfiguration.defaultPort)
          --host <addr>              HTTP bind address. Default: \(HTTPTransportConfiguration.defaultHost)
          --http-allowed-host <host> Extra Host this server answers to, repeatable. Setting it
                                     selects the HTTP transport, like the flags above.
          --http-path <path>         MCP endpoint path. Default: \(HTTPTransportConfiguration.defaultPath)

        Setting any of --port, --host or --http-path selects the HTTP transport, so
        --transport http is optional. Combining one with an explicit --transport stdio is
        rejected rather than silently resolved.

        EXAMPLES
          # Local clients (Claude Desktop, Claude Code, Cursor, VS Code)
          SwiftWebSearchMCP

          # Remote connectors, reachable only from this machine
          SwiftWebSearchMCP --transport http --port 8080

        CONFIGURATION
          All settings come from the environment. See README and example.env.
          Diagnostics are written to stderr; stdout carries MCP protocol traffic only.
        """

    /// Parse command-line arguments.
    ///
    /// Unknown arguments and invalid values are rejected rather than ignored, so a
    /// typo cannot silently start the wrong transport.
    public static func parse(_ arguments: [String]) throws -> ServerOptions {
        var options = ServerOptions(transport: .stdio)
        var index = 0

        /// Which transport the user named, if any.
        enum Named { case stdio, http }

        /// HTTP-only settings are collected separately from the transport choice, so the
        /// order of arguments cannot decide which transport is served.
        var httpConfiguration = HTTPTransportConfiguration()
        var httpSettingsGiven = false
        var named: Named?

        /// Read the value for a flag, supporting both `--flag value` and `--flag=value`.
        func value(for flag: String) throws -> String {
            let current = arguments[index]
            if let equals = current.firstIndex(of: "=") {
                return String(current[current.index(after: equals)...])
            }
            guard index + 1 < arguments.count else {
                throw OptionError.missingValue(flag)
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]

            switch true {
            case argument == "--help" || argument == "-h":
                options.wantsHelp = true

            case argument == "--transport" || argument.hasPrefix("--transport="):
                let raw = try value(for: "--transport").lowercased()
                switch raw {
                case "stdio":
                    named = .stdio
                case "http", "streamable-http", "streamable_http":
                    named = .http
                default:
                    throw OptionError.invalidValue(
                        flag: "--transport",
                        value: raw,
                        expected: "stdio or http"
                    )
                }

            case argument == "--port" || argument.hasPrefix("--port="):
                let raw = try value(for: "--port")
                guard let port = Int(raw), (1...65535).contains(port) else {
                    throw OptionError.invalidValue(
                        flag: "--port",
                        value: raw,
                        expected: "an integer between 1 and 65535"
                    )
                }
                httpConfiguration.port = port
                httpSettingsGiven = true

            case argument == "--host" || argument.hasPrefix("--host="):
                let raw = try value(for: "--host")
                guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw OptionError.invalidValue(
                        flag: "--host",
                        value: raw,
                        expected: "an interface address such as 127.0.0.1"
                    )
                }
                httpConfiguration.host = raw
                httpSettingsGiven = true

            case argument == "--http-allowed-host" || argument.hasPrefix("--http-allowed-host="):
                let raw = try value(for: "--http-allowed-host")
                guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw OptionError.invalidValue(
                        flag: "--http-allowed-host",
                        value: raw,
                        expected: "a host name such as search.example.com"
                    )
                }
                httpConfiguration.additionalAllowedHosts.append(raw)
                httpSettingsGiven = true

            case argument == "--http-path" || argument.hasPrefix("--http-path="):
                var raw = try value(for: "--http-path")
                if !raw.hasPrefix("/") { raw = "/" + raw }
                httpConfiguration.path = raw
                httpSettingsGiven = true

            default:
                throw OptionError.unknownArgument(argument)
            }

            index += 1
        }

        switch named {
        case .stdio where httpSettingsGiven:
            // Contradictory rather than merely redundant: stdio has no host, port or path,
            // so one of the two requests is a mistake the user needs to see.
            throw OptionError.conflictingArguments(
                "HTTP options (--port/--host/--http-path) were given together with "
                    + "--transport stdio; drop one or ask for --transport http"
            )
        case .stdio:
            options.transport = .stdio
        case .http:
            options.transport = .http(httpConfiguration)
        case nil:
            // Documented convenience: HTTP-only flags select the HTTP transport, so
            // `--transport http` does not have to be repeated.
            options.transport = httpSettingsGiven ? .http(httpConfiguration) : .stdio
        }

        return options
    }

    /// The HTTP configuration in effect, if the HTTP transport was selected.
    public var httpConfiguration: HTTPTransportConfiguration? {
        if case .http(let configuration) = transport { return configuration }
        return nil
    }
}

extension ServerOptions {
    public enum OptionError: Error, CustomStringConvertible, Equatable {
        case unknownArgument(String)
        case missingValue(String)
        case invalidValue(flag: String, value: String, expected: String)
        case conflictingArguments(String)

        public var description: String {
            switch self {
            case .unknownArgument(let argument):
                "Unknown argument: \(argument)"
            case .missingValue(let flag):
                "Missing value for \(flag)"
            case .invalidValue(let flag, let value, let expected):
                "Invalid value for \(flag): '\(value)' (expected \(expected))"
            case .conflictingArguments(let detail):
                "Conflicting arguments: \(detail)"
            }
        }
    }
}
