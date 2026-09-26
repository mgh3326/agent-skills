#!/usr/bin/env bash
# #745: T3 split rule contract (operator approval 2026-09-26, source hk:doc
# advice/2026-09-26/t3-split-astra). A T3 task may be split across PRs/workers
# only by invariant impact, never by file type: the core (guard wiring — even a
# one-line call — safety DB constraints, error paths, lock/transaction lifetime,
# the state/DB/exception boundary) stays with the core owner on a strong model;
# only provable peripheral work (pure rendering, verified read-only CLI output,
# fixed API glue) may go to cheaper eligible models. Ambiguous pieces return
# NEEDS_CLASSIFICATION instead of running at a lower T; a peripheral PR that
# touches core is reclassified T3 (#728 PR 2 / #733); the final integration
# keeps a cross-family T3 tester under the normal round cap. builder and
# director carry one-line pointers only — no second copy. gate_policy.json
# local_sources pins must match the edited skill files. Every mutant weakens
# one rule in-memory and must go RED by assertion — repository files are
# never modified.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import hashlib
import json
import os
import re
import sys

root = Path(sys.argv[1])
paths = {
    "spawn": Path(os.environ.get("SPAWN_WORKER_SKILL", root / "spawn-worker/SKILL.md")),
    "builder": Path(os.environ.get("BUILDER_SKILL", root / "builder/SKILL.md")),
    "director": Path(os.environ.get("DIRECTOR_SKILL", root / "director/SKILL.md")),
    "policy": root / "director/gate_policy.json",
}
docs = {name: path.read_text(encoding="utf-8") for name, path in paths.items()}

START = "<!-- T745-T3-SPLIT -->"
END = "<!-- /T745-T3-SPLIT -->"
SKILLS = ("spawn", "builder", "director")


def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def block(text: str, name: str) -> str:
    assert text.count(START) == 1 and text.count(END) == 1, (
        f"{name}: exactly one T745-T3-SPLIT block required "
        f"(start={text.count(START)} end={text.count(END)})"
    )
    return flat(text[text.index(START) : text.index(END)])


# Required rows in the spawn-worker T745 block — the negations live inside the
# patterns so a weakened or dropped clause goes RED instead of matching.
BLOCK_ROWS = [
    # Split axis: invariant impact, not file type.
    ("split-by-invariant", r"불변식 영향으로 나눈다"),
    ("not-by-file-type", r"파일 종류[^\n]{0,30}?나누지 않는다|파일 종류[^\n]{0,30}?아니라 불변식 영향"),
    ("body-axis-negated", r"파일 종류\(UI·CLI·테스트 등\)가 아니라 불변식 영향"),
    # The core owner writes the invariant table FIRST, with the named columns.
    ("table-first", r"핵심 책임자가 불변식 표를 먼저"),
    ("table-columns", r"입력[^\n]{0,15}?전이[^\n]{0,15}?강제 위치[^\n]{0,20}?의존성[^\n]{0,30}?독립 관찰 결과"),
    # Core stays on a strong model with the core owner.
    ("core-strong-owner", r"핵심[^\n]{0,10}?강한 모델[^\n]{0,20}?핵심 책임자"),
    # Guard wiring is core even when the diff is one call line.
    ("core-one-line-call", r"호출 한 줄이어도[^\n]{0,80}?핵심"),
    ("core-safety-db", r"안전 DB 제약"),
    ("core-error-path", r"에러 경로"),
    ("core-lock-tx", r"lock/transaction 수명"),
    ("core-state-boundary", r"상태/DB/예외 경계"),
    # Peripheral work eligible for cheaper models — every eligibility
    # condition is pinned, not just the allowed-file list (tester B-R1-1).
    ("periph-rendering", r"순수 렌더링"),
    ("periph-cli-readonly", r"검증된 읽기 API[^\n]{0,10}?CLI 출력"),
    ("periph-api-glue", r"고정 API 연결"),
    ("periph-fixed-contract", r"입/출력[^\n]{0,5}?실패 계약 고정"),
    ("periph-no-safety-impact", r"안전 결정[^\n]{0,5}?권한[^\n]{0,5}?상태[^\n]{0,5}?증거[^\n]{0,10}?영향 없음"),
    ("periph-conditions", r"허용 파일/심볼[^\n]{0,10}?금지 변경"),
    ("periph-independent", r"독립 인수[^\n]{0,5}?되돌리기 가능"),
    # Ambiguous = NEEDS_CLASSIFICATION, never a lower-T run.
    ("needs-classification", r"애매하면[^\n]{0,20}?낮은 T[^\n]{0,10}?실행하지 않고[^\n]{0,10}?NEEDS_CLASSIFICATION"),
    # Peripheral PR that touches core is reclassified T3; cite #728 PR 2/#733.
    ("reclassify-t3", r"주변 PR[^\n]{0,10}?핵심을 건드리면[^\n]{0,30}?T3[^\n]{0,10}?재분류"),
    ("cite-728-733", r"#728[^\n]{0,20}?#733|#733[^\n]{0,20}?#728"),
    # Final integration: cross-family tester secured before dispatch.
    ("cross-family-tester", r"합집합 밖[^\n]{0,20}?T3 tester[^\n]{0,20}?발주 전에 확보"),
    # Normal round cap applies — no one-round cap on the integration tester.
    ("normal-round-cap", r"라운드 캡[^\n]{0,15}?3라운드[^\n]{0,20}?그대로 적용"),
    ("cap-not-shrunk", r"라운드 상한을 따로 줄이지 않는다"),
    # The weekly-pool single-round limit (§2-2) must not reach the final
    # integration tester — §2-6 carries the exclusion (tester B-R1-2).
    ("weekly-pool-carveout", r"단일[^\n]{0,3}?라운드 한정[^\n]{0,20}?tester 는? 최종 통합 tester 가 될 수 없다"),
    # Parent T3 ownership and per-child gates survive.
    ("parent-ownership", r"불변식 소유[^\n]{0,10}?핵심 책임자 1명[^\n]{0,20}?최종 검증 수준[^\n]{0,10}?유지"),
    # Gate-side machinery is task #746's scope.
    ("gate-side-746", r"#746[^\n]{0,10}?범위"),
    # Cost never lowers the floor.
    ("floor-not-lowered", r"floor 를 낮추지 않는다"),
]

# Drift classes that must not appear anywhere in the three skill files.
FILE_FORBIDDEN = [
    # A one-round cap on the T3 / final-integration tester sneaking back in.
    ("t3-one-round-cap-ko",
     r"T3[^\n]{0,80}?(?:tester|테스터|적대검증)[^\n]{0,80}?(?:1|한)\s*라운드[^\n]{0,25}?(?:상한|캡|한정|제한|고정|충분|으로\s*끝|으로\s*족)"),
    ("integration-one-round-ko",
     r"통합[^\n]{0,40}?(?:검증|tester)[^\n]{0,40}?(?:1|한)\s*라운드[^\n]{0,25}?(?:상한|캡|한정|제한|고정|충분|으로\s*끝|으로\s*족)"),
    ("t3-one-round-en",
     r"(?i)\bT3\b[^\n]{0,80}?(?:tester|verifier|verification)[^\n]{0,60}?(?:one|single|1)[ -]round[^\n]{0,25}?(?:cap|limit|only|enough|suffic)"),
    # Core work reclassified to a lower T (the directed attack class).
    ("core-at-lower-t",
     r"핵심[^\n]{0,30}?(?:을|를|은|도|으로)?[^\n]{0,15}?(?:T1|T2|낮은 T)[^\n]{0,20}?(?:로|으로)?[^\n]{0,10}?(?:실행|처리|배정|돌린|내린|떼|나누)(?!하지)"),
    ("core-as-peripheral",
     r"핵심[^\n]{0,20}?(?:을|를|도|은)?[^\n]{0,10}?주변으로"),
    # Ambiguous piece run at a lower T instead of NEEDS_CLASSIFICATION.
    ("lower-t-on-ambiguous",
     r"애매하면[^\n]{0,30}?낮은 T[^\n]{0,10}?로?\s*실행(?!하지|\s*않)"),
    # File-type split coming back as the axis.
    ("file-type-axis",
     r"파일 종류로 나눈다|파일 종류[^\n]{0,16}?\)로 나눈다|UI/CLI/fixture/문서[^\n]{0,20}?자동[^\n]{0,10}?T[12]|UI·CLI·테스트[^\n]{0,20}?(?:로|별로)[^\n]{0,10}?분류"),
    # The weekly-pool one-round limit carried onto the T3 final-integration
    # tester (tester B-R1-2 — the pre-existing line-111 conflict). The cap
    # alternation covers application forms only — the rule itself is cited
    # by name ("단일 라운드 한정(§2-2)") in legit prose and must not trip.
    ("integration-single-round-ko",
     r"통합[^\n]{0,40}?(?:검증|tester)[^\n]{0,40}?단일 라운드[^\n]{0,5}?(?:로[^\n]{0,5}?(?:한정|제한|상한|캡)|한정[은을이가]|상한|캡|제한|만|까지|에만|검증)"),
    ("weekly-pool-t3-carry",
     r"T3[^\n]{0,40}?(?:최종\s*)?통합[^\n]{0,40}?tester[^\n]{0,40}?단일 라운드[^\n]{0,5}?(?:로[^\n]{0,5}?(?:한정|제한|상한|캡)|한정[은을이가]|상한|캡|제한|만|까지|에만|검증)"),
]

# Required rows against the whole spawn-worker file (outside the marked
# block): the §2-2 weekly-pool footnote must carry the carve-out pointer.
FILE_ROWS = [
    ("weekly-pool-111-carveout",
     r"단일 라운드 한정은?[^\n]{0,30}?최종 통합[^\n]{0,10}?T3 tester[^\n]{0,20}?적용하지 않는다"),
]

# Sentences that must exist ONLY inside the spawn block — a second copy in a
# pointer file is a leak, not a reference.
RULE_PHRASES_NOT_COPIED = [
    "핵심 책임자가 불변식 표를 먼저",
    "호출 한 줄이어도",
    "라운드 상한을 따로 줄이지 않는다",
]

PINNED_SKILLS = (
    "spawn-worker/SKILL.md",
    "builder/SKILL.md",
    "director/SKILL.md",
    "checker/SKILL.md",
)


def check(d: dict) -> None:
    blk = block(d["spawn"], "spawn")
    for row, pattern in BLOCK_ROWS:
        assert re.search(pattern, blk), f"spawn: T3 split row '{row}' missing or weakened"
    for name in SKILLS:
        text = flat(d[name])
        for row, pattern in FILE_FORBIDDEN:
            assert not re.search(pattern, text), (
                f"{name}: forbidden T3-split wording ({row}): "
                f"{re.search(pattern, text).group(0)!r}"
            )
    spawn_text = flat(d["spawn"])
    for row, pattern in FILE_ROWS:
        assert re.search(pattern, spawn_text), f"spawn: file-level row '{row}' missing or weakened"
    # Single canonical copy: pointers reference spawn §2-6 but carry no rules.
    for name in ("builder", "director"):
        assert START not in d[name] and END not in d[name], (
            f"{name}: a second T745-T3-SPLIT block copy"
        )
        text = flat(d[name])
        assert re.search(r"spawn-worker[^\n]{0,10}?§2-6", text), (
            f"{name}: one-line pointer to spawn-worker §2-6 missing"
        )
        for phrase in RULE_PHRASES_NOT_COPIED:
            assert phrase not in text, (
                f"{name}: rule sentence copied out of the canonical block: {phrase!r}"
            )
    # The gate policy pins the skill files: a re-pinned hash must match the
    # edited bytes, and an un-pinned file must not have drifted either way.
    policy = json.loads(d["policy"])
    pinned = policy["local_sources"]
    for rel in PINNED_SKILLS:
        if rel not in pinned:
            continue
        actual = hashlib.sha256((root / rel).read_bytes()).hexdigest()
        assert pinned[rel] == actual, (
            f"gate_policy local_sources pin for {rel} is stale "
            f"(pinned {pinned[rel][:12]}… actual {actual[:12]}…)"
        )


check(docs)
print(
    f"PASS t3-split-rule rows={len(BLOCK_ROWS)} "
    f"forbidden={len(FILE_FORBIDDEN)}/file pointers=2 pins verified"
)


def mutate(name: str, old: str, new: str) -> dict:
    doc = dict(docs)
    assert doc[name].count(old) >= 1, f"fixture: {old!r} not in {name}"
    doc[name] = doc[name].replace(old, new, 1)
    return doc


def append(name: str, text: str) -> dict:
    doc = dict(docs)
    doc[name] = doc[name] + "\n" + text + "\n"
    return doc


mutants = {}
# Axis and boundary.
mutants["spawn-split-by-file-type"] = mutate(
    "spawn", "불변식 영향으로 나눈다", "파일 종류로 나눈다"
)
mutants["spawn-file-type-body"] = mutate(
    "spawn", "파일\n종류(UI·CLI·테스트 등)가 아니라 불변식 영향이다", "파일\n종류(UI·CLI·테스트 등)로 나눈다"
)
# Invariant table.
mutants["spawn-table-second"] = mutate(
    "spawn", "불변식 표를 먼저 쓰고", "불변식 표를 나중에 쓰고"
)
mutants["spawn-table-column-dropped"] = mutate(
    "spawn", "전이 · 강제 위치 · 의존성", "전이 · 의존성"
)
# Core rows weakened.
mutants["spawn-one-line-out"] = mutate(
    "spawn", "**호출 한 줄이어도**", "한 줄 호출은 주변으로 떼도 되고"
)
mutants["spawn-safety-db-dropped"] = mutate(
    "spawn", "안전 DB 제약(UNIQUE/CHECK/", "일반 DB 변경("
)
mutants["spawn-error-path-dropped"] = mutate(
    "spawn", "에러 경로(cleanup·", "로그 경로(cleanup·"
)
mutants["spawn-lock-tx-dropped"] = mutate(
    "spawn", "lock/transaction 수명", "lock/transaction 이름"
)
mutants["spawn-boundary-dropped"] = mutate(
    "spawn", "상태/DB/예외 경계", "상태/DB/예외 표시"
)
# Peripheral rows weakened.
mutants["spawn-rendering-any"] = mutate(
    "spawn", "순수 렌더링", "모든 렌더링"
)
mutants["spawn-cli-readwrite"] = mutate(
    "spawn", "검증된 읽기 API 의 CLI", "읽기·쓰기 API 의 CLI"
)
# The surviving mutant the tester found (B-R1-1): flipping the safety-impact
# condition classified safety-touching work as peripheral while the contract
# still passed. Every eligibility condition is pinned now.
mutants["spawn-safety-impact-relaxed"] = mutate(
    "spawn", "안전 결정·권한·상태·증거에 영향 없음", "안전 결정·권한·상태·증거에 영향 있음"
)
mutants["spawn-fixed-contract-dropped"] = mutate(
    "spawn", "입/출력·\n  실패 계약 고정", "입/출력 계약은 추후에 정한다"
)
mutants["spawn-enumerable-dropped"] = mutate(
    "spawn", "허용 파일/심볼·금지\n  변경 열거 가능", "허용 범위는 작업자가 정한다"
)
mutants["spawn-independent-dropped"] = mutate(
    "spawn", "독립 인수·되돌리기 가능", "팀 내 인수만 가능"
)
# Other unlisted mutants the tester ran (all were RED — keep them in-repo).
mutants["spawn-observation-column-dropped"] = mutate(
    "spawn", "· 독립 관찰 결과", ""
)
mutants["spawn-api-glue-generalized"] = mutate(
    "spawn", "안전 경로와 무관한 고정 API 연결", "API 연결은 전부 주변"
)
mutants["spawn-reclassify-t2"] = mutate(
    "spawn", "그 PR 은 T3 로 재분류한다", "그 PR 은 T2 로 재분류한다"
)
# Weekly-pool one-round limit reaching the final integration tester (B-R1-2).
mutants["spawn-weekly-carveout-dropped"] = mutate(
    "spawn", "**주간 풀 단일\n  라운드 한정(§2-2)이 붙는 tester 는 최종 통합 tester 가 될 수 없다** — 통합\n  자리는 일반 라운드 캡이 필요하므로, 한정이 걸린 tester 로는 통합 검증을 열지\n  않고 다른 합집합 밖 tester 를 확보한다", ""
)
mutants["spawn-111-carveout-dropped"] = mutate(
    "spawn", " 이 **단일 라운드 한정은 최종 통합 T3 tester 자리에는 적용하지 않는다** — 그 자리는 §2-6 의 일반 라운드 캡이 필요하다.", ""
)
mutants["spawn-weekly-limit-applied"] = append(
    "spawn", "T3 최종 통합 tester 도 주간 풀 한정이라면 단일 라운드로 한정한다."
)
# NEEDS_CLASSIFICATION rule dropped or inverted.
mutants["spawn-needs-classification-dropped"] = mutate(
    "spawn", "낮은 T 로 실행하지 않고 `NEEDS_CLASSIFICATION`\n  으로 반환한다", "낮은 T 로 실행한다"
)
# Reclassification + citation.
mutants["spawn-reclassify-dropped"] = mutate(
    "spawn", "주변 PR 이 핵심을 건드리면 그 PR 은 T3 로 재분류한다", "주변 PR 은 그대로 머지한다"
)
mutants["spawn-728-733-dropped"] = mutate(
    "spawn", "(#728 PR 2·#733:", "(#000:"
)
# Cross-family tester + round cap.
mutants["spawn-cross-family-dropped"] = mutate(
    "spawn", "합집합 밖의 T3 tester 를 발주 전에 확보", "아무 tester 를 나중에 붙여"
)
mutants["spawn-one-round-cap"] = mutate(
    "spawn", "§5 의 라운드 캡(하드 캡 3라운드)이 그대로 적용된다 — 통합 tester 의 라운드\n  상한을 따로 줄이지 않는다",
    "라운드 캡(1라운드)이 적용된다 — 통합 tester 는 한 라운드로 끝낸다",
)
mutants["spawn-cap-shrunk"] = mutate(
    "spawn", "라운드\n  상한을 따로 줄이지 않는다", "라운드\n  상한을 1로 줄인다",
)
mutants["spawn-parent-ownership-dropped"] = mutate(
    "spawn", "불변식 소유·핵심 책임자 1명·최종 검증 수준은 유지", "불변식 소유는 나누고"
)
mutants["spawn-746-dropped"] = mutate(
    "spawn", "task #746 의\n  범위다", "아직 정해지지 않았다"
)
mutants["spawn-floor-lowering"] = mutate(
    "spawn", "비용\n때문에 floor 를 낮추지 않는다", "비용\n때문에 floor 를 낮춘다"
)
mutants["spawn-marker-dropped"] = mutate("spawn", START, "")
# Pointer files.
mutants["builder-pointer-dropped"] = mutate(
    "builder", "`spawn-worker` §2-6이다", "`spawn-worker` §2-5이다"
)
mutants["director-pointer-dropped"] = mutate(
    "director", "`spawn-worker` §2-6이다", "오케스트레이트 스킬이다"
)
mutants["builder-second-copy"] = append(
    "builder",
    START + "\n핵심 책임자가 불변식 표를 먼저 쓴다.\n" + END,
)
mutants["director-rule-copied"] = append(
    "director", "라운드 상한을 따로 줄이지 않는다."
)
mutants["director-one-round-added"] = append(
    "director", "T3 통합 tester는 1라운드로 충분하다."
)
mutants["builder-core-lower-t"] = append(
    "builder", "핵심 가드 배선도 T2 로 처리한다."
)
mutants["spawn-ambiguous-run"] = append(
    "spawn", "판정이 애매하면 낮은 T로 실행한다."
)
# A broken pin must fail closed.
mutants["policy-pin-broken"] = mutate(
    "policy",
    docs["policy"].split('"spawn-worker/SKILL.md": "', 1)[1].split('"', 1)[0],
    "0" * 64,
)

for name, doc in mutants.items():
    try:
        check(doc)
    except AssertionError as exc:
        print(f"RED {name}")
        continue
    raise SystemExit(f"mutant {name} did not go RED")
print(f"PASS mutants assertion-red={len(mutants)}/{len(mutants)}")
PY

echo "PASS test-t3-split-rule (prose contract + pointers + pins + mutants)"
