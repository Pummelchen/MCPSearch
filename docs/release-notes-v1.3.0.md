# MCPSearch 1.3.0 — release notes

Released 2026-09-18. A hardening release. Almost nothing here is new capability: it is behaviour that
was documented but not implemented, checks that could not fail, and one bypass in a guard that existed
specifically to stop a crash. The full set of findings, including the ones with no user-visible effect,
is in [`AUDIT/ledger.md`](../AUDIT/ledger.md).

## The nesting guard could be walked past

`MarkupDepth` measures how deeply a fetched document nests and refuses anything past 512, because a
deeply nested document can exhaust the stack in the parser. Its model of HTML was wrong in a way that
made the guard decorative.

It decremented a counter on every closing tag, under a comment claiming *"a closing tag always returns
to the parent, even if it never matched one"*. That is false. `</p>` with no open `p` closes nothing, so

```html
<div></p><div></p><div></p>…   <!-- repeated -->
```

nests 100 000 elements deep while the counter reads 0 or 1. Measured through the parser, that document
**did not finish within ten minutes**, in under a megabyte, inside the fetch size cap.

The guard now keeps a stack of open element names, ignores a closing tag that matches nothing, and
models HTML's implied end tags — the block set closes a paragraph, `li` closes `li`, a table row closes
within its own table, and a `<tr>` with no section gets the parser's implicit `<tbody>`. It is now
measured against real pages as well as fixtures: 37 pages fetched from the web, of which 34 are exact,
3 over-count (the safe direction), and **none under-count**.

**Check:** `swift test --filter MarkupDepthTests`. The real-page run is opt-in:
`MARKUP_DEPTH_CORPUS=<dir> swift test --filter testTheModelAgainstARealPageCorpus`.

## `web_open` now checks where it connected

The SSRF policy validates the addresses a hostname resolves to and then hands the hostname to
`URLSession`, which resolves it again when it connects. A name whose answer changes in between — DNS
rebinding — could still land on a private address, and `URLSession` offers no way to pin it.

The fetch now reads the address the connection actually used from `URLSessionTaskMetrics` and refuses
the body unless it was one the policy resolved for that host. Two cases fail closed: a peer outside the
validated set, and a connection that reported no address at all.

This is **detection, not prevention**. The connection is still made; because `web_open` issues `GET`
only, the side effects a blind request can cause are limited, and the attacker does not receive the
response.

**Check:** `swift test --filter PeerAddressGuardTests` — a validated peer returns its body, an
unvalidated one is refused, and an empty validated set skips the check. With the refusal disabled on
purpose the second test fails, so the test is known to be able to fail.

## SearXNG answers were being discarded

The SearXNG JSON API answers with `results` as an array of objects, and this build decoded it as
`[String]`. An instance that answered a query correctly produced **no results at all**.

## `/health` was wired to nothing

`GET /health` returned a hardcoded `ok`, so the production health surface reported success regardless.
It reports real readiness now, and readiness reflects reachability rather than configuration alone. The
check that consumes it reads the body, not just the status code — reading the code was the reason a
hardcoded body went unnoticed.

## Credentials that travelled further than they should

- A credential in a target URL's query or fragment was forwarded to the third-party reader on the
  fallback path. It is stripped before the fallback.
- The generated SearXNG secret was passed as a command-line argument, where `ps` could read it. It
  travels through a file with restrictive permissions.
- The credential-leak scan ran only on the fully successful path, and only over stderr, so a failure
  that echoed a credential was never scanned.
- A rejected URL-valued setting was echoed verbatim into a diagnostic that is logged.
- The documented installer invocation put the sudo password on a command line and into the child's
  environment.

## Gates that could not fail

Each of these was "passing" for a reason unrelated to what it claimed to check:

- The mandatory-SearXNG proof accepted an instance that returned **zero results**.
- The end-to-end gate accepted a JSON-RPC **error** reply as success.
- The test-suite count was reported as `PASS` without checking that it parsed.
- The release-notes gate named `NOT CHECKED` in its failure message but never checked for it.
- The secret scan was blind to the credential pattern this repository actually uses, and one `gitleaks`
  config cannot carry both the defaults and custom rules in this version — it is two passes now.
- `-warnings-as-errors` was not in the build config, SwiftLint could not reject a force-unwrap, and Ruff
  did not select `S101`, so the language-standard proof the release process claimed was not in force.

## Also fixed

Cancellation was mapped to a provider failure, so a caller who cancelled was charged to that provider's
circuit breaker. The response charset was discarded, so a page declaring anything but UTF-8 was decoded
as Latin-1. A `+` in a query was dropped while building the URL. An empty extraction was returned as a
success, discarding the real error. Bot-challenge markers were substring-matched against the whole page,
discarding ordinary results. Mojeek's domain filters were space-joined where it documents commas. The
installer could drop every API key when a `|| true` swallowed a `grep` error. Installing overwrote the
previous binary with no rollback. A half-open circuit-breaker probe was never released when the rate
limiter denied.

## Checksums

- `mcps-1.3.0-macos-arm64.tar.gz` — SHA256 `SHA256_PENDING`, `ARCHIVE_BYTES_PENDING` bytes.
- Published beside the archive: `mcps-1.3.0-macos-arm64.tar.gz.sha256` and `SHA256SUMS`, both carrying
  that same digest.

## Checks that did not run

- **Live provider tests.** `SEARCH_LIVE_TESTS` was not set and no usable key was available, so
  `LiveProviderTests` was skipped, as it is in CI. Every provider is covered against stubs.
- **The real-page depth corpus is opt-in** and is not part of the default suite, so CI does not fetch
  pages. The measurement quoted above was run by hand against 37 pages.
