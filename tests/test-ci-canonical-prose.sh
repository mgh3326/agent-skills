#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$root" <<'PY'
import hashlib
import json
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
policy = json.loads((root / "director/gate_policy.json").read_text(encoding="utf-8"))
RULE_IDS = [f"CI-CANONICAL-{number}" for number in range(1, 8)]
STRUCTURAL_BLOCK_SHA256 = "59bdbd9fd2736bb37a6304ad32ce38ff54ba089919922976a2cb165f5ec0c6ff"


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
        actual_ids = re.findall(r"(?m)^- \[(CI-CANONICAL-[1-7])\]", body)
        assert actual_ids == RULE_IDS, f"{name}: canonical structural rule IDs changed"
        assert hashlib.sha256(body.encode("utf-8")).hexdigest() == STRUCTURAL_BLOCK_SHA256, (
            f"{name}: canonical structural rule block changed"
        )
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
            "t3는 local에서 관련 safety-guard 파일 전체, independent counterexample, mutant red then restored green, 그리고 environment-difference checks를 최소한 유지한다.",
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
        for repo, workflows in policy["ci"].items():
            distinctive = [job.casefold() for jobs in workflows.values() for job in jobs
                           if job.casefold() not in {"test", "image", "lint"}]
            mentioned = [job for job in distinctive if job in all_normalized]
            assert len(mentioned) < 2, f"{name}: prose copied required CI jobs for {repo} instead of policy authority"
        positive_text = all_normalized.replace("tester does not rerun a local full suite", "")
        assert not re.search(
            r"(?:\b(?:a\s+)?tester(?![a-z])|테스터).{0,80}\b(?:must|shall|needs?\s+to|required(?:\s+to)?)\b.{0,40}\b(?:rerun|run)\b.{0,100}(?:\b(?:local\s+)?(?:full[- ]suite|full test suite)\b|(?:(?:local|로컬)\s*)?(?:전체\s*(?:스위트|테스트)|풀\s*스위트))"
            r"|(?:\b(?:a\s+)?tester(?![a-z])|테스터).{0,100}(?:(?:반드시|필수).{0,60})?(?:\b(?:local\s+)?(?:full[- ]suite|full test suite)\b|(?:(?:local|로컬)\s*)?(?:전체\s*(?:스위트|테스트)|풀\s*스위트)).{0,100}(?:\brerun\b|\brun\b|재실행|다시\s*돌려야|돌려야)",
            positive_text,
        ), f"{name}: tester local full-suite rerun was reintroduced"
        for forbidden, label in (
            (r"outside ci surface.{0,160}local run.{0,80}(?:선택|optional)", "outside-CI local run weakened"),
            (r"red rerun.{0,160}verification is met", "red rerun was treated as met"),
            (r"surviving mutant.{0,160}(?:참고|passes|통과를 막지)", "surviving mutant was excused"),
            (r"(?:ci(?: or collection)? configuration|ci 설정).{0,160}shortcut.{0,80}(?:쓴다|use|사용)", "CI configuration shortcut restored"),
        ):
            assert not re.search(forbidden, all_normalized), f"{name}: {label}"


def expect_assertion(label: str, callback) -> None:
    try:
        callback()
    except AssertionError:
        print(f"PASS assertion-RED {label}")
        return
    raise AssertionError(f"mutant survived: {label}")


check_contracts(texts)
print("PASS ci-canonical structural-contracts=4/4 rule-ids=7 policy-list-smoke=0 tester-full-suite-smoke=0")


def mutate_builder(old: str, new: str) -> dict[str, str]:
    mutant = dict(texts)
    assert old in mutant["builder"], f"test setup missing {old!r}"
    mutant["builder"] = mutant["builder"].replace(old, new, 1)
    return mutant


def append_builder(text: str) -> dict[str, str]:
    mutant = dict(texts)
    mutant["builder"] += "\n" + text + "\n"
    return mutant


for label, old, new in (
    ("tester-full-suite-rerun", "tester does not rerun a local full suite", "tester must rerun a local full suite"),
    ("tester-korean-full-suite-rerun", "red rerun이면 verification is not met다.",
     "red rerun이면 verification is not met다. tester는 local 전체 스위트를 다시 돌려야 한다."),
    ("tester-may-widen-surface", "Tester는 근거를 기록해 affected surface를 넓힐 수 있다.", ""),
    ("surviving-mutant-unproven", "surviving mutant는 unproven이며,", "surviving mutant는 참고다,"),
    ("t3-whole-safety-guard", "관련 safety-guard 파일 전체", "관련 safety-guard 파일 일부"),
    ("t3-local-minimum", "T3는 local에서", "T3는 필요하면 local에서"),
    ("t3-environment-difference", "environment-difference checks를 최소한 유지한다.", "environment-difference checks는 필요하면 유지한다."),
    ("outside-ci-local-run", "outside CI surface는 CI에 등록되어 실제 실행됨이 확인될 때까지 local run이 필요하다.",
     "outside CI surface의 local run은 선택이다."),
    ("red-rerun-not-met", "red rerun이면 verification is not met다.", "red rerun이면 verification is met다."),
):
    expect_assertion(label, lambda old=old, new=new: check_contracts(mutate_builder(old, new)))

for label, text in (
    ("tester-korean-local-whole-suite", "tester는 반드시 로컬 전체 스위트를 재실행한다."),
    ("tester-korean-whole-test", "tester는 로컬에서 전체 테스트를 다시 돌려야 한다."),
    ("tester-korean-spaced-full-suite", "tester 는 local full suite 를 재실행한다."),
    ("tester-korean-pool-suite", "테스터는 풀 스위트를 로컬에서 다시 돌려야 한다."),
    ("tester-english-needs-suite", "A tester needs to rerun the local full suite."),
    ("tester-english-full-test-suite", "The tester must rerun the full test suite locally."),
    ("required-auto-trader-list", "auto_trader 필수 CI: lint, taskiq-smoke, test (3.13, 1), test (3.13, 2), test (3.13, 3), test (3.13, 4)."),
    ("required-handoffkeep-list", "handoffkeep 필수 job: test, vitest, build (darwin, arm64), build (linux, amd64), build (linux, arm64), image."),
    ("outside-ci-override", "단 outside CI surface의 local run은 선택이다."),
    ("red-rerun-override", "다만 red rerun 뒤 green rerun이면 verification is met다."),
    ("surviving-mutant-override", "단 surviving mutant는 참고용이며 통과를 막지 않는다."),
    ("configuration-shortcut-override", "CI or collection configuration PR도 CI가 green이면 shortcut을 쓴다."),
    ("configuration-korean-p10", "CI 설정 변경 PR도 CI가 green이면 shortcut을 쓴다."),
):
    expect_assertion(label, lambda text=text: check_contracts(append_builder(text)))

list_mutant = dict(texts)
list_mutant["checker"] += "\nRequired CI jobs: handoffkeep test, panewire test, scopefuel test.\n"
expect_assertion("required-job-list-copy", lambda: check_contracts(list_mutant))

runner_list_mutant = dict(texts)
runner_list_mutant["director"] += "\n(ubuntu-latest, macos-latest)\n"
expect_assertion("required-runner-list-copy", lambda: check_contracts(runner_list_mutant))

structural_id_mutant = mutate_builder("CI-CANONICAL-5", "CI-CANONICAL-X")
expect_assertion("structural-rule-id", lambda: check_contracts(structural_id_mutant))
PY
