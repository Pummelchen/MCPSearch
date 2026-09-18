# Audit ledger — MCPSearch

**Generated from `AUDIT/ledger.json` by `AUDIT/render_ledger.py`. Do not edit this
file** —
edit the JSON and re-render, so the two cannot disagree (§8, §9).

- Repository: `MCPSearch`
- Branch: `audit/2026-09-18` (from `992a27f`)
- Primary host: `Node1`; verification host: `macbook-ab.local`

## Counts

**total 10 — done 1 · open 8 · blocked 1**

| Severity | Total | Done | Open | Blocked |
| --- | --- | --- | --- | --- |
| S0 | 1 | 0 | 0 | 1 |
| S1 | 7 | 1 | 6 | 0 |
| S2 | 2 | 0 | 2 | 0 |

Status tally: OPEN 7, PROGRESS 1, DONE 1, BLOCKED 1

## Tasks

| id | sev | tier | status | title |
| --- | --- | --- | --- | --- |
| A0001 | S0 | A | BLOCKED | A live-looking Tavily credential prefix is in public git history and cannot be un-published |
| A0002 | S1 | A | DONE | Warnings-as-errors is not in the build config, so the Swift standard is not in force at the build level |
| A0003 | S1 | A | OPEN | SwiftLint cannot reject a force-unwrap, so the §1 Swift standard proof fails |
| A0004 | S1 | A | OPEN | Ruff does not select S101, so `assert` used for validation is unchecked |
| A0005 | S1 | A | PROGRESS | The secret-scan delegation is unproven: gitleaks is blind to the credential pattern this repository actually leaked |
| A0007 | S1 | A | OPEN | /health returns a hardcoded ok, so the production health surface is wired to nothing |
| A0008 | S1 | C | OPEN | The only check that consumes /health reads the status code and never the body, so it cannot fail |
| A0009 | S1 | A | OPEN | The HTTP server installs no signal handler, and its graceful-shutdown helper is dead code |
| A0006 | S2 | A | OPEN | Validation is written as `assert`, which python -O strips |
| A0010 | S2 | A | OPEN | Installing overwrites the previous binary in place with no rollback path |

---

### A0001 — A live-looking Tavily credential prefix is in public git history and cannot be un-published

- **Severity / tier / status:** S0 / A / BLOCKED
- **Location:** `Tests/WebSearchCoreTests/LiveProviderTests.swift (historical blob at 1f68c23^)`
- **Category:** security/secret-exposure
- **Host:** Node1
- **Discovered by:** L0 secret scan + the repository's own release notes for 1.2.0
- **Evidence before:** gitleaks detect --log-opts=--all reports 0 findings, but the blob at 1f68c23^ contains six tvly-prefixed literals (47, 44, 41, 26, 19, 19 chars). The 1.2.0 release notes already instruct the owner to rotate that key. History is immutable under §0 and the repository is public.
- **BLOCKED:** Credential rotation is forbidden to this audit (§0: never touch live runtime systems, never rotate credentials). Owner: repository owner (Pummelchen). Options for the human: (1) rotate the Tavily key in the vendor console and update config.env on all five machines; (2) if the key is already revoked, record that here and close. Trying history rewrite was rejected: §0 forbids rewriting history, and the repository is already public so a rewrite would not un-disclose it.

### A0002 — Warnings-as-errors is not in the build config, so the Swift standard is not in force at the build level

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Package.swift:64,77,86,95,103`
- **Category:** language-standard
- **Host:** Node1
- **Discovered by:** Phase A build-config review (§1)
- **Evidence before:** Every target declares swiftLanguageMode(.v6) but no target declares treatAllWarnings(as: .error). Warnings only fail because CI and tools/release.sh pass -Xswiftc -warnings-as-errors per invocation; a plain `swift build` emits warnings and exits 0. §1 requires enforcement in build config, not per invocation.
- **Fix:** Added `.treatAllWarnings(as: .error)` to all five targets' swiftSettings in Package.swift, so SwiftPM fails the build on a warning rather than only the CI invocation doing so.
- **Evidence after:** Same scratch file, same command: `swift build --target WebSearchCore` exits 1 (was 0). Clean tree builds (exit 0); full suite green — 593 tests (551 + 42), 6 skipped, 0 failures, 0 warnings; swift-format and swiftlint still clean.
- **Commit:** `b51a7fc`

### A0003 — SwiftLint cannot reject a force-unwrap, so the §1 Swift standard proof fails

- **Severity / tier / status:** S1 / A / OPEN
- **Location:** `.swiftlint.yml:40`
- **Category:** language-standard
- **Host:** Node1
- **Discovered by:** Phase A language-standard proof (§1)
- **Evidence before:** The config enables no opt-in rules ('Opt-in rules are deliberately not enabled by this task', .swiftlint.yml:40), so force_unwrapping is off and `swiftlint lint --strict` accepts a `!` force-unwrap. §1 requires that a force-unwrap fail SwiftLint --strict.

### A0004 — Ruff does not select S101, so `assert` used for validation is unchecked

- **Severity / tier / status:** S1 / A / OPEN
- **Location:** `ruff.toml:15-27`
- **Category:** language-standard
- **Host:** Node1
- **Discovered by:** Phase A lint-config review (§1)
- **Evidence before:** select = [E, F, W, I, UP, B, BLE, SIM, RUF, PERF, FURB]; the S set is deliberately excluded with a rationale that names bandit's subprocess/socket rules. §1 requires the rule that catches 'assert used for validation that -O strips', which is S101.

### A0005 — The secret-scan delegation is unproven: gitleaks is blind to the credential pattern this repository actually leaked

- **Severity / tier / status:** S1 / A / PROGRESS
- **Location:** `.gitleaks.toml`
- **Category:** tool-coverage
- **Host:** Node1
- **Discovered by:** L4 tool-coverage proof (§1)
- **Evidence before:** gitleaks detect --log-opts=--all on full history: 0 findings. Pointed directly at the historical blob (gitleaks detect --no-git --source <blob>) which contains six tvly-prefixed literals: 0 findings. A tool that stays silent does not cover the check.
- **Fix:** Added a `tavily-api-key` rule to .gitleaks.toml. It fires on 17 history findings, so the delegation is no longer silent — but the regex does not yet fire on the historical fixture blob even though Python's `re` matches 6 literals there, so the rule is not yet understood well enough to trust. Open: why gitleaks and Python disagree on the same bytes.

### A0007 — /health returns a hardcoded ok, so the production health surface is wired to nothing

- **Severity / tier / status:** S1 / A / OPEN
- **Location:** `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:537-542`
- **Category:** facade/ops
- **Host:** Node1
- **Discovered by:** L7 ops + §5 facade hunt (subagent, verified by reading the handler at 537-542)
- **Evidence before:** The GET/HEAD /health branch returns a literal body: Data(#"{"status":"ok"}"#.utf8) with status .ok. It consults neither the MCP server, nor the provider registry, nor the circuit breakers, nor the local SearXNG. main.swift advertises the endpoint and README/AGENTS document it as the health check, so an operator or supervisor reading it learns nothing about whether search works. §5: a hardcoded success return on a production path.

### A0008 — The only check that consumes /health reads the status code and never the body, so it cannot fail

- **Severity / tier / status:** S1 / C / OPEN
- **Location:** `scripts/mcp_smoke.py:466-470`
- **Category:** check-cannot-fail
- **Host:** Node1
- **Discovered by:** L7 ops + §5 facade hunt (subagent), corroborated by reading the function
- **Evidence before:** wait_for_health opens the health URL and returns as soon as response.status == 200. It never reads or asserts the body. Since the body is a constant (A0007), "the server is healthy" is proven by "a socket is bound": a process that bound the port and then bricked still passes the smoke test and CI.

### A0009 — The HTTP server installs no signal handler, and its graceful-shutdown helper is dead code

- **Severity / tier / status:** S1 / A / OPEN
- **Location:** `Sources/SwiftWebSearchMCP/main.swift:120-124`
- **Category:** ops/graceful-shutdown
- **Host:** Node1
- **Discovered by:** L7 ops pass (subagent), corroborated by grepping Sources/ for the caller
- **Evidence before:** shutdown(server:host:) is declared and never called anywhere in Sources/. No SIGTERM/SIGINT handler or DispatchSourceSignal exists for the server (the only sigaction code in Sources/ is Monitor/SignalRestore.swift, which belongs to mcps-mon). The HTTP path parks on host.waitUntilStopped(), whose continuation is resumed only by stop(). So `docker stop` or `launchctl unload` kills the process outright: open sessions, the bound socket and group.shutdownGracefully() never run. The stdio path is unaffected (the SDK exits on stdin EOF).

### A0006 — Validation is written as `assert`, which python -O strips

- **Severity / tier / status:** S2 / A / OPEN
- **Location:** `scripts/mcp_smoke.py:147,161,167,204,211,533; scripts/soak.py:160,166,199,208`
- **Category:** python/assert
- **Host:** Node1
- **Discovered by:** Phase A Python review (§1 pitfall list)
- **Evidence before:** Ten `assert` statements guard real conditions, including the environment-scrub check (mcp_smoke.py:147) and a port-race check (mcp_smoke.py:533). Running the harness under `python3 -O` silently disables every one of them, so the check would report success while asserting nothing.

### A0010 — Installing overwrites the previous binary in place with no rollback path

- **Severity / tier / status:** S2 / A / OPEN
- **Location:** `deploy/install.sh:477-478`
- **Category:** ops/rollback
- **Host:** Node1
- **Discovered by:** L7 ops pass (subagent)
- **Evidence before:** cp of the new binary over $BIN, with no backup of the previous one, no version pin to reinstall and no uninstall path (grep finds no rollback/uninstall/backup/revert in deploy/, tools/ or Sources/). config.env is staged safely and keys are preserved, so the binary is the only irreversible part.
