#!/usr/bin/env bash
# #736: assignment defaults contract (operator decision 2026-09-26, decision
# 4088 B + the same-day scope table). The three skill files must each carry the
# T736 block; bin/wrk must refuse a max rung on a builder seat and default
# builder-sol to high; gate_policy.json must agree. Every mutant weakens one
# policy row in-memory and must go RED by assertion — repository files are
# never modified.
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
    ("builder-never-max", r"빌더 좌석은 max 런그를 쓰지 않는다"),
    ("builder-floor", r"high 이하, 또는 devin 프로필"),
    ("builder-sol-high", r"Sol 빌더는? Sol high"),
    ("max-t3-only", r"max effort 는 T3 구현 워커와 T3 tester 에만\s*예약한다"),
    ("wrk-enforces", r"wrk 도? `?--role builder`? 에서 max 를 거부한다"),
    ("t1t2-devin", r"T1/T2 구현 기본은 devin"),
    ("swe2max-free", r"SWE-2 max[^\n]{0,60}?무료이므로 적극 쓴다"),
    ("devin-sole-restriction", r"devin\(A\+\)은 T3·S 의 단독 구현자·단독 tester 가 되지 않는다"),
    ("tier-t3", r"T3 코어·tester = Opus xhigh / Sol xhigh"),
    ("sol-max-t3core", r"Sol max 는?[^\n]*?T3 코어[^\n]*한정"),
    ("tier-t2", r"T2 = Sonnet high / Terra high~xhigh 또는 Sol high"),
    ("tier-t1", r"T1·기계적 작업 = Haiku / Luna max / devin swe2-max"),
    ("sol-worker-xhigh", r"Sol 워커 기본 effort 는? `?xhigh`?"),
    ("terra-replaced", r"Terra max 는? Sol high~xhigh 로 대체"),
    ("terra-auxiliary", r"Sol 을? 못 쓸 때의 보조"),
    ("terra-no-load-claim", r"부하를 분산한다\"?고 주장하지 않는다"),
    ("sonnet5-substitute", r"Sonnet 5 는? 우선순위 낮은 codex 대체재"),
    ("cite-decision", r"2026-09-26 운영자 결정"),
    ("cite-telemetry", r"pinion05\.github\.io/aa-model-telemetry"),
    ("cite-collected", r"수집 2026-09-23"),
    ("no-bench-copy", r"벤치 수치는?"),
    ("scopefuel-authority", r"scopefuel --recommend"),
]

# Patterns that must NOT appear anywhere in a skill file — the classes of
# drift this test exists to catch.
FILE_FORBIDDEN = [
    ("builder-max-default",
     r"빌더[^\n]{0,40}?(?:max[^\n]{0,12}?(?:기본|default|권장|허용|쓴다)|(?:기본|default|권장|허용)[^\n]{0,12}?max)"),
    ("devin-sole-granted", r"devin\(A\+\)[^\n]{0,20}?T3[^\n]{0,60}?단독[^\n]{0,80}?(된다|허용)"),
]

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
    # The closed max-rung E6 spellings are documented where the rungs live.
    for name in ("spawn", "builder"):
        assert re.search(CLOSED_E6, flat(d[name])), (
            f"{name}: closed max-rung E6 spellings note missing"
        )

    # bin/wrk: the builder-seat rule must sit on EFFECTIVE_EFFORT, and
    # builder-sol must resolve/catalog-pin at high.
    wrk = flat(d["wrk"])
    assert "builder seats never take a max rung" in wrk, (
        "wrk: builder-seat max refusal message missing"
    )
    assert re.search(r"ROLE:-worker.{0,40}?builder.{0,40}?EFFECTIVE_EFFORT.{0,15}?max", wrk), (
        "wrk: the seat rule must gate on role=builder and resolved effort max"
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
# The two drift classes the brief names must go RED in every file.
for name in SKILLS:
    mutants[f"{name}-builder-max-weakened"] = mutate(
        name, "빌더 좌석은 max 런그를 쓰지 않는다", "빌더 좌석은 보통 max 를 피한다"
    )
    mutants[f"{name}-builder-max-reintroduced"] = mutate(
        name, "Sol 빌더는", "빌더 좌석의 기본은 max 런이며, Sol 빌더는"
    )
    mutants[f"{name}-devin-sole-weakened"] = mutate(
        name, "단독 구현자·단독 tester 가 되지 않는다", "단독 구현자·단독 tester 도 된다"
    )
    reserve_old = (
        "T3 구현 워커와\n  T3 tester 에만 예약한다"
        if name == "spawn"
        else "T3 구현 워커와 T3 tester 에만\n  예약한다"
    )
    mutants[f"{name}-max-reservation-dropped"] = mutate(
        name, reserve_old, "주로 T3 에 쓴다"
    )
# One-file mutants for the remaining rows.
mutants["director-builder-max-default-added"] = mutate(
    "director",
    "Sonnet 5 는 우선순위 낮은 codex 대체재",
    "Sonnet 5 는 우선순위 낮은 codex 대체재 — 빌더는 max 를 기본으로 쓴다",
)
mutants["builder-floor-weakened"] = mutate(
    "builder", "high 이하, 또는 devin 프로필이다", "medium 이하만 허용한다"
)
mutants["builder-solmax-t3core-dropped"] = mutate(
    "builder", "Sol max 는 T3 코어\n  한정", "Sol max 도 쓸 수 있다"
)
mutants["director-cite-decision-dropped"] = mutate(
    "director", "(출처: 2026-09-26 운영자 결정", "(출처: 최근 운영자 결정"
)
mutants["spawn-no-bench-rule-dropped"] = mutate(
    "spawn", "벤치 수치는 이 문서에 복사하지 않는다.", ""
)
mutants["director-wrk-enforce-dropped"] = mutate(
    "director", "wrk 도 `--role builder` 에서 max 를 거부한다", "wrk 가 참고한다"
)
mutants["terra-replacement-dropped"] = mutate(
    "spawn", "Terra max 는 Sol high~xhigh 로\n  대체한다", "Terra max 도 유효하다"
)
mutants["sol-xhigh-default-weakened"] = mutate(
    "spawn", "Sol 워커 기본 effort 는 `xhigh`", "Sol 기본 effort 는 max"
)
mutants["tier-t2-weakened"] = mutate(
    "builder", "T2 = Sonnet high / Terra high~xhigh 또는 Sol high", "T2 = Sonnet max"
)
mutants["tier-t1-dropped"] = mutate(
    "director", "Haiku / Luna max / devin swe2-max", "Haiku"
)
mutants["opus-t3-weakened"] = mutate(
    "spawn", "T3 코어·tester = Opus xhigh / Sol xhigh", "T3 코어·tester = Opus high / Sol xhigh"
)
mutants["sonnet5-dropped"] = mutate(
    "spawn", "Sonnet 5 는 우선순위 낮은 codex 대체재", "Sonnet 5 도 codex 대체재다"
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
    "spawn", "주장하지 않는다.", "주장하지 않는다. Sol 점수 82.4."
)
mutants["closed-e6-note-dropped"] = mutate(
    "spawn", ")는 닫혔다 — 빌더 좌석은 max 를 못 쓰므로", ")는 측정 전용이다 —"
)
mutants["wrk-seat-rule-removed"] = mutate(
    "wrk",
    'if [[ "${ROLE:-worker}" == builder && "$EFFECTIVE_EFFORT" == max ]]; then',
    "if false; then",
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
