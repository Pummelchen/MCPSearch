import Foundation
import Logging
import MCP
import WebSearchCore

// Entry point for the SwiftWebSearchMCP server.
//
// Boot sequence:
// 1. Parse the command line and answer `--help`, before anything depends on the environment.
// 2. Parse configuration from the optional config file plus environment variables.
// 3. Build the provider registry and the search/fetch pipeline.
// 4. Register `web_search`, `web_open`, `web_answer` and `web_search_status`.
// 5. Serve MCP over the selected transport until it completes.
//
// All diagnostics go to stderr. stdout carries JSON-RPC framing only.

// The command line is parsed before any configuration is loaded. The reverse order meant that a
// mistyped `SEARCH_CONFIG_FILE` refused to start even for `--help`, and a flag that was about to
// be rejected still emitted the startup log and built the HTTP client and the whole provider
// pipeline first.
let options: ServerOptions
do {
    options = try ServerOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    // The logger takes its level from the configuration, which is deliberately not loaded yet, so
    // this diagnostic goes to stderr directly.
    FileHandle.standardError.write(
        Data(("Invalid arguments: \(error)\n" + ServerOptions.usage + "\n").utf8)
    )
    exit(2)
}

if options.wantsHelp {
    print(ServerOptions.usage)
    exit(0)
}

let configuration = AppConfiguration.load()
let log = Log(level: configuration.logLevel, logQueries: configuration.logQueries)

// Report every configured value that could not be used. Silently falling back to a default is
// how a typo turns into "no providers are configured" with no explanation.
for issue in configuration.issues {
    // The tool's own logger takes string metadata; the detail never contains a credential.
    let metadata = ["key": issue.key, "detail": issue.detail]
    switch issue.kind {
    case .unreadableConfigFile:
        log.error("Configuration file problem", metadata: metadata)
    case .unparseableValue, .invalidURL:
        log.warning("Ignoring an unusable configured value", metadata: metadata)
    }
}
if configuration.issues.contains(where: { $0.kind == .unreadableConfigFile }) {
    // A config file that was asked for and is not there is fatal: starting with defaults would
    // quietly serve a different configuration than the one the operator provided.
    FileHandle.standardError.write(
        Data("Refusing to start: SEARCH_CONFIG_FILE could not be read.\n".utf8)
    )
    exit(2)
}

log.info(
    "Starting \(MCPServerFactory.serverName)",
    metadata: [
        "version": MCPServerFactory.serverVersion,
        "log_level": configuration.logLevel.rawValue,
    ]
)

// Report which providers came up, without ever echoing a credential.
//
// The requirements and their satisfaction both come from `ProviderEnablement`, the one
// authority the status tool, the tool error text and the monitor also read, so a provider
// cannot be named here and forgotten there. The inventory and the
// empty-configuration warning read the same authority, so the warning cannot name only the
// variables that existed when it was written.
//
// Jina is absent on purpose: its key only raises the page-extraction rate limit, and it is
// not a search provider. Parallel needs the flag *and* an endpoint, because an emptied
// PARALLEL_MCP_URL registers no adapter while the flag still reads as on — which is exactly
// the pair of inputs `ProviderEnablement` records for it.
let configuredProviders = ProviderID.allCases
    .filter { ProviderEnablement.isSatisfied($0, in: configuration) }
    .map(\.rawValue)

// Every variable that can register a provider, named once each.
let providerVariables = ProviderEnablement.allInputs.map(\.variableName)

log.info(
    "Provider configuration resolved",
    metadata: [
        "configured": configuredProviders.isEmpty
            ? "none" : configuredProviders.joined(separator: ","),
        "scrapers_enabled": "\(configuration.enableScrapers)",
        "parallel_enabled": "\(configuration.enableParallel)",
    ]
)

if configuredProviders.isEmpty {
    // Not fatal: the server must start and explain itself with zero keys.
    log.warning(
        "No search provider is configured. Set "
            + providerVariables.joined(separator: ", ")
            + ". web_search_status will show the details."
    )
}

let http = URLSessionHTTPClient(configuration: configuration, log: log)

let pipeline = SearchPipelineFactory.make(
    configuration: configuration,
    http: http,
    log: log
)

let handlers = ToolHandlers(pipeline: pipeline, log: log)

let server = await MCPServerFactory.make(handlers: handlers, log: log)

/// Stop the server cleanly, releasing the HTTP socket if one is bound.
func shutdown(server: Server, host: HTTPMCPHost?) async {
    await server.stop()
    await host?.stop()
}

/// Sources kept alive for the process's lifetime; a released `DispatchSource` stops delivering.
nonisolated(unsafe) var terminationSources: [DispatchSourceSignal] = []

/// Run `body` when the process is asked to stop.
///
/// Nothing installed a handler and `shutdown` was never called, so the HTTP branch parked in
/// `waitUntilStopped()` for a wake-up that nothing could send: `SIGTERM` killed the process outright
/// and the sweep in `stop()` never ran. `HTTPMCPHost.stop()` had to become once-only first, because
/// both this path and the parked task call it (ledger A0009).
func onTermination(_ body: @escaping @Sendable () -> Void) {
    for number in [SIGINT, SIGTERM] {
        // The default disposition would end the process before the source could fire.
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler(handler: body)
        source.resume()
        terminationSources.append(source)
    }
}

switch options.transport {
case .stdio:
    // The MCP SDK owns JSON-RPC framing; only the transport is ours to choose.
    let transport = StdioTransport(logger: Logger(label: "mcp.transport.stdio"))
    do {
        try await server.start(transport: transport)
        log.info("MCP server listening on stdio")
        await server.waitUntilCompleted()
        log.info("MCP server stopped")
    } catch {
        log.error("MCP server failed to start", metadata: ["error": "\(error)"])
        exit(1)
    }

case .http(let httpConfiguration):
    // One Server and one transport per session. The SDK's stateful transport is single-session
    // and one-shot — it refuses a second `initialize` and answers 404 forever after a
    // termination — so a shared instance meant exactly one HTTP client per process, for the
    // life of the process. The streamable transport owns the session header,
    // Accept negotiation and SSE framing; the host routes by session id.
    let makeSessionServer: HTTPMCPHost.SessionFactory = { transport in
        let sessionServer = await MCPServerFactory.make(handlers: handlers, log: log)
        try await sessionServer.start(transport: transport)
        return sessionServer
    }

    do {
        // Derived from the same state `web_search_status` reports, so an operator reading
        // `/health` sees the process rather than a claim about it. `ready` is what a supervisor
        // should act on: a server with no configured provider cannot serve a search, and saying so
        // with a 503 is the point of the endpoint.
        let healthSource: HTTPMCPHost.HealthSource = {
            let states = await pipeline.orchestrator.status()
            let configured = states.filter(\.configured).count
            // Readiness is usability, not configuration. A provider whose circuit is open is
            // configured and cannot serve: reporting `ok` for a process whose every configured
            // provider is skipping requests tells a supervisor to keep sending traffic to something
            // that will answer each one with a failure. `web_search_status` already reports the
            // circuit, so this derives from the same state rather than guessing at it (ledger A0053).
            let usable = states.filter { $0.configured && $0.circuit.state != .open }.count
            return HTTPMCPHost.HealthReport(
                ready: usable > 0,
                details: [
                    "version": BuildVersion.value,
                    "providers_total": "\(states.count)",
                    "providers_configured": "\(configured)",
                    "providers_usable": "\(usable)",
                ]
            )
        }
        let host = HTTPMCPHost(
            configuration: httpConfiguration,
            makeServer: makeSessionServer,
            // The same budget the fetch itself gets. It also bounds how long an inbound
            // connection may stay open without completing its request, so a peer that opens
            // connections and never finishes a request cannot hold them indefinitely
            requestCompletionTimeout: configuration.requestTimeout,
            health: healthSource,
            // An unauthenticated peer controls how many sessions exist, so the bound is configurable
            // rather than fixed. Nil means the host's own default (ledger A0028).
            maximumLiveSessions: httpConfiguration.maximumLiveSessions
                ?? HTTPMCPHost.defaultMaximumLiveSessions,
            log: log
        )
        try await host.start()

        // Serve until the process is asked to stop, and leave through the path a signal takes rather
        // than by being killed (ledger A0009).
        onTermination { Task { await shutdown(server: server, host: host) } }
        await host.waitUntilStopped()
        await host.stop()
        log.info("MCP server stopped")
    } catch {
        log.error("MCP server failed to start", metadata: ["error": "\(error)"])
        exit(1)
    }
}
