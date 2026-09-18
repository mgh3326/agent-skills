#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" "$0" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
test_path = Path(sys.argv[2]).resolve()
director_path = Path(
    __import__("os").environ.get("DIRECTOR_SKILL", root / "director/SKILL.md")
)
checker_path = Path(
    __import__("os").environ.get("CHECKER_SKILL", root / "checker/SKILL.md")
)
ci_path = root / ".github/workflows/ci.yml"

START = "<!-- openai-independent-verification:start -->"
END = "<!-- openai-independent-verification:end -->"
EXPECTED_BLOCK = """<!-- openai-independent-verification:start -->
**OpenAI 계열 독립검증 계약**

OpenAI 기여가 있는 PR은 contributor 계열 합집합 밖의 검증된 tester가 최종 head에 PASS하지 않으면 머지하지 않는다. Sol·Astra·Terra·Luna는 모델명이 달라도 서로 독립 검증이 아니다.

기여 계열은 합집합이다 — 최종 커미터만 보지 않고 초안·수리·처방을 낸 모든 계열. 계열 unknown이면 독립성 불통과.

신규 Codex 구현은 독립 tester와 reservation이 발주 전에 확보될 때만 발주한다. 없으면 HOLD(no_independent_reviewer).

09-14 동일계열 지연검증 예외는 Sol director 재임 중 OpenAI contributor PR에는 적용하지 않는다.

checker 파생 판정:

- 위 독립성 조건 중 하나라도 충족하지 않으면 BOUNCE
- 적격 반대계열 tester의 exact-head PASS와 나머지 gate PASS가 모두 있으면 READY

입력·증거:

- contributor family union과 각 기여의 근거(초안/수리/처방 포함)
- tester provider family, exact tested SHA, PASS 증거
- family가 unknown이거나 contributor union 밖임을 증명하지 못하면 fail-closed
- 최종 PR head와 tested SHA가 다르면 BOUNCE
<!-- openai-independent-verification:end -->"""


def extract_block(text: str) -> str:
    assert text.count(START) == 1, "policy start marker must occur exactly once"
    assert text.count(END) == 1, "policy end marker must occur exactly once"
    start = text.index(START)
    end = text.index(END, start) + len(END)
    return text[start:end]


def assert_contracts(director_text: str, checker_text: str) -> tuple[str, str]:
    director_block = extract_block(director_text)
    checker_block = extract_block(checker_text)
    assert director_block == checker_block, "director/checker policy blocks drifted"
    assert director_block == EXPECTED_BLOCK, "policy block differs from canonical text"
    return director_block, checker_block


director_text = director_path.read_text(encoding="utf-8")
checker_text = checker_path.read_text(encoding="utf-8")
director_block, checker_block = assert_contracts(director_text, checker_text)
print("PASS contract-block byte-equality=1 canonical=1")

openai_family_labels = ("OpenAI", "Sol", "Astra", "Terra", "Luna", "Codex")
aliases = {name: "OpenAI" for name in openai_family_labels}


def normalize(family: str) -> str:
    return aliases.get(family, family)


for model_name in openai_family_labels:
    assert normalize(model_name) == "OpenAI"
print(
    "PASS family-normalization "
    f"cases={len(openai_family_labels)}/{len(openai_family_labels)}"
)


def merge_verdict(
    contributor_families,
    tester_family,
    tested_sha="head",
    pr_head="head",
    tester_pass=True,
    other_gates_pass=True,
    independence_proven=True,
    allow_same_family=False,
):
    union = {normalize(family) for family in contributor_families}
    tester = normalize(tester_family)
    if "unknown" in union or tester == "unknown" or not independence_proven:
        return "BOUNCE"
    if tested_sha != pr_head or not tester_pass or not other_gates_pass:
        return "BOUNCE"
    if "OpenAI" in union and tester in union and not allow_same_family:
        return "BOUNCE"
    return "READY"


def dispatch_verdict(
    new_codex=True,
    independent_tester=True,
    reservation=True,
    require_independent_tester=True,
):
    independent_tester_missing = require_independent_tester and not independent_tester
    if new_codex and (independent_tester_missing or not reservation):
        return "HOLD(no_independent_reviewer)"
    return "DISPATCH"


merge_cases = [
    (merge_verdict({"OpenAI"}, "OpenAI"), "BOUNCE", "same-family"),
    (merge_verdict({"OpenAI"}, "Codex"), "BOUNCE", "codex-same-family"),
    (merge_verdict({"OpenAI"}, "xAI"), "READY", "independent-exact-head"),
    (merge_verdict({"OpenAI", "unknown"}, "xAI"), "BOUNCE", "contributor-unknown"),
    (merge_verdict({"OpenAI"}, "unknown"), "BOUNCE", "tester-unknown"),
    (merge_verdict({"OpenAI"}, "xAI", tested_sha="old"), "BOUNCE", "head-mismatch"),
    (merge_verdict({"OpenAI"}, "xAI", other_gates_pass=False), "BOUNCE", "other-gate-fail"),
    (merge_verdict({"OpenAI"}, "xAI", independence_proven=False), "BOUNCE", "unproven"),
]
for actual, expected, label in merge_cases:
    assert actual == expected, f"{label}: expected {expected}, got {actual}"
print(f"PASS merge-outcomes cases={len(merge_cases)}/{len(merge_cases)}")

dispatch_cases = [
    (
        dispatch_verdict(independent_tester=False, reservation=False),
        "HOLD(no_independent_reviewer)",
        "no-independent-tester-or-reservation",
    ),
    (
        dispatch_verdict(independent_tester=False, reservation=True),
        "HOLD(no_independent_reviewer)",
        "no-independent-tester",
    ),
    (
        dispatch_verdict(independent_tester=True, reservation=False),
        "HOLD(no_independent_reviewer)",
        "no-reservation",
    ),
    (
        dispatch_verdict(independent_tester=True, reservation=True),
        "DISPATCH",
        "tester-and-reservation",
    ),
]
for actual, expected, label in dispatch_cases:
    assert actual == expected, f"{label}: expected {expected}, got {actual}"
print(f"PASS dispatch-outcomes cases={len(dispatch_cases)}/{len(dispatch_cases)}")

director_merge_section = director_text.split("## 머지 게이트(전부 충족해야 머지)", 1)[1].split(
    "## 배포", 1
)[0]
director_gates = re.findall(r"(?m)^([1-6])\. ", director_merge_section)
checker_gates = re.findall(r"(?m)^\| G([1-8]) \|", checker_text)
assert director_gates == list("123456"), director_gates
assert checker_gates == list("12345678"), checker_gates
print("PASS legacy-gates director=6/6 checker=8/8")

secret_prefixes = ("gh" + "p_", "github" + "_pat_")
patterns = {
    "pane-id": re.compile(r"\b(?:w\d+|[a-z][a-z0-9_-]*):p\d+\b", re.I),
    "machine-alias": re.compile(
        r"\b(?:machine|host|hostname)\s*[:=]\s*(?!<)[a-z0-9][a-z0-9._-]*", re.I
    ),
    "internal-host": re.compile(r"\b[a-z0-9-]+\.(?:internal|lan|local)\b", re.I),
    "home-path": re.compile(r"/(?:Users|home)/[a-z0-9._-]+(?:/|$)", re.I),
    "tailnet-ip": re.compile(
        r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])(?:\.\d{1,3}){2}\b"
    ),
    "secret-value": re.compile(
        rf"(?:{re.escape(secret_prefixes[0])}|{re.escape(secret_prefixes[1])}|"
        r"sk-[a-z0-9]|AKIA[0-9A-Z]|-----BEGIN [A-Z ]+ PRIVATE KEY-----|"
        r"(?:token|secret|password)\s*[:=]\s*['\"]?[a-z0-9+/=_-]{8,})",
        re.I,
    ),
}

ci_lines = "\n".join(
    line for line in ci_path.read_text(encoding="utf-8").splitlines()
    if "test-openai-independent-gate.sh" in line
)
public_surface = "\n".join(
    (director_block, checker_block, test_path.read_text(encoding="utf-8"), ci_lines)
)
findings = [name for name, pattern in patterns.items() if pattern.search(public_surface)]
assert not findings, f"PUBLIC hygiene findings: {findings}"

positive_controls = {
    "pane-id": "".join(("w", "99", ":p", "88")),
    "machine-alias": "".join(("machine", "=", "buildbox")),
    "internal-host": "".join(("service", ".", "internal")),
    "home-path": "".join(("/", "Users", "/", "sample-user", "/private")),
    "tailnet-ip": "".join(("100", ".", "64", ".", "0", ".", "1")),
    "secret-value": "".join(("token", "=", "syntheticvalue123")),
}
for name, sample in positive_controls.items():
    assert patterns[name].search(sample), f"scanner missed positive control: {name}"
print(
    "PASS public-hygiene findings=0 "
    f"positive-controls={len(positive_controls)}/{len(positive_controls)}"
)


def expect_assertion(label, callback):
    try:
        callback()
    except AssertionError:
        return
    except Exception as exc:
        raise AssertionError(f"{label} mutant errored instead of assertion RED: {exc}") from exc
    raise AssertionError(f"{label} mutant did not go RED")


drifted_director = director_text.replace(
    "초안·수리·처방을 낸 모든 계열", "초안·수리를 낸 모든 계열", 1
)
def assert_same_family_bounces(allow_same_family=False):
    assert merge_verdict(
        {"OpenAI"}, "OpenAI", allow_same_family=allow_same_family
    ) == "BOUNCE"


def assert_dispatch_requires_independent_tester(require_independent_tester=True):
    assert dispatch_verdict(
        independent_tester=False,
        reservation=True,
        require_independent_tester=require_independent_tester,
    ) == "HOLD(no_independent_reviewer)"


assertion_red_mutants = [
    ("contract-drift", lambda: assert_contracts(drifted_director, checker_text)),
    ("same-family-outcome", lambda: assert_same_family_bounces(True)),
    (
        "dispatch-independent-tester",
        lambda: assert_dispatch_requires_independent_tester(False),
    ),
]
for label, callback in assertion_red_mutants:
    expect_assertion(label, callback)
print(
    "PASS mutants assertion-red="
    f"{len(assertion_red_mutants)}/{len(assertion_red_mutants)}"
)
PY
