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
| Tasks enumerated | 115 (A01-A12 from Phase A/B, B01-B101 folded in Phase D, B102 and B103 found in Phase D) |
| Raw findings folded | 121 across 5 passes, 17 duplicate reports merged |
| DONE | 29 |
| START (reproduced, expected behaviour written) | 86 |
| BLOCKED | 0 |

Severity of the folded set: S0 2, S1 6, S2 27, S3 66.


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
| A05 | S2 | SwiftPM | `Package.swift:26-30` | `swift-nio` is pinned by range while the other direct dependencies are exact | deps | START | this Mac | scope discovery |
| A06 | S2 | `Tests/` + history | `Tests/WebSearchCoreTests/StdioServerTests.swift`, `AnswerSynthesizerTests.swift`, `.gitleaks.toml` | 5 secret-scan findings across full history are synthetic test literals | deps | DONE | this Mac | audit baseline (gitleaks) |
| A07 | S3 | deploy | `deploy/provision-node.sh:69` | Homebrew installed by piping a remote script into bash (supply chain) | unsafe | DONE | this Mac | audit baseline (semgrep) |
| A08 | S3 | scripts | `scripts/mcp_smoke.py:335`, `scripts/searxng_health.py:36` | `dynamic-urllib-use`: URLs built at runtime without an explicit scheme/host guard | unsafe | DONE | this Mac | audit baseline (semgrep) |
| A09 | S3 | tests | `Tests/WebSearchCoreTests/URLPolicyTests.swift:46` | `detect-insecure-websocket` fires on the *rejection* fixture (false positive) | style | DONE | this Mac | audit baseline (semgrep) |
| A10 | **S1** | CI | `.github/workflows/ci.yml`, `scripts/coverage_floor.py` | No gate for warnings-as-errors, formatter, linter, type checker, coverage floor or scanners | test | DONE | this Mac | audit baseline |
| A11 | S2 | scripts | `ruff.toml` (new), `pyrightconfig.json` (new), `scripts/*.py` | Python is 3.14 with no strict type-checking config and no annotations | style | DONE | this Mac | audit baseline (pyright) |
| A12 | S2 | cross-unit contracts | `Support/AppConfiguration.swift`, `scripts/*`, `deploy/*`, CI | Env-var contracts between units have no automated consistency check | logic | START | this Mac | scope discovery |
| B01 | **S0** | `deploy/docker-compose.yml` (with `deploy/searxng/settings.yml`, `deploy/.env.example`) | `deploy/docker-compose.yml:33`, `deploy/searxng/settings.yml:13-22` | The documented compose secret-key override is the wrong variable, so the tracked placeholder is what signs the instance | placeholder | DONE | this Mac (arm64) | Phase B PLACEHOLDER-3 + L7-10 |
| B02 | **S0** | `DirectHTTPFetcher` (redirect branch), `Tests/WebSearchCoreTests/FetchRedirectTests.swift` | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:81-101` | The manual redirect loop is the SSRF boundary for redirects and has no test at all | test | DONE | this Mac (arm64) | Phase B L6-1 |
| B03 | S1 | `SwiftWebSearchMCP` (HTTP transport wiring) | `Sources/SwiftWebSearchMCP/main.swift:118` (one transport per process), `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:290` (non-POST refused before the | The HTTP transport serves exactly one MCP session per process, and that session can never be released | bug | DONE | this Mac (arm64) | Phase B L3-25 |
| B04 | **S1** | `WebSearchCore` (search) + `SwiftWebSearchMCP` (tools) | `Sources/WebSearchCore/Search/SearchOrchestrator.swift:66`, `Fetch/DirectHTTPFetcher.swift:190`, `Fetch/WebFetcher.swift:104` | Caller cancellation is never tested, and mid-flight cancellation is observably swallowed | bug | DONE | this Mac (arm64) | Phase B L6-3 + L2-6 |
| B05 | S1 | `Tests/WebSearchCoreTests/AUDITDiagnosticsTests.swift` | `Tests/WebSearchCoreTests/AUDITDiagnosticsTests.swift:6` (also `:11`, `:83`, `:111`) | TEMPORARY audit tooling is committed to the go-live test target and can abort the whole suite | placeholder | DONE | MacBook-AB.local (arm64, macOS 26.6.2, Swift 6.3.3) | Phase B PLACEHOLDER-1 |
| B06 | **S1** | `WebSearchCore` / `Support` + `Fetch`, `MCPSMonitor` | `Sources/WebSearchCore/Support/Logging.swift:128`, `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:142`, `Sources/MCPSMonitor/main.swift:171` | Untrusted seconds are converted `Double`->`Int` without a range check, so a hostile value traps the whole process | unsafe | DONE | this Mac (arm64) | Phase B L4-1 + L3-3 |
| B07 | **S1** | `WebSearchCore` (transport) | `Sources/WebSearchCore/Support/BoundedResponseBody.swift`, `Support/HTTPClient.swift:299`, `Fetch/DirectHTTPFetcher.swift:176` | Response bodies are fully buffered in memory before the byte cap is applied, so one hostile page exhausts the process | perf | DONE | this Mac (arm64) | Phase B L5-1 |
| B08 | **S1** | `SwiftWebSearchMCP` (web_open tool) | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:134`, `ToolSchemas.swift:738-774`, `Tests/WebSearchCoreTests/StdioServerTests.swift` | `web_open`'s success path through the MCP tool is untested end to end | test | DONE | this Mac (arm64) | Phase B L6-2 |
| B09 | S2 | `WebSearchCore` — `Support/AppConfiguration.swift`, `SwiftWebSearchMCP/main.swift` | `Sources/WebSearchCore/Support/AppConfiguration.swift:252-261`, `:283-300`, `:389-391` | Nothing validates configuration at startup: a mistyped value or config path is silently discarded | incomplete | DONE | this Mac (arm64) | Phase B L7-1 |
| B10 | S2 | `MCPSMonitor` + `Monitor/Terminal.swift` | `Sources/WebSearchCore/Monitor/Terminal.swift:156-157`, `:165-171`, `:187-189`; `Sources/MCPSMonitor/main.swift:508`, `:571-574` | Ctrl-C (or SIGTERM) leaves the dashboard's terminal in raw mode with the cursor hidden, and the Ctrl-C key branch is unreachable | bug | PROGRESS | this Mac (arm64) | Phase B L7-2 |
| B11 | S2 | WebSearchCore (Search) | `Sources/WebSearchCore/Search/ProviderHealth.swift:143` | A half-open breaker authorises an unbounded number of requests: `authorize` discards the probe refusal | bug | DONE | this Mac (arm64) | Phase B L2-1 |
| B12 | S2 | WebSearchCore (Search) | `Sources/WebSearchCore/Search/SearchOrchestrator.swift:384` | Providers that already reported a failure are charged a second, synthetic deadline failure | bug | DONE | this Mac (arm64) | Phase B L2-3 |
| B13 | S2 | WebSearchCore (Support) | `Sources/WebSearchCore/Support/HTTPClient.swift:216` | The session resource timeout silently caps every per-request timeout override, including the 45 s synthesis budget | bug | DONE | this Mac (arm64) | Phase B L2-4 |
| B14 | S2 | WebSearchCore (Fetch) | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:37` | `web_open` has no total deadline: a slow-drip server holds the tool call open indefinitely | unsafe | DONE | this Mac (arm64) | Phase B L2-5 |
| B15 | S2 | WebSearchCore (Fetch) | `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:43` | The Jina Reader target is percent-encoded into a *path*, so URLs with a query or fragment fetch the wrong resource | bug | DONE | this Mac (arm64) | Phase B L2-7 |
| B16 | S2 | WebSearchCore (Fetch) | `Sources/WebSearchCore/Fetch/WebFetcher.swift:50` | PDFs are on the allowed content-type list but are decoded as Latin-1 text, so `web_open` returns binary mojibake as "readable text" | bug | DONE | this Mac (arm64) | Phase B L2-8 |
| B17 | S2 | `deploy/provision-node.sh` | `deploy/provision-node.sh:235` (template at `:216`) | Unchecked `sed` can leave the tracked `__SECRET_KEY__` placeholder signing a provisioned SearXNG instance | placeholder | DONE | this Mac (arm64) | Phase B PLACEHOLDER-2 |
| B18 | S2 | `Tests/WebSearchCoreTests/StdioServerTests.swift` | `Tests/WebSearchCoreTests/StdioServerTests.swift:716` | `web_open` security-rejection test is weakened to "some refusal happened" | test | START | this Mac (arm64) | Phase B L3-4 |
| B19 | S2 | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift` | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:674` | The test named `testProvidersReceiveALargerBudgetThanTheFinalResultLimit` never inspects the budget | test | START | this Mac (arm64) | Phase B L3-5 |
| B20 | S2 | `Tests/WebSearchCoreTests/HTTPTransportTests.swift` | `Tests/WebSearchCoreTests/HTTPTransportTests.swift:183` (release at `:188`, use at `:215`) | Port race in the HTTP-transport harness, whose comment claims collision-freedom | test | START | this Mac (arm64) | Phase B L3-6 |
| B21 | S2 | `SwiftWebSearchMCP` (HTTP transport wiring) | `Sources/SwiftWebSearchMCP/main.swift:120` | The HTTP Host allow-list is hard-coded to loopback, so the documented `--host`/proxy deployment gets 421 | bug | START | this Mac (arm64) | Phase B L3-26 |
| B22 | S2 | `.github/workflows/ci.yml` | `.github/workflows/ci.yml:67` (parse at `:63`) | The CI Swift-version gate passes silently when the version cannot be parsed | logic | START | this Mac (arm64) | Phase B L3-27 |
| B23 | S2 | `scripts/soak.py` | `scripts/soak.py:217` (guard at `:214`, assignment `:221`) | `soak.py --providers` is not authoritative: an ambient `SEARCH_DISABLED_PROVIDERS` still disables requested providers | logic | START | this Mac (arm64) | Phase B L3-28 |
| B24 | S2 | `Tests/WebSearchCoreTests/HTTPClientTests.swift`, `Sources/WebSearchCore/Support/HTTPClient.swift` | `Tests/WebSearchCoreTests/HTTPClientTests.swift:314` | `testCancellationPropagatesAsCancelled` uses an assertion that cannot fail | test | START | this Mac (arm64) | Phase B L3-19 |
| B25 | S2 | `MCPSMonitor` (rendering) + `WebSearchCore` / `Monitor` | `Sources/WebSearchCore/Monitor/Renderer.swift:313` (also `:307` for `status.lastError`, and `Sources/MCPSMonitor/main.swift:431`) | Provider/instance-controlled engine names are written to the operator's terminal without stripping control characters (terminal escape injection) | unsafe | START | this Mac (arm64) | Phase B L4-2 |
| B26 | S2 | `WebSearchCore` / `Search` (`AnswerSynthesizer`) | `Sources/WebSearchCore/Search/AnswerSynthesizer.swift:460` | Citation validation covers only `[n]` markers, so the answer prose can still carry fabricated URLs that the documented guarantee says cannot exist | logic | DONE | this Mac (arm64) | Phase B L4-3 |
| B27 | S2 | `WebSearchCore` / `Search` (`AnswerSynthesizer`, `SearchOrchestrator`) + `SwiftWebSearchMCP` | `Sources/WebSearchCore/Search/AnswerSynthesizer.swift:215` (also `Sources/WebSearchCore/Search/SearchOrchestrator.swift:201`) | Untrusted page text and provider answers enter the synthesis prompt and the tool output as undelimited content (indirect prompt injection) | unsafe | DONE | this Mac (arm64) | Phase B L4-4 |
| B28 | S2 | `WebSearchCore` / `Fetch` (`HTMLExtractor`) | `Sources/WebSearchCore/Fetch/HTMLExtractor.swift:143` | `preferredContentRoot` re-serialises every candidate's subtree, giving quadratic work on crafted HTML | perf | START | this Mac (arm64) | Phase B L5-2 |
| B29 | S2 | `Sources/WebSearchCore/Support/HTTPClient.swift` (`send` retry branch) | `Sources/WebSearchCore/Support/HTTPClient.swift:243` | `maxRetryAfter` (the cap that stops a hostile `Retry-After` stalling a search) is untested | test | START | this Mac (arm64) | Phase B L6-5 |
| B30 | S2 | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift` | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:202` | `DirectHTTPFetcher`'s size cap, content-type gate, raw-text path and timeout mapping have no test | test | START | this Mac (arm64) | Phase B L6-6 |
| B31 | S2 | `Tests/WebSearchCoreTests/CoreUnitTests.swift` (`ConfigurationTests`), `Sources/WebSearchCore/Support/AppConfi | `Tests/WebSearchCoreTests/CoreUnitTests.swift:317` | `AppConfiguration.load()` and its file-vs-environment precedence have no test | test | START | this Mac (arm64) | Phase B L6-9 |
| B32 | S2 | `Sources/SwiftWebSearchMCP/ToolSchemas.swift` (`ToolArguments`), `Sources/SwiftWebSearchMCP/ToolHandlers.swift | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:477` | Tool-argument validation boundaries are untested; only three malformed cases exist | test | START | this Mac (arm64) | Phase B L6-10 |
| B33 | S2 | `Sources/WebSearchCore/Fetch/WebFetcher.swift`, `Tests/WebSearchCoreTests/FetchFallbackTests.swift` | `Sources/WebSearchCore/Fetch/WebFetcher.swift:135` | `WebFetcher`'s Jina-failure fallback and error propagation are untested | test | START | this Mac (arm64) | Phase B L6-11 |
| B34 | S2 | `Sources/WebSearchCore/Search/ResultNormalizer.swift` | `Sources/WebSearchCore/Search/ResultNormalizer.swift:68` | `ResultNormalizer`'s URL repair and text cleaning are untested | test | START | this Mac (arm64) | Phase B L6-12 |
| B35 | S2 | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift`, `HTTPClientTests.swift`, `HTTPTransportTests.swift` | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:500` | Timing-dependent tests: real sleeps, real clocks and an upper-bound wall-clock assertion | test | START | this Mac (arm64) | Phase B L6-13 |
| B36 | S3 | repository root | `.gitignore:1-16` | `.gitignore` does not cover the LLVM profile output the documented sanitizer runs produce | style | DONE | this Mac (arm64) | Phase B L0-1 |
| B37 | S3 | `AUDIT/baseline/**` | `AUDIT/baseline/swiftlint.json:4` (first of 491 such lines), `AUDIT/baseline/swift-test-asan.log:58`, `AUDIT/baseline/swift-test.log:4`, `AUDIT/baseli | Committed baseline evidence embeds the auditor's absolute home path (491 lines) and 2.5 MB of generated output | unsafe | START | this Mac (arm64) | Phase B L0-2 |
| B38 | S3 | `.github/workflows/ci.yml` | `.github/workflows/ci.yml:1-31` | The CI workflow declares no `permissions:`, so the job token keeps the default scope | unsafe | DONE | this Mac (arm64) | Phase B L0-3 |
| B39 | S3 | `.github/workflows/ci.yml` | `.github/workflows/ci.yml:40-70` | CI does not pin the Swift toolchain, so "Swift 6.3" is whatever the runner image has | deps | START | this Mac (arm64) | Phase B L0-4 |
| B40 | S3 | `Package.swift`, `Package.resolved`, CI | `Package.swift:31-34`, `.github/workflows/ci.yml:89-96` | Nothing detects that `Package.resolved` has drifted from the manifests | deps | START | this Mac (arm64) | Phase B L0-5 |
| B41 | S3 | `Package.swift`, repository root | `Package.swift:31-34` | Apache-2.0 `NOTICE` files of two dependencies are not carried with any distributed binary | deps | START | this Mac (arm64) | Phase B L0-6 |
| B42 | S3 | `SwiftWebSearchMCP` (`HTTPMCPHost`) | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:448` | The hand-rolled `Origin` check accepts any host starting with `127.`, which is a bypass of the check it pretends to be | logic | START | this Mac (arm64) | Phase B L4-7 |
| B43 | S3 | `AUDIT/plan.md` vs `AUDIT/baseline/` | `AUDIT/plan.md:38` | The baseline evidence table cites `gitleaks.json`, which is not in the repository | docs | START | this Mac (arm64) | Phase B L7-5 |
| B44 | S3 | `scripts/soak.py` | `scripts/soak.py:473-479` | The soak test's comment promises a "provider never contributed" failure that the code never implements | incomplete | START | this Mac (arm64) | Phase B L7-6 |
| B45 | S3 | `scripts/mcp_smoke.py`, `scripts/monitor_tty_smoke.py` | `scripts/mcp_smoke.py:100-105`, `scripts/monitor_tty_smoke.py:186-194` | The "prove the scrub" loops in both smoke scripts are no-ops that cannot fail | dead | START | this Mac (arm64) | Phase B L7-7 |
| B46 | S3 | `MCPSMonitor` | `Sources/MCPSMonitor/main.swift:45-78` (`--iterations  Stop after n refreshes (useful for scripting)`), `:533-580` | `mcps-mon` always exits 0, so `--iterations` cannot be used as a health check | incomplete | START | this Mac (arm64) | Phase B L7-8 |
| B47 | S3 | `example.env` vs `deploy/` | `example.env:35-39` | `example.env` tells the operator to fix a SearXNG setting that the shipped files already set | docs | START | this Mac (arm64) | Phase B L7-9 |
| B48 | S3 | `deploy/provision-node.sh` | `deploy/provision-node.sh:296-297` | `provision-node.sh` cannot find a Homebrew-installed Tailscale CLI on Apple Silicon | bug | START | this Mac (arm64) | Phase B L7-11 |
| B49 | S3 | `deploy/provision-node.sh` | `deploy/provision-node.sh:192-199`, `:203-235` | The generated SearXNG `settings.yml` inherits the umask, so the per-node secret key is world-readable | unsafe | START | this Mac (arm64) | Phase B L7-12 |
| B50 | S3 | `deploy/provision-node.sh` | `deploy/provision-node.sh:255-284` | Provisioning destroys the working instance before its replacement is proven on the production port, with no rollback | incomplete | START | this Mac (arm64) | Phase B L7-13 |
| B51 | S3 | `WebSearchCore` / `Support` (`Log`) | `Sources/WebSearchCore/Support/Logging.swift:119` | `Log.escape` leaves every control character except `\n`, `\r` and `\t`, so a query can inject terminal escapes into stderr | unsafe | START | this Mac (arm64) | Phase B L4-8 |
| B52 | S3 | WebSearchCore (Search) | `Sources/WebSearchCore/Search/SearchOrchestrator.swift:501` | A claimed half-open probe is never released when a request ends in a bare `CancellationError` | bug | START | this Mac (arm64) | Phase B L2-2 |
| B53 | S3 | WebSearchCore (Monitor) | `Sources/WebSearchCore/Monitor/Terminal.swift:96` | `Terminal.truncate` counts ANSI escape characters as display width, so truncating styled text can drop the SGR reset | bug | START | this Mac (arm64) | Phase B L2-9 |
| B54 | S3 | WebSearchCore (Providers) | `Sources/WebSearchCore/Providers/ParallelMCPProvider.swift:162` | Concurrent first use of the Parallel provider performs the MCP handshake more than once | bug | START | this Mac (arm64) | Phase B L2-10 |
| B55 | S3 | WebSearchCore (Search) | `Sources/WebSearchCore/Search/ProviderHealth.swift:119` | `ProviderHealth.setNote` is dead public API | dead | START | this Mac (arm64) | Phase B L2-11 |
| B56 | S3 | WebSearchCore (Providers) | `Sources/WebSearchCore/Providers/ScraperSupport.swift:24` | `ScraperSupport.BlockKind.noResults` is never produced, so an empty result page is reported as unparseable | dead | START | this Mac (arm64) | Phase B L2-12 |
| B57 | S3 | SwiftWebSearchMCP (with WebSearchCore) | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:407` | The per-provider "which variable enables me" contract is triplicated across units and already wrong for `parallel` | logic | START | this Mac (arm64) | Phase B L1-1 |
| B58 | S3 | SwiftWebSearchMCP | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:186` | `web_search` and `web_answer` duplicate their argument parsing, and the two schemas have already drifted | style | START | this Mac (arm64) | Phase B L1-2 |
| B59 | S3 | `WebSearchCore/Support/AppConfiguration.swift` | `Sources/WebSearchCore/Support/AppConfiguration.swift:330` | `PARALLEL_MCP_URL=` cannot clear the default endpoint: the branch is unreachable in production | dead | START | this Mac (arm64) | Phase B L3-7 |
| B60 | S3 | `WebSearchCore/Providers/DuckDuckGoProvider.swift` | `Sources/WebSearchCore/Providers/DuckDuckGoProvider.swift:70` | DuckDuckGo region hint sends the region twice instead of region-language | bug | START | this Mac (arm64) | Phase B L3-8 |
| B61 | S3 | `WebSearchCore/Fetch/HTMLExtractor.swift` | `Sources/WebSearchCore/Fetch/HTMLExtractor.swift:63` (markers at `:36`, `:40`) | Hyphenated boilerplate markers are inert, and the prefix clause is unreachable | logic | START | this Mac (arm64) | Phase B L3-9 |
| B62 | S3 | `WebSearchCore/Fetch/URLPolicy.swift` | `Sources/WebSearchCore/Fetch/URLPolicy.swift:435` | `isReserved` blocks all of `192.0.0.0/16` while documenting `192.0.0.0/24` | logic | START | this Mac (arm64) | Phase B L3-10 |
| B63 | S3 | `WebSearchCore` / `Search` (`ResultNormalizer`) | `Sources/WebSearchCore/Search/ResultNormalizer.swift:155` | Entity decoding loops over its own output, so `&amp;lt;` becomes a live `<` in text returned to the model | bug | START | this Mac (arm64) | Phase B L4-14 |
| B64 | S3 | `WebSearchCore/Monitor/NodeProbe.swift` | `Sources/WebSearchCore/Monitor/NodeProbe.swift:102` (catch at `:133-142`) | Malformed JSON from a node is reported as "unreachable" | bug | START | this Mac (arm64) | Phase B L3-12 |
| B65 | S3 | `WebSearchCore/Monitor/MonitorModel.swift`, `Sources/MCPSMonitor/main.swift` | `Sources/WebSearchCore/Monitor/MonitorModel.swift:50` | `NodeStatus.State.skipped` is unreachable dead state | dead | START | this Mac (arm64) | Phase B L3-13 |
| B66 | S3 | `WebSearchCore/Providers/*` | `Sources/WebSearchCore/Providers/MojeekProvider.swift:219` (and `ExaProvider.swift:174`, `SearXNGProvider.swift:174`, `TavilyProvider.swift:165`, `Bra | Decoded-but-unused vendor DTO fields across five adapters | dead | START | this Mac (arm64) | Phase B L3-14 |
| B67 | S3 | `WebSearchCore/Monitor/Renderer.swift` | `Sources/WebSearchCore/Monitor/Renderer.swift:273` (data at `:288`) | Node table header and data disagree on the state column width | style | START | this Mac (arm64) | Phase B L3-17 |
| B68 | S3 | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift` | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:499` | Stale "detached task" comment plus a 60 ms sleep that waits for nothing | test | START | this Mac (arm64) | Phase B L3-18 |
| B69 | S3 | `Tests/WebSearchCoreTests/CoreUnitTests.swift` | `Tests/WebSearchCoreTests/CoreUnitTests.swift:344` | Clock test asserts a property that cannot fail | test | START | this Mac (arm64) | Phase B L3-20 |
| B70 | S3 | `Tests/WebSearchCoreTests/StdioServerTests.swift` (same pattern in `ErrorReportingTests.swift`, `SchemaCompati | `Tests/WebSearchCoreTests/StdioServerTests.swift:85` (loop `:70-93`) | Subprocess harnesses advertise a timeout that a blocking read cannot enforce | test | START | this Mac (arm64) | Phase B L3-21 |
| B71 | S3 | `Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift` | `Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift:30` | Three copies of the same subprocess harness, already diverged | test | START | this Mac (arm64) | Phase B L3-22 |
| B72 | S3 | `Tests/WebSearchCoreTests/TestSupport.swift` | `Tests/WebSearchCoreTests/TestSupport.swift:178` (body `:170-189`) | `assertNoCredentialLeak` documents a check it does not perform and passes vacuously | test | START | this Mac (arm64) | Phase B L3-23 |
| B73 | S3 | `scripts/soak.py` | `scripts/soak.py:446` | Soak report attributes every failure category to every provider | bug | START | this Mac (arm64) | Phase B L3-24 |
| B74 | S3 | `MCPSMonitor` (option parsing) | `Sources/MCPSMonitor/main.swift:200` (`--no-nodes` at `:143`, custom nodes at `:160`) | `--no-nodes` is silently ignored whenever a `--node` is also present | logic | START | this Mac (arm64) | Phase B L3-29 |
| B75 | S3 | `MCPSMonitor` (option parsing); same helper copied in `WebSearchCore/Support/TransportConfiguration.swift` | `Sources/MCPSMonitor/main.swift:155` (helper `:127-135`); `Sources/WebSearchCore/Support/TransportConfiguration.swift:97` | `--node` accepts a relative URL and can swallow the next flag as its value | logic | START | this Mac (arm64) | Phase B L3-30 |
| B76 | S3 | `MCPSMonitor` (provider selection); `WebSearchCore/Search/ProviderRegistry.swift` | `Sources/MCPSMonitor/main.swift:348` (and `:292`), `Sources/WebSearchCore/Search/ProviderRegistry.swift:34` | `mcps-mon` ignores `SEARCH_DISABLED_PROVIDERS`, labels disabled providers "ready", and probes them | logic | START | this Mac (arm64) | Phase B L3-31 |
| B77 | S3 | `SwiftWebSearchMCP` (argument parsing) | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:464` | `ToolArguments.bool(_:)` has no caller | dead | START | this Mac (arm64) | Phase B L3-33 |
| B78 | S3 | `MCPSMonitor` view state; `WebSearchCore/Monitor/Renderer.swift` | `Sources/WebSearchCore/Monitor/MonitorModel.swift:127` and `:134` | `ProviderStatus.State.probing` and `.unavailable` can never be produced, so their renderer branches are unreachable | dead | START | this Mac (arm64) | Phase B L3-34 |
| B79 | S3 | `SwiftWebSearchMCP` (HTTP host body cap) | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:167` | A request-head `Content-Length` reserves up to 1 MiB per connection before any body arrives | unsafe | START | this Mac (arm64) | Phase B L3-36 |
| B80 | S3 | `scripts/soak.py` | `scripts/soak.py:170` (used at `:183`) | `soak.py` conflates EOF with a malformed stdout line and discards the line | bug | START | this Mac (arm64) | Phase B L3-38 |
| B81 | S3 | `scripts/mcp_smoke.py` | `scripts/mcp_smoke.py:315` (decode at `:296`) | `mcp_smoke.py` de-chunks an SSE body after decoding it to `str` | bug | START | this Mac (arm64) | Phase B L3-39 |
| B82 | S3 | `scripts/soak.py` | `scripts/soak.py:327` (argument at `:301`) | A negative `--queries` silently truncates the query list from the end | bug | START | this Mac (arm64) | Phase B L3-40 |
| B83 | S3 | `scripts/mcp_smoke.py` | `scripts/mcp_smoke.py:345-353` (port at `:350-357`, stderr only read at `:458`) | HTTP smoke can wait 20 s on a dead server and never checks that it is alive | bug | START | this Mac (arm64) | Phase B L3-41 |
| B84 | S3 | `WebSearchCore` / `Fetch` (`URLPolicy`) | `Sources/WebSearchCore/Fetch/URLPolicy.swift:289` | `IPAddress.v6` is a public case that accepts any byte count, and its accessors index 16 bytes unconditionally | unsafe | START | this Mac (arm64) | Phase B L4-9 |
| B85 | S3 | `WebSearchCore` / `Support` (`Log`) | `Sources/WebSearchCore/Support/Logging.swift:93` | Query hashing for logs is a fast unsalted FNV-1a, but is documented as non-reversible | docs | START | this Mac (arm64) | Phase B L4-10 |
| B86 | S3 | `deploy` (`provision-node.sh`) | `deploy/provision-node.sh:71` | Provisioning writes through fixed, predictable `/tmp` paths and loads a container image from one | unsafe | START | this Mac (arm64) | Phase B L4-12 |
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
| B107 | **S2** | `MCPSMonitor` | `Sources/MCPSMonitor/main.swift`, `Monitor/Terminal.swift:165-171` | An externally delivered SIGINT or SIGTERM leaves the terminal in raw mode with the cursor hidden | bug | START | this Mac | Phase D (found while fixing B10) |
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
