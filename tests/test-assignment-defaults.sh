#!/usr/bin/env bash
# #736: assignment defaults contract (operator decision 2026-09-26, decision
# 4088 B + note/2026-09-26/grade-cost-table id 4098 — the FINAL rule is
# "among candidates whose grade is at least the task grade, pick the lowest
# cost per task"; the listed model/effort pairs are its current output, not a
# hard-coded list; Sonnet=T2 is withdrawn). The three skill files must each
# carry the T736 block; bin/wrk must refuse a max rung on a builder seat and
# default builder-sol to high; gate_policy.json must agree. Every mutant
# weakens one policy row in-memory and must go RED by assertion — repository
# files are never modified.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import json
import os
import re
import sys

root = Path(sys.argv[1])
paths = {
    "spawn": Path(os.environ.get("SPAWN_WORKER_SKILL", root / "spawn-worker/SKILL.md")),
    "builder": Path(os.environ.get("BUILDER_SKILL", root / "builder/SKILL.md")),
    "director": Path(os.environ.get("DIRECTOR_SKILL", root / "director/SKILL.md")),
    "readme": root / "README.md",
    "wrk": root / "bin/wrk",
    "policy": root / "director/gate_policy.json",
}
docs = {name: path.read_text(encoding="utf-8") for name, path in paths.items()}

START = "<!-- T736-ASSIGNMENT-DEFAULTS -->"
END = "<!-- /T736-ASSIGNMENT-DEFAULTS -->"
SKILLS = ("spawn", "builder", "director")


def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def block(text: str, name: str) -> str:
    assert text.count(START) == 1 and text.count(END) == 1, (
        f"{name}: exactly one T736-ASSIGNMENT-DEFAULTS block required "
        f"(start={text.count(START)} end={text.count(END)})"
    )
    return flat(text[text.index(START) : text.index(END)])


# (row, required regex) — the negations live inside the patterns so a
# weakened or dropped clause goes RED instead of silently matching.
BLOCK_ROWS = [
    # The FINAL rule sentence (note 4098): the listed pairs below are its
    # current output, not a hard-coded list — #735 measured reps recalibrate.
    ("rule-cost-per-task", r"과제 급 이상으로 배치된 후보 중 작업당 비용이 가장 낮은 것을 기본으로\s*고른다"),
    ("rule-example-not-list", r"고정 목록이 아니라 이 규칙의 현재 출력"),
    ("rule-recalibrate-735", r"#735 의 측정 rep 이? 이 표를 재보정한다"),
    # The rule is applied by picking profile@effort explicitly — the wrk
    # spelling defaults are NOT the policy (director-1 answer 2026-09-26).
    ("wrk-defaults-not-policy", r"wrk 철자 기본값은? 정책이 아니다"),
    # Builder seat: never max — ultra counts as the same refusal, and under
    # the cost rule builders still exclude max from the candidate set.
    ("builder-never-max", r"빌더 좌석은 max 런그를 쓰지 않는다"),
    ("builder-ultra-counts", r"ultra[^\n]{0,30}?(거부|상한)"),
    ("builder-floor", r"기본은 high 이하 또는 devin 프로필"),
    ("builder-max-excluded", r"빌더 후보는 max 를 빼고 고른다"),
    ("builder-xhigh-exceptions", r"별도 승인된 xhigh 빌더"),
    ("builder-sol-high", r"Sol 빌더는? Sol high"),
    # Sol high is an unmeasured (C) rung — the seat default is NOT an eligible
    # candidate under the cost rule; the text must say so (S-R3-1).
    ("sol-high-seat-not-candidate", r"Sol high[^\n]{0,30}?배정 후보가 아니라 좌석 고정값"),
    ("devin-no-effort-flag", r"devin 빌더는? effort 플래그 없이"),
    # 4088 B reservation restored with its sourced exceptions — the only
    # non-T3 max rungs are the ones the sources name.
    ("max-t3-only", r"max effort 는? T3 구현 워커·T3 tester 에만\s*예약한다"),
    ("max-exceptions-sourced", r"예외는? devin swe2-max[^\n]{0,60}?A\+ 의 Luna max[^\n]{0,40}?E6 측정 런그"),
    ("wrk-enforces", r"wrk 도? `?--role builder`? 에서 max 를 거부한다"),
    # Devin defaults (unchanged by the FINAL rule).
    ("t1t2-devin", r"T1/T2 구현 기본은 devin"),
    ("swe2max-free", r"SWE-2 max[^\n]{0,60}?무료이므로 적극 쓴다"),
    ("devin-sole-restriction", r"devin\(A\+\)은 T3·S 의 단독 구현자·단독 tester 가 되지 않는다"),
    # Current output — claude (one shared weekly window: cost per task is the
    # quota axis). Opus low carries the gate=escalation caveat.
    ("claude-shared-window", r"하나의 주간 창을 나누므로[^\n]{0,80}?작업당 비용이 곧 쿼타 소모 비교축"),
    ("claude-splus-opus-medium", r"S\+ = Opus medium"),
    ("claude-t3-core-high", r"T3 코어 구현은? Opus high"),
    ("claude-t3-tester-xhigh", r"T3 tester 는? Opus xhigh"),
    ("claude-no-opus-max", r"Opus max 는? 쓰지 않는다"),
    ("claude-opus-low", r"S·A\+·A =\s*Opus low"),
    ("opus-low-dominates-sonnet", r"모든 Sonnet effort 를 비용·점수 양쪽에서 지배"),
    ("claude-bc-haiku", r"B·C·기계적 작업 =\s*Haiku"),
    ("opus-low-gate-escalation", r"Opus low 는? 현재 카탈로그에서 gate=escalation"),
    ("opus-low-gate-scopefuel-only", r"scopefuel 카탈로그 변경이며[^\n]{0,30}?이 PR 의 범위 밖"),
    # While Opus low is gated, S/A+/A still picks the cheapest USABLE
    # candidate — no ad-hoc gap (N-R3-1).
    ("opus-low-interim", r"해제 전까지 S·A\+·A 도 사용 가능 후보 중 비용 최소로 고른다"),
    # The lift is a merged scopefuel change (#738) pending install — the
    # caveat must not read as open-ended.
    ("opus-low-738-status", r"#738[^\n]{0,25}?merge[^\n]{0,25}?설치"),
    # The interim parenthetical pins the corrected per-grade output
    # (S-R4-1): with Opus low gated, A's cheapest usable candidate is
    # Sonnet low (note 4098, catalog gate=default), not Opus medium.
    ("opus-low-interim-detail", r"그 다음 저가는 S·A\+ = Opus medium[^\n]{0,3}?A = Sonnet low"),
    # E6 measurement rungs in the max-reservation exception are worker
    # rungs — builder max stays closed (N-R4-1).
    ("worker-e6-rungs", r"워커 E6 측정 런그"),
    # Current output — codex. Terra is dominated at every grade; the codex-sol
    # spelling itself still defaults to max, so Sol assignments carry --effort.
    ("codex-s-sol-xhigh", r"S\+·S = Sol xhigh"),
    ("sol-max-t3core", r"Sol max 는?[^\n]*?T3 코어가 필요할 때만"),
    ("codex-aplus-luna-max", r"A\+ = Luna max"),
    ("codex-a-luna-high", r"A = Luna high"),
    ("codex-b-luna-medium", r"B = Luna medium"),
    ("terra-dominated", r"Terra 는? 모든 급에서 지배당한다"),
    ("terra-reserve-only", r"Terra 전용으로 확인될 때만 보조"),
    ("terra-no-load-claim", r"부하 분산 주장 금지"),
    ("sol-codex-default-max", r"codex-sol`?\s*철자 자체의 기본값은 max"),
    ("sol-assign-explicit-effort", r"Sol 배정은? `?--effort`? 명시"),
    ("e6-sol-priority", r"미측정 Sol high\(C\)·미배치 Sol medium 은?[^\n]{0,40}?E6 arm 우선 측정 대상"),
    # Provenance and authority.
    ("cite-decision", r"2026-09-26 운영자 결정"),
    ("cite-note-4098", r"note/2026-09-26/grade-cost-table"),
    ("cite-telemetry", r"pinion05\.github\.io/aa-model-telemetry"),
    ("cite-collected", r"수집 2026-09-23"),
    ("no-bench-copy", r"벤치 수치는?"),
    ("scopefuel-authority", r"scopefuel --recommend"),
]

# Patterns that must NOT appear anywhere in a skill file — the classes of
# drift this test exists to catch.
FILE_FORBIDDEN = [
    # devin builder spellings carry the rung in the model name and are
    # allowed (and encouraged) — builder-devin-max/builder-ds41-max are not
    # "a builder using max" in the drift sense.
    ("builder-max-default",
     r"(?:빌더|builders?\b(?!-(?:devin|ds41)))[^\n]{0,40}?(?:max[^\n]{0,15}?(?:기본|default|권장|허용|쓴다|쓸 수 있다|써도 된다|열린다|뜬다|가능|\bmay\b|\bcan\b|\ballowed\b|\bopen\b|\blaunch)|(?:기본|default|권장|허용|\bmay\b|\bcan\b|\ballowed\b|\bopen\b|\blaunch)[^\n]{0,12}?max)"),
    ("builder-max-spelling-opens",
     r"builder-(?:sonnet|sol|luna|terra|kimi)-max[^\n]{0,30}?(?:launch|opens?|열린|뜬|쓸 수 있다|될 수 있다)"),
    ("devin-sole-granted",
     r"(?:devin[^\n]{0,40}?T3|T3[^\n]{0,40}?devin)[^\n]{0,60}?단독[^\n]{0,60}?(가 된다|될 수 있다|허용|가능|쓴다|쓸 수 있다)"),
    # Withdrawn by the FINAL rule (note 4098): Sonnet is not the T2 default —
    # neither "T2 = Sonnet" nor "Sonnet = T2" may come back, anywhere.
    ("sonnet-t2-stale",
     r"T2[^\n]{0,15}?=\s*Sonnet|Sonnet[^\n]{0,25}?=\s*T2"),
    # The contradictory replacement sentence from the first FINAL-rule edit
    # (B-R3-1): "worker max remains only X" contradicted the same block's
    # A+ = Luna max row. The reservation is stated as 4088 B + exceptions now.
    ("worker-max-remnant-contradiction",
     r"워커 쪽의 max 는[^\n]{0,60}?에만 남는다"),
]

# Same drift classes in the launcher: help and comment text must not claim a
# closed max-rung builder spelling opens or launches.
WRK_FORBIDDEN = [
    ("wrk-max-spelling-launch",
     r"builder-(?:sonnet|sol|luna|terra|kimi)-max[^\n]{0,30}?(?:opens?|launches|spawns?|열린|뜬)"),
]

# #748 (post-#740 codex tester finding): on an explicit --effort rung the
# installed gate judges quota rules and shows the escalation tag — it never
# enforces a --operator-request REF there (scopefuel #716). The stale claim
# that a marked rung "needs a REF" is forbidden wherever it appeared; the
# negated forms ("요구하지 않는다", "no ... enforced") stay legal.
REF_REQUIRED_FORBIDDEN = [
    ("ref-required-en",
     r"(?:needs?|requires?|demands?|must)\s+(?:an?\s+|the\s+|a\s+)?--operator-request"),
    ("ref-required-en-passive",
     r"--operator-request`?\s+(?:is|are)\s+(?:required|needed|mandatory)"),
    ("ref-required-ko",
     r"--operator-request`?\s*가\s*(?:추가로\s+)?필요(?:하다|함)|--operator-request`?\s*를\s*요구한다"),
    ("ref-required-escalation",
     r"에스컬레이션[^\n]{0,40}?--operator-request[^\n]{0,15}?추가"),
]

EXPLICIT_RUNG_NO_REF = (
    r"명시[^\n]{0,20}?--effort[^\n]{0,60}?--operator-request[^\n]{0,40}?요구하지 않는다"
)

CLOSED_E6 = r"max 런그 철자\([^\n]*?builder-sonnet-max[^\n]*?\)는? 닫혔다"


def check(d: dict) -> None:
    for name in SKILLS:
        blk = block(d[name], name)
        text = flat(d[name])
        for row, pattern in BLOCK_ROWS:
            assert re.search(pattern, blk), f"{name}: assignment row '{row}' missing or weakened"
        for row, pattern in FILE_FORBIDDEN:
            assert not re.search(pattern, text), (
                f"{name}: forbidden wording reintroduced ({row}): "
                f"{re.search(pattern, text).group(0)!r}"
            )
        # No second grade table: the block must not carry a markdown table.
        assert "|---" not in blk and "| 급 |" not in blk, (
            f"{name}: a second grade table appeared inside the T736 block"
        )
        # No benchmark numbers copied into the block (dates/rungs are fine;
        # decimal scores are not).
        assert not re.search(r"\d+\.\d+", blk), (
            f"{name}: benchmark-style number copied into the T736 block"
        )
    # The launcher text must not claim a closed max-rung builder opens.
    wrk_flat = flat(d["wrk"])
    for row, pattern in WRK_FORBIDDEN:
        assert not re.search(pattern, wrk_flat), (
            f"wrk: forbidden wording reintroduced ({row}): "
            f"{re.search(pattern, wrk_flat).group(0)!r}"
        )
    # The closed max-rung E6 spellings are documented where the rungs live.
    for name in ("spawn", "builder"):
        assert re.search(CLOSED_E6, flat(d[name])), (
            f"{name}: closed max-rung E6 spellings note missing"
        )

    # #748: the stale "marked rung needs a REF" claim may not appear in any
    # scanned doc, and the corrected #716 wording must be where the rungs are
    # documented (spawn/builder table rows, README note, wrk help).
    for name in (*SKILLS, "wrk", "readme"):
        for row, pattern in REF_REQUIRED_FORBIDDEN:
            assert not re.search(pattern, flat(d[name])), (
                f"{name}: stale REF-required claim reintroduced ({row}): "
                f"{re.search(pattern, flat(d[name])).group(0)!r}"
            )
    for name in ("spawn", "builder", "readme"):
        assert re.search(EXPLICIT_RUNG_NO_REF, flat(d[name])), (
            f"{name}: #716 explicit-rung no-REF wording missing"
        )
    assert re.search(
        r"explicit --effort rung[^\n]{0,80}?quota rules[^\n]{0,80}?no --operator-request[^\n]{0,40}?enforced",
        wrk_flat,
    ), "wrk: help must say explicit rungs are quota-judged with no REF enforced"

    # bin/wrk: the builder-seat rule must sit on the resolved effort, and
    # builder-sol must resolve/catalog-pin at high. The kimi home read below
    # is what lets the unflagged kimi spellings reach the same case arm.
    wrk = flat(d["wrk"])
    assert "builder seats never take a max rung" in wrk, (
        "wrk: builder-seat max refusal message missing"
    )
    assert re.search(
        r"ROLE:-worker.{0,40}?builder.{0,60}?local seat_effort=\"\$EFFECTIVE_EFFORT\".{0,900}?case \"\$seat_effort\" in max\|ultra\)",
        wrk,
    ), (
        "wrk: the seat rule must gate on role=builder and refuse resolved max|ultra"
    )
    # #748: builder-kimi/kimi-k3 leave EFFECTIVE_EFFORT empty — the seat rule
    # must read the kimi home's resolved effort or a max home slips through.
    assert re.search(
        r"-z \"\$seat_effort\" && \"\$PROFILE_KIND\" == kimi.{0,900}?kimi_clone_resolved_effort \"\$\{KIMI_TRUST_HOME:-\}/config\.toml\" \"\$kimi_model\"",
        wrk,
    ), (
        "wrk: an empty resolved effort on a kimi profile must read the home's resolved effort for the seat rule"
    )
    # #748r2 (tester round 1): the resolution must honour TOML literal
    # (single-quoted) strings and the model default_effort fallback with
    # support_efforts membership — a double-quote-only scan or a
    # thinking-only read leaves valid max homes admitted.
    assert "default_effort" in wrk and "support_efforts" in wrk, (
        "wrk: the kimi seat read must fall back to the model's default_effort honouring support_efforts"
    )
    assert re.search(
        r"m_seen && \(t == \"\" \|\| \(s_seen && !\(t in S\)\)\)\) r = d",
        wrk,
    ), "wrk: the kimi resolver must substitute default_effort for missing/unsupported requests"
    assert re.search(r"substr\(s, 1, 1\) == sq", wrk), (
        "wrk: the kimi resolver must parse TOML literal (single-quoted) strings"
    )
    # #748r3 (tester round 2): the resolution must be a real TOML parse —
    # dotted keys, inline tables, escapes, multiline strings and indented
    # headers are equivalent spellings an awk scan cannot fully cover — plus
    # the documented env overlay, Thinking disabled→off_effort, and the
    # [models."<id>".overrides] table.
    assert re.search(r"import tomllib\b", wrk), (
        "wrk: the kimi resolver must parse real TOML via tomllib/tomli"
    )
    assert re.search(
        r"resolved not in support\)\): resolved = default",
        wrk,
    ), "wrk: the kimi resolver must fall back to default_effort for missing/unsupported requests"
    assert 'env_eff="${KIMI_MODEL_THINKING_EFFORT:-}"' in wrk, (
        "wrk: the kimi resolver must honour the KIMI_MODEL_THINKING_EFFORT overlay"
    )
    assert 'thinking.get("enabled") is False' in wrk, (
        "wrk: the kimi resolver must resolve disabled Thinking to off_effort"
    )
    assert 'model.get("overrides")' in wrk, (
        "wrk: the kimi resolver must honour the model overrides table"
    )
    assert 'pick("off_effort")' in wrk, (
        "wrk: the kimi resolver must read the model off_effort"
    )
    # always-thinking also arrives as a capabilities tag, not only a boolean
    # field; effort="off" is a valid off spelling; and the env overlay is
    # bounded to documented rung spellings before it is honoured.
    assert '"always_thinking" in caps' in wrk, (
        "wrk: the kimi resolver must honour the always_thinking capability tag"
    )
    assert 'if effort == "off" and not always:' in wrk, (
        "wrk: the kimi resolver must treat effort=off as Thinking off"
    )
    assert '"xhigh", "max", "ultra", "off", "on"' in wrk, (
        "wrk: the kimi resolver must bound the env overlay to documented rung spellings"
    )
    # CodeRabbit #153: with no readable config the env value alone resolves —
    # it must be bounded and normalized like the real parse or MAX bypasses
    # the case-sensitive seat match; the E6 pinned clone must exist before
    # its effort is compared (the env overlay cannot stand in for it); and
    # the awk overrides strip must anchor at the suffix, not eat the model
    # id's closing quote.
    assert re.search(
        r'! -r "\$cfg".{0,600}?tr .\[:upper:\]. .\[:lower:\].',
        wrk,
    ), "wrk: the no-config env path must normalize the effort value"
    assert 'minimal|low|medium|high|xhigh|max|ultra|off|on) printf' in wrk, (
        "wrk: the no-config env path must bound the effort value to documented rungs"
    )
    assert 'printf \'%s\\n\' "$norm"' in wrk, (
        "wrk: the no-config env path must print the normalized value, not the raw env"
    )
    assert re.search(
        r'-r "\$KIMI_TRUST_HOME/config\.toml".{0,200}?config\.toml missing',
        wrk,
    ), "wrk: the E6 pinned kimi clone must fail closed on a missing config.toml"
    assert 'sub(/\\.overrides$/, "", mh)' in wrk, (
        "wrk: the awk overrides strip must anchor at the suffix, not eat the closing quote"
    )
    assert re.search(
        r"builder-sol\|captain-sol\)\s*PROFILE_KIND=codex;\s*PROFILE_MODEL=gpt-6-sol;\s*DEFAULT_EFFORT=high",
        wrk,
    ), "wrk: builder-sol must default to effort high"
    assert "builder-sol|captain-sol) CATALOG_PROFILE=codex-sol; CATALOG_EFFORT_PIN=high" in d["wrk"], (
        "wrk: builder-sol must consult the catalog at the high rung"
    )

    # gate_policy.json agrees: builder-sol/captain-sol default high.
    policy = json.loads(d["policy"])
    for alias in ("builder-sol", "captain-sol"):
        assert policy["profiles"][alias]["default_effort"] == "high", (
            f"gate_policy: {alias} default_effort must be high (builder seats never max)"
        )


check(docs)
print(
    f"PASS assignment-defaults rows={len(BLOCK_ROWS)}/file "
    f"forbidden={len(FILE_FORBIDDEN)}/file wrk+policy consistent"
)


def mutate(name: str, old: str, new: str) -> dict:
    doc = dict(docs)
    assert doc[name].count(old) >= 1, f"fixture: {old!r} not in {name}"
    doc[name] = doc[name].replace(old, new, 1)
    return doc


mutants = {}
# The two drift classes the brief names must go RED in every file, plus the
# FINAL-rule sentence and its withdrawn Sonnet=T2 predecessor.
for name in SKILLS:
    mutants[f"{name}-builder-max-weakened"] = mutate(
        name, "빌더 좌석은 max 런그를 쓰지 않는다", "빌더 좌석은 보통 max 를 피한다"
    )
    mutants[f"{name}-builder-max-reintroduced"] = mutate(
        name, "빌더 후보는 max 를 빼고 고른다", "빌더 좌석의 기본은 max 런이다"
    )
    mutants[f"{name}-devin-sole-weakened"] = mutate(
        name, "단독 구현자·단독 tester 가 되지 않는다", "단독 구현자·단독 tester 도 된다"
    )
    mutants[f"{name}-rule-sentence-weakened"] = mutate(
        name, "작업당 비용이 가장 낮은 것을 기본으로", "가장 강한 모델을 기본으로"
    )
    mutants[f"{name}-recalibrate-735-dropped"] = mutate(
        name, "#735 의 측정 rep 이 이 표를 재보정한다", "#735 도 이 표를 참고한다"
    )
    # 4088 B clauses — dropping either again is the B-R3-1 regression.
    mutants[f"{name}-max-reservation-dropped"] = mutate(
        name, "max effort 는 T3 구현 워커·T3 tester 에만 예약한다", "max effort 는 상황에 따라 쓴다"
    )
    mutants[f"{name}-builder-floor-weakened"] = mutate(
        name, "기본은 high 이하 또는 devin 프로필이다", "기본은 xhigh 이다"
    )
    mutants[f"{name}-max-exceptions-dropped"] = mutate(
        name, "예외는 devin swe2-max", "예외는 없다"
    )
    mutants[f"{name}-sonnet-t2-reintroduced"] = mutate(
        name,
        "<!-- /T736-ASSIGNMENT-DEFAULTS -->",
        "T2 = Sonnet high.\n<!-- /T736-ASSIGNMENT-DEFAULTS -->",
    )
# One-file mutants for the remaining rows.
mutants["spawn-sonnet-t2-alt-order"] = mutate(
    "spawn",
    "<!-- /T736-ASSIGNMENT-DEFAULTS -->",
    "Sonnet high = T2 이다.\n<!-- /T736-ASSIGNMENT-DEFAULTS -->",
)
mutants["director-builder-max-default-added"] = mutate(
    "director",
    "<!-- /T736-ASSIGNMENT-DEFAULTS -->",
    "빌더는 max 를 기본으로 쓴다.\n<!-- /T736-ASSIGNMENT-DEFAULTS -->",
)
mutants["builder-max-exclusion-dropped"] = mutate(
    "builder", "빌더 후보는 max 를 빼고 고른다", "빌더 후보도 모든 런그를 고른다"
)
mutants["sol-max-boundary-dropped"] = mutate(
    "builder", "Sol max 는 T3 코어가 필요할 때만", "Sol max 도 기본 후보다"
)
mutants["director-cite-decision-dropped"] = mutate(
    "director", "(출처: 2026-09-26 운영자 결정", "(출처: 최근 운영자 결정"
)
mutants["director-cite-4098-dropped"] = mutate(
    "director", "note/2026-09-26/grade-cost-table", "note/2026-09-26/effort-table"
)
mutants["spawn-no-bench-rule-dropped"] = mutate(
    "spawn", "벤치 수치는 이 문서에 복사하지 않는다.", ""
)
mutants["director-wrk-enforce-dropped"] = mutate(
    "director", "wrk 도 `--role builder` 에서 max 를 거부한다", "wrk 가 참고한다"
)
mutants["terra-dominated-dropped"] = mutate(
    "spawn", "Terra 는 모든 급에서 지배당한다", "Terra 도 모든 급의 후보다"
)
mutants["terra-reserve-only-weakened"] = mutate(
    "builder", "Terra 전용으로 확인될 때만 보조로 쓴다", "Terra 로 부하를 분산한다"
)
# A builder could read "Sol default xhigh" as the tool default and launch
# `-m codex-sol` bare — getting max. The spelling-default warning must stay.
mutants["sol-codex-default-warning-dropped"] = mutate(
    "spawn",
    "`codex-sol` 철자 자체의 기본값은 max 라서 Sol 배정은 `--effort` 명시로 한다",
    "`codex-sol` 철자로 바로 띄운다",
)
# The named xhigh builder exceptions keep the seat rule consistent with
# builder-grok/builder-luna/E6 xhigh; dropping them hides the carve-out.
mutants["xhigh-exceptions-dropped"] = mutate(
    "builder",
    "별도 승인된 xhigh 빌더 —\n  `builder-grok`·`builder-luna`·E6 xhigh 철자 — 는 그대로다",
    "",
)
# Opus low's gate=escalation caveat is what keeps the S/A+/A default honest —
# lifting it is a scopefuel catalog change, not this PR.
mutants["opus-low-gate-dropped"] = mutate(
    "spawn", "Opus low 는 현재 카탈로그에서 gate=escalation 이라 아직 그대로 못 쓴다", "Opus low 도 바로 쓸 수 있다"
)
mutants["opus-low-scope-caveat-dropped"] = mutate(
    "builder", "scopefuel 카탈로그 변경이며", "임의로 고쳐도 되며"
)
mutants["e6-sol-priority-dropped"] = mutate(
    "spawn", "E6 arm 우선 측정 대상", "E6 측정 대상이 아니다"
)
mutants["claude-shared-window-dropped"] = mutate(
    "builder", "하나의 주간 창을 나누므로", "각각 별개의 주간 창이므로"
)
mutants["claude-splus-to-opus-max"] = mutate(
    "director", "S+ = Opus medium", "S+ = Opus max"
)
mutants["claude-t3-tester-weakened"] = mutate(
    "spawn", "T3 tester 는 Opus xhigh", "T3 tester 는 Opus low"
)
mutants["luna-max-downgraded"] = mutate(
    "builder", "A+ = Luna max", "A+ = Luna low"
)
mutants["claude-opus-low-dropped"] = mutate(
    "director", "Opus low**(모든 Sonnet", "Sonnet high**(모든 Sonnet"
)
mutants["no-opus-max-dropped"] = mutate(
    "builder", "Opus max 는 쓰지 않는다", "Opus max 도 쓴다"
)
# "wrk spelling defaults are not the policy" is what keeps the kept-at-high
# builder defaults from being read as the cost-rule mapping.
mutants["wrk-defaults-as-policy"] = mutate(
    "director", "wrk 철자 기본값은\n  정책이 아니다", "wrk 철자 기본값이 곧 정책이다"
)
mutants["builder-sol-high-dropped"] = mutate(
    "spawn", "Sol 빌더는 Sol high(wrk 기본값 그대로", "Sol 빌더는 상황에 따라"
)
# The Sol-high-is-not-a-candidate caveat keeps the seat default from being
# read as grade eligibility (S-R3-1).
mutants["sol-high-seat-caveat-dropped"] = mutate(
    "builder", "자체는 미측정 C 라 배정 후보가 아니라 좌석 고정값이다", "자체는 이미 측정된 S 후보다"
)
# While Opus low is gated the interim "cheapest usable" clause prevents
# ad-hoc S/A+/A picks (N-R3-1).
mutants["opus-low-interim-dropped"] = mutate(
    "director", "해제 전까지 S·A+·A 도 사용 가능 후보 중 비용 최소로 고른다\n  (현재 그 다음 저가는", ""
)
# The #738 merge status keeps the gate caveat from reading as an
# open-ended block (director-1: merged, installing soon).
mutants["opus-low-738-dropped"] = mutate(
    "spawn", "scopefuel #738 에서 merge 됐고 설치 예정이다(scopefuel 카탈로그 변경이며", "언젠가 해제될 것이다(scopefuel 카탈로그 변경이며"
)
# The interim detail pins the corrected per-grade output (S-R4-1): A's
# cheapest usable candidate is Sonnet low, not Opus medium.
mutants["opus-low-interim-detail-wrong"] = mutate(
    "builder", "S·A+ = Opus medium·A = Sonnet low", "S·A+·A = Opus medium"
)
# E6 measurement rungs are worker-side — builder max stays closed (N-R4-1).
mutants["worker-e6-rungs-dropped"] = mutate(
    "director", "워커 E6 측정 런그다(#704)", "빌더 E6 측정 런그다(#704)"
)
# The contradictory "worker max remains only ..." sentence must not come
# back — only the forbidden guard catches this class.
mutants["worker-max-remnant-back"] = mutate(
    "director",
    "<!-- /T736-ASSIGNMENT-DEFAULTS -->",
    "워커 쪽의 max 는 Sol 의 T3 코어 필요분과 E6 측정 런그에만 남는다.\n<!-- /T736-ASSIGNMENT-DEFAULTS -->",
)
# Forbidden-pattern mutants (tester round-1 classes): these only the guard
# catches — every required row still reads the same.
mutants["en-builder-may-max"] = mutate(
    "director",
    "<!-- /T736-ASSIGNMENT-DEFAULTS -->",
    "builders may use max for T3 work.\n<!-- /T736-ASSIGNMENT-DEFAULTS -->",
)
mutants["ko-builder-seats-can-max"] = mutate(
    "builder",
    "<!-- /T736-ASSIGNMENT-DEFAULTS -->",
    "빌더 좌석도 T3 에서는 max 런그를 쓸 수 있다.\n<!-- /T736-ASSIGNMENT-DEFAULTS -->",
)
mutants["devin-sole-permission-no-tag"] = mutate(
    "director",
    "<!-- /T736-ASSIGNMENT-DEFAULTS -->",
    "T3 tester 로 devin-swe2-max 단독 배정을 허용한다.\n<!-- /T736-ASSIGNMENT-DEFAULTS -->",
)
mutants["post-block-repeal"] = mutate(
    "spawn",
    "<!-- /T736-ASSIGNMENT-DEFAULTS -->",
    "위 규칙은 폐지됐다 — 빌더 좌석은 max 를 써도 된다.\n<!-- /T736-ASSIGNMENT-DEFAULTS -->",
)
mutants["wrk-help-max-launch"] = mutate(
    "wrk",
    "closed — a builder seat never takes a max rung, marker or not.",
    "open — builder-sol-max launches when armed.",
)
mutants["telemetry-citation-dropped"] = mutate(
    "builder", "`pinion05.github.io/aa-model-telemetry`, 수집 2026-09-23", ""
)
mutants["t1t2-devin-dropped"] = mutate(
    "spawn", "T1/T2 구현 기본은 devin 이다", "T1/T2 는 상황에 따라 배정한다"
)
mutants["swe2max-free-dropped"] = mutate(
    "spawn", "무료이므로 적극 쓴다", "무료다"
)
mutants["scopefuel-authority-dropped"] = mutate(
    "director", "scopefuel --recommend", "추천 도구"
)
mutants["second-grade-table-added"] = mutate(
    "builder",
    "<!-- /T736-ASSIGNMENT-DEFAULTS -->",
    "| 급 | 작업 |\n|---|---|\n| S | 구현 |\n<!-- /T736-ASSIGNMENT-DEFAULTS -->",
)
mutants["benchmark-number-copied"] = mutate(
    "spawn", "측정되면 S 후보.", "측정되면 S 후보. Sol 점수 82.4."
)
mutants["closed-e6-note-dropped"] = mutate(
    "spawn", ")는 닫혔다 — 빌더 좌석은 max 를 못 쓰므로", ")는 측정 전용이다 —"
)
mutants["wrk-seat-rule-removed"] = mutate(
    "wrk",
    'if [[ "${ROLE:-worker}" == builder ]]; then',
    "if false; then",
)
mutants["wrk-seat-rule-ultra-dropped"] = mutate(
    "wrk",
    "      max|ultra)",
    "      max)",
)
# #748: a seat rule that stops reading the kimi home leaves the unflagged
# kimi spellings blind to a max-effort home.
mutants["wrk-seat-rule-kimi-blind"] = mutate(
    "wrk",
    'seat_effort="$(kimi_clone_resolved_effort "${KIMI_TRUST_HOME:-}/config.toml" "$kimi_model")"',
    'seat_effort=""',
)
# #748r2: dropping the default_effort fallback or the literal-string parse
# reopens the tester-found max-home paths.
mutants["wrk-seat-rule-no-model-default"] = mutate(
    "wrk",
    'if (m_seen && (t == "" || (s_seen && !(t in S)))) r = d',
    'r = t',
)
mutants["wrk-seat-rule-no-literal-string"] = mutate(
    "wrk",
    "if (substr(s, 1, 1) == sq && substr(s, length(s), 1) == sq)\n        return substr(s, 2, length(s) - 2)",
    'return ""',
)
# #748r3: dropping the real TOML parse, the env overlay, disabled-Thinking or
# the overrides table reopens the round-2 paths. The python
# `resolved = default` is the primary-path default fallback the awk `r = d`
# mutant above covers for the degraded path.
mutants["wrk-seat-rule-no-real-toml"] = mutate(
    "wrk",
    "    import tomllib",
    "    import os as tomllib",
)
mutants["wrk-seat-rule-py-no-model-default"] = mutate(
    "wrk",
    "    resolved = default",
    "    resolved = effort",
)
mutants["wrk-seat-rule-env-blind"] = mutate(
    "wrk",
    'env_eff="${KIMI_MODEL_THINKING_EFFORT:-}"',
    'env_eff=""',
)
mutants["wrk-seat-rule-enabled-ignored"] = mutate(
    "wrk",
    'if thinking.get("enabled") is False and not always:',
    "if False:",
)
mutants["wrk-seat-rule-overrides-dropped"] = mutate(
    "wrk",
    'over = table(model.get("overrides"))',
    "over = {}",
)
# The capabilities-tag always shape, the bounded env list and effort=off all
# gate refusal paths; dropping any reopens a round-3 attack.
mutants["wrk-seat-rule-no-cap-always"] = mutate(
    "wrk",
    '"always_thinking" in caps',
    "False",
)
mutants["wrk-seat-rule-env-unbounded"] = mutate(
    "wrk",
    'if env_eff in {"minimal", "low", "medium", "high", "xhigh", "max", "ultra", "off", "on"}:',
    "if env_eff:",
)
mutants["wrk-seat-rule-off-ignored"] = mutate(
    "wrk",
    'if effort == "off" and not always:',
    "if False:",
)
# CodeRabbit #153: an unbounded env passthrough on the no-config path, an env
# stand-in for a missing pinned clone, and a quote-eating overrides strip
# each reopen a refusal path the tester or reviewer already demonstrated.
mutants["wrk-seat-rule-env-unbounded-nocfg"] = mutate(
    "wrk",
    "minimal|low|medium|high|xhigh|max|ultra|off|on",
    "minimal|low|medium|high",
)
mutants["wrk-e6-clone-env-standin"] = mutate(
    "wrk",
    '      [[ -r "$KIMI_TRUST_HOME/config.toml" ]] ||\n'
    '        die "$MODEL needs a $GATE_EFFORT_PIN-effort Kimi clone at $KIMI_TRUST_HOME (config.toml missing); refresh it with: bin/kimi-clone-home --effort $GATE_EFFORT_PIN"\n',
    "",
)
mutants["wrk-seat-rule-env-raw-nocfg"] = mutate(
    "wrk",
    'printf \'%s\\n\' "$norm"',
    'printf \'%s\\n\' "$env_eff"',
)
mutants["wrk-seat-rule-awk-overrides-quote"] = mutate(
    "wrk",
    'sub(/\\.overrides$/, "", mh)',
    'sub(/[."]?\\.overrides.*$/, "", mh)',
)
# #748: the stale "marked rung needs a REF" claim must go RED in every
# scanned doc; dropping the corrected wording goes RED via the required row.
mutants["builder-ref-required-back"] = mutate(
    "builder",
    "`--operator-request` REF를\n요구하지 않는다",
    "`--operator-request`가 추가로\n필요하다",
)
mutants["spawn-ref-required-back"] = mutate(
    "spawn",
    "`--operator-request` REF를 요구하지 않는다",
    "`--operator-request`가 추가로 필요하다",
)
mutants["readme-ref-required-back"] = mutate(
    "readme",
    "`--operator-request` REF를 요구하지 않는다",
    "`--operator-request` 추가",
)
mutants["wrk-ref-required-back"] = mutate(
    "wrk",
    "so no --operator-request REF is enforced there",
    "additionally need --operator-request REF",
)
mutants["builder-explicit-no-ref-dropped"] = mutate(
    "builder",
    "`--operator-request` REF를\n요구하지 않는다",
    "`--operator-request` REF를\n요구한다",
)
mutants["wrk-builder-sol-back-to-max"] = mutate(
    "wrk",
    "builder-sol|captain-sol) PROFILE_KIND=codex; PROFILE_MODEL=gpt-6-sol; DEFAULT_EFFORT=high",
    "builder-sol|captain-sol) PROFILE_KIND=codex; PROFILE_MODEL=gpt-6-sol; DEFAULT_EFFORT=max",
)
mutants["policy-builder-sol-back-to-max"] = mutate(
    "policy",
    '"builder-sol": {\n      "default_effort": "high"',
    '"builder-sol": {\n      "default_effort": "max"',
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

# ---------------------------------------------------------------------------
# Runtime half: the seat rule and the new builder-sol default must hold in a
# real spawn against the fixtures (the mutants above cover text drift only).
# ---------------------------------------------------------------------------
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROMPT="$TMP/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"
export CLINEPASS_GATE_KEY_FILE="$TMP/clinepass-gate-key.txt"
printf 'fixture-gate-key\n' >"$CLINEPASS_GATE_KEY_FILE"

spawn_t736() {
  local model="$1"; shift
  : >"$TMP/herdr.log"
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="$TMP/absent-arbiter" XDG_DATA_HOME="$TMP/xdg" \
    ARBITER_INBOX_ROOT="$TMP/inbox" WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml" \
    PANEWIRE_BIN="$ROOT/tests/fixtures/panewire" HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
    WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_LAUNCH_LOG="$TMP/launch.log" \
    WRK_REFRESH_LOG="$TMP/refresh.log" WRK_REFRESH_PID_LOG="$TMP/refresh.pids" \
    WRK_REFRESH_TIMEOUT_S=5 \
    "$ROOT/bin/wrk" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture --t T1 "$@"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# builder-sol under --role builder now launches codex-sol at effort high and
# consults the catalog at high (was max before 2026-09-26).
: >"$TMP/launch.log"
spawn_t736 builder-sol --role builder --lane builder-lane --parent parent-lane \
  --job t736-builder-sol >/dev/null
grep -q 'model_reasoning_effort=high' "$TMP/herdr.log" ||
  fail "builder-sol must launch at effort high: $(cat "$TMP/herdr.log")"
grep -q 'policy launch codex-sol effort=high' "$TMP/launch.log" ||
  fail "builder-sol must consult codex-sol at effort high: $(cat "$TMP/launch.log")"
echo "PASS builder-sol launches codex-sol@high and consults the catalog at high"

# An explicit --effort max on a builder seat dies on the seat rule, not on a
# profile pin (builder-sol itself carries no rung pin).
set +e
out="$(spawn_t736 builder-sol --role builder --lane builder-lane --parent parent-lane \
  --effort max --job t736-builder-sol-max 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "builder-sol --effort max must die rc 2 (rc=$rc): $out"
grep -q 'builder seats never take a max rung' <<<"$out" ||
  fail "builder-sol --effort max refusal must name the seat rule: $out"
echo "PASS builder-sol --effort max dies on the builder-seat rule"

# codex `ultra` is the max tier plus subagents — the seat rule refuses it too;
# without that arm a builder could still take a max-tier rung (tester-found).
set +e
out="$(spawn_t736 builder-sol --role builder --lane builder-lane --parent parent-lane \
  --effort ultra --job t736-builder-sol-ultra 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "builder-sol --effort ultra must die rc 2 (rc=$rc): $out"
grep -q 'builder seats never take a max rung' <<<"$out" ||
  fail "builder-sol --effort ultra refusal must name the seat rule: $out"
echo "PASS builder-sol --effort ultra dies on the builder-seat rule"

# The E6 max-rung spelling dies the same way even with its exact marker armed —
# the seat rule fires before the E6 pin check.
set +e
out="$(SCOPEFUEL_E6_ARM=codex-sol@max \
  spawn_t736 builder-sol-max --role builder --lane builder-lane --parent parent-lane \
  --job t736-e6-max 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "armed builder-sol-max must die rc 2 (rc=$rc): $out"
grep -q 'builder seats never take a max rung' <<<"$out" ||
  fail "builder-sol-max refusal must name the seat rule: $out"
echo "PASS builder-sol-max refused even with SCOPEFUEL_E6_ARM=codex-sol@max"

# Worker-side names keep working: a bare codex-sol worker spawn still resolves
# (the seat rule is builder-scoped), running the Sol model argv.
spawn_t736 codex-sol --job t736-worker-sol >/dev/null
grep -q -- '-m gpt-6-sol' "$TMP/herdr.log" ||
  fail "worker codex-sol must still resolve to gpt-6-sol: $(cat "$TMP/herdr.log")"
echo "PASS worker codex-sol spelling still resolves"

echo "PASS test-assignment-defaults (prose contract + wrk behavior + mutants)"
