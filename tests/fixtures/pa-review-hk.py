#!/usr/bin/env python3
"""Small read-only handoffkeep fixture for pa-review-scan tests."""
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
if args[:2] == ["tasks", "comments"] and len(args) == 3:
    task = int(args[2])
    rows = json.loads(Path(os.environ["PA_REVIEW_FIXTURE"]).read_text())
    print(json.dumps({"comments": [row for row in rows if row["task_id"] == task]}))
elif args[:2] == ["tasks", "list"]:
    state = args[args.index("--state") + 1]
    tasks = [1935] if state == "open" else [1891]
    print(json.dumps({"tasks": [{"id": task} for task in tasks]}))
else:
    print("unsupported fixture invocation", file=sys.stderr)
    sys.exit(2)
