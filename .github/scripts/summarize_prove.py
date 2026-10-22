#!/usr/bin/env python3
"""Extract per-file TAP counts from a serial `prove -v` console log.

The original console log and prove exit status remain the test authority.
Fail rather than produce a partial success summary when the format changes.
"""
import json
import re
import sys
from pathlib import Path


def summarize(text):
    rows = []
    current = None
    for line in text.splitlines():
        start = re.match(r"^(\S+\.t)\s+\.{2,}\s*$", line)
        if start:
            current = {"file": start[1], "planned": None, "seen": 0,
                       "failed": 0, "skipped": 0, "todo": 0,
                       "skip_all": False, "harness_error": False}
            rows.append(current)
        elif current is not None:
            plan = re.match(r"^1\.\.(\d+)(.*)$", line)
            # Test::More numbers assertions; bare 'ok' is the formatter status.
            assertion = re.match(r"^(not ok|ok)\s+\d+\b(.*)$", line)
            if plan:
                current["planned"] = int(plan[1])
                current["skip_all"] = int(plan[1]) == 0 and bool(
                    re.search(r"#\s*SKIP\b", plan[2], re.I))
            elif assertion:
                current["seen"] += 1
                todo = bool(re.search(r"#\s*TODO\b", assertion[2], re.I))
                current["todo"] += int(todo)
                current["skipped"] += int(bool(re.search(
                    r"#\s*SKIP\b", assertion[2], re.I)))
                current["failed"] += int(assertion[1] == "not ok" and not todo)
            elif re.match(r"^(Dubious|Failed|Bail out!)", line):
                current["harness_error"] = True
    totals = re.search(r"^Files=(\d+), Tests=(\d+),", text, re.M)
    if not rows or not totals or len(rows) != int(totals[1]):
        raise ValueError("Cannot reconcile per-file records with prove file count")
    if sum(row["seen"] for row in rows) != int(totals[2]):
        raise ValueError("Cannot reconcile TAP assertions with prove test count")
    for row in rows:
        row["result"] = "SKIP" if row["skip_all"] else (
            "FAIL" if row["failed"] or row["harness_error"]
            or row["planned"] != row["seen"] else "PASS")
    return {"files": int(totals[1]), "tests": int(totals[2]), "results": rows}


if __name__ == "__main__":
    result = summarize(Path(sys.argv[1]).read_text(errors="replace"))
    Path(sys.argv[2]).write_text(json.dumps(result, indent=2) + "\n")
