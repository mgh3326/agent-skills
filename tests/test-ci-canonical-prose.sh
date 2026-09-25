#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
files = {
    "spawn-worker": root / "spawn-worker/SKILL.md",
    "builder": root / "builder/SKILL.md",
    "checker": root / "checker/SKILL.md",
    "director": root / "director/SKILL.md",
}
texts = {name: path.read_text(encoding="utf-8") for name, path in files.items()}


def contract(text: str) -> str:
    start = "<!-- ci-canonical-full-suite:start -->"
    end = "<!-- ci-canonical-full-suite:end -->"
    assert text.count(start) == 1 and text.count(end) == 1, "canonical contract markers missing or duplicated"
    body = text.split(start, 1)[1].split(end, 1)[0]
    assert body.strip(), "canonical contract is empty"
    return body


def check_contracts(subjects: dict[str, str]) -> None:
    for name, text in subjects.items():
        body = contract(text)
        normalized = re.sub(r"\s+", " ", body).casefold()
        for required in (
            "director/gate_policy.json",
            "director/merge_precheck.py",
            "director/ci_canonical.py",
            "h/b/m",
            "tester does not rerun a local full suite",
            "tester는 근거를 기록해 affected surface를 넓힐 수 있다.",
            "surviving mutant",
            "unproven",
            "ci or collection configuration",
            "separately judged",
            "t3",
            "관련 safety-guard 파일 전체, independent counterexample, mutant red then restored green, 그리고 environment-difference checks를 최소한 유지한다.",
            "outside ci surface는 ci에 등록되어 실제 실행됨이 확인될 때까지 local run이 필요하다.",
            "red rerun이면 verification is not met다.",
        ):
            assert required in normalized, f"{name}: missing canonical rule {required!r}"
        all_normalized = re.sub(r"\s+", " ", text).casefold()
        assert "required ci jobs:" not in all_normalized, f"{name}: prose copied a required-job list"
        assert "ubuntu-latest" not in all_normalized and "macos-latest" not in all_normalized, (
            f"{name}: prose copied required CI job names instead of policy authority"
        )
        assert not re.search(
            r"(?is)required\s+ci\s+jobs?.{0,600}(?:handoffkeep|panewire|scopefuel|auto_trader).{0,900}(?:test|build|image)",
            text,
        ), f"{name}: prose copied repository CI jobs instead of policy authority"
        assert not re.search(
            r"\btester\b.{0,120}\b(?:must|shall|required(?:\s+to)?)\b.{0,120}\b(?:local\s+)?full[- ]suite\b"
            r"|\btester\b.{0,120}\b(?:local\s+)?full[- ]suite\b.{0,120}\b(?:must|shall|required)\b",
            all_normalized,
        ), f"{name}: tester local full-suite rerun was reintroduced"
        assert not re.search(
            r"(?:tester|테스터).{0,120}(?:local\s*)?(?:full[- ]suite|전체\s*스위트).{0,120}"
            r"(?:다시\s*돌려야|돌려야|필수|반드시|must|shall|required)",
            all_normalized,
        ), f"{name}: tester local full-suite rerun was reintroduced"


def expect_assertion(label: str, callback) -> None:
    try:
        callback()
    except AssertionError:
        print(f"PASS assertion-RED {label}")
        return
    raise AssertionError(f"mutant survived: {label}")


check_contracts(texts)
print("PASS ci-canonical prose contracts=4/4 policy-list-copies=0 tester-full-suite-mandates=0")


def mutate_builder(old: str, new: str) -> dict[str, str]:
    mutant = dict(texts)
    assert old in mutant["builder"], f"test setup missing {old!r}"
    mutant["builder"] = mutant["builder"].replace(old, new, 1)
    return mutant


for label, old, new in (
    ("tester-full-suite-rerun", "tester does not rerun a local full suite", "tester must rerun a local full suite"),
    ("tester-korean-full-suite-rerun", "red rerun이면 verification is not met다.",
     "red rerun이면 verification is not met다. tester는 local 전체 스위트를 다시 돌려야 한다."),
    ("tester-may-widen-surface", "Tester는 근거를 기록해 affected surface를 넓힐 수 있다.", ""),
    ("surviving-mutant-unproven", "surviving mutant는 unproven이며,", "surviving mutant는 참고다,"),
    ("t3-whole-safety-guard", "관련 safety-guard 파일 전체", "관련 safety-guard 파일 일부"),
    ("t3-environment-difference", "environment-difference checks를 최소한 유지한다.", "environment-difference checks는 필요하면 유지한다."),
    ("outside-ci-local-run", "outside CI surface는 CI에 등록되어 실제 실행됨이 확인될 때까지 local run이 필요하다.",
     "outside CI surface의 local run은 선택이다."),
    ("red-rerun-not-met", "red rerun이면 verification is not met다.", "red rerun이면 verification is met다."),
):
    expect_assertion(label, lambda old=old, new=new: check_contracts(mutate_builder(old, new)))

list_mutant = dict(texts)
list_mutant["checker"] += "\nRequired CI jobs: handoffkeep test, panewire test, scopefuel test.\n"
expect_assertion("required-job-list-copy", lambda: check_contracts(list_mutant))

runner_list_mutant = dict(texts)
runner_list_mutant["director"] += "\n(ubuntu-latest, macos-latest)\n"
expect_assertion("required-runner-list-copy", lambda: check_contracts(runner_list_mutant))
PY
