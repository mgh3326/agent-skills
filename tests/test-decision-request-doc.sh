#!/usr/bin/env bash
# #618 AC5: director/SKILL.md must keep the decision-request contract
# (hk:doc task/2026-09-24/console-req-1 수정 AC A2·A3·A6·A7):
#
#   1. the CLI line `handoffkeep tasks decision-request` with the separate
#      recommendation / no-response / deadline flags;
#   2. record first, then notify with the returned request_id, and never
#      claim console visibility when the record failed (A6);
#   3. recommendation and default action are separate (A2);
#   4. a passed deadline is not an application; applied needs a receipt (A3);
#   5. the label limit is 120 bytes, not 120 characters (A7);
#   6. mutants (each rule removed) go RED through an assertion.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import os
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
director_path = Path(os.environ.get("DIRECTOR_SKILL", root / "director/SKILL.md"))
director_text = director_path.read_text(encoding="utf-8")

HEADING = "## 운영자 결정 요청"


def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def section(text: str, heading: str) -> str:
    assert heading in text, f"missing heading: {heading}"
    body = text.split(heading, 1)[1]
    m = re.search(r"(?m)^#{1,2} ", body)
    return body[: m.start()] if m else body


def check(text: str) -> None:
    sec = flat(section(text, HEADING))
    assert "handoffkeep tasks decision-request" in sec, "decision-request CLI line missing"
    for flag in ("--question", "--option", "--recommended", "--default-action", "--due"):
        assert flag in sec, f"CLI line must carry {flag}"
    assert re.search(r"기록 먼저.{0,40}request_id", sec), "record-first-then-notify-with-request_id rule missing (A6)"
    assert re.search(r"NOT recorded.{0,80}통지하지 않는다", sec), "no console-visibility claim on a failed record (A6)"
    assert re.search(r"권고와 무응답 동작은 별개", sec), "recommendation/default separation missing (A2)"
    assert re.search(r"기한 경과는 적용이 아니다", sec) and "--receipt" in sec, "deadline != applied / receipt rule missing (A3)"
    assert re.search(r"120바이트.{0,40}120자가 아니다", sec), "120-byte (not character) label limit missing (A7)"
    assert "--supersedes" in sec and "decision-resolve" in sec, "supersede and resolve lines missing"


def expect_assertion(label, callback):
    try:
        callback()
    except AssertionError:
        return
    except Exception as exc:  # noqa: BLE001 - a crash is not a RED assertion
        raise AssertionError(f"{label} mutant errored instead of assertion RED: {exc}")
    raise AssertionError(f"{label} mutant did not go RED")


check(director_text)
print("PASS director decision-request contract")

mutants = [
    ("cli-line-removed", director_text.replace("handoffkeep tasks decision-request", "handoffkeep tasks transition")),
    ("record-first-removed", director_text.replace("기록 먼저, 알림에 request_id", "알림")),
    ("failed-record-claim", director_text.replace("통지하지 않는다", "통지한다")),
    ("default-merged-into-recommendation", director_text.replace("권고와 무응답 동작은 별개다", "권고가 곧 기본값이다")),
    ("deadline-means-applied", director_text.replace("기한 경과는 적용이 아니다", "기한이 지나면 적용된 것으로 본다")),
    ("label-120-chars", director_text.replace("120바이트**(한글 120자가 아니다", "120자**(")),
    ("section-removed", director_text.replace(HEADING, "## 기타")),
]
for label, text in mutants:
    assert text != director_text, f"{label} mutant did not change the text"
    expect_assertion(label, lambda t=text: check(t))
print(f"PASS mutants assertion-red={len(mutants)}/{len(mutants)}")
PY
