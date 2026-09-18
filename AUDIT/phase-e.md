# Phase E — independent-host verification

Per §1b, the final verification runs on a host other than the primary one. This is that run.

## Where and what

| | |
|---|---|
| Primary host | `Node1` (this Mac) — where every fix was written |
| Independent host | `MacBook-AB.local` (`andreborchert@macbook-ab.local`) |
| Host OS | macOS 27.0 |
| Toolchain | Swift 6.4 (`swiftlang-6.4.0.34.1`), Xcode 27.0, `arm64` |
| Commit verified | `75adee87cb65af052deff0dd2a252d1379515805` |
| Branch | `audit/2026-09-18` |
| Clean tree at that commit | yes — `git status --porcelain` empty |

## How the code got there, and what was deliberately not done

`origin` **does not have** the audit branch, and this audit does not push. So the branch was
transferred as a self-contained bundle and cloned from it:

```
git bundle create phase-e.bundle audit/2026-09-18     # 2.2 MB
scp phase-e.bundle andreborchert@macbook-ab.local:~
git clone --branch audit/2026-09-18 ~/phase-e.bundle ~/mcps-phase-e
```

The clone is a fresh checkout at the exact commit, on a different machine, with no working tree
carried over. It is not a clone *from origin*, and that distinction is stated rather than glossed:
a reviewer who wants the origin path will need the branch pushed first, which is a decision for the
repository owner and not one this audit took.

## Results

Every command below ran on `MacBook-AB.local` inside the fresh clone. `PASS` means exit 0.

| Gate | Result |
|---|---|
| `swift build --build-tests -Xswiftc -warnings-as-errors` | PASS — exit 0, **0 warnings** |
| `swift test` | PASS — **573 + 42 tests, 6 skipped, 0 failures** |
| `swift-format lint --recursive --strict` | PASS |
| `swiftlint lint --strict` | PASS |
| `ruff check scripts` | PASS |
| `ruff format --check scripts` | PASS |
| `pyright` | PASS |
| `shellcheck -S warning` (deploy + tools) | PASS |
| `scripts/harness_tests.py` | PASS |
| `scripts/mcp_smoke.py <bin>` (stdio) | PASS |
| `scripts/mcp_smoke.py <bin> --http` | PASS |
| `scripts/dual_client_contract.py <bin-dir>` | PASS |
| `tools/check-version.sh` | PASS |
| `gitleaks detect --log-opts=--all` | PASS — 0 findings |
| `osv-scanner scan source -r .` | PASS |
| `semgrep --error` | PASS |

The independent host has the whole toolchain installed — `swift-format`, `swiftlint`, `ruff`,
`pyright`, `shellcheck`, `gitleaks`, `semgrep`, `osv-scanner`, `python3` — so nothing in the table
above is `NOT CHECKED` for want of a tool. That is the point of checking the toolchain list first.

## The one failure, and what it was

`dual_client_contract.py` **failed** on the first run of that gate, and it is worth recording
because the first reading of it was wrong:

```
DUAL CLIENT CONTRACT FAILED: no binary at
  .../Debug/SwiftWebSearchMCP/SwiftWebSearchMCP
```

The path has the product name twice. The script takes the **bin directory** and joins
`SwiftWebSearchMCP` onto it itself (line 111); I passed the full binary path, as the other two
harnesses accept. CI and `tools/release.sh` both pass `"$(swift build --show-bin-path)"`.

So this was **my invocation error, not a product defect** — and the correct reading is the one that
matters: a fresh host surfaced a difference in how the harnesses take their argument, and the first
run of a check is exactly where that should surface. Re-run with the directory:

```
DUAL CLIENT CONTRACT PASSED
  one stub, two executables: SwiftWebSearchMCP and mcps-mon
  both name duckduckgo: CAPTCHA, mojeek: timeout and the answering engine
  both treat an instance that answered with nothing as a failure
```

## What Phase E does not cover

- **Live provider traffic.** No real credential was used; `LiveProviderTests` is opt-in and stayed
  off, so no key was spent.
- **The installer.** `deploy/install.sh` was not executed here either: it installs software and
  needs a SearXNG, which is the same reason it was not run on the primary host.
- **A clone from `origin`.** See above — a bundle clone, and the branch is not on `origin`.
- **Release packaging.** `tools/release.sh` was not run end-to-end; it publishes, and the audit does
  not release.

## Verdict

The commit verified above builds warning-free and passes every static gate, the full Swift suite,
all three Python harnesses and the version check **on a machine other than the one it was written
on**, from a clean checkout. Per §11 Phase E, that is the required end-to-end run, and it passed in
one pass after one invocation error of mine was corrected.

---

# Phase E — final run

The run above verified `75adee87`. The tree changed afterwards (A0005, A0016, A0029, A0055), so it
was **stale** and Phase E was repeated on the final commit. A verification that predates the work it
verifies is not a verification, which is why this second run exists rather than a reference to the
first.

| | |
|---|---|
| Commit verified | `a7c840b9497b173c36463a3025cdcc743ff1cad6` |
| Clone | fresh, from the bundle, `git status --porcelain` empty |
| Build | exit 0, **0 warnings** |
| Tests | **Executed 574 tests, with 6 tests skipped and 0 failures (0 unexpected) in 35.910 (35.969) seconds** |
| Gates | **all PASS** |

Every gate, run in that clone:

```
PASS  swift-format        PASS  harness_tests        PASS  gitleaks defaults
PASS  swiftlint           PASS  smoke stdio          PASS  gitleaks project
PASS  ruff check          PASS  smoke http           PASS  osv-scanner
PASS  ruff format         PASS  contract             PASS  semgrep
PASS  pyright             PASS  check-version
PASS  shellcheck
```

Two gitleaks rows, not one: the project credential-shape rules are a second pass because one config
cannot carry both the defaults and custom rules in this scanner version (A0005).

Nothing in that list is NOT CHECKED for want of a tool, and no gate in the audit's gate list was
skipped. The limits named above still apply: no live provider traffic, the installer not run, no clone
from `origin`, no release packaging.

**With this run, both halves of the completion condition hold on the same commit: the ledger's open
count is zero (52 DONE, 3 BLOCKED with named owners) and Phase E passes end to end on an independent
host.**

---

# Phase E — run 3, the commit that closes A0011 and A0017

Runs 1 and 2 above verified `75adee87` and `a7c840b9`. Both are **stale**: A0011 (six steps of the
`MarkupDepth` model) and A0017 (the peer-address check) landed after them. A verification that
predates the work it verifies is not a verification, which is why this run exists rather than a
reference to the second.

| | |
|---|---|
| Commit verified | `bcc29bc9752aaeed6ce06334a514cdc68e2f4866` |
| Branch | `audit/2026-09-18` — `main` still at `992a27f`, 142 ahead, 0 behind |
| Clone | fresh, from the bundle, `git status --porcelain` empty |
| Primary host | `Node1`, macOS 27.0, Swift 6.4 |
| Independent host | `MacBook-AB.local`, macOS 27.0, Swift 6.4 (`swiftlang-6.4.0.34.1`), `arm64` |

The clone's `HEAD` was compared with the primary host's before any gate ran, because a bundle that
resolved to the wrong commit would make every row below meaningless:

```
primary     bcc29bc9752aaeed6ce06334a514cdc68e2f4866
independent bcc29bc9752aaeed6ce06334a514cdc68e2f4866
```

**This run was performed twice, and the first attempt is the reason.** It first verified `44ced26`,
which was the commit that closed A0011 and A0017. Re-reading the goal afterwards showed a change made
*after* that commit which was not part of this record: `AGENTS.md` and `README.md` still carried the
old test counts, and this audit's own test additions are what moved them. Correcting documentation is
still a change to the verified tree, and "the gate would not read a README" is an argument, not a
verification — so the bundle was rebuilt from the corrected commit and the whole table was run again
rather than carrying the first result forward. The first attempt's numbers are not quoted anywhere
below, because they belong to a commit that is not the final one.

## Every gate

| Gate | Result |
|---|---|
| `swift build --build-tests -Xswiftc -warnings-as-errors` | PASS — exit 0, **0 warnings**, 0 errors |
| `swift test` | PASS — **581 + 42 tests, 6 skipped, 0 failures** |
| `swift-format lint --recursive --strict` | PASS |
| `swiftlint lint --strict` | PASS — 0 findings |
| `tools/check-version.sh` | PASS — version agreement 1.2.0 |
| `swift package resolve` + `git diff --exit-code Package.resolved` | PASS — no lockfile drift |
| `gitleaks detect --source . --log-opts=--all` | PASS — no leaks |
| `gitleaks` project config, same scope | PASS — no leaks |
| `osv-scanner scan source -r .` | PASS — no issues |
| `semgrep --error` | PASS |
| `ruff check scripts` | PASS |
| `ruff format --check scripts` | PASS |
| `pyright scripts` | PASS |
| `shellcheck -S warning` (deploy, tools) | PASS |
| `scripts/harness_tests.py` | PASS |
| `scripts/mcp_smoke.py <bin>` (stdio) | PASS — "stdout carried only valid JSON-RPC; diagnostics appeared on stderr" |
| `scripts/mcp_smoke.py --http <bin>` | PASS — "negative cases refused (no session, no SSE accept, cross-origin)" |
| `scripts/dual_client_contract.py <bin-dir>` | PASS |
| `scripts/monitor_tty_smoke.py <bin>` | PASS — "SIGTERM exited 0 and restored the terminal" |

The independent host has the whole toolchain, so **no row is `NOT CHECKED` for want of a tool**. The
test count agrees exactly with the primary host: **581 in the core suite plus 42 in the monitor
suite — 623 total — 6 skipped, 0 failures**. The smaller totals in the raw log are per-`XCTestCase`
lines, not a second suite.

The limits named above still apply unchanged: no live provider traffic, the installer not run, no
clone from `origin`, no release packaging.

## Three invocation errors, all mine, none a product defect

A fresh host is where a difference in how a harness takes its argument shows up, and this run found
three — each of which first read as a failure:

| What I ran | What it said | What it was |
|---|---|---|
| `shellcheck deploy/… tools/*.sh` | exit 1, 4 findings | CI and `release.sh` both run **`shellcheck -S warning`**. At the default severity the four are `info`, and shellcheck exits non-zero on any finding. With `-S warning`: exit 0. |
| `mcp_smoke.py <bin-dir>` | "server binary not found at …/Products/Debug" | CI passes the **binary**, `"$(swift build -c release --show-bin-path)/SwiftWebSearchMCP"`. With the binary: PASS. |
| `dual_client_contract.py <bin-dir>` | — | This one I got right, having learned it in run 1: it takes the directory, not the binary. |
| `swift build -c release > +/dev/null` | four harnesses: "no binary at …" | A **typo in my gate script**, `+/dev/null` for `/dev/null`. The redirect failed, so the release build never ran and the four binary harnesses had nothing to run. They passed once it did. |

So the argument conventions are not uniform across the four harnesses, and two of the three are the
opposite of each other. That is worth knowing, and it is recorded here rather than in a message.

## A false positive, named so it is not mistaken for a finding

`shellcheck` at default severity reports **SC2015** at `deploy/install.sh:553`:

```sh
[ "$archs" = "arm64" ] && pass "binary is native arm64" || fail "binary is '$archs', expected arm64"
```

`A && B || C` is not `if-then-else`, because `C` runs when `B` fails. Here it cannot: `pass()` is
`printf 'PASS  %s\n' "$*"`, which returns 0 whenever it returns. **Checked, not assumed** — this is a
false positive at this call site, and it is recorded rather than silently dropped, because "the
linter is at `-S warning`" is not a reason a reader should have to take on trust.

## Verdict

The commit that closes A0011 and A0017 builds warning-free and passes every static gate, the full
Swift suite, all four Python harnesses and the version check **on a machine other than the one it was
written on**, from a clean checkout at the verified commit. Both halves of the completion condition
therefore hold on `bcc29bc`: the ledger's non-terminal count is **zero** (54 DONE, 1 BLOCKED with a
named owner — A0001, rotating a live credential, which this audit does not touch), and Phase E passes
end to end on an independent host.

The only commit after `bcc29bc` is this record's own update, so the diff following verification is the
audit's documentation and nothing else — the same arrangement as runs 1 and 2.
