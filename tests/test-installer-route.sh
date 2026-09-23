#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import os
import re
import sys

root = Path(sys.argv[1])
installer_path = Path(
    os.environ.get("INSTALLER_SKILL", root / "installer/SKILL.md")
)
checklist_path = Path(
    os.environ.get("INSTALLER_CHECKLIST", root / "installer/CHECKLIST.md")
)
director_path = Path(os.environ.get("DIRECTOR_SKILL", root / "director/SKILL.md"))
readme_path = Path(os.environ.get("README_FILE", root / "README.md"))

installer_text = installer_path.read_text(encoding="utf-8")
checklist_text = checklist_path.read_text(encoding="utf-8")
director_text = director_path.read_text(encoding="utf-8")
readme_text = readme_path.read_text(encoding="utf-8")

RECIPIENT = "director"


def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def section(text: str, heading: str) -> str:
    """Body of a ##/### section up to the next heading of same-or-higher level."""
    assert heading in text, f"missing heading: {heading}"
    body = text.split(heading, 1)[1]
    level = len(heading) - len(heading.lstrip("#"))
    m = re.search(rf"(?m)^#{{1,{level}}} ", body)
    return body[: m.start()] if m else body


# Every place the installer names where it takes orders from or reports to.
# Each anchor captures the recipient token; the token must EQUAL "director".
INSTALLER_SLOTS = (
    ("description", None, r"(?m)^description: .*?reporting only to the (\w[\w-]*) —"),
    ("R1-parent", "## R1. 정체", r"parent는 \*\*([^*\s]+)\*\*다\."),
    ("R1-orders", "## R1. 정체", r"지시는 (\S+?)에게서 받고"),
    ("R1-results", "## R1. 정체", r"결과\(JOIN/ESC\)도 (\S+?)에게 올린다"),
    ("R3-step8", "## R3. 고정 절차 (8단계, 순서 불변)",
     r"(?m)^8\. \*\*JOIN 보고\*\* — (\S+?) 레인에 R11의 JOIN 템플릿으로 보고한다\.$"),
    ("R10-route", "## R10. 사이트 정본 분리", r"디제스트/체크포인트 디렉터리, (\S+?)로의 보고 경로\."),
    ("R11-join-line8", "## R11. 보고 형식", r"(?m)^8\. JOIN 보고 — 증거: <(\S+?)로 전달한 경로/시각>$"),
)
CHECKLIST_SLOTS = (
    ("checklist-step8", None, r"(?m)^- \[ \] 8\. JOIN 보고 — 증거: `<(\S+?)로 전달한 경로/시각,"),
)

README_SLOTS = (
    ("readme-installer-row", None,
     r"(?m)^\| `installer` \| [^|\n]*? — (\S+?) 직속\(스폰·보고 모두 director\), 고정 8단계 절차·판단 없음 \|$"),
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
]

# The only lines in the installer files allowed to mention the abolished
# checker seat: historical notes, compared by exact equality (not substring).
# Site lane names are deliberately not spelled in this public repo; the
# private site doc carries its own lane-name sweep, and the recipient slots
# above reject any token other than "director".
HISTORY_LINES = {
    "installer": {
        "(이력: 역할 구조 변경 전에는 checker 계열 게이트 레인이 parent였고 지시·보고가 그 레인을 거쳤다. 그 좌석은 폐지됐다.)",
    },
    "checklist": set(),
}
FORBIDDEN = re.compile(r"(?i)checker")


def check_slots(text: str, slots) -> None:
    for name, heading, pattern in slots:
        scope = section(text, heading) if heading else text
        m = re.search(pattern, scope)
        assert m, f"{name}: route anchor missing"
        assert m.group(1) == RECIPIENT, (
            f"{name}: recipient {m.group(1)!r} != {RECIPIENT!r}"
        )


def check_history_only(text: str, allowed: set, label: str) -> None:
    for n, line in enumerate(text.splitlines(), 1):
        if FORBIDDEN.search(line):
            assert line.strip() in allowed, (
                f"{label}:{n}: checker outside the history allowlist: {line.strip()}"
            )


def check_r3(text: str) -> None:
    sec = section(text, "## R3. 고정 절차 (8단계, 순서 불변)")
    steps = re.findall(r"(?m)^(\d+)\. \*\*(.+?)\*\*", sec)
    assert [int(n) for n, _ in steps] == list(range(1, 9)), (
        f"R3 numbering changed: {[n for n, _ in steps]}"
    )
    assert [title for _, title in steps] == R3_STEPS, (
        f"R3 step titles/order changed: {[t for _, t in steps]}"
    )


def check_installer(text: str) -> None:
    check_slots(text, INSTALLER_SLOTS)
    check_history_only(text, HISTORY_LINES["installer"], "installer/SKILL.md")
    check_r3(text)


def check_checklist(text: str) -> None:
    check_slots(text, CHECKLIST_SLOTS)
    check_history_only(text, HISTORY_LINES["checklist"], "installer/CHECKLIST.md")


def check_readme(text: str) -> None:
    check_slots(text, README_SLOTS)
    row = [line for line in text.splitlines() if line.startswith("| `installer` |")]
    assert len(row) == 1, f"README installer row count {len(row)} != 1"
    assert not FORBIDDEN.search(row[0]), f"README installer row mentions checker: {row[0]}"


def check_director(text: str) -> None:
    """director orders and judges deploys; installer executes (#115)."""
    head = flat(text.split("## 시작", 1)[0])
    assert "배포를 **실행하는 유일한 역할**" not in head and not re.search(
        r"머지·배포를 \*\*실행하는 유일한 역할", head
    ), "director intro still names director the deploy executor"
    assert re.search(
        r"배포는 \*\*발주·판정\*\*하는 역할이지 실행자가 아니다 — 배포 실행은 installer다", head
    ), "director intro must say it orders/judges deploys, installer executes"
    bounds = flat(section(text, "## 권한 경계"))
    assert re.search(r"director만: 머지, 배포 발주·판정\(실행은 installer\)", bounds), (
        "권한 경계 must list deploy as order/judge, execution by installer"
    )
    deploy = flat(section(text, "## 배포"))
    assert re.search(r"배포 \*\*실행\*\*은 installer가 한다", deploy), (
        "§배포 must name installer as the executor"
    )
    assert re.search(r"JOIN/ESC를 중간 경유 레인 없이 직접 받아 판정한다", deploy), (
        "§배포 must route installer JOIN/ESC straight to director"
    )


check_installer(installer_text)
print(
    f"PASS installer route slots={len(INSTALLER_SLOTS)}/{len(INSTALLER_SLOTS)} "
    f"recipient={RECIPIENT} history-allowlisted={len(HISTORY_LINES['installer'])} "
    f"r3-steps={len(R3_STEPS)}/8"
)
check_checklist(checklist_text)
print(f"PASS installer checklist slots={len(CHECKLIST_SLOTS)}/{len(CHECKLIST_SLOTS)}")
check_readme(readme_text)
print(f"PASS readme installer-row slots={len(README_SLOTS)}/{len(README_SLOTS)}")
check_director(director_text)
print("PASS director deploy=order+judge executor=installer route=direct")

# The history line really is present in the real file, so the allowlist is
# exercised (not vacuous): the guard passes WITH a checker mention in it.
assert any(
    FORBIDDEN.search(line) for line in installer_text.splitlines()
), "fixture: expected a historical checker mention in installer/SKILL.md"
print("PASS history line present and not flagged")


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


step8 = "8. **JOIN 보고** — director 레인에"
r1_parent = "parent는 **director**다."
r1_results = "결과(JOIN/ESC)도 director에게 올린다"
r10 = "director로의 보고 경로."
r11 = "8. JOIN 보고 — 증거: <director로 전달한 경로/시각>"
desc = "reporting only to the director —"
history = next(iter(HISTORY_LINES["installer"]))
esc_heading = "## R9. escalate 트리거 (7개 전부)\n"

installer_mutants = [
    ("step8->checker", mutate(installer_text, step8, step8.replace("director", "checker"))),
    ("step8->gate-lane", mutate(installer_text, step8, step8.replace("director", "gate-lane"))),
    ("r1-parent->checker", mutate(installer_text, r1_parent, "parent는 **checker**다.")),
    ("r1-results->gate-lane", mutate(installer_text, r1_results, r1_results.replace("director", "gate-lane"))),
    ("r10->checker", mutate(installer_text, r10, "checker로의 보고 경로.")),
    ("r11->checker", mutate(installer_text, r11, r11.replace("director", "checker"))),
    ("description->checker", mutate(installer_text, desc, "reporting only to the checker —")),
    # New route sentence added elsewhere: slots stay green, sweep must catch it.
    ("new-esc-route-sentence", mutate(
        installer_text, esc_heading,
        esc_heading + "\nescalate는 Checker 레인에 R11의 ESC 템플릿으로 올린다.\n",
    )),
    # A history line edited into a route: no longer equal to the allowlisted line.
    ("history-line-turned-route", mutate(
        installer_text, history, history + " 지금도 JOIN은 checker 레인에 올린다.",
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
checklist_line = "`<director로 전달한 경로/시각,"
checklist_mutants = [
    ("checklist->checker", mutate(checklist_text, checklist_line, checklist_line.replace("director", "checker"))),
]
readme_row = "— director 직속(스폰·보고 모두 director),"
readme_mutants = [
    ("readme-row-reverted", mutate(readme_text, readme_row, "— checker 게이트 레인 하위,")),
    ("readme-row-checker-appended", mutate(readme_text, readme_row, "— director 직속(스폰·보고 모두 director, JOIN은 checker 경유),")),
]
director_mutants = [
    ("director-intro-executor-restored", mutate(
        director_text,
        "머지를 **실행하는 유일한 역할**이다. 배포는 **발주·판정**하는 역할이지 실행자가 아니다 — 배포 실행은\ninstaller다(운영자 결정 #115).",
        "머지·배포를 **실행하는 유일한 역할**이다.",
    )),
    ("director-bounds-deploy-bare", mutate(
        director_text, "머지, 배포 발주·판정(실행은 installer),", "머지, 배포,",
    )),
    ("director-deploy-section-line-removed", mutate(
        director_text,
        "- 배포 **실행**은 installer가 한다(운영자 결정 #115). director는 installer를 스폰해 발주하고, 그 JOIN/ESC를\n  중간 경유 레인 없이 직접 받아 판정한다.\n",
        "",
    )),
]

for label, text in installer_mutants:
    expect_assertion(label, lambda text=text: check_installer(text))
for label, text in checklist_mutants:
    expect_assertion(label, lambda text=text: check_checklist(text))
for label, text in readme_mutants:
    expect_assertion(label, lambda text=text: check_readme(text))
for label, text in director_mutants:
    expect_assertion(label, lambda text=text: check_director(text))
total = (
    len(installer_mutants) + len(checklist_mutants)
    + len(readme_mutants) + len(director_mutants)
)
print(f"PASS mutants assertion-red={total}/{total}")
PY
