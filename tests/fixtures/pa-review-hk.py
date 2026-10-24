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
    rows = [row for row in rows if isinstance(row, dict) and row["task_id"] == task and row["id"] > after_id]
    if os.environ.get("PA_REVIEW_NON_DICT"):
        rows.insert(0, None)
    if os.environ.get("PA_REVIEW_CALL_LOG"):
        with Path(os.environ["PA_REVIEW_CALL_LOG"]).open("a") as log:
            log.write(f"{task}|{limit}|{after_id}\n")
    print(json.dumps({"comments": rows[:limit]}))
elif args[:2] == ["tasks", "list"]:
    project = args[args.index("--project") + 1]
    state = args[args.index("--state") + 1]
    limit = int(args[args.index("--limit") + 1]) if "--limit" in args else 20
    if os.environ.get("PA_REVIEW_CALL_LOG"):
        with Path(os.environ["PA_REVIEW_CALL_LOG"]).open("a") as log:
            log.write(f"list|{project}|{state}|{limit}\n")
    if os.environ.get("PA_REVIEW_FAIL_LIST"):
        print("fixture list failure", file=sys.stderr)
        sys.exit(1)
    if project == "TruncatedProject":
        tasks = [{"id": 1} for _ in range(limit)]
    else:
        tasks = [{"id": task} for task in ([1935] if state == "merged" else [1891])]
    if os.environ.get("PA_REVIEW_NON_DICT"):
        tasks.insert(0, None)
    print(json.dumps({"tasks": tasks}))
else:
    print("unsupported fixture invocation", file=sys.stderr)
    sys.exit(2)
