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
            "surviving mutant",
            "unproven",
            "ci or collection configuration",
            "separately judged",
            "t3",
            "safety-guard",
            "independent counterexample",
            "red then restored green",
            "outside ci",
            "local run",
            "red rerun",
            "verification is not met",
        ):
            assert required in normalized, f"{name}: missing canonical rule {required!r}"
        all_normalized = re.sub(r"\s+", " ", text).casefold()
        assert "required ci jobs:" not in all_normalized, f"{name}: prose copied a required-job list"
        assert not re.search(
            r"(?is)required\s+ci\s+jobs?.{0,600}(?:handoffkeep|panewire|scopefuel|auto_trader).{0,900}(?:test|build|image)",
            text,
        ), f"{name}: prose copied repository CI jobs instead of policy authority"
        for line in text.splitlines():
            lowered = line.casefold()
            has_mandate = re.search(r"\btester\b.{0,240}\b(?:must|shall|required to)\b", lowered)
            has_suite = re.search(r"\bfull[- ]suite\b", lowered)
            has_rerun = re.search(r"\b(?:rerun|run)\b", lowered)
            negated = "does not rerun a local full suite" in lowered
            assert not (has_mandate and has_suite and has_rerun and not negated), (
                f"{name}: tester local full-suite rerun was reintroduced"
            )
            direct_rerun = re.search(r"\btester\b.{0,240}\brerun\b.{0,240}\bfull[- ]suite\b", lowered)
            assert not (direct_rerun and not negated), f"{name}: tester local full-suite rerun was reintroduced"


def expect_assertion(label: str, callback) -> None:
    try:
        callback()
    except AssertionError:
        print(f"PASS assertion-RED {label}")
        return
    raise AssertionError(f"mutant survived: {label}")


check_contracts(texts)
print("PASS ci-canonical prose contracts=4/4 policy-list-copies=0 tester-full-suite-mandates=0")

rerun_mutant = dict(texts)
rerun_mutant["builder"] = rerun_mutant["builder"].replace(
    "tester does not rerun a local full suite", "tester must rerun a local full suite", 1
)
expect_assertion("tester-full-suite-rerun", lambda: check_contracts(rerun_mutant))

list_mutant = dict(texts)
list_mutant["checker"] += "\nRequired CI jobs: handoffkeep test, panewire test, scopefuel test.\n"
expect_assertion("required-job-list-copy", lambda: check_contracts(list_mutant))
PY
