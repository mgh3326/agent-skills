#!/usr/bin/env bash
# Deploy record contract (#528): the installer's last step writes one
# append-only deploy record on every path (success, failure, escalation).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import os
import re
import sys

root = Path(sys.argv[1])
installer_text = Path(
    os.environ.get("INSTALLER_SKILL", root / "installer/SKILL.md")
).read_text(encoding="utf-8")
checklist_text = Path(
    os.environ.get("INSTALLER_CHECKLIST", root / "installer/CHECKLIST.md")
).read_text(encoding="utf-8")
director_text = Path(
    os.environ.get("DIRECTOR_SKILL", root / "director/SKILL.md")
).read_text(encoding="utf-8")


def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def section(text: str, heading: str) -> str:
    """Body of a ##/### section up to the next heading of same-or-higher level."""
    assert heading in text, f"missing heading: {heading}"
    body = text.split(heading, 1)[1]
    level = len(heading) - len(heading.lstrip("#"))
    m = re.search(rf"(?m)^#{{1,{level}}} ", body)
    return body[: m.start()] if m else body


R3 = "## R3. 고정 절차 (9단계, 순서 불변)"
R9 = "## R9. escalate 트리거 (8개 전부)"
R11 = "## R11. 보고 형식"
R12 = "## R12. 단계 9 — 배포 기록 (append-only, 실패·escalate 포함)"

# AC1 minimum fields plus the contract's own (schema, failed_step, source).
FIELDS = [
    "schema", "service", "target", "head_sha", "deployed_ref", "previous_ref",
    "deployed_at", "result", "failed_step", "job_id", "approval_ref",
    "included_prs", "source",
]
RESULTS = ["success", "failed", "rolled_back"]
KEY_SHAPE = "`deploy/<service>/<UTC 시각>`"
TIME_FORMAT = "`YYYYMMDDTHHMMSSZ`"
# The key regex the documented shape and format imply.
KEY_RE = re.compile(r"^deploy/[a-z][a-z0-9_-]*/\d{8}T\d{6}Z$")


def check_procedure(text: str) -> None:
    sec = section(text, R3)
    steps = re.findall(r"(?m)^(\d+)\. \*\*(.+?)\*\*", sec)
    assert steps, "R3 steps missing"
    last_n, last_title = steps[-1]
    assert (int(last_n), last_title) == (9, "배포 기록"), (
        f"record step is not the last R3 step: {steps[-1]}"
    )
    assert sum(1 for _, t in steps if t == "배포 기록") == 1, "record step count != 1"
    body = flat(sec)
    # ESC path: the stop-on-escalate rule must carve out step 9 explicitly.
    assert "이후 단계는 실행하지 않는다 — **단 단계 9(배포 기록)는 예외다.**" in body, (
        "R3 stop rule lacks the step-9 exception"
    )
    assert "ESC 보고서를 올린 뒤 단계 9를 반드시 실행한다" in body, (
        "R3 does not run step 9 after an ESC report"
    )
    assert "성공·실패·escalate 중 어느 경로로 끝나든 마지막 단계는 단계 9다" in body, (
        "R3 does not name step 9 as last on every path"
    )
    start = flat(section(text, "## 시작"))
    assert "R3의 9단계를 순서대로 실행한다" in start, "시작 still runs a different step count"
    assert "기록 키가 있으면 단계 9를 실행한다(`failed_step` = `0`)" in start, (
        "pre-start escalation skips the record"
    )


def check_key(text: str) -> None:
    sec = flat(section(text, R12))
    assert f"**키** — {KEY_SHAPE}" in sec, "record key shape missing or without time"
    assert f"시각 형식은 {TIME_FORMAT}(UTC, 콜론 없음) 하나다" in sec, "time format not fixed"
    assert "기록 키는 **스폰 입력으로 받는다** — installer는 키를 만들거나 바꾸지 않는다" in sec, (
        "installer may mint its own key"
    )
    # The documented format actually yields keys matching KEY_RE, and a
    # time-less or colon-formatted key does not.
    assert KEY_RE.match("deploy/auto_trader/20260923T032500Z")
    assert not KEY_RE.match("deploy/auto_trader")
    assert not KEY_RE.match("deploy/auto_trader/2026-09-23T03:25:00Z")


def check_fields(text: str) -> None:
    sec = section(text, R12)
    rows = re.findall(r"(?m)^\| `([a-z_]+)` \|", sec)
    assert rows == FIELDS, f"record fields changed: {rows}"
    body = flat(sec)
    assert "필드 전부 필수 — 모르는 값은 `null`, 추측으로 채우지 않는다" in body, (
        "no-guess rule missing"
    )
    assert "`success` · `failed` · `rolled_back` 중 하나" in body, "result enum changed"
    for word in RESULTS:
        assert f"`{word}`" in body
    assert "표시 원문이 정의되지 않은 서비스는 롤백이 있었어도 `failed`로 적고" in body, (
        "rolled_back may be inferred"
    )
    assert "현재 서빙 중인 판은 `result=success`인 가장 최근 기록의 `deployed_ref`다" in body, (
        "reader rule for deployed_ref missing"
    )
    assert "단계 5가 exit 0으로 끝나지 않았으면 `null`" in body, (
        "deployed_ref may name a ref that was never deployed"
    )
    assert "시도한 커밋은 `head_sha`" in body, "reader rule for head_sha missing"


def check_append_only(text: str) -> None:
    sec = section(text, R12)
    steps = re.findall(r"(?m)^(\d+)\. (\S+)", sec)
    titles = [t for _, t in steps]
    assert titles[:3] == ["부재", "쓰기", "새로"], f"record procedure order changed: {titles}"
    body = flat(sec)
    assert "키가 이미 있으면 **쓰지 않고** 트리거 8" in body, "existing key may be overwritten"
    assert "exit≠0이면 재시도 없이 트리거 8" in body, "write failure may be retried/silent"
    assert "생성 시각 = 갱신 시각" in body and "덮어쓰기가 일어난 것이다 → 트리거 8" in body, (
        "post-write overwrite detection missing"
    )
    assert "기존 `deploy/` 키를 수정·삭제하는 명령은 어떤 경우에도 실행하지 않는다" in body


def check_escalation(text: str) -> None:
    sec = section(text, R9)
    triggers = re.findall(r"(?m)^(\d+)\. ", sec)
    assert [int(n) for n in triggers] == list(range(1, 9)), f"R9 triggers: {triggers}"
    assert re.search(r"(?m)^8\. 배포 기록 실패\(R12\)", sec), "record failure is not an ESC trigger"
    assert "쓰려던 기록 본문을 **원문 그대로** 붙인다" in flat(sec), "failed record body can be lost"
    rep = section(text, R11)
    assert re.search(
        r"(?m)^배포 기록 키: <스폰 입력의 기록 키> \(단계 9에서 result=success 로 기록 — 이 보고 뒤\)$",
        rep,
    ), "JOIN template lacks the record key line"
    assert re.search(
        r"(?m)^배포 기록 키: <스폰 입력의 기록 키> \(단계 9에서 result=<failed\|rolled_back>, "
        r"failed_step=<n> 로 기록 — 이 보고 뒤\)$",
        rep,
    ), "ESC template lacks the record key line"


def check_installer(text: str) -> None:
    check_procedure(text)
    check_key(text)
    check_fields(text)
    check_append_only(text)
    check_escalation(text)


def check_checklist(text: str) -> None:
    sec = section(text, "## 단계 9 — 배포 기록 (R12, 성공·실패·ESC 모두 — ESC로 멈췄어도 ESC 보고 뒤 반드시 실행)")
    items = re.findall(r"(?m)^- \[ \] (9[a-e])\. ", sec)
    assert items == ["9a", "9b", "9c", "9d", "9e"], f"checklist step 9 items: {items}"
    assert "0d. 배포 기록 키 확보(R12, 스폰 입력)" in text, "checklist lacks record-key input"
    assert "9a. 본문 필드 13개 전부(모르는 값 `null`, 추측 0)" in sec, "checklist field count drifted"


def check_director(text: str) -> None:
    deploy = flat(section(text, "## 배포"))
    assert "생긴 것을 확인하기 전에는 installer 세션을 회수하지 않는다" in deploy, (
        "director may reap installer before the record exists"
    )
    assert "기존 `deploy/` 키는 덮어쓰지 않는다" in deploy
    assert "기록 키는 installer 스폰 입력으로 director가 정한다(시각 = 스폰 시각, UTC `YYYYMMDDTHHMMSSZ`)" in deploy


check_installer(installer_text)
print(f"PASS installer deploy-record step=9/last fields={len(FIELDS)} triggers=8")
check_checklist(checklist_text)
print("PASS checklist step 9 items=5")
check_director(director_text)
print("PASS director reap-after-record")


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


def mutate(text: str, old: str, new: str) -> str:
    assert text.count(old) == 1, f"fixture: mutation anchor not unique: {old}"
    return text.replace(old, new, 1)


step9 = "9. **배포 기록** — R12의 배포 기록 1건을 새 키로 남긴다. 절차의 마지막 단계다.\n"
exception = " — **단 단계 9(배포 기록)는 예외다.** escalate로 멈춘 경우에도\nR11의 ESC 보고서를 올린 뒤 단계 9를 반드시 실행한다(result는 R12 규칙대로 `failed` 또는\n`rolled_back`)."
installer_mutants = [
    # AC7: record step removed from the procedure.
    ("step9-removed", mutate(installer_text, step9, "")),
    # Record step moved before the report (no longer last).
    ("step9-not-last", mutate(
        mutate(installer_text, step9, ""),
        "8. **JOIN 보고**",
        "8. **배포 기록** — R12.\n9. **JOIN 보고**",
    )),
    # AC7: ESC path loses the record step.
    ("esc-path-record-removed", mutate(installer_text, exception, ".")),
    ("esc-run-after-report-removed", mutate(
        installer_text, "R11의 ESC 보고서를 올린 뒤 단계 9를 반드시 실행한다", "R11의 ESC 보고서를 올린다",
    )),
    ("pre-start-esc-skips-record", mutate(
        installer_text, " — 이때도 기록 키가 있으면 단계 9를 실행한다(`failed_step` = `0`).", ".",
    )),
    # AC7: time removed from the key.
    ("key-without-time", mutate(installer_text, "**키** — `deploy/<service>/<UTC 시각>`", "**키** — `deploy/<service>`")),
    ("time-format-loosened", mutate(installer_text, "시각 형식은 `YYYYMMDDTHHMMSSZ`(UTC, 콜론 없음) 하나다", "시각 형식은 자유다")),
    ("installer-mints-key", mutate(
        installer_text, "기록 키는 **스폰 입력으로 받는다** — installer는 키를 만들거나 바꾸지 않는다",
        "기록 키는 installer가 현재 시각으로 만든다",
    )),
    ("field-previous-ref-dropped", re.sub(r"(?m)^\| `previous_ref` \|.*\n", "", installer_text, count=1)),
    ("deployed-ref-is-attempted", mutate(
        installer_text, "단계 5가 exit 0으로 끝나지 않았으면 `null`", "단계 1에서 고정한 대상 ref",
    )),
    ("rolled-back-inferred", mutate(
        installer_text, "표시 원문이 정의되지 않은\n서비스는 롤백이 있었어도 `failed`로 적고",
        "롤백 흔적이 보이면\n`rolled_back`으로 적고",
    )),
    ("absence-check-removed", re.sub(r"(?m)^1\. 부재 확인 — .*\n(?:   .*\n)*", "", installer_text, count=1)),
    ("overwrite-allowed", mutate(installer_text, "키가 이미 있으면 **쓰지 않고** 트리거 8.", "키가 이미 있으면 덮어쓴다.")),
    ("write-retried", mutate(installer_text, "exit≠0이면 재시도 없이 트리거 8.", "exit≠0이면 1회 재시도한다.")),
    ("overwrite-detection-removed", re.sub(r"(?m)^3\. 새로 만들어졌는지 확인 — .*\n(?:   .*\n)*", "", installer_text, count=1)),
    ("trigger8-removed", re.sub(r"(?m)^8\. 배포 기록 실패\(R12\).*\n(?:   .*\n)*", "", installer_text, count=1)),
    ("esc-body-dropped", mutate(installer_text, "쓰려던 기록 본문을 **원문 그대로** 붙인다", "기록 키만 적는다")),
    ("esc-template-key-dropped", re.sub(
        r"(?m)^배포 기록 키: <스폰 입력의 기록 키> \(단계 9에서 result=<failed.*\n", "", installer_text, count=1,
    )),
]
checklist_mutants = [
    ("checklist-step9-removed", mutate(
        checklist_text,
        "## 단계 9 — 배포 기록 (R12, 성공·실패·ESC 모두 — ESC로 멈췄어도 ESC 보고 뒤 반드시 실행)",
        "## 참고",
    )),
    ("checklist-absence-item-removed", re.sub(r"(?m)^- \[ \] 9b\. .*\n", "", checklist_text, count=1)),
]
director_mutants = [
    ("director-reaps-before-record", mutate(
        director_text, "생긴 것을 확인하기 전에는 installer 세션을 회수하지 않는다", "기다리지 않고 installer 세션을 회수한다",
    )),
]

for label, text in installer_mutants:
    assert text != installer_text, f"fixture: {label} did not change the text"
    expect_assertion(label, lambda text=text: check_installer(text))
for label, text in checklist_mutants:
    assert text != checklist_text, f"fixture: {label} did not change the text"
    expect_assertion(label, lambda text=text: check_checklist(text))
for label, text in director_mutants:
    expect_assertion(label, lambda text=text: check_director(text))
total = len(installer_mutants) + len(checklist_mutants) + len(director_mutants)
print(f"PASS mutants assertion-red={total}/{total}")
PY
