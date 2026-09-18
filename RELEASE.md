# Release and build rules — MCPSearch

The release and build standard for this repository.

**This file belongs to this repository.** Edit it here and nowhere else. It was once
deployed from a master document kept in another repository; that arrangement is gone.
Nothing outside this repository governs these rules or can overwrite this file, and an
agent working here never needs to leave the repository to find the standard.

**Part 1 is the rule set** and **Part 2 is this repository's own section**; where the
two appear to disagree, Part 2 wins.

---

# Part 1 — Generic rules

## 1.1 Scope

These apply to any repository that produces a **runnable artifact**: a binary, a
library, an image, a package. Repositories that only hold documents, data or
configuration are out of scope, and should say so in their Part 2 section rather
than adopting a release process they cannot use.

## 1.2 Non-negotiable

1. **Apple Silicon only.** Build native `arm64`. This covers M1–M6. Never
   `--arch x86_64`, never `ARCHS=arm64 x86_64`, and never `lipo -create` — that
   is how a universal binary gets made, and there is no x86_64 build.
2. **Assert it, do not assume it.** After building, check the artifact:
   `lipo -archs <binary>` must be exactly `arm64`. A build that silently produced
   a fat binary is a release defect, not a build option.
3. **Every release carries the artifacts.** A tag alone is not a release. If the
   Release page has no binaries attached, the release did not happen.
4. **No hardcoded build-toolchain triple in a path.** `.build/release` is the
   stable spelling. `.build/arm64-apple-macosx/release` points at nothing on a
   newer toolchain and at a stale binary on this one. The one exception is a build
   that explicitly passes `--arch arm64`: then the triple directory really is
   where SwiftPM writes, and that build must also assert the arch (§1.2.2).
5. **One checksummed artifact per target, or one checksum file covering all of
   them.** Never publish a binary without a digest beside it.
6. **Dry run by default; publish only on an explicit flag.**
7. **Never fetch a model, dataset or dependency to make a gate pass.** A check
   that cannot run is reported *not checked* — and the release notes must name it.
   "Not checked, no input" and "checked and identical" are different sentences.

## 1.3 Identity

The version or build number is **single-sourced and enforced**, not maintained by
hope.

- **One authoritative value.** A file at the repository root — `VERSION` for a
  semantic version, `BUILD_NUMBER` for a build number. Anywhere else it appears
  is a **mirror**, and the build or CI must fail when a mirror disagrees.
- **Pick one scheme and state it.** Semantic versions (`vX.Y.Z`) or build numbers
  (`b1`, `b2`). Do not mix them, and do not "helpfully" introduce versions into a
  project that uses build numbers.
- **The build refuses a malformed or inconsistent identity.** Fail at configure
  or compile time, not at release time.
- **Identity is observable.** A user must be able to say what they are running
  from the artifact alone: the archive filename, or the program's own answer, or
  both.
- **Bump once, propagate mechanically.** Provide a command that writes the mirrors
  from the authoritative value. A release is one edit plus one command.
- **A second declaration in a test is a defect.** Derive the expected value from
  the source of truth; a literal in a test means every bump fails a test that is
  not about the version, and the tempting fix — editing the test — is how a wrong
  version ships.
- **Multi-library projects version in lockstep.** Libraries that ship together and
  interoperate carry the **same** version, because a caller pairing them has no
  other way to know the pair is compatible. A library with no code change is
  recompiled and republished at the new number rather than left behind.
  Lockstep applies to the **library version only** — an ABI version, protocol
  draft, or schema version is a separate axis and must not be dragged along.

## 1.4 Preconditions

Before starting, confirm and record: the OS floor and toolchain floor are met
(`sw_vers`, `swift --version`); there is disk for a clean scratch build plus the
staged archive; `memory_pressure -Q` is acceptable; **no competing build or model
process is running**; `gh auth status` is the repository owner's account; the tree
is clean; and `HEAD` **is** the tag.

**Never terminate a process you did not start.** If one is blocking, name it with
its parent and age, and stop.

## 1.5 Gates

Run these in order, and make each one **able to fail**:

1. **Lint** — the project's own lint gates.
2. **Full test suite**, serially, and it must report the count that passed.
3. **Parity or golden checks** — real inference, real rendering, real protocol
   frames; whatever "the output is unchanged" means for this project.
4. **A clean scratch build** with the log scanned for warnings.

Two traps, both of which have shipped broken gates in this organisation:

- **A gate that cannot fail is not a gate.** A guard that looks for a file the
  build never produces passes for every input. A warning scan over an *incremental*
  build compiles nothing and passes vacuously — always use a fresh scratch path.
  Before trusting a new gate, break its input and watch it fail.
- **Guard the plan, not the byproduct.** Ask the build system what it resolved
  (`swift package describe --type json`, `cmake --build ... -t help`) rather than
  checking for artifacts after the fact.

## 1.6 Packaging

The archive contains, at minimum:

- the **executables or libraries**, built for arm64;
- **resource bundles** — a Swift binary without its `.bundle` cannot load its
  Metal kernels, and this fails at runtime rather than at build time;
- `LICENSE`, and `NOTICE` / `THIRD_PARTY_NOTICES.md` where third-party code is
  redistributed;
- a **`README-binaries.txt`** stating the platform floor, that the build is
  Apple-Silicon-only, and that the binaries are **not code-signed or notarized** —
  with the quarantine command (`xattr -dr com.apple.quarantine <path>`) so a user
  who verified the checksum can run them. Do not imply a notarized build.

Name the archive `<project>[-<library>]-<version>-macos-arm64.tar.gz`; the
library segment is required only for a multi-library project, and exists so two
artifacts of the same release are distinguishable.

## 1.7 Publishing

```bash
gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sha256" \
  --repo <owner>/<repo> --title "<Project> $VERSION" \
  --notes-file "$NOTES" --latest
```

**Pin `--repo` on every `gh` call.** In a fork `gh` defaults to the *parent*
repository, so `gh release list` shows another project's releases and
`gh release create` fails with a misleading "tag has not been pushed".

## 1.8 Release notes

- Full notes in `docs/release-notes-vX.Y.md` (or the repository's equivalent),
  one section per user-visible change, each naming the check that backs it.
- End with a checksum block carrying `SHA256_PENDING` and
  `ARCHIVE_BYTES_PENDING`, substituted at publish time. **Never copy a size out
  of a dry run** — publish rebuilds, and the archive differs.
- `--publish` must **refuse** unless the notes carry the placeholder or quote the
  real value. A release quoting the wrong digest is worse than one quoting none.
- Name **every** check that did not run, and why.
- The README gets **no release callout**. It changes only when a fact it states
  changes. The changelog is the announcement.

## 1.9 After publishing

Verify the Release: the notes quote the digest in the `.sha256` beside it, the
assets are the archive and its checksum, and the changelog points at the same tag.
Leave previous releases' notes and performance tables alone.

## 1.10 Rules, agents and other repositories

- **These rules live in this repository and are edited only here.** They are not
  deployed from anywhere and nothing outside this repository can overwrite them. A
  rule an agent cannot find is a rule that will be broken, so a rule about this
  repository belongs in this file or in `AGENTS.md` — not in a shell-script comment,
  and not in another repository.
- **Work happens in this repository only** — and this repository includes its own
  wiki (`MCPSearch.wiki.git`), which is part of the documentation surface, so keeping
  its pages in sync with a release is in scope. **Other repositories are out of
  scope**, with one exception: filing an issue or a pull request against another
  Pummelchen repository is allowed when the instruction says to. A change that
  belongs elsewhere but was not asked for is reported to the owner with the exact
  edit and the reason, not applied.
- **`AGENTS.md` is the one instruction file, and every harness must reach it.** This
  account works with Codex, Claude Code, DeepSeek Harness, OpenCode, Qwen Code,
  Qoder and Zed. Six read `AGENTS.md` directly; **Claude Code does not** — its
  documentation is explicit that it reads `CLAUDE.md`, not `AGENTS.md` — so this
  repository also carries a committed `CLAUDE.md` whose entire content is the
  `@AGENTS.md` import. Commit it: a symlink made on one machine is invisible to a
  fresh clone, to CI and to every other checkout, and on Windows it needs
  Administrator rights. Qwen Code reads `AGENTS.md` alongside its own `QWEN.md`, so
  there is nothing to duplicate for it.
- **Never add a file that shadows `AGENTS.md`.** Zed takes the *first match* from
  `.rules`, `.cursorrules`, `.windsurfrules`, `.clinerules`,
  `.github/copilot-instructions.md`, `AGENT.md`, and only then `AGENTS.md` — so any
  of those six silently replaces this file for every Zed user. Check for them whenever
  the instruction file changes.
- **An archived repository is read-only.** Nothing can be committed to it, so no
  release step may depend on one. Name the exclusion rather than leaving a gap.
- **A check that has never been seen to fail is not yet trusted.**

# Part 2 — This repository

## MCPSearch — Swift, semantic version, 5 releases

- **Identity** `vX.Y.Z`, **single-sourced and enforced since `v1.0.1`**. `VERSION` at
  the repository root is authoritative and holds a bare `X.Y.Z`.
  `Sources/WebSearchCore/Support/BuildVersion.swift` is **generated** from it by
  `tools/sync-version.sh` and is the only version literal in `Sources/`;
  `MCPServer.swift` reports it, the Parallel provider sends it as
  `clientInfo.version`, and the default `SEARCH_USER_AGENT` is built from it. A bump
  is one edit (`VERSION`) plus one command (`tools/sync-version.sh`).
  `tools/check-version.sh` fails when the generated mirror does not reproduce
  byte-for-byte, when `CHANGELOG.md` has no `## [X.Y.Z]` heading, or when a version
  literal appears anywhere else in `Sources/`. Before `v1.0.1` the version was
  declared in three unconnected places with nothing tying them together, so a
  half-done bump shipped a server that misreported itself over MCP.
- **Artifacts** `mcps-X.Y.Z-macos-arm64.tar.gz`, published beside
  `mcps-X.Y.Z-macos-arm64.tar.gz.sha256` and `SHA256SUMS`, both carrying the same
  digest — this section names `SHA256SUMS` and Part 1 §1.7 names `<archive>.sha256`,
  so both ship. The archive carries both executables, `LICENSE`,
  `THIRD-PARTY-NOTICES.md` and `README-binaries.txt`; the install instructions live in
  the release notes. `v1.0.0` (2026-09-15), `v1.0.1` (2026-09-16), `v1.2.0` (2026-09-17),
  `v1.3.0` (2026-09-18) and `v1.3.1` (2026-09-18) are released.
- **`tools/release.sh` cuts a release.** Dry run by default, publishing only with
  `--publish`. It checks the §1.4 preconditions (including that HEAD is the tag and
  that no competing build is running), runs the §1.5 gates in order, builds with a
  fresh scratch path and scans the log for compiler warnings, asserts `lipo -archs`
  is exactly `arm64` on every binary, packages, checksums, renders the notes with the
  digest of the build it just made, publishes with `--repo` pinned, and then verifies
  what it published. Every check is reported `PASS`, `FAIL` or `NOT CHECKED`, and it
  refuses to publish on anything but a clean run. `v1.0.0` was cut by hand; `v1.0.1`
  is the first release produced by the script.
- **`main` is unprotected** and carries no rulesets: nothing gates a merge today,
  so the checks below are advisory until that changes.
- **Code scanning uses CodeQL advanced setup** (`.github/workflows/codeql.yml`,
  `build-mode: manual`, weekly cron). **Do not switch it to default setup** — the
  runner image ships Swift 6.3.3, which cannot parse this package's 6.4 manifest, so
  default setup analyses nothing while appearing to run, and removes SAST silently.
- **AI Scan for pull requests is deliberately disabled** on this repository and
  every other non-archived one — the Autofind job asks
  `api.individual.githubcopilot.com` for a model an individual Copilot plan does not
  serve, so it failed on every PR head with `CAPIError: 400 The requested model is
  not supported` and could never report a finding. Re-enable only with an
  entitlement that serves the requested model:
  `PATCH /repos/{owner}/{repo}/code-scanning/ai-scan` with `{"pr_scan":"enabled"}`.
- **The pre-production audit material has been retired.** It was processed into the code and the
  changelog and then removed, so the next audit starts from the code rather than from a previous
  audit's ledger, findings and baseline logs. Its one human-action finding — a GitHub PAT embedded in
  cleartext in the local wiki clones' `.git/config` — is closed as issue #16. Verified here: every local
  clone's remote is now a plain `https://github.com/...` URL with no embedded userinfo. Whether the old
  token was rotated is not something this repository can check, and the issue was closed by the owner.
- **Next release** is machinery-complete: bump `VERSION`, run
  `tools/sync-version.sh`, add the `CHANGELOG.md` section and
  `docs/release-notes-vX.Y.Z.md`, land it, tag, then `tools/release.sh --publish`.
- **Known limit in the release script**: it checks for a competing build once, at the
  start, so a build that begins *during* a release is not detected. These are 8 GB
  Macs; one heavy build at a time is the working rule.
