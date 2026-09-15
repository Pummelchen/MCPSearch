# L3 (line-level) + zero-tolerance placeholder sweep — findings

## Scope note

Repository `MCPSearch`, branch `audit/2026-09-13`. Audited revision: working tree at
**`92a0ae1`** (`audit(A01): raise to S0 …`), which is *not* the revision named in the
brief — `HEAD` advanced from `e72cadc` to `92a0ae1` while this pass was running, and two
working-tree files changed under it. Recorded so the result is attributable:

* `HEAD` moved `e72cadc → 92a0ae1`, which committed `Tests/WebSearchCoreTests/AUDITDiagnosticsTests.swift`
  (5 test functions).
* The **working tree** changed again during the pass: the in-flight A01 fix added
  `Sources/WebSearchCore/Fetch/MarkupDepth.swift` (untracked), wired it into
  `HTMLExtractor.extract` and `ScraperSupport.parse`, added `SearchError.markupDepthExceeded`,
  deleted `AUDITDiagnosticsTests.swift`, and added `Tests/WebSearchCoreTests/MarkupDepthTests.swift`.
  Findings below were established against the **committed** revision `92a0ae1`; where the
  in-flight fix has since addressed one, the finding says so. For that committed revision the
  A01 depth guard is absent, and `PLACEHOLDER-1`'s file is still present.
* `MarkupDepth.swift` itself is owned by the concurrent A01 task and is **not** audited here.
* Everything else reviewed is the committed tree.

Read in full: all of `Sources/WebSearchCore/**`, `Sources/SwiftWebSearchMCP/**`,
`Sources/MCPSMonitor/main.swift`, all four `scripts/*.py`, `deploy/**`,
`.github/workflows/ci.yml`, `Package.swift`, `example.env`, and all `Tests/**` (to separate
test fixtures from production paths). `grep -rn` across the tree was the main instrument;
every flagged region was read in full and `git blame`/`git log` consulted.

**Production vs fixture.** No test fixture is on a production path (production targets
depend only on `SwiftSoup`/`MCP`/`swift-nio`; no `Sources/**` file can reach `Tests/**`).
Test-only doubles (`MockHTTPClient`, `MockSearchProvider`, `StubDNSResolver`,
`LoopbackServer`, `RawHTTP`, `TestClock`, the `let stub = try LoopbackServer(…)` variables,
canned JSON bodies, fake keys, `.invalid`/`example.com` hosts) are **not** findings. The
`LiveProviderTests` live-network path is correctly gated behind `SEARCH_LIVE_TESTS` **and**
a usable-key check.

## Severity count (proposed)

| Severity | Count |
| --- | --- |
| S0 | 1 |
| S1 | 2 |
| S2 | 10 |
| S3 | 32 |
| **Total** | **45** |

## Placeholder / marker sweep (auditable)

Exact commands and raw results, over `Sources Tests scripts deploy .github` (the `AUDIT/`
directory is the audit's own output and is excluded):

| Command | Result |
| --- | --- |
| `grep -rniE '\bTODO\b'` | 0 |
| `grep -rniE '\bFIXME\b'` | 0 |
| `grep -rniE '\bHACK\b'` | 0 |
| `grep -rniE '\bXXX\b'` | 0 |
| `grep -rniE '\bWIP\b'` | 0 |
| `grep -rniE '\bSTUB\b'` | **45** — all uses of the noun "stub" for loopback stand-ins / doc prose, 0 of them a stub body |
| `grep -rniE 'notimplemented\|unimplemented\|fatalerror\|preconditionfailure\|\babort\(\)'` | 0 |
| `grep -rniE '\b(dummy\|sample\|lorem\|foo-?bar)\b' Sources scripts deploy` | 0 |
| `grep -rniE 'placeholder' Sources scripts deploy` | 3 — all doc comments in `deploy/` |
| `grep -rnE '^\s*pass\s*$' scripts` | 2 — both legitimate `except: pass` cleanup (`soak.py:195`, `monitor_tty_smoke.py:254`) |
| `grep -rnE '\bexit\(\|_exit\(\)' Sources` | 6 — all real process exits in `main.swift` (`--help`, bad args, fatal start), no stub |
| `grep -rnE '^\s*//.*func test' Tests` | 0 commented-out tests |
| `grep -rnE 'XCTAssertTrue\(true\)\|XCTAssertFalse\(false\)' Tests` | 0 |

**Marker hits: 48 raw token matches for the literal markers; 0 literal
TODO/FIXME/HACK/XXX/WIP/STUB placeholder bodies.** Three concept-level placeholder
findings were still found on paths that run in production (below): temporary audit tooling
committed into the test target (`PLACEHOLDER-1`), an unchecked secret substitution that can
leave the tracked `__SECRET_KEY__` placeholder live in a provisioned instance
(`PLACEHOLDER-2`), and a compose secret-key override that names the wrong variable so the
tracked `change-me-local-only-not-a-credential` placeholder is what signs the instance
(`PLACEHOLDER-3`).

---

## Findings, ordered by severity

#### PLACEHOLDER-3 — The documented compose secret-key override is the wrong variable, so the tracked placeholder is what signs the instance
- severity: S0 (placeholder on the documented production deploy path; blast radius bounded — loopback-only, no accounts, limiter off)
- unit: `deploy/docker-compose.yml` (with `deploy/searxng/settings.yml`)
- file:line: `deploy/docker-compose.yml:30` (placeholder at `deploy/searxng/settings.yml:22`)
- category: placeholder
- evidence: The compose file documents `- SEARXNG_SECRET_KEY=${SEARXNG_SECRET_KEY:-change-me-local-only-not-a-credential}` under the comment "Overrides the placeholder in the mounted settings.yml. SearXNG maps SEARXNG_* variables onto its settings…". SearXNG does not read that name: in upstream `searx/settings_defaults.py`, `server.secret_key` is declared `SettingsValue(str, environ_name='SEARXNG_SECRET')` (verified against upstream master; there is no `SEARXNG_SECRET_KEY` anywhere upstream). Because `deploy/searxng/settings.yml:22` already sets `secret_key: "change-me-local-only-not-a-credential"`, the image's create/randomise path never runs, so exporting the documented variable changes nothing and the tracked literal key is the one in force. `git blame` shows the line was added deliberately in `7e0a3eb`, repeating the false claim. This is also the concrete instance of ledger A12 (env-var contracts between units are unchecked).
- expected-correct: Use the variable SearXNG actually reads (`SEARXNG_SECRET`), and fail closed when it is unset (e.g. `${SEARXNG_SECRET:?set a real key}`), or generate a per-instance key as `deploy/provision-node.sh:190-199` already does; delete the tracked placeholder from the mounted settings so it cannot silently take effect.
- reproducible-by: `grep -n SEARXNG_SECRET_KEY deploy/docker-compose.yml`; upstream `settings_defaults.py` maps `server.secret_key` to `SEARXNG_SECRET`; `docker compose -f deploy/docker-compose.yml config` shows the override is only ever the placeholder unless that (unread) name is set.
- confidence: certain

#### PLACEHOLDER-1 — TEMPORARY audit tooling is committed to the go-live test target and can abort the whole suite
- severity: S1
- unit: `Tests/WebSearchCoreTests/AUDITDiagnosticsTests.swift`
- file:line: `Tests/WebSearchCoreTests/AUDITDiagnosticsTests.swift:6` (also `:11`, `:83`, `:111`)
- category: placeholder
- evidence: The file's own header says `/// TEMPORARY audit diagnostic — not part of the product suite.` and `/// ... Deleted before the audit branch merges.`, yet it is committed at `HEAD 92a0ae1`. `testD_deepNestingThresholdWithoutASan` loops `for depth in [1_000, 5_000, 20_000, 100_000, 300_000]` and `testE_deepNestingThroughHTMLExtraction` loops `[20_000, 100_000, 300_000]`, feeding 300 000 nested `<div>` into `SwiftSoup.parse` with no depth bound on the path (`HTMLExtractor.swift:84`, `ScraperSupport.swift:100`). `AUDIT/ledger.md` A01 records that a non-sanitized run "DIES at depth 5000 with signal 10 (SIGBUS)"; CI runs the unfiltered suite (`ci.yml:93`, `ci.yml:127` are both `run: swift test`), so this file alone can kill the run and invalidate every other result. Its four non-crashing probes (`testA`, `testC`, and the two loops) contain no assertion primitive at all — `testC` is `_ = try? await provider.search(…)`, which discards both value and error — so they pass whether the code is right or wrong. **Working-tree status at 09:41:** the in-flight A01 fix has deleted this file and wired the depth guard; verify the deletion is committed so CI can go green.
- expected-correct: Delete the file before the branch merges (its stated plan), or move it behind an explicit opt-in so the default/CI suite cannot execute it; carry A01's regression as a real assertion-bearing test once `MarkupDepth` is wired (the untracked `MarkupDepthTests.swift` is that step).
- reproducible-by: `grep -n 'func test' Tests/WebSearchCoreTests/AUDITDiagnosticsTests.swift; grep -rn 'MarkupDepth' Sources/; sed -n '88,127p' .github/workflows/ci.yml`
- confidence: certain

#### L3-25 — The HTTP transport serves exactly one MCP session per process, and that session can never be released
- severity: S1 (S0 for any multi-client HTTP deployment; stdio default is unaffected)
- unit: `SwiftWebSearchMCP` (HTTP transport wiring)
- file:line: `Sources/SwiftWebSearchMCP/main.swift:118` (one transport per process), `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:290` (non-POST refused before the transport)
- category: bug
- evidence: `main.swift` builds a single `StatefulHTTPServerTransport` at startup and hands it to `HTTPMCPHost`; that SDK type is one-shot. In the pinned MCP SDK 0.12.1, `StatefulHTTPServerTransport.handleInitializationRequest` rejects re-initialization — `if sessionID != nil { … .invalidRequest("Bad Request: Session already initialized") }` — and `handleRequest` returns `404 "Not Found: Session has been terminated"` for every request once `terminate()` has set `terminated = true`, while `terminate()` never clears `sessionID`. So a second or reconnecting HTTP client can never initialize, for the whole lifetime of the process. `HTTPMCPHost.dispatch` makes it worse by refusing GET and DELETE before the transport (`guard method == .POST else { … ("Allow", "POST") }`), so the SDK's DELETE termination path is unreachable and the dead session cannot even be released; the comment there ("Only POST is meaningful to the stateless transport") is also factually wrong, because the wired transport is `StatefulHTTPServerTransport`. `Tests/WebSearchCoreTests/HTTPTransportTests.swift:459-474` currently asserts the 405/`Allow: POST` behaviour, so a fix must update that test too.
- expected-correct: Create a `StatefulHTTPServerTransport` **per session** (keyed by the `Mcp-Session-Id` the SDK issues) and route POST/GET/DELETE to the owning transport, as the SDK's per-session design expects; or explicitly scope the product to one client per process and document that a restart is required. Note that merely forwarding DELETE is *not* sufficient: the SDK's `terminate()` kills the whole transport (all later requests 404), not just the session.
- reproducible-by: start `SwiftWebSearchMCP --transport http --port 18099`, POST `initialize` (200 + `Mcp-Session-Id`), POST a second `initialize` → `400 Session already initialized`; DELETE with the issued session id → `405` because the host never forwards it.
- confidence: certain

#### PLACEHOLDER-2 — Unchecked `sed` can leave the tracked `__SECRET_KEY__` placeholder signing a provisioned SearXNG instance
- severity: S2
- unit: `deploy/provision-node.sh`
- file:line: `deploy/provision-node.sh:235` (template at `:216`)
- category: placeholder
- evidence: The script writes `secret_key: "__SECRET_KEY__"` into `settings.yml` (`:216`) and then substitutes it with `sed -i '' "s|__SECRET_KEY__|${SECRET_KEY}|" "${INSTALL_DIR}/searxng/settings.yml"` (`:235`). Unlike every other mutating step in the file (which carry `|| fail`), this one has **no return-value check and no `||` guard**, and the script runs under `set -uo pipefail` (no `-e`, `:10`). If `sed` fails, the container starts normally with the literal, tracked, publicly-known key — the very outcome the comment at `:190` ("the tracked placeholder is never the key") promises cannot happen — and the canary still answers JSON, so the script reports `READY`.
- expected-correct: Check the substitution and fail loudly, e.g. `sed -i '' … || fail "could not install the SearXNG secret key"`, and assert the placeholder no longer appears in the rendered file before starting the container.
- reproducible-by: `grep -n 'SECRET_KEY\|sed -i' deploy/provision-node.sh`; (non-destructive) copy the script's settings heredoc to a temp dir, `chmod 000` the file, run the `sed`, and observe no failure path.
- confidence: certain

#### L3-1 — Budget expiry double-counts a provider that already failed
- severity: S2
- unit: `WebSearchCore/Search/SearchOrchestrator.swift`
- file:line: `Sources/WebSearchCore/Search/SearchOrchestrator.swift:384` (defect), call site `:361-368`
- category: bug
- evidence: The caller correctly computes the set of providers that already reported from **responses ∪ failures**: `let reported = Set(aggregate.responses.map(\.provider)).union(aggregate.failures.map(\.provider))` (`:361-362`). `recordBudgetExceeded` then re-derives it from responses only: `let answeredIDs = Set(answered.responses.map(\.provider))` (`:384`) and `for id in ids where !answeredIDs.contains(id)` (`:385`). A provider that failed fast (e.g. HTTP 500) and is already in `aggregate.failures` is therefore charged a **second**, synthetic `.timeout` failure, and `health.recordDeadlineExceeded` (`:395`) increments its failure counter again — so `providersFailed` can list one provider twice and the status tool over-reports failures.
- expected-correct: Use the same union the caller computes (`answered.responses ∪ answered.failures`) so a provider that already reported is never charged a budget timeout.
- reproducible-by: A `SearchOrchestratorTests` case with provider A failing immediately and provider B hanging past a short `fastTimeout`, then assert `response.providersFailed.filter { $0.provider == .a }.count == 1` and that A has no `.timeout` entry.
- confidence: certain

#### L3-2 — Jina Reader fallback percent-encodes the target URL's query and fragment
- severity: S2
- unit: `WebSearchCore/Fetch/JinaReaderFetcher.swift`
- file:line: `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:43`
- category: bug
- evidence: `let target = baseURL.appendingPathComponent(request.url.absoluteString)` treats an entire absolute URL as one *path component*. Foundation escapes characters that are illegal in a path segment, so `https://example.com/search?q=swift` is sent as `https://r.jina.ai/https://example.com/search%3Fq=swift` (and `#frag` as `%23frag`). Jina Reader takes the target from the path, so any `web_open` fallback for a URL carrying a query string — the common case — requests the wrong resource (or a `%3F`-literal one). The comment above it ("the target URL is appended directly") is not what the code does, and the tests only ever use `https://example.com/page` (no query) so the defect is uncovered.
- expected-correct: Preserve the target verbatim, e.g. build the reader URL from a string (`URL(string: baseURL.absoluteString + request.url.absoluteString)`) or percent-encode only what must be encoded while leaving `?`, `#` and `/` intact.
- reproducible-by: In `FetchFallbackTests`, fetch through the reader with `URL(string: "https://example.com/search?q=swift")!` and assert the recorded `request.url.absoluteString` contains `?q=swift` (it does not today).
- confidence: likely

#### L3-3 — `mcps-mon --interval` traps on an infinite or huge value
- severity: S2
- unit: `MCPSMonitor`
- file:line: `Sources/MCPSMonitor/main.swift:171` (guard at `:166`)
- category: bug
- evidence: `guard let seconds = Double(raw), seconds >= 1` accepts `inf` and any huge finite value; the very next line is `options.interval = Duration.milliseconds(Int(seconds * 1000))`. `Int(Double.infinity)` and out-of-range `Double→Int` conversions **trap**, so `mcps-mon --interval inf` (or `--interval 1e30`) kills the process with a runtime trap instead of an `OptionError`. `MonitorOptionsTests` covers `"0"` and `"abc"` but not `inf`/overflow.
- expected-correct: Bound the accepted value and/or use the checked conversion, throwing `OptionError.invalidValue(flag: "--interval", …)` when the value cannot be represented, as `--port` already does via `Int(raw)`.
- reproducible-by: `swift run mcps-mon --interval inf` (or add the case to `MonitorOptionsTests.testInvalidValuesAreRejected` and assert it throws rather than traps).
- confidence: certain

#### L3-4 — `web_open` security-rejection test is weakened to "some refusal happened"
- severity: S2
- unit: `Tests/WebSearchCoreTests/StdioServerTests.swift`
- file:line: `Tests/WebSearchCoreTests/StdioServerTests.swift:716`
- category: test
- evidence: `XCTAssertTrue(text.contains(testCase.expected) || text.contains("Refused"), …)`. Every blocked-URL error contains `Refused` (`Sources/SwiftWebSearchMCP/ToolHandlers.swift:385`), so the row `(14, "javascript:alert(1)", "valid absolute URL")` passes on any policy refusal. If `javascript:` regressed into the `blockedURL` arm instead of the intended invalid-URL arm (`ToolHandlers.swift:131`), the suite stays green; the `||` disjunct makes the entire `expected` column unenforceable.
- expected-correct: Assert the specific expectation per row (drop the `|| text.contains("Refused")` fallback), since the two error classes carry different operator actions.
- reproducible-by: `sed -n '692,721p' Tests/WebSearchCoreTests/StdioServerTests.swift`
- confidence: certain

#### L3-5 — The test named `testProvidersReceiveALargerBudgetThanTheFinalResultLimit` never inspects the budget
- severity: S2
- unit: `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift`
- file:line: `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:674`
- category: test
- evidence: The closure receives `request` but never reads it, returning one fixed result; the body ends with `// Verified indirectly: the call succeeds and the provider was invoked once.` / `XCTAssertEqual(capturing.callCount, 1)`. `providerResultBudget` (`SearchRequest.swift:111`) is the entire contract under test, so passing `maxResults` (3) instead of the surplus budget (6) would not fail anything.
- expected-correct: Record the request in the mock and assert `request.providerResultBudget == 6` (or `> maxResults`).
- reproducible-by: `sed -n '674,694p' Tests/WebSearchCoreTests/SearchOrchestratorTests.swift`
- confidence: certain

#### L3-6 — Port race in the HTTP-transport harness, whose comment claims collision-freedom
- severity: S2
- unit: `Tests/WebSearchCoreTests/HTTPTransportTests.swift`
- file:line: `Tests/WebSearchCoreTests/HTTPTransportTests.swift:183` (release at `:188`, use at `:215`)
- category: test
- evidence: `freeLoopbackPort()` binds a probe socket to port 0, reads the port with `getsockname`, then closes it via `defer { close(fd) }` and returns the number; `startServer()` later hands it to the child process. Between `close()` and the child's `bind()` the port is unowned and can be taken by any other binder, yet the doc comment asserts `/// Ask the kernel for an unused loopback port, so two concurrent runs cannot collide`. The failure surfaces as a bind error or as the test talking to a foreign listener.
- expected-correct: Let the server bind port 0 and report its bound port (the host already logs `channel?.localAddress?.port`), or hold the probe socket open until the child has bound and retry on bind failure; at minimum correct the comment.
- reproducible-by: `sed -n '181,252p' Tests/WebSearchCoreTests/HTTPTransportTests.swift`; run two copies of the HTTP transport test class concurrently.
- confidence: likely

#### L3-26 — The HTTP Host allow-list is hard-coded to loopback, so the documented `--host`/proxy deployment gets 421
- severity: S2
- unit: `SwiftWebSearchMCP` (HTTP transport wiring)
- file:line: `Sources/SwiftWebSearchMCP/main.swift:120`
- category: bug
- evidence: `OriginValidator.localhost(port: httpConfiguration.port)` builds an exact allow-list of `127.0.0.1:<port>`, `localhost:<port>` and `[::1]:<port>` and validates the **Host** header against it, returning `421 Misdirected Request` otherwise (pinned MCP SDK 0.12.1, `HTTPRequestValidation.swift:268-301`). The bind address is not consulted, yet `HTTPMCPHost` supports a non-loopback bind and only warns (`HTTPMCPHost.swift:97-103`), and the README/`docs/openai-mcp-compatibility-report.md` document `--host` + TLS proxy / tunnel as the remote path. Any such request carrying a LAN, Tailscale or public Host is refused before MCP handling; the host's own `isLoopbackOrigin` check does not compensate because it inspects `Origin`, which server-to-server callers do not send.
- expected-correct: Build the validator's `allowedHosts`/`allowedOrigins` from the configured bind host and port using the SDK's `OriginValidator(allowedHosts:allowedOrigins:)`, so the deployment's own address is allowed while DNS-rebinding protection is preserved rather than disabled.
- reproducible-by: start `SwiftWebSearchMCP --transport http --port 18103`, then POST `initialize` with `Host: 127.0.0.2:18103` → `421`; the same request with `Host: 127.0.0.1:18103` → `200`.
- confidence: certain

#### L3-27 — The CI Swift-version gate passes silently when the version cannot be parsed
- severity: S2
- unit: `.github/workflows/ci.yml`
- file:line: `.github/workflows/ci.yml:67` (parse at `:63`)
- category: logic
- evidence: `version="$(swift -version 2>&1 | sed -n 's/.*Swift version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)"`; on any output-format mismatch `version` is empty, both `[ "$major" -lt 6 ]` tests fail with `integer expected`, the overall condition is false, the `::error::` branch is skipped and the step exits 0. That mismatch is precisely what the step exists to catch. Replayed locally: `version=""` → `GATE PASSED silently`, exit 0.
- expected-correct: `if [ -z "$version" ]; then echo "::error::could not parse the Swift version"; exit 1; fi` before the comparison, so an unparseable toolchain is a hard failure.
- reproducible-by: `bash -c 'set -euo pipefail; version=""; major="${version%%.*}"; minor="${version##*.}"; if [ "$major" -lt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -lt 3 ]; }; then exit 1; fi; echo "guard passed with empty version"'; echo $?`
- confidence: certain

#### L3-28 — `soak.py --providers` is not authoritative: an ambient `SEARCH_DISABLED_PROVIDERS` still disables requested providers
- severity: S2
- unit: `scripts/soak.py`
- file:line: `scripts/soak.py:217` (guard at `:214`, assignment `:221`)
- category: logic
- evidence: `already = [p.strip() for p in environment.get("SEARCH_DISABLED_PROVIDERS", "").split(",") if p.strip()]` seeds the re-emitted union from the ambient value, so a *requested* provider that is already listed stays disabled; and when `disabled` is empty (all nine requested) the `if disabled:` guard skips the write entirely, leaving the ambient value in place. The docstring at `:205-211` states "``--providers`` is authoritative", and the run header prints the requested set as the expected set (`:331`, `:336`) — the misreported run that the earlier fix set out to remove.
- expected-correct: Always assign the request-derived value: `environment["SEARCH_DISABLED_PROVIDERS"] = ",".join(sorted(set(ALL_PROVIDERS) - providers))`.
- reproducible-by: `SEARCH_DISABLED_PROVIDERS=tavily python3 -c "import sys; sys.path.insert(0,'scripts'); import soak; print(soak.build_environment({'tavily','brave'})['SEARCH_DISABLED_PROVIDERS'])"` → includes `tavily`.
- confidence: certain

#### L3-7 — `PARALLEL_MCP_URL=` cannot clear the default endpoint: the branch is unreachable in production
- severity: S3
- unit: `WebSearchCore/Support/AppConfiguration.swift`
- file:line: `Sources/WebSearchCore/Support/AppConfiguration.swift:330`
- category: dead
- evidence: `} else if values[Key.parallelMCPURL.rawValue]?.isEmpty == true { configuration.parallelMCPURL = nil }`. `values` can never contain an empty string: `load()` only copies environment entries when `!value.isEmpty` (`:265`), and `parseDotEnv` drops empty values entirely (`:415`). So when the operator exports `PARALLEL_MCP_URL=` (the documented-looking way to remove the built-in default `https://search.parallel.ai/mcp`), the else-if never fires and the default endpoint stays configured. The branch is only reachable if callers invoke the pure `parse(_:)` directly with an empty value.
- expected-correct: Make the empty-but-present case survive `load()` (preserve an explicitly empty value, or test `environment[Key.parallelMCPURL.rawValue] != nil` before filtering) so clearing the endpoint works; otherwise delete the branch and document that `SEARCH_ENABLE_PARALLEL=false` is the only switch.
- reproducible-by: `AppConfiguration.load(environment: ["PARALLEL_MCP_URL": ""]).parallelMCPURL` returns the non-nil default; add that assertion to `CoreUnitTests`.
- confidence: certain

#### L3-8 — DuckDuckGo region hint sends the region twice instead of region-language
- severity: S3
- unit: `WebSearchCore/Providers/DuckDuckGoProvider.swift`
- file:line: `Sources/WebSearchCore/Providers/DuckDuckGoProvider.swift:70`
- category: bug
- evidence: `items.append(URLQueryItem(name: "kl", value: "\(region.lowercased())-\(region.lowercased())"))` produces `kl=us-us` for `en-US`. DDG's `kl` is `region-language` (`us-en`, `de-de`); the language is available as `request.locale?.language` and is discarded. The copy-paste of `region` in both positions is the wrong operand.
- expected-correct: `"\(region.lowercased())-\(locale.language)"` (guard both parts), or omit `kl` when the language is unknown.
- reproducible-by: Add a provider-contract test asserting the built URL's `kl` value for locale `en-US` equals `us-en` (it is `us-us` today).
- confidence: certain

#### L3-9 — Hyphenated boilerplate markers are inert, and the prefix clause is unreachable
- severity: S3
- unit: `WebSearchCore/Fetch/HTMLExtractor.swift`
- file:line: `Sources/WebSearchCore/Fetch/HTMLExtractor.swift:63` (markers at `:36`, `:40`)
- category: logic
- evidence: Tokens are produced by `identifier.split(whereSeparator: { !$0.isLetter && !$0.isNumber })` (`:52-54`), which removes every `-`. Therefore a token can never contain `-`, so the third conjunct `token.dropFirst(needle.count).first == "-"` (`:63`) is **unreachable**, and every hyphen-bearing marker is dead: `side-bar` (`:36`), `skip-link` (`:40`), `meta-bar`, `site-header`, `site-footer`. Concretely, `class="side-bar"` tokenises to `["side","bar"]`, neither of which equals `side-bar` or matches another marker, so the element is **not** removed although it is explicitly listed — the exact false-negative the list exists to prevent. The doc comment at `:49-50` claims these markers match.
- expected-correct: Compare against the hyphenated marker on the raw identifier as well as on tokens, or list the hyphen-split forms (`side`,`bar` is too broad — better to normalise both the identifier and the marker by removing `-` before token comparison, or test `identifier.lowercased().contains("side-bar")` for the explicit hyphenated entries).
- reproducible-by: `HTMLExtractor.extract(html: "<html><body><div class='side-bar'>ADVERT TEXT</div><p>REAL</p></body></html>")` and assert the result does not contain `ADVERT TEXT` (it does today).
- confidence: certain

#### L3-10 — `isReserved` blocks all of `192.0.0.0/16` while documenting `192.0.0.0/24`
- severity: S3
- unit: `WebSearchCore/Fetch/URLPolicy.swift`
- file:line: `Sources/WebSearchCore/Fetch/URLPolicy.swift:435`
- category: logic
- evidence: `if a == 192, b == 0 { return true }  // 192.0.0.0/24`. The test only inspects the first two octets, so it rejects `192.0.1.0/24` … `192.0.255.0/24`, which are ordinary public space; only `192.0.0.0/24` is IETF-reserved and `192.0.2.0/24` is TEST-NET-1. The comment and the RFC say `/24`; the code is a `/16`.
- expected-correct: Match the documented prefix by also requiring the third octet to be zero (keep `192.0.2.0/24` covered, which it already is), so legitimate public URLs in `192.0.1.0/24`–`192.0.255.0/24` are not refused. This narrows an over-broad denial rather than relaxing a security control — no private or metadata range is involved.
- reproducible-by: Add a `URLPolicyTests` case asserting `URLPolicy(...).validateLexically(URL(string: "http://192.0.1.1/")!)` is `.allowed` (it is denied today).
- confidence: certain

#### L3-11 — Entity decoding runs twice, so `&amp;lt;` becomes a literal `<`
- severity: S3
- unit: `WebSearchCore/Search/ResultNormalizer.swift`
- file:line: `Sources/WebSearchCore/Search/ResultNormalizer.swift:149` (loop at `:155-157`)
- category: bug
- evidence: The replacement table is applied in a single sequential pass starting with `("&amp;", "&")` (`:150`) and continuing with `("&lt;", "<")` (`:150`). For input `&amp;lt;script&amp;gt;`, pass 1 rewrites `&amp;` → `&`, yielding `&lt;script&gt;`, and pass 2 then rewrites that to `<script>` — a double decode. A provider snippet that literally contained the text `&amp;` is displayed as `&`, and an escaped tag becomes a raw tag after `stripHTMLTags` (`:120-122`) has already run. It is a fidelity bug today (the payload is plain text/JSON, not rendered HTML) but it is a latent injection-shape bug if the text is ever rendered.
- expected-correct: Decode entities in one pass (a single scan with a replacement table, or replace `&amp;` last), so an already-escaped entity is never decoded twice.
- reproducible-by: Add a `CoreUnitTests` case asserting `ResultNormalizer.cleanText("&amp;lt;b&amp;gt;") == "&lt;b&gt;"` (it returns `<b>` today).
- confidence: certain

#### L3-12 — Malformed JSON from a node is reported as "unreachable"
- severity: S3
- unit: `WebSearchCore/Monitor/NodeProbe.swift`
- file:line: `Sources/WebSearchCore/Monitor/NodeProbe.swift:102` (catch at `:133-142`)
- category: bug
- evidence: `try JSONCoding.decoder().decode(SearXNGProbeResponse.self, from: response.body)` throws `DecodingError`, which is neither `SearchError` nor a transport error, so it lands in the generic `catch { … error: "unreachable" }` (`:133-141`). An instance that answered HTTP 200 but returned a non-SearXNG JSON body (or HTML with a JSON content type) is therefore shown as `DOWN / unreachable`, sending the operator after a network fault that does not exist — the same misdiagnosis the 403 branch (`:79-90`) was written to avoid.
- expected-correct: Catch the decode failure separately and report `state: .degraded` with a parse reason (e.g. "JSON response was not a SearXNG payload"), reserving `.down`/`unreachable` for transport failures.
- reproducible-by: `ProbeTests`: serve `{"not":"searxng"}` with `content-type: application/json` and assert the result state is `.degraded`, not `.down`.
- confidence: certain

#### L3-13 — `NodeStatus.State.skipped` is unreachable dead state
- severity: S3
- unit: `WebSearchCore/Monitor/MonitorModel.swift`, `Sources/MCPSMonitor/main.swift`
- file:line: `Sources/WebSearchCore/Monitor/MonitorModel.swift:50`
- category: dead
- evidence: `case skipped` ("Deliberately not probed, e.g. the monitor was told to skip it", `:49`) is declared, given a `SKIP` label (`:58`), a `–` glyph and a colour branch (`Renderer.swift:25`, `:57`) — and produced **nowhere**. `grep -rn '\.skipped' Sources` shows no assignment; `NodeProbe.Result.state` can only be `.down`, `.degraded` or `.up`, and `--no-nodes` removes the nodes (`main.swift:144`) instead of marking them skipped. The documented `SKIP` state can never be displayed.
- expected-correct: Either produce `.skipped` for a node the operator excluded (so `--no-nodes`/a skipped node is distinguishable from a node that was never configured), or delete the enum case and its three render branches.
- reproducible-by: `grep -rn 'skipped' Sources/WebSearchCore/Monitor Sources/MCPSMonitor` — declaration and render sites only.
- confidence: certain

#### L3-14 — Decoded-but-unused vendor DTO fields across five adapters
- severity: S3
- unit: `WebSearchCore/Providers/*`
- file:line: `Sources/WebSearchCore/Providers/MojeekProvider.swift:219` (and `ExaProvider.swift:174`, `SearXNGProvider.swift:174`, `TavilyProvider.swift:165`, `BraveProvider.swift:213`)
- category: dead
- evidence: Fields are decoded and never read: Mojeek `Head.start`, `Head.return`, `Item.date`, `Item.pdate` (`MojeekProvider.swift:221-233`); Exa `requestId`, `resolvedSearchType`, `Item.author`, `Item.summary` (`ExaProvider.swift:175-185`); SearXNG `query`, `corrections`, `suggestions`, `Item.category` (`SearXNGProvider.swift:175-200`); Tavily `TavilyResponse.query` (`TavilyProvider.swift:165`); Brave `BraveResponse.type` and `BraveErrorResponse.ErrorBody.id/status/detail` (`BraveProvider.swift:214`, `:255-257`). This is the same class of dead wire surface already removed for Brave once (`a375ddd`/`e60203e`); these instances remain. Decoding unused fields is harmless at runtime but misleads a reader into thinking the value is used and silently tolerates wire drift.
- expected-correct: Remove fields that no code path reads (or actually surface the useful ones, e.g. SearXNG `corrections`/`suggestions` as warnings), keeping the DTO to the contract that is consumed.
- reproducible-by: `grep -n 'start\|return\|pdate\|date' Sources/WebSearchCore/Providers/MojeekProvider.swift` and compare with every read site.
- confidence: certain

#### L3-15 — Dead scrub loops in two smoke scripts
- severity: S3
- unit: `scripts/mcp_smoke.py`, `scripts/monitor_tty_smoke.py`
- file:line: `scripts/mcp_smoke.py:100` (loop `:104`), `scripts/monitor_tty_smoke.py:192`
- category: dead
- evidence: In `mcp_smoke.py`, `environment = {"PATH": …, "SEARCH_LOG_LEVEL": "debug"}` builds a fresh dict containing only two names; the following `for name in SCRUBBED_VARIABLES: environment.pop(name, None)` therefore pops keys that were never inserted and can never remove anything. `monitor_tty_smoke.py` copies the pattern with an extra `if name in os.environ:` guard that makes it look deliberate but is still a no-op on a freshly built dict. The stated mechanism ("Provider and synthesis variables are cleared so the run is hermetic") is not what scrubs the run — the from-scratch dicts are. Both loops are dead code that will silently stop matching reality if the dicts are ever changed to seed from `os.environ`.
- expected-correct: Either drop the loops, or build from `os.environ` and actually pop `SCRUBBED_VARIABLES` (which is what the comments describe), so the hermeticity mechanism is the one that is written down.
- reproducible-by: `sed -n '96,106p' scripts/mcp_smoke.py; sed -n '186,195p' scripts/monitor_tty_smoke.py`; `SCRUBBED_VARIABLES` names are absent from both initial dicts.
- confidence: certain

#### L3-16 — `application/pdf` is claimed as text and returned as Latin-1 mojibake
- severity: S3
- unit: `WebSearchCore/Fetch/*`
- file:line: `Sources/WebSearchCore/Fetch/WebFetcher.swift:50` (decode at `DirectHTTPFetcher.swift:133-141`)
- category: incomplete
- evidence: `WebFetcher.Policy.allowedContentTypePrefixes` includes `"application/pdf"` (`WebFetcher.swift:50`), and `DirectHTTPFetcher.fetch` treats any non-HTML allowed type as raw text: `String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) ?? ""` (`DirectHTTPFetcher.swift:134-136`). A PDF is binary, so `web_open` returns a page of Latin-1 garbage labelled `method: rawText` instead of declining it or extracting its text. Nothing in the pipeline parses PDF, and the allow-list entry implies it does.
- expected-correct: Either remove `application/pdf` from the allow-list so a PDF yields a clear `extractionFailed`, or add real text extraction; do not pass binary through a text decoder.
- reproducible-by: `web_open` a known PDF URL and inspect `text` / `extraction_method` in the structured result.
- confidence: likely

#### L3-17 — Node table header and data disagree on the state column width
- severity: S3
- unit: `WebSearchCore/Monitor/Renderer.swift`
- file:line: `Sources/WebSearchCore/Monitor/Renderer.swift:273` (data at `:288`)
- category: style
- evidence: The node header pads the state column to 10 (`Terminal.pad("state", to: 10)`), while every data row renders it via `stateText(_: NodeStatus.State)` which pads to 8 (`:52`). The header's `latency`/`results`/`ok` columns therefore start two characters to the right of the data columns on every frame; the provider table (`:203`, `:215`) uses a consistent width, so this is a copy-paste divergence rather than a deliberate design.
- expected-correct: Use the same width in both places (the `used` estimate at `:317` already assumes 10).
- reproducible-by: `swift run mcps-mon --iterations 1` and compare the `state` header offset with the `UP`/`DOWN` glyphs.
- confidence: certain

#### L3-18 — Stale "detached task" comment plus a 60 ms sleep that waits for nothing
- severity: S3
- unit: `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift`
- file:line: `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:499`
- category: test
- evidence: `// The state update happens in a detached task inside recordFailure.` followed by `try await Task.sleep(for: .milliseconds(60))`. Production does the opposite and says so: `ProviderHealth.recordFailure` awaits the breaker ("Awaited for the same reason as `recordSuccess`", `ProviderHealth.swift:203-209`), and the sibling test `testOutcomesReachTheBreakerBeforeRecordReturns` (`:893`) asserts the breaker has already observed the outcome when `recordFailure` returns. The sleep is dead wall-clock cost plus a timing assumption.
- expected-correct: Delete the sleep and the stale comment; assert on `health` state directly, as the sibling test does.
- reproducible-by: `sed -n '488,516p' Tests/WebSearchCoreTests/SearchOrchestratorTests.swift`
- confidence: certain

#### L3-19 — Cancellation test accepts any `HTTPError`, so it passes without cancellation propagating
- severity: S3
- unit: `Tests/WebSearchCoreTests/HTTPClientTests.swift`
- file:line: `Tests/WebSearchCoreTests/HTTPClientTests.swift:313`
- category: test
- evidence: `XCTAssertTrue(error is CancellationError || (error as? HTTPError) != nil, …)`. Every transport failure the client throws is an `HTTPError`, including `.timedOut` (`HTTPClient.swift:110-123`, `:343-356`), so a request-timeout regression satisfies the assertion. The test also relies on `try await Task.sleep(for: .milliseconds(200))` (`:305`) to "give the request time to reach the server" before cancelling — a scheduling assumption.
- expected-correct: Require the dedicated case (`guard case .cancelled = error as? HTTPError`) and replace the fixed sleep with a deterministic synchronisation point.
- reproducible-by: `sed -n '295,318p' Tests/WebSearchCoreTests/HTTPClientTests.swift`
- confidence: certain

#### L3-20 — Clock test asserts a property that cannot fail
- severity: S3
- unit: `Tests/WebSearchCoreTests/CoreUnitTests.swift`
- file:line: `Tests/WebSearchCoreTests/CoreUnitTests.swift:344`
- category: test
- evidence: `let elapsed = clock.elapsedMilliseconds(since: start); XCTAssertGreaterThanOrEqual(elapsed, 0)`. `SystemClock.elapsedMilliseconds` is `Int((uptimeNanoseconds() &- start) / 1_000_000)` (`Clock.swift:13-16`) — a non-negative division of an unsigned delta, measured immediately after `start`, so the value is 0 and no plausible implementation of the signature can violate `>= 0`. The test name promises nanosecond handling that is never exercised.
- expected-correct: Advance a `TestClock` by a known duration and assert the converted milliseconds, or delete the test.
- reproducible-by: `sed -n '340,346p' Tests/WebSearchCoreTests/CoreUnitTests.swift`
- confidence: certain

#### L3-21 — Subprocess harnesses advertise a timeout that a blocking read cannot enforce
- severity: S3
- unit: `Tests/WebSearchCoreTests/StdioServerTests.swift` (same pattern in `ErrorReportingTests.swift`, `SchemaCompatibilityTests.swift`)
- file:line: `Tests/WebSearchCoreTests/StdioServerTests.swift:85` (loop `:70-93`)
- category: test
- evidence: The read loops are `while Date() < deadline { … let chunk = stdoutPipe.fileHandleForReading.availableData … }`. `FileHandle.availableData` blocks until data arrives or EOF, so the deadline check at the top of the loop cannot preempt a wedged server; the 15 s/20 s "timeouts" (`StdioServerTests.swift:67`, `ErrorReportingTests.swift:61`, `SchemaCompatibilityTests.swift:56`) are never enforced and a deadlocked server hangs the run indefinitely instead of failing. These harnesses are the only end-to-end coverage of the built binary.
- expected-correct: Read with a real deadline (poll/`select`, a `readabilityHandler` plus a semaphore wait, or a background reader with a join timeout) and fail the test on expiry.
- reproducible-by: `sed -n '67,106p' Tests/WebSearchCoreTests/StdioServerTests.swift`; temporarily make the server not answer and observe the hang.
- confidence: likely

#### L3-22 — Three copies of the same subprocess harness, already diverged
- severity: S3
- unit: `Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift`
- file:line: `Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift:30`
- category: test
- evidence: `StdioServerTests.ServerProcess` (`:28-120`), `ErrorReportingTests.Server` (`:19-104`) and `SchemaCompatibilityTests.Server` (`:30-84`) are copies of one process+pipe+newline-JSON harness. The `SchemaCompatibilityTests` copy has drifted: `enum Failure: Error { case timeout, unexpectedExit }` (`:83`) drops the stderr payload, and `process.standardError = Pipe()` (`:40`) is created but never read, so an early exit reports only `unexpectedExit` with no diagnostic; `ErrorReportingTests.readResponse` (`:61`) also uses a different id-filtering structure from `StdioServerTests.readResponse` (`:98`). The shared environment scrub list was correctly factored into `ServerTestSupport`, but the framing/timeout logic was not.
- expected-correct: One parameterised harness in `TestSupport.swift` (scrubbed environment, enforced timeout, stderr capture) so the copies cannot drift.
- reproducible-by: `sed -n '28,120p' Tests/WebSearchCoreTests/StdioServerTests.swift; sed -n '30,84p' Tests/WebSearchCoreTests/SchemaCompatibilityTests.swift`
- confidence: certain

#### L3-23 — `assertNoCredentialLeak` documents a check it does not perform and passes vacuously
- severity: S3
- unit: `Tests/WebSearchCoreTests/TestSupport.swift`
- file:line: `Tests/WebSearchCoreTests/TestSupport.swift:178` (body `:170-189`)
- category: test
- evidence: The comment says "assert the request was recorded but that our *own* diagnostics never echo it" (`:178-180`), but the body only scans the mock's recorded request headers and body — never a log line, error, or `safeDescription`, which is where a Mojeek query-string key could actually leak. It also iterates `for request in requests` with no non-empty guard, so a client that made zero requests passes without asserting anything.
- expected-correct: Add `XCTAssertFalse(requests.isEmpty)` (or take an expected count) and either assert on captured log/error output or reword the comment to say it only checks the wire request.
- reproducible-by: `sed -n '163,190p' Tests/WebSearchCoreTests/TestSupport.swift`
- confidence: certain

#### L3-24 — Soak report attributes every failure category to every provider
- severity: S3
- unit: `scripts/soak.py`
- file:line: `scripts/soak.py:446`
- category: bug
- evidence: The per-provider failure line filters the **global** counter rather than a per-provider one: `print(f"    {name:16} {count:>3}  (categories: " f"{', '.join(sorted({c for c, _ in failures_by_category.items()}))})")`. `failures_by_category` is accumulated across every provider (`:408`), so each provider's printed "categories" set is the union of all categories seen in the whole run. A provider that only ever timed out is printed as also having failed with `server_error` or `rate_limited` if any other provider did — the opposite of the per-provider attribution the soak exists to produce.
- expected-correct: Accumulate a per-provider category counter (a nested `defaultdict(Counter)` or a `Counter` keyed by `(provider, category)`) and print only that provider's categories.
- reproducible-by: `sed -n '400,412p' scripts/soak.py; sed -n '442,451p' scripts/soak.py`; run with two providers forced to fail with different categories and compare the per-provider lines.
- confidence: certain

#### L3-29 — `--no-nodes` is silently ignored whenever a `--node` is also present
- severity: S3
- unit: `MCPSMonitor` (option parsing)
- file:line: `Sources/MCPSMonitor/main.swift:200` (`--no-nodes` at `:143`, custom nodes at `:160`)
- category: logic
- evidence: `--no-nodes` sets `options.nodes = []` inside the parse loop, but after the loop `if !customNodes.isEmpty { options.nodes = customNodes }` unconditionally restores them. So `mcps-mon --node n1=… --no-nodes` still probes n1, while `--no-nodes` alone disables probing; the two flags are order-independent in the usage text but order-dependent in the code. This is the same class of defect as the already-fixed order-dependent server transport flags, in a second parser.
- expected-correct: Track a `nodesDisabled` flag and make it authoritative after the loop, or document that `--node` wins.
- reproducible-by: `mcps-mon --node n1=http://127.0.0.1:8888 --no-nodes --iterations 1` → the node row is still probed.
- confidence: certain

#### L3-30 — `--node` accepts a relative URL and can swallow the next flag as its value
- severity: S3
- unit: `MCPSMonitor` (option parsing); same helper copied in `WebSearchCore/Support/TransportConfiguration.swift`
- file:line: `Sources/MCPSMonitor/main.swift:155` (helper `:127-135`); `Sources/WebSearchCore/Support/TransportConfiguration.swift:97`
- category: logic
- evidence: `guard let url = URL(string: urlText)` is not an absolute-URL check — `URL(string:)` accepts relative references — so `--node n1=foo` starts, probes nothing useful and shows `n1 DOWN … unreachable` instead of a CLI error. `value(for:)` returns `arguments[index + 1]` without checking that it is not itself a flag, so `--node --interval=5` creates a node literally named `--interval` and consumes the interval flag. The identical `value(for:)` is copy-pasted into `TransportConfiguration.parse`, where `--host --http-path` likewise accepts `--http-path` as a host string and fails only at bind time.
- expected-correct: Require `url.scheme != nil && url.host != nil` for `--node`, and have `value(for:)` throw `missingValue` when the next argument starts with `--`, in both parsers (the divergence itself is the reason to share the helper).
- reproducible-by: `mcps-mon --node n1=foo --iterations 1` (succeeds, node DOWN); `mcps-mon --node --interval=5 --iterations 1` (node named `--interval`).
- confidence: certain

#### L3-31 — `mcps-mon` ignores `SEARCH_DISABLED_PROVIDERS`, labels disabled providers "ready", and probes them
- severity: S3
- unit: `MCPSMonitor` (provider selection); `WebSearchCore/Search/ProviderRegistry.swift`
- file:line: `Sources/MCPSMonitor/main.swift:348` (and `:292`), `Sources/WebSearchCore/Search/ProviderRegistry.swift:34`
- category: logic
- evidence: `ProviderProbe.isConfigured` delegates to `ProviderRegistry.isConfigured`, which is only `providers[id]?.isConfigured ?? false` (`ProviderRegistry.swift:34-36`) and never consults `isEnabled(id)` (`:30-32`, the `SEARCH_DISABLED_PROVIDERS` map used by the server's `select`/`isEligible`). The monitor therefore shows an operator-disabled provider as `IDLE` with "ready — press p to probe", includes it in the probe set (`main.swift:348`), and `ProviderProbe.probe` (which also guards only on the adapter's `isConfigured`) issues a real search on `--probe` and on the first pass — spending a credit on a provider the server itself refuses to use.
- expected-correct: Make the monitor's ready/configured notion agree with server eligibility by factoring in `registry.isEnabled(id)`, and present such a provider as unavailable rather than ready.
- reproducible-by: `TAVILY_API_KEY=<throwaway> SEARCH_DISABLED_PROVIDERS=tavily mcps-mon --iterations 1` → Tavily shown IDLE/"ready" and probed; `web_search provider=tavily` returns `unsupportedRequest("provider is disabled")` for the same environment.
- confidence: certain (code); credit impact likely

#### L3-32 — `web_answer`'s `provider` property omits the enum that `web_search` declares
- severity: S3
- unit: `SwiftWebSearchMCP` (tool schemas)
- file:line: `Sources/SwiftWebSearchMCP/ToolSchemas.swift:275` vs `:83`
- category: incomplete
- evidence: `webSearchInput["provider"]` carries `"enum": ["auto", "tavily", …, "parallel"]`; `webAnswerInput["provider"]` is only `["type": ["string","null"]]` with prose. Both handlers run the identical `ProviderID(rawValue:)` validation (`ToolHandlers.swift:52-62` vs `:202-212`), so acceptance matches, but a schema-driven client cannot pre-validate `web_answer`'s provider and the schema lists no ids anywhere. This is the only divergence between the otherwise mirrored argument blocks — classic copy-paste drift.
- expected-correct: Mirror web_search's enum (`"auto"` + `ProviderID.allCases` raw values) in `webAnswerInput`.
- reproducible-by: `grep -n '"auto"' Sources/SwiftWebSearchMCP/ToolSchemas.swift` → only the `web_search` block.
- confidence: certain

#### L3-33 — `ToolArguments.bool(_:)` has no caller
- severity: S3
- unit: `SwiftWebSearchMCP` (argument parsing)
- file:line: `Sources/SwiftWebSearchMCP/ToolSchemas.swift:464`
- category: dead
- evidence: `public func bool(_ name: String) throws -> Bool?` is never called: every `.bool(` match in `Sources`/`Tests` is a `Value.bool(…)` constructor in the formatters, and no tool schema declares a boolean property. It is public API on a type whose purpose is validated tool arguments, so it invites untested re-use.
- expected-correct: Delete it, or add it together with the boolean argument that needs it.
- reproducible-by: `grep -rn 'args\.bool\|arguments\.bool' Sources Tests` → no matches.
- confidence: certain

#### L3-34 — `ProviderStatus.State.probing` and `.unavailable` can never be produced, so their renderer branches are unreachable
- severity: S3
- unit: `MCPSMonitor` view state; `WebSearchCore/Monitor/Renderer.swift`
- file:line: `Sources/WebSearchCore/Monitor/MonitorModel.swift:127` and `:134`
- category: dead
- evidence: The only producers of `ProviderStatus` are `ProviderStatus.pending` (`configuredButIdle`/`notConfigured`) and `applying` (`healthy`/`failing`); no code assigns `.probing` or `.unavailable` (the only other `.unavailable` references are the unrelated `unavailableEngines`), yet `Renderer` implements a glyph and state colour for both (`Renderer.swift:34-36`, `:45`). The monitor does not model an in-flight probe (the model is updated only after all probes return), so the "N/A" presentation for an enabled-but-unusable provider is permanently unreachable.
- expected-correct: Either set `.probing` around a probe cycle and `.unavailable` for an enabled-but-unusable provider, or delete the two states and their render branches.
- reproducible-by: `grep -rn '\.probing\b\|= \.unavailable' Sources/MCPSMonitor Sources/WebSearchCore/Monitor` → declaration/render sites only.
- confidence: certain

#### L3-35 — `isLoopbackOrigin` matches any hostname beginning with `127.`
- severity: S3 (latent — currently masked by the SDK's later exact allow-list)
- unit: `SwiftWebSearchMCP` (HTTP origin check)
- file:line: `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:445`
- category: logic
- evidence: `return host == "127.0.0.1" || host == "::1" || host == "localhost" || host.hasPrefix("127.")` — the prefix arm accepts `127.0.0.1.evil.com` and `127.evil.com`. The SDK's `OriginValidator.localhost` runs afterwards and exact-matches the whole origin, so such a request is still refused 403 today; the branch is nevertheless an always-too-permissive check that becomes live if the stricter validator is relaxed, reordered, or replaced.
- expected-correct: Exact-match the loopback names/literals, or parse the host as an IP and test its loopback property, rather than testing a string prefix.
- reproducible-by: request with `Origin: http://127.0.0.1.evil.com` once the SDK validator no longer masks it; the helper is private.
- confidence: certain (behaviour), masked today

#### L3-36 — A request-head `Content-Length` reserves up to 1 MiB per connection before any body arrives
- severity: S3
- unit: `SwiftWebSearchMCP` (HTTP host body cap)
- file:line: `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:167`
- category: unsafe
- evidence: `bodyBuffer.reserveCapacity(min(head.headers.first(name: "content-length").flatMap(Int.init) ?? 4096, 1 << 20))` runs on `.head`, i.e. on an untrusted header, and NIO's `ByteBuffer.reserveCapacity` allocates immediately when the requested capacity exceeds the current one. A client can make the server hold ~1 MiB per connection by sending only the request head with `Content-Length: 1048576` and no body; the 1 MiB cap in `HTTPMCPHandler.maximumBodyBytes` is enforced only later, once bytes actually arrive. Bounded on the loopback default, but real for the opt-in unauthenticated non-loopback bind.
- expected-correct: Reserve a small fixed capacity (or grow lazily as `.body` parts arrive) and rely on the existing `maximumBodyBytes` check as the enforcement point.
- reproducible-by: open N connections to the HTTP port, send only the head with `Content-Length: 1048576`, send nothing, and observe RSS growth per connection.
- confidence: likely

#### L3-37 — `soak.py`'s promised "primary provider never contributed" failure is not implemented
- severity: S3
- unit: `scripts/soak.py`
- file:line: `scripts/soak.py:475`
- category: incomplete
- evidence: The comment above the exit gate promises failure when "the primary provider never contributed", but the only condition is `if errors == len(queries) and queries:`. Nothing consults `usage_by_provider` (`:405`) or `results_total` (`:403`), so a run in which the primary provider contributed 0/N, or in which every query returned zero results, still prints `SOAK COMPLETE` and exits 0 — the soak's headline guarantee is not checked.
- expected-correct: Fail when the primary requested provider's participation count is 0 (or when a non-empty run produced zero results), using the existing `SOAK FAILED` path at `:468-471`.
- reproducible-by: `grep -n 'SOAK FAILED\|errors == len(queries)' scripts/soak.py`; the only gate is the all-queries-errored one.
- confidence: certain

#### L3-38 — `soak.py` conflates EOF with a malformed stdout line and discards the line
- severity: S3
- unit: `scripts/soak.py`
- file:line: `scripts/soak.py:170` (used at `:183`)
- category: bug
- evidence: `read()` returns `None` both on EOF (`:167`) and on `JSONDecodeError` (`:170-171`); `request()` maps that single `None` to `RuntimeError("server closed stdout")` (`:183`). A stray non-JSON protocol line — which `mcp_smoke.py:129-135` treats as a hard failure and quotes — is discarded and misdiagnosed as a closed stdout.
- expected-correct: Return `None` only for EOF and raise with the offending line on `JSONDecodeError`, so a corrupted protocol stream is reported as such.
- reproducible-by: `sed -n '163,185p' scripts/soak.py`.
- confidence: certain

#### L3-39 — `mcp_smoke.py` de-chunks an SSE body after decoding it to `str`
- severity: S3
- unit: `scripts/mcp_smoke.py`
- file:line: `scripts/mcp_smoke.py:315` (decode at `:296`)
- category: bug
- evidence: `http_exchange` decodes the whole response first (`text = raw.decode("utf-8", "replace")`, `:296`) and then, for a chunked body, slices `remaining[index + 2 : index + 2 + size]` where `size` is the hex byte count from the chunk header (`:315`). A byte count is applied to a `str`, so any non-ASCII body (Swift's `JSONEncoder` emits raw UTF-8) shifts every later boundary and the recovered stream is truncated/corrupted. Latent today only because the smoke payloads are ASCII.
- expected-correct: De-chunk the raw bytes before decoding, or let `http.client`/`urllib` handle framing.
- reproducible-by: replay lines 308-322 on a chunked body containing a multi-byte character; the recovered tail is wrong.
- confidence: certain (mismatch), uncertain (reachability today)

#### L3-40 — A negative `--queries` silently truncates the query list from the end
- severity: S3
- unit: `scripts/soak.py`
- file:line: `scripts/soak.py:327` (argument at `:301`)
- category: bug
- evidence: `argparse` with `type=int` accepts negatives, and `queries = QUERIES[: args.queries]` applies Python negative-slice semantics: `--queries -3` runs 48 of 51 queries while the header presents that count as requested, and `--queries -100` runs zero queries and still exits 0. Verified locally: `len(QUERIES) == 51`, `len(QUERIES[:-3]) == 48`.
- expected-correct: Reject negatives (`parser.error("--queries must be positive")`) or clamp with an explicit message.
- reproducible-by: `python3 -c "import sys; sys.path.insert(0,'scripts'); import soak; print(len(soak.QUERIES), len(soak.QUERIES[:-3]))"` → `51 48`.
- confidence: certain

#### L3-41 — HTTP smoke can wait 20 s on a dead server and never checks that it is alive
- severity: S3
- unit: `scripts/mcp_smoke.py`
- file:line: `scripts/mcp_smoke.py:345-353` (port at `:350-357`, stderr only read at `:458`)
- category: bug
- evidence: `free_loopback_port()` binds port 0 and closes the probe socket before handing the number to the child, so the child can fail to bind; if the child then exits, `wait_for_health` loops for the full 20 s and raises `"HTTP transport did not become healthy on port N"` without ever calling `process.poll()` or reading the captured stderr. The captured stderr is only consumed on the success path, so a startup failure produces a bare timeout with no diagnostic.
- expected-correct: Check `process.poll()` inside the wait loop and include the child's stderr in the `Failure`; keep the probe socket until the child has bound, or retry a fresh port on bind failure.
- reproducible-by: `sed -n '330,372p' scripts/mcp_smoke.py`; force the child to fail to start (e.g. occupy the port) and observe the 20 s wait with no stderr in the message.
- confidence: certain (mechanism), likely (frequency)

#### L3-42 — Provisioning removes the live SearXNG container before the replacement is running
- severity: S3
- unit: `deploy/provision-node.sh`
- file:line: `deploy/provision-node.sh:270` (replacement run at `:275-281`)
- category: unsafe
- evidence: `docker rm -f mcps-searxng` (`:270`) runs before `docker run … || fail` (`:275-281`), so a failure in the run step leaves the node with no instance at all. The canary (`:255-268`) validates the image but binds `127.0.0.1:${SEARXNG_CANARY_PORT}` (`:259`), so it never exercises the final `-p "${SEARXNG_PORT}:8080"` binding (`:278`) — a host-port conflict on the real port is exactly the failure the canary cannot catch, and the comment at `:251-254` reads as if that window were eliminated.
- expected-correct: Start the replacement under a temporary name/port, verify it answers, then swap; or restart the previous image on failure instead of leaving the node dark.
- reproducible-by: `sed -n '251,282p' deploy/provision-node.sh`; on a host with `:8888` already bound, the script removes the working container and then `docker run` fails.
- confidence: likely

---

## Explicitly not findings (test fixtures that look like placeholders)

`MockHTTPClient`, `MockSearchProvider`, `Fixtures`, `StubDNSResolver`, `LoopbackServer`,
`RawHTTP`, `TestClock`, the `let stub = try LoopbackServer(…)` variables, canned
SearXNG/completion JSON, synthetic credentials (`tvly-…`, `sk-test-…`, `jina-test-key`),
and `.invalid`/`example.com` hosts are test-only doubles and documentation-style names.
`LiveProviderTests`' live network calls and `config.env` read are gated behind
`SEARCH_LIVE_TESTS` plus a usable-key check. CI's `tvly-ci-placeholder-not-a-real-key`
values (`ci.yml:124-126`) are deliberate hermeticity probes, and `example.env` contains
no uncommented assignments. None is a production-path placeholder.
