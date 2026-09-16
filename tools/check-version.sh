#!/bin/bash
#
# The version-agreement gate. CI runs this; the release script refuses to build when it fails.
#
# RELEASE.md §1.3 requires the identity to be single-sourced and *enforced*: one authoritative value,
# every other appearance a mirror, and the build or CI must fail when a mirror disagrees. Before this
# existed the version lived in three unconnected places and a half-done bump shipped a server that
# misreported itself over MCP.
#
# Checks, in order:
#   1. VERSION is a bare X.Y.Z.
#   2. The generated Swift mirror matches, byte-for-byte, what VERSION would generate.
#   3. CHANGELOG.md carries a '## [X.Y.Z]' heading for it.
#   4. No other X.Y.Z literal appears anywhere in Sources/ — a new hardcoded copy is the exact
#      defect this gate exists to prevent, and check 2 alone would not catch it.
#
# This script never writes to the working tree. An earlier version regenerated the mirror and then
# asked git whether it had changed, which reports "clean" for an untracked file and so passed a mirror
# that was flatly wrong. `tools/sync-version.sh --stdout` renders the expectation instead, and the
# comparison is against the file as it stands.
#
# Every check prints what it found, so a failure names the file and the value.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
fail=0

note() { printf '%s\n' "$*"; }
bad() {
    printf 'FAIL: %s\n' "$*" >&2
    fail=1
}

# 1 — the authoritative value.
if [ ! -f VERSION ]; then
    bad "VERSION does not exist at the repository root (RELEASE.md §1.3)"
    exit 1
fi
version="$(tr -d '[:space:]' < VERSION)"
if printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    note "ok   VERSION is a bare semantic version: $version"
else
    bad "VERSION must be a bare X.Y.Z with no leading 'v' and no suffix; found '$version'"
    exit 1
fi

# 2 — the generated Swift mirror, compared against the file as it stands.
mirror="Sources/WebSearchCore/Support/BuildVersion.swift"
if [ ! -f "$mirror" ]; then
    bad "$mirror is missing; run tools/sync-version.sh"
else
    expected="$(mktemp)"
    trap 'rm -f "$expected"' EXIT
    if ! ./tools/sync-version.sh --stdout > "$expected"; then
        bad "tools/sync-version.sh --stdout failed; cannot verify $mirror"
    elif diff -q "$expected" "$mirror" > /dev/null; then
        note "ok   $mirror matches what VERSION generates"
    else
        bad "$mirror does not match VERSION — run tools/sync-version.sh and commit the result:"
        diff -u "$expected" "$mirror" | sed -n '1,20p' >&2
    fi
fi

# 3 — the changelog heading.
if grep -qE "^## \[$version\]" CHANGELOG.md; then
    note "ok   CHANGELOG.md has a '## [$version]' section"
else
    bad "CHANGELOG.md has no '## [$version]' heading; add the section for this version"
fi

# 4 — no stray literal in Sources/. BuildVersion.swift is the one allowed home for it.
strays="$(grep -rnE '"[0-9]+\.[0-9]+\.[0-9]+"' Sources/ --include='*.swift' \
    | grep -v "^${mirror}:" || true)"
if [ -z "$strays" ]; then
    note "ok   no version literal outside $mirror in Sources/"
else
    bad "a version literal appears outside $mirror — derive it from BuildVersion.value instead:"
    printf '%s\n' "$strays" >&2
fi

echo
if [ "$fail" -eq 0 ]; then
    note "version agreement: $version"
else
    note "version agreement FAILED" >&2
fi
exit "$fail"
