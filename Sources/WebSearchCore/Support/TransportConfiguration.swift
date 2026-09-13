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

    // MARK: Flags

    /// A command-line flag `parse` accepts.
    ///
    /// The parser dispatches on this table and `usage` is rendered from it, so a flag cannot be
    /// accepted without being documented, or documented without being accepted. The usage string
    /// used to be maintained by hand and had already fallen behind the parser — it did not mention
    /// `--help`, the `--transport` value aliases or the `--flag=value` spelling — while the test
    /// that claimed to check it asserted a hand-written list of four names (ledger B114).
    enum Flag: CaseIterable {
        case help
        case transport
        case port
        case host
        case httpAllowedHost
        case httpPath

        /// Every spelling the parser accepts for this flag, canonical first.
        var names: [String] {
            switch self {
            case .help: ["--help", "-h"]
            case .transport: ["--transport"]
            case .port: ["--port"]
            case .host: ["--host"]
            case .httpAllowedHost: ["--http-allowed-host"]
            case .httpPath: ["--http-path"]
            }
        }

        /// The spelling used to render `usage`.
        var canonicalName: String { names[0] }

        /// Whether the flag consumes the following argument.
        var takesValue: Bool {
            switch self {
            case .help: false
            case .transport, .port, .host, .httpAllowedHost, .httpPath: true
            }
        }

        /// The `<placeholder>` drawn after the canonical name, or nil for a valueless flag.
        var valuePlaceholder: String? {
            switch self {
            case .help: nil
            case .transport: "stdio|http"
            case .port: "n"
            case .host: "addr"
            case .httpAllowedHost: "host"
            case .httpPath: "path"
            }
        }

        /// Whether naming this flag on its own selects the HTTP transport.
        var selectsHTTP: Bool {
            switch self {
            case .port, .host, .httpAllowedHost, .httpPath: true
            case .help, .transport: false
            }
        }

        /// The flag as `usage` writes it: `--port <n>`, or `--help, -h`.
        var documentedForm: String {
            let spellings = names.joined(separator: ", ")
            guard let valuePlaceholder else { return spellings }
            return "\(canonicalName) <\(valuePlaceholder)>"
        }

        /// The description lines, with the name column supplied by the renderer.
        var documentation: [String] {
            switch self {
            case .help:
                ["Print this usage and exit."]
            case .transport:
                [
                    "Transport to serve on: "
                        + TransportName.allCases.map(\.rawValue).joined(separator: ", ") + ".",
                    "Default: stdio.",
                ]
            case .port:
                ["HTTP port. Default: \(HTTPTransportConfiguration.defaultPort)"]
            case .host:
                ["HTTP bind address. Default: \(HTTPTransportConfiguration.defaultHost)"]
            case .httpAllowedHost:
                [
                    "Extra Host this server answers to, repeatable. Setting it",
                    "selects the HTTP transport, like the flags above.",
                ]
            case .httpPath:
                ["MCP endpoint path. Default: \(HTTPTransportConfiguration.defaultPath)"]
            }
        }

        /// The flag an argument names, for both `--flag` and `--flag=value`.
        static func matching(_ argument: String) -> Flag? {
            for flag in Flag.allCases where flag.names.contains(argument) {
                return flag
            }
            for flag in Flag.allCases where flag.takesValue {
                for name in flag.names where argument.hasPrefix(name + "=") {
                    return flag
                }
            }
            return nil
        }

        /// The value written inline as `--flag=value`, when the argument uses that spelling.
        func inlineValue(in argument: String) -> String? {
            guard takesValue else { return nil }
            for name in names where argument.hasPrefix(name + "=") {
                return String(argument.dropFirst(name.count + 1))
            }
            return nil
        }
    }

    /// The spellings `--transport` accepts.
    ///
    /// `parse` resolves the value through this table and `usage` lists it from the table, so a new
    /// alias cannot be accepted without being documented (ledger B114).
    enum TransportName: String, CaseIterable {
        case stdio
        case http
        case streamableHyphen = "streamable-http"
        case streamableUnderscore = "streamable_http"
    }

    // MARK: Usage

    /// The help text.
    ///
    /// Rendered from `Flag` and `TransportName` — the same tables `parse` dispatches on — so the
    /// documented CLI and the accepted CLI cannot drift (ledger B114).
    public static let usage: String = renderUsage()

    private static func renderUsage() -> String {
        let forms = Flag.allCases.map(\.documentedForm)
        let column = (forms.map(\.count).max() ?? 0) + 2
        var lines = [
            "SwiftWebSearchMCP — MCP server for public-web search.",
            "",
            "USAGE",
            "  SwiftWebSearchMCP [options]",
            "",
            "OPTIONS",
        ]
        for (flag, form) in zip(Flag.allCases, forms) {
            var descriptions = flag.documentation
            let first = descriptions.removeFirst()
            let padding = String(repeating: " ", count: column - form.count)
            lines.append("  " + form + padding + first)
            for description in descriptions {
                lines.append("  " + String(repeating: " ", count: column) + description)
            }
        }
        let implicit = joinedList(Flag.allCases.filter(\.selectsHTTP).map(\.canonicalName))
        lines += [
            "",
            "Every flag that takes a value also accepts the --flag=value spelling, for example",
            "--port=\(HTTPTransportConfiguration.defaultPort).",
            "",
            "Setting any of \(implicit) selects the HTTP transport,",
            "so --transport http is optional. Combining one with an explicit",
            "--transport stdio is rejected rather than silently resolved.",
            "",
            "EXAMPLES",
            "  # Local clients (Claude Desktop, Claude Code, Cursor, VS Code)",
            "  SwiftWebSearchMCP",
            "",
            "  # Remote connectors, reachable only from this machine",
            "  SwiftWebSearchMCP --transport http --port \(HTTPTransportConfiguration.defaultPort)",
            "",
            "CONFIGURATION",
            "  All settings come from the environment. See README and example.env.",
            "  Diagnostics are written to stderr; stdout carries MCP protocol traffic only.",
        ]
        return lines.joined(separator: "\n")
    }

    /// `a`, `a and b` or `a, b and c`.
    private static func joinedList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " or " + items[items.count - 1]
        }
    }

    // MARK: Parsing

    /// Parse command-line arguments.
    ///
    /// Unknown arguments and invalid values are rejected rather than ignored, so a
    /// typo cannot silently start the wrong transport.
    public static func parse(_ arguments: [String]) throws -> ServerOptions {
        var options = ServerOptions(transport: .stdio)
        var index = 0

        /// HTTP-only settings are collected separately from the transport choice, so the
        /// order of arguments cannot decide which transport is served.
        var httpConfiguration = HTTPTransportConfiguration()
        var httpSettingsGiven = false
        var named: TransportName?

        /// Read the value for a flag, supporting both `--flag value` and `--flag=value`.
        func value(for flag: Flag) throws -> String {
            let current = arguments[index]
            if let inline = flag.inlineValue(in: current) {
                return inline
            }
            guard index + 1 < arguments.count else {
                throw OptionError.missingValue(flag.canonicalName)
            }
            // A flag is not a value: `--host --http-path` used to take "--http-path" as the host
            // and fail later at bind time. The `--flag=value` form above is unaffected (ledger
            // B75).
            guard !arguments[index + 1].hasPrefix("--") else {
                throw OptionError.missingValue(flag.canonicalName)
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            guard let flag = Flag.matching(argument) else {
                throw OptionError.unknownArgument(argument)
            }

            switch flag {
            case .help:
                options.wantsHelp = true

            case .transport:
                let raw = try value(for: .transport).lowercased()
                guard let name = TransportName(rawValue: raw) else {
                    throw OptionError.invalidValue(
                        flag: "--transport",
                        value: raw,
                        expected: "stdio or http"
                    )
                }
                named = name

            case .port:
                let raw = try value(for: .port)
                guard let port = Int(raw), (1...65535).contains(port) else {
                    throw OptionError.invalidValue(
                        flag: "--port",
                        value: raw,
                        expected: "an integer between 1 and 65535"
                    )
                }
                httpConfiguration.port = port
                httpSettingsGiven = true

            case .host:
                let raw = try value(for: .host)
                guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw OptionError.invalidValue(
                        flag: "--host",
                        value: raw,
                        expected: "an interface address such as 127.0.0.1"
                    )
                }
                httpConfiguration.host = raw
                httpSettingsGiven = true

            case .httpAllowedHost:
                let raw = try value(for: .httpAllowedHost)
                guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw OptionError.invalidValue(
                        flag: "--http-allowed-host",
                        value: raw,
                        expected: "a host name such as search.example.com"
                    )
                }
                httpConfiguration.additionalAllowedHosts.append(raw)
                httpSettingsGiven = true

            case .httpPath:
                var raw = try value(for: .httpPath)
                if !raw.hasPrefix("/") { raw = "/" + raw }
                httpConfiguration.path = raw
                httpSettingsGiven = true
            }

            index += 1
        }

        switch named {
        case .some(.stdio) where httpSettingsGiven:
            // Contradictory rather than merely redundant: stdio has no host, port or path,
            // so one of the two requests is a mistake the user needs to see.
            throw OptionError.conflictingArguments(
                "HTTP options (--port/--host/--http-path/--http-allowed-host) were given together with "
                    + "--transport stdio; drop one or ask for --transport http"
            )
        case .some(.stdio):
            options.transport = .stdio
        case .some:
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
