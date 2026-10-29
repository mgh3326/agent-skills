#!/usr/bin/env bash
# Report-outside-worktree contract (2026-09-03 incident, hk 2290): a worker
# told to leave a clean `git status` deleted a report written inside its
# worktree. wake/SKILL.md must carry both sides of the fix:
#   write side — §Brief rules and the §Worker brief template put the report
#   outside the worktree and tell the worker not to delete it;
#   collect side — merge step 8 harvests a missing report from the pane before
#   the pane is reaped.
# Each mutant weakens one clause in memory and must go RED by assertion.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import os
import re
import sys

root = Path(sys.argv[1])
wake_path = Path(os.environ.get("WAKE_SKILL", root / "wake/SKILL.md"))
wake_text = wake_path.read_text(encoding="utf-8")


def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def section(text: str, heading: str) -> str:
    """Body of a ##/### section up to the next heading of same-or-higher level."""
    assert heading in text, f"missing heading: {heading}"
    body = text.split(heading, 1)[1]
    level = len(heading) - len(heading.lstrip("#"))
    m = re.search(rf"(?m)^#{{1,{level}}} ", body)
    return body[: m.start()] if m else body


DELETE_PERMIT = r"(?i)(may|can|should) (be )?delete|delete it when|clean it up"
REPORT_PATH = "~/work/herdr-inbox/jobs/<job>/report.md"


def check_brief_rules(text: str) -> None:
    sec = flat(section(text, "## Brief rules"))
    assert re.search(r"\*\*Report outside the worktree:\*\*", sec), "brief rule heading missing"
    assert REPORT_PATH in sec, "brief rule must name the report path outside the worktree"
    assert re.search(r"does not affect `git status` and must not be deleted", sec), (
        "brief rule must say the path does not affect git status and must not be deleted"
    )
    assert re.search(r"clean-tree exit condition makes the worker delete it", sec), (
        "brief rule must keep the incident rationale"
    )
    assert not re.search(DELETE_PERMIT, sec), "delete-permission phrasing reverses the rule"


def check_template(text: str) -> None:
    sec = flat(section(text, "## Done"))
    assert REPORT_PATH.replace("~/work", "~/work") in sec, "template report path missing"
    assert re.search(r"outside the worktree, so it does not affect `git status`; do not delete it", sec), (
        "worker brief template must carry the outside-worktree / do-not-delete clause"
    )
    assert not re.search(DELETE_PERMIT, sec), "delete-permission phrasing in the template"


def check_collect(text: str) -> None:
    loop = flat(section(text, "## The loop"))
    m = re.search(r"8\. \*\*Merge\*\*.*", loop)
    assert m, "merge step 8 missing"
    step = m.group(0)
    assert re.search(r"check the report exists at its path outside the worktree", step), (
        "step 8 must check the report outside the worktree"
    )
    assert re.search(r"harvest it from the pane first if not — a closed pane loses it", step), (
        "a missing report must be harvested before the pane is reaped"
    )
    before = step[: step.index("harvest it from the pane first")]
    assert "reap" not in before, "harvest must come before any reap"
    assert "close the hk task" not in before, "the report check must come before closing the task"


def check(text: str) -> None:
    check_brief_rules(text)
    check_template(text)
    check_collect(text)


check(wake_text)
print("PASS wake write-side brief-rule=1 template=1 collect-side harvest-before-reap=1")


def mutate(old: str, new: str) -> str:
    """Replace one occurrence of old, matching any line wrapping."""
    pattern = r"\s+".join(re.escape(word) for word in old.split())
    assert len(re.findall(pattern, wake_text)) == 1, f"fixture: anchor not unique: {old!r}"
    return re.sub(pattern, lambda _m: new, wake_text, count=1)


mutants = {
    "brief-rule-removed": mutate(
        "- **Report outside the worktree:**", "- **Report location:**"),
    "brief-rule-delete-permitted": mutate(
        "does not affect `git status` and must\n  not be deleted",
        "does not affect `git status` and may\n  be deleted after READY"),
    "brief-rule-rationale-dropped": mutate(
        " — otherwise a\n  clean-tree exit condition makes the worker delete it.", "."),
    "template-clause-dropped": mutate(
        " — outside the worktree, so it does not affect\n`git status`; do not delete it:", ":"),
    "template-delete-permitted": mutate(
        "do not delete it:", "you can delete it when the PR merges:"),
    "collect-harvest-dropped": mutate(
        " (harvest it from the pane first if not — a closed pane loses it)", ""),
    "collect-reap-before-harvest": mutate(
        "check the report exists at its path outside the worktree",
        "reap, then check the report exists at its path outside the worktree"),
    "collect-task-closed-before-report": mutate(
        "check the report exists at its path outside the worktree",
        "close the hk task, check the report exists at its path outside the worktree"),
}
for name, doc in mutants.items():
    try:
        check(doc)
    except AssertionError:
        print(f"RED {name}")
        continue
    raise SystemExit(f"mutant {name} did not go RED")
print(f"PASS mutants assertion-red={len(mutants)}/{len(mutants)}")
PY
