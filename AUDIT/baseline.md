# §3 Baseline — MCPSearch

Measured once, on the primary host (§1b), at `992a27f` + the Phase A commit, before any fix.
The language mode in force was read back rather than assumed — see `AUDIT/environment.md`.

| Metric | Baseline |
| --- | --- |
| Debug build (`swift build --build-tests -Xswiftc -warnings-as-errors`) | **success, 0 warnings** |
| Release build (`swift build -c release`) | **success, 0 warnings** |
| Test suite (`swift test --enable-code-coverage`) | **593 tests, 6 skipped, 0 failures** |
| — `WebSearchCoreTests` | 551 (6 skipped) |
| — `MCPSMonitorTests` | 42 |
| Line coverage, `Sources/` | **91.6 %** — 10 449 / 11 401 lines, 57 files, 4 reports |
| Coverage floor (`coverage_floor.py Sources/ 80`) | **pass** (floor 80 %) |
| `swift-format lint --recursive --strict` | **0 findings** |
| `swiftlint lint --strict` | **0 findings** |
| `ruff check scripts` + `ruff format --check` | **0 findings** |
| `pyright` (strict, pinned 1.1.414) | **0 errors, 0 warnings** |
| `shellcheck -S warning` over `deploy/*.sh tools/*.sh` | **0 findings** |
| `semgrep --config=p/default --error` | **0 findings** (332 rules run) |
| `osv-scanner --lockfile Package.resolved` | **8 packages, 0 known vulnerabilities** |
| `gitleaks detect --log-opts=--all` | **0 findings** — see the tool-coverage caveat below |
| Python `assert` count in `scripts/` | 10 (finding A0006) |

Captured under `~/Library/Caches/MCPSearch/audit/` on the primary host, outside the repository:
`baseline.txt`, `baseline-test.log`, `lint-*.txt`, `build-release.log`, `gitleaks.json`.

## Regression yardstick

No later state may be worse on any metric above without a justified numbered task (§3). The two
numbers a fix is most likely to move are the warning count (must stay 0) and line coverage (must not
fall below 91.6 % without a task saying why). The suite count may only rise; a fix that deletes or
skips a test to make something pass is forbidden by §0 and would show here.

## Caveat carried forward from the baseline

`gitleaks` reports **0 findings over full history**, and that number is **not** evidence that
history is clean. The same scanner, pointed directly at the blob at `1f68c23^`, also reports 0 —
while that blob contains six `tvly`-prefixed literals. The delegation is therefore unproven, which
is finding **A0005**, and the exposure it failed to find is **A0001**. A baseline figure a tool
produced without covering its check is recorded here as a caveat rather than as a pass.
