# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] — 2026-09-18

Security and correctness work from a pre-production audit of the whole tree. Most of it is not new
capability: it is behaviour that was documented but not implemented, checks that could not fail, and one
bypass in a guard that existed to stop a crash. Every finding, including the ones with no user-visible
effect, was processed into this release; the audit material itself has since been retired.

### Security

- **`web_open` now checks the address it actually connected to.** `URLSession` cannot be told to connect
  to the address the SSRF policy validated, so a name whose answer changed between the policy's lookup
  and the connection — DNS rebinding — could still land on a private address. The fetch now reads the
  address the connection used from the task metrics and refuses the body unless it was one the policy
  resolved for that host. This is **detection, not prevention**: the connection is still made, but the
  attacker does not receive the response.
- **The markup-nesting guard could be walked past.** It decremented a counter on every closing tag,
  under the comment *"a closing tag always returns to the parent, even if it never matched one"* — which
  is false for real HTML. `<div></p>` repeated nests 100 000 deep while the counter read 0 or 1, and that
  document did not finish parsing within ten minutes. The guard now tracks open element names on a stack,
  ignores a closing tag that matches nothing open, and models HTML's implied end tags. Measured against
  37 real pages, no page reads shallower than the tree the parser builds.
- **Credentials in a target URL were forwarded to the third-party reader.** The full URL, query and
  fragment included, went to `r.jina.ai` on the fallback path. They are stripped before the fallback.
- **The generated SearXNG secret was passed as a command-line argument**, where `ps` could read it. It
  now travels through a file with restrictive permissions.
- **The credential-leak scan ran only on the fully successful path** and only over stderr, so a failure
  that echoed a credential was never scanned. It runs on every path now.
- **A page title could close the untrusted-data fence.** Length-omitted results entered the fenced prompt
  unsanitised. Fence markers are neutralised in every result, omitted length included.
- An unauthenticated client could grow the HTTP session registry without limit; it is bounded now.
- A rejected URL-valued setting was echoed verbatim into a diagnostic that is logged.

### Fixed

- **`web_search` through SearXNG discarded every result.** The JSON API answers with `[String]` and the
  decoder expected objects, so an instance that answered correctly produced nothing.
- **`GET /health` returned a hardcoded `ok`** and was wired to nothing. It reports real readiness, and
  the check that consumes it reads the body rather than the status code.
- **The installer could drop every API key.** A `|| true` swallowed a `grep` error, and the truncated
  staging file then replaced `config.env`.
- **Cancellation was mapped to a provider failure**, so a caller who cancelled was charged to the
  provider's circuit breaker, and a cancelled fetch could return a stale success.
- **The charset was discarded**, so a page declaring anything other than UTF-8 was decoded as Latin-1.
- A `+` in a query was dropped while building the URL, corrupting the search.
- An empty extraction was returned as a success, discarding the real failure reason.
- Bot-challenge markers were substring-matched against the whole page, so ordinary pages were discarded
  as challenges.
- Mojeek's include and exclude domains were space-joined where it documents commas, so the filters never
  applied.
- Installing overwrote the previous binary in place with no rollback; `--bind` was silently dropped by
  the container method; a repeated provider in `SEARCH_PROVIDER_ORDER` was not deduplicated.
- A half-open circuit-breaker probe was never released when the local rate limiter denied, wedging the
  breaker; a failed handshake left `sessionID` set so initialization never retried.

### Changed

- **`-warnings-as-errors` is in the build config**, SwiftLint rejects force-unwraps, and Ruff selects
  `S101` — the language-standard proof the release process claimed was not actually in force.
- **The secret scan is two-pass.** `gitleaks` was blind to the credential pattern this repository
  actually uses, and one config cannot carry both the defaults and custom rules in this version.
- The gates that could not fail now can: the mandatory-SearXNG proof rejects an instance returning zero
  results, the end-to-end gate no longer accepts a JSON-RPC error as success, and the test-suite count is
  no longer reported as `PASS` without parsing it.
- Test and soak harnesses no longer deadlock on an undrained pipe, hang on an unanswered query, leak PTY
  descriptors, or kill the run with `SIGPIPE`.

## [1.2.0] — 2026-09-17

Feature release. **Every provider is on by default**, and installing with a verified local SearXNG
is now one command. Upgrading needs no configuration change, but the defaults did change: the
credential-free routes — DuckDuckGo, Startpage and Parallel — were opt-in and now take part in every
search, so a host with no API keys returns results instead of failing with "no provider configured".
Full notes: [`docs/release-notes-v1.2.0.md`](docs/release-notes-v1.2.0.md).

### Added

- **`deploy/install.sh`** — installs MCPSearch and treats a working **local SearXNG as mandatory**. It
  adopts a running instance, installs one when there is none (the digest-pinned container if a Docker
  daemon answers, otherwise native under `launchd`), proves it answers a real query through the JSON
  API, then installs the binary, writes `config.env` and verifies a real `web_search`. Any failed gate
  exits non-zero. Options: `--method`, `--port`, `--bind`, `--from-release`, `--verify-only`,
  `--dry-run`, `--searxng-only`.
- **`deploy/provision-node.sh` provisions a cluster node natively.** It is thin by design — sudo,
  Homebrew, `git`, a Python the native build accepts, then `install.sh --method native
  --searxng-only` — so the install has one implementation and provisioning cannot drift from what is
  deployed.
- **`--searxng-only`** for the installer, so a node needs neither a Swift toolchain nor a published
  release while still passing the mandatory-SearXNG gate.
- **`--bind`** for the installer, so an instance can serve the tailnet without being exposed by
  accident; the default remains loopback.

### Changed

- **Every provider is enabled by default**, including the ones that need no credential. A provider
  without a credential reports `not_configured` and the others still serve the query.
  `SEARCH_ENABLE_SCRAPERS` and `SEARCH_ENABLE_PARALLEL` remain, as off switches.
- **Cluster SearXNG runs natively under `launchd`** rather than in a Colima container. Same listener,
  no VM in the path, and no login-keychain dependency at install time.
- **The installer no longer overwrites `config.env`.** It owns `SEARXNG_BASE_URL` and preserves
  everything else, seeding from the repository's own `config.env` on a first install, so an operator's
  keys survive a re-run.
- **The monitor derives its node list from the host.** The local machine was listed twice — a loopback
  entry *and* its own Tailscale entry — so four machines reported as five.
- The failure reason for a certificate-trust error now names network interception, because a DNS
  block page presenting a foreign certificate reads like a TLS defect in this code.

### Fixed

- **`scripts/mcp_smoke.py` asserted a state that no longer existed.** With every provider on by
  default, its "no provider configured" check searched successfully and failed; the credential-free
  providers are now switched off explicitly for that check, mirroring the Swift harness.
- **`grep -q` under `set -o pipefail` reported a match as a failure.** `grep` exits at the first match,
  SIGPIPEs the producer, and the pipeline returns 141 — so "is the job loaded" said no while it was
  loaded, and two release-note assertions inverted the same way.
- **`tools/release.sh`'s shellcheck gate could not fail.** Its `for` loop reported the status of its
  last iteration, so a defect in an earlier file was masked; it also linted one file where CI lints
  three.
- **The monitor reported one machine's failing engine as a fleet-level problem**, because the
  duplicate node doubled it past the threshold.
- **The installer demanded install-sized disk headroom for `--verify-only`**, which builds nothing.
- The monitor's default-node test pinned the duplicate as intended, and the default-node list had no
  coverage of the local-machine rule.

### Security

- **A test fixture held the first 47 characters of a live Tavily key** in a public repository. It is
  replaced with synthetic material and `LiveProviderTests` now rejects placeholder keys. The value
  remains in history: **rotate that key.**

## [1.0.1] — 2026-09-16

Maintenance release. **The server, fetch and answer code is unchanged from 1.0.0** — the only
tracked changes are the release machinery, the identity handling and documentation. The binaries are
rebuilt, so the version they report is the one they were built from. Upgrading needs no configuration
change. Full notes: [`docs/release-notes-v1.0.1.md`](docs/release-notes-v1.0.1.md).

### Added

- **`tools/release.sh`** — walks `RELEASE.md`: preconditions, gates, a clean scratch `arm64`-only
  build with the log scanned for warnings, the `lipo -archs` assertion, packaging, checksums and
  release notes with the real digest substituted at publish time. Dry run by default; publishes only
  with `--publish`.
- **`tools/check-version.sh`** — the version-agreement gate, run in CI. Fails when `VERSION` is
  malformed, when the generated Swift mirror disagrees with it, when `CHANGELOG.md` has no heading
  for the version, or when a version literal appears elsewhere in `Sources/`.
- **`VERSION`** at the repository root — the single authoritative identity.
- **`AGENTS.md`** (with the committed `CLAUDE.md` bridge) and **`RELEASE.md`** — the repository's own
  orientation and the release standard.

### Changed

- **The version is single-sourced.** `VERSION` is authoritative and
  `Sources/WebSearchCore/Support/BuildVersion.swift` is generated from it by `tools/sync-version.sh`;
  `MCPServer.swift` and the Parallel provider's `clientInfo` both read it, so a bump can no longer
  half-happen and ship a server that misreports its own version over MCP.
- **The default `SEARCH_USER_AGENT` carries the real version.** It was the literal
  `SwiftWebSearchMCP/1.0`, which already disagreed with the reported version; it is now
  `SwiftWebSearchMCP/1.0.1`.
- `initialize` returns `serverInfo.version` from the single source, and `scripts/mcp_smoke.py`
  asserts the built binary reports it — it used to print the reported version without checking it,
  so any version would have passed.

### Fixed

- A version literal could be added to `Sources/` without anything noticing; `tools/check-version.sh`
  now fails on any version literal outside the generated mirror.

## [1.0.0] — 2026-09-15

First release. A Swift-native MCP server that gives an AI client real public-web search and page
fetching, with no mandatory paid infrastructure: every credential is optional and the server starts
and explains what is missing.

Verified before release: **590 tests, 6 skipped, 0 failures**, `Sources/` line coverage **91.6 %**
against an 80 % floor, zero compiler warnings in debug and release under `-warnings-as-errors` on
Swift 6.4 / Xcode 27, and the full gate set (formatter, linter, type checker, SAST, secret scan over
full history, dependency CVE scan) clean. Prebuilt binaries are smoke-tested over a real stdio
handshake before publication.

**Architecture:** Apple silicon only (`arm64`, M1 and later). There is no Intel slice — the project
is built and verified on the `xcode-27` runner image, which is arm64-only.

### Added

- **Four MCP tools** — `web_search` (ranked, deduplicated, source-attributed results), `web_open`
  (one public URL as readable text), `web_answer` (prose answered *only* from results the search
  actually fetched, with citations) and `web_search_status` (per-provider diagnostics).
- **Nine search adapters, all optional** — Tavily, Brave, Mojeek, Exa, self-hosted SearXNG, Open Web
  Search, DuckDuckGo and Startpage (opt-in HTML scrapers) and Parallel Search MCP. Jina Reader is
  used for page extraction only, never as a search provider.
- **Both MCP transports** — stdio (default) and Streamable HTTP, for the remote connectors that
  cannot launch a subprocess.
- **`mcps-mon`**, a live terminal dashboard for provider health, node health and latency.
- **Rank fusion instead of score comparison** — weighted Reciprocal Rank Fusion over canonical URLs,
  with per-domain diversity and corroboration, because vendor relevance scores are not comparable.
- **Grounded answer synthesis**, opt-in via `DEEPSEEK_API_KEY`: the answering model has no web access
  of its own, so it cannot cite a document the search did not retrieve. If synthesis fails, the
  search results are still returned.
- **Self-hosting** — a digest-pinned SearXNG compose file and a provisioning script for a headless
  Apple-silicon node, with a per-node generated secret key and a canary check before replacing a
  running instance.
- **Prebuilt macOS binaries for Apple silicon** (M1 and later) attached to each release, with
  `SHA256SUMS`.
- **Documentation** — a wiki covering installation, compatibility, tools, architecture, providers,
  configuration, reliability, security, self-hosting, the monitor and troubleshooting, plus `docs/`
  research notes in which every claim is labelled verified or unverified.

### Security

- **SSRF boundary for `web_open`** in three layers — lexical validation, DNS resolution validation
  of every returned address, and re-validation on **every** redirect hop. IP literals are parsed
  strictly, and IPv6 forms that embed an IPv4 address (IPv4-mapped, IPv4-compatible, NAT64, 6to4 and
  Teredo) are unwrapped and classified rather than trusted.
- **A URL, and therefore a credential in a query string, can no longer reach a diagnostic.** Provider
  failure text is curated rather than taken from platform descriptions.
- **Retrieved text and provider answers are delimited** before they enter the synthesis prompt, so
  fetched content cannot be read as an instruction.
- **The redirect loop — the whole SSRF boundary for redirects — now has tests**, including the
  cross-scheme refusals.
- Accepted and documented, not silently ignored: the DNS-rebinding window is one TTL wide, the HTTP
  transport has **no built-in authentication or TLS by design** (loopback is the default bind and a
  TLS-terminating reverse proxy is the supported exposed deployment), and JavaScript is not executed.

### Fixed

- **A deeply nested page could kill the server process from a single `web_open` call.** HTML parsing
  now refuses a body with no markup at all on the scraper path, bounds element nesting at 512 levels
  counted iteratively on the raw bytes, and parses on a dedicated 8 MiB-stack thread.
- **Response bodies were fully buffered before the byte cap applied**, so one hostile or endless page
  could exhaust memory; the cap is now enforced during the transfer.
- **A caller's cancellation was swallowed** on the search, fetch and synthesis paths. It now
  propagates, so a cancelled tool call says so instead of blaming a provider or reporting a
  synthesis failure.
- **Untrusted seconds were converted `Double` → `Int` without a range check**, so `Retry-After: 1e30`
  or `mcps-mon --interval inf` could trap the process.
- **A half-open circuit breaker authorised an unbounded number of requests**, because the probe
  refusal was discarded outside the open branch.
- **Ctrl-C, `SIGINT` and `SIGTERM` left the dashboard's terminal in raw mode with the cursor hidden.**
- **`web_open` blamed a search provider for a fetch failure**, and the Jina Reader fallback hid the
  third-party disclosure.
- **A locally throttled provider was reported to the caller as a bad request** rather than as a
  retryable local condition, and upstream throttles were reported as "nothing was attempted".
- **The compose file's `SEARXNG_SECRET_KEY` override named a variable SearXNG never reads**, so a
  publicly tracked placeholder signed sessions.
- **The HTTP transport served exactly one MCP session per process and could never release it**; each
  `initialize` now gets its own session and `DELETE` releases it.
- **Removing a running SearXNG instance before its replacement was proven**, which could leave a node
  serving nothing; the swap is now reversible with rollback at every fallible step.
- **A request head declaring a large body allocated the buffer before the body arrived** (64 MiB at
  the connection bound).
- **Rank fusion applied a resale discount per response instead of per result**, discounting results
  from indexes nobody else had; a resold page is now attributed to the index it came from.
- **Provider limits were installed after the pipeline was returned**, so an early request could
  bypass the breaker and rate limiter.
- **The mode deadline could open circuit breakers**, treating a budget timeout as a provider failure.
- **Configuration was validated before the command line was parsed**, so a mistyped config value made
  `--help` exit 2 with no usage.
- **Tool schemas drifted apart**: `web_answer` had lost the `provider` enum `web_search` declares,
  the nullable enums excluded the `null` their own type admits, and the zero-argument status tool was
  the only object schema without `required`.
- Two defects the new tests found in the monitor: the node probe read `unresponsiveEngines` while
  SearXNG emits `unresponsive_engines`, and a redirected frame was padded to an assumed screen size.
- **Placeholder credentials no longer activate the live test suite**, so a plain `swift test` cannot
  spend provider credits.

### Changed

- **Swift 6.4 / Xcode 27**, strict concurrency (Swift 6 language mode) in every target, and
  `-warnings-as-errors`; the build has zero warnings.
- **Every provider contributes to fusion with weight 1.0.** Wider weights degenerate into provider
  preference — a score of `weight / (k + rank)` lets one provider's whole list outrank another's.
- **`SEARCH_CONNECT_TIMEOUT_MS` was removed rather than implemented**: the transport exposes no
  connect-only deadline, and a knob nothing reads is worse than no knob.
- **Jina is no longer selectable as a search provider** — the adapter and its provider id were
  deleted, because it could never be selected. `JINA_API_KEY` only raises the extractor's rate limit.
- **`mcps-mon` exits non-zero when the whole fleet is down**, so it can be used as a health check;
  `--exit-zero` restores the old behaviour.
- **`mcps-mon` probes providers once on the first frame and thereafter only on demand**, so an
  unattended dashboard cannot spend recurring credits.
- **Tool output carries a human-readable text block alongside `structuredContent`**, because OpenAI's
  MCP client exposes only a string.
- **CI runs on the `xcode-27` image with 18 gates**, including a coverage floor, `swift-format`,
  SwiftLint, `ruff`, `pyright` (strict), `shellcheck`, `semgrep`, a full-history `gitleaks` scan and
  `osv-scanner`. CodeQL runs in advanced setup on the same image with a manual build, so the analysis
  is of the toolchain the project actually uses.
- Dependency graph pinned exactly, with Apache-2.0 attribution notices carried in
  `THIRD-PARTY-NOTICES.md` and checked against the lockfile in CI.

### Known limitations

- No vendor MCP client round trip has been run; client compatibility is bounded to the documented
  strict-mode schema rules, the schema lint and the protocol tests. The transport, session, SSE,
  origin and body-limit behaviour is verified against a real socket.
- Live provider coverage is Tavily-only, behind `SEARCH_LIVE_TESTS=1`; every other adapter is
  verified against fixtures and published API notes.
- HTML scrapers depend on markup that is not a contract; Startpage is currently unusable because the
  site serves an Anubis proof-of-work challenge.
- Google Custom Search JSON and Bing Search are deliberately unsupported (closed to new customers and
  retired respectively).

[1.3.0]: https://github.com/Pummelchen/MCPSearch/releases/tag/v1.3.0
[1.2.0]: https://github.com/Pummelchen/MCPSearch/releases/tag/v1.2.0
[1.0.1]: https://github.com/Pummelchen/MCPSearch/releases/tag/v1.0.1
[1.0.0]: https://github.com/Pummelchen/MCPSearch/releases/tag/v1.0.0
