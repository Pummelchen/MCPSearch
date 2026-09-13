#!/usr/bin/env python3
"""Fail when line coverage of this repository's own ``Sources/`` drops below a floor.

SwiftPM instruments every target it builds, including the dependency checkouts under
``.build/checkouts/``, so an unfiltered total reads far lower than the code this repository owns:
the audit baseline was 40 % unfiltered against 84.3 % for ``Sources/`` alone. Only paths under the
repository's own ``Sources/`` directory are counted, which is what makes the number meaningful and
what makes a floor usable as a gate.

Usage:
    coverage_floor.py <repo-sources-prefix> <floor-percent> <llvm-cov-export.json>
"""

from __future__ import annotations

import json
import sys
from typing import Any, cast


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    prefix, floor_text, report_path = sys.argv[1], sys.argv[2], sys.argv[3]
    floor = float(floor_text)

    with open(report_path, encoding="utf-8") as handle:
        report = cast("dict[str, Any]", json.load(handle))

    covered = total = 0
    for entry in report["data"][0]["files"]:
        if not entry["filename"].startswith(prefix):
            continue
        summary = entry["summary"]["lines"]
        covered += summary["covered"]
        total += summary["count"]

    percent = 100.0 * covered / total if total else 0.0
    print(f"Sources/ line coverage: {covered}/{total} = {percent:.1f} % (floor {floor:.0f} %)")
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
