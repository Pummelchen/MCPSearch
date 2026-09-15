# Handover — MCPSearch pre-production audit

Written 2026-09-13; **updated by the second session on `node1`**. `AUDIT/ledger.md` is
authoritative; `AUDIT/ledger.json` carries every field. This page is orientation only.

## Where things stand

| | |
| --- | --- |
| Branch | `audit/2026-09-13`, pushed to `origin`. `main` was merged **into** the branch (`4b59dfa`, ledger B125) after it advanced 8 commits |
| Relationship | `main` is an **ancestor** of this branch again, so PR #1 is a **fast-forward**; GitHub reports it `MERGEABLE` |
| Tasks | **138 DONE, 0 PROGRESS, 0 START, 0 BLOCKED** (138 enumerated) |
| Suite | **590 tests, 6 skipped, 0 failures** |
| Builds | debug + release, 0 warnings under `-warnings-as-errors`, on **Swift 6.4 / Xcode 27** |
| Linters | `swift-format --strict` 0 · `swiftlint --strict` 0 · ruff clean · pyright strict 0 · shellcheck 0 · semgrep 0 · gitleaks 0 · osv-scanner 0 |
| Phases | **A, B, C, D and E complete**; the only remaining work is merging PR #1 |
| CI | green on the branch; the workflow now runs on the `xcode-27` image (Swift 6.4) |
| Blocked | none. `B122`, the parked cancellation-contract decision, was resolved as "propagate" |

### The go-live session (2026-09-15)

Five tasks were added and closed, and the record above is this session's state:

* **B122** — the parked decision. A caller's cancellation during synthesis is now propagated as a
  `CancellationError` (consistent with `B04` for search and fetch), so the tool layer's cancelled arm
  is reachable; `B97`'s opposite expectation was re-pinned as part of the same change.
* **B123** — the mandated toolchain. CI runs on `xcode-27` and its gate requires 6.4; the fleet had
  already been upgraded to Swift 6.4 / Xcode 27 / macOS 27 out from under the audit; `environment.md`
  §1.1 records it.
* **B127** — the manifest floor stays at `swift-tools-version: 6.3`. Raising it to 6.4 broke GitHub's
  CodeQL Swift scan, which builds with the runner's Swift 6.3.3 and cannot parse a 6.4 manifest, so a
  raised floor silently cost the repository a SAST gate.
* **B124** — found by running the gates on the new toolchain: SwiftPM 6.4 emits one test bundle per
  target under `out/Products`, so the coverage gate's hard-coded bundle path no longer resolved. It
  now discovers the bundles and fails loudly if there are none.
* **B125** — `main` was merged into the branch, resolving the single `README.md` conflict, so PR #1 is
  a fast-forward again. The exact command and its rollback were committed *before* the operation.
* **B126** — the README's suite count (371 → 590) and its CI description, which omitted every gate the
  audit added.

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

  Two more joined in round 5: **B58**'s premise was *half* stale (the parser duplication was real,
  the schema drift it also described had already been fixed by B110), and **B57** understated its own
  problem — the enablement mapping was in **five** places, not three.

  Round 7 added two more: **B98** claimed a testable seam the Monitor actor did not have (it built
  its own HTTP client), and **B100** named a `"No results."` branch that cannot be reached. **B101**
  found its internal-error arm unreachable from the HTTP surface — measured, not assumed.

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
* **Toolchain on this host**: Swift 6.4 / Xcode 27, Python 3.14.7 (the fleet was upgraded on
  2026-09-15; `environment.md` §1.1 has the measurement). The audit's six gate tools
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

## Open tasks

**None.** `AUDIT/ledger.json` holds **139 tasks, all DONE, 0 BLOCKED**. The rows that used to sit here
(`B103`, `B121`) were closed in the previous session, and `B122` — the one BLOCKED-with-owner item,
the cancellation-contract decision — was resolved in the go-live session by propagating the
cancellation. The audit-branch queue is therefore empty; the only remaining work is merging
[PR #1](https://github.com/Pummelchen/MCPSearch/pull/1).

## Next steps, in order

1. **Merge [PR #1](https://github.com/Pummelchen/MCPSearch/pull/1)** into `main`. It is
   `MERGEABLE` and a fast-forward again: `main` advanced eight commits after the PR opened, so it was
   merged *into* the branch (`B125`) rather than rebased, and the single `README.md` conflict was
   resolved by keeping both sides. Nothing else is outstanding.
2. After the merge, `main` carries the audit. The five S0 equivalents and the rest of the fixes stop
   being branch-only, which is the whole point of the exercise.
3. **Human actions recorded** (see the wiki `Project-Tracker`, ISSUE-20 and ISSUE-21).

   **ISSUE-21 is closed.** GitHub's AI code-scanning check was auto-enabled on this repository and
   failed on every PR head with a Copilot service error (`CAPIError: 400 The requested model is not
   supported`) that no repository change could influence. The cause is on the service side: the
   Autofind job asks `api.individual.githubcopilot.com` for the model
   `sweagent-capi:claude-opus-5`, which an individual Copilot plan does not serve, so the job died
   in under 90 seconds without ever reaching a scan — it could not have reported a finding. It was
   never a gate either: `main` is unprotected and carries no rulesets, so it blocked nothing and
   only painted every pull request red.

   The decision is to disable it rather than leave a check that can only ever error. AI Scan for
   pull requests is off via `PATCH /repos/{owner}/{repo}/code-scanning/ai-scan` with
   `{"pr_scan": "disabled"}` — here, and on every other non-archived `Pummelchen` repository, since
   each had it auto-enabled and would have failed identically on its next pull request. The two
   archived repositories carry no such setting. Re-enabling is the same endpoint with `"enabled"`,
   and is worth revisiting only with a Copilot entitlement that serves the requested model.

   **ISSUE-20 remains open, and is the more serious of the two:** rotate the GitHub PAT that sits in
   cleartext in the local wiki clones' `.git/config`.

### The Phase E checklist, and where it now stands

A fresh clone on an independent host, zero warnings, the full suite green, coverage at or above the
80 % floor, every scanner clean or waived in writing, zero placeholders, a ledger with no non-BLOCKED
open task, the wiki tracker mirrored, and a pull request into `main`.

Verified twice: **node1** at `891b94f` (2026-09-14, preserved as
`AUDIT/evidence/PHASE-E-2026-09-14-node1.txt`) and **node2** at `6e0f70a` (2026-09-15, a host that
developed none of the changes) — 0 warnings, 590 tests / 0 failures, `Sources/` coverage 91.7 %
against the 80 % floor, all 18 gates clean. Artifact:
`AUDIT/evidence/PHASE-E-independent-host.txt`.

> **Why Phase E ran twice.** The branch changed after the first run: `B122`–`B127` were closed, and
> `B123`/`B127` changed the toolchain the build runs on. A verification of a commit that is no longer
> the tip is worth re-doing rather than citing.
## Things a new session should know that are easy to rediscover badly

* `AUDIT/environment.md` lists the host facts, the fleet, the secret-scan method and the build
  traps. Its Dropbox sections describe the **first** machine, not this one.
* **A false green is the specific danger when mutating for a RED.** B93 hit two mechanical traps that
  together produced one: `swift build --build-tests` does not reliably recompile the library for a
  source-only edit made within the same second (a `touch` forces it), and the spawned product must be
  relinked separately or an end-to-end test still talks to the old server. If a mutation does not turn
  a test red, suspect the build before concluding the test is blind.
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
