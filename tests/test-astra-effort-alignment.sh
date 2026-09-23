#!/usr/bin/env bash
# task #527 요건 ⑦: the astra consultation effort must be one value in every
# place that declares it. This guard compares the two declarations that live
# in THIS repo — bin/wrk's codex-astra DEFAULT_EFFORT and the consult-advisor
# SKILL.md default — so a change to only one of them fails here.
#
# admiral/ARCHITECT.md is the third declaration but lives in another repo; no
# agent-skills test can read it, so that leg is reported, not guarded.
#
# Mutation contract: editing only the codex-astra DEFAULT_EFFORT in bin/wrk
# (or only the SKILL.md default) must turn this guard RED.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
SKILL="$ROOT/consult-advisor/SKILL.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- bin/wrk side: the real resolve_profile() case row ---------------------
wrk_effort="$(sed -n 's/.*codex-astra).*DEFAULT_EFFORT=\([a-z]*\).*/\1/p' "$WRK")"
[[ -n "$wrk_effort" ]] || fail "bin/wrk lost the codex-astra DEFAULT_EFFORT row"
[[ "$(printf '%s\n' "$wrk_effort" | wc -l)" -eq 1 ]] ||
  fail "bin/wrk has more than one codex-astra DEFAULT_EFFORT row: $wrk_effort"

# --- consult-advisor side: the declared consultation default ---------------
skill_effort="$(sed -n 's/.*기본값은 \*\*\(low\|medium\|high\|xhigh\|max\|ultra\)\*\*.*/\1/p' "$SKILL")"
[[ -n "$skill_effort" ]] ||
  fail "consult-advisor/SKILL.md lost the '기본값은 **<effort>**' declaration"
[[ "$(printf '%s\n' "$skill_effort" | wc -l)" -eq 1 ]] ||
  fail "consult-advisor/SKILL.md declares more than one effort default: $skill_effort"

[[ "$wrk_effort" == "$skill_effort" ]] ||
  fail "astra consult effort drifted: bin/wrk=$wrk_effort consult-advisor=$skill_effort"
[[ "$wrk_effort" == "xhigh" ]] ||
  fail "astra consult effort must be xhigh (note/2026-09-22/task527-astra-effort-alignment); got $wrk_effort"

# The "max only on explicit operator request" half of the requirement.
grep -q 'max 는 운영자가 명시할 때만' "$SKILL" ||
  fail "consult-advisor/SKILL.md lost the 'max only when the operator specifies it' clause"

echo "PASS test-astra-effort-alignment: wrk=$wrk_effort consult-advisor=$skill_effort"
