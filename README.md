# MCPSearch

**MCP Search Engine** — a Swift-native MCP server that gives local AI clients
reliable public-web search and page fetching. It talks MCP over stdio, sits in front
of a set of search providers, and degrades gracefully when a provider fails.

The executable and Swift modules are named `SwiftWebSearchMCP` / `WebSearchCore`.

- **Swift 6.3.3**, strict concurrency, no runtime dependency on Node or Python.
- **No mandatory paid infrastructure.** Every credential is optional; the server
  starts with zero keys and explains what is missing.
- **API-first.** Supported JSON APIs and self-hosted SearXNG are preferred. HTML
  scrapers exist but are opt-in and disabled by default.
- **One vendor outage never fails a search.** Failures failover; only a total
  failure is an error.

## Quick start

```bash
swift build -c release
```

The binary is `$(swift build -c release --show-bin-path)/SwiftWebSearchMCP`.

Give it at least one provider, then point your MCP client at the executable.

```bash
# Cheapest useful start: one Tavily key (free tier available).
export TAVILY_API_KEY=tvly-...
# Or a broad independent index:
export BRAVE_SEARCH_API_KEY=...
# Or no vendor account at all, using your own SearXNG instance:
export SEARXNG_BASE_URL=https://searx.example.com
```

### Client configuration

Most MCP clients take the same shape. Example for a client that reads JSON config:

```json
{
  "mcpServers": {
    "web-search": {
      "command": "/absolute/path/to/SwiftWebSearchMCP",
      "env": {
        "TAVILY_API_KEY": "tvly-...",
        "BRAVE_SEARCH_API_KEY": "..."
      }
    }
  }
}
```

Diagnostics always go to **stderr**; stdout carries JSON-RPC framing only.

## Tools

### `web_search`

Search the public web and return ranked, deduplicated results with provenance.

| Argument | Type | Notes |
| --- | --- | --- |
| `query` | string | **required** |
| `max_results` | integer 1–20 | default 8 |
| `recency` | `any` \| `day` \| `week` \| `month` \| `year` | default `any` |
| `include_domains` | string[] (≤20) | |
| `exclude_domains` | string[] (≤20) | |
| `locale` | string | e.g. `en-US`, `de-DE` |
| `provider` | `auto` or a provider id | forces a single provider |
| `mode` | `fast` \| `balanced` \| `thorough` | default `balanced` |

Modes:

- `fast` — one provider, lowest latency.
- `balanced` — up to two independent providers, fused.
- `thorough` — up to three providers, fused, with aggregator coverage when the
  direct providers return a thin result set.

Results are fused with **weighted Reciprocal Rank Fusion**, not by comparing
provider scores: a Tavily score of 0.87 and an Exa score of 0.87 mean different
things. Each result lists the providers that returned it in `sources`, so
corroboration is visible.

### `web_open`

Fetch one public URL and return readable text.

| Argument | Type | Notes |
| --- | --- | --- |
| `url` | string | **required**, absolute `http`/`https` |
| `max_characters` | integer 1000–50000 | default 12000 |

Native `URLSession` + SwiftSoup extraction is tried first; JS-heavy or
extraction-resistant pages fall back to Jina Reader. Only public addresses are
fetchable — see [Security](#security).

### `web_search_status`

Per-provider configuration, circuit-breaker state, request counters and last
failure. Intended for operators; never exposes credentials.

## Providers

| Provider | Kind | Free path | Credentials | Default |
| --- | --- | --- | --- | --- |
| Tavily | AI-oriented index | monthly credits | `TAVILY_API_KEY` | preferred |
| Brave Search | independent index | monthly credits | `BRAVE_SEARCH_API_KEY` | preferred |
| Mojeek | independent index | trial / paid | `MOJEEK_API_KEY` | optional |
| Exa | neural retrieval | signup + monthly credits | `EXA_API_KEY` | optional |
| SearXNG | self-hosted metasearch | free, self-hosted | `SEARXNG_BASE_URL` | preferred no-vendor path |
| Open Web Search | aggregator | depends on endpoint | `OPEN_WEB_SEARCH_URL` | optional |
| DuckDuckGo | HTML scraper | no key | none | **opt-in** |
| Startpage | HTML scraper | no key | none | **opt-in** |
| Parallel Search MCP | upstream MCP service | anonymous endpoint | none | **opt-in** |

`jina` is a fetch/extraction provider, not a search provider.

### Provider notes worth knowing

- **SearXNG requires JSON output to be enabled.** The shipped `settings.yml`
  enables only `html`, so `format=json` returns **403**. Add `json` to
  `search.formats` in your instance. This is reported as a configuration problem,
  not a transient outage, so it does not trip the circuit breaker.
- **Mojeek authenticates with an `api_key` query parameter**, not a header, and an
  invalid key returns **HTTP 200** with an error string in `response.status`.
- **Brave signals an invalid token with `422` plus `error.code`**, not `401`.
- **Exa answers a missing key with `402`** and an invalid one with `401`.
- **Tavily has no `days` parameter**; unknown fields are rejected.
- **Aggregators are discounted once during fusion.** SearXNG, Open Web Search and
  Parallel Search MCP have their fusion weight multiplied by `aggregatorWeight`
  (0.7) exactly once, because they usually resell another engine's index rather than
  owning one.
- **Known limitation — same-index double counting is not yet solved.** The discount
  reduces an aggregator's vote but does not *merge* provenance. If Brave returns a
  URL and a SearXNG instance that queried Brave returns the same URL, that URL still
  receives a reduced second vote rather than collapsing to a single independent
  signal. Doing this properly requires per-result upstream-engine attribution, which
  no current adapter carries. This is tracked as open work.

### Scrapers are opt-in and experimental

`DuckDuckGo` and `Startpage` rely on undocumented HTML that changes without notice.

- Set `SEARCH_ENABLE_SCRAPERS=true` to enable them.
- DuckDuckGo answers automated requests with **HTTP 202** and an "anomaly" bot
  challenge, not a 403.
- Startpage serves an **Anubis proof-of-work challenge** that a plain HTTP client
  cannot solve, so in practice it will usually report itself unavailable. It is
  kept behind the same switch because it draws on a different index when it works.
- Both are rate limited hard, down-weighted during fusion, and fail cleanly rather
  than returning malformed results.

## Configuration

Environment variables, optionally supplemented by a `KEY=VALUE` file. Environment
wins over the file. See `example.env` for a complete list.

```bash
TAVILY_API_KEY=
BRAVE_SEARCH_API_KEY=
MOJEEK_API_KEY=
EXA_API_KEY=
JINA_API_KEY=
SEARXNG_BASE_URL=
OPEN_WEB_SEARCH_URL=
PARALLEL_MCP_URL=https://search.parallel.ai/mcp
SEARCH_PROVIDER_ORDER=tavily,brave,mojeek,exa,searxng,open_web_search,duckduckgo,startpage,parallel
SEARCH_DISABLED_PROVIDERS=
SEARCH_MAX_RESULTS=8
SEARCH_FAST_TIMEOUT_MS=12000
SEARCH_BALANCED_TIMEOUT_MS=15000
SEARCH_THOROUGH_TIMEOUT_MS=20000
SEARCH_ENABLE_SCRAPERS=false
SEARCH_ENABLE_PARALLEL=false
SEARCH_ENABLE_JINA_READER=true
SEARCH_CACHE_TTL_SECONDS=120
SEARCH_CONNECT_TIMEOUT_MS=3000
SEARCH_REQUEST_TIMEOUT_MS=10000
SEARCH_MAX_RETRIES=2
SEARCH_USER_AGENT="SwiftWebSearchMCP/1.0 (+https://example.invalid/project)"
SEARCH_ALLOW_PRIVATE_NETWORK=false
SEARCH_LOG_LEVEL=info
SEARCH_LOG_QUERIES=false
```

`SEARCH_CONFIG_FILE` selects an explicit config file. `SEARCH_USER_AGENT` sets the
outbound `User-Agent`; the default identifies the project honestly rather than
impersonating a browser. `SEARCH_ALLOW_PRIVATE_NETWORK` is documented under
[Security](#security).

Set `SEARCH_CONFIG_FILE` to load a file explicitly. Secrets are read from the
environment and are never written to disk or logged.

## Reliability behaviour

- **Timeouts** are per-mode wall-clock budgets (12s / 15s / 20s). A slow provider is
  cut off; providers that already answered keep their results.
- **Retries** apply only to idempotent requests and only to `408, 425, 429, 500,
  502, 503, 504`, with exponential backoff and jitter. `Retry-After` is honoured,
  bounded so a hostile server cannot stall a search. `POST`-based searches are not
  retried, because a retry costs credits and may duplicate an effect.
- **Circuit breakers** open after 3 consecutive *transient* failures and cooldown
  for 30s, then allow one probe. Authentication and configuration errors never trip
  a breaker — waiting cannot fix a bad key.
- **Rate limiting** treats a provider's published limit as a ceiling, not a quota to
  spend. Scrapers are throttled hardest.
- **Caching** is in-memory, keyed on query, filters, mode and provider set. Only
  successful responses are cached; failures and empty results are not.

## Security

`web_open` accepts a URL from a model, so it is an SSRF boundary. Three layers:

1. **Lexical** — scheme allow-list (`http`/`https` only), credential rejection,
   blocked internal names (`localhost`, `*.internal`, `metadata.google.internal`),
   and strict IP-literal parsing that rejects obfuscated forms such as `2130706433`
   and `0x7f000001`.
2. **Resolution** — the hostname is resolved and **every** returned address is
   classified, so a public-looking name pointing at `10.0.0.5` is refused.
3. **Redirects** — automatic redirect following is disabled; each hop is re-validated
   before it is requested.

Blocked: loopback, RFC 1918 private ranges, link-local, multicast, broadcast,
carrier-grade NAT, reserved ranges, cloud metadata addresses, and IPv6
unique-local addresses.

`SEARCH_ALLOW_PRIVATE_NETWORK=true` lifts these restrictions for a deliberately
internal deployment. Only use it if you intend models to reach internal hosts.

## Architecture

```
MCP layer (Sources/SwiftWebSearchMCP)
  main.swift, MCPServer.swift, ToolHandlers.swift, ToolSchemas.swift
      │  knows MCP; knows nothing about any vendor
      ▼
WebSearchCore (Sources/WebSearchCore)
  Search/    orchestrator, registry, fusion, cache, breakers, health
  Providers/ one adapter per vendor, all behind SearchProvider
  Fetch/     URL policy, HTTP fetcher, SwiftSoup extraction, Jina fallback
  Support/   HTTP client, retry policy, config, logging, JSON coding
```

The MCP layer knows almost nothing about any search vendor, and the providers know
almost nothing about MCP. That separation is what makes provider churn cheap: adding
or removing a vendor touches one adapter and the factory.

Adding a provider means implementing `SearchProvider` (four members plus `search`)
and registering it in `SearchPipelineFactory`.

## Testing

```bash
swift test
```

178 tests. No test contacts the public internet, and the end-to-end tests run the
server with a scrubbed environment, so they are unaffected by provider keys exported
in your shell:

- **Unit** — URL canonicalization, configuration parsing, RRF fusion, circuit-breaker
  transitions, rate limiting, caching, HTML extraction, SSRF policy.
- **Provider contract** — the adapters for Tavily, Brave, Mojeek, Exa, SearXNG and
  DuckDuckGo are driven against a scripted transport and must satisfy the same
  contract: normalized results, `401`/`403` → authentication, `429` → rate limited,
  `5xx` → transient, malformed body → clean failure, and no credential leakage.
  Startpage is covered only for configuration and parsing; Open Web Search, Parallel
  Search MCP and Jina Search have no adapter tests yet.
- **Transport** — retry, `Retry-After`, idempotency, size limits and cancellation are
  verified against a real loopback HTTP server, not a mock.
- **End-to-end** — the built executable is started as a subprocess and driven through
  a real MCP stdio handshake: `initialize`, `tools/list`, tool calls, error reporting,
  and a check that logging never contaminates stdout.

`docs/provider-api-notes.md` records the API-contract research behind the adapters,
with uncertain points explicitly marked as unverified.

## Limitations

- `web_open` does not execute JavaScript. JS-heavy pages depend on the Jina Reader
  fallback.
- Startpage cannot work through a plain HTTP client (Anubis proof-of-work) and will
  normally report itself unavailable.
- The Parallel Search MCP adapter speaks JSON-RPC over Streamable HTTP directly and
  its upstream tool contract is third-party and unverified; it is disabled by default.
- "Open Web Search" has no authoritative published specification, so that adapter is
  a configurable, defensively-parsed aggregator and is only active when
  `OPEN_WEB_SEARCH_URL` is set.
- Google Custom Search and Bing Search APIs are deliberately not supported: Google's
  JSON API is closed to new customers and retires in 2027, and Bing's was retired in
  August 2025.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Pummelchen.
