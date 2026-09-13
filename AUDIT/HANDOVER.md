# Handover — MCPSearch pre-production audit

Written 2026-09-13; **updated by the second session on `node1`**. `AUDIT/ledger.md` is
authoritative; `AUDIT/ledger.json` carries every field. This page is orientation only.

## Where things stand

| | |
| --- | --- |
| Branch | `audit/2026-09-13` at **`3cc0620`**, pushed to `origin` (never merged; `main` untouched at `f3dd8d9`) |
| Relationship | `main` is a **strict ancestor** of this branch — `git rev-list --count origin/audit/2026-09-13..origin/main` is 0, so the eventual merge is a fast-forward |
| Tasks | **100 DONE, 0 PROGRESS, 30 START, 0 BLOCKED** (130 enumerated; all open work is S3) |
| Suite | **501 tests, 6 skipped, 0 failures** (486 baseline + 3 from B116) |
| Builds | debug + release, 0 warnings under `-warnings-as-errors` |
| Linters | `swift-format --strict` 0 · `swiftlint --strict` 0 · ruff clean · pyright strict 0 |
| Phases | A, B and D complete; C in progress (all S0/S1/S2 closed); **E not started** |
| CI | green at `9d4b816`'s predecessors: runs 34760288731 and 34760840703, both jobs. Dispatch by hand (see below) |

## What the second session did

Established the baseline on the independent host first, which was the right order: it found that
the suite was **not** reliably green. `StdioServerTests.testToolArgumentClampsAreEnforced` failed
about once in twenty runs, root-caused to a local-throttle boundary race and fixed as **B116** with
a deterministic clock rather than by re-running. Then it closed **B41, B48, B49, B64, B78, B80, B81, B82,
B83, B86, B108, B112, B115** and, in further passes, **B109**, **B110**, **B111**, **B112**, **B113**, **B114**, **B117** and **B50**, folded seven findings the re-read turned up as **B109–B115**, and recorded
B83's deliberately-left residual as **B117**. A later round closed **B50, B110, B111, B113, B114** and
**B117**, and folded **B118** (the invalid `--transport` error still names two of the four spellings
`usage` now documents).

Two things worth carrying forward:

* **The ledger's summary prose was wrong and is now generated.** It read "of the 75 S3 tasks 7 are
  DONE and 68 open", which contradicted both its own table and the `DONE 79` total (79 − 45
  S0/S1/S2 = 34). The mechanical fields — status cell, counts, severity sentence — are now written
  by a helper kept **outside** the repository at `~/Library/Caches/MCPSearch/ledger_tool.py`;
  prose is still written by hand. Run it as `ledger_tool.py complete <ID> <payload.json>`.
* **A green suite on the CI runner is not the same as a green suite here.** The B116 flake passed
  CI repeatedly. Establish the baseline locally, several times, before trusting it.
* **One commit on this branch is authored `Node1 <node1@Node1.local>`** (`audit(B64): …`) rather
  than `Pummelchen`, because a delegated worker committed without an identity override. It is not a
  foreign or imported commit; it cannot be corrected without a force-push, which is forbidden, so it
  is recorded here instead.
* **B78 deleted `ProviderStatus.State.unavailable`**, and B76 is the one open task whose
  expected-correct could want it back. B76's ledger note says so and explains why the deletion was
  still right: B76 owns the producer and should introduce the state with its semantics rather than
  inherit a renderer branch that never ran.

## How the work is done here (so it continues identically elsewhere)

* **Repo root**: this checkout, `/Users/node1/Downloads/MCPSearch` (node1, Mac14,3 M2, **8 GB**).
  It is **not** in Dropbox on this machine, so the old Dropbox traps do not apply — but the
  scratch-path rule still does: every SwiftPM command passes
  `--scratch-path ~/Library/Caches/MCPSearch/audit-a01`, so nothing writes ~1 GB into the repo.
* **One heavy build at a time.** 8 GB is the binding constraint: never run two Swift builds
  concurrently, and never Docker plus a build. Swift work is therefore serialised; Python, shell
  and docs work can run in parallel with it.
* **Per task**: code → test (**prove it can fail**: mutate the production code, watch the new test
  go red, restore) → gates → `AUDIT/evidence/<id>-<slug>.txt` → `AUDIT/ledger.json` **and**
  `AUDIT/ledger.md` → commit `audit(<id>): …` on the branch (never `main`) → push →
  `gh workflow run CI --ref audit/2026-09-13` → verify with
  `gh run view <id> --json status,conclusion` (not `gh run watch`, which has hung) → commit
  `audit(<id>): record the CI run` → mirror the wiki.
* **Gate commands** (all required):

  ```bash
  SCRATCH="$HOME/Library/Caches/MCPSearch/audit-a01"
  swift build --build-tests --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors
  swift test --scratch-path "$SCRATCH"
  swift build -c release --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors
  swift-format lint --recursive --strict Sources Tests Package.swift
  swiftlint lint --strict
  ruff check scripts && ruff format --check scripts && pyright scripts
  bash -n deploy/provision-node.sh && shellcheck deploy/provision-node.sh
  python3 scripts/third_party_notices.py
  ```
* **Toolchain on this host**: Swift 6.3.3 / Xcode 26.6, Python 3.14.7. The audit's six gate tools
  were installed here with Homebrew at exactly the recorded versions — `swift-format` 603.0.0,
  `swiftlint` 0.65.1, `pyright` 1.1.414, `semgrep` 1.176.0, `gitleaks` 8.30.1, `osv-scanner` 2.5.1
  — so the recorder's numbers are reproducible.
* **Evidence must be value-free**: repository-relative paths or `$HOME`/`$SCRATCH`, never
  `/Users/<name>/…`, and never a real secret or tailnet address. The repository is public.
* **Wiki**: clone `https://github.com/Pummelchen/MCPSearch.wiki.git` (the second session used a
  sibling directory, `../mcps-wiki-ro`, so it stays outside the repo), edit `Project-Tracker.md`,
  commit, push to `master`. There is **no GitHub Project** — the wiki page is the tracker.
* **Never**: touch `main`, force-push, work in `/tmp`, or restart a live SearXNG container.
  `node1` runs one (`mcps-searxng`, `127.0.0.1:8888`); its image ID matches the digest pinned in
  `deploy/docker-compose.yml`, so the fleet is in sync.

## Open tasks (30, all S3)

The queue order is this table's order.

| id | sev | category | title | file |
| --- | --- | --- | --- | --- |
| B100 | S3 | test | ToolOutputFormatter's fallback and diagnostic branches are untested | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:526` |
| B101 | S3 | test | HTTPMCPHost's startup-failure and internal-error paths are untested | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:79` |
| B102 | S3 | bug | A cross-scheme redirect is refused by the transport, not by our policy, and surfaces as an opaque transp | `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:245-256 (NoR` |
| B103 | S3 | test | The tool-layer cancellation branches are still not exercised by any test | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:91-93, 142-143, 237` |
| B106 | S3 | test | The PTY harness reports a crashing monitor as a first-frame timeout | `scripts/monitor_tty_smoke.py` |
| B118 | S3 | docs | The invalid --transport error names only two of the four accepted spellings that the usage text now do | `Sources/WebSearchCore/Support/TransportConfiguration.swift (the ` |
| B46 | S3 | incomplete | mcps-mon always exits 0, so --iterations cannot be used as a health check | `Sources/MCPSMonitor/main.swift:45-78 (--iterations  Stop after n` |
| B54 | S3 | bug | Concurrent first use of the Parallel provider performs the MCP handshake more than once | `Sources/WebSearchCore/Providers/ParallelMCPProvider.swift:162` |
| B57 | S3 | logic | The per-provider "which variable enables me" contract is triplicated across units and already wrong for  | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:407` |
| B58 | S3 | style | web_search and web_answer duplicate their argument parsing, and the two schemas have already drifted | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:186` |
| B66 | S3 | dead | Decoded-but-unused vendor DTO fields across five adapters | `Sources/WebSearchCore/Providers/MojeekProvider.swift:219 (and Ex` |
| B70 | S3 | test | Subprocess harnesses advertise a timeout that a blocking read cannot enforce | `Tests/WebSearchCoreTests/StdioServerTests.swift:85 (loop :70-93)` |
| B71 | S3 | test | Three copies of the same subprocess harness, already diverged | `Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift:30` |
| B76 | S3 | logic | mcps-mon ignores SEARCH_DISABLED_PROVIDERS, labels disabled providers "ready", and probes them | `Sources/MCPSMonitor/main.swift:348 (and :292), Sources/WebSearch` |
| B79 | S3 | unsafe | A request-head Content-Length reserves up to 1 MiB per connection before any body arrives | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:167` |
| B84 | S3 | unsafe | IPAddress.v6 is a public case that accepts any byte count, and its accessors index 16 bytes unconditio | `Sources/WebSearchCore/Fetch/URLPolicy.swift:289` |
| B85 | S3 | docs | Query hashing for logs is a fast unsalted FNV-1a, but is documented as non-reversible | `Sources/WebSearchCore/Support/Logging.swift:93` |
| B87 | S3 | docs | The Jina Reader fallback discloses the target URL to a third party by default, with no warning that it d | `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:65` |
| B88 | S3 | perf | The declared per-host DNS cache does not exist, and every redirect hop resolves twice | `Sources/WebSearchCore/Fetch/URLPolicy.swift:57` |
| B89 | S3 | perf | SearchCache.pruneExpired rebuilds the whole dictionary on every read, write and stats call | `Sources/WebSearchCore/Search/SearchCache.swift:103` |
| B90 | S3 | perf | The HTTP listener bounds the request body but nothing else, so idle or slow connections are unbounded | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:61` |
| B91 | S3 | perf | Log emission performs a synchronous blocking write to fd 2 from whatever task is logging | `Sources/WebSearchCore/Support/Logging.swift:42` |
| B92 | S3 | logic | web_open reports the requested URL as final_url on the Jina path, and the reader's own url field i | `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:125` |
| B93 | S3 | test | The new MarkupDepth regression suite still leaves four branches/contracts unpinned | `Sources/WebSearchCore/Fetch/MarkupDepth.swift:190` |
| B94 | S3 | test | testStatusCountsSuccessesAndFailures never observes a failure | `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:716` |
| B95 | S3 | test | The monitor's setup-hint test asserts a string the test itself constructed | `Tests/WebSearchCoreTests/MonitorTests.swift:101` |
| B96 | S3 | test | HTTPStatusMapper.map's HTTPError branches and validate's default/422 statuses are untested | `Sources/WebSearchCore/Providers/HTTPStatusMapper.swift:46` |
| B97 | S3 | test | AnswerSynthesizer's completion edge cases, token usage and locale prompt are untested | `Sources/WebSearchCore/Search/AnswerSynthesizer.swift:349` |
| B98 | S3 | test | The Monitor actor's refresh/counting/warning logic has no Swift test | `Sources/MCPSMonitor/main.swift:337` |
| B99 | S3 | test | No test ties the Swift test harnesses to the Python harnesses, and two scripts are untested entirely | `Tests/WebSearchCoreTests/TestSupport.swift:12` |

## Next steps, in order

1. Continue the S3 queue above, one commit per task, each with its own evidence file, ledger rows
   and CI record.
2. Then **Phase E**: a fresh clone on an independent host (node1 is the designated one, and the
   baseline is already established here), zero warnings, full suite green **repeatedly**, coverage
   at or above the 80 % floor, every scanner clean or waived in writing, the ledger containing only
   DONE or BLOCKED-with-owner, the wiki tracker mirrored, and finally a pull request to `main`.

## Things a new session should know that are easy to rediscover badly

* `AUDIT/environment.md` lists the host facts, the fleet, the secret-scan method and the build
  traps. Its Dropbox sections describe the **first** machine, not this one.
* **Build artefacts lie.** `swift build --target <executable>` does not link the executable, and a
  long-lived scratch tree can hold object files compiled against two different struct layouts. When
  a crash is the thing being investigated, build the **product** into a **fresh** scratch path.
* **A flaky test is a Phase E blocker, not a nuisance.** B116 existed because a 1-in-20 failure was
  invisible to CI. When a test fails intermittently, catch it with a loop
  (`for i in $(seq 1 25); do swift test … ; done`) that saves each log, then fix it with a
  deterministic clock rather than by re-running.
* **Check a claim about platform behaviour before writing it into a comment.** B49's first fix
  rested on "`sed -i` takes its mode from the umask"; measurement showed BSD `sed -i` *preserves*
  the original mode. The wrong assumption is recorded in that artifact next to the measurement
  that killed it.
* Python here is **3.14**, which accepts unparenthesised `except` tuples (PEP 758). That is not a
  syntax error at line 169 of `scripts/mcp_smoke.py`, and it is the style the file already uses.
* `AUDIT/findings/` holds the raw L0–L7 passes; `AUDIT/plan.md` holds the baseline table and the
  phase notes. The last commits on the branch carry the per-task history.
