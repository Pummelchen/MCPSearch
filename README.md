# MCPSearch

**MCP Search Engine** — a Swift-native [Model Context Protocol](https://modelcontextprotocol.io)
server that gives local AI clients reliable public-web search and page fetching.

[![CI](https://github.com/Pummelchen/MCPSearch/actions/workflows/ci.yml/badge.svg)](https://github.com/Pummelchen/MCPSearch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Swift 6.3.3](https://img.shields.io/badge/Swift-6.3.3-orange.svg)

- **No mandatory paid infrastructure.** Every credential is optional; the server runs
  with zero API keys and reports exactly what is missing.
- **Grounded, not generated.** The optional answer layer may only use results that real
  providers already fetched, so it abstains rather than inventing facts or URLs.
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

## What is here

| Product | What it is |
| --- | --- |
| `SwiftWebSearchMCP` | The MCP server. Any MCP client launches this as a subprocess. |
| `mcps-mon` | A live terminal dashboard for providers and nodes — see [Monitor](https://github.com/Pummelchen/MCPSearch/wiki/Monitor). |
| `WebSearchCore` | The library both are built on: search, fetching, reliability, no MCP coupling. |

## Quick start

```bash
swift build -c release
```

Point your MCP client at the built server and give it at least one provider:

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
| `web_answer` | Search, then answer the question in prose using **only** those results, with citations |
| `web_search_status` | Per-provider diagnostics for operators |

`web_search` takes `query` (required), `max_results`, `recency`, `include_domains`,
`exclude_domains`, `locale`, `provider` and `mode` (`fast` / `balanced` / `thorough`).
Provider-specific options are deliberately not exposed.

### Answers that cannot invent their sources

`web_answer` runs an ordinary search first, then has a language model answer the question
from the results that were actually fetched. It is opt-in (`DEEPSEEK_API_KEY`) and is
**not** a search provider: nothing about it participates in provider selection, fusion or
ranking.

This matters because the model has **no web access of its own**. Asked about a current
price unaided, it will answer from a stale training snapshot — confidently and wrongly.
Given real results and told to use nothing else, the failure mode becomes abstention
instead of invention: it says the sources do not answer the question rather than filling
the gap. Every claim carries a `[n]` marker, markers that do not match a supplied result
are stripped and disclosed, and only cited sources are returned. If the search succeeds
but synthesis fails, the results are still returned.

```bash
export DEEPSEEK_API_KEY=sk-...   # optional; adds web_answer
```

## Providers

No account is required to run this. Four of the routes below need no vendor key at all:

| Route | Needs | Notes |
| --- | --- | --- |
| **Self-hosted SearXNG** | Docker only | Aggregates Google and Brave with no vendor key. See [Self-Hosting](https://github.com/Pummelchen/MCPSearch/wiki/Self-Hosting). |
| **Parallel Search MCP** | nothing | Free anonymous tier, measured at exactly 20 calls per window. Enable with `SEARCH_ENABLE_PARALLEL=true`. |
| **DuckDuckGo** | nothing | Free scraper. Throttles to about one query per 10s. Enable with `SEARCH_ENABLE_SCRAPERS=true`. |
| Tavily | `TAVILY_API_KEY` | Good on keyword queries; weaker on interpretive ones. 1 credit per search. |
| Brave Search | `BRAVE_SEARCH_API_KEY` | Broad independent index. |
| Mojeek | `MOJEEK_API_KEY` | Independent index, for diversity. Paid API. |
| Exa | `EXA_API_KEY` | Neural retrieval and highlights. |
| Open Web Search | `OPEN_WEB_SEARCH_URL` | Aggregation endpoint; contract unverified. |
| Startpage | none | Currently unusable: the site serves an Anubis proof-of-work challenge. |

Run at least two providers. A single provider is brittle in practice: measured on this
deployment, DuckDuckGo alone failed 41 of 50 queries once its throttle was reached,
while the same run with a second provider produced 241 results and one error.

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
| [Project Tracker](https://github.com/Pummelchen/MCPSearch/wiki/Project-Tracker) | Open issues, observations, decisions, known limitations |

## Development

```bash
swift build                    # debug
swift test                     # 368 tests, no network required
SEARCH_LIVE_TESTS=1 swift test --filter LiveProviderTests   # opt-in; calls real providers, also needs a key
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

The default suite is hermetic and needs no credentials. Live tests are an explicit
opt-in: they run only with `SEARCH_LIVE_TESTS=1` **and** a usable `TAVILY_API_KEY` (from the
environment or a git-ignored `config.env`). A key alone does not activate them, so a plain
`swift test` cannot spend credits by accident.

`docs/` holds the API research the adapters are built on, with every claim labelled
verified or unverified — see [docs/README.md](docs/README.md).

CI runs on `macos-26` (Swift 6.3): build, test, release build, smoke tests over both
transports, and a second test run with credentials present to prove the suite is
hermetic.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Pummelchen.
