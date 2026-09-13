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
// pipeline first (ledger B113).
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
// how a typo turns into "no providers are configured" with no explanation (ledger B09).
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
// Jina is absent on purpose: its key only raises the page-extraction rate limit, and it is
// not a search provider. Parallel needs the flag *and* an endpoint, because an emptied
// PARALLEL_MCP_URL registers no adapter while the flag still reads as on.
let configuredProviders = [
    configuration.tavilyAPIKey != nil ? "tavily" : nil,
    configuration.braveAPIKey != nil ? "brave" : nil,
    configuration.mojeekAPIKey != nil ? "mojeek" : nil,
    configuration.exaAPIKey != nil ? "exa" : nil,
    configuration.searxngBaseURL != nil ? "searxng" : nil,
    configuration.openWebSearchURL != nil ? "open_web_search" : nil,
    configuration.enableScrapers ? "duckduckgo" : nil,
    configuration.enableScrapers ? "startpage" : nil,
    configuration.enableParallel && configuration.parallelMCPURL != nil ? "parallel" : nil,
].compactMap { $0 }

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
        "No search provider is configured. Set TAVILY_API_KEY, BRAVE_SEARCH_API_KEY, "
            + "MOJEEK_API_KEY, EXA_API_KEY or SEARXNG_BASE_URL. "
            + "web_search_status will show the details."
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
    // life of the process (ledger B03). The streamable transport owns the session header,
    // Accept negotiation and SSE framing; the host routes by session id.
    let makeSessionServer: HTTPMCPHost.SessionFactory = { transport in
        let sessionServer = await MCPServerFactory.make(handlers: handlers, log: log)
        try await sessionServer.start(transport: transport)
        return sessionServer
    }

    do {
        let host = HTTPMCPHost(
            configuration: httpConfiguration,
            makeServer: makeSessionServer,
            log: log
        )
        try await host.start()

        // Serve until the process is asked to stop.
        await host.waitUntilStopped()
        await host.stop()
        log.info("MCP server stopped")
    } catch {
        log.error("MCP server failed to start", metadata: ["error": "\(error)"])
        exit(1)
    }
}
