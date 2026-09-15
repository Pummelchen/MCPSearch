# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-09-15

First release. A Swift-native MCP server that gives an AI client real public-web search and page
fetching, with no mandatory paid infrastructure: every credential is optional and the server starts
and explains what is missing.

Verified before release: **590 tests, 6 skipped, 0 failures**, `Sources/` line coverage **91.6 %**
against an 80 % floor, zero compiler warnings in debug and release under `-warnings-as-errors` on
Swift 6.4 / Xcode 27, and the full gate set (formatter, linter, type checker, SAST, secret scan over
full history, dependency CVE scan) clean. Prebuilt binaries are smoke-tested over a real stdio
handshake on both architectures. See `AUDIT/` for the pre-production audit this release comes from.

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
- **Prebuilt universal macOS binaries** (Apple Silicon and Intel) attached to each release, with
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

[1.0.0]: https://github.com/Pummelchen/MCPSearch/releases/tag/v1.0.0
