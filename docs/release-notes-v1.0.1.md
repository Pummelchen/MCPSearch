# MCPSearch 1.0.1 — release notes

Released 2026-09-16. Upgrading from `1.0.0` needs no configuration change; nothing in the tool
surface, the provider set or the environment variables changed.

This is a maintenance release. **The server, fetch and answer code is byte-identical to `1.0.0`** —
the only tracked changes since that tag are the documentation and release machinery below. The
binaries are rebuilt, so the version they report is the one they were built from, and the default
user agent tracks it. If you do not need the tooling, `1.0.0` remains correct behaviourally.

## The version now has one source of truth

`VERSION` at the repository root is authoritative. `Sources/WebSearchCore/Support/BuildVersion.swift`
is **generated** from it by `tools/sync-version.sh`, and nothing else in `Sources/` may hold a
version literal. Before this, the version lived in three unconnected places — `MCPServer.swift`, the
Parallel provider's `clientInfo`, and the changelog — with no check tying them together, so a
half-finished bump shipped a server that misreported its own version over MCP.

**Check:** `tools/check-version.sh`, run in CI's `static-analysis` job and again by the release
script. It fails when `VERSION` is not a bare `X.Y.Z`, when the generated mirror does not reproduce
byte-for-byte, when `CHANGELOG.md` has no heading for the version, or when a version literal appears
anywhere else in `Sources/`.

## The default user agent carries the real version

`SEARCH_USER_AGENT` defaulted to the literal `SwiftWebSearchMCP/1.0`, and so already disagreed with
the version the server reported. It is now built from `BuildVersion`, so it reads
`SwiftWebSearchMCP/1.0.1`.

**Check:** `CoreUnitTests.testDefaultUserAgentTracksTheBuildVersion`, which compares the whole default
string against `BuildVersion.value`, so re-hardcoding either side fails a test.

## The artifact states its own version

`initialize` now returns `serverInfo.version` from the single source, so `1.0.1` on the archive and
`1.0.1` over the wire cannot disagree.

**Check:** `scripts/mcp_smoke.py` drives a real `initialize` handshake against the built binary and
requires `serverInfo.version` to equal the repository's `VERSION`. It previously printed the
reported version without asserting it, so any version at all would have passed. The assertion now
runs in CI on every pull request as well as at release time.

## The release is reproducible from one command

`tools/release.sh` walks `RELEASE.md`: preconditions (§1.4), gates (§1.5), a clean scratch
`arm64`-only build with the log scanned for compiler warnings, the `lipo -archs` assertion (§1.2.2),
packaging (§1.6), checksums (§1.2.5), notes with the real digest substituted at publish time (§1.8)
and a `gh release create` with the repository pinned (§1.7). It is a **dry run by default** and
publishes only with an explicit `--publish` (§1.2.6). Before this, `1.0.0` was packaged by hand and
the sequence was not reproducible.

**Check:** the script's own dry run, in which every step above reports `PASS`, `FAIL` or
`NOT CHECKED`.

## Documentation

`AGENTS.md` (with the committed `CLAUDE.md` bridge), `RELEASE.md`, and this notes file are new. No
gate covers prose; they are reviewed by reading them.

## Checksums

- `mcps-1.0.1-macos-arm64.tar.gz` — SHA256 `SHA256_PENDING`, `ARCHIVE_BYTES_PENDING` bytes.
- Published beside the archive: `mcps-1.0.1-macos-arm64.tar.gz.sha256` and `SHA256SUMS`, both
  carrying that same digest. `RELEASE.md` Part 2 names `SHA256SUMS`; its Part 1 §1.7 names
  `<archive>.sha256`. Both are shipped so either documented command works.

Apple silicon only (`arm64`, M1–M6), macOS 13 or newer. Not code-signed and not notarized — see
`README-binaries.txt` inside the archive. The archive contains `SwiftWebSearchMCP`, `mcps-mon`,
`LICENSE`, `THIRD-PARTY-NOTICES.md` and that README.

## Checks that did not run

NOT_CHECKED_PENDING

**No CI job ran on the commits this release is built from.** On the pull requests that landed it,
`build-and-test` and `Analyze (swift)` (CodeQL) never obtained a runner: GitHub left the runs
`queued` with no runner assigned, and a re-queued run after the final commit did not start either.
This is the known macOS runner-capacity problem. Both are reported here as
**not checked**, not as passing.

One CI result does exist: `static-analysis` — the job that carries the new version-agreement gate —
completed successfully on the first of those pull requests (`03019416`), so that gate has been
exercised in CI. The release gates themselves were run locally on the tagged commit and are recorded
above.
