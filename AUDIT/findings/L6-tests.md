# L6 — Tests audit

**Package:** `SwiftWebSearchMCP` (branch `audit/2026-09-13`) · **Unit under audit:** `Tests/**` and the
production code those tests claim to pin · **Baseline (parent-measured, not re-measured):** 371 XCTest
cases, 6 skipped, 0 failures; line coverage 84.3 % `Sources/` overall, 88.2 % `WebSearchCore`,
**0 % in-process for the `SwiftWebSearchMCP` executable**, 29.5 % `MCPSMonitor`; TSan clean; ASan crash
in `ProviderContractTests/testDuckDuckGoTaxonomy` = ledger **A01** (not re-reported; only the residual
test gaps in the new depth scanner are noted below as L6-4).

## Scope note

Every file under `Tests/**` was read in full (22 files, 9 313 lines), plus the production code each
test claims to cover: `SearchOrchestrator`, `AnswerSynthesizer`, `RankFusion`, `ProviderHealth`,
`ResultNormalizer`, `SearchRequest`, `HTTPClient`, `HTTPStatusMapper`, `AppConfiguration`, `Logging`,
`JSONCoding`, `URLPolicy`, `DirectHTTPFetcher`, `WebFetcher`, `JinaReaderFetcher`, `HTMLExtractor`,
`MarkupDepth` (untracked, in the working tree), `NodeProbe`, `ProviderProbe`, `MonitorModel`,
`ToolHandlers`, `ToolSchemas`, `MCPServer`, `HTTPMCPHost`, `main.swift` (both executables), and the
four Python harnesses. `git log`/`git diff` were inspected read-only; no build or test command was
run.

**As-of note:** the pass started from commit `e72cadc` (and `92a0ae1` landed mid-pass). While this
report was being written the parent concurrently landed the A01 fix: `Sources/WebSearchCore/Fetch/MarkupDepth.swift`
plus guards in `HTMLExtractor`/`ScraperSupport`, a new `Tests/WebSearchCoreTests/MarkupDepthTests.swift`
(untracked at the time of writing), and the deletion of the temporary `AUDITDiagnosticsTests.swift`.
Those additions are **not** in the 371-case baseline. L6-4 was rewritten to cover only what the new
tests still leave unpinned, and the `AUDITDiagnosticsTests` observation (originally drafted as a
finding) is resolved by that deletion and is no longer listed.

Two structural facts drive several findings:

1. `SwiftWebSearchMCP` and `MCPSMonitor` are executable targets with **no unit-test target that can
   import them** (`Package.swift:48-84`; only `MCPSMonitorTests` imports `MCPSMonitor`). Everything in
   `ToolHandlers`/`ToolSchemas`/`HTTPMCPHost` can therefore only be reached through the subprocess
   harnesses, and the harnesses only exercise a subset of the surface. This is ledger A04; the
   concrete untested paths it leaves are enumerated below.
2. The subprocess harnesses scrub provider credentials from a shared list
   (`TestSupport.swift:17-27`) that is mirrored by hand in `scripts/mcp_smoke.py:45-64`, and no test
   compares the two (overlaps ledger A12).

## Severity count

| severity | count | findings |
| --- | --- | --- |
| S0 | 1 | L6-1 |
| S1 | 2 | L6-2, L6-3 |
| S2 | 9 | L6-5 … L6-13 |
| S3 | 9 | L6-4, L6-14 … L6-21 |
| **total** | **21** | |

## What the suite genuinely covers well

- **Provider taxonomy is systematic, not per-test.** `assertFailureTaxonomy`
  (`ProviderContractTests.swift:55-158`) drives every adapter through auth / 429 / 5xx / malformed and
  pins both the `SearchError` category and `isTransient`, so a dropped branch fails a test rather than
  surviving on a vendor quirk. Vendor quirks are separately pinned: Brave 422-with-code vs ordinary
  422 (`:352-390`), Mojeek HTTP-200-with-error and quota strings (`:440-475`), Exa 402/401
  (`:557-589`), SearXNG 403-means-JSON-disabled (`:635-663`), DDG/Startpage challenge pages
  (`:743-768`, `:907-930`).
- **The SSRF policy is tested adversarially.** `URLPolicyTests` covers schemes, credential URLs,
  trailing-dot/`localhost.` tricks, internal suffixes, integer/hex/octal obfuscations, IPv6 literals
  embedding non-public IPv4 (mapped, compatible, NAT64, 6to4, Teredo) **and** public-embedded
  negatives, plus resolution-based decisions with an injected resolver. Together with the
  `MarkupDepthTests` that landed during this pass (depth boundaries, void/self-closing/raw-text
  handling, early exit, and the two SIGBUS inputs), these are the security units with the strongest
  negative coverage.
- **Fusion invariants are pinned to numbers, not vibes.** `RankFusionTests` asserts the exact
  per-result aggregator discount arithmetic (`FusionAndReliabilityTests.swift:304-383`), the
  rank-ratio invariant that forbids a blanket penalty (`:154-168`), deterministic tie-breaking, and
  interleaving of disjoint providers. The regression story (live-fusion defect) is captured in the
  assertions.
- **Concurrency primitives are deterministic.** `CircuitBreaker`, `RateLimiter`, `SearchCache`,
  `ProviderHealth` and `SearchOrchestrator` cache/expiry tests use `TestClock`; the detached-task
  registration hazard has a no-suspension test (`:869-890`). TSan is clean.
- **End-to-end harness hygiene.** `ServerTestSupport.binaryURL()` fails (not skips) in CI when the
  binary is missing (`TestSupport.swift:40-64`); every server harness uses a scrubbed env; stdout
  purity and stderr diagnostics are asserted over stdio and HTTP; `scripts/mcp_smoke.py` (stdio +
  `--http`) and `scripts/monitor_tty_smoke.py` (PTY, real key handling) run in CI. `LiveProviderTests`
  requires an explicit opt-in **and** a non-placeholder key (`LiveProviderTests.swift:50-124`), which
  keeps the default suite hermetic under CI's placeholder credentials.

---

#### L6-1 — The manual redirect loop is the SSRF boundary for redirects and has no test at all
- severity: S0
- unit: `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift` (fetch redirect branch), `Tests/WebSearchCoreTests/FetchBehaviorTests.swift`
- file:line: `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:82`
- category: test
- evidence: The fetcher deliberately disables `URLSession` redirect-following and re-validates every hop:

  ```swift
  // DirectHTTPFetcher.swift:82-102
  if (300..<400).contains(response.statusCode),
     let location = response.header("Location")
  {
      guard redirectsFollowed < maxRedirects else {
          throw SearchError.extractionFailed(request.url)
      }
      guard let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL
      else { throw SearchError.extractionFailed(request.url) }
      let hopDecision = await policy.validate(nextURL)
      guard hopDecision.allowed else { throw SearchError.blockedURL(nextURL) }
      redirectNotes.append("Followed redirect to \(nextURL.host() ?? "unknown host").")
      currentURL = nextURL
      redirectsFollowed += 1
      continue
  }
  ```

  No test in `Tests/**` ever returns a `3xx`. `grep -rni "redirect\|Location" Tests/` matches only the
  DDG `unwrapRedirect` helper tests and `MonitorTests`' *rendering* test names. `FetchBehaviorTests`
  exercises 403, 404 and 200 only (`FetchBehaviorTests.swift:34-93`); the only fetch-level denial test
  is for the **initial** URL (`FetchFallbackTests.swift:197-220`). `LoopbackServer.Response` already
  supports `status` and `headers` (`HTTPClientTests.swift:12-18`), so the missing coverage is not a
  harness limitation.
- expected-correct: Add `DirectHTTPFetcherTests` over `LoopbackServer` that assert: (a) a 302 whose
  `Location` is a blocked destination (`http://169.254.169.254/`, `allowPrivateNetwork: false`)
  throws `.blockedURL`, and the blocked host is never contacted; (b) with `allowPrivateNetwork: true`,
  a 302 to a second loopback server is followed — `FetchResult.finalURL` is the target and
  `warnings` contains `Followed redirect to …`; (c) a chain of `maxRedirects + 1` redirects throws
  `.extractionFailed`; (d) a relative `Location: /next` resolves against the current URL; (e) a 3xx
  with no `Location` is treated as a non-success status (currently `fetchFailed`/`extractionFailed`).
- reproducible-by: Change `if (300..<400).contains(response.statusCode)` to `if false` (redirect
  following silently stops working), or replace the manual loop with `URLSession`'s automatic
  redirects, or delete the per-hop `policy.validate(nextURL)` guard. Every one of these leaves the
  whole suite green because no test sends a 3xx: a public page that 302s to
  `http://169.254.169.254/` is then fetched without a policy decision.
- confidence: certain

#### L6-2 — `web_open`'s success path through the MCP tool is untested end to end
- severity: S1
- unit: `Sources/SwiftWebSearchMCP/ToolHandlers.swift` (`webOpen`), `Sources/SwiftWebSearchMCP/ToolSchemas.swift` (`ToolOutputFormatter.openText/openStructured`)
- file:line: `Sources/SwiftWebSearchMCP/ToolHandlers.swift:134`
- category: test
- evidence: Every committed `web_open` call is a rejection:

  ```swift
  // StdioServerTests.swift:692-698
  let cases: [(id: Int, url: String, expected: String)] = [
      (10, "file:///etc/passwd", "public http/https"),
      (11, "http://localhost:8080/admin", "public http/https"),
      (12, "http://169.254.169.254/latest/meta-data/", "public http/https"),
      (13, "http://10.0.0.1/", "public http/https"),
      (14, "javascript:alert(1)", "valid absolute URL"),
  ]
  ```

  `ErrorReportingTests` only drives `web_open` failures (`:137-183`). `FetchBehaviorTests` /
  `FetchFallbackTests` call `DirectHTTPFetcher`/`WebFetcher` **directly**, which proves nothing about
  the tool wiring, and nothing in `Tests/**` calls `ToolOutputFormatter.openText`/`openStructured`.
  No test therefore pins `structuredContent.url`, `final_url`, `status`, `extraction_method`,
  `text_characters`, `truncated`, `warnings`, or the `# title` heading de-duplication branch
  (`ToolSchemas.swift:742-753`), and no produced payload is ever checked against `webOpenOutput`
  (the schema linter validates the *declared* schema only).
- expected-correct: A stdio test that starts the server with `SEARCH_ALLOW_PRIVATE_NETWORK=true` and a
  `LoopbackServer` serving `<html><head><title>Hello</title></head><body><article><p>…</p></article></body></html>`,
  calls `web_open`, and asserts `isError != true`, `structuredContent.extraction_method ==
  "htmlExtraction"`, `status == 200`, `final_url == requested url`, `text_characters ==` the length of
  the text block, `warnings == []`, `truncated == false`, and that the text starts with the article
  prose (not a duplicated `# Hello`). A second call with `max_characters: 1000` against a longer body
  asserts `truncated == true` and the truncation note.
- reproducible-by: In `webOpen`, insert `return Self.error("Fetch failed.")` immediately after the
  `do {` at line 134, or delete the `"text_characters"` / `"extraction_method"` entries from
  `openStructured` (`ToolSchemas.swift:762-774`): the entire suite (including the Python smoke script)
  stays green. A regression that breaks `web_open` for every real page would ship unnoticed.
- confidence: certain

#### L6-3 — Caller cancellation is never tested, and mid-flight cancellation is observably swallowed
- severity: S1
- unit: `Sources/WebSearchCore/Search/SearchOrchestrator.swift`, `Sources/SwiftWebSearchMCP/ToolHandlers.swift`
- file:line: `Sources/WebSearchCore/Search/SearchOrchestrator.swift:91`
- category: test
- evidence: The orchestrator has four cancellation points and none is exercised:

  ```swift
  // SearchOrchestrator.swift:70-91 (entry snapshot) and :91 (the only propagation)
  let callerCancelledBefore = Task.isCancelled
  …
  if Task.isCancelled, callerCancelledBefore { throw CancellationError() }
  // :479 in runSingle
  try Task.checkCancellation()
  // :501
  } catch is CancellationError {
      result.failures.append(ProviderFailure(provider: id, category: .cancelled, …))
  ```

  `grep -rni "cancel" Tests/` finds exactly two places: `ProbeTests.testCancellationIsClassifiedAsCancelled`
  (a provider that *throws* `CancellationError`, at the `ProviderProbe` level) and the weak HTTP test
  in L6-8. No test cancels a running `SearchOrchestrator.search` or a live `tools/call`. Because
  `callerCancelledBefore` is captured before the fan-out, a cancellation that arrives **during** a
  search satisfies `Task.isCancelled` but not `callerCancelledBefore`, so `CancellationError` is not
  propagated; `runSingle` converts it into a `.cancelled` provider failure and the call returns
  partial results — so `ToolHandlers`' `catch is CancellationError` (`ToolHandlers.swift:91-93`)
  is unreachable for that case and is untested for the pre-cancelled case too.
- expected-correct: Two tests: (a) cancel the `Task` *before* calling `search` on a `hanging` provider
  and assert `CancellationError`; (b) start a search on a `hanging` provider, `Task.sleep` briefly,
  cancel, and assert the documented contract — either `CancellationError` is thrown, or the call
  degrades to a response whose `providersFailed` contains `.cancelled` and whose results contain no
  further provider work. If (b) shows graceful degradation, `web_open`/`web_search` cancellation and
  the MCP-level "cancelled" message must be asserted through a tool call. (If the intended contract is
  propagation, the missing post-fan-out `throw CancellationError()` is a production finding for the
  parent, not a test one.)
- reproducible-by: Delete `if Task.isCancelled, callerCancelledBefore { throw CancellationError() }`
  (`:91`), or make `runSingle`'s `catch is CancellationError` record `.unknown` instead of `.cancelled`
  — every test still passes. An MCP client that cancels a tool call keeps the providers running and
  consumes their credits with nothing to notice it.
- confidence: certain

#### L6-4 — The new `MarkupDepth` regression suite still leaves four branches/contracts unpinned
- severity: S3
- unit: `Sources/WebSearchCore/Fetch/MarkupDepth.swift`, `Search/SearchError.swift`, `SwiftWebSearchMCP/ToolHandlers.swift`
- file:line: `Sources/WebSearchCore/Fetch/MarkupDepth.swift:190`
- category: test
- evidence: The parent landed `Tests/WebSearchCoreTests/MarkupDepthTests.swift` during this pass
  (untracked, not in the 371-case baseline). It covers the scanner well — limit accepted / limit+1
  rejected (`:28-34`), void and self-closing elements (`:36-44`), comments and declarations
  (`:46-50`), closing tags (`:52-57`), stray `<` (`:59-63`), a quoted `>` (`:65-70`), raw-text content
  (`:72-77`), early exit on 300 000 levels (`:84-90`), the markup sniff (`:92-101`), and the three A01
  call paths: `DuckDuckGoProvider` at 5 000 (`:106-130`), `ScraperSupport.parse` at 5 000
  (`:149-163`), `HTMLExtractor.extract` at 20 000 (`:167-171`). Four things it does not pin:

  ```swift
  // MarkupDepth.swift:190-220 — skipRawText's unterminated branch returns `end`
  // every raw-text test closes the element, so this branch is never taken
  private static func skipRawText<Bytes: RandomAccessCollection>(…) -> Int { … return end }
  ```

  - `skipRawText`'s unterminated-element path (returns `end`): all raw-text fixtures close the tag.
  - The non-contiguous-UTF-8 fallback in `exceedsLimit` (`:60-66`, the `Array(html.utf8)` copy); a
    byte-for-byte `ArraySlice` scan is directly callable because `scan` is internal.
  - `SearchError.markupDepthExceeded`'s projection: `category == .malformedResponse`
    (`SearchError.swift:71`) and its `safeDescription` (`:138`). `MarkupDepthTests` asserts error
    *equality* at the source, never the category/message a tool result shows.
  - The deep-markup path through the MCP tool surface: no test fetches a deeply nested page via
    `web_open` (or `DuckDuckGoProvider` through `ToolHandlers`) and asserts an `isError` result
    instead of process death; `ToolHandlers.errorMessage` falls to its `default:` arm for this case
    (`ToolHandlers.swift:393-394`).
- expected-correct: Add an unterminated `<script>` whose body contains thousands of `<div>` and assert
  `exceedsLimit == false` (a browser swallows the rest of the document, so it must not count);
  a direct `MarkupDepth.scan(ArraySlice(...), limit:)`/`exceedsLimit` test built from a non-contiguous
  UTF-8 view; `XCTAssertEqual(SearchError.markupDepthExceeded(512).category, .malformedResponse)` plus
  a `safeDescription` assertion ("nests more than"); and one stdio/`LoopbackServer` test where
  `web_open` on a 20 000-deep page returns `isError == true` with that message.
- reproducible-by: Make `skipRawText` scan its body when the close tag is missing (return `start`
  instead of `end`). The suite stays green, yet a JavaScript bundle full of `<div>` literals is then
  rejected as too deep. Change `markupDepthExceeded`'s category to `.serverError` or blank its message:
  also green, but `web_search_status` and the tool text would misreport the condition.
- confidence: certain

#### L6-5 — `maxRetryAfter` (the cap that stops a hostile `Retry-After` stalling a search) is untested
- severity: S2
- unit: `Sources/WebSearchCore/Support/HTTPClient.swift` (`send` retry branch)
- file:line: `Sources/WebSearchCore/Support/HTTPClient.swift:243`
- category: test
- evidence:

  ```swift
  // HTTPClient.swift:243-247
  let retryAfter = RetryAfter.parse(response.header("Retry-After"))
  let delay = min(
      retryAfter ?? policy.backoff(forRetryIndex: retryIndex),
      policy.maxRetryAfter
  )
  ```

  `testHonorsRetryAfterHeader` is the only test of the header and uses `"Retry-After": "1"`
  (`HTTPClientTests.swift:245-264`), where `min(1s, 5s) == 1s`. No test sends a `Retry-After` larger
  than `policy.maxRetryAfter` (5 s default, `HTTPClient.swift:147`).
- expected-correct: A loopback server that answers `429` with `Retry-After: 3600` and a client with
  `maxRetries: 1`; assert `server.requestCount == 2` and elapsed wall time below ~2 s, proving the
  delay was clamped to `policy.maxRetryAfter`. Add a symmetric assertion that a *short* value is
  honoured (already covered by the existing 1 s test).
- reproducible-by: Replace the `min(…)` with `retryAfter ?? policy.backoff(…)`. The suite stays
  green; a single hostile (or merely misconfigured) upstream that answers `429 Retry-After: 86400`
  then stalls a search for a day, holding the MCP tool call open.
- confidence: certain

#### L6-6 — `DirectHTTPFetcher`'s size cap, content-type gate, raw-text path and timeout mapping have no test
- severity: S2
- unit: `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift`
- file:line: `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:202`
- category: test
- evidence: `FetchBehaviorTests` covers only 403, 404 and a 200 `text/html` page. The other four
  failure/success branches are unreachable from the current tests:

  ```swift
  // :119-124 — non-textual content type is refused
  guard let mimeType, DirectHTTPFetcher.isTextual(mimeType, allowedPrefixes: …) else {
      throw SearchError.extractionFailed(currentURL)
  }
  // :133-141 — non-HTML textual body becomes .rawText with no title
  } else {
      let text = String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) ?? ""
      extraction = HTMLDocument.Extraction(title: nil, text: text)
  }
  // :184-186 — timeout is a fetch failure, not a provider failure
  case .timedOut:
      throw SearchError.fetchFailed(request.url, reason: "request timed out")
  // :202-204 — per-page byte cap
  if data.count > maxBytes { throw SearchError.extractionFailed(request.url) }
  ```

  `HTTPClientTests.testEnforcesResponseSizeLimit` covers `URLSessionHTTPClient`'s cap, not this
  fetcher's independent `configuration.maxFetchedPageBytes` cap.
- expected-correct: Loopback tests asserting: a `text/plain` body yields `method == .rawText`,
  `title == nil`, and the body text; an `image/png` body throws `.extractionFailed`; a page larger
  than a shrunk `maxFetchedPageBytes` throws `.extractionFailed`; a `LoopbackServer` with
  `delayMilliseconds` above a 1 s `requestTimeout` throws `.fetchFailed` with reason `request timed
  out` (and `safeDescription` names no search provider).
- reproducible-by: Delete the `data.count > maxBytes` guard, change the content-type `guard` to
  always pass, hardcode `method: .htmlExtraction`, or map `.timedOut` to `.extractionFailed`: all four
  mutations leave the suite green. `web_open` could then return a 10 MB binary as HTML text, or
  misclassify a timeout, without a failing test.
- confidence: certain

#### L6-7 — `testProvidersReceiveALargerBudgetThanTheFinalResultLimit` asserts nothing about the budget
- severity: S2
- unit: `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift`, `Sources/WebSearchCore/Search/SearchOrchestrator.swift:75-76`
- file:line: `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:674`
- category: test
- evidence: The mock receives the request and ignores it; the only assertion is the call count:

  ```swift
  // SearchOrchestratorTests.swift:676-693
  let capturing = MockSearchProvider(id: .tavily) { request in
      ProviderSearchResponse(
          provider: .tavily,
          results: [ SearchResult(title: "T", url: URL(string: "https://example.com/1")!, …) ]
      )
  }
  …
  _ = try await orchestrator.search(Fixtures.request(maxResults: 3, mode: .fast))
  // 3 requested results yields a provider budget of 6.
  // Verified indirectly: the call succeeds and the provider was invoked once.
  XCTAssertEqual(capturing.callCount, 1)
  ```

  `request` is never read, so nothing distinguishes `providerResultBudget == 6` from `== 3`, `== 1`,
  or a missing field. The test name and comment claim a property the assertions do not test.
- expected-correct: Capture the request inside the provider closure and assert
  `request.providerResultBudget == 6` (and `> request.maxResults`) for `maxResults: 3`, plus the
  clamp at the top of the range (`maxResults: 20` → budget 20, since `SearchOrchestrator.swift:75`
  is `min(20, max(maxResults * 2, maxResults))`).
- reproducible-by: Replace `let providerBudget = min(20, …)` with `request.maxResults` and delete the
  `scoped(to:)` call at `SearchOrchestrator.swift:76`. The test passes. Fusion then receives no
  surplus material to deduplicate against — the exact reason the field exists — with no red test.
- confidence: certain

#### L6-8 — `testCancellationPropagatesAsCancelled` uses an assertion that cannot fail
- severity: S2
- unit: `Tests/WebSearchCoreTests/HTTPClientTests.swift`, `Sources/WebSearchCore/Support/HTTPClient.swift`
- file:line: `Tests/WebSearchCoreTests/HTTPClientTests.swift:314`
- category: test
- evidence:

  ```swift
  // HTTPClientTests.swift:308-317
  let result = await task.result
  switch result {
  case .success:
      XCTFail("expected cancellation")
  case .failure(let error):
      XCTAssertTrue(
          error is CancellationError || (error as? HTTPError) != nil,
          "cancellation must surface as an error, got \(error)"
      )
  }
  ```

  `URLSessionHTTPClient.send` can only throw `HTTPError` (everything in `perform` is mapped to one,
  `HTTPClient.swift:302-311`) or `CancellationError` from `Task.checkCancellation`. The second
  disjunct is therefore true for **every** error the client can produce, including `.timedOut` and
  `.connectionFailed`. The test is named for cancellation but cannot distinguish it.
- expected-correct: Pin the category, not the error's existence:
  `XCTAssertEqual(error as? HTTPError, .cancelled(label: "test"))` (or unwrap with
  `guard case .cancelled`), and keep the `CancellationError` alternative only if the client is allowed
  to throw it. Assert `server.requestCount == 1` so a retry after cancellation is also excluded.
- reproducible-by: Change `HTTPError.from(urlError:)` to map `.cancelled` to `.timedOut`, or make
  `perform` throw `.timedOut` when the task is cancelled. The test still passes, so a cancellation
  regression is invisible.
- confidence: certain

#### L6-9 — `AppConfiguration.load()` and its file-vs-environment precedence have no test
- severity: S2
- unit: `Tests/WebSearchCoreTests/CoreUnitTests.swift` (`ConfigurationTests`), `Sources/WebSearchCore/Support/AppConfiguration.swift:246`
- file:line: `Tests/WebSearchCoreTests/CoreUnitTests.swift:317`
- category: test
- evidence: The test simulates precedence by merging a dictionary by hand and then calling `parse`:

  ```swift
  // CoreUnitTests.swift:317-322
  func testEnvironmentOverridesConfigFile() {
      // Simulated by merging manually: file values first, environment second.
      var merged = AppConfiguration.parseDotEnv("SEARCH_MAX_RESULTS=3")
      merged["SEARCH_MAX_RESULTS"] = "11"
      XCTAssertEqual(AppConfiguration.parse(merged).defaultMaxResults, 11)
  }
  ```

  It asserts a value the test itself just wrote, and never calls `AppConfiguration.load` (the only
  production entry point, used by `main.swift:16` and `ProviderProbe.buildConfiguration`). `load`'s
  file branch (`:252-261`), the missing-file fallback, and the `SEARCH_CONFIG_FILE` lookup are all
  untested; `grep -rn "AppConfiguration.load" Tests/` returns nothing.
- expected-correct: Write a temporary dotenv with `SEARCH_MAX_RESULTS=3` and
  `TAVILY_API_KEY=file-key`, call `load(environment: ["SEARCH_MAX_RESULTS": "11"], configFileURL: url)`,
  and assert the env value wins while the file-only key is applied; then call it with a non-existent
  `SEARCH_CONFIG_FILE` and assert defaults rather than a crash. This is also the automated check that
  the documented "environment always wins" claim (`AppConfiguration.swift:5-7`) holds.
- reproducible-by: Swap the two loops in `load` (`AppConfiguration.swift:257-268`) so the config file
  overwrites the environment. The suite stays green: an operator's explicit `SEARCH_MAX_RESULTS=20`
  would be silently overridden by a stale `config.env`.
- confidence: certain

#### L6-10 — Tool-argument validation boundaries are untested; only three malformed cases exist
- severity: S2
- unit: `Sources/SwiftWebSearchMCP/ToolSchemas.swift` (`ToolArguments`), `Sources/SwiftWebSearchMCP/ToolHandlers.swift`
- file:line: `Sources/SwiftWebSearchMCP/ToolSchemas.swift:477`
- category: test
- evidence: `testMalformedArgumentsProduceAnErrorResultNotAProtocolFailure`
  (`StdioServerTests.swift:754-794`) covers exactly: missing `query`, `max_results: "not-a-number"`,
  and an unknown tool name. Untested guards:

  ```swift
  // ToolSchemas.swift:477-489
  guard elements.count <= maxItems else {
      throw ArgumentError("`\(name)` accepts at most \(maxItems) entries")
  }
  …
  guard let text = element.stringValue else {
      throw ArgumentError("`\(name)` must contain only strings")
  }
  // ToolSchemas.swift:497-499 (recency / mode)
  guard let parsed = T(rawValue: text.lowercased()) else {
      throw ArgumentError("`\(name)` must be one of the documented values")
  }
  // ToolSchemas.swift:456-462 — numeric strings are tolerated
  if let text = value.stringValue, let integer = Int(text) { return integer }
  ```

  plus the clamps `max_results` (`ToolHandlers.swift:37`, `min(max(1, …), 20)`), `max_characters`
  (`ToolHandlers.swift:123`, `min(max(1_000, …), 50_000)`) and the invalid-`locale` rejection
  (`ToolHandlers.swift:44-46`). No test sends `include_domains` with 21 entries, a non-string array
  element, `recency: "sometimes"`, `mode: "deep"`, `locale: "not a locale"`, `max_results: 0` or `50`,
  or a numeric string for `max_results`.
- expected-correct: A table-driven stdio test that sends each malformed shape and asserts
  `result.isError == true` with a message naming the offending argument, plus boundary clamps:
  `max_results: 50` → `structuredContent.results` never exceeds 20; `max_results: 0` → 1;
  `max_characters: 10` → the fetch runs with 1000; `include_domains` with 20 entries is accepted and
  21 is refused. This is the layer that prevents untrusted client input reaching provider URLs.
- reproducible-by: Delete the `elements.count <= maxItems` guard (`ToolSchemas.swift:477`). The suite
  is green; a client can send 10 000 domains, which are then interpolated into provider query strings.
  Likewise deleting the `enumValue` guard makes an unknown `mode` fall through to a default instead of
  an error.
- confidence: certain

#### L6-11 — `WebFetcher`'s Jina-failure fallback and error propagation are untested
- severity: S2
- unit: `Sources/WebSearchCore/Fetch/WebFetcher.swift`, `Tests/WebSearchCoreTests/FetchFallbackTests.swift`
- file:line: `Sources/WebSearchCore/Fetch/WebFetcher.swift:135`
- category: test
- evidence:

  ```swift
  // WebFetcher.swift:135-149
  } catch {
      log.debug("Jina Reader fallback failed", metadata: ["error": "\(type(of: error))"])
      guard let result = directResult else {
          throw directError ?? SearchError.extractionFailed(request.url)
      }
      var finalized = result
      finalized.warnings.append(
          "Jina Reader fallback was unavailable; returned native extraction."
      )
      …
  }
  ```

  `FetchFallbackTests` has a reader-disabled test and a reader-success test but **no** test where the
  reader throws; the same is true of the `guard let result = directResult` propagation at `:107-110`.
  A `MockHTTPClient` with no handler for `jina.reader` throws `HTTPError.transportFailure`
  (`TestSupport.swift:154-159`), which is exactly the missing input.
- expected-correct: One test where the direct fetch returns thin native HTML and the Jina mock throws:
  assert the result is the native extraction with the warning `Jina Reader fallback was unavailable;
  returned native extraction.` and `method == .htmlExtraction`. A second where the direct fetch fails
  (404) and the reader is disabled or also fails: assert the thrown error is the **direct** error
  (`fetchFailed`/`extractionFailed` for that URL) rather than a generic extraction failure.
- reproducible-by: Replace the catch body with `throw error`, or the `guard let result = directResult`
  fallback with `throw SearchError.extractionFailed(request.url)`. The suite stays green, so a reader
  outage could either fail a fetch that native extraction could have served or hide the real cause of
  a failure behind a generic message.
- confidence: certain

#### L6-12 — `ResultNormalizer`'s URL repair and text cleaning are untested
- severity: S2
- unit: `Sources/WebSearchCore/Search/ResultNormalizer.swift`
- file:line: `Sources/WebSearchCore/Search/ResultNormalizer.swift:68`
- category: test
- evidence:

  ```swift
  // ResultNormalizer.swift:78-82 — providers return schemeless and protocol-relative links
  if candidate.hasPrefix("//") {
      candidate = "https:" + candidate
  } else if !candidate.contains("://") {
      candidate = "https://" + candidate
  }
  // :130-145 stripHTMLTags, :147-159 decodeCommonEntities
  ```

  No test calls `normalizedURL`, `cleanText`, `stripHTMLTags`, `decodeCommonEntities` or
  `displayDomain` (the last is dead — `grep -rn "displayDomain" Sources/` matches only its
  definition). Every fixture in `ProviderContractTests`/`FusionAndReliabilityTests` uses an absolute
  `https://` URL with no markup or entities, so both repair branches and both cleaning helpers are
  never executed. `providerResultBudget`'s effect on normalization is likewise untested.
- expected-correct: A `ResultNormalizerTests` asserting: `"//example.com/x"` →
  `https://example.com/x`; `"example.com/x"` → `https://example.com/x`; a URL with embedded control
  characters is repaired or rejected, not passed to `URL(string:)`; `"<b>bold</b> text"` →
  `"bold text"`; `"a &amp; b &nbsp;c"` → `"a & b c"`; a non-http scheme (`ftp://`) is dropped; and
  `make(...)` returns nil for an empty/hostless URL and for an intra-response duplicate (the
  `seenKeys` contract).
- reproducible-by: Delete the `else if !candidate.contains("://")` branch (`:80-82`) or make
  `cleanText` return its input unchanged. The suite is green; a provider that emits schemeless links
  silently returns zero results, and snippets containing `<b>`/`&amp;` reach model context as raw
  markup.
- confidence: certain

#### L6-13 — Timing-dependent tests: real sleeps, real clocks and an upper-bound wall-clock assertion
- severity: S2
- unit: `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift`, `HTTPClientTests.swift`, `HTTPTransportTests.swift`
- file:line: `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:500`
- category: test
- evidence:

  ```swift
  // SearchOrchestratorTests.swift:493-500 — comment describes a detached task that no longer exists
  for _ in 0..<3 {
      await health.recordFailure(.brave, failure: ProviderFailure(…))
  }
  // The state update happens in a detached task inside recordFailure.
  try await Task.sleep(for: .milliseconds(60))
  ```

  `ProviderHealth.recordFailure` now `await`s the breaker synchronously
  (`ProviderHealth.swift:195-211`, and `FusionAndReliabilityTests.swift:893-908` asserts exactly
  that), so the 60 ms sleep is dead and the comment misdescribes the implementation — a reader who
  trusts it may reintroduce the race. Further real-time couplings:

  ```swift
  // SearchOrchestratorTests.swift:382-410 — real clock on purpose; waits out a real refill
  let health = ProviderHealth()
  await health.register(.tavily, ratePolicy: RateLimiter.Policy(burst: 1, requestsPerMinute: 600))
  // :539-545 — wall-clock upper bound with a 6x margin
  let started = DispatchTime.now().uptimeNanoseconds
  …
  XCTAssertLessThan(elapsedMilliseconds, 2_000, "the time budget must bound the call")
  // HTTPClientTests.swift:252-263 — real 1 s wait asserted only as a lower bound
  // HTTPClientTests.swift:305 — Task.sleep(200 ms) then cancel
  // HTTPTransportTests.swift:236-247 — readiness poll: up to 200 × usleep(50 ms) = 10 s
  ```

  `FetchFallbackTests` even documents the rule the suite breaks (`:30`): "no test in this suite may
  sleep for more than 50 ms". The PTY harness has the same class of assertion
  (`scripts/monitor_tty_smoke.py`, `time.monotonic() - started < 0.9` after pressing `r`).
- expected-correct: Delete the dead 60 ms sleep and its stale comment (the awaited calls are the
  synchronisation). For the throttle test, keep a real clock only where a real refill is the point,
  but assert the observable contract (`provider.callCount == 1`, no failures) without depending on
  scheduler latency, or drive it with a `TestClock` that advances the limiter and stub the wait. For
  the budget test, assert the sentinel failure is reported (`providersFailed` contains the timeout
  category) and that the responsive provider's results survive, and either drop the 2 s upper bound or
  raise it to a CI-tolerant value; pin the timeout path deterministically with `TestClock` where
  possible. Reuse one "no sleeps longer than N ms" assertion policy across files so the stated rule is
  true.
- reproducible-by: Run the suite on a loaded CI runner. `testProviderThatHangsIsCutOffByTheTimeBudget`
  can exceed 2 000 ms from scheduling alone (the budget is 300 ms but the fan-out, fusion and assertion
  overhead share the measured interval), and the PTY `r` refresh can exceed 0.9 s — both produce the
  classic "passes locally, fails in CI" outcome. The dead sleep also means a future refactor can
  reintroduce the detached-task race with the comment still claiming it is handled.
- confidence: likely

#### L6-14 — `testStatusCountsSuccessesAndFailures` never observes a failure
- severity: S3
- unit: `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift`, `Sources/WebSearchCore/Search/SearchOrchestrator.swift` (`status()`), `ProviderHealth.swift`
- file:line: `Tests/WebSearchCoreTests/SearchOrchestratorTests.swift:716`
- category: test
- evidence:

  ```swift
  // SearchOrchestratorTests.swift:716-730
  let good = MockSearchProvider.returning(.tavily, results: [("T", "https://t.example.com/1", nil)])
  let bad = MockSearchProvider.failing(.brave, with: .providerUnavailable(.brave))
  let (orchestrator, _, _) = makeOrchestrator(providers: [good, bad])
  // `fast` uses exactly one provider, keeping the counters unambiguous.
  _ = try await orchestrator.search(Fixtures.request(mode: .fast))
  let states = await orchestrator.status()
  …
  XCTAssertEqual(tavily?.successes, 1)
  XCTAssertEqual(brave?.failures, 0)
  ```

  Because `fast` selects only Tavily, `brave` is never called: `XCTAssertEqual(brave?.failures, 0)` is
  true whether or not `ProviderHealth.recordFailure` increments anything, and the failing provider's
  classification is never observed through `status()`. (`ProviderHealthTests` does assert a raw
  failure count, so `status()`'s projection of it is what goes unverified.)
- expected-correct: Run a `balanced` search where the failing provider is selected (order
  `[.tavily, .brave]`), then assert `brave?.failures == 1`,
  `brave?.lastErrorCategory == .serverError`, `brave?.lastError != nil`, and
  `tavily?.successes == 1`; assert `status` is `.ready`/`.notConfigured` appropriately per
  `ProviderHealth.state(for:configured:enabled:)`.
- reproducible-by: Make `SearchOrchestrator.status()` pass `configured: true` always, or stop
  forwarding `lastErrorCategory`; the test passes. A dashboard/status regression that hides the last
  failure category would not be caught at the orchestrator level.
- confidence: certain

#### L6-15 — The monitor's setup-hint test asserts a string the test itself constructed
- severity: S3
- unit: `Tests/WebSearchCoreTests/MonitorTests.swift`, `Sources/WebSearchCore/Monitor/ProviderProbe.swift:50`
- file:line: `Tests/WebSearchCoreTests/MonitorTests.swift:101`
- category: test
- evidence: The fixture hardcodes one hint for every provider:

  ```swift
  // MonitorTests.swift:101
  var status = ProviderStatus.pending(provider: id, configured: state != .notConfigured, hint: "TAVILY_API_KEY")
  …
  // MonitorTests.swift:324-333
  func testUnconfiguredProviderShowsItsSetupHint() {
      let lines = Renderer(useColour: false).render(
          model(providers: [ provider(.brave, state: .notConfigured, probes: 0, successes: 0) ]),
          …
      ).joined(separator: "\n")
      XCTAssertTrue(lines.contains("TAVILY_API_KEY"), "the hint should name the variable")
  }
  ```

  A Brave provider is given Tavily's hint by the test fixture and then the test asserts Tavily's
  variable appears. The real hint mapping (`ProviderProbe.setupHint`, `:50-61`) is genuinely tested by
  `ProviderProbeTests.testSetupHintNamesTheRightVariableForEveryProvider`, so this test adds no
  coverage of it.
- expected-correct: Either drop the hint assertion and assert only that the rendered row of an
  unconfigured provider contains its `setupHint` field (`provider(.brave, …).setupHint`), or build
  the fixture with `ProviderProbe(registry:configuration:).setupHint(for: .brave)` and assert
  `"BRAVE_SEARCH_API_KEY"` so the test pins the real mapping through the renderer.
- reproducible-by: Change `ProviderProbe.setupHint(for:)` to return `"TAVILY_API_KEY"` for every
  provider: `MonitorTests` still passes (it never calls the function), and the dashboard would show a
  useless hint for seven providers.
- confidence: certain

#### L6-16 — `HTTPStatusMapper.map`'s HTTPError branches and `validate`'s default/422 statuses are untested
- severity: S3
- unit: `Sources/WebSearchCore/Providers/HTTPStatusMapper.swift`
- file:line: `Sources/WebSearchCore/Providers/HTTPStatusMapper.swift:46`
- category: test
- evidence:

  ```swift
  // HTTPStatusMapper.swift:49-61 — no test reaches the HTTPError arms
  if let httpError = error as? HTTPError {
      switch httpError {
      case .timedOut: return .timeout(provider)
      case .cancelled: return .networkFailure(provider, "cancelled")
      case .connectionFailed(_, let reason), .transportFailure(_, let reason):
          return .networkFailure(provider, reason)
      case .responseTooLarge: return .malformedResponse(provider)
      case .invalidURL(let detail): return .unsupportedRequest(provider, detail)
      }
  }
  // :29-42 — validate's 422 branch and its default (e.g. 404) branch are not covered
  ```

  The only direct `map` test passes a `URLError` (`ErrorReportingTests.swift:312`), so the
  `HTTPError` switch — which is how a real transport timeout/`responseTooLarge` is classified for a
  provider — and the `SearchError` passthrough and generic fallback are unverified.
  `testHTTPStatusMapperClassifiesCorrectly` covers 401/403/429/400/503/200 but not 422 or an
  unmapped status such as 404/418.
- expected-correct: Table-driven tests over each `HTTPError` case asserting the mapped `SearchError`
  category and that `safeDescription` carries no request URL; plus `validate` for a 422
  (`unsupportedRequest`) and a 404/418 (`unsupportedRequest` via the default arm) and a 3xx
  (non-success, unsupported).
- reproducible-by: Change `case .timedOut: return .timeout(provider)` to
  `.networkFailure(provider, "timeout")`. The suite is green; a provider's timeouts would be
  classified as network failures in `web_search_status` and in breaker accounting.
- confidence: certain

#### L6-17 — `AnswerSynthesizer`'s completion edge cases, token usage and locale prompt are untested
- severity: S3
- unit: `Sources/WebSearchCore/Search/AnswerSynthesizer.swift`, `Tests/WebSearchCoreTests/AnswerSynthesizerTests.swift`
- file:line: `Sources/WebSearchCore/Search/AnswerSynthesizer.swift:349`
- category: test
- evidence: The synthesizer's tests are otherwise strong (empty content, `INSUFFICIENT`, citation
  stripping/renumbering, auth/429/malformed/vendor error, credential placement, thinking-mode retry).
  These branches are not covered:

  ```swift
  // :349-351 — a 200 body with no choices at all
  guard let choice = decoded.choices?.first else {
      throw SearchError.synthesisFailed("The synthesis model returned no choices.")
  }
  // :358-359 — token usage is decoded but never asserted
  inputTokens: decoded.usage?.promptTokens,
  outputTokens: decoded.usage?.completionTokens,
  // :425-431 — the locale instruction, reached only when synthesize(locale:) is passed
  if let locale, !locale.isEmpty {
      question += "\nAnswer in the language implied by locale \(locale)."
  }
  // :525-541 — describe()'s URLError arms (timedOut/cancelled/cannotConnectToHost/…)
  ```

  `testSendsGroundingPromptWithNumberedResults` calls `synthesize(query:results:)` with no locale, and
  no test decodes a `{"choices":[]}` body or asserts `answer.inputTokens`/`outputTokens`. Cancellation
  during synthesis is likewise unpinned (`describe(CancellationError)` is never reached).
- expected-correct: Add: a `{"choices":[]}` body → `synthesisFailed` mentioning "no choices"; a
  completion with `usage` → `answer.inputTokens == 100`, `answer.outputTokens == 20`;
  `synthesize(query:results:locale:"de-DE")` → the user message contains
  "Answer in the language implied by locale de-DE"; and unit assertions for
  `AnswerSynthesizer.describe(URLError(.timedOut))` / `.cannotConnectToHost` / `CancellationError`
  mapping to the curated strings.
- reproducible-by: Delete the `guard let choice` and return an empty `Completion`, or drop the locale
  line. The suite stays green; a provider answering 200 with an empty `choices` array surfaces as
  "returned no answer (finish reason: unknown)" instead of the accurate message, and locale-aware
  answering silently disappears.
- confidence: certain

#### L6-18 — The `Monitor` actor's refresh/counting/warning logic has no Swift test
- severity: S3
- unit: `Sources/MCPSMonitor/main.swift` (`Monitor`), `Tests/MCPSMonitorTests/MonitorOptionsTests.swift`
- file:line: `Sources/MCPSMonitor/main.swift:337`
- category: test
- evidence: The sole MCPSMonitor test file tests only `Options.parse` (`MonitorOptionsTests.swift`,
  171 lines). The actor that owns the dashboard's state is untested in-process:

  ```swift
  // main.swift:337-378 — refresh, probe gating, counter folding
  func refresh(forceProbeProviders: Bool) async -> MonitorModel { … }
  // main.swift:412-442 — operator warnings (down nodes, engine failures, missing credentials)
  private func buildWarnings(_ model: MonitorModel) -> [String] { … }
  // main.swift:322-331 — short-slice sleep / refresh request
  func waitForNextCycle(_ interval: Duration) async { … }
  ```

  `Monitor` is reachable from `MCPSMonitorTests` (the target depends on the executable,
  `Package.swift:80-84`), so this is a target-membership choice, not a SwiftPM limitation. The PTY
  harness (`scripts/monitor_tty_smoke.py`) covers interactive rendering and key handling, but its
  assertions are about frames and the `unavailable:` column — not `buildWarnings`' aggregation, the
  `probedProviders`/`hasProbedBefore` gating, or the counter folding on `NodeStatus`/`ProviderStatus`.
- expected-correct: Actor tests that call `refresh(forceProbeProviders:)` with a stub `HTTPClient`
  and assert: the first refresh probes, a second with `probeProviders: false` does not; a node result
  folds into `checks`/`failures`; two unavailable engines across nodes produce the
  `engine '…' unavailable on N node(s)` warning and a down node produces the unreachable warning
  (`main.swift:412-442`).
- reproducible-by: Change `buildWarnings` to return `[]`, or invert
  `Options.shouldProbeProviders`' use in `refresh` so it never probes after the first frame. The
  Swift suite is green and the PTY harness still passes (it presses `p`, which forces a probe).
- confidence: certain

#### L6-19 — No test ties the Swift test harnesses to the Python harnesses, and two scripts are untested entirely
- severity: S3
- unit: `Tests/WebSearchCoreTests/TestSupport.swift`, `scripts/*.py`
- file:line: `Tests/WebSearchCoreTests/TestSupport.swift:12`
- category: test
- evidence: The scrub list is duplicated by hand:

  ```swift
  // TestSupport.swift:12-16
  /// The provider environment scrub list lives here so the two Swift server harnesses
  /// cannot drift from each other *or* from `scripts/mcp_smoke.py`, which mirrors it.
  /// … When this list changes, update the Python tuple in the same commit.
  static let providerEnvironmentVariables = [ …18 entries… ]
  ```

  ```python
  # scripts/mcp_smoke.py:45-64
  SCRUBBED_VARIABLES = ( …same 18 entries… )
  ```

  They match today, but no test or CI step enforces it (this is the test-level half of ledger A12).
  Separately, `scripts/soak.py` (490 lines) and `scripts/searxng_health.py` (131 lines) are referenced
  only by docs (`README.md`, `.git/mcps-wiki/*`) and are **not** invoked by
  `.github/workflows/ci.yml`; neither has a test of its own. There is also no test that drives the two
  built executables (`SwiftWebSearchMCP` and `mcps-mon`) against the same stub endpoint and compares
  what they report, even though that contract is the stated reason `ProviderProbe.buildRegistry`
  delegates to `SearchPipelineFactory` (`ProviderProbe.swift:35`).
- expected-correct: A test (or CI step) that reads `scripts/mcp_smoke.py`, extracts the
  `SCRUBBED_VARIABLES` tuple and asserts set equality with
  `ServerTestSupport.providerEnvironmentVariables`, failing with the diff. Add a CI invocation of
  `soak.py --queries 1` against a loopback stub (or a pytest-style test for the script's argument
  parsing and credential-leak scan) and a unit test for `searxng_health.probe`'s status classification
  against a stub HTTP server, so both harnesses cannot rot silently.
- reproducible-by: Remove `DEEPSEEK_API_KEY` from `SCRUBBED_VARIABLES` in `mcp_smoke.py`: all Swift
  tests pass, and the Python smoke run then inherits an ambient synthesis key (CI's placeholder is
  caught by `isUsableKey`, but a developer machine's real key would make the harness issue a live
  request). Likewise, break `soak.py`'s `--providers` filter or `searxng_health.py`'s exit codes and
  nothing fails.
- confidence: certain

#### L6-20 — `ToolOutputFormatter`'s fallback and diagnostic branches are untested
- severity: S3
- unit: `Sources/SwiftWebSearchMCP/ToolSchemas.swift` (`ToolOutputFormatter`)
- file:line: `Sources/SwiftWebSearchMCP/ToolSchemas.swift:526`
- category: test
- evidence: The stdio test asserts only the happy rendering of two results
  (`StdioServerTests.swift:424-429`). Untested branches in the formatter:

  ```swift
  // ToolSchemas.swift:529-531
  if response.results.isEmpty { lines.append("No results.") }
  // :536-541 — the 400-character snippet clip and its ellipsis
  let clipped = snippet.count > maximumSnippet ? String(snippet.prefix(maximumSnippet)) + "…" : snippet
  // :550-563 — unavailable providers / warnings / cache notes
  // :837-851 — statusText: request counters, non-closed circuit, note, last error
  ```

  No test calls `searchText`/`statusText` directly (the executable cannot be imported), and no
  subprocess test produces an empty result set, an over-400-character snippet, a failed provider in
  the text block, or a status entry with a non-closed circuit and a last error.
- expected-correct: Through stdio: a search through a stub that returns `{"results":[]}` (assert the
  text contains "No results."); a stub result with a 500-character snippet (assert the text contains
  the ellipsis and no more than ~400 characters of snippet); a search that also fails one provider
  (assert the text lists it under "Unavailable providers"); a status call after a provider failure
  (assert the text includes `failed=` and `last error:`).
- reproducible-by: Delete the snippet-clipping expression so full snippets are always emitted, or drop
  the `results.isEmpty` branch. The suite stays green; `web_search` would exceed the documented compact
  text contract and return an empty text block for a legitimately empty result set.
- confidence: certain

#### L6-21 — `HTTPMCPHost`'s startup-failure and internal-error paths are untested
- severity: S3
- unit: `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift`, `Tests/WebSearchCoreTests/HTTPTransportTests.swift`
- file:line: `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:79`
- category: test
- evidence: `HTTPTransportTests` covers `/health`, initialize, SSE `tools/list`, missing session,
  cross-origin, oversized body, unknown path and non-POST — a strong negative set. Not covered:

  ```swift
  // HTTPMCPHost.swift:79-85 — bind failure becomes HTTPHostError.bindFailed
  } catch {
      throw HTTPHostError.bindFailed(host: configuration.host, port: configuration.port,
                                     reason: String(describing: error))
  }
  // :211-225 — the dispatch failure path writes a 500 "Internal error"
  case .failure(let error):
      log.error("HTTP request handling failed", …)
      handler.respond(to: channel, status: .internalServerError, …)
  // :445-449 — isLoopbackOrigin accepts localhost/::1/127.x
  ```

  The cross-origin test only checks a foreign origin and `127.0.0.1` (`:410-439`), so the `localhost` /
  `::1` / `127.x` acceptance arms and the non-loopback startup warning (`:97-103`) are unexercised.
  `HTTPHostError.bindFailed`'s `description` is never asserted.
- expected-correct: A test that binds an ephemeral port with a plain socket and then starts the
  server on that exact port, asserting the process exits with the documented error (or, in-process
  where possible, that `.bindFailed` is thrown with host/port in the description); origin tests for
  `http://localhost:<port>` and `http://[::1]:<port>`; and a unit-level assertion of
  `HTTPHostError.bindFailed(host:port:reason:).description`.
- reproducible-by: Delete the `catch` around `bootstrap.bind` and let the raw NIO error escape, or
  narrow `isLoopbackOrigin` to `127.0.0.1` only. The suite stays green; a port-in-use failure would
  surface as an unhelpful raw error and a `localhost`-origin client (a common local tool) would be
  rejected as cross-origin.
- confidence: certain
