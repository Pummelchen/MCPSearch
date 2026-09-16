# MCPSearch

<!-- agent-harnesses:begin -->
> **One instruction file.** This is it. Codex, DeepSeek Harness, OpenCode,
> Qwen Code, Qoder and Zed read `AGENTS.md` directly, and Claude Code reads it
> through the committed `CLAUDE.md`, which contains nothing but `@AGENTS.md`.
> **Edit only this file** — do not add a second set of instructions anywhere.
>
> Do **not** add `.rules`, `.cursorrules`, `.windsurfrules`, `.clinerules`,
> `.github/copilot-instructions.md` or `AGENT.md`. Zed takes the *first match*
> from that list, **ahead of `AGENTS.md`**, so any one of them silently
> replaces this file for every Zed user.
<!-- agent-harnesses:end -->

A Swift-native MCP server that gives a local AI client real public-web search, page
fetching and grounded answers, with no mandatory paid infrastructure: every
credential is optional, and the server starts and explains what is missing. Three
products share one package — `SwiftWebSearchMCP` (the MCP server, over stdio or
Streamable HTTP), `mcps-mon` (a live terminal dashboard), and `WebSearchCore` (the
library). **All search, fetch and reliability logic lives in `WebSearchCore`, which
contains no MCP code**, so it is testable without a transport. Released `1.0.1`
(2026-09-16) with prebuilt arm64 binaries and `SHA256SUMS`; there is no Node or
Python runtime. Swift 6.4 / Xcode 27, Apple Silicon only (M1–M6, native `arm64`, no
Intel slice).

## Layout

- `Sources/SwiftWebSearchMCP/` — the MCP surface: `MCPServer.swift` (holds
  `serverVersion`, which reads `BuildVersion`), `HTTPMCPHost.swift`, `ToolHandlers.swift`,
  `ToolSchemas.swift`, `main.swift`.
- `Sources/WebSearchCore/` — `Providers/` (nine `SearchProvider` adapters plus
  scraper support), `Search/` (orchestrator, weighted RRF fusion, cache, circuit
  breaker), `Fetch/` (`URLPolicy` SSRF layer, `HTMLExtractor`, `JinaReaderFetcher`),
  `Support/` (`HTTPClient`, config, loopback/Origin policy, the generated
  `BuildVersion.swift`), `Monitor/`.
- `Tests/WebSearchCoreTests/` (551) and `Tests/MCPSMonitorTests/` (40) — fixtures
  are inline Swift literals, not a resource bundle.
- `VERSION` — the authoritative version at the repository root. See Identity.
- `tools/` — the release machinery: `sync-version.sh` (writes the mirrors from
  `VERSION`), `check-version.sh` (the version-agreement gate CI runs), and
  `release.sh` (the whole release, dry run by default).
- `scripts/` — the CI harnesses: `mcp_smoke.py`, `monitor_tty_smoke.py`,
  `coverage_floor.py`, `soak.py`, `harness_tests.py`, `third_party_notices.py`.
- `deploy/` — a digest-pinned SearXNG compose file and `provision-node.sh`.
- `docs/` — four research notes whose claims are labelled VERIFIED / UNVERIFIED /
  NOT FOUND, plus the per-release `release-notes-vX.Y.Z.md`.

## Build, test, run

```bash
swift build                     # release: swift build -c release
swift test                      # 591 tests, 6 skipped
SEARCH_LIVE_TESTS=1 swift test --filter LiveProviderTests   # opt-in, needs a key

swift run mcps-mon              # --probe adds provider latency
swift build -c release --show-bin-path   # then run SwiftWebSearchMCP
SwiftWebSearchMCP --transport http --port 8080   # serves /mcp plus GET /health
```

CI's build gate is `swift build --build-tests -Xswiftc -warnings-as-errors`, and
tests run under `--enable-code-coverage` with a **hard 80 % floor** on `Sources/`
enforced by `python3 scripts/coverage_floor.py Sources/ 80`.

## Identity

**`VERSION` at the repository root is authoritative.** It holds a bare `X.Y.Z`.
`Sources/WebSearchCore/Support/BuildVersion.swift` is **generated** from it and is
the only version literal in `Sources/`; `MCPServer.swift` reports it in the MCP
`initialize` result, the Parallel provider sends it as `clientInfo.version`, and the
default `SEARCH_USER_AGENT` is built from it. Editing `BuildVersion.swift` by hand is
a mistake — `tools/check-version.sh` regenerates the expected content and fails when
the file differs, when `CHANGELOG.md` has no `## [X.Y.Z]` heading for the version, or
when a version literal appears anywhere else in `Sources/`.

A bump is therefore **two steps, not one**:

```bash
printf '1.0.2\n' > VERSION      # 1. the one authoritative edit
tools/sync-version.sh           # 2. rewrites BuildVersion.swift
tools/check-version.sh          #    verify (CI runs this too)
```

Add the `## [X.Y.Z]` changelog section and a `docs/release-notes-vX.Y.Z.md` in the
same change. Before this arrangement the version lived in three unconnected places
with nothing tying them together, so a half-done bump shipped a server that
misreported its own version over MCP.

## Gates

- Toolchain must parse as **≥ 6.4**; the step parses `swift -version` itself and
  refuses to guess on unparseable output.
- `swift package resolve` then `git diff --exit-code Package.resolved` — lockfile
  drift fails the job. Dependencies are pinned with `exact:`.
- Debug and release builds with `-warnings-as-errors`; then `scripts/mcp_smoke.py`
  (stdio and `--http`) and `scripts/monitor_tty_smoke.py` (pseudo-terminal). The
  smoke test also **asserts the server reports the version in `VERSION`** — it used
  to print the reported version without checking it, so any version passed.
- A second `swift test` run with **placeholder credentials**, to prove the suite is
  hermetic.
- **Version mirrors agree with `VERSION`** — `bash tools/check-version.sh`.
- Static job: `swift-format lint --recursive --strict`, `swiftlint lint --strict`,
  `ruff check`/`format --check` on `scripts`, `pyright`, `shellcheck` (over
  `deploy/provision-node.sh` **and `tools/*.sh`**), `gitleaks detect --log-opts=--all`,
  `osv-scanner`, `semgrep --error`, and `scripts/harness_tests.py`.
- There are **no git hooks and no pre-commit config** — run the commands yourself.

## Traps

- **stdout must carry JSON-RPC framing only; diagnostics go to stderr.** A stray
  `print` corrupts the MCP stream — that is what the smoke test exists to catch.
- **CodeQL must stay in advanced setup** (`codeql.yml`, manual build). Default setup
  builds with the image's Swift 6.3.3, cannot parse the 6.4 manifest, and **silently
  removes SAST** while appearing to run.
- The HTTP transport binds `127.0.0.1` unless `--host` is passed, has **no
  authentication and no TLS**, and refuses undeclared `Host` names with
  `421 Misdirected Request`; behind a proxy add `--http-allowed-host <name>`.
- **`web_open` falls back to the third-party Jina Reader** (`r.jina.ai`), sending it
  the full target URL *including any credential in it*. `SEARCH_ENABLE_JINA_READER=false`
  disables the fallback. The SSRF policy runs before the fallback.
- `web_answer` is inert without `DEEPSEEK_API_KEY`, and it is **not a search
  provider**: it never participates in selection, fusion or ranking.
- An older toolchain fails opaquely: `… using Swift tools version 6.4.0 but the
  installed version is 6.3.3`.
- Keys belong in the git-ignored `config.env`. `swift test` is hermetic by design, so
  a plain run cannot spend credits — live tests need `SEARCH_LIVE_TESTS=1` **and** a
  usable `TAVILY_API_KEY`.
- Scrapers are opt-in (`SEARCH_ENABLE_SCRAPERS=true`). DuckDuckGo throttles to
  roughly one query per 10 s, and Startpage is currently unusable (Anubis
  proof-of-work).

## Releasing

**Read [`RELEASE.md`](RELEASE.md) before cutting a release.** It is this repository's
own release standard — edited here, not published from anywhere else — and it carries
both the general rules and this repository's own section. Do not improvise a release.

Cutting one is a single command once the version is bumped and landed:

```bash
tools/check-version.sh                 # identity agrees (CI runs it too)
#  bump VERSION, run tools/sync-version.sh, add the changelog section and
#  docs/release-notes-vX.Y.Z.md, land it on main
git tag -a vX.Y.Z -m "MCPSearch X.Y.Z" && git push origin vX.Y.Z
git checkout vX.Y.Z                    # §1.4: HEAD must be the tag
tools/release.sh                       # dry run — gates the build, publishes nothing
tools/release.sh --publish             # only on a clean dry run
```

`tools/release.sh` walks the standard for you: preconditions, the gates above, a
clean scratch `arm64` build with the log scanned for compiler warnings, the
`lipo -archs` assertion, packaging with `README-binaries.txt`, checksums, release
notes with the real digest substituted at publish time, and `gh release create` with
the repository pinned. It reports every check as `PASS`, `FAIL` or `NOT CHECKED`,
and refuses to publish on anything but a clean run.

The non-negotiables:

- **Apple Silicon only** — build native `arm64` (M1–M6). Never `--arch x86_64`,
  never `ARCHS=arm64 x86_64`, and never `lipo -create`, which is how a universal
  binary gets made.
- **Assert it** — `lipo -archs <binary>` must report exactly `arm64`. A build that
  silently produced a fat binary is a release defect, not a build option.
- **Every release carries the artifacts.** A tag alone is not a release.
- **Identity is single-sourced and enforced** — never bump one declaration of the
  version or build number on its own; the build or CI must fail on a mismatch.
- **Dry run first**; publish only on an explicit flag.
- **Never fetch a model, dataset or dependency to make a gate pass.** A check that
  cannot run is reported *not checked*, and the release notes must name it.
