#!/bin/bash
#
# Cut a release: preconditions, gates, native arm64 build, package, checksum, notes, publish.
#
# RELEASE.md is the standard; this script is the mechanical walk of it. Part 2 of that file says this
# repository has no release script and that the packaging/digest/notes sequence "has to be walked
# manually and is not yet reproducible from one command" — this closes that gap.
#
# Usage:
#   tools/release.sh              # dry run: everything except publishing (Part 1 §1.2.6)
#   tools/release.sh --publish    # publish, only if every check above passed
#   tools/release.sh --skip-gates # iteration only; refuses to publish
#
# Apple Silicon only. This script never passes --arch, never sets ARCHS, and never runs lipo -create;
# it asserts `lipo -archs` reports exactly `arm64` on every shipped binary (Part 1 §1.2.1–2).

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO_SLUG="Pummelchen/MCPSearch"

PUBLISH=0
SKIP_GATES=0
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        --dry-run) PUBLISH=0 ;;
        --skip-gates) SKIP_GATES=1 ;;
        -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

if [ "$SKIP_GATES" -eq 1 ] && [ "$PUBLISH" -eq 1 ]; then
    echo "refusing: --skip-gates cannot be combined with --publish" >&2
    exit 2
fi

fails=0
notchecked=()
GATE_LOG_DIR="${RELEASE_LOG_DIR:-$HOME/Library/Caches/MCPSearch/release-logs}"
mkdir -p "$GATE_LOG_DIR"

say() { printf '%s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() {
    printf 'FAIL  %s\n' "$*" >&2
    fails=$((fails + 1))
}
skip() {
    printf 'NOT CHECKED  %s — %s\n' "$1" "$2"
    notchecked+=("$1 ($2)")
}

# Run one gate. $1 label, $2.. command. Records pass/fail; never aborts the whole script so the
# report can list everything (§1.5: make each one able to fail, and report each).
run_gate() {
    local label="$1"
    shift
    local slug log
    slug="$(printf '%s' "$label" | tr ' /' '__')"
    log="$GATE_LOG_DIR/$slug.log"
    if "$@" >"$log" 2>&1; then
        pass "$label"
    else
        fail "$label — see $log"
        tail -15 "$log" | sed 's/^/      /' >&2
    fi
}

step "preconditions (RELEASE.md §1.4)"
VERSION="$(tr -d '[:space:]' < VERSION)"
# Validated before anything is built from it. `VERSION` becomes part of a path that is later
# `rm -rf`'d, and `${VERSION:?}` only guards *empty*: a value like `../..` aimed the removal
# somewhere else entirely. A bare X.Y.Z is the only shape the rest of this script can mean
# (ledger A0042).
if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "refusing: VERSION must be a bare X.Y.Z, found '$VERSION'" >&2
    exit 2
fi
TAG="v$VERSION"
say "version       $VERSION   (from VERSION; tools/check-version.sh enforces the mirrors)"
say "tag           $TAG"

say "os            $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
say "swift         $(swift --version 2>&1 | head -1)"
swift_minor="$(swift -version 2>&1 | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -1)"
smajor="${swift_minor%% *}"
sminor="${swift_minor##* }"
if [ -n "$smajor" ] && { [ "$smajor" -gt 6 ] || { [ "$smajor" -eq 6 ] && [ "$sminor" -ge 4 ]; }; }; then
    pass "toolchain is >= 6.4"
else
    fail "toolchain must be >= 6.4; found '$swift_minor'"
fi

free_kb="$(df -k / | tail -1 | awk '{print $4}')"
if [ "$free_kb" -gt 5242880 ]; then
    pass "disk: $((free_kb / 1024 / 1024)) GiB free"
else
    fail "disk: only $((free_kb / 1024)) MiB free; a clean scratch build plus the archive needs more"
fi

mem_free="$(memory_pressure -Q 2>/dev/null | sed -n 's/System-wide memory free percentage: //p')"
if [ -n "$mem_free" ] && [ "${mem_free%\%}" -ge 25 ]; then
    pass "memory: $mem_free free"
else
    fail "memory: $mem_free free is too tight for a clean build"
fi

# Process names only (-x), so this cannot match a command line containing the word.
competing="$(pgrep -x swift-build; pgrep -x swift-frontend; pgrep -x xcodebuild)"
if [ -z "$competing" ]; then
    pass "no competing build process"
else
    fail "a competing build is running (pids: $(echo "$competing" | tr '\n' ' ')) — §1.4 says stop, and never kill a process you did not start"
fi

owner="${REPO_SLUG%%/*}"
# Not `grep -q`: grep exits at the first match, SIGPIPEs the producer, and `pipefail` turns the
# pipeline into 141 — so a match reads as a failure.
if gh auth status 2>&1 | grep "account $owner" >/dev/null; then
    pass "gh auth is the repository owner ($owner)"
else
    fail "gh auth is not $owner of $REPO_SLUG"
fi

if [ -z "$(git status --porcelain)" ]; then
    pass "working tree is clean"
else
    fail "working tree is not clean; §1.4 requires a clean tree"
fi

at_tag="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
if [ "$at_tag" = "$TAG" ]; then
    pass "HEAD is the tag ($TAG)"
else
    fail "HEAD is not $TAG (found '${at_tag:-no tag}'); §1.4 requires the release to be cut from the tag"
fi

step "identity (RELEASE.md §1.3)"
run_gate "version agreement" ./tools/check-version.sh

step "gates (RELEASE.md §1.5)"
if [ "$SKIP_GATES" -eq 1 ]; then
    say "--skip-gates: gate set not run (this dry run cannot be published)"
else
    # 1. lint — the project's own gates, exactly what CI's static-analysis job runs.
    run_gate "swift-format" swift-format lint --recursive --strict Sources Tests Package.swift
    run_gate "swiftlint" swiftlint lint --strict
    run_gate "ruff" bash -c 'ruff check scripts && ruff format --check scripts'
    # The file list and the `set -e` both matter, and both were wrong before. The list named only
    # provision-node.sh, so the installer users actually run — and this script itself — were linted
    # by CI and by nothing in the release gate. And without `set -e` a `for` loop reports the status
    # of its *last* iteration, so a failure in install.sh was masked by a later tools/*.sh passing:
    # the widened gate passed while install.sh was deliberately broken. CI's own step is safe
    # because it runs under `set -euo pipefail`; this now matches it exactly.
    run_gate "shellcheck" bash -c 'set -euo pipefail
        for script in deploy/provision-node.sh deploy/install.sh tools/*.sh; do
            bash -n "$script"
            shellcheck -S warning "$script"
        done'
    run_gate "third-party notices" python3 scripts/third_party_notices.py
    run_gate "python harness tests" python3 scripts/harness_tests.py
    if command -v pyright >/dev/null 2>&1; then
        run_gate "pyright" pyright
    elif command -v npx >/dev/null 2>&1; then
        run_gate "pyright" npx --yes pyright@1.1.414
    else
        skip "pyright" "neither pyright nor npx is installed, and fetching a tool to satisfy a gate is forbidden (§1.2.7)"
    fi
    if command -v semgrep >/dev/null 2>&1; then
        run_gate "semgrep" semgrep scan --config=p/default --error --metrics=off --quiet
    else
        skip "semgrep" "not installed"
    fi
    if command -v gitleaks >/dev/null 2>&1; then
        run_gate "gitleaks (full history)" gitleaks detect --source . --log-opts=--all --redact
    else
        skip "gitleaks" "not installed"
    fi
    if command -v osv-scanner >/dev/null 2>&1; then
        run_gate "osv-scanner" osv-scanner scan source -r .
    else
        skip "osv-scanner" "not installed"
    fi

    # 2. full suite, serially, reporting the count (swift test defaults to --no-parallel).
    step "full test suite"
    suite_log="$GATE_LOG_DIR/tests.log"
    if swift test >"$suite_log" 2>&1; then
        # Sum only the per-bundle totals. XCTest prints an "Executed N tests" line for every suite
        # *and* for each .xctest bundle, so adding up every line double-counts — this reported 1771
        # for what is a 591-test run. The bundle totals are the lines following "Test Suite
        # '<name>.xctest' passed"; the 'All tests' line after each duplicates that bundle's own.
        counts="$(python3 - "$suite_log" <<'PY'
import pathlib
import re
import sys

total = skipped = bundles = 0
expect = False
for line in pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines():
    if re.match(r"Test Suite '.*\.xctest' (passed|failed)", line.strip()):
        expect = True
        continue
    if expect:
        match = re.search(r"Executed (\d+) tests?(?:, with (\d+) tests? skipped)?", line)
        if match:
            total += int(match.group(1))
            skipped += int(match.group(2) or 0)
            bundles += 1
        expect = False
print(total, bundles, skipped)
PY
)"
        read -r total bundles skipped <<<"$counts"
        # A parser that found nothing is not a passing suite. `swift test` exits 0 above, but the
        # count is derived from its *output*, and a format change or a Python error yields zeros — which
        # were then reported as "test suite: 0 tests across 0 bundles, 0 skipped, 0 failures", the most
        # reassuring possible way to say the suite did not run (ledger A0043).
        if [ "${bundles:-0}" -ge 1 ] && [ "${total:-0}" -ge 1 ]; then
            pass "test suite: $total tests across $bundles bundles, $skipped skipped, 0 failures"
        else
            fail "test suite ran but its count could not be read from $suite_log (parsed ${total:-0} tests across ${bundles:-0} bundles)"
        fi
    else
        fail "test suite — see $suite_log"
        tail -20 "$suite_log" | sed 's/^/      /' >&2
    fi

    # 3. Protocol parity runs after the clean build below, against the binaries that will actually
    # ship. Running it here against a `.build` binary would check something other than the artifact,
    # and §1.5 is explicit that a stale binary passing a check is not a check.
fi

step "clean scratch release build, native arm64"
STAGE="${RELEASE_STAGE:-$HOME/Library/Caches/MCPSearch/release}"
if [ "$fails" -gt 0 ]; then
    # `fail` deliberately does not abort, so the report can list every gate. But this is the one step
    # here that cannot be undone, and taking it for a release already declared unfit is how a failed
    # run still destroys the previous staging. Reported as NOT CHECKED rather than silently skipped
    # (ledger A0042).
    skip "clear the stage directory" "$fails gate(s) failed before this point"
else
    rm -rf "${STAGE:?}/${VERSION:?}"
fi
mkdir -p "${STAGE:?}/${VERSION:?}"
SCRATCH="$STAGE/$VERSION/scratch"
BUILD_LOG="$GATE_LOG_DIR/build-release.log"
say "scratch path  $SCRATCH (fresh: an incremental build compiles nothing and passes a warning scan vacuously, §1.5)"
if swift build -c release --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors >"$BUILD_LOG" 2>&1; then
    # The log is scanned for warnings; SwiftPM's dependency-cache notices are not compiler diagnostics.
    compiler_warnings="$(grep -c 'warning:' "$BUILD_LOG" || true)"
    cache_notices="$(grep -c "skipping cache due to an error" "$BUILD_LOG" || true)"
    if [ "$compiler_warnings" -eq "$cache_notices" ]; then
        pass "release build: 0 compiler warnings ($cache_notices SwiftPM cache notices)"
    else
        fail "release build produced $((compiler_warnings - cache_notices)) compiler warning(s) — see $BUILD_LOG"
        grep 'warning:' "$BUILD_LOG" | grep -v "skipping cache" | head -10 | sed 's/^/      /' >&2
    fi
else
    fail "release build — see $BUILD_LOG"
    tail -20 "$BUILD_LOG" | sed 's/^/      /' >&2
fi

# Ask the build system where it wrote (Part 1 §1.2.4: no hardcoded toolchain triple in a path).
BIN_DIR="$(swift build -c release --show-bin-path --scratch-path "$SCRATCH" 2>/dev/null || true)"
say "bin dir       $BIN_DIR"
for product in SwiftWebSearchMCP mcps-mon; do
    if [ -x "$BIN_DIR/$product" ]; then
        pass "built $product"
    else
        fail "$product was not built"
    fi
done

step "assert native arm64 (RELEASE.md §1.2.1–2)"
for product in SwiftWebSearchMCP mcps-mon; do
    if [ -x "$BIN_DIR/$product" ]; then
        archs="$(lipo -archs "$BIN_DIR/$product" 2>/dev/null)"
        if [ "$archs" = "arm64" ]; then
            pass "$product: lipo -archs = $archs"
        else
            fail "$product: lipo -archs = '$archs', expected exactly 'arm64'"
        fi
    fi
done

step "parity against the packaged binaries"
# `mcp_smoke.py` drives a real initialize handshake and asserts the server reports the version in
# VERSION (RELEASE.md §1.3: identity is observable from the program's own answer). That assertion
# lives in the harness rather than here, so CI checks it on every pull request too — an ad-hoc
# version check in this script was the only thing checking it before, and it was broken: piping the
# request in and closing stdin made the server shut down before it replied, so the reply was empty.
if [ "$SKIP_GATES" -eq 0 ]; then
    run_gate "mcp_smoke (stdio, release)" python3 scripts/mcp_smoke.py "$BIN_DIR/SwiftWebSearchMCP"
    run_gate "mcp_smoke (http, release)" python3 scripts/mcp_smoke.py --http "$BIN_DIR/SwiftWebSearchMCP"
    run_gate "monitor tty smoke (release)" python3 scripts/monitor_tty_smoke.py "$BIN_DIR/mcps-mon"
    # The other half of the contract `harness_tests.py` owns statically: both executables are
    # pointed at one stub and each is asked what it sees, because the two parse the same SearXNG
    # response with two independent parsers and nothing else compares them.
    run_gate "dual client contract (release)" python3 scripts/dual_client_contract.py "$BIN_DIR"
fi

step "package (RELEASE.md §1.6)"
DIST="$STAGE/$VERSION/dist"
ARCHIVE_NAME="mcps-$VERSION-macos-arm64.tar.gz"
ARCHIVE="$DIST/$ARCHIVE_NAME"
rm -rf "$DIST"
mkdir -p "$DIST/$VERSION/mcps-$VERSION-macos-arm64"

for product in SwiftWebSearchMCP mcps-mon; do
    cp "$BIN_DIR/$product" "$DIST/$VERSION/mcps-$VERSION-macos-arm64/"
done
cp LICENSE THIRD-PARTY-NOTICES.md "$DIST/$VERSION/mcps-$VERSION-macos-arm64/"

cat > "$DIST/$VERSION/mcps-$VERSION-macos-arm64/README-binaries.txt" <<EOF
MCPSearch $VERSION — prebuilt binaries
==========================================

Contents
  SwiftWebSearchMCP   the MCP server (stdio by default, or Streamable HTTP)
  mcps-mon            the live provider/node dashboard
  LICENSE             MIT
  THIRD-PARTY-NOTICES.md   attribution for the Apache-2.0 components linked into the binary

Platform floor
  macOS 13 (Ventura) or newer.
  Apple silicon only: arm64, M1 through M6. There is no Intel slice and none is planned.
  Confirm before running:  lipo -archs SwiftWebSearchMCP   ->  arm64

Not code-signed or notarized
  These binaries are not signed with a Developer ID and are not notarized, so Gatekeeper has no
  signature to check. A file fetched with curl carries no quarantine flag and runs directly. One
  downloaded through a browser does carry it; either allow it under System Settings -> Privacy &
  Security, or clear the flag yourself:

      xattr -dr com.apple.quarantine mcps-$VERSION-macos-arm64

  This does not imply a notarized build. There is none.

Verify before running
  shasum -a 256 -c SHA256SUMS --ignore-missing    (from the directory holding the archive)

Run
  ./SwiftWebSearchMCP --help
  ./SwiftWebSearchMCP --transport http --port 8080   # serves /mcp plus GET /health
EOF

if tar -czf "$ARCHIVE" -C "$DIST/$VERSION" "mcps-$VERSION-macos-arm64"; then
    pass "archive $ARCHIVE_NAME"
else
    fail "tar failed"
fi
digest="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
bytes="$(wc -c < "$ARCHIVE" | tr -d ' ')"
printf '%s  %s\n' "$digest" "$ARCHIVE_NAME" > "$DIST/$ARCHIVE_NAME.sha256"
printf '%s  %s\n' "$digest" "$ARCHIVE_NAME" > "$DIST/SHA256SUMS"
pass "archive bytes $bytes"
pass "sha256 $digest"
say "published alongside: $ARCHIVE_NAME.sha256 and SHA256SUMS (Part 2 names SHA256SUMS; Part 1 §1.7 names <archive>.sha256 — both are shipped, with the same digest)"

step "release notes (RELEASE.md §1.8)"
NOTES_SRC="docs/release-notes-v$VERSION.md"
NOTES="$DIST/release-notes-v$VERSION.md"
if [ ! -f "$NOTES_SRC" ]; then
    fail "$NOTES_SRC does not exist; the notes are part of the release, not an afterthought"
else
    # The marker is required, not merely tolerated. Without this the notes could omit the
    # "Checks that did not run" section entirely and still pass: the placeholder check below only
    # rejects a *remaining* PENDING, so a section that was never written looks identical to one where
    # every gate ran — which is the distinction RELEASE.md §1.2.7 exists to protect (ledger A0041).
    if grep -qE 'SHA256_(PENDING)?[0-9a-f]{0,64}|SHA256_PENDING' "$NOTES_SRC" &&
        grep -q 'ARCHIVE_BYTES_PENDING\|ARCHIVE_BYTES [0-9]' "$NOTES_SRC" &&
        grep -q 'NOT_CHECKED_PENDING' "$NOTES_SRC"; then
        pass "notes carry the checksum block and the not-checked marker"
    else
        fail "$NOTES_SRC must end with a checksum block carrying SHA256_PENDING / ARCHIVE_BYTES / NOT_CHECKED_PENDING"
    fi
    # Scoped on purpose. This line is substituted under the heading "Checks that did not run", and
    # the notes may also carry something that did *not* run for another reason — CI, in this
    # repository's case. A bare "none" there read as "nothing at all was unchecked", which is the
    # distinction §1.2.7 exists to protect.
    #
    # The label and the list are separated by a literal newline in the string rather than `\n`:
    # inside double quotes bash does not interpret that escape, so it would reach the notes as the
    # two characters `\n`. Measured both ways.
    not_checked_label="**Release gates (RELEASE.md §1.5):**"
    if [ "${#notchecked[@]}" -eq 0 ]; then
        not_checked_text="${not_checked_label} none skipped — every one ran."
    else
        not_checked_text="${not_checked_label} skipped:
$(printf -- '- %s\n' "${notchecked[@]}")"
    fi
    # python3 rather than sed: the not-checked list can be several lines and BSD sed rejects a
    # newline in a replacement string.
    if python3 - "$NOTES_SRC" "$NOTES" "$digest" "$bytes" "$not_checked_text" <<'PY'
import pathlib, sys
src, dst, digest, size, not_checked = sys.argv[1:6]
text = pathlib.Path(src).read_text(encoding="utf-8")
text = text.replace("SHA256_PENDING", digest).replace("ARCHIVE_BYTES_PENDING", size)
lines = text.splitlines(keepends=True)
out = []
for line in lines:
    if line.startswith("NOT_CHECKED_PENDING"):
        out.append(not_checked if not_checked.endswith("\n") else not_checked + "\n")
    else:
        out.append(line)
pathlib.Path(dst).write_text("".join(out), encoding="utf-8")
PY
    then
        pass "notes rendered with the real digest"
    else
        fail "could not render $NOTES_SRC"
    fi
    if grep -q 'PENDING' "$NOTES"; then
        fail "the rendered notes still contain a PENDING placeholder"
    else
        pass "no placeholder left in the rendered notes"
    fi
    # And the section must actually have arrived. Checking only that nothing PENDING is left cannot
    # distinguish the two states a reader cares about (ledger A0041).
    if grep -qF "$not_checked_label" "$NOTES"; then
        pass "the published notes state which gates did not run"
    else
        fail "the published notes do not carry the not-checked section"
    fi
fi

step "summary"
say "version       $VERSION"
say "tag           $TAG"
say "archive       $ARCHIVE"
say "sha256        $digest"
say "bytes         $bytes"
say "notes         $NOTES"
if [ "${#notchecked[@]}" -gt 0 ]; then
    say "NOT CHECKED:"
    printf '  - %s\n' "${notchecked[@]}"
fi

if [ "$fails" -ne 0 ]; then
    printf '\n%d check(s) FAILED — not publishing.\n' "$fails" >&2
    exit 1
fi

if [ "$PUBLISH" -eq 0 ]; then
    printf '\nDRY RUN CLEAN — nothing was published. Re-run with --publish to publish.\n'
    exit 0
fi

step "publish (RELEASE.md §1.7)"
# --repo is pinned: in a fork gh defaults to the parent repository.
if gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sha256" "$DIST/SHA256SUMS" \
    --repo "$REPO_SLUG" --title "MCPSearch $VERSION" \
    --notes-file "$NOTES" --latest; then
    pass "published $TAG"
else
    fail "gh release create failed"
    exit 1
fi

step "verify what was published (RELEASE.md §1.9)"
gh release view "$TAG" --repo "$REPO_SLUG" --json assets --jq '.assets[].name' | sort > "$DIST/assets.txt"
if diff -q <(printf '%s\n' "$ARCHIVE_NAME" "$ARCHIVE_NAME.sha256" "SHA256SUMS" | sort) "$DIST/assets.txt" >/dev/null; then
    pass "assets are the archive and its checksums"
else
    fail "asset list does not match expectations:"
    cat "$DIST/assets.txt" >&2
fi
published_notes="$(gh release view "$TAG" --repo "$REPO_SLUG" --json body --jq .body)"
# Not `grep -q`: grep exits at the first match, SIGPIPEs the producer, and `pipefail` turns the
# pipeline into 141 — so a match reads as a failure.
if printf '%s' "$published_notes" | grep "$digest" >/dev/null; then
    pass "published notes quote the real digest"
else
    fail "published notes do not quote $digest"
fi
# Not `grep -q`: grep exits at the first match, SIGPIPEs the producer, and `pipefail` turns the
# pipeline into 141 — so a match reads as a failure.
if printf '%s' "$published_notes" | grep 'PENDING' >/dev/null; then
    fail "published notes still contain a PENDING placeholder"
else
    pass "no placeholder left in the notes"
fi
if grep -q "releases/tag/$TAG" CHANGELOG.md; then
    pass "CHANGELOG.md points at $TAG"
else
    fail "CHANGELOG.md does not link $TAG"
fi

if [ "$fails" -ne 0 ]; then
    printf '\n%d post-publish check(s) FAILED.\n' "$fails" >&2
    exit 1
fi
printf '\nPUBLISHED and verified: %s\n' "$TAG"
