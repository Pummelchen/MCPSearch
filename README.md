# MCPSearch

**MCP Search Engine** — a Swift-native [Model Context Protocol](https://modelcontextprotocol.io)
server that gives local AI clients reliable public-web search and page fetching.

[![CI](https://github.com/Pummelchen/MCPSearch/actions/workflows/ci.yml/badge.svg)](https://github.com/Pummelchen/MCPSearch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Swift 6.4](https://img.shields.io/badge/Swift-6.4-orange.svg)
[![Stars](https://img.shields.io/github/stars/Pummelchen/MCPSearch?style=flat-square&logo=github&label=Stars&color=e3b341)](https://github.com/Pummelchen/MCPSearch/stargazers)
[![Views (14d)](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/Pummelchen/MCPSearch/main/.github/traffic.json)](https://github.com/Pummelchen/MCPSearch)
[![Last Commit](https://img.shields.io/github/last-commit/Pummelchen/MCPSearch?style=flat-square&logo=git&label=Last%20Commit&color=2ea44f)](https://github.com/Pummelchen/MCPSearch/commits/main)
[![Contact](https://img.shields.io/badge/Contact-0xa0b1%40gmail.com-blue?style=flat-square&logo=gmail&logoColor=white)](mailto:0xa0b1@gmail.com)

- **No mandatory paid infrastructure.** Every credential is optional; the server runs
  with zero API keys and reports exactly what is missing.
- **Grounded, not generated.** The optional answer layer may only use results that real
  providers already fetched, so it abstains rather than inventing facts or URLs.
- **Every provider on.** All nine routes are enabled by default, including the ones that
  need no key. A provider without a credential reports `not_configured` and the others still
  answer; HTML scrapers are rate limited and never fail a search on their own.
- **One vendor outage never fails a search.** Providers fail over; only total failure
  is an error.
- **Rank fusion, not score comparison.** Provider relevance scores are not on a shared
  scale, so results are fused with weighted Reciprocal Rank Fusion.
- **Swift 6.4**, strict concurrency, no runtime dependency on Node or Python.
- **Client-compatible by construction.** Tool schemas satisfy the strictest consumer's
  validation, and both stdio and Streamable HTTP are supported. No vendor client has been
  connected to this server and that round trip is not planned, so the claim is bounded to
  the documented rules, the schema linter and the protocol tests that run locally — see
  [Compatibility](https://github.com/Pummelchen/MCPSearch/wiki/Compatibility).

## What is here

| Product | What it is |
| --- | --- |
| `SwiftWebSearchMCP` | The MCP server. Any MCP client launches this as a subprocess. |
| `mcps-mon` | A live terminal dashboard for providers and nodes — see [Monitor](https://github.com/Pummelchen/MCPSearch/wiki/Monitor). |
| `WebSearchCore` | The library both are built on: search, fetching, reliability, no MCP coupling. |

## Quick start

**Install it, with a local SearXNG, in one command:**

```bash
deploy/install.sh              # builds from source
deploy/install.sh --from-release   # or installs the published arm64 binary
```

The installer treats a working local [SearXNG](https://docs.searxng.org) as **mandatory**: it
installs one if there is none (container if a Docker daemon answers, otherwise natively under
`launchd`), then proves it answers a real query before it will install anything. That matters
because every vendor provider is optional and metered, so a local SearXNG is the only search
that can be guaranteed to work on the machine running the server — with no account and no key.
If that proof fails the installer exits non-zero rather than leaving you a server that cannot
search. `deploy/install.sh --verify-only` re-checks an existing install and changes nothing.

Or do it by hand — download a prebuilt macOS binary for Apple silicon (M1 and later) from the
[latest release](https://github.com/Pummelchen/MCPSearch/releases/latest), or build from source:

```bash
swift build -c release
```

It runs with **no credentials at all**: DuckDuckGo needs none, and a local SearXNG needs none.
Add keys to switch on more providers — this is optional, and every provider is already on:

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

The server answers only the `Host` names it knows — that is what stops a browser page on
another site from reaching it — so when a proxy forwards a public name that is not the
address the server binds, declare it (repeatable):

```bash
SwiftWebSearchMCP --transport http --host 0.0.0.0 \
  --http-allowed-host search.example.com
```

A wildcard bind already accepts the machine's own interface addresses. An undeclared name is
refused with `421 Misdirected Request` before any MCP handling.

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

### Third-party rendering for `web_open`

`web_open` fetches a URL directly first. If the page needs JavaScript, or its native
extraction is too thin, it falls back to **Jina Reader** (`r.jina.ai`): the full target URL
— including any credentials, token or signed query parameter in it — is sent to that
third-party service, which fetches the page on this server's behalf. The fallback is on by
default; `SEARCH_ENABLE_JINA_READER=false` disables it and `JINA_API_KEY` raises its rate
limit. The SSRF policy runs before the fallback, so a URL it blocks is never laundered
through the reader.

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

No account is required to run this. **Every route below is enabled by default.** Five need no
vendor key at all: two still need an endpoint you point them at (a SearXNG instance, or an Open
Web Search aggregator), two are scrapers that need nothing, and Parallel needs only its flag.

| Route | Needs | Notes |
| --- | --- | --- |
| **Self-hosted SearXNG** | Docker, plus `SEARXNG_BASE_URL` | Aggregates Google and Brave with no vendor key. See [Self-Hosting](https://github.com/Pummelchen/MCPSearch/wiki/Self-Hosting). |
| **Parallel Search MCP** | nothing (on by default) | Free anonymous tier, measured at exactly 20 calls per window. `SEARCH_ENABLE_PARALLEL=false` turns it off. |
| **DuckDuckGo** | nothing (on by default) | Free scraper. Throttles to about one query per 10s. `SEARCH_ENABLE_SCRAPERS=false` turns it off. |
| Tavily | `TAVILY_API_KEY` | Good on keyword queries; weaker on interpretive ones. 1 credit per search. |
| Brave Search | `BRAVE_SEARCH_API_KEY` | Broad independent index. |
| Mojeek | `MOJEEK_API_KEY` | Independent index, for diversity. Paid API. |
| Exa | `EXA_API_KEY` | Neural retrieval and highlights. |
| Open Web Search | `OPEN_WEB_SEARCH_URL` | No vendor key: an aggregation endpoint you supply. Contract unverified. |
| Startpage | nothing (on by default) | Usually unusable: the site serves an Anubis proof-of-work challenge. Enabled anyway, because it costs nothing to try and the day it answers is the day we find out. |

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
| [Project Tracker](https://github.com/Pummelchen/MCPSearch/wiki/Project-Tracker) | Open work, and the limitations accepted rather than fixed |

See [CHANGELOG.md](CHANGELOG.md) for what changed in each release.

## Development

```bash
swift build                    # debug
swift test                     # 593 tests, no network required
SEARCH_LIVE_TESTS=1 swift test --filter LiveProviderTests   # opt-in; calls real providers, also needs a key
python3 scripts/mcp_smoke.py   # end-to-end stdio handshake
python3 scripts/mcp_smoke.py --http   # end-to-end Streamable HTTP session
python3 scripts/monitor_tty_smoke.py  # drives the dashboard through a pseudo-terminal
python3 scripts/dual_client_contract.py  # one stub, both executables, compared
tools/check-version.sh         # VERSION, the generated mirror and the changelog agree
```

`monitor_tty_smoke.py` is how the dashboard's key handling is tested without a desktop:
it allocates a pseudo-terminal (a kernel object, so no window opens), types `p`/`r`/`e`/`c`/`q`
into a live `mcps-mon`, and asserts on the escape sequences and frames that come back.

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

CI runs on the `xcode-27` image (Swift 6.4). One job builds with warnings as errors, runs the
suite with coverage against an 80 % floor on `Sources/`, builds release, drives both transports
and the dashboard's pseudo-terminal path, and re-runs the suite with placeholder credentials to
prove it is hermetic. A second job holds the static gates: `swift-format`, SwiftLint, `ruff`,
`pyright` (strict), `shellcheck`, `semgrep`, a full-history `gitleaks` scan, and `osv-scanner`
over the locked dependency graph. A third runs `CodeQL` over the Swift sources on the same image,
building them by hand so the analysis is of the toolchain this project actually uses.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 André Borchert.

The binary links third-party packages with their own terms. Their licences, and the attribution
notices that Apache-2.0 requires a distributed work to carry, are collected in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md); a CI gate keeps that inventory in step with
`Package.resolved`.

## Contact

Questions, bug reports and suggestions are always welcome. You can contact André Borchert by email at [0xa0b1@gmail.com](mailto:0xa0b1@gmail.com).
