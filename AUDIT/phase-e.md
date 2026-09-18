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
