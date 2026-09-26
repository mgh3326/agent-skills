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
     r"(?i)\bT3\b[^\n]{0,80}?(?:tester|verifier|verification)[^\n]{0,60}?(?:one|single|1(?!\s*차))[ -]round[^\n]{0,25}?(?:cap|limit|only|enough|suffic)"),
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
    # R2 tester findings — same attack classes under alternate wording:
    # a once-only integration pass, a skipped re-verify, ambiguous work run
    # low then classified later, core classes named without the word 핵심.
    ("integration-one-pass",
     r"(?:통합|결합|합침|병합|머지)[^\n]{0,40}?(?:검증|tester|확인|점검|검토)?[^\n]{0,40}?(?:한 차례|한 번|한번|1회|단 한 번|1패스|한 패스|단일|한 회)[^\n]{0,15}?(?:만[^\n]{0,15}?(?:검증|확인|보고|통과|본다|체크|끝낸다|보면|훑|살피|둘러보|검토|점검|마친|마무리)|(?:검증|확인|보고|통과|체크|훑|살피|둘러보|검토|점검|보고)[^\n]{0,10}?(?:으로\s*끝|까지만|충분|하면\s*된다|끝낸다|마친다|마무리|면면|훑어보면))|(?:한 차례|한 번|한번|1회|단 한 번|1패스|한 패스|단일|한 회)[^\n]{0,15}?(?:검증|확인|보고|통과|본다|"
     r"체크|보면|봐도|훑|살피|둘러보|검토|점검|보고)[^\n]{0,20}?(?:최종\s*)?(?:통합|결합|합침|병합|머지)|(?:통합|결합|합침|병합|머지)[^\n]{0,25}?(?:검증|tester)[^\n]{0,15}?충분(?!하지|하다고|할 리|치 않|기가)|한\s*번[^\n]{0,10}?(?:훑|살피|둘러보|보고|본다|보면|검토|점검|확인|스캔)[^\n]{0,10}?(?:마친|끝|마무리|충분|된다|완료|통과)"),
    ("integration-one-pass-en",
     r"(?i)(?:final\s+)?(?:integration|merge(?:r|d|s)?|merging|combin\w+|결합|병합|머지|합침|통합)[^\n]{0,45}?(?:(?:only\s+one|\bone\b|single|a\s+single|just\s+one|one-?shot|single-?shot|1(?!\s*차))[^\n]{0,15}?(?:pass|round|look|check|review|verification|glance|peek|once-?over|runthrough|walkthrough|sign[- ]?(?:ed?[-\s]*)?off|signoff|inspection|scrutiny|assessment|audit|examin(?:ation|e)|perusal|scan|survey|sweep|read[- ]through|dry[- ]run|test\b|probe|double[- ]check|skim|browse|approval)|(?:run|look|review|verify|check|use|read|skim|scan|browse)[ -]?once|once\s+only)|(?:only\s+one|"
     r"\bone\b|single|a\s+single|just\s+one|one-?shot|single-?shot|1(?!\s*차))[^\n]{0,15}?(?:pass|round|look|check|review|verification|glance|peek|once-?over|runthrough|walkthrough|sign[- ]?(?:ed?[-\s]*)?off|signoff|inspection|scrutiny|assessment|audit|examin(?:ation|e)|perusal|scan|survey|sweep|read[- ]through|dry[- ]run|test\b|probe|double[- ]check|skim|browse|approval)[^\n]{0,45}?(?:final\s+)?(?:integration|merge(?:r|d|s)?|merging|combin\w+|결합|병합|머지|합침|통합)"),
    ("integration-initial-pass-suffices",
    r"(?i)(?:initial|first|single|one|lone|sole|opening)[^\n]{0,15}?(?:sign[- ]?(?:ed?[-\s]*)?off|pass|round|review|inspection|check|audit|examin\w+|glance|look)[^\n]{0,25}?(?:alone|by itself|on its own|suffices|is enough|conclusive|decisive|adequate|sufficient|enough|충분|족하|혼자)[^\n]{0,25}?(?:final\s+)?(?:integration|merge(?:r|d|s)?|merging|combin\w+|결합|병합|머지|합침|통합)|(?:final\s+)?(?:integration|merge(?:r|d|s)?|merging|combin\w+|결합|병합|머지|합침|통합)[^\n]{0,45}?(?:initial|first|single|one|lone|sole|"
    r"opening)[^\n]{0,15}?(?:sign[- ]?(?:ed?[-\s]*)?off|pass|round|review|inspection|check|audit|examin\w+|glance|look)[^\n]{0,20}?(?:alone|by itself|on its own|suffices|is enough|conclusive|decisive|adequate|sufficient|enough|충분|족하|혼자)|(?:initial|first|one|single)[^\n]{0,15}?(?:pass|round|inspection|review|check|audit|examin\w+|sign[- ]?offs?)[^\n]{0,30}?(?:later|subsequent|further|additional|extra|more|second|follow-?up|나중|후속|추가|뒤)[^\n]{0,15}?(?:passes?|rounds?|inspections?|reviews?|checks?|audits?|examin\w+|ones?|패스|"
    r"라운드|검토|검사)?[^\n]{0,30}?(?:at[^\n]{0,15}?(?:discretion|choice)|discretionary|optional|unnecessary|not needed|waivable|skippable|dispensable|unneeded|up\s+to\s+(?:the\s+)?\w+|owner'?s?\s+(?:call|choice|discretion)|선택|생략|불필요|재량|자유)|(?:final\s+)?(?:integration|merge(?:r|d|s)?|merging|combin\w+|결합|병합|머지|합침|통합)[^\n]{0,45}?(?:is\s+|are\s+|be\s+|gets?\s+|was\s+|been\s+)?(?:settled|decided|determined|resolved|closed|done|finished|completed|concluded|disposed|discharged|ended|finalized|정해|결정|마무리|종결)[^\n]{0,15}?(?:by|with|after|on|via|through|으로|에서)\s+(?:the\s+|a\s+|an\s+|one\s+|its\s+)?(?:first|initial|single|sole|lone|opening|1st|earliest|primary|첫|처음|최초)[^\n]{0,15}?(?:sign[- ]?(?:ed?[-\s]*)?off|pass|round|review|inspection|check|audit|examin\w+|glance|look|assessment|verdict|evaluation|scrutiny|검토|검사|심사|평가)"),
    ("integration-cap-numeric",
    r"(?i)(?:(?:final\s+)?(?:integration|merge(?:r|d|s)?|merging|combin\w+|결합|병합|머지|합침|통합)[^\n]{0,45}?(?:(?:cap\w*|limit\w*|ceil\w*|restrict\w*|confine\w*|ceiling|up\s+to|consume|permit\w*|allow\w*|use|uses|employ\w*|상한|캡|제한|둔다|정한|고정|끝|충분|허용|가능|enough|suffic\w*)[^\n]{0,20}?(?:[01245-9]|one|two|zero|four|five|six|seven|eight|nine|ten|eleven|twelve|dozen|1[0-9]|many|several|multiple|numerous|unlimited|unbounded|한|두|네|다섯|여섯|일곱|여덟|아홉|열|열한|열두|십|다수|여러|무제한|단일|single|couple(?:\s+of)?|pair(?:\s+of)?|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|score|scores|\d{2,}|스물|서른|마흔|쉰|예순|일흔|여든|아흔|백|천)\s*(?:passes?|rounds?|회|차례|패스|라운드|번|looks?|reviews?|checks?|sign[- ]?offs?|"
    r"cycles?|audits?|inspections?|examin\w+|evaluations?|assessments?|verifications?)|(?:[01245-9]|one|two|zero|four|five|six|seven|eight|nine|ten|eleven|twelve|dozen|1[0-9]|many|several|multiple|numerous|unlimited|unbounded|한|두|네|다섯|여섯|일곱|여덟|아홉|열|열한|열두|십|다수|여러|무제한|단일|single|couple(?:\s+of)?|pair(?:\s+of)?|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|score|scores|\d{2,}|스물|서른|마흔|쉰|예순|일흔|여든|아흔|백|천)\s*(?:passes?|rounds?|회|차례|패스|라운드|번|looks?|reviews?|checks?|sign[- ]?offs?|cycles?|audits?|inspections?|examin\w+|evaluations?|assessments?|verifications?)[^\n]{0,20}?(?:cap\w*|limit\w*|ceil\w*|restrict\w*|confine\w*|ceiling|up\s+to|consume|permit\w*|allow\w*|use|uses|employ\w*|상한|캡|제한|둔다|정한|고정|끝|충분|허용|가능|enough|suffic\w*))|(?:[01245-9]|one|two|zero|four|five|six|seven|eight|nine|"
    r"한|두|네|다섯|여섯|일곱|여덟|아홉|단일|single|couple(?:\s+of)?|pair(?:\s+of)?)\s*(?:permitted|allowed|available|remaining|left|남은|허용|가능)?\s*(?:passes?|rounds?|회|차례|패스|라운드|번|looks?|reviews?|checks?|sign[- ]?offs?|cycles?|audits?|inspections?|examin\w+|verifications?)(?!\s*(?:한정|상한|캡|제한|규칙)[은이는란])[^\n]{0,20}?(?:for|of|on|per|at|에|으로)?\s*(?:the\s+)?(?:final\s+)?(?:integration|merge(?:r|d|s)?|merging|combin\w+|결합|병합|머지|합침|통합)|(?:unbounded|boundless|uncapped|limitless|unlimited|unrestricted|unconstrained|infinite|endless|no\s+(?:upper\s+|hard\s+|firm\s+)?(?:bound|limit|cap|ceiling|restriction|constraint)|without\s+(?:any\s+|an\s+)?(?:upper\s+|hard\s+|firm\s+)?(?:bounds?|limit|cap|ceiling|restriction|constraint))[^\n]{0,20}?(?:passes?|rounds?|회|차례|패스|라운드|번|looks?|reviews?|checks?|sign[- ]?offs?|cycles?|audits?|inspections?|examin\w+|evaluations?|assessments?|verifications?)[^\n]{0,25}?(?:final\s+)?(?:integration|merge(?:r|d|s)?|merging|combin\w+|결합|병합|머지|합침|통합)|(?:final\s+)?(?:integration|merge(?:r|d|s)?|merging|combin\w+|결합|병합|머지|합침|통합)[^\n]{0,45}?(?:(?:unbounded|boundless|uncapped|limitless|unlimited|unrestricted|unconstrained|infinite|endless)[^\n]{0,15}?(?:passes?|rounds?|회|차례|패스|라운드|번|looks?|reviews?|checks?|sign[- ]?offs?|cycles?|audits?|inspections?|examin\w+|evaluations?|assessments?|verifications?)|(?:without|sans|with\s+no|no)\s+(?:any\s+|an\s+)?(?:upper\s+|hard\s+|firm\s+)?(?:bounds?|limit|cap|ceiling|restriction|constraint)|(?:may|might|can|could)\s+(?:continue|proceed|run|go|extend|stretch|drag|repeat|revisit)[^\n]{0,15}?(?:without|sans|with\s+no|no)\s+(?:any\s+|an\s+)?(?:upper\s+|hard\s+|firm\s+)?(?:bounds?|limit|cap|ceiling|restriction|constraint)|(?:is|are|be|remains?|stays?|seems?|appears?|counts?\s+as|becomes?|turns?|goes|gets?|stands?|남는다|유지|두고|둔다)\s+(?:unbounded|boundless|uncapped|limitless|unlimited|unrestricted|unconstrained|infinite|endless|무제한|무한|상한\s*없)))"),
    ("verdict-inherit-after-change",
     r"(?i)(?:previous|prior|old|earlier|parent|pre[- ]?squash|original|existing|stale|ancestor|predecessor|grandparent|기존|이전|부모|조상|선행)[^\n]{0,25}?(?:sign[- ]?(?:ed?[-\s]*)?off|approval|verdict|review|verification|PASS|accept\w*|green\s*light|go[-\s]?ahead|receipt|token|records?|file|log|acceptance|승인|판정|검증|통과|결과|허가|효력)[^\n]{0,25}?(?:substitut\w*|inherit\w*|replac\w*|suffic\w*|enough|stands?|holds?|appl\w*|carr\w*|counts?|serves?|acts?|works?|covers?|grandfather\w*|rides?|transfer\w*|rolls?\s+over|borrow\w*|stands?\s+on|rests?\s+on|leans?\s+on|relies?\s+on|builds?\s+on|draws?\s+on|instead|in\s+(?:its|their|"
     r"the)\s+place|갈음|대신|대체|승계|계승|유효|충분|그대로)[^\n]{0,30}?(?:head|revision|commit|merged|amended|squashed|new|changed|fresh|updated|커밋|변경|수정|머지|병합|리비전|replacement|sha|version|버전|successor|descendant|derived|downstream)|(?:squash\w*|amend\w*|rebas\w*|rewrit\w*|revis\w*|force[- ]?push|patch|updat\w*|스쿼시|어?멘드|개정|리베이스|패치|수정|새\s*head|follow[- ]?up|subsequent|후속)[^\n]{0,30}?(?:commits?|head|revision|sha|version|커밋|버전|리비전)[^\n]{0,25}?(?:(?:inherit\w*|substitut\w*|replac\w*|keep\w*|reuse|re-?use|carr\w*|retain\w*|"
     r"hold\w*|stand\w*|suffic\w*|enough|grandfather\w*|rides?|transfer\w*|갈음|대신|대체|승계|계승|유지|충분)[^\n]{0,35}?(?:verification|verdict|review|approval|sign[- ]?(?:ed?[-\s]*)?off|PASS|accept\w*|green\s*light|receipt|token|records?|acceptance|판정|검증|승인|통과|결과|효력)|(?:verification|verdict|review|approval|sign[- ]?(?:ed?[-\s]*)?off|PASS|accept\w*|green\s*light|receipt|token|records?|acceptance|승인|판정|검증|통과|결과|효력)[^\n]{0,20}?(?:inherit\w*|substitut\w*|replac\w*|carr\w*|retain\w*|transfer\w*|grandfather\w*|rides?|borrow\w*|stands?\s+on|rests?\s+on|leans?\s+on|relies?\s+on|승계|계승|"
     r"갈음|대신|대체|유지)|(?:squash\w*|amend\w*|rebas\w*|rewrit\w*|revis\w*|force[- ]?push|patch|updat\w*|스쿼시|어?멘드|개정|리베이스|패치|수정|새\s*head|follow[- ]?up|subsequent|후속)[^\n]{0,25}?(?:inherit\w*|substitut\w*|replac\w*|reuse|re-?use|carr\w*|retain\w*|transfer\w*|grandfather\w*|rides?|borrow\w*|stands?\s+on|rests?\s+on|leans?\s+on|relies?\s+on|승계|계승|갈음|대신|대체|유지|그대로)[^\n]{0,15}?(?:verification|verdict|review|approval|sign[- ]?(?:ed?[-\s]*)?off|PASS|accept\w*|green\s*light|receipt|token|records?|acceptance|승인|판정|검증|통과|결과|효력)[^\n]{0,30}?(?:head|revision|commit|"
     r"commits?|sha|version|replacement|successor|descendant|derived|downstream|커밋|버전|리비전))|(?:new|revised|updated|patched|rebased|squashed|amended|새|새로운|수정된|리베이스된)[^\n]{0,5}?(?:head|revision|commit|sha|version|커밋|버전|리비전)[^\n]{0,25}?(?:inherit\w*|substitut\w*|replac\w*|reuse|re-?use|carr\w*|retain\w*|transfer\w*|grandfather\w*|rides?|holds?|stands?\s+on|borrow\w*|rests?\s+on|leans?\s+on|relies?\s+on|승계|계승|갈음|대신|대체|유지|그대로)[^\n]{0,15}?(?:under|from|of|의|으로|에)?\s*(?:the\s+)?(?:previous|prior|old|earlier|parent|ancestor|predecessor|grandparent|existing|"
     r"stale|기존|이전|부모|조상|선행)[^\n]{0,15}?(?:'s\s+)?(?:verification|verdict|review|approval|sign[- ]?(?:ed?[-\s]*)?off|PASS|accept\w*|green\s*light|receipt|token|records?|acceptance|승인|판정|검증|통과|결과|효력)|(?:squash\w*|amend\w*|rebas\w*|rewrit\w*|revis\w*|force[- ]?push|patch|updat\w*|스쿼시|어?멘드|개정|리베이스|패치|수정|새\s*head|follow[- ]?up|subsequent|후속)[^\n]{0,25}?(?:inherit\w*|substitut\w*|replac\w*|reuse|re-?use|carr\w*|retain\w*|transfer\w*|grandfather\w*|rides?|borrow\w*|stands?\s+on|rests?\s+on|leans?\s+on|relies?\s+on|승계|계승|갈음|대신|대체|유지|"
     r"그대로)[^\n]{0,15}?(?:verification|verdict|review|approval|sign[- ]?(?:ed?[-\s]*)?off|PASS|accept\w*|green\s*light|receipt|token|records?|acceptance|승인|판정|검증|통과|결과|효력)[^\n]{0,30}?(?:head|revision|commit|commits?|sha|version|replacement|successor|descendant|derived|downstream|커밋|버전|리비전)|(?:results?|verdicts?|approvals?|reviews?|findings?|conclusions?|outcomes?|records?|결과)\s+of\s+(?:an?\s+|the\s+)?(?:old|earlier|previous|prior|ancestor|predecessor|original|existing|stale|past|preceding|former|기존|이전|부모|조상|선행)[^\n]{0,15}?(?:examination|review|inspection|audit|check|verdict|test|assessment|evaluation|scrutiny|look|pass|round|trial|probe|sweep|run|검증|판정|검사|심사|조사|시험)[^\n]{0,25}?(?:governs?|controls?|binds?|applies?|covers?|extends?|reaches?|suffices?|stands?|holds?|remains?|stays?|persists?|carries?|continues?|endures?|survives?|decides?|rules?|authoritative|decisive|binding|conclusive|operative)[^\n]{0,30}?(?:every|each|all|any|the|its|their|subsequent|later|new|successor|descendant|derived|child|downstream|future|succeeding)[^\n]{0,20}?(?:revisions?|heads?|commits?|shas?|versions?|successors?|descendants?|offspring|커밋|리비전|버전)"),


    ("integration-skipped",
     r"(?i)(?:최종\s*)?통합[^\n]{0,25}?(?:tester|검증)[^\n]{0,12}?(?:없이|생략|불필요|제외|건너)|머지[^\n]{0,15}?(?:없이|생략)[^\n]{0,10}?(?:검증|tester)|(?:merge|merging)[^\n]{0,15}?(?:without|skip\w*|omit\w*)[^\n]{0,10}?(?:verif\w*|tester|check)|(?:final\s+)?(?:integration|merge(?:r|d|s)?|merging|combin\w+|결합|병합|머지|합침|통합)[^\n]{0,30}?(?:tester[- ]?(?:free|less)|without\s+(?:an?\s+)?(?:independent\s+|cross[- ]family\s+)?tester|no\s+tester)|verdict[^\n]{0,15}?(?:유효|valid|재사용|그대로)[^\n]{0,10}?(?:수정|바뀐|새|patched|changed|new|updated)\s+head|(?:old|previous|prior|stale|earlier|existing|same|preceding|original|기존|이전)[^\n]{0,10}?(?:verdict|PASS|review|check|"
     r"verification|sign[- ]?(?:ed?[-\s]*)?off|approval|accept\w*|results?|outcomes?|승인|판정|결과|허가|통과)[^\n]{0,15}?(?:still|remains?|stays?|valid|count\w*|reuse|carry|carries|applies|suffic\w*|enough|stands|holds|in\s+force|in\s+effect|rolls?\s+over|persists?|authoritative|controlling|governing|decisive|binding|operative|conclusive|definitive|갈음|대체|그대로|사용|이용|쓴|삼|충분|유효)"),
    ("integration-no-reverify",
     r"(?:수정된?|바뀐|새|패치된)\s*head[^\n]{0,20}?(?:재검증|다시 검증|재확인|후속 확인|후속 검증|추가 확인|검증|확인|점검)[^\n]{0,12}?(?:하지\s*않|없|생략|불필요|필요[^\n]{0,3}?없)|재검증[^\n]{0,12}?(?:없이|하지|생략|불필요|필요[^\n]{0,3}?없)|(?:후속|추가)\s*(?:확인|검증|점검)[^\n]{0,8}?(?:생략|불필요|없|하지)"),
    ("integration-no-reverify-en",
     r"(?i)(?:re-?verif\w*|re-?check\w*|recheck\w*|re-?examin\w*|re-?inspect\w*|re-?review\w*|re-?evaluat\w*)[^\n]{0,15}?(?:waiv\w*|skip\w*|omit\w*|dropped|not needed|unnecessary|unneeded|no longer)|(?:skip|omit|waive|without|sans|no)[^\n]{0,15}(?:re-?verif\w*|re-?check\w*|recheck\w*|(?:second|third|another|extra)\s+(?:verification|check|pass|look|review|inspection|scrutiny)|follow-?up\s+(?:verification|check|look|review|inspection)|further\s+(?:verification|check|review|scrutiny|inspection|look))|(?:patched|changed|modified|updated|new)\s+heads?[^\n]{0,20}?(?:accept\w*|approv\w*|merg\w*|pass\w*|us\w*|go\w*|no|without|sans|skip\w*|omit\w*|waiv\w*|"
     r"not needed|unnecessary|unneeded)[^\n]{0,15}?(?:second\s+|third\s+|another\s+|further\s+|additional\s+|re-?|extra\s+)?(?:verification|verif|check|pass|look|review|inspection|scrutiny)|after[^\n]{0,10}?(?:the\s+)?head[^\n]{0,10}?change\w*[^\n]{0,15}?(?:no|without|skip|omit|waive|not needed|unnecessary|accept\w*)[^\n]{0,12}?(?:second\s+)?(?:verification|check|pass|look|review|inspection|scrutiny)|(?:second|third|another|further|additional|extra)\s+(?:look|check|review|verification|pass|inspection|scrutiny)[^\n]{0,25}?(?:at|on|for|of)?[^\n]{0,15}?(?:patched|changed|modified|updated|new)\s+heads?|(?:no need|not needed|unnecessary|"
     r"unneeded)[^\n]{0,15}?(?:for\s+)?(?:a\s+)?(?:second|third|another|follow-?up|further|additional|extra|fresh|new)[ -]?(?:look|check|review|verification|pass|inspection|scrutiny)|(?:no|without|sans|skip\w*|omit\w*|waiv\w*)[^\n]{0,10}?(?:fresh|new|additional|further|second|third|another|extra|follow-?up)\s+(?:check|verification|review|look|inspection|scrutiny|verif)[^\n]{0,15}?(?:is\s+|are\s+|be\s+)?(?:required|needed|necessary|mandatory|obligatory)|(?:post[- ]?update|after\s+(?:an?\s+)?(?:update|patch|change)|head[^\n]{0,6}?(?:change|update|patch|수정|변경))[^\n]{0,20}?(?:verification|verif|check|review|inspection|scrutiny|look|확인|"
     r"검증|점검)[^\n]{0,12}?(?:optional|discretionary|skip\w*|omit\w*|waiv\w*|not needed|unnecessary|unneeded|생략|불필요|없)|(?:previous|prior|old|earlier|existing|same)[^\n]{0,10}?(?:review|verdict|check|verification|look)[^\n]{0,15}?(?:carries?\s*(?:through|over|forward)|still\s+(?:valid|holds|applies|counts?)|remains?\s+(?:valid|sufficient|enough|in\s+force|in\s+effect)|stands|holds|suffic\w*|rolls?\s+over|persists?)|(?:needs?\s+no|requires?\s+no)[^\n]{0,15}?(?:renewed|refreshed|fresh|new|repeat\w*|re-?|second|another|further|additional)[ -]?(?:scrutiny|verification|verif|check|review|look|inspection|assessment|audit|검증|확인|"
     r"점검|재검)|(?:새|수정된?|바뀐|패치된?)\s*(?:head|커밋|commit)[^\n]{0,20}?(?:기존|이전)[^\n]{0,10}?(?:승인|판정|결과|검증|확인|허가|통과)[^\n]{0,10}?(?:갈음|대체|충분|유효|그대로|사용|이용|쓴|삼)"),
    ("ambiguous-lower-t-alt",
     r"(?i)(?:애매|모호|불명확|불확실|미분류|미정|모른|알 수 없|정해지지 않|경계가|분류 불가|unclear|unclassified|ambiguous|uncertain|unsure|undecided|undetermined|indeterminate|unsettled|unresolved|unknown|vague|fuzzy|hazy|iffy|open[- ]ended|undefined|unset|questionable|borderline|tentative|murky|cloudy|obscure|muddled|gray|grey|nebulous|unpinned|loose|opaque|doubtful|dubious|shaky|in[- ]between|limbo|unscoped|unbounded|untriaged|unsorted|unfiled|uncategorized|contested|disputed|arguable|moot|competing\s+(?:interpretations?|readings?|accounts?|claims?|meanings?)|conflicting\s+(?:interpretations?|readings?|accounts?|claims?|reports?|meanings?)|divergent\s+interpretations?|multiple\s+(?:interpretations?|readings?|accounts?|meanings?)|rival\s+interpretations?|open\s+to\s+interpretation|subject\s+to\s+interpretation|interpretation[-\s]dependent|competing\s+meanings?|판단 불가|결정 불가|흐리|곤란|불명|미상|불분명|헷갈|불투명|그레이|회색|어중간|판단 어려|"
     r"판별 불가|경계 불명|adjudicat\w*|unadjudicat\w*|not\s+yet\s+(?:adjudicat\w*|decid\w*|determin\w*|settled|resolv\w*|classif\w*|sort\w*|triag\w*)|TBD|to\s+be\s+(?:decid\w*|determin\w*|resolv\w*|classif\w*|sort\w*|triag\w*)|미결|판정\s*전|미확정|정해지지\s*않은|outstanding|open\s+question|half[- ]?defined|undetermined|unresolved|판정\s*보류|분류\s*보류|보류\s*상태|(?:cannot|can't|unable|hard|difficult)[^\n]{0,15}?(?:decide|determine|classify|scope|boundar|resolve))[^\n]{0,30}?(?:(?:T0|T1|T2|tier[ -]?(?:zero|one|two|three|[0-3])|낮은 T|lower\s*T)[^\n]{0,15}?(?:실행|처리|배정|돌리|맡기|넘기|시작|보낸|보냄|착수|진입|투입|돌입|배치|할당|넣|넣는|집어|태우|올리|밀어|던지|start|run|"
     r"assign|dispatch|handle|processing|work|enter|go|land|fall|drop|move|shift|place|put|set|slot|park|feed|throw|pass|delegate|push|offload|execute|process|perform|queu\w*|enqueu\w*|rout\w*|shelv\w*)(?!하지)|(?:start|begin|run|assign|dispatch|handle|send|route|enter|go|land|fall|drop|move|shift|place|put|set|slot|park|feed|throw|pass|delegate|push|offload|execute|process|"
     r"perform|queu\w*|enqueu\w*|rout\w*|shelv\w*)[^\n]{0,16}?(?:at|as|to|into|on|in|for|onto|toward\w*|upon)\s*(?:the\s+|a\s+)?(?:T0|T1|T2|tier[ -]?(?:zero|one|two|three|[0-3])|L[0-3]\b|level\s*(?:one|two|[0-3])|band\s*(?:[IVX]+|[0-9])|lower\s*T|low[- ]?tier|저급|하급|싼|저렴|junior|entry[- ]level|inexpensive|low[- ]cost|low[- ]skill|minor|가벼운|경량|auxiliary|secondary|bottom|intern|apprentice|rookie|novice|staff|personnel|보조|부수|trainee|clerical|housekeeping|provisionally|pending)|(?:enter\w*|join\w*|hit\w*|reach\w*|land\w*|slip\w*|slide\w*|fall\w*|"
     r"park\w*|queu\w*|enqueu\w*|slot\w*|deposit\w*|begin\w*|commence\w*|embark\w*|kick\w*|착수|진입|투입|돌입|넣|배치)[^\n]{0,5}?(?:into\s+|in\s+|to\s+|at\s+|on\s+|for\s+)?\s*(?:the\s+|a\s+)?(?:T0|T1|T2|tier[ -]?(?:zero|one|two|three|[0-3])|L[0-3]\b|band\s*(?:[IVX]+|[0-9])|lower\s*T|low[- ]?tier|low[- ]cost|junior|apprentice|entry[- ]level|inexpensive|temp\w*|casual|part[-\s]?time|contract|support|queue|lane|track|저급|하급|싼|저렴|보조|부수|주변)|(?:착수|진입|투입|돌입|시작|개시|start|begin)[^\n]{0,15}?(?:먼저|우선|first)[^\n]{0,20}?(?:급|T0|T1|T2|tier|등급|grade|band)[^\n]{0,15}?(?:뒤에|나중|이후|추후|사후|나중에|later|after|following|"
     r"postponed|deferred|미뤄|보류)[^\n]{0,10}?(?:정한다|정해|결정|decided|determined|classified|sorted|분류|정리)|(?:먼저|우선|first)[^\n]{0,15}?(?:작업|실행|착수|진입|work|start|run|proceed)[^\n]{0,20}?(?:급|T0|T1|T2|tier|등급|grade|band|분류|classification)[^\n]{0,15}?(?:뒤에|나중|이후|추후|사후|later|after|postponed|deferred|미뤄|보류|pending))"),
    ("ambiguous-posthoc-classify",
     r"(?i)(?:애매|모호|불명확|불확실|미분류|미정|경계 작업|경계 불명|불명|미상|ambiguous|unclear|uncertain|unsure|undecided|undetermined|unsettled|unresolved|unknown)[^\n]{0,40}?(?:(?:사후|나중에?|추후|뒤에?|후에|이후|afterwards?|later|after|following|pending|awaiting|until|till|while|대기|보류|유보)[^\n]{0,10}?(?:분류|재분류|classif|triage|categoriz|sort|tag|grade|label|file|bucket|bracket|정리|판별|분별|분류 대기)|(?:분류|재분류|classif\w*|triage|categoriz|sort|tag|grade|label|file|bucket|bracket|정리|판별|분별|분류 대기)[^\n]{0,10}?(?:사후|나중에|추후|뒤에|"
     r"후에|이후|afterwards?|later|after|following|pending|awaiting|대기|보류|유보)|(?:defer\w*|postpone\w*|delay\w*|put\s+off|pend\w*|hold\w*|shelv\w*|tabl\w*|stall\w*|미뤄|미룬|늦추|연기|보류|유보|대기)[^\n]{0,15}?(?:분류|재분류|classif|triage|categoriz|정리|판별|분별)|(?:pending|awaiting|until|till|while|대기 상태로|보류|유보)[^\n]{0,10}?(?:triage|classification|classif|categoriz|sort|분류|정리|판별|분별|분류 대기)|(?:enter\w*|join\w*|hit\w*|reach\w*|land\w*|drop\w*|slide\w*|fall\w*|착수|진입|투입|돌입)[^\n]{0,5}?(?:into\s+|in\s+|to\s+|at\s+|on\s+|for\s+)?\s*(?:the\s+|a\s+)?(?:T0|T1|T2|"
     r"low[- ]?tier|lower\s*T|junior|entry[- ]level|inexpensive|cheap\w*|주변|싼|저렴|하급|보조|부수)[^\n]{0,25}?(?:pending|awaiting|until|till|while|before|대기|보류|유보|사후|나중|later)[^\n]{0,10}?(?:triage|classification|classif|categoriz|sort|분류|정리|판별|분별|분류 대기))"),
    ("lower-t-then-classify",
     r"(?i)(?:T0|T1|T2|낮은 T|lower\s*T)[^\n]{0,15}?(?:실행|처리|배정|돌리|맡기|넘기|시작|보낸|보냄|run|start|assign|dispatch|handle|processing|work)[^\n]{0,25}?(?:사후|나중에|추후|뒤에|후에|이후|afterwards?|later|after|following)[^\n]{0,15}?(?:애매|모호|경계|분류|classif|ambiguous|unclear|uncertain|boundary|triage|sort|categoriz|정리)|(?:T0|T1|T2|lower\s*T)[^\n]{0,15}?(?:processing|work|execution|run|start|시작|실행|처리|돌리|맡기|배정|넘기|보낸|보냄|assign|dispatch|"
     r"handle)[^\n]{0,25}?(?:before|prior|ahead|전에|앞서|먼저)[^\n]{0,15}?(?:uncertainty|ambiguity|boundary|classification|scope|애매|모호|경계|분류|triage|sort|categoriz|정리)[^\n]{0,15}?(?:resolved|decided|determined|settled|classified|정해|분류|해결|postponed|deferred|delayed|미뤄)|(?:run|start|begin|assign|dispatch|handle|실행|처리|배정|돌리|맡기|넘기|시작)[^\n]{0,10}?(?:at|as|to|into|on)\s*(?:T0|T1|T2|lower\s*T)[^\n]{0,20}?(?:before|prior|ahead|전에|앞서|먼저)[^\n]{0,10}?(?:triage|classification|"
     r"classif|sort|categoriz|분류|정리)|(?:T0|T1|T2|lower\s*T)[^\n]{0,15}?(?:execution|work|run|실행|처리)[^\n]{0,15}?(?:first|먼저|우선)[^\n]{0,20}?(?:triage|classification|classif|sort|categoriz|분류|정리)[^\n]{0,15}?(?:postponed|deferred|delayed|later|나중|미뤄)|(?:classif\w*|triage|sort\w*|categoriz|분류|정리)[^\n]{0,30}?(?:after|following|once|post[- ]?|후에|뒤에|이후|나중)[^\n]{0,20}?(?:assign\w*|rout\w*|send|put|place|slot|queu\w*|enqueu\w*|dispatch\w*|hand\w*|delegat\w*|push|drop|dump|mov\w*|shift|park|feed|"
     r"throw|shelv\w*)[^\n]{0,15}?(?:at|as|to|into|on|in|for|onto)?\s*(?:the\s+|a\s+)?(?:T0|T1|T2|tier[ -]?(?:zero|one|two|three|[0-3])|lower\s*T|low[- ]?tier|낮은\s*T|junior|entry[- ]level|inexpensive|low[- ]cost|저급|하급|싼|저렴|보조|부수)|(?:assign\w*|rout\w*|send|put|place|slot|queu\w*|enqueu\w*|dispatch\w*|delegat\w*|shelv\w*|park)[^\n]{0,16}?(?:at|as|to|into|on|in|for|onto)?\s*(?:the\s+|a\s+)?(?:T0|T1|T2|tier[ -]?(?:zero|one|two|three|[0-3])|lower\s*T|low[- ]?tier|low[- ]cost|junior|entry[- ]level|inexpensive|낮은\s*T|저급|하급|싼|저렴|"
     r"보조|부수)[^\n]{0,15}?(?:before|prior|ahead|전에|앞서|먼저)[^\n]{0,10}?(?:triage|classification|classif|sort\w*|categoriz|분류|정리|판별|분별)|(?:begin\w*|start\w*|run\w*|assign\w*|dispatch\w*|enter\w*|work\w*|do\w*|proceed\w*|continu\w*|commence\w*|embark\w*|착수|진입|투입|돌입|시작|개시)[^\n]{0,15}?(?:the\s+|a\s+)?(?:T0|T1|T2|tier[ -]?(?:zero|one|two|three|[0-3])|L[0-3]\b|level\s*(?:one|two|[0-3])|band\s*(?:[IVX]+|[0-9])|lower\s*T|low[- ]?tier|저급|하급|싼|저렴)[^\n]{0,25}?(?:first|먼저|"
     r"우선)[^\n]{0,20}?(?:classif|triage|sort|categoriz|decide|determine|분류|정리|판정|결정|분별)[^\n]{0,30}?(?:after|later|post|following|subsequent|뒤|후|이후|사후|나중|추후)"),

    ("core-class-lower-t",
     r"(?i)(?:안전 DB|안전 제약|에러 경로|에러 처리|예외 경계|lock[-/\s](?:and\s+)?transaction|상태/DB/예외 경계|가드 배선|가드 인자|가드 호출|가드 인수|가드 매개|가드 파라미터|가드 순서|가드 호출부|가드 동작|가드 로직|guard\s+(?:wiring|call|arg|param\w*|order|sequenc\w*|invocation\w*|config\w*|setting\w*|behaviou?r|hook\w*|check\w*|logic|code|path|site|policy|rule|chain|set)\w*|safety[-\s]db|safety[-\s]constraint|safety[-\s]invariant|database\s+constraints?|db\s+constraints?|데이터베이스\s*제약|invariant|order[-\s]integrity|integrity|정합|무결성|accounting|ledger|"
     r"balance|원장|장부|core\s+safety|error[-\s]path|error[-\s]handling|error[-\s]recovery|exception[-\s]boundary|exception[-\s]propagat\w*|exception[-\s]flow|exception[-\s]recovery|failure[-\s]recovery|failure[-\s]path|failure[-\s]handling|recovery|복구|rollback|롤백|return[-\s](?:check|value|valid\w*|code)|exit[-\s]code|status[-\s]check|반환값|리턴|종료\s*코드|transaction|tx\b|lock(?:s|ing)?\b|mutex|semaphore|critical[-\s]section|isolation[-\s]level|트랜잭션|락|잠금|임계|크리티컬|atomic|원자|persist\w*[-\s]?(?:state|data)|state[-\s]transition|transition\b|seam|이음|경계\s*심|영속|저장\s*경계|"
     r"safe\s+accounting|transaction\s+lifetime|lock/tx|lock-tx|state[-/\s]boundary|db[-/\s]boundary|state[-/\s]exception|가드 설정|state/db|authorization[-\s]gate|access[-\s]control|authorization|authenticat\w*|permission[-\s]boundary|auth[-\s]boundary|authz|authn|인가|권한\s*경계|접근\s*제어|invocation|invok\w+|호출\s*인자|retry|retr\w+|재시도|failed\s+(?:write|persist|commit|save)|write\s+failure|failed\s+writes?|쓰기\s*실패|unlock|un-?lock|해제|compensation|post[-\s]?write|보상|schema|UNIQUE|CHECK\s+constraint|safety[-\s]schema|스키마|semantics?|commit/rollback|"
     r"hold\s+duration|open[-\s]to[-\s]commit|lease[-\s]release|lock\s*release|lease\s+release|idempotenc\w*|serializab\w*|conflict[-\s]resolution|two[-\s]phase|2pc|prepare[-\s]commit|trigger|privileges?|callback|release\s*ordering|casual\s+maintenance|dependency[-\s]injection|injection|wiring)[^\n]{0,45}?(?:(?:T0|T1|T2|낮은 T|lower\s*T|low[- ]?tier|주변|periph\w*|cheap\w*|cosmetic|janitorial|routine|mechanical|junior|entry[- ]level|inexpensive|low[- ]cost|low[- ]skill|staff|personnel|grunt|scut|busywork|chore|auxiliary|secondary|clerical|housekeeping|apprenticeship|apprentices?|trainee|"
     r"clerk|caretaker|custodian|janitor|temp\w*|casual|part[-\s]?time|rotating|ad[-\s]?hoc|temporary|contract|support|vendor|freelance|crew|external|outside|third[- ]?party|consult\w*|helper|assistant|bargain|frugal|thrifty|discount|budget|low[- ]paid|cut[- ]?rate|사무|심부름|서류|보조|부수|잡무|단순|청소|싼|저렴|하급|초급|주변부|가장자리)[^\n]{0,15}?(?:주변|배정|실행|처리|돌리|맡기|떼|취급|간주|본다|여긴다|핫픽스|작업|분류|넘긴다|보낸다|업무|워커|레인|"
     r"peripheral|worker|assign|"
     r"task|work\b|run|hotfix|handle|treat|mark|glue|pool|tier|lane\b|queue|track\b|stream|maintenance|cleanup|cosmetic|mechanical|janitorial|junior|entry[- ]level|inexpensive|low[- ]cost|low[- ]skill|staff|personnel|interns?|apprentices?|trainee|rookie|novice|chore|grunt|scut|busywork|routine|upkeep|misc|leftover|adjust\w*|tweak\w*|alter\w*|delegate\w*|offload|outsource|farm\w*|분담|하청|외주|잡무|청소|초급|주니어|concern|matter|issue|item|detail|aspect|topic|question|material|stuff|fodder|contractor|freelancer|outsourc\w*|관심|사안|항목|change|make|edit|modify|own|take|do|developer|programmer|coder|workforce|staffer)|(?:assign\w*|rout\w*|send|dispatch\w*|delegat\w*|hand\w*|put|treat|mark|go\w*|move|dump|lump|offload|outsource|farm\w*|belong\w*|fall\w*|land\w*|adjust\w*|tweak\w*|alter\w*|"
     r"맡긴다|보낸다|넘긴다|배정|돌리|위임)[^\n]{0,10}?(?:at|as|to|into|on|in|by|with|for|under|에게|에|로)\s*(?:the\s+|a\s+|an\s+)?(?:T0|T1|T2|낮은\s*T|lower\s*T|low[- ]?tier|주변|periph\w*|cheap|pool|tier|glue|junior|entry[- ]level|inexpensive|low[- ]cost|low[- ]skill|staff|personnel|interns?|apprentices?|trainee|rookie|novice|temp\w*|casual|part[-\s]?time|contract|support|lane\b|queue|track\b|stream|band|maintenance|cosmetic|routine|janitorial|chore|cleanup|clerical|housekeeping|주니어|초급|잡무|청소|보조|부수|저렴|싼|하급|가벼운|경량|vendor|freelance|crew|external|outside|third[- ]?party|consult\w*|helper|assistant|bargain|frugal|thrifty|discount|budget|low[- ]paid|cut[- ]?rate|developer|programmer|coder|workforce|staffer)|(?:is|are|be|remains?|stays?|counts?\s+as|qualif\w*\s+as|classified\s+as|"
     r"regarded\s+as|consider\w*|treated\s+as|deemed|label\w*\s+as|tagged\s+as|filed\s+as|booked\s+as|logged\s+as|fits?|suits?|belongs?|goes|appropriate|suitable|proper|fitting|ideal|natural|acceptable|adequate|reasonable|간주|취급|여긴다?|본다)[^\n]{0,10}?(?:a\s+|an\s+|the\s+|just\s+|mere\w*\s+)?(?:periph\w*|cheap\w*|cosmetic|janitorial|routine|mechanical|junior|entry[- ]level|inexpensive|low[- ]cost|low[- ]skill|clerical|housekeeping|apprenticeship|apprentice|caretaker|custodial|custodian|temp\w*|casual|part[-\s]?time|rotating|ad[-\s]?hoc|temporary|contract|contractor|freelancer|outsourc\w*|support|busywork|chore|grunt|scut|auxiliary|secondary|misc|maintenance|cleanup|menial|drudge|grunt|보조|부수|잡무|단순|청소|싼|저렴|하급|초급|주변|가벼운|경량|사무|심부름|vendor|freelance|crew|external|outside|third[- ]?party|consult\w*|helper|assistant|bargain|frugal|thrifty|discount|budget|low[- ]paid|cut[- ]?rate)\b)"),
    ("lower-t-first-core",
     r"(?i)(?:T0|T1|T2|낮은 T|lower\s*T|lower[- ]tier|low[- ]?tier|주변|periph\w*|cheap\w*|low[- ]cost|저비용|junior|entry[- ]level|inexpensive|low[- ]skill|staff|personnel|intern\b|apprentice|rookie|novice|cosmetic|janitorial|routine|mechanical|auxiliary|secondary|보조|부수|잡무|단순|싼|저렴|하급|초급|주니어|가벼운|경량)[^\n]{0,12}?(?:워커|worker|모델|작업|task|tier|pool|owner|work\b|lane\b|queue|track\b|stream|assign\w*|send|route|dispatch\w*|hand\w*|giv\w*|put|own\w*|take\w*|handle\w*|do\w*|make|change\w*|edit\w*|modify\w*|adjust\w*|tweak\w*|alter\w*|delegate\w*|offload|outsource|farm\w*|chore|maintenance|"
     r"cleanup|cosmetic|misc)[^\n]{0,25}?(?:안전 DB|안전 제약|에러 경로|에러 처리|예외 경계|lock[-/\s]|lock\b|가드 배선|가드 인자|가드 호출|가드 인수|가드 매개|가드 파라미터|가드 순서|가드 호출부|가드 동작|가드 로직|guard|core|핵심|상태/DB|safety|error|exception|boundary|wiring|constraint|invariant|integrity|accounting|ledger|transaction|recovery|transition|seam|persist\w*|rollback|atomic|argument|parameter|invocation|sequenc|database|return[-\s]|반환값|원장|장부|무결성|정합|복구|롤백|트랜잭션|잠금|이음|영속)"),
    ("one-line-guard-periph",
     r"(?i)(?:호출 한 줄|한 줄 호출|one[- ]line|single[- ]line)[^\n]{0,30}?(?:T0|T1|T2|낮은 T|주변|periph\w*|cheap\w*|lower)"),
    ("periph-core-merge-anyway",
     r"(?:주변 PR|주변 작업)[^\n]{0,30}?(?:핵심|core|가드|안전)[^\n]{0,30}?(?:그대로|낮은 T|T0|T1|T2)[^\n]{0,15}?(?:머지|유지|통과|진행|실행|둔다|두고|넘긴다)"),
    ("periph-core-no-reclassify",
     r"(?i)(?:주변 PR|주변 작업|주변\s*(?:diff|변경|패치)|peripheral\s+(?:PR|work|change|patch|diff)|(?:cosmetic\w*|view|display|surface|render\w*|ui|screen|layout|typography|visual|read[-\s]?only|readonly|output|조회[-\s]?전용|읽기)[-\s]+(?:only[-\s]+)?(?:PR|patch|work|change|diff|edit|job|task|fix|output))[^\n]{0,30}?(?:핵심|core|가드|안전|guard|seam|invariant|integrity|constraint|boundary|permission|authoriz|ledger|touch\w*|건드리|건드려|slip\w*|sneak\w*|leak\w*|creep\w*|affect\w*|hit|contain\w*|includ\w*|incorporat\w*|carries|holds|has|involv\w*|implicat\w*|drift|cross\w*|span\w*|acquir\w*|gain\w*|absorb\w*|enter\w*|"
     r"reach\w*|accumulat\w*|carr\w+|transaction|state|ledger)[^\n]{0,30}?(?:재분류하지|재분류\s*없|안\s*재분류|재분류[^\n]{0,3}?않|not\s+be\s+reclassif|remain\w*[^\n]{0,10}?peripheral|stay\w*[^\n]{0,10}?peripheral|no[^\n]{0,5}?(?:reclassif|re-?scope|re-?bucket|re-?tier|re-?slice|re-?route|re-?grade|re-?rate|re-?class|re-?file|re-?tag|re-?label|re-?band|re-?categoriz|re-?sort|promot\w*|elevat\w*|"
     r"escalat\w*|upgrad\w*|bump|raise)|without[^\n]{0,10}?(?:reclassif|re-?scope|promot\w*|escalat\w*|upgrad\w*)|exempt\w*[^\n]{0,10}?(?:from\s+)?(?:reclassif|promot\w*|escalat\w*)|(?:retain|keep|stay|remain|hold|leave|let|maintain|stick\w*|sit|cling|rest|persist|linger|유지|머물|남|그대로|두고|둔다)[^\n]{0,15}?(?:original|same|current|lower|assigned|initial|first|existing|starting|opening|submitted|given|customary|usual|traditional|its|their|기존|처음)[^\n]{0,20}?(?:tier|grade|classif|T0|T1|T2|band|level|class|bucket|bracket|categor\w*|label|tag|severit\w*|criticalit\w*|priorit\w*|lane|track|queue|route|channel|레인|등급|클래스|레벨|버킷|라벨)|(?:leave|let|keep|hold|"
     r"maintain)[^\n]{0,10}?(?:its|their|the|own)[^\n]{0,15}?(?:classif\w*|tier|grade|band|bucket|level|label|tag|severit\w*|분류|등급)[^\n]{0,12}?(?:untouched|unchanged|unmodified|unaltered|intact|as[-\s]is|그대로|유지)|(?:its|their|the)\s+(?:original|same|starting|initial|first|existing|assigned|current|ordinary|normal|usual|기존|처음)[^\n]{0,20}?(?:tier|grade|classif|category|band|bucket|label|tag|routing|lane|severit\w*|분류|등급)[^\n]{0,12}?(?:remains?|stays?|keeps?|persists?|holds?|stands?|endures?|survives?|continues?|유지|"
     r"그대로)|(?:continues?|proceeds?|stays?|keeps?|remains?|follows?)[^\n]{0,10}?(?:through|in|on|within|along)[^\n]{0,15}?(?:its|their|the|ordinary|normal|usual|same|existing|opening|original|submitted|assigned|기존)[^\n]{0,20}?(?:lane|track|queue|path|channel|route|레인|경로))|(?:핵심|core|안전|가드)[^\n]{0,20}?(?:slip\w*|sneak\w*|leak\w*|creep\w*|touch\w*|end\w*|land\w*|enter\w*)[^\n]{0,15}?(?:into|in|to|onto|"
     r"within)[^\n]{0,15}?(?:peripheral\s+(?:PR|work|change|patch)|주변\s*(?:PR|작업))[^\n]{0,25}?(?:retain|keep|stay|remain|hold|no|without|skip|not|exempt)[^\n]{0,15}?(?:original\s+|same\s+|assigned\s+)?(?:tier|grade|reclassif)"),
]

# Required rows against the whole spawn-worker file (outside the marked
# block): the §2-2 weekly-pool footnote must carry the carve-out pointer.
FILE_ROWS = [
    ("weekly-pool-111-carveout",
     r"단일 라운드 한정은?[^\n]{0,30}?최종 통합[^\n]{0,10}?T3 tester[^\n]{0,20}?적용하지 않는다"),
]

# Sentences that must exist ONLY inside the spawn block — a second copy in a
# pointer file is a leak, not a reference. Every fragment is §2-6-specific and
# absent from the pointer files today (불변식 표·NEEDS_CLASSIFICATION·합집합·
# 라운드 캡 are legitimate summary labels in the pointers and stay unpinned).
RULE_PHRASES_NOT_COPIED = [
    "핵심 책임자가",
    "호출 한 줄이어도",
    "라운드 상한을 따로 줄이지 않는다",
    "(UI·CLI·테스트 등)가 아니라",
    "더 저렴한 적격 모델 가능",
    "순수 렌더링",
    "분리 조건: 입/출력",
    "안전 결정·권한·상태·증거에 영향 없음",
    "허용 파일/심볼",
    "독립 인수·되돌리기",
    "lock/transaction 수명",
    "상태/DB/예외 경계",
    "T3 로 재분류한다",
    "T3 재분류",
    "핵심을 건드리면",
    "최종 통합 tester 가 될 수 없다",
    "실패 계약 고정",
    "안전 DB 제약",
    "에러 경로",
    "검증된 읽기",
    "주간 풀 단일",
    "일반 라운드 캡이 필요",
    "미등록 변경은 침범",
    "불변식 표를 먼저",
    "주문·브로커",
    "가드 배선",
    "호출 한 줄",
    "더 저렴한 적격",
    "invariant",
    "file type",
    "ambiguous",
    "unclear",
    "uncertain",
    "peripheral",
    "reclassif",
    "classified",
    "guard wiring",
    "safety DB",
    "error path",
    "error-path",
    "lock/transaction",
    "state/DB/exception",
    "state/db",
    "touches core",
    "touching core",
    "fixed input/output",
    "failure contract",
    "no safety impact",
    "pure rendering",
    "read-only CLI",
    "API glue",
    "guard argument",
    "exception propagation",
    "core owner",
    "core-owner",
    "await",
    "rendering",
    "read-only",
    "cheaper model",
    "independent acceptance",
    "revertible",
    "failure contracts",
    "observable result",
    "enforcement location",
    "reversible",
    "low-tier",
    "low-cost",
    "view-only",
    "display-only",
    "presentational",
    "zero safety",
    "safety-neutral",
    "cheap worker",
    "low-cost worker",
    "cheap pool",
    "eligib",
    "allowed only",
    "fixed contracts",
    "no effect on",
    "no impact",
    "plumbing",
    "boilerplate",
    "cosmetic",
    "surface work",
    "guard logic",
    "guard code",
    "visual output",
    "screen formatting",
    "entry-level",
    "lower-cost",
    "inexpensive",
    "junior",
    "read commands",
    "independently checked",
    "fixed IO",
    "no risk",
    "presentation",
    "suitable for",
    "staff",
    "personnel",
    "delegated to",
    "delegable",
    "low-skill",
    "routine work",
    "routine cleanup",
    "window dressing",
    "scaffolding",
    "shallow",
    "trivial",
    "lightweight",
    "grunt",
    "scut",
    "busywork",
    "chore",
    "janitorial",
    "mechanical",
    "low-risk",
    "risk-free",
    "zero risk",
    "harmless",
    "benign",
    "safe to delegate",
    "safe to offload",
    "offloadable",
    "farmed out",
    "non-core",
    "edge work",
    "edge case",
    "side work",
    "misc work",
    "위임",
    "외주",
    "싼 모델",
    "저렴한 모델",
    "하급 모델",
    "주니어",
    "초급",
    "경량 작업",
    "가벼운 작업",
    "화면 출력",
    "시각 출력",
    "읽기 명령",
    "고정 입출력",
    "입출력 고정",
    "정해진 입출력",
    "실패 동작 고정",
    "위험 변화 없음",
    "안전 영향 없",
    "보조 작업",
    "잡무",
    "단순 작업",
    "주변 작업",
    "주변부",
    "가장자리",
    "표면 작업",
    "미화",
    "청소 작업",
    "layout",
    "typography",
    "budget pool",
    "request/response",
    "adapter",
    "outcomes are fixed",
    "delegated when",
    "qualify for the budget",
    "stable request",
    "조회 전용",
    "명령행",
    "저비용 모델",
    "업무로 뗄",
    "뗄 수",
    "저비용 모델 업무",
    "page composition",
    "composition belongs",
    "rotating assistants",
    "static template",
    "templates",
    "part-time",
    "editors",
    "접착",
    "고정 경로",
    "보조 인력",
    "계약이 변하지",
    "정렬된 조회",
    "CLI 표현",
    "싼 급",
    "DTO",
    "mapping",
    "lower-paid",
    "modestly",
    "priced assistant",
    "saved records",
    "untouched",
    "화면 모양",
    "비용이 낮은",
    "작업자",
    "손대지",
    "분리할",
    "visual adjustment",
    "adjustments",
    "preserve behavior",
    "affordable",
    "appropriate for",
    "display formatting",
    "ornamental",
    "thrifty",
    "helper",
    "helpers",
    "stored outcomes",
    "outcomes do not change",
    "outcomes stay",
    "view updates",
    "frugal",
    "bargain",
    "stay put",
    "stays fixed",
    "stay fixed",
    "thrifty helper",
    "frugal helper",
    "bargain help",
    "cheap help",
    "modest help",
    "꾸밈",
    "꾸미",
    "자동화",
    "인력",
    "저렴한",
    "넘겨",
    "권한 판단",
    "판단과 기록",
    "기록은 그대로",
    "기록 유지",
    "권한 유지",
    "records untouched",
    "permissions untouched",
    "untouched records",
]

PINNED_SKILLS = (
    "spawn-worker/SKILL.md",
    "builder/SKILL.md",
    "director/SKILL.md",
    "checker/SKILL.md",
)

# Every entry currently pinned in local_sources must stay present: removing
# a pin hides drift regardless of whether the file was task-modified (R2/R6
# testers: spawn pin removal, bin/wrk removal, and bin/wrk corruption all
# passed silently).
REQUIRED_PINS = (
    ".github/workflows/ci.yml",
    "bin/wrk",
    "checker/SKILL.md",
    "director/SKILL.md",
    "spawn-worker/SKILL.md",
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
            assert phrase.casefold() not in text.casefold(), (
                f"{name}: rule sentence copied out of the canonical block: {phrase!r}"
            )
    # The gate policy pins the skill files: a re-pinned hash must match the
    # edited bytes, and an un-pinned file must not have drifted either way.
    # Duplicate keys — literal or JSON-escaped equivalents (R3/R4 tester:
    # stale-first/correct-last pin, "spawn-worker\/SKILL.md", and a second
    # "\u006cocal_sources" map) smuggle stale pins past last-key-wins parsers
    # and literal-text scans. object_pairs_hook compares DECODED keys.
    def _no_dup_keys(pairs):
        seen = {}
        for key, value in pairs:
            assert key not in seen, f"gate_policy duplicate decoded key {key!r}"
            seen[key] = value
        return seen

    policy = json.loads(d["policy"], object_pairs_hook=_no_dup_keys)
    pinned = policy["local_sources"]
    # Malformed shapes must fail by assertion, not TypeError (R5 tester:
    # numeric pin value and numeric local_sources crashed outside the
    # assertion-RED path).
    assert isinstance(pinned, dict), "gate_policy local_sources must be an object"
    for rel in REQUIRED_PINS:
        assert rel in pinned, (
            f"gate_policy local_sources must pin {rel} "
            "(task-modified file; a removed pin hides drift)"
        )
    # Verify EVERY pinned entry, not a curated subset: an entry the contract
    # never checks can be corrupted or removed without detection (R6 tester).
    for rel in sorted(pinned):
        val = pinned[rel]
        rel_path = Path(rel)
        assert not rel_path.is_absolute() and ".." not in rel_path.parts, (
            f"gate_policy local_sources path must stay repo-relative: {rel!r}"
        )
        # The RESOLVED path must stay inside the repo: a relative symlink
        # (file or parent dir) pointing outside escapes a lexical check
        # while still hashing a real file's bytes (R13 tester).
        resolved = (root / rel).resolve()
        try:
            resolved.relative_to(root.resolve())
        except ValueError:
            raise AssertionError(
                f"gate_policy local_sources path resolves outside repo: {rel}"
            )
        assert (root / rel).is_file(), (
            f"gate_policy local_sources path missing from repo: {rel}"
        )
        actual = hashlib.sha256((root / rel).read_bytes()).hexdigest()
        assert isinstance(val, str) and val == actual, (
            f"gate_policy local_sources pin for {rel} is stale or malformed "
            f"(pinned {str(val)[:12]}… actual {actual[:12]}…)"
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
# R2 tester findings verbatim — alternate wording for the same attack classes.
mutants["spawn-integration-one-pass-alt"] = append(
    "spawn", "최종 통합 tester 는 한 차례만 검증하며 수정된 head 는 재검증하지 않는다."
)
mutants["spawn-ambiguous-t1-after"] = append(
    "spawn", "경계가 애매한 작업은 먼저 T1 로 실행하고 사후에 분류한다."
)
mutants["spawn-one-line-guard-t1"] = append(
    "spawn", "호출 한 줄 가드 배선은 T1 의 주변 작업으로 배정할 수 있다."
)
# Same classes again: reclassification bypass and a generic core class.
mutants["spawn-periph-core-merge"] = append(
    "spawn", "주변 PR 이 핵심을 건드려도 그대로 머지한다."
)
mutants["spawn-safety-db-t1"] = append(
    "spawn", "안전 DB 제약 변경은 T1 주변 작업으로 배정한다."
)
# A required pin deleted outright must fail closed, not be skipped.
_pinless = dict(docs)
_pol = json.loads(_pinless["policy"])
del _pol["local_sources"]["spawn-worker/SKILL.md"]
_pinless["policy"] = json.dumps(_pol, ensure_ascii=False, indent=2)
mutants["policy-spawn-pin-removed"] = _pinless
# R3 tester finding: a duplicate key — stale value first, correct last —
# parses correct under last-key-wins but stale under first-key-wins.
_dupkey = dict(docs)
_dupkey["policy"] = _dupkey["policy"].replace(
    '"spawn-worker/SKILL.md": "',
    '"spawn-worker/SKILL.md": "' + "0" * 64 + '",\n    "spawn-worker/SKILL.md": "',
    1,
)
mutants["policy-spawn-pin-duplicated"] = _dupkey
# A second local_sources object carrying a stale mini-map.
_dupobj = dict(docs)
_dupobj["policy"] = _dupobj["policy"].replace(
    '"profiles": {',
    '"local_sources": {"spawn-worker/SKILL.md": "' + "0" * 64 + '"},\n  "profiles": {',
    1,
)
mutants["policy-dup-local-sources"] = _dupobj
# R4 tester findings verbatim: a corrupted CI pin (required but not
# hash-verified) and JSON-escaped duplicate keys that beat literal scans.
_cipin = dict(docs)
_cipin["policy"] = _cipin["policy"].replace(
    '".github/workflows/ci.yml": "'
    + docs["policy"].split('".github/workflows/ci.yml": "', 1)[1].split('"', 1)[0],
    '".github/workflows/ci.yml": "' + "0" * 64,
    1,
)
mutants["policy-ci-pin-corrupted"] = _cipin
_esckey = dict(docs)
_esckey["policy"] = _esckey["policy"].replace(
    '"spawn-worker/SKILL.md": "',
    '"spawn-worker\\/SKILL.md": "' + "0" * 64 + '",\n    "spawn-worker/SKILL.md": "',
    1,
)
mutants["policy-spawn-pin-escaped-dup"] = _esckey
_escmap = dict(docs)
_escmap["policy"] = _escmap["policy"].replace(
    '"local_sources": {',
    '"\\u006cocal_sources": {"spawn-worker/SKILL.md": "' + "0" * 64 + '"},\n  "local_sources": {',
    1,
)
mutants["policy-escaped-local-sources"] = _escmap
# Rule sentences copied into pointer files beyond the three old phrases.
mutants["builder-periph-rule-copied"] = append(
    "builder",
    "주변 (더 저렴한 적격 모델 가능): 순수 렌더링 · 검증된 읽기 API 의 CLI 출력(조회·정렬·출력) · 안전 경로와 무관한 고정 API 연결. 분리 조건: 입/출력·실패 계약 고정 · 안전 결정·권한·상태·증거에 영향 없음 · 허용 파일/심볼·금지 변경 열거 가능 · 독립 인수·되돌리기 가능.",
)
mutants["director-periph-condition-copied"] = append(
    "director", "안전 결정·권한·상태·증거에 영향 없음."
)
mutants["director-core-enum-copied"] = append(
    "director", "lock/transaction 수명 · 상태/DB/예외 경계."
)
mutants["builder-reclassify-copied"] = append(
    "builder", "주변 PR 이 핵심을 건드리면 그 PR 은 T3 로 재분류한다."
)
# R5 tester findings verbatim — further alternate wording, partial copies,
# and numeric pin shapes that must fail by assertion (not TypeError).
mutants["spawn-integration-look-once"] = append(
    "spawn", "최종 통합 tester 는 한 번만 보고 끝낸다."
)
mutants["spawn-no-reverify-needed"] = append(
    "spawn", "수정된 head 는 재검증할 필요가 없다."
)
mutants["spawn-vague-boundary-t1"] = append(
    "spawn", "모호한 경계는 T1 에 먼저 배정하고 나중에 분류한다."
)
mutants["spawn-guard-arg-t1-regard"] = append(
    "spawn", "가드 인자 변경은 T1 작업으로 취급할 수 있다."
)
mutants["spawn-safety-db-t1-hotfix"] = append(
    "spawn", "안전 DB 제약 변경은 T1 핫픽스다."
)
mutants["builder-contract-frag-copied"] = append(
    "builder", "입/출력·실패 계약 고정."
)
mutants["director-core-partial-copied"] = append(
    "director", "안전 DB 제약 · 에러 경로."
)
mutants["builder-reclassify-partial"] = append(
    "builder", "주변 PR 이 핵심을 건드리면 T3 재분류."
)
_numpin = dict(docs)
_np = json.loads(_numpin["policy"])
_np["local_sources"]["spawn-worker/SKILL.md"] = 17
_numpin["policy"] = json.dumps(_np, ensure_ascii=False, indent=2)
mutants["policy-spawn-pin-number"] = _numpin
_nummap = dict(docs)
_nm = json.loads(_nummap["policy"])
_nm["local_sources"] = 17
_nummap["policy"] = json.dumps(_nm, ensure_ascii=False, indent=2)
mutants["policy-local-sources-number"] = _nummap
# English forms of the same attack classes.
mutants["spawn-integration-single-pass-en"] = append(
    "spawn", "The final integration tester may use a single pass."
)
mutants["spawn-ambiguous-t1-en"] = append(
    "spawn", "Ambiguous boundary work can start at T1 and be classified later."
)
# R6 tester findings verbatim — clause-order and synonym variants, English
# rule copies, and pin removal/corruption outside the required set.
mutants["spawn-one-look-then-integration"] = append(
    "spawn", "한 번만 보면 최종 통합 검증은 충분하다."
)
mutants["spawn-one-review-integration-en"] = append(
    "spawn", "Only one review is needed for the final integration."
)
mutants["spawn-one-pass-sufficient-en"] = append(
    "spawn", "One pass is sufficient to finish the final integration verification."
)
mutants["spawn-followup-check-skipped"] = append(
    "spawn", "수정 head 의 후속 확인은 생략한다."
)
mutants["spawn-no-second-verification-en"] = append(
    "spawn", "After the head changes, no second verification is necessary."
)
mutants["spawn-recheck-waived-en"] = append(
    "spawn", "Rechecking is waived on a patched head."
)
mutants["spawn-uncertain-t1-en"] = append(
    "spawn", "When the scope is uncertain, run it at T1 and classify afterwards."
)
mutants["spawn-boundary-undecided-t2-en"] = append(
    "spawn", "When the boundary cannot be decided, start at T2 and classify after the run."
)
mutants["spawn-t1-then-classify"] = append(
    "spawn", "T1 에서 먼저 실행하고, 나중에 경계가 모호했는지 분류한다."
)
mutants["spawn-guard-wiring-periph-biz"] = append(
    "spawn", "가드 배선은 주변 업무로 처리한다."
)
mutants["spawn-one-line-guard-cheap-en"] = append(
    "spawn", "A one-line guard call is a cheap peripheral change."
)
mutants["spawn-t1-worker-guard-arg"] = append(
    "spawn", "T1 워커에게 가드 인자 변경을 맡긴다."
)
mutants["spawn-safety-db-periph-task"] = append(
    "spawn", "안전 DB 제약은 주변 작업이다."
)
mutants["spawn-error-path-cheaper-en"] = append(
    "spawn", "Error-path changes can go to a cheaper peripheral worker."
)
mutants["spawn-lock-tx-assigned-t1-en"] = append(
    "spawn", "Lock and transaction lifetime work is assigned to T1."
)
mutants["spawn-periph-touch-no-reclassify"] = append(
    "spawn", "주변 PR 이 핵심을 건드려도 T3 로 재분류하지 않는다."
)
mutants["spawn-periph-remains-en"] = append(
    "spawn", "A peripheral PR touching core remains peripheral."
)
mutants["builder-core-enum-copied-en"] = append(
    "builder", "Core work includes guard wiring, safety DB constraints, error paths, lock/transaction lifetime, and the state/DB/exception boundary."
)
mutants["director-periph-rule-copied-en"] = append(
    "director", "Peripheral work is allowed only with fixed input/output and failure contracts and no safety impact."
)
mutants["builder-reclassify-copied-en"] = append(
    "builder", "A peripheral PR that touches core must be reclassified as T3."
)
_bin_removed = dict(docs)
_br = json.loads(_bin_removed["policy"])
del _br["local_sources"]["bin/wrk"]
_bin_removed["policy"] = json.dumps(_br, ensure_ascii=False, indent=2)
mutants["policy-bin-wrk-removed"] = _bin_removed
_bin_zeroed = dict(docs)
_bz = json.loads(_bin_zeroed["policy"])
_bz["local_sources"]["bin/wrk"] = "0" * 64
_bin_zeroed["policy"] = json.dumps(_bz, ensure_ascii=False, indent=2)
mutants["policy-bin-wrk-zeroed"] = _bin_zeroed
_checker_removed = dict(docs)
_cr = json.loads(_checker_removed["policy"])
del _cr["local_sources"]["checker/SKILL.md"]
_checker_removed["policy"] = json.dumps(_cr, ensure_ascii=False, indent=2)
mutants["policy-checker-removed"] = _checker_removed
# R7 tester findings verbatim — optional-middle once-forms, second-look/
# scrutiny negations, undetermined/unknown prefixes, dest-first core routing,
# exempt/retain reclassification, and an English pointer fragment.
mutants["spawn-integration-one-look-done-en"] = append(
    "spawn", "Final integration: one look and done."
)
mutants["spawn-integration-needs-one-review-en"] = append(
    "spawn", "A final integration only needs one review."
)
mutants["spawn-integration-stop-single-en"] = append(
    "spawn", "Final integration may stop after a single verification."
)
mutants["spawn-no-second-look-head-en"] = append(
    "spawn", "There is no need for a second look at a modified head."
)
mutants["spawn-heads-no-scrutiny-en"] = append(
    "spawn", "Changed heads are accepted without further scrutiny."
)
mutants["spawn-undetermined-t1-en"] = append(
    "spawn", "Undetermined work may start at T1, with classification afterward."
)
mutants["spawn-boundary-unknown-t0-en"] = append(
    "spawn", "If the boundary is unknown, assign at T0 and classify later."
)
mutants["spawn-t2-before-resolved-en"] = append(
    "spawn", "T2 processing may start before the uncertainty is resolved."
)
mutants["spawn-periph-worker-owns-guard-en"] = append(
    "spawn", "A peripheral worker owns guard wiring changes."
)
mutants["spawn-cheap-tier-safety-db-en"] = append(
    "spawn", "The cheap tier can change safety DB constraints."
)
mutants["spawn-t1-exception-boundary-en"] = append(
    "spawn", "T1 may handle exception-boundary work."
)
mutants["spawn-lower-tier-lock-tx-en"] = append(
    "spawn", "Lower-tier owners will make changes to lock/transaction lifetime."
)
mutants["spawn-error-handling-glue-en"] = append(
    "spawn", "Error handling changes are peripheral glue."
)
mutants["spawn-core-safety-cheap-pool-en"] = append(
    "spawn", "Core safety constraints can go to the cheap pool."
)
mutants["spawn-periph-exempt-reclassify-en"] = append(
    "spawn", "A peripheral PR touching core is exempt from reclassification."
)
mutants["spawn-slip-retain-tier-en"] = append(
    "spawn", "When core changes slip into a peripheral PR, retain the original tier."
)
mutants["builder-core-detail-copied-en"] = append(
    "builder", "Guard argument order, await behavior, return checks, and exception propagation are core-owner work."
)
# Preemptive same-class variants — the lexical space around each attack
# class must be covered in-repo, not only the verbatim tester spellings.
mutants["spawn-integration-one-shot-en"] = append(
    "spawn", "The final integration uses a one-shot verification."
)
mutants["spawn-integration-tester-free-en"] = append(
    "spawn", "Final integration runs without an independent tester."
)
mutants["spawn-verdict-reuse-en"] = append(
    "spawn", "The previous verdict remains valid for the patched head."
)
mutants["spawn-vague-defer-classify-en"] = append(
    "spawn", "A vague boundary item can run at T1 and defer classification."
)
mutants["spawn-tx-lifetime-t2-en"] = append(
    "spawn", "Transaction lifetime edits are handled by a T2 worker."
)
mutants["spawn-state-boundary-cheap-en"] = append(
    "spawn", "State boundary checks can be done by the cheap tier."
)
mutants["spawn-exception-propagation-periph-en"] = append(
    "spawn", "Exception propagation tweaks belong in a peripheral task."
)
mutants["spawn-reexam-unneeded-en"] = append(
    "spawn", "Reexamination is unnecessary on the updated head."
)
mutants["spawn-no-third-review-en"] = append(
    "spawn", "Changed heads get merged with no third review."
)
mutants["builder-readonly-periph-copied-en"] = append(
    "builder", "Read-only CLI output and independent acceptance are peripheral."
)
mutants["director-revertible-copied-en"] = append(
    "director", "Revertible rendering slices may go to cheaper models."
)
_missing_path = dict(docs)
_mp = json.loads(_missing_path["policy"])
_mp["local_sources"]["bin/wrk2"] = _mp["local_sources"]["bin/wrk"]
_missing_path["policy"] = json.dumps(_mp, ensure_ascii=False, indent=2)
mutants["policy-pin-nonexistent-path"] = _missing_path
# R8 tester findings verbatim — glance/sign-off/final-pass nouns, optional
# and fresh-check negations, carries-through old reviews, questionable/
# unsettled + triage ordering, lane/maintenance/low-cost destinations,
# re-scope + initial-tier reclassification evasion.
mutants["spawn-one-glance-en"] = append(
    "spawn", "Final integration ends after one glance."
)
mutants["spawn-single-final-pass-en"] = append(
    "spawn", "The integration check is a single final pass."
)
mutants["spawn-one-signoff-en"] = append(
    "spawn", "A final integration needs just one independent sign-off."
)
mutants["spawn-old-pass-enough-en"] = append(
    "spawn", "The old PASS is enough after integration."
)
mutants["spawn-post-update-optional-en"] = append(
    "spawn", "Post-update verification is optional."
)
mutants["spawn-no-fresh-check-en"] = append(
    "spawn", "No fresh check is required for the patched head."
)
mutants["spawn-review-carries-en"] = append(
    "spawn", "After a head update, the previous review carries through."
)
mutants["spawn-questionable-t1-triage-en"] = append(
    "spawn", "Questionable boundary items may be run at T1 before triage."
)
mutants["spawn-t1-first-triage-postponed-en"] = append(
    "spawn", "T1 execution begins first; triage is postponed for unsettled work."
)
mutants["spawn-exception-flow-t1-lane-en"] = append(
    "spawn", "Exception flow belongs in the T1 lane."
)
mutants["spawn-return-checks-t1-en"] = append(
    "spawn", "Return checks are T1 maintenance."
)
mutants["spawn-lowcost-changes-guard-en"] = append(
    "spawn", "Peripheral low-cost work may change guard wiring."
)
mutants["spawn-guard-logic-no-rescope-en"] = append(
    "spawn", "A peripheral PR accidentally includes guard logic; no re-scope is needed."
)
mutants["spawn-retain-initial-t1-en"] = append(
    "spawn", "A peripheral PR contains core changes; retain the PR's initial T1 classification."
)
# R9 tester findings verbatim — inspection/scrutiny nouns, 결합/커밋 Korean
# forms, approval-in-force, need-no-renewed, pending-triage orderings,
# junior/entry-level/inexpensive/staff destinations, guard parameter/
# invocation/db-constraint/recovery/window/seam/return-value class names,
# original band retention, paraphrased pointer rules.
mutants["spawn-one-close-inspection-en"] = append(
    "spawn", "Final integration is signed off after one close inspection."
)
mutants["spawn-single-scrutiny-en"] = append(
    "spawn", "A single scrutiny suffices for final integration."
)
mutants["spawn-gyeolhap-once-ko"] = append(
    "spawn", "최종 결합 결과는 한 번 훑어보면 마친다."
)
mutants["spawn-prior-approval-force-en"] = append(
    "spawn", "After a patch, the prior approval remains in force."
)
mutants["spawn-new-commit-approval-ko"] = append(
    "spawn", "새 커밋은 기존 승인으로 갈음한다."
)
mutants["spawn-head-amendments-scrutiny-en"] = append(
    "spawn", "Head amendments need no renewed scrutiny."
)
mutants["spawn-unsettled-t0-pending-en"] = append(
    "spawn", "Unsettled items enter T0 pending triage."
)
mutants["spawn-gyeonggye-bulmyeong-t2-ko"] = append(
    "spawn", "경계 불명 작업은 T2 에서 분류 대기 상태로 착수한다."
)
mutants["spawn-uncertain-scope-low-tier-en"] = append(
    "spawn", "Items of uncertain scope may be handled in the low tier pending categorization."
)
mutants["spawn-guard-param-junior-en"] = append(
    "spawn", "Guard parameter order can go to the junior pool."
)
mutants["spawn-junior-adjust-guard-args-en"] = append(
    "spawn", "Junior workers may adjust a guard invocation's arguments."
)
mutants["spawn-db-constraints-periph-maint-en"] = append(
    "spawn", "Database constraints that preserve safe accounting are peripheral maintenance."
)
mutants["spawn-exception-recovery-t1-en"] = append(
    "spawn", "Exception recovery may be delegated to T1."
)
mutants["spawn-failure-recovery-cheap-en"] = append(
    "spawn", "Failure recovery policy goes to the cheap pool."
)
mutants["spawn-tx-window-periph-cleanup-en"] = append(
    "spawn", "The transaction window is peripheral cleanup."
)
mutants["spawn-lock-scope-cosmetic-en"] = append(
    "spawn", "Lock scope adjustments belong in cosmetic work."
)
mutants["spawn-persisted-state-seam-low-en"] = append(
    "spawn", "Persisted state and raised-exception seam work is assigned to low tier."
)
mutants["spawn-return-validation-lowcost-en"] = append(
    "spawn", "Return-value validation may be done by low-cost staff."
)
mutants["spawn-periph-patch-core-seam-band-en"] = append(
    "spawn", "A peripheral patch containing a core seam retains its original band."
)
mutants["builder-visual-output-en"] = append(
    "builder", "Visual output work is suitable for entry-level workers."
)
mutants["director-screen-formatting-en"] = append(
    "director", "Screen formatting can be assigned to a lower-cost model."
)
mutants["builder-read-commands-indep-en"] = append(
    "builder", "Read commands can be delegated to inexpensive models when their output is independently checked."
)
mutants["director-fixed-io-junior-en"] = append(
    "director", "Fixed IO and error behavior with no risk change make presentation edits suitable for junior models."
)
# Same-class preemptive variants for the next adversarial sweep.
mutants["spawn-one-inspection-needed-en"] = append(
    "spawn", "One inspection is all the integration needs."
)
mutants["spawn-merger-single-audit-en"] = append(
    "spawn", "The merger needs only a single audit."
)
mutants["spawn-head-panjeong-galeum-ko"] = append(
    "spawn", "수정된 head 는 기존 판정으로 갈음한다."
)
mutants["spawn-gyeonggye-misang-t1-ko"] = append(
    "spawn", "경계 미상 항목은 T1 로 투입하고 분류는 보류한다."
)
mutants["spawn-lock-ordering-cosmetic-en"] = append(
    "spawn", "Lock ordering is a cosmetic concern."
)
mutants["spawn-ledger-routine-cleanup-en"] = append(
    "spawn", "Ledger constraints can be handled as routine cleanup."
)
mutants["spawn-rollback-auxiliary-en"] = append(
    "spawn", "Rollback edges are auxiliary work."
)
mutants["spawn-periph-invariant-band-en"] = append(
    "spawn", "A peripheral diff with invariant drift may keep its band."
)
mutants["builder-cheap-staff-display-en"] = append(
    "builder", "Cheap staff may handle display slices."
)
mutants["director-formatting-junior-en"] = append(
    "director", "Formatting output is junior work."
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
# R10 tester findings verbatim — numeric caps, verdict inheritance,
# adjudication/TBD ambiguity, tier-spelled routing, junior/maintenance
# class words, cosmetics/view reclassification, pointer paraphrases.
mutants["spawn-integration-two-pass-cap-en"] = append(
    "spawn", "The final integration review is capped at 2 passes."
)
mutants["spawn-integration-two-times-cap-ko"] = append(
    "spawn", "최종 통합 검증 상한은 2회로 둔다."
)
mutants["spawn-squash-signoff-substitutes-en"] = append(
    "spawn", "After a squash, the previous sign-off substitutes for reviewing the merged head."
)
mutants["spawn-amended-commits-inherit-en"] = append(
    "spawn", "Amended commits inherit the parent revision's verification."
)
mutants["spawn-unadjudicated-t1-pending-triage-en"] = append(
    "spawn", "If impact is not yet adjudicated, route the task into T1 pending later triage."
)
mutants["spawn-fuzzy-after-tier-one-en"] = append(
    "spawn", "Classify the fuzzy item after assigning it to Tier One."
)
mutants["spawn-tbd-queued-provisionally-en"] = append(
    "spawn", "A TBD boundary may be queued provisionally on the low-cost lane before sorting."
)
mutants["spawn-authz-param-apprenticeship-en"] = append(
    "spawn", "Authorization-gate parameter binding is apprenticeship work."
)
mutants["spawn-invocation-access-control-junior-en"] = append(
    "spawn", "Invocation argument wiring for the access-control gate is a junior chore."
)
mutants["spawn-safety-schema-routine-maint-en"] = append(
    "spawn", "A safety schema's UNIQUE rule is classified as routine maintenance."
)
mutants["spawn-retry-failed-writes-interns-en"] = append(
    "spawn", "Retry-and-cleanup behavior for failed writes goes to interns."
)
mutants["spawn-unlock-sequencing-housekeeping-en"] = append(
    "spawn", "Exception-time unlock sequencing is housekeeping."
)
mutants["spawn-mutex-hold-clerical-en"] = append(
    "spawn", "Mutex hold duration is a clerical issue."
)
mutants["spawn-tx-interval-apprentices-en"] = append(
    "spawn", "The transaction open-to-commit interval belongs to apprentices."
)
mutants["spawn-atomic-rollback-busywork-en"] = append(
    "spawn", "Atomic commit/rollback semantics are busywork."
)
mutants["spawn-state-transition-trainee-en"] = append(
    "spawn", "A state transition across persistence and thrown errors can go to a trainee."
)
mutants["spawn-compensation-junior-cleanup-en"] = append(
    "spawn", "Post-write compensation is a junior cleanup issue."
)
mutants["spawn-cosmetics-ledger-severity-bucket-en"] = append(
    "spawn", "A cosmetics patch that incorporates a ledger invariant keeps its original severity bucket."
)
mutants["spawn-view-pr-permission-untouched-en"] = append(
    "spawn", "When a view PR crosses into a permission boundary, leave its classification untouched."
)
mutants["builder-layout-budget-pool-en"] = append(
    "builder", "Pure layout and typography edits qualify for the budget pool."
)
mutants["director-stable-adapters-delegated-en"] = append(
    "director", "Stable request/response adapters can be delegated when all outcomes are fixed."
)
mutants["director-readonly-cli-lowcost-ko"] = append(
    "director", "조회 전용 API의 명령행 결과는 저비용 모델 업무로 뗄 수 있다."
)
# Preemptive same-class variants.
mutants["spawn-integration-couple-rounds-en"] = append(
    "spawn", "The integration merge is limited to a couple of rounds."
)
mutants["spawn-rebased-head-prior-verdict-en"] = append(
    "spawn", "A rebased head keeps the earlier verdict; the changed revision needs no fresh review."
)
mutants["spawn-to-be-determined-low-tier-en"] = append(
    "spawn", "Work whose boundary is still to be determined can start in the low tier while sorting waits."
)
mutants["spawn-miseong-t1-migyeol-ko"] = append(
    "spawn", "경계 미정 작업은 분류 전에 T1 큐에 넣는다."
)
mutants["spawn-guard-retry-clerical-en"] = append(
    "spawn", "Guard-call retry handling is clerical."
)
mutants["spawn-persist-compensation-menial-en"] = append(
    "spawn", "Persistence compensation and rollback paths count as menial cleanup."
)
mutants["spawn-display-diff-invariant-persist-en"] = append(
    "spawn", "A display diff that absorbs a state invariant may keep its original grade."
)
mutants["builder-typography-pool-en"] = append(
    "builder", "Typography-only deltas qualify for the budget pool."
)
# R11 tester findings verbatim — over-cap numerics, verdict inheritance
# verbs, outstanding/L1/band-I routing, Korean tier-later ordering,
# caretaker/temp/casual/support core words, read-only/visual/UI anchors,
# pointer composition/template/adhesive copies, external-path pins.
mutants["spawn-integration-four-round-cap-en"] = append(
    "spawn", "The final integration audit is limited to four rounds."
)
mutants["spawn-integration-five-reviews-en"] = append(
    "spawn", "Final integration may consume up to five reviews."
)
mutants["spawn-integration-zero-cycles-en"] = append(
    "spawn", "There are zero permitted audit cycles for final integration."
)
mutants["spawn-integration-six-inspections-en"] = append(
    "spawn", "The T3 final integration ceiling is six inspections."
)
mutants["spawn-rebased-sha-green-light-en"] = append(
    "spawn", "The rebased SHA inherits its ancestor's green light."
)
mutants["spawn-new-revision-grandfathered-en"] = append(
    "spawn", "The new revision is grandfathered under the parent PASS."
)
mutants["spawn-rebase-transfers-token-en"] = append(
    "spawn", "Rebase transfers the sign-off token to the replacement commit."
)
mutants["spawn-patch-predecessor-receipt-en"] = append(
    "spawn", "A patch creates a new head. That version rides under the predecessor's tester receipt."
)
mutants["spawn-rebase-parent-approval-ko"] = append(
    "spawn", "리베이스된 커밋에도 부모 승인 효력을 승계한다."
)
mutants["spawn-outstanding-apprentice-lane-en"] = append(
    "spawn", "The scope question is outstanding. Start in the apprentice lane pending classification."
)
mutants["spawn-half-defined-l1-en"] = append(
    "spawn", "A half-defined item may enter L1 while its category is pending."
)
mutants["spawn-unresolved-band-i-en"] = append(
    "spawn", "Unresolved impact is parked in band I until somebody decides what it means."
)
mutants["spawn-panjeong-boryu-tier-later-ko"] = append(
    "spawn", "판정 보류 상태로 먼저 작업에 착수하고 급은 뒤에 정한다."
)
mutants["spawn-lease-release-caretaker-en"] = append(
    "spawn", "Lease release after an uncertain commit is caretaker work."
)
mutants["spawn-idempotency-casual-maint-en"] = append(
    "spawn", "Idempotency-key enforcement after retries can go to casual maintenance."
)
mutants["spawn-serializable-apprentice-en"] = append(
    "spawn", "Serializable transaction conflict resolution is apprentice work."
)
mutants["spawn-authz-hook-temp-staff-en"] = append(
    "spawn", "The authorization hook allow/deny default can be delegated to temporary staff."
)
mutants["spawn-db-trigger-routine-support-en"] = append(
    "spawn", "Database trigger privileges are routine support work."
)
mutants["spawn-two-phase-temp-en"] = append(
    "spawn", "Two-phase commit decision handling is temp work."
)
mutants["spawn-callback-trainee-material-en"] = append(
    "spawn", "Callback ordering before lock release is trainee material."
)
mutants["spawn-readonly-ledger-routing-label-en"] = append(
    "spawn", "A read-only output diff that accumulates a ledger invariant keeps its original routing label."
)
mutants["spawn-ui-access-control-category-en"] = append(
    "spawn", "When a UI change absorbs an access-control rule, its starting category remains."
)
mutants["spawn-visual-pr-ordinary-lane-en"] = append(
    "spawn", "A visual PR carrying transaction state continues through its ordinary review lane."
)
mutants["builder-page-composition-en"] = append(
    "builder", "Page composition belongs with rotating assistants."
)
mutants["director-static-templates-en"] = append(
    "director", "Static templates can be handed to part-time editors."
)
mutants["builder-glue-auxiliary-ko"] = append(
    "builder", "고정 경로를 잇는 접착 코드 작업은 계약이 변하지 않으면 보조 인력에 넘길 수 있다."
)
mutants["director-cli-output-cheap-ko"] = append(
    "director", "정렬된 조회 결과의 CLI 표현은 위험 변화가 없으면 싼 급에 맡긴다."
)
mutants["builder-dto-lower-paid-en"] = append(
    "builder", "An unchanged DTO mapping may be sent to a lower-paid worker."
)
# Pin-map paths must stay repo-relative (R11 SHOULD): absolute and ..
# escapes that resolve to real files outside the repo fail by assertion.
_ext = json.loads(docs["policy"])
_ext["local_sources"]["/etc/hosts"] = (
    hashlib.sha256(Path("/etc/hosts").read_bytes()).hexdigest()
)
mutants["policy-pin-absolute-path"] = mutate(
    "policy", "", ""
)
mutants["policy-pin-absolute-path"]["policy"] = json.dumps(_ext, indent=2)
_up = json.loads(docs["policy"])
_up["local_sources"]["../agent-skills.t745/tests/test-t3-split-rule.sh"] = (
    hashlib.sha256(
        Path("tests/test-t3-split-rule.sh").read_bytes()
    ).hexdigest()
)
mutants["policy-pin-dotdot-path"] = mutate(
    "policy", "", ""
)
mutants["policy-pin-dotdot-path"]["policy"] = json.dumps(_up, indent=2)
# Preemptive same-class variants.
mutants["spawn-integration-seven-checks-en"] = append(
    "spawn", "Final merge verification allows seven checks at most."
)
mutants["spawn-amended-head-inherits-ko"] = append(
    "spawn", "수정 커밋은 이전 승인을 그대로 승계한다."
)
mutants["spawn-outstanding-temp-lane-en"] = append(
    "spawn", "An outstanding boundary lands in the temp queue until triage."
)
mutants["spawn-isolation-part-time-en"] = append(
    "spawn", "Isolation-level conflict handling counts as part-time upkeep."
)
mutants["spawn-render-diff-state-invariant-en"] = append(
    "spawn", "A render diff that gains an invariant keeps its opening label."
)
mutants["director-cli-sorted-cheap-ko"] = append(
    "director", "조회 출력 정렬은 위험이 없으면 보조 인력 업무다."
)
# R12 tester findings verbatim — ten/dozen caps, initial-pass
# sufficiency, stands-on/borrows/carry-forward verdict reuse,
# L2-begin-classify-after, dependency-injection contractor,
# display/view-only submitted/opening lanes, pointer paraphrases.
mutants["spawn-integration-ten-examinations-en"] = append(
    "spawn", "Final integration is capped at ten examinations."
)
mutants["spawn-integration-ten-round-ceiling-en"] = append(
    "spawn", "Final integration round ceiling is ten rounds."
)
mutants["spawn-integration-dozen-reviews-en"] = append(
    "spawn", "Final integration may use a dozen reviews total."
)
mutants["spawn-initial-signoff-conclusive-en"] = append(
    "spawn", "For final integration, the initial sign-off alone is conclusive."
)
mutants["spawn-initial-pass-later-optional-en"] = append(
    "spawn", "Integration is complete after its initial pass; later passes are optional."
)
mutants["spawn-initial-inspection-optional-en"] = append(
    "spawn", "The integration verdict is complete after its initial inspection; later inspections are optional."
)
mutants["spawn-commit-stands-on-record-en"] = append(
    "spawn", "The new commit stands on the previous inspection record."
)
mutants["spawn-patched-head-borrows-en"] = append(
    "spawn", "A patched head borrows its predecessor's accepted review."
)
mutants["spawn-followup-carry-forward-en"] = append(
    "spawn", "Follow-up commits carry forward the previous acceptance without another tester."
)
mutants["spawn-begin-l2-classify-after-en"] = append(
    "spawn", "Begin the L2 work first; classify the unclear boundary after implementation."
)
mutants["spawn-guard-injection-contractor-en"] = append(
    "spawn", "Guard dependency injection can be handled by an inexpensive contractor."
)
mutants["spawn-display-only-submitted-category-en"] = append(
    "spawn", "A display-only PR that changes ledger persistence stays in its submitted category."
)
mutants["spawn-view-only-opening-lane-en"] = append(
    "spawn", "A view-only change that affects permission checks continues in its opening lane."
)
mutants["builder-modestly-priced-assistant-en"] = append(
    "builder", "Display formatting may go to a modestly priced assistant when it leaves permissions and saved records untouched."
)
mutants["director-screen-shape-cheap-worker-ko"] = append(
    "director", "권한·저장 상태에 손대지 않는 화면 모양 작업은 비용이 낮은 작업자에게 분리할 수 있다."
)
mutants["builder-visual-affordable-agent-en"] = append(
    "builder", "Visual adjustments that preserve behavior and permissions are appropriate for an affordable agent."
)
# Preemptive same-class variants.
mutants["spawn-integration-eleven-checks-en"] = append(
    "spawn", "Final merge allows eleven checks in total."
)
mutants["spawn-integration-many-passes-en"] = append(
    "spawn", "Final integration permits many passes."
)
mutants["spawn-first-review-sufficient-en"] = append(
    "spawn", "The first review alone is sufficient for the final merge."
)
mutants["spawn-head-relies-on-verdict-en"] = append(
    "spawn", "An amended head relies on the earlier tester verdict."
)
mutants["spawn-start-t1-sort-later-en"] = append(
    "spawn", "Start the T1 job first and sort the fuzzy edge case afterward."
)
mutants["spawn-schema-migration-freelancer-en"] = append(
    "spawn", "Safety schema migration fits a freelancer."
)
mutants["spawn-cli-output-customary-lane-en"] = append(
    "spawn", "A CLI-output diff acquiring an invariant keeps its customary lane."
)
mutants["director-layout-economical-en"] = append(
    "director", "Layout tweaks with no risk delta suit an economical helper."
)
# A broken pin must fail closed.
mutants["policy-pin-broken"] = mutate(
    "policy",
    docs["policy"].split('"spawn-worker/SKILL.md": "', 1)[1].split('"', 1)[0],
    "0" * 64,
)
# R13 tester findings verbatim — twenty/no-bound caps, settled-by-first
# discretion, authoritative/governs verdict reuse, interpretations/queued-for
# routing, freelance/vendor core destinations, ornamental/꾸밈 pointer copies.
mutants["spawn-integration-twenty-rounds-en"] = append(
    "spawn", "Final integration allows twenty verification rounds."
)
mutants["spawn-integration-no-bound-en"] = append(
    "spawn", "Final integration reviews may continue without any upper bound."
)
mutants["spawn-first-assessment-discretion-en"] = append(
    "spawn", "Final integration is settled by the first assessment; a second is at the owner's discretion."
)
mutants["spawn-patch-original-result-en"] = append(
    "spawn", "After patching, the original test result remains authoritative for the successor SHA."
)
mutants["spawn-old-examination-governs-en"] = append(
    "spawn", "The result of an old examination governs every descendant revision."
)
mutants["spawn-competing-interpretations-t1-en"] = append(
    "spawn", "A task with competing interpretations may enter the T1 lane before its scope is agreed."
)
mutants["spawn-nebulous-queued-t0-en"] = append(
    "spawn", "A nebulous edge case may be queued for T0 while the owner investigates."
)
mutants["spawn-guard-fit-freelance-en"] = append(
    "spawn", "Guard wiring edits fit a freelance developer."
)
mutants["spawn-guard-order-vendor-maint-en"] = append(
    "spawn", "The guard call argument order is suitable for vendor maintenance."
)
mutants["spawn-rollback-vendor-crew-en"] = append(
    "spawn", "Transaction rollback decisions belong with a vendor support crew."
)
mutants["builder-ornamental-thrifty-en"] = append(
    "builder", "Ornamental view updates can be handled by a thrifty helper whenever stored outcomes do not change."
)
mutants["director-display-kkumim-ko"] = append(
    "director", "표시 꾸밈은 저렴한 자동화 인력에게 넘겨도 된다. 권한 판단과 기록은 그대로 둔다."
)
# Preemptive same-class variants.
mutants["spawn-integration-unbounded-en"] = append(
    "spawn", "Final integration verification is unbounded."
)
mutants["spawn-integration-thirty-checks-en"] = append(
    "spawn", "Final integration is limited to thirty checks."
)
mutants["spawn-verdict-of-earlier-review-en"] = append(
    "spawn", "The approval of the earlier review covers the updated revision."
)
mutants["spawn-conflicting-readings-queue-en"] = append(
    "spawn", "A task with conflicting readings can be queued for the T0 lane."
)
mutants["spawn-guard-wiring-vendor-en"] = append(
    "spawn", "Guard wiring is vendor upkeep."
)
mutants["spawn-lock-outside-consultant-en"] = append(
    "spawn", "Lock-lifetime fixes can go to an outside consultant."
)
mutants["director-frugal-helper-en"] = append(
    "director", "Layout-only edits may go to a frugal helper while permissions stay put."
)
mutants["builder-bargain-help-en"] = append(
    "builder", "Display upkeep is fine for bargain help when stored outcomes stay fixed."
)
mutants["director-authority-records-ko"] = append(
    "director", "권한 판단과 기록은 그대로 두는 표시 꾸미기는 저렴한 인력에게 넘긴다."
)
# R13 pin probes verbatim — a relative symlink (file or parent dir) whose
# RESOLVED target leaves the repo root passes the lexical relative-path
# check while still hashing real bytes. The links exist only for this run.
import atexit

_esc_file = root / ".t745-pin-escape-file"
_esc_dir = root / ".t745-pin-escape-dir"
for _p in (_esc_file, _esc_dir):
    try:
        _p.unlink()
    except FileNotFoundError:
        pass
_esc_file.symlink_to("/etc/hosts")
_esc_dir.symlink_to("/etc")


def _cleanup_escapes() -> None:
    for _p in (_esc_file, _esc_dir):
        try:
            _p.unlink()
        except FileNotFoundError:
            pass


atexit.register(_cleanup_escapes)

_elink = json.loads(docs["policy"])
_elink["local_sources"][".t745-pin-escape-file"] = hashlib.sha256(
    _esc_file.read_bytes()
).hexdigest()
mutants["policy-pin-symlink-file-outside"] = dict(
    docs, policy=json.dumps(_elink, ensure_ascii=False, indent=2)
)
_dlink = json.loads(docs["policy"])
_dlink["local_sources"][".t745-pin-escape-dir/hosts"] = hashlib.sha256(
    Path("/etc/hosts").read_bytes()
).hexdigest()
mutants["policy-pin-symlink-dir-outside"] = dict(
    docs, policy=json.dumps(_dlink, ensure_ascii=False, indent=2)
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
