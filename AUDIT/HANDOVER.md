# Handover — MCPSearch pre-production audit

Written 2026-09-13 so this work can continue on another machine.
`AUDIT/ledger.md` is authoritative; `AUDIT/ledger.json` carries every field. This page is orientation only.

## Where things stand

| | |
| --- | --- |
| Branch | `audit/2026-09-13`, pushed to `origin` (never merged; `main` untouched at `f3dd8d9`) |
| Tasks | **79 DONE, 0 PROGRESS, 41 START, 0 BLOCKED** (all open tasks are S3) |
| Suite | 486 tests, 6 skipped, 0 failures |
| Builds | debug + release, 0 warnings under `-warnings-as-errors` |
| Linters | `swift-format --strict` 0 · `swiftlint --strict` 0 · ruff clean · pyright strict 0 |
| Scanners | semgrep 0 with no exclusions · gitleaks 0 with the written `.gitleaks.toml` waiver for five synthetic test literals · osv-scanner 0 |
| Phases | A, B and D complete; C in progress (all S0/S1/S2 closed, 41 S3 open); **E not started** |
| Wiki | `Project-Tracker.md` and the pages each change touched are mirrored and pushed |

## How the work is done here (so it continues identically elsewhere)

* **Repo root**: this checkout (inside Dropbox). Every SwiftPM command passes
  `--scratch-path ~/Library/Caches/MCPSearch/audit-a01`; never let SwiftPM use the default `.build`,
  which writes ~1 GB into the synced folder (recorded in `AUDIT/environment.md`).
* **Per task**: code → test (prove it can fail: mutate the production code, watch the new test go
  red, restore) → gates → `AUDIT/evidence/<id>-<slug>.txt` → `AUDIT/ledger.json` **and**
  `AUDIT/ledger.md` → commit `audit(<id>): …` on the branch (never `main`) → push →
  `gh workflow run CI --ref audit/2026-09-13` → wait for green → commit `audit(<id>): record the CI
  run` → mirror the wiki.
* **CI**: pushes to this branch trigger nothing (`CI` runs on `main` pushes and pull requests), so
  dispatch by hand. The dispatch API intermittently answers HTTP 500 — retry with `sleep 30`–`40`.
  `gh run watch` once hung for ten minutes; `gh run view <id> --json status,conclusion` is the
  reliable check.
* **Wiki**: clone `https://github.com/Pummelchen/MCPSearch.wiki.git` (for example to
  `~/Library/Caches/MCPSearch/wiki`), edit `Project-Tracker.md` (and any page the change touches),
  commit, push to `master`.
* **Never**: touch `main`, force-push, work in `/tmp`, restart the live local SearXNG container
  (`127.0.0.1:8888`), or commit raw gitleaks output (it carries matched values).

## Open tasks (41, all S3)

| id | sev | category | title | file |
| --- | --- | --- | --- | --- |
| B41 | S3 | deps | Apache-2.0 `NOTICE` files of two dependencies are not carried with any distributed binary | ``Package.swift:31-34`` |
| B46 | S3 | incomplete | `mcps-mon` always exits 0, so `--iterations` cannot be used as a health check | ``Sources/MCPSMonitor/main.swift:45-78` (`--iterations  Stop after n refreshes (useful for ` |
| B48 | S3 | bug | `provision-node.sh` cannot find a Homebrew-installed Tailscale CLI on Apple Silicon | ``deploy/provision-node.sh:296-297`` |
| B49 | S3 | unsafe | The generated SearXNG `settings.yml` inherits the umask, so the per-node secret key is world-readable | ``deploy/provision-node.sh:192-199`, `:203-235`` |
| B50 | S3 | incomplete | Provisioning destroys the working instance before its replacement is proven on the production port, with no ro | ``deploy/provision-node.sh:255-284`` |
| B54 | S3 | bug | Concurrent first use of the Parallel provider performs the MCP handshake more than once | ``Sources/WebSearchCore/Providers/ParallelMCPProvider.swift:162`` |
| B57 | S3 | logic | The per-provider "which variable enables me" contract is triplicated across units and already wrong for `paral | ``Sources/SwiftWebSearchMCP/ToolHandlers.swift:407`` |
| B58 | S3 | style | `web_search` and `web_answer` duplicate their argument parsing, and the two schemas have already drifted | ``Sources/SwiftWebSearchMCP/ToolHandlers.swift:186`` |
| B64 | S3 | bug | Malformed JSON from a node is reported as "unreachable" | ``Sources/WebSearchCore/Monitor/NodeProbe.swift:102` (catch at `:133-142`)` |
| B66 | S3 | dead | Decoded-but-unused vendor DTO fields across five adapters | ``Sources/WebSearchCore/Providers/MojeekProvider.swift:219` (and `ExaProvider.swift:174`, `` |
| B70 | S3 | test | Subprocess harnesses advertise a timeout that a blocking read cannot enforce | ``Tests/WebSearchCoreTests/StdioServerTests.swift:85` (loop `:70-93`)` |
| B71 | S3 | test | Three copies of the same subprocess harness, already diverged | ``Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift:30`` |
| B76 | S3 | logic | `mcps-mon` ignores `SEARCH_DISABLED_PROVIDERS`, labels disabled providers "ready", and probes them | ``Sources/MCPSMonitor/main.swift:348` (and `:292`), `Sources/WebSearchCore/Search/ProviderR` |
| B78 | S3 | dead | `ProviderStatus.State.probing` and `.unavailable` can never be produced, so their renderer branches are unreac | ``Sources/WebSearchCore/Monitor/MonitorModel.swift:127` and `:134`` |
| B79 | S3 | unsafe | A request-head `Content-Length` reserves up to 1 MiB per connection before any body arrives | ``Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:167`` |
| B80 | S3 | bug | `soak.py` conflates EOF with a malformed stdout line and discards the line | ``scripts/soak.py:170` (used at `:183`)` |
| B81 | S3 | bug | `mcp_smoke.py` de-chunks an SSE body after decoding it to `str` | ``scripts/mcp_smoke.py:315` (decode at `:296`)` |
| B82 | S3 | bug | A negative `--queries` silently truncates the query list from the end | ``scripts/soak.py:327` (argument at `:301`)` |
| B83 | S3 | bug | HTTP smoke can wait 20 s on a dead server and never checks that it is alive | ``scripts/mcp_smoke.py:345-353` (port at `:350-357`, stderr only read at `:458`)` |
| B84 | S3 | unsafe | `IPAddress.v6` is a public case that accepts any byte count, and its accessors index 16 bytes unconditionally | ``Sources/WebSearchCore/Fetch/URLPolicy.swift:289`` |
| B85 | S3 | docs | Query hashing for logs is a fast unsalted FNV-1a, but is documented as non-reversible | ``Sources/WebSearchCore/Support/Logging.swift:93`` |
| B86 | S3 | unsafe | Provisioning writes through fixed, predictable `/tmp` paths and loads a container image from one | ``deploy/provision-node.sh:71`` |
| B87 | S3 | docs | The Jina Reader fallback discloses the target URL to a third party by default, with no warning that it did | ``Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:65`` |
| B88 | S3 | perf | The declared per-host DNS cache does not exist, and every redirect hop resolves twice | ``Sources/WebSearchCore/Fetch/URLPolicy.swift:57`` |
| B89 | S3 | perf | `SearchCache.pruneExpired` rebuilds the whole dictionary on every read, write and stats call | ``Sources/WebSearchCore/Search/SearchCache.swift:103`` |
| B90 | S3 | perf | The HTTP listener bounds the request body but nothing else, so idle or slow connections are unbounded | ``Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:61`` |
| B91 | S3 | perf | Log emission performs a synchronous blocking write to fd 2 from whatever task is logging | ``Sources/WebSearchCore/Support/Logging.swift:42`` |
| B92 | S3 | logic | `web_open` reports the requested URL as `final_url` on the Jina path, and the reader's own `url` field is deco | ``Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:125`` |
| B93 | S3 | test | The new `MarkupDepth` regression suite still leaves four branches/contracts unpinned | ``Sources/WebSearchCore/Fetch/MarkupDepth.swift:190`` |
| B94 | S3 | test | `testStatusCountsSuccessesAndFailures` never observes a failure | ``Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:716`` |
| B95 | S3 | test | The monitor's setup-hint test asserts a string the test itself constructed | ``Tests/WebSearchCoreTests/MonitorTests.swift:101`` |
| B96 | S3 | test | `HTTPStatusMapper.map`'s HTTPError branches and `validate`'s default/422 statuses are untested | ``Sources/WebSearchCore/Providers/HTTPStatusMapper.swift:46`` |
| B97 | S3 | test | `AnswerSynthesizer`'s completion edge cases, token usage and locale prompt are untested | ``Sources/WebSearchCore/Search/AnswerSynthesizer.swift:349`` |
| B98 | S3 | test | The `Monitor` actor's refresh/counting/warning logic has no Swift test | ``Sources/MCPSMonitor/main.swift:337`` |
| B99 | S3 | test | No test ties the Swift test harnesses to the Python harnesses, and two scripts are untested entirely | ``Tests/WebSearchCoreTests/TestSupport.swift:12`` |
| B100 | S3 | test | `ToolOutputFormatter`'s fallback and diagnostic branches are untested | ``Sources/SwiftWebSearchMCP/ToolSchemas.swift:526`` |
| B101 | S3 | test | `HTTPMCPHost`'s startup-failure and internal-error paths are untested | ``Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:79`` |
| B102 | S3 | bug | A cross-scheme redirect is refused by the transport, not by our policy, and surfaces as an opaque transport er | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:245-256 (NoRedirectDelegate), Sources/` |
| B103 | S3 | test | The tool-layer cancellation branches are still not exercised by any test | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:91-93, 142-143, 237-238, 262-263` |
| B106 | S3 | test | The PTY harness reports a crashing monitor as a first-frame timeout | `scripts/monitor_tty_smoke.py` |
| B108 | S3 | deps | The pinned GitHub Actions still target Node 20, which the runner is deprecating, so every job is forced onto N | ``.github/workflows/ci.yml` (actions/checkout, actions/cache pins)` |

## Next steps, in order

1. Continue the S3 queue above (the ledger's order is the queue order). Batch the small ones no more
   than the "one task = one commit" rule allows: one commit per task, with its own evidence file and
   ledger rows, plus the CI-record commit.
2. Then **Phase E**: fresh clone on an independent host (node1, one heavy job at a time), zero
   warnings, full suite green, coverage at or above the 80 % floor, every scanner clean or waived in
   writing, ledger containing only DONE or BLOCKED-with-owner, wiki tracker mirrored, and finally a
   pull request to `main`.

## Things a new session should know that are easy to rediscover badly

* `AUDIT/environment.md` lists the host facts, the fleet, the secret-scan method and the build traps
  (build artefacts lie; `--target` does not link; the Dropbox `.build` trap).
* `AUDIT/evidence/B32-B28-ci-hardening.txt` records two of the audit's own tests that were
  environment-sensitive: a clamp test that depended on ambient placeholder credentials, and a timing
  bound that measured the scheduler. Both are fixed; the lesson is worth keeping.
* `AUDIT/findings/` holds the raw L0–L7 passes; `AUDIT/plan.md` holds the baseline table (now citing
  value-free summaries) and the phase notes.
* The last commits on the branch carry the per-task history; `git log --oneline` reads as the audit
  trail.
