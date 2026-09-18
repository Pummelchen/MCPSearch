# Audit environment — MCPSearch

Recorded once, at Phase A. One pinned toolchain per language, one primary host per §1b.

## Primary host (baseline, fixes, tests)

| | |
| --- | --- |
| Host | `Node1` — this machine |
| OS | macOS 27.0 (build 26A428), `arm64` |
| CPU / RAM | 8 cores / **8 GiB** |
| Disk free at baseline | 37 GiB of 228 GiB |
| Repository | `/Users/node1/Downloads/MCPSearch` |
| Branch | `audit/2026-09-18`, forked from `main` @ `992a27f` |

**8 GiB means one heavy job at a time** (§1b). Builds, test runs and sanitizer runs are therefore
serialised deliberately rather than run concurrently; a job that OOMs is recorded and parallelism
lowered, never retried blindly.

## Independent host (Phase E, single final verification)

| | |
| --- | --- |
| Host | `macbook-ab.local` (reached as `andreborchert@macbook-ab.local`) |
| OS | macOS 27.0 |
| Toolchain | **Xcode 27.0**, **Apple Swift version 6.4** (`swiftlang-6.4.0.34.1`) — identical to the primary host |

Chosen because it must run a Swift 6.4 / Xcode 27 strict-concurrency build, and the rest of the
fleet is Linux, which cannot (§1b: "Do not attempt Swift 6.4 strict-concurrency builds on Linux
hosts"). It is a separate machine from the primary host, which is what §1b requires.

## Languages present (§2.1)

| Language | Present | Standard in force | Notes |
| --- | --- | --- | --- |
| Swift | Yes — 58 source files, 15 581 lines | Swift 6 language mode, complete concurrency, warnings as errors | See below |
| Python | Yes — 9 scripts | Ruff format + lint, basic tier | Test/glue code, no dependency manifest |
| Shell | Yes — 5 `.sh` (3 in `tools/`, 2 in `deploy/`) | `shellcheck -S warning` | Release machinery and provisioning |
| C / C++ | **No** — `git ls-files` finds zero `.c/.h/.cpp/.hpp/.m` | n/a | The C99 standard, its warning set, its sanitizers and the native-interop seam in §2.3 do not apply. No Swift↔C module map or bridging header exists either. |

## Toolchain versions

Formatter, linter, type checker, dependency scanner and secret scanner per language; SAST across
Tier A. All installed via Homebrew at `/opt/homebrew/bin` — one pinned version per language, not a
matrix (§1).

| Tool | Version | Role | Covers |
| --- | --- | --- | --- |
| `swift-format` | 603.0.0 | Swift formatter | `Sources`, `Tests`, `Package.swift` via `.swift-format` |
| `swiftlint` | 0.65.1 | Swift linter | same, via `.swiftlint.yml`, run `--strict` |
| `ruff` | 0.16.7 | Python formatter + linter | `scripts`, via `ruff.toml` |
| `pyright` | 1.1.414 | Python type checker | `scripts`, strict, via `pyrightconfig.json` |
| `shellcheck` | 0.11.0 | Shell linter | `deploy/*.sh`, `tools/*.sh`, `-S warning` |
| `semgrep` | 1.176.0 | SAST | whole tree, `--config=p/default --error` |
| `gitleaks` | 8.30.1 | Secret scanner (full history, once) | whole history, `.gitleaks.toml` |
| `osv-scanner` | 2.6.0 | Dependency/CVE scanner | SwiftPM graph, `Package.resolved` |

### Not applicable, with the reason

- **`pip-audit`** — not installed, and deliberately not: §1 conditions it on "a requirements/lock
  file exists". `git ls-files` finds no `requirements*.txt`, `poetry.lock`, `Pipfile`,
  `pyproject.toml`, `uv.lock` or `setup.py`. The Python here has no declared dependencies beyond
  the standard library.
- **C toolchain (`clang`/ASan/UBSan, strict C99)** — no C sources exist.
- **Valgrind** — not run, and not run alongside ASan by §1's own instruction.
- **`swift test --sanitize=thread`** — applies, and is run in a later phase; §1 requires it for
  concurrency-heavy targets, and `WebSearchCore` is actor- and Task-heavy.

## Toolchain standing (§1) — verified, not assumed

Both required proofs are recorded with their violating snippet and the tool's actual output in
`AUDIT/tool-coverage.md`. The summary at baseline:

| Requirement | In force at baseline? |
| --- | --- |
| Swift 6 language mode, per target | **Yes** — `.swiftLanguageMode(.v6)` on all five targets |
| Complete strict concurrency | **Yes** — implied by Swift 6 language mode |
| Warnings as errors *in build config* | **No** — only per-invocation (`-Xswiftc -warnings-as-errors` in CI, `tools/release.sh`) |
| `swiftlint --strict` fails the build | Yes, via CI step |
| Force-unwrap rejected by the linter | **No** — `force_unwrapping` is opt-in and not enabled |
| Ruff covers bare `except` | Yes — `E722` is inside the selected `E` set |
| Ruff covers `assert` for validation | **No** — the `S` set is not selected |
| Python version pinned | Yes — `target-version = "py314"`, interpreter 3.14.7 |

Unmet rows are recorded in the ledger as tasks, not waived.
