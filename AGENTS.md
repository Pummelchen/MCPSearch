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
contains no MCP code**, so it is testable without a transport. Released `1.3.0`
(2026-09-18) with prebuilt arm64 binaries and `SHA256SUMS`; there is no Node or
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
- `Tests/WebSearchCoreTests/` (585) and `Tests/MCPSMonitorTests/` (42) — fixtures
  are inline Swift literals, not a resource bundle.
- `VERSION` — the authoritative version at the repository root. See Identity.
- `tools/` — the release machinery: `sync-version.sh` (writes the mirrors from
  `VERSION`), `check-version.sh` (the version-agreement gate CI runs), and
  `release.sh` (the whole release, dry run by default).
- `scripts/` — the CI harnesses: `mcp_smoke.py`, `monitor_tty_smoke.py`,
  `dual_client_contract.py` (one stub, both executables, compared),
  `coverage_floor.py`, `soak.py`, `harness_tests.py`, `third_party_notices.py`,
  `searxng_stub.py` — the loopback instance the last two of those serve — and
  `searxng_health.py`, which asks a SearXNG whether its JSON API actually answers.
- `deploy/` — `install.sh` (the installer, and the single implementation of a SearXNG install),
  `provision-node.sh` (a thin native node provisioner that delegates to it), and a digest-pinned
  SearXNG compose file kept as the container alternative.
- `docs/` — an index, four research notes whose claims are labelled VERIFIED /
  UNVERIFIED / NOT FOUND, and the per-release `release-notes-vX.Y.Z.md`.

## Install

`deploy/install.sh` installs MCPSearch and **requires a working local SearXNG**, because every
vendor provider is optional and metered while SearXNG needs no account and no key. It installs
one when there is none — container if a Docker daemon answers, otherwise native under `launchd`
— then proves it answers a real query before proceeding, and verifies the server itself with a
real `web_search` at the end. Any failed gate exits non-zero.

```bash
deploy/install.sh --from-release    # install the published arm64 binary
deploy/install.sh --method native   # no container runtime
deploy/install.sh --verify-only     # change nothing, re-check
deploy/install.sh --dry-run         # print what would happen
deploy/install.sh --bind 0.0.0.0 --port 8888   # serve other machines (default is loopback)
```

`--bind` defaults to `127.0.0.1`, and an instance that is **already running is adopted as-is** —
`--bind`/`--port` are then reported as not applied rather than silently ignored, because the
running instance may be a container or another install. Stop it first to move it.

Two traps it exists to absorb, both hit for real: Docker Desktop's credential store needs the
login keychain, which a non-interactive session cannot unlock, so even a public image pull fails
with a credentials error — use `--method native` there; and `/healthz` answering 200 proves
nothing, because a SearXNG without `search.formats: [json]` answers it and returns 403 to the API
the server actually uses. The installer checks the JSON API, not the health endpoint.

## Build, test, run

```bash
swift build                     # release: swift build -c release
swift test                      # 627 tests, 7 skipped
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
  (stdio and `--http`), `scripts/monitor_tty_smoke.py` (pseudo-terminal) and
  `scripts/dual_client_contract.py`. The smoke test also **asserts the server reports
  the version in `VERSION`** — it used to print the reported version without checking
  it, so any version passed. The contract test is the one check that reads **both**
  executables at once: the server and the dashboard parse the same SearXNG response
  with two independent parsers, and each side's own tests pass while they disagree.
- A second `swift test` run with **placeholder credentials**, to prove the suite is
  hermetic.
- **Version mirrors agree with `VERSION`** — `bash tools/check-version.sh`.
- Static job: `swift-format lint --recursive --strict`, `swiftlint lint --strict`,
  `ruff check`/`format --check` on `scripts`, `pyright`, `shellcheck` (over
  `deploy/provision-node.sh`, `deploy/install.sh` **and `tools/*.sh`**),
  `gitleaks detect --log-opts=--all`,
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
- **Every provider is on by default**, including the ones needing no credential: the scrapers
  and Parallel. A provider with no credential reports `not_configured` and the rest still serve
  the query, so an unconfigured install searches rather than refusing. `SEARCH_ENABLE_SCRAPERS`
  and `SEARCH_ENABLE_PARALLEL` can still turn the credential-free ones off, which is how the
  stdio test harness keeps the suite offline: providers that need no key are a live network
  dependency, and scrubbing credentials alone stopped being enough.
- DuckDuckGo throttles to roughly one query per 10 s, and Startpage is usually unusable
  (Anubis proof-of-work) — enabled regardless, since trying costs one request.
- **DuckDuckGo can fail in two unrelated ways, and one of them looks like a TLS bug.**

  **(a) The DNS redirect.** This network's ISP redirects **UDP/53** to its own resolver, which
  answers `duckduckgo.com` with `rpz.biznet.` and an address that serves nothing; connecting
  there fails the *certificate* check, so it reads like a defect in this code. Queries to 1.1.1.1
  or 8.8.8.8 seem to agree only because they never arrive — `dig @1.1.1.1 CH TXT id.server`
  answers `noc-dev` (the ISP) over UDP but `cgk01` (Cloudflare, Jakarta) over TCP. TCP/53 and DoH
  return the real address, and this is **fixed at the tailnet level**: global nameservers of
  `https://cloudflare-dns.com/dns-query` plus Cloudflare (`1.1.1.1`) and Google (`8.8.8.8`), all
  with `useWithExitNode: true`, and `overrideLocalDNS: true`. Tailscale upgrades public global
  nameservers to DoH, which is what keeps the plain addresses clear of the redirect. Four things
  bit on the way; know them before touching tailnet DNS:
  - **`POST /dns/preferences` replaces the object.** Sending only `overrideLocalDNS` silently
    turned **MagicDNS off**. Always send `magicDNS` alongside it.
  - **`GET /dns/preferences` does not report `overrideLocalDNS`**, so a write that worked looks
    like it failed. Read back `/dns/configuration`, which reports the whole thing.
  - **`/dns/nameservers` takes flat strings and rejects `useWithExitNode`**; the combined
    `/dns/configuration` endpoint takes `{address, useWithExitNode}`. Without that flag, a device
    on an exit node ignores the tailnet nameserver entirely.
  - **macOS per-service DNS coexists with MagicDNS; it does not override it.** Setting the
    public resolvers on every network service leaves `100.100.100.100` as `scutil --dns`
    resolver #1, and DuckDuckGo keeps resolving, on all five machines. An earlier version of
    this note claimed per-service DNS beat MagicDNS — **that was a misattribution**. The machine
    that looked broken was on an exit node and its new DNS configuration had not been applied
    yet; clearing its per-service DNS coincided with the fix rather than causing it.

  **(b) The CAPTCHA is transient.** DuckDuckGo serves an interactive challenge — *"select all
  squares containing a duck"* as HTTP 202 — from time to time. A burst of probing produced it on
  every endpoint and both user agents; a single polite request afterwards returned 12 real
  results. Treat it as back-pressure to rate-limit around, never as proof the engine is dead, and
  do not probe hard to find out. Scrapers fail over, so a challenge costs a request, not a
  result.

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
