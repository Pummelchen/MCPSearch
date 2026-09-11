import Foundation

/// Parallel Search MCP — optional upstream **MCP client** adapter.
///
/// Using this makes the process both an MCP server (to its local client) and an MCP
/// client (to Parallel). It is off by default behind `SEARCH_ENABLE_PARALLEL=true`
/// and is treated as an aggregator, so its results never count as independent
/// evidence alongside another aggregator.
///
/// Default endpoint: `https://search.parallel.ai/mcp`, anonymous access.
///
/// - Important: This adapter speaks JSON-RPC 2.0 over the MCP Streamable HTTP
///   transport directly rather than through a full MCP client lifecycle. That keeps
///   an optional, unverified third-party integration from complicating the core
///   server: there is no long-lived session, no SSE stream to manage, and a failed
///   handshake degrades to a provider failure like any other. The tool name and result
///   shape are discovered defensively because the upstream contract is not something
///   this project controls.
public actor ParallelMCPProvider: SearchProvider {
    public nonisolated let id: ProviderID = .parallel
    public nonisolated let capabilities = ProviderCapabilities(
        supportsIncludeDomains: false,
        supportsExcludeDomains: false,
        supportsRecency: false,
        supportsLocale: false,
        supportsAnswer: false,
        supportsInlineContent: true,
        supportsPagination: false
    )
    public nonisolated let fusionWeight: Double = 0.8

    /// Candidate tool names, most likely first. The upstream server owns this name, so
    /// it is discovered from `tools/list` when possible. `web_search` is the name the
    /// live Parallel server exposes.
    public static let preferredToolNames = ["web_search", "search", "parallel_search"]

    private let endpoint: URL
    private let http: any HTTPClient
    private let configuration: AppConfiguration
    private let enabled: Bool
    private let log: Log

    private var sessionID: String?
    private var resolvedToolName: String?
    private var resolvedToolSupportsMaxResults = false
    private var requestCounter = 0
    /// Stable identifier for free-tier rate-limit accounting, generated once.
    private let sessionIdentifier = UUID().uuidString

    public init(
        endpoint: URL,
        http: any HTTPClient,
        configuration: AppConfiguration,
        enabled: Bool,
        log: Log = .disabled
    ) {
        self.endpoint = endpoint
        self.http = http
        self.configuration = configuration
        self.enabled = enabled
        self.log = log
    }

    public nonisolated var isConfigured: Bool { enabled }

    public func search(_ request: SearchRequest) async throws -> ProviderSearchResponse {
        guard enabled else {
            throw SearchError.notConfigured(.parallel)
        }

        let started = DispatchTime.now().uptimeNanoseconds

        let result = try await callSearchTool(request)

        var seen: Set<String> = []
        var results: [SearchResult] = []
        for (index, item) in result.items.enumerated() {
            guard let normalized = ResultNormalizer.make(
                provider: .parallel,
                rank: index + 1,
                title: item.title,
                urlString: item.url,
                snippet: item.snippet,
                publishedAt: item.publishedAt.flatMap(JSONCoding.date(from:)),
                content: item.content,
                request: request,
                seenKeys: &seen
            ) else { continue }
            results.append(normalized)
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        log.debug(
            "Parallel MCP search complete",
            metadata: ["results": "\(results.count)", "latency_ms": "\(elapsed)"]
        )

        return ProviderSearchResponse(
            provider: .parallel,
            results: results,
            upstreamEngines: ["parallel"],
            latencyMilliseconds: elapsed
        )
    }

    // MARK: - MCP plumbing

    /// One complete request/response exchange with the upstream MCP server.
    private func callSearchTool(_ request: SearchRequest) async throws -> ToolOutput {
        try await ensureInitialized()

        let toolName = resolvedToolName ?? ParallelMCPProvider.preferredToolNames[0]

        // The upstream `web_search` tool requires both `objective` (a natural-language
        // description) and `search_queries` (concise keyword queries). A result-count
        // parameter does not exist on this tool: result volume is controlled by the
        // connect-time configuration, so requesting more here would be ignored.
        var arguments: [String: Any] = [
            "objective": request.normalizedQuery,
            "search_queries": [request.normalizedQuery],
        ]
        // The free tier meters requests by `session_id`, so reusing one stable value
        // keeps this server's usage attributable and avoids per-IP accounting.
        arguments["session_id"] = sessionIdentifier
        arguments["model_name"] = "SwiftWebSearchMCP"

        // Retained for servers that accept a count argument; ignored otherwise.
        if resolvedToolSupportsMaxResults {
            arguments["max_results"] = request.providerResultBudget
        }

        let response = try await send(
            JSONRPCRequest(
                id: nextRequestID(),
                method: "tools/call",
                params: [
                    "name": toolName,
                    "arguments": arguments,
                ]
            )
        )

        if let error = response.error {
            // `-32602` / `-32601` mean the tool name or arguments were wrong.
            if error.code == -32601 {
                resolvedToolName = nil
                throw SearchError.unsupportedRequest(
                    .parallel,
                    "the upstream server does not expose a search tool"
                )
            }
            throw SearchError.providerUnavailable(.parallel)
        }

        guard let result = response.result else {
            throw SearchError.malformedResponse(.parallel)
        }

        return try ToolOutput.parse(result)
    }

    /// Perform the MCP initialize handshake once, and discover the search tool name.
    private func ensureInitialized() async throws {
        if sessionID != nil { return }

        let initialize = JSONRPCRequest(
            id: nextRequestID(),
            method: "initialize",
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "SwiftWebSearchMCP", "version": "1.0.0"],
            ]
        )

        let response = try await send(initialize)
        if let error = response.error {
            log.debug(
                "Parallel MCP initialize failed",
                metadata: ["code": "\(error.code)"]
            )
            throw SearchError.providerUnavailable(.parallel)
        }

        // An empty result is still a completed handshake.
        _ = response.result

        // The spec requires `notifications/initialized` after a successful
        // initialize; the live server answers it with 202 and expects it before
        // tool calls.
        await sendInitializedNotification()

        // Best-effort tool discovery; the preferred names remain the fallback.
        await discoverToolName()

        // A server without a session is legal: Streamable HTTP sessions are optional.
        if sessionID == nil {
            sessionID = ""
        }
    }

    /// Send the `notifications/initialized` notification.
    ///
    /// Notifications carry no `id` and the server replies `202 Accepted` with an
    /// empty body, so the response is intentionally discarded.
    private func sendInitializedNotification() async {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ]
        if let sessionID, !sessionID.isEmpty {
            headers["MCP-Session-Id"] = sessionID
        }
        let body: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        _ = try? await http.send(
            HTTPRequest.post(endpoint, headers: headers, body: data, label: "parallel.mcp"),
            maxBytes: 64 * 1024
        )
    }

    private func discoverToolName() async {
        let response = try? await send(
            JSONRPCRequest(id: nextRequestID(), method: "tools/list", params: [:])
        )
        guard let result = response?.result,
              let tools = result["tools"] as? [[String: Any]]
        else { return }

        let names = tools.compactMap { $0["name"] as? String }
        for preferred in ParallelMCPProvider.preferredToolNames
        where names.contains(preferred) {
            resolvedToolName = preferred
            break
        }
        // Fall back to any tool whose name mentions search.
        if resolvedToolName == nil,
           let searchTool = names.first(where: { $0.lowercased().contains("search") }) {
            resolvedToolName = searchTool
        }

        // Only send `max_results` if the announced input schema actually declares it.
        if let tool = tools.first(where: { ($0["name"] as? String) == resolvedToolName }),
           let schema = tool["inputSchema"] as? [String: Any],
           let properties = schema["properties"] as? [String: Any] {
            resolvedToolSupportsMaxResults = properties["max_results"] != nil
        }
    }

    /// Send one JSON-RPC message over the Streamable HTTP transport.
    private func send(_ request: JSONRPCRequest) async throws -> JSONRPCResponse {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ]
        if let sessionID, !sessionID.isEmpty {
            headers["MCP-Session-Id"] = sessionID
        }

        let body = try JSONSerialization.data(withJSONObject: request.jsonObject)

        let response = try await http.send(
            HTTPRequest.post(endpoint, headers: headers, body: body, label: "parallel.mcp"),
            maxBytes: configuration.maxSearchResponseBytes
        )

        if response.statusCode == 401 || response.statusCode == 403 {
            throw SearchError.authenticationRequired(.parallel)
        }
        if response.statusCode == 429 {
            throw SearchError.rateLimited(.parallel, retryAfter: nil)
        }
        guard response.isSuccess else {
            throw SearchError.providerUnavailable(.parallel)
        }

        // Capture the session id the server assigned, if any.
        if let assigned = response.header("MCP-Session-Id"), !assigned.isEmpty {
            sessionID = assigned
        }

        let text = response.text()
        let jsonText = ParallelMCPProvider.extractJSON(from: text)

        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SearchError.malformedResponse(.parallel)
        }

        return JSONRPCResponse(json: object)
    }

    private func nextRequestID() -> Int {
        requestCounter += 1
        return requestCounter
    }

    /// The transport may answer with a bare JSON body or with an SSE stream. Extract
    /// the last complete JSON-RPC object from either.
    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return trimmed }

        // SSE framing: `data: {...}` lines.
        var candidates: [String] = []
        for line in trimmed.split(separator: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard stripped.hasPrefix("data:") else { continue }
            let payload = stripped.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.hasPrefix("{") { candidates.append(payload) }
        }
        return candidates.last ?? trimmed
    }

    // MARK: - Wire types

    /// Not `Sendable`: the parameter dictionary holds `Any` JSON values and the
    /// request never leaves the actor.
    struct JSONRPCRequest {
        let id: Int
        let method: String
        let params: [String: Any]

        var jsonObject: [String: Any] {
            [
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params,
            ]
        }
    }

    struct JSONRPCResponse {
        let json: [String: Any]

        var result: [String: Any]? { json["result"] as? [String: Any] }

        var error: RPCError? {
            guard let raw = json["error"] as? [String: Any] else { return nil }
            return RPCError(
                code: raw["code"] as? Int ?? 0,
                message: raw["message"] as? String ?? ""
            )
        }

        struct RPCError: Sendable {
            let code: Int
            let message: String
        }
    }

    /// Normalized search output extracted from an MCP tool result.
    struct ToolOutput: Sendable {
        struct Item: Sendable {
            let title: String?
            let url: String?
            let snippet: String?
            let content: String?
            let publishedAt: String?
        }

        let items: [Item]

        /// MCP tool results carry `content: [{type:"text", text:"..."}]`, and the text
        /// is usually a JSON document listing the results.
        static func parse(_ result: [String: Any]) throws -> ToolOutput {
            // Structured content is preferred when the server provides it.
            if let structured = result["structuredContent"] as? [String: Any],
               let items = itemsFromJSON(structured)
            {
                return ToolOutput(items: items)
            }

            guard let content = result["content"] as? [[String: Any]] else {
                throw SearchError.malformedResponse(.parallel)
            }

            for block in content {
                guard let text = block["text"] as? String else { continue }
                guard let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                else { continue }

                if let dictionary = object as? [String: Any],
                   let items = itemsFromJSON(dictionary)
                {
                    return ToolOutput(items: items)
                }
                if let array = object as? [[String: Any]] {
                    return ToolOutput(items: array.compactMap(parseItem))
                }
            }
            throw SearchError.malformedResponse(.parallel)
        }

        static func itemsFromJSON(_ object: [String: Any]) -> [Item]? {
            for key in ["results", "data", "items", "searchResults"] {
                if let array = object[key] as? [[String: Any]] {
                    return array.compactMap(parseItem)
                }
            }
            return nil
        }

        static func parseItem(_ raw: [String: Any]) -> Item? {
            let url = (raw["url"] as? String) ?? (raw["link"] as? String)
            guard let url, !url.isEmpty else { return nil }

            // Parallel returns excerpts as an array of markdown chunks; only `url` and
            // `excerpts` are guaranteed present.
            let excerpts = (raw["excerpts"] as? [String]) ?? []
            let snippet =
                (raw["snippet"] as? String)
                ?? (raw["description"] as? String)
                ?? excerpts.first(where: { !$0.isEmpty })
                ?? (raw["excerpt"] as? String)

            // Full content is the joined excerpts when the server returns no field.
            let content =
                (raw["content"] as? String)
                ?? (raw["text"] as? String)
                ?? (excerpts.isEmpty ? nil : excerpts.joined(separator: "\n\n"))

            return Item(
                title: raw["title"] as? String,
                url: url,
                snippet: snippet,
                content: content,
                publishedAt: (raw["publish_date"] as? String)
                    ?? (raw["published_at"] as? String)
                    ?? (raw["publishedDate"] as? String)
            )
        }
    }
}
