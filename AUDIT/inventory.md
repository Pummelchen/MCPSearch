# §2 Inventory, dependency graph, trust boundaries and tiers

Committed before any fix, per §2.4. The tier table is what licenses reduced human inspection; the
reduction is disclosed here and in the final report, never hidden.

## 2.1 Projects, languages, build systems, entry points

One project. Three products from one SwiftPM package.

| | |
| --- | --- |
| Project | `MCPSearch` (package `SwiftWebSearchMCP`) |
| Build system | SwiftPM (`Package.swift`, tools-version 6.4), `Package.resolved` committed |
| Primary host | `Node1` (this Mac) — see `AUDIT/environment.md` |
| Languages | Swift (15 581 lines), Python (9 scripts), Shell (5 scripts). **No C/C++.** |

Products and entry points:

| Product | Entry point | Kind |
| --- | --- | --- |
| `SwiftWebSearchMCP` | `Sources/SwiftWebSearchMCP/main.swift` | MCP server over stdio or Streamable HTTP |
| `mcps-mon` | `Sources/MCPSMonitor/main.swift` | Interactive terminal dashboard |
| `WebSearchCore` | library, no `main` | All search/fetch/reliability logic; contains no MCP code |
| — | `deploy/install.sh`, `deploy/provision-node.sh` | Installer and node provisioner |
| — | `tools/release.sh`, `tools/check-version.sh`, `tools/sync-version.sh` | Release machinery |
| — | `scripts/*.py` (9) | Test harnesses, diagnostics, release helpers |

## 2.2 Dependency graph (depth cap: 2 hops)

Direct module dependencies, from `Package.swift`:

| From | To | Hop |
| --- | --- | --- |
| `SwiftWebSearchMCP` | `WebSearchCore`, `MCP` (swift-sdk 0.12.1), `NIOCore`/`NIOPosix`/`NIOHTTP1` (swift-nio 2.102.0) | 1 |
| `MCPSMonitor` | `WebSearchCore` | 1 |
| `WebSearchCore` | `SwiftSoup` 2.13.5 | 1 |
| `MCP` (swift-sdk) | `swift-nio`, `swift-log`, … | 2 |
| `SwiftSoup` | none declared | 2 |

All three direct dependencies are pinned with `exact:`, and `Package.resolved` is committed and
checked for drift in CI. Nothing couples at 2 hops that is not a library dependency, so no
dependency-graph escalation to Tier A arises from hop count alone.

### Cross-project / cross-consumer contracts

A contract with more than one consumer is Tier A by §2.2. These were found by reading the tree, not
by reaching outside it.

| Contract | Consumers | Tier |
| --- | --- | --- |
| **MCP protocol** (JSON-RPC over stdio and Streamable HTTP) | This server, plus every external MCP client | A |
| **SearXNG JSON API** (`/search?format=json`) | `SwiftWebSearchMCP` (`SearXNGProvider`) **and** `mcps-mon` (`NodeProbe`) — two independent parsers of one response | A |
| **`config.env` / `SEARCH_CONFIG_FILE` KEY=VALUE format** | The server's config loader **and** `scripts/soak.py`'s leak scanner, which mirrors it | A |
| **Provider environment scrub list** | `Tests/…/TestSupport.swift` **and** `scripts/mcp_smoke.py` | A |
| **`VERSION` → `BuildVersion.swift` mirror** | `MCPServer.swift`, `SearXNGProvider`-adjacent `clientInfo`, `SEARCH_USER_AGENT`, `tools/check-version.sh` | A |
| **Installed SearXNG endpoint + settings** (`deploy/searxng/settings.yml`, port, bind) | `install.sh`, `provision-node.sh`, the server, the dashboard, the fleet | A |
| **Release artifact layout** (`mcps-X.Y.Z-macos-arm64.tar.gz`, `SHA256SUMS`, `README-binaries.txt`) | `tools/release.sh` writer, `deploy/install.sh --from-release` reader, users | A |

### Scope limitation, recorded rather than assumed

§2.2 asks for **cross-project** contracts. Sibling repositories are off limits in this session
(the operator's standing instruction), so no sibling repo was inspected — not even its metadata.
Contracts *outward* from this repository are therefore enumerated from this side only: the MCP
protocol, the vendor HTTP APIs (`tavily`, `brave`, `mojeek`, `exa`, `jina`, `parallel`,
`deepseek`, Open Web Search, DuckDuckGo/Startpage scrapers), and the fleet's SearXNG instances.
Whether a sibling repository consumes any of them is **not verified here** and is recorded as
unverified in the ledger rather than silently treated as absent.

## 2.3 Trust boundaries

1. **MCP client → server.** Untrusted tool arguments (`query`, `url`, `max_results`, `include_domains`,
   …) over stdio or HTTP. `ToolSchemas.swift` validates shape; `ToolHandlers.swift` executes.
2. **HTTP transport → server.** Network-reachable when `--host` is not loopback. Has no
   authentication and no TLS *by design* (documented); the compensating control is `HTTPOriginPolicy`
   and `HTTPMCPHost`'s `Host`-header check (421 for undeclared hosts).
3. **Vendor/search response → server.** Nine providers parse JSON and HTML authored by third
   parties, including `scripts`-style scrapers where the markup is not a contract.
4. **Fetched web page → server.** `Fetch/URLPolicy.swift` is the SSRF gate; `HTMLExtractor` parses
   hostile HTML; the Jina fallback transmits the full target URL (documented, opt-out flag).
5. **SearXNG instance → server *and* dashboard.** Untrusted JSON, including `unresponsive_engines`
   and engine names, which the dashboard renders into a terminal (escape-injection surface).
6. **Credential holders.** `AppConfiguration` (env + `config.env`), `install.sh` (writes
   `config.env`, generates the SearXNG secret), `soak.py` (reads credential values to scan for leaks).
7. **Installer/provisioner → host machine.** Runs with `sudo`, downloads Homebrew and Python, writes
   `launchd` units and `config.env`, and starts services.
8. **Release machinery → the public internet.** `tools/release.sh --publish` creates a GitHub release
   and uploads artifacts; irreversible.
9. **Native-interop seam.** **None exists.** There is no C target, no module map, no bridging header,
   and no `@_cdecl`/`Unmanaged`/`UnsafePointer` interop in this repository. The §2.3 escalation for
   native interop therefore does not apply, and the C sanitizer requirement in §1 is inapplicable.

## 2.4 Tier table

| Area | Path | Tier | Why |
| --- | --- | --- | --- |
| Providers | `Sources/WebSearchCore/Providers/` (11 files) | **A** | Parses untrusted vendor JSON/HTML; holds and transmits credentials |
| Fetch | `Sources/WebSearchCore/Fetch/` (7 files) | **A** | SSRF policy, untrusted HTML, credential-bearing Jina fallback |
| Search | `Sources/WebSearchCore/Search/` (15 files) | **A** | Core production path over untrusted provider output; fusion, cache, circuit breaker |
| Support | `Sources/WebSearchCore/Support/` (13 files) | **A** | Credential/config resolution, HTTP client, origin and loopback policy |
| Monitor | `Sources/WebSearchCore/Monitor/` (6 files) | **A** | Parses untrusted JSON; renders it to a terminal; probes the network |
| MCP surface | `Sources/SwiftWebSearchMCP/` (5 files) | **A** | Network-facing endpoint; validates and acts on untrusted input |
| Dashboard | `Sources/MCPSMonitor/main.swift` | **B** | Production CLI, thin over `WebSearchCore::Monitor` |
| Installer | `deploy/install.sh` | **A** | Runs as `sudo`, writes `config.env`, installs and starts services, irreversible |
| Provisioner | `deploy/provision-node.sh` | **A** | Remote privileged provisioning |
| Release machinery | `tools/release.sh` | **A** | Publishes artifacts irreversibly; handles the release identity |
| Version tools | `tools/check-version.sh`, `tools/sync-version.sh` | **B** | Deterministic local edits, no network, no privilege |
| Credential-handling script | `scripts/soak.py` | **A** | §2.4: a Python script that **handles credentials** is Tier A whatever its size |
| Other harnesses | `scripts/{mcp_smoke,monitor_tty_smoke,dual_client_contract,harness_tests,searxng_stub,searxng_health,coverage_floor,third_party_notices}.py` | **C** | Test/glue code, no production path, no credentials |
| Tests | `Tests/` (34 files) | **C** | Scanner-only |
| Docs, config, workflows | `docs/`, `*.md`, `.github/` | **C** | Not production code |

Tier coverage stated explicitly: Tier A modules are read manually at L2/L3; Tier B is tool-first with
manual review of findings; Tier C gets formatter, linter and secret scan only. **Findings are
enumerated and closed at every tier** — the tiering reduces how much surface is human-read, not how
many findings get fixed.
