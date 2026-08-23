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

# ROB-1313: oc-ox 는 OpenRouter 키를 파일에서 읽는다 — suite 전체가 실파일 대신 fixture 사용
# (실키 값이 herdr.log 로 새는 것도 방지).
export OX_OPENROUTER_KEY_FILE="$TMP/ai-keys-fixture.env"
# 실파일 형식 미러: export + 따옴표 + 인라인 주석(ROB-1313 실사고 회귀 가드)
printf 'export OPENROUTER_API_KEY="fixture-openrouter-key"  # https://openrouter.ai/keys\n' >"$OX_OPENROUTER_KEY_FILE"

# ROB-1199: the suite must never reach a real arbiter state db or the real inbox.
# ARBITER_BIN points at nothing by default, so every pre-existing case keeps
# exercising the installation-transition path; the arbiter section below opts in.
export ARBITER_BIN="$TMP/absent-arbiter"
export XDG_DATA_HOME="$TMP/xdg"
export ARBITER_INBOX_ROOT="$TMP/inbox"

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
"$WRK" spawn --help >/dev/null
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
! grep -qx 'codex-ultra' <<<"$profiles_out"
! grep -qx 'codex-luna-ultra' <<<"$profiles_out"

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
! grep -q 'pane_id=w:p2' <<<"$priority_out"

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
  "oc-ox:oc-glm" "oc-oxz:oc-glm"
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

: >"$TMP/herdr.log"
spawn_base oc-oxz >/dev/null
# ROB-1314: Zen 경로는 키 주입 없이 위장 슬러그로 뜬다 (OpenRouter 경로와 독립 인그레스).
grep -q -- '--model opencode/x-preview-f-free' "$TMP/herdr.log"
! grep -q -- '--env OPENROUTER_API_KEY=' "$TMP/herdr.log"
echo "PASS oc-oxz-zen-no-key"

: >"$TMP/herdr.log"
spawn_base oc-ox >/dev/null
grep -q -- '--model openrouter/stealth/ox-alpha' "$TMP/herdr.log"
grep -q -- '--env OPENROUTER_API_KEY=fixture-openrouter-key' "$TMP/herdr.log"
echo "PASS oc-ox-openrouter-env"

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
! grep -q -- 'KIMI_CODE_HOME' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base kimi-k27 >/dev/null
! grep -q -- 'KIMI_CODE_HOME' "$TMP/herdr.log"

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

# ROB-1246 landing acceptance fixtures. Retry is allowed only after a
# successful prompt plus measured non-landing.
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
echo "PASS ac1-marker-landed: $marker_out"

PROMPT="$TMP/prompt.md"
: >"$TMP/herdr.log"
retry_out="$(TEST_FIXTURE_SCENARIO=landing-retry spawn_base codex-terra 2>&1)"
grep -q 'landed=retry' <<<"$retry_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS ac2-swallowed-then-retry: $retry_out"

: >"$TMP/herdr.log"
set +e
no_landing_out="$(TEST_FIXTURE_SCENARIO=landing-no spawn_base codex-terra 2>&1)"
no_landing_rc=$?
set -e
[[ "$no_landing_rc" -eq 0 ]]
grep -q 'landed=no' <<<"$no_landing_out"
grep -q 'spawn succeeded but brief landed=no' <<<"$no_landing_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS ac3-swallowed-twice-spawn-success exit=$no_landing_rc: $no_landing_out"

: >"$TMP/herdr.log"
scrollout_out="$(TEST_FIXTURE_SCENARIO=landing-working-scrollout spawn_base codex-terra 2>&1)"
grep -q 'landed=yes' <<<"$scrollout_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
echo "PASS ac5-working-scrollout-no-duplicate: $scrollout_out"

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
[[ "$elapsed_ms" -lt 1000 ]]
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
[[ "$timeout_elapsed_ms" -lt 1000 ]]
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

# A duplicate claim does not block a spawn — quota records are independent.
arb release --job arb-retry --resource claude --kind quota_pool >/dev/null
rm -f "$TMP/herdr.log"
dup_out="$(spawn_base opus --job arb-retry --t T2 2>&1)"
grep -q "already claimed" <<<"$dup_out"
grep -q 'quota_record=claude/quota_pool' <<<"$dup_out"

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
untyped_out="$(spawn_untyped 2>&1 || true)"
grep -q 'NEEDS_CLASSIFICATION' <<<"$untyped_out"
! grep -q '^OK ' <<<"$untyped_out"
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
! grep -q 'canonical checkout is not on default branch' <<<"$on_out"
grep -q '^OK ' <<<"$on_out"
# 3) linked worktree off default at worktree path → silent (path is not canonical)
CG_WT="$TMP/canon-guard-wt"
rm -rf "$CG_WT"
git -C "$CG_REPO" worktree add -q -b feature/wt-branch "$CG_WT"
: >"$TMP/herdr.log"
wt_out="$(canon_guard_spawn "$CG_WT" 2>&1)"
! grep -q 'canonical checkout is not on default branch' <<<"$wt_out"
grep -q '^OK ' <<<"$wt_out"
# 4) origin/HEAD missing → quiet skip even if off default (no false positive)
git -C "$CG_REPO" switch -q -c feature/no-origin-head
git -C "$CG_REPO" remote remove origin
: >"$TMP/herdr.log"
skip_out="$(canon_guard_spawn "$CG_REPO" 2>&1)"
! grep -q 'canonical checkout is not on default branch' <<<"$skip_out"
grep -q '^OK ' <<<"$skip_out"
# Guard must not hard-code main: the warn path used default=master above.
! grep -q "default=main" <<<"$off_out"
git -C "$CG_REPO" worktree remove -f "$CG_WT" 2>/dev/null || rm -rf "$CG_WT"
echo "PASS canonical-checkout-guard"

grep -q 'for tool in "$REPO_DIR"/bin/\*' "$ROOT/install.sh"

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
