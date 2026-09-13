# AUDIT — plan and phase status

Companion files: [`environment.md`](environment.md) (fleet/toolchain), [`inventory.md`](inventory.md)
(scope), [`ledger.md`](ledger.md) + [`ledger.json`](ledger.json) (tasks),
[`baseline/`](baseline) (raw evidence).

Branch: `audit/2026-09-13` from `main` @ `f3dd8d9`. Never force-pushed; `main` is untouched.

---

## Phase A — inventory, baseline, environment  ✅ complete

| Deliverable | Where |
| --- | --- |
| Scope inventory (units, languages, build systems, entry points, host class) | `inventory.md` |
| Cross-unit dependency graph, implicit contracts, trust boundaries, blast radius | `inventory.md` §2–§5 |
| Fleet + toolchain record, install method, reproducibility | `environment.md` |
| Baseline: build, tests, coverage, lint, analyzers, scanners | `baseline/` |

### Baseline numbers (the regression yardstick — no later state may be worse)

| Metric | Baseline @ `f3dd8d9` | Evidence |
| --- | --- | --- |
| Debug build | **success, 0 compiler warnings, 0 errors** | `baseline/swift-build-debug.log` |
| Release build | **success, 0 warnings, 0 errors** | `baseline/swift-build-release.log` |
| Tests (hermetic) | **371 executed, 6 skipped (opt-in live), 0 failures** | `baseline/swift-test.log` |
| Coverage — repo `Sources/` | **84.3 % lines**, 78.1 % functions | `coverage-sources.txt` |
| Coverage — `WebSearchCore` | 88.2 % lines | `coverage-sources.txt` |
| Coverage — `SwiftWebSearchMCP` | **0 % measured** (driven as a subprocess) | `coverage-sources.txt` |
| Coverage — `MCPSMonitor` | 29.5 % lines | `coverage-sources.txt` |
| AddressSanitizer (test suite) | **CRASH** — see A01 | `swift-test-asan.log` |
| ThreadSanitizer (test suite) | **clean** — 371 executed, 0 data races | `swift-test-tsan.log` |
| `swiftlint` | 491 findings (251 `trailing_comma`, 41 `identifier_name`, 33 `function_body_length`, …) | `swiftlint.json` |
| `swift-format lint` | 19 155 diagnostics (default style ≠ project style) | `swift-format-lint.txt` |
| `ruff check` (4 scripts) | 70 findings; `ruff format --check` → 4 files would be reformatted | `ruff-check.txt`, `ruff-format.txt` |
| `pyright` (default mode, 4 scripts) | 2 errors | `pyright.txt` |
| `shellcheck` (`-S style`) | 13 style notes, 0 warnings/errors | `shellcheck.txt` |
| Secret scan, **full history** (gitleaks) | 5 findings, all synthetic test literals | `gitleaks.json` (values never echoed) |
| Dependency CVE (osv-scanner, 8 packages) | **no issues found** | `osv-scanner.txt` |
| SAST (semgrep, `--config auto`) | 4 findings (2 informational, 1 false positive, 1 supply-chain) | `semgrep.json` |
| YAML parse | 3/3 parse | `yaml-parse.txt` |

Notes that matter for later comparisons:

* The debug log contains 3 `warning:` lines that are **SwiftPM dependency-cache notices**
  ("skipping cache due to an error: The file maintenance.lock doesn't exist"), not compiler
  diagnostics. Compiler warnings from this repository are **0** in both configurations.
* Coverage totals computed with `llvm-cov` over `/Coding/MCPSearch/Sources/` only; an
  unfiltered run reports 40 % because it also counts dependency sources under
  `checkouts/*/Sources/`, which are instrumented but not under test. Both figures are
  recorded in `coverage-sources.txt` for transparency.
* TSan is clean, which matters for A01: the defect is not a data race.

---

## Phase B — audit passes ✅ complete (121 raw findings, all enumerated)

Passes to run, each producing candidate findings that are verified before they enter the
ledger. Swift/Apple work on this Mac or the fleet; Linux/x86 work (none identified yet)
would go to the VPS only after asking.

| Pass | Scope | Status |
| --- | --- | --- |
| L0 repository | reproducibility, pins, lockfile, CI config, `.gitignore`, committed artifacts, history leaks, licensing | ✅ 6 findings |
| L1 architecture | boundaries, layering, duplication, cross-unit contracts, error strategy, config management | ✅ 2 findings |
| L2 module | public API, invariants, resource lifecycle, concurrency, cancellation, timeouts, retries, backpressure, idempotency | ✅ 12 findings |
| L3 line | logic, off-by-one, wrong branch, unreachable code, truncation/overflow, timezone/encoding, unchecked returns, dead params, magic numbers, copy-paste divergence | ✅ 41 findings |
| L4 security | injection, deserialization, SSRF, TOCTOU, temp files, file modes, weak crypto/randomness, authn/authz, secrets, unvalidated external/LLM output, prompt injection, memory safety | ✅ 14 findings (SSRF history known) |
| L5 performance | hot paths, repeated I/O, unbounded memory, pagination/streaming, blocking on async paths, allocation, caching, complexity | ✅ 7 findings |
| L6 tests | critical-path gaps, assertions that assert nothing, flakiness, implementation coupling, failure/boundary paths, integration | ✅ 21 findings |
| L7 ops | logging, structured errors, health checks, shutdown, config validation, runbook accuracy, rollback | ✅ 14 findings |
| §5 placeholders | TODO/FIXME/STUB/dummy markers, stub returns, always-true validators, canned data on production paths, sleeps, dead feature flags, localhost defaults | ✅ 3 concept-level; 0 literal markers |

**Phase B is complete.** Five passes (L0+L7, L1+L2, L3+placeholders, L4+L5, L6) produced 121
findings, one committed record per finding in `findings/`. Phase D folded them into the ledger
as `B01`-`B101` (17 duplicate reports merged); the enumeration, dedup notes and fix order are in
`ledger.md`. Fixing then began in severity order, as the brief requires — A01 was already fixed
in `199a962`.

### Known findings already carried in from the pre-audit session

These were fixed **before** the audit branch existed, on `main`, and are therefore part of
the baseline rather than audit tasks: the SSRF embedded-IPv4 bypass, the stale CI smoke-test
tool list, `web_open` error misattribution, upstream-throttle misclassification, the
`mcps-mon` credit leak, provider-limit registration races, deadline-vs-breaker accounting,
the `mcps-mon` layout/`fillHeight` defects, the `engines` column header, the `NodeProbe`
`unresponsive_engines` key, and the OpenWebSearch bare-array shape. Their regression tests
are in the baseline suite. They are recorded in `ledger.md` as context, not as open work.

---

## Phase C — fix → test → audit (in progress)

Work order: all **S0**, then S1, then S2, then S3. One task = one commit on
`audit/2026-09-13`, message `audit(<id>): <title>`. Each task needs: a test that fails
before and passes after, the full suite green on the correct host class, no new warnings
versus baseline, then a cold re-read plus re-run of linters/scanners before DONE.

## Phase D — new findings (continuous) ✅ folded once; repeats on new findings

Any finding discovered at any time gets a new ledger id and the same treatment.

## Phase E — final verification (not started)

Fresh clone on a **node that did not develop the fix** (node1–node4, 8 GB each, one heavy
job at a time), clean build with zero warnings, full suite green, coverage report, all
scanners clean or waived in writing, zero placeholders, no non-BLOCKED open task, wiki
tracker synced.

---

## Git operations performed (with rollback, per §0)

| Command | Purpose | Rollback |
| --- | --- | --- |
| `git switch -c audit/2026-09-13` | create the audit branch from `main` @ `f3dd8d9` | none needed; `main` is untouched. The branch is never deleted (per §0) — if abandoned, it is simply left unmerged |
| `git push -u origin audit/2026-09-13` | publish the audit branch so the ledger survives context loss | none — no history is rewritten and no existing branch is affected |

No destructive operation (force-push, history rewrite, branch/tag deletion, reset) has been
performed or is planned.
