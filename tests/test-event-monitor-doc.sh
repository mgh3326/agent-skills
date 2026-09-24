#!/usr/bin/env bash
# #636 part A (AC1+AC5): the polling-monitor ban must stay executable.
#
# A director session accumulated 256 session-bound polling monitors over 96h
# and lost 34 of them in one reboot (hk:doc
# task/2026-09-24/director-monitors-to-panewire). The fix is contract text:
# director/SKILL.md bans per-job polling loops and binds the allowed signals
# to the deployed-build event table; builder/SKILL.md makes spawned builders
# idle-wait on pushed events instead of re-checking every turn. This guard:
#
#   1. director §감시 정책 carries the ban, the event-subscription rule, the
#      missing-event -> task rule, a numeric concurrency cap with its
#      rationale, and a pointer to the event table;
#   2. builder carries the idle-until-event rule, the per-turn re-check ban,
#      and the single blocking-wait exception;
#   3. director/panewire-events.md keeps all four categories and marks
#      deployed-only "있음" separately from source-only "미배포";
#   4. mutants (wording or table rows removed) go RED through an assertion.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import os
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
director_path = Path(os.environ.get("DIRECTOR_SKILL", root / "director/SKILL.md"))
builder_path = Path(os.environ.get("BUILDER_SKILL", root / "builder/SKILL.md"))
events_path = Path(os.environ.get("EVENTS_DOC", root / "director/panewire-events.md"))

director_text = director_path.read_text(encoding="utf-8")
builder_text = builder_path.read_text(encoding="utf-8")
events_text = events_path.read_text(encoding="utf-8")


def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def section(text: str, heading: str) -> str:
    """Body of a ##/### section up to the next heading of same-or-higher level."""
    assert heading in text, f"missing heading: {heading}"
    body = text.split(heading, 1)[1]
    level = len(heading) - len(heading.lstrip("#"))
    m = re.search(rf"(?m)^#{{1,{level}}} ", body)
    return body[: m.start()] if m else body


def check_director(text: str) -> None:
    """§감시 정책 must ban per-job polling loops, route to event subscription,
    escalate missing events to tasks, and carry a numeric cap with rationale."""
    sec = flat(section(text, "## 감시 정책"))
    assert re.search(r"폴링 루프.{0,80}(감시하지|금지|상한은 0)", sec) or re.search(
        r"상한은 0", sec
    ), "per-job polling-loop ban missing (cap must be 0)"
    assert re.search(r"job\.\*", sec) and "lane.event" in sec and "idle-wake" in sec, (
        "event-subscription rule must name job.* / lane.event / idle-wake"
    )
    assert re.search(r"부족한 이벤트.{0,60}태스크", sec), (
        "missing events must go to a task, not back to polling"
    )
    assert re.search(r"동시 3개 이하|3개 이하", sec), (
        "concurrency cap number (3) missing"
    )
    assert "256" in flat(text), "cap rationale must cite the 96h/256 measured count"
    assert "panewire-events.md" in sec, "section must point at the event table"


def check_builder(text: str) -> None:
    """Builder must idle after spawning, wake on pushed events, never re-check
    per turn, and get exactly one blocking wait."""
    sec = flat(section(text, "### 스폰 후 대기"))
    assert re.search(r"유휴로 대기하고.{0,40}알림으로 깨어난다", sec), (
        "idle-until-completion-notification rule missing"
    )
    assert re.search(r"턴마다.{0,60}폴링 반복은 금지|턴.{0,20}확인.{0,20}금지", sec), (
        "per-turn re-check ban missing"
    )
    assert re.search(r"블로킹 명령 1개", sec) and "panewire wait" in sec, (
        "single bounded blocking-wait exception missing"
    )
    assert "panewire-events.md" in sec, "builder must point at the event table"


def check_events_doc(text: str) -> None:
    """The table must keep all four categories, deployed versions, and the
    deployed/source split that keeps '있음' honest."""
    for category in ("빌더·워커 감시", "호스트 건강", "CI·PR 대기", "기타"):
        assert re.search(rf"(?m)^## \d+\. {re.escape(category)}\s*$", text), (
            f"category section missing: {category}"
        )
    assert "pw-e401923" in text and "pw-05667f4" in text, (
        "deployed build pins (hub pw-e401923, node pw-05667f4) missing"
    )
    assert "미배포" in text, "source-only rows must be marked 미배포"
    assert "**있음**" in text, "deployed-available rows must be marked 있음"
    assert re.search(r"job\.lost.*미배포|미배포.*job\.lost", flat(text), re.S) or (
        "job.lost" in text and "미배포" in text
    ), "job.lost/revoked must be marked 미배포 (source-only, #80)"
    assert re.search(r"CI.{0,10}대기 결론|짧게 기다린다", flat(text)), (
        "CI wait conclusion (scope 4) missing"
    )
    assert "task/2026-09-24/director-monitors-to-panewire" in text, (
        "canonical requirement ref missing"
    )


check_director(director_text)
print("PASS director ban=1 subscribe=1 missing->task=1 cap=3 rationale=1 doc-ptr=1")

check_builder(builder_text)
print("PASS builder idle-wait=1 no-per-turn-recheck=1 blocking-wait-1=1 doc-ptr=1")

check_events_doc(events_text)
print("PASS events-doc categories=4/4 pins=2 deployed/source-split=1 ci-conclusion=1")


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


director_section_removed = re.sub(
    r"(?s)## 감시 정책.*?(?=\n## |\Z)", "", director_text, count=1
)
assert director_section_removed != director_text, (
    "fixture: director 감시 정책 section not found to remove"
)

director_cap_removed = director_text.replace("동시 3개 이하", "동시 적당히", 1)
assert director_cap_removed != director_text, (
    "fixture: director cap number not found to weaken"
)

director_task_rule_removed = re.sub(
    r"(?s)\*\*부족한 이벤트는.*?\n\n", "\n", director_text, count=1
)
assert director_task_rule_removed != director_text, (
    "fixture: director missing-event->task bullet not found"
)

builder_section_removed = re.sub(
    r"(?s)### 스폰 후 대기.*?(?=\n### |\n## |\Z)", "", builder_text, count=1
)
assert builder_section_removed != builder_text, (
    "fixture: builder 대기 section not found to remove"
)

events_deployed_split_removed = events_text.replace("미배포", "있음")
assert events_deployed_split_removed != events_text, (
    "fixture: events doc 미배포 markers not found"
)

events_category_removed = events_text.replace("## 3. CI·PR 대기", "## 3. 대기", 1)
assert events_category_removed != events_text, (
    "fixture: events doc CI category heading not found"
)

mutants = [
    ("director-section-removed", lambda: check_director(director_section_removed)),
    ("director-cap-weakened", lambda: check_director(director_cap_removed)),
    (
        "director-missing-event-task-rule-removed",
        lambda: check_director(director_task_rule_removed),
    ),
    ("builder-section-removed", lambda: check_builder(builder_section_removed)),
    (
        "events-deployed-source-split-removed",
        lambda: check_events_doc(events_deployed_split_removed),
    ),
    ("events-ci-category-renamed", lambda: check_events_doc(events_category_removed)),
]
for label, callback in mutants:
    expect_assertion(label, callback)
print(f"PASS mutants assertion-red={len(mutants)}/{len(mutants)}")
PY
