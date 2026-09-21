#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import os
import re
import sys

root = Path(sys.argv[1])
builder_path = Path(os.environ.get("BUILDER_SKILL", root / "builder/SKILL.md"))
spawn_worker_path = Path(
    os.environ.get("SPAWN_WORKER_SKILL", root / "spawn-worker/SKILL.md")
)
relay_path = Path(os.environ.get("RELAY_SKILL", root / "relay-handoff/SKILL.md"))

builder_text = builder_path.read_text(encoding="utf-8")
spawn_text = spawn_worker_path.read_text(encoding="utf-8")
relay_text = relay_path.read_text(encoding="utf-8")


def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def section(text: str, heading: str) -> str:
    """Body of a ##/### section up to the next heading of same-or-higher level."""
    assert heading in text, f"missing heading: {heading}"
    body = text.split(heading, 1)[1]
    level = len(heading) - len(heading.lstrip("#"))
    m = re.search(rf"(?m)^#{{1,{level}}} ", body)
    return body[: m.start()] if m else body


INJECTION_HEADING = "## 후속 라운드·보충 지시의 주입"
TOOL = "panewire prompt --uptake status-transition"


def check_builder(text: str) -> None:
    """The follow-up injection section must carry the approved wording and the
    harness split, anchored inside its own section — not elsewhere."""
    sec = flat(section(text, INJECTION_HEADING))
    assert TOOL in sec, "follow-up injection tool (panewire prompt --uptake status-transition) missing"
    assert "send-text" in sec and "send-keys" in sec and re.search(
        r"복구 목적 외.{0,10}금지", sec
    ), "send-text/send-keys recovery-only ban missing"
    assert re.search(r"rc≠0.{0,40}재전송 전에 화면을 확인", sec), (
        "rc!=0 -> check screen before resend rule missing"
    )
    assert "expect:" in sec and "cwd" in sec, (
        "expect: name/cwd prompt-file requirement missing"
    )
    assert re.search(r"working.{0,40}거부|거부.{0,20}rc=6", sec) or "rc=6" in sec, (
        "working-target rejection (rc=6) missing"
    )
    assert "claude" in sec and "codex" in sec and "unproven" in sec, (
        "harness split (claude/codex provable, devin/grok/kimi unproven) missing"
    )
    assert re.search(r"queued 배너.{0,20}판정|배너로 판정", sec), (
        "unproven harnesses: judge by visible queued banner rule missing"
    )
    assert re.search(r"Enter.{0,10}보내지 않", sec) and "툴 호출을 취소" in sec, (
        "no-Enter-during-tool-call rule missing"
    )


def check_spawn_worker(text: str) -> None:
    """The §4 bullet that cites relay-handoff §3-1 must designate the same tool
    as builder and must not keep the herdr agent prompt designation."""
    bullet = None
    for line in text.splitlines():
        if "relay-handoff §3-1 정본" in line:
            bullet = line
            break
    assert bullet is not None, "§4 bullet citing relay-handoff §3-1 not found"
    # The bullet wraps over several lines; capture until the next top-level bullet.
    idx = text.index("relay-handoff §3-1 정본")
    start = text.rindex("\n- ", 0, idx) + 1
    nxt = text.find("\n- ", idx)
    blk = flat(text[start : nxt if nxt != -1 else len(text)])
    assert TOOL in blk or "panewire prompt --uptake" in blk, (
        "spawn-worker must designate panewire prompt --uptake status-transition "
        "for follow-up injection"
    )
    assert "builder` 스킬 §후속 라운드" in blk, (
        "spawn-worker bullet must point at builder §후속 라운드·보충 지시의 주입"
    )
    assert "send-text" in blk and "send-keys" in blk, (
        "spawn-worker bullet must repeat the send-text/send-keys ban"
    )
    assert not re.search(r"비-claude pane에는?\s*`herdr agent prompt`", blk), (
        "stale designation: bullet still assigns herdr agent prompt to "
        "non-claude panes (contradicts submission-verification duty)"
    )


def check_relay_handoff(text: str) -> None:
    """§3-1 must carve out follow-up/supplementary instructions to the same
    tool so all three files agree."""
    sec = flat(section(text, "### 3-1. 완료 통지·pane kind 분기 정본"))
    assert re.search(r"후속 라운드·보충 지시.{0,200}?panewire prompt", sec), (
        "relay-handoff §3-1 must exempt follow-up injection to panewire prompt"
    )
    assert "builder` 스킬 §후속 라운드" in sec, (
        "relay-handoff §3-1 must point at builder § as the normative source"
    )


check_builder(builder_text)
print("PASS builder injection-section tool=1 send-ban=1 rc-screen=1 expect=1 harness-split=1")

check_spawn_worker(spawn_text)
print("PASS spawn-worker same-tool=1 builder-ptr=1 stale-designation=0")

check_relay_handoff(relay_text)
print("PASS relay-handoff followup-carveout=1 builder-ptr=1")

# Cross-file agreement: all three files name the identical command for
# follow-up/supplementary injection.
for name, text in (
    ("builder", builder_text),
    ("spawn-worker", spawn_text),
    ("relay-handoff", relay_text),
):
    assert TOOL in flat(text), f"{name}: does not name '{TOOL}'"
print("PASS cross-file same-tool=3/3")


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


builder_section_removed = re.sub(
    rf"(?s){re.escape(INJECTION_HEADING)}.*?(?=\n## |\Z)", "", builder_text, count=1
)
assert builder_section_removed != builder_text, (
    "fixture: builder injection section not found to remove"
)

builder_uptake_stripped = builder_text.replace(" --uptake status-transition", "")
assert builder_uptake_stripped != builder_text, (
    "fixture: --uptake status-transition not found to strip"
)

builder_sendban_removed = builder_text.replace(
    "`herdr pane send-text` 와 `send-keys` 는 **복구 목적 외에 금지**한다 —",
    "",
    1,
)
assert builder_sendban_removed != builder_text, (
    "fixture: send-text/send-keys ban clause not found to remove"
)

builder_enter_removed = builder_text.replace(
    "**툴 실행 중에는 Enter 를 보내지 않는다**", "", 1
)
assert builder_enter_removed != builder_text, (
    "fixture: no-Enter-during-tool clause not found to remove"
)

spawn_tool_removed = spawn_text.replace(
    "후속 라운드·보충 지시의 주입은 `panewire prompt --uptake\n"
    "  status-transition` 으로 한다",
    "후속 라운드·보충 지시의 주입은 `herdr agent prompt` 로 한다",
    1,
)
assert spawn_tool_removed != spawn_text, (
    "fixture: spawn-worker panewire designation not found to revert"
)

relay_carveout_removed = re.sub(
    r"(?s)🔴 \*\*예외 — 후속 라운드·보충 지시.*?통지·질의에만 해당한다\.\n",
    "",
    relay_text,
    count=1,
)
assert relay_carveout_removed != relay_text, (
    "fixture: relay-handoff carve-out paragraph not found to remove"
)

assertion_red_mutants = [
    (
        "builder-injection-section-removed",
        lambda: check_builder(builder_section_removed),
    ),
    (
        "builder-uptake-flag-stripped",
        lambda: check_builder(builder_uptake_stripped),
    ),
    (
        "builder-send-ban-removed",
        lambda: check_builder(builder_sendban_removed),
    ),
    (
        "builder-no-enter-clause-removed",
        lambda: check_builder(builder_enter_removed),
    ),
    (
        "spawn-worker-tool-reverted",
        lambda: check_spawn_worker(spawn_tool_removed),
    ),
    (
        "relay-handoff-carveout-removed",
        lambda: check_relay_handoff(relay_carveout_removed),
    ),
]
for label, callback in assertion_red_mutants:
    expect_assertion(label, callback)
print(
    "PASS mutants assertion-red="
    f"{len(assertion_red_mutants)}/{len(assertion_red_mutants)}"
)
PY
