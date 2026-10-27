#!/usr/bin/env python3
"""Fail when this test run left a process whose argv names its private files."""
import os
import subprocess
import sys


root_raw = os.environ["WRK_LEAK_ROOT"]
root = os.path.realpath(root_raw)
wrk_raw = os.environ.get("WRK_LEAK_COPY", "")
wrk = os.path.realpath(wrk_raw) if wrk_raw else ""
needles = list(dict.fromkeys((root_raw, root)))
if wrk and (wrk.startswith(root + os.sep) or wrk_raw.startswith(root_raw + os.sep)):
    needles.extend((wrk_raw, wrk))

result = subprocess.run(
    ["ps", "-axo", "pid=,command="],
    check=True,
    capture_output=True,
    text=True,
)
leaks = []
for line in result.stdout.splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) != 2:
        continue
    pid, argv = fields
    if any(needle and needle in argv for needle in needles):
        leaks.append((pid, argv))

if leaks:
    print("FAIL: test left wrk-related processes alive:", file=sys.stderr)
    for pid, argv in leaks:
        print(f"  pid={pid} argv={argv}", file=sys.stderr)
    sys.exit(1)

print("PASS: no wrk-related process contains this run's temp root or wrk copy")
