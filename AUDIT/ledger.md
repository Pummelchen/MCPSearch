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
| Tasks enumerated | 129 (A01-A12 from Phase A/B, B01-B101 folded in Phase D, B102-B107 found while fixing, B108 found while recording CI, B109-B115 found while verifying the handover) |
| Raw findings folded | 121 across 5 passes, 17 duplicate reports merged; 7 further findings added while re-reading the tree at handover |
| DONE | 97 |
| START (reproduced, expected behaviour written) | 32 |
| PROGRESS | 0 |
| BLOCKED | 0 |

Severity of the whole set: **S0 3, S1 8, S2 34, S3 84** — the S0 set (A01, B01, B02) and the S1 set
are all DONE; of the 34 S2 tasks 34 are DONE and 0 open; of the 84 S3 tasks 52 are DONE and 32 open.

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
| B46 | S3 | `MCPSMonitor` | `Sources/MCPSMonitor/main.swift:45-78` (`--iterations  Stop after n refreshes (useful for scripting)`), `:533-580` | `mcps-mon` always exits 0, so `--iterations` cannot be used as a health check | incomplete | START | this Mac (arm64) | Phase B L7-8 |
| B47 | S3 | `example.env` vs `deploy/` | `example.env:35-39` | `example.env` tells the operator to fix a SearXNG setting that the shipped files already set | docs | DONE | this Mac (arm64) | Phase B L7-9 |
| B48 | S3 | `deploy/provision-node.sh` | `deploy/provision-node.sh:296-297` | `provision-node.sh` cannot find a Homebrew-installed Tailscale CLI on Apple Silicon | bug | DONE | this Mac (arm64) | Phase B L7-11 |
| B49 | S3 | `deploy/provision-node.sh` | `deploy/provision-node.sh:192-199`, `:203-235` | The generated SearXNG `settings.yml` inherits the umask, so the per-node secret key is world-readable | unsafe | DONE | this Mac (arm64) | Phase B L7-12 |
| B50 | S3 | `deploy/provision-node.sh` | `deploy/provision-node.sh:255-284` | Provisioning destroys the working instance before its replacement is proven on the production port, with no rollback | incomplete | DONE | this Mac (arm64) | Phase B L7-13 |
| B51 | S3 | `WebSearchCore` / `Support` (`Log`) | `Sources/WebSearchCore/Support/Logging.swift:119` | `Log.escape` leaves every control character except `\n`, `\r` and `\t`, so a query can inject terminal escapes into stderr | unsafe | DONE | this Mac (arm64) | Phase B L4-8 |
| B52 | S3 | WebSearchCore (Search) | `Sources/WebSearchCore/Search/SearchOrchestrator.swift:501` | A claimed half-open probe is never released when a request ends in a bare `CancellationError` | bug | DONE | this Mac (arm64) | Phase B L2-2 |
| B53 | S3 | WebSearchCore (Monitor) | `Sources/WebSearchCore/Monitor/Terminal.swift:96` | `Terminal.truncate` counts ANSI escape characters as display width, so truncating styled text can drop the SGR reset | bug | DONE | this Mac (arm64) | Phase B L2-9 |
| B54 | S3 | WebSearchCore (Providers) | `Sources/WebSearchCore/Providers/ParallelMCPProvider.swift:162` | Concurrent first use of the Parallel provider performs the MCP handshake more than once | bug | START | this Mac (arm64) | Phase B L2-10 |
| B55 | S3 | WebSearchCore (Search) | `Sources/WebSearchCore/Search/ProviderHealth.swift:119` | `ProviderHealth.setNote` is dead public API | dead | DONE | this Mac (arm64) | Phase B L2-11 |
| B56 | S3 | WebSearchCore (Providers) | `Sources/WebSearchCore/Providers/ScraperSupport.swift:24` | `ScraperSupport.BlockKind.noResults` is never produced, so an empty result page is reported as unparseable | dead | DONE | this Mac (arm64) | Phase B L2-12 |
| B57 | S3 | SwiftWebSearchMCP (with WebSearchCore) | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:407` | The per-provider "which variable enables me" contract is triplicated across units and already wrong for `parallel` | logic | START | this Mac (arm64) | Phase B L1-1 |
| B58 | S3 | SwiftWebSearchMCP | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:186` | `web_search` and `web_answer` duplicate their argument parsing, and the two schemas have already drifted | style | START | this Mac (arm64) | Phase B L1-2 |
| B59 | S3 | `WebSearchCore/Support/AppConfiguration.swift` | `Sources/WebSearchCore/Support/AppConfiguration.swift:330` | `PARALLEL_MCP_URL=` cannot clear the default endpoint: the branch is unreachable in production | dead | DONE | this Mac (arm64) | Phase B L3-7 |
| B60 | S3 | `WebSearchCore/Providers/DuckDuckGoProvider.swift` | `Sources/WebSearchCore/Providers/DuckDuckGoProvider.swift:70` | DuckDuckGo region hint sends the region twice instead of region-language | bug | DONE | this Mac (arm64) | Phase B L3-8 |
| B61 | S3 | `WebSearchCore/Fetch/HTMLExtractor.swift` | `Sources/WebSearchCore/Fetch/HTMLExtractor.swift:63` (markers at `:36`, `:40`) | Hyphenated boilerplate markers are inert, and the prefix clause is unreachable | logic | DONE | this Mac (arm64) | Phase B L3-9 |
| B62 | S3 | `WebSearchCore/Fetch/URLPolicy.swift` | `Sources/WebSearchCore/Fetch/URLPolicy.swift:435` | `isReserved` blocks all of `192.0.0.0/16` while documenting `192.0.0.0/24` | logic | DONE | this Mac (arm64) | Phase B L3-10 |
| B63 | S3 | `WebSearchCore` / `Search` (`ResultNormalizer`) | `Sources/WebSearchCore/Search/ResultNormalizer.swift:155` | Entity decoding loops over its own output, so `&amp;lt;` becomes a live `<` in text returned to the model | bug | DONE | this Mac (arm64) | Phase B L4-14 |
| B64 | S3 | `WebSearchCore/Monitor/NodeProbe.swift` | `Sources/WebSearchCore/Monitor/NodeProbe.swift:102` (catch at `:133-142`) | Malformed JSON from a node is reported as "unreachable" | bug | DONE | this Mac (arm64) | Phase B L3-12 |
| B65 | S3 | `WebSearchCore/Monitor/MonitorModel.swift`, `Sources/MCPSMonitor/main.swift` | `Sources/WebSearchCore/Monitor/MonitorModel.swift:50` | `NodeStatus.State.skipped` is unreachable dead state | dead | DONE | this Mac (arm64) | Phase B L3-13 |
| B66 | S3 | `WebSearchCore/Providers/*` | `Sources/WebSearchCore/Providers/MojeekProvider.swift:219` (and `ExaProvider.swift:174`, `SearXNGProvider.swift:174`, `TavilyProvider.swift:165`, `Bra | Decoded-but-unused vendor DTO fields across five adapters | dead | START | this Mac (arm64) | Phase B L3-14 |
| B67 | S3 | `WebSearchCore/Monitor/Renderer.swift` | `Sources/WebSearchCore/Monitor/Renderer.swift:273` (data at `:288`) | Node table header and data disagree on the state column width | style | DONE | this Mac (arm64) | Phase B L3-17 |
| B68 | S3 | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift` | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:499` | Stale "detached task" comment plus a 60 ms sleep that waits for nothing | test | DONE | this Mac (arm64) | Phase B L3-18 |
| B69 | S3 | `Tests/WebSearchCoreTests/CoreUnitTests.swift` | `Tests/WebSearchCoreTests/CoreUnitTests.swift:344` | Clock test asserts a property that cannot fail | test | DONE | this Mac (arm64) | Phase B L3-20 |
| B70 | S3 | `Tests/WebSearchCoreTests/StdioServerTests.swift` (same pattern in `ErrorReportingTests.swift`, `SchemaCompati | `Tests/WebSearchCoreTests/StdioServerTests.swift:85` (loop `:70-93`) | Subprocess harnesses advertise a timeout that a blocking read cannot enforce | test | START | this Mac (arm64) | Phase B L3-21 |
| B71 | S3 | `Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift` | `Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift:30` | Three copies of the same subprocess harness, already diverged | test | START | this Mac (arm64) | Phase B L3-22 |
| B72 | S3 | `Tests/WebSearchCoreTests/TestSupport.swift` | `Tests/WebSearchCoreTests/TestSupport.swift:178` (body `:170-189`) | `assertNoCredentialLeak` documents a check it does not perform and passes vacuously | test | DONE | this Mac (arm64) | Phase B L3-23 |
| B73 | S3 | `scripts/soak.py` | `scripts/soak.py:446` | Soak report attributes every failure category to every provider | bug | DONE | this Mac (arm64) | Phase B L3-24 |
| B74 | S3 | `MCPSMonitor` (option parsing) | `Sources/MCPSMonitor/main.swift:200` (`--no-nodes` at `:143`, custom nodes at `:160`) | `--no-nodes` is silently ignored whenever a `--node` is also present | logic | DONE | this Mac (arm64) | Phase B L3-29 |
| B75 | S3 | `MCPSMonitor` (option parsing); same helper copied in `WebSearchCore/Support/TransportConfiguration.swift` | `Sources/MCPSMonitor/main.swift:155` (helper `:127-135`); `Sources/WebSearchCore/Support/TransportConfiguration.swift:97` | `--node` accepts a relative URL and can swallow the next flag as its value | logic | DONE | this Mac (arm64) | Phase B L3-30 |
| B76 | S3 | `MCPSMonitor` (provider selection); `WebSearchCore/Search/ProviderRegistry.swift` | `Sources/MCPSMonitor/main.swift:348` (and `:292`), `Sources/WebSearchCore/Search/ProviderRegistry.swift:34` | `mcps-mon` ignores `SEARCH_DISABLED_PROVIDERS`, labels disabled providers "ready", and probes them | logic | START | this Mac (arm64) | Phase B L3-31 |
| B77 | S3 | `SwiftWebSearchMCP` (argument parsing) | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:464` | `ToolArguments.bool(_:)` has no caller | dead | DONE | this Mac (arm64) | Phase B L3-33 |
| B78 | S3 | `MCPSMonitor` view state; `WebSearchCore/Monitor/Renderer.swift` | `Sources/WebSearchCore/Monitor/MonitorModel.swift:127` and `:134` | `ProviderStatus.State.probing` and `.unavailable` can never be produced, so their renderer branches are unreachable | dead | DONE | this Mac (arm64) | Phase B L3-34 |
| B79 | S3 | `SwiftWebSearchMCP` (HTTP host body cap) | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:167` | A request-head `Content-Length` reserves up to 1 MiB per connection before any body arrives | unsafe | START | this Mac (arm64) | Phase B L3-36 |
| B80 | S3 | `scripts/soak.py` | `scripts/soak.py:170` (used at `:183`) | `soak.py` conflates EOF with a malformed stdout line and discards the line | bug | DONE | this Mac (arm64) | Phase B L3-38 |
| B81 | S3 | `scripts/mcp_smoke.py` | `scripts/mcp_smoke.py:315` (decode at `:296`) | `mcp_smoke.py` de-chunks an SSE body after decoding it to `str` | bug | DONE | this Mac (arm64) | Phase B L3-39 |
| B82 | S3 | `scripts/soak.py` | `scripts/soak.py:327` (argument at `:301`) | A negative `--queries` silently truncates the query list from the end | bug | DONE | this Mac (arm64) | Phase B L3-40 |
| B83 | S3 | `scripts/mcp_smoke.py` | `scripts/mcp_smoke.py:345-353` (port at `:350-357`, stderr only read at `:458`) | HTTP smoke can wait 20 s on a dead server and never checks that it is alive | bug | DONE | this Mac (arm64) | Phase B L3-41 |
| B84 | S3 | `WebSearchCore` / `Fetch` (`URLPolicy`) | `Sources/WebSearchCore/Fetch/URLPolicy.swift:289` | `IPAddress.v6` is a public case that accepts any byte count, and its accessors index 16 bytes unconditionally | unsafe | START | this Mac (arm64) | Phase B L4-9 |
| B85 | S3 | `WebSearchCore` / `Support` (`Log`) | `Sources/WebSearchCore/Support/Logging.swift:93` | Query hashing for logs is a fast unsalted FNV-1a, but is documented as non-reversible | docs | START | this Mac (arm64) | Phase B L4-10 |
| B86 | S3 | `deploy` (`provision-node.sh`) | `deploy/provision-node.sh:71` | Provisioning writes through fixed, predictable `/tmp` paths and loads a container image from one | unsafe | DONE | this Mac (arm64) | Phase B L4-12 |
| B87 | S3 | `WebSearchCore` / `Fetch` (`JinaReaderFetcher`) + `WebSearchCore` / `Search` (`SearchPipelineFactory`) | `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:65` | The Jina Reader fallback discloses the target URL to a third party by default, with no warning that it did | docs | START | this Mac (arm64) | Phase B L4-13 |
| B88 | S3 | `WebSearchCore` / `Fetch` (`URLPolicy` + `DirectHTTPFetcher`) | `Sources/WebSearchCore/Fetch/URLPolicy.swift:57` | The declared per-host DNS cache does not exist, and every redirect hop resolves twice | perf | START | this Mac (arm64) | Phase B L5-3 |
| B89 | S3 | `WebSearchCore` / `Search` (`SearchCache`) | `Sources/WebSearchCore/Search/SearchCache.swift:103` | `SearchCache.pruneExpired` rebuilds the whole dictionary on every read, write and stats call | perf | START | this Mac (arm64) | Phase B L5-4 |
| B90 | S3 | `SwiftWebSearchMCP` (`HTTPMCPHost`) | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:61` | The HTTP listener bounds the request body but nothing else, so idle or slow connections are unbounded | perf | START | this Mac (arm64) | Phase B L5-5 |
| B91 | S3 | `WebSearchCore` / `Support` (`Log`) | `Sources/WebSearchCore/Support/Logging.swift:42` | Log emission performs a synchronous blocking write to fd 2 from whatever task is logging | perf | START | this Mac (arm64) | Phase B L5-6 |
| B92 | S3 | `WebSearchCore` / `Fetch` (`JinaReaderFetcher`) | `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:125` | `web_open` reports the requested URL as `final_url` on the Jina path, and the reader's own `url` field is decoded but never used | logic | START | this Mac (arm64) | Phase B L5-7 |
| B93 | S3 | `Sources/WebSearchCore/Fetch/MarkupDepth.swift`, `Search/SearchError.swift`, `SwiftWebSearchMCP/ToolHandlers.s | `Sources/WebSearchCore/Fetch/MarkupDepth.swift:190` | The new `MarkupDepth` regression suite still leaves four branches/contracts unpinned | test | START | this Mac (arm64) | Phase B L6-4 |
| B94 | S3 | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift`, `Sources/WebSearchCore/Search/SearchOrchestrator.swi | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:716` | `testStatusCountsSuccessesAndFailures` never observes a failure | test | START | this Mac (arm64) | Phase B L6-14 |
| B95 | S3 | `Tests/WebSearchCoreTests/MonitorTests.swift`, `Sources/WebSearchCore/Monitor/ProviderProbe.swift:50` | `Tests/WebSearchCoreTests/MonitorTests.swift:101` | The monitor's setup-hint test asserts a string the test itself constructed | test | START | this Mac (arm64) | Phase B L6-15 |
| B96 | S3 | `Sources/WebSearchCore/Providers/HTTPStatusMapper.swift` | `Sources/WebSearchCore/Providers/HTTPStatusMapper.swift:46` | `HTTPStatusMapper.map`'s HTTPError branches and `validate`'s default/422 statuses are untested | test | START | this Mac (arm64) | Phase B L6-16 |
| B97 | S3 | `Sources/WebSearchCore/Search/AnswerSynthesizer.swift`, `Tests/WebSearchCoreTests/AnswerSynthesizerTests.swift | `Sources/WebSearchCore/Search/AnswerSynthesizer.swift:349` | `AnswerSynthesizer`'s completion edge cases, token usage and locale prompt are untested | test | START | this Mac (arm64) | Phase B L6-17 |
| B98 | S3 | `Sources/MCPSMonitor/main.swift` (`Monitor`), `Tests/MCPSMonitorTests/MonitorOptionsTests.swift` | `Sources/MCPSMonitor/main.swift:337` | The `Monitor` actor's refresh/counting/warning logic has no Swift test | test | START | this Mac (arm64) | Phase B L6-18 |
| B99 | S3 | `Tests/WebSearchCoreTests/TestSupport.swift`, `scripts/*.py` | `Tests/WebSearchCoreTests/TestSupport.swift:12` | No test ties the Swift test harnesses to the Python harnesses, and two scripts are untested entirely | test | START | this Mac (arm64) | Phase B L6-19 |
| B100 | S3 | `Sources/SwiftWebSearchMCP/ToolSchemas.swift` (`ToolOutputFormatter`) | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:526` | `ToolOutputFormatter`'s fallback and diagnostic branches are untested | test | START | this Mac (arm64) | Phase B L6-20 |
| B101 | S3 | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift`, `Tests/WebSearchCoreTests/HTTPTransportTests.swift` | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:79` | `HTTPMCPHost`'s startup-failure and internal-error paths are untested | test | START | this Mac (arm64) | Phase B L6-21 |
| B109 | S3 | `WebSearchCore` / `Search` (`RankFusion`) | `Sources/WebSearchCore/Search/RankFusion.swift:161-162` | The response-level resale discount is applied to every result of an aggregator response, defeating the per-result refinement the code documents | logic | DONE | this Mac (arm64) | handover re-read L2 |
| B110 | S3 | `SwiftWebSearchMCP` (`ToolSchemas`, `web_answer` input) | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:275-281` | `web_answer`'s `provider` argument lost the enum that `web_search`'s `provider` declares, though the schema documents itself as a mirror | logic | DONE | this Mac (arm64) | handover re-read L1 |
| B111 | S3 | `SwiftWebSearchMCP` (`ToolSchemas`, nullable enums) | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:62-66`, `:83-93`, `:94-101`, `:270-274` | Nullable enum arguments declare `["string", "null"]` with an `enum` that excludes `null`, so a strict client cannot legally send the null the design depends on | logic | DONE | this Mac (arm64) | handover re-read L1 |
| B112 | S3 | `SwiftWebSearchMCP` (`ToolSchemas`, `web_search_status` input) | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:350-358` | `statusInput` is the only object schema in the file that omits `required` | style | DONE | this Mac (arm64) | handover re-read L1 |
| B113 | S3 | `WebSearchCore` / `Support` + `SwiftWebSearchMCP` (`main`) | `Sources/SwiftWebSearchMCP/main.swift:16` and `:98` | Configuration is loaded and validated before the command line is parsed, so an unreadable config file pre-empts `--help` | logic | START | this Mac (arm64) | handover re-read L7 |
| B114 | S3 | `SwiftWebSearchMCP` (`TransportConfiguration.usage`) | `Sources/WebSearchCore/Support/TransportConfiguration.swift:51-77` | `usage` under-documents the CLI, and the test that claims to check every flag locks the incomplete list in place | docs | START | this Mac (arm64) | handover re-read L7 |
| B115 | S3 | repository root (`README.md`) | `README.md:120`, provider table `:122-134` | The README undercounts the keyless routes and its Startpage row omits the flag the adapter actually requires | docs | DONE | this Mac (arm64) | handover re-read L7 |
| B116 | S3 | `WebSearchCore` / `Search` (`SearchOrchestrator`, `RateLimiter`) | `SearchOrchestrator.swift:456-462`, `RateLimiter.swift:97-104` | A local throttle that cleared between the authorise and the wait estimate was reported as a hard skip, making the suite intermittently red | bug | DONE | node1 (arm64) | Phase E baseline |
| B117 | S3 | `scripts` (`mcp_smoke.py`) | `scripts/mcp_smoke.py` (`free_loopback_port`) | The HTTP smoke picks a free port by closing the socket before the child binds, so the child can lose the bind race | test | START | this Mac (arm64) | Phase C (residual B83 left) |

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
| B102 | S3 | `WebSearchCore` (fetch) | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:245-256` (delegate), `Sources/WebSearchCore/Support/HTTPClient.swift:386` (message) | A cross-scheme redirect is refused by the transport, not by our policy, and surfaces as an opaque transport error | bug | START | this Mac (arm64) | Phase D (found while fixing B02) |
| B103 | S3 | `SwiftWebSearchMCP` (tools) | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:91-93`, `:142-143`, `:237-238`, `:262-263` | The tool-layer cancellation branches are still not exercised by any test | test | START | this Mac (arm64) | Phase D (found while fixing B04) |
| B104 | S3 | build/environment | `AppConfiguration.swift` + the audit scratch tree | `mcps-mon` appeared to crash on startup in a debug build: a stale incremental build, not a code defect | bug | DONE | this Mac | Phase D (found while testing B10) |
| B105 | S3 | repository hygiene | `scripts/__pycache__/*.pyc` (4 files) | Generated Python byte-code was committed to the branch | style | DONE | this Mac | Phase D (found while restoring the tree) |
| B106 | S3 | tests/scripts | `scripts/monitor_tty_smoke.py` | The PTY harness reports a crashing monitor as a first-frame timeout | test | START | this Mac | Phase D (found during B104) |
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
