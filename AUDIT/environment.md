# AUDIT — environment and reproducibility record

Audit of **MCPSearch** (`Pummelchen/MCPSearch`), branch `audit/2026-09-13`, branched from
`main` at `f3dd8d9`. Started 2026-09-13.

This file is the single source of truth for *where* the audit ran and *what* it installed.
Everything recorded here must be re-installable from this file alone. The task ledger is
[`ledger.md`](ledger.md); the scope is [`inventory.md`](inventory.md); the plan is
[`plan.md`](plan.md).

---

## 1. Hosts

| Host | Role in this audit | Hardware | OS | Notes |
| --- | --- | --- | --- | --- |
| `MacBook-AB.local` (this Mac, `Mac15,3`) | development + Apple-platform builds/tests; also the machine being audited | 24 GB RAM, arm64 | macOS 26.6.2 (25G83) | repo lives in Dropbox (`~/Library/CloudStorage/Dropbox/Coding/MCPSearch`) — see §5 |
| `node1` … `node4` | Mac fleet: independent Apple-platform verification (Phase E) | `Mac14,3` Mac mini M2, **8 GB RAM** | macOS 26.6.2 | reached as `nodeN@nodeN.local` (mDNS) or `nodeN@100.x` (Tailscale); **key auth, no password needed** |
| Debian 13 (Trixie) Intel VPS (`91.99.176.243`) | not used | — | — | reserved for Linux/x86 work if needed; **not provisioned by this audit** and requires asking first |

Per-host toolchain (recorded 2026-09-13):

| Host | Swift | Xcode | Docker | Colima | Python |
| --- | --- | --- | --- | --- | --- |
| this Mac | 6.3.3 | 26.6 (`/Applications/Xcode.app`) | 29.8.0 | — (Docker Desktop) | 3.14.7 |
| node1–node4 | 6.3.3 | 26.6 | 29.8.0 | 0.10.3 | — (not needed) |

All four nodes are identical, which is what makes any of them a valid independent
verification host.

---

## 2. Toolchain per language present in scope

| Language | Compiler/runtime | Formatter | Linter | Type checker | Static analysis | SAST | Dependency CVE | Secret scan |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Swift (`swift-tools-version: 6.3`) | Swift 6.3.3, strict concurrency (language mode 6) | `swift-format` 603.0.0 | `swiftlint` 0.65.1 | compiler (Swift 6 type checker) | `swift build --sanitize=address` / `thread` | `semgrep` 1.176.0, CodeQL (GitHub default setup, Swift) | `osv-scanner` 2.5.1 on `Package.resolved` | `gitleaks` 8.30.1, full history |
| Python (`scripts/*.py`) | CPython 3.14.7 | `ruff format` (ruff 0.16.7) | `ruff check` | `pyright` 1.1.414 | `pyright` | `semgrep` 1.176.0 | none (stdlib only — see §3) | `gitleaks` |
| Bash (`deploy/provision-node.sh`) | `/bin/bash` 3.2 (macOS) | — | `shellcheck` | — | — | `semgrep` | — | `gitleaks` |
| YAML (`ci.yml`, `docker-compose.yml`, `settings.yml`) | — | — | `python3 -c yaml.safe_load` parse check | — | — | `semgrep` | — | `gitleaks` |

Coverage: `swift test --enable-code-coverage` + `xcrun llvm-cov report`.

### Languages in the brief but NOT in this repository

The audit brief specifies standards for C#/.NET and C. Neither language appears in this
repository — `git ls-files` shows 69 `.swift`, 4 `.py`, 3 `.yml`, 1 `.sh`, 1 `.resolved`,
1 `.env` template and docs. There is no `.csproj`, `.sln`, `CMakeLists.txt`, `Makefile`,
`go.mod`, `Cargo.toml`, `package.json` or Xcode project, and no submodules.

* C# / .NET 10 tooling: **N/A — no C# in scope.**
* C tooling (strict C99, ASan/UBSan, valgrind): **N/A — no C in scope.** The equivalent
  memory-safety instruments for the language that *is* in scope (Swift AddressSanitizer /
  ThreadSanitizer) are part of the plan.

This is recorded as N/A rather than BLOCKED: BLOCKED is for a tool that could not be
installed, and no such tool is needed for a language that is absent.

---

## 3. Installed by this audit

Installed on **this Mac only**, with Homebrew 6.0.22-325-g06cc132, on 2026-09-13:

```bash
brew install swift-format osv-scanner pyright
```

| Tool | Version | Why |
| --- | --- | --- |
| `swift-format` | 603.0.0 | Swift formatter (baseline + gate) |
| `osv-scanner` | 2.5.1 | dependency / CVE scan of `Package.resolved` |
| `pyright` | 1.1.414 | strict type checking of `scripts/*.py` |

Already present before the audit (not installed by it): `swiftlint` 0.65.1, `gitleaks`
8.30.1, `semgrep` 1.176.0, `ruff` 0.16.7, `shellcheck`, `jq` 1.8.2, `node` v26.8.2,
Docker 29.8.0, Homebrew, Swift 6.3.3 / Xcode 26.6, CPython 3.14.7.

### How the secret scan is run (and why it is `detect`, not `dir`)

`gitleaks detect --source . --log-opts=--all` scans git-tracked content and its history; that is
the gate. `gitleaks dir .` additionally reads git-ignored files, and on this Mac it reports exactly
one thing: `config.env:20`, the operator's own credential file (git-ignored, mode 0600, live-looking
values on lines 9 and 20, values recorded nowhere in the repository). Scanning a working directory
would therefore fail for every correctly configured operator while proving nothing about the
repository.

History contains five `generic-api-key` findings, all the same synthetic literal in two test files
from commit `41d56935`. They are waived in writing in `.gitleaks.toml`, whose allowlist is an AND of
those two paths and that exact literal and which keeps the default ruleset (`[extend]
useDefault = true`); the working tree no longer contains the literal. Ledger: A06.


### Nothing installed on the fleet

No package, container or file was installed on node1–node4 or on the VPS during this
session. Phase E clones the repository to a node and builds there; if that requires
installing anything, it is appended to this table first, and the clone/build artefacts are
removed afterwards. The nodes already carry exactly the toolchain Phase E needs.

Containers: none created so far. Any container used later is disposable — no audit state
lives only inside one.

---

## 4. Local build recipe (this machine only)

The repository lives inside a Dropbox folder, and Dropbox has evicted files inside `.build`
and `.git` before (see §5). **All local Swift work therefore uses a scratch path outside
Dropbox:**

```bash
SCRATCH=~/Library/Caches/MCPSearch/audit-baseline     # fresh scratch, outside Dropbox
swift build --scratch-path "$SCRATCH"
swift build -c release --scratch-path "$SCRATCH"
TAVILY_API_KEY=tvly-ci-placeholder-not-a-real-key \
  swift test --enable-code-coverage --scratch-path "$SCRATCH"
```

`TAVILY_API_KEY=tvly-ci-placeholder-not-a-real-key` is deliberate: `LiveProviderTests`
requires **both** `SEARCH_LIVE_TESTS=1` and a usable key, so the placeholder guarantees the
hermetic suite with no network and no credits. Live tests are run only deliberately.

This is a machine quirk, not a repository requirement: CI on a clean `macos-26` runner uses
plain `swift build` / `swift test` (see `AUDIT/baseline/`).

---

## 5. Known host hazards (affect how the audit must run)

1. **Dropbox evicts files, including inside `.git`.** During the pre-audit session Dropbox
   turned `.git/objects/pack/*.pack` into a `compressed,dataless` placeholder, which made
   every object read fail with `Operation timed out`. Recovery was `git fetch --refetch
   origin` (a fresh pack from GitHub). Consequences: some git commands (notably a full
   `git status`) can stall on the file provider, and the stale dataless pack still produces
   harmless read errors. `git log`, `add`, plumbing commits and `push` all work.
2. **`.build` inside the repository is unusable** — Dropbox had evicted it; it is now empty
   and marked `com.dropbox.ignored`. Builds go to a scratch path (§4).
3. **SwiftPM intermittently reports "input file ... was modified during the build"** when
   Dropbox touches file metadata mid-build. The fix is to retry the build; the sources are
   not corrupted (verified by comparing against `HEAD` blobs).
4. **8 GB per node.** At most one heavy build/test per node at a time, and never Docker plus
   an Xcode build together on the same node.

---

## 6. Access notes

* Fleet: `ssh nodeN@nodeN.local` (mDNS) or `nodeN@100.x.x.x` (Tailscale), key-based, no
  password prompt. `BatchMode=yes` works, which is how the toolchain table above was taken.
* Node IPs seen in the monitor defaults: node1 `100.66.125.48`, node2 `100.97.158.87`,
  node3 `100.114.69.128`, node4 `100.80.144.76`.
* No credentials are recorded in this file, and none are printed in any audit artefact.
