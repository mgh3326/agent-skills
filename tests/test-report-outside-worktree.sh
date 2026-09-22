#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import os
import re
import sys

root = Path(sys.argv[1])
spawn_worker_path = Path(
    os.environ.get("SPAWN_WORKER_SKILL", root / "spawn-worker/SKILL.md")
)
director_path = Path(os.environ.get("DIRECTOR_SKILL", root / "director/SKILL.md"))
builder_path = Path(os.environ.get("BUILDER_SKILL", root / "builder/SKILL.md"))

spawn_text = spawn_worker_path.read_text(encoding="utf-8")
director_text = director_path.read_text(encoding="utf-8")
builder_text = builder_path.read_text(encoding="utf-8")


def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def section(text: str, heading: str) -> str:
    """Body of a ##/### section up to the next heading of same-or-higher level."""
    assert heading in text, f"missing heading: {heading}"
    body = text.split(heading, 1)[1]
    level = len(heading) - len(heading.lstrip("#"))
    m = re.search(rf"(?m)^#{{1,{level}}} ", body)
    return body[: m.start()] if m else body


DELETE_PERMIT = r"(지워도\s*된다|지워도\s*좋다|삭제해도\s*된다|삭제해도\s*좋다)"


def check_spawn_worker(text: str) -> None:
    """§3 brief format must carry the write-side rule: report path is always
    outside the worktree and the brief must say 'do not delete it'."""
    sec = flat(section(text, "## 3. 브리프 작성"))
    assert "보고서는 worktree 밖에 두고 지우지 않는다" in sec, (
        "rule statement (report outside worktree, never delete) missing"
    )
    assert "지우지 마라" in sec, (
        "brief must tell the worker not to delete the report"
    )
    assert not re.search(DELETE_PERMIT, sec), (
        "delete-permission phrasing reverses the rule"
    )
    assert re.search(r"git status.{0,20}영향이 없다", sec), (
        "git status collision rationale missing"
    )


def check_builder(text: str) -> None:
    """The builder's brief format must repeat the same write-side rule."""
    sec = flat(section(text, "## 시작과 브리프"))
    assert re.search(r"보고서 경로는 항상\s*worktree 밖", sec), (
        "builder brief format must pin the report path outside the worktree"
    )
    assert "지우지 마라" in sec, (
        "builder brief format must carry the do-not-delete clause"
    )
    assert not re.search(DELETE_PERMIT, sec), (
        "delete-permission phrasing reverses the rule"
    )
    assert "빌더 자신의 보고서도 같은 규칙" in sec, (
        "builder's own report must be covered by the same rule"
    )


def check_director(text: str) -> None:
    """The merge gate's post-merge harvest item must carry the collect-side
    rule: report lives outside the worktree, harvest it before closing the
    pane, and the standing reap conditions are unchanged."""
    sec = flat(section(text, "## 머지 게이트"))
    assert re.search(r"보고서는 worktree 밖.{0,80}지우지 않는다", sec), (
        "post-merge harvest must keep reports outside the worktree and "
        "never delete them"
    )
    assert "먼저 회수" in sec, (
        "missing report must be harvested before the pane is closed"
    )
    assert "미push 0" in sec and "dry-run" in sec, (
        "standing harvest conditions must be cited unchanged"
    )
    assert not re.search(DELETE_PERMIT, sec), (
        "delete-permission phrasing reverses the rule"
    )


check_spawn_worker(spawn_text)
print("PASS spawn-worker write-side rule=1 no-delete-clause=1 git-status-rationale=1")

check_builder(builder_text)
print("PASS builder brief-format rule=1 own-report-covered=1")

check_director(director_text)
print("PASS director collect-side rule=1 harvest-before-close=1 standing-conditions-cited=1")


def expect_assertion(label, callback):
    try:
        callback()
    except AssertionError:
        return
    except Exception as exc:
        raise AssertionError(
            f"{label} mutant errored instead of assertion RED: {exc}"
        ) from exc
    raise AssertionError(f"{label} mutant did not go RED")


spawn_rule_removed = re.sub(
    r"(?s)🔴 \*\*보고서는 worktree 밖에 두고 지우지 않는다.*?남고 산출물이 사라진다\.\n\n",
    "",
    spawn_text,
    count=1,
)
assert spawn_rule_removed != spawn_text, (
    "fixture: spawn-worker report-outside paragraph not found to remove"
)

spawn_rule_inverted = spawn_text.replace("지우지 마라", "지워도 된다", 1)
assert spawn_rule_inverted != spawn_text, (
    "fixture: spawn-worker do-not-delete clause not found to invert"
)

builder_rule_removed = re.sub(
    r"(?s) 🔴 보고서 경로는 항상.*?같은 규칙이다\.",
    ".",
    builder_text,
    count=1,
)
assert builder_rule_removed != builder_text, (
    "fixture: builder brief-format rule not found to remove"
)

director_rule_removed = re.sub(
    r"(?s) 🔴 보고서는 worktree 밖.*?바꾸지 않는다\.",
    ".",
    director_text,
    count=1,
)
assert director_rule_removed != director_text, (
    "fixture: director harvest rule not found to remove"
)

director_close_first = director_text.replace(
    "pane을 닫기 전에 먼저 회수한다",
    "pane을 먼저 닫고 나중에 회수한다",
    1,
)
assert director_close_first != director_text, (
    "fixture: director harvest-before-close clause not found to invert"
)

assertion_red_mutants = [
    (
        "spawn-worker-rule-removed",
        lambda: check_spawn_worker(spawn_rule_removed),
    ),
    (
        "spawn-worker-rule-inverted",
        lambda: check_spawn_worker(spawn_rule_inverted),
    ),
    ("builder-rule-removed", lambda: check_builder(builder_rule_removed)),
    (
        "director-rule-removed",
        lambda: check_director(director_rule_removed),
    ),
    (
        "director-close-before-harvest",
        lambda: check_director(director_close_first),
    ),
]
for label, callback in assertion_red_mutants:
    expect_assertion(label, callback)
print(
    "PASS mutants assertion-red="
    f"{len(assertion_red_mutants)}/{len(assertion_red_mutants)}"
)
PY
