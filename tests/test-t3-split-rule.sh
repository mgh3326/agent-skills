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
    # R2 tester findings — same attack classes under alternate wording:
    # a once-only integration pass, a skipped re-verify, ambiguous work run
    # low then classified later, core classes named without the word 핵심.
    ("integration-one-pass",
     r"통합[^\n]{0,40}?(?:검증|tester)[^\n]{0,40}?(?:한 차례|한 번|한번|1회|단 한 번|1패스|한 패스|단일|한 회)[^\n]{0,10}?(?:만[^\n]{0,15}?(?:검증|확인|보고|통과|본다|체크|끝낸다|보면)|(?:검증|확인|보고|통과|체크)[^\n]{0,10}?(?:으로\s*끝|까지만|충분|하면\s*된다|끝낸다))|(?:한 차례|한 번|한번|1회|단 한 번|1패스|한 패스|단일|한 회)[^\n]{0,15}?(?:검증|확인|보고|통과|본다|체크|보면|봐도)[^\n]{0,20}?(?:최종\s*)?통합|통합[^\n]{0,25}?(?:검증|tester)[^\n]{0,15}?충분(?!하지|하다고|할 리|치 않|기가)"),
    ("integration-one-pass-en",
     r"(?i)(?:final\s+)?integration[^\n]{0,45}?(?:(?:only\s+one|one|single|a\s+single|just\s+one|one-?shot|single-?shot|1)[ -]?(?:pass|round|look|check|review|verification)|(?:run|look|review|verify|check|use|read)[ -]?once|once\s+only)|(?:only\s+one|one|single|a\s+single|just\s+one|one-?shot|single-?shot|1)[ -]?(?:pass|round|look|check|review|verification)[^\n]{0,45}?(?:final\s+)?integration"),
    ("integration-cap-numeric",
     r"통합[^\n]{0,40}?(?:검증|tester)[^\n]{0,40}?(?:cap|캡|상한)[^\n]{0,8}?[:=]?\s*1\b"),
    ("integration-skipped",
     r"(?i)(?:최종\s*)?통합[^\n]{0,25}?(?:tester|검증)[^\n]{0,12}?(?:없이|생략|불필요|제외|건너)|머지[^\n]{0,15}?(?:없이|생략)[^\n]{0,10}?(?:검증|tester)|(?:merge|merging)[^\n]{0,15}?(?:without|skip\w*|omit\w*)[^\n]{0,10}?(?:verif\w*|tester|check)|(?:final\s+)?integration[^\n]{0,30}?(?:tester[- ]?(?:free|less)|without\s+(?:an?\s+)?(?:independent\s+|cross[- ]family\s+)?tester|no\s+tester)|verdict[^\n]{0,15}?(?:유효|valid|재사용|그대로)[^\n]{0,10}?(?:수정|바뀐|새|patched|changed|new|updated)\s+head|(?:old|previous|prior|stale|earlier|existing)[^\n]{0,10}?verdict[^\n]{0,15}?(?:still|remains|valid|count\w*|reuse|carry|applies)"),
    ("integration-no-reverify",
     r"(?:수정된?|바뀐|새|패치된)\s*head[^\n]{0,20}?(?:재검증|다시 검증|재확인|후속 확인|후속 검증|추가 확인|검증|확인|점검)[^\n]{0,12}?(?:하지\s*않|없|생략|불필요|필요[^\n]{0,3}?없)|재검증[^\n]{0,12}?(?:없이|하지|생략|불필요|필요[^\n]{0,3}?없)|(?:후속|추가)\s*(?:확인|검증|점검)[^\n]{0,8}?(?:생략|불필요|없|하지)"),
    ("integration-no-reverify-en",
     r"(?i)(?:re-?verif\w*|re-?check\w*|recheck\w*|re-?examin\w*|re-?inspect\w*|re-?review\w*|re-?evaluat\w*)[^\n]{0,15}?(?:waiv\w*|skip\w*|omit\w*|dropped|not needed|unnecessary|unneeded|no longer)|(?:skip|omit|waive|without|sans|no)[^\n]{0,15}(?:re-?verif\w*|re-?check\w*|recheck\w*|(?:second|third|another|extra)\s+(?:verification|check|pass|look|review|inspection|scrutiny)|follow-?up\s+(?:verification|check|look|review|inspection)|further\s+(?:verification|check|review|scrutiny|inspection|look))|(?:patched|changed|modified|updated|new)\s+heads?[^\n]{0,20}?(?:accept\w*|approv\w*|merg\w*|pass\w*|us\w*|go\w*|no|without|sans|skip\w*|omit\w*|waiv\w*|not needed|unnecessary|unneeded)[^\n]{0,15}?(?:second\s+|third\s+|another\s+|further\s+|additional\s+|re-?|extra\s+)?(?:verification|verif|check|pass|look|review|inspection|scrutiny)|after[^\n]{0,10}?(?:the\s+)?head[^\n]{0,10}?change\w*[^\n]{0,15}?(?:no|without|skip|omit|waive|not needed|unnecessary|accept\w*)[^\n]{0,12}?(?:second\s+)?(?:verification|check|pass|look|review|inspection|scrutiny)|(?:second|third|another|further|additional|extra)\s+(?:look|check|review|verification|pass|inspection|scrutiny)[^\n]{0,25}?(?:at|on|for|of)?[^\n]{0,15}?(?:patched|changed|modified|updated|new)\s+heads?|(?:no need|not needed|unnecessary|unneeded)[^\n]{0,15}?(?:for\s+)?(?:a\s+)?(?:second|third|another|follow-?up|further|additional|extra)[ -]?(?:look|check|review|verification|pass|inspection|scrutiny)"),
    ("ambiguous-lower-t-alt",
     r"(?i)(?:애매|모호|불명확|불확실|미분류|미정|모른|알 수 없|정해지지 않|경계가|분류 불가|unclear|unclassified|ambiguous|uncertain|unsure|undecided|undetermined|indeterminate|unsettled|unresolved|unknown|vague|fuzzy|hazy|iffy|open[- ]ended|undefined|unset|(?:cannot|can't|unable|hard|difficult)[^\n]{0,15}?(?:decide|determine|classify|scope|boundar|resolve))[^\n]{0,30}?(?:(?:T0|T1|T2|낮은 T|lower\s*T)[^\n]{0,15}?(?:실행|처리|배정|돌리|맡기|넘기|시작|보낸|보냄|start|run|assign|dispatch|handle|processing|work)(?!하지)|(?:start|begin|run|assign|dispatch|handle|send|route)[^\n]{0,10}?(?:at|as|to|into|on)\s*(?:T0|T1|T2|lower\s*T))"),
    ("ambiguous-posthoc-classify",
     r"(?i)(?:애매|모호|불명확|불확실|미분류|미정|경계 작업|ambiguous|unclear|uncertain|unsure|undecided|undetermined|unsettled|unknown)[^\n]{0,40}?(?:(?:사후|나중에?|추후|뒤에?|후에|이후|afterwards?|later|after|following)[^\n]{0,10}?(?:분류|재분류|classif)|(?:분류|재분류|classif\w*)[^\n]{0,10}?(?:사후|나중에|추후|뒤에|후에|이후|afterwards?|later|after|following)|(?:defer\w*|postpone\w*|delay\w*|put\s+off|미뤄|미룬|늦추|연기)[^\n]{0,15}?(?:분류|재분류|classif))"),
    ("lower-t-then-classify",
     r"(?i)(?:T0|T1|T2|낮은 T|lower\s*T)[^\n]{0,15}?(?:실행|처리|배정|돌리|맡기|넘기|시작|보낸|보냄|run|start|assign|dispatch|handle|processing|work)[^\n]{0,25}?(?:사후|나중에|추후|뒤에|후에|이후|afterwards?|later|after|following)[^\n]{0,15}?(?:애매|모호|경계|분류|classif|ambiguous|unclear|uncertain|boundary)|(?:T0|T1|T2|lower\s*T)[^\n]{0,15}?(?:processing|work|execution|run|start|시작|실행|처리|돌리|맡기|배정|넘기|보낸|보냄|assign|dispatch|handle)[^\n]{0,25}?(?:before|prior|ahead|전에|앞서|먼저)[^\n]{0,15}?(?:uncertainty|ambiguity|boundary|classification|scope|애매|모호|경계|분류)[^\n]{0,15}?(?:resolved|decided|determined|settled|classified|정해|분류|해결)"),
    ("core-class-lower-t",
     r"(?i)(?:안전 DB|안전 제약|에러 경로|에러 처리|예외 경계|lock[-/\s](?:and\s+)?transaction|상태/DB/예외 경계|가드 배선|가드 인자|가드 호출|guard\s+wiring|guard\s+call|guard\s+arg|safety[-\s]db|safety[-\s]constraint|core\s+safety|error[-\s]path|error[-\s]handling|exception[-\s]boundary|exception[-\s]propagat\w*|exception[-\s]flow|return[-\s]check|transaction\s+lifetime|lock/tx|lock-tx|state[-/\s]boundary|db[-/\s]boundary|state[-/\s]exception|guard\s+(?:config|setting|behavior|hook|check)|가드 설정|state/db)[^\n]{0,35}?(?:(?:T0|T1|T2|낮은 T|lower\s*T|주변|periph\w*|cheap\w*)[^\n]{0,15}?(?:주변|배정|실행|처리|돌리|맡기|떼|취급|간주|본다|여긴다|핫픽스|작업|분류|넘긴다|보낸다|업무|워커|peripheral|worker|assign|task|work|run|hotfix|handle|treat|mark|glue|pool|tier|change|make|edit|modify|own|take|do)|(?:assign\w*|rout\w*|send|dispatch\w*|delegat\w*|hand\w*|put|treat|mark|go\w*|move|dump|lump|맡긴다|보낸다|넘긴다|배정)[^\n]{0,10}?(?:at|as|to|into|on|에게|에|로)\s*(?:the\s+|a\s+)?(?:T0|T1|T2|낮은\s*T|lower\s*T|주변|periph\w*|cheap|pool|tier|glue))"),
    ("lower-t-first-core",
     r"(?i)(?:T0|T1|T2|낮은 T|lower\s*T|lower[- ]tier|주변|periph\w*|cheap\w*)[^\n]{0,12}?(?:워커|worker|모델|작업|task|tier|pool|owner|assign\w*|send|route|dispatch\w*|hand\w*|giv\w*|put|own\w*|take\w*|handle\w*|do\w*|make|change\w*|edit\w*|modify\w*)[^\n]{0,25}?(?:안전 DB|안전 제약|에러 경로|에러 처리|예외 경계|lock[-/\s]|가드 배선|가드 인자|가드 호출|guard|core|핵심|상태/DB|safety|error|exception|boundary|wiring|constraint)"),
    ("one-line-guard-periph",
     r"(?i)(?:호출 한 줄|한 줄 호출|one[- ]line|single[- ]line)[^\n]{0,30}?(?:T0|T1|T2|낮은 T|주변|periph\w*|cheap\w*|lower)"),
    ("periph-core-merge-anyway",
     r"(?:주변 PR|주변 작업)[^\n]{0,30}?(?:핵심|core|가드|안전)[^\n]{0,30}?(?:그대로|낮은 T|T0|T1|T2)[^\n]{0,15}?(?:머지|유지|통과|진행|실행|둔다|두고|넘긴다)"),
    ("periph-core-no-reclassify",
     r"(?i)(?:주변 PR|주변 작업|peripheral\s+(?:PR|work|change|patch))[^\n]{0,30}?(?:핵심|core|가드|안전|touch\w*|건드리|건드려|slip\w*|sneak\w*|leak\w*|creep\w*|affect\w*|hit)[^\n]{0,30}?(?:재분류하지|재분류\s*없|안\s*재분류|재분류[^\n]{0,3}?않|not\s+be\s+reclassif|remain\w*[^\n]{0,10}?peripheral|stay\w*[^\n]{0,10}?peripheral|no[^\n]{0,5}?reclassif|without[^\n]{0,10}?reclassif|exempt\w*[^\n]{0,10}?(?:from\s+)?reclassif|(?:retain|keep|stay|remain|hold)[^\n]{0,15}?(?:original|same|current|lower|assigned)[^\n]{0,10}?(?:tier|grade))|(?:핵심|core|안전|가드)[^\n]{0,20}?(?:slip\w*|sneak\w*|leak\w*|creep\w*|touch\w*|end\w*|land\w*|enter\w*)[^\n]{0,15}?(?:into|in|to|onto|within)[^\n]{0,15}?(?:peripheral\s+(?:PR|work|change|patch)|주변\s*(?:PR|작업))[^\n]{0,25}?(?:retain|keep|stay|remain|hold|no|without|skip|not|exempt)[^\n]{0,15}?(?:original\s+|same\s+|assigned\s+)?(?:tier|grade|reclassif)"),
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
