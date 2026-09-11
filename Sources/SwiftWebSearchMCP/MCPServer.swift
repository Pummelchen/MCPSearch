import Foundation
import MCP
import WebSearchCore

/// Builds the MCP server and wires the tool surface.
enum MCPServerFactory {
    static let serverName = "SwiftWebSearchMCP"
    static let serverVersion = "1.0.0"

    /// Create a configured `Server` with all three tools registered.
    ///
    /// The transport is intentionally not connected here so that tests can drive the
    /// server over an in-memory transport.
    static func make(handlers: ToolHandlers, log: Log) async -> Server {
        let server = Server(
            name: serverName,
            version: serverVersion,
            title: "Swift Web Search",
            instructions: """
                Search the public web and fetch pages. Use web_search for discovery and \
                web_open to read a specific URL. Results carry provenance in `sources`; \
                prefer results corroborated by multiple independent providers. \
                Use web_search_status only for diagnostics.
                """,
            capabilities: Server.Capabilities(
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(
                tools: [
                    Tool(
                        name: ToolSchemas.searchToolName,
                        title: "Web search",
                        description: """
                            Search the public web and return ranked, deduplicated results \
                            with source attribution. Providers are selected automatically and \
                            results are fused; a failing provider degrades gracefully rather \
                            than failing the search.
                            """,
                        inputSchema: ToolSchemas.webSearchInput,
                        annotations: Tool.Annotations(
                            title: "Web search",
                            readOnlyHint: true,
                            destructiveHint: false,
                            idempotentHint: false,
                            openWorldHint: true
                        ),
                        outputSchema: ToolSchemas.webSearchOutput
                    ),
                    Tool(
                        name: ToolSchemas.openToolName,
                        title: "Open URL",
                        description: """
                            Fetch one public URL and return its readable text. HTML is \
                            reduced to prose; JS-heavy pages may fall back to a rendering \
                            service. Only public http/https URLs are permitted.
                            """,
                        inputSchema: ToolSchemas.webOpenInput,
                        annotations: Tool.Annotations(
                            title: "Open URL",
                            readOnlyHint: true,
                            destructiveHint: false,
                            idempotentHint: true,
                            openWorldHint: true
                        ),
                        outputSchema: ToolSchemas.webOpenOutput
                    ),
                    Tool(
                        name: ToolSchemas.statusToolName,
                        title: "Search provider status",
                        description: """
                            Report per-provider configuration, circuit-breaker state, request \
                            counters and last failure. Diagnostic tool for operators; not \
                            normally needed for search.
                            """,
                        inputSchema: ToolSchemas.statusInput,
                        annotations: Tool.Annotations(
                            title: "Search provider status",
                            readOnlyHint: true,
                            destructiveHint: false,
                            idempotentHint: true,
                            openWorldHint: false
                        ),
                        outputSchema: ToolSchemas.statusOutput
                    ),
                ]
            )
        }

        await server.withMethodHandler(CallTool.self) { params in
            switch params.name {
            case ToolSchemas.searchToolName:
                return await handlers.webSearch(params.arguments)
            case ToolSchemas.openToolName:
                return await handlers.webOpen(params.arguments)
            case ToolSchemas.statusToolName:
                return await handlers.status(params.arguments)
            default:
                return ToolHandlers.error("Unknown tool: \(params.name)")
            }
        }

        log.debug("Registered MCP tools", metadata: ["count": "3"])
        return server
    }
}
