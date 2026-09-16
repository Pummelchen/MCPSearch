# MCPSearch 1.2.0 — release notes

Released 2026-09-17. Upgrading from `1.0.1` needs no configuration change, but **the defaults
changed** — the first section below is the one to read before upgrading.

## Every provider is on by default

The routes that need no credential — DuckDuckGo, Startpage and Parallel — were opt-in behind
`SEARCH_ENABLE_SCRAPERS` and `SEARCH_ENABLE_PARALLEL`, so an installation with no API keys could not
search at all. All nine providers are now enabled by default. A provider without a credential reports
`not_configured` and the others still serve the query, so a search on a host with no keys returns
results instead of the "no provider configured" error. The flags remain, as off switches.

**Check:** `CoreUnitTests.testDefaultsStartWithNoCredentials` asserts both flags are on in a default
configuration. Observed live: `web_search_status` with an empty environment lists all nine providers,
with `duckduckgo`, `startpage` and `parallel` `ready`, and a `web_search` returns results sourced from
the credential-free routes.

This change broke a check that had encoded the old assumption, and it is fixed below.

## Installing is one command, and SearXNG is mandatory

`deploy/install.sh` installs the server and refuses to report success without a **working local
SearXNG**. It adopts a running instance; installs one when there is none — the digest-pinned container
when a Docker daemon answers, otherwise native under `launchd`; proves it answers a real query on the
JSON API; installs the binary; writes `config.env`; and verifies a real `web_search` end to end. Any
failed gate exits non-zero.

The gate is the **JSON API, not `/healthz`**: an instance whose settings omit `json` answers health
checks with 200 and returns 403 to the API the server actually uses, which is the most common way a
self-hosted SearXNG "does not work".

**Check:** the installer was watched failing three ways before it was trusted — nothing listening, and
a mock answering `/healthz` 200 while refusing the JSON API, both exit 1; a mock returning real results
passes. It was then run end to end: node1 adopted its running instance, and a machine with no SearXNG
at all was installed from nothing and verified.

## Cluster nodes are provisioned natively

`deploy/provision-node.sh` used to build a Colima container with a digest-pinned image and a canary
swap, while every node ran SearXNG natively — so the scripted way to provision a node produced
something other than what was running. It is now thin and delegates to the installer, so the install
has one implementation. 538 lines to 290, and the removed ones were the copy that had drifted.

**Check:** run against a live node. It fetched the repository, invoked the installer, adopted the
running instance, verified a real query and reported the tailnet address. The `sudo` handshake is the
one part not exercised with a real password, because no machine in this deployment has passwordless
`sudo`; it is unchanged code from the previous script.

## The monitor no longer counts this machine twice

The default node list carried a loopback entry *and* the local machine's own Tailscale entry. They are
the same machine, so a four-machine fleet reported five nodes — and because the engine warning
threshold is a fraction of the node count, one machine's failing engine was doubled into
`engine 'duckduckgo' unavailable on 2 node(s)`, a fleet-level warning. The list is now derived from the
host, and the local instance is named after it.

`NodeProbe.Target.isLocal` existed for exactly this distinction and was write-only: set in five places,
never carried into `NodeStatus`, read nowhere. It is now carried through and used to give a down
*local* instance its own warning, because that means the server on this host has lost its local
provider — a different problem from a remote node being unreachable.

**Check:** `MonitorOptionsTests.testDefaultNodesCollapseTheLocalMachineOntoItsLoopbackEntry` asserts
the rule for an injected hostname; `MonitorActorTests.testALocalNodeDownIsCalledOutOnItsOwn` asserts
the separate warning. Observed live after the change: `SEARXNG NODES 4 up · 0 down`, one row per
machine.

## A match is no longer reported as a failure

`grep -q` exits at the first match, which SIGPIPEs the producer, and `set -o pipefail` turns that into
exit 141 — so the pipeline reports failure *precisely when it matched*. Measured: 141 with `pipefail`,
0 without. Four sites had it, in three scripts: the provisioner's "is the launchd job loaded", the
installer's "does this container exist", and two assertions in the release script that the published
notes contain the real digest and no leftover placeholder. A gate that fails when it matched is a gate
that gets distrusted and then worked around.

**Check:** no automated test covers shell control flow. Found by running the new provisioner, which
announced a loaded `launchd` job was missing; fixed at all four sites and re-run.

## The release gate lints what CI lints, and can fail

`tools/release.sh`'s shellcheck gate named one file where CI names three, so `deploy/install.sh` — the
installer users run — was linted by CI and by nothing in the release gate. Widening it exposed a
second defect: without `set -e` a `for` loop reports the status of its *last* iteration, so a defect in
an earlier file was masked by a later one passing. The gate passed while `install.sh` was deliberately
broken.

**Check:** the gate was made to fail on purpose, twice — a `shellcheck` defect in `deploy/install.sh`,
and a syntax error in the last file in the loop — and confirmed to pass on clean input. CI's own step
was already safe: it runs under `set -euo pipefail`.

## Both smoke harnesses asserted a state that no longer existed

`scripts/mcp_smoke.py` required `web_search` to fail with "no provider configured" when started with a
scrubbed environment. With every provider on by default, that environment still has a working search
path, so the check observed a *successful* search and failed — this is why CI was red on `3257b0b`.
The credential-free providers are now switched off explicitly for that check.

`scripts/monitor_tty_smoke.py` carried the same assumption with a different symptom, and the release
gate found it: the dashboard **probes the configured providers on its first frame**, so with a bare
environment that frame waited on a live DuckDuckGo request. Measured against one binary, first frame:

| credential-free providers | time to first frame |
| --- | --- |
| off | 0.03 s |
| on (the new default) | 2.02 s |

The harness polls at 0.4 s, saw no frame, and failed. It also made a smoke test depend on the network
and on a search engine's mood, which is what its own scrub list exists to prevent. Those providers are
now switched off explicitly there too.

The wait loop was fragile in its own right: a predicate that reads a frame *raises* when no frame has
completed yet, and letting that escape defeated the point of waiting. It now treats that as "not yet"
and keeps polling, so a slow start is waited out while a monitor that never paints still fails on the
timeout, with the reason attached.

**Check:** the `mcp_smoke` failure was reproduced locally before the fix, byte-for-byte the message CI
reported, and both halves — stdio and Streamable HTTP — pass after it. The monitor failure was
reproduced against the release binary, attributed by timing the same binary with the flags on and off,
and fixed; it then passes, the pre-existing `v1.0.1` binary still passes, and the harness still fails
against a binary that is not the monitor.

## Security: key material in a public test fixture

`Tests/WebSearchCoreTests/LiveProviderTests.swift` held the first 47 characters of a live Tavily API
key. It is replaced with synthetic material, and the live-test guard now rejects placeholder keys.

**Check:** `LiveProviderTests` refuses to run against a key containing `not-a-real-key`, `placeholder`,
`fake`, `dummy`, `example`, `invalid` or `ci-`, or shorter than 20 characters.

**The value remains in this repository's history, and history was not rewritten.** Rotate that key.

## Checksums

- `mcps-1.2.0-macos-arm64.tar.gz` — SHA256 `SHA256_PENDING`, `ARCHIVE_BYTES_PENDING` bytes.
- Published beside the archive: `mcps-1.2.0-macos-arm64.tar.gz.sha256` and `SHA256SUMS`, both carrying
  that same digest. `RELEASE.md` Part 2 names `SHA256SUMS`; its Part 1 §1.7 names `<archive>.sha256`.
  Both are shipped so either documented command works.

Apple silicon only (`arm64`, M1–M6), macOS 13 or newer. Not code-signed and not notarized — see
`README-binaries.txt` inside the archive. The archive contains `SwiftWebSearchMCP`, `mcps-mon`,
`LICENSE`, `THIRD-PARTY-NOTICES.md` and that README.

## Checks that did not run

NOT_CHECKED_PENDING

**No CI result is claimed for the commit this release is built from.** The instruction was not to wait
for GitHub checks, so none was awaited. The most recent completed CI run on `main` — on `3257b0b` —
was **red**, and its cause is fixed here: `build-and-test` failed in the end-to-end smoke test with
`expected isError=true with no provider configured`, which is the regression described above. That
failure was reproduced locally against the same binary behaviour, the fix applied, and both the stdio
and Streamable HTTP halves then passed locally. `static-analysis` passed on that run, and CodeQL
passed.

That is a local reproduction and a local pass, not a CI run. A green CI run on the tagged commit
remains outstanding and should be obtained before this release is treated as verified by CI.
