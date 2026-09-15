# AUDIT — scope and inventory (Phase A, §2)

Repository: **MCPSearch**, a Swift-native MCP web-search server. Branch
`audit/2026-09-13` from `main` @ `f3dd8d9`.

Method: `git ls-files` (69 `.swift`, 4 `.py`, 3 `.yml`, 1 `.sh`, 1 `.resolved`,
1 `.env` template, 5 `.md`, `LICENSE`), `Package.swift`, `Package.resolved`,
`.github/workflows/ci.yml`, `deploy/`, and a static read of each entry point. **No build
system other than SwiftPM exists in the tree.**

> **Scope correction to the brief.** The brief describes "a monorepo with 20+ increasingly
> interdependent projects". This repository is **one Swift package with five targets**, four
> Python scripts, one shell script and three YAML configs. There are no submodules, no other
> package manifests, and no C, C#, Go or Rust. The monorepo-scale instructions therefore
> reduce to *intra-package* boundaries plus the script/deploy/CI surface; they are applied at
> that scale rather than skipped. Recorded so the difference is not mistaken for missing
> work.

---

## 1. Buildable units

| # | Unit | Language | Build system | Kind | Entry point | Host class | LOC |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `WebSearchCore` | Swift 6 | SwiftPM | library (target) | — (no `main`) | **Mac only** | 10 065 (42 files) |
| 2 | `SwiftWebSearchMCP` | Swift 6 | SwiftPM | executable | `Sources/SwiftWebSearchMCP/main.swift` → stdio (default) or `--transport http` | **Mac only** | 2 077 (5 files) |
| 3 | `MCPSMonitor` (product `mcps-mon`) | Swift 6 | SwiftPM | executable | `Sources/MCPSMonitor/main.swift` → full-screen TUI or plain frames | **Mac only** | 581 (1 file) |
| 4 | `WebSearchCoreTests` | Swift 6 | SwiftPM | test target (16 files) | — | **Mac only** | 9 240 total with #5 |
| 5 | `MCPSMonitorTests` | Swift 6 | SwiftPM | test target (1 file) | — | **Mac only** | (above) |
| 6 | `scripts/mcp_smoke.py` | Python 3.14 | none (stdlib only) | operator/CI tool | CLI | any | 488 |
| 7 | `scripts/monitor_tty_smoke.py` | Python 3.14 | none | operator/CI tool | CLI | any (POSIX PTY) | 404 |
| 8 | `scripts/soak.py` | Python 3.14 | none | operator tool | CLI | any | ~400 |
| 9 | `scripts/searxng_health.py` | Python 3.14 | none | operator tool | CLI | any | 131 |
| 10 | `deploy/provision-node.sh` | Bash 3.2 | none | provisioning script | CLI | **Mac only** (targets the Mac fleet) | 248 → audited revision |
| 11 | `deploy/docker-compose.yml` + `deploy/searxng/settings.yml` | YAML | Docker Compose | deployment | `docker compose up` | any (arm64 image pinned) | 30 + 44 |
| 12 | `.github/workflows/ci.yml` | YAML | GitHub Actions | CI | push/PR to `main` | macOS runner (`macos-26`) | ~120 |

Everything Swift requires Apple's toolchain (XCTest + Darwin sockets + the MCP SDK's
`macOS 13` floor), so **no Swift work may be moved to Linux**. Python and shell are portable;
the PTY harness needs a POSIX pseudoterminal, which macOS and Linux both provide.

---

## 2. Dependency graph (build-time)

```
SwiftWebSearchMCP ──▶ WebSearchCore ──▶ SwiftSoup
        │
        └──▶ MCP (swift-sdk 0.12.1, exact)
        └──▶ NIOCore/NIOPosix/NIOHTTP1 (swift-nio, from: 2.65.0)

MCPSMonitor ───────▶ WebSearchCore
WebSearchCoreTests ─▶ WebSearchCore
MCPSMonitorTests ───▶ MCPSMonitor (executable-as-dependency)
```

`Package.resolved` pins (all exact at resolution time):

| Package | Version | Pin style in `Package.swift` |
| --- | --- | --- |
| `swift-sdk` (MCP) | 0.12.1 | `exact` |
| `SwiftSoup` | 2.13.5 | `exact` |
| `swift-nio` | 2.102.0 | `from: 2.65.0` |
| `swift-atomics` | 1.3.1 | transitive |
| `swift-collections` | 1.6.0 | transitive |
| `swift-log` | 1.15.1 | transitive |
| `swift-system` | 1.8.1 | transitive |
| `eventsource` | 1.5.1 | transitive |

Two dependencies are declared `exact`; `swift-nio` is a version **range**, so it can float
within `2.x` — captured as a finding candidate (L0, dependency reproducibility).

Python: **no third-party imports at all** (verified with `ast` against
`sys.stdlib_module_names` under CPython 3.14 for all four scripts). There is no
`requirements.txt`, `pyproject.toml` or lockfile because there is nothing to lock.

---

## 3. Runtime and implicit coupling

### 3.1 Configuration surface (environment variables)

`AppConfiguration.Key` is the authoritative list (independent of the contract):
provider credentials (`TAVILY_API_KEY`, `BRAVE_SEARCH_API_KEY`, `MOJEEK_API_KEY`,
`EXA_API_KEY`, `JINA_API_KEY`), endpoints (`SEARXNG_BASE_URL`, `OPEN_WEB_SEARCH_URL`,
`PARALLEL_MCP_URL`), synthesis (`DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL`, `DEEPSEEK_MODEL`,
`SEARCH_SYNTHESIS_TIMEOUT_MS`, `SEARCH_SYNTHESIS_REASONING`), policy
(`SEARCH_PROVIDER_ORDER`, `SEARCH_DISABLED_PROVIDERS`, `SEARCH_MAX_RESULTS`,
`SEARCH_FAST_TIMEOUT_MS`, `SEARCH_BALANCED_TIMEOUT_MS`, `SEARCH_THOROUGH_TIMEOUT_MS`,
`SEARCH_ENABLE_SCRAPERS`, `SEARCH_ENABLE_PARALLEL`, `SEARCH_ENABLE_JINA_READER`,
`SEARCH_CACHE_TTL_SECONDS`), transport (`SEARCH_REQUEST_TIMEOUT_MS`, `SEARCH_MAX_RETRIES`,
`SEARCH_USER_AGENT`), security (`SEARCH_ALLOW_PRIVATE_NETWORK`), logging
(`SEARCH_LOG_LEVEL`, `SEARCH_LOG_QUERIES`), and `SEARCH_CONFIG_FILE`.

Consumers outside the package: `deploy/docker-compose.yml` sets `SEARXNG_*` for the
container; `deploy/provision-node.sh` writes a settings file and reads `SUDO_PASSWORD`;
`scripts/soak.py` writes `SEARCH_ENABLE_*`, `SEARCH_DISABLED_PROVIDERS` and
`SEARCH_CONFIG_FILE` into the child; CI sets placeholder credentials. **These are implicit
contracts:** renaming a variable in `AppConfiguration` silently breaks a script or a
deployment with no compile-time link.

### 3.2 Wire / file contracts

| Contract | Producer | Consumer(s) | Breakage mode |
| --- | --- | --- | --- |
| MCP tool schemas (`ToolSchemas`) | `SwiftWebSearchMCP` | every MCP client; `SchemaCompatibilityTests`; `scripts/mcp_smoke.py` (property list) | a schema change breaks clients silently |
| MCP tool names (`web_search`, `web_open`, `web_answer`, `web_search_status`) | `MCPServer.swift` | clients, `mcp_smoke.py`, `StdioServerTests` | rename breaks clients and CI |
| `web_search` structured result keys | `ToolSchemas.searchStructured` | clients, docs wiki | additive-only contract |
| SearXNG JSON (`results[].engine/engines`, `unresponsive_engines`, `answers`, `format=json`) | SearXNG instances | `SearXNGProvider`, `NodeProbe`, `scripts/searxng_health.py`, `scripts/soak.py` | silent empty results |
| Docker Compose service/port/healthcheck | `deploy/docker-compose.yml` | local instance; `searxng_health.py`; the monitor's `this-mac` node | local provider disappears |
| Node provisioning (Colima VM, port 8888, container name `mcps-searxng`, settings path) | `deploy/provision-node.sh` | the four nodes; the monitor's default node list | fleet drift |
| Monitor default node addresses (`Options.defaultNodes`) | `Sources/MCPSMonitor/main.swift` | the fleet's actual Tailscale addresses; wiki `Self-Hosting` | monitor shows phantom nodes |
| Config file (`config.env`, `KEY=VALUE`) | operator | `AppConfiguration.load` via `SEARCH_CONFIG_FILE`; `LiveProviderTests` walk-up | server runs unconfigured |
| SQL/IPC/queues/DB tables | — | — | **none in this repository** |

### 3.3 Model / LLM interface

`AnswerSynthesizer` calls an OpenAI-compatible `/chat/completions` on `DEEPSEEK_BASE_URL`
(default `https://api.deepseek.com/v1`, model `deepseek-flash`) and is deliberately **not**
a `SearchProvider`: its output is used only to produce prose with citations, and out-of-range
citations are stripped. Model output never drives tool selection, ranking or fetching.

---

## 4. Trust boundaries

| Boundary | Direction | What crosses it | Existing controls |
| --- | --- | --- | --- |
| **1. MCP client → tools** (stdio or HTTP) | untrusted in | tool names + JSON arguments | schema validation, argument clamping, `additionalProperties: false`; HTTP: loopback default, origin check, session id, 1 MiB body cap — **no auth (by design, ISSUE-7)** |
| **2. `web_open` → public internet** | untrusted in/out | arbitrary URL chosen by a model | `URLPolicy` three layers (lexical, DNS classification incl. embedded-IPv4, per-hop redirect re-validation); private-network opt-in; **DNS-rebinding window accepted** |
| **3. Provider HTTP responses → parsers** | untrusted in | vendor JSON / HTML | size caps, content-type allow-list, explicit DTO decoding, `ResultNormalizer` re-filtering |
| **4. Scraped HTML → extraction** | untrusted in | arbitrary markup | SwiftSoup with boilerplate removal and challenge detection; scrapers opt-in |
| **5. LLM output → answer text** | untrusted in | generated prose | citations range-checked, stripped and renumbered; prose never affects ranking |
| **6. SearXNG instances** (local + 4 nodes) | semi-trusted | metasearch JSON | no auth; loopback locally, LAN/Tailscale on nodes; documented as not to be port-forwarded |
| **7. Credentials** | secret | env vars / config file | never logged, never persisted, `SEARCH_LOG_QUERIES=false` default, curated error text |
| **8. CI** | semi-trusted | repo + placeholder env | actions SHA-pinned, no secrets configured, cache key on `Package.resolved` |

---

## 5. Blast radius (anything with >1 consumer is audited at higher severity)

| Unit | Consumers | Severity multiplier |
| --- | --- | --- |
| `WebSearchCore` | both executables, both test targets, all four scripts indirectly | **highest** — a change here reaches every product surface |
| `ToolSchemas` | every MCP client, `SchemaCompatibilityTests`, `StdioServerTests`, `mcp_smoke.py` | **high** (external contract) |
| `AppConfiguration.Key` | server, monitor, scripts, deploy, CI, docs | **high** (implicit cross-unit contract) |
| `MCPServer` tool names | clients, tests, smoke script | high |
| `deploy/*` | 5 running SearXNG instances (4 remote) | high (remote effect) |
| `mcps-mon` | operators only | medium |
| `scripts/*` | operators + CI | medium |
| `docs/**`, wiki | external readers | medium (contract documentation) |

---

## 6. Findings from scope discovery (entered in the ledger)

* `SCOPE-1` — the brief's monorepo/C#/C premises do not apply (§ header). N/A, not BLOCKED.
* `SCOPE-2` — implicit env-var contracts have no automated consistency check across
  `AppConfiguration`, `scripts/*`, `deploy/*` and CI (candidate finding for L1).
* `SCOPE-3` — `swift-nio` is pinned by range while the other two direct dependencies are
  `exact` (candidate finding for L0).
