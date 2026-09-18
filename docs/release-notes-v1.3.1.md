# MCPSearch 1.3.1 — release notes

Released 2026-09-18. A cleanup release. **There is no behavioural change**: the executables do exactly
what `1.3.0`'s do. It exists so the restructuring is tagged and reproducible rather than living only on
`main`.

## Every source and test file is now under 500 lines

Twenty files were over that, one of them 1421 lines. They were not over it because they were doing one
large thing; they were over it because they had accumulated unrelated ones.

- **One type per file** where the types were unrelated. `ToolSchemas.swift` held the schema definitions,
  an argument parser and an output formatter; `CoreUnitTests.swift` held five unrelated test classes.
- **An `extension` file** where a single class had outgrown a screen, since a class has no type seam.
  `ProviderContractTests` became a base file plus `+Adapters`, `+Scrapers` and `+Retry` — named by what
  they hold, because a file called `+2` is the same defect as a file called `CoreUnitTests` that no longer
  holds the core unit tests.

Nothing in the public API changed, and **no test changed meaning**: the suite reports the same count and
the same result before and after each split. That number is the check that matters — a test moved into an
`extension` the runner ignores still compiles and still passes.

The one honest cost: four of the splits needed members widened from `private` to `internal` so a sibling
file could reach them. That cannot escape the module, and `SwiftWebSearchMCP` is an executable, so no
public surface changed. It is still a real reduction in encapsulation inside those modules, and it is
recorded rather than glossed.

## The audit material is gone, and so is everything that pointed at it

The pre-production audit's findings were processed into `1.3.0`. Its ledger, baseline, environment
record, inventory, coverage proofs and Phase E record are now removed, along with the branch they lived
on — so the next audit starts from the code rather than from a previous audit's conclusions.

Deleting the folder was the easy part. **108 comments across 38 files cited that ledger by finding
number** — `(ledger A0011)`, `(ledger A0017, tracker T4)`. Left behind, those are citations to a document
that does not exist, which is precisely the confusion the removal was meant to prevent. The engineering
rationale around them is untouched; only the pointers are gone.

## Documentation re-checked against the tree

`RELEASE.md` said "2 releases" and listed three, with `v1.3.0` missing; it described issue #16 as still
open, and it now records that the local clones' remotes carry no embedded credential while noting that
whether the old token was rotated is not something this repository can check. `AGENTS.md`'s `scripts/`
inventory omitted `searxng_health.py`.

The wiki gained a worked walkthrough — one question through all four tools, with per-engine attribution,
the fetch cap, and `web_answer`'s refusal to answer from nothing — and lost seven passages that narrated
the project's own development rather than describing what it does.

## Checksums

- `mcps-1.3.1-macos-arm64.tar.gz` — SHA256 `SHA256_PENDING`, `ARCHIVE_BYTES_PENDING` bytes.
- Published beside the archive: `mcps-1.3.1-macos-arm64.tar.gz.sha256` and `SHA256SUMS`, both carrying
  that same digest.

## Checks that did not run

NOT_CHECKED_PENDING

Two things are true of this release regardless of the gates above, and are named rather than implied:

- **No live provider traffic.** `SEARCH_LIVE_TESTS` is unset and no usable credential is present, so
  `LiveProviderTests` was skipped. Every provider is covered against stubs.
- **The real-page depth corpus run is opt-in** (`MARKUP_DEPTH_CORPUS=<dir>`) and is not part of the
  default suite, so no gate here fetches pages.
