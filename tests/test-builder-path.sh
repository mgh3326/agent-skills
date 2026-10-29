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


SPAWN_TABLE = "| T | spawn_mode |"


def check_spawn_worker(text: str) -> None:
    """The caller section must sit before the spawn_mode table and carry the
    proposition, not just the word 'builder'."""
    assert SPAWN_TABLE in text, "spawn_mode table missing"
    prefix = flat(text.split(SPAWN_TABLE, 1)[0])
    assert re.search(r"leaf\s*\(worker·tester\)\s*구성표", prefix), (
        "caller section must name the table a leaf(worker·tester) 구성표"
    )
    assert re.search(r"호출자는 builder", prefix), (
        "caller section must name builder as the caller"
    )
    assert re.search(r"director .{0,90}?직접 띄우지 않는다", prefix), (
        "caller section must forbid director from spawning workers directly"
    )
    assert re.search(r"§빌더 운용.{0,60}?builder 를 스폰한다", prefix), (
        "caller section must route director to §빌더 운용 -> spawn builder"
    )
    assert re.search(r"`builder` 스킬 §단독 모드", prefix), (
        "caller section must point solo-mode conditions at builder §단독 모드"
    )
    for t in ("T0", "T1", "T2", "T3"):
        assert f"| {t} |" in text, f"spawn_mode row {t} missing"


def check_director(text: str) -> None:
    """§빌더 운용 must state the spawn scope and the override audit rule."""
    sec = flat(section(text, "## 빌더 운용"))
    assert re.search(
        r"director 가 스폰하는 것은 builder 와 installer 뿐이다", sec
    ), "§빌더 운용 must state director spawns only builder and installer"
    assert re.search(
        r"worker·tester 직접 스폰은?\s*\**운영자 override 가 있을 때만", sec
    ), "direct worker/tester spawn must be gated on operator override"
    assert "decision ref" in sec and "큐" in sec, (
        "override must leave its decision ref in the queue"
    )
    assert "wrk spawn --role builder" in sec, "builder spawn command missing"
    assert "spawn-worker" in sec and "`builder` 스킬" in sec, (
        "§빌더 운용 must reference builder/spawn-worker skills"
    )


def check_builder(text: str) -> None:
    """Default rule stays; §단독 모드 carries all 6 conditions and reaches
    'director spawns builder'."""
    assert "워커와 tester는 빌더가 스폰한다" in text, (
        "default rule (builder spawns workers/testers) missing"
    )
    sec = flat(section(text, "### 단독 모드"))
    assert re.search(r"실측 급이", sec) and "worker 성적" in sec, (
        "condition 1: measured grade, no inference from worker results"
    )
    assert "PR 1개" in sec and "2라운드" in sec and "병렬 하위작업" in sec, (
        "condition 2: one PR / <=2 expected rounds / no parallel subtasks"
    )
    assert re.search(r"T2[^.]{0,60}독립 tester", sec), (
        "condition 3: T2+ requires independent tester"
    )
    assert "자기 구현의 tester" in sec and "provider family" in sec, (
        "condition 3: builder cannot test own implementation; T3 other family"
    )
    assert re.search(r"전에.{0,30}AC 검토", sec), (
        "condition 4: AC review ref before implementation"
    )
    assert re.search(r"의미.{0,50}ESC", sec), (
        "condition 5: AC meaning change -> ESC, not edit"
    )
    assert "builder 1명 = PR 1개" in sec, "condition 6: one builder = one PR"
    assert re.search(r"director 는 builder.{0,40}스폰한다", sec), (
        "builder file must itself reach 'director spawns builder'"
    )
    assert "§빌더 운용" in sec and "§2-1" in sec, (
        "builder §단독 모드 must reference director §빌더 운용 and "
        "spawn-worker §2-1"
    )


check_spawn_worker(spawn_text)
print("PASS spawn-worker caller-section leaf=1 caller=builder prohibition=1 solo-ptr=1 rows=4/4")

check_director(director_text)
print("PASS director spawn-scope builder+installer override-audit=1 spawn-cmd=1")

check_builder(builder_text)
print("PASS builder default-rule=1 solo-conditions=6/6 reach-director-spawns-builder=1")

# Reachability: every one of the three files independently states the
# proposition 'director spawns builder' at its designated anchor (checked
# above), not via an unrelated substring elsewhere in the file.
for name, text, anchor in (
    ("spawn-worker", spawn_text, r"§빌더 운용.{0,60}?builder 를 스폰한다"),
    ("director", director_text, r"스폰하는 것은 builder 와 installer 뿐이다"),
    ("builder", builder_text, r"director 는 builder.{0,40}스폰한다"),
):
    assert re.search(anchor, flat(text)), (
        f"{name}: 'director spawns builder' not reachable at its anchor"
    )
print("PASS reachability director->builder anchored=3/3")


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


caller_removed = re.sub(
    r"(?s)\*\*호출자는 builder.*?\n\n", "", spawn_text, count=1
)
assert caller_removed != spawn_text, "fixture: caller section not found to remove"

scope_line_removed = re.sub(
    r"(?s)\*\*director 가 스폰하는 것은.*?\n\n", "", director_text, count=1
)
assert scope_line_removed != director_text, (
    "fixture: director scope paragraph not found to remove"
)

solo_removed = re.sub(
    r"(?s)### 단독 모드.*?(?=\n### |\n## |\Z)", "", builder_text, count=1
)
assert solo_removed != builder_text, "fixture: solo section not found to remove"

override_gate_removed = director_text.replace("있을 때만", "있으면", 1)
assert override_gate_removed != director_text, (
    "fixture: override gate clause not found to weaken"
)

assertion_red_mutants = [
    (
        "spawn-worker-caller-section-removed",
        lambda: check_spawn_worker(caller_removed),
    ),
    (
        "director-spawn-scope-removed",
        lambda: check_director(scope_line_removed),
    ),
    (
        "director-override-gate-weakened",
        lambda: check_director(override_gate_removed),
    ),
    ("builder-solo-section-removed", lambda: check_builder(solo_removed)),
]
for label, callback in assertion_red_mutants:
    expect_assertion(label, callback)
print(
    "PASS mutants assertion-red="
    f"{len(assertion_red_mutants)}/{len(assertion_red_mutants)}"
)
PY
