#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="$ROOT/bin/arbiter"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROMPT="$TMP/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"

# ROB-1252: cc-qwen38/cc-glm read the clinepass gate key from this file at
# spawn time (never from ~/.claude/); point it at a harmless fixture value.
export CLINEPASS_GATE_KEY_FILE="$TMP/clinepass-gate-key.txt"
printf 'fixture-gate-key\n' >"$CLINEPASS_GATE_KEY_FILE"

# ROB-1199: the suite must never reach a real arbiter state db or the real inbox.
# ARBITER_BIN points at nothing by default, so every pre-existing case keeps
# exercising the installation-transition path; the arbiter section below opts in.
export ARBITER_BIN="$TMP/absent-arbiter"
export XDG_DATA_HOME="$TMP/xdg"
export ARBITER_INBOX_ROOT="$TMP/inbox"

# R20: `wrk done/escalate/joined` now notify panewire. The suite must never
# reach a real one, so every case runs against the silent fixture below; the
# R20 section opts into capture, failure and stalling through its environment.
PANEWIRE="$ROOT/tests/fixtures/panewire"
export PANEWIRE_BIN="$PANEWIRE"

run_fail() {
  if "$@" >/dev/null 2>&1; then
    echo "expected failure: $*" >&2
    exit 1
  fi
}

expect_exit() {
  local want="$1"; shift
  local rc=0
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne "$want" ]]; then
    echo "expected exit $want, got $rc: $*" >&2
    exit 1
  fi
}

# --t is required by wrk; supply one unless the case under test provides its own.
spawn_base() {
  local model="$1"; shift
  local extra=("$@")
  case " ${extra[*]-} " in *" --t "*) ;; *) extra+=(--t T1) ;; esac
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="${TEST_ARBITER_BIN:-$TMP/absent-arbiter}" \
    WRK_FIXTURE_SCENARIO="${TEST_FIXTURE_SCENARIO:-spawn}" WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_FIXTURE_MARKER="${WRK_FIXTURE_MARKER:-}" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S="${WRK_REFRESH_TIMEOUT_S:-5}" \
    "$WRK" spawn \
    -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture "${extra[@]}"
}

arb() { "$ARBITER" "$@"; }

"$WRK" --help >/dev/null
spawn_help_out="$("$WRK" spawn --help)"
grep -q -- '--landing-strict' <<<"$spawn_help_out"
"$WRK" find --help >/dev/null
"$WRK" name-sync --help >/dev/null
"$WRK" profiles --help >/dev/null
run_fail "$WRK" profiles --bogus
run_fail "$WRK" spawn -c "$ROOT" -p "$PROMPT" -w w -l fixture
run_fail "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --bogus
run_fail "$WRK" nope

# ROB-1190 ④-2: wrk profiles — 기계 판독 가능한 프로필 목록. oc-omni 가 포함돼야 한다
# (드리프트 방지: scopefuel 이 추천하는데 wrk 가 못 띄우는 상태 방지).
profiles_out="$("$WRK" profiles)"
grep -qx 'oc-omni' <<<"$profiles_out"
grep -qx 'kimi-k3' <<<"$profiles_out"
grep -qx 'kimi-k27' <<<"$profiles_out"
grep -qx 'kimi-k3-low' <<<"$profiles_out"
grep -qx 'codex-terra-max' <<<"$profiles_out"
grep -qx 'captain-opus' <<<"$profiles_out"
grep -qx 'captain-sol' <<<"$profiles_out"
grep -qx 'captain-astra' <<<"$profiles_out"
grep -qx 'codex-astra' <<<"$profiles_out"
if grep -qx 'codex-ultra' <<<"$profiles_out"; then exit 1; fi
if grep -qx 'codex-luna-ultra' <<<"$profiles_out"; then exit 1; fi

name_out="$(WRK_FIXTURE_SCENARIO=find-name HERDR_BIN="$HERDR" "$WRK" find orch)"
grep -q 'pane_id=w:p1' <<<"$name_out"
grep -q 'ACTUAL SCREEN LAST LINE' <<<"$name_out"
[[ "$(WRK_FIXTURE_SCENARIO=find-name HERDR_BIN="$HERDR" "$WRK" find orch --pane-only)" == "w:p1" ]]
label_out="$(WRK_FIXTURE_SCENARIO=find-label HERDR_BIN="$HERDR" "$WRK" find target)"
grep -q 'match=label' <<<"$label_out"
grep -q 'pane_id=w:p2' <<<"$label_out"
run_fail env WRK_FIXTURE_SCENARIO=find-multi HERDR_BIN="$HERDR" "$WRK" find target
run_fail env WRK_FIXTURE_SCENARIO=find-multi HERDR_BIN="$HERDR" "$WRK" find target --pane-only
priority_out="$(WRK_FIXTURE_SCENARIO=name-priority HERDR_BIN="$HERDR" "$WRK" find target)"
grep -q 'pane_id=w:p1' <<<"$priority_out"
if grep -q 'pane_id=w:p2' <<<"$priority_out"; then exit 1; fi

mkdir -p "$TMP/home-old/.local/bin"
ln -s "$HERDR" "$TMP/home-old/.local/bin/herdr"
old_sync="$(HOME="$TMP/home-old" WRK_FIXTURE_SCENARIO=name-sync "$ROOT/bin/herdr-name-sync")"
new_sync="$(HERDR_BIN="$HERDR" WRK_FIXTURE_SCENARIO=name-sync "$WRK" name-sync)"
[[ "$old_sync" == "$new_sync" ]]
apply_sync="$(HERDR_BIN="$HERDR" WRK_FIXTURE_SCENARIO=name-sync "$WRK" name-sync build)"
grep -q "w:p3" <<<"$apply_sync"

: >"$TMP/herdr.log"
: >"$TMP/scopefuel.log"
canonical_out="$(spawn_base codex-terra --effort max)"
grep -q 'codex-terra-max' "$TMP/scopefuel.log"
grep -q -- '-m gpt-5.6-terra' "$TMP/herdr.log"
grep -q 'model_reasoning_effort=max' "$TMP/herdr.log"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
grep -q 'model=codex-terra' <<<"$canonical_out"

profiles=(
  "opus:opus" "sonnet:sonnet" "sonnet-med:sonnet" "haiku:haiku" "fable:fable"
  "codex:codex-max" "codex-sol:codex-max" "codex-med:codex-terra-max"
  "codex-luna:codex-luna-max" "codex-luna-hi:codex-luna-max"
  "codex-max:codex-max" "codex-terra:codex-terra-max"
  "codex-terra-max:codex-terra-max" "codex-luna-max:codex-luna-max"
  "kiro:kiro-sol" "kiro-opus:kiro-opus" "kiro-sonnet:kiro-sonnet"
  "kiro-sol:kiro-sol" "kiro-luna:kiro-sol" "kiro-cheap:kiro-cheap"
  "kiro-glm:kiro-sol" "kiro-deepseek:kiro-sol" "kiro-minimax:kiro-sol"
  "kiro-minimax21:kiro-sol" "kiro-haiku:kiro-haiku"
  "kiro-opus-xhigh:kiro-opus" "kiro-opus-max:kiro-opus"
  "kiro-sol-xhigh:kiro-sol" "kiro-sol-max:kiro-sol"
  "kimi-k3:kimi-k3" "kimi-k27:kimi-k27" "kimi-k3-low:kimi-k3-low"
  "oc-kimi-code:oc-kimi-code" "oc-glm:oc-glm" "oc-kimi-k3:oc-kimi-k3"
  "oc-dsflash:oc-dsflash" "oc-gflash:oc-gflash" "oc-sonnet46:oc-sonnet46"
  "oc-oss:oc-oss" "oc-omni:oc-omni" "oc-qwen37-max:oc-qwen37-max"
  "oc-minimax-m3:oc-minimax-m3" "grok:grok-hi" "grok-hi:grok-hi" "grok-med:grok-hi" "grok45:grok-hi" "grok45-med:grok-hi" "grok46:grok-hi" "grok46-med:grok-hi"
  "cc-qwen38:cc-qwen38" "cc-glm:cc-glm"
  "cc-dsflash:cc-qwen38" "cc-dspro:cc-qwen38" "cc-glm53:cc-qwen38"
  )
for pair in "${profiles[@]}"; do
  runtime="${pair%%:*}"
  expected="${pair#*:}"
  : >"$TMP/scopefuel.log"
  : >"$TMP/herdr.log"
  spawn_base "$runtime" >/dev/null
  [[ "$(tail -n 1 "$TMP/scopefuel.log")" == "$expected" ]]
done
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m agy -p "$PROMPT" -w w -l fixture

# ROB-1252: cc-qwen38/cc-glm must refuse to spawn when the clinepass gate key
# file is missing, rather than silently spawning without ANTHROPIC_AUTH_TOKEN.
run_fail env CLINEPASS_GATE_KEY_FILE="$TMP/nonexistent-gate-key.txt" \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m cc-qwen38 -p "$PROMPT" -w w -l fixture --t T1

# ROB-1188/ROB-1190 ③-1: ultra 폐기 — codex-ultra/codex-luna-ultra 는 이제 unknown profile.
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m codex-ultra -p "$PROMPT" -w w -l fixture
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m codex-luna-ultra -p "$PROMPT" -w w -l fixture

: >"$TMP/herdr.log"
spawn_base codex-med >/dev/null
grep -q 'model_reasoning_effort=medium' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base codex-med --effort high >/dev/null
grep -q 'model_reasoning_effort=high' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base codex-sol >/dev/null
grep -q 'model_reasoning_effort=max' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base kiro-sol --effort low >/dev/null
grep -q -- '--effort low' "$TMP/herdr.log"
grep -q '/effort low' "$TMP/herdr.log"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m kiro-sol -p "$PROMPT" -w w -l fixture --effort ultra

: >"$TMP/herdr.log"
spawn_base kimi-k3 >/dev/null
grep -q -- '--kind kimi' "$TMP/herdr.log"
grep -q -- '--auto' "$TMP/herdr.log"
grep -q -- '-m kimi-for-coding/k3' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base kimi-k27 >/dev/null
grep -q -- '--kind kimi' "$TMP/herdr.log"
grep -q -- '-m kimi-for-coding/kimi-for-coding' "$TMP/herdr.log"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m kimi-k3 -p "$PROMPT" -w w -l fixture --effort high

# ROB-1307: kimi(0.37.2)는 trust 파일명을 basename 소문자화 + 앞 40자로 정규화해
# 조회한다. 대문자·40자 초과 worktree 이름에서 시딩이 어긋나 Trust 다이얼로그가 스폰을
# 죽였다(orch-mock 실측 2회). 시딩 파일명이 kimi 정규화와 일치하는지 고정한다.
KIMI_TRUST_CWD="$TMP/UPPER-Case-ROB-9999-Very-Long-Worktreex-Tail-Extra"
mkdir -p "$KIMI_TRUST_CWD"
KIMI_TEST_HOME="$TMP/kimi-home"
: >"$TMP/herdr.log"
env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$TMP/absent-arbiter" KIMI_CODE_HOME="$KIMI_TEST_HOME" \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$KIMI_TRUST_CWD" -m kimi-k3 -p "$PROMPT" -w w -l fixture --t T1 >/dev/null
kimi_abs="$(cd "$KIMI_TRUST_CWD" && pwd -P)"
kimi_base="$(printf '%s' "${kimi_abs##*/}" | tr '[:upper:]' '[:lower:]')"
kimi_base="${kimi_base:0:40}"
while [[ -n "$kimi_base" && ! "${kimi_base: -1}" =~ [a-z0-9] ]]; do kimi_base="${kimi_base%?}"; done
kimi_digest="$(printf '%s' "$kimi_abs" | shasum -a 256 | awk '{print $1}')"
kimi_expected="$KIMI_TEST_HOME/workspace-trust/wd_${kimi_base}_${kimi_digest:0:12}"
[[ -f "$kimi_expected" ]]
grep -q "\"root\":\"$kimi_abs\"" "$kimi_expected"
# 원형(대문자·미절단) 이름으로는 쓰이지 않아야 한다 — 그게 이번 버그였다.
[[ ! -e "$KIMI_TEST_HOME/workspace-trust/wd_${kimi_abs##*/}_${kimi_digest:0:12}" ]]
echo "PASS kimi-trust-canonical-filename"

# kimi-k3-low: same argv as kimi-k3, but KIMI_CODE_HOME must be injected via the
# tab-create --env mechanism (LANE_ENV/TAB_ENV precedent), scoped to only this
# profile — kimi-k3/kimi-k27 must NOT get KIMI_CODE_HOME.
: >"$TMP/herdr.log"
spawn_base kimi-k3-low >/dev/null
grep -q -- '--kind kimi' "$TMP/herdr.log"
grep -q -- '--auto' "$TMP/herdr.log"
grep -q -- '-m kimi-for-coding/k3' "$TMP/herdr.log"
grep -q -- '--env KIMI_CODE_HOME=' "$TMP/herdr.log"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m kimi-k3-low -p "$PROMPT" -w w -l fixture --effort high
: >"$TMP/herdr.log"
spawn_base kimi-k3 >/dev/null
if grep -q -- 'KIMI_CODE_HOME' "$TMP/herdr.log"; then exit 1; fi
: >"$TMP/herdr.log"
spawn_base kimi-k27 >/dev/null
if grep -q -- 'KIMI_CODE_HOME' "$TMP/herdr.log"; then exit 1; fi

# ROB-1191 ⑥: Claude opus/sonnet effort wiring via CLI argv (settings.json never written).
SETTINGS_PATH="${HOME}/.claude/settings.json"
if [[ -f "$SETTINGS_PATH" ]]; then
  SETTINGS_SHA_BEFORE="$(shasum -a 256 "$SETTINGS_PATH" | awk '{print $1}')"
else
  SETTINGS_SHA_BEFORE=""
fi
: >"$TMP/herdr.log"
spawn_base opus --effort xhigh >/dev/null
grep -q -- '--effort xhigh' "$TMP/herdr.log"
grep -q -- '--model opus' "$TMP/herdr.log"
# Default effort for opus is xhigh even without override.
: >"$TMP/herdr.log"
spawn_base opus >/dev/null
grep -q -- '--effort xhigh' "$TMP/herdr.log"
# sonnet default=high; override works; fable still rejects --effort
: >"$TMP/herdr.log"
spawn_base sonnet >/dev/null
grep -q -- '--effort high' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base sonnet --effort medium >/dev/null
grep -q -- '--effort medium' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base haiku >/dev/null
grep -q -- '--model haiku' "$TMP/herdr.log"
grep -q -- '--effort low' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base haiku --effort low >/dev/null
grep -q -- '--model haiku' "$TMP/herdr.log"
grep -q -- '--effort low' "$TMP/herdr.log"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m fable -p "$PROMPT" -w w -l fixture --effort high
if [[ -n "$SETTINGS_SHA_BEFORE" ]]; then
  SETTINGS_SHA_AFTER="$(shasum -a 256 "$SETTINGS_PATH" | awk '{print $1}')"
  [[ "$SETTINGS_SHA_BEFORE" == "$SETTINGS_SHA_AFTER" ]]
fi

: >"$TMP/herdr.log"
spawn_base oc-kimi-code >/dev/null
grep -q 'send-keys w:p1 return' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base oc-omni >/dev/null
grep -q -- '--model omniroute/auto/coding' "$TMP/herdr.log"
grep -q 'send-keys w:p1 return' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base oc-qwen37-max >/dev/null
grep -q -- '--model cline-pass/cline-pass/qwen3.7-max' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base oc-minimax-m3 >/dev/null
grep -q -- '--model cline-pass/cline-pass/minimax-m3' "$TMP/herdr.log"
: >"$TMP/herdr.log"
# ROB-1244: 기본 grok = 4.6, grok45 는 명시 롤백 별칭, grok46 은 동의어
spawn_base grok >/dev/null
grep -q -- '-m grok-4.6' "$TMP/herdr.log"
grep -q -- '--effort high' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base grok45 >/dev/null
grep -q -- '-m grok-4.5' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base grok46 >/dev/null
grep -q -- '-m grok-4.6' "$TMP/herdr.log"
: >"$TMP/herdr.log"
once_out="$(env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=prompt-wait-fails WRK_FIXTURE_LOG="$TMP/herdr.log" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" "$WRK" spawn \
  -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1 2>&1)"
grep -q 'model=codex-terra' <<<"$once_out"
grep -q 'landed=yes' <<<"$once_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
[[ "$(grep -c 'agent send-keys w:p1 return' "$TMP/herdr.log")" -eq 1 ]]

# ROB-1321 landing acceptance fixtures. `working` is only a reason to keep
# observing: marker (recent-unwrapped scrollback) or the visible Pasted text
# chip is required before the brief may be called landed.
marker_prompt="$TMP/landing-marker.md"
marker_first_line='marker-source-0123456789012345678901234567890123456789'
marker_expected="${marker_first_line:0:40}"
printf '\n%s\nsecond line\n' "$marker_first_line" >"$marker_prompt"
PROMPT="$marker_prompt"
: >"$TMP/herdr.log"
marker_out="$(TEST_FIXTURE_SCENARIO=landing-marker WRK_FIXTURE_MARKER="$marker_expected" spawn_base codex-terra 2>&1)"
grep -q 'landed=yes' <<<"$marker_out"
grep -q "$marker_first_line" "$TMP/herdr.log"
[[ "$(grep -c '^agent prompt ' "$TMP/herdr.log")" -eq 1 ]]
echo "PASS marker-positive-landed: $marker_out"

PROMPT="$TMP/prompt.md"
: >"$TMP/herdr.log"
# AC1 RED before ROB-1321: the old implementation emits landed=yes here
# solely because the freshly booted agent reports working. A complete first
# observation window must instead re-inject once and then report landed=no.
working_no_marker_out="$(TEST_FIXTURE_SCENARIO=landing-working-no-marker spawn_base codex-terra 2>&1)"
grep -q 'landed=no' <<<"$working_no_marker_out"
grep -q 'action=reinject-once' <<<"$working_no_marker_out"
grep -q 'last_status=working' <<<"$working_no_marker_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS ac1-working-without-marker-retries-then-no: $working_no_marker_out"

: >"$TMP/herdr.log"
delayed_marker_out="$(TEST_FIXTURE_SCENARIO=landing-delayed-marker spawn_base codex-terra 2>&1)"
grep -q 'landed=yes' <<<"$delayed_marker_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
[[ "$(grep -c -- '--source recent-unwrapped' "$TMP/herdr.log")" -ge 3 ]]
echo "PASS ac2-delayed-marker-no-retry: $delayed_marker_out"

: >"$TMP/herdr.log"
retry_out="$(TEST_FIXTURE_SCENARIO=landing-retry spawn_base codex-terra 2>&1)"
grep -q 'landed=retry' <<<"$retry_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS ac3-swallowed-then-retry: $retry_out"

: >"$TMP/herdr.log"
set +e
no_landing_out="$(TEST_FIXTURE_SCENARIO=landing-no spawn_base codex-terra 2>&1)"
no_landing_rc=$?
set -e
[[ "$no_landing_rc" -eq 0 ]]
grep -q 'landed=no' <<<"$no_landing_out"
grep -q 'spawn succeeded but brief landed=no' <<<"$no_landing_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS landed-no-default-exit=$no_landing_rc: $no_landing_out"

: >"$TMP/herdr.log"
set +e
strict_no_landing_out="$(TEST_FIXTURE_SCENARIO=landing-working-no-marker spawn_base codex-terra --landing-strict 2>&1)"
strict_no_landing_rc=$?
set -e
[[ "$strict_no_landing_rc" -eq 76 ]]
grep -q '^OK pane=w:p1 .*landed=no' <<<"$strict_no_landing_out"
grep -q 'spawn succeeded but brief landed=no' <<<"$strict_no_landing_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS ac4-landing-strict exit=$strict_no_landing_rc: $strict_no_landing_out"

: >"$TMP/herdr.log"
scrollout_out="$(TEST_FIXTURE_SCENARIO=landing-scrollback-marker spawn_base codex-terra 2>&1)"
grep -q 'landed=yes' <<<"$scrollout_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
grep -q 'agent read w:p1 --source recent-unwrapped --lines 200' "$TMP/herdr.log"
echo "PASS ac5-scrollback-marker-no-duplicate: $scrollout_out"

: >"$TMP/herdr.log"
pasted_out="$(TEST_FIXTURE_SCENARIO=landing-pasted spawn_base codex-terra 2>&1)"
grep -q 'landed=yes' <<<"$pasted_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
grep -q 'agent read w:p1 --source visible --lines 40' "$TMP/herdr.log"
echo "PASS pasted-chip-queued: $pasted_out"

: >"$TMP/herdr.log"
opencode_retry_out="$(TEST_FIXTURE_SCENARIO=opencode-retry spawn_base oc-omni 2>&1)"
grep -q 'landed=retry' <<<"$opencode_retry_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS opencode-landing-retry: $opencode_retry_out"

: >"$TMP/herdr.log"
observation_fail_out="$(TEST_FIXTURE_SCENARIO=landing-observation-fails spawn_base codex-terra 2>&1)"
grep -q 'landed=no' <<<"$observation_fail_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
echo "PASS ambiguous-observation-no-retry: $observation_fail_out"

rm -f "$TMP/herdr.log"
blocked3="$(WRK_GATE_MODE=3 spawn_base codex-terra 2>&1 || true)"
grep -q 'gate blocked' <<<"$blocked3"
[[ ! -e "$TMP/herdr.log" ]]
blocked4="$(WRK_GATE_MODE=4 spawn_base codex-terra 2>&1 || true)"
grep -q 'measurement unavailable' <<<"$blocked4"
[[ ! -e "$TMP/herdr.log" ]]
rm -f "$TMP/herdr.log"
unsupported="$(WRK_GATE_MODE=unsupported spawn_base codex-terra 2>&1)"
grep -q 'no gate subcommand' <<<"$unsupported"
[[ -e "$TMP/herdr.log" ]]
rm -f "$TMP/herdr.log"
run_fail env WRK_GATE_MODE=broken HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1
SCOPEFUEL_BIN="$TMP/missing-scopefuel" HERDR_BIN="$HERDR" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture \
  --t T1 >"$TMP/missing.out" 2>&1
grep -q 'scopefuel unavailable; quota gate skipped' "$TMP/missing.out"
grep -q 'scopefuel refresh skipped; gate/arbiter did not provide a pool' "$TMP/missing.out"
grep -q 'model=codex-terra' "$TMP/missing.out"

# ROB-1227 D4: refresh is detached, uses the gate-provided pool, and exposes
# failure/timeout warnings without changing the successful spawn.
: >"$TMP/refresh.log"
start_ns="$(python3 -c 'import time; print(time.time_ns())')"
success_out="$(spawn_base codex-terra 2>&1)"
elapsed_ms="$(( ($(python3 -c 'import time; print(time.time_ns())') - start_ns) / 1000000 ))"
grep -q 'model=codex-terra' <<<"$success_out"
[[ "$elapsed_ms" -lt 1800 ]]  # 동일 flake 계열 — 위 timeout 케이스와 같은 근거로 완화
for _ in {1..20}; do
  grep -q '^refresh codex --background$' "$TMP/refresh.log" && break
  sleep 0.05
done
grep -q '^refresh codex --background$' "$TMP/refresh.log"

failed_out="$(WRK_REFRESH_MODE=fail spawn_base codex-terra 2>&1)"
grep -q 'scopefuel refresh failed for pool=codex; spawn already succeeded' <<<"$failed_out"
grep -q 'model=codex-terra' <<<"$failed_out"

timeout_start_ns="$(python3 -c 'import time; print(time.time_ns())')"
: >"$TMP/refresh.pids"
timeout_out="$(WRK_REFRESH_MODE=hang WRK_REFRESH_DELAY=2 WRK_REFRESH_TIMEOUT_S=0.2 spawn_base codex-terra 2>&1)"
timeout_elapsed_ms="$(( ($(python3 -c 'import time; print(time.time_ns())') - timeout_start_ns) / 1000000 ))"
# 2s hang 을 기다리지 않았음을 증명하면 충분하다 — 1000ms 는 부하 있는 머신에서
# 오탐(실측 1075ms flake)이라 hang(2000ms) 대비 명확히 짧은 1800ms 로 완화.
[[ "$timeout_elapsed_ms" -lt 1800 ]]
grep -q 'scopefuel refresh timed out for pool=codex; spawn already succeeded' <<<"$timeout_out"
grep -q 'model=codex-terra' <<<"$timeout_out"
while IFS= read -r refresh_pid; do
  [[ -z "$refresh_pid" ]] || ! ps -p "$refresh_pid" -o pid= | grep -q '[0-9]'
done <"$TMP/refresh.pids"

cp "$SCOPEFUEL" "$TMP/non-executable-scopefuel"
chmod -x "$TMP/non-executable-scopefuel"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$TMP/non-executable-scopefuel" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1

# ---------------------------------------------------------------------------
# ROB-1199/ROB-1201: arbiter admission control. wrk holds no pool mapping — arbiter reads
# the pool out of scopefuel's own gate output and validates it against
# `scopefuel --json`. There is no bypass flag; only an absent/too-old arbiter is
# tolerated, and only with a warning.
# ---------------------------------------------------------------------------

# ⑦ arbiter not installed at all → warn, spawn proceeds (installation transition).
rm -f "$TMP/herdr.log"
absent_out="$(spawn_base codex-terra 2>&1)"
grep -q 'arbiter unavailable' <<<"$absent_out"
grep -q 'model=codex-terra' <<<"$absent_out"
[[ -e "$TMP/herdr.log" ]]

# ⑦ installed arbiter that predates the lease subcommand → warn, spawn proceeds.
rm -f "$TMP/herdr.log"
export TEST_ARBITER_BIN="$ROOT/tests/fixtures/arbiter-legacy"
legacy_out="$(spawn_base codex-terra 2>&1)"
grep -q 'no lease subcommand' <<<"$legacy_out"
grep -q 'model=codex-terra' <<<"$legacy_out"
[[ -e "$TMP/herdr.log" ]]
unset TEST_ARBITER_BIN

# An arbiter command failure is observational for quota_pool; spawning continues.
cp "$ARBITER" "$TMP/non-executable-arbiter"
chmod -x "$TMP/non-executable-arbiter"
rm -f "$TMP/herdr.log"
export TEST_ARBITER_BIN="$TMP/non-executable-arbiter"
nonexec_out="$(spawn_base codex-terra 2>&1)"
grep -q 'quota-pool record unavailable' <<<"$nonexec_out"
grep -q 'model=codex-terra' <<<"$nonexec_out"
[[ -e "$TMP/herdr.log" ]]
unset TEST_ARBITER_BIN

# ⑥ record: the gate passes, arbiter records the pool scopefuel resolved, and the
# worker is handed its own job/resource/profile identity.
export TEST_ARBITER_BIN="$ARBITER"
rm -f "$TMP/herdr.log"
admit_out="$(spawn_base codex-terra --job arb-ok --t T2 2>&1)"
grep -q 'quota_record=codex/quota_pool' <<<"$admit_out"
grep -q 'job=arb-ok' <<<"$admit_out"
grep -q 'ARBITER_JOB=arb-ok' "$TMP/herdr.log"
grep -q 'ARBITER_RESOURCE=codex' "$TMP/herdr.log"
grep -q 'ARBITER_KIND=quota_pool' "$TMP/herdr.log"
grep -q 'ARBITER_PROFILE=codex-terra-max' "$TMP/herdr.log"
grep -q 'ARBITER_STARTED_AT=' "$TMP/herdr.log"
arb status --job arb-ok --json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["quota_pool_records"]; assert len(r)==1 and r[0]["pool"]=="codex" and r[0]["profile"]=="codex-terra-max", d'
arb status --job arb-ok --json |
  python3 -c 'import json,sys; j=json.load(sys.stdin)["jobs"]; assert len(j)==1 and j[0]["t_level"]=="T2" and j[0]["owner_lane"]=="default", j'
python3 - "$ARBITER_INBOX_ROOT/arb-ok/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["agent_label"] == "fixture", event
PY

# ⑥ the pool is a record, not a mutex: another job asking for the same pool
# succeeds and both records remain visible.
rm -f "$TMP/herdr.log"
second_out="$(spawn_base codex-terra --job arb-second --t T2 2>&1)"
grep -q 'quota_record=codex/quota_pool' <<<"$second_out"
arb status --json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=[x for x in d["quota_pool_records"] if x["pool"]=="codex"]; assert {x["job_id"] for x in r} >= {"arb-ok","arb-second"}, d'

# A different profile mapping to a different pool is unaffected by that denial.
rm -f "$TMP/herdr.log"
other_out="$(spawn_base kiro-sol --job arb-other --t T1 2>&1)"
grep -q 'quota_record=kiro/quota_pool' <<<"$other_out"

# ---------------------------------------------------------------------------
# ROB-1326: a duplicate arbiter job is an exact-once boundary, not an advisory.
# All cases use the existing fixture Herdr and this suite's temporary arbiter DB.
# ---------------------------------------------------------------------------

# AC1: an active row stops before tab creation, with a stable dedicated exit and
# enough evidence for the owner to investigate.
arb claim --job idem-active --agent-label incumbent --lane incumbent-lane --t T2 >/dev/null
rm -f "$TMP/herdr.log"
set +e
active_dup_out="$(spawn_base codex-terra --job idem-active --t T2 2>&1)"
active_dup_rc=$?
set -e
[[ "$active_dup_rc" -eq 74 ]] || { echo "expected active duplicate exit 74, got $active_dup_rc: $active_dup_out" >&2; exit 1; }
grep -q 'job_id=idem-active' <<<"$active_dup_out"
grep -q 'state=claimed' <<<"$active_dup_out"
grep -q 'owner_lane=incumbent-lane' <<<"$active_dup_out"
[[ ! -e "$TMP/herdr.log" ]] || { echo "active duplicate reached Herdr spawn" >&2; exit 1; }
echo "PASS ROB-1326 AC1 active duplicate fail-closed: $active_dup_out"

# AC2: a released row gets the explicit reclaim transition, then spawns once.
arb claim --job idem-released --agent-label released-old --lane released-old-lane --t T1 >/dev/null
arb lease --job idem-released --kind quota_pool --profile codex-terra-max --gate-output <("$SCOPEFUEL" gate -m codex-terra-max) >/dev/null
arb release --job idem-released --resource codex --kind quota_pool >/dev/null
rm -f "$TMP/herdr.log"
released_dup_out="$(spawn_base codex-terra --job idem-released --t T3 2>&1)"
grep -q '^OK ' <<<"$released_dup_out"
[[ -e "$TMP/herdr.log" ]] || { echo "released job did not reach fixture spawn" >&2; exit 1; }
arb job-get --job idem-released --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["state"] == "leased", d
assert d["recent_event_kinds"].count("job.reclaim") == 1, d
'
echo "PASS ROB-1326 AC2 released duplicate reclaimed then spawned: $released_dup_out"

# AC3: once a live arbiter reported duplicate, an unreadable state is itself a
# fail-closed condition.  The proxy fails only the actual lookup, not --help.
arb claim --job idem-unknown --agent-label unknown-owner --lane unknown-lane --t T1 >/dev/null
export REAL_ARBITER="$ARBITER"
export WRK_ARBITER_PROXY_MODE=job-get-fails
export TEST_ARBITER_BIN="$ROOT/tests/fixtures/arbiter-proxy"
rm -f "$TMP/herdr.log"
set +e
unknown_dup_out="$(spawn_base codex-terra --job idem-unknown --t T1 2>&1)"
unknown_dup_rc=$?
set -e
[[ "$unknown_dup_rc" -eq 75 ]] || { echo "expected unreadable-state exit 75, got $unknown_dup_rc: $unknown_dup_out" >&2; exit 1; }
grep -q 'state lookup failed' <<<"$unknown_dup_out"
[[ ! -e "$TMP/herdr.log" ]] || { echo "unknown duplicate state reached Herdr spawn" >&2; exit 1; }
unset WRK_ARBITER_PROXY_MODE TEST_ARBITER_BIN REAL_ARBITER
echo "PASS ROB-1326 AC3 duplicate lookup failure is fail-closed: $unknown_dup_out"

# AC8: the only active-duplicate escape hatch is explicit and auditable.
export TEST_ARBITER_BIN="$ARBITER"
arb claim --job idem-override --agent-label override-owner --lane override-lane --t T1 >/dev/null
rm -f "$TMP/herdr.log"
override_out="$(spawn_base codex-terra --job idem-override --t T1 --job-dup-ok 2>&1)"
grep -q '^OK ' <<<"$override_out"
grep -q 'job-dup-ok override' <<<"$override_out"
grep -q 'state=claimed' <<<"$override_out"
[[ -e "$TMP/herdr.log" ]] || { echo "explicit duplicate override did not reach Herdr spawn" >&2; exit 1; }
echo "PASS ROB-1326 AC8 explicit active duplicate override: $override_out"

# AC6: a successful fixture spawn writes a queryable receipt.  Its recording
# failure is non-transactional: the pane remains successful but job-get says
# receipt=absent, and wrk emits a warning.
rm -f "$TMP/herdr.log"
receipt_out="$(spawn_base codex-terra --job idem-receipt --t T1 2>&1)"
grep -q '^OK pane=w:p1' <<<"$receipt_out"
arb job-get --job idem-receipt --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = d["receipt"]
assert r["pane_id"] == "w:p1", d
assert r["spawned_at"], d
assert r["label"] == "fixture", d
assert r["profile"] == "codex-terra", d
assert r["workspace"] == "w", d
assert "job.spawned" in d["recent_event_kinds"], d
'
export REAL_ARBITER="$ARBITER"
export WRK_ARBITER_PROXY_MODE=spawn-receipt-fails
export TEST_ARBITER_BIN="$ROOT/tests/fixtures/arbiter-proxy"
rm -f "$TMP/herdr.log"
receipt_fail_out="$(spawn_base codex-terra --job idem-receipt-fail --t T1 2>&1)"
grep -q '^OK pane=w:p1' <<<"$receipt_fail_out"
grep -q 'job.spawned receipt failed' <<<"$receipt_fail_out"
[[ -e "$TMP/herdr.log" ]] || { echo "receipt failure stopped successful fixture spawn" >&2; exit 1; }
arb job-get --job idem-receipt-fail --json | python3 -c '
import json, sys
assert json.load(sys.stdin)["receipt"] == "absent"
'
unset WRK_ARBITER_PROXY_MODE TEST_ARBITER_BIN REAL_ARBITER
export TEST_ARBITER_BIN="$ARBITER"
echo "PASS ROB-1326 AC6 spawn receipt success and non-transactional receipt failure"

# ⑥ spawn failure releases the record instead of leaking it.
rm -f "$TMP/herdr.log"
export TEST_FIXTURE_SCENARIO=tab-create-fails
rollback_out="$(spawn_base opus --job arb-rollback --t T2 2>&1 || true)"
unset TEST_FIXTURE_SCENARIO
grep -q 'arbiter quota-pool record released after spawn failure: claude job=arb-rollback' <<<"$rollback_out"
arb status --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert not [r for r in d["quota_pool_records"] if r["pool"] == "claude"], d["quota_pool_records"]
events = __import__("pathlib").Path(__import__("os").environ["ARBITER_INBOX_ROOT"], "arb-rollback", "events")
assert any(__import__("json").loads(p.read_text())["kind"] == "quota_pool.release" for p in events.glob("*.json")), events
'
# The released pool can be recorded again right away.
rm -f "$TMP/herdr.log"
retry_out="$(spawn_base opus --job arb-retry --t T2 2>&1)"
grep -q 'quota_record=claude/quota_pool' <<<"$retry_out"

# A released duplicate reclaims the existing row and then records the pool;
# ordinary duplicate claim still never deletes its original history.
arb release --job arb-retry --resource claude --kind quota_pool >/dev/null
rm -f "$TMP/herdr.log"
dup_out="$(spawn_base opus --job arb-retry --t T2 2>&1)"
grep -q "reclaimed" <<<"$dup_out"
grep -q 'quota_record=claude/quota_pool' <<<"$dup_out"
arb job-get --job arb-retry --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["recent_event_kinds"].count("job.reclaim") == 1'

# ⑥ quota_pool record failure warns and still spawns; this is not a quota gate.
cat >"$TMP/quota-record-failing-arbiter" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "lease" && "\$*" == *"quota_pool"* ]]; then
  echo "fixture: quota record unavailable" >&2
  exit 7
fi
exec "$ARBITER" "\$@"
EOF
chmod +x "$TMP/quota-record-failing-arbiter"
rm -f "$TMP/herdr.log"
export TEST_ARBITER_BIN="$TMP/quota-record-failing-arbiter"
record_failed_out="$(spawn_base codex-terra --job arb-record-fail --t T1 2>&1)"
grep -q 'arbiter quota-pool record failed' <<<"$record_failed_out"
grep -q 'model=codex-terra' <<<"$record_failed_out"
[[ -e "$TMP/herdr.log" ]]
arb status --job arb-record-fail --json |
  python3 -c 'import json,sys; assert json.load(sys.stdin)["quota_pool_records"] == [], sys.stdin'
unset TEST_ARBITER_BIN

# Captain contract: the real arbiter claim artifact remains an envelope while
# wrk's upward-facing events stay flat. owner_lane is always the captain's own
# lane; parent_lane is recorded as information, while panewire resolves parent
# routing from lanes.json.
export TEST_ARBITER_BIN="$ARBITER"
CAPTAIN_REPORT="$TMP/captain-report.md"
printf 'captain report terminal line\n' >"$CAPTAIN_REPORT"
: >"$TMP/herdr.log"
captain_opus_out="$(spawn_base captain-opus --role captain --lane captain-lane --parent parent-lane --job captain-opus-job --t T1 2>&1)"
grep -q 'model=captain-opus' <<<"$captain_opus_out"
grep -q -- '--model opus' "$TMP/herdr.log"
grep -q -- '--effort high' "$TMP/herdr.log"
python3 - "$ARBITER_INBOX_ROOT/captain-opus-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert set(event) == {"created_at", "job_id", "kind", "payload", "seq"}, event
assert event["kind"] == "job.claim", event
assert event["payload"] == {
    "agent_label": "fixture", "owner_lane": "captain-lane", "parent_lane": "parent-lane",
    "role": "captain", "t_level": "T1",
}, event
PY
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" escalate captain-opus-job --question 'need parent decision' >/dev/null
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" joined captain-opus-job --pr https://example.invalid/pr/1 --head deadbeef --report "$CAPTAIN_REPORT" >/dev/null
python3 - "$ARBITER_INBOX_ROOT/captain-opus-job/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
escalate = next(e for e in events if e["kind"] == "job.escalate")
joined = next(e for e in events if e["kind"] == "job.joined")
assert escalate["owner_lane"] == joined["owner_lane"] == "captain-lane", events
assert escalate["parent_lane"] == joined["parent_lane"] == "parent-lane", events
assert escalate["reason"] == "captain escalation" and escalate["question"] == "need parent decision", escalate
assert joined["reason"] == "captain joined PR" and joined["pr"].endswith("/1") and joined["head"] == "deadbeef", joined
for event in (escalate, joined):
    assert {"pane_id", "report_path", "report_last_line"} <= set(event), event
assert "payload" not in escalate and "payload" not in joined, events
PY

# Reclaim must replace completion metadata, not retain the first claim. First
# reclaim a worker as a captain, then reclaim again under a different parent.
arb claim --job captain-reclaim-job --lane worker-lane --agent-label worker-label --t T1 >/dev/null
arb lease --job captain-reclaim-job --resource captain-reclaim-resource --kind path >/dev/null
arb release --job captain-reclaim-job --resource captain-reclaim-resource --kind path --force >/dev/null
arb claim --job captain-reclaim-job --lane captain-old-lane --agent-label captain-old-label --t T1 \
  --role captain --parent-lane parent-old --reclaim-released >/dev/null
arb event --job captain-reclaim-job --kind job.spawned \
  --payload-json '{"owner_lane":"captain-old-lane","label":"captain-old-label","pane_id":"w1:p1"}' >/dev/null
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" escalate captain-reclaim-job --question 'first reclaim is captain' >/dev/null
arb lease --job captain-reclaim-job --resource captain-reclaim-resource-2 --kind path >/dev/null
arb release --job captain-reclaim-job --resource captain-reclaim-resource-2 --kind path --force >/dev/null
arb claim --job captain-reclaim-job --lane captain-new-lane --agent-label captain-new-label --t T1 \
  --role captain --parent-lane parent-new --reclaim-released >/dev/null
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" joined captain-reclaim-job --pr https://example.invalid/pr/2 --head feedface --report "$CAPTAIN_REPORT" >/dev/null
python3 - "$ARBITER_INBOX_ROOT/captain-reclaim-job/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
escalate = next(e for e in events if e["kind"] == "job.escalate")
joined = next(e for e in events if e["kind"] == "job.joined")
assert escalate["owner_lane"] == "captain-old-lane", escalate
assert joined["owner_lane"] == "captain-new-lane", joined
assert joined["parent_lane"] == "parent-new", joined
PY
: >"$TMP/herdr.log"
captain_sol_out="$(spawn_base captain-sol --role captain --lane captain-sol-lane --parent parent-lane --job captain-sol-job --t T1 2>&1)"
grep -q 'model=captain-sol' <<<"$captain_sol_out"
grep -q -- '-m gpt-5.6-sol' "$TMP/herdr.log"
: >"$TMP/herdr.log"
captain_astra_out="$(spawn_base captain-astra --role captain --lane captain-astra-lane --parent parent-lane --job captain-astra-job --t T1 2>&1)"
grep -q 'model=captain-astra' <<<"$captain_astra_out"
grep -q -- '-m gpt-6-astra' "$TMP/herdr.log"

# Mutants: a worker-grade profile, missing parent, and a non-high Opus effort
# must all stop before gate/claim/tab creation.
expect_exit 2 spawn_base codex-terra --role captain --lane captain-lane --parent parent-lane --job captain-terra-mutant
expect_exit 2 spawn_base codex-luna --role captain --lane captain-lane --parent parent-lane --job captain-luna-mutant
expect_exit 2 spawn_base captain-opus --role captain --lane captain-lane --job captain-parent-mutant
expect_exit 2 spawn_base captain-opus --role captain --lane captain-lane --parent parent-lane --effort max --job captain-effort-mutant
if grep -q 'captain-.*-mutant' "$ARBITER_INBOX_ROOT"/*/events/* 2>/dev/null; then exit 1; fi

# R19a fixtures must be the exact bytes emitted by the production arbiter and
# wrk writers (claim -> spawned -> escalate -> joined), never hand-maintained
# lookalikes.
PANEVIRE_FIXTURE="$ROOT/tests/fixtures/panewire-r19a"
PANEVIRE_OUTPUT="$TMP/panewire-r19a-output"
"$PANEVIRE_FIXTURE/regen.sh" "$PANEVIRE_OUTPUT"
for fixture in "$PANEVIRE_FIXTURE"/*.json; do
  cmp "$fixture" "$PANEVIRE_OUTPUT/$(basename "$fixture")"
done
[[ "$(find "$PANEVIRE_OUTPUT" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" -eq 4 ]]
unset TEST_ARBITER_BIN
echo "PASS captain profiles, own-lane escalation/JOIN, reclaim metadata, fixture bytes, and fail-closed mutants"

# ⑤ a broken state db is a quota-record failure: warn and still spawn.
rm -f "$TMP/herdr.log"
export TEST_ARBITER_BIN="$ARBITER"
printf 'not a database\n' >"$TMP/xdg/arbiter/state.db"
rm -f "$TMP/xdg/arbiter/state.db-wal" "$TMP/xdg/arbiter/state.db-shm"
schema_failed_out="$(spawn_base grok --job arb-broken --t T1 2>&1)"
grep -q 'arbiter quota-pool claim failed' <<<"$schema_failed_out"
grep -q 'continuing spawn' <<<"$schema_failed_out"
[[ -e "$TMP/herdr.log" ]]
rm -rf "$TMP/xdg/arbiter"
unset TEST_ARBITER_BIN

# ROB-1198 §③: an unclassified job is refused outright — no default T, and the
# refusal happens before the gate, the claim and the spawn.
spawn_untyped() {
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="${TEST_ARBITER_BIN:-$TMP/absent-arbiter}" WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
    "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture "$@"
}
rm -f "$TMP/herdr.log" "$TMP/scopefuel.log"
export TEST_ARBITER_BIN="$ARBITER"
untyped_out="$(spawn_untyped "$@" 2>&1 || true)"
grep -q 'NEEDS_CLASSIFICATION' <<<"$untyped_out"
if grep -q '^OK ' <<<"$untyped_out"; then exit 1; fi
expect_exit 2 spawn_untyped
[[ ! -e "$TMP/herdr.log" ]]                      # nothing spawned
[[ ! -e "$TMP/scopefuel.log" ]]                  # gate not even consulted
expect_exit 2 spawn_untyped --t T9
expect_exit 2 spawn_untyped --t ""
[[ ! -e "$TMP/herdr.log" ]]
[[ ! -e "$TMP/scopefuel.log" ]]
# A classified job goes through, and the classification is what gets recorded.
expect_exit 0 spawn_untyped --job arb-typed --t T3
arb status --job arb-typed --json |
  python3 -c 'import json,sys; j=json.load(sys.stdin)["jobs"]; assert j[0]["t_level"]=="T3", j'
arb status --json |
  python3 -c 'import json,sys; assert not [j for j in json.load(sys.stdin)["jobs"] if j["job"]=="fixture"], "an unclassified job was claimed"'
unset TEST_ARBITER_BIN

# Canonical checkout off default branch → warn on stderr, spawn still proceeds (exit 0).
# Worktree / on-default / unresolved origin/HEAD → silent. No hard-coded "main".
canon_guard_spawn() {
  local cwd="$1"
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="$TMP/absent-arbiter" WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
    "$WRK" spawn -c "$cwd" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1
}
setup_temp_repo() {
  # $1 = dest dir. Creates a bare origin + clone with origin/HEAD = master (not main)
  # so the guard cannot be cheating with a hard-coded "main" string compare.
  local dest="$1" bare="$TMP/canon-guard-origin.git"
  rm -rf "$bare" "$dest"
  mkdir -p "$dest"
  git init -q -b master --bare "$bare"
  git -C "$dest" init -q -b master
  git -C "$dest" config user.email "wrk-test@example.com"
  git -C "$dest" config user.name "wrk-test"
  printf 'x\n' >"$dest/README"
  git -C "$dest" add README
  git -C "$dest" commit -q -m init
  git -C "$dest" remote add origin "$bare"
  git -C "$dest" push -q -u origin master
  git -C "$dest" remote set-head origin master
}
CG_REPO="$TMP/canon-guard-repo"
setup_temp_repo "$CG_REPO"
# 1) canonical off default → warning + spawn continues
git -C "$CG_REPO" switch -q -c feature/off-default
: >"$TMP/herdr.log"
set +e
off_out="$(canon_guard_spawn "$CG_REPO" 2>&1)"
off_rc=$?
set -e
[[ "$off_rc" -eq 0 ]]
grep -q 'canonical checkout is not on default branch' <<<"$off_out"
grep -q "path=$CG_REPO" <<<"$off_out"
grep -q 'current=feature/off-default' <<<"$off_out"
grep -q 'default=master' <<<"$off_out"
grep -q "recover: git -C" <<<"$off_out"
grep -q 'switch' <<<"$off_out"
grep -q '^OK ' <<<"$off_out"
# 2) canonical on default → no canonical warning
git -C "$CG_REPO" switch -q master
: >"$TMP/herdr.log"
on_out="$(canon_guard_spawn "$CG_REPO" 2>&1)"
if grep -q 'canonical checkout is not on default branch' <<<"$on_out"; then exit 1; fi
grep -q '^OK ' <<<"$on_out"
# 3) linked worktree off default at worktree path → silent (path is not canonical)
CG_WT="$TMP/canon-guard-wt"
rm -rf "$CG_WT"
git -C "$CG_REPO" worktree add -q -b feature/wt-branch "$CG_WT"
: >"$TMP/herdr.log"
wt_out="$(canon_guard_spawn "$CG_WT" 2>&1)"
if grep -q 'canonical checkout is not on default branch' <<<"$wt_out"; then exit 1; fi
grep -q '^OK ' <<<"$wt_out"
# 4) origin/HEAD missing → quiet skip even if off default (no false positive)
git -C "$CG_REPO" switch -q -c feature/no-origin-head
git -C "$CG_REPO" remote remove origin
: >"$TMP/herdr.log"
skip_out="$(canon_guard_spawn "$CG_REPO" 2>&1)"
if grep -q 'canonical checkout is not on default branch' <<<"$skip_out"; then exit 1; fi
grep -q '^OK ' <<<"$skip_out"
# Guard must not hard-code main: the warn path used default=master above.
if grep -q "default=main" <<<"$off_out"; then exit 1; fi
git -C "$CG_REPO" worktree remove -f "$CG_WT" 2>/dev/null || rm -rf "$CG_WT"
echo "PASS canonical-checkout-guard"

# `wrk done` must consume artifacts produced by the real arbiter, not a
# hand-written fixture. Exercise both arbiter's default root and its explicit
# ARBITER_INBOX_ROOT override; completed stays a flat record with top-level epoch.
real_done_case() (
  local mode="$1" job="wrk-done-$1" case_home="$TMP/home-$1" jobs_root report
  export HOME="$case_home" XDG_DATA_HOME="$TMP/xdg-$1"
  mkdir -p "$HOME"
  case "$mode" in
    default)
      unset ARBITER_INBOX_ROOT
      jobs_root="$HOME/work/herdr-inbox/jobs"
      ;;
    configured)
      export ARBITER_INBOX_ROOT="$TMP/configured-jobs"
      jobs_root="$ARBITER_INBOX_ROOT"
      ;;
    *) return 2 ;;
  esac
  "$ARBITER" claim --job "$job" --lane test-lane --agent-label test-label --t T1 >/dev/null
  "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json '{"owner_lane":"test-lane","label":"test-label","pane_id":"test:pane"}' >/dev/null
  report="$TMP/$job-report.md"
  printf 'completion report\n' >"$report"
  "$WRK" 'done' "$job" --report "$report" >/dev/null
  python3 - "$jobs_root/$job/events/00003-job.completed.json" "$job" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert set(event) == {"kind", "job_id", "owner_lane", "label", "pane_id", "host", "report_path", "report_last_line", "epoch"}, event
assert event["kind"] == "job.completed" and event["job_id"] == sys.argv[2], event
assert event["epoch"] == 1, event
PY
)
real_done_case default
real_done_case configured
echo "PASS wrk-done-uses-arbiter-inbox-root-default-and-override"

# ── R20 T3: wrk notifies panewire once the record file has landed ────────────
# The event file stays the durable contract and the offline fallback; emit is
# only an extra notification that saves the node a directory rescan. It must
# never change wrk's stdout, its exit code, or how long wrk takes to return.
R20_HELPER="$TMP/r20_emit.py"
cat >"$R20_HELPER" <<'PY'
import json
import pathlib


def calls(log):
    """One list of argv elements per captured `panewire` invocation."""
    out, current = [], []
    for line in pathlib.Path(log).read_text(encoding="utf-8").split("\n")[:-1]:
        if line == "--":
            out.append(current)
            current = []
        else:
            current.append(line)
    assert not current, current
    return out


def flags(call):
    assert call[0] == "emit", call
    assert len(call) % 2 == 1, call
    return {call[i]: call[i + 1] for i in range(1, len(call), 2)}


def record(events, kind):
    for path in sorted(pathlib.Path(events).glob("*.json")):
        event = json.loads(path.read_text(encoding="utf-8"))
        if event.get("kind") == kind:
            return event
    raise AssertionError(f"no {kind} record under {events}")


def assert_matches_record(call, event):
    """Every field the two relay paths share must carry the record's value."""
    got = flags(call)
    assert got["--kind"] == event["kind"], (got, event)
    assert got["--job"] == event["job_id"], (got, event)
    assert got["--epoch"] == str(event["epoch"]) == "1", (got, event)
    assert got["--owner-lane"] == event["owner_lane"], (got, event)
    assert got["--label"] == event["label"], (got, event)
    assert got["--pane"] == event["pane_id"], (got, event)
    assert got["--host"] == event["host"], (got, event)
    assert got["--report"] == event["report_path"], (got, event)
    assert got["--report-last-line"] == event["report_last_line"], (got, event)
    for option, field in (
        ("--reason", "reason"), ("--question", "question"), ("--pr", "pr"), ("--head", "head")
    ):
        assert got.get(option, "") == event.get(field, ""), (option, got, event)
    return got
PY

R20_INBOX="$TMP/r20-inbox"
R20_REPORT="$TMP/r20-report.md"
printf 'R20 report terminal line\n' >"$R20_REPORT"
r20_arb() { env ARBITER_INBOX_ROOT="$R20_INBOX" XDG_DATA_HOME="$TMP/xdg-r20" "$ARBITER" "$@"; }
r20_claim() {  # a spawned worker job the completion commands can read back
  r20_arb claim --job "$1" --lane lane-a --agent-label wrk-a --t T1 "${@:2}" >/dev/null
  r20_arb event --job "$1" --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
}

# TW1 — the exact artifacts the production arbiter and wrk writers emit. The
# record files must stay byte-identical to the committed R19a fixture (no
# regression), and only then is the emit call examined.
R20_FIXTURE="$ROOT/tests/fixtures/panewire-r19a"
R20_FIXTURE_INBOX="$TMP/r20-fixture-inbox"
R20_FIXTURE_LOG="$TMP/r20-fixture-emit.log"
mkdir -p "$R20_FIXTURE_INBOX/captain-fixture/events"
cp "$R20_FIXTURE/00001-job.claim.json" "$R20_FIXTURE/00002-job.spawned.json" \
  "$R20_FIXTURE_INBOX/captain-fixture/events/"
(
  cd "$R20_FIXTURE"
  env ARBITER_INBOX_ROOT="$R20_FIXTURE_INBOX" HOSTNAME=fixture-host \
    WRK_PANEWIRE_LOG="$R20_FIXTURE_LOG" "$WRK" escalate captain-fixture \
    --question 'need parent decision' >/dev/null
  env ARBITER_INBOX_ROOT="$R20_FIXTURE_INBOX" HOSTNAME=fixture-host \
    WRK_PANEWIRE_LOG="$R20_FIXTURE_LOG" "$WRK" joined captain-fixture \
    --pr https://example.invalid/pr/1 --head deadbeef --report report.md >/dev/null
)
cmp "$R20_FIXTURE/00003-job.escalate.json" \
  "$R20_FIXTURE_INBOX/captain-fixture/events/00003-job.escalate.json"
cmp "$R20_FIXTURE/00004-job.joined.json" \
  "$R20_FIXTURE_INBOX/captain-fixture/events/00004-job.joined.json"
PYTHONPATH="$TMP" python3 - "$R20_FIXTURE_LOG" "$R20_FIXTURE_INBOX/captain-fixture/events" <<'PY'
import sys
import r20_emit as helper
log, events = sys.argv[1:]
captured = helper.calls(log)
assert len(captured) == 2, captured
for call, kind in zip(captured, ("job.escalate", "job.joined")):
    helper.assert_matches_record(call, helper.record(events, kind))
PY
echo "PASS r20-emit-on-real-arbiter-fixture-artifacts"

# TW2 — `wrk done` emits job.completed carrying the record's own values.
R20_DONE_LOG="$TMP/r20-done-emit.log"
r20_claim r20-done
r20_done_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_LOG="$R20_DONE_LOG" "$WRK" 'done' r20-done --report "$R20_REPORT")"
PYTHONPATH="$TMP" python3 - "$R20_DONE_LOG" "$R20_INBOX/r20-done/events" <<'PY'
import sys
import r20_emit as helper
log, events = sys.argv[1:]
captured = helper.calls(log)
assert len(captured) == 1, captured
got = helper.assert_matches_record(captured[0], helper.record(events, "job.completed"))
assert got["--kind"] == "job.completed" and got["--job"] == "r20-done", got
assert got["--report-last-line"] == "R20 report terminal line ", got
# `done` carries no reason/question/pr/head, so those options are left out
# entirely rather than passed as empty strings.
assert not {"--reason", "--question", "--pr", "--head"} & set(got), got
PY
grep -qxF "OK job=r20-done report=$R20_REPORT" <<<"$r20_done_out"
echo "PASS r20-emit-argv-matches-done-record"

# TW3 — escalate carries --question, joined carries --pr/--head, and both carry
# the record's reason verbatim.
R20_CAPTAIN_LOG="$TMP/r20-captain-emit.log"
r20_claim r20-captain --role captain --parent-lane parent-a
r20_escalate_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_LOG="$R20_CAPTAIN_LOG" "$WRK" escalate r20-captain \
  --question 'need parent decision')"
r20_joined_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_LOG="$R20_CAPTAIN_LOG" "$WRK" joined r20-captain \
  --pr https://example.invalid/pr/1 --head deadbeef --report "$R20_REPORT")"
PYTHONPATH="$TMP" python3 - "$R20_CAPTAIN_LOG" "$R20_INBOX/r20-captain/events" <<'PY'
import sys
import r20_emit as helper
log, events = sys.argv[1:]
escalate_call, joined_call = helper.calls(log)
escalate = helper.assert_matches_record(escalate_call, helper.record(events, "job.escalate"))
joined = helper.assert_matches_record(joined_call, helper.record(events, "job.joined"))
assert escalate["--reason"] == "captain escalation", escalate
assert escalate["--question"] == "need parent decision", escalate
assert not {"--pr", "--head"} & set(escalate), escalate
assert joined["--reason"] == "captain joined PR", joined
assert joined["--pr"].endswith("/pr/1") and joined["--head"] == "deadbeef", joined
assert "--question" not in joined, joined
PY
echo "PASS r20-emit-argv-matches-escalate-and-joined-records"

# TW4 — no panewire on the box: exit 0, the record is still written, exactly
# one warning on stderr, stdout untouched.
R20_ABSENT_ERR="$TMP/r20-absent.err"
r20_claim r20-absent
set +e
r20_absent_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" PANEWIRE_BIN="$TMP/absent-panewire" \
  "$WRK" 'done' r20-absent --report "$R20_REPORT" 2>"$R20_ABSENT_ERR")"
r20_absent_rc=$?
set -e
[[ "$r20_absent_rc" -eq 0 ]]
[[ -f "$R20_INBOX/r20-absent/events/00003-job.completed.json" ]]
grep -qxF "OK job=r20-absent report=$R20_REPORT" <<<"$r20_absent_out"
grep -qxF 'wrk: warning: panewire not found; relay event left as file only (job=r20-absent kind=job.completed)' "$R20_ABSENT_ERR"
[[ "$(wc -l <"$R20_ABSENT_ERR" | tr -d ' ')" -eq 1 ]]
echo "PASS r20-missing-panewire-warns-without-changing-exit-or-stdout"

# TW5 — emit fails: exit 0, the record is still written, the warning quotes rc.
R20_FAIL_ERR="$TMP/r20-fail.err"
r20_claim r20-fail
set +e
r20_fail_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" WRK_PANEWIRE_RC=3 \
  "$WRK" 'done' r20-fail --report "$R20_REPORT" 2>"$R20_FAIL_ERR")"
r20_fail_rc=$?
set -e
[[ "$r20_fail_rc" -eq 0 ]]
[[ -f "$R20_INBOX/r20-fail/events/00003-job.completed.json" ]]
grep -qxF "OK job=r20-fail report=$R20_REPORT" <<<"$r20_fail_out"
grep -qxF 'wrk: warning: panewire emit failed (rc=3 job=r20-fail kind=job.completed); relay event left as file only' "$R20_FAIL_ERR"
[[ "$(wc -l <"$R20_FAIL_ERR" | tr -d ' ')" -eq 1 ]]
echo "PASS r20-failed-emit-warns-with-rc-without-changing-exit"

# TW6 — a wedged emit must not stall wrk: `wrk joined` runs inside the captain
# loop, so a hang there would stop the fleet. The 5s guard returns long before
# the fixture's 30s stall would.
R20_SLOW_ERR="$TMP/r20-slow.err"
r20_claim r20-slow
r20_slow_start_ns="$(python3 -c 'import time; print(time.time_ns())')"
set +e
r20_slow_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" WRK_PANEWIRE_SLEEP=30 \
  "$WRK" 'done' r20-slow --report "$R20_REPORT" 2>"$R20_SLOW_ERR")"
r20_slow_rc=$?
set -e
r20_slow_ms="$(( ($(python3 -c 'import time; print(time.time_ns())') - r20_slow_start_ns) / 1000000 ))"
echo "r20 wedged-emit: elapsed_ms=$r20_slow_ms rc=$r20_slow_rc"
[[ "$r20_slow_rc" -eq 0 ]]
[[ "$r20_slow_ms" -lt 10000 ]]
[[ -f "$R20_INBOX/r20-slow/events/00003-job.completed.json" ]]
grep -qxF "OK job=r20-slow report=$R20_REPORT" <<<"$r20_slow_out"
grep -q 'panewire emit failed' "$R20_SLOW_ERR"
echo "PASS r20-wedged-emit-is-bounded-by-the-timeout-guard"

# TW7 — job.lost is not one of panewire's relay kinds, so the sentinel path
# must not emit at all; passing it would only pile up usage warnings.
R20_LOST_LOG="$TMP/r20-lost-emit.log"
R20_LOST_INBOX="$TMP/r20-lost-inbox"
set +e
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$R20_LOST_INBOX" WRK_PANEWIRE_LOG="$R20_LOST_LOG" \
  WRK_FIXTURE_SCENARIO=sentinel-working WRK_COMPLETION_TIMEOUT_S=1 WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel r20-lost lane-a wrk-a w1:p1 "$R20_REPORT" >/dev/null 2>&1
r20_lost_rc=$?
set -e
[[ "$r20_lost_rc" -eq 0 ]]
find "$R20_LOST_INBOX/r20-lost/events" -name '*job.lost.json' | grep -q .
[[ ! -e "$R20_LOST_LOG" ]]
echo "PASS r20-job-lost-is-never-emitted"

# TW8 — the stdout contract is exactly what it was before emit existed: one
# line, in the pre-R20 format, for each of the three commands.
[[ "$(wc -l <<<"$r20_done_out" | tr -d ' ')" -eq 1 ]]
[[ "$(wc -l <<<"$r20_escalate_out" | tr -d ' ')" -eq 1 ]]
[[ "$(wc -l <<<"$r20_joined_out" | tr -d ' ')" -eq 1 ]]
grep -qxF "OK job=r20-done report=$R20_REPORT" <<<"$r20_done_out"
grep -qxF 'OK job=r20-captain owner_lane=lane-a kind=job.escalate' <<<"$r20_escalate_out"
grep -qxF "OK job=r20-captain owner_lane=lane-a kind=job.joined pr=https://example.invalid/pr/1 head=deadbeef report=$R20_REPORT" <<<"$r20_joined_out"
echo "PASS r20-stdout-contract-unchanged"

# R18 completion sentinel: a report alone is never completion evidence. A
# worker still working must time out/lost rather than emit job.completed.
SENTINEL_REPORT="$TMP/sentinel-report.md"
printf 'sentinel final line\n' >"$SENTINEL_REPORT"
SENTINEL_INBOX="$TMP/sentinel-inbox"
set +e
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$SENTINEL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-working WRK_COMPLETION_TIMEOUT_S=1 WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel sentinel-working lane worker w:p1 "$SENTINEL_REPORT" >/dev/null 2>&1
sentinel_working_rc=$?
set -e
[[ "$sentinel_working_rc" -eq 0 ]]
if find "$SENTINEL_INBOX/sentinel-working/events" -name '*job.completed.json' | grep -q .; then
  echo "working agent incorrectly emitted job.completed" >&2
  exit 1
fi
find "$SENTINEL_INBOX/sentinel-working/events" -name '*job.lost.json' | grep -q .
echo "PASS r18-sentinel-requires-terminal-status"

# Automatic discovery must work on macOS too, and the observation key must be
# stable for an unchanged report but advance when that same report is updated.
SENTINEL_INBOX="$TMP/sentinel-dedupe-inbox"
env ARBITER_INBOX_ROOT="$SENTINEL_INBOX" "$ARBITER" claim \
  --job sentinel-idle --lane test-lane --agent-label test-label --t T1 >/dev/null
env ARBITER_INBOX_ROOT="$SENTINEL_INBOX" "$ARBITER" event --job sentinel-idle \
  --kind job.spawned --payload-json '{"owner_lane":"test-lane","label":"test-label","pane_id":"test:pane"}' >/dev/null
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$SENTINEL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-idle WRK_COMPLETION_TIMEOUT_S=20 WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel sentinel-idle lane worker w:p1 "" >/dev/null 2>&1 &
sentinel_idle_pid=$!
sleep 2
[[ "$(find "$SENTINEL_INBOX/sentinel-idle/events" -name '*job.completed.json' | wc -l | tr -d ' ')" -eq 0 ]]
cp "$SENTINEL_REPORT" "$SENTINEL_INBOX/sentinel-idle/report.md"
sleep 2
[[ "$(find "$SENTINEL_INBOX/sentinel-idle/events" -name '*job.completed.json' | wc -l | tr -d ' ')" -eq 1 ]]
printf 'updated report line\n' >>"$SENTINEL_INBOX/sentinel-idle/report.md"
sleep 2
[[ "$(find "$SENTINEL_INBOX/sentinel-idle/events" -name '*job.completed.json' | wc -l | tr -d ' ')" -eq 2 ]]
kill "$sentinel_idle_pid" 2>/dev/null || true
wait "$sentinel_idle_pid" 2>/dev/null || true
echo "PASS r18-sentinel-portable-discovery-and-dedupe"

# Both terminal statuses are accepted; `done` is tested separately so this is
# an explicit status-set contract rather than an idle-only implementation.
SENTINEL_INBOX="$TMP/sentinel-done-inbox"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$SENTINEL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-done WRK_COMPLETION_TIMEOUT_S=20 WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel sentinel-done lane worker w:p1 "$SENTINEL_REPORT" >/dev/null 2>&1 &
sentinel_done_pid=$!
sleep 2
[[ "$(find "$SENTINEL_INBOX/sentinel-done/events" -name '*job.completed.json' | wc -l | tr -d ' ')" -eq 1 ]]
kill "$sentinel_done_pid" 2>/dev/null || true
wait "$sentinel_done_pid" 2>/dev/null || true
echo "PASS r18-sentinel-accepts-done-status"

grep -q "for tool in \"\$REPO_DIR\"/bin/\\*" "$ROOT/install.sh"

# ROB-1190 ④-3: scopefuel 이 추천하는 모든 프로필 ⊆ wrk 가 띄울 수 있는 프로필.
# WRK_TEST_SCOPEFUEL_SRC 로 scopefuel worktree 경로를 주면 uv run 으로 실제 GRADE_TABLE 을
# 조회해 대조한다(둘 다 로컬에 있을 때만 — 없으면 스킵, CI 이식성 유지).
if [[ -n "${WRK_TEST_SCOPEFUEL_SRC:-}" ]] && command -v uv >/dev/null 2>&1; then
  scopefuel_profiles="$(cd "$WRK_TEST_SCOPEFUEL_SRC" && uv run scopefuel --list-recommend-profiles 2>/dev/null)"
  wrk_profiles="$("$WRK" profiles)"
  missing=0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if ! grep -qx "$p" <<<"$wrk_profiles"; then
      echo "cross-check FAIL: scopefuel recommends '$p' but wrk cannot spawn it" >&2
      missing=1
    fi
  done <<<"$scopefuel_profiles"
  [[ "$missing" -eq 0 ]]
  echo "PASS scopefuel-recommends-subset-of-wrk-profiles"
else
  echo "SKIP scopefuel⊆wrk cross-check (set WRK_TEST_SCOPEFUEL_SRC + uv to enable)"
fi

echo 'PASS test-wrk'
