# Handover — MCPSearch pre-production audit

Written 2026-09-13; **updated by the second session on `node1`**. `AUDIT/ledger.md` is
authoritative; `AUDIT/ledger.json` carries every field. This page is orientation only.

## Where things stand

| | |
| --- | --- |
| Branch | `audit/2026-09-13` at **`a6390f4`**, pushed to `origin` (never merged; `main` untouched at `f3dd8d9`) |
| Relationship | `main` is a **strict ancestor** of this branch — `git rev-list --count origin/audit/2026-09-13..origin/main` is 0, so the eventual merge is a fast-forward |
| Tasks | **120 DONE, 0 PROGRESS, 12 START, 0 BLOCKED** (132 enumerated; all open work is S3) |
| Suite | **548 tests, 6 skipped, 0 failures** (486 baseline + 3 from B116) |
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
* **A finding's premise is wrong often enough that checking it must be the FIRST step.** Four of the
  tasks worked in rounds 2-4 had a false premise, each caught only because the fixer verified before
  implementing:
  * **B106** was already fixed (`761966b1`); only its evidence was missing, so it read START for a
    whole session.
  * **B92** claimed the hosted Jina reader reports the URL it resolved to. Upstream fills that field
    with the *requested* target, so the literal fix cannot add redirect transparency.
  * **B90** prescribed `ChannelOptions.maxConnections`, which does not exist in swift-nio 2.102.0, and
    `IdleStateHandler` is unavailable because NIOExtras is not a dependency. The bounds had to be
    built in `HTTPMCPHost`.
  * **B120** (folded here from B102's residual claim) asserted `ftp:`/`data:` redirects surface as an
    opaque reason. Measured with a loopback redirect probe, `URLSession` consults the redirect
    delegate for every scheme **except `file:`**, so those hops already reach the policy and are
    already refused as `blockedURL(target)`. The task needed no behaviour change at all.

  Two more joined this round: **B58**'s premise was *half* stale (the parser duplication was real,
  the schema drift it also described had already been fixed by B110), and **B57** understated its own
  problem — the enablement mapping was in **five** places, not three.

  So: **verify a finding against the code or a measurement before implementing it, and correct the
  ledger record when the premise falls** — a closed task with a false premise is worse than an open
  one, because the next reader trusts it.
* **A task can be closed in the ledger but still marked START.** B106's fix had been committed
  (`761966b1`) and only its evidence artifact was missing, so it read START for a whole session and
  would have blocked Phase E. Before assuming an open task is open, run
  `git log --oneline --all --grep "audit(<ID>)"` for it.
* **Never run two workers in this checkout.** Two did in round 2: one wrote the shared
  `AUDIT/ledger.json` while the other was mid-task. It was recovered by staging a task-only ledger
  copy via `git update-index --cacheinfo`, but the ledger is a single shared file with no locking,
  so workers must be serialised.
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

## Open tasks (12, all S3)

The queue order is this table's order.

| id | sev | category | title | file |
| --- | --- | --- | --- | --- |
| B100 | S3 | test | ToolOutputFormatter's fallback and diagnostic branches are untested | `Sources/SwiftWebSearchMCP/ToolSchemas.swift:526` |
| B101 | S3 | test | HTTPMCPHost's startup-failure and internal-error paths are untested | `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:79` |
| B103 | S3 | test | The tool-layer cancellation branches are still not exercised by any test | `Sources/SwiftWebSearchMCP/ToolHandlers.swift:91-93, 142-143, 237` |
| B70 | S3 | test | Subprocess harnesses advertise a timeout that a blocking read cannot enforce | `Tests/WebSearchCoreTests/StdioServerTests.swift:85 (loop :70-93)` |
| B71 | S3 | test | Three copies of the same subprocess harness, already diverged | `Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift:30` |
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
