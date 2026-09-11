# MCPSearch

**MCP Search Engine** — a Swift-native [Model Context Protocol](https://modelcontextprotocol.io)
server that gives local AI clients reliable public-web search and page fetching.

[![CI](https://github.com/Pummelchen/MCPSearch/actions/workflows/ci.yml/badge.svg)](https://github.com/Pummelchen/MCPSearch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Swift 6.3.3](https://img.shields.io/badge/Swift-6.3.3-orange.svg)

- **No mandatory paid infrastructure.** Every credential is optional; the server runs
  with zero API keys and reports exactly what is missing.
- **API-first.** Supported JSON APIs and self-hosted SearXNG are preferred. HTML
  scrapers exist but are opt-in, rate limited and down-weighted.
- **One vendor outage never fails a search.** Providers fail over; only total failure
  is an error.
- **Rank fusion, not score comparison.** Provider relevance scores are not on a shared
  scale, so results are fused with weighted Reciprocal Rank Fusion.
- **Swift 6.3.3**, strict concurrency, no runtime dependency on Node or Python.

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
swift build          # debug
swift test           # 179 tests, no network required
python3 scripts/mcp_smoke.py   # end-to-end stdio handshake
```

CI runs on `macos-26` (Swift 6.3): build, test, release build, stdio smoke test, and a
second test run with credentials present to prove the suite is hermetic.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Pummelchen.
