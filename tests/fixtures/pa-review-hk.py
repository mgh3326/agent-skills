#!/usr/bin/env python3
"""Small read-only handoffkeep fixture for pa-review-scan tests."""
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
if args[:2] == ["tasks", "comments"] and len(args) >= 3:
    task = int(args[2])
    limit = int(args[args.index("--limit") + 1]) if "--limit" in args else 100
    after_id = int(args[args.index("--after-id") + 1]) if "--after-id" in args else 0
    rows = json.loads(Path(os.environ["PA_REVIEW_FIXTURE"]).read_text())
    rows = sorted((row for row in rows if row["task_id"] == task and row["id"] > after_id),
                  key=lambda row: row["id"])
    if os.environ.get("PA_REVIEW_CALL_LOG"):
        with Path(os.environ["PA_REVIEW_CALL_LOG"]).open("a") as log:
            log.write(f"{task}|{limit}|{after_id}\n")
    print(json.dumps({"comments": rows[:limit]}))
elif args[:2] == ["tasks", "list"]:
    state = args[args.index("--state") + 1]
    tasks = [1935] if state == "open" else [1891]
    print(json.dumps({"tasks": [{"id": task} for task in tasks]}))
else:
    print("unsupported fixture invocation", file=sys.stderr)
    sys.exit(2)
