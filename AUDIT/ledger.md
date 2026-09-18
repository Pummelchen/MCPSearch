# Audit ledger — MCPSearch

**Generated from `AUDIT/ledger.json` by `AUDIT/render_ledger.py`. Do not edit this
file** —
edit the JSON and re-render, so the two cannot disagree (§8, §9).

- Repository: `MCPSearch`
- Branch: `audit/2026-09-18` (from `992a27f`)
- Primary host: `Node1`; verification host: `macbook-ab.local`

## Counts

**total 54 — done 45 · open 6 · blocked 3**

| Severity | Total | Done | Open | Blocked |
| --- | --- | --- | --- | --- |
| S0 | 4 | 2 | 0 | 2 |
| S1 | 30 | 27 | 2 | 1 |
| S2 | 16 | 14 | 2 | 0 |
| S3 | 4 | 2 | 2 | 0 |

Status tally: OPEN 4, PROGRESS 2, DONE 45, BLOCKED 3

## Tasks

| id | sev | tier | status | title |
| --- | --- | --- | --- | --- |
| A0001 | S0 | A | BLOCKED | A live-looking Tavily credential prefix is in public git history and cannot be un-published |
| A0007 | S0 | A | DONE | /health returns a hardcoded ok, so the production health surface is wired to nothing |
| A0011 | S0 | A | BLOCKED | The markup-depth guard is bypassable, so crafted HTML reaches a recursive parse and kills the process |
| A0045 | S0 | A | DONE | SearXNG answers are decoded as [String] but emitted as objects, so an answering query discards every result |
| A0002 | S1 | A | DONE | Warnings-as-errors is not in the build config, so the Swift standard is not in force at the build level |
| A0003 | S1 | A | DONE | SwiftLint cannot reject a force-unwrap, so the §1 Swift standard proof fails |
| A0004 | S1 | A | DONE | Ruff does not select S101, so `assert` used for validation is unchecked |
| A0005 | S1 | A | PROGRESS | The secret-scan delegation is unproven: gitleaks is blind to the credential pattern this repository actually leaked |
| A0008 | S1 | C | DONE | The only check that consumes /health reads the status code and never the body, so it cannot fail |
| A0009 | S1 | A | DONE | The HTTP server installs no signal handler, and its graceful-shutdown helper is dead code |
| A0012 | S1 | A | DONE | The response charset is discarded, so non-UTF-8 pages are silently decoded as Latin-1 |
| A0013 | S1 | A | DONE | Credentials in the target URL's query or fragment are forwarded to the third-party reader |
| A0014 | S1 | A | DONE | An empty extraction is returned as a success, discarding the real failure reason |
| A0015 | S1 | A | DONE | Cancellation is swallowed on the reader path, so a cancelled fetch can return a stale success |
| A0017 | S1 | A | BLOCKED | DNS-rebinding TOCTOU between validation and connect (documented, no local fix) |
| A0018 | S1 | A | DONE | The soak's stdio read has no timeout, so one unanswered query hangs the whole run |
| A0019 | S1 | A | DONE | The child's stderr pipe is not drained until exit, which deadlocks against the stdout read |
| A0020 | S1 | A | DONE | The credential-leak scan is stderr-only and only runs on the fully successful path |
| A0021 | S1 | A | DONE | A non-JSON stdout line is embedded in a raised exception, reaching an unscanned traceback |
| A0028 | S1 | A | DONE | The HTTP session registry is unbounded, so an unauthenticated client can grow it without limit |
| A0029 | S1 | A | PROGRESS | A disconnected SSE client leaks a suspended relay task and wedges the session |
| A0030 | S1 | A | DONE | A cancelled provider request is recorded as a transient failure and can open a circuit breaker |
| A0031 | S1 | A | DONE | A claimed half-open probe is never released when the local rate limiter denies, wedging the breaker |
| A0032 | S1 | A | DONE | Length-omitted results enter the fenced prompt unsanitised, so a page title can close the untrusted-data fence |
| A0035 | S1 | A | DONE | The mandatory-SearXNG proof passes on an instance that returns zero results |
| A0036 | S1 | A | DONE | The end-to-end gate accepts a JSON-RPC error reply as success and never asserts the result count |
| A0037 | S1 | A | DONE | The generated SearXNG secret is passed as a command-line argument, where ps can read it |
| A0038 | S1 | A | DONE | `|| true` swallows a grep error and the truncated staging file then replaces config.env, dropping every API key |
| A0041 | S1 | A | DONE | The release-notes gate names NOT_CHECKED in its failure message but never checks for it |
| A0046 | S1 | A | DONE | Include and exclude domains are space-joined but Mojeek documents comma separation, so the filters never apply |
| A0047 | S1 | A | DONE | Bot-challenge markers are substring-matched against the whole page, so ordinary queries are discarded as challenges |
| A0048 | S1 | A | DONE | Cancellation is mapped to a transient network failure, so a caller cancel is charged to the provider's breaker |
| A0049 | S1 | A | DONE | A handshake that was assigned a session id and then failed leaves sessionID set, so initialization is never retried |
| A0050 | S1 | A | DONE | URL query construction drops '+', so queries containing it are corrupted |
| A0006 | S2 | A | DONE | Validation is written as `assert`, which python -O strips |
| A0010 | S2 | A | DONE | Installing overwrites the previous binary in place with no rollback path |
| A0016 | S2 | A | OPEN | An over-cap transfer may keep streaming after the cap is hit (UNSURE) |
| A0022 | S2 | C | DONE | The PTY master and slave fds leak when the spawn raises |
| A0023 | S2 | C | DONE | A failed signal case leaks the stub's socket and thread |
| A0024 | S2 | C | DONE | Per-instance stub state lives on the handler class, so two concurrent stubs would share it |
| A0025 | S2 | C | DONE | The test depends on the developer's ambient config.env and contradicts the function it tests |
| A0026 | S2 | C | DONE | No read timeout, and the early-close path blocks on stderr of a possibly-live child |
| A0033 | S2 | A | DONE | A rejected URL-valued setting is echoed verbatim into a diagnostic that is logged, contradicting the type's own contract |
| A0034 | S2 | A | DONE | A repeated name in SEARCH_PROVIDER_ORDER is not deduplicated, so one provider can vote twice |
| A0039 | S2 | A | DONE | --bind is accepted and silently dropped by the docker method |
| A0040 | S2 | A | DONE | The documented invocation puts the sudo password on a command line and into the child environment |
| A0042 | S2 | A | DONE | `rm -rf $STAGE/$VERSION` runs even after the identity gate failed, and VERSION is never validated in this script |
| A0043 | S2 | A | DONE | The test-suite count is reported as PASS without checking that it parsed |
| A0044 | S2 | A | DONE | `--dry-run` creates the SearXNG directory, so it does change the filesystem |
| A0051 | S2 | A | OPEN | Mojeek timestamp is read but never requested, so publishedAt is always nil (UNSURE) |
| A0027 | S3 | C | OPEN | A lost bind race abandons the exited child unreaped |
| A0052 | S3 | C | DONE | The documented test count is stale after A0045 added three tests |
| A0053 | S3 | A | OPEN | /health readiness reflects configuration, not reachability |
| A0054 | S3 | C | DONE | The documented test count drifted from the suite as the audit added tests |

---

### A0001 — A live-looking Tavily credential prefix is in public git history and cannot be un-published

- **Severity / tier / status:** S0 / A / BLOCKED
- **Location:** `Tests/WebSearchCoreTests/LiveProviderTests.swift (historical blob at 1f68c23^)`
- **Category:** security/secret-exposure
- **Host:** Node1
- **Discovered by:** L0 secret scan + the repository's own release notes for 1.2.0
- **Evidence before:** gitleaks detect --log-opts=--all reports 0 findings, but the blob at 1f68c23^ contains six tvly-prefixed literals (47, 44, 41, 26, 19, 19 chars). The 1.2.0 release notes already instruct the owner to rotate that key. History is immutable under §0 and the repository is public.
- **BLOCKED:** Credential rotation is forbidden to this audit (§0: never touch live runtime systems, never rotate credentials). Owner: repository owner (Pummelchen). Options for the human: (1) rotate the Tavily key in the vendor console and update config.env on all five machines; (2) if the key is already revoked, record that here and close. Trying history rewrite was rejected: §0 forbids rewriting history, and the repository is already public so a rewrite would not un-disclose it.

### A0007 — /health returns a hardcoded ok, so the production health surface is wired to nothing

- **Severity / tier / status:** S0 / A / DONE
- **Location:** `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:537-542`
- **Category:** facade/ops
- **Host:** Node1
- **Discovered by:** L7 ops + §5 facade hunt (subagent, verified by reading the handler at 537-542)
- **Evidence before:** The GET/HEAD /health branch returns a literal body: Data(#"{"status":"ok"}"#.utf8) with status .ok. It consults neither the MCP server, nor the provider registry, nor the circuit breakers, nor the local SearXNG. main.swift advertises the endpoint and README/AGENTS document it as the health check, so an operator or supervisor reading it learns nothing about whether search works. §5: a hardcoded success return on a production path. Re-classified S1 -> S0: §5 says a production-path facade is S0, and a hardcoded success return on the documented health endpoint is one.
- **Fix:** `HTTPMCPHost` takes a `HealthSource` closure and serves a body built from it, answering 503 when the report is not ready; `main.swift` supplies a source reading the live registry (version from VERSION, provider totals and configured count).
- **Evidence after:** With the source stashed the new test failed on exactly the facade: XCTAssertEqual failed ("nil") is not equal to ("Optional(\"1.2.0\")") and an XCTUnwrap failed for the missing integer count. With the fix it passes, asserting the version equals BuildVersion.value and that the counts parse and are consistent. Full suite 596 tests (554 + 42), 6 skipped, 0 failures, 0 warnings; swift-format --strict and swiftlint --strict both exit 0.
- **Commit:** `f4028ba`

### A0011 — The markup-depth guard is bypassable, so crafted HTML reaches a recursive parse and kills the process

- **Severity / tier / status:** S0 / A / BLOCKED
- **Location:** `Sources/WebSearchCore/Fetch/MarkupDepth.swift:114-115,137`
- **Category:** security/dos
- **Host:** Node1
- **Discovered by:** Fetch tier A manual review (subagent), with the SwiftSoup internals cited at file:line; static verification pending
- **Evidence before:** exceedsLimit counts every closing tag as closing one level (depth > 0 ? depth - 1 : 0) and treats trailing '/>' as self-closing. Neither matches SwiftSoup: a closing tag with no matching open element is ignored (or inserts an empty <p>), and `<div foo=/>` gives '/' to the attribute value rather than setting the self-closing flag, because the unquoted-attribute reader excludes '/' from its delimiters. So `<div></p>` repeated N times builds an N-deep tree while the guard reports depth ~1. HTMLExtractor.swift:91 is the only bound before SwiftSoup.parse and the recursive walk; the body cap is 10 MiB, i.e. >1M levels of the 7-byte form. The repository's own comment records ~20 000 levels as fatal (stack exhaustion). VERIFIED STATICALLY by reading the guard: MarkupDepth.swift:114-115 decrements on every closing tag (`depth = depth > 0 ? depth - 1 : 0`) and :137 reads `/>` as self-closing from the byte before `>`. Neither matches SwiftSoup, so `<div></p>` repeated N times leaves depth pinned at 0 while the parsed tree is N deep. START gate satisfied; the expected-correct is 'the depth bound must never under-count the tree the parser will build'.

MEASURED 2026-09-18: a scratch test parsed 100 000 repetitions of the bypass (`<div></p>`, ~900 KB — inside the 10 MiB body cap) through `SwiftSoup.parse` directly, with no SwiftSoupException and no crash: the run HAD TO BE KILLED after 10 minutes. So the guard's blind spot is not only a stack-depth hazard — the parse of unmatched-closer-heavy markup does not complete in any useful time, which is a resource-exhaustion/hang DoS reachable by any fetched page, and it happens on the server's own thread. The scratch test was deleted and no test process was left behind.

ANALYSIS of what actually bounds this, worked through rather than guessed: the bypass nests because each `<div>` really is an open element (real tree depth grows by one per repetition) while the guard is talked out of counting it by the `</p>`. So the tree can nest as deeply as the number of *start tags*, and bounding unmatched closers alone does NOT bound depth. The sound bound is therefore the start-tag count — which at 512 (the depth budget) would refuse ordinary pages, and ordinary large pages carry tens of thousands of tags, so any tag cap that is safe for the ~20 000-level fatal figure sits inside the range real pages occupy. A tight bound needs HTML's implied-end-tag rules (a `</ul>` closing open `li`s, `<li>` auto-closing the previous `<li>`) modelled accurately, or the parse must be bounded by work rather than by shape, which SwiftSoup does not expose. This is the irreducible tension, stated so the next attempt does not re-derive it: there is no cheap check that is both sound and free of false rejections.
- **Fix:** Planned, not yet implemented. The bound must be unfoolable rather than model-matching: count start tags without any decrement, since every element in the tree was opened by some start tag, so start-tag count is a sound upper bound on tree depth. That costs a behaviour change (a very tag-heavy but shallow page would also be refused), so the limit needs choosing against the ~20 000 level figure the file already records as fatal, and the byte cap stays. Rejected alternatives: teaching the scan HTML's implied end-tag and self-closing rules (still model-matching, still bypassable), and making our own walk iterative (does not help: SwiftSoup's parse is recursive and runs first).

REFINED PLAN (better than the first): do NOT change the existing depth semantics — 24 tests in MarkupDepthTests assert them (testClosingTagsReturnToTheParent, testNestingAtTheLimitIsAccepted, and others), and redefining depth would mean rewriting those tests, which risks looking like weakening. Instead make the guard ADDITIVE: in the same single pass, keep `depth` exactly as it is for the early-exit heuristic, and add a monotonic `startTags` counter that is never decremented and never reduced by a closing tag. Every element in the parsed tree was opened by some start tag, so startTags is a sound upper bound on tree depth and cannot be fooled by an unmatched closing tag or by `<div foo=/>`. Fail when either bound is exceeded. The existing depth tests keep their meaning, and the new bound needs its own tests: `<div></p>` repeated past the limit must be rejected, and an ordinary page must still pass. The trade-off is unchanged and must be stated in the code: a page with more start tags than the limit is refused even if it is shallow, because the limit must stay below the ~20 000 level figure the file records as fatal, and a crash reachable by any fetched page is worse than refusing an absurd one.

CORRECTION TO THE REFINED PLAN, after reading the constant: maximumNesting is 512, not ~20 000. The file records ~20 000 *levels* as fatal; 512 is the depth budget. So a monotonic start-tag bound sharing that limit would reject almost every real page, and a bound set below the fatal depth (~20 000) would still land in the range ordinary large pages occupy — a 1 MB page of markup carries tens of thousands of tags. The sound bound is therefore NOT usable as a naive patch, and implementing the refined plan as written would trade a remotely triggerable crash for refusing normal pages. That is a worse product, and it is exactly the kind of 'fix' this audit exists to prevent.

OPEN DESIGN QUESTION, to be settled before any code: the depth bound must be sound without rejecting tag-heavy but shallow documents. Candidate directions, none verified: (a) bound the number of *unmatched* closing tags rather than total tags, since the bypass needs closing tags that close nothing — targeted at the mechanism, but ordinary sloppy HTML has some; (b) confirm whether SwiftSoup's tree builder recurses per nesting level and, if the recursion is ours alone, make the walk iterative and raise the depth budget; (c) run the parse with a deliberately large stack and a much higher tag bound, accepting memory cost; (d) parse with a depth-limited builder if SwiftSoup exposes one. The next round must EVIDENCE which of these is sound (the SwiftSoup internals are in .build/checkouts) rather than pick one.

BEST DIRECTION, on the measured evidence: bound the *unmatched closing tags*, not the total tag count. The experiment shows unmatched closers are the fuel for both the depth inflation and the pathological parse, and ordinary HTML has very few of them while ordinary pages have tens of thousands of matched tags — so a threshold there is discriminating where a total-tag bound is not. A simple stack of open tag names is enough to count them. This still needs evidence for the threshold on real pages before it is written. Making our own `walk` iterative is necessary regardless (it is our recursion at HTMLExtractor.swift:259,288) but is NOT sufficient on its own, because the hang is inside `SwiftSoup.parse` and happens before `walk` is reached.
- **BLOCKED:** Owner: repository owner (Pummelchen) — a product decision, not an unimplemented patch. NOT FIXED: this S0 ships unless the owner chooses an option below. WHAT WAS TRIED: (1) make our own recursive walk iterative — necessary but NOT sufficient, the hang is inside SwiftSoup.parse before walk is reached; (2) a monotonic start-tag bound — withdrawn, because at maximumNesting = 512 it refuses ordinary pages and a cap safe for the ~20 000-level fatal figure sits inside the range real pages occupy; (3) bounding unmatched closing tags — measured reasoning shows it does not bound depth, since each <div> really is an open element and the tree nests once per start tag; (4) measured the blind spot directly: 100 000 repetitions of `<div></p>` (~900 KB, inside the 10 MiB cap) through SwiftSoup.parse did not crash and did not finish — killed after 10 minutes. OPTIONS: (a) accept a false-rejection cap — bound total start tags around 12 000, sound because it sits below the fatal depth, at the cost of refusing very tag-heavy but legitimate pages; (b) model HTML's implied-end-tag rules accurately enough to bound real depth tightly (a project-sized task, and the only option with no false rejections); (c) move extraction to a work-bounded or process-isolated parse (a watchdog plus a bounded stack) if SwiftSoup exposes a seam, accepting the complexity. RECOMMENDATION: (b) if a correct bound matters, (a) if a release must ship now and the owner accepts refusing the largest pages. Doing nothing leaves a remotely triggerable denial of service reachable from any fetched page.

### A0045 — SearXNG answers are decoded as [String] but emitted as objects, so an answering query discards every result

- **Severity / tier / status:** S0 / A / DONE
- **Location:** `Sources/WebSearchCore/Providers/SearXNGProvider.swift:180,154`
- **Category:** correctness/decoding
- **Host:** Node1
- **Discovered by:** Providers tier A review (subagent)
- **Evidence before:** `let answers: [String]?` with `payload.answers?.first(where: { !$0.isEmpty })`. SearXNG builds answers as a list of dicts (`Answer.as_dict()` -> {answer, url, engine}), so the wire type is an array of objects and never strings. decodeIfPresent([String].self) throws typeMismatch on an object array rather than returning nil, and Data.decodeJSON turns that into .malformedResponse(.searxng) — discarding the valid results array for the whole query. Trigger: any query an answering engine handles. The repo's own notes and the provider test feed only use "answers":[], so it is untested.
- **Fix:** `answers` is now `[Answer]?`, decoding either an object ({answer,url,engine}) or a plain string, taking the first entry with non-empty text; an unrecognised element is ignored rather than fatal. Three tests added in a new SearXNGAnswerShapeTests file, because adding them to ProviderContractTests pushed it past the file-length envelope .swiftlint.yml records.
- **Evidence after:** With the fix stashed the new test failed as the defect predicts: caught error: "malformedResponse(WebSearchCore.ProviderID.searxng)". With the fix: the same test passes, plus plain-string and unreadable-entry cases. Full suite 593 tests (551 + 42), 6 skipped, 0 failures, 0 warnings; swift-format --strict and swiftlint --strict both exit 0.
- **Commit:** `14daaad`

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

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `.swiftlint.yml:40`
- **Category:** language-standard
- **Host:** Node1
- **Discovered by:** Phase A language-standard proof (§1)
- **Evidence before:** The config enables no opt-in rules ('Opt-in rules are deliberately not enabled by this task', .swiftlint.yml:40), so force_unwrapping is off and `swiftlint lint --strict` accepts a `!` force-unwrap. §1 requires that a force-unwrap fail SwiftLint --strict.
- **Fix:** All 20 sites fixed rather than suppressed and `force_unwrapping` is enabled under `opt_in_rules`. The two sites in contexts that cannot `try` were resolved structurally: `LoopbackServer.baseURL` became a stored `let` assigned in the throwing `init` with a real error case, and `AnswerSynthesizerTests` gained a non-throwing `fixtureURL` that calls `XCTFail` and returns a sentinel, which no test can pass on because it is already marked failed.
- **Evidence after:** Committed in b95038a. §1 standard proof: a deliberate `value!` added in Sources/WebSearchCore/Support/ produced "error: Force Unwrapping Violation: Force unwrapping should be avoided (force_unwrapping)" under `swiftlint --strict`, so the gate fails on it; the file was then removed. `swiftlint lint --strict` on the repository exits 0 with 0 findings. No `# swiftlint:disable`, no `try!` substitution and no `fatalError` helper standing in for `!`. 20 signatures gained `throws`. Suite green at 612 tests (570 + 42), 0 failures; swift-format --strict exits 0.
- **Commit:** `b95038a`

### A0004 — Ruff does not select S101, so `assert` used for validation is unchecked

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `ruff.toml:15-27`
- **Category:** language-standard
- **Host:** Node1
- **Discovered by:** Phase A lint-config review (§1)
- **Evidence before:** select = [E, F, W, I, UP, B, BLE, SIM, RUF, PERF, FURB]; the S set is deliberately excluded with a rationale that names bandit's subprocess/socket rules. §1 requires the rule that catches 'assert used for validation that -O strips', which is S101.
- **Fix:** `"S101"` is selected in `ruff.toml`, narrowly rather than re-enabling the whole `S` family the file explains is off on purpose.
- **Evidence after:** Committed in 6c57464. Before: `ruff check --select S101 scripts` found 8. After: it passes, and the rule is live in the default config — a deliberate assert produced "scripts/proof_temp.py:2:5: S101 Use of `assert` detected". ruff format --check clean, pyright strict 0 errors, 18 harness tests pass, stdio smoke passes end to end.
- **Commit:** `6c57464`

### A0005 — The secret-scan delegation is unproven: gitleaks is blind to the credential pattern this repository actually leaked

- **Severity / tier / status:** S1 / A / PROGRESS
- **Location:** `.gitleaks.toml`
- **Category:** tool-coverage
- **Host:** Node1
- **Discovered by:** L4 tool-coverage proof (§1)
- **Evidence before:** gitleaks detect --log-opts=--all on full history: 0 findings. Pointed directly at the historical blob (gitleaks detect --no-git --source <blob>) which contains six tvly-prefixed literals: 0 findings. A tool that stays silent does not cover the check.
- **Fix:** Added a `tavily-api-key` rule to .gitleaks.toml. It fires on 17 history findings, so the delegation is no longer silent — but the regex does not yet fire on the historical fixture blob even though Python's `re` matches 6 literals there, so the rule is not yet understood well enough to trust. Open: why gitleaks and Python disagree on the same bytes.

RULE TEXT TO RE-APPLY (reverted uncommitted because it makes the CI gitleaks gate fail on 17 history findings with no waiver yet):

[[rules]]
id = "tavily-api-key"
description = "Tavily API key or key prefix"
# `{10,}` and not `{8,}`: the shortest real literal in the leaked blob has a 14-character body,
# while the prose "tvly-prefixed" has 8 — the first draft of this rule fired on this very
# document, which is how the bound was chosen. A disclosure shorter than 10 body characters is
# not usable as a credential.
regex = '''\btvly-[A-Za-z0-9_-]{10,}'''
keywords = ["tvly-"]

REMAINING WORK: (1) explain why gitleaks stays silent on the historical fixture blob while Python's re matches 6 literals in the same bytes — until then the rule is not trusted; (2) decide the waiver: the 17 findings are real disclosures in immutable history, so they need either a narrow allowlist keyed on commit SHA plus path (never on the secret value, which must not be written into a committed file) plus a written waiver, or acceptance that CI stays red until A0001 is rotated.

### A0008 — The only check that consumes /health reads the status code and never the body, so it cannot fail

- **Severity / tier / status:** S1 / C / DONE
- **Location:** `scripts/mcp_smoke.py:466-470`
- **Category:** check-cannot-fail
- **Host:** Node1
- **Discovered by:** L7 ops + §5 facade hunt (subagent), corroborated by reading the function
- **Evidence before:** wait_for_health opens the health URL and returns as soon as response.status == 200. It never reads or asserts the body. Since the body is a constant (A0007), "the server is healthy" is proven by "a socket is bound": a process that bound the port and then bricked still passes the smoke test and CI. NOTE: after A0007 the body is derived and carries version plus provider counts, so this is now cheap to close — the gate should read the body it already fetches and assert status/version rather than only that a socket answered.
- **Fix:** `wait_for_health` parses the body and asserts status, version == VERSION, and that provider counts are present; a non-object or non-JSON body is a named failure.
- **Evidence after:** Against the pre-A0007 release binary (which still has the hardcoded body) the gate fails with 'SMOKE TEST FAILED: /health reported version None, expected '1.2.0' from VERSION'. Against the current binary both stdio and --http modes pass. ruff clean, pyright strict 0 errors, 17 harness tests pass.
- **Commit:** `9d18d5d`

### A0009 — The HTTP server installs no signal handler, and its graceful-shutdown helper is dead code

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/SwiftWebSearchMCP/main.swift:120-124,186`
- **Category:** ops/graceful-shutdown
- **Host:** Node1
- **Discovered by:** L7 ops pass (subagent), corroborated by grepping Sources/ for the caller
- **Evidence before:** Measured, and this is new: start the server, wait for /health, send SIGTERM — the committed build exits with returncode -15, i.e. killed by the signal.
- **Fix:** `HTTPMCPHost.stop()` is once-only, and SIGINT/SIGTERM handlers call the previously dead `shutdown(server:host:)`, so the session sweep runs on shutdown instead of the process being killed.
- **Evidence after:** Committed in 4885170. Before: SIGTERM gave returncode -15 (killed by the signal). After: SIGINT and SIGTERM both give returncode 0. The probe distinguishes clean exit (0) from killed (-15) from hung (-9); the two round-41 attempts both measured -9, which is why the fix was reverted then and the once-only guard was written first now. Suite green at 614 tests (572 + 42), 0 failures, 0 warnings; both linters exit 0; stdio smoke passes.
- **Commit:** `4885170`

### A0012 — The response charset is discarded, so non-UTF-8 pages are silently decoded as Latin-1

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/WebSearchCore/Fetch/DirectHTTPFetcher.swift:136-139,250-254`
- **Category:** correctness/encoding
- **Host:** Node1
- **Discovered by:** Fetch tier A manual review (subagent)
- **Evidence before:** mimeType(from:) keeps only the part before ';' and drops the charset parameter, and the <meta charset> in the markup is never consulted (`grep charset` over Sources/ finds no consumer). Decoding is `String(data:encoding:.utf8) ?? String(data:encoding:.isoLatin1) ?? ""`, and Latin-1 decoding cannot fail, so a windows-1251 / Shift_JIS / GBK page is silently mojibake with no warning and no truncation flag.
- **Fix:** `decodeText(_:contentType:)` decodes with the declared `charset`, then UTF-8, then the document's own `<meta charset>`, then Latin-1; both decode sites use it. Latin-1 remains the last resort because it cannot fail.
- **Evidence after:** Committed in 48092f6. `LoopbackServer.Response.bodyData: Data?` lets the loopback server serve raw bytes, so the test drives `DirectHTTPFetcher.fetch` against a windows-1251 page and the before-state is demonstrable: with the call sites reverted, "expected Привет мир in: Ïðèâåò ìèð" — the Latin-1 mojibake a caller was served with no warning. After: the fetch returns the Cyrillic. Four decoder-level tests plus this fetch-path test; suite green at 611 tests (569 + 42), 0 failures, 0 warnings; both linters exit 0.
- **Commit:** `48092f6`

### A0013 — Credentials in the target URL's query or fragment are forwarded to the third-party reader

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/WebSearchCore/Fetch/JinaReaderFetcher.swift:48`
- **Category:** security/credential-disclosure
- **Host:** Node1
- **Discovered by:** Fetch tier A manual review (subagent)
- **Evidence before:** The reader URL is built by appending the whole target (`URL(string: readerURL + request.url.absoluteString)`). URLPolicy.validateLexically rejects only url.user/url.password, so `?api_key=...` or a signed URL passes validation and is transmitted in full to r.jina.ai. The only control is a warning appended after the request (JinaReaderFetcher.swift:127-130). The pure-userinfo case cannot reach here (WebFetcher.swift:126 rethrows .blockedURL first). Documented as a known trap in AGENTS.md; mitigation today is SEARCH_ENABLE_JINA_READER=false.
- **Fix:** `credentialToWithhold(from:)` declines the fallback for userinfo or a credential-shaped parameter name, and `withoutFragment(_:)` drops the fragment. Matching is on a closed list of parameter names, not on values, and excludes names like `key` and `code` that are usually benign.
- **Evidence after:** Committed in 1b1a332. Before: the request that left the machine read "https://reader.invalid/http://127.0.0.1:51555/?token=super-secret-value". After: the reader is not consulted and the native extraction is returned, while the existing thin-page test still shows the reader being used for an ordinary URL. Suite green at 613 tests (571 + 42), 0 failures; both linters exit 0.
- **Commit:** `1b1a332`

### A0014 — An empty extraction is returned as a success, discarding the real failure reason

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/WebSearchCore/Fetch/WebFetcher.swift:147-158,175-189`
- **Category:** correctness/error-reporting
- **Host:** Node1
- **Discovered by:** Fetch tier A manual review (subagent)
- **Evidence before:** When the reader is disabled or fails, `guard let result = directResult else { throw ... }` returns whatever directResult holds, including an empty text. The transport or reader reason is discarded and web_open returns success with text_characters: 0 plus a note. A caller cannot distinguish 'the page has no text' from 'every extraction path failed'.
- **Fix:** Both fallback arms require non-empty text before returning the direct result; an empty extraction throws `directError ?? .extractionFailed` instead of reporting success with 0 characters.
- **Evidence after:** Before: the new test's XCTFail fired — open returned normally for a document with no extractable text. After: it throws with category .malformedResponse. The four existing fetch suites still pass, so nothing had asserted the old behaviour. Suite green at 606 tests (564 + 42), 0 failures, 0 warnings; both linters exit 0.
- **Commit:** `6569e77`

### A0015 — Cancellation is swallowed on the reader path, so a cancelled fetch can return a stale success

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/WebSearchCore/Fetch/WebFetcher.swift:175; JinaReaderFetcher.swift:69`
- **Category:** concurrency/cancellation
- **Host:** Node1
- **Discovered by:** Fetch tier A manual review (subagent)
- **Evidence before:** The generic `catch` around the reader fallback also catches CancellationError and returns a normal FetchResult instead of propagating, and `try? await Task.sleep(...)` discards cancellation. ToolHandlers.swift:188 is written to report CancellationError as 'Fetch cancelled', which this path can bypass. Partly masked because the HTTP client re-checks cancellation first, so the outbound request usually is not sent.
- **Fix:** A `catch let error where Self.isCancellation(error)` arm ahead of the broad catch rethrows, so a cancelled reader fetch propagates instead of returning the native extraction as a fallback result.
- **Evidence after:** Committed in 7ff2eeb. Before: the new test's XCTFail fired — a cancelled fetch returned a result instead of propagating. After: the cancellation propagates. The test drives the real fallback chain with a thin native page, so the reader is genuinely consulted. Suite green at 612 tests (570 + 42), 0 failures, 0 warnings; both linters exit 0.
- **Commit:** `7ff2eeb`

### A0017 — DNS-rebinding TOCTOU between validation and connect (documented, no local fix)

- **Severity / tier / status:** S1 / A / BLOCKED
- **Location:** `Sources/WebSearchCore/Fetch/URLPolicy.swift:147-154; DirectHTTPFetcher.swift:68,83`
- **Category:** security/ssrf
- **Host:** Node1
- **Discovered by:** Fetch tier A manual review (subagent)
- **Evidence before:** The URL is validated (resolved, checked) and then handed to URLSession, which resolves the name again when it connects; a name whose A record flips into private space between the two lookups lands internally. The window is bounded by DNS TTL and the code documents it as an accepted limitation. URLSession exposes no address pinning, so there is no local fix.
- **BLOCKED:** Owner: platform (Foundation/URLSession) + repository owner for the residual risk decision. No local fix exists because URLSession offers no address pinning. Options for a human: (1) accept and keep the existing documentation, which is already done in URLPolicy.swift:147-154 and the tracker; (2) move the fetch to a transport that exposes the resolved address (a custom NIO client, or a connector that pins the IP) as its own project-sized task. Already documented as accepted before this audit; recorded here so it is counted rather than silently dropped.

### A0018 — The soak's stdio read has no timeout, so one unanswered query hangs the whole run

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `scripts/soak.py:167,181-193`
- **Category:** reliability/hang
- **Host:** Node1
- **Discovered by:** Python scripts tier review (subagent), statically verified against the code
- **Evidence before:** line = self.process.stdout.readline() with no timeout, deadline or watchdog on any read path. The only timeout is process.wait(timeout=30) in close(), which is unreachable if a read never returns. A server that stops answering without closing stdout hangs all 50 queries and produces no verdict at all.
- **Fix:** stdout is drained on a daemon thread into a queue, so `read(timeout=...)` waits with a deadline and raises a named RuntimeError instead of blocking in `readline` with no bound.
- **Evidence after:** A stub that stays alive and never answers trips the deadline: "the server did not answer within 2s; abandoning the run rather than hanging". The default is 120s, so a hung server now produces a verdict instead of nothing. ruff and pyright clean; 17 harness tests pass.
- **Commit:** `e50729b`

### A0019 — The child's stderr pipe is not drained until exit, which deadlocks against the stdout read

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `scripts/soak.py:152,209`
- **Category:** reliability/deadlock
- **Host:** Node1
- **Discovered by:** Python scripts tier review (subagent), statically verified against the code
- **Evidence before:** stderr=subprocess.PIPE and read() only in close() after wait(). macOS pipe capacity is ~16 KiB; SEARCH_LOG_LEVEL=warning is set deliberately so warnings are retained, and 50 queries against rate-limited providers emit them. Once the child blocks writing stderr it stops answering stdout and the parent blocks in readline() — a deadlock, not a timeout. The Swift harness drains stderr as it is produced for exactly this reason (Tests/WebSearchCoreTests/TestSupport.swift:205-209).
- **Fix:** A daemon thread drains stderr continuously into a lock-guarded buffer that `close` returns, so the pipe never fills and the child never blocks writing.
- **Evidence after:** A stub writing 2 000 lines to stderr then answering: with the fix it answers in 0.32s and 122 893 characters of stderr are retained for the leak scan; with the fix stashed and a 20s wall clock it was killed (exit=124) because the parent never read the reply. ruff and pyright clean. NOT VERIFIED: a full live soak was not run.
- **Commit:** `e50729b`

### A0020 — The credential-leak scan is stderr-only and only runs on the fully successful path

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `scripts/soak.py:513,384`
- **Category:** security/credential-detection
- **Host:** Node1
- **Discovered by:** Python scripts tier review (subagent), statically verified against the code
- **Evidence before:** Two independent holes. (a) Only stderr is scanned, but the harness prints server-supplied last_error to stdout (502-510). The server documents that a diagnostic can carry a credential: Mojeek authenticates with api_key= in the query string, HTTPClient.swift:379-384 says a URL in a diagnostic is a credential in a diagnostic, and ProviderHealth.swift:215 copies that into lastError which ToolSchemas.swift:831 returns to the client. (b) The scan sits inside the try opened at 384, so any exception before 513 jumps to finally (529-531) which only kills the child: the stderr that may hold the leak is never read or scanned, so the check silently does not run on exactly the failed runs. Whether a key currently reaches last_error is UNSURE.
- **Fix:** `server_diagnostics` collects the server-supplied `last_error` values untruncated and the scan reads stderr plus that text; the scan also runs from the `finally`, so an early failure cannot skip it.
- **Evidence after:** Committed in 122aafe. Before, with a stub whose last_error carries the configured TAVILY_API_KEY: the report printed the secret and then "credential leak in stderr: none", SOAK COMPLETE, exit 0. After: "credential leak in the server's output: ['TAVILY_API_KEY value', 'api_key=']", SOAK FAILED, exit 1. ruff, ruff-format and pyright clean; 18 harness tests pass. REMAINING: the evidence is a manual reproduction, not a harness test, so CI does not re-run it — a `harness_tests.py` case driving the soak against a stub with a known secret would make it permanent.
- **Commit:** `122aafe`

### A0021 — A non-JSON stdout line is embedded in a raised exception, reaching an unscanned traceback

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `scripts/soak.py:176-179`
- **Category:** security/credential-detection
- **Host:** Node1
- **Discovered by:** Python scripts tier review (subagent), statically verified against the code
- **Evidence before:** RuntimeError(f"...; offending line: {line!r}") with no handler in main (only KeyboardInterrupt, 534-538), so Python prints the raw server line to stderr — and by A0020 nothing scans that traceback. Reachability is UNSURE: it requires the server to write credential material on stdout, which is itself what the soak probes for.
- **Fix:** Both sites report the malformed line's length instead of its contents, so server-controlled text no longer reaches a traceback that the credential scan does not cover. The JSON error still carries the position.
- **Evidence after:** Committed in 5767d8b. Before: a stub whose malformed stdout line carried the configured TAVILY_API_KEY put it in the output once. After: zero occurrences, replaced by "the line was 48 characters long". ruff, ruff-format and pyright clean; 18 harness tests pass; stdio smoke passes. REMAINING: the evidence is a manual reproduction, so CI does not re-run it — a harness test with such a stub would make it permanent.
- **Commit:** `5767d8b`

### A0028 — The HTTP session registry is unbounded, so an unauthenticated client can grow it without limit

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:80,196`
- **Category:** resource/unbounded
- **Host:** Node1
- **Discovered by:** MCP surface tier A review (subagent)
- **Evidence before:** sessions entries are removed only by closeSession (DELETE or refused initialize) or stop(). maximumConnections=64 bounds concurrent sockets, but non-streaming responses send Connection: close, so a client can POST initialize, drop the connection and repeat serially forever. Each entry holds a Server plus a StatefulHTTPServerTransport whose storedEvents also never shrinks. No cap and no idle expiry.
- **Fix:** `HTTPMCPHost` keeps at most `maximumLiveSessions` (64 by default) sessions, with the slot reserved under a lock before any work starts and released on every path — the normal release, the failure that never registered a session, and `stop()`'s sweep. The cap is injectable and settable with `--max-sessions N`, so an operator can tighten it.
- **Evidence after:** Committed in f2ff8b9. Against the built server, four `initialize` requests (the first being the readiness probe's own session): cap of 3 → [200, 200, 503, 503]; no flag → [200, 200, 200, 200]. The over-cap refusal is a 503 rather than a silent allocation. The exhaustive `default`-less switch in TransportConfigurationTests failed to compile until the new flag had a sample value, which is that test working as designed. Suite green at 613 tests (571 + 42), 0 failures; both linters exit 0; stdio smoke passes.
- **Commit:** `f2ff8b9`

### A0029 — A disconnected SSE client leaks a suspended relay task and wedges the session

- **Severity / tier / status:** S1 / A / PROGRESS
- **Location:** `Sources/SwiftWebSearchMCP/HTTPMCPHost.swift:721,723,403-408`
- **Category:** resource/leak
- **Host:** Node1
- **Discovered by:** MCP surface tier A review (subagent)
- **Evidence before:** SSEStreamRelay.relay spawns Task { for try await frame in stream }. Nothing cancels it; channelInactive only cancels the deadline and releases the connection count. It never finishes the stream or clears the SDK's standaloneSSEContinuation, which the SDK finishes only in terminate(). After a client disconnect the task stays parked for the session's life retaining the channel, and later plain GETs on that session return 409 until DELETE or Last-Event-ID. Combined with A0028 this grows without bound.
- **Fix:** `SSEStreamRelay.relay` keeps its task, watches `channel.closeFuture` and cancels it when the channel closes, with a `catch is CancellationError` arm that stops rather than trying to close an already-closed channel. The relay no longer depends on the stream ending.
- **Evidence after:** Committed in d110631. NOT CLOSED: the before-state could not be demonstrated. A probe that opens a session, opens the SSE stream three times, kills each socket with SO_LINGER=0 (RST, not FIN) and then calls `tools/list` on the same session returns 200 afterwards — and returns 200 with the pre-change relay too, so the probe does not discriminate and is not evidence. Either the finding's "wedges the session" half does not reproduce under an abrupt disconnect, or it needs a different trigger; I do not know which, and that is written down rather than guessed. The fix is landed because nothing in the old relay could ever end a parked task. REMAINING: an observation that distinguishes the two relays — a task-count or memory probe across many connect/disconnect cycles — and a decision on whether the ledger's wording is accurate. Suite green at 613 tests (571 + 42), 0 failures; both linters exit 0.
- **Commit:** `d110631`

### A0030 — A cancelled provider request is recorded as a transient failure and can open a circuit breaker

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/WebSearchCore/Search/SearchOrchestrator.swift:557-561`
- **Category:** concurrency/cancellation
- **Host:** Node1
- **Discovered by:** Search + Support tier A review (subagent)
- **Evidence before:** Only `catch is CancellationError` is treated as cancellation. A mid-flight URLSession cancellation surfaces as HTTPError.cancelled, not CancellationError — documented in this codebase at AnswerSynthesizer.swift:380-385. It reaches the generic arm; HTTPStatusMapper maps .cancelled to .networkFailure, whose .network category isTransient, so ProviderHealth increments consecutiveFailures and CircuitBreaker can open. Three client disconnects therefore open breakers on providers that never failed, contradicting the intent at :543-548 and recordBudgetExceeded (:428-431). The existing test uses a mock that throws CancellationError directly, so it never exercises the real transport path.
- **Fix:** `SearchOrchestrator.runSingle` now recognises cancellation in both shapes via a new `isCancellation(_:)` (CancellationError and HTTPError.cancelled), so the transport's shape no longer falls into the generic arm that mapped it to a transient network failure. The same fix closes A0048, which is the mapping half of this defect: with the orchestrator catching cancellation first, that arm is no longer reached from the path that charges the breaker.
- **Evidence after:** Before: category .network ("Tavily network failure: cancelled") and authorize(.tavily) returned .circuitOpen — charged as transient AND the probe never released. After: category .cancelled and the probe is claimable. Suite green at 600 tests (558 + 42), 0 failures, 0 warnings; both linters exit 0.
- **Commit:** `c3349bd`

### A0031 — A claimed half-open probe is never released when the local rate limiter denies, wedging the breaker

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/WebSearchCore/Search/ProviderHealth.swift:143,156-159`
- **Category:** concurrency/state-machine
- **Host:** Node1
- **Discovered by:** Search + Support tier A review (subagent)
- **Evidence before:** breaker.shouldAttempt() claims the probe (probeInFlight = true). If limiter.tryAcquire() then denies, authorize returns the rate-limited failure without releaseProbe(); runSingle treats an authorize denial as skippedLocally and records no outcome, and the only releaseProbe caller is the CancellationError arm. State stays .halfOpen with probeInFlight == true, so every later authorize returns .circuitOpen — permanently, until a manual reset(). Reachable: a half-open probe cancelled as CancellationError correctly releases, leaving .halfOpen; the next search inside the refill/min-interval window is denied after claiming a new probe. Scraper policy is burst 1 / 10 rpm / 1.5 s, so that window is up to 6 s.
- **Fix:** `authorize` tracks whether this call claimed the half-open probe and releases it before returning when the local limiter refuses. `releaseProbe` no-ops unless half-open, so marking both claim sites is safe.
- **Evidence after:** Before: the third authorize failed with `.circuitOpen` — "Tavily is being probed after failures; this request is skipped until that probe finishes." After: the sequence recovers and it returns nil. Suite green at 601 tests (559 + 42), 0 failures, 0 warnings; both linters exit 0.
- **Commit:** `8c671e9`

### A0032 — Length-omitted results enter the fenced prompt unsanitised, so a page title can close the untrusted-data fence

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/WebSearchCore/Search/AnswerSynthesizer.swift:488`
- **Category:** security/prompt-injection
- **Host:** Node1
- **Discovered by:** Search + Support tier A review (subagent)
- **Evidence before:** Every other insertion sanitises the delimiter (:482-484), but this branch appends result.title and the URL verbatim. web_answer passes up to 20 fused results; with a 14 000-character budget and 1 200 per result roughly half take this branch, and ResultNormalizer.cleanText does not remove the literal delimiter. A hostile page title containing </untrusted-search-results> is emitted inside the block, letting the remainder read as text outside the fence — the escape the fence exists to prevent.
- **Fix:** The omitted branch applies `sanitiseFences` to the title and the URL, as the full block always did. The result is still numbered, so citation markers stay aligned.
- **Evidence after:** Committed in 05c98c1. Before: the new test failed with "the bomb title reached the corpus raw". After: it passes and the title carries "[delimiter removed]". Two fixture mistakes were corrected first — a Markdown fence instead of this corpus's XML-ish tag pair, and a budget loose enough that the result was never omitted — both caught because the test failed identically before and after. Suite green at 614 tests (572 + 42), 0 failures; both linters exit 0.
- **Commit:** `05c98c1`

### A0035 — The mandatory-SearXNG proof passes on an instance that returns zero results

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `deploy/install.sh:427-433,382-384`
- **Category:** check-cannot-fail
- **Host:** Node1
- **Discovered by:** installer/release shell tier A review (subagent)
- **Evidence before:** searxng_answers prints len(data["results"]), so {"results": []} prints the string "0", which [ -n ... ] treats as true. An instance with json enabled but every engine failing or disabled is adopted as "a working SearXNG is already listening" and reported as having "answered a real query: 0 results". Nothing else covers it: the end-to-end step can pass through the default-enabled scrapers and Parallel, so the install's central claim is not established.
- **Fix:** A `has_results` predicate refuses anything that is not a positive integer, used at both adoption sites, so a zero-result instance is no longer adopted as working.
- **Evidence after:** The real `has_results`, extracted from install.sh and evaluated: "" refused, "0" refused, "abc" refused, "5" accepted, "12" accepted. bash -n and shellcheck clean. NOT VERIFIED: the installer was not run (it installs software; this host runs a live SearXNG).
- **Commit:** `5439839`

### A0036 — The end-to-end gate accepts a JSON-RPC error reply as success and never asserts the result count

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `deploy/install.sh:585-592`
- **Category:** check-cannot-fail
- **Host:** Node1
- **Discovered by:** installer/release shell tier A review (subagent)
- **Evidence before:** A reply carrying "error" and no "result" gives res = {}, isError falsy, and prints ok: 0 result blocks, which the gate reports as "returned a real search result". The same happens if a stray stdout notification arrives first — the exact trap stdout purity exists to catch. The block count is computed but never asserted, and it is off by one: the joined text starts with [1], so text.count("\n[") is 0 for a genuine single-result answer.
- **Fix:** The gate rejects a JSON-RPC error, a reply with no result object, an `isError` result and a content-less result, and asserts at least one result block instead of printing a count it never checked.
- **Evidence after:** Previous logic on a JSON-RPC error printed `ok: 0 result blocks` — its own success path. The new gate, extracted from install.sh and run against stubs: error reply -> "error: JSON-RPC error: ..."; one real result -> "ok: 1 result block(s)"; empty content -> "error: the search returned no result blocks". NOT VERIFIED: the installer was not run.
- **Commit:** `5439839`

### A0037 — The generated SearXNG secret is passed as a command-line argument, where ps can read it

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `deploy/install.sh:250,295`
- **Category:** security/credential-disclosure
- **Host:** Node1
- **Discovered by:** installer/release shell tier A review (subagent)
- **Evidence before:** `-e SEARXNG_SECRET=${secret}` on the docker run, and the same value as an argv to python3. On a real run the secret is in the argv of docker/python3 for the life of the process, readable by any local user via ps, and later exposed by docker inspect. The script keeps the secret 600 everywhere else; this is the one place it is exposed.
- **Fix:** Docker path passes the secret with `--env-file` on a 600 file removed on both paths; the native path passes it in the environment and reads it with `os.environ["SEARXNG_SECRET"]`.
- **Evidence after:** No value is an argument anywhere; bash -n and shellcheck -S warning clean on both scripts; the native heredoc body was extracted and executed exactly as the installer runs it and wrote secret, bind and port, exit 0. NOT VERIFIED: the installer itself was not run (it installs software; this host runs a live SearXNG), and the docker `--env-file` path was checked by reading and shellcheck, not by starting a container.
- **Commit:** `f84cd47`

### A0038 — `|| true` swallows a grep error and the truncated staging file then replaces config.env, dropping every API key

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `deploy/install.sh:559`
- **Category:** data-loss
- **Host:** Node1
- **Discovered by:** installer/release shell tier A review (subagent)
- **Evidence before:** `grep -v '^SEARXNG_BASE_URL=' "$base" > "$staged" || true` needs || true for grep's exit 1 (no match) but also masks exit 2 (open/read error). The redirection has already truncated $staged, so it is empty, and the next line moves it over config.env, leaving only the new SEARXNG_BASE_URL block while the script prints "existing keys preserved". Trigger: $base passes the -f test at :519 but cannot be read at :522 (permissions change, or removal between the two).
- **Fix:** grep's status is examined: 0 and 1 are accepted, anything else removes the staged file and stops the install. The distinction is made on the exit status rather than the file's size, so a legitimate config whose only line is SEARXNG_BASE_URL still stages.
- **Evidence after:** Committed in 68c6907. Before: an unreadable base gave no refusal and "staged bytes: 0" — the file that would replace config.env. After: case (a) stages 51 bytes, case (b) stages 0 with no refusal (legitimate, grep exit 1), case (c) refuses and removes the staged file. bash -n and shellcheck -S warning clean over install.sh, provision-node.sh and tools/*.sh; 18 harness tests pass.
- **Commit:** `68c6907`

### A0041 — The release-notes gate names NOT_CHECKED in its failure message but never checks for it

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `tools/release.sh:349-354,391-395`
- **Category:** release-gate
- **Host:** Node1
- **Discovered by:** installer/release shell tier A review (subagent)
- **Evidence before:** Neither grep condition looks for NOT_CHECKED_PENDING, and the renderer only substitutes a line starting with it. A notes file with the checksum block but without that placeholder passes every gate, so any gate that skip()ed (pyright, semgrep, gitleaks, osv-scanner) is absent from the published notes while the script still prints PUBLISHED. That contradicts RELEASE.md §1.2.7/§1.8. The console summary lists them; the irreversible artifact does not.
- **Fix:** The source notes must carry `NOT_CHECKED_PENDING`, and a second check confirms the rendered notes carry the not-checked section, so the marker cannot be dropped between staging and publication.
- **Evidence after:** Committed in d8e7a13. The gate condition extracted from the script, run against a notes file with the marker and one without: before → PASS/PASS (the defect), after → PASS/FAIL. The `with` case is the control against over-rejection. bash -n and shellcheck clean over install.sh, provision-node.sh and tools/*.sh; 18 harness tests pass.
- **Commit:** `d8e7a13`

### A0046 — Include and exclude domains are space-joined but Mojeek documents comma separation, so the filters never apply

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/WebSearchCore/Providers/MojeekProvider.swift:78-79,87-88`
- **Category:** correctness/request-encoding
- **Host:** Node1
- **Discovered by:** Providers tier A review (subagent)
- **Evidence before:** joined(separator: " ") for both `fi` and `fe`. Mojeek's parameter docs and this repo's docs/provider-api-notes.md:58 say comma separated ("Comma separated domain names"). A space-joined list is sent as one malformed domain, so a caller's filter is silently ignored (unfiltered results) or returns nothing.
- **Fix:** `fi`/`fe` join include and exclude domains with "," instead of " ", matching what Mojeek documents and what docs/provider-api-notes.md:58 already recorded. Test lives in its own MojeekDomainFilterTests.swift, because adding it to ProviderContractTests pushed that file past its length envelope.
- **Evidence after:** With the source fix stashed the new test fails on exactly the defect: XCTAssertEqual failed: ("Optional(\"example.com example.org\")") is not equal to (\"Optional(\"example.com,example.org\")\"). With it, it passes. Compared through queryItems so the assertion is the value Mojeek receives, not Foundation's escaping. Full suite 597 tests (555 + 42), 6 skipped, 0 failures, 0 warnings; swift-format --strict and swiftlint --strict both exit 0.
- **Commit:** `f6df2a4 + d3e5d9d`

### A0047 — Bot-challenge markers are substring-matched against the whole page, so ordinary queries are discarded as challenges

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/WebSearchCore/Providers/ScraperSupport.swift:38-52`
- **Category:** correctness/false-positive
- **Host:** Node1
- **Discovered by:** Providers tier A review (subagent)
- **Evidence before:** challengeMarkers.contains { lowered.contains($0) } against the entire response body, which includes the echoed query and every result title and snippet. Searching "anomaly detection", "captcha", "blocked" or "anubis" makes a legitimate results page contain the marker, so parse returns .botChallenge with zero results and DuckDuckGo:119-121 / Startpage:104-106 throw providerUnavailable — transient, so it also counts toward the circuit breaker. The single word "blocked" makes this routine.
- **Fix:** `parse` parses first and reports a block only when the page yielded no results, choosing `.botChallenge` vs `.unknownMarkup` at that point, instead of matching markers against the whole response body before parsing.
- **Evidence after:** With the source fix stashed the new test fails on both symptoms: XCTAssertNil failed: "botChallenge" and ("0") != ("1"). With it, it passes and both existing interstitial tests still detect theirs. Suite green at 599 tests (557 + 42), 6 skipped, 0 failures, 0 warnings; both linters exit 0.
- **Commit:** `4310e93`

### A0048 — Cancellation is mapped to a transient network failure, so a caller cancel is charged to the provider's breaker

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/WebSearchCore/Providers/HTTPStatusMapper.swift:48,52`
- **Category:** concurrency/cancellation
- **Host:** Node1
- **Discovered by:** Providers tier A review (subagent)
- **Evidence before:** Both `if error is CancellationError` and `case .cancelled` return .networkFailure(provider, "cancelled"), whose .network category isTransient, so CircuitBreaker.recordFailure increments consecutiveFailures and can open. URLSessionHTTPClient.perform converts in-flight cancellation into HTTPError.cancelled, so the orchestrator's `catch is CancellationError` arm never sees it. Same defect as A0030 seen from the mapping side; both must be fixed together or the breaker still trips. NOTE: closed by the same change as A0030. The mapper's two cancellation arms still return .networkFailure, which remains semantically wrong for any future caller, but they are no longer reachable from the orchestrator path that charges the breaker — the defect's harm is removed at the point it mattered, and the residual is recorded here rather than claimed fixed.
- **Fix:** `SearchOrchestrator.runSingle` now recognises cancellation in both shapes via a new `isCancellation(_:)` (CancellationError and HTTPError.cancelled), so the transport's shape no longer falls into the generic arm that mapped it to a transient network failure. The same fix closes A0048, which is the mapping half of this defect: with the orchestrator catching cancellation first, that arm is no longer reached from the path that charges the breaker.
- **Evidence after:** Before: category .network ("Tavily network failure: cancelled") and authorize(.tavily) returned .circuitOpen — charged as transient AND the probe never released. After: category .cancelled and the probe is claimable. Suite green at 600 tests (558 + 42), 0 failures, 0 warnings; both linters exit 0.
- **Commit:** `c3349bd`

### A0049 — A handshake that was assigned a session id and then failed leaves sessionID set, so initialization is never retried

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Sources/WebSearchCore/Providers/ParallelMCPProvider.swift:178,187-192,311-313`
- **Category:** state-machine
- **Host:** Node1
- **Discovered by:** Providers tier A review (subagent)
- **Evidence before:** send captures MCP-Session-Id (311) before the caller interprets the body, so if performHandshake then throws — a JSON-RPC error returned (:208-214) or an unparsable body (:318-322, thrown after 311) — ensureInitialized clears only `handshake`, leaving sessionID non-nil. Every later call returns at 178 and never sends notifications/initialized (:222) or re-runs tools/list (:225), so the provider stays half-initialized for the process lifetime. The doc comment at :175-176 ("A failed handshake is not cached, so the next caller retries it") is therefore false. Related: a 404 for an expired session is mapped to providerUnavailable and never clears sessionID, though the MCP spec requires re-initialize on 404.
- **Fix:** A failed handshake clears sessionID/resolvedToolName/resolvedToolSupportsMaxResults as well as the cached task, and a 404 clears sessionID and handshake so the next caller re-initialises.
- **Evidence after:** Before: the new test failed with ("1") != ("2") — the second search never re-handshook. After: it issues its own initialize. Suite green at 604 tests (562 + 42), 0 failures, 0 warnings; both linters exit 0.
- **Commit:** `9113cd6`

### A0050 — URL query construction drops '+', so queries containing it are corrupted

- **Severity / tier / status:** S1 / A / DONE
- **Location:** `Providers/BraveProvider.swift:83, DuckDuckGoProvider.swift:77, MojeekProvider.swift:92, OpenWebSearchProvider.swift:73, SearXNGProvider.swift:66, StartpageProvider.swift:73`
- **Category:** correctness/encoding
- **Host:** Node1
- **Discovered by:** Providers tier A review (subagent)
- **Evidence before:** components.queryItems = items at all six sites. Foundation's queryItems setter validates with the .queryItem allowed mask, which includes '+', so q=C++ is emitted literally instead of C%2B%2B. DuckDuckGo, Startpage and SearXNG are form-style GET endpoints that decode '+' as a space, so the query becomes 'C' and the results are wrong for C++, A+B and regex queries. No test asserts query percent-encoding.
- **Fix:** `URLComponents.setQueryItemsEscapingPlus(_:)` escapes `+` to `%2B` after assigning query items; all six providers that built a request URL this way now use it.
- **Evidence after:** Before: the request URL was `?q=C++%20concurrency`. After: `q=C%2B%2B%20concurrency`. A second test pins that a comma in a value is left alone, so the helper is not a general re-encoder. Suite green at 603 tests (561 + 42), 0 failures, 0 warnings; both linters exit 0.
- **Commit:** `81f1618`

### A0006 — Validation is written as `assert`, which python -O strips

- **Severity / tier / status:** S2 / A / DONE
- **Location:** `scripts/mcp_smoke.py:147,161,167,204,211,533; scripts/soak.py:160,166,199,208`
- **Category:** python/assert
- **Host:** Node1
- **Discovered by:** Phase A Python review (§1 pitfall list)
- **Evidence before:** Ten `assert` statements guard real conditions, including the environment-scrub check (mcp_smoke.py:147) and a port-race check (mcp_smoke.py:533). Running the harness under `python3 -O` silently disables every one of them, so the check would report success while asserting nothing.
- **Fix:** All eight assert sites became real checks: the credential-scrubbing check raises `Failure`, the five typing asserts became named errors or no-ops, and the bind-race message no longer needs an assert to be well-formed.
- **Evidence after:** Committed in 6c57464. The converted credential check runs on its real path: the stdio smoke test passes end to end against the built server, and 18 harness tests pass. No assert remains in `scripts/`, so `python -O` no longer removes any check. A0004's entry carries the S101 proof.
- **Commit:** `6c57464`

### A0010 — Installing overwrites the previous binary in place with no rollback path

- **Severity / tier / status:** S2 / A / DONE
- **Location:** `deploy/install.sh:110-124,518,531`
- **Category:** ops/rollback
- **Host:** Node1
- **Discovered by:** L7 ops pass (subagent)
- **Evidence before:** cp of the new binary over $BIN, with no backup of the previous one, no version pin to reinstall and no uninstall path (grep finds no rollback/uninstall/backup/revert in deploy/, tools/ or Sources/). config.env is staged safely and keys are preserved, so the binary is the only irreversible part.
- **Fix:** A new `install_binary` copies beside `$BIN`, sets the mode on the staged file, and moves it into place, removing the staged file on either failure. The path is always either the old binary or the new one.
- **Evidence after:** Committed in 3a9edcb. `install_binary` extracted from the script, run against a `cp` stub that truncates the destination then fails: before, BIN held "partial"; after, BIN held the untouched "GOOD OLD BINARY". The failure mode is simulated because the real `cp` cannot be made to fail half-way without filling a disk. Two harness mistakes produced a passing before-state first and were corrected; the commit records both. bash -n and shellcheck clean; 18 harness tests pass.
- **Commit:** `3a9edcb`

### A0016 — An over-cap transfer may keep streaming after the cap is hit (UNSURE)

- **Severity / tier / status:** S2 / A / OPEN
- **Location:** `Sources/WebSearchCore/Support/BoundedResponseBody.swift:37-40`
- **Category:** resource/unbounded
- **Host:** Node1
- **Discovered by:** Fetch tier A manual review (subagent, marked UNSURE)
- **Evidence before:** Throwing ResponseBodyTooLarge out of `for try await byte in stream` finishes the task normally; nothing cancels the underlying URLSessionDataTask and DirectHTTPFetcher sets no timeoutIntervalForResource. If Foundation does not cancel on AsyncBytes deinit, a hostile endless body keeps arriving. Marked UNSURE: what would settle it is inspecting this Foundation's AsyncBytes deinit/cancellation behaviour or observing the data task after the throw.

### A0022 — The PTY master and slave fds leak when the spawn raises

- **Severity / tier / status:** S2 / C / DONE
- **Location:** `scripts/monitor_tty_smoke.py:196,230-239`
- **Category:** resource/leak
- **Host:** Node1
- **Discovered by:** Python scripts tier review (subagent), statically verified against the code
- **Evidence before:** pty.openpty() then os.close(slave) only after a successful subprocess.Popen. A FileNotFoundError or EMFILE in that gap leaks both fds and never closes self.master; check_ctrl_c_quits_cleanly starts three sessions, so several can leak.
- **Fix:** Everything after `openpty` is wrapped in `try`/`except BaseException`, and the handler closes both ends before re-raising.
- **Evidence after:** Committed in eed50a6. The module loaded directly, `Session` constructed with a nonexistent binary so `Popen` raises: before, fds 4 -> 6 (leak of 2); after, 4 -> 4 across three attempts, counted with `len(os.listdir("/dev/fd"))`. A first attempt at the re-indent corrupted the block via stale line numbers and was reverted and redone. ruff, ruff-format and pyright clean; 18 harness tests pass.
- **Commit:** `eed50a6`

### A0023 — A failed signal case leaks the stub's socket and thread

- **Severity / tier / status:** S2 / C / DONE
- **Location:** `scripts/monitor_tty_smoke.py:599`
- **Category:** resource/leak
- **Host:** Node1
- **Discovered by:** Python scripts tier review (subagent), statically verified against the code
- **Evidence before:** stub.stop() sits after the for loop; only session.close() is in a finally. A Failure inside the loop skips stub.stop(), leaving the HTTP stub bound until process exit.
- **Fix:** The loop is wrapped in `try`/`finally` and `stub.stop()` is in the `finally`, so it runs whether the cases pass, fail, or raise.
- **Evidence after:** Committed in 5ec56c6. The real function run with a spy stub that records `stop()` and a `Session` whose `drain` raises: before, calls = ['session.close'] and stub.stop() was skipped; after, ['session.close', 'stub.stop']. The doubles replace only the process spawn and the HTTP stub; the control flow under test is the file's own. ruff, ruff-format and pyright clean; 18 harness tests pass.
- **Commit:** `5ec56c6`

### A0024 — Per-instance stub state lives on the handler class, so two concurrent stubs would share it

- **Severity / tier / status:** S2 / C / DONE
- **Location:** `scripts/searxng_stub.py:31-33,51-54`
- **Category:** shared-state
- **Host:** Node1
- **Discovered by:** Python scripts tier review (subagent), statically verified against the code
- **Evidence before:** status, payload and requests are class attributes mutated per instance. The docstring's claim that each caller building its own server avoids sharing is false for payload/status/log. Both current callers create stubs sequentially, so there is no live failure today; a second concurrent stub, or a handler thread outliving close() (shutdown() does not join handler threads), would serve the wrong body and clobber the log. UNSURE only in that nothing exercises it yet.
- **Fix:** A `_StubState` object per stub, carried by a typed `_StubServer` subclass and read by the handler through `self.server`. The handler class holds no state.
- **Evidence after:** Committed in 59e5d37. Two stubs built in sequence, A asked before and after B exists: before, A answered {"from":"B"} with status 503 and its own '/search?q=1' had been erased; after, A answers {"from":"A"} with 200, A.requests = ['/search?q=1', '/search?q=2'] and B.requests = []. The typed subclass was needed because pyright strict cannot see a dynamic attribute through `self.server`. ruff, ruff-format and pyright clean; 18 harness tests pass.
- **Commit:** `59e5d37`

### A0025 — The test depends on the developer's ambient config.env and contradicts the function it tests

- **Severity / tier / status:** S2 / C / DONE
- **Location:** `scripts/harness_tests.py:265`
- **Category:** test-portability
- **Host:** Node1
- **Discovered by:** Python scripts tier review (subagent), statically verified against the code
- **Evidence before:** assertNotIn("MOJEEK_API_KEY", values) after load_secret_values(), which unconditionally appends <repo>/config.env as a candidate (soak.py:301-302). The temp config defines only TAVILY and BRAVE, so MOJEEK falls through to the repository file: a developer whose git-ignored config.env defines MOJEEK_API_KEY fails locally while CI passes.
- **Fix:** `load_secret_values` takes an optional `repository_root`, and the test points it at an empty directory. Production behaviour is unchanged: without the argument the repository-root `config.env` is still scanned.
- **Evidence after:** Committed in 3379a46. With an ambient MOJEEK_API_KEY appended to the real config.env: before, the test failed with "'MOJEEK_API_KEY' unexpectedly found in {...}"; after, all 18 harness tests pass. The real config.env was backed up and verified byte-identical afterwards. ruff, ruff-format and pyright clean.
- **Commit:** `3379a46`

### A0026 — No read timeout, and the early-close path blocks on stderr of a possibly-live child

- **Severity / tier / status:** S2 / C / DONE
- **Location:** `scripts/mcp_smoke.py:168,170,206`
- **Category:** reliability/hang
- **Host:** Node1
- **Discovered by:** Python scripts tier review (subagent), statically verified against the code
- **Evidence before:** readline() with no timeout; on failure the message calls stderr_text(), which does process.stderr.read(). Closing stdout is not exiting: if the child is alive, read() waits for EOF and the smoke test hangs instead of reporting the failure it already detected.
- **Fix:** Daemon threads drain stderr into a lock-guarded buffer and stdout into a queue, so `read_message(timeout:)` has a deadline and `stderr_text()` never blocks; `close()` kills a child that will not exit.
- **Evidence after:** Committed in 4ff6609. Before, under a 15s wall clock: read_message() against a silent child and stderr_text() against a live child with 3000 stderr lines both exited 124 (hung). After: read_message(timeout=2.0) raised after 2.0s with the timeout message, and stderr_text() returned 160 893 characters in 0.00s — ten times the pipe's capacity. The (a) probes differ because the old signature has no timeout at all, which is the finding; both are stated. ruff, ruff-format and pyright clean; 18 harness tests and the stdio smoke pass.
- **Commit:** `4ff6609`

### A0033 — A rejected URL-valued setting is echoed verbatim into a diagnostic that is logged, contradicting the type's own contract

- **Severity / tier / status:** S2 / A / DONE
- **Location:** `Sources/WebSearchCore/Support/AppConfiguration.swift:401 (also :373,:385); Sources/SwiftWebSearchMCP/main.swift:44-50`
- **Category:** security/credential-in-log
- **Host:** Node1
- **Discovered by:** MCP surface tier A review (subagent) and Search + Support tier A review (subagent)
- **Evidence before:** record(.invalidURL, key, "'\(raw)' is not an http(s) URL with a host") interpolates the raw value, and main.swift logs issue.detail. Four keys are URL-typed and may carry an embedded token; a schemeless value such as search.example.com/mcp?token=... is realistic. This contradicts AppConfiguration.swift:106-107 ("Never contains a credential") and the comment at main.swift:44. Reported independently by two review agents; UNSURE whether operators embed secrets in those settings.
- **Fix:** The three `record(...)` sites report the key and the reason only, so no diagnostic can carry a configured value. The key is still named, so an operator loses nothing they need.
- **Evidence after:** Before: the test failed with the token in the diagnostic — "the value reached a loggable diagnostic: 'search.example.com/mcp?token=s3cr3t-token-value' is not an http(s) URL with a host". After: it passes. Suite green at 605 tests (563 + 42), 0 failures, 0 warnings; both linters exit 0.
- **Commit:** `219762f`

### A0034 — A repeated name in SEARCH_PROVIDER_ORDER is not deduplicated, so one provider can vote twice

- **Severity / tier / status:** S2 / A / DONE
- **Location:** `Sources/WebSearchCore/Support/AppConfiguration.swift:447-448`
- **Category:** correctness/ranking
- **Host:** Node1
- **Discovered by:** Search + Support tier A review (subagent)
- **Evidence before:** `seen` is seeded from `parsed` but `full` starts as `parsed` with duplicates intact; the dedup loop only guards providers appended afterwards. SEARCH_PROVIDER_ORDER=tavily,tavily,brave yields two Tavily entries, and select takes ordered.prefix(maxDirectProviders), so balanced fans out to Tavily twice and never to Brave. RankFusion's duplicate guard is per response, so identical URLs from both responses each get a full contribution. Requires an operator typo. NOTE ON THIS AUDIT'S OWN RECORD: the A0034 fix commit (6efcc38) says the complexity overrun came from 'my first attempt at this task' having been committed before the linter ran. That is wrong: the linter WAS run before committing A0034 and caught the overrun, which is why this commit is clean. The commit-before-linting slip belongs to A0046 (f6df2a4). The message cannot be corrected because rewriting history is forbidden, so the correction lives here.
- **Fix:** `AppConfiguration.parse` resolves `SEARCH_PROVIDER_ORDER` through a new `resolvedProviderOrder(from:)` that deduplicates the operator's list as it seeds the result, then appends the remaining providers. The extraction also takes `parse` back under the cyclomatic-complexity envelope my inline fix had pushed it one over.
- **Evidence after:** With the source fix stashed the new test fails on both counts — ("[tavily, tavily]") != ("[tavily, brave]") and count 10 != 9. With it, it passes, the neighbouring order test still passes, and the suite is green at 598 tests (556 + 42), 6 skipped, 0 failures, 0 warnings; swift-format --strict and swiftlint --strict exit 0.
- **Commit:** `6efcc38`

### A0039 — --bind is accepted and silently dropped by the docker method

- **Severity / tier / status:** S2 / A / DONE
- **Location:** `deploy/install.sh:269-284`
- **Category:** config-ignored
- **Host:** Node1
- **Discovered by:** installer/release shell tier A review (subagent)
- **Evidence before:** install_searxng_docker hardcodes -p 127.0.0.1:${PORT}:8080 and never uses BIND, so --bind 0.0.0.0 binds loopback only whenever the method resolves to docker. The sibling adopt path warns explicitly when --bind was not applied, so this is an unintended silent drop rather than a stated limitation: a node is unreachable from other machines while the install reports success.
- **Fix:** The publish mapping is `-p "${BIND}:${PORT}:8080"` and the message names the same address, so the docker method honours `--bind` as the native one does.
- **Evidence after:** Committed in 63b4abd. The `docker run` command extracted and run against a stub `docker` that prints the `-p` argument: before, both BINDs gave 127.0.0.1:8888:8080; after, 127.0.0.1 is unchanged (the control) and 0.0.0.0 gives 0.0.0.0:8888:8080. bash -n and shellcheck clean; 18 harness tests pass. Two harness mistakes and one shell mistake were made and corrected while proving it, and are recorded in the commit.
- **Commit:** `63b4abd`

### A0040 — The documented invocation puts the sudo password on a command line and into the child environment

- **Severity / tier / status:** S2 / A / DONE
- **Location:** `deploy/provision-node.sh:6`
- **Category:** security/credential-disclosure
- **Host:** Node1
- **Discovered by:** installer/release shell tier A review (subagent)
- **Evidence before:** The header example is ssh node1@node1.local 'SUDO_PASSWORD=... bash -s'. sshd runs that through the user's shell, so the value is in the shell's argv on the node (readable via ps) and in the local ssh argv, and it is inherited by every child. The code itself is correct (it pipes the password to sudo -S from stdin); the leak is created by the documented interface.
- **Fix:** The documented invocation reads the password from a 600 file on the node: `ssh ... 'SUDO_PASSWORD="$(cat ~/.mcps-sudo)" bash -s'`, so the value lands in the environment rather than in any argv, local or remote. The script body was already correct (it pipes the password to `sudo -S` on stdin).
- **Evidence after:** The header no longer contains a literal password placeholder in the command string; the only thing the remote argv carries is the filename. bash -n and shellcheck -S warning clean.
- **Commit:** `f84cd47`

### A0042 — `rm -rf $STAGE/$VERSION` runs even after the identity gate failed, and VERSION is never validated in this script

- **Severity / tier / status:** S2 / A / DONE
- **Location:** `tools/release.sh:76,233-235`
- **Category:** destructive-without-validation
- **Host:** Node1
- **Discovered by:** installer/release shell tier A review (subagent)
- **Evidence before:** VERSION is only whitespace-stripped; the only X.Y.Z validation is tools/check-version.sh via run_gate, which records FAIL and continues. A VERSION containing .. or / therefore reaches the deletion with a path outside the staging directory (VERSION=.. deletes the release cache root, including the gate logs). ${:?} covers empty/unset only. Publication is still blocked by fails, so the consequence is deletion rather than a bad release. UNSURE on exploitability: VERSION is reviewed input.
- **Fix:** `VERSION` must match `^[0-9]+\.[0-9]+\.[0-9]+$` or the script exits 2, and the stage is cleared only when `fails` is zero; otherwise it is reported NOT CHECKED.
- **Evidence after:** Committed in e6c6e1c. Blocks extracted from the script: VERSION — `1.2.3` accepted, `1.2`/`../..`/`1.2.3/../../etc`/`v1.2.3` refused. Stage with a sentinel from a previous run — fails=0 destroys it (control), fails=1 leaves it and reports NOT CHECKED. bash -n and shellcheck clean; 18 harness tests pass. My first stage-evidence attempt set `STAGE` rather than `RELEASE_STAGE`, so it ran against the default cache path; it removed and recreated an empty `release/1.2.3`, which was confirmed empty and removed.
- **Commit:** `e6c6e1c`

### A0043 — The test-suite count is reported as PASS without checking that it parsed

- **Severity / tier / status:** S2 / A / DONE
- **Location:** `tools/release.sh:212-213`
- **Category:** misleading-report
- **Host:** Node1
- **Discovered by:** installer/release shell tier A review (subagent)
- **Evidence before:** `read -r total bundles skipped <<<"$counts"` then pass "test suite: $total tests ...", with no check that the python parse succeeded. If it fails or XCTest's log format changes, the gate still prints PASS with blank counts, contrary to RELEASE.md §1.5.2. The suite is genuinely gated by swift test's exit status, so this is a misleading report rather than a false green.
- **Fix:** Fewer than one bundle or fewer than one test fails the gate, naming what was parsed, so an unreadable count cannot be reported as a pass.
- **Evidence after:** Committed in d3c3778. The script's own parser, run against a well-formed log and one with XCTest's wording changed: good → PASS "614 tests across 2 bundles" before and after; changed → PASS "0 tests across 0 bundles, 0 skipped, 0 failures" before, FAIL after. The good log is the control. bash -n and shellcheck clean; 18 harness tests pass.
- **Commit:** `d3c3778`

### A0044 — `--dry-run` creates the SearXNG directory, so it does change the filesystem

- **Severity / tier / status:** S2 / A / DONE
- **Location:** `deploy/install.sh:300`
- **Category:** dry-run-honesty
- **Host:** Node1
- **Discovered by:** installer/release shell tier A review (subagent)
- **Evidence before:** mkdir -p "${SEARXNG_DIR}" is the one mutation in the native path not routed through the run helper that exists so "--dry-run is honest rather than decorative", and it is not behind a DRY_RUN guard. deploy/install.sh --dry-run --method native leaves a directory behind while the help text promises it will change nothing.
- **Fix:** The call goes through `run`. The other two bare `mkdir` calls were checked rather than assumed: line 144 is inside `if [ "$DRY_RUN" -eq 0 ]` and line 380 is in the `else` of a `DRY_RUN` test.
- **Evidence after:** Committed in 4f454ad. The script's own `run()` extracted from the file: under --dry-run the bare form created the directory and the staged form creates nothing; under a real run both create it, which is the control. bash -n and shellcheck clean; 18 harness tests pass.
- **Commit:** `4f454ad`

### A0051 — Mojeek timestamp is read but never requested, so publishedAt is always nil (UNSURE)

- **Severity / tier / status:** S2 / A / OPEN
- **Location:** `Sources/WebSearchCore/Providers/MojeekProvider.swift:143`
- **Category:** correctness/date
- **Host:** Node1
- **Discovered by:** Providers tier A review (subagent)
- **Evidence before:** item.timestamp is read, but Mojeek's `date` flag is opt-in and defaults to 0 and the provider sends no date=1 (it sends no such parameter at :55-69), so every Mojeek result may have a nil date. The repo's notes say timestamp appears only when the flag is requested. UNSURE: settled by one live request with and without date=1.

### A0027 — A lost bind race abandons the exited child unreaped

- **Severity / tier / status:** S3 / C / OPEN
- **Location:** `scripts/mcp_smoke.py:517-523`
- **Category:** resource/leak
- **Host:** Node1
- **Discovered by:** Python scripts tier review (subagent), statically verified against the code
- **Evidence before:** Under except BindRace the code records last_race and continues; only the except Failure branch cleans up. The child has exited (that is what makes it a BindRace) but is never waited and its pipes are never closed; up to HTTP_START_ATTEMPTS = 3 sets leak per run.

### A0052 — The documented test count is stale after A0045 added three tests

- **Severity / tier / status:** S3 / C / DONE
- **Location:** `AGENTS.md:80, README.md:201, docs/release-notes-v1.2.0.md, wiki Home.md`
- **Category:** docs/stale-number
- **Host:** Node1
- **Discovered by:** the audit's own change (A0045 bumped 593 to 596)
- **Evidence before:** AGENTS.md and README.md state 593 tests; the suite is now 554 + 42 = 596 after the three SearXNG answer-shape tests. §6: code the audit's own changes orphaned.
- **Fix:** AGENTS.md (both the layout count and the `swift test` comment), README.md and the wiki Home page now say 597 tests (555 + 42). The v1.2.0 release notes were checked and do not state a count, so no historical record was touched.
- **Evidence after:** grep for the stale strings returns nothing in AGENTS.md, README.md or wiki Home.md.
- **Commit:** `db39cb7 (repo) + 1d9c47d (wiki)`

### A0053 — /health readiness reflects configuration, not reachability

- **Severity / tier / status:** S3 / A / OPEN
- **Location:** `Sources/SwiftWebSearchMCP/main.swift (the health source)`
- **Category:** ops/health-scope
- **Host:** Node1
- **Discovered by:** residual of the audit's own A0007 fix (§6)
- **Evidence before:** After A0007 the body is derived, so it is no longer a facade, but `ready` is computed from `configured` alone: a provider that is configured and unreachable still reports ok. That is a deliberate limit — probing a provider inside a liveness endpoint adds network latency and a new failure mode to the probe — but it means an operator cannot distinguish 'configured' from 'working' without calling web_search_status. Recorded so the limit is a decision on the record rather than an unstated gap, and so nobody later reads a 200 as proof that search works.

### A0054 — The documented test count drifted from the suite as the audit added tests

- **Severity / tier / status:** S3 / C / DONE
- **Location:** `AGENTS.md:36, AGENTS.md:82, README.md:201, wiki Home.md:18, wiki Home.md:128`
- **Category:** documentation/accuracy
- **Host:** Node1
- **Discovered by:** The workspace instructions surfaced it: AGENTS.md is injected into the session and it stated 597 tests while the suite reported 610.
- **Evidence before:** AGENTS.md said 555 + 42 and 597; README.md said 597; the wiki said 597 twice.
- **Fix:** All five sites now say 610 — 568 in WebSearchCoreTests and 42 in MCPSMonitorTests — which is what `swift test` reports. Repo and wiki committed separately, as they are separate repositories.
- **Evidence after:** `swift test` reports 568 + 42 = 610. Repo commit f1eaf41, wiki commit 0a5582d. The counts now match the suite and the per-target split matches the actual target sizes.
- **Commit:** `f1eaf41`
