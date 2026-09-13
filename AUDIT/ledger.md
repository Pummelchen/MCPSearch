# AUDIT — task ledger

Machine-readable twin: [`ledger.json`](ledger.json) (same ids; the JSON carries every field
of the schema in the brief). **This file wins on conflict with the wiki.**

Branch `audit/2026-09-13` from `main` @ `f3dd8d9`. Baseline and evidence: [`plan.md`](plan.md),
[`baseline/`](baseline). Fleet/toolchain: [`environment.md`](environment.md).

Statuses: START → PROGRESS → TEST → AUDIT → DONE, plus BLOCKED. Gates are defined in
`plan.md`; a status does not advance without its artifact.

> **Session entry point.** Re-read this file and `environment.md` first; then resume from the
> highest-severity task that is not DONE or BLOCKED. Do not restart from scratch.

## Summary

| Metric | Count |
| --- | --- |
| Tasks enumerated | 133 (A01-A12 from Phase A/B, B01-B101 folded in Phase D, B102-B107 found while fixing, B108 found while recording CI, B109-B115 found while verifying the handover) |
| Raw findings folded | 121 across 5 passes, 17 duplicate reports merged; 7 further findings added while re-reading the tree at handover |
| DONE | 130 |
| START (reproduced, expected behaviour written) | 3 |
| PROGRESS | 0 |
| BLOCKED | 0 |

Severity of the whole set: **S0 3, S1 8, S2 34, S3 88** — the S0 set (A01, B01, B02) and the S1 set
are all DONE; of the 34 S2 tasks 34 are DONE and 0 open; of the 88 S3 tasks 85 are DONE and 3 open.

> **Correction (handover session).** The sentence above previously read "of the 75 S3 tasks 7 are
> DONE and 68 open", which contradicted both the table above it and the `DONE 79` total: 79 DONE
> minus the 45 DONE S0/S1/S2 tasks is 34 S3 tasks, and 75 - 34 is 41. The figure is recomputed from
> `ledger.json` now. The summary is generated, not typed.


Two cross-cutting gates are **not** tasks but acceptance criteria for Phase E: the whole
suite must be green on an independent host, and every scanner must be clean or explicitly
waived in writing.

---

## Open tasks

| id | sev | unit | file:line | title | category | status | host | discovered-by |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A01 | **S0** | `WebSearchCore` (scrapers + fetch) | `Fetch/MarkupDepth.swift`, `Fetch/LargeStackParse.swift`, `Providers/ScraperSupport.swift:89`, `Fetch/HTMLExtractor.swift:81` | HTML parse on a cooperative task stack exhausts the stack and kills the process | unsafe | DONE | this Mac (arm64) | audit baseline (ASan) |
| A02 | S2 | repo-wide Swift | `.swift-format` (new), `Sources/**`, `Tests/**` | `swift-format` reports 19 155 diagnostics: no config encodes the project's style | style | DONE | this Mac | audit baseline |
| A03 | S2 | repo-wide Swift | `.swiftlint.yml` (new), `URLPolicy.swift:491`, 7 test files | SwiftLint reports 491 findings with no repository config; genuine rules drown in style noise | style | DONE | this Mac | audit baseline |
| A04 | **S1** | `SwiftWebSearchMCP`, `MCPSMonitor` | `Tests/WebSearchCoreTests/TestSupport.swift`, `scripts/coverage_floor.py`, `.github/workflows/ci.yml` | The executables' coverage is unmeasured (0 % / 29.5 %): the MCP surface is driven as a subprocess | test | DONE | this Mac | audit baseline (coverage) |
| A05 | S2 | SwiftPM | `Package.swift:26-30` | `swift-nio` is pinned by range while the other direct dependencies are exact | deps | DONE | this Mac (arm64) | scope discovery |
| A06 | S2 | `Tests/` + history | `Tests/WebSearchCoreTests/StdioServerTests.swift`, `AnswerSynthesizerTests.swift`, `.gitleaks.toml` | 5 secret-scan findings across full history are synthetic test literals | deps | DONE | this Mac | audit baseline (gitleaks) |
| A07 | S3 | deploy | `deploy/provision-node.sh:69` | Homebrew installed by piping a remote script into bash (supply chain) | unsafe | DONE | this Mac | audit baseline (semgrep) |
| A08 | S3 | scripts | `scripts/mcp_smoke.py:335`, `scripts/searxng_health.py:36` | `dynamic-urllib-use`: URLs built at runtime without an explicit scheme/host guard | unsafe | DONE | this Mac | audit baseline (semgrep) |
| A09 | S3 | tests | `Tests/WebSearchCoreTests/URLPolicyTests.swift:46` | `detect-insecure-websocket` fires on the *rejection* fixture (false positive) | style | DONE | this Mac | audit baseline (semgrep) |
| A10 | **S1** | CI | `.github/workflows/ci.yml`, `scripts/coverage_floor.py` | No gate for warnings-as-errors, formatter, linter, type checker, coverage floor or scanners | test | DONE | this Mac | audit baseline |
| A11 | S2 | scripts | `ruff.toml` (new), `pyrightconfig.json` (new), `scripts/*.py` | Python is 3.14 with no strict type-checking config and no annotations | style | DONE | this Mac | audit baseline (pyright) |
| A12 | S2 | cross-unit contracts | `Support/AppConfiguration.swift`, `scripts/*`, `deploy/*`, CI | Env-var contracts between units have no automated consistency check | logic | DONE | this Mac (arm64) | scope discovery |
| B01 | **S0** | `deploy/docker-compose.yml` (with `deploy/searxng/settings.yml`, `deploy/.env.example`) | `deploy/docker-compose.yml:33`, `deploy/searxng/settings.yml:13-22` | The documented compose secret-key override is the wrong variable, so the tracked placeholder is what signs the instance | placeholder | DONE | this Mac (arm64) | Phase B PLACEHOLDER-3 + L7-10 |
| B02 | **S0** | `DirectHTTPFetcher` (redirect branch), `Tests/WebSearchCoreTests/FetchRedirectTests.swift` | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:81-101` | The manual redirect loop is the SSRF boundary for redirects and has no test at all | test | DONE | this Mac (arm64) | Phase B L6-1 |
| B03 | S1 | `SwiftWebSearchMCP` (HTTP transport wiring) | `Sources/SwiftWebSearchMCP/main.swift:118` (one transport per process), `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:290` (non-POST refused before the | The HTTP transport serves exactly one MCP session per process, and that session can never be released | bug | DONE | this Mac (arm64) | Phase B L3-25 |
| B04 | **S1** | `WebSearchCore` (search) + `SwiftWebSearchMCP` (tools) | `Sources/WebSearchCore/Search/SearchOrchestrator.swift:66`, `Fetch/DirectHTTPFetcher.swift:190`, `Fetch/WebFetcher.swift:104` | Caller cancellation is never tested, and mid-flight cancellation is observably swallowed | bug | DONE | this Mac (arm64) | Phase B L6-3 + L2-6 |
| B05 | S1 | `Tests/WebSearchCoreTests/AUDITDiagnosticsTests.swift` | `Tests/WebSearchCoreTests/AUDITDiagnosticsTests.swift:6` (also `:11`, `:83`, `:111`) | TEMPORARY audit tooling is committed to the go-live test target and can abort the whole suite | placeholder | DONE | MacBook-AB.local (arm64, macOS 26.6.2, Swift 6.3.3) | Phase B PLACEHOLDER-1 |
| B06 | **S1** | `WebSearchCore` / `Support` + `Fetch`, `MCPSMonitor` | `Sources/WebSearchCore/Support/Logging.swift:128`, `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:142`, `Sources/MCPSMonitor/main.swift:171` | Untrusted seconds are converted `Double`->`Int` without a range check, so a hostile value traps the whole process | unsafe | DONE | this Mac (arm64) | Phase B L4-1 + L3-3 |
| B07 | **S1** | `WebSearchCore` (transport) | `Sources/WebSearchCore/Support/BoundedResponseBody.swift`, `Support/HTTPClient.swift:299`, `Fetch/DirectHTTPFetcher.swift:176` | Response bodies are fully buffered in memory before the byte cap is applied, so one hostile page exhausts the process | perf | DONE | this Mac (arm64) | Phase B L5-1 |
| B08 | **S1** | `SwiftWebSearchMCP` (web_open tool) | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:134`, `ToolSchemas.swift:738-774`, `Tests/WebSearchCoreTests/StdioServerTests.swift` | `web_open`'s success path through the MCP tool is untested end to end | test | DONE | this Mac (arm64) | Phase B L6-2 |
| B09 | S2 | `WebSearchCore` — `Support/AppConfiguration.swift`, `SwiftWebSearchMCP/main.swift` | `Sources/WebSearchCore/Support/AppConfiguration.swift:252-261`, `:283-300`, `:389-391` | Nothing validates configuration at startup: a mistyped value or config path is silently discarded | incomplete | DONE | this Mac (arm64) | Phase B L7-1 |
| B10 | S2 | `MCPSMonitor` + `Monitor/Terminal.swift` | `Sources/WebSearchCore/Monitor/Terminal.swift:156-157`, `:165-171`, `:187-189`; `Sources/MCPSMonitor/main.swift:508`, `:571-574` | Ctrl-C (or SIGTERM) leaves the dashboard's terminal in raw mode with the cursor hidden, and the Ctrl-C key branch is unreachable | bug | DONE | this Mac (arm64) | Phase B L7-2 |
| B11 | S2 | WebSearchCore (Search) | `Sources/WebSearchCore/Search/ProviderHealth.swift:143` | A half-open breaker authorises an unbounded number of requests: `authorize` discards the probe refusal | bug | DONE | this Mac (arm64) | Phase B L2-1 |
| B12 | S2 | WebSearchCore (Search) | `Sources/WebSearchCore/Search/SearchOrchestrator.swift:384` | Providers that already reported a failure are charged a second, synthetic deadline failure | bug | DONE | this Mac (arm64) | Phase B L2-3 |
| B13 | S2 | WebSearchCore (Support) | `Sources/WebSearchCore/Support/HTTPClient.swift:216` | The session resource timeout silently caps every per-request timeout override, including the 45 s synthesis budget | bug | DONE | this Mac (arm64) | Phase B L2-4 |
| B14 | S2 | WebSearchCore (Fetch) | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:37` | `web_open` has no total deadline: a slow-drip server holds the tool call open indefinitely | unsafe | DONE | this Mac (arm64) | Phase B L2-5 |
| B15 | S2 | WebSearchCore (Fetch) | `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:43` | The Jina Reader target is percent-encoded into a *path*, so URLs with a query or fragment fetch the wrong resource | bug | DONE | this Mac (arm64) | Phase B L2-7 |
| B16 | S2 | WebSearchCore (Fetch) | `Sources/WebSearchCore/Fetch/WebFetcher.swift:50` | PDFs are on the allowed content-type list but are decoded as Latin-1 text, so `web_open` returns binary mojibake as "readable text" | bug | DONE | this Mac (arm64) | Phase B L2-8 |
| B17 | S2 | `deploy/provision-node.sh` | `deploy/provision-node.sh:235` (template at `:216`) | Unchecked `sed` can leave the tracked `__SECRET_KEY__` placeholder signing a provisioned SearXNG instance | placeholder | DONE | this Mac (arm64) | Phase B PLACEHOLDER-2 |
| B18 | S2 | `Tests/WebSearchCoreTests/StdioServerTests.swift` | `Tests/WebSearchCoreTests/StdioServerTests.swift:716` | `web_open` security-rejection test is weakened to "some refusal happened" | test | DONE | this Mac (arm64) | Phase B L3-4 |
| B19 | S2 | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift` | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:674` | The test named `testProvidersReceiveALargerBudgetThanTheFinalResultLimit` never inspects the budget | test | DONE | this Mac (arm64) | Phase B L3-5 |
| B20 | S2 | `Tests/WebSearchCoreTests/HTTPTransportTests.swift` | `Tests/WebSearchCoreTests/HTTPTransportTests.swift:183` (release at `:188`, use at `:215`) | Port race in the HTTP-transport harness, whose comment claims collision-freedom | test | DONE | this Mac (arm64) | Phase B L3-6 |
| B21 | S2 | `SwiftWebSearchMCP` (HTTP transport wiring) | `Sources/SwiftWebSearchMCP/main.swift:120` | The HTTP Host allow-list is hard-coded to loopback, so the documented `--host`/proxy deployment gets 421 | bug | DONE | this Mac (arm64) | Phase B L3-26 |
| B22 | S2 | `.github/workflows/ci.yml` | `.github/workflows/ci.yml:67` (parse at `:63`) | The CI Swift-version gate passes silently when the version cannot be parsed | logic | DONE | this Mac (arm64) | Phase B L3-27 |
| B23 | S2 | `scripts/soak.py` | `scripts/soak.py:217` (guard at `:214`, assignment `:221`) | `soak.py --providers` is not authoritative: an ambient `SEARCH_DISABLED_PROVIDERS` still disables requested providers | logic | DONE | this Mac (arm64) | Phase B L3-28 |
| B24 | S2 | `Tests/WebSearchCoreTests/HTTPClientTests.swift`, `Sources/WebSearchCore/Support/HTTPClient.swift` | `Tests/WebSearchCoreTests/HTTPClientTests.swift:314` | `testCancellationPropagatesAsCancelled` uses an assertion that cannot fail | test | DONE | this Mac (arm64) | Phase B L3-19 |
| B25 | S2 | `MCPSMonitor` (rendering) + `WebSearchCore` / `Monitor` | `Sources/WebSearchCore/Monitor/Renderer.swift:313` (also `:307` for `status.lastError`, and `Sources/MCPSMonitor/main.swift:431`) | Provider/instance-controlled engine names are written to the operator's terminal without stripping control characters (terminal escape injection) | unsafe | DONE | this Mac (arm64) | Phase B L4-2 |
| B26 | S2 | `WebSearchCore` / `Search` (`AnswerSynthesizer`) | `Sources/WebSearchCore/Search/AnswerSynthesizer.swift:460` | Citation validation covers only `[n]` markers, so the answer prose can still carry fabricated URLs that the documented guarantee says cannot exist | logic | DONE | this Mac (arm64) | Phase B L4-3 |
| B27 | S2 | `WebSearchCore` / `Search` (`AnswerSynthesizer`, `SearchOrchestrator`) + `SwiftWebSearchMCP` | `Sources/WebSearchCore/Search/AnswerSynthesizer.swift:215` (also `Sources/WebSearchCore/Search/SearchOrchestrator.swift:201`) | Untrusted page text and provider answers enter the synthesis prompt and the tool output as undelimited content (indirect prompt injection) | unsafe | DONE | this Mac (arm64) | Phase B L4-4 |
| B28 | S2 | `WebSearchCore` / `Fetch` (`HTMLExtractor`) | `Sources/WebSearchCore/Fetch/HTMLExtractor.swift:143` | `preferredContentRoot` re-serialises every candidate's subtree, giving quadratic work on crafted HTML | perf | DONE | this Mac (arm64) | Phase B L5-2 |
| B29 | S2 | `Sources/WebSearchCore/Support/HTTPClient.swift` (`send` retry branch) | `Sources/WebSearchCore/Support/HTTPClient.swift:243` | `maxRetryAfter` (the cap that stops a hostile `Retry-After` stalling a search) is untested | test | DONE | this Mac (arm64) | Phase B L6-5 |
| B30 | S2 | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift` | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:202` | `DirectHTTPFetcher`'s size cap, content-type gate, raw-text path and timeout mapping have no test | test | DONE | this Mac (arm64) | Phase B L6-6 |
| B31 | S2 | `Tests/WebSearchCoreTests/CoreUnitTests.swift` (`ConfigurationTests`), `Sources/WebSearchCore/Support/AppConfi | `Tests/WebSearchCoreTests/CoreUnitTests.swift:317` | `AppConfiguration.load()` and its file-vs-environment precedence have no test | test | DONE | this Mac (arm64) | Phase B L6-9 |
| B32 | S2 | `Sources/SwiftWebSearchMCP/ToolSchemas.swift` (`ToolArguments`), `Sources/SwiftWebSearchMCP/ToolHandlers.swift | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:477` | Tool-argument validation boundaries are untested; only three malformed cases exist | test | DONE | this Mac (arm64) | Phase B L6-10 |
| B33 | S2 | `Sources/WebSearchCore/Fetch/WebFetcher.swift`, `Tests/WebSearchCoreTests/FetchFallbackTests.swift` | `Sources/WebSearchCore/Fetch/WebFetcher.swift:135` | `WebFetcher`'s Jina-failure fallback and error propagation are untested | test | DONE | this Mac (arm64) | Phase B L6-11 |
| B34 | S2 | `Sources/WebSearchCore/Search/ResultNormalizer.swift` | `Sources/WebSearchCore/Search/ResultNormalizer.swift:68` | `ResultNormalizer`'s URL repair and text cleaning are untested | test | DONE | this Mac (arm64) | Phase B L6-12 |
| B35 | S2 | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift`, `HTTPClientTests.swift`, `HTTPTransportTests.swift` | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:500` | Timing-dependent tests: real sleeps, real clocks and an upper-bound wall-clock assertion | test | DONE | this Mac (arm64) | Phase B L6-13 |
| B36 | S3 | repository root | `.gitignore:1-16` | `.gitignore` does not cover the LLVM profile output the documented sanitizer runs produce | style | DONE | this Mac (arm64) | Phase B L0-1 |
| B37 | S3 | `AUDIT/baseline/**` | `AUDIT/baseline/swiftlint.json:4` (first of 491 such lines), `AUDIT/baseline/swift-test-asan.log:58`, `AUDIT/baseline/swift-test.log:4`, `AUDIT/baseli | Committed baseline evidence embeds the auditor's absolute home path (491 lines) and 2.5 MB of generated output | unsafe | DONE | this Mac (arm64) | Phase B L0-2 |
| B38 | S3 | `.github/workflows/ci.yml` | `.github/workflows/ci.yml:1-31` | The CI workflow declares no `permissions:`, so the job token keeps the default scope | unsafe | DONE | this Mac (arm64) | Phase B L0-3 |
| B39 | S3 | `.github/workflows/ci.yml` | `.github/workflows/ci.yml:40-70` | CI does not pin the Swift toolchain, so "Swift 6.3" is whatever the runner image has | deps | DONE | this Mac (arm64) | Phase B L0-4 |
| B40 | S3 | `Package.swift`, `Package.resolved`, CI | `Package.swift:31-34`, `.github/workflows/ci.yml:89-96` | Nothing detects that `Package.resolved` has drifted from the manifests | deps | DONE | this Mac (arm64) | Phase B L0-5 |
| B41 | S3 | `Package.swift`, repository root | `Package.swift:31-34` | Apache-2.0 `NOTICE` files of two dependencies are not carried with any distributed binary | deps | DONE | node1 (arm64) | Phase B L0-6 |
| B42 | S3 | `SwiftWebSearchMCP` (`HTTPMCPHost`) | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:448` | The hand-rolled `Origin` check accepts any host starting with `127.`, which is a bypass of the check it pretends to be | logic | DONE | this Mac (arm64) | Phase B L4-7 |
| B43 | S3 | `AUDIT/plan.md` vs `AUDIT/baseline/` | `AUDIT/plan.md:38` | The baseline evidence table cites `gitleaks.json`, which is not in the repository | docs | DONE | this Mac (arm64) | Phase B L7-5 |
| B44 | S3 | `scripts/soak.py` | `scripts/soak.py:473-479` | The soak test's comment promises a "provider never contributed" failure that the code never implements | incomplete | DONE | this Mac (arm64) | Phase B L7-6 |
| B45 | S3 | `scripts/mcp_smoke.py`, `scripts/monitor_tty_smoke.py` | `scripts/mcp_smoke.py:100-105`, `scripts/monitor_tty_smoke.py:186-194` | The "prove the scrub" loops in both smoke scripts are no-ops that cannot fail | dead | DONE | this Mac (arm64) | Phase B L7-7 |
| B46 | S3 | `MCPSMonitor` | `Sources/MCPSMonitor/main.swift:45-78` (`--iterations  Stop after n refreshes (useful for scripting)`), `:533-580` | `mcps-mon` always exits 0, so `--iterations` cannot be used as a health check | incomplete | DONE | this Mac (arm64) | Phase B L7-8 |
| B47 | S3 | `example.env` vs `deploy/` | `example.env:35-39` | `example.env` tells the operator to fix a SearXNG setting that the shipped files already set | docs | DONE | this Mac (arm64) | Phase B L7-9 |
| B48 | S3 | `deploy/provision-node.sh` | `deploy/provision-node.sh:296-297` | `provision-node.sh` cannot find a Homebrew-installed Tailscale CLI on Apple Silicon | bug | DONE | this Mac (arm64) | Phase B L7-11 |
| B49 | S3 | `deploy/provision-node.sh` | `deploy/provision-node.sh:192-199`, `:203-235` | The generated SearXNG `settings.yml` inherits the umask, so the per-node secret key is world-readable | unsafe | DONE | this Mac (arm64) | Phase B L7-12 |
| B50 | S3 | `deploy/provision-node.sh` | `deploy/provision-node.sh:255-284` | Provisioning destroys the working instance before its replacement is proven on the production port, with no rollback | incomplete | DONE | this Mac (arm64) | Phase B L7-13 |
| B51 | S3 | `WebSearchCore` / `Support` (`Log`) | `Sources/WebSearchCore/Support/Logging.swift:119` | `Log.escape` leaves every control character except `\n`, `\r` and `\t`, so a query can inject terminal escapes into stderr | unsafe | DONE | this Mac (arm64) | Phase B L4-8 |
| B52 | S3 | WebSearchCore (Search) | `Sources/WebSearchCore/Search/SearchOrchestrator.swift:501` | A claimed half-open probe is never released when a request ends in a bare `CancellationError` | bug | DONE | this Mac (arm64) | Phase B L2-2 |
| B53 | S3 | WebSearchCore (Monitor) | `Sources/WebSearchCore/Monitor/Terminal.swift:96` | `Terminal.truncate` counts ANSI escape characters as display width, so truncating styled text can drop the SGR reset | bug | DONE | this Mac (arm64) | Phase B L2-9 |
| B54 | S3 | WebSearchCore (Providers) | `Sources/WebSearchCore/Providers/ParallelMCPProvider.swift:162` | Concurrent first use of the Parallel provider performs the MCP handshake more than once | bug | DONE | this Mac (arm64) | Phase B L2-10 |
| B55 | S3 | WebSearchCore (Search) | `Sources/WebSearchCore/Search/ProviderHealth.swift:119` | `ProviderHealth.setNote` is dead public API | dead | DONE | this Mac (arm64) | Phase B L2-11 |
| B56 | S3 | WebSearchCore (Providers) | `Sources/WebSearchCore/Providers/ScraperSupport.swift:24` | `ScraperSupport.BlockKind.noResults` is never produced, so an empty result page is reported as unparseable | dead | DONE | this Mac (arm64) | Phase B L2-12 |
| B57 | S3 | SwiftWebSearchMCP (with WebSearchCore) | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:407` | The per-provider "which variable enables me" contract is triplicated across units and already wrong for `parallel` | logic | DONE | this Mac (arm64) | Phase B L1-1 |
| B58 | S3 | SwiftWebSearchMCP | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:186` | `web_search` and `web_answer` duplicate their argument parsing, and the two schemas have already drifted | style | DONE | this Mac (arm64) | Phase B L1-2 |
| B59 | S3 | `WebSearchCore/Support/AppConfiguration.swift` | `Sources/WebSearchCore/Support/AppConfiguration.swift:330` | `PARALLEL_MCP_URL=` cannot clear the default endpoint: the branch is unreachable in production | dead | DONE | this Mac (arm64) | Phase B L3-7 |
| B60 | S3 | `WebSearchCore/Providers/DuckDuckGoProvider.swift` | `Sources/WebSearchCore/Providers/DuckDuckGoProvider.swift:70` | DuckDuckGo region hint sends the region twice instead of region-language | bug | DONE | this Mac (arm64) | Phase B L3-8 |
| B61 | S3 | `WebSearchCore/Fetch/HTMLExtractor.swift` | `Sources/WebSearchCore/Fetch/HTMLExtractor.swift:63` (markers at `:36`, `:40`) | Hyphenated boilerplate markers are inert, and the prefix clause is unreachable | logic | DONE | this Mac (arm64) | Phase B L3-9 |
| B62 | S3 | `WebSearchCore/Fetch/URLPolicy.swift` | `Sources/WebSearchCore/Fetch/URLPolicy.swift:435` | `isReserved` blocks all of `192.0.0.0/16` while documenting `192.0.0.0/24` | logic | DONE | this Mac (arm64) | Phase B L3-10 |
| B63 | S3 | `WebSearchCore` / `Search` (`ResultNormalizer`) | `Sources/WebSearchCore/Search/ResultNormalizer.swift:155` | Entity decoding loops over its own output, so `&amp;lt;` becomes a live `<` in text returned to the model | bug | DONE | this Mac (arm64) | Phase B L4-14 |
| B64 | S3 | `WebSearchCore/Monitor/NodeProbe.swift` | `Sources/WebSearchCore/Monitor/NodeProbe.swift:102` (catch at `:133-142`) | Malformed JSON from a node is reported as "unreachable" | bug | DONE | this Mac (arm64) | Phase B L3-12 |
| B65 | S3 | `WebSearchCore/Monitor/MonitorModel.swift`, `Sources/MCPSMonitor/main.swift` | `Sources/WebSearchCore/Monitor/MonitorModel.swift:50` | `NodeStatus.State.skipped` is unreachable dead state | dead | DONE | this Mac (arm64) | Phase B L3-13 |
| B66 | S3 | `WebSearchCore/Providers/*` | `Sources/WebSearchCore/Providers/MojeekProvider.swift:219` (and `ExaProvider.swift:174`, `SearXNGProvider.swift:174`, `TavilyProvider.swift:165`, `Bra | Decoded-but-unused vendor DTO fields across five adapters | dead | DONE | this Mac (arm64) | Phase B L3-14 |
| B67 | S3 | `WebSearchCore/Monitor/Renderer.swift` | `Sources/WebSearchCore/Monitor/Renderer.swift:273` (data at `:288`) | Node table header and data disagree on the state column width | style | DONE | this Mac (arm64) | Phase B L3-17 |
| B68 | S3 | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift` | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:499` | Stale "detached task" comment plus a 60 ms sleep that waits for nothing | test | DONE | this Mac (arm64) | Phase B L3-18 |
| B69 | S3 | `Tests/WebSearchCoreTests/CoreUnitTests.swift` | `Tests/WebSearchCoreTests/CoreUnitTests.swift:344` | Clock test asserts a property that cannot fail | test | DONE | this Mac (arm64) | Phase B L3-20 |
| B70 | S3 | `Tests/WebSearchCoreTests/StdioServerTests.swift` (same pattern in `ErrorReportingTests.swift`, `SchemaCompati | `Tests/WebSearchCoreTests/StdioServerTests.swift:85` (loop `:70-93`) | Subprocess harnesses advertise a timeout that a blocking read cannot enforce | test | DONE | this Mac (arm64) | Phase B L3-21 |
| B71 | S3 | `Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift` | `Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift:30` | Three copies of the same subprocess harness, already diverged | test | DONE | this Mac (arm64) | Phase B L3-22 |
| B72 | S3 | `Tests/WebSearchCoreTests/TestSupport.swift` | `Tests/WebSearchCoreTests/TestSupport.swift:178` (body `:170-189`) | `assertNoCredentialLeak` documents a check it does not perform and passes vacuously | test | DONE | this Mac (arm64) | Phase B L3-23 |
| B73 | S3 | `scripts/soak.py` | `scripts/soak.py:446` | Soak report attributes every failure category to every provider | bug | DONE | this Mac (arm64) | Phase B L3-24 |
| B74 | S3 | `MCPSMonitor` (option parsing) | `Sources/MCPSMonitor/main.swift:200` (`--no-nodes` at `:143`, custom nodes at `:160`) | `--no-nodes` is silently ignored whenever a `--node` is also present | logic | DONE | this Mac (arm64) | Phase B L3-29 |
| B75 | S3 | `MCPSMonitor` (option parsing); same helper copied in `WebSearchCore/Support/TransportConfiguration.swift` | `Sources/MCPSMonitor/main.swift:155` (helper `:127-135`); `Sources/WebSearchCore/Support/TransportConfiguration.swift:97` | `--node` accepts a relative URL and can swallow the next flag as its value | logic | DONE | this Mac (arm64) | Phase B L3-30 |
| B76 | S3 | `MCPSMonitor` (provider selection); `WebSearchCore/Search/ProviderRegistry.swift` | `Sources/MCPSMonitor/main.swift:348` (and `:292`), `Sources/WebSearchCore/Search/ProviderRegistry.swift:34` | `mcps-mon` ignores `SEARCH_DISABLED_PROVIDERS`, labels disabled providers "ready", and probes them | logic | DONE | this Mac (arm64) | Phase B L3-31 |
| B77 | S3 | `SwiftWebSearchMCP` (argument parsing) | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:464` | `ToolArguments.bool(_:)` has no caller | dead | DONE | this Mac (arm64) | Phase B L3-33 |
| B78 | S3 | `MCPSMonitor` view state; `WebSearchCore/Monitor/Renderer.swift` | `Sources/WebSearchCore/Monitor/MonitorModel.swift:127` and `:134` | `ProviderStatus.State.probing` and `.unavailable` can never be produced, so their renderer branches are unreachable | dead | DONE | this Mac (arm64) | Phase B L3-34 |
| B79 | S3 | `SwiftWebSearchMCP` (HTTP host body cap) | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:167` | A request-head `Content-Length` reserves up to 1 MiB per connection before any body arrives | unsafe | DONE | this Mac (arm64) | Phase B L3-36 |
| B80 | S3 | `scripts/soak.py` | `scripts/soak.py:170` (used at `:183`) | `soak.py` conflates EOF with a malformed stdout line and discards the line | bug | DONE | this Mac (arm64) | Phase B L3-38 |
| B81 | S3 | `scripts/mcp_smoke.py` | `scripts/mcp_smoke.py:315` (decode at `:296`) | `mcp_smoke.py` de-chunks an SSE body after decoding it to `str` | bug | DONE | this Mac (arm64) | Phase B L3-39 |
| B82 | S3 | `scripts/soak.py` | `scripts/soak.py:327` (argument at `:301`) | A negative `--queries` silently truncates the query list from the end | bug | DONE | this Mac (arm64) | Phase B L3-40 |
| B83 | S3 | `scripts/mcp_smoke.py` | `scripts/mcp_smoke.py:345-353` (port at `:350-357`, stderr only read at `:458`) | HTTP smoke can wait 20 s on a dead server and never checks that it is alive | bug | DONE | this Mac (arm64) | Phase B L3-41 |
| B84 | S3 | `WebSearchCore` / `Fetch` (`URLPolicy`) | `Sources/WebSearchCore/Fetch/URLPolicy.swift:289` | `IPAddress.v6` is a public case that accepts any byte count, and its accessors index 16 bytes unconditionally | unsafe | DONE | this Mac (arm64) | Phase B L4-9 |
| B85 | S3 | `WebSearchCore` / `Support` (`Log`) | `Sources/WebSearchCore/Support/Logging.swift:93` | Query hashing for logs is a fast unsalted FNV-1a, but is documented as non-reversible | docs | DONE | this Mac (arm64) | Phase B L4-10 |
| B86 | S3 | `deploy` (`provision-node.sh`) | `deploy/provision-node.sh:71` | Provisioning writes through fixed, predictable `/tmp` paths and loads a container image from one | unsafe | DONE | this Mac (arm64) | Phase B L4-12 |
| B87 | S3 | `WebSearchCore` / `Fetch` (`JinaReaderFetcher`) + `WebSearchCore` / `Search` (`SearchPipelineFactory`) | `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:65` | The Jina Reader fallback discloses the target URL to a third party by default, with no warning that it did | docs | DONE | this Mac (arm64) | Phase B L4-13 |
| B88 | S3 | `WebSearchCore` / `Fetch` (`URLPolicy` + `DirectHTTPFetcher`) | `Sources/WebSearchCore/Fetch/URLPolicy.swift:57` | The declared per-host DNS cache does not exist, and every redirect hop resolves twice | perf | DONE | this Mac (arm64) | Phase B L5-3 |
| B89 | S3 | `WebSearchCore` / `Search` (`SearchCache`) | `Sources/WebSearchCore/Search/SearchCache.swift:103` | `SearchCache.pruneExpired` rebuilds the whole dictionary on every read, write and stats call | perf | DONE | this Mac (arm64) | Phase B L5-4 |
| B90 | S3 | `SwiftWebSearchMCP` (`HTTPMCPHost`) | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:61` | The HTTP listener bounds the request body but nothing else, so idle or slow connections are unbounded | perf | DONE | this Mac (arm64) | Phase B L5-5 |
| B91 | S3 | `WebSearchCore` / `Support` (`Log`) | `Sources/WebSearchCore/Support/Logging.swift:42` | Log emission performs a synchronous blocking write to fd 2 from whatever task is logging | perf | DONE | this Mac (arm64) | Phase B L5-6 |
| B92 | S3 | `WebSearchCore` / `Fetch` (`JinaReaderFetcher`) | `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:125` | `web_open` reports the requested URL as `final_url` on the Jina path, and the reader's own `url` field is decoded but never used | logic | DONE | this Mac (arm64) | Phase B L5-7 |
| B93 | S3 | `Sources/WebSearchCore/Fetch/MarkupDepth.swift`, `Search/SearchError.swift`, `SwiftWebSearchMCP/ToolHandlers.s | `Sources/WebSearchCore/Fetch/MarkupDepth.swift:190` | The new `MarkupDepth` regression suite still leaves four branches/contracts unpinned | test | DONE | this Mac (arm64) | Phase B L6-4 |
| B94 | S3 | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift`, `Sources/WebSearchCore/Search/SearchOrchestrator.swi | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:716` | `testStatusCountsSuccessesAndFailures` never observes a failure | test | DONE | this Mac (arm64) | Phase B L6-14 |
| B95 | S3 | `Tests/WebSearchCoreTests/MonitorTests.swift`, `Sources/WebSearchCore/Monitor/ProviderProbe.swift:50` | `Tests/WebSearchCoreTests/MonitorTests.swift:101` | The monitor's setup-hint test asserts a string the test itself constructed | test | DONE | this Mac (arm64) | Phase B L6-15 |
| B96 | S3 | `Sources/WebSearchCore/Providers/HTTPStatusMapper.swift` | `Sources/WebSearchCore/Providers/HTTPStatusMapper.swift:46` | `HTTPStatusMapper.map`'s HTTPError branches and `validate`'s default/422 statuses are untested | test | DONE | this Mac (arm64) | Phase B L6-16 |
| B97 | S3 | `Sources/WebSearchCore/Search/AnswerSynthesizer.swift`, `Tests/WebSearchCoreTests/AnswerSynthesizerTests.swift | `Sources/WebSearchCore/Search/AnswerSynthesizer.swift:349` | `AnswerSynthesizer`'s completion edge cases, token usage and locale prompt are untested | test | DONE | this Mac (arm64) | Phase B L6-17 |
| B98 | S3 | `Sources/MCPSMonitor/main.swift` (`Monitor`), `Tests/MCPSMonitorTests/MonitorOptionsTests.swift` | `Sources/MCPSMonitor/main.swift:337` | The `Monitor` actor's refresh/counting/warning logic has no Swift test | test | DONE | this Mac (arm64) | Phase B L6-18 |
| B99 | S3 | `Tests/WebSearchCoreTests/TestSupport.swift`, `scripts/*.py` | `Tests/WebSearchCoreTests/TestSupport.swift:12` | No test ties the Swift test harnesses to the Python harnesses, and two scripts are untested entirely | test | DONE | this Mac (arm64) | Phase B L6-19 |
| B100 | S3 | `Sources/SwiftWebSearchMCP/ToolSchemas.swift` (`ToolOutputFormatter`) | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:526` | `ToolOutputFormatter`'s fallback and diagnostic branches are untested | test | DONE | this Mac (arm64) | Phase B L6-20 |
| B101 | S3 | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift`, `Tests/WebSearchCoreTests/HTTPTransportTests.swift` | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:79` | `HTTPMCPHost`'s startup-failure and internal-error paths are untested | test | START | this Mac (arm64) | Phase B L6-21 |
| B109 | S3 | `WebSearchCore` / `Search` (`RankFusion`) | `Sources/WebSearchCore/Search/RankFusion.swift:161-162` | The response-level resale discount is applied to every result of an aggregator response, defeating the per-result refinement the code documents | logic | DONE | this Mac (arm64) | handover re-read L2 |
| B110 | S3 | `SwiftWebSearchMCP` (`ToolSchemas`, `web_answer` input) | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:275-281` | `web_answer`'s `provider` argument lost the enum that `web_search`'s `provider` declares, though the schema documents itself as a mirror | logic | DONE | this Mac (arm64) | handover re-read L1 |
| B111 | S3 | `SwiftWebSearchMCP` (`ToolSchemas`, nullable enums) | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:62-66`, `:83-93`, `:94-101`, `:270-274` | Nullable enum arguments declare `["string", "null"]` with an `enum` that excludes `null`, so a strict client cannot legally send the null the design depends on | logic | DONE | this Mac (arm64) | handover re-read L1 |
| B112 | S3 | `SwiftWebSearchMCP` (`ToolSchemas`, `web_search_status` input) | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:350-358` | `statusInput` is the only object schema in the file that omits `required` | style | DONE | this Mac (arm64) | handover re-read L1 |
| B113 | S3 | `WebSearchCore` / `Support` + `SwiftWebSearchMCP` (`main`) | `Sources/SwiftWebSearchMCP/main.swift:16` and `:98` | Configuration is loaded and validated before the command line is parsed, so an unreadable config file pre-empts `--help` | logic | DONE | this Mac (arm64) | handover re-read L7 |
| B114 | S3 | `SwiftWebSearchMCP` (`TransportConfiguration.usage`) | `Sources/WebSearchCore/Support/TransportConfiguration.swift:51-77` | `usage` under-documents the CLI, and the test that claims to check every flag locks the incomplete list in place | docs | DONE | this Mac (arm64) | handover re-read L7 |
| B115 | S3 | repository root (`README.md`) | `README.md:120`, provider table `:122-134` | The README undercounts the keyless routes and its Startpage row omits the flag the adapter actually requires | docs | DONE | this Mac (arm64) | handover re-read L7 |
| B116 | S3 | `WebSearchCore` / `Search` (`SearchOrchestrator`, `RateLimiter`) | `SearchOrchestrator.swift:456-462`, `RateLimiter.swift:97-104` | A local throttle that cleared between the authorise and the wait estimate was reported as a hard skip, making the suite intermittently red | bug | DONE | node1 (arm64) | Phase E baseline |
| B117 | S3 | `scripts` (`mcp_smoke.py`) | `scripts/mcp_smoke.py` (`free_loopback_port`) | The HTTP smoke picks a free port by closing the socket before the child binds, so the child can lose the bind race | test | DONE | this Mac (arm64) | Phase C (residual B83 left) |
| B118 | S3 | `SwiftWebSearchMCP` (`ServerOptions`) | `Sources/WebSearchCore/Support/TransportConfiguration.swift` (the `--transport` error) | The invalid `--transport` error names only two of the four accepted spellings that the usage text now documents | docs | DONE | node1 (arm64) | Phase C (found while doing B114) |
| B119 | S3 | `scripts` (`monitor_tty_smoke.py`) | `scripts/monitor_tty_smoke.py` (the startup check) | The PTY harness polls the monitor only once, so a crash after the drain window but before the first frame is still reported as a timeout | test | DONE | node1 (arm64) | Phase C (found while verifying B106) |
| B120 | S3 | `WebSearchCore` / `Fetch` (`DirectHTTPFetcher`) | `DirectHTTPFetcher.swift` (cross-scheme refusal) | Only the file-system transport codes are mapped, so a redirect to any other cross-scheme target still surfaces as an opaque transport reason | incomplete | DONE | node1 (arm64) | Phase C (residual B102 left) |
| B121 | S3 | `WebSearchCore` / `Providers` (`HTTPStatusMapper`) | `HTTPStatusMapper.swift` (`unsupportedRequest`) | `HTTPError.invalidURL`'s detail is interpolated verbatim into the caller-facing message, so a URL-shaped detail would be echoed with any key in it | unsafe | START | node1 (arm64) | Phase C (surfaced by B96) |

---

## Phase D — how the folded findings are recorded

Phase B ran five audit passes (L0+L7 layering/deployment/docs, L1+L2 API contracts and
reliability, L3+placeholders logic and dead code, L4+L5 security and performance, L6 tests).
Each pass wrote `findings/<pass>.md` with one record per finding: severity, unit, file:line,
category, evidence, expected-correct behaviour, reproduction and confidence. **121 raw findings
in total.**

Folding them into this ledger:

* **Ids.** `B01`-`B101`, assigned by severity and then by discovery order, so the fix order for
  Phase C is readable straight off the table.
* **Merges.** 17 raw findings are one root cause with one fix and are recorded once; the
  `discovered-by` column names every raw id that fed the task, and the `notes` field in
  `ledger.json` points at the raw record in the pass file. Examples: `B01` is
  `PLACEHOLDER-3` + `L7-10`; `B06` is `L4-1` + `L3-3` (two `Double`→`Int` conversions that trap);
  `B03` is `L3-25` + `L7-3`.
* **Already closed.** `PLACEHOLDER-1` (temporary `AUDITDiagnosticsTests.swift`) was deleted by
  A01's commit `199a962`; it is recorded as `B05`/DONE with that commit rather than dropped, so
  the enumeration stays complete.
* **Detail stays in the pass files.** The ledger table is the enumeration and the tracker; the
  full evidence, expected-correct behaviour and reproduction commands live in
  `findings/<pass>.md` under the raw id, which keeps the ledger maintainable at 113 tasks. A
  task is closed here only with its own before/after evidence, as A01 was.
* **Overlap with the A-series.** Several folded findings are concrete instances of an earlier
  task: `B01` is the env-var contract failure A12 describes, `B05` came out of A01, and the
  `A02`/`A03` style sweep is the same territory as several `L3` records. Where that is the case
  the note says so; the tasks are still tracked separately because their fixes are separate.
* **Scope of a task cannot be narrowed to close it**, and `BLOCKED` requires a named owner; both
  apply to the folded tasks exactly as to the A-series.

### B109-B115 — found while verifying the handover (this session)

The session that resumed this audit on the second machine re-read the tree before touching it,
the same way Phase B did, and enumerated seven further findings that were not in the five passes.
They use the same record shape and are folded here rather than kept in a side note:

| id | pass | what the re-read checked |
| --- | --- | --- |
| B109 | L2 | `RankFusion`'s discount decision against the comment that documents it |
| B110, B111, B112 | L1 | the four tool schemas against each other and against the stated strict-mode rules |
| B113 | L7 | startup ordering: configuration versus `argv` |
| B114 | L7 | the operator-facing `usage` text against the parser it describes |
| B115 | L7 | `README.md`'s claims against the adapter registration predicates |

Full before/expected-correct records are in `ledger.json` (`raw_file` names this re-read). No raw
pass file exists for these seven, because the re-read wrote its findings straight into the ledger;
`raw_id` is `H1`-`H7` so the provenance is still traceable.

## B100 — `ToolOutputFormatter`'s fallback and diagnostic branches were untested

**Severity S3** · **category** test · **status** DONE · **host** node1 (arm64)

**Premise open, one branch unreachable.** `ToolOutputFormatter` lives in the executable target, which `WebSearchCoreTests` cannot import, so the only coverage was the happy-path two-result rendering and the structured status payload. But `searchText`'s `if response.results.isEmpty { "No results." }` cannot run through the server: `SearchOrchestrator.search` throws before constructing a response when `fuse` yields nothing, `SearchResponse` has exactly one construction site after that guard, and `SearchCache.store` refuses a response without usable results. The record's requested `{"results":[]}` search is a tool error instead, and that is what the test pins.

**What was added.** A new `ToolOutputFormatterTests.swift` (four tests) reaching the formatter over a real stdio session against a `LoopbackServer`, in a new file because `StdioServerTests.swift` is at 1327 of SwiftLint's 1458 lines. It pins: the all-empty search being a tool error that never renders "No results."; a 500-character body clipped to a 401-character snippet line (400 + ellipsis) whose kept text is a prefix of the source; an "Unavailable providers: open_web_search" line when only one of two providers answers; and a status line whose `requests=`/`failed=` counters parse non-zero with a "last error:" line.

**Two corrections the run forced.** `fast` mode selects one provider, so the partial-failure case needs `balanced` (two direct providers); and a second stub response is a race because the fan-out is concurrent, so the failing provider is pointed at a listener that has been released. The status test also parses the counters rather than substring-matching `failed=`, which would pass at `failed=0`.

**Falsification.** M1 raised the snippet budget to 1000; M2 renamed the text renderer's unavailable-provider label; M3 renamed the last-error label. Each relinked `SwiftWebSearchMCP` (`--build-tests`) and produced 5 assertion failures across the four tests. `ToolSchemas.swift` restored byte-identical (`diff` empty, SHA-256 verified); no production code changed.

Gate: 583 tests / 6 skipped / 0 failures; debug and release 0 warnings; swift-format 0; swiftlint 0 in 90 files; notices clean. Evidence: `AUDIT/evidence/B100-tool-output-formatter.txt`.

## B99 — no test tied the Swift harnesses to the Python harnesses, and two scripts were untested

**Severity S3** · **category** test · **status** DONE · **host** node1 (arm64)

**Premise open, one clause stale.** The 18-entry scrub list really was duplicated by hand and unenforced in both directions, and `searxng_health.py` had no test at all. `soak.py` had more coverage than recorded: CI already drives `build_environment`, `silent_providers` and `run_verdict` (B23/B44 guards); only `main`'s argument handling, `parse_dotenv`, `load_secret_values` and `find_credential_leaks` were uncovered.

**What was chosen.** One new module, `scripts/harness_tests.py`, with 16 stdlib `unittest` tests: the cross-language scrub-list equality (reading the Swift literal from `TestSupport.swift` and the tuple from `mcp_smoke.py`, failing with the diff in each direction), seven `searxng_health.py` cases against a real loopback `ThreadingHTTPServer` (healthy, 403 JSON-disabled, empty results, non-JSON 200, closed port, `file://` refusal, human report), and seven `soak.py` cases (`--help`, the B82 non-positive `--queries` guard, missing binary, dotenv, leak scan, config-file secrets). A single CI step runs it in `static-analysis`.

**Why that option.** The alternative `soak.py --queries 1` CI invocation needs the release binary and a reusable SearXNG stub that does not exist outside `monitor_tty_smoke.py`, and would still not exercise soak.py's own parsing and leak scan. The module lives in `scripts/` rather than a new `tests/` so it is covered by the existing ruff and pyright gates with no scope change.

**Falsification.** One entry deleted from each scrub list (`SEARCH_PROVIDER_ORDER` from Swift, `DEEPSEEK_MODEL` from Python) turned the equality red with the "names variables scripts/mcp_smoke.py does not scrub" message; a first attempt deleting only from Python produced the other message. Both files restored byte-identical (`diff` empty, SHA-256 verified).

**Left open.** The record's third clause — driving both built executables against one stub and comparing their reports — is a different contract and is not addressed; the artifact says so rather than implying it was closed.

Gate: 579 Swift tests / 6 skipped / 0 failures; debug and release 0 warnings; swift-format 0; swiftlint 0 in 89 files; ruff and pyright clean; notices clean; 16 Python harness tests OK. Evidence: `AUDIT/evidence/B99-harness-tie.txt`.

## B98 — the `Monitor` actor's refresh/counting/warning logic had no Swift test

**Severity S3** · **category** test · **status** DONE · **host** node1 (arm64)

**Premise open, one clause wrong.** Only `Options.parse`/`exitCode` and the renderer plus `NodeStatus`/`ProviderStatus.applying` in isolation were covered; the actor's `refresh`, `buildWarnings` and `waitForNextCycle` were not, and no commit mentions B98. But the record's "with a stub HTTPClient" was not reachable: `Monitor.init(options:)` built its own `URLSessionHTTPClient` and `Log(level: .none)` from this machine's environment, and nothing accepted a client.

**Production change, stated plainly.** A test-only internal `init(options:configuration:http:log:)` was added and `init(options:)` now delegates to it unchanged. The two stored properties widened to `any HTTPClient`/`Log`. That is the whole source diff; production construction is identical (same client, same 8 s probe timeout, same disabled log, same registry).

**What was added.** `Tests/MCPSMonitorTests/MonitorActorTests.swift` with nine tests and two local stubs (a URL-keyed `StubHTTPClient`, plus a `FailingEndpointClient` that fails one node endpoint). They pin the first-refresh probe and the no-second-credit gate, the forced probe, an empty node list, `.up`/`.degraded` folding into checks/failures, accumulation across refreshes, the down-node + fleet-engine + missing-credential warnings with the `max(2, nodes/2)` threshold, that one node's failing engine is below it, and `waitForNextCycle` returning early on `requestRefresh()` but otherwise honouring a short interval.

**Falsification.** M1 set `hasProbedBefore: true` so nothing is probed; M2 deleted the `else { failures += 1 }` arm of `NodeStatus.applying`; M3 raised the engine-warning threshold to 999. Each built and run under `--filter MonitorActorTests`, producing 10 failures across the nine tests. Both files restored byte-identical (`diff` empty, SHA-256 unchanged).

Gate: 579 tests / 6 skipped / 0 failures; debug and release 0 warnings; swift-format 0; swiftlint 0 in 89 files; notices clean. Evidence: `AUDIT/evidence/B98-monitor-actor.txt`.

## B97 — `AnswerSynthesizer`'s completion edge cases, token usage and locale prompt were untested

**Severity S3** · **category** test · **status** DONE · **host** node1 (arm64)

**Premise confirmed open.** The four named branches had no coverage: no test sends `{"choices":[]}`; `completion.inputTokens`/`outputTokens` are decoded on every response and never asserted; every `synthesize` call omits `locale:`; and `describe(_:)` was never called because no mock throws `URLError` or `CancellationError`. B70/B71/B93–B96/B54/B76/B79 did not touch this file, and no commit mentions B97.

**What was added.** Eight tests in the existing `AnswerSynthesizerTests.swift` (646 -> 772 lines, under the ceiling, so no split) plus a private `userTurn(in:)` decoding helper. They pin: a 200 with an empty `choices` array -> `synthesisFailed` naming "no choices"; `answer.inputTokens == 100` / `outputTokens == 20`; `locale: "de-DE"` -> "Answer in the language implied by locale de-DE." in the user turn, with `nil`/`""` adding nothing; the full `describe` table (timeout, cancelled, five unreachable codes, generic); and a thrown `CancellationError` surfacing as a cancelled request. Production code unchanged — the injectable `HTTPClient` seam already existed.

**Falsification.** Four one-line production mutations, each built and run under `--filter AnswerSynthesizerTests` after a `touch`: "no choices" -> "no completions"; `!locale.isEmpty` dropped; `promptTokens` -> `completionTokens`; `.timedOut` -> "gave up". Each produced exactly the matching assertion failure (35 tests, 4 failures combined). `AnswerSynthesizer.swift` restored byte-identical (`diff` empty, SHA-256 `0c756413edfc7bc313cda8cb8f43fbd5f363c26eeceedee1f5daaca0790117b6`).

Gate: 570 tests / 6 skipped / 0 failures; debug and release 0 warnings; swift-format 0; swiftlint 0 in 88 files; notices clean. Evidence: `AUDIT/evidence/B97-answer-synthesizer-edges.txt`.

## B96 — the status mapper's `HTTPError` arms and `validate`'s default/422 paths were untested

**Severity S3** · **category** test · **status** DONE · **host** node1 (arm64)

**Premise confirmed open.** `HTTPStatusMapper.map` had exactly one direct test, which passed a
`URLError`, so no `HTTPError` arm was verified; `validate` was covered for 401/403/429/400/503/200
only — no 422 and no unmapped status. B17 and the recent provider work had not added coverage.

**What was added.** A new `HTTPStatusMapperTests.swift` owns the status/transport contract, and
`testHTTPStatusMapperClassifiesCorrectly` moved into it unchanged. `ProviderContractTests` was at
SwiftLint's 1458-line `file_length` ceiling, so growing it was not possible; the move takes it to
1421 lines and the file count 87 -> 88. Eleven tests pin: the status table including 422, 404, 418
and 301; the success range; `Retry-After`; vendor-specific status sets; all six `HTTPError` arms;
the `SearchError` passthrough; explicit cancellation; curated `URLError` reasons; the generic
fallback; and that the transport-produced descriptions carry no URL.

**Two measurements corrected the test, not the code.** `.cannotConnectToHost` is curated as
`could not connect to the host` (not `the host could not be resolved`), and 204 is inside
`HTTPResponse.isSuccess`'s `200..<300`, so it passes `validate` rather than taking the default arm.

**A finding surfaced.** `HTTPError.invalidURL(detail)` is interpolated verbatim into
`SearchError.unsupportedRequest(provider, detail)` and rendered as `"<Provider> cannot serve this
request: <detail>"`, so a URL-shaped detail would be echoed, key included. `git grep` finds no
production call site that throws `invalidURL` — the case is dormant — so this is not an active leak,
but the first draft of the URL-hygiene test asserted it was safe, which was wrong. The test now
covers the three descriptions the transports actually produce and both the artifact and the test
file record the hazard for whichever task owns `HTTPError`'s construction.

**Falsification.** M1 removes 422 from `case 400, 422` and makes the `default` arm throw
`providerUnavailable`: 5 assertion failures. M2 disables the whole `HTTPError` switch so every case
falls through to the generic network failure: all six table rows red with the generic description.
`HTTPStatusMapper.swift` restored byte-identical (`diff` empty, SHA-256
`663b23ca4fabf914917f7eb17f2d50d30c280963d645fc682e6a5a019c9be6dc`).

Gate: 564 tests / 6 skipped / 0 failures; debug and release 0 warnings; swift-format 0;
swiftlint 0 in 88 files; notices clean. Evidence: `AUDIT/evidence/B96-http-status-mapper.txt`.

## B95 — the monitor's setup-hint test asserted a string it had constructed itself

**Severity S3** · **category** test · **status** DONE · **host** node1 (arm64)

**Premise confirmed open after B57.** B57 replaced the five hand-written enablement mappings with
`ProviderEnablement` and rewired `ProviderProbe.setupHint`, and `ProbeTests` pins that mapping
per provider. It did not touch `MonitorTests.swift`, where `RendererTests.provider(_:state:…)` still
handed `hint: "TAVILY_API_KEY"` to every provider and `testUnconfiguredProviderShowsItsSetupHint`
asserted that literal on a Brave row: the test verified only that the renderer echoed the string the
test had written. A renderer printing a constant would have passed.

**What changed.** A `setupHint(for:)` helper builds the same `ProviderProbe(registry:configuration:)`
the monitor builds and returns `setupHint(for:)`, so every fixture row carries the real authority's
value. The test asserts that the authority's Brave hint is `BRAVE_SEARCH_API_KEY`, that it differs
from Tavily's, that the rendered row contains `set <that hint>`, and that it does not contain
Tavily's variable. No production change; `ProbeTests` still owns the authority's own table, so this
does not duplicate it.

**Falsification.** M1 reverts the fixture to its old hard-coded `"TAVILY_API_KEY"` and keeps the new
test: it reds on both halves (`XCTAssertTrue failed - the row must show the hint the fixture
carried` and `XCTAssertFalse failed - the renderer must not substitute a different provider's
variable`), which is precisely the state the old body passed. M2 mutates `Renderer.swift` to print
`set TAVILY_API_KEY` unconditionally; the test reds on both halves again. `MonitorTests.swift` and
`Renderer.swift` were restored byte-identical (`diff` empty; SHA-256
`18cf98cbba7a2188a819ff890c1c4379cfdc0def9bc64daf1d7e0bea07b8190e` and
`7853eb6b36ec565c257872c06e91ee84bcc00a7cb727b2b7a9defe840b46eb88`).

Gate: 554 tests / 6 skipped / 0 failures; debug and release 0 warnings; swift-format 0;
swiftlint 0; notices clean. Evidence: `AUDIT/evidence/B95-monitor-hint-authority.txt`.

## B94 — `testStatusCountsSuccessesAndFailures` never observed a failure

**Severity S3** · **category** test · **status** DONE · **host** node1 (arm64)

**Premise confirmed open.** The test had moved to `SearchOrchestratorTests.swift:862` (the ledger
said 716) but its shape was unchanged: it searched in `fast` mode, which selects exactly one
provider, so `brave` was never called and `XCTAssertEqual(brave?.failures, 0)` held whether or not
`ProviderHealth.recordFailure` incremented anything. Nothing else observed a failure through
`status()`.

**Current behaviour, measured before asserting.** Two assertions came from running the changed test
rather than reading the code. The failed provider's message is `Brave Search is temporarily
unavailable.` — the first run failed on the shorter string I had written, and the assertion was
corrected to the code's own output rather than the message changed to match the test. And a single
failure leaves the breaker closed, so `brave?.status` is `.ready`, not `.circuitOpen`.

**The test.** A `balanced` search with order `[.tavily, .brave]` now asserts that both providers
were spent (`callCount == 1` each), that the caller sees `providersUsed == [.tavily]` and
`providersFailed == [.brave]`, that `tavily` has one success and no failures, and that `brave` has
one failure, zero successes, `.serverError`, its message and a `lastFailureAt`, with both states
`.ready` and `totalRequests == 1`.

**Falsification.** M1 deletes `counter.failures += 1` from `ProviderHealth.recordFailure`; the test
reds with `("Optional(0)") is not equal to ("Optional(1)")`. M2 makes `ProviderHealth.state`
report `lastErrorCategory: nil`; the test reds with `("nil") is not equal to
(...FailureCategory.serverError)`. The old `fast`-based body would have passed M1, which is the
finding. `ProviderHealth.swift` was restored byte-identical (`diff` empty, SHA-256
`e7cc22dd68604a4e884d5e2cb6549ce649b7933d342c4e774c41658571bdd5f0`).

Gate: 554 tests / 6 skipped / 0 failures; debug and release 0 warnings; swift-format 0;
swiftlint 0; notices clean. Evidence: `AUDIT/evidence/B94-status-counts-failure.txt`.

## B93 — the `MarkupDepth` suite's four open branches are pinned

**Severity S3** · **category** test · **status** DONE · **host** node1 (arm64)

**Premise confirmed open.** `markupDepthExceeded` appeared in tests only in the three pre-existing
case-value assertions in `MarkupDepthTests.swift`, and no other test file touched `MarkupDepth` or
exceedsLimit`. All four gaps the finding names — `skipRawText`'s unterminated return, the
`Array(html.utf8)[...]` path, the error's category/description projection, and the `web_open`
end-to-end contract — were unexercised.

**What was added.** Five test methods, no production change. Two pin the unterminated raw-text
branch (an unclosed `<script>` full of 20 000 `<div>`s must be accepted because the markup is raw
text; a document at exactly the limit followed by an unclosed `<style>` full of markup must also be
accepted). One pins `scan` over an `ArraySlice` with a non-zero `startIndex`. One pins
`category == .malformedResponse`, `provider == nil`, the exact `safeDescription` and that the limit
is carried through. One drives a real stdio session against a loopback page nested 20 000 deep and
requires `isError == true` plus the model-visible sentence.

**Falsification, one mutation per assertion.** M1 (`skipRawText` unterminated `return end` ->
`return start`) reds both unterminated tests. M2 (`case .markupDepthExceeded: .unknown`) reds only
the projection test. M3 raises the limit to 10 000 and relinks the product so the spawned server
carries it; the e2e test reds with `The markup nests more than 10000 elements deep`. M3's first
value (100 000) knocked the runner over with `Bus error: 10`, which is the A01 failure mode the
guard exists to prevent. Two mechanical traps are recorded in the artifact because they nearly
produced a false proof: a source-only edit within the same second is not recompiled without a
touch, and the spawned product must be relinked separately or the e2e test talks to the old
server.

**Restoration.** All mutated files restored byte-identical (`diff` empty; SHA-256
`aed19c05…c547`, `3f7f6841…2e42`, `395cb2d6…09e3e6`).

**Stated limitation.** The `withContiguousStorageIfAvailable` fallback cannot be reached from a
test on this platform — a native `String` hands out contiguous UTF-8 however it is built — so the
second assertion pins the slice semantics that fallback depends on rather than executing the
fallback itself.

Gate: 554 tests / 6 skipped / 0 failures; debug and release 0 warnings; swift-format 0;
swiftlint 0; notices clean. Evidence: `AUDIT/evidence/B93-markupdepth-branches.txt`.

## B71 — three copies of the subprocess harness, already diverged

**Severity S3** · **category** test · **status** DONE · **host** node1 (arm64)

**Premise confirmed.** `StdioServerTests.ServerProcess`, `ErrorReportingTests.Server` and
`SchemaCompatibilityTests.Server` were three copies of one process + pipe + newline-JSON harness.
The `SchemaCompatibilityTests` copy had drifted furthest: `enum Failure { case timeout,
unexpectedExit }` dropped the stderr payload, and the `Pipe()` assigned to `standardError` was
never read, so an early exit reported bare `unexpectedExit`. The shared environment scrub list had
been factored out earlier; the framing, deadline and stderr capture had not.

**What changed.** `ServerProcess` in `TestSupport.swift` is the one harness, with the scrub list,
`childEnvironment`, the B70 `poll` deadline, `send`/`readMessage`/`readResponse`, the
`call(id:tool:arguments:)` convenience only one copy had, and a background readability handler
that accumulates stderr for the life of the harness. Both other files now declare
`private typealias Server = ServerProcess`. No production code changed and no call site changed
spelling. 150 lines deleted, 96 added.

**Equivalence shown, not asserted.** A detached worktree at the previous commit was built with
its own scratch path; the same three test classes were run in both trees through the same runner.
The `Test Case … passed/failed/skipped` lines, stripped of timing and sorted, form manifests that
are byte-identical (`diff` exit 0; 46 tests each, 0 failures). The one case where the copies
differed was probed separately: a child that exits without answering (`/usr/bin/true`) yields
`unexpectedExit` from the old `SchemaCompatibilityTests` harness and `server exited early; stderr:`
from the consolidated one. The probe was removed and the file restored byte-identical (`diff`
empty, SHA-256 `7493e9ef89e6ff04856dba3a9c51e785ec37b2134b15a683898a9eec9495b53f`).

**A hang found during the refactor.** The first stderr-capture version waited unbounded for EOF;
`StdioServerTests` inspects stderr while the child is still running, so the class hung — the same
failure mode B70 removes. The wait is now bounded at two seconds. Recorded because a "pure
refactor" claim would otherwise have hidden it.

Gate: 549 tests / 6 skipped / 0 failures; debug and release 0 warnings; swift-format 0;
swiftlint 0; notices clean. Evidence: `AUDIT/evidence/B71-one-subprocess-harness.txt`.

## B70 — the subprocess harness "timeout" could not fire

**Severity S3** · **category** test · **status** DONE · **host** node1 (arm64)

**Premise confirmed, not stale.** All three stdio harnesses read with
`while Date() < deadline { … FileHandle.availableData }`. `availableData` blocks until data
arrives or the pipe reaches EOF, and the child holds the write end open, so the deadline test
could only run after a read returned — the one thing a wedged server never allows. The 15 s and
20 s bounds were never enforced.

**What changed.** The shared harness (introduced here, in `TestSupport.swift`, because B71 folds
the other two copies into it next) waits in `poll(2)` on the stdout descriptor for exactly the
time remaining before each read, so expiry fires while the child is alive and silent. A complete
line already buffered is served before the deadline is consulted, so an answer that arrived on
the previous read is never discarded; `poll` restarts on `EINTR` with the recomputed remainder so
a signal cannot extend the bound; and `readResponse` now carries one deadline across the
notifications it skips instead of passing a 0.1 s floor to each read. The harness also owns a
shared stderr buffer, which is what lets the two `StdioServerTests` assertions stop reaching into
the pipe directly.

**Falsification.** The new `testHarnessDeadlinePreemptsABlockedRead` runs `/bin/sh -c "printf
'partial line with no newline'; sleep 60"` — a child that has *some* output pending but no
complete line, so a poll-less read parks in `availableData` — and requires
`readResponse(id: 1, timeout: 0.3)` to throw the timeout. With the pre-fix blocking read restored
the test hangs: `xcrun xctest` printed `Test Case … started.` and was killed 30 s later (exit
124). `TestSupport.swift` was restored byte-identical (`diff` empty; SHA-256
`ac98f22dd6f7750902351f7dcf99f6d773138bb9eea46150c8433245fe314d05`).

**No production change.** The defect is in the test harness, and the ledger item is category
`test`; `Sources/` is untouched.

**Sequencing note.** `ErrorReportingTests` and `SchemaCompatibilityTests` still hold their own
copies of the broken loop at this commit. B71 is the next task and routes both through this
harness, so the enforced deadline lands on all three rather than one.

Gate: 549 tests / 6 skipped / 0 failures; debug and release 0 warnings; swift-format 0;
swiftlint 0; notices clean. Evidence: `AUDIT/evidence/B70-harness-deadline.txt`.

## B79 — a request head could allocate 1 MiB per connection

**Severity S3** · **category** unsafe · **status** DONE · **host** node1 (arm64)

**Premise holds.** At HEAD `HTTPMCPHandler.channelRead`'s `.head` branch called `bodyBuffer.reserveCapacity(min(contentLength ?? 4096, 1 << 20))`. The header is peer-written, a fresh `ByteBuffer()` has capacity 0, and the pinned swift-nio (`NIOCore/ByteBuffer-core.swift:755`) reallocates whenever the request exceeds the current capacity — so a client sending only a head with `Content-Length: 1048576` allocated a megabyte per connection. The cap (`maximumBodyBytes`) was checked only in `.body`, after bytes arrived. Composed with B90's `maximumConnections = 64`, the ceiling was 64 MiB from a peer that sent no body; the default loopback bind confines the peer, the opt-in non-loopback bind does not.

**Measured, and why the test pins the decision.** A probe of 64 loopback head-only connections declaring 1 MiB against the defective binary grew RSS by only ~1.9 MiB (control: ~0.6 MiB for `Content-Length: 1`) and left `ps`'s virtual-size field flat: macOS maps the 1 MiB allocations and `reserveCapacity` never touches the pages. The premise is therefore confirmed against the dependency's implementation and the call site rather than by an RSS delta, and the regression test asserts the reservation decision, not the allocator.

**Fix.** New `HTTPRequestBodyPolicy` in WebSearchCore (beside `HTTPTransportConfiguration`): `initialCapacity = 4096`, `maximumBodyBytes = 1 << 20`, and `reservationCapacity(declaredContentLength:)` returning the constant while keeping the parameter so the decision is visible. The handler reserves that fixed capacity, `writeBuffer` grows the buffer as body parts arrive, and the cap stays the enforcement point in `.body`. `HTTPMCPHandler.maximumBodyBytes` is gone, so the cap is named once.

**Falsification.** Reverting `reservationCapacity` to `min(declared ?? 4096, maximumBodyBytes)` reddens `testReservationIgnoresTheDeclaredContentLength` with `("1048576") is not equal to ("4096")` for both the 1 MiB and `Int.max` declarations. Restored byte-identical (`diff` empty, SHA-256 `9799cac4…`). `testReservationIsFarBelowTheBodyCap` additionally holds the constant below 64 KiB and 64 connections below 4 MiB.

**Noted.** The constants live in `WebSearchCore` because `HTTPMCPHandler` is private to the executable target, which the test target cannot import (the limitation `HTTPTransportTests` already documents); a private constant would have no falsifiable test. No handler behaviour for an accepted request changed.

## B76 — the monitor was labelling and probing disabled providers

**Severity S3** · **category** logic · **status** DONE · **host** node1 (arm64)

**Premise holds.** `ProviderRegistry.isEnabled` (the `SEARCH_DISABLED_PROVIDERS` map) was consulted only by `isEligible`; `ProviderProbe.isConfigured` delegated to `isConfigured`, `Monitor.refresh` filtered the probe set on it, `ProviderProbe.probe` guarded only on the adapter's `isConfigured`, and `Monitor.init` built every status at `.configuredButIdle`/`.notConfigured`. A provider the server refuses to use was therefore shown as ready, listed for probing, and sent a real search on the first pass or `--probe`.

**`.unavailable` is back, with a producer.** B78 deleted the case because nothing produced it and recorded that B76 owns the producer. `ProviderStatus.pending(provider:configured:enabled:hint:)` (new `enabled:` parameter, default `true`) starts at `.unavailable` when `enabled` is false, ahead of a missing credential — the two reasons a provider is inert are distinct. `isInService` fails for both `notConfigured` and `unavailable`, which is what `Options.exitCode` now uses, so an all-disabled set is not an unhealthy fleet.

**The probe set.** `ProviderProbe.mayProbe` is `isEnabled && isConfigured`, `probeableTargets()` is the display order filtered by it, `Monitor.refresh` calls it, and `probe` refuses a disabled provider before touching the adapter, so a direct call cannot spend a credit either.

**The display.** `Renderer` gained the `◐`/bright-yellow `OFF` row, the note `disabled via SEARCH_DISABLED_PROVIDERS`, and a `N disabled` summary term that appears only when non-zero (so ordinary frames are unchanged).

**Falsification.** M1 reverts `mayProbe`/the `probe` guard and reddens the two `ProviderProbe` tests (the disabled provider re-enters the probe set and `callCount` becomes 1) with 7 failures. M2 makes `pending` ignore `enabled` and reddens the model and renderer tests with 8 failures, including `("IDLE") is not equal to ("OFF")`. Both files restored byte-identical (`diff` empty; SHA-256 `70896d61…`, `bbb6c058…`).

**Measured.** `SEARCH_DISABLED_PROVIDERS=searxng` with a usable-looking SearXNG endpoint: the frame renders `◐ SearXNG aggregator OFF … disabled via SEARCH_DISABLED_PROVIDERS` and `1 disabled` in the summary, exit 0.

**Noted.** `ProviderStatus.isConfigured` still means "state is not `.notConfigured`" and is true for a disabled provider that holds its inputs; nothing depends on it for the disabled case, and `isInService` is the predicate callers should use. The Monitor actor still has no direct unit test (B98); the changed wiring is the one call to the tested `probeableTargets()`.

## B58 — the discovery parser is shared, not copied

**Severity S3** · **category** style · **status** DONE · **host** node1 (arm64)

**Premise: half stale.** The parser duplication was real — `git show HEAD:…/ToolHandlers.swift | grep -c 'requiredString("query")'` was 2, and the two blocks were byte-identical. The schema-drift half was **already fixed by B110** (`a3bf795`): `provider` is one `providerDiscoverySchema` derived from `ProviderID.allCases` for both tools, and `SchemaCompatibilityTests.violations` compares `web_answer.inputSchema` with `web_search`'s declared key set and every value-constraining keyword, holding `provider` to the whole property. That lint is green at HEAD, so no schema constraint remains drifted. B110's own record named B58's residual: `testDefaultsAreDocumentedInDescriptions` read `web_search` only, and the parity walk exempts `description`.

**What changed.** `ToolHandlers` gained an internal `DiscoveryArguments` value (which builds the `SearchRequest`) and one `parseDiscoveryArguments(_:) -> Result<DiscoveryArguments, DiscoveryError>` covering the clamp, the enum parses, the array bounds, the locale parse and the provider/auto resolution. Both handlers start with the same three-line switch, so the parse-error path is one path. No public signature changed.

**Schemas untouched on purpose.** B110's lint is the mechanism the guidance asked to extend, and the differing prose is legitimate (`web_search` returns results; `web_answer` grounds an answer in them), so unifying the literals would have forced one tool to describe the other's behaviour. Instead the behavioural parity is pinned at the stdio boundary: `testTheTwoSearchToolsParseTheirSharedArgumentsIdentically` rejects the same value for all seven shared arguments in both tools and requires identical text.

**Falsification.** M1 points `web_answer` at a divergent wrapper (a second parse path, the shape of the defect) and reddens the parity test with 7 failures naming each argument. M2 drops `, default 8` from `web_answer.max_results` and reddens the extended defaults test, which the pre-B58 web_search-only assertion could not see. Both files restored byte-identical (`diff` empty; SHA-256 `c846dd21…` and `e62e9262…`).

**Noted.** The ledger's expected-correct said to constrain both schemas identically for `provider`; that was B110's work. No further schema change was made.

## B57 — one authority for provider enablement, and the `parallel` hint

**Severity S3** · **category** logic · **status** DONE · **host** node1 (arm64)

**Premise holds, and the duplication was worse than reported.** "Which variable enables me" was written out in five places at HEAD: `SearchPipelineFactory` notes (`:61-127`), `ProviderRegistry.ineligibleReasons` (`:67-69`) and its two `select` messages (`:114,120`), `ToolHandlers.unconfiguredHint` (`:396-403`), `ProviderProbe.setupHint` (`:52-59`) and the server's startup inventory (`main.swift:80-92`). `parallel` is the provider with two inputs: emptying `PARALLEL_MCP_URL` makes `AppConfiguration.parse` set it to nil and the factory register no adapter, so `.notConfigured(.parallel)` fires while `SEARCH_ENABLE_PARALLEL` may be true — and both hint copies then named the flag.

**Consolidation.** New `Sources/WebSearchCore/Support/ProviderEnablement.swift`: `Input` cases whose `variableName` comes from `AppConfiguration.Key`, an exhaustive `inputs(for:)`, `AppConfiguration.satisfies(_:)` as the only configuration read, and `missingInputs`/`inputsToName`/`isSatisfied`/`instruction`/`assignmentList`/`allInputs`. Every surface listed above now calls it; the status tool's note for a provider with no adapter is the actionable instruction rather than `no adapter registered`, which is what makes the status tool and the tool error agree. No public signature changed; `ProviderProbe.setupHint(for:)` is now configuration-dependent, as naming the right `parallel` input requires.

**Behaviour.** `inputs(for: .parallel)` is `[.parallelEnabled, .parallelEndpoint]`, so: flag off + URL present → `Set SEARCH_ENABLE_PARALLEL=true …`; flag on + URL absent → `Set PARALLEL_MCP_URL …`; both absent → both, flag first. The SearXNG JSON guidance and the scraper/Parallel phrasing are preserved by per-input `purpose` clauses.

**Falsification.** M1 reverts `inputs(for: .parallel)` to the flag only, which makes the strings literally the ones the finding quotes, and reddens 15 assertions across the nine tests including the stdio end-to-end case. M2 reverts the no-provider message to its hard-coded pair and reddens the strengthened assertion with `omits BRAVE_SEARCH_API_KEY`, `omits SEARCH_ENABLE_SCRAPERS=true`, `omits PARALLEL_MCP_URL`. Both files restored byte-identical (`diff` empty; SHA-256 `f3618e0e…` and `eee1ee0a…`).

**Noted.** SwiftLint's `function_body_length` fired once on `SearchOrchestrator.search` while developing; the shared list moved into `ProviderEnablement.allInputs`, which the startup inventory also uses now. The literal change covers five call sites rather than the three named, because the registry reasons and the no-provider error are operator-facing copies of the same contract.

## B46 — `mcps-mon` exits 0 even when the whole fleet is down

**Severity S3** · **category** incomplete · **status** DONE · **host** node1 (arm64)

**The premise holds.** `grep -rn "exit(" Sources/MCPSMonitor/` found only `--help` (0) and the parse error (2); the refresh loop ended at the bottom of `main.swift` with no `exit` call, so the C runtime returned 0 whatever the probes found, and no `audit(B46)` commit existed anywhere on the branch. The sibling `scripts/searxng_health.py` already documents 0/1/2, which is the precedent the usage text now follows.

**The contract, stated explicitly.** 0 — the fleet answered: at least one probed node returned results and, when any provider was configured, at least one was healthy (a run that checked nothing, or did not finish a refresh, also reports 0). 1 — every probed node failed to return results, or every configured provider failed; a `degraded` node counts as failed because it cannot serve a search either. 2 — invalid arguments, unchanged. This is a deliberate behaviour change: a script that pipes a frame or runs `--iterations n` now sees 1 when the whole fleet is down, which is exactly the signal the task exists to provide; `--exit-zero` is the opt-out the expected-correct asks for. The signal path keeps its deliberate `_exit(0)` — a supervisor's `kill` is a clean stop, not a health verdict.

**What changed.** `Options.exitZero` and `Options.exitCode(for:)`, a `--exit-zero` parse case, an `EXIT STATUS` section plus the flag in `Options.usage`, and one `exit(options.exitCode(for: lastModel))` after the final summary. No public signature changed; `Options` is internal to the executable target.

**Falsification.** Replacing `exitCode`'s body with `return 0` — the original behaviour — reddens `testExitStatusIsNonZeroWhenEveryNodeIsDown`, `testExitStatusCountsDegradedNodesAsFailed`, `testExitStatusIsNonZeroWhenEveryConfiguredProviderFails` and `testExitZeroForcesSuccessForAGraphicalRun` with `("0") is not equal to ("1")`. The file was restored byte-identical (`diff` empty, SHA-256 `e832d6c1…`).

**Measured on the process.** Against a refused loopback port with no provider key: default `--iterations 1` exits 1, `--exit-zero` exits 0, `--no-nodes` exits 0. `scripts/monitor_tty_smoke.py` (healthy stub) still observes exit 0 on `q`, Ctrl-C, SIGINT and SIGTERM.

**Noted.** `exitCode` filters on `state != .notConfigured`; B76's operator-disabled case must extend that filter when it introduces the case, or a fully disabled fleet would report 1. Recorded there in the task's evidence.

## B120 — the cross-scheme refusal is already classified by scheme, not by transport code

**Severity S3** · **category** incomplete · **status** DONE · **host** node1 (arm64)

**The premise is wrong.** B120 claims that after B102, a redirect to `ftp:`, `data:` or any scheme
`URLSession` refuses beneath the policy still surfaces as `the transport rejected the request URL`.
Measured here, `URLSession` consults `willPerformHTTPRedirection` for **every scheme except
`file:`**: of seventeen targets tried (sixteen non-file, including `ftp:`, `data:`, `gopher:`, `ws:`,
`mailto:`, `ssh:`, `blob:`, `tel:` and private-use schemes), only the `file:` family bypasses the
delegate. Every other one hands the `302` back to `DirectHTTPFetcher`'s manual loop, which calls
`policy.validate(nextURL)`; `validateLexically` applies `allowedSchemes` first, so the hop becomes a
`blockedURL(nextURL)` naming the actual target — the scheme-keyed classification the finding asks
for, with no code needed for a new scheme. A new end-to-end test drives the real fetcher through
loopback 302s to `ftp:` and `data:` and passes against unmodified production code.

**The one opaque case cannot be classified by scheme.** `file:` is refused beneath the policy *and*
is the case where the target scheme never reaches the process: the delegate is not called,
`URLError.failingURL` and `NSErrorFailingURLStringKey` carry the original `http(s)` URL, and no
other `userInfo` payload names the target. The three file-system codes therefore stay, now
documented as the narrow exception rather than as an instance of a general cross-scheme rule.

**What changed.** Documentation on `URLPolicy`'s type doc and `DirectHTTPFetcher`'s file-code case
(the generalisation "a redirect that changes scheme is refused beneath the policy" is corrected),
the same correction in the file-URL test's doc comment, and the new
`FetchRedirectTests.testARedirectToAnUnfetchableSchemeIsRefusedByTheHopPolicy`, which asserts the
`.blockedURL` denial and its target scheme, the absence of the opaque `transport rejected` text, and
that the refused hop is never requested. No behaviour, signature or public API changed.

**Falsification.** There is no pre-fix behaviour to revert, so the mutation is the defect the
finding describes — the per-hop denial throwing
`fetchFailed(…, reason: "the transport rejected the request URL")` — and the test reddens with that
exact error (`expected a policy denial for ftp://example.com/file, got fetchFailed(…)`).
`DirectHTTPFetcher.swift` was restored byte-identical (`diff` empty, SHA-256 `3f6f6bf1…41a6cd10`).

**Deviation.** The expected-correct asked to replace the transport-code enumeration with a
scheme-keyed rule. That rule already governs every scheme that can reach the policy and cannot
exist for `file:`, whose target never reaches the process; the literal change would have required
duplicating the transport's redirect handling, the larger option B102 already rejected.

## B91 — log emission blocked the task that logged

**Severity S3** · **category** perf · **status** DONE · **host** node1 (arm64)

**What was wrong.** `Log.emit` called `standardErrorSink` synchronously, and the sink looped on
`write(2, …)` on the calling task's thread. A stdio MCP host runs with stderr on a pipe, so once
that pipe filled and its reader stopped draining, the search or fetch that logged blocked with it;
`written <= 0` also abandoned a line on `EINTR`.

**Why the bounded queue, not `O_NONBLOCK`.** The finding's first option (set fd 2 non-blocking,
drop on `EAGAIN`) has two costs it does not price in. `O_NONBLOCK` lives on the open file
description, so setting it on fd 2 changes how the Swift runtime's own diagnostics and the MCP
transport's swift-log handler behave on the same descriptor — this package would be making another
component's output lossy. And `PIPE_BUF` is 512 bytes on this host (measured), so a longer line can
be transferred partially before `EAGAIN`, truncating a diagnostic and concatenating the next one to
it; that is the one-line framing the same sentence asks to keep. The finding offers the bounded
queue as the alternative, so that is the bounded version taken.

**The fix.** `StderrQueue` is a bounded FIFO (1024 lines) between the sink and fd 2. `submit`
appends under an `NSCondition`, starts one writer thread on first use, and drops plus counts the
newest line when full, so it never blocks the caller. The writer takes lines in order and writes
each whole line with a retrying `write(2, …)`: `EINTR` is retried, partial writes continue, any
other error drops the rest of that line. After drops it emits one
`level=warning msg="dropped N log lines: the stderr consumer is not draining"` line before the next
real line. `flush(timeout:)` waits for the queue to empty and the current write to finish, and is
registered with `atexit`, so a normal exit keeps the tail; it is bounded so a stopped consumer
cannot turn shutdown into a hang. The sink still writes to fd 2 only.

**Verification.** Two tests in `LoggingTests`. `testTheDefaultSinkRoutesFramedLinesThroughTheQueue`
points the sink at a queue whose writer records, and asserts exactly `["first\n", "second\n"]`.
`testAFullQueueDropsInsteadOfBlockingTheCaller` parks an injected writer with semaphores (no timing),
holds one line, fills a `limit: 2` queue, and asserts that a fourth `submit` returns, that
`droppedLines == 1`, that the gap is reported once, and that the three real lines keep order and
framing. **Falsification.** Reverting the sink to a direct write reddens the first test (`("[]")`
against the framed lines); removing the limit guard reddens the second with the unbounded queue
contents, `["one\n", "two\n", "three\n", "four\n"]`. The file was restored byte-identical
(`diff` empty, SHA-256 `f335d70c…51919b`). The "`submit` does not wait" property is proven by
construction, not by an assertion: the drop assertion is only reachable if the fourth `submit`
returned while the writer was parked, so a waiting `submit` would hang rather than redden, and that
is stated rather than claimed.

**Not changed.** The shipped constant is `makeStandardErrorSink(queue: .shared)`; the tests pin the
helper and the queue, not a future edit that bypassed the helper from the constant. A consumer that
never drains still parks the writer thread; bounding that thread would mean giving up delivery under
backpressure, which is the trade this design deliberately refuses.

## B90 — the HTTP listener bounded the request body and nothing else

**Severity S3** · **category** perf · **status** DONE · **host** node1 (arm64)

**What was wrong.** The server was built with a backlog, `so_reuseaddr` and an HTTP pipeline, and
nothing else: no bound on accepted connections and no read/idle timeout, so a peer that opened
connections and never finished a request held a channel and a descriptor indefinitely. The 1 MiB
body cap only applies once a request has been framed. The intended shape is a reverse proxy in
front, but `--host 0.0.0.0` is a supported opt-in and the class calls itself a minimal, correct
HTTP/1.1 server, so slowloris-style exhaustion was available to anyone who could reach the port.

**One premise is wrong.** The expected fix names `ChannelOptions.maxConnections` and
`IdleStateHandler`. A grep over the pinned swift-nio 2.102.0 checkout finds no `maxConnections`
API at all, and `IdleStateHandler` lives in NIOExtras, which this package does not depend on. Both
bounds are therefore implemented in `HTTPMCPHost` itself — a deviation from the literal spec, not
from its intent.

**The fix.** `maximumConnections = 64` plus a lock-guarded live count: `channelActive` counts the
child channel and closes it when over the limit, `channelInactive` releases it. The same
`channelActive` schedules a request deadline, deliberately armed before any header is parsed so a
trickled request line is covered; `.end` cancels it. `Duration` is converted to NIO's `TimeAmount`
through its components, so the conversion is exact. The value is `AppConfiguration.requestTimeout`
(`SEARCH_REQUEST_TIMEOUT_MS`, default 10 s) passed from `main.swift`, so no new configuration
surface was added and the tests can make the bound short; `example.env` records the second meaning.

**Idle versus streaming.** The bound is on receiving a request, not on the connection's lifetime.
An idle connection and a slowloris never reach `.end`, so the deadline fires; a streaming response
is a request that already ended, so the deadline was cancelled before the first response byte and
the SDK's standalone GET stream can stay open indefinitely.

**Verification.** Four tests in `HTTPTransportTests`, which drives the built executable over real
loopback sockets, with new descriptor-level `RawHTTP` helpers and an `extraEnvironment` parameter
on the harness: an idle connection is closed and `/health` still answers; a partial request is
closed; a standalone SSE stream is still open 2 s after a 400 ms budget; and 80 idle connections
against the 64 bound leave at least one refused, with the listener serving again once they are
released. **Falsification.** Three mutations redden disjoint tests: no deadline reddens the two
timeout tests, a deadline not cancelled at `.end` reddens only the streaming test, and no
connection guard reddens only the cap test. `HTTPMCPHost.swift` was restored byte-identical
(`diff` empty, SHA-256 `0cfddf08…36d44b0d`).

**Not changed.** The bound does not police a slow *reader* of the response (write backpressure is
NIO's story), and a pipelined second request never gets a fresh deadline because every response
sets `Connection: close` and closes the channel.

## B89 — `SearchCache.pruneExpired` rebuilt the whole dictionary on every access

**Severity S3** · **category** perf · **status** DONE · **host** node1 (arm64)

**What was wrong.** `get`, `store` and `stats` each called `pruneExpired()`, which did
`storage = storage.filter { now.timeIntervalSince($0.value.storedAt) < $0.value.ttl.seconds }`.
Every search therefore allocated a new dictionary and re-hashed every live entry even when nothing
had expired, and `evictOldest` sorted the whole dictionary on overflow.

**The fix.** Entries store an absolute `expiresAt` and the cache keeps `nextExpiry`, the earliest
deadline in `storage`. `get` no longer sweeps: it judges the requested key directly and removes it
on the spot, the branch the old code already had. `store` lowers the watermark, then sweeps and
enforces capacity in the old order; `stats` sweeps when due. `sweepExpired(now:)` removes expired
entries in place and recomputes the watermark. No public API changed.

**The invariant.** `nextExpiry` is only lowered by a store and exactly recomputed by a sweep, and
entries are only removed, so it can be stale-early but never stale-late — it is always at most the
earliest deadline in `storage`. Skipping the sweep when it is in the future therefore changes
nothing, and it is never skipped when an entry is actually due. The preserved observables: `get`
results and hit/miss counters (both paths now compare the same `expiresAt`), `stats().entries`
still counting live entries only, the capacity bound (sweep before the bound check, eviction order
untouched), and the successful-responses-only rule.

**Verification.** Two tests in `SearchCacheTests`, driven by `TestClock`: `stats().entries == 1`
with a short-lived and a long-lived entry after the short one lapses, and a capacity-8 cache whose
eight entries all expire before one live store still reports one entry with the live key present.
**Falsification.** The literal revert — the pre-fix `SearchCache.swift` from `HEAD` — makes both
tests *pass*, which is the evidence that the fast path preserved the old semantics rather than
merely claiming to. Removing the two `sweepExpired` call sites instead reddens them (`"8"` and
`"2"` against `"1"`), so the tests are load-bearing for the lazy design. The file was restored and
verified byte-identical (`diff` empty, SHA-256 `ea3992ef…15443ae`).

**Not changed.** `evictOldest` still sorts on overflow; that is a write-path cost only, and the
finding names `pruneExpired`.

## B88 — the declared per-host DNS cache did not exist, and a redirect hop resolved twice

**Severity S3** · **category** perf · **status** DONE · **host** node1 (arm64)

**What was wrong.** `URLPolicy` carried `/// Per-host cached DNS results, so a redirect chain does
not re-resolve.` above `private let resolver: any DNSResolver`. There was no cache: `resolver` is a
plain stored property and `SystemDNSResolver.resolve` calls `getaddrinfo` every time. The duplicate
work was real too — `DirectHTTPFetcher` validates each hop pre-emptively against the `Location`
target and again at the top of the loop, so a one-hop redirect paid three lookups for two hosts.

**The fix.** `validate(_:)` keeps its public signature and delegates to a new internal
`validate(_:cache:)`; the cache holds the *address list* per host for one fetch. `DirectHTTPFetcher`
creates one `DNSAnswerCache` per `fetch` and passes it to both validations of every hop. No public
signature changed.

**The invariant.** Re-validation is unchanged: the cache stores addresses, never decisions, so
every validation still runs the full address classification and a host that answers with private
space is denied every time; a host not in the memo is resolved before it is judged; and the memo
is dropped when `fetch` returns, so it can never answer for a later request. A process-lifetime
cache was the option to avoid: it would let a stale public answer be re-validated while
`URLSession` connects to whatever DNS says now. Only successful lookups are stored, because a
resolver failure is deliberately allowed through to become a real network error. The pre-emptive
hop check is kept alongside the loop-top re-check: the cache removes a duplicate *resolution*,
not a policy decision.

**Verification.** Four new tests in `URLPolicyTests` with a `CountingDNSResolver`: one lookup for
two validations of one host, a second host still resolved exactly once, a cached `10.0.0.5` still
denied with the private reason, and the uncached public path resolving on every call. Mutating
`validate(_:cache:)` back to always resolving reddens the three cache tests with the duplicate
host lists verbatim; the file was restored and verified byte-identical (`diff` empty, SHA-256
`7f9aad79…b19854c`).

**Not pinned.** The fetch-level lookup count cannot be observed end to end: the loopback fixture
is an IP literal and the private-network opt-in that makes it reachable short-circuits resolution,
so the memo is pinned against the exact policy object the redirect loop calls, as the existing
address-level hop check is.

## B119 — the PTY harness polled the monitor once, so a late startup crash was a timeout

**Severity S3** · **category** test · **status** DONE · **host** node1 (arm64)

**What was wrong.** B106 made a monitor that dies during startup report its exit status instead
of a first-frame timeout by polling the child once, immediately after `session.drain(3.0)`.
`Session.wait_for` — the frame wait that follows — never polled again, so a monitor that started,
crashed after the drain window and never painted a complete frame reached that wait with `poll()`
still `None` and was reported as "timed out waiting for the first frame": the same conflation
B106 removed, just moved later.

**The fix.** `wait_for` polls the child on every read turn and, when it has exited, raises
`Failure` naming the exit status and the last 300 characters of the transcript, mirroring B106's
startup check. An exit is therefore classified as an exit whenever it is observed, and every frame
wait in `run()` — colour, engine breakdown, refresh, provider probe — gets the same diagnosis.
`Session.drain` keeps no poll because the `q` and signal paths use it in loops where an exit is
the expected outcome.

**Verification, with stubs only.** No Swift build is involved. An executable stub at
`$HOME/Library/Caches/MCPSearch/B119/crash_after_drain.py` hides the cursor, clears the screen,
sleeps five seconds, writes `boom: startup failed while rendering` and exits 3 without ever writing
a cursor-home frame. With the fix, `python3 scripts/monitor_tty_smoke.py <stub>` fails in ~6.1 s
with `the monitor exited with 3 while waiting for the first frame: 'boom: startup failed while
rendering'`. **Falsification.** Removing the new poll from `wait_for` makes the same command fail
with `timed out waiting for the first frame` after ~15.6 s (three-second drain plus twelve-second
timeout), which is the pre-fix message verbatim. The harness was restored byte-identical (`diff`
empty, SHA-256 `abba36f2…130bb9`). The PTY harness was **not** exercised against the real
`mcps-mon` binary for this task: the proof is stub-only as required. No in-repository test was
added because the repository has no Python test infrastructure and B99 is the open task that owns
one. `ruff check scripts`, `ruff format --check scripts` and `pyright scripts/monitor_tty_smoke.py`
are clean; debug and release builds are 0 warnings under `-warnings-as-errors`; the suite is 508
tests, 6 skipped, 0 failures; `swift-format --strict` and `swiftlint --strict` are clean (85
files); `third_party_notices.py` is clean. Evidence:
`AUDIT/evidence/B119-tty-frame-wait-polls-child.txt`.

## B102 — a cross-scheme redirect surfaced as an opaque transport error

**Severity S3** · **category** bug · **status** DONE · **host** node1 (arm64)

**What was wrong.** `DirectHTTPFetcher` follows redirects manually so every hop is
re-validated, but a redirect that changes scheme never reaches that loop: `URLSession` does not
consult `NoRedirectDelegate.willPerformHTTPRedirection` for a cross-scheme hop, refuses it
internally against `file:///etc/hosts` and reports the file-system `URLError` `-1102`. The
catch-all mapping turned that into `fetchFailed(entryURL, reason: "the transport reported error
-1102")`. The security outcome was already correct — no local content was returned even for a
readable file — but the diagnosis was opaque and the safety property rested on undocumented
transport behaviour.

**The fix, and its limit.** The three file-system codes (`-1100 fileDoesNotExist`,
`-1101 fileIsDirectory`, `-1102 noPermissionsToReadFile`) now map to
`"the server redirected to a local file, which is not fetched"`, and `URLPolicy`'s doc comment
records that a cross-scheme hop is refused beneath the policy without producing a `Decision`.
The task brief asked for the refusal to come from policy; it cannot literally do so, because the
transport never surfaces the redirect target, so `policy.validate` is never called with it. The
only alternatives were probing the target ourselves first (duplicating the request and its policy
hop) or replacing `URLSession`'s redirect handling entirely — both larger than this finding. The
fix therefore delivers a legible, policy-shaped reason and a documented limitation. It stays a
`fetchFailed` rather than a `blockedURL`: the blocked URL is the `file:` target we never see, so
`blockedURL(currentURL)` would name the entry URL and claim a decision never made about it, and
`blockedURL` would also suppress the Jina fallback; the ledger's candidate fix asks for the
diagnosis change and to keep the regression test's observable outcome.

**Verification.** The existing `FetchRedirectTests.testARedirectToAFileURLIsRefusedWithoutReadingTheFile`
now asserts the exact reason, still asserts that no `localhost` (`/etc/hosts`) text appears in the
error, and asserts the opaque `transport reported error` text is gone. **Falsification.** Removing
the three-code case restores the pre-fix mapping and reddens the test with the original message
verbatim (`the transport reported error -1102`, 2 failures), which also confirms the environment
really takes the new branch. The file was restored byte-identical (`diff` empty, SHA-256
`1f651367…c5308e`). Debug and release builds are 0 warnings under `-warnings-as-errors`; the suite
is 508 tests, 6 skipped, 0 failures (unchanged from B92 — this strengthens an existing test);
`swift-format --strict` and `swiftlint --strict` are clean (85 files); `third_party_notices.py` is
clean. Evidence: `AUDIT/evidence/B102-cross-scheme-redirect-refusal.txt`.

## B92 — `web_open`'s Jina path hard-set `final_url` to the requested URL

**Severity S3** · **category** logic · **status** DONE · **host** node1 (arm64)

**What was wrong.** `JinaReaderFetcher.fetch` decoded the reader's JSON envelope but read only
`data.content` and `data.title`; `finalURL` was hard-set to `request.url`, and `code`/`status`
were decoded and unused. `ToolOutputFormatter.openStructured` therefore reported `final_url`
equal to the requested URL on the Jina path while the direct-HTTP path reports the URL it actually
reached, so the two extraction methods disagreed about what `final_url` means.

**What the reader actually reports.** The ledger's note says the field carries the URL the reader
resolved to. Reading the reader's source (the open-source branch the README says was
re-synchronised with the SaaS code in 2026-04) shows `src/services/snapshot-formatter.ts` builds it
as `url: nominalUrl?.toString() || snapshot.href?.trim()`, and the crawler passes the requested
`targetUrl` as `nominalUrl`. For `r.jina.ai` the field is therefore the **nominal target**, not the
post-redirect URL, and no response header exposes the resolved URL. The fix was still made — the
field is third-party input that was rendered verbatim and is now validated, and a reader that does
report a resolved URL is now followed — but it does not deliver redirect transparency for the
hosted reader, and no in-process fix can without duplicating the fetch and its policy hop.

**The fix.** `data.url` is parsed through the new `resolvedURL(_:)` helper and used as `finalURL`
when it parses to an absolute `http`/`https` URL with a non-empty host; absent, relative, `file:`,
`javascript:` and `https://` all fall back to `request.url`. The unused `code`/`status` fields were
dropped from `ReaderResponse`. The markdown/text path is unchanged and still reports the
requested URL; the `URL Source:` line was deliberately not parsed because the reader fills it from
the same nominal value.

**Verification.** Two tests in the existing `FetchFallbackTests.swift`: one where the envelope's
`data.url` differs from the request and `finalURL` must follow it, and a table over seven unusable
values that must each fall back. **Falsification.** M1 reverting `finalURL` to `request.url`
reddens the follow test (1 failure); M2 removing the scheme/host validation reddens the fallback
test with five failures, showing that without the check a relative, `file:` or `javascript:` string
could become `final_url`. The file was restored byte-identical after each (`diff` empty, SHA-256
`465d57f6…399a37`). Debug and release builds are 0 warnings under `-warnings-as-errors`; the suite
is 508 tests, 6 skipped, 0 failures; `swift-format --strict` and `swiftlint --strict` are clean
(85 files); `third_party_notices.py` is clean. Evidence:
`AUDIT/evidence/B92-jina-final-url.txt`.

## B84 — `IPAddress.v6` accepted any byte count while its accessors indexed 16 bytes

**Severity S3** · **category** unsafe · **status** DONE · **host** node1 (arm64)

**What was wrong.** `IPAddress` is a public enum whose `case v6([UInt8])` carries an
unvalidated array. `init?(_:)` only ever produces 16 bytes and every in-tree producer goes
through it, so no MCP tool path is affected, but a downstream caller can write
`IPAddress.v6([1])`. `description` (`stride(to: 16, by: 2)` indexing `bytes[index + 1]`),
`isLoopback` (`bytes[15]`), `embeddedIPv4` (`bytes[0..<10]`, `bytes[10]`, `bytes[11]`, and
`address(at:)` at offset 12), `isLinkLocal`, `isPrivate` and `isMulticast` all indexed fixed
offsets unconditionally, so a short array turned a data value into a process crash. `isUnspecified`
did not trap but classified `[]` as unspecified.

**The fix, and the API decision.** The public API is unchanged: the case and its `[UInt8]`
payload stay, and every accessor is defended. `description` returns `invalid IPv6 (N bytes)` for a
non-16-byte value, `embeddedIPv4` returns nil and the five predicates return false. I chose the
guard approach rather than a fixed-width payload because the stronger options change a public
enum's associated value: a 16-byte tuple payload would drop `Hashable` (Swift does not synthesise
it for tuple payloads), and a public wrapper type would break `IPAddress.v6([...])` at every
downstream construction and pattern match, for a defect not reachable from `web_open`/`web_search`.
The honest cost is that the invariant stays structurally representable, so the guards are the
defence. `isCloudMetadata`/`isReserved` already used `prefix(4)` and
`isSharedAddressSpace`/`isBroadcast` return constants, so they needed no change; nothing about the
SSRF classification of a valid address changed. The v4 arms of four predicates gained an explicit
`return`, a mechanical consequence of turning their switches from expressions into statements.

**Verification.** `testMalformedIPv6ValuesAreClassifiedInsteadOfTrapping` in the existing
`URLPolicyTests.swift` builds 0-, 1-, 2-, 10-, 15-, 17- and 32-byte `IPAddress.v6` values and
exercises every accessor. **Falsification.** Removing the seven accessor guards restores the
defect and the test aborts the process: `Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index
out of range`, xctest signal code 5. The file was restored byte-identical (`diff` empty, SHA-256
`f2040f3b…0eda0b`). `URLPolicyTests` is green (24 tests) and the full suite is 506 tests,
6 skipped, 0 failures; debug and release builds are 0 warnings under `-warnings-as-errors`,
`swift-format --strict` and `swiftlint --strict` are clean (85 files), `third_party_notices.py` is
clean. Evidence: `AUDIT/evidence/B84-ipv6-case-guards.txt`.

## B54 — concurrent first use of the Parallel provider performed the MCP handshake more than once

**Severity S3** · **category** bug · **status** DONE · **host** node1 (arm64)

**What was wrong.** `ParallelMCPProvider` is an actor and `ensureInitialized` guarded only on
`sessionID != nil`, but `sessionID` is assigned at the very end of the handshake — after
`send(initialize)`, `sendInitializedNotification()` and `discoverToolName()`, each an `await`.
Actors are re-entrant across `await`, so a second `search` arriving while the first handshake was
suspended re-entered `ensureInitialized`, still saw `sessionID == nil`, and ran a full second
handshake. The class deliberately reuses one stable `sessionIdentifier` because the free tier
meters per `session_id`, so the duplicate spent metered quota and left the two in-flight calls able
to use whichever `MCP-Session-Id` the server assigned last.

**The fix.** The handshake now runs inside a `Task` cached on the actor. The first caller creates
it; later callers that arrive before it completes await `handshake.value` and then return. A failed
handshake clears the cache so the next caller retries it, which is exactly the un-cached behaviour.
The handshake body is unchanged and merely moved into `performHandshake`. Cancelling a waiting
caller does not cancel the shared handshake, so the other callers sharing it still complete. No
public API changed: the new state and method are private, and the public surface, wire messages,
JSON-RPC sequence and error taxonomy are untouched.

**Verification, and why the race is deterministic.** The test lives in the new
`Tests/WebSearchCoreTests/ParallelHandshakeTests.swift` because `ProviderContractTests.swift` is
already at SwiftLint's 1 458-line ceiling — the same reason B116 put its race test in
`LocalThrottleRaceTests.swift`. `GatedInitializeHTTPClient`, an actor transport, parks the first
`initialize` response on a checked continuation until the test releases it and answers later
`initialize` requests immediately while recording every method. The handshake window only exists
while the provider is suspended, so parking that response holds the window open deliberately. The
test starts the first search, waits until its `initialize` is parked, starts the second, lets it
reach `ensureInitialized`, and asserts one `initialize` has reached the transport **while the
first is still parked**; it then releases and asserts the full sequence (one `initialize`, one
`notifications/initialized`, one `tools/list`, two `tools/call`). The second caller cannot observe
a completed handshake because the first cannot complete before the release, so the interleaving is
forced rather than hoped for; the bounded `Task.yield` spin only lets the already-enqueued second
task run and no wall-clock window is involved.

**Falsification.** Replacing the fix with the pre-fix control flow (guard on `sessionID` only, call
the handshake body directly) reddens the new test: two `initialize`, two
`notifications/initialized`, two `tools/list` — 4 failures. The mutated file was restored from a
saved copy and verified byte-identical (`diff` empty, SHA-256 `7a0d74c7…4de752` matches the
backup). The new test is then green in 0.003 s.

**Gates.** debug and release builds 0 warnings under `-warnings-as-errors`; 505 tests, 6 skipped,
0 failures (the 504-test baseline plus this one); `swift-format --strict` 0; `swiftlint --strict` 0
in 85 files; `third_party_notices.py` clean. Evidence: `AUDIT/evidence/B54-parallel-handshake-once.txt`.

## B118 — the invalid `--transport` error named two of the four accepted spellings

**Severity S3** (recorded) · **category** docs · **status** DONE · **host** node1 (arm64)

**What was wrong.** B114 made `usage` render the `--transport` help line from the `TransportName`
table, so `--help` now lists all four accepted spellings (`stdio`, `http`, `streamable-http`,
`streamable_http`). The rejection message did not come along: it hardcoded
`expected: "stdio or http"`, which after B114 was the only place in the CLI that disagreed with
`--help`. A caller who mistyped was told the legal set was smaller than it is, so the more natural
`--transport streamable-http` looked unsupported.

**The fix.** One producer, `TransportName.acceptedValues`, renders the list from the same table
`parse` resolves against, and both the usage line and the parse error print it, so the two cannot
drift apart again. The error now reads `Invalid value for --transport: 'carrier-pigeon' (expected
stdio, http, streamable-http, streamable_http)`, byte-for-byte the phrase `--help` shows. No public
signature changed; `acceptedValues` is internal to `ServerOptions`.

**Verification.** `TransportConfigurationTests.testInvalidTransportIsRejected` no longer pins the
two-value wording: it asserts the full literal list and that the same phrase appears in
`ServerOptions.usage`. Restoring the hardcoded `"stdio or http"` makes it fail with both messages
side by side — the exact drift the finding describes — and `TransportConfiguration.swift` was then
restored byte-identically (`diff` empty; SHA-256 equal). No new test method was added, so the count
is unchanged from B87. Debug and release build with 0 warnings under `-warnings-as-errors`;
**504 tests, 6 skipped, 0 failures**; `swift-format --strict` and `swiftlint --strict` clean over 84
files; the third-party notices check reports all 8 pinned packages covered. Artifact:
`AUDIT/evidence/B118-transport-expected-values.txt`.

**Noted.** `MCPSMonitor` has its own option parser with its own error wording, but it does not parse
`--transport`, so there is no second transport list to keep in sync.

## B87 — the Jina Reader fallback hid the third-party disclosure

**Severity S3** (recorded) · **category** docs · **status** DONE · **host** node1 (arm64)

**What was wrong.** `enableJinaReaderFallback` defaults to `true`, so by default every
`web_open` whose native extraction is thin sends the full target URL to `r.jina.ai`, which fetches
the page on this server's behalf — and `web_open` accepts authorisation-bearing URLs. Nothing told
the caller: the tool description said only "JS-heavy pages may fall back to a rendering service",
the README never mentioned the reader, and the result warning said only "used Jina Reader instead".
Worse, when the native fetch failed outright and the reader succeeded, no warning was emitted at
all, because it was appended only inside `if let directResult`. The behaviour is an accepted,
toggleable design decision guarded by the SSRF policy, so this is a disclosure gap, not a control
failure.

**The fix.** The fact is disclosed in all three channels the finding names rather than softened:
the `web_open` description now names Jina Reader and `r.jina.ai` and says the URL is fetched
remotely; the README gains a `### Third-party rendering for web_open` section stating that the full
URL (credentials, tokens, signed query parameters included) goes to the third party, naming
`SEARCH_ENABLE_JINA_READER=false` and `JINA_API_KEY`, and recording that the SSRF policy runs
first; and `JinaReaderFetcher.fetch` attaches `"Used Jina Reader (<host>), a third-party service
that fetched this URL remotely."` to every successful reader result. The host comes from the
configured `baseURL`, so a non-default reader endpoint is named correctly, and putting the warning
in the reader closes the direct-failure gap that emitted nothing. The fallback stays on by default,
the URL policy is untouched, and no public signature changed. Userinfo/query redaction is marked a
"consider" in the finding: it changes which resource the reader fetches and needs a new operator
opt-in, so it is recorded as left open for an operator decision rather than done silently here.

**Verification.** `StdioServerTests.testWebOpenDescriptionDisclosesTheThirdPartyReader` reads
`tools/list` from a real server and requires the description to name `r.jina.ai`, `third-party` and
`remotely` — the assertion that catches the omission in the model-visible text.
`FetchFallbackTests.testAReaderSuccessAfterADirectFailureStillDisclosesTheThirdParty` covers the
previously-silent path, and `testThinNativeExtractionFallsBackToTheReader` was strengthened to
require the disclosure on the ordinary fallback. Reverting both production changes makes all three
fail (the direct-failure case reports an empty warning list), and both files were restored
byte-identically (`diff` empty; SHA-256 equal). Debug and release build with 0 warnings under
`-warnings-as-errors`; **504 tests, 6 skipped, 0 failures** (502 at B85 plus these two);
`swift-format --strict` and `swiftlint --strict` clean over 84 files; the third-party notices check
reports all 8 pinned packages covered. Artifact:
`AUDIT/evidence/B87-jina-third-party-disclosure.txt`.

## B106 — the PTY harness reported a crashing monitor as a first-frame timeout

**Severity S3** (recorded) · **category** test · **status** DONE · **host** node1 (arm64)

**This task was already fixed and had been left open.** The fix is commit `761966b1`
("audit(B106): report a crashing monitor as a crash, and pin Ctrl-C in the harness"), which
`git merge-base --is-ancestor` confirms is an ancestor of HEAD, and `scripts/monitor_tty_smoke.py`
is byte-identical to it. `B106` was the **only** START task in this ledger with a resolving
`audit(<ID>)` commit: the change had landed and only its evidence artifact was missing. That is why
it still read START, and it would have blocked Phase E's "ledger containing only DONE or
BLOCKED-with-owner" gate.

**The fix, as committed.** The harness attaches the child's stdin/stdout/stderr to one PTY, so a
crash banner arrives in the transcript. After the startup drain it polls: an exited child fails with
"the monitor exited during startup with <status>: <transcript tail>", while a live-but-silent child
still falls through to the first-frame wait and times out. A crash and a hang no longer produce the
same message.

**Verification added.** A stub-based check drives the real `run()` against a monitor that exits 3
with a crash banner and one that starts and blocks. RED (the six check lines removed in place, then
restored byte-identically) reports `timed out waiting for the first frame` for **both** and fails
four assertions; GREEN names the exit status and the stderr for the crash and still reports a
timeout for the hang, passing six. The real `main()` entry point reproduces it end to end. ruff,
`ruff format --check` and pyright strict are clean.

**Separate residual, folded as B119.** The check runs once after a fixed `drain(3.0)`, so a monitor
that crashes *after* that window but before its first frame is still reported as a timeout. That is
outside this task's expected-correct and is recorded rather than quietly closed.

Artifact: `AUDIT/evidence/B106-pty-crash-vs-hang.txt`.

## B85 — the log query digest was a public FNV-1a documented as non-reversible

**Severity S3** (recorded) · **category** docs · **status** DONE · **host** node1 (arm64)

**What was wrong.** `Log.hash` rendered a query as an unkeyed FNV-1a digest and its doc comment
claimed a "Stable, non-reversible short hash for correlating repeated queries without recording
user content". FNV-1a has no key, so "non-reversible" was false: queries are low-entropy natural
language and anyone holding a log line can confirm or recover a candidate by hashing a dictionary
with the same public function — a one-line offline check. The default (`logQueries: false`) is
still better than verbatim logging, but the claim overstated the protection for whoever reads the
logs (a collector, a pasted bug report, an operator).

**The fix.** The finding allowed renaming this a correlation id *or* making it resistant. The
second was chosen: the recoverability is the problem, and relabelling would leave the fact in place
while deleting the only warning about it. `hash` is now HMAC-SHA-256 under a 256-bit `SymmetricKey`
generated once at process start, truncated to the same 64-bit `q` + hex form so the log-line field
is unchanged for existing consumers. The key is held in memory only, never persisted or logged, so
a dictionary attack needs it. CryptoKit was already a dependency (`SearchCache` uses `SHA256`), so
no package was added, and no public signature changed. The trade-off the design implies — ids
reproduce within a run but not across restarts — is now stated in the code rather than hidden
behind "stable".

**Verification.** `LoggingTests.testHashIsNotTheUnkeyedFNV1aDigest` holds the exact FNV-1a outputs
of three inputs, computed independently in Python, and asserts the current digest differs; reverting
`hash` to FNV-1a fails all three with `XCTAssertNotEqual ... reproduces the unkeyed FNV-1a digest`,
which is the dictionary attack made concrete. `Logging.swift` was then restored byte-identically
(`diff` empty; SHA-256 equal). `LoggingTests` is 7 tests green. Debug and release build with 0
warnings under `-warnings-as-errors`; **502 tests, 6 skipped, 0 failures** (501 at B66 plus this
one); `swift-format --strict` and `swiftlint --strict` clean over 84 files; the third-party notices
check reports all 8 pinned packages covered. Artifact:
`AUDIT/evidence/B85-query-hash-keyed.txt`.

**Noted.** No README or operator-facing document repeated the false claim; it lived only in the
source comment, so there was no second wording to correct.

## B66 — decoded-but-unused fields across five vendor DTOs

**Severity S3** (recorded) · **category** dead · **status** DONE · **host** node1 (arm64)

**What was wrong.** Five adapters declared `Decodable` fields that nothing reads: Mojeek
`Head.start`/`Head.return` and `Item.date`/`Item.pdate`; Exa `requestId`/`resolvedSearchType` and
`Item.author`/`Item.summary`; SearXNG `query`/`corrections`/`suggestions` and `Item.category`;
Tavily `query`; Brave `BraveResponse.type` and `BraveErrorResponse.ErrorBody.id`/`.status`/`.detail`
— plus `BraveErrorResponse.type`, a sixth instance the finding did not enumerate and `validate`
never reads. Inert at runtime, but each field advertises a contract the code does not keep and
absorbs wire drift that should be visible; `a375ddd`/`e60203e` removed the same class of surface for
Brave once, and this closes the rest.

**The fix.** Every listed field is deleted rather than surfaced, following B78's call for dead
surface; rendering SearXNG `corrections`/`suggestions` would be new user-visible behaviour and
belongs to a task that owns it. All fifteen properties are `Optional`, so the synthesized
`init(from:)` used `decodeIfPresent` and the key was never required; JSON keys with no matching
property are ignored, so no surviving field's decoding changes. SearXNG's explicit `CodingKeys`
lost the three cases with their properties while `results`/`answers`/`unresponsiveEngines` keep
their exact spellings (including the `unresponsive_engines` rename); Tavily's `Item.CodingKeys` is
untouched. The DTOs are `Decodable` only, so nothing outbound changes. No public signature changed.

**Verification.** A deletion cannot be pinned by a naming test, so the accepted shape (B78) applies:
compiler, suite and before/after grep. A temporary test method naming every removed member was
appended to `ProviderContractTests`, the test target built, and the file restored byte-identically
(`diff` empty; SHA-256 equal to the backup). The build emitted a `has no member` error for each
removed field on all five types. The after-grep shows only the live `ProviderID` constants and the
request-body `query`/`type` fields. Debug and release build with 0 warnings under
`-warnings-as-errors`; **501 tests, 6 skipped, 0 failures** (unchanged, since no test named a deleted
field); `swift-format --strict` and `swiftlint --strict` clean over 84 files; the third-party notices
check reports all 8 pinned packages covered. Artifact:
`AUDIT/evidence/B66-dead-vendor-dto-fields.txt`.

**Noted, not changed.** The finding's alternative — surfacing SearXNG `corrections`/`suggestions` as
warnings — is deliberately left to its own task; the consumed wire contract (`totalEstimatedMatches`,
the result fields, the Brave altered-query warning, the SearXNG unresponsive-engine warnings) is
unchanged and the scripted-transport contract tests for all five adapters still pass.

## B114 — the operator-facing usage text had drifted from the parser

**Severity S3** (recorded) · **category** docs · **status** DONE · **host** node1 (arm64)

**What was wrong.** `ServerOptions.usage` was a hand-written string. The parser accepted more
than the text described: `--help`/`-h`, the `streamable-http` and `streamable_http` aliases for
`--transport`, and the `--flag=value` spelling. The guard was toothless —
`testUsageDocumentsEveryFlag` compared a hand-written list of five names against
`usage.contains`, so the parser could grow any flag and the test kept passing. A `contains` check
is also weaker than it looks: `-h` is a substring of `--http-allowed-host`, so it would have
passed without ever being documented. Separately the empty-configuration warning named five of
the eight provider-registering variables, omitting `OPEN_WEB_SEARCH_URL`, `SEARCH_ENABLE_SCRAPERS`
and `SEARCH_ENABLE_PARALLEL`.

**The fix.** Flag names, aliases, value placeholders and descriptions now live in one table,
`ServerOptions.Flag`; accepted `--transport` values live in `ServerOptions.TransportName`.
`parse` dispatches on the table (`Flag.matching` plus `inlineValue` for the `=` spelling) and
`usage` is rendered from the same table, so a flag cannot be accepted without being documented or
documented without being accepted: the per-case switches are exhaustive, so adding a case forces
entries in every computed property. `renderUsage` derives the `OPTIONS` column, the
"Setting any of …" sentence and the alias list from the tables. In `main.swift` the provider
inventory became a `providerAvailability` table that feeds both the inventory and the warning, so
the warning names every variable that can register a provider and cannot go stale on its own. No
public signature changed; `usage` remains a `String`.

**Verification.** `testUsageDocumentsEveryFlagTheParserAccepts` iterates `Flag.allCases` and
`TransportName.allCases` and matches whole whitespace tokens;
`testEveryDocumentedFlagIsAcceptedByTheParser` and `testEveryValueFlagAcceptsBothSpellings` are
table-driven over the parser's table, with an exhaustive test-side `sampleValue(for:)` that fails
to compile when a flag case is added; `testMissingValuesAreRejected` was likewise switched from a
hand-written list. A process-level `testEmptyConfigurationWarningNamesEveryProviderVariable`
starts the executable with a scrubbed environment and asserts the warning on stderr names all
eight variables. Both defects were mutated back and the tests reddened (usage: 5 failures;
warning: 3 failures); the first RED run showed `-h` passing as a substring, so the test was
strengthened to token matching before the recorded run. Both files were restored byte-identical
and every gate is clean: debug and release builds 0 warnings under `-warnings-as-errors`, 501
tests / 6 skipped / 0 failures, `swift-format --strict` 0, `swiftlint --strict` 0,
`third_party_notices.py` clean.

**Interaction with B113.** B113 moved the argv parse and the `--help` arm above
`AppConfiguration.load()`, making a help request environment-independent; B114 then changed what
`usage` says without changing when it is produced. Doing B113 first is what allowed the derived
text to be observed through the real executable under a fatal `SEARCH_CONFIG_FILE`. The two are
otherwise separate concerns — B113 owns *when* the command line is read, B114 owns *what* it
documents — and B113's process tests (which assert exit status, `USAGE` and the absence of startup
diagnostics, never exact flag text) stayed green across the B114 rewrite.

## B113 — configuration was loaded before the command line was parsed

**Severity S3** (recorded) · **category** logic · **status** DONE · **host** node1 (arm64)

**What was wrong.** `main.swift` called `AppConfiguration.load()` at the top and only parsed
`argv` after the HTTP client and the whole provider pipeline had been built. Because B09 made an
unreadable `SEARCH_CONFIG_FILE` fatal at startup, `SwiftWebSearchMCP --help` with a mistyped path
wrote "Refusing to start" and `exit(2)` **before** the `wantsHelp` arm could run, so a help
request depended on the environment. The same ordering meant an unknown flag could only be
reported after the config error, after the startup log and after the client and pipeline were
constructed — the comment at the old parse site ("a bad flag should fail fast and loudly")
described an intent the ordering defeated.

**The fix.** The parse block moved above `AppConfiguration.load()`. `--help` is answered and a
bad flag is reported first. The parse error no longer routes through `log.error` (the logger's
level comes from the configuration, which is deliberately not loaded yet) and is written to
stderr directly, followed by the same usage text as before. Nothing else depended on the early
load: the issue report, the `unreadableConfigFile` fatal arm, the `Starting` log, the provider
inventory and the empty-configuration warning all remain below the new block and still run for a
real invocation. No public signature changed.

**Why not the other reading.** The finding also mentions that `AppConfiguration.parse` drops
empty values, which makes the `PARALLEL_MCP_URL=` arm unreachable (`:330-332`). That is B59's
deliberately recorded behaviour — an explicitly empty environment value is how the built-in
Parallel endpoint is removed — and it is not part of this task's expected-correct, which is only
about parse order. It was left alone.

**Verification.** Three process-level tests were added to `StdioServerTests` using a new
`runToCompletion` helper that launches the built executable with the hermetic provider-scrubbed
environment and returns `(status, stdout, stderr)`. They assert that `--help` under
`SEARCH_CONFIG_FILE=/nonexistent/audit-missing-config.env` exits 0 with usage on stdout and no
"Refusing to start"; that `--not-a-flag` under the same fatal configuration exits 2 with
`Unknown argument: --not-a-flag`; and that a plain `--help` emits no `Starting` diagnostic. The
tests were proven to fail against HEAD's ordering (3 tests, 6 failures), the file was restored
byte-identical (SHA-256 `38f356f3…e386415`), and every gate is clean: debug and release builds 0
warnings under `-warnings-as-errors`, 498 tests / 6 skipped / 0 failures, `swift-format --strict`
0, `swiftlint --strict` 0, `third_party_notices.py` clean.

## B117 — the HTTP smoke picked a free port before the child bound, so the child could lose the race

**Severity S3** (recorded) · **category** test · **status** DONE · **host** node1 (arm64)

**What was wrong.** `free_loopback_port` binds port 0, reads the assigned number, closes the socket
and returns it; the child then binds it itself. Between the close and the child's bind the port is
unowned, so another process can take it and the child exits `EADDRINUSE`. B83 fixed the *symptom* -
the wait loop now polls the child and reports the exit code with its stderr in under a second - but
left the race, which is the same class `B20` fixed in the Swift HTTP-transport harness.

**Why the retry, and not the handshake.** The finding offered "have the child report the port it
actually bound". That is impossible here without a production change: `ServerOptions.parse` rejects
`--port 0` (its range is `1...65535`), so the harness must still name a port, and the child's choice
can only be made authoritative by letting the OS choose. Holding the probe socket open across the
exec was already rejected by B83 and was **re-measured on this machine**: a second bind fails
`Errno 48` with *and* without `SO_REUSEADDR`. The honest minimal fix is therefore the retry, which
keeps port ownership entirely in the harness.

**Not masking a real failure.** The retry fires only on the `Could not bind` marker that
`HTTPHostError.bindFailed` emits through `main.swift`'s startup error log. A non-bind exit
propagates on the first attempt; a live-but-unhealthy child is killed and reported, never retried;
the loop is bounded at three ports and raises the last diagnostic if all lose; and each retry prints
a `note:` line so a raced run is visible rather than silent.

**Verification.** A deterministic fixture holds the exact port the harness picks first, so the stub
child's real bind fails `EADDRINUSE` instead of relying on luck. RED (fix reverted) fails to retry
and never completes the HTTP session (exit 1); GREEN completes the whole session and passes six
assertions, including that a non-bind startup failure is *not* retried. ruff, `ruff format --check`
and pyright strict are clean. Artifact: `AUDIT/evidence/B117-smoke-port-race.txt`.

**Stated limit.** The race cannot be fully removed without a production argument-parsing change
(allowing `--port 0` so the child can choose), which is out of this task's scope. The marker string
is source-verified and reproduced in a stub, not observed from the real binary, because no Swift
binary was built in that session.

## B111 — nullable enums excluded the null the design depends on

**Severity S3** (recorded) · **category** logic · **status** DONE · **host** node1 (arm64)

**What was wrong.** Every optional argument in `ToolSchemas.swift` is a nullable union
(`["string", "null"]`) listed in `required`, the documented strict-mode idiom, and the runtime
parser treats an explicit null as absent. Where such a property also carried an `enum`, the `enum`
listed only the choices: `web_search.recency`, `web_search.mode`, `web_answer.recency` and
`web_answer.mode`. `type` and `enum` are conjunctive in JSON Schema, so null satisfied `type` and
violated `enum` — the value the design depends on was invalid, and a strict client that must fill
every required slot could not legally ask for the default. Read back from a started server, the
contradiction was visible on the wire for all four. The repository lint could not see it because
`testToolsAreUsableWithNoOptionalArguments` asserted nullability from `type` alone.

**Why the enum gained null.** The finding offers dropping these from `required` instead. That was
rejected: `required` is what OpenAI strict mode demands, the file's lint enforces
`properties == required` on every object, and every other optional argument uses the same
nullable-union-listed-in-`required` idiom — dropping it for these four would abandon the file's one
optionality idiom and leave `provider` (whose handler treats `auto` and null identically)
inconsistent with its neighbours. Adding `null` keeps the idiom and makes the advertised value legal,
which is what the parser already implements. The literals use `Value.null` so the mixed arrays still
type as `[Value]`. The file header's nullable-types bullet now states the pairing rule.

**The lint.** The recursive `violations` walk now appends a violation whenever a property whose
`type` admits null has an `enum` that does not, for every object schema at any depth. The check is
unconditional on `required`, matching the finding's wording and covering nested output schemas where
the same contradiction could appear. The rule table at the top of the test file gained the matching
row, `testToolsAreUsableWithNoOptionalArguments` now asserts the `enum` next to the `type` assertion
it already made, and `testOptionalSearchArgumentsAdmitNull` states the contract for `recency`,
`provider` and `mode` on both search tools so a failure names the argument a caller cannot express.

**Verification.** Mutation-proven. Removing `Value.null` from the two `recency` enums makes the lint
report exactly `web_search.inputSchema.recency: type admits null but enum does not, so the nullable
union the schema advertises is not a legal value` and the same for `web_answer`, while the focused
test reports the two argument-level failures. Running the **pre-B111** test file (taken from the B110
commit, so every earlier rule including B110's parity comparison was active) against that defective
tree passes — 7 tests, 0 failures, 0.740 s — which is the omission the finding describes and shows
the new rule is load-bearing. The production file was restored from a copy and verified
byte-identical (`diff` empty; SHA-256 equal to the backup). Debug and release build with 0 warnings
under `-warnings-as-errors`; **495 tests, 6 skipped, 0 failures** (494 plus the one new test method);
`swift-format --strict` 0 diagnostics and `swiftlint --strict` 0 violations in 84 files. Artifact:
`AUDIT/evidence/B111-nullable-enum-admits-null.txt`.

**Noted, not changed.** The four enums remain literals rather than derivations of `Recency` and
`SearchMode`; only `provider` is derived, because B110's subject was a drift between two tools. The
finding's compatibility caveat stands: no vendor client is run here, so the impact is reasoned from
the JSON Schema specification and from this server's parser, not observed against a vendor.

## B110 — `web_answer`'s `provider` argument lost the enum that `web_search`'s declares

**Severity S3** (recorded) · **category** logic · **status** DONE · **host** node1 (arm64)

**What was wrong.** `web_search.provider` advertised the closed set of provider ids, and
`web_answer.provider` — the same argument, resolved by a copy of the same parsing block in
`ToolHandlers` — advertised a bare nullable string. Both handlers reject an unknown id at runtime
with the same message, so the missing `enum` cost a strict `tools/list` consumer the only place it
could learn the legal values and gained the server nothing. The doc comment on `webAnswerInput`
claims the tool "deliberately mirrors `web_search`'s discovery arguments"; the mirror was a
hand-maintained copy that had already drifted.

**The fix — structural, not a copied enum.** The obvious repair is to paste the ten values into
`web_answer`, which would repeat the mistake that caused the defect. Both tools now reference one
private `providerDiscoverySchema`, and its `enum` is derived from `ProviderID.allCases` plus the
`auto` sentinel rather than from a literal, so a provider added to the core enum cannot be omitted
from the advertised contract. `null` is part of that derived list because the property is a
nullable union; the lint that requires an enum to admit every type it declares is B111, the next
commit, and the comment cross-refers to it. The `web_answer` description intentionally adopts the
`web_search` wording: the two tools have one `provider` contract and that text names the default
explicitly. No public signature changed.

**The lint.** The recursive `violations` walk in `SchemaCompatibilityTests` now accepts the schema
a tool mirrors and, for `web_answer.inputSchema`, compares it with `web_search.inputSchema`: the set
of declared discovery arguments must be identical, and so must every keyword that constrains a
value (`type`, `enum`, `minimum`, `maximum`, `maxItems`, `items`) for each shared property, with
`provider` compared whole — description included, because that is where the default is documented.
Each tool's own description prose is exempt, since `web_answer` describes grounding an answer
rather than returning results; an earlier version compared whole properties and reported four false
positives, which is why the comparison is scoped by keyword. The focused test
`testProviderEnumListsTheAcceptedProviderIDs` asserts that both tools advertise exactly the ten ids
the runtime parser accepts, which the parity comparison alone cannot see: two tools that lost the
same value together would still agree with each other. `StdioServerTests.testProviderEnumMatchesSelectableProviders` read the enum as `[String]` and now reads `[Any]`, filtering the string members; its subject is unchanged and the null-count assertion is left to B111.

**Verification.** Mutation-proven twice. Restoring the original defect in `web_answer` alone makes
the lint fail with exactly `web_answer.inputSchema: discovery argument provider differs from the
schema this tool mirrors, so a client cannot discover the ids the server accepts`, and the focused
test reports the complete missing id set plus the description divergence. Running the **pre-fix**
test file against that same defective tree passes (6 tests, 0 failures, 0.651 s), which is the
omission the finding describes and shows the new comparison is load-bearing rather than incidental.
Both files were restored from copies and verified byte-identical (`diff` empty; SHA-256 equal to the
backups). Debug and release build with 0 warnings under `-warnings-as-errors`; **494 tests, 6
skipped, 0 failures** (493 plus the one new test method); `swift-format --strict` 0 diagnostics and
`swiftlint --strict` 0 violations in 84 files. Artifact:
`AUDIT/evidence/B110-web-answer-provider-enum.txt`.

**Noted, not changed.** `web_answer.mode` and `web_search.mode` remain two literals with the same
three values; the parity lint now fails the build if either changes alone. The duplicated *parsing*
block in `ToolHandlers` is B58's subject and is untouched.

## B50 — provisioning destroyed the working instance before its replacement was proven

**Severity S3** (recorded) · **category** incomplete · **status** DONE · **host** node1 (arm64)

**What was wrong, and whether the residue is real.** The canary validates the image and settings
on a spare loopback port, so the original "a bad pull bricks the node" window is narrowed - but the
canary never exercises the production `-p ${SEARXNG_PORT}:8080` binding. A port conflict, a
`docker run` error, or a container that starts and never answers JSON on the production port all
land **after** `docker rm -f mcps-searxng`, and the node keeps no compose file, tag or retained
image for the old container. `fail` then leaves it serving nothing with no in-place recovery. The
residue is real, not theoretical.

**The fix shape, and why not the alternatives.** A "temporary port" would repeat the canary's
mistake of never exercising the production binding, and a "temporary name" on the production port
cannot coexist with the old container still holding it. The only shape that proves the production
binding is to vacate the port **reversibly**: rename the old container aside and `stop` it (frees
the port, keeps the configuration), run the replacement under the canonical name on the production
port, and `rm` the old one only after the production-port health check passes. Every fallible step
routes through `swap_fail`, which removes a partial replacement, renames the old container back and
starts it. A first provision has no previous container, so the restore is a no-op and old behaviour
is unchanged.

**Verification.** A harness extracts the swap functions verbatim (fixed) and the inline block
verbatim from the previous commit (unfixed), and stubs `docker` so that `rm` deletes configuration
while `stop` only clears a running marker - that asymmetry is what makes the test meaningful. RED:
3 of 6 cases fail, `run-fail-after-rm` leaving no container at all and `health-fail-after-rm`
leaving the unproven replacement holding the port. GREEN: 6 of 6. `bash -n` passes; shellcheck's
finding set is unchanged; the B86 and B48 harnesses still pass 10/10 and 6/6, so the earlier fixes
are composed with rather than undone. Provisioning was not run. Artifact:
`AUDIT/evidence/B50-provision-rollback.txt`.

**Noted, not fixed.** A SIGKILL between the `stop` and the rollback leaves the old container
stopped and renamed aside - configuration still on the node, one rename and start from serving. The
EXIT trap was deliberately not extended, because doing so would break B86's verified trap.

## B112 — `statusInput` was the only object schema that omitted `required`

**Severity S3** (recorded) · **category** style · **status** DONE · **host** node1 (arm64)

**What was wrong.** Every object schema in `Sources/SwiftWebSearchMCP/ToolSchemas.swift`, including
all the nested ones, declares an explicit `required` list; only the zero-argument `web_search_status`
input did not. The comment inside `statusInput` shows the author was reasoning about
strict-validation rules for exactly this schema and covered `properties` while missing `required`,
so the tool advertised a structurally different contract from every other tool. The repository lint
could not catch it: it inferred an absent `required` as the empty set and compared that to the
(also empty) property set, so the omission was invisible to the guard that exists to catch it.

**The fix.** `statusInput` declares `"required": []` — empty because there is nothing to require —
and the file header bullet now states the rule for both keys. The structural lint was strengthened
rather than duplicated: the same recursive check that already walks every advertised input and
output schema now appends a violation when an object schema has no `required` key, and the rule
table at the top of `SchemaCompatibilityTests` gained the matching row. No public signature changed,
and no new test method was added: `testAllAdvertisedSchemasSatisfyCrossClientRules` fetches the real
`tools/list` output from a freshly started server and is now strictly stronger.

**Verification.** Mutation-proven twice. Removing `"required": []` from `statusInput` makes the lint
fail with exactly `web_search_status.inputSchema: object schema without required`. Leaving the
defect in place and reverting only the strengthened line makes the same test pass in 0.099 s, which
is the omission the finding describes and shows the new check is load-bearing rather than incidental.
Both files were restored from copies and verified byte-identical (`diff` empty, SHA-256 equal to the
backups). Debug and release build with 0 warnings under `-warnings-as-errors`; **493 tests, 6
skipped, 0 failures** (unchanged from B109, since this task strengthens an existing test rather than
adding one); `swift-format --strict` and `swiftlint --strict` clean over 84 files. Artifact:
`AUDIT/evidence/B112-status-input-required.txt`.

**Noted, not changed.** `testRootIsAlwaysAClosedObject` still asserts `properties` on the root
without asserting `required`; the recursive walk already covers every root, so a second assertion
there would be the parallel check the finding asked not to add.

## B109 — the response-level resale discount overrode the per-result attribution

**Severity S3** (recorded) · **category** logic · **status** DONE · **host** node1 (arm64)

**What was wrong.** `RankFusion.fuse` documented in the comment directly above the code that the
aggregator discount is decided per result — one instance can serve one page from Brave and another
from an engine nobody else owns — and then ORed the response-level answer into the per-result one:
`duplicatedOwnedIndex: responseResellsOwnedIndex || resoldFamily != nil`. One resold page therefore
discounted every sibling in the response, including pages whose own `upstreamEngines` named nobody
else's index, so the per-result refinement did nothing once the response-level list also matched.
Separately, `resellsIndexAlreadyOwned` omitted the `family.isIndependentIndex` guard that the
per-result `resoldFamily` applies, so a response-level hit on Google or DuckDuckGo counted as
duplicating an "owned index" — the same provenance was judged differently depending on which level
the adapter reported it at. Both are reachable: `SearXNGProvider` and `OpenWebSearchProvider`
populate the response-level list and, when the vendor gives per-item `engine`/`engines`, the
per-result list as well (`engines(of:)` returns nil when the item carries none).

**The fix.** A result that carries its own `upstreamEngines` is judged on that attribution alone;
the response-level list is consulted only when `result.upstreamEngines` is nil, which is exactly
"the adapter could not attribute this result". `resellsIndexAlreadyOwned` gained the same
`isIndependentIndex` guard as `resoldFamily`, and its doc comment now says the two must agree. No
public signature changed and `weight` is untouched.

**Verification.** Three tests were added to `RankFusionTests` and one existing test was extended.
The primary test holds a response whose response-level list names Brave while its two results name
Brave and Wikipedia, and asserts the resold page scores `1/61 + 0.7/61` while its sibling keeps the
full `1/62` — the only assertion that distinguishes the two levels. The fallback is pinned with
both results unattributed (`0.7/62`), and the guard with a Startpage-plus-Google-SearXNG pair
(`1/61`), plus a direct `resellsIndexAlreadyOwned` assertion for `[.google]`. Each mutation goes red
on its own test: restoring the OR scores the sibling `0.7/62`; dropping the guard fails both the
fuse-level and direct assertions; deleting the fallback scores the two response-level results
`1/61` and `1/62`. Debug and release build with 0 warnings under `-warnings-as-errors`; **493 tests,
6 skipped, 0 failures** (the 490 baseline plus 3); `swift-format --strict` and `swiftlint --strict`
clean over 84 files. Artifact: `AUDIT/evidence/B109-response-level-resale-discount.txt`.

**Noted, not changed.** The response-level fallback deliberately does not fold the contribution
family the way the per-result path does: with only a response-level list there is no way to say
which result belongs to the owned index, so the whole response is discounted but keeps its own
family. That asymmetry predates this task, is covered by
`testAggregatorAloneIsDiscountedAgainstIndependentIndex`, and is left alone.

## B86 — provisioning wrote through fixed, predictable `/tmp` paths and loaded an image from one

**Severity S3** (recorded) · **category** unsafe · **status** DONE · **host** node1 (arm64)

**What was wrong.** Nine writes went through fixed, predictable `/tmp` paths, and the container
image was loaded from `/tmp/searxng-image.tar`. Separating the two: the **real exposure is the write
targets**, because `>` follows a symlink, so any local user able to create `/tmp/brew-install.log`
could make this cached-sudo run truncate a file that account can write (measured: a 29-byte target
went to zero). The **unverified load is defence in depth**, not the primary control - the container
is always *run* by the digest-pinned reference, so a tampered tarball cannot simply execute, and the
missing check only let the load proceed unverified while the canary proved nothing about provenance.

**The fix.** One private, unpredictable scratch directory (`mktemp -d`, then `install -d -m 700`)
holds every log and the staged tarball, removed by an `EXIT` trap that prints bounded log tails on
the failure path so the existing `see <path>` messages stay honest. The tarball is now explicit
(`SEARXNG_IMAGE_TAR`) with no `/tmp` default, and after `docker load` its `RepoDigests` is compared
to the pinned reference, failing closed on a mismatch.

**Verification.** A harness extracting the blocks verbatim from the previous commit shows 9 of 10
cases missing the fixed behaviour before and 10 of 10 present after; fail-closed is demonstrated
behaviourally, not just asserted. `bash -n` passes and shellcheck's finding set is unchanged.
Provisioning was not run. Artifact: `AUDIT/evidence/B86-provision-temp-paths.txt`.

**Operator-visible change.** The tarball is no longer auto-picked up; it must be passed as
`SEARXNG_IMAGE_TAR=…`, and if set but not a file the run stops rather than pulling.

## B78 — `ProviderStatus.State.probing` and `.unavailable` were unreachable

**Severity S3** (recorded) · **category** dead · **status** DONE · **host** node1 (arm64)

**What was wrong.** `ProviderStatus.State` declared six cases but only four could be produced: `pending(provider:configured:hint:)` starts at `.configuredButIdle` or `.notConfigured`, and `applying(_:)` assigns `.healthy` or `.failing`. Nothing assigned `.probing` (the monitor builds a fresh immutable model only after all probes return, so it cannot draw an in-flight probe) or `.unavailable`, yet `Renderer` implemented a glyph and a colour for both - including the "N/A" presentation that looked like an enabled-but-unusable provider's state while being permanently unreachable. The other `.probing` hit in the tree is `ProviderHealth.Status.probing`, a different enum.

**The decision.** Delete the two cases and their three render branches rather than invent producers, the same call B65 made for `NodeStatus.State.skipped`. `.probing` would need the monitor to publish a partially updated model mid-cycle, which the design deliberately avoids. `.unavailable` describes an operator-disabled provider, and **B76** (still open) is the task whose `expected-correct` says a disabled provider must be presented as unavailable; that producer belongs to B76, so the dead branch is removed here rather than left for it to inherit.

**Verification.** A grep before the change showed the two declarations whose only other uses were the render branches, with no producer and no test constructing either. The compiler and the suite prove nothing referenced them: a temporary test method naming both removed cases fails the build with `type 'ProviderStatus.State' has no member 'probing'` / `'unavailable'`, and the file was restored byte-identically (`diff` clean). Debug and release build with 0 warnings under `-warnings-as-errors`; **490 tests, 6 skipped, 0 failures** (unchanged, because no test can name a deleted case); `swift-format --strict` and `swiftlint --strict` clean. Artifact: `AUDIT/evidence/B78-dead-provider-states.txt`.

## B64 — a non-SearXNG body from a live node was reported as "unreachable"

**Severity S3** (recorded) · **category** bug · **status** DONE · **host** node1 (arm64)

**What was wrong.** `NodeProbe.probe` decoded the body with `JSONCoding.decoder().decode(SearXNGProbeResponse.self, …)`, which throws a `DecodingError` for anything that is not a SearXNG payload. That is neither a `SearchError` nor a transport error, so it fell through to the generic `catch` and produced `state: .down, error: "unreachable"`. An instance answering `200 OK` with an HTML error page under a JSON content type, a proxy's own JSON body, or a JSON error object was therefore shown as `DOWN / unreachable` - sending the operator after a network fault that does not exist, exactly the misdiagnosis the adjacent `403` branch was written to avoid.

**The fix.** A dedicated `catch is DecodingError` reports `.degraded` with the parse reason `JSON response was not a SearXNG payload` and the elapsed latency (recomputed inside the catch, because a catch clause does not see the `do` block's locals). `.down`/`unreachable` now covers only genuine transport failures, and a client-level `SearchError` keeps its existing `.down` + `safeDescription` treatment.

**Verification.** The old test pinned the defect by asserting `.down`, so it was replaced rather than left to contradict the fix: `testMalformedBodyIsDegradedNotUnreachable` covers a body that is not JSON at all and `testNonSearXNGJSONIsDegradedNotUnreachable` covers valid JSON of the wrong shape, while `testTransportFailureIsDown` still pins that a real connection failure stays `.down`. Deleting the new catch arm turns both new tests red (`down` vs `degraded`, `"unreachable"` vs the parse reason) and the file was then restored byte-identically (`diff` clean). Debug and release build with 0 warnings under `-warnings-as-errors`; **490 tests, 6 skipped, 0 failures** (489 + 1); `swift-format --strict` and `swiftlint --strict` clean. Artifact: `AUDIT/evidence/B64-malformed-json-reported-unreachable.txt`.

## B116 — a local throttle that cleared between two reads was reported as a hard skip

**Severity S3** (recorded) · **category** bug · **status** DONE · **host** node1 (arm64)

**How it was found.** Establishing the baseline on the independent host showed the suite is **not**
reliably green: `StdioServerTests.testToolArgumentClampsAreEnforced` failed about once in twenty
runs, at `XCTUnwrap` on the second `web_search`'s structured results. That rate matches the
observed 1-in-21, and a flaky end-to-end test is a Phase E blocker rather than a nuisance.

**What was wrong.** Two defects on the same boundary. `authorizationAfterBoundedWait` combined the
wait lookup into one `guard`: `authorize` denies because `elapsed` is just under the limiter's
`minimumInterval`, then `localWait` re-reads the clock a few microseconds later and correctly
reports "available now" by returning **nil** — which the guard read as "cannot wait" and returned
the stale denial. The provider was recorded as `skippedLocally`, nothing was returned, and with a
single provider the tool call became an error with no structured content. Separately,
`RateLimiter.timeUntilAvailable`'s minimum-interval branch truncated (`Int(remaining * 1000)`) while
the token branch below it rounded up, so an estimate could be up to a millisecond short — or
`.milliseconds(0)` for a sub-millisecond remainder.

**The fix.** A nil estimate now means the throttle already cleared, so `authorize` is retried once;
only a non-nil estimate beyond either cap gives up. The remainder is rounded up and a value that
rounds to zero reports nil, matching the token branch.

**Verification.** The race is deterministic rather than sampled: a new `CreepingClock` advances 1 ms
on every `now()` read, so the two reads land on opposite sides of the boundary every run. Three
tests cover the race, the rounding property, and "elapsed interval is nil, not a zero wait". Each
mutation goes red on its own test: reverting the orchestrator arm produces exactly the diagnosed
`temporarilyUnavailable([...rateLimited])`, and reverting the rounding fails both rounding
assertions. Debug and release build with 0 warnings under `-warnings-as-errors`; **489 tests, 6
skipped, 0 failures** (the 486 baseline plus 3); `swift-format --strict` and `swiftlint --strict`
clean. 33 consecutive full-suite runs were green, but the deterministic mutation is the proof — 32
clean runs of a 1-in-20 flake is only about 81 % confidence. Artifact:
`AUDIT/evidence/B116-local-throttle-race.txt`.

**Noted, not changed.** `ProviderHealth.authorize` claims a half-open breaker probe before
consulting the limiter, so in the unrelated half-open-plus-just-cleared-limiter case the retry can
surface `circuitOpen` rather than `rateLimited`. The search outcome is the same skip, and it is
outside this task's scope; recorded so it is not rediscovered as a surprise.

## B48 — `provision-node.sh` could not find a Homebrew Tailscale CLI on Apple Silicon

**Severity S3** (recorded) · **category** bug · **status** DONE · **host** node1 (arm64)

**What was wrong.** The READY-address lookup tried exactly two hard-coded locations:
`/usr/local/bin/tailscale` (the Intel Homebrew prefix) and then the `.app` bundle. On an Apple
Silicon node with the Homebrew formula installed the CLI is at `/opt/homebrew/bin/tailscale`, which
neither path covers, so the script printed a LAN fallback address instead of the Tailscale address
the monitor and the wiki use - and, per the comment it defeated, sent an operator hunting for a
network fault that was really a lookup miss.

**The fix.** `tailscale_cli()` tries `command -v tailscale` first, which works because the
Homebrew section earlier in the script has already applied this node's `shellenv`, and then falls
back over the three explicit known paths. It returns the path rather than probing a directory plus
a basename: on the case-insensitive macOS filesystem `[ -x "$dir/tailscale" ]` is true when only
`$dir/Tailscale` exists, so that approach printed a filename not on disk. There is no `|| fail`
because nothing mutates and a missing CLI intentionally falls through to the LAN address.

**Verification.** A harness extracts `tailscale_cli()` verbatim for GREEN and the pre-fix two-line
lookup verbatim for RED, against fake bin directories whose stubs record their own `$0`, so it
asserts the path selected and not merely an address: RED selects nothing in 5 of 6 cases
(including the decisive `/opt/homebrew/bin` row), GREEN selects the expected path in 6 of 6, and
integrating the real call-site lines with the fake `/opt/homebrew` stub on `PATH` yields the
expected CLI and canned IP. `bash -n` passes; shellcheck's finding set is unchanged. No node was
provisioned. Artifact: `AUDIT/evidence/B48-tailscale-discovery.txt`.

## B83 — HTTP smoke could wait 20 s on a dead server and never check that it was alive

**Severity S3** (recorded) · **category** bug · **status** DONE · **host** node1 (arm64)

**What was wrong.** `free_loopback_port()` closes its probe socket before the child starts, so the
child can lose the bind race; `wait_for_health` then never called `process.poll()` and never read
the captured stderr. A server that had already exited produced a silent 20-second wait ending in
`HTTP transport did not become healthy on port N` - blaming the port for a process that was already
dead, and discarding the stderr that said why.

**The fix.** `wait_for_health` takes the child and polls it on every pass; an exited child is
reported at once with its exit code and stderr, read by a new never-raising `child_stderr` helper.
The original timeout message is kept for the live-but-never-healthy case, which is a different
failure.

**Verification.** A check drives the real `run_http_smoke` with a child that exits 1 without
binding. Against the reverted code all three assertions fail at 20.05 s elapsed with the port-only
message; with the fix all three pass at 0.79 s naming the dead server and its stderr. A separate
sanity check confirms the guard returns rather than raising on a live, healthy child. ruff,
`ruff format --check` and pyright strict are clean. Artifact:
`AUDIT/evidence/B83-smoke-dead-server.txt`.

**Deliberate deviation, and the residual it leaves.** The finding's expected-correct also offered
"keep the probe socket until the child has bound, or retry a fresh port on bind failure". Holding
the parent socket cannot work - the child does its own bind and would get `EADDRINUSE`, since
macOS `SO_REUSEADDR` does not permit two live binders - and a retry is a behavioural change beyond
the reported defect. The race itself therefore remains and is recorded as **B117** rather than
quietly closed with the symptom.

## B82 — a negative `--queries` silently truncated the query list from the end

**Severity S3** (recorded) · **category** bug · **status** DONE · **host** node1 (arm64)

**What was wrong.** `--queries` was a plain `type=int` and the run did
`queries = QUERIES[: args.queries]`. Python's negative-slice semantics then took queries from the
**end**: `--queries -3` ran 48 of 51 while the header presented 48 as what was requested, and
`--queries -100` ran nothing and exited 0. A soak that silently measures a different run from the
one asked for is worse than one that refuses.

**The decision.** The finding allowed reject-or-clamp; rejection is taken, with the finding's own
suggested message, placed before binary resolution so it costs no subprocess. The guard is `<= 0`
rather than `< 0`: zero is not positive and matches the message, and a zero-query run would
otherwise reach `run_verdict` and be reported as "requested provider(s) contributed to no query" —
blaming providers for an empty request. That extension beyond the literal negative case is the one
judgment call and is recorded in the artifact.

**Verification.** A check drives the real `soak.main()` through `sys.argv` with a missing binary,
pinning `-3`, `-100`, `0` and `1`. RED (guard removed) fails on the message; GREEN returns exit 2
with `--queries must be positive` for the three rejected values and accepts `1`. ruff,
`ruff format --check` and pyright strict are clean. A full soak needs real providers and the
binary; the guard sits upstream of binary resolution, so that is not needed to pin the contract.
Artifact: `AUDIT/evidence/B82-negative-queries.txt`.

## B49 — the generated `settings.yml` inherited the umask, so the node secret was world-readable

**Severity S3** (recorded) · **category** unsafe · **status** DONE · **host** node1 (arm64)

**What was wrong.** The script generates a per-node key, writes it to a `0600` file, then
substitutes the same value into `settings.yml` - which a plain redirect creates `0644` under the
default umask, with no `chmod` applied. The key the key file protects was copied into a
world-readable one. Impact is limited (single-operator Mac minis, no accounts, `limiter: false`,
`public_instance: false`), but two files holding the same secret disagreeing about who may read it
is a defect regardless.

**A hypothesis the test disproved.** The first fix wrapped the `sed` in a `umask 077` subshell,
assuming `sed -i` replaces the file and therefore takes the umask's mode. Measuring shows that is
false here: BSD `sed -i` **preserves** the original mode (a `0600` input stays `0600`). The fix was
redirected accordingly, and the wrong assumption and the measurement that killed it are both in the
artifact - the umask version would have looked correct and passed a check that only ever started
from `0644`.

**The fix.** Two changes for different reasons: a guarded `chmod 600` **before** the substitution,
so the secret never lands in a `0644` file even momentarily (it survives the `sed` because the mode
is preserved); and a `chmod 600` **inside** `install_secret_key` after the substitution, which is
what the finding asks for and makes the mode a property the function guarantees rather than one its
caller happens to have set.

**Verification.** RED: mode 644 with the key present, exit 1. GREEN: mode 600, placeholder gone, key
present, exit 0. `bash -n` passes; shellcheck's finding set is identical to HEAD's; the B17
assertions are untouched. Provisioning a real node was deliberately not run. Artifact:
`AUDIT/evidence/B49-settings-mode.txt`.

## B81 — `mcp_smoke.py` de-chunked an SSE body after decoding it to `str`

**Severity S3** (recorded) · **category** bug · **status** DONE · **host** node1 (arm64)

**What was wrong.** `http_exchange` decoded the whole response to `str` and *then* de-chunked it.
A chunk header carries a **byte** count, so framing the decoded text applies that count to
character offsets: any multi-byte character in the body shifts every later boundary, truncating or
corrupting the recovered stream. The harness would then report a protocol failure that the server
did not cause - the worst kind of false negative in the smoke test that exists to prove the
transport works.

**The fix.** The head/body split, the status line and the header loop read a decoded head, while
the de-chunk loop is framed on the raw bytes; the body is decoded once, at the end. `raw_body` is
used rather than `body` because the latter is the existing request-parameter name - pyright strict
caught the shadowing on the first attempt.

**Verification.** A check drives the real `http_exchange` with `socket.create_connection` stubbed
to return one chunked SSE response whose `note` is `é日本語` with the chunk boundary inside a
multi-byte character. Against the reverted framing it fails with `AssertionError: corrupted: []`
(exit 1); with the fix it recovers the exact string (exit 0). Two payload shapes are red - one
losing the whole message, one corrupting it - so the check is not tuned to a single symptom. ruff,
`ruff format --check` and pyright strict are clean. The real `--http` smoke needs the Swift binary
and was not run; the framing helper itself is exercised end to end. Artifact:
`AUDIT/evidence/B81-sse-dechunk.txt`.

## B108 — the pinned actions targeted the deprecated Node 20 runtime

**Severity S3** (recorded) · **category** deps · **status** DONE · **host** node1 (arm64)

**What was wrong.** Three `uses:` pins declared the `node20` action runtime, so every dispatched
run carried a `Node.js 20 is deprecated ... forced to run on Node.js 24` annotation against
`actions/cache@5a3ec84e` and `actions/checkout@11bd7190` (lines 44, 103 and 213). The jobs pass
today only because the runner forces the action onto Node 24; when that shim is withdrawn the
steps stop running, which turns a maintenance warning into a red build for an unrelated change.

**The decision.** Take the current stable of each (`checkout` v7.0.1, `cache` v6.1.0) rather than
the oldest release that declares `node24` (`v5.0.0` of each). `v5.0.0` is the node24 switch and
nothing else, so it is the smaller change — but these pins are SHA-frozen and nothing auto-updates
them, so `v5.0.0` would land the repository two and one majors behind on action code that runs
with repository credentials, and `checkout` v7 additionally refuses fork-PR checkout for
`pull_request_target`/`workflow_run`. Both require Actions Runner ≥ `2.327.1`, satisfied by the
GitHub-hosted `macos-26` runners. Our usage is the default minimal form of both actions, so the
ESM migrations in `checkout` v6-v7 and `cache` v6 touch no input this workflow reads.

**Verification.** Each candidate's `runs.using` was read from its own `action.yml` at the tag's
commit, and each pinned SHA was asserted to be that tag's commit rather than trusted from the
version comment. The workflow still parses and both jobs survive. The annotation-free dispatched
run is the one thing a local check cannot assert and is recorded with the run id. Artifact:
`AUDIT/evidence/B108-action-runtime-pins.txt`.

## B80 — `soak.py` conflated EOF with a malformed stdout line and discarded the line

**Severity S3** (recorded) · **category** bug · **status** DONE · **host** node1 (arm64)

**What was wrong.** `Server.read()` returned `None` for both an empty read and a line that failed
`json.loads`. Its caller treats `None` as "the server closed stdout", so a corrupted protocol
stream was reported as a clean end of stream and the offending line was thrown away - the one
piece of evidence that would have explained the failure.

**The fix.** `None` now means end of stream only; a `JSONDecodeError` raises a `RuntimeError`
carrying the decoder message and the offending line, which `request()` propagates because it has
no `except` around `read()`.

**Verification.** A check driving `read()` over a fake process with a `StringIO` stdout goes red
against the reverted code (`AssertionError: malformed protocol line was discarded as if stdout
had closed`) and green with the fix; an empty stream still returns `None`. ruff, `ruff format
--check` and pyright strict are clean. The end-to-end request path needs a live soak and provider
credentials, which was not run; that limit is stated in the artifact rather than implied. Artifact:
`AUDIT/evidence/B80-soak-eof.txt`.

**Noted, not fixed (out of B80's scope).** `json.loads` can still return a non-dict (a bare JSON
array or scalar), which would make `request()`'s `message.get()` raise `AttributeError`. B80's
expected-correct covers only the `JSONDecodeError`/EOF conflation, so no type check was added; it
is recorded here so it is not rediscovered as a surprise.

## B115 — the README undercounted the keyless routes and mis-stated two `Needs` cells

**Severity S3** (recorded) · **category** docs · **status** DONE · **host** node1 (arm64)

**What was wrong.** The heading claimed four keyless routes and never stated the rule behind the
number, so it could not be checked - and it was not the rule the code implements. Five adapters
need no vendor credential (`DuckDuckGoProvider.swift:52`, `OpenWebSearchProvider.swift:51`,
`ParallelMCPProvider.swift:63`, `SearXNGProvider.swift:43`, `StartpageProvider.swift:49`), split
as two gated on an endpoint you supply (SearXNG, Open Web Search), two opt-in scrapers, and
Parallel on its flag. The README's four excluded Open Web Search for needing a supplied endpoint
while including SearXNG, which needs one for exactly the same reason; Open Web Search's own row
said "Aggregation endpoint", three rows below a claim implying it did not belong in the keyless
group. Two `Needs` cells were wrong independently: SearXNG said `Docker only` although
`SEARXNG_BASE_URL` is equally required, and Startpage said `none` although the adapter is inert
until `SEARCH_ENABLE_SCRAPERS=true`, so the two opt-in scrapers read inconsistently.

**The fix.** The count is five, the rule is stated in the sentence so it is checkable, and the
three inaccurate cells are corrected. Artifact: `AUDIT/evidence/B115-readme-keyless-routes.txt`.

## B41 — Apache-2.0 `NOTICE` files were not carried with any distributed binary

**Severity S3** (recorded) · **category** deps · **status** DONE · **host** node1 (arm64)

**What was wrong.** The project is MIT but links Apache-2.0 packages, and Apache-2.0 §4(d)
requires a work that is *distributed* to reproduce the attribution notices of the Apache-2.0
components it contains. No `NOTICE`/`THIRD-PARTY` file existed under any name and no release step
produced one, so a shipped binary carried no attribution.

**The licence facts, read from the resolved checkouts.** Eight packages, and the obligation is
narrower than the finding assumed:

| package | version | licence | runtime exception | `NOTICE.txt` |
| --- | --- | --- | --- | --- |
| `eventsource` | 1.5.1 | MIT | n/a | — |
| `swift-atomics` | 1.3.1 | Apache-2.0 | **yes** — §4(a)/(b)/(d) waived | — |
| `swift-collections` | 1.6.0 | Apache-2.0 | **yes** — §4(a)/(b)/(d) waived | — |
| `swift-log` | 1.15.1 | Apache-2.0 | no | **yes** |
| `swift-nio` | 2.102.0 | Apache-2.0 | no | **yes** |
| `swift-sdk` | 0.12.1 | MIT + Apache-2.0, mixed | n/a | — |
| `swift-system` | 1.8.1 | Apache-2.0 | **yes** — §4(a)/(b)/(d) waived | — |
| `SwiftSoup` | 2.13.5 | MIT | n/a | — |

Three packages carry the Swift Runtime Library Exception, whose text (verified byte-identical
across all three) waives the §4(a)/(b)/(d) attribution for code embedded into a compiled binary,
so their notices are **not** required. `swift-sdk` is mid-transition MIT→Apache-2.0 and ships no
`NOTICE.txt`; it is recorded as mixed with both texts carried rather than asserting one.

**The decision.** Add `THIRD-PARTY-NOTICES.md` rather than invent a release step, because there is
no release workflow and a committed file is checkable. It carries a machine-readable inventory, the
licence notes, the verbatim `NOTICE.txt` of `swift-nio` and `swift-log`, and the full Apache-2.0,
Runtime Library Exception and both MIT texts. `scripts/third_party_notices.py` then compares the
inventory against `Package.resolved` in both directions — the same authority the lockfile gate uses
— and runs as a CI gate. It deliberately does **not** generate the file: copying a licence in
automatically is how an unlicensed or copyleft dependency gets shipped unremarked, so each licence
is read by hand and the check only proves the inventory stayed complete.

**Verification.** The gate was shown to fail under three mutations — drop the `swift-nio` row,
invent an unresolved package, mis-state a version — each exiting 1 with its own `::error` line; the
first is the silent failure this task is about. ruff, `ruff format --check`, pyright strict (0
errors), `swift-format --strict` and `swiftlint --strict` are clean. Artifact:
`AUDIT/evidence/B41-third-party-notices.txt`.

## B01 — the compose secret-key override named a variable SearXNG never reads

**Severity S0** (recorded) · **category** placeholder · **status** DONE

**What was wrong.** `deploy/docker-compose.yml` documented `SEARXNG_SECRET_KEY`, and
`deploy/searxng/settings.yml` tracked `secret_key: "change-me-local-only-not-a-credential"`.
Checked against the **pinned image**, not upstream master: `settings_defaults.py:218` declares
`'secret_key': SettingsValue(str, environ_name='SEARXNG_SECRET')`, and `SettingsValue.__call__`
overrides the value with the environment variable when it is set. So the documented variable did
nothing, and the literal in git was the key signing sessions. The image's own "generate a random
key" path only runs when no settings file is mounted, which is not this deployment.

**Fix.** The key now comes from the environment only: compose requires
`SEARXNG_SECRET=${SEARXNG_SECRET:?...}` and `settings.yml` no longer sets `secret_key`, so there
is no tracked placeholder to take effect. `deploy/.env.example` (git-ignored when copied to
`.env`) shows the `openssl rand -hex 32` one-liner, and the wiki's installation and self-hosting
pages describe it. Both layers fail closed: compose refuses to render without the variable, and
SearXNG itself refuses to start with its shipped placeholder.

**Evidence after** ([`evidence/B01-searxng-secret.txt`](evidence/B01-searxng-secret.txt))

| Check | Result |
| --- | --- |
| `docker compose config` with no key | exit 1, `required variable SEARXNG_SECRET is missing a value` |
| `SEARXNG_SECRET=probe-value docker compose config` | renders `SEARXNG_SECRET: probe-value` |
| container with the new settings and no key | exits 1, `server.secret_key is not changed` |
| throwaway container with a key, `q=swift&format=json` | HTTP 200, 21 results |

The live `mcps-searxng` instance on `127.0.0.1:8888` was not restarted, recreated or touched: the
verification used a separate container on port 18888, which was removed afterwards.

**Still open (`B02`-adjacent, not this task).** `deploy/provision-node.sh` writes a *generated*
per-node key into its own `settings.yml` (unchanged here) and its unchecked `sed` is tracked
separately; the file mode of that generated settings file is `L7-12`/`L4-11`.

## B06 — untrusted seconds were converted `Double` → `Int` without a range check

**Severity S1** · **category** unsafe · **status** DONE · merges `L4-1` (Retry-After) and `L3-3` (`mcps-mon --interval`)

**What was wrong.** Three sites turned a number from an untrusted source into `Int` milliseconds
with `Int(max(0, seconds) * 1000)`: `RetryAfter.parse` (the `Retry-After` header, reachable from
any provider 429 through `HTTPStatusMapper.validate`, from an idempotent retry inside
`URLSessionHTTPClient`, and from Jina Reader), `JinaReaderFetcher.retryAfterFromBody` (a
`{"retryAfter": 1e33}` body), and `Options.parse`'s `--interval` (a command line argument).
`Double` → `Int` **traps** past `Int.max`, and `inf`/`nan` trap too, so `Retry-After: 1e30` or
`--interval inf` killed the process: every connected MCP client lost service, or the monitor died
before its first frame.

**Fix.**

* `RetryAfter.boundedDuration(seconds:)` is now the single conversion both `Retry-After` callers
  use. Non-finite input returns nil, so the caller falls back to its own backoff; finite input is
  clamped into `0...RetryAfter.maximumSeconds` (24 h) *before* the multiply.
* Callers still clamp to their own policy (`HTTPPolicy.maxRetryAfter`, 5 s by default), so
  ordinary retry timing is unchanged — the bound is about arithmetic, not about behaviour.
* `Options.parse` requires `isFinite` and `1...Options.maximumInterval.seconds` (86 400 s), and
  the usage text now names the range.

**Evidence** ([`evidence/B06-retry-after.txt`](evidence/B06-retry-after.txt)) — with the pre-fix
conversions restored temporarily, the new tests kill the runner:

| Restored pre-fix code | Result |
| --- | --- |
| `Int(max(0, seconds) * 1000)` in `RetryAfter` | signal 5, `Fatal error: Double value cannot be converted to Int because the result would be greater than Int.max` |
| `guard let seconds = Double(raw), seconds >= 1` for `--interval` | signal 5, `Fatal error: Double value cannot be converted to Int because it is either infinite or NaN` |

After: `DurationTests`, `FetchFallbackTests` and `HTTPClientTests` → 28 tests, 0 failures;
`MonitorOptionsTests` → 18 tests, 0 failures; full suite **401 tests, 6 skipped, 0 failures**;
debug and release builds 0 warnings. Both pre-fix experiments were reverted.

---

---

## B02 — the redirect loop is the SSRF boundary for redirects and had no test at all

**Severity S0** (as recorded by the L6 pass) · **category** test · **status** DONE

**What was wrong.** No test in the suite ever returned a 3xx. `DirectHTTPFetcher` disables
`URLSession`'s own redirect following and walks redirects itself, re-validating every hop through
`URLPolicy` — that loop is the entire SSRF boundary for redirects, and it could have been deleted,
or had its hop validation removed, with every other test still green.

**Fix.** `Tests/WebSearchCoreTests/FetchRedirectTests.swift` (7 tests): a hop is followed and
reported (`finalURL`, warning, one request each), a relative `Location` resolves against the
current URL (`requestPaths == ["/", "/final"]`), `maxRedirects` is enforced (exactly
`maxRedirects + 1` requests, then `extractionFailed`), a hop carrying credentials is refused by
the policy and never requested, a `file://` redirect returns no content, a 3xx without `Location`
is a fetch failure rather than a page, and the policy itself refuses a link-local metadata
address.

**Mutation evidence** ([`evidence/B02-redirect-tests.txt`](evidence/B02-redirect-tests.txt)) — the
finding's claim, tested rather than asserted:

| Mutation | Result |
| --- | --- |
| redirect handling deleted from `fetch` | `testARedirectIsFollowedAndReported` and `testARelativeLocationIsResolvedAgainstTheCurrentURL` fail with `upstream returned HTTP 302/301` |
| only the first hop validated, in-loop hop check removed | `testARedirectToACredentialedURLIsRefusedByTheHopPolicy` fails (the credentialed hop is requested); the other six stay green, so that test is the one pinning per-hop re-validation |

Both mutations were reverted and `DirectHTTPFetcher.swift` was verified byte-identical to HEAD
(`git show HEAD:<path> | diff - <path>`).

**Evidence after.** `swift test --filter FetchRedirectTests` → 7 tests, 0 failures; full suite
**397 tests, 6 skipped, 0 failures** (baseline 371); debug build 0 warnings.

**A boundary found while testing, recorded as `B102`, not fixed here.** A redirect to a different
scheme never reaches the manual loop: `URLSession`/CFNetwork refuses it internally without
consulting `NoRedirectDelegate`, so the caller sees "the transport reported error -1102" instead
of a policy denial. The probe used a *readable* `/etc/hosts` and confirmed no part of it is
returned, so this is a diagnosis and robustness gap (the guarantee rests on transport behaviour
rather than on our policy), not a leak. It is S3 and tracked separately so this task's scope stays
the redirect loop.

---

---

## A01 — HTML parse on a cooperative task stack exhausts the stack and kills the process

**Severity S0** — go-live blocker: remote denial of service / crash on a normal path ·
**category** unsafe · **status** DONE

**It reproduces WITHOUT any sanitizer, and that is what makes it S0.** A deeply nested HTML
document exhausts the stack and the process dies (SIGBUS, signal 10):

```bash
swift test --filter 'AUDITDiagnosticsTests/testD_deepNestingThresholdWithoutASan'
#  AUDIT depth=1000 start / survived (error: malformedResponse)
#  AUDIT depth=5000  start  ->  exited with unexpected signal code 10

swift test --filter 'AUDITDiagnosticsTests/testE_deepNestingThroughHTMLExtraction'
#  AUDIT extract depth=20000 start  ->  exited with unexpected signal code 10
```

* Scraper path (`DuckDuckGoProvider` → `ScraperSupport.parse` → `SwiftSoup.parse`): survives
  1,000 levels, **dies at 5,000** — about 25 KB of `"<div>"` repeated, on a cooperative task.
* `web_open` path (`HTMLExtractor.extract`, which parses arbitrary fetched pages): **dies at
  20,000** levels — about 100 KB of markup.

Both inputs are attacker-controlled and tiny. `web_open` is reachable from any MCP client
with one tool call against a hostile URL, and the failure mode is **process death**: every
connected client loses service until the server is restarted. That is why it is graded S0
rather than the S1 the ASan-only observation first suggested.

**Reproduction**

```bash
swift test --sanitize=address --scratch-path ~/Library/Caches/MCPSearch/audit-asan \
  --filter 'ProviderContractTests/testDuckDuckGoTaxonomy'
```

Result: `error: Process ... exited with unexpected signal code 6`, and

```
AddressSanitizer:DEADLYSIGNAL
ERROR: AddressSanitizer: BUS on unknown address (pc ... _platform_memset+0xb0)
The signal is caused by a WRITE memory access.
SUMMARY: AddressSanitizer: BUS (libsystem_platform.dylib:arm64e+0x3140) in _platform_memset+0xb0
```

The faulting thread is `Task 3` on `com.apple.root.user-initiated-qos.cooperative` — a Swift
concurrency task, whose stack is far smaller than the main thread's. `lldb` cannot unwind
past frame 0, and the faulting address is a stack address at the guard page, i.e. the write
runs off the end of the task stack.

**Attribution matrix** (`Tests/WebSearchCoreTests/AUDITDiagnosticsTests.swift`, temporary
audit tooling):

| Case | Path | Stack | Result |
| --- | --- | --- | --- |
| A | `ScraperSupport.parse` on the same 23-byte junk body | synchronous test (main thread) | **ok** |
| B | `DuckDuckGoProvider.search` with HTTP 200 + junk body | `async` (cooperative task) | **CRASH** |
| B102 | S3 | `WebSearchCore` (fetch) | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:245-256` (delegate), `Sources/WebSearchCore/Support/HTTPClient.swift:386` (message) | A cross-scheme redirect is refused by the transport, not by our policy, and surfaces as an opaque transport error | bug | DONE | this Mac (arm64) | Phase D (found while fixing B02) |
| B103 | S3 | `SwiftWebSearchMCP` (tools) | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:91-93`, `:142-143`, `:237-238`, `:262-263` | The tool-layer cancellation branches are still not exercised by any test | test | START | this Mac (arm64) | Phase D (found while fixing B04) |
| B104 | S3 | build/environment | `AppConfiguration.swift` + the audit scratch tree | `mcps-mon` appeared to crash on startup in a debug build: a stale incremental build, not a code defect | bug | DONE | this Mac | Phase D (found while testing B10) |
| B105 | S3 | repository hygiene | `scripts/__pycache__/*.pyc` (4 files) | Generated Python byte-code was committed to the branch | style | DONE | this Mac | Phase D (found while restoring the tree) |
| B106 | S3 | tests/scripts | `scripts/monitor_tty_smoke.py` | The PTY harness reports a crashing monitor as a first-frame timeout | test | DONE | this Mac | Phase D (found during B104) |
| B107 | **S2** | `MCPSMonitor` | `Sources/MCPSMonitor/main.swift`, `Monitor/Terminal.swift:165-171` | An externally delivered SIGINT or SIGTERM leaves the terminal in raw mode with the cursor hidden | bug | DONE | this Mac (arm64) | Phase D (found while fixing B10) |
| B108 | S3 | `.github` | `.github/workflows/ci.yml` (checkout/cache pins) | The pinned GitHub Actions still target Node 20, which the runner is deprecating, so every job runs on a forced Node 24 | deps | DONE | — | Phase D (CI annotations this round) |
| C | `DuckDuckGoProvider.search` with HTTP 200 + well-formed empty HTML | `async` (cooperative task) | **ok** |

Also: `HTMLExtractorTests` (SwiftSoup-heavy) ok, `testDuckDuckGoScraperEndToEnd` (real DDG
markup) ok, `testSearXNGTaxonomy` ok, and **ThreadSanitizer is clean** — so this is not a race
and not a data bug in the parser wrapper.

**Expected-correct behaviour.** A provider must never terminate the process. A response whose
body is not the expected markup, and a page with pathological nesting, must both degrade to a
`ProviderFailure`. `web_open` parses arbitrary attacker-controlled HTML through the same
parser (`Fetch/HTMLExtractor.swift`), so the same guarantee is required there.

**Why it is not dismissed as toolchain noise.** The reproduction needs ASan today, which
inflates per-frame stack usage; without it the suite passes. But the *class* of input is
untrusted and remotely reachable, the failure mode is process death (every connected MCP
client loses service), and the margin is unknown — so this is fixed as a guard, not waived.

**Threshold measurement** (no sanitizer, debug build, this Mac):

| Path | Depth | Result |
| --- | --- | --- |
| `DuckDuckGoProvider.search` (HTTP 200, nested markup) | 1,000 | clean `malformedResponse` |
| same | 5,000 | **SIGBUS — process death** |
| `HTMLExtractor.extract` | 20,000 | **SIGBUS — process death** |

**Fix (implemented · status DONE · commit `199a962`)**

1. **Reject a body that is not markup before parsing.** `MarkupDepth.containsMarkup` looks for a
   `<` that actually starts a tag, and `ScraperSupport.parse` fails such a response as
   `malformedResponse(provider)` instead of parsing a JSON error payload or a rate-limit notice
   as HTML. Scoped to the scrapers: `web_open`'s extractor deliberately still accepts markup-free
   text, because `text/plain`, JSON and YAML are allow-listed content types on that path.
2. **Bound nesting depth before the recursive parser runs.** `Fetch/MarkupDepth.swift` counts
   element depth on the raw bytes, iteratively, with an early exit. `MarkupDepth.maximumNesting`
   is 512 — the HTML specification's own limit and every browser's. Comments, declarations, void
   elements, self-closing tags and the content of raw-text elements (`script`, `style`, …) open no
   level; a `>` inside a quoted attribute value does not end a tag; a stray `<` in prose stays
   prose. Exceeding the cap throws the new `SearchError.markupDepthExceeded(limit)`, category
   `.malformedResponse`, whose message names the limit — so an operator can tell pathological
   nesting apart from a provider defect, and a scraper failure stays a `ProviderFailure`.
3. **Parse on a thread with an explicit large stack.** `Fetch/LargeStackParse.swift` runs the
   recursive part of both paths on a dedicated 8 MiB-stack thread (the main thread's size, about
   16× a cooperative task's), synchronously, publishing the outcome through a `Sendable`
   `OSAllocatedUnfairLock`: no unchecked conformance, no unsynchronised shared state, and provably
   deadlock-free because the parse thread performs no Swift concurrency work and therefore cannot
   be starved by a blocked cooperative thread.
4. **Regression tests.** `Tests/WebSearchCoreTests/MarkupDepthTests.swift`, 19 tests: 14 for the
   counter and its boundaries, the three original probe inputs converted into assertions on the
   same call paths, and a document *at* the cap parsed through `Task.detached`, i.e. on a
   cooperative task. The temporary `AUDITDiagnosticsTests.swift` probes were deleted in the same
   commit.

**A byte cap was deliberately not added.** The measured inputs are 25 KB and 100 KB, far below the
4 MiB response cap, so size does not bound depth; body size is already capped where bodies are
read (`maxBytes`/`maxCharacters`). A second limit here would bound nothing the existing caps do
not.

**Item 3 was promoted from belt-and-braces to load-bearing by measurement, and that is the honest
reason it is in the fix.** With the depth cap alone, a document *at* the cap still exhausted a
cooperative task stack under AddressSanitizer: the instrument inflates frames enough that 512
levels no longer fit. Rather than lower the cap until the instrument was satisfied — which would
have made a production parameter depend on a debug build — the parse got a stack with room for
the bound, which is the control that actually removes the stack from the safety margin.

**Evidence after** ([`evidence/A01-asan.txt`](evidence/A01-asan.txt))

| Command | Result |
| --- | --- |
| `swift test --sanitize=address --filter 'MarkupDepthTests\|ProviderContractTests\|HTMLExtractorTests'` | **81 tests, 0 failures, exit 0** — the run that previously ended in `AddressSanitizer: BUS`, now including a 512-deep document parsed on a cooperative task |
| `swift test --filter 'MarkupDepthTests\|HTMLExtractorTests\|FetchFallbackTests\|FetchBehaviorTests'` | 45 tests, 0 failures |
| full suite `swift test` | **390 tests, 6 skipped, 0 failures** (baseline: 371 tests, 6 skipped → +19 regression tests, no test removed, skipped count unchanged) |
| `swift build` and `swift build -c release` | 0 warnings, 0 errors (baseline: 0) |

Removing either the depth guard or the large-stack hop makes `MarkupDepthTests` kill the runner
again (SIGBUS / signal 4), so the fix is pinned by the sanitizer run and not by assertion alone.

**Rejected alternatives.** Raising only the byte cap (does not bound depth); deleting or
skipping the ASan run (forbidden by §0); disabling ASan's stack instrumentation (weakens the
instrument, forbidden); lowering the cap until the ASan build stops crashing (makes a production
parameter a function of a debug instrument); treating it as a SwiftSoup bug and doing nothing (the
process still dies, and the dependency is not ours to patch in time for go-live).

**Blocked reason.** none.

---

## Tasks carried in from before the audit branch (context, not open work)

These were found and fixed on `main` during the pre-audit session; they are part of the
baseline and each has a regression test in the suite.

| Item | Commit |
| --- | --- |
| SSRF: IPv6 literals embedding a non-public IPv4 address were allowed | `eb4c52a` |
| CI smoke test asserted a stale three-tool list (CI red since `41d5693`) | `de63b81` |
| `web_open` blamed Tavily for fetch failures | `73a5ac0` |
| Upstream 429/401 reported as "nothing was attempted" | `d41becd` |
| `mcps-mon` spent provider credits without `--probe` | `3187ea0` |
| `URLError.localizedDescription` could put a keyed URL in diagnostics | `0edc66b` |
| Provider limits registered in a detached task (bypass window) | `2c9be10` |
| Inert `SEARCH_CONNECT_TIMEOUT_MS`; order-dependent transport flags | `4ef1888` |
| Fan-out slot wasted by a local skip; duplicated `web_open` title | `f393947` |
| Local throttle turned into a hard failure | `569e6d3` |
| Aggregator discount was per response, not per result | `e1359c0` |
| Dead code sweep (Jina provider identity, `ProviderCapabilities`, Exa mapping, …) | `a375ddd`, `e60203e` |
| SearXNG image pinned by digest; provisioning canary | `7e0a3eb` |
| `mcps-mon` name-column collision; redirected-frame padding; interactive PTY harness | `170fd6f`, `5d655dd`, `692d475` |
| README/wiki incompatibilities (scraper weighting, dependency count, ISSUE-6 refusal) | `bc56236`, `f3dd8d9` |
