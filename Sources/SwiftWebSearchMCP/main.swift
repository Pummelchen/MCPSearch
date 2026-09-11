import Foundation
import Logging
import MCP
import WebSearchCore

/// Entry point for the SwiftWebSearchMCP stdio server.
///
/// Boot sequence:
/// 1. Parse configuration from the optional config file plus environment variables.
/// 2. Build the provider registry and the search/fetch pipeline.
/// 3. Register `web_search`, `web_open` and `web_search_status`.
/// 4. Serve MCP over stdio until the transport completes.
///
/// All diagnostics go to stderr. stdout carries JSON-RPC framing only.

let configuration = AppConfiguration.load()
let log = Log(level: configuration.logLevel, logQueries: configuration.logQueries)

log.info(
    "Starting \(MCPServerFactory.serverName)",
    metadata: [
        "version": MCPServerFactory.serverVersion,
        "log_level": configuration.logLevel.rawValue,
    ]
)

// Report which providers came up, without ever echoing a credential.
let configuredProviders = [
    configuration.tavilyAPIKey != nil ? "tavily" : nil,
    configuration.braveAPIKey != nil ? "brave" : nil,
    configuration.mojeekAPIKey != nil ? "mojeek" : nil,
    configuration.exaAPIKey != nil ? "exa" : nil,
    configuration.jinaAPIKey != nil ? "jina" : nil,
    configuration.searxngBaseURL != nil ? "searxng" : nil,
    configuration.openWebSearchURL != nil ? "open_web_search" : nil,
    configuration.enableScrapers ? "duckduckgo" : nil,
    configuration.enableScrapers ? "startpage" : nil,
    configuration.enableParallel ? "parallel" : nil,
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
