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
          --http-path <path>         MCP endpoint path. Default: \(HTTPTransportConfiguration.defaultPath)

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
                    options.transport = .stdio
                case "http", "streamable-http", "streamable_http":
                    // Keep any host/port already supplied on the command line.
                    let existing: HTTPTransportConfiguration
                    if case .http(let configuration) = options.transport {
                        existing = configuration
                    } else {
                        existing = HTTPTransportConfiguration()
                    }
                    options.transport = .http(existing)
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
                var configuration = options.httpConfiguration ?? HTTPTransportConfiguration()
                configuration.port = port
                options.transport = .http(configuration)

            case argument == "--host" || argument.hasPrefix("--host="):
                let raw = try value(for: "--host")
                guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw OptionError.invalidValue(
                        flag: "--host",
                        value: raw,
                        expected: "an interface address such as 127.0.0.1"
                    )
                }
                var configuration = options.httpConfiguration ?? HTTPTransportConfiguration()
                configuration.host = raw
                options.transport = .http(configuration)

            case argument == "--http-path" || argument.hasPrefix("--http-path="):
                var raw = try value(for: "--http-path")
                if !raw.hasPrefix("/") { raw = "/" + raw }
                var configuration = options.httpConfiguration ?? HTTPTransportConfiguration()
                configuration.path = raw
                options.transport = .http(configuration)

            default:
                throw OptionError.unknownArgument(argument)
            }

            index += 1
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

        public var description: String {
            switch self {
            case .unknownArgument(let argument):
                "Unknown argument: \(argument)"
            case .missingValue(let flag):
                "Missing value for \(flag)"
            case .invalidValue(let flag, let value, let expected):
                "Invalid value for \(flag): '\(value)' (expected \(expected))"
            }
        }
    }
}
