#!/usr/bin/env python3
"""Keep ``THIRD-PARTY-NOTICES.md`` in step with the resolved dependency graph.

Apache-2.0 section 4(d) requires a work that is *distributed* to reproduce the attribution
notices of the Apache-2.0 components it contains. This repository is MIT but builds against
several Apache-2.0 packages, two of which ship a ``NOTICE.txt`` (swift-nio and swift-log), so a
shipped binary has to carry those texts. The notices file is committed rather than generated at
release time, because there is no release workflow and a file that exists is checkable.

The failure this guards against is silent: adding a dependency is a one-line manifest edit that
nothing else notices, and the attribution would simply be missing from the next binary. So this
compares the inventory in the notices file against ``Package.resolved`` -- the same authority the
lockfile gate uses -- and fails on any difference in either direction. It needs no network and no
dependency checkout, which is what lets it run as a plain CI gate.

It deliberately does **not** generate the notices file. Copying a licence in automatically is how
a copyleft or unlicensed dependency gets shipped unremarked; each package's licence is read and
recorded by hand, and this check only proves the inventory stayed complete.

Usage:
    third_party_notices.py [PACKAGE_RESOLVED] [NOTICES_MD]

Both arguments are optional and exist so the check can be pointed at fixtures; they default to
this repository's ``Package.resolved`` and ``THIRD-PARTY-NOTICES.md``.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any, cast

ROOT = Path(__file__).resolve().parent.parent

# Marks the inventory table, so the check reads exactly the rows a human reads.
TABLE_START = "<!-- inventory:start -->"
TABLE_END = "<!-- inventory:end -->"
ROW = re.compile(r"^\| `(?P<name>[^`]+)` \| (?P<version>[^ |]+) \|", re.MULTILINE)


def resolved_packages(path: Path) -> dict[str, str]:
    """Read the resolved package graph.

    Args:
        path: The ``Package.resolved`` to read.

    Returns:
        A mapping of lower-cased package identity to pinned version.

    Raises:
        SystemExit: The lockfile is missing or not valid JSON.
    """
    try:
        document = cast("dict[str, Any]", json.loads(path.read_text(encoding="utf-8")))
    except OSError as error:
        print(f"::error::cannot read {path}: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    except json.JSONDecodeError as error:
        print(f"::error::{path} is not valid JSON: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    resolved: dict[str, str] = {}
    for entry in document.get("pins", []):
        identity = str(entry["identity"]).lower()
        resolved[identity] = str(entry.get("state", {}).get("version", ""))
    return resolved


def documented_packages(path: Path) -> dict[str, tuple[str, str]]:
    """Read the inventory table out of the notices file.

    Args:
        path: The ``THIRD-PARTY-NOTICES.md`` to read.

    Returns:
        A mapping of lower-cased package name to ``(as-written name, version)``.

    Raises:
        SystemExit: The file or its inventory markers are missing.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        print(f"::error::cannot read {path}: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    if TABLE_START not in text or TABLE_END not in text:
        print(
            f"::error::{path.name} has no {TABLE_START} / {TABLE_END} inventory block",
            file=sys.stderr,
        )
        raise SystemExit(2)
    table = text[text.index(TABLE_START) : text.index(TABLE_END)]
    documented: dict[str, tuple[str, str]] = {}
    for match in ROW.finditer(table):
        name = match["name"]
        documented[name.lower()] = (name, match["version"])
    return documented


def main(argv: list[str]) -> int:
    """Compare the documented inventory against the resolved graph.

    Args:
        argv: Optional ``[package_resolved, notices_md]`` overrides.

    Returns:
        0 when the two agree, 1 when they differ, 2 when an input is unusable.
    """
    resolved_path = Path(argv[0]) if argv else ROOT / "Package.resolved"
    notices_path = Path(argv[1]) if len(argv) > 1 else ROOT / "THIRD-PARTY-NOTICES.md"

    resolved = resolved_packages(resolved_path)
    documented = documented_packages(notices_path)

    missing = sorted(name for name in resolved if name not in documented)
    extra = sorted(name for name in documented if name not in resolved)
    drifted = sorted(
        name for name in resolved if name in documented and documented[name][1] != resolved[name]
    )

    for name in missing:
        print(
            f"::error::{name} {resolved[name]} is in {resolved_path.name} but not in "
            f"{notices_path.name}: record its licence and reproduce any NOTICE text.",
            file=sys.stderr,
        )
    for name in extra:
        print(
            f"::error::{documented[name][0]} is in {notices_path.name} but is no longer "
            f"resolved by {resolved_path.name}: remove it.",
            file=sys.stderr,
        )
    for name in drifted:
        print(
            f"::error::{documented[name][0]} is documented at {documented[name][1]} but "
            f"{resolved_path.name} pins {resolved[name]}: update the row.",
            file=sys.stderr,
        )

    if missing or extra or drifted:
        return 1

    print(
        f"{notices_path.name} covers all {len(resolved)} resolved packages at the pinned versions"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
