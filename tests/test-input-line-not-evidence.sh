#!/usr/bin/env bash
# #646: builder's follow-up injection section says what decides a suspected
# unsubmitted prompt — the delivery row and the receiver's transcript, not
# text on the input line — before any resend or Enter. Mutants: the bullet
# removed, its verdict inverted, the resend/Enter ordering dropped, the
# transcript message no longer tied to the delivery, and the zero-return basis
# no longer scoped to herdr's API log must each turn the check RED by
# assertion.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import os
import re
import sys

root = Path(sys.argv[1])
builder_path = Path(os.environ.get("BUILDER_SKILL", root / "builder/SKILL.md"))
text = builder_path.read_text(encoding="utf-8")

HEADING = "## 후속 라운드·보충 지시의 주입"


def section(doc: str) -> str:
    assert HEADING in doc, f"missing heading: {HEADING}"
    body = doc.split(HEADING, 1)[1]
    m = re.search(r"(?m)^## ", body)
    return re.sub(r"\s+", " ", body[: m.start()] if m else body)


def check(doc: str) -> None:
    sec = section(doc)
    assert "입력줄에 보이는 글은 미제출 증거가 아니다" in sec, (
        "input-line-is-not-evidence rule missing"
    )
    assert "입력줄에 보이는 글은 미제출 증거다" not in sec, "rule inverted"
    assert re.search(r"재전송·Enter\s*전에.{0,40}deliveries 행", sec), (
        "delivery row must be checked before resend/Enter"
    )
    assert "panewire deliveries show" in sec, "deliveries read command missing"
    assert "transcript" in sec, "receiver transcript comparison missing"
    assert re.search(r"그 delivery 의 시각·본문과\s*일치하는 user 메시지", sec), (
        "transcript message must be identified by the delivery's time and text"
    )
    assert re.search(r"herdr API 로그에.{0,40}`send_keys`", sec) and re.search(
        r"터미널에 붙은 사람의 키 입력은 그 로그에 남지 않는다", sec
    ), "zero-return basis must be scoped to herdr's API log"


check(text)

BULLET = re.compile(r"(?s)- \*\*입력줄에 보이는 글은 미제출 증거가 아니다\(#646\)\.\*\*.*?(?=\n- \*\*)")
removed = BULLET.sub("", text, count=1)
inverted = text.replace(
    "입력줄에 보이는 글은 미제출 증거가 아니다", "입력줄에 보이는 글은 미제출 증거다", 1
)
unordered = text.replace("재전송·Enter\n  전에 그 호출의", "나중에 그 호출의", 1)
last_message = text.replace("그 delivery 의 시각·본문과\n  일치하는 user 메시지", "마지막 user 메시지", 1)
unscoped = text.replace("(터미널에 붙은 사람의 키 입력은 그 로그에 남지 않는다)", "", 1)
mutants = {
    "bullet-removed": removed,
    "verdict-inverted": inverted,
    "order-dropped": unordered,
    "transcript-last-message": last_message,
    "return-count-unscoped": unscoped,
}
for name, doc in mutants.items():
    assert doc != text, f"fixture: mutant {name} did not change the text"
    try:
        check(doc)
    except AssertionError:
        print(f"RED {name}")
        continue
    raise SystemExit(f"mutant {name} did not go RED")
print(f"PASS input-line-not-evidence ({len(mutants)} mutants RED)")
PY
