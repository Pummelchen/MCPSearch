#!/usr/bin/env python3
"""Fail when line coverage of this repository's own ``Sources/`` drops below a floor.

SwiftPM instruments every target it builds, including the dependency checkouts under
``.build/checkouts/``, so an unfiltered total reads far lower than the code this repository owns:
the audit baseline was 40 % unfiltered against 84.3 % for ``Sources/`` alone. Only paths under the
repository's own ``Sources/`` directory are counted, which is what makes the number meaningful and
what makes a floor usable as a gate.

Several reports are accepted because the same code is reached from different processes: the test
bundle covers ``WebSearchCore``, while the MCP server and the monitor are only exercised as
subprocesses and emit their own profiles (ledger A04). Each binary gets its own ``llvm-cov
export``, and the counts are added up here — a file appears in exactly one of them, and a file
that somehow appeared in two is counted once.

Usage:
    coverage_floor.py <repo-sources-prefix> <floor-percent> <llvm-cov-export.json>...
"""

from __future__ import annotations

import json
import sys
from typing import Any, cast


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    prefix, floor_text = sys.argv[1], sys.argv[2]
    report_paths = sys.argv[3:]
    floor = float(floor_text)

    covered = total = 0
    counted: set[str] = set()
    for report_path in report_paths:
        with open(report_path, encoding="utf-8") as handle:
            report = cast("dict[str, Any]", json.load(handle))
        for entry in report["data"][0]["files"]:
            name = entry["filename"]
            if not name.startswith(prefix) or name in counted:
                continue
            counted.add(name)
            summary = entry["summary"]["lines"]
            covered += summary["covered"]
            total += summary["count"]

    percent = 100.0 * covered / total if total else 0.0
    print(
        f"Sources/ line coverage: {covered}/{total} = {percent:.1f} % "
        f"(floor {floor:.0f} %, {len(counted)} files from {len(report_paths)} report(s))"
    )
    if percent < floor:
        print(
            f"::error::Sources/ line coverage is {percent:.1f} %, below the {floor:.0f} % floor. "
            "Lower the floor only with a reason recorded in AUDIT/ledger.md.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
