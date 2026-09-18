# §1 Tool-coverage and language-standard proofs — MCPSearch

A check delegated to a tool is covered only if the tool is configured to catch it (§1). Each entry
below introduces a deliberate violation in a scratch file, records the tool's actual output, and
deletes the scratch file. **A tool that stays silent does not cover the check**, and the entries that
stayed silent became ledger tasks rather than being written down as passes.

All commands run on the primary host (`Node1`) at `992a27f` + the Phase A commit.

## Language standards

### Swift — strict concurrency must reject a non-Sendable capture

**COVERED.** Swift 6 language mode (`swiftLanguageMode(.v6)` on all five targets) checks complete
concurrency, and the compiler rejects the violation rather than warning about it.

Scratch `Sources/WebSearchCore/ScratchConcurrencyProof.swift` (deleted after recording):

```swift
final class NotSendable {
    var value = 0
}

func captureAcrossBoundary(_ object: NotSendable) {
    Task {
        object.value += 1
    }
}
```

```
$ swift build --target WebSearchCore
exit=1
.../ScratchConcurrencyProof.swift:9:5: error: passing closure as a 'sending' parameter risks causing
    data races between code in the current isolation context and concurrent execution of the closure
    [#RegionIsolation::SendingClosureRisksDataRace]
error: Build failed
```

So the strict-concurrency half of the Swift standard **is** in force at the build level. The
warnings-as-errors half is not — see finding A0002, which is about `treatAllWarnings(as:)` missing
from `Package.swift`, a separate question from isolation checking.

### Swift — a force-unwrap must fail `swiftlint --strict`

**NOT COVERED — finding A0003.**

Scratch `AUDIT/proofs/ScratchProof.swift`:

```swift
func forceUnwrap(_ value: String?) -> Int {
    return Int(value!)!
}
```

```
$ swiftlint lint --strict --quiet AUDIT/proofs/ScratchProof.swift
exit=2
.../ScratchProof.swift:8:23: error: Returning Whitespace Violation: Return arrow and return type
    should be separated by a single space or on a separate line (return_arrow_whitespace)

$ swiftlint lint --strict --quiet AUDIT/proofs/ScratchProof.swift | grep -c "Force Unwrap"
0
```

The negative control matters here: the same invocation on the same file reports an **enabled** rule
and exits 2, so the linter is running and reading the file. It simply has `force_unwrapping` switched
off (`.swiftlint.yml:40`, "Opt-in rules are deliberately not enabled by this task"). The standard is
therefore not in force, and the fix is to enable the rule rather than to accept the silence.

### C — strict C99, implicit declarations, GNU extensions

**Not applicable.** `git ls-files` finds zero `.c`, `.h`, `.cpp`, `.hpp` or `.m` files, and no
Swift↔C module map or bridging header exists (`AUDIT/inventory.md` §2.3, item 9). There is nothing to
compile under `-std=c99 -pedantic-errors`, and nothing for ASan/UBSan to run.

### Python — a bare `except:` must be rejected

**COVERED** by `E722` inside the selected `E` set.

Scratch file:

```python
def bare_except(path):
    try:
        return open(path).read()
    except:
        return None
```

```
$ ruff check AUDIT/proofs/scratch_ruff.py
AUDIT/proofs/scratch_ruff.py:7:5: E722 Do not use bare `except`
Found 1 error.
```

**A note on how this proof was almost wrong.** The first attempt carried an inline
`# noqa: E722` in the scratch file — written to excuse the violation, which is exactly backwards.
Ruff then reported `SIM105` and `SIM115` and **no** `E722`, and the proof would have been recorded as
"the bare except is covered" on the strength of an output that did not contain it. Re-run without the
`noqa`, the rule fires. Both the mistake and the correction are recorded because the failure mode —
a proof that passes for a reason other than the one claimed — is the thing this document exists to
prevent.

### Python — `assert` used for validation must be rejected

**NOT COVERED — finding A0004.**

```
$ ruff check AUDIT/proofs/scratch_ruff.py          # config as committed
AUDIT/proofs/scratch_ruff.py:7:5: E722 Do not use bare `except`
Found 1 error.                                      # no S101, for the assert on line 12

$ ruff check --select E722,S101,PT AUDIT/proofs/scratch_ruff.py
AUDIT/proofs/scratch_ruff.py:7:5: E722 Do not use bare `except`
AUDIT/proofs/scratch_ruff.py:12:5: S101 Use of `assert` detected
Found 2 errors.
```

`ruff.toml` selects `E F W I UP B BLE SIM RUF PERF FURB`, which contains neither `S101` nor `PT`.
Ten real `assert`s in `scripts/` are therefore unchecked (finding A0006).

## Scanners

### `gitleaks` — a known-leaked credential pattern must be detected

**NOT COVERED — finding A0005**, and this is the most consequential entry here, because the check it
fails to cover has already failed once in this repository.

```
$ gitleaks detect --log-opts=--all --report-format json --redact
exit=0            # 0 findings over full history

$ git show 1f68c23^:Tests/WebSearchCoreTests/LiveProviderTests.swift > <outside the repo>/historical.swift
$ python3 -c '<count tvly-prefixed literals>'     # values never printed
line 192: literal starting 'tvly', 19 chars, value redacted
line 193: literal starting 'tvly', 19 chars, value redacted
line 199: literal starting 'tvly', 26 chars, value redacted
line 213: literal starting 'tvly', 47 chars, value redacted
line 216: literal starting 'tvly', 41 chars, value redacted
line 231: literal starting 'tvly', 44 chars, value redacted

$ gitleaks detect --no-git --source <...>/historical.swift --report-format json --redact
exit=0            # still 0 findings, pointed straight at the file
```

Six key-shaped literals, one of them the 47-character prefix of a live Tavily key that this
repository's own 1.2.0 release notes instruct the owner to rotate, and the scanner is silent on all
of them. The delegation is unproven and the fix is a rule in `.gitleaks.toml`, with a negative
control to show the rule fires on a value outside the waiver.

### `semgrep` — SAST must reject a dangerous pattern

**COVERED.**

```
$ semgrep scan --config=p/default --error --metrics=off AUDIT/proofs/scratch_py.py
exit=1
• Findings: 1 (1 blocking)
  ❯❯❱ python.lang.security.audit.subprocess-shell-true.subprocess-shell-true
       Found 'subprocess' function 'run' with 'shell=True'.
```

Baseline across the whole repository: 0 findings, 332 rules run.

### `pyright` — a type error must be rejected

**COVERED** (strict mode, pinned 1.1.414).

```
$ pyright AUDIT/proofs/scratch_py.py
exit=1
.../scratch_py.py:6:12 - error: Type "int" is not assignable to return type "str"
1 error, 0 warnings, 0 informations
```

### `shellcheck` — a destructive expansion must be rejected

**COVERED.**

```
$ shellcheck -S warning AUDIT/proofs/scratch.sh
In AUDIT/proofs/scratch.sh line 2:
rm -rf "$DIR"/
       ^-----^ SC2115 (warning): Use "${var:?}" to ensure this never expands to / .
```

### `swift-format` — a formatting violation must be rejected

**COVERED** under `--strict` (which is how CI and the release gate invoke it).

```
$ swift-format lint --strict AUDIT/proofs/ScratchProof.swift
exit=1
AUDIT/proofs/ScratchProof.swift:8:21: error: [Spacing] remove 1 space
AUDIT/proofs/ScratchProof.swift:8:26: error: [Spacing] add 1 space
```

### `osv-scanner` — dependency CVEs: input covered, detection unproven for this ecosystem

**Input COVERED, detection UNPROVEN — recorded, not waived.**

```
$ osv-scanner scan --lockfile Package.resolved
exit=0
Scanned Package.resolved file and found 8 packages
No issues found
```

The lockfile is parsed and every pinned package enumerated, so the tool is wired to the right input.
Detection could not be proven *for the SwiftPM ecosystem*: the OSV database holds no entries for any
of the nine SwiftPM packages probed (`swift-nio`, `SwiftSoup`, `swift-sdk`, `vapor`, `swift-crypto`,
`swift-protobuf`, `grpc-swift`, `CryptoSwift`, and the server's own graph), so there is no vulnerable
version to test against. The detection path itself is proven on a scratch manifest for an ecosystem
where entries do exist:

```
$ printf 'urllib3==1.24.1\n' > requirements.txt && osv-scanner scan --lockfile requirements.txt
exit=1
Total 1 package affected by 12 known vulnerabilities (0 Critical, 6 High, 6 Medium, 0 Low, ...)
```

Residual risk, stated rather than hidden: if a CVE were published tomorrow for one of the eight
pinned packages, this scanner would report it — the mechanism works and CI re-runs it on every push —
but that specific detection has not been demonstrated, because the database has nothing to
demonstrate it with. No human check was removed on the strength of this tool.

### `coverage_floor.py` — the floor must actually fail

**COVERED**, in all three directions.

```
$ python3 scripts/coverage_floor.py "$PWD/Sources/" 99 coverage-*.json
exit=1
::error::Sources/ line coverage is 91.6 %, below the 99 % floor. Lower the floor only with the reason
    recorded in the pull request that lowers it.

$ python3 scripts/coverage_floor.py "$PWD/Sources/" 80          # no reports at all
exit=2            # usage error: it refuses to pass vacuously

$ python3 scripts/coverage_floor.py "$PWD/Sources/" 80 coverage-*.json
exit=0
Sources/ line coverage: 10449/11401 = 91.6 % (floor 80 %, 57 files from 4 report(s))
```

A floor that cannot fail is decoration; this one fails on a raised floor and on a missing report.

## Summary

| Delegated check | Tool | Covered? |
| --- | --- | --- |
| Swift formatting | `swift-format --strict` | Yes |
| Swift style and force-unwrap | `swiftlint --strict` | Style yes, **force-unwrap no (A0003)** |
| Swift strict concurrency | compiler, Swift 6 mode | Yes |
| Python formatting and lint | `ruff` | Yes |
| Python bare `except` | `ruff` E722 | Yes |
| Python `assert` | `ruff` S101 | **No (A0004)** |
| Python types | `pyright` strict | Yes |
| Shell | `shellcheck -S warning` | Yes |
| Dangerous patterns | `semgrep` | Yes |
| Secrets in history | `gitleaks` | **No (A0005)** |
| Dependency CVEs | `osv-scanner` | Input yes; SwiftPM detection unproven |
| Coverage floor | `coverage_floor.py` | Yes |
