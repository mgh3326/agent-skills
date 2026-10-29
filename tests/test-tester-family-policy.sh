#!/usr/bin/env bash
# #643: conditional same-family tester verification. The spawn-worker §2-4
# block is parsed into a decision model and checked both ways: the allowed
# surface (A+ or below, reversible T1/T2, strong eligible tester, directed
# brief) is ALLOW, and every forbidden surface (T3, S grade, each excluded
# surface, effort-only tester, neutral brief, reused session, missing
# counterexamples or CI) is DENY. builder/director must carry the
# directed-attack-surface rule, and the three status labels stay distinct.
# Each mutant weakens one line of the wording and must go RED by assertion.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import os
import re
import sys

root = Path(sys.argv[1])
paths = {
    "spawn": Path(os.environ.get("SPAWN_WORKER_SKILL", root / "spawn-worker/SKILL.md")),
    "builder": Path(os.environ.get("BUILDER_SKILL", root / "builder/SKILL.md")),
    "director": Path(os.environ.get("DIRECTOR_SKILL", root / "director/SKILL.md")),
    "checker": Path(os.environ.get("CHECKER_SKILL", root / "checker/SKILL.md")),
}
docs = {name: path.read_text(encoding="utf-8") for name, path in paths.items()}

START = "<!-- same-family-verification:start -->"
END = "<!-- same-family-verification:end -->"
EXCLUDED = ["권한/승인", "안전가드", "배포", "매매", "민감정보", "비가역 쓰기"]
SAME = "동일 계열 독립 세션 검증"
CROSS = "교차 검증 완료"
NONE = "현 head 미검증"


def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def block(spawn: str) -> str:
    assert spawn.count(START) == 1 and spawn.count(END) == 1, "block markers"
    return spawn[spawn.index(START) : spawn.index(END)]


def item(blk: str, mark: str) -> str:
    m = re.search(rf"{mark}(.*?)(?=[①②③④⑤⑥⑦]|🔴|\*\*근거|$)", blk, re.S)
    assert m, f"condition {mark} missing"
    return flat(m.group(1))


def rules(spawn: str) -> dict:
    blk = block(spawn)
    c1, c2, c3 = item(blk, "①"), item(blk, "②"), item(blk, "③")
    c4, c5, c6, c7 = item(blk, "④"), item(blk, "⑤"), item(blk, "⑥"), item(blk, "⑦")
    surfaces = []
    m = re.search(r"제외 표면이 아님\*\*:(.*)", c2)
    if m:
        surfaces = [s.strip(" *") for s in m.group(1).split("·") if s.strip(" *")]
    return {
        "grades": {"A+", "A", "B", "C"} if "A+ 이하" in c1 else set(),
        "s_forbidden": "S·S+ 판단이 필요하면 불가" in c1,
        "tiers": {"T1", "T2"} if "되돌릴 수 있는 T1/T2" in c1 else set(),
        "t3_forbidden": "T3 불가" in c1,
        "excluded": set(surfaces),
        "fresh_session": "새 세션 + 별도 detached worktree" in c3,
        "strong_tester": "`opus` `xhigh` 급" in c4
        and "reps 실측" in c4
        and "지시형 브리프를 받은 원 tester 급 이상" in c4,
        "effort_only_rejected": re.search(r"effort 만 올린 tester.*충족하지 않는다", c4)
        is not None,
        "directed_brief": "지시형 공격 표면" in c5 and "`file:line`" in c5,
        "counterexamples": "독립적으로 만든 반례·실패 테스트" in c6,
        "required_ci": "required CI 초록" in c6,
        "label": f"`{SAME}`" in c7 and f"`{CROSS}`" in c7,
        "family_alone": "계열만으로는 자격이 되지 않는다" in flat(blk),
    }


def decide(r: dict, case: dict) -> str:
    """ALLOW = the same-family PASS may count as the merge gate's verification."""
    if case["family_only"] and r["family_alone"]:
        return "DENY"
    if case["grade"] not in r["grades"] or (case["grade"] in {"S", "S+"} and not r["s_forbidden"]):
        return "DENY"
    if case["tier"] not in r["tiers"] or not case["reversible"]:
        return "DENY"
    if case["surface"] in r["excluded"]:
        return "DENY"
    if r["fresh_session"] and not case["fresh_session"]:
        return "DENY"
    if r["strong_tester"] and case["tester"] != "strong":
        if case["tester"] != "effort_only" or r["effort_only_rejected"]:
            return "DENY"
    if r["directed_brief"] and not case["directed_brief"]:
        return "DENY"
    if r["counterexamples"] and not case["counterexamples"]:
        return "DENY"
    if r["required_ci"] and not case["ci_green"]:
        return "DENY"
    return "ALLOW"


BASE = dict(
    grade="A+", tier="T2", reversible=True, surface="docs", fresh_session=True,
    tester="strong", directed_brief=True, counterexamples=True, ci_green=True,
    family_only=False,
)
CASES = [("allowed-A+-T2", {}, "ALLOW"), ("allowed-A-T1", {"grade": "A", "tier": "T1"}, "ALLOW")]
CASES += [(f"excluded-{s}", {"surface": s}, "DENY") for s in EXCLUDED]
CASES += [
    ("tier-T3", {"tier": "T3"}, "DENY"),
    ("grade-S", {"grade": "S"}, "DENY"),
    ("grade-S+", {"grade": "S+"}, "DENY"),
    ("irreversible", {"reversible": False}, "DENY"),
    ("reused-session", {"fresh_session": False}, "DENY"),
    ("effort-only-tester", {"tester": "effort_only"}, "DENY"),
    ("weaker-tester", {"tester": "weak"}, "DENY"),
    ("neutral-brief", {"directed_brief": False}, "DENY"),
    ("no-counterexamples", {"counterexamples": False}, "DENY"),
    ("ci-not-green", {"ci_green": False}, "DENY"),
    ("family-alone", {"family_only": True, "tester": "weak", "directed_brief": False}, "DENY"),
]


def check(d: dict) -> None:
    r = rules(d["spawn"])
    assert r["excluded"] >= set(EXCLUDED), f"excluded surfaces lost: {set(EXCLUDED) - r['excluded']}"
    for label, over, want in CASES:
        got = decide(r, {**BASE, **over})
        assert got == want, f"{label}: expected {want}, got {got}"
    for key in ("t3_forbidden", "label", "family_alone"):
        assert r[key], f"rule missing: {key}"
    spawn = flat(d["spawn"])
    assert re.search(
        r"T3 와 아래 제외 표면은 머지 전에 contributor 계열 합집합 밖 tester 의 exact-head PASS 가 필수다",
        spawn,
    ), "T3/excluded out-of-union PASS rule missing"
    assert "1차가 위 조건부 동일 계열 검증의 ①~⑥ 을 모두 충족할 때만 1차 PASS 로 머지" in spawn, (
        "exhaustion fallback no longer bound to the same conditions"
    )
    assert f"| `{NONE}` |" in spawn.replace("**", "") and f"| `{SAME}` |" in spawn and f"| `{CROSS}` |" in spawn, (
        "three status labels must stay distinct"
    )
    assert "검증 강도 = 동일 계열 1회" not in spawn, "retired label reintroduced"
    assert "n=5 이고 T1·cognition 구현자·devin 하네스만 측정했으므로" in flat(block(d["spawn"])), (
        "E7 n=5 scope caveat missing"
    )
    assert "8건 중 각각 0건·1건" in flat(block(d["spawn"])), "E7 result numbers missing"
    assert "외삽하지 않는다" in flat(block(d["spawn"])), "no-extrapolation caveat missing"
    blk = flat(block(d["spawn"]))
    assert (
        "아래 조건을 **전부** 충족할 때만 contributor 계열과 같은 계열 tester 의 PASS 가 "
        "머지 게이트의 독립 검증이 된다" in blk
    ), "grant sentence must stay conditional on every item"
    assert "AC 의미 변경·같은 표면 반복 회귀가 있으면 교차 검증 또는 설계 재검토로 간다" in blk, (
        "escalation to cross verification / design review missing"
    )
    assert re.search(r"계열 합집합 밖 tester 가 같은 SHA 를 블라인드로 재검토한다", blk), (
        "pilot blind re-review missing"
    )
    assert (
        "`동일 계열 독립 세션 검증` 표기만으로는 머지 가능 상태가 아니다" in spawn
        and "`동일 계열 독립 세션 검증 (2차 대기 · 머지 불가)`" in spawn
    ), "same-family label must not by itself mean merge-eligible"
    for name in ("spawn", "builder"):
        assert "§2-4 동일 계열 예외" not in d[name], f"{name}: retired term '§2-4 동일 계열 예외'"
    builder = flat(d["builder"])
    assert re.search(
        r"최종 tester 는 builder 계열 밖이 기본이다 — 단 가역 T1/T2 는 `spawn-worker` §2-4 조건부 동일 계열 검증의 "
        r"조건을 \*\*전부\*\* 충족한 새 세션의 동일 계열 tester 도 된다\(T3·제외 표면은 예외 없이 계열 밖\)",
        builder,
    ), "builder solo mode must admit the §2-4 route for T1/T2 and keep T3/excluded out of family"
    assert "| 검증 독립성 | 다른 세션·다른 계열(동일 계열은 §2-4 조건부 동일 계열 검증만) |" in d["spawn"], (
        "§2-3 independence row must point at the §2-4 route"
    )
    for name in ("builder", "director"):
        text = flat(d[name])
        assert re.search(r"계열과 무관하게 항상 지시형 공격 표면", text), f"{name}: directed-surface rule missing"
        assert "`file:line`" in text and "중립" in text and "결함 대부분을 놓친다" in text, (
            f"{name}: neutral-brief warning missing"
        )
    for name in ("director", "checker"):
        text = flat(d[name])
        assert "T3와 제외 표면은 예외 없이 합집합 밖 PASS가 필요하다" in text, f"{name}: T3 carve-out missing"
        assert "계열만으로는 자격이 되지 않는다" in text, f"{name}: family-alone rule missing"
        assert "Sol director 재임 중 OpenAI contributor PR에는 동일 계열 경로" in text, (
            f"{name}: Sol director clause must cover the new route"
        )


check(docs)
print(f"PASS tester-family-policy cases={len(CASES)}/{len(CASES)}")


def mutate(name: str, old: str, new: str) -> dict:
    doc = dict(docs)
    assert doc[name].count(old) >= 1, f"fixture: {old!r} not in {name}"
    doc[name] = doc[name].replace(old, new, 1)
    return doc


mutants = {
    "excluded-surface-dropped": mutate("spawn", " · 배포 · 매매", " · 매매"),
    "t3-allowed": mutate("spawn", "**되돌릴 수 있는 T1/T2**(T3 불가)", "**되돌릴 수 있는 T1/T2/T3**"),
    "grade-widened": mutate("spawn", "작업 급 **A+ 이하**", "작업 급 **S 이하**"),
    "effort-only-accepted": mutate("spawn", "tester(예: `devin-swe2` 구현 → `swe-2-max` tester)는 충족하지 않는다", "tester 도 충족한다"),
    "strong-tester-dropped": mutate("spawn", "`opus` `xhigh` 급, 또는", "적격 모델, 또는"),
    "directed-brief-dropped": mutate("spawn", "⑤ tester 브리프에 **지시형 공격 표면**", "⑤ tester 브리프에 AC"),
    "ci-dropped": mutate("spawn", ", 최종 SHA 의 **required CI 초록**", ""),
    "family-alone-dropped": mutate("spawn", "🔴 **계열만으로는 자격이 되지 않는다.**", "🔴"),
    "label-merged": mutate("spawn", "| `동일 계열 독립 세션 검증` |", "| `교차 검증 완료` |"),
    "exhaustion-unbound": mutate("spawn", "1차가 위 조건부 동일 계열 검증의 ①~⑥ 을 모두 충족할 때만 ", ""),
    "e7-caveat-dropped": mutate("spawn", "n=5 이고", "측정이"),
    "e7-numbers-dropped": mutate("spawn", "각각 0건·1건을 잡았다", "일부를 잡았다"),
    "builder-directed-dropped": mutate("builder", "계열과 무관하게 항상 지시형 공격 표면을", "필요하면 공격 표면을"),
    "director-directed-dropped": mutate("director", "계열과 무관하게 항상 지시형 공격 표면이", "가능하면 공격 표면이"),
    "director-t3-carveout-dropped": mutate("director", "T3와 제외 표면은 예외 없이 합집합 밖 PASS가 필요하다. ", ""),
    "grant-neutralized": mutate("spawn", "계열 tester 의 PASS 가 머지 게이트의 독립 검증이 된다.", "계열 tester 의 PASS 도 참고한다."),
    "all-dropped": mutate("spawn", "아래 조건을 **전부** 충족할 때만", "아래 조건을 충족할 때만"),
    "original-tester-dropped": mutate("spawn", "지시형 브리프를 받은 원 tester 급 이상", "적격"),
    "escalation-dropped": mutate("spawn", "AC 의미 변경·같은 표면 반복 회귀가 있으면 교차 검증 또는 설계 재검토로 간다", "다시 본다"),
    "blind-rereview-dropped": mutate("spawn", "블라인드로 재검토한다", "재검토한다"),
    "label-eligibility-dropped": mutate("spawn", "`동일 계열 독립 세션 검증` 표기만으로는 머지 가능 상태가 아니다", "표기는 참고용이다"),
    "solo-mode-categorical": mutate("builder", "계열 밖이\n   기본이다 — 단 가역 T1/T2 는", "계열 밖.\n   가역 T1/T2 도"),
    "solo-mode-t3-leak": mutate("builder", "(T3·제외 표면은 예외 없이 계열 밖)", "(T3 포함)"),
    "independence-row-categorical": mutate("spawn", "다른 세션·다른 계열(동일 계열은 §2-4 조건부 동일 계열 검증만)", "다른 세션·다른 계열"),
    "retired-term-back": mutate("spawn", "(§2-4 조건부 동일 계열 검증·소진 시 지연 검증).", "(타사 풀 물리적 소진 시 §2-4 동일 계열 예외)."),
}
for name, doc in mutants.items():
    try:
        check(doc)
    except AssertionError:
        print(f"RED {name}")
        continue
    raise SystemExit(f"mutant {name} did not go RED")
print(f"PASS mutants assertion-red={len(mutants)}/{len(mutants)}")
PY
