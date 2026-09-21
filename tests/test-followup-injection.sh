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
PERMISSION = r"(내도|써도|써도 좋|자유롭게|허용한다|허용이다)"


def no_permission_near_banned(sec: str) -> None:
    """send-text/send-keys may appear only inside the recovery-only ban —
    any permission phrasing near them is a direction reversal."""
    for m in re.finditer(r"send-text|send-keys", sec):
        tail = sec[m.end() : m.end() + 80]
        assert not re.search(PERMISSION, tail), (
            "permission phrasing near send-text/send-keys "
            f"(context: ...{tail[:60]})"
        )


def check_builder(text: str) -> None:
    """The follow-up injection section must carry the approved wording, the
    harness split (in the right direction), and operational details —
    anchored inside its own section."""
    sec = flat(section(text, INJECTION_HEADING))
    assert re.search(r"후속 라운드·보충 지시의 주입은.{0,60}panewire prompt", sec), (
        "follow-up injection designation for panewire prompt missing"
    )
    assert TOOL in sec, "--uptake status-transition flag missing"
    assert "send-text" in sec and "send-keys" in sec and re.search(
        r"복구\s*목적 외에 금지", sec
    ), "send-text/send-keys recovery-only ban missing"
    no_permission_near_banned(sec)
    assert "재전송 전에 화면을 확인한다" in sec, (
        "rc!=0 -> check screen before resend rule missing"
    )
    assert "확인하지 않고" not in sec, "negated screen-check rule present"
    assert re.search(r"panewire prompt --from.{0,80}--to.{0,80}--file", sec), (
        "command shape (--from/--to/--file) missing"
    )
    assert "--timeout" in sec and "rc=3" in sec, (
        "default-timeout trap / rc=3 wording missing"
    )
    assert "expect:" in sec and re.search(r"name=.{0,10}또는.{0,10}cwd=", sec), (
        "expect: name=/cwd= prompt-file requirement missing"
    )
    assert "rc=6" in sec and re.search(r"working.{0,40}거부", sec), (
        "working-target rejection (rc=6) missing"
    )
    # Harness split must be directional: claude/codex provable, others unproven.
    assert re.search(r"제출 증명은 claude·codex 에서만", sec), (
        "direction: submission evidence must be pinned to claude/codex"
    )
    assert "harnessHasSubmissionEvidence" in sec, (
        "harnessHasSubmissionEvidence citation missing"
    )
    assert "devin·grok·kimi" in sec and "unproven" in sec, (
        "devin/grok/kimi unproven group missing"
    )
    assert "composer_residue" in sec, "composer_residue outcome missing"
    assert re.search(r"queued 배너로 판정", sec), (
        "unproven harnesses: judge by visible queued banner rule missing"
    )
    assert "명시 제출" in sec, "explicit-submit rule missing"
    assert "Enter 를 보내지 않" in sec and "툴 호출을 취소" in sec, (
        "no-Enter-during-tool-call rule missing"
    )
    assert "command still running" in sec and "소비 마커" in sec, (
        "grok banner/landing-marker reconciliation missing"
    )
    assert "relay-handoff §3-2" in sec, "§3-2 marker-table pointer missing"


def check_spawn_worker(text: str) -> None:
    """The §4 bullet that cites relay-handoff §3-1 must designate the same tool
    as builder and carry no herdr agent prompt designation at all."""
    idx = text.find("relay-handoff §3-1 정본")
    assert idx != -1, "§4 bullet citing relay-handoff §3-1 not found"
    start = text.rindex("\n- ", 0, idx) + 1
    nxt = text.find("\n- ", idx)
    blk = flat(text[start : nxt if nxt != -1 else len(text)])
    assert "panewire prompt --uptake status-transition" in blk, (
        "spawn-worker must designate panewire prompt --uptake "
        "status-transition for follow-up injection"
    )
    assert "builder` 스킬 §후속 라운드" in blk, (
        "spawn-worker bullet must point at builder §후속 라운드·보충 지시의 주입"
    )
    assert "herdr agent prompt" not in blk, (
        "bullet must not designate herdr agent prompt for pane instructions "
        "(a non-submitting tool contradicts the submission-verification duty)"
    )
    assert "send-text" in blk and "send-keys" in blk and re.search(
        r"복구 목적 외에 금지", blk
    ), "spawn-worker bullet must repeat the send-text/send-keys ban"
    no_permission_near_banned(blk)


def check_relay_handoff(text: str) -> None:
    """§3-1 must carve out follow-up/supplementary instructions to panewire
    (direction pinned), and §3-2 must defer submit-timing to builder §."""
    sec = flat(section(text, "### 3-1. 완료 통지·pane kind 분기 정본"))
    assert re.search(
        r"herdr agent prompt.{0,10}가 아니라.{0,40}panewire prompt --uptake "
        r"status-transition",
        sec,
    ), ("relay-handoff §3-1 must pin the direction: NOT herdr agent prompt "
        "but panewire prompt --uptake status-transition")
    assert "builder` 스킬 §후속 라운드" in sec, (
        "relay-handoff §3-1 must point at builder § as the normative source"
    )
    assert "send-text" in sec and "send-keys" in sec and re.search(
        r"복구 목적 외에 금지", sec
    ), "relay-handoff carve-out must repeat the send-text/send-keys ban"
    assert "초기 브리프 주입과 통지·질의에만 해당" in sec, (
        "carve-out scope sentence (initial-injection/notify only) missing"
    )
    sec32 = flat(section(text, "### 3-2. 하네스별 제출 마커 표 (측정한 것만)"))
    assert "builder` 스킬 §후속 라운드" in sec32 and "정본" in sec32, (
        "§3-2 must defer follow-up submit-timing to builder § (precedence note)"
    )


check_builder(builder_text)
print("PASS builder injection-section tool=1 send-ban=1 rc-screen=1 "
      "expect=1 cmdshape=1 harness-split-directional=1")

check_spawn_worker(spawn_text)
print("PASS spawn-worker same-tool=1 builder-ptr=1 no-agent-prompt=1")

check_relay_handoff(relay_text)
print("PASS relay-handoff carveout-directional=1 builder-ptr=2 scope=1")

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
    "**본문 주입 수단으로는 복구\n  목적 외에 금지**한다",
    "**언제든 허용**한다",
    1,
)
assert builder_sendban_removed != builder_text, (
    "fixture: send-text/send-keys ban clause not found to weaken"
)

builder_send_permitted = builder_text.replace(
    "미제출 브리프가 컴포저에서 이어 붙는다",
    "미제출 브리프가 컴포저에서 이어 붙는다. 급하면 `herdr pane send-text` 로 "
    "후속 지시를내도 된다",
    1,
)
assert builder_send_permitted != builder_text, (
    "fixture: builder send-permit injection point not found"
)

builder_enter_removed = builder_text.replace(
    "**툴 실행\n  중에는 Enter 를 보내지 않는다**", "", 1
)
assert builder_enter_removed != builder_text, (
    "fixture: no-Enter-during-tool clause not found to remove"
)

builder_rcscreen_negated = builder_text.replace(
    "재전송 전에 화면을 확인한다", "확인하지 않고 바로 재전송한다", 1
)
assert builder_rcscreen_negated != builder_text, (
    "fixture: screen-check clause not found to negate"
)

builder_harness_inverted = builder_text.replace(
    "제출 증명은 claude·codex 에서만", "제출 증명은 devin·grok·kimi 에서만", 1
)
assert builder_harness_inverted != builder_text, (
    "fixture: harness-split direction not found to invert"
)

spawn_tool_reverted = spawn_text.replace(
    "후속 라운드·보충 지시의 주입은\n  `panewire prompt --uptake status-transition` "
    "으로 한다",
    "후속 라운드·보충 지시의 주입은\n  `herdr agent prompt` 로 한다",
    1,
)
assert spawn_tool_reverted != spawn_text, (
    "fixture: spawn-worker panewire designation not found to revert"
)

spawn_stale_readded = spawn_text.replace(
    "비-claude pane 은 §3-1 의 직접주입 경로)",
    "비-claude pane 은 §3-1 의 직접주입 경로). 후속 지시에도 비-claude pane "
    "에는 `herdr agent prompt`를 쓴다",
    1,
)
assert spawn_stale_readded != spawn_text, (
    "fixture: spawn-worker stale-designation insertion point not found"
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

relay_carveout_inverted = relay_text.replace(
    "`herdr agent prompt` 가 아니라 `panewire prompt --uptake status-transition` 이다",
    "`panewire prompt --uptake status-transition` 가 아니라 `herdr agent prompt` 이다",
    1,
)
assert relay_carveout_inverted != relay_text, (
    "fixture: relay-handoff carve-out direction not found to invert"
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
        "builder-send-ban-weakened",
        lambda: check_builder(builder_sendban_removed),
    ),
    (
        "builder-send-permitted",
        lambda: check_builder(builder_send_permitted),
    ),
    (
        "builder-no-enter-clause-removed",
        lambda: check_builder(builder_enter_removed),
    ),
    (
        "builder-rc-screen-negated",
        lambda: check_builder(builder_rcscreen_negated),
    ),
    (
        "builder-harness-split-inverted",
        lambda: check_builder(builder_harness_inverted),
    ),
    (
        "spawn-worker-tool-reverted",
        lambda: check_spawn_worker(spawn_tool_reverted),
    ),
    (
        "spawn-worker-stale-designation-readded",
        lambda: check_spawn_worker(spawn_stale_readded),
    ),
    (
        "relay-handoff-carveout-removed",
        lambda: check_relay_handoff(relay_carveout_removed),
    ),
    (
        "relay-handoff-carveout-inverted",
        lambda: check_relay_handoff(relay_carveout_inverted),
    ),
]
for label, callback in assertion_red_mutants:
    expect_assertion(label, callback)
print(
    "PASS mutants assertion-red="
    f"{len(assertion_red_mutants)}/{len(assertion_red_mutants)}"
)
PY
