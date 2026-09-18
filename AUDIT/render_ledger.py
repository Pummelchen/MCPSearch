#!/usr/bin/env python3
"""Render AUDIT/ledger.md from AUDIT/ledger.json.

`ledger.json` is the single source of truth (§8) and this is the only thing that writes
`ledger.md` (§9): the markdown is generated output, never edited by hand, so the two cannot drift.

It also validates the ledger it renders. A task missing a required field, carrying an unknown
status, or claiming DONE without an evidence-after or a commit fails the render — a ledger that
cannot be checked is a tracker, not a source of truth.

Usage:
    python3 AUDIT/render_ledger.py          # write AUDIT/ledger.md
    python3 AUDIT/render_ledger.py --check  # validate and report the counts, write nothing
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

AUDIT = Path(__file__).resolve().parent
LEDGER = AUDIT / "ledger.json"
OUTPUT = AUDIT / "ledger.md"

REQUIRED = (
    "id",
    "severity",
    "tier",
    "project",
    "location",
    "title",
    "category",
    "status",
    "host",
    "discovered_by",
    "evidence_before",
    "fix_summary",
    "evidence_after",
    "commit",
    "blocked_reason",
)
SEVERITIES = ("S0", "S1", "S2", "S3")
# Terminal states are DONE and BLOCKED; everything else is open work (§8).
TERMINAL = ("DONE", "BLOCKED")
STATUSES = ("OPEN", "PROGRESS", "TEST", "AUDIT", "SWEPT", "DONE", "BLOCKED")
# A status that claims completion must carry the evidence that proves it.
NEEDS_EVIDENCE = ("DONE",)


class LedgerError(Exception):
    """The ledger is malformed; the render is refused rather than emitted wrong."""


def load() -> dict[str, Any]:
    data = json.loads(LEDGER.read_text(encoding="utf-8"))
    tasks = data.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        raise LedgerError("ledger.json has no tasks")
    seen: set[str] = set()
    for task in tasks:
        where = task.get("id", "<missing id>")
        missing = [field for field in REQUIRED if field not in task]
        if missing:
            raise LedgerError(f"{where}: missing field(s) {missing}")
        if task["severity"] not in SEVERITIES:
            raise LedgerError(f"{where}: unknown severity {task['severity']!r}")
        if task["status"] not in STATUSES:
            raise LedgerError(f"{where}: unknown status {task['status']!r}")
        if task["id"] in seen:
            raise LedgerError(f"{where}: duplicate id")
        seen.add(task["id"])
        if task["status"] in NEEDS_EVIDENCE and not (task["evidence_after"] and task["commit"]):
            raise LedgerError(f"{where}: {task['status']} needs evidence_after and commit")
        if task["status"] == "BLOCKED" and not task["blocked_reason"]:
            raise LedgerError(f"{where}: BLOCKED needs a blocked_reason naming an owner")
        completed_s0_s1 = task["severity"] in ("S0", "S1") and task["status"] == "DONE"
        if completed_s0_s1 and not task["fix_summary"]:
            raise LedgerError(f"{where}: a done S0/S1 needs a fix_summary")
    return data


def counts(tasks: list[dict[str, Any]]) -> dict[str, int]:
    done = sum(1 for t in tasks if t["status"] == "DONE")
    blocked = sum(1 for t in tasks if t["status"] == "BLOCKED")
    return {
        "total": len(tasks),
        "done": done,
        "blocked": blocked,
        "open": len(tasks) - done - blocked,
    }


def render(data: dict[str, Any]) -> str:
    meta = data["meta"]
    tasks = data["tasks"]
    tally = counts(tasks)
    by_severity = {s: [t for t in tasks if t["severity"] == s] for s in SEVERITIES}
    by_status: dict[str, int] = {}
    for task in tasks:
        by_status[task["status"]] = by_status.get(task["status"], 0) + 1

    lines = [
        "# Audit ledger — MCPSearch",
        "",
        "**Generated from `AUDIT/ledger.json` by `AUDIT/render_ledger.py`. Do not edit this",
        "file** —",
        "edit the JSON and re-render, so the two cannot disagree (§8, §9).",
        "",
        f"- Repository: `{meta['repo']}`",
        f"- Branch: `{meta['branch']}` (from `{meta['base_commit']}`)",
        f"- Primary host: `{meta['primary_host']}`; "
        f"verification host: `{meta['verification_host']}`",
        "",
        "## Counts",
        "",
        f"**total {tally['total']} — done {tally['done']} · open {tally['open']} · "
        f"blocked {tally['blocked']}**",
        "",
        "| Severity | Total | Done | Open | Blocked |",
        "| --- | --- | --- | --- | --- |",
    ]
    for severity in SEVERITIES:
        group = by_severity[severity]
        if not group:
            continue
        done = sum(1 for t in group if t["status"] == "DONE")
        blocked = sum(1 for t in group if t["status"] == "BLOCKED")
        open_count = len(group) - done - blocked
        lines.append(f"| {severity} | {len(group)} | {done} | {open_count} | {blocked} |")
    lines += [
        "",
        "Status tally: "
        + ", ".join(
            f"{status} {by_status.get(status, 0)}" for status in STATUSES if by_status.get(status)
        ),
        "",
        "## Tasks",
        "",
        "| id | sev | tier | status | title |",
        "| --- | --- | --- | --- | --- |",
    ]
    for task in sorted(tasks, key=lambda t: (SEVERITIES.index(t["severity"]), t["id"])):
        lines.append(
            f"| {task['id']} | {task['severity']} | {task['tier']} | {task['status']} | "
            f"{task['title']} |"
        )
    lines += ["", "---", ""]
    for task in sorted(tasks, key=lambda t: (SEVERITIES.index(t["severity"]), t["id"])):
        lines += [
            f"### {task['id']} — {task['title']}",
            "",
            f"- **Severity / tier / status:** "
            f"{task['severity']} / {task['tier']} / {task['status']}",
            f"- **Location:** `{task['location']}`",
            f"- **Category:** {task['category']}",
            f"- **Host:** {task['host']}",
            f"- **Discovered by:** {task['discovered_by']}",
            f"- **Evidence before:** {task['evidence_before']}",
        ]
        if task["fix_summary"]:
            lines.append(f"- **Fix:** {task['fix_summary']}")
        if task["evidence_after"]:
            lines.append(f"- **Evidence after:** {task['evidence_after']}")
        if task["commit"]:
            lines.append(f"- **Commit:** `{task['commit']}`")
        if task["blocked_reason"]:
            lines.append(f"- **BLOCKED:** {task['blocked_reason']}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    try:
        data = load()
    except LedgerError as error:
        print(f"LEDGER INVALID: {error}", file=sys.stderr)
        return 1
    tally = counts(data["tasks"])
    if "--check" in sys.argv:
        print(
            f"ledger ok: total {tally['total']} done {tally['done']} "
            f"open {tally['open']} blocked {tally['blocked']}"
        )
        return 0
    OUTPUT.write_text(render(data), encoding="utf-8")
    print(
        f"wrote {OUTPUT.relative_to(AUDIT.parent)}: total {tally['total']} done {tally['done']} "
        f"open {tally['open']} blocked {tally['blocked']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
