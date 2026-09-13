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
| DONE | 1 |
| START (reproduced, expected behaviour written) | 11 |
| BLOCKED | 0 |

Two cross-cutting gates are **not** tasks but acceptance criteria for Phase E: the whole
suite must be green on an independent host, and every scanner must be clean or explicitly
waived in writing.

---

## Open tasks

| id | sev | unit | file:line | title | category | status | host | discovered-by |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A01 | **S0** | `WebSearchCore` (scrapers + fetch) | `Fetch/MarkupDepth.swift`, `Fetch/LargeStackParse.swift`, `Providers/ScraperSupport.swift:89`, `Fetch/HTMLExtractor.swift:81` | HTML parse on a cooperative task stack exhausts the stack and kills the process | unsafe | DONE | this Mac (arm64) | audit baseline (ASan) |
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
