#!/usr/bin/env bash
# Deploy route contract (#115, hk 2290): the installer seat in
# ops/references/deploy.md takes orders from and reports to exactly one lane,
# operator-desk, and the ops routing table says the same. The retired gate and
# orchestrator seats must not come back as a route anywhere in the deploy files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import os
import re
import sys

root = Path(sys.argv[1])
installer_path = Path(
    os.environ.get("INSTALLER_SKILL", root / "ops/references/deploy.md")
)
checklist_path = Path(
    os.environ.get("INSTALLER_CHECKLIST", root / "ops/references/deploy-checklist.md")
)
ops_path = Path(os.environ.get("OPS_SKILL", root / "ops/SKILL.md"))

installer_text = installer_path.read_text(encoding="utf-8")
checklist_text = checklist_path.read_text(encoding="utf-8")
ops_text = ops_path.read_text(encoding="utf-8")

RECIPIENT = "operator-desk"


def section(text: str, heading: str) -> str:
    """Body of a ##/### section up to the next heading of same-or-higher level."""
    assert heading in text, f"missing heading: {heading}"
    body = text.split(heading, 1)[1]
    level = len(heading) - len(heading.lstrip("#"))
    m = re.search(rf"(?m)^#{{1,{level}}} ", body)
    return body[: m.start()] if m else body


# Every place the installer names where it takes orders from or reports to.
# Each anchor captures the recipient token; the token must EQUAL RECIPIENT.
INSTALLER_SLOTS = (
    ("R1-parent", "## R1. 정체", r"parent는 \*\*([^*\s]+)\*\*다\."),
    ("R1-orders", "## R1. 정체", r"지시는 (\S+?)에게서 받고"),
    ("R1-results", "## R1. 정체", r"결과\(JOIN/ESC\)도 (\S+?)에게 올린다"),
    ("R3-step8", "## R3. 고정 절차 (9단계, 순서 불변)",
     r"(?m)^8\. \*\*JOIN 보고\*\* — (\S+?) 레인에 R11의 JOIN 템플릿으로 보고한다\.$"),
    ("R10-route", "## R10. 사이트 정본 분리", r"디제스트/체크포인트 디렉터리, (\S+?)로의 보고 경로\."),
    ("R11-join-line8", "## R11. 보고 형식", r"(?m)^8\. JOIN 보고 — 증거: <(\S+?)로 전달한 경로/시각>$"),
    ("orderer-heading", None, r"(?m)^## 발주자 측 — (\S+)$"),
)
CHECKLIST_SLOTS = (
    ("checklist-step8", None, r"(?m)^- \[ \] 8\. JOIN 보고 — 증거: `<(\S+?)로 전달한 경로/시각,"),
)
OPS_SLOTS = (
    ("ops-deploy-row", None,
     r"(?m)^\| Deploy one change \| \[`deploy\.md`\]\(references/deploy\.md\)[^\n]*?spawned by and reporting only to (\S+?)[,;. ]"),
)

# R3's fixed procedure: count and order are an invariant of the skill itself.
R3_STEPS = [
    "대상 확정",
    "이미지/아티팩트 존재 확인",
    "DB 마이그레이션 판정",
    "additive 일 때만 선적용",
    "배포 명령 실행",
    "사후 검증",
    "체크포인트 기록",
    "JOIN 보고",
    "배포 기록",
]

# The retired seats must not reappear as a route in the deploy files.
FORBIDDEN = re.compile(r"(?i)checker|director|gate[- ]lane")


def check_slots(text: str, slots) -> None:
    for name, heading, pattern in slots:
        scope = section(text, heading) if heading else text
        m = re.search(pattern, scope)
        assert m, f"{name}: route anchor missing"
        assert m.group(1) == RECIPIENT, (
            f"{name}: recipient {m.group(1)!r} != {RECIPIENT!r}"
        )


def check_no_retired_seat(text: str, label: str) -> None:
    for n, line in enumerate(text.splitlines(), 1):
        assert not FORBIDDEN.search(line), f"{label}:{n}: retired seat named: {line.strip()}"


def check_r3(text: str) -> None:
    sec = section(text, "## R3. 고정 절차 (9단계, 순서 불변)")
    steps = re.findall(r"(?m)^(\d+)\. \*\*(.+?)\*\*", sec)
    assert [int(n) for n, _ in steps] == list(range(1, 10)), (
        f"R3 numbering changed: {[n for n, _ in steps]}"
    )
    assert [title for _, title in steps] == R3_STEPS, (
        f"R3 step titles/order changed: {[t for _, t in steps]}"
    )


def check_installer(text: str) -> None:
    check_slots(text, INSTALLER_SLOTS)
    check_no_retired_seat(text, "deploy.md")
    check_r3(text)


def check_checklist(text: str) -> None:
    check_slots(text, CHECKLIST_SLOTS)
    check_no_retired_seat(text, "deploy-checklist.md")


def check_ops(text: str) -> None:
    check_slots(text, OPS_SLOTS)
    rows = [line for line in text.splitlines() if "references/deploy.md" in line]
    assert len(rows) == 1, f"ops deploy row count {len(rows)} != 1"
    assert not FORBIDDEN.search(rows[0]), f"ops deploy row names a retired seat: {rows[0]}"


check_installer(installer_text)
print(
    f"PASS installer route slots={len(INSTALLER_SLOTS)}/{len(INSTALLER_SLOTS)} "
    f"recipient={RECIPIENT} r3-steps={len(R3_STEPS)}/9"
)
check_checklist(checklist_text)
print(f"PASS installer checklist slots={len(CHECKLIST_SLOTS)}/{len(CHECKLIST_SLOTS)}")
check_ops(ops_text)
print(f"PASS ops deploy-row slots={len(OPS_SLOTS)}/{len(OPS_SLOTS)}")


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


step8 = "8. **JOIN 보고** — operator-desk 레인에"
r1_parent = "parent는 **operator-desk**다."
r1_results = "결과(JOIN/ESC)도 operator-desk에게 올린다"
r10 = "operator-desk로의 보고 경로."
r11 = "8. JOIN 보고 — 증거: <operator-desk로 전달한 경로/시각>"
esc_heading = "## R9. escalate 트리거 (8개 전부)\n"

installer_mutants = [
    ("step8->checker", mutate(installer_text, step8, step8.replace("operator-desk", "checker"))),
    ("step8->director", mutate(installer_text, step8, step8.replace("operator-desk", "director"))),
    ("r1-parent->director", mutate(installer_text, r1_parent, "parent는 **director**다.")),
    ("r1-results->gate-lane", mutate(installer_text, r1_results, r1_results.replace("operator-desk", "gate-lane"))),
    ("r10->repo-session", mutate(installer_text, r10, "repo-session로의 보고 경로.")),
    ("r11->checker", mutate(installer_text, r11, r11.replace("operator-desk", "checker"))),
    ("orderer->repo-session", mutate(installer_text, "## 발주자 측 — operator-desk", "## 발주자 측 — repo-session")),
    # New route sentence added elsewhere: slots stay green, the sweep must catch it.
    ("new-esc-route-sentence", mutate(
        installer_text, esc_heading,
        esc_heading + "\nescalate는 Director 레인에 R11의 ESC 템플릿으로 올린다.\n",
    )),
    ("r3-steps-reordered", mutate(
        installer_text,
        "6. **사후 검증** — R6의 6개 항목을 전부 확인한다.\n7. **체크포인트 기록** — 단계별 진행 상태를 기록한다.",
        "6. **체크포인트 기록** — 단계별 진행 상태를 기록한다.\n7. **사후 검증** — R6의 6개 항목을 전부 확인한다.",
    )),
    ("r3-step-dropped", mutate(
        installer_text, "7. **체크포인트 기록** — 단계별 진행 상태를 기록한다.\n", "",
    )),
]
checklist_line = "`<operator-desk로 전달한 경로/시각,"
checklist_mutants = [
    ("checklist->checker", mutate(checklist_text, checklist_line, checklist_line.replace("operator-desk", "checker"))),
]
ops_row = "spawned by and reporting only to operator-desk"
ops_mutants = [
    ("ops-row->director", mutate(ops_text, ops_row, "spawned by and reporting only to director")),
    ("ops-row-checker-appended", mutate(ops_text, ops_row, ops_row + " (JOIN via checker)")),
]

for label, text in installer_mutants:
    expect_assertion(label, lambda text=text: check_installer(text))
for label, text in checklist_mutants:
    expect_assertion(label, lambda text=text: check_checklist(text))
for label, text in ops_mutants:
    expect_assertion(label, lambda text=text: check_ops(text))
total = len(installer_mutants) + len(checklist_mutants) + len(ops_mutants)
print(f"PASS mutants assertion-red={total}/{total}")
PY
