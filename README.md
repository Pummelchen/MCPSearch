# MCPSearch

**MCP Search Engine** — a Swift-native [Model Context Protocol](https://modelcontextprotocol.io)
server that gives local AI clients reliable public-web search and page fetching.

[![CI](https://github.com/Pummelchen/MCPSearch/actions/workflows/ci.yml/badge.svg)](https://github.com/Pummelchen/MCPSearch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Swift 6.3.3](https://img.shields.io/badge/Swift-6.3.3-orange.svg)

- **No mandatory paid infrastructure.** Every credential is optional; the server runs
  with zero API keys and reports exactly what is missing.
- **API-first.** Supported JSON APIs and self-hosted SearXNG are preferred. HTML
  scrapers exist but are opt-in and rate limited.
- **One vendor outage never fails a search.** Providers fail over; only total failure
  is an error.
- **Rank fusion, not score comparison.** Provider relevance scores are not on a shared
  scale, so results are fused with weighted Reciprocal Rank Fusion.
- **Swift 6.3.3**, strict concurrency, no runtime dependency on Node or Python.
- **Client-compatible by construction.** Tool schemas satisfy the strictest consumer's
  validation, and both stdio and Streamable HTTP are supported — see
  [Compatibility](https://github.com/Pummelchen/MCPSearch/wiki/Compatibility).

## Quick start

```bash
swift build -c release
```

Point your MCP client at the built executable and give it at least one provider:

```bash
export TAVILY_API_KEY=tvly-...       # or
export BRAVE_SEARCH_API_KEY=...      # or
export SEARXNG_BASE_URL=https://searx.example.com
```

```json
{
  "mcpServers": {
    "web-search": {
      "command": "/absolute/path/to/SwiftWebSearchMCP",
      "env": { "TAVILY_API_KEY": "tvly-..." }
    }
  }
}
```

The server starts with no credentials and explains what is missing. Diagnostics go to
stderr; **stdout carries JSON-RPC framing only**.

For the remote connectors used by OpenAI's Responses API and Anthropic's Messages API,
which cannot reach a stdio server, serve Streamable HTTP instead:

```bash
SwiftWebSearchMCP --transport http --port 8080   # MCP at /mcp, plus GET /health
```

It binds `127.0.0.1` unless you pass `--host`, and it has no authentication, so put a
TLS-terminating reverse proxy in front before exposing it. Every local client uses the
default stdio mode.

## Tools

| Tool | Purpose |
| --- | --- |
| `web_search` | Search the public web; returns ranked, deduplicated, source-attributed results |
| `web_open` | Fetch one public URL and return readable text |
| `web_search_status` | Per-provider diagnostics for operators |

`web_search` takes `query` (required), `max_results`, `recency`, `include_domains`,
`exclude_domains`, `locale`, `provider` and `mode` (`fast` / `balanced` / `thorough`).
Provider-specific options are deliberately not exposed.

## Providers

| Provider | Kind | Credentials | Default |
| --- | --- | --- | --- |
| Tavily | AI-oriented index | `TAVILY_API_KEY` | preferred |
| Brave Search | independent index | `BRAVE_SEARCH_API_KEY` | preferred |
| Mojeek | independent index | `MOJEEK_API_KEY` | optional |
| Exa | neural retrieval | `EXA_API_KEY` | optional |
| SearXNG | self-hosted metasearch | `SEARXNG_BASE_URL` | preferred no-vendor path |
| Open Web Search | aggregator | `OPEN_WEB_SEARCH_URL` | optional |
| DuckDuckGo | HTML scraper | none | opt-in |
| Startpage | HTML scraper | none | opt-in |
| Parallel Search MCP | upstream MCP service | none | opt-in |

## Documentation

**[Read the wiki](https://github.com/Pummelchen/MCPSearch/wiki)** — the full reference
lives there.

| Page | Contents |
| --- | --- |
| [Installation & Setup](https://github.com/Pummelchen/MCPSearch/wiki/Installation) | Requirements, building, client configuration |
| [Compatibility](https://github.com/Pummelchen/MCPSearch/wiki/Compatibility) | OpenAI, Anthropic and Open Responses; transports and schema rules |
| [Self-Hosting](https://github.com/Pummelchen/MCPSearch/wiki/Self-Hosting) | The SearXNG cluster on the nodes |
| [Monitor](https://github.com/Pummelchen/MCPSearch/wiki/Monitor) | The live `mcps-mon` dashboard |
| [Tools Reference](https://github.com/Pummelchen/MCPSearch/wiki/Tools-Reference) | Every tool, argument and response field |
| [Architecture](https://github.com/Pummelchen/MCPSearch/wiki/Architecture) | Layering, request flow, fusion algorithm |
| [Providers](https://github.com/Pummelchen/MCPSearch/wiki/Providers) | Adapters and the API quirks they depend on |
| [Configuration](https://github.com/Pummelchen/MCPSearch/wiki/Configuration) | Every environment variable |
| [Reliability](https://github.com/Pummelchen/MCPSearch/wiki/Reliability) | Timeouts, retries, circuit breakers, caching |
| [Security](https://github.com/Pummelchen/MCPSearch/wiki/Security) | The SSRF boundary in `web_open` |
| [Testing](https://github.com/Pummelchen/MCPSearch/wiki/Testing) | Test suite and CI |
| [Troubleshooting](https://github.com/Pummelchen/MCPSearch/wiki/Troubleshooting) | Symptom → cause → fix |
| [Project Tracker](https://github.com/Pummelchen/MCPSearch/wiki/Project-Tracker) | Done, open work, known limitations |

## Development

```bash
swift build                    # debug
swift test                     # 250 tests, no network required
swift test --filter LiveProviderTests   # opt-in; calls real providers, needs a key
python3 scripts/mcp_smoke.py   # end-to-end stdio handshake
python3 scripts/mcp_smoke.py --http   # end-to-end Streamable HTTP session
```

There is also a live terminal dashboard for providers and nodes:

```bash
swift run mcps-mon            # node health, refreshes every 10s
swift run mcps-mon --probe    # also measure provider latency and errors
```

See the wiki for the [monitor](https://github.com/Pummelchen/MCPSearch/wiki/Monitor)
and [self-hosting](https://github.com/Pummelchen/MCPSearch/wiki/Self-Hosting).

The default suite is hermetic and needs no credentials. Live tests skip themselves
unless `TAVILY_API_KEY` is set in the environment or in a git-ignored `config.env`.

CI runs on `macos-26` (Swift 6.3): build, test, release build, smoke tests over both
transports, and a second test run with credentials present to prove the suite is
hermetic.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Pummelchen.
