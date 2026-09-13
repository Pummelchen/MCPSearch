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
| Tasks enumerated | 12 |
| DONE | 0 |
| START (reproduced, expected behaviour written) | 12 |
| BLOCKED | 0 |

Two cross-cutting gates are **not** tasks but acceptance criteria for Phase E: the whole
suite must be green on an independent host, and every scanner must be clean or explicitly
waived in writing.

---

## Open tasks

| id | sev | unit | file:line | title | category | status | host | discovered-by |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A01 | **S1** (raised to S0 if it reproduces without ASan) | `WebSearchCore` (scrapers) | `Providers/DuckDuckGoProvider.swift:105`, `Providers/ScraperSupport.swift:100` | HTML parse on a cooperative task stack exhausts the stack and kills the process | unsafe | START | this Mac (arm64) | audit baseline (ASan) |
| A02 | S2 | repo-wide Swift | `Sources/**`, `Tests/**` | `swift-format` reports 19 155 diagnostics: no config encodes the project's style | style | START | this Mac | audit baseline |
| A03 | S2 | repo-wide Swift | `Sources/**`, `Tests/**` | SwiftLint reports 491 findings with no repository config; genuine rules drown in style noise | style | START | this Mac | audit baseline |
| A04 | S1 | `SwiftWebSearchMCP`, `MCPSMonitor` | `Sources/SwiftWebSearchMCP/**`, `Sources/MCPSMonitor/**` | The executables' coverage is unmeasured (0 % / 29.5 %): the MCP surface is driven as a subprocess | test | START | this Mac | audit baseline (coverage) |
| A05 | S2 | SwiftPM | `Package.swift:26-30` | `swift-nio` is pinned by range while the other direct dependencies are exact | deps | START | this Mac | scope discovery |
| A06 | S2 | `Tests/` + history | `Tests/WebSearchCoreTests/StdioServerTests.swift`, `AnswerSynthesizerTests.swift` | 5 secret-scan findings across full history are synthetic test literals | deps | START | this Mac | audit baseline (gitleaks) |
| A07 | S3 | deploy | `deploy/provision-node.sh:69` | Homebrew installed by piping a remote script into bash (supply chain) | unsafe | START | this Mac | audit baseline (semgrep) |
| A08 | S3 | scripts | `scripts/mcp_smoke.py:335`, `scripts/searxng_health.py:36` | `dynamic-urllib-use`: URLs built at runtime without an explicit scheme/host guard | unsafe | START | this Mac | audit baseline (semgrep) |
| A09 | S3 | tests | `Tests/WebSearchCoreTests/URLPolicyTests.swift:46` | `detect-insecure-websocket` fires on the *rejection* fixture (false positive) | style | START | this Mac | audit baseline (semgrep) |
| A10 | S1 | CI | `.github/workflows/ci.yml` | No gate for warnings-as-errors, formatter, linter, type checker, coverage floor, or scanners | test | START | this Mac | audit baseline |
| A11 | S2 | scripts | `scripts/*.py` (4 files) | Python is 3.14 with no strict type-checking config and no annotations | style | START | this Mac | audit baseline (pyright) |
| A12 | S2 | cross-unit contracts | `Support/AppConfiguration.swift`, `scripts/*`, `deploy/*`, CI | Env-var contracts between units have no automated consistency check | logic | START | this Mac | scope discovery |

---

## A01 — HTML parse on a cooperative task stack exhausts the stack and kills the process

**Severity** S1, and S0 if it reproduces without a sanitizer · **category** unsafe ·
**status** START (reproduced; expected behaviour written)

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

**Planned fix (Phase C, in this order)**

1. Reject an obvious non-markup body before parsing (validate the response content type and a
   cheap markup sniff), returning `malformedResponse` — the same shape Startpage already uses.
2. Bound the input before handing it to the recursive parser: a maximum nesting depth and a
   maximum body size, with a clean provider failure when exceeded.
3. Parse HTML on a dedicated thread with an explicitly large stack, so a legitimately deep but
   bounded document cannot exhaust a cooperative task stack.
4. Regression test that fails before and passes after, for both the scraper path and
   `web_open`'s extraction path.

**Rejected alternatives.** Raising only the byte cap (does not bound depth); deleting or
skipping the ASan run (forbidden by §0); disabling ASan's stack instrumentation (weakens the
instrument, forbidden); treating it as a SwiftSoup bug and doing nothing (the process still
dies, and the dependency is not ours to patch in time for go-live).

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
