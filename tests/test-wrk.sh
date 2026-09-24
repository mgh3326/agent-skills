#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="$ROOT/bin/arbiter"
TMP="$(mktemp -d)"
# spawn 이 띄운 센티널은 nohup 으로 분리되어 있다 — 스위트가 끝나면 함께 거둔다.
cleanup() {
  local pidfile pid
  while IFS= read -r pidfile; do
    [[ -s "$pidfile" ]] || continue
    read -r pid <"$pidfile" || continue
    if [[ "$pid" =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; fi
  done < <(find "$TMP" -name 'completion-sentinel.pid' 2>/dev/null)
  rm -rf "$TMP"
}
trap cleanup EXIT
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
# Nor the operator's real spill-over config: under host load it moved fixture
# spawns onto a real remote host (or died with rc 2 on its cwd_map). Cases
# that exercise spill-over pass their own WRK_HOSTS_CONFIG.
export WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml"

# R20: `wrk done/escalate/joined` now notify panewire. The suite must never
# reach a real one, so every case runs against the silent fixture below; the
# R20 section opts into capture, failure and stalling through its environment.
PANEWIRE="$ROOT/tests/fixtures/panewire"
export PANEWIRE_BIN="$PANEWIRE"

# Document uploads are also opt-in below. Keep pre-existing cases away from a
# real handoffkeep installation while preserving their historical records.
export HANDOFFKEEP_BIN="$TMP/absent-handoffkeep"

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

fail() { echo "FAIL: $*" >&2; exit 1; }

event_count() {
  find "$1" -name "*$2.json" 2>/dev/null | wc -l | tr -d ' '
}

wait_until() {
  local limit="$1"; shift
  local deadline=$(( $(date +%s) + limit ))
  while (( $(date +%s) <= deadline )); do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  return 1
}

event_count_is() {
  [[ "$(event_count "$1" "$2")" -eq "$3" ]]
}

sentinel_lost_reason() {
  python3 - "$1" <<'PY'
import glob, json, sys
for path in sorted(glob.glob(sys.argv[1] + "/*job.lost.json")):
    print(json.load(open(path)).get("reason", ""))
PY
}

# --t is required by wrk; supply one unless the case under test provides its own.
spawn_base() {
  local model="$1"; shift
  local extra=("$@")
  case " ${extra[*]-} " in *" --t "*) ;; *) extra+=(--t T1) ;; esac
  # A registered job leaves a detached sentinel behind, and that sentinel keeps
  # calling the fixture herdr — which appends every invocation to the shared
  # WRK_FIXTURE_LOG. At the default 30s interval one of those probes lands, about
  # once in three runs, between a case's `rm -f "$TMP/herdr.log"` and its
  # `[[ ! -e "$TMP/herdr.log" ]]`, and the suite dies there with no message.
  # Park the probes past the end of the run instead.
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="${TEST_ARBITER_BIN:-$TMP/absent-arbiter}" \
    WRK_COMPLETION_INTERVAL_S="${WRK_COMPLETION_INTERVAL_S:-3600}" \
    WRK_FIXTURE_SCENARIO="${TEST_FIXTURE_SCENARIO:-spawn}" WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_FIXTURE_MARKER="${WRK_FIXTURE_MARKER:-}" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S="${WRK_REFRESH_TIMEOUT_S:-5}" \
    "$WRK" spawn \
    -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture "${extra[@]}"
}

hub_quota_run_case() {
  local name="$1" hub_rc="$2" gate_mode="$3" config="$4"
  HUB_QUOTA_OUT="$TMP/hub-quota-$name.out"
  HUB_QUOTA_ERR="$TMP/hub-quota-$name.err"
  HUB_QUOTA_PANEWIRE_LOG="$TMP/hub-quota-$name-panewire.log"
  HUB_QUOTA_HERDR_LOG="$TMP/hub-quota-$name-herdr.log"
  HUB_QUOTA_SPILLOVER_LOG="$TMP/hub-quota-$name-spillover.log"
  : >"$HUB_QUOTA_PANEWIRE_LOG"
  : >"$HUB_QUOTA_HERDR_LOG"
  : >"$HUB_QUOTA_SPILLOVER_LOG"
  set +e
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" PANEWIRE_BIN="$PANEWIRE" \
    ARBITER_BIN="$ARBITER" XDG_DATA_HOME="$TMP/hub-quota-xdg-$name" \
    ARBITER_INBOX_ROOT="$TMP/hub-quota-inbox-$name" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$HUB_QUOTA_HERDR_LOG" WRK_SCOPEFUEL_LOG="$TMP/hub-quota-scopefuel.log" \
    WRK_REFRESH_LOG="$TMP/hub-quota-refresh.log" WRK_REFRESH_PID_LOG="$TMP/hub-quota-refresh.pids" \
    WRK_REFRESH_TIMEOUT_S=5 WRK_HOSTS_CONFIG="$config" \
    WRK_SPILLOVER_LOG="$HUB_QUOTA_SPILLOVER_LOG" \
    WRK_PANEWIRE_LOG="$HUB_QUOTA_PANEWIRE_LOG" WRK_PANEWIRE_RC="$hub_rc" \
    WRK_GATE_MODE="$gate_mode" \
    "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1 --host local \
    >"$HUB_QUOTA_OUT" 2>"$HUB_QUOTA_ERR"
  HUB_QUOTA_RC=$?
  set -e
}

hub_quota_expect_rc() {
  local name="$1" want="$2"
  [[ "$HUB_QUOTA_RC" -eq "$want" ]] ||
    fail "hub quota combination $name expected exit $want, got $HUB_QUOTA_RC"
}

hub_quota_expect_spawn() {
  local name="$1" want="$2"
  if [[ "$want" -eq 1 ]]; then
    [[ -s "$HUB_QUOTA_HERDR_LOG" ]] ||
      fail "hub quota combination $name expected spawn"
  elif [[ -s "$HUB_QUOTA_HERDR_LOG" ]]; then
    fail "hub quota combination $name unexpectedly spawned"
  fi
}

run_hub_quota_gate_tests() {
  local configured="$TMP/hub-quota-hosts.toml"
  local unconfigured="$TMP/hub-quota-no-hub.toml"
  local token_file="$TMP/hub-quota-operator.env"
  local cf_file="$TMP/hub-quota-cf.env"
  local token_value="fixture-quota-token-must-not-leak"
  printf 'HUB_TOKEN=%s\n' "$token_value" >"$token_file"
  printf 'CF_ACCESS_CLIENT_ID=fixture\nCF_ACCESS_CLIENT_SECRET=fixture\n' >"$cf_file"
  printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nhub_cf_env = "%s"\n' \
    "$token_file" "$cf_file" >"$configured"
  printf '[local]\nmax_load_ratio = 1.0\n' >"$unconfigured"

  # W1 isolates the original scopefuel exit contract with no [hub] section.
  # These assertions intentionally precede the policy-combination table so a
  # broad relaxation of `3|4) exit "$rc"` fails at the legacy boundary.
  hub_quota_run_case local-contract-3 0 3 "$unconfigured"
  hub_quota_expect_rc local-contract-3 3
  hub_quota_expect_spawn local-contract-3 0
  grep -q 'gate blocked profile=codex-terra-max' "$HUB_QUOTA_ERR" ||
    fail "W1 scopefuel exit 3 stderr was not preserved"
  echo "PASS hub-quota-local-contract exit-3=deny"

  hub_quota_run_case local-contract-4 0 4 "$unconfigured"
  hub_quota_expect_rc local-contract-4 4
  hub_quota_expect_spawn local-contract-4 0
  grep -q 'gate measurement unavailable profile=codex-terra-max' "$HUB_QUOTA_ERR" ||
    fail "W1 scopefuel exit 4 stderr was not preserved"
  echo "PASS hub-quota-local-contract exit-4=unknown"

  # The scopefuel success payload remains the exact two-line prefix consumed by
  # arbiter. The hub call receives only the pool emitted by scopefuel.
  hub_quota_run_case allow-local-0 0 ok "$configured"
  hub_quota_expect_rc allow/local-0 0
  hub_quota_expect_spawn allow/local-0 1
  [[ "$(sed -n '1p' "$HUB_QUOTA_OUT")" == 'profile=codex-terra-max pool=codex used_pct=12.5 class=preserve' ]] ||
    fail "scopefuel gate stdout line 1 was not reprinted verbatim"
  [[ "$(sed -n '2p' "$HUB_QUOTA_OUT")" == 'gate allowed profile=codex-terra-max' ]] ||
    fail "scopefuel gate stdout line 2 was not reprinted verbatim"
  python3 - "$HUB_QUOTA_PANEWIRE_LOG" "$ROOT" "$token_file" "$cf_file" <<'PY' ||
import sys
got = open(sys.argv[1], encoding="utf-8").read().splitlines()
want = [
    "place", "--class", "worker", "--cwd", sys.argv[2], "--pool", "codex",
    "--hub-url", "https://hub.invalid", "--hub-token-env", sys.argv[3],
    "--hub-cf-env", sys.argv[4], "--",
]
if got != want:
    raise SystemExit(f"hub quota argv mismatch: got={got!r} want={want!r}")
PY
    fail "hub quota allow invocation did not preserve the panewire contract"
  echo "PASS hub-quota-combination allow/0=allow"

  # Local denial/unknown terminates before hub policy can override it. The fake
  # hub is configured to allow, and non-invocation is part of the assertion.
  hub_quota_run_case allow-local-3 0 3 "$configured"
  hub_quota_expect_rc allow/local-3 3
  hub_quota_expect_spawn allow/local-3 0
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "hub allow was consulted after local exit 3"
  grep -q 'gate blocked profile=codex-terra-max' "$HUB_QUOTA_ERR" ||
    fail "scopefuel exit 3 stderr was not preserved"
  echo "PASS hub-quota-combination allow/3=deny"

  hub_quota_run_case allow-local-4 0 4 "$configured"
  hub_quota_expect_rc allow/local-4 4
  hub_quota_expect_spawn allow/local-4 0
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "hub allow was consulted after local exit 4"
  grep -q 'gate measurement unavailable profile=codex-terra-max' "$HUB_QUOTA_ERR" ||
    fail "scopefuel exit 4 stderr was not preserved"
  echo "PASS hub-quota-combination allow/4=unknown"

  hub_quota_run_case deny-local-0 5 ok "$configured"
  hub_quota_expect_rc deny/local-0 5
  hub_quota_expect_spawn deny/local-0 0
  grep -q 'hub quota policy denied' "$HUB_QUOTA_ERR" ||
    fail "hub exit 5 was not classified as deny"
  echo "PASS hub-quota-combination deny/0=deny"

  hub_quota_run_case unavailable-local-0 4 ok "$configured"
  hub_quota_expect_rc unavailable/local-0 0
  hub_quota_expect_spawn unavailable/local-0 1
  grep -q 'hub quota policy unavailable; using local scopefuel result' "$HUB_QUOTA_ERR" ||
    fail "hub exit 4 did not take the approved fallback"
  echo "PASS hub-quota-combination unavailable/0=allow"

  hub_quota_run_case unavailable-local-3 4 3 "$configured"
  hub_quota_expect_rc unavailable/local-3 3
  hub_quota_expect_spawn unavailable/local-3 0
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "unavailable hub was consulted after local exit 3"
  echo "PASS hub-quota-combination unavailable/3=deny"

  hub_quota_run_case authentication-local-0 6 ok "$configured"
  hub_quota_expect_rc authentication_error/local-0 6
  hub_quota_expect_spawn authentication_error/local-0 0
  grep -q 'hub quota policy authentication failed' "$HUB_QUOTA_ERR" ||
    fail "hub exit 6 was not classified as authentication error"
  echo "PASS hub-quota-combination authentication_error/0=authentication_error"

  hub_quota_run_case malformed-local-0 70 ok "$configured"
  hub_quota_expect_rc fail_closed/local-0 70
  hub_quota_expect_spawn fail_closed/local-0 0
  grep -q 'hub quota policy response rejected' "$HUB_QUOTA_ERR" ||
    fail "hub exit 70 was not classified fail-closed"
  echo "PASS hub-quota-combination fail_closed/0=fail_closed"

  # Usage is also fail-closed. Of panewire's nonzero outcomes, only 4 spawns.
  hub_quota_run_case usage-local-0 2 ok "$configured"
  hub_quota_expect_rc usage/local-0 2
  hub_quota_expect_spawn usage/local-0 0
  grep -q 'hub quota policy invocation rejected' "$HUB_QUOTA_ERR" ||
    fail "hub exit 2 did not fail closed"
  echo "PASS hub-quota-only-exit-4-falls-back"

  # A readable hosts.toml without [hub] is the original local-only path.
  hub_quota_run_case unconfigured-local-0 70 ok "$unconfigured"
  hub_quota_expect_rc unconfigured/local-0 0
  hub_quota_expect_spawn unconfigured/local-0 1
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "hub-unconfigured local-only path invoked panewire"
  [[ "$(sed -n '1p' "$HUB_QUOTA_OUT")" == 'profile=codex-terra-max pool=codex used_pct=12.5 class=preserve' ]] ||
    fail "hub-unconfigured path changed local gate stdout"
  echo "PASS hub-quota-unconfigured-preserves-local-only"

  # The credential files are passed by path only. Neither their contents nor
  # panewire output can enter wrk's stdout, stderr, or spill-over audit log.
  for output in "$TMP"/hub-quota-*.out "$TMP"/hub-quota-*.err "$TMP"/hub-quota-*-spillover.log; do
    if grep -Fq "$token_value" "$output"; then
      fail "hub token leaked into ${output##*/}"
    fi
  done
  echo "PASS hub-quota-token-redaction"
}

if [[ "${WRK_TEST_ONLY_HUB_QUOTA:-0}" -eq 1 ]]; then
  run_hub_quota_gate_tests
  exit 0
fi
run_hub_quota_gate_tests

arb() { "$ARBITER" "$@"; }

"$WRK" --help >/dev/null
spawn_help_out="$("$WRK" spawn --help)"
grep -q -- '--landing-strict' <<<"$spawn_help_out"
grep -q -- '--role worker|builder (legacy alias: captain)' <<<"$spawn_help_out"
grep -q -- 'builder-opus' <<<"$spawn_help_out"
# Task 612: the help text must document the kimi-code/ namespace and must not
# carry the retired kimi-for-coding/ prefix.
grep -q -- 'kimi --auto -m kimi-code/k3' <<<"$spawn_help_out" ||
  fail "spawn --help must document kimi-code/k3"
grep -q -- 'kimi --auto -m kimi-code/kimi-for-coding' <<<"$spawn_help_out" ||
  fail "spawn --help must document kimi-code/kimi-for-coding"
if grep -q 'kimi-for-coding/' <<<"$spawn_help_out"; then
  fail "spawn --help still carries the old kimi-for-coding/ namespace"
fi
reap_help_out="$("$WRK" reap --help)"
grep -q -- '--include-builders' <<<"$reap_help_out"
grep -q -- '--include-captains legacy alias' <<<"$reap_help_out"
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
grep -qx 'oc-solar4' <<<"$profiles_out"
grep -qx 'kimi-k3' <<<"$profiles_out"
grep -qx 'kimi-k27' <<<"$profiles_out"
grep -qx 'kimi-k27-code' <<<"$profiles_out"
grep -qx 'kimi-k3-low' <<<"$profiles_out"
grep -qx 'codex-terra-max' <<<"$profiles_out"
grep -qx 'builder-opus' <<<"$profiles_out"
grep -qx 'builder-sol' <<<"$profiles_out"
grep -qx 'builder-devin' <<<"$profiles_out"
grep -qx 'builder-grok' <<<"$profiles_out"
grep -qx 'builder-kimi' <<<"$profiles_out"
grep -qx 'captain-opus' <<<"$profiles_out"
grep -qx 'captain-sol' <<<"$profiles_out"
grep -qx 'codex-astra' <<<"$profiles_out"
# ROB-591 rollback spellings (gpt-5.6-sol/gpt-5.6-luna) must remain spawnable.
grep -qx 'codex-sol56' <<<"$profiles_out"
grep -qx 'codex-luna56' <<<"$profiles_out"
# task #526: the astra builder spellings were removed — astra is counsel-only
# (hk:doc decision/2026-09-21/astra-allowed-purposes-approved).
if grep -qx 'builder-astra' <<<"$profiles_out"; then exit 1; fi
if grep -qx 'captain-astra' <<<"$profiles_out"; then exit 1; fi
[[ "$(grep -xc 'devin-swe2' <<<"$profiles_out")" -eq 1 ]]
grep -qx 'devin-glm52' <<<"$profiles_out"
grep -qx 'devin-swe17' <<<"$profiles_out"
grep -qx 'devin-ds41' <<<"$profiles_out"
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
  "opus:opus" "sonnet:sonnet" "sonnet-med:sonnet" "haiku:haiku"
  "devin-swe2:devin-swe2"
  "devin-glm52:devin-swe2" "devin-swe17:devin-swe2" "devin-ds41:devin-swe2"
  "codex:codex-max" "codex-sol:codex-max" "codex-med:codex-terra-max"
  "codex-luna:codex-luna-max" "codex-luna-hi:codex-luna-max"
  "codex-max:codex-max" "codex-terra:codex-terra-max"
  "codex-terra-max:codex-terra-max" "codex-luna-max:codex-luna-max"
  "codex-sol56:codex-max" "codex-luna56:codex-luna-max"
  "kiro:kiro-sol" "kiro-opus:kiro-opus" "kiro-sonnet:kiro-sonnet"
  "kiro-sol:kiro-sol" "kiro-luna:kiro-sol" "kiro-cheap:kiro-cheap"
  "kiro-glm:kiro-sol" "kiro-deepseek:kiro-sol" "kiro-minimax:kiro-sol"
  "kiro-minimax21:kiro-sol" "kiro-haiku:kiro-haiku"
  "kiro-opus-xhigh:kiro-opus" "kiro-opus-max:kiro-opus"
  "kiro-sol-xhigh:kiro-sol" "kiro-sol-max:kiro-sol"
  "kimi-k3:kimi-k3" "kimi-k27:kimi-k27" "kimi-k27-code:kimi-k27-code" "kimi-k3-low:kimi-k3-low"
  "oc-kimi-code:oc-kimi-code" "oc-glm:oc-glm" "oc-kimi-k3:oc-kimi-k3"
  "oc-dsflash:oc-dsflash" "oc-gflash:oc-gflash" "oc-sonnet46:oc-sonnet46"
  "oc-oss:oc-oss" "oc-omni:oc-omni" "oc-qwen37-max:oc-qwen37-max"
  "oc-minimax-m3:oc-minimax-m3" "oc-solar4:oc-solar4" "grok:grok-hi" "grok-hi:grok-hi" "grok-med:grok-hi" "grok45:grok-hi" "grok45-med:grok-hi" "grok46:grok-hi" "grok46-med:grok-hi"
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
# #593: fable is consult_only in the catalog, so it is no longer a plain entry
# in the table above — a bare spawn is refused even when the quota gate allows
# it. Its gate spelling is still part of the contract, asserted with the
# operator request that makes the launch legal.
: >"$TMP/scopefuel.log"
: >"$TMP/herdr.log"
spawn_base fable --operator-request hk:doc/decision/2026-09-21/astra-allowed-purposes-approved \
  --requested-by operator >/dev/null
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == fable ]]
: >"$TMP/herdr.log"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m fable -p "$PROMPT" -w w -l fixture --t T1

run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m agy -p "$PROMPT" -w w -l fixture

# Task 577: Devin temporarily bypasses Herdr 0.9.1's failing agent-start
# ownership check. The fixture pins the exact pane-id run -> bounded welcome
# wait -> explain identity -> pane-id rename sequence, and no prompt/effort
# mutation is smuggled into the Devin process. Permission mode is intentionally
# unattended (`--permission-mode dangerous`): accept-edits prompts on every
# shell command in a pane and stalls (task201). Task 240 later admitted the
# same profile under --role builder (pilot) without changing this argv.
: >"$TMP/herdr.log"
# The fake clock below answers every `date +%s` with 1000 until the first
# herdr call matching FAKECLOCK_AFTER is logged, then 1000+FAKECLOCK_JUMP
# (#606).
# With FAKECLOCK_JUMP=0 it is frozen, so the attempt cap — not how fast this
# host runs 120 fixture calls — is what ends a never-ready poll.
mkdir -p "$TMP/jumpclock"
cat >"$TMP/jumpclock/date" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == +%s ]]; then
  seen="$(grep -c "^$FAKECLOCK_AFTER" "$WRK_FIXTURE_LOG" 2>/dev/null || true)"
  if (( ${seen:-0} >= 1 )); then echo $(( 1000 + FAKECLOCK_JUMP )); else echo 1000; fi
  exit 0
fi
exec /bin/date "$@"
SH
chmod +x "$TMP/jumpclock/date"
devin_idle_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-swe2 2>&1)"
grep -q 'model=devin-swe2' <<<"$devin_idle_out"
grep -q 'status=idle' <<<"$devin_idle_out"
grep -q 'landed=yes' <<<"$devin_idle_out"
[[ "$(grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
devin_run_line="$(grep '^pane run ' "$TMP/herdr.log")"
[[ "$devin_run_line" == 'pane run w:p1 devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' ]] ||
  fail "devin pane-run argv snapshot mismatch: $devin_run_line"
# Detection and the idle wait share one 30s window, so the wait gets what is
# left of it (whole seconds; never more than 30000ms). The clock is frozen so
# host speed cannot move the value (#606: the shell-ready poll now also runs
# inside the window, and on a loaded host 2-3s had already passed).
devin_wait_line="$(grep '^agent wait ' "$TMP/herdr.log")"
if ! [[ "$devin_wait_line" =~ ^agent\ wait\ w:p1\ --until\ idle\ --timeout\ ([0-9]+)$ ]] ||
   (( BASH_REMATCH[1] != 30000 )); then
  fail "devin welcome wait argv drifted: $devin_wait_line"
fi
grep -qx 'agent get w:p1' "$TMP/herdr.log" ||
  fail "devin detection poll must query the tab-create pane id"
grep -qx 'agent explain w:p1 --format json' "$TMP/herdr.log" ||
  fail "devin explain argv drifted"
grep -qx 'agent rename w:p1 fixture' "$TMP/herdr.log" ||
  fail "devin rename must target tab-create pane id, never a name lookup"
if grep -q '^agent start .*--kind devin' "$TMP/herdr.log"; then
  fail "devin workaround must not call agent start"
fi
devin_run_no="$(grep -n '^pane run ' "$TMP/herdr.log" | cut -d: -f1)"
devin_get_no="$(grep -n '^agent get ' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
(( devin_run_no < devin_get_no )) || fail "devin detection poll must follow pane run"
devin_wait_no="$(grep -n '^agent wait ' "$TMP/herdr.log" | cut -d: -f1)"
devin_explain_no="$(grep -n '^agent explain ' "$TMP/herdr.log" | cut -d: -f1)"
devin_rename_no="$(grep -n '^agent rename ' "$TMP/herdr.log" | cut -d: -f1)"
devin_prompt_no="$(grep -n '^agent prompt .*fixture prompt' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
(( devin_run_no < devin_wait_no && devin_wait_no < devin_explain_no &&
   devin_explain_no < devin_rename_no && devin_rename_no < devin_prompt_no )) ||
  fail "devin startup order must be run < wait < explain < rename < brief"
[[ " $devin_run_line " != *' -p '* ]] || fail "devin run argv must not contain -p"
[[ " $devin_run_line " != *' --dangerously-skip-permissions '* ]] || fail "devin run argv must not contain Claude-only --dangerously-skip-permissions"
[[ " $devin_run_line " != *' --effort '* ]] || fail "devin run argv must not contain effort"
# Pin README's documented argv to the live snapshot. Read README; do not
# hardcode a second expected string (that would just grow the drift surface).
# shellcheck disable=SC2016  # the backtick is literal markdown, not a substitution
readme_devin_argv="$(sed -n 's/.*`herdr pane run <pane_id> devin \(--model swe-2 .* --respect-workspace-trust false\)`.*/\1/p' "$ROOT/README.md")"
[[ -n "$readme_devin_argv" && "$(grep -c . <<<"$readme_devin_argv")" -eq 1 ]] ||
  fail "README.md has no unique documented devin argv to pin against the snapshot"
devin_snapshot_argv="${devin_run_line#pane run w:p1 devin }"
[[ "$readme_devin_argv" == "$devin_snapshot_argv" ]] ||
  fail "README.md argv drifted from wrk snapshot: readme='$readme_devin_argv' snapshot='$devin_snapshot_argv'"

# Task 577 FIX: right after `pane run` herdr has not yet detected the pane, so
# agent get/wait/explain answer agent_not_found (16:44 probe2). Inside the
# window that is "not detected yet": poll `agent get` on the created pane id,
# and only after detection wait for idle, check identity and rename. Reverting
# agent_not_found to an immediate failure turns this case red.
: >"$TMP/herdr.log"
devin_late_out="$(TEST_FIXTURE_SCENARIO=devin-late-detect spawn_base devin-swe2 2>&1)" ||
  fail "Devin detected on the fourth poll must still spawn: $devin_late_out"
grep -q 'landed=yes' <<<"$devin_late_out" || fail "late-detected Devin did not land: $devin_late_out"
devin_late_first_wait="$(grep -n '^agent wait ' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
[[ "$(head -n "$devin_late_first_wait" "$TMP/herdr.log" | grep -c '^agent get w:p1$')" -eq 4 ]] ||
  fail "late-detected Devin must poll get until detection before waiting"
grep -qx 'agent rename w:p1 fixture' "$TMP/herdr.log" ||
  fail "late-detected Devin must rename the tab-create pane id"
[[ "$(grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "late-detected Devin must receive exactly one brief"
if grep -q '^pane close ' "$TMP/herdr.log"; then fail "late-detected Devin pane was closed"; fi

# Mutants for the ownership substitute: skipping the bounded wait/explain,
# accepting another detected agent/rule, or renaming after timeout must all be
# red. Every failure records process-info and lets the existing pane cleanup run.
devin_readiness_failure_case() {
  local scenario="$1" want_rc="$2" out rc
  : >"$TMP/herdr.log"
  set +e
  # Frozen clock (#606): the attempt cap, not host speed, ends never-detect.
  out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO="$scenario" spawn_base devin-swe2 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq "$want_rc" ]] ||
    fail "$scenario expected rc=$want_rc, got rc=$rc: $out"
  grep -qx 'pane run w:p1 devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' "$TMP/herdr.log" ||
    fail "$scenario did not use the created pane id"
  if grep -q '^agent rename ' "$TMP/herdr.log"; then
    fail "$scenario renamed an unowned/unready pane"
  fi
  if grep -q '^agent prompt ' "$TMP/herdr.log"; then
    fail "$scenario delivered a brief before ownership/readiness"
  fi
  sed -n '/^pane run /,$p' "$TMP/herdr.log" | grep -qx 'pane process-info --pane w:p1' ||
    fail "$scenario omitted failure process diagnostics"
  grep -qx 'pane close w:p1' "$TMP/herdr.log" ||
    fail "$scenario leaked the failed pane"
  DEVIN_CASE_OUT="$out"
}
devin_readiness_failure_case devin-wait-timeout 7
devin_readiness_failure_case devin-wrong-agent 1
devin_readiness_failure_case devin-wrong-rule 1
# Task 577 SHOULD (first-round tester): every remaining diagnostic branch is
# pinned by its own fixture failure.
devin_readiness_failure_case devin-run-fail 5
devin_readiness_failure_case devin-get-error 1
grep -q 'agent get exited 1 before detection' <<<"$DEVIN_CASE_OUT" ||
  fail "non-agent_not_found get error lost its diagnostic: $DEVIN_CASE_OUT"
[[ "$(grep -c '^agent get w:p1$' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "non-agent_not_found get error must fail on the first get, not be retried"
devin_readiness_failure_case devin-explain-fail 4
devin_readiness_failure_case devin-explain-garbage 1
grep -q 'agent explain returned an invalid identity envelope' <<<"$DEVIN_CASE_OUT" ||
  fail "malformed explain JSON lost its diagnostic: $DEVIN_CASE_OUT"
devin_readiness_failure_case devin-never-detect 1
grep -q "Devin pane startup failed: agent not detected within 30000ms (agent_not_found x120)" <<<"$DEVIN_CASE_OUT" ||
  fail "never-detected Devin lost its bounded-window diagnostic: $DEVIN_CASE_OUT"
[[ "$(grep -c '^agent get w:p1$' "$TMP/herdr.log")" -eq 120 ]] ||
  fail "never-detected Devin must poll exactly the 30000/250 attempt cap"
if grep -q '^agent wait \|^agent explain ' "$TMP/herdr.log"; then
  fail "never-detected Devin waited or explained an undetected pane"
fi

# Detection on the window edge: a fake clock (only `date +%s` is faked) puts
# every reading after the first 31s past pane run. Detection succeeds on the
# first get, but no time is left, so wrk must fail before agent wait instead of
# handing it a zero or negative timeout.
mkdir -p "$TMP/fakeclock"
cat >"$TMP/fakeclock/date" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == +%s ]]; then
  if [[ -e "$FAKECLOCK_STATE" ]]; then echo 1031; else : >"$FAKECLOCK_STATE"; echo 1000; fi
  exit 0
fi
exec /bin/date "$@"
SH
chmod +x "$TMP/fakeclock/date"
: >"$TMP/herdr.log"
rm -f "$TMP/fakeclock.state"
set +e
devin_edge_out="$(PATH="$TMP/fakeclock:$PATH" FAKECLOCK_STATE="$TMP/fakeclock.state" TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-swe2 2>&1)"
devin_edge_rc=$?
set -e
[[ "$devin_edge_rc" -eq 1 ]] || fail "window-edge Devin detection expected rc=1, got $devin_edge_rc: $devin_edge_out"
grep -q 'Devin pane startup failed: agent detected after the 30000ms window' <<<"$devin_edge_out" ||
  fail "window-edge Devin detection lost its diagnostic: $devin_edge_out"
if grep -q '^agent wait \|^agent rename \|^agent prompt ' "$TMP/herdr.log"; then
  fail "window-edge Devin detection waited, renamed or delivered past the window"
fi
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "window-edge Devin detection leaked its pane"

# The wall clock, not the attempt cap, is what bounds the window in
# production (verify1 E1: 97 gets in 30s). With the same fake clock, the first
# agent_not_found is already past the window: wrk must stop after that one get,
# long before the 120-attempt cap, and never wait or rename.
: >"$TMP/herdr.log"
rm -f "$TMP/fakeclock.state"
set +e
devin_clock_out="$(PATH="$TMP/fakeclock:$PATH" FAKECLOCK_STATE="$TMP/fakeclock.state" TEST_FIXTURE_SCENARIO=devin-never-detect spawn_base devin-swe2 2>&1)"
devin_clock_rc=$?
set -e
[[ "$devin_clock_rc" -eq 1 ]] || fail "wall-clock-bounded Devin detection expected rc=1, got $devin_clock_rc: $devin_clock_out"
grep -q 'agent not detected within 30000ms (agent_not_found x1)' <<<"$devin_clock_out" ||
  fail "wall-clock bound did not stop the detection poll: $devin_clock_out"
[[ "$(grep -c '^agent get w:p1$' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "wall-clock bound must stop polling at the first get past the window"
if grep -q '^agent wait \|^agent rename \|^agent prompt ' "$TMP/herdr.log"; then
  fail "wall-clock-bounded Devin detection waited, renamed or delivered"
fi

# SHOULD-1 (first-round tester): a rename failure must record diagnostics for
# the renamed pane and deliver nothing.
: >"$TMP/herdr.log"
set +e
devin_rename_out="$(TEST_FIXTURE_SCENARIO=devin-rename-fail spawn_base devin-swe2 2>&1)"
devin_rename_rc=$?
set -e
[[ "$devin_rename_rc" -eq 6 ]] || fail "devin rename failure expected rc=6, got $devin_rename_rc: $devin_rename_out"
grep -q 'Devin pane startup failed: agent rename exited 6; pane=w:p1' <<<"$devin_rename_out" ||
  fail "devin rename failure lost its diagnostic: $devin_rename_out"
devin_rename_no="$(grep -n '^agent rename w:p1 fixture$' "$TMP/herdr.log" | cut -d: -f1)"
devin_info_no="$(grep -n '^pane process-info --pane w:p1$' "$TMP/herdr.log" | tail -n1 | cut -d: -f1)"
if [[ -z "$devin_rename_no" || -z "$devin_info_no" ]] || (( devin_rename_no > devin_info_no )); then
  fail "devin rename failure must record process-info after the failed rename"
fi
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "devin rename failure leaked its pane"
if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "devin rename failure delivered a brief"; fi
echo "PASS task577 Devin detection poll, bounded window and failure diagnostics"

# The devin branch remains behind the unchanged gate. A refusal preserves the
# gate rc and reaches neither tab creation nor pane run.
rm -f "$TMP/herdr.log"
set +e
devin_gate_out="$(WRK_GATE_MODE=3 spawn_base devin-swe2 2>&1)"
devin_gate_rc=$?
set -e
[[ "$devin_gate_rc" -eq 3 ]] ||
  fail "devin gate refusal rc drifted (rc=$devin_gate_rc): $devin_gate_out"
[[ ! -e "$TMP/herdr.log" ]] || fail "devin gate refusal reached Herdr"

# Every other kind keeps the generic `agent start` path exactly.
: >"$TMP/herdr.log"
spawn_base codex-terra >/dev/null
grep -qx 'agent start fixture --kind codex --pane w:p1 --timeout 120000 -- --yolo -m gpt-5.6-terra -c model_reasoning_effort=medium' "$TMP/herdr.log" ||
  fail "non-Devin agent-start path drifted"
if grep -q '^pane run ' "$TMP/herdr.log"; then fail "non-Devin kind reached pane run"; fi

# #606: a fresh pane whose shell is still running rc subprocesses answers
# `agent start` with agent_pane_busy (real herdr 0.9.0 envelope, stderr, rc=1).
# Inside the START_TIMEOUT window that is retried with the 250ms poll; every
# other start failure still fails at once. Removing the retry turns the
# shell-busy cases red; retrying every error turns the non-busy cases red.
for shell_busy_pair in "opus:claude" "codex-terra:codex"; do
  shell_busy_model="${shell_busy_pair%%:*}"
  shell_busy_kind="${shell_busy_pair#*:}"
  : >"$TMP/herdr.log"
  shell_busy_out="$(TEST_FIXTURE_SCENARIO=shell-busy spawn_base "$shell_busy_model" 2>&1)" ||
    fail "$shell_busy_model: shell ready on the fourth start must still spawn: $shell_busy_out"
  grep -q '^OK pane=w:p1' <<<"$shell_busy_out" ||
    fail "$shell_busy_model: late shell did not reach the OK line: $shell_busy_out"
  grep -q 'landed=yes' <<<"$shell_busy_out" ||
    fail "$shell_busy_model: late shell brief did not land: $shell_busy_out"
  [[ "$(grep -c "^agent start fixture --kind $shell_busy_kind --pane w:p1 " "$TMP/herdr.log")" -eq 4 ]] ||
    fail "$shell_busy_model: agent_pane_busy x3 must be retried on the tab-create pane until accepted"
  [[ "$(grep -c '"code":"agent_pane_busy"' <<<"$shell_busy_out")" -eq 3 ]] ||
    fail "$shell_busy_model: each busy refusal must stay visible on stderr: $shell_busy_out"
  [[ "$(grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$shell_busy_model: late shell must receive exactly one brief"
  first_prompt_no="$(grep -n '^agent prompt ' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
  last_start_no="$(grep -n '^agent start ' "$TMP/herdr.log" | tail -n1 | cut -d: -f1)"
  (( last_start_no < first_prompt_no )) || fail "$shell_busy_model: brief delivered before the accepted start"
  if grep -q '^pane close ' "$TMP/herdr.log"; then fail "$shell_busy_model: late-shell pane was closed"; fi
done

# A shell that never frees the foreground fails closed at the window: the
# attempt cap bounds the loop when sleep is disabled (30000/250 for Claude),
# the pane is closed and no brief is delivered.
: >"$TMP/herdr.log"
set +e
shell_never_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO=shell-never-ready spawn_base opus 2>&1)"
shell_never_rc=$?
set -e
[[ "$shell_never_rc" -eq 1 ]] || fail "never-ready shell expected rc=1, got $shell_never_rc: $shell_never_out"
grep -q 'agent start failed: shell not ready within the 30000ms window (agent_pane_busy x120); pane=w:p1' <<<"$shell_never_out" ||
  fail "never-ready shell lost its bounded-window diagnostic: $shell_never_out"
[[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 120 ]] ||
  fail "never-ready shell must stop at the 30000/250 attempt cap"
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "never-ready shell leaked its pane"
if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "never-ready shell delivered a brief"; fi

# Non-busy start failures keep failing on the first attempt with herdr's rc.
for shell_err_pair in "start-not-ready:1:agent_not_ready" "start-pane-unavailable:3:agent_pane_unavailable"; do
  IFS=: read -r shell_err_scenario shell_err_rc shell_err_code <<<"$shell_err_pair"
  : >"$TMP/herdr.log"
  set +e
  shell_err_out="$(TEST_FIXTURE_SCENARIO="$shell_err_scenario" spawn_base opus 2>&1)"
  shell_err_got=$?
  set -e
  [[ "$shell_err_got" -eq "$shell_err_rc" ]] ||
    fail "$shell_err_scenario expected rc=$shell_err_rc, got $shell_err_got: $shell_err_out"
  [[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$shell_err_scenario must not be retried"
  grep -q "\"code\":\"$shell_err_code\"" <<<"$shell_err_out" ||
    fail "$shell_err_scenario lost herdr's error envelope: $shell_err_out"
  grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "$shell_err_scenario leaked its pane"
  if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "$shell_err_scenario delivered a brief"; fi
done

# Window boundaries on a fake clock: every `date +%s` after the first agent
# start (or, for Devin, the first process-info) reads FAKECLOCK_JUMP seconds
# later. Each retry hands herdr only what is left of the window, and herdr
# refuses a start timeout of 3000ms or less, so Claude's 30s window accepts a
# retry at 26s (4000ms left) and fails closed at 27s, 30s and 31s. Codex's
# 120s window still retries at 31s.
shell_window_case() {
  local model="$1" scenario="$2" after="$3" jump="$4"
  : >"$TMP/herdr.log"
  set +e
  SHELL_WINDOW_OUT="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER="$after" FAKECLOCK_JUMP="$jump" \
    WRK_FIXTURE_SHELL_BUSY_COUNT=1 TEST_FIXTURE_SCENARIO="$scenario" spawn_base "$model" 2>&1)"
  SHELL_WINDOW_RC=$?
  set -e
}
shell_window_case opus shell-busy 'agent start ' 26
[[ "$SHELL_WINDOW_RC" -eq 0 ]] || fail "retry at 26s of 30s must spawn: $SHELL_WINDOW_OUT"
grep -q '^agent start fixture --kind claude --pane w:p1 --timeout 4000 -- ' "$TMP/herdr.log" ||
  fail "retry at 26s must hand herdr only the 4000ms left of the window"
for shell_window_jump in 27 29 30 31; do
  shell_window_case opus shell-busy 'agent start ' "$shell_window_jump"
  [[ "$SHELL_WINDOW_RC" -eq 1 ]] ||
    fail "retry at ${shell_window_jump}s of 30s expected rc=1, got $SHELL_WINDOW_RC: $SHELL_WINDOW_OUT"
  grep -q 'shell not ready within the 30000ms window (agent_pane_busy x1); pane=w:p1' <<<"$SHELL_WINDOW_OUT" ||
    fail "retry at ${shell_window_jump}s lost its window diagnostic: $SHELL_WINDOW_OUT"
  [[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "retry at ${shell_window_jump}s must not start again past the window"
  grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "retry at ${shell_window_jump}s leaked its pane"
  if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "retry at ${shell_window_jump}s delivered a brief"; fi
done
# A second ticking over between the window's start reading and the first
# attempt must not shorten a first-attempt success: it keeps the pre-#606
# argv (tester R1 repro: `date +%s` 1000 then 1001 gave --timeout 29000).
mkdir -p "$TMP/tickclock"
cat >"$TMP/tickclock/date" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == +%s ]]; then
  if [[ -e "$FAKECLOCK_STATE" ]]; then echo 1001; else : >"$FAKECLOCK_STATE"; echo 1000; fi
  exit 0
fi
exec /bin/date "$@"
SH
chmod +x "$TMP/tickclock/date"
: >"$TMP/herdr.log"
rm -f "$TMP/tickclock.state"
tick_out="$(PATH="$TMP/tickclock:$PATH" FAKECLOCK_STATE="$TMP/tickclock.state" spawn_base opus 2>&1)" ||
  fail "first-attempt start across a second tick must spawn: $tick_out"
[[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "first-attempt start across a second tick must start once"
grep -q '^agent start fixture --kind claude --pane w:p1 --timeout 30000 -- ' "$TMP/herdr.log" ||
  fail "first-attempt start must keep --timeout 30000 across a second tick: $(grep '^agent start ' "$TMP/herdr.log")"
shell_window_case codex-terra shell-busy 'agent start ' 31
[[ "$SHELL_WINDOW_RC" -eq 0 ]] || fail "codex retry at 31s of 120s must spawn: $SHELL_WINDOW_OUT"
grep -q '^agent start fixture --kind codex --pane w:p1 --timeout 89000 -- ' "$TMP/herdr.log" ||
  fail "codex retry at 31s must hand herdr the 89000ms left of its window"

# Devin types through `pane run`, which checks nothing, so wrk polls
# process-info before it until the shell holds the foreground alone. The same
# window then covers detection and the idle wait.
: >"$TMP/herdr.log"
devin_shell_out="$(TEST_FIXTURE_SCENARIO=devin-shell-busy spawn_base devin-swe2 2>&1)" ||
  fail "Devin with a shell ready on the fourth poll must still spawn: $devin_shell_out"
grep -q 'landed=yes' <<<"$devin_shell_out" || fail "late-shell Devin did not land: $devin_shell_out"
devin_shell_run_no="$(grep -n '^pane run ' "$TMP/herdr.log" | cut -d: -f1)"
[[ "$(head -n "$devin_shell_run_no" "$TMP/herdr.log" | grep -c '^pane process-info --pane w:p1$')" -eq 4 ]] ||
  fail "late-shell Devin must poll process-info on the tab-create pane until ready, then pane run"
if grep -q '^pane close ' "$TMP/herdr.log"; then fail "late-shell Devin pane was closed"; fi
devin_shell_failure_case() {
  local scenario="$1" diag="$2" out rc
  : >"$TMP/herdr.log"
  set +e
  out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO="$scenario" spawn_base devin-swe2 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 1 ]] || fail "$scenario expected rc=1, got rc=$rc: $out"
  grep -q "Devin pane startup failed: $diag; pane=w:p1" <<<"$out" || fail "$scenario lost its diagnostic: $out"
  if grep -q '^pane run \|^agent rename \|^agent prompt ' "$TMP/herdr.log"; then
    fail "$scenario ran Devin, renamed or delivered into an unready shell"
  fi
  grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "$scenario leaked its pane"
}
devin_shell_failure_case devin-shell-never-ready 'shell not ready within 30000ms (foreground busy x120)'
devin_shell_failure_case devin-process-info-fail 'pane process-info exited 3 before pane run'
[[ "$(grep -c '^pane process-info ' "$TMP/herdr.log")" -eq 2 ]] ||
  fail "a failed process-info must not be polled again (one check + one diagnostic)"
devin_shell_failure_case devin-process-info-garbage 'pane process-info returned an invalid envelope before pane run'
[[ "$(grep -c '^pane process-info ' "$TMP/herdr.log")" -eq 2 ]] ||
  fail "an unreadable process-info must not be polled again (one check + one diagnostic)"
shell_window_case devin-swe2 devin-shell-busy 'pane process-info ' 29
[[ "$SHELL_WINDOW_RC" -eq 0 ]] || fail "Devin shell ready at 29s of 30s must spawn: $SHELL_WINDOW_OUT"
grep -qx 'agent wait w:p1 --until idle --timeout 1000' "$TMP/herdr.log" ||
  fail "Devin shell ready at 29s must leave the idle wait only the 1000ms left"
for shell_window_jump in 30 31; do
  shell_window_case devin-swe2 devin-shell-busy 'pane process-info ' "$shell_window_jump"
  [[ "$SHELL_WINDOW_RC" -eq 1 ]] ||
    fail "Devin shell at ${shell_window_jump}s expected rc=1, got $SHELL_WINDOW_RC: $SHELL_WINDOW_OUT"
  grep -q 'shell not ready within 30000ms (foreground busy x1)' <<<"$SHELL_WINDOW_OUT" ||
    fail "Devin shell at ${shell_window_jump}s lost its window diagnostic: $SHELL_WINDOW_OUT"
  if grep -q '^pane run ' "$TMP/herdr.log"; then fail "Devin shell at ${shell_window_jump}s ran past the window"; fi
  grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "Devin shell at ${shell_window_jump}s leaked its pane"
done
echo "PASS task606 shell-ready wait: agent_pane_busy retry, Devin process-info poll, window bound, fail-closed"

expect_exit 2 spawn_base devin-swe2 --effort high
# Task 240 pilot (operator decision 2026-09-14 §3): the devin-swe2 worker
# spelling is now admitted under --role builder too — this acceptance replaces
# the pre-pilot `expect_exit 2` refusal that pinned devin as worker-only.
set +e
devin_builder_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-swe2 --role builder --lane devin-builder-lane --parent parent-lane --job devin-worker-builder-job 2>&1)"
devin_builder_rc=$?
set -e
[[ "$devin_builder_rc" -eq 0 ]] ||
  fail "devin-swe2 must be admitted under --role builder (rc=$devin_builder_rc): $devin_builder_out"
grep -q 'model=devin-swe2' <<<"$devin_builder_out" ||
  fail "devin-swe2 builder spawn output lost its model: $devin_builder_out"
grep -q '^OK ' <<<"$devin_builder_out" ||
  fail "devin-swe2 builder spawn did not reach the OK line: $devin_builder_out"
echo "PASS devin-swe2 worker kind/argv/no-effort snapshot + builder-pilot admission"

# Task 281 (operator decision 2026-09-14 devin-pro-paid-models): the three
# additional Devin model profiles reuse the identical unattended argv — only
# the --model name differs — and reject --effort like devin-swe2.
for devin_pair in "devin-glm52:glm-5-2" "devin-swe17:swe-1-7" "devin-ds41:deepseek-v4-1-flash-high"; do
  devin_profile="${devin_pair%%:*}"
  devin_model="${devin_pair#*:}"
  : >"$TMP/herdr.log"
  devin_variant_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base "$devin_profile" 2>&1)"
  grep -q "model=$devin_profile" <<<"$devin_variant_out" ||
    fail "$devin_profile spawn output lost its model: $devin_variant_out"
  grep -q 'status=idle' <<<"$devin_variant_out" ||
    fail "$devin_profile did not reach idle landing: $devin_variant_out"
  devin_variant_run="$(grep '^pane run ' "$TMP/herdr.log")"
  [[ "$devin_variant_run" == "pane run w:p1 devin --model $devin_model --permission-mode dangerous --respect-workspace-trust false" ]] ||
    fail "$devin_profile run argv snapshot mismatch: $devin_variant_run"
  [[ " $devin_variant_run " != *' --effort '* ]] ||
    fail "$devin_profile run argv must not contain effort"
  expect_exit 2 spawn_base "$devin_profile" --effort high
done
echo "PASS devin-glm52/devin-swe17/devin-ds41 worker kind/argv/no-effort snapshots"

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
kimi_k3_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$kimi_k3_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/k3' ]] ||
  fail "kimi-k3 start argv snapshot mismatch: $kimi_k3_start"
: >"$TMP/herdr.log"
spawn_base kimi-k27 >/dev/null
kimi_k27_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$kimi_k27_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/kimi-for-coding' ]] ||
  fail "kimi-k27 start argv snapshot mismatch: $kimi_k27_start"
: >"$TMP/herdr.log"
spawn_base kimi-k27-code >/dev/null
kimi_k27_code_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$kimi_k27_code_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/kimi-for-coding' ]] ||
  fail "kimi-k27-code start argv snapshot mismatch: $kimi_k27_code_start"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m kimi-k3 -p "$PROMPT" -w w -l fixture --effort high
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m kimi-k27-code -p "$PROMPT" -w w -l fixture --effort high

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
kimi_low_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$kimi_low_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/k3' ]] ||
  fail "kimi-k3-low start argv snapshot mismatch: $kimi_low_start"
grep -q -- '--env KIMI_CODE_HOME=' "$TMP/herdr.log"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m kimi-k3-low -p "$PROMPT" -w w -l fixture --effort high
: >"$TMP/herdr.log"
spawn_base kimi-k3 >/dev/null
if grep -q -- 'KIMI_CODE_HOME' "$TMP/herdr.log"; then exit 1; fi
: >"$TMP/herdr.log"
spawn_base kimi-k27 >/dev/null
if grep -q -- 'KIMI_CODE_HOME' "$TMP/herdr.log"; then exit 1; fi
: >"$TMP/herdr.log"
spawn_base kimi-k27-code >/dev/null
if grep -q -- 'KIMI_CODE_HOME' "$TMP/herdr.log"; then exit 1; fi

# Task 612: kimi-clone-home must carry kimi-code/ namespace config into the clone
# byte-identically (a fresh kimi 2.0.2 install — e.g. desktop — has only
# `kimi-code/*` model entries, and the clone is what kimi-k3-low runs against).
CLONE_SRC="$TMP/kimi-src-home"
CLONE_DEST="$TMP/kimi-low-home"
mkdir -p "$CLONE_SRC/credentials" "$CLONE_SRC/oauth" "$CLONE_SRC/sessions" "$CLONE_SRC/logs"
cat >"$CLONE_SRC/config.toml" <<'EOF'
default_model = "kimi-code/k3"

[providers."managed:kimi-code"]
type = "kimi"
base_url = "https://api.kimi.com/coding/v1"

[providers."managed:kimi-code".oauth]
storage = "file"
key = "oauth/kimi-code"

[models."kimi-code/k3"]
provider = "managed:kimi-code"
model = "k3"

[models."kimi-code/kimi-for-coding"]
provider = "managed:kimi-code"
model = "kimi-for-coding"

[thinking]
effort = "high"
EOF
printf 'fixture-credential\n' >"$CLONE_SRC/credentials/kimi-code.json"
printf 'fixture-oauth\n' >"$CLONE_SRC/oauth/kimi-code"
printf 'fixture-device-id\n' >"$CLONE_SRC/device_id"
printf 'fixture-session\n' >"$CLONE_SRC/sessions/s1.jsonl"
printf 'fixture-log\n' >"$CLONE_SRC/logs/l1.log"
env KIMI_CODE_SRC="$CLONE_SRC" KIMI_CODE_LOW_HOME="$CLONE_DEST" \
  "$ROOT/bin/kimi-clone-home" >/dev/null
# The clone config must equal the source byte-for-byte except the [thinking]
# effort rewrite to "low" — compare against a literal expected file so a
# lossy clone (dropped lines, missing entries) fails here.
cat >"$TMP/config-expected.toml" <<'EOF'
default_model = "kimi-code/k3"

[providers."managed:kimi-code"]
type = "kimi"
base_url = "https://api.kimi.com/coding/v1"

[providers."managed:kimi-code".oauth]
storage = "file"
key = "oauth/kimi-code"

[models."kimi-code/k3"]
provider = "managed:kimi-code"
model = "k3"

[models."kimi-code/kimi-for-coding"]
provider = "managed:kimi-code"
model = "kimi-for-coding"

[thinking]
effort = "low"
EOF
cmp "$TMP/config-expected.toml" "$CLONE_DEST/config.toml" ||
  fail "clone config.toml must equal source except [thinking] effort=low"
[[ -f "$CLONE_DEST/credentials/kimi-code.json" ]] || fail "clone must carry credentials/"
[[ -f "$CLONE_DEST/oauth/kimi-code" ]] || fail "clone must carry oauth/"
[[ -f "$CLONE_DEST/device_id" ]] || fail "clone must carry device_id"
[[ ! -e "$CLONE_DEST/sessions" ]] || fail "clone must not carry sessions/"
[[ ! -e "$CLONE_DEST/logs" ]] || fail "clone must not carry logs/"
# The clone rewrite must not touch the source home.
grep -q 'effort = "high"' "$CLONE_SRC/config.toml" ||
  fail "source config.toml must stay untouched"
echo "PASS kimi-clone-home copies kimi-code/ namespace entries verbatim"

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
# Default effort for opus is high even without override (ROB-591).
: >"$TMP/herdr.log"
spawn_base opus >/dev/null
grep -q -- '--effort high' "$TMP/herdr.log"
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
# Task 210: oc-solar4 kind+args snapshot. A model/kind drift must fail this
# exact-string assertion (not an exception during spawn).
oc_solar4_out="$(spawn_base oc-solar4 2>&1)"
grep -q 'model=oc-solar4' <<<"$oc_solar4_out"
oc_solar4_start_line="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$oc_solar4_start_line" == 'agent start fixture --kind opencode --pane w:p1 --timeout 30000 -- --auto --model upstage/solar-pro4' ]] ||
  fail "oc-solar4 start argv snapshot mismatch: $oc_solar4_start_line"
echo "PASS oc-solar4 kind/args snapshot"
: >"$TMP/herdr.log"
# ROB-591: 기본 grok = 4.7, grok45/grok46 은 둘 다 즉시 롤백용 명시 별칭
spawn_base grok >/dev/null
grep -q -- '-m grok-4.7' "$TMP/herdr.log"
grep -q -- '--effort high' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base grok45 >/dev/null
grep -q -- '-m grok-4.5' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base grok46 >/dev/null
grep -q -- '-m grok-4.6' "$TMP/herdr.log"
: >"$TMP/herdr.log"
# ROB-1186 at-most-once, now on the #498 rc 4 fallback: the direct herdr
# injection whose --wait fails gets one return and is never sent again.
once_out="$(env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=prompt-wait-fails WRK_FIXTURE_LOG="$TMP/herdr.log" \
  WRK_PANEWIRE_PROMPT=daemon-down \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" "$WRK" spawn \
  -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1 2>&1)"
grep -q 'model=codex-terra' <<<"$once_out"
grep -q 'landed=yes' <<<"$once_out"
grep -q ' via=herdr-fallback$' <<<"$once_out"
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

# task406: a queued grok payload renders as a `N queued, Enter to send now`
# footer with no `──` head. On a shared screen that chip cannot be attributed
# to THIS injection — the r3 tester showed every "grew past baseline" variant
# is still a false positive (self-echo, missed baseline, count growth, another
# sender). The chip is therefore an ambiguous signal, never landed evidence:
# it only suppresses re-injection so a possibly queued payload is not
# duplicated. The transcript marker stays the only positive evidence, and
# other harnesses must keep ignoring the footer.
: >"$TMP/herdr.log"
grok_queued_out="$(TEST_FIXTURE_SCENARIO=grok-queued spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_queued_out" ||
  fail "grok queued footer is ambiguous, not landed evidence: $grok_queued_out"
grep -q 'grok-queue-chip-unattributable' <<<"$grok_queued_out" ||
  fail "grok chip landed=no must name the unattributable reason: $grok_queued_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "grok queued chip triggered a re-injection: $grok_queued_out"
echo "PASS grok-queued-chip-ambiguous: $grok_queued_out"

# Self-echo with a payload that itself quotes the chip text: the fixture
# echoes the actual injected payload, so this screen genuinely is this
# brief's own echo — and it still must not land.
echo_prompt="$TMP/grok-echo-prompt.md"
printf 'brief literal: 1 queued, Enter to send now (quoted contract text)\n' >"$echo_prompt"
PROMPT="$echo_prompt"
: >"$TMP/herdr.log"
grok_echo_out="$(TEST_FIXTURE_SCENARIO=grok-echo spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_echo_out" ||
  fail "brief self-echo must not land as a grok queue chip: $grok_echo_out"
[[ "$(grep -c '^agent prompt ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "grok self-echo chip triggered a re-injection: $grok_echo_out"
echo "PASS grok-self-echo-no-land: $grok_echo_out"

# Derivation proof: a payload without the chip text must render a different
# post-injection screen, so the normal retry path comes back. A fixture that
# hardcodes the echo would keep showing the chip and fail this case.
echo_prompt_b="$TMP/grok-echo-prompt-b.md"
printf 'brief without the queued contract phrase\n' >"$echo_prompt_b"
PROMPT="$echo_prompt_b"
: >"$TMP/herdr.log"
grok_echo_b_out="$(TEST_FIXTURE_SCENARIO=grok-echo spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_echo_b_out" ||
  fail "payload-derived echo screen changed the verdict path: $grok_echo_b_out"
grep -q 'action=reinject-once' <<<"$grok_echo_b_out" ||
  fail "echo screen must be derived from the actual payload: $grok_echo_b_out"
[[ "$(grep -c '^agent prompt ' "$TMP/herdr.log")" -eq 2 ]] ||
  fail "payload-derived echo suppressed the re-injection: $grok_echo_b_out"
echo "PASS grok-echo-screen-from-payload: $grok_echo_b_out"
PROMPT="$TMP/prompt.md"

: >"$TMP/herdr.log"
grok_stale_out="$(TEST_FIXTURE_SCENARIO=grok-stale spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_stale_out" ||
  fail "a footer the transitional pre-prompt screen missed must not land: $grok_stale_out"
echo "PASS grok-missed-footer-no-land: $grok_stale_out"

: >"$TMP/herdr.log"
grok_or_out="$(TEST_FIXTURE_SCENARIO=grok-or-count spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_or_out" ||
  fail "chip-line growth while the queue shrank must not land: $grok_or_out"
echo "PASS grok-or-count-no-land: $grok_or_out"

: >"$TMP/herdr.log"
grok_toctou_out="$(TEST_FIXTURE_SCENARIO=grok-toctou spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_toctou_out" ||
  fail "another sender's queued payload must not land this injection: $grok_toctou_out"
echo "PASS grok-toctou-no-land: $grok_toctou_out"

: >"$TMP/herdr.log"
grok_zero_out="$(TEST_FIXTURE_SCENARIO=grok-zero spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_zero_out" ||
  fail "0 queued must not land: $grok_zero_out"
grep -q 'action=reinject-once' <<<"$grok_zero_out" ||
  fail "0 queued is not a chip — the normal retry must still run: $grok_zero_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]] ||
  fail "0 queued suppressed the re-injection: $grok_zero_out"
echo "PASS grok-zero-queued-no-land: $grok_zero_out"

# A chip visible only on the first observation still suppresses re-injection,
# and the final warning must keep WHY: the last ticks see no chip, so without
# provenance the reason would decay to working-without-positive-evidence.
: >"$TMP/herdr.log"
grok_transient_out="$(TEST_FIXTURE_SCENARIO=grok-transient spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_transient_out" ||
  fail "transient grok chip must not land: $grok_transient_out"
grep -q 'first_ambiguous_reason=grok-queue-chip-unattributable' <<<"$grok_transient_out" ||
  fail "transient chip lost its ambiguity provenance: $grok_transient_out"
grep -q 'retry=skipped reason=ambiguous-observation' <<<"$grok_transient_out" ||
  fail "transient chip must still suppress re-injection: $grok_transient_out"
[[ "$(grep -c '^agent prompt ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "transient chip triggered a re-injection: $grok_transient_out"
echo "PASS grok-transient-chip-provenance: $grok_transient_out"

: >"$TMP/herdr.log"
grok_marker_out="$(TEST_FIXTURE_SCENARIO=grok-marker spawn_base grok 2>&1)"
grep -q 'landed=yes' <<<"$grok_marker_out" ||
  fail "transcript marker must stay priority-1 evidence for grok: $grok_marker_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "grok marker path triggered a re-injection: $grok_marker_out"
echo "PASS grok-marker-priority-landed: $grok_marker_out"

: >"$TMP/herdr.log"
grok_no_chip_out="$(TEST_FIXTURE_SCENARIO=landing-working-no-marker spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_no_chip_out" ||
  fail "grok without the queued footer must stay landed=no: $grok_no_chip_out"
grep -q 'action=reinject-once' <<<"$grok_no_chip_out" ||
  fail "grok negative path lost the reinject-once action: $grok_no_chip_out"
echo "PASS grok-no-chip-negative: $grok_no_chip_out"

: >"$TMP/herdr.log"
claude_grok_chip_out="$(TEST_FIXTURE_SCENARIO=grok-queued spawn_base sonnet 2>&1)"
grep -q 'landed=no' <<<"$claude_grok_chip_out" ||
  fail "claude pane must not treat the grok footer as evidence: $claude_grok_chip_out"
echo "PASS claude-ignores-grok-queued-chip: $claude_grok_chip_out"

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

# ---------------------------------------------------------------------------
# #498: the spawn brief goes through `panewire prompt` only (hk decision
# 2026-09-21/task498-esc-landing-unify). The panewire fixture models the
# daemon: expect preflight, send through the herdr fixture (so herdr.log still
# counts every injection), submission proof only for claude/codex.
PW_LOG="$TMP/panewire-prompt.log"
pw_reset() { rm -f "$PW_LOG" "$PW_LOG".* "$TMP/herdr.log"; }
pw_calls() { if [[ -f "$PW_LOG" ]]; then grep -c '^prompt ' "$PW_LOG"; else echo 0; fi; }
herdr_briefs() { if [[ -f "$TMP/herdr.log" ]]; then grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log" || true; else echo 0; fi; }
pw_spawn() { WRK_PANEWIRE_PROMPT_LOG="$PW_LOG" spawn_base "$@"; }

# A-7: expect line, agent-name target, absolute fresh file, no uptake.
pw_reset
pw_out="$(pw_spawn codex-terra 2>&1)"
grep -q 'landed=yes' <<<"$pw_out" || fail "498 baseline spawn must land: $pw_out"
[[ "$(pw_calls)" -eq 1 ]] || fail "498 one panewire prompt call expected"
[[ "$(herdr_briefs)" -eq 1 ]] || fail "498 exactly one brief injection expected"
grep -q "^prompt from=wrk-spawn:fixture to=fixture file=/.* timeout=60s uptake=\$" "$PW_LOG" ||
  fail "498 panewire prompt argv (name target, absolute file, codex 60s, no uptake): $(cat "$PW_LOG")"
root_physical="$(cd "$ROOT" && pwd -P)"
[[ "$(head -n1 "$PW_LOG.1")" == "expect: name=fixture cwd=$root_physical" ]] ||
  fail "498 expect line: $(head -n1 "$PW_LOG.1")"
diff <(sed '1,2d' "$PW_LOG.1") "$PROMPT" >/dev/null || fail "498 brief body must follow the expect line verbatim"
grep -q ' via=' <<<"$pw_out" && fail "498 panewire path must not annotate via=: $pw_out"
grep -q 'agent prompt w:p1 fixture prompt' "$TMP/herdr.log" || fail "498 brief must reach the pane"
echo "PASS 498-a7-expect-name-cwd-no-uptake"

# C4: injection only after tab create and agent start.
tab_line="$(grep -n '^tab create' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
start_line="$(grep -n '^agent start' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
brief_line="$(grep -n '^agent prompt .*fixture prompt' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
(( tab_line < start_line && start_line < brief_line )) ||
  fail "498 order must be tab create < agent start < brief: $tab_line $start_line $brief_line"
echo "PASS 498-c4-injection-after-start"

# A-3: every refusing gate means zero panewire calls and zero injections.
for gate_mode in 3 4 broken; do
  pw_reset
  WRK_GATE_MODE="$gate_mode" pw_spawn codex-terra >/dev/null 2>&1 && fail "498 gate $gate_mode must refuse"
  [[ "$(pw_calls)" -eq 0 && "$(herdr_briefs)" -eq 0 ]] || fail "498 gate $gate_mode refusal still prompted"
done
pw_reset
TEST_FIXTURE_SCENARIO=tab-create-fails pw_spawn codex-terra >/dev/null 2>&1 && fail "498 tab create failure must fail the spawn"
[[ "$(pw_calls)" -eq 0 ]] || fail "498 no prompt without a pane"
echo "PASS 498-a3-gate-refusal-no-prompt"

# C3: the cwd reaches panewire in herdr's spelling when it names the same
# physical directory, else physical. $TMP is under /var/folders, itself a
# symlink to /private/var/folders on macOS; a symlinked worktree adds one more.
pw_cwd_real="$TMP/pw-cwd-real"; mkdir -p "$pw_cwd_real"
ln -sfn "$pw_cwd_real" "$TMP/pw-cwd-link"
pw_cwd_physical="$(cd "$pw_cwd_real" && pwd -P)"
cwd_case() {
  local reported="$1" pane_cwd="$2" out
  pw_reset
  out="$(WRK_PANEWIRE_PROMPT_LOG="$PW_LOG" WRK_FIXTURE_AGENT_CWD="$reported" WRK_PANEWIRE_PANE_CWD="$pane_cwd" \
    env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
    "$WRK" spawn -c "$TMP/pw-cwd-link" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1 2>&1)"
  grep -q 'landed=yes' <<<"$out" || fail "498 cwd case reported=$reported pane=$pane_cwd: $out $(head -n1 "$PW_LOG.1" 2>/dev/null)"
  [[ "$(head -n1 "$PW_LOG.1")" == "expect: name=fixture cwd=$pane_cwd" ]] || fail "498 cwd spelling: $(head -n1 "$PW_LOG.1")"
}
cwd_case "" "$pw_cwd_physical"                       # herdr gives no cwd: physical
cwd_case "$pw_cwd_physical" "$pw_cwd_physical"       # herdr reports physical
cwd_case "$TMP/pw-cwd-link" "$TMP/pw-cwd-link"       # herdr reports the logical spelling
# herdr says the pane is somewhere else: wrk must not adopt that spelling;
# panewire's preflight then refuses (rc 5) and nothing is injected.
pw_reset
elsewhere_out="$(WRK_PANEWIRE_PROMPT_LOG="$PW_LOG" WRK_FIXTURE_AGENT_CWD=/ WRK_PANEWIRE_PANE_CWD=/ \
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$TMP/pw-cwd-link" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1 2>&1)"
[[ "$(head -n1 "$PW_LOG.1")" == "expect: name=fixture cwd=$pw_cwd_physical" ]] || fail "498 foreign cwd adopted"
grep -q 'landed=no' <<<"$elsewhere_out" || fail "498 cwd mismatch must be landed=no: $elsewhere_out"
grep -q 'panewire_rc=5 submit=unsent' <<<"$elsewhere_out" || fail "498 cwd mismatch detail: $elsewhere_out"
[[ "$(herdr_briefs)" -eq 0 ]] || fail "498 cwd mismatch must not inject (no fallback on rc 5)"
echo "PASS 498-c3-cwd-normalized"

# A-6 ①: no uptake mode — a cold-booting pane that already reports working
# still gets the brief (the fixture refuses working targets when uptake is
# set, as prompt.go does).
pw_reset
working_out="$(TEST_FIXTURE_SCENARIO=landing-scrollback-marker pw_spawn codex-terra 2>&1)"
[[ "$(herdr_briefs)" -eq 1 ]] || fail "498 working target must still receive the brief: $working_out"
grep -q 'landed=yes' <<<"$working_out" || fail "498 working target landing: $working_out"
echo "PASS 498-a6-working-target-injected"

# A-6 ②: panewire's negative verdict on a brief that did land (claude/codex
# rc 6 "submission evidence unproven", transcript shows the brief) is
# corrected by read-only corroboration — landed=yes and no second brief.
for pw_mode in unproven composer; do
  pw_reset
  fn_out="$(WRK_PANEWIRE_PROMPT="$pw_mode" pw_spawn codex-terra 2>&1)"
  grep -q 'landed=yes' <<<"$fn_out" || fail "498 false negative ($pw_mode) must land: $fn_out"
  [[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "498 false negative ($pw_mode) re-injected"
  grep -q 'reinject' <<<"$fn_out" && fail "498 false negative ($pw_mode) announced a reinject: $fn_out"
done
echo "PASS 498-a6-false-negative-no-duplicate"

# I2: confirmed non-landing re-injects once, through panewire, as a new file.
pw_reset
pw_retry_out="$(TEST_FIXTURE_SCENARIO=landing-retry pw_spawn codex-terra 2>&1)"
grep -q 'landed=retry' <<<"$pw_retry_out" || fail "498 retry: $pw_retry_out"
[[ "$(pw_calls)" -eq 2 && "$(herdr_briefs)" -eq 2 ]] || fail "498 retry must be one extra panewire delivery"
first_file="$(sed -n '1s/.* file=\([^ ]*\) .*/\1/p' "$PW_LOG")"
second_file="$(sed -n '2s/.* file=\([^ ]*\) .*/\1/p' "$PW_LOG")"
[[ -n "$first_file" && "$first_file" != "$second_file" ]] || fail "498 re-injection must use a new file path"
[[ "$first_file" == "$TMP/inbox/fixture/"* || "$first_file" == "$(cd "$TMP" && pwd -P)/inbox/fixture/"* ]] ||
  fail "498 prompt file must live in the (fixture) job dir: $first_file"
pw_reset
pw_never_out="$(TEST_FIXTURE_SCENARIO=landing-no pw_spawn codex-terra 2>&1)"
grep -q 'landed=no' <<<"$pw_never_out" || fail "498 never-lands: $pw_never_out"
[[ "$(pw_calls)" -eq 2 && "$(herdr_briefs)" -eq 2 ]] || fail "498 at most one re-injection"
echo "PASS 498-i2-reinject-once-new-file"

# A-5: rc 4 (no daemon socket = guaranteed unsent) and only rc 4 falls back to
# one direct herdr injection, visible on the OK line; never twice.
pw_reset
fb_out="$(WRK_PANEWIRE_PROMPT=daemon-down pw_spawn codex-terra 2>&1)"
grep -q '^OK pane=w:p1 .*landed=yes.* via=herdr-fallback$' <<<"$fb_out" || fail "498 fallback OK line: $fb_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "498 fallback must inject exactly once"
pw_reset
set +e
fb_no_out="$(WRK_PANEWIRE_PROMPT=daemon-down TEST_FIXTURE_SCENARIO=landing-working-no-marker pw_spawn codex-terra --landing-strict 2>&1)"
fb_no_rc=$?
set -e
[[ "$fb_no_rc" -eq 76 ]] || fail "498 fallback landed=no strict exit: $fb_no_rc"
grep -q '^OK pane=w:p1 .*landed=no.* via=herdr-fallback$' <<<"$fb_no_out" || fail "498 fallback no OK line: $fb_no_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "498 fallback must never repeat: $(herdr_briefs)"
grep -q 'reason=fallback-once' <<<"$fb_no_out" || fail "498 fallback no-retry reason: $fb_no_out"
pw_reset
missing_out="$(PANEWIRE_BIN="$TMP/absent-panewire" pw_spawn codex-terra 2>&1)"
grep -q 'landed=yes.* via=herdr-fallback$' <<<"$missing_out" || fail "498 missing panewire binary: $missing_out"
[[ "$(herdr_briefs)" -eq 1 ]] || fail "498 missing panewire: one injection"
# rc 3, rc 5 and both rc 6 flavors never fall back.
for pw_mode in timeout expect-fail rejected-unsent rejected; do
  pw_reset
  set +e
  nf_out="$(WRK_PANEWIRE_PROMPT="$pw_mode" TEST_FIXTURE_SCENARIO=landing-no pw_spawn codex-terra --landing-strict 2>&1)"
  nf_rc=$?
  set -e
  grep -q 'via=herdr-fallback' <<<"$nf_out" && fail "498 $pw_mode must not fall back: $nf_out"
  [[ "$nf_rc" -eq 76 ]] || fail "498 $pw_mode unlanded strict exit: $nf_rc"
  grep -q '^OK pane=w:p1 .*landed=no' <<<"$nf_out" || fail "498 $pw_mode OK line: $nf_out"
  [[ "$(pw_calls)" -eq 1 ]] || fail "498 $pw_mode must not re-deliver"
  want=0; [[ "$pw_mode" == rejected ]] && want=1
  [[ "$(herdr_briefs)" -eq "$want" ]] || fail "498 $pw_mode injections: $(herdr_briefs) want $want"
done
echo "PASS 498-a5-fallback-rc4-only-once"

# A-4: harnesses panewire cannot prove (devin here) keep the pre-#498 verdict
# through corroboration: devin idle after the brief is landed, one brief.
pw_reset
devin_pw_out="$(TEST_FIXTURE_SCENARIO=devin-idle pw_spawn devin-swe2 2>&1)"
grep -q 'landed=yes' <<<"$devin_pw_out" || fail "498 devin landing regressed: $devin_pw_out"
grep -q 'panewire_rc' <<<"$devin_pw_out" && fail "498 devin landed must not carry a failure detail: $devin_pw_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "498 devin one delivery"
echo "PASS 498-a4-devin-corroborated"

# #568: the 2026-09-22 t502-verify duplicate — panewire rc 6 "submission
# evidence unproven" while devin had already consumed the brief. The
# transcript holds the marker folded across a line break and devin reports
# working; neither must trigger a second delivery.
pw_reset
devin_wrapped_out="$(TEST_FIXTURE_SCENARIO=devin-wrapped-marker pw_spawn devin-swe2 2>&1)"
grep -q 'landed=yes' <<<"$devin_wrapped_out" || fail "568 folded-marker devin must land: $devin_wrapped_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "568 folded-marker devin was re-injected"
if grep -q 'reinject' <<<"$devin_wrapped_out"; then fail "568 folded-marker devin announced a reinject: $devin_wrapped_out"; fi
echo "PASS 568-devin-folded-marker-no-duplicate"

# #568 auxiliary evidence: marker absent entirely, devin working after an
# accepted submit — the pane was verified idle before injection, so working
# means it consumed the brief.
pw_reset
devin_working_out="$(TEST_FIXTURE_SCENARIO=devin-working-no-marker pw_spawn devin-swe2 2>&1)"
grep -q 'landed=yes' <<<"$devin_working_out" || fail "568 devin working must land: $devin_working_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "568 devin working was re-injected"
echo "PASS 568-devin-working-status-lands"

# #568: a devin queued banner is unattributable (grok-chip precedent) —
# ambiguous evidence suppresses the re-injection without claiming landed.
pw_reset
devin_queued_out="$(TEST_FIXTURE_SCENARIO=devin-queued pw_spawn devin-swe2 2>&1)"
grep -q 'landed=no' <<<"$devin_queued_out" || fail "568 devin queued must not claim landed: $devin_queued_out"
grep -q 'reason=ambiguous-observation' <<<"$devin_queued_out" ||
  fail "568 devin queued must be ambiguous: $devin_queued_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "568 devin queued was re-injected"
echo "PASS 568-devin-queued-ambiguous-no-reinject"

# #568 negative direction: a devin pane with no evidence at all (status
# unknown — absent from agent list) still gets exactly one re-injection and
# then stops.
pw_reset
devin_none_out="$(TEST_FIXTURE_SCENARIO=devin-no-landing pw_spawn devin-swe2 2>&1)"
grep -q 'landed=no' <<<"$devin_none_out" || fail "568 devin no-landing: $devin_none_out"
grep -q 'action=reinject-once' <<<"$devin_none_out" ||
  fail "568 devin no-landing lost the re-injection: $devin_none_out"
[[ "$(pw_calls)" -eq 2 && "$(herdr_briefs)" -eq 2 ]] ||
  fail "568 devin no-landing must re-inject exactly once: $(pw_calls)/$(herdr_briefs)"
echo "PASS 568-devin-confirmed-nonlanding-reinject-once"

# #568 round-2 (tester blocker): an unconfirmed submit — panewire timed out,
# possibly before anything was sent — must not be upgraded to landed by a
# merely-working devin. The timeout fixture exits before `agent prompt`, so
# herdr_briefs=0 proves nothing was ever injected.
pw_reset
devin_unconf_out="$(TEST_FIXTURE_SCENARIO=devin-working-no-marker WRK_PANEWIRE_PROMPT=timeout \
  pw_spawn devin-swe2 2>&1)"
grep -q 'landed=no' <<<"$devin_unconf_out" ||
  fail "568 unconfirmed+working must not claim landed: $devin_unconf_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 0 ]] ||
  fail "568 unconfirmed+working must not inject: $(pw_calls)/$(herdr_briefs)"
echo "PASS 568-devin-unconfirmed-working-not-landed"

# #568 round-2/3 (tester blockers): the marker's words in unrelated UI text are
# not a folded marker — a UI tab on one line (no line break), a line break
# without indent (no wrap continuation), and an indented break mid-line (not
# after `❭`/line start). With no other evidence this is confirmed non-landing:
# exactly one re-injection.
pw_reset
devin_coll_out="$(TEST_FIXTURE_SCENARIO=devin-fold-collision pw_spawn devin-swe2 2>&1)"
grep -q 'landed=no' <<<"$devin_coll_out" ||
  fail "568 fold-collision must not claim landed: $devin_coll_out"
grep -q 'action=reinject-once' <<<"$devin_coll_out" ||
  fail "568 fold-collision lost the re-injection: $devin_coll_out"
[[ "$(pw_calls)" -eq 2 && "$(herdr_briefs)" -eq 2 ]] ||
  fail "568 fold-collision must re-inject exactly once: $(pw_calls)/$(herdr_briefs)"
echo "PASS 568-devin-fold-collision-not-marker"

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

# Task 201: scopefuel, not wrk, is the sole Devin-pool authority. The fixture's
# stable first line must arrive unchanged at arbiter, while the receipt keeps
# the profile spelling the worker actually launched.
rm -f "$TMP/herdr.log" "$TMP/scopefuel.log"
devin_admit_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-swe2 --job arb-devin --t T1 2>&1)"
grep -qx 'profile=devin-swe2 pool=devin used_pct=0 class=spend' <<<"$devin_admit_out"
grep -q 'quota_record=devin/quota_pool' <<<"$devin_admit_out"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == 'devin-swe2' ]]
arb status --job arb-devin --json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["quota_pool_records"]; assert len(r)==1 and r[0]["pool"]=="devin" and r[0]["profile"]=="devin-swe2", d'
python3 - "$ARBITER_INBOX_ROOT/arb-devin/events" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
spawned = next(event for event in events if event["kind"] == "job.spawned")
assert spawned["payload"]["profile"] == "devin-swe2", spawned
PY
echo "PASS devin-swe2 scopefuel-gate-to-arbiter-pool-and-spawn-receipt"

# Task 577 failure cleanup: a bounded welcome timeout occurs after the Devin
# quota record and pane exist. It must emit process diagnostics, close that
# pane, and release this job's arbiter record without touching another Devin
# job's record.
rm -f "$TMP/herdr.log"
set +e
devin_timeout_out="$(TEST_FIXTURE_SCENARIO=devin-wait-timeout spawn_base devin-swe2 --job arb-devin-timeout --t T2 2>&1)"
devin_timeout_rc=$?
set -e
[[ "$devin_timeout_rc" -eq 7 ]] ||
  fail "arbiter-backed Devin timeout expected rc=7, got $devin_timeout_rc: $devin_timeout_out"
grep -q 'Devin pane startup failed: welcome_prompt_footer wait exited 7' <<<"$devin_timeout_out" ||
  fail "Devin timeout lost its readiness diagnostic"
sed -n '/^agent wait /,$p' "$TMP/herdr.log" | grep -qx 'pane process-info --pane w:p1' ||
  fail "Devin timeout omitted process-info"
grep -qx 'pane close w:p1' "$TMP/herdr.log" ||
  fail "Devin timeout leaked its pane"
arb status --job arb-devin-timeout --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["quota_pool_records"] == [], d
'
python3 - "$ARBITER_INBOX_ROOT/arb-devin-timeout/events" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
assert any(event.get("kind") == "quota_pool.release" for event in events), events
PY
arb status --job arb-devin --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert len(d["quota_pool_records"]) == 1 and d["quota_pool_records"][0]["job_id"] == "arb-devin", d
'
echo "PASS task577 Devin timeout closes pane and releases only its arbiter record"

# Task 577 FIX: a pane never detected inside the window fails the same way —
# no rename, pane closed, only this job's arbiter record released.
rm -f "$TMP/herdr.log"
set +e
devin_undetected_out="$(TEST_FIXTURE_SCENARIO=devin-never-detect spawn_base devin-swe2 --job arb-devin-undetected --t T2 2>&1)"
devin_undetected_rc=$?
set -e
[[ "$devin_undetected_rc" -eq 1 ]] ||
  fail "arbiter-backed undetected Devin expected rc=1, got $devin_undetected_rc: $devin_undetected_out"
if grep -q '^agent rename ' "$TMP/herdr.log"; then fail "undetected Devin was renamed"; fi
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "undetected Devin leaked its pane"
arb status --job arb-devin-undetected --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["quota_pool_records"] == [], d
'
arb status --job arb-devin --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert len(d["quota_pool_records"]) == 1 and d["quota_pool_records"][0]["job_id"] == "arb-devin", d
'
echo "PASS task577 undetected Devin closes pane and releases only its arbiter record"

# #606 AC3: a shell that never frees the foreground inside the window fails
# closed exactly like any other start failure after the record exists — pane
# closed, this job's quota record released (release event written), and no
# brief delivered. Dropping the release turns this red.
rm -f "$TMP/herdr.log"
set +e
shell_arb_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO=shell-never-ready spawn_base opus --job arb-shell-busy --t T2 2>&1)"
shell_arb_rc=$?
set -e
[[ "$shell_arb_rc" -eq 1 ]] ||
  fail "arbiter-backed never-ready shell expected rc=1, got $shell_arb_rc: $shell_arb_out"
grep -q 'agent start failed: shell not ready within the 30000ms window' <<<"$shell_arb_out" ||
  fail "arbiter-backed never-ready shell lost its diagnostic: $shell_arb_out"
grep -q 'arbiter quota-pool record released after spawn failure: claude job=arb-shell-busy' <<<"$shell_arb_out" ||
  fail "arbiter-backed never-ready shell did not release its quota record: $shell_arb_out"
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "arbiter-backed never-ready shell leaked its pane"
if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "arbiter-backed never-ready shell delivered a brief"; fi
arb status --job arb-shell-busy --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["quota_pool_records"] == [], d
'
python3 - "$ARBITER_INBOX_ROOT/arb-shell-busy/events" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
assert any(event.get("kind") == "quota_pool.release" for event in events), events
PY
echo "PASS task606 never-ready shell closes pane and releases its arbiter record"

# Task 281: the new devin model variants share scopefuel's single `devin` pool
# — the gate call uses the only devin spelling installed scopefuel accepts
# (devin-swe2), while the spawn receipt keeps the actual launch profile.
rm -f "$TMP/herdr.log" "$TMP/scopefuel.log"
ds41_admit_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-ds41 --job arb-devin-ds41 --t T1 2>&1)"
grep -qx 'profile=devin-swe2 pool=devin used_pct=0 class=spend' <<<"$ds41_admit_out"
grep -q 'quota_record=devin/quota_pool' <<<"$ds41_admit_out"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == 'devin-swe2' ]]
arb status --job arb-devin-ds41 --json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["quota_pool_records"]; assert len(r)==1 and r[0]["pool"]=="devin" and r[0]["profile"]=="devin-swe2", d'
python3 - "$ARBITER_INBOX_ROOT/arb-devin-ds41/events" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
spawned = next(event for event in events if event["kind"] == "job.spawned")
assert spawned["payload"]["profile"] == "devin-ds41", spawned
PY
echo "PASS devin-ds41 shares the devin-swe2 gate spelling and devin quota pool"

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

# ---------------------------------------------------------------------------
# task483: --operator-request/--requested-by are forwarded verbatim to
# `scopefuel gate`. wrk owns no REF-format or profile-applicability judgement —
# the fixture mirrors the installed gate's fail-closed refusal vocabulary, and
# wrk must propagate both the refusal text and the exit code. The four gate
# fields (escalation_override/operator_request_ref/requested_by/ref_resolution)
# persist into the spawn log (gate stdout reprint) and the arbiter
# quota_pool.record event, byte-identical to what the gate emitted.
# ---------------------------------------------------------------------------

grep -q -- '--operator-request' <<<"$spawn_help_out" ||
  fail "spawn --help lost --operator-request"
grep -q -- '--requested-by' <<<"$spawn_help_out" ||
  fail "spawn --help lost --requested-by"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m fable -p "$PROMPT" -w w -l fixture --t T1 --operator-request
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m fable -p "$PROMPT" -w w -l fixture --t T1 --requested-by

# Deny-path runs take a private fixture log and a missing hosts.toml: the
# detached completion sentinels left by earlier registered spawns keep
# appending first-probe calls to the shared $TMP/herdr.log, and a configured
# machine's router runs `herdr agent list` for local measurement before the
# gate — both would fake "denied spawn reached Herdr". With no hosts.toml the
# router short-circuits to the local spawn path, so "gate denied before ANY
# Herdr call" stays provable.
spawn_deny() {
  local log="$1" model="$2"; shift 2
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="${TEST_ARBITER_BIN:-$TMP/absent-arbiter}" \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml" \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$log" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
    "$WRK" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture "$@"
}

# AC-1: with no REF the consult_only profile is still gate-denied — the
# fixture mirrors the installed scopefuel, which refuses a bare fable
# unconditionally (task #625). The denial reason must reach the caller
# verbatim.
set +e
esc_denied_out="$(spawn_deny "$TMP/herdr-esc-denied.log" fable --job esc-denied --t T1 2>&1)"
esc_denied_rc=$?
set -e
[[ "$esc_denied_rc" -eq 3 ]] ||
  fail "fable without --operator-request must stay gate-denied (rc=$esc_denied_rc): $esc_denied_out"
grep -q 'consult_only' <<<"$esc_denied_out" ||
  fail "fable denial lost the gate's own reason: $esc_denied_out"
[[ ! -e "$TMP/herdr-esc-denied.log" ]] ||
  fail "a gate-denied consult_only spawn reached Herdr"
echo "PASS AC-1 fable-no-ref-still-denied rc=$esc_denied_rc"

# AC-2/AC-6/AC-5/AC-7: a valid REF reaches the gate unchanged, the four fields
# ride gate stdout into the spawn log, and arbiter's quota_pool.record event
# persists them byte-identically.
export TEST_ARBITER_BIN="$ARBITER"
: >"$TMP/scopefuel.log"
rm -f "$TMP/herdr.log"
esc_ok_out="$(spawn_base fable --job esc-ok --t T1 \
  --operator-request hk:doc/research/2026-09-20/example-key --requested-by operator 2>&1)"
grep -q '^OK pane=' <<<"$esc_ok_out" ||
  fail "fable + valid operator request did not spawn: $esc_ok_out"
grep -q -- '--operator-request hk:doc/research/2026-09-20/example-key' "$TMP/scopefuel.log" ||
  fail "gate argv log lost --operator-request: $(cat "$TMP/scopefuel.log")"
grep -q -- '--requested-by operator' "$TMP/scopefuel.log" ||
  fail "gate argv log lost --requested-by: $(cat "$TMP/scopefuel.log")"
# fable's request satisfies consult_only — it overrode no "alternatives
# available" denial, so the gate emits escalation_override=false (task #625).
for field in escalation_override=false \
  operator_request_ref=hk:doc/research/2026-09-20/example-key \
  requested_by=operator ref_resolution=unverified; do
  grep -q "$field" <<<"$esc_ok_out" ||
    fail "spawn log lost gate field $field: $esc_ok_out"
done
gate_ref_resolution="$(tr ' ' '\n' <<<"$esc_ok_out" | sed -n 's/^ref_resolution=//p' | head -1)"
[[ -n "$gate_ref_resolution" ]] || fail "gate stdout had no ref_resolution token: $esc_ok_out"
python3 - "$ARBITER_INBOX_ROOT/esc-ok/events" "$gate_ref_resolution" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(e for e in events if e["kind"] == "quota_pool.record")
p = record["payload"]
assert p["escalation_override"] == "false", p
assert p["operator_request_ref"] == "hk:doc/research/2026-09-20/example-key", p
assert p["requested_by"] == "operator", p
# AC-7: byte-identical to the token the gate itself printed, not a normalized
# or re-derived value.
assert p["ref_resolution"] == sys.argv[2], p
PY
echo "PASS AC-2/5/6/7 operator-request-passed-fields-persisted: $esc_ok_out"

# hk:task/<int> is the gate's second accepted REF shape.
: >"$TMP/scopefuel.log"
esc_task_out="$(spawn_base fable --job esc-task --t T1 \
  --operator-request hk:task/483 2>&1)"
grep -q '^OK pane=' <<<"$esc_task_out" ||
  fail "fable + hk:task ref did not spawn: $esc_task_out"
grep -q 'operator_request_ref=hk:task/483' <<<"$esc_task_out" ||
  fail "spawn log lost the hk:task ref: $esc_task_out"
grep -q 'requested_by=unknown' <<<"$esc_task_out" ||
  fail "gate's default requested_by=unknown was not preserved: $esc_task_out"
echo "PASS hk-task-ref-accepted-default-requested-by"

# AC-3: a free-text REF is the gate's refusal, not wrk's — rc and reason must
# both propagate.
set +e
esc_badref_out="$(spawn_deny "$TMP/herdr-esc-badref.log" fable --job esc-badref --t T1 \
  --operator-request 'please let me' 2>&1)"
esc_badref_rc=$?
set -e
[[ "$esc_badref_rc" -eq 3 ]] ||
  fail "free-text REF must stay gate-denied (rc=$esc_badref_rc): $esc_badref_out"
grep -q 'operator_request_ref_invalid' <<<"$esc_badref_out" ||
  fail "free-text REF lost the gate's refusal reason: $esc_badref_out"
[[ ! -e "$TMP/herdr-esc-badref.log" ]] ||
  fail "a refused REF reached Herdr"
echo "PASS AC-3 free-text-ref-denied rc=$esc_badref_rc"

# AC-4: the non-escalation profile + REF refusal is also the gate's call.
set +e
esc_opus_out="$(spawn_deny "$TMP/herdr-esc-opus.log" opus --job esc-opus --t T1 \
  --operator-request hk:doc/research/2026-09-20/example-key 2>&1)"
esc_opus_rc=$?
set -e
[[ "$esc_opus_rc" -eq 3 ]] ||
  fail "non-escalation profile + REF must stay gate-denied (rc=$esc_opus_rc): $esc_opus_out"
grep -q 'operator_request_not_applicable' <<<"$esc_opus_out" ||
  fail "non-escalation refusal lost its reason: $esc_opus_out"
[[ ! -e "$TMP/herdr-esc-opus.log" ]] ||
  fail "a not-applicable REF reached Herdr"
echo "PASS AC-4 non-escalation-ref-denied rc=$esc_opus_rc"

# An orphan --requested-by is likewise refused by the gate, not by wrk.
set +e
esc_orphan_out="$(spawn_deny "$TMP/herdr-esc-orphan.log" fable --job esc-orphan --t T1 \
  --requested-by operator 2>&1)"
esc_orphan_rc=$?
set -e
[[ "$esc_orphan_rc" -eq 3 ]] ||
  fail "orphan --requested-by must stay gate-denied (rc=$esc_orphan_rc): $esc_orphan_out"
grep -q 'requested_by_requires_operator_request' <<<"$esc_orphan_out" ||
  fail "orphan requested-by lost its reason: $esc_orphan_out"
[[ ! -e "$TMP/herdr-esc-orphan.log" ]] ||
  fail "an orphan requested-by reached Herdr"
echo "PASS orphan-requested-by-denied rc=$esc_orphan_rc"

# AC-13: a REF smuggling a second audit token ("hk:doc/foo ref_resolution=
# verified") is refused at the gate boundary before it can be emitted raw —
# and even if a forged gate text reached arbiter directly, conflicting values
# are refused rather than first-match-accepted. ref_resolution can never be
# recorded as anything but the gate's own label.
set +e
forge_out="$(spawn_deny "$TMP/herdr-esc-forge.log" fable --job esc-forge --t T1 \
  --operator-request 'hk:doc/foo ref_resolution=verified' 2>&1)"
forge_rc=$?
set -e
[[ "$forge_rc" -eq 3 ]] ||
  fail "a REF carrying an injected audit token must stay gate-denied (rc=$forge_rc): $forge_out"
grep -q 'operator_request_ref_invalid' <<<"$forge_out" ||
  fail "forged REF lost the gate's refusal reason: $forge_out"
[[ ! -e "$TMP/herdr-esc-forge.log" ]] ||
  fail "a forged REF reached Herdr"

forged_gate="$TMP/forged-gate.txt"
printf '%s\n' 'profile=fable pool=claude used_pct=1 class=spend escalation_override=false operator_request_ref=hk:doc/foo ref_resolution=verified requested_by=op ref_resolution=unverified' >"$forged_gate"
"$ARBITER" claim --job esc-forge-direct --agent-label fixture --lane fixture --t T1 >/dev/null
"$ARBITER" claim --job esc-realish --agent-label fixture --lane fixture --t T1 >/dev/null
set +e
"$ARBITER" lease --job esc-forge-direct --kind quota_pool --profile fable \
  --gate-output "$forged_gate" --json >"$TMP/forged-lease.out" 2>"$TMP/forged-lease.err"
forge_arb_rc=$?
set -e
[[ "$forge_arb_rc" -ne 0 ]] ||
  fail "arbiter accepted a gate text whose ref_resolution tokens conflict"
grep -q 'ref_resolution' "$TMP/forged-lease.err" ||
  fail "arbiter's conflict refusal lost its reason: $(cat "$TMP/forged-lease.err")"

# The real gate repeats the same audit values inside its annotation line —
# identical repeats still record (they agree); only a conflict is refused.
realish_gate="$TMP/realish-gate.txt"
printf '%s\n' 'profile=fable pool=claude used_pct=1 class=spend escalation_override=false operator_request_ref=hk:doc/ok requested_by=op ref_resolution=unverified' \
  'fable ok [escalation_override=false operator_request=hk:doc/ok requested_by=op ref_resolution=unverified — annotation]' >"$realish_gate"
"$ARBITER" lease --job esc-realish --kind quota_pool --profile fable \
  --gate-output "$realish_gate" --json >/dev/null ||
  fail "arbiter refused a gate text whose repeated audit values agree"
python3 - "$ARBITER_INBOX_ROOT" <<'PY'
import json, pathlib, sys
forged_ok = seen_realish = False
for path in pathlib.Path(sys.argv[1]).rglob("*.json"):
    event = json.loads(path.read_text())
    if event.get("kind") != "quota_pool.record":
        continue
    value = event["payload"].get("ref_resolution")
    assert value in (None, "unverified"), event
    if event["job_id"] == "esc-forge-direct":
        forged_ok = True
    if event["job_id"] == "esc-realish":
        assert value == "unverified", event
        seen_realish = True
assert not forged_ok, "the refused forged lease still wrote a record"
assert seen_realish, "the agreeing-repeat gate text did not record"
PY
echo "PASS AC-13 forged-ref-cannot-promote-audit-label rc=$forge_rc arb_rc=$forge_arb_rc"

# AC-14: a value-taking option must not swallow the next option token — the
# missing-value error keeps rc=2 and its message at every consume site, and
# the mangled pair never reaches the gate or downstream argv.
: >"$TMP/scopefuel.log"
set +e
swallow_out="$(spawn_deny "$TMP/herdr-esc-swallow.log" fable --job esc-swallow --t T1 \
  --operator-request --requested-by operator 2>&1)"
swallow_rc=$?
set -e
[[ "$swallow_rc" -eq 2 ]] ||
  fail "--operator-request --requested-by must be a missing-value error (rc=$swallow_rc): $swallow_out"
grep -q 'requires a value' <<<"$swallow_out" ||
  fail "missing-value error lost its message: $swallow_out"
[[ ! -e "$TMP/herdr-esc-swallow.log" ]] ||
  fail "a swallowed option token reached Herdr"
! grep -q 'operator-request' "$TMP/scopefuel.log" ||
  fail "a swallowed option token reached the gate: $(cat "$TMP/scopefuel.log")"

# Negative control: a leading-dash value that is not a wrk option still
# parses — "-operator" is a legitimate requested_by and must reach the gate
# verbatim.
: >"$TMP/scopefuel.log"
dashval_out="$(spawn_base fable --job esc-dashval --t T1 \
  --operator-request hk:doc/x --requested-by -operator 2>&1)"
grep -q '^OK pane=' <<<"$dashval_out" ||
  fail "a leading-dash requested_by value was rejected: $dashval_out"
grep -q 'requested_by=-operator' <<<"$dashval_out" ||
  fail "gate did not receive requested_by=-operator verbatim: $dashval_out"
echo "PASS AC-14 option-token-value-not-swallowed rc=$swallow_rc"

# Ordinary spawns carry no operator-request argv and no audit fields — the
# pass-through must be strictly opt-in.
: >"$TMP/scopefuel.log"
plain_out="$(spawn_base codex-terra --job esc-plain --t T1 2>&1)"
grep -q '^OK pane=' <<<"$plain_out"
if grep -q -- 'operator-request\|requested-by' "$TMP/scopefuel.log"; then
  fail "a plain spawn leaked operator-request argv: $(cat "$TMP/scopefuel.log")"
fi
python3 - "$ARBITER_INBOX_ROOT/esc-plain/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(e for e in events if e["kind"] == "quota_pool.record")
p = record["payload"]
for key in ("escalation_override", "operator_request_ref", "requested_by", "ref_resolution"):
    assert key not in p, p
PY
echo "PASS plain-spawn-carries-no-operator-request"
unset TEST_ARBITER_BIN

# ---------------------------------------------------------------------------
# task #527: --purpose is forwarded verbatim to `scopefuel gate`, the astra
# counsel path defaults it to `architect`, and a role denial (gate rc 5 → wrk
# exit 77) is caller-visibly distinct from a quota denial (rc 3) AND from the
# pre-existing hub quota-policy denial (wrk exit 5).
# ---------------------------------------------------------------------------

grep -q -- '--purpose' <<<"$spawn_help_out" ||
  fail "spawn --help lost --purpose"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1 --purpose

# The architect counsel path injects --purpose architect on its own: a plain
# `-m codex-astra` spawn must reach the gate with the purpose attached.
: >"$TMP/scopefuel.log"
rm -f "$TMP/herdr.log"
astra_ok_out="$(spawn_base codex-astra --job astra-purpose --t T1 2>&1)"
grep -q '^OK pane=' <<<"$astra_ok_out" ||
  fail "codex-astra counsel spawn did not pass the gate: $astra_ok_out"
grep -q -- '--purpose architect' "$TMP/scopefuel.log" ||
  fail "gate argv log lost --purpose architect: $(cat "$TMP/scopefuel.log")"
grep -q 'model_reasoning_effort=xhigh' "$TMP/herdr.log" ||
  fail "codex-astra default effort drifted from xhigh: $(cat "$TMP/herdr.log")"
echo "PASS 527-astra-counsel-spawn-passes-purpose-architect"

# An explicit allowed purpose still wins over the architect default.
: >"$TMP/scopefuel.log"
rm -f "$TMP/herdr.log"
astra_dir_out="$(spawn_base codex-astra --job astra-purpose-director --t T1 --purpose director 2>&1)"
grep -q '^OK pane=' <<<"$astra_dir_out" ||
  fail "codex-astra --purpose director did not spawn: $astra_dir_out"
grep -q -- '--purpose director' "$TMP/scopefuel.log" ||
  fail "explicit --purpose director was overridden: $(cat "$TMP/scopefuel.log")"
echo "PASS 527-explicit-purpose-overrides-architect-default"

# Role denial: a disallowed purpose is refused by the gate with rc 5, which
# wrk remaps to exit 77 — exit 5 is already quota_hub_policy_gate's
# hub-quota-policy denial, so sharing it would let a caller misread a role
# denial as a quota stop.
set +e
role_denied_out="$(spawn_deny "$TMP/herdr-astra-role.log" codex-astra --job astra-role --t T1 \
  --purpose worker 2>&1)"
role_denied_rc=$?
set -e
[[ "$role_denied_rc" -eq 77 ]] ||
  fail "disallowed purpose must role-deny with wrk rc=77 (rc=$role_denied_rc): $role_denied_out"
grep -q 'role_restricted' <<<"$role_denied_out" ||
  fail "role denial lost the gate's reason: $role_denied_out"
grep -q 'role-denied' <<<"$role_denied_out" ||
  fail "wrk did not label the role denial: $role_denied_out"
[[ ! -e "$TMP/herdr-astra-role.log" ]] ||
  fail "a role-denied astra spawn reached Herdr"
echo "PASS 527-astra-disallowed-purpose-role-denied rc=$role_denied_rc"

# Quota denial: the same profile with an allowed purpose hits the quota path
# and is refused with rc 3 — exactly distinct from the role denial above.
set +e
quota_denied_out="$(WRK_GATE_MODE=3 \
  spawn_deny "$TMP/herdr-astra-quota.log" codex-astra --job astra-quota --t T1 2>&1)"
quota_denied_rc=$?
set -e
[[ "$quota_denied_rc" -eq 3 ]] ||
  fail "quota refusal must keep rc=3 (rc=$quota_denied_rc): $quota_denied_out"
grep -q 'gate blocked' <<<"$quota_denied_out" ||
  fail "quota refusal lost its reason: $quota_denied_out"
if grep -q 'role_restricted\|role-denied' <<<"$quota_denied_out"; then
  fail "quota refusal was mislabeled as a role denial: $quota_denied_out"
fi
[[ "$role_denied_rc" -ne "$quota_denied_rc" ]] ||
  fail "role and quota denials share an exit code — callers cannot tell them apart"
# …and neither may collide with the pre-existing hub quota-policy denial (5).
[[ "$role_denied_rc" -ne 5 && "$quota_denied_rc" -ne 5 ]] ||
  fail "a denial rc collided with hub quota-policy denial (exit 5)"
[[ ! -e "$TMP/herdr-astra-quota.log" ]] ||
  fail "a quota-denied astra spawn reached Herdr"
echo "PASS 527-astra-quota-denial-distinct rc=$quota_denied_rc"

# --purpose is audit metadata for non-astra profiles: it is forwarded but the
# spawn outcome is unchanged.
: >"$TMP/scopefuel.log"
plain_purpose_out="$(spawn_base codex-terra --job plain-purpose --t T1 --purpose builder 2>&1)"
grep -q '^OK pane=' <<<"$plain_purpose_out" ||
  fail "non-astra spawn with --purpose was refused: $plain_purpose_out"
grep -q -- '--purpose builder' "$TMP/scopefuel.log" ||
  fail "gate argv log lost --purpose for non-astra: $(cat "$TMP/scopefuel.log")"
echo "PASS 527-non-astra-purpose-is-audit-only"

# Builder contract: the real arbiter claim artifact remains an envelope while
# wrk's upward-facing events stay flat. owner_lane is always the builder's own
# lane; parent_lane is recorded as information, while panewire resolves parent
# routing from lanes.json. `captain` remains a deprecated input alias only.
export TEST_ARBITER_BIN="$ARBITER"
BUILDER_REPORT="$TMP/builder-report.md"
printf 'builder report terminal line\n' >"$BUILDER_REPORT"
: >"$TMP/herdr.log"
builder_opus_out="$(spawn_base builder-opus --role builder --lane builder-lane --parent parent-lane --job builder-opus-job --t T1 2>&1)"
grep -q 'model=builder-opus' <<<"$builder_opus_out"
grep -q -- '--model opus' "$TMP/herdr.log"
grep -q -- '--effort high' "$TMP/herdr.log"
python3 - "$ARBITER_INBOX_ROOT/builder-opus-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert set(event) == {"created_at", "job_id", "kind", "payload", "seq"}, event
assert event["kind"] == "job.claim", event
assert event["payload"] == {
    "agent_label": "fixture", "owner_lane": "builder-lane", "parent_lane": "parent-lane",
    "role": "builder", "t_level": "T1",
}, event
PY
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" escalate builder-opus-job --question 'need parent decision' >/dev/null
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" joined builder-opus-job --pr https://example.invalid/pr/1 --head deadbeef --report "$BUILDER_REPORT" >/dev/null
python3 - "$ARBITER_INBOX_ROOT/builder-opus-job/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
escalate = next(e for e in events if e["kind"] == "job.escalate")
joined = next(e for e in events if e["kind"] == "job.joined")
assert escalate["owner_lane"] == joined["owner_lane"] == "builder-lane", events
assert escalate["parent_lane"] == joined["parent_lane"] == "parent-lane", events
assert escalate["reason"] == "builder escalation" and escalate["question"] == "need parent decision", escalate
assert joined["reason"] == "builder joined PR" and joined["pr"].endswith("/1") and joined["head"] == "deadbeef", joined
for event in (escalate, joined):
    assert {"pane_id", "report_path", "report_last_line"} <= set(event), event
assert "payload" not in escalate and "payload" not in joined, events
PY
echo "PASS role-builder-spawn-claim-payload-parent"

# The legacy role must hit the same real spawn/claim path, emit one warning,
# and persist only canonical builder in its claim artifact.
: >"$TMP/herdr.log"
captain_alias_err="$TMP/captain-alias.err"
captain_alias_out="$(spawn_base captain-opus --role captain --lane legacy-builder-lane --parent parent-lane --job captain-alias-job --t T1 2>"$captain_alias_err")"
grep -qx 'wrk: warning: --role captain is deprecated; use --role builder' "$captain_alias_err" ||
  fail "legacy captain role must emit its deprecation warning on stderr: $(<"$captain_alias_err")"
[[ "$(grep -c 'deprecated; use --role builder' "$captain_alias_err")" -eq 1 ]] ||
  fail "legacy captain role must emit exactly one deprecation warning: $(<"$captain_alias_err")"
grep -q 'model=captain-opus' <<<"$captain_alias_out"
python3 - "$ARBITER_INBOX_ROOT/captain-alias-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
echo "PASS role-captain-alias-normalizes-to-builder"

# Every builder profile spelling, including both legacy captain spellings,
# must traverse the actual spawn/claim path under canonical --role builder.
builder_profile_index=0
for builder_profile in builder-opus captain-opus builder-sol captain-sol; do
  builder_profile_index=$((builder_profile_index + 1))
  spawn_base "$builder_profile" --role builder --lane "builder-profile-$builder_profile_index" \
    --parent parent-lane --job "builder-profile-$builder_profile_index" --t T1 >/dev/null
done
python3 - "$ARBITER_INBOX_ROOT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for index in range(1, 5):
    event = json.loads((root / f"builder-profile-{index}" / "events" / "00001-job.claim.json").read_text())
    assert event["payload"]["role"] == "builder", event
PY
echo "PASS builder-accepts-canonical-and-legacy-profile-aliases"

# task #526: --role builder rejects every astra spelling before claim/gate/tab,
# and the refusal names the operator decision. The captain role alias must not
# smuggle captain-astra past the same gate.
builder_reject_astra() {
  local model="$1" tag="$2"; shift 2
  local job="builder-astra-reject-${model}-${tag}" output rc
  set +e
  output="$(spawn_base "$model" "$@" --job "$job" --t T1 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 2 ]] || fail "--role builder must reject $model (rc=$rc): $output"
  grep -q "rejects astra profile '$model'" <<<"$output" ||
    fail "astra rejection must name the profile: $output"
  grep -q 'hk:doc decision/2026-09-21/astra-allowed-purposes-approved' <<<"$output" ||
    fail "astra rejection must cite the operator decision: $output"
  [[ ! -e "$ARBITER_INBOX_ROOT/$job/events/00001-job.claim.json" ]] ||
    fail "rejected astra builder must not claim $job"
}
builder_reject_astra builder-astra b --role builder --lane astra-b-lane --parent parent-lane
builder_reject_astra codex-astra c --role builder --lane astra-c-lane --parent parent-lane
builder_reject_astra captain-astra k --role builder --lane astra-k-lane --parent parent-lane
builder_reject_astra captain-astra kalias --role captain --lane astra-k-alias-lane --parent parent-lane
echo "PASS role-builder-rejects-astra-spellings"

role_must_fail() {
  local rejected_role="$1" job="$2" output rc
  set +e
  output="$(spawn_base codex-terra --role "$rejected_role" --job "$job" --t T1 2>&1)"
  rc=$?
  set -e
  python3 - "$rc" "$rejected_role" "$output" <<'PY'
import sys
assert int(sys.argv[1]) == 2, "unknown --role %r must be a usage error, rc=%s output=%s" % (sys.argv[2], sys.argv[1], sys.argv[3])
PY
  grep -Fqx -- 'wrk: --role accepts only worker or builder (legacy alias: captain)' <<<"$output" ||
    fail "unknown --role '$rejected_role' must hit role validation: $output"
  [[ ! -e "$ARBITER_INBOX_ROOT/$job/events/00001-job.claim.json" ]] || fail "unknown role must not claim $job"
}
role_must_fail admiral role-unknown-admiral
role_must_fail tester role-unknown-tester

role_must_require_value() {
  local job="$1" output rc
  set +e
  output="$(spawn_base codex-terra --role '' --job "$job" --t T1 2>&1)"
  rc=$?
  set -e
  python3 - "$rc" "$output" <<'PY'
import sys
assert int(sys.argv[1]) == 2, "empty --role value must be a usage error, rc=%s output=%s" % (sys.argv[1], sys.argv[2])
PY
  grep -Fqx -- 'wrk: --role requires a value' <<<"$output" ||
    fail "empty --role value must hit the value guard: $output"
  [[ ! -e "$ARBITER_INBOX_ROOT/$job/events/00001-job.claim.json" ]] || fail "empty role must not claim $job"
}
role_must_require_value role-unknown-empty
echo "PASS role-unknown-values-are-usage-errors"

expect_exit 2 spawn_base builder-opus --role builder --parent parent-lane --job builder-missing-lane
expect_exit 2 spawn_base builder-opus --role builder --lane builder-lane --job builder-missing-parent
expect_exit 2 spawn_base builder-opus --role builder --lane builder-lane --parent parent-lane --owner owner-lane --job builder-owner-conflict
expect_exit 2 spawn_base builder-opus --role builder --lane builder-lane --parent builder-lane --job builder-self-parent
expect_exit 2 spawn_base builder-opus --role builder --lane director-9 --parent parent-lane --job builder-director-lane
expect_exit 2 spawn_base builder-opus --role builder --lane admiral-9 --parent parent-lane --job builder-admiral-lane
expect_exit 2 spawn_base codex-terra --role worker --lane worker-lane --parent parent-lane --job worker-hierarchy-regression
echo "PASS builder-parent-and-director-lane-guards"

for builder_profile in builder-opus captain-opus builder-sol captain-sol builder-devin builder-grok builder-kimi; do
  expect_exit 2 spawn_base "$builder_profile" --role worker --job "worker-reject-${builder_profile}"
done
echo "PASS worker-rejects-all-builder-profile-aliases"

# task #526: the removed astra builder spellings die on the tombstone under the
# default role too — they are gone from ALL_PROFILES and resolve_profile, so no
# role can spawn them.
for removed_profile in builder-astra captain-astra; do
  set +e
  removed_out="$(spawn_base "$removed_profile" --job "removed-${removed_profile}" --t T1 2>&1)"
  removed_rc=$?
  set -e
  [[ "$removed_rc" -eq 2 ]] || fail "removed profile $removed_profile must fail (rc=$removed_rc): $removed_out"
  grep -q "profile '$removed_profile' was removed" <<<"$removed_out" ||
    fail "removed profile $removed_profile must hit the tombstone: $removed_out"
  grep -q 'hk:doc decision/2026-09-21/astra-allowed-purposes-approved' <<<"$removed_out" ||
    fail "removed profile $removed_profile tombstone must cite the decision: $removed_out"
done
expect_exit 2 spawn_base gpt-6-astra --job removed-gpt-6-astra --t T1
echo "PASS removed-astra-builder-spellings-hit-tombstone"

# task #526 AC4: the three builder surfaces must name the same profile set —
# builder/SKILL.md, the `wrk spawn --help` --role paragraph and the --role
# builder accept list. Fixing only one side must turn this RED (that read-order
# dependence is what #505 removed). The literal accept-line pin also makes
# re-adding an astra spelling to the list alone go RED.
accept_line="$(grep -nF 'builder-opus|builder-sol|builder-devin|builder-grok|builder-kimi|devin-swe2|grok|grok-hi|kimi-k3|captain-opus|captain-sol) ;;' "$ROOT/bin/wrk")"
[[ -n "$accept_line" ]] || fail "--role builder accept list drifted or was not found"
[[ "$(wc -l <<<"$accept_line" | tr -d ' ')" == 1 ]] ||
  fail "accept-list pattern is not unique: $accept_line"
# Token pattern covers the whole accept set: builder-*/captain-* spellings plus
# the pilot worker spellings. Bare 'grok' is not extracted (it also matches
# inside builder-grok); grok-hi presence covers it, and the literal accept-line
# pin above guards the list itself.
builder_tokens() { grep -oE '(builder|captain)-[a-z]+|devin-swe2|grok-hi|kimi-k3' | grep -vx 'builder-level' | sort -u; }
accept_set="$(builder_tokens <<<"$accept_line")"
help_block="$(sed -n '/--role worker|builder/,/--lane NAME/p' "$ROOT/bin/wrk")"
help_set="$(builder_tokens <<<"$help_block")"
skill_set="$(builder_tokens <"$ROOT/builder/SKILL.md")"
[[ "$accept_set" == "$help_set" ]] ||
  fail "builder profile set drift (accept vs help): $(diff <(echo "$accept_set") <(echo "$help_set"))"
[[ "$accept_set" == "$skill_set" ]] ||
  fail "builder profile set drift (accept vs SKILL.md): $(diff <(echo "$accept_set") <(echo "$skill_set"))"
if grep -iq 'astra' <<<"$help_block"; then fail "--role help paragraph still names astra"; fi
if grep -iq 'astra' "$ROOT/builder/SKILL.md"; then fail "builder/SKILL.md still names astra"; fi
echo "PASS builder-profile-set-three-source-consistency"

# A legacy/canonical role pair must not create two role-distinct claims for the
# same job: the second real spawn remains an active duplicate and the first
# artifact is canonical builder.
spawn_base builder-opus --role builder --lane collision-lane --parent parent-lane --job role-alias-collision --t T1 >/dev/null
set +e
collision_out="$(spawn_base captain-opus --role captain --lane collision-lane --parent parent-lane --job role-alias-collision --t T1 2>&1)"
collision_rc=$?
set -e
[[ "$collision_rc" -ne 0 ]] || fail "captain alias must not create a second claim for builder's job"
grep -q 'active arbiter job duplicate' <<<"$collision_out" || fail "role alias collision did not fail as an active duplicate: $collision_out"
python3 - "$ARBITER_INBOX_ROOT/role-alias-collision/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
PY
echo "PASS role-builder-captain-alias-collision"

# Reclaim must replace completion metadata, not retain the first claim. First
# reclaim a worker as a builder, then reclaim again under a different parent.
arb claim --job builder-reclaim-job --lane worker-lane --agent-label worker-label --t T1 >/dev/null
arb lease --job builder-reclaim-job --resource builder-reclaim-resource --kind path >/dev/null
arb release --job builder-reclaim-job --resource builder-reclaim-resource --kind path --force >/dev/null
arb claim --job builder-reclaim-job --lane builder-old-lane --agent-label builder-old-label --t T1 \
  --role builder --parent-lane parent-old --reclaim-released >/dev/null
arb event --job builder-reclaim-job --kind job.spawned \
  --payload-json '{"owner_lane":"builder-old-lane","label":"builder-old-label","pane_id":"w1:p1"}' >/dev/null
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" escalate builder-reclaim-job --question 'first reclaim is builder' >/dev/null
arb lease --job builder-reclaim-job --resource builder-reclaim-resource-2 --kind path >/dev/null
arb release --job builder-reclaim-job --resource builder-reclaim-resource-2 --kind path --force >/dev/null
arb claim --job builder-reclaim-job --lane builder-new-lane --agent-label builder-new-label --t T1 \
  --role builder --parent-lane parent-new --reclaim-released >/dev/null
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" joined builder-reclaim-job --pr https://example.invalid/pr/2 --head feedface --report "$BUILDER_REPORT" >/dev/null
python3 - "$ARBITER_INBOX_ROOT/builder-reclaim-job/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
escalate = next(e for e in events if e["kind"] == "job.escalate")
joined = next(e for e in events if e["kind"] == "job.joined")
assert escalate["owner_lane"] == "builder-old-lane", escalate
assert joined["owner_lane"] == "builder-new-lane", joined
assert joined["parent_lane"] == "parent-new", joined
PY
: >"$TMP/herdr.log"
builder_sol_out="$(spawn_base builder-sol --role builder --lane builder-sol-lane --parent parent-lane --job builder-sol-job --t T1 2>&1)"
grep -q 'model=builder-sol' <<<"$builder_sol_out"
grep -q -- '-m gpt-6-sol' "$TMP/herdr.log"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "codex-max" ]]
# task #526 AC2: the counsel path must not regress — `wrk spawn -m codex-astra`
# under the default role (the ARCHITECT.md spawn shape, no --role) still
# resolves to gpt-6-astra and still gates as the codex-astra spelling so the
# scopefuel gate remains the single purpose check.
: >"$TMP/herdr.log"
# #527 + #593 combined. The catalog marks codex-astra consult_only and the gate
# role-gates it by declared purpose. These are two spellings of one restriction,
# and requiring both would break the approved counsel path: a bare
# `-m codex-astra` defaults PURPOSE=architect, the gate admits it, and the
# catalog must admit it too. The purpose reaches BOTH — wrk forwards it verbatim
# and scopefuel decides, applying the rule to astra only.
codex_astra_out="$(spawn_base codex-astra --job codex-astra-counsel-job --t T0 2>&1)"
grep -q '^OK pane=' <<<"$codex_astra_out" ||
  fail "the architect counsel spawn must proceed (purpose satisfies consult_only): $codex_astra_out"
grep -q -- '--purpose architect' "$TMP/scopefuel.log" ||
  fail "gate argv lost --purpose architect: $(cat "$TMP/scopefuel.log")"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "codex-astra" ]]
echo "PASS 593-astra-counsel-purpose-satisfies-consult-only"

# A purpose outside #527's list is refused, and the ROLE denial speaks first:
# gate exit 5 surfaces as wrk exit 77, which must not be flattened into the
# catalog refusal's exit 2 — a caller reading 2 would look for a quota problem.
expect_exit 77 spawn_base codex-astra --purpose builder --job astra-bad-purpose --t T0
echo "PASS 593-astra-disallowed-purpose-role-denied-77"

# 🔴 fable is NOT astra: #527 AC⑤ forbids relaxing its consult gate, so a
# purpose must never become a second key to it. Only --operator-request opens
# it. Since #625 the quota gate denies a request-less fable before the held-back
# catalog refusal can speak — the caller-visible reason is the gate's
# consult_only denial, and either way the spawn does not happen.
fable_purpose_out="$(spawn_base fable --purpose architect --job fable-purpose --t T1 2>&1 || true)"
grep -q 'consult_only' <<<"$fable_purpose_out" ||
  fail "a purpose must not satisfy fable's consult_only: $fable_purpose_out"
echo "PASS 593-fable-not-unlocked-by-purpose"

# Mutants: a worker-grade profile, missing parent, and a non-high Opus effort
# must all stop before gate/claim/tab creation.
expect_exit 2 spawn_base codex-terra --role builder --lane builder-lane --parent parent-lane --job builder-terra-mutant
expect_exit 2 spawn_base codex-luna --role builder --lane builder-lane --parent parent-lane --job builder-luna-mutant
expect_exit 2 spawn_base builder-opus --role builder --lane builder-lane --job builder-parent-mutant
expect_exit 2 spawn_base builder-opus --role builder --lane builder-lane --parent parent-lane --effort max --job builder-effort-mutant
if grep -q 'builder-.*-mutant' "$ARBITER_INBOX_ROOT"/*/events/* 2>/dev/null; then exit 1; fi

# Task 240 builder pilot (operator decision 2026-09-14
# codex-usage-and-builder-profiles §3 devin · §4 grok · §5 kimi): each pilot
# profile reuses its worker profile's kind/argv verbatim, gates as the
# scopefuel-known worker spelling, and rides the same claim path
# (role=builder, parent recorded).
: >"$TMP/herdr.log" "$TMP/scopefuel.log"
set +e
builder_devin_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base builder-devin --role builder --lane builder-devin-lane --parent parent-lane --job builder-devin-job --t T1 2>&1)"
builder_devin_rc=$?
set -e
[[ "$builder_devin_rc" -eq 0 ]] ||
  fail "builder-devin must be admitted under --role builder (rc=$builder_devin_rc): $builder_devin_out"
grep -q 'model=builder-devin' <<<"$builder_devin_out" ||
  fail "builder-devin spawn output lost its model: $builder_devin_out"
builder_devin_run="$(grep '^pane run ' "$TMP/herdr.log")"
[[ "$builder_devin_run" == 'pane run w:p1 devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' ]] ||
  fail "builder-devin must reuse the devin-swe2 worker argv verbatim: $builder_devin_run"
[[ " $builder_devin_run " != *' --effort '* ]] || fail "builder-devin must not gain an effort flag"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "devin-swe2" ]] ||
  fail "builder-devin must gate as the scopefuel-known devin-swe2 spelling"
python3 - "$ARBITER_INBOX_ROOT/builder-devin-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["owner_lane"] == "builder-devin-lane", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
expect_exit 2 spawn_base builder-devin --role builder --lane builder-devin-lane --parent parent-lane --effort high --job builder-devin-effort-mutant
echo "PASS builder-devin pilot profile reuses devin-swe2 kind/argv"

: >"$TMP/herdr.log" "$TMP/scopefuel.log"
set +e
builder_grok_out="$(spawn_base builder-grok --role builder --lane builder-grok-lane --parent parent-lane --job builder-grok-job --t T1 2>&1)"
builder_grok_rc=$?
set -e
[[ "$builder_grok_rc" -eq 0 ]] ||
  fail "builder-grok must be admitted under --role builder (rc=$builder_grok_rc): $builder_grok_out"
grep -q 'model=builder-grok' <<<"$builder_grok_out" ||
  fail "builder-grok spawn output lost its model: $builder_grok_out"
builder_grok_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_grok_start" == 'agent start fixture --kind grok --pane w:p1 --timeout 30000 -- --always-approve -m grok-4.7 --effort xhigh' ]] ||
  fail "builder-grok must reuse the grok worker argv at effort xhigh: $builder_grok_start"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "grok-hi" ]] ||
  fail "builder-grok must gate as the scopefuel-known grok-hi spelling"
python3 - "$ARBITER_INBOX_ROOT/builder-grok-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["owner_lane"] == "builder-grok-lane", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
echo "PASS builder-grok pilot profile reuses grok kind/argv at xhigh"

: >"$TMP/herdr.log" "$TMP/scopefuel.log"
set +e
builder_kimi_out="$(KIMI_CODE_HOME="$TMP/kimi-builder-home" spawn_base builder-kimi --role builder --lane builder-kimi-lane --parent parent-lane --job builder-kimi-job --t T1 2>&1)"
builder_kimi_rc=$?
set -e
[[ "$builder_kimi_rc" -eq 0 ]] ||
  fail "builder-kimi must be admitted under --role builder (rc=$builder_kimi_rc): $builder_kimi_out"
grep -q 'model=builder-kimi' <<<"$builder_kimi_out" ||
  fail "builder-kimi spawn output lost its model: $builder_kimi_out"
builder_kimi_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_kimi_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/k3' ]] ||
  fail "builder-kimi must reuse the kimi-k3 worker argv verbatim: $builder_kimi_start"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "kimi-k3" ]] ||
  fail "builder-kimi must gate as the scopefuel-known kimi-k3 spelling"
python3 - "$ARBITER_INBOX_ROOT/builder-kimi-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["owner_lane"] == "builder-kimi-lane", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
( KIMI_CODE_HOME="$TMP/kimi-builder-home" \
  expect_exit 2 spawn_base builder-kimi --role builder --lane builder-kimi-lane --parent parent-lane --effort high --job builder-kimi-effort-mutant )
echo "PASS builder-kimi pilot profile reuses kimi-k3 kind/argv"

# The worker spellings the decision names for the pilot are admissible as
# builders too, and keep their ordinary worker meaning.
for pilot_alias in grok grok-hi kimi-k3; do
  set +e
  pilot_alias_out="$(KIMI_CODE_HOME="$TMP/kimi-builder-home" spawn_base "$pilot_alias" --role builder --lane "pilot-${pilot_alias}-lane" --parent parent-lane --job "pilot-${pilot_alias}-job" --t T1 2>&1)"
  pilot_alias_rc=$?
  set -e
  [[ "$pilot_alias_rc" -eq 0 ]] ||
    fail "pilot worker spelling '$pilot_alias' must be admitted under --role builder: $pilot_alias_out"
  grep -q "model=$pilot_alias" <<<"$pilot_alias_out" ||
    fail "pilot worker spelling '$pilot_alias' spawn output lost its model: $pilot_alias_out"
  python3 - "$ARBITER_INBOX_ROOT/pilot-${pilot_alias}-job/events/00001-job.claim.json" "$pilot_alias" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["parent_lane"] == "parent-lane", event
assert event["payload"]["owner_lane"] == "pilot-%s-lane" % sys.argv[2], event
PY
done
echo "PASS builder-pilot-admits-worker-spellings"

# Profiles outside the allowlist are still refused before the gate, and the
# refusal enumerates the three pilot profiles by name plus the worker-only
# devin model variants (task 281).
for rejected in codex-terra codex-luna oc-solar4 devin-ds41; do
  set +e
  rejected_out="$(spawn_base "$rejected" --role builder --lane builder-lane --parent parent-lane --job "builder-reject-$rejected" --t T1 2>&1)"
  rejected_rc=$?
  set -e
  [[ "$rejected_rc" -eq 2 ]] ||
    fail "--role builder must still reject $rejected with exit 2, got $rejected_rc: $rejected_out"
  for named in builder-devin builder-grok builder-kimi devin-glm52 devin-swe17 devin-ds41; do
    grep -q "$named" <<<"$rejected_out" ||
      fail "the --role builder refusal must list $named: $rejected_out"
  done
done
echo "PASS builder-pilot-allowlist-rejects-outsiders-with-named-message"

# R19a keeps the historical captain payload as an inbox-consumer regression
# input, while the new builder claim must be the exact bytes emitted by the
# production arbiter writer (never a hand-maintained lookalike).
PANEVIRE_FIXTURE="$ROOT/tests/fixtures/panewire-r19a"
PANEVIRE_OUTPUT="$TMP/panewire-r19a-output"
"$PANEVIRE_FIXTURE/regen.sh" "$PANEVIRE_OUTPUT"
for fixture in "$PANEVIRE_FIXTURE"/*.json; do
  cmp "$fixture" "$PANEVIRE_OUTPUT/$(basename "$fixture")"
done
[[ "$(find "$PANEVIRE_OUTPUT" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" -eq 5 ]]
python3 - "$PANEVIRE_OUTPUT/00005-builder-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert set(event) == {"created_at", "job_id", "kind", "payload", "seq"}, event
assert event["payload"]["role"] == "builder", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
unset TEST_ARBITER_BIN
echo "PASS builder profiles, own-lane escalation/JOIN, reclaim metadata, fixture bytes, and fail-closed mutants"

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
assert set(event) == {"kind", "job_id", "owner_lane", "label", "pane_id", "host", "report_path", "report_last_line", "epoch", "report_sha256"}, event
assert event["kind"] == "job.completed" and event["job_id"] == sys.argv[2], event
assert event["pane_id"] == "test:pane", (
    "pane_id is what panewire routes on; it must be the pane alone, not the rest of the metadata row: %r"
    % event["pane_id"])
assert event["epoch"] == 1, event
assert len(event["report_sha256"]) == 64, event
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
# A19 — a successful emit must leave zero trace in the failure marker.
[[ ! -e "$R20_INBOX/r20-done/emit-failures.log" ]]
echo "PASS r20-emit-argv-matches-done-record"

# TW3 — builder escalation carries --question, joined carries --pr/--head, and both carry
# the record's reason verbatim.
R20_BUILDER_LOG="$TMP/r20-builder-emit.log"
r20_claim r20-builder --role builder --parent-lane parent-a
r20_escalate_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_LOG="$R20_BUILDER_LOG" "$WRK" escalate r20-builder \
  --question 'need parent decision')"
r20_joined_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_LOG="$R20_BUILDER_LOG" "$WRK" joined r20-builder \
  --pr https://example.invalid/pr/1 --head deadbeef --report "$R20_REPORT")"
PYTHONPATH="$TMP" python3 - "$R20_BUILDER_LOG" "$R20_INBOX/r20-builder/events" <<'PY'
import sys
import r20_emit as helper
log, events = sys.argv[1:]
escalate_call, joined_call = helper.calls(log)
escalate = helper.assert_matches_record(escalate_call, helper.record(events, "job.escalate"))
joined = helper.assert_matches_record(joined_call, helper.record(events, "job.joined"))
assert escalate["--reason"] == "builder escalation", escalate
assert escalate["--question"] == "need parent decision", escalate
assert not {"--pr", "--head"} & set(escalate), escalate
assert joined["--reason"] == "builder joined PR", joined
assert joined["--pr"].endswith("/pr/1") and joined["--head"] == "deadbeef", joined
assert "--question" not in joined, joined
PY
echo "PASS r20-emit-argv-matches-builder-escalate-and-joined-records"

# TW4 — no panewire on the box: exit 0, the record is still written and both
# independently optional relays warn without changing stdout.
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
grep -qxF 'wrk: warning: handoffkeep not found; report document not uploaded (job=r20-absent)' "$R20_ABSENT_ERR"
grep -qxF 'wrk: warning: panewire not found; relay event left as file only (job=r20-absent kind=job.completed)' "$R20_ABSENT_ERR"
[[ "$(wc -l <"$R20_ABSENT_ERR" | tr -d ' ')" -eq 2 ]]
# A19 — a warning on stderr is not durable; the failure to relay must be
# discoverable later from files alone, without re-reading logs.
[[ -f "$R20_INBOX/r20-absent/emit-failures.log" ]]
grep -q 'kind=job.completed rc=not_found' "$R20_INBOX/r20-absent/emit-failures.log"
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
grep -qxF 'wrk: warning: handoffkeep not found; report document not uploaded (job=r20-fail)' "$R20_FAIL_ERR"
grep -qxF 'wrk: warning: panewire emit failed (rc=3 job=r20-fail kind=job.completed); relay event left as file only' "$R20_FAIL_ERR"
[[ "$(wc -l <"$R20_FAIL_ERR" | tr -d ' ')" -eq 2 ]]
# A19 — same durable-failure trace as TW4, this time for a non-zero rc rather
# than a missing binary.
[[ -f "$R20_INBOX/r20-fail/emit-failures.log" ]]
grep -q 'kind=job.completed rc=3' "$R20_INBOX/r20-fail/emit-failures.log"
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
  WRK_SENTINEL_LOST_GRACE=0 \
  "$WRK" sentinel r20-lost lane-a wrk-a w1:p1 "$R20_REPORT" >/dev/null 2>&1
r20_lost_rc=$?
set -e
[[ "$r20_lost_rc" -eq 0 ]]
find "$R20_LOST_INBOX/r20-lost/events" -name '*job.lost.json' | grep -q .
[[ ! -e "$R20_LOST_LOG" ]]
# A19 — emit_relay_event is never called for job.lost, so no failure marker
# either.
[[ ! -e "$R20_LOST_INBOX/r20-lost/emit-failures.log" ]]
echo "PASS r20-job-lost-is-never-emitted"

# TW8 — the stdout contract is exactly what it was before emit existed: one
# line, in the pre-R20 format, for each of the three commands.
[[ "$(wc -l <<<"$r20_done_out" | tr -d ' ')" -eq 1 ]]
[[ "$(wc -l <<<"$r20_escalate_out" | tr -d ' ')" -eq 1 ]]
[[ "$(wc -l <<<"$r20_joined_out" | tr -d ' ')" -eq 1 ]]
grep -qxF "OK job=r20-done report=$R20_REPORT" <<<"$r20_done_out"
grep -qxF 'OK job=r20-builder owner_lane=lane-a kind=job.escalate' <<<"$r20_escalate_out"
grep -qxF "OK job=r20-builder owner_lane=lane-a kind=job.joined pr=https://example.invalid/pr/1 head=deadbeef report=$R20_REPORT" <<<"$r20_joined_out"
echo "PASS r20-stdout-contract-unchanged"

# TW9 — emit must always name --inbox-root: panewire wants the root containing
# jobs/<job>/events, which is the parent of wrk_jobs_root() (ARBITER_INBOX_ROOT
# is the jobs directory itself). Without the flag the emit lands on the
# daemon's default root and the relay is lost; the fixture's opt-in
# WRK_PANEWIRE_REQUIRE_INBOX_ROOT turns that into the observed rc=2, which must
# therefore never reach the warning path for any of the three kinds.
R20_ROOT_LOG="$TMP/r20-inbox-root-emit.log"
R20_ROOT_ERR="$TMP/r20-inbox-root.err"
r20_claim r20-root-done
r20_claim r20-root-builder --role builder --parent-lane parent-a
env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_REQUIRE_INBOX_ROOT=1 WRK_PANEWIRE_LOG="$R20_ROOT_LOG" \
  "$WRK" 'done' r20-root-done --report "$R20_REPORT" 2>"$R20_ROOT_ERR" >/dev/null
env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_REQUIRE_INBOX_ROOT=1 WRK_PANEWIRE_LOG="$R20_ROOT_LOG" \
  "$WRK" escalate r20-root-builder --question 'need parent decision' \
  2>>"$R20_ROOT_ERR" >/dev/null
env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_REQUIRE_INBOX_ROOT=1 WRK_PANEWIRE_LOG="$R20_ROOT_LOG" \
  "$WRK" joined r20-root-builder --pr https://example.invalid/pr/1 \
  --head deadbeef --report "$R20_REPORT" 2>>"$R20_ROOT_ERR" >/dev/null
if grep -q 'panewire' "$R20_ROOT_ERR"; then
  fail "emit without --inbox-root is rc=2; the warning proves it was not passed: $(cat "$R20_ROOT_ERR")"
fi
PYTHONPATH="$TMP" python3 - "$R20_ROOT_LOG" "$(dirname "$R20_INBOX")" <<'PY'
import sys
import r20_emit as helper

log, inbox_root = sys.argv[1:]
captured = helper.calls(log)
assert len(captured) == 3, captured
kinds = []
for call in captured:
    got = helper.flags(call)
    assert got.get("--inbox-root") == inbox_root, got
    kinds.append(got["--kind"])
assert kinds == ["job.completed", "job.escalate", "job.joined"], kinds
PY
echo "PASS r20-emit-passes-inbox-root-parent-of-jobs-dir"

# ── R21: report documents are optional handoffkeep uploads ──────────────────
# Keep the capture shape identical to R20: a fixture collects every argv
# element, and real arbiter claim/spawned envelopes provide the command input.
R21_HANDOFFKEEP="$TMP/handoffkeep"
cat >"$R21_HANDOFFKEEP" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${WRK_HANDOFFKEEP_LOG:-}" ]]; then
  {
    for argument in "$@"; do printf '%s\n' "$argument"; done
    printf -- '--\n'
  } >>"$WRK_HANDOFFKEEP_LOG"
fi

[[ -z "${WRK_HANDOFFKEEP_SLEEP:-}" ]] || sleep "$WRK_HANDOFFKEEP_SLEEP"
exit "${WRK_HANDOFFKEEP_RC:-0}"
SH
chmod +x "$R21_HANDOFFKEEP"

R21_INBOX="$TMP/r21-inbox"
r21_arb() { env ARBITER_INBOX_ROOT="$R21_INBOX" XDG_DATA_HOME="$TMP/xdg-r21" "$ARBITER" "$@"; }
r21_claim() {
  r21_arb claim --job "$1" --lane lane-a --agent-label wrk-a --t T1 "${@:2}" >/dev/null
  r21_arb event --job "$1" --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
}
r21_report() {
  local job="$1" name="$2" line="$3"
  local path="$R21_INBOX/$job/$name"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$line" >"$path"
  printf '%s\n' "$path"
}

# T1/T2/T9 — exact document argv, one call, and the same doc-suffixed last
# line in both the durable record and captured panewire argv. The fixture token
# proves that wrk neither reads nor prints the credential passed to the CLI.
R21_DONE_JOB="r21-done"
R21_DONE_REPORT="$(r21_report "$R21_DONE_JOB" report.md 'document terminal line')"
R21_DONE_HK_LOG="$TMP/r21-done-handoffkeep.log"
R21_DONE_PW_LOG="$TMP/r21-done-panewire.log"
R21_DONE_ERR="$TMP/r21-done.err"
r21_claim "$R21_DONE_JOB"
r21_done_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" HANDOFFKEEP_TOKEN=fixture-token \
  WRK_HANDOFFKEEP_LOG="$R21_DONE_HK_LOG" WRK_PANEWIRE_LOG="$R21_DONE_PW_LOG" \
  "$WRK" 'done' "$R21_DONE_JOB" --report "$R21_DONE_REPORT" 2>"$R21_DONE_ERR")"
PYTHONPATH="$TMP" python3 - "$R21_DONE_HK_LOG" "$R21_DONE_PW_LOG" "$R21_INBOX/$R21_DONE_JOB/events" "$R21_DONE_REPORT" <<'PY'
import sys
import r20_emit as helper

handoff, panewire, events, report = sys.argv[1:]
expected = ["doc", "put", "--key", "reports/r21-done/report.md", "--kind", "report",
            "--job", "r21-done", "--file", report]
assert helper.calls(handoff) == [expected], helper.calls(handoff)
event = helper.record(events, "job.completed")
call = helper.calls(panewire)
assert len(call) == 1, call
got = helper.assert_matches_record(call[0], event)
assert event["report_last_line"] == got["--report-last-line"], (event, got)
assert event["report_last_line"].endswith(" doc:reports/r21-done/report.md"), event
PY
grep -qxF "OK job=$R21_DONE_JOB report=$R21_DONE_REPORT" <<<"$r21_done_out"
[[ ! -s "$R21_DONE_ERR" ]]
if grep -qF 'fixture-token' "$R21_DONE_HK_LOG" || grep -qF 'fixture-token' <<<"$r21_done_out" \
  || grep -qF 'fixture-token' "$R21_DONE_ERR"; then
  fail "handoffkeep token leaked to an argv capture or wrk output"
fi
echo "PASS r21-done-document-argv-record-wire-and-token-hygiene"

# T3 — reserve space for the complete document suffix before truncating the
# original terminal line; a broken link is worse than a shortened summary.
R21_LONG_JOB="r21-long"
R21_LONG_REPORT="$R21_INBOX/$R21_LONG_JOB/report-long.md"
mkdir -p "$(dirname "$R21_LONG_REPORT")"
python3 -c 'print("x" * 300)' >"$R21_LONG_REPORT"
r21_claim "$R21_LONG_JOB"
env ARBITER_INBOX_ROOT="$R21_INBOX" HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
  "$WRK" 'done' "$R21_LONG_JOB" --report "$R21_LONG_REPORT" >/dev/null
PYTHONPATH="$TMP" python3 - "$R21_INBOX/$R21_LONG_JOB/events" <<'PY'
import sys
import r20_emit as helper

last = helper.record(sys.argv[1], "job.completed")["report_last_line"]
suffix = " doc:reports/r21-long/report-long.md"
assert len(last) <= 240, len(last)
assert last.endswith(suffix), last
assert len(last) == 240, len(last)
PY
echo "PASS r21-document-suffix-survives-240-character-cap"

# T4 — a failed upload is one warning only; it must not alter the OK line,
# prevent the durable record/emit, or attach a document suffix.
R21_FAIL_JOB="r21-upload-fail"
R21_FAIL_REPORT="$(r21_report "$R21_FAIL_JOB" report.md 'upload failure terminal line')"
R21_FAIL_PW_LOG="$TMP/r21-fail-panewire.log"
R21_FAIL_ERR="$TMP/r21-fail.err"
r21_claim "$R21_FAIL_JOB"
set +e
r21_fail_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_RC=1 \
  WRK_PANEWIRE_LOG="$R21_FAIL_PW_LOG" "$WRK" 'done' "$R21_FAIL_JOB" \
  --report "$R21_FAIL_REPORT" 2>"$R21_FAIL_ERR")"
r21_fail_rc=$?
set -e
[[ "$r21_fail_rc" -eq 0 ]]
grep -qxF "OK job=$R21_FAIL_JOB report=$R21_FAIL_REPORT" <<<"$r21_fail_out"
grep -qxF 'wrk: warning: handoffkeep document upload failed (rc=1 job=r21-upload-fail); continuing without document link' "$R21_FAIL_ERR"
[[ "$(wc -l <"$R21_FAIL_ERR" | tr -d ' ')" -eq 1 ]]
PYTHONPATH="$TMP" python3 - "$R21_FAIL_PW_LOG" "$R21_INBOX/$R21_FAIL_JOB/events" <<'PY'
import sys
import r20_emit as helper

event = helper.record(sys.argv[2], "job.completed")
call = helper.calls(sys.argv[1])
assert len(call) == 1, call
helper.assert_matches_record(call[0], event)
assert " doc:" not in event["report_last_line"], event
PY
echo "PASS r21-failed-document-upload-warns-and-continues"

# T5 — resolving no CLI at all has the same non-fatal, no-document result.
R21_ABSENT_JOB="r21-handoffkeep-absent"
R21_ABSENT_REPORT="$(r21_report "$R21_ABSENT_JOB" report.md 'absent terminal line')"
R21_ABSENT_PW_LOG="$TMP/r21-absent-panewire.log"
R21_ABSENT_ERR="$TMP/r21-absent.err"
r21_claim "$R21_ABSENT_JOB"
set +e
r21_absent_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$TMP/no-handoffkeep" WRK_PANEWIRE_LOG="$R21_ABSENT_PW_LOG" \
  "$WRK" 'done' "$R21_ABSENT_JOB" --report "$R21_ABSENT_REPORT" 2>"$R21_ABSENT_ERR")"
r21_absent_rc=$?
set -e
[[ "$r21_absent_rc" -eq 0 ]]
grep -qxF "OK job=$R21_ABSENT_JOB report=$R21_ABSENT_REPORT" <<<"$r21_absent_out"
grep -qxF 'wrk: warning: handoffkeep not found; report document not uploaded (job=r21-handoffkeep-absent)' "$R21_ABSENT_ERR"
[[ "$(wc -l <"$R21_ABSENT_ERR" | tr -d ' ')" -eq 1 ]]
PYTHONPATH="$TMP" python3 - "$R21_ABSENT_PW_LOG" "$R21_INBOX/$R21_ABSENT_JOB/events" <<'PY'
import sys
import r20_emit as helper

event = helper.record(sys.argv[2], "job.completed")
call = helper.calls(sys.argv[1])
assert len(call) == 1, call
helper.assert_matches_record(call[0], event)
assert " doc:" not in event["report_last_line"], event
PY
echo "PASS r21-missing-handoffkeep-warns-and-continues"

# T6 — a stalled CLI is bounded by the three-second guard and otherwise has
# the T4 behavior. Its 30-second fixture delay must never escape the guard.
R21_SLOW_JOB="r21-handoffkeep-slow"
R21_SLOW_REPORT="$(r21_report "$R21_SLOW_JOB" report.md 'slow terminal line')"
R21_SLOW_PW_LOG="$TMP/r21-slow-panewire.log"
R21_SLOW_ERR="$TMP/r21-slow.err"
r21_claim "$R21_SLOW_JOB"
r21_slow_start_ns="$(python3 -c 'import time; print(time.time_ns())')"
set +e
r21_slow_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_SLEEP=30 \
  WRK_PANEWIRE_LOG="$R21_SLOW_PW_LOG" "$WRK" 'done' "$R21_SLOW_JOB" \
  --report "$R21_SLOW_REPORT" 2>"$R21_SLOW_ERR")"
r21_slow_rc=$?
set -e
r21_slow_ms="$(( ($(python3 -c 'import time; print(time.time_ns())') - r21_slow_start_ns) / 1000000 ))"
[[ "$r21_slow_rc" -eq 0 ]]
[[ "$r21_slow_ms" -lt 10000 ]]
grep -qxF "OK job=$R21_SLOW_JOB report=$R21_SLOW_REPORT" <<<"$r21_slow_out"
grep -q 'handoffkeep document upload failed' "$R21_SLOW_ERR"
[[ "$(wc -l <"$R21_SLOW_ERR" | tr -d ' ')" -eq 1 ]]
PYTHONPATH="$TMP" python3 - "$R21_SLOW_PW_LOG" "$R21_INBOX/$R21_SLOW_JOB/events" <<'PY'
import sys
import r20_emit as helper

event = helper.record(sys.argv[2], "job.completed")
call = helper.calls(sys.argv[1])
assert len(call) == 1, call
helper.assert_matches_record(call[0], event)
assert " doc:" not in event["report_last_line"], event
PY
echo "PASS r21-stalled-handoffkeep-is-bounded-by-three-second-guard elapsed_ms=$r21_slow_ms"

# T7 — joined follows the same upload and suffix rules, using the builder's
# own job id in the document command.
R21_JOINED_JOB="r21-joined"
R21_JOINED_REPORT="$(r21_report "$R21_JOINED_JOB" joined-report.md 'joined terminal line')"
R21_JOINED_HK_LOG="$TMP/r21-joined-handoffkeep.log"
R21_JOINED_PW_LOG="$TMP/r21-joined-panewire.log"
r21_claim "$R21_JOINED_JOB" --role builder --parent-lane parent-a
env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
  WRK_HANDOFFKEEP_LOG="$R21_JOINED_HK_LOG" WRK_PANEWIRE_LOG="$R21_JOINED_PW_LOG" \
  "$WRK" joined "$R21_JOINED_JOB" --pr https://example.invalid/pr/21 --head deadbeef \
  --report "$R21_JOINED_REPORT" >/dev/null
PYTHONPATH="$TMP" python3 - "$R21_JOINED_HK_LOG" "$R21_JOINED_PW_LOG" "$R21_INBOX/$R21_JOINED_JOB/events" "$R21_JOINED_REPORT" <<'PY'
import sys
import r20_emit as helper

handoff, panewire, events, report = sys.argv[1:]
call = helper.calls(handoff)
assert len(call) == 1 and call[0][7] == "r21-joined", call
event = helper.record(events, "job.joined")
relay = helper.calls(panewire)
assert len(relay) == 1, relay
helper.assert_matches_record(relay[0], event)
assert event["report_last_line"].endswith(" doc:reports/r21-joined/joined-report.md"), event
PY
echo "PASS r21-joined-uploads-and-relays-document-link"

# T8 — escalation accepts an optional report; without it it retains the old
# empty report fields and makes no handoffkeep call. A missing report is fatal.
R21_ESC_JOB="r21-escalate-report"
R21_ESC_REPORT="$(r21_report "$R21_ESC_JOB" escalation.md 'escalation terminal line')"
R21_ESC_HK_LOG="$TMP/r21-escalate-handoffkeep.log"
R21_ESC_PW_LOG="$TMP/r21-escalate-panewire.log"
r21_claim "$R21_ESC_JOB" --role builder --parent-lane parent-a
env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
  WRK_HANDOFFKEEP_LOG="$R21_ESC_HK_LOG" WRK_PANEWIRE_LOG="$R21_ESC_PW_LOG" \
  "$WRK" escalate "$R21_ESC_JOB" --question 'need a decision' --report "$R21_ESC_REPORT" >/dev/null
PYTHONPATH="$TMP" python3 - "$R21_ESC_HK_LOG" "$R21_ESC_PW_LOG" "$R21_INBOX/$R21_ESC_JOB/events" <<'PY'
import sys
import r20_emit as helper

handoff, panewire, events = sys.argv[1:]
assert len(helper.calls(handoff)) == 1, helper.calls(handoff)
event = helper.record(events, "job.escalate")
relay = helper.calls(panewire)
assert len(relay) == 1, relay
helper.assert_matches_record(relay[0], event)
assert event["report_path"].endswith("/escalation.md"), event
assert event["report_last_line"].endswith(" doc:reports/r21-escalate-report/escalation.md"), event
PY
R21_ESC_EMPTY_JOB="r21-escalate-empty"
R21_ESC_EMPTY_HK_LOG="$TMP/r21-escalate-empty-handoffkeep.log"
R21_ESC_EMPTY_PW_LOG="$TMP/r21-escalate-empty-panewire.log"
r21_claim "$R21_ESC_EMPTY_JOB" --role builder --parent-lane parent-a
env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
  WRK_HANDOFFKEEP_LOG="$R21_ESC_EMPTY_HK_LOG" WRK_PANEWIRE_LOG="$R21_ESC_EMPTY_PW_LOG" \
  "$WRK" escalate "$R21_ESC_EMPTY_JOB" --question 'need a decision' >/dev/null
[[ ! -s "$R21_ESC_EMPTY_HK_LOG" ]]
PYTHONPATH="$TMP" python3 - "$R21_ESC_EMPTY_PW_LOG" "$R21_INBOX/$R21_ESC_EMPTY_JOB/events" <<'PY'
import sys
import r20_emit as helper

event = helper.record(sys.argv[2], "job.escalate")
relay = helper.calls(sys.argv[1])
assert len(relay) == 1, relay
helper.assert_matches_record(relay[0], event)
assert event["report_path"] == event["report_last_line"] == "", event
PY
R21_ESC_MISSING_JOB="r21-escalate-missing"
R21_ESC_MISSING_HK_LOG="$TMP/r21-escalate-missing-handoffkeep.log"
r21_claim "$R21_ESC_MISSING_JOB" --role builder --parent-lane parent-a
: >"$R21_ESC_MISSING_HK_LOG"
set +e
env ARBITER_INBOX_ROOT="$R21_INBOX" HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
  WRK_HANDOFFKEEP_LOG="$R21_ESC_MISSING_HK_LOG" "$WRK" escalate "$R21_ESC_MISSING_JOB" \
  --question 'need a decision' --report "$TMP/no-such-report.md" >/dev/null 2>&1
r21_esc_missing_rc=$?
set -e
[[ "$r21_esc_missing_rc" -ne 0 ]]
[[ ! -s "$R21_ESC_MISSING_HK_LOG" ]]
echo "PASS r21-escalate-report-optional-and-missing-path-is-fatal"

# R18 completion sentinel: a report alone is never completion evidence. A
# worker still working must time out/lost rather than emit job.completed.
SENTINEL_REPORT="$TMP/sentinel-report.md"
printf 'sentinel final line\n' >"$SENTINEL_REPORT"
SENTINEL_INBOX="$TMP/sentinel-inbox"
set +e
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$SENTINEL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-working WRK_COMPLETION_TIMEOUT_S=1 WRK_COMPLETION_INTERVAL_S=1 \
  WRK_SENTINEL_LOST_GRACE=0 \
  "$WRK" sentinel sentinel-working lane worker w:p1 "$SENTINEL_REPORT" >/dev/null 2>&1
sentinel_working_rc=$?
set -e
[[ "$sentinel_working_rc" -eq 0 ]]
if find "$SENTINEL_INBOX/sentinel-working/events" -name '*job.completed.json' | grep -q .; then
  echo "working agent incorrectly emitted job.completed" >&2
  exit 1
fi
find "$SENTINEL_INBOX/sentinel-working/events" -name '*job.lost.json' | grep -q .
python3 - "$SENTINEL_INBOX/sentinel-working/events" <<'PY'
import glob, json, sys
lost = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.lost.json"))]
assert lost and lost[0].get("reason") == "timeout", (
    "an expired watch window is job.lost with reason=timeout, got %r" % lost)
PY
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
event_count_is "$SENTINEL_INBOX/sentinel-idle/events" job.completed 0 ||
  fail "a job with no report is not complete, whatever the pane status says (got $(event_count "$SENTINEL_INBOX/sentinel-idle/events" job.completed))"
cp "$SENTINEL_REPORT" "$SENTINEL_INBOX/sentinel-idle/report.md"
# the report must sit unchanged for one interval before it counts as final —
# the first sighting only logs action=pending.
wait_until 30 event_count_is "$SENTINEL_INBOX/sentinel-idle/events" job.completed 1 ||
  fail "an idle pane plus a settled report is exactly one job.completed (got $(event_count "$SENTINEL_INBOX/sentinel-idle/events" job.completed))"
printf 'updated report line\n' >>"$SENTINEL_INBOX/sentinel-idle/report.md"
wait_until 30 event_count_is "$SENTINEL_INBOX/sentinel-idle/events" job.completed 2 ||
  fail "an updated report at the same path is a new round, so a second job.completed follows (got $(event_count "$SENTINEL_INBOX/sentinel-idle/events" job.completed))"
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
wait_until 30 event_count_is "$SENTINEL_INBOX/sentinel-done/events" job.completed 1 ||
  fail "a done pane plus a settled report is exactly one job.completed (got $(event_count "$SENTINEL_INBOX/sentinel-done/events" job.completed))"
kill "$sentinel_done_pid" 2>/dev/null || true
wait "$sentinel_done_pid" 2>/dev/null || true
echo "PASS r18-sentinel-accepts-done-status"

# ---------------------------------------------------------------------------
# 센티널 판정: 빈 값은 소멸의 증거가 아니다 (job.lost 오탐 수정)
# ---------------------------------------------------------------------------

# (a) 빈 출력·exit 1·JSON 파싱 실패·소켓 에러가 연속 임계 미만이면 소멸이 아니다.
# 그 뒤 정상 상태가 오면 판정은 completed 여야 하고 job.lost 는 하나도 없어야 한다.
TRANSIENT_INBOX="$TMP/sentinel-transient-inbox"
TRANSIENT_SEQ="$TMP/sentinel-transient.seq"
printf '%s\n' empty exit1 garbage socket working idle >"$TRANSIENT_SEQ"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$TRANSIENT_INBOX" \
  WRK_FIXTURE_GET_SEQUENCE="$TRANSIENT_SEQ" \
  WRK_COMPLETION_TIMEOUT_S=120 WRK_COMPLETION_INTERVAL_S=1 \
  WRK_SENTINEL_TRANSIENT_MAX=10 WRK_SENTINEL_LOST_GRACE=0 \
  "$WRK" sentinel sentinel-transient lane-a worker w1:p1 "$SENTINEL_REPORT" >/dev/null 2>&1 &
transient_pid=$!
TRANSIENT_EVENTS="$TRANSIENT_INBOX/sentinel-transient/events"
wait_until 30 event_count_is "$TRANSIENT_EVENTS" job.completed 1 ||
  fail "transient herdr failures below WRK_SENTINEL_TRANSIENT_MAX must still reach job.completed (got $(event_count "$TRANSIENT_EVENTS" job.completed))"
kill "$transient_pid" 2>/dev/null || true
wait "$transient_pid" 2>/dev/null || true
[[ "$(event_count "$TRANSIENT_EVENTS" job.lost)" -eq 0 ]] ||
  fail "empty/failed 'agent get' output is not pane loss: job.lost written with reason=$(sentinel_lost_reason "$TRANSIENT_EVENTS")"
transient_log="$TRANSIENT_INBOX/sentinel-transient/completion-sentinel.log"
[[ -s "$transient_log" ]] || fail "completion-sentinel.log must record one line per decision, but it is empty"
transient_seen="$(awk '{print $2, $3, $4}' "$transient_log" | head -7)"
transient_want='status=empty transient=1 action=none
status=err:exit1 transient=2 action=none
status=err:parse transient=3 action=none
status=err:transport_unavailable transient=4 action=none
status=working transient=0 action=none
status=idle transient=0 action=pending
status=idle transient=0 action=completed'
[[ "$transient_seen" == "$transient_want" ]] ||
  fail "sentinel decision log must classify each observation; want:
$transient_want
got:
$transient_seen"
echo "PASS sentinel-tolerates-transient-herdr-failures"

# (a') 연속 실패가 임계를 넘으면 herdr_unreachable 로 lost 하되, 유예 동안 계속
# 감시해 report + 종료 상태가 나타나면 completed 를 추가로 쓴다.
GRACE_INBOX="$TMP/sentinel-grace-inbox"
GRACE_SEQ="$TMP/sentinel-grace.seq"
printf '%s\n' empty empty empty empty idle >"$GRACE_SEQ"
GRACE_REPORT="$TMP/sentinel-grace-report.md"
rm -f "$GRACE_REPORT"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$GRACE_INBOX" \
  WRK_FIXTURE_GET_SEQUENCE="$GRACE_SEQ" \
  WRK_COMPLETION_TIMEOUT_S=300 WRK_COMPLETION_INTERVAL_S=1 \
  WRK_SENTINEL_TRANSIENT_MAX=3 WRK_SENTINEL_LOST_GRACE=120 \
  "$WRK" sentinel sentinel-grace lane-a worker w1:p1 "$GRACE_REPORT" >/dev/null 2>&1 &
grace_pid=$!
GRACE_EVENTS="$GRACE_INBOX/sentinel-grace/events"
wait_until 30 event_count_is "$GRACE_EVENTS" job.lost 1 ||
  fail "more than WRK_SENTINEL_TRANSIENT_MAX consecutive unreachable observations must end in job.lost"
[[ "$(sentinel_lost_reason "$GRACE_EVENTS")" == "herdr_unreachable" ]] ||
  fail "job.lost from consecutive observation failures must carry reason=herdr_unreachable, got '$(sentinel_lost_reason "$GRACE_EVENTS")'"
[[ "$(event_count "$GRACE_EVENTS" job.completed)" -eq 0 ]] ||
  fail "no report existed yet, so nothing may be completed at this point"
printf 'grace report line\n' >"$GRACE_REPORT"
wait_until 30 event_count_is "$GRACE_EVENTS" job.completed 1 ||
  fail "a report that appears within WRK_SENTINEL_LOST_GRACE must still produce job.completed after job.lost"
wait_until 15 bash -c "! kill -0 $grace_pid 2>/dev/null" ||
  fail "the sentinel must exit once it has completed a job it had already reported lost"
wait "$grace_pid" 2>/dev/null || true
grace_log="$GRACE_INBOX/sentinel-grace/completion-sentinel.log"
grace_lines="$(awk 'END{print NR}' "$grace_log")"
grace_calls="$(awk 'END{print NR}' "$GRACE_SEQ.calls")"
[[ "$grace_lines" -eq "$grace_calls" ]] ||
  fail "completion-sentinel.log must hold exactly one line per decision: $grace_lines lines for $grace_calls observations"
grep -q 'action=lost:herdr_unreachable' "$grace_log" ||
  fail "the decision log must name the lost reason it wrote (action=lost:herdr_unreachable)"
grep -q 'action=completed' "$grace_log" ||
  fail "the decision log must record the post-lost completion"
echo "PASS sentinel-lost-grace-still-completes"

# (b) 확정 소멸 코드는 즉시 lost 다 — 여기서만 재시도가 없다.
GONE_INBOX="$TMP/sentinel-gone-inbox"
GONE_SEQ="$TMP/sentinel-gone.seq"
printf '%s\n' not-found >"$GONE_SEQ"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$GONE_INBOX" \
  WRK_FIXTURE_GET_SEQUENCE="$GONE_SEQ" \
  WRK_COMPLETION_TIMEOUT_S=300 WRK_COMPLETION_INTERVAL_S=1 \
  WRK_SENTINEL_TRANSIENT_MAX=10 WRK_SENTINEL_LOST_GRACE=0 \
  "$WRK" sentinel sentinel-gone lane-a worker w1:p1 "$SENTINEL_REPORT" >/dev/null 2>&1
GONE_EVENTS="$GONE_INBOX/sentinel-gone/events"
[[ "$(event_count "$GONE_EVENTS" job.lost)" -eq 1 ]] ||
  fail "an explicit agent_not_found is confirmed pane loss and must be reported at once"
[[ "$(sentinel_lost_reason "$GONE_EVENTS")" == "agent_not_found" ]] ||
  fail "job.lost must carry reason=agent_not_found, got '$(sentinel_lost_reason "$GONE_EVENTS")'"
gone_log="$GONE_INBOX/sentinel-gone/completion-sentinel.log"
[[ "$(awk 'END{print NR}' "$gone_log")" -eq 1 ]] ||
  fail "one observation is one decision is one log line"
grep -q 'status=err:agent_not_found transient=0 action=lost:agent_not_found' "$gone_log" ||
  fail "the decision log must show the error code that proved the loss"
echo "PASS sentinel-agent-not-found-is-immediate-loss"

# 분리된 센티널은 wrk 가 쓰던 herdr 세션을 명시적으로 물려받아야 한다. 상속에
# 기대면 비기본 세션 호스트에서 기본 소켓을 물어 영원히 빈 값을 본다.
ENV_INBOX="$TMP/sentinel-env-inbox"
ENV_LOG="$TMP/sentinel-env.log"
: >"$ENV_LOG"
env -u HERDR_SESSION -u HERDR_SOCKET_PATH \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
  ARBITER_INBOX_ROOT="$ENV_INBOX" WRK_NO_SLEEP=1 WRK_FIXTURE_SCENARIO=spawn \
  WRK_FIXTURE_LOG="$TMP/sentinel-env-herdr.log" WRK_FIXTURE_ENV_LOG="$ENV_LOG" \
  WRK_SENTINEL_HERDR_SESSION=host-a WRK_SENTINEL_HERDR_SOCKET=/tmp/host-a.sock \
  WRK_COMPLETION_INTERVAL_S=1 WRK_SENTINEL_LOST_GRACE=0 \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture \
  --t T1 --job sentinel-env --owner lane-a >/dev/null
ENV_PIDFILE="$ENV_INBOX/sentinel-env/completion-sentinel.pid"
[[ -s "$ENV_PIDFILE" ]] || fail "spawn must start a completion sentinel once the job is registered"
wait_until 30 grep -q 'HERDR_SESSION=host-a' "$ENV_LOG" ||
  fail "the sentinel must query herdr with the session wrk pinned into it (HERDR_SESSION=host-a), saw: $(tr '\n' '|' <"$ENV_LOG")"
grep -q 'HERDR_SOCKET_PATH=/tmp/host-a.sock' "$ENV_LOG" ||
  fail "the sentinel must query herdr through the socket wrk pinned into it"
kill "$(cat "$ENV_PIDFILE")" 2>/dev/null || true
python3 - "$ENV_INBOX/sentinel-env/events" <<'PY'
import glob, json, sys
spawned = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.spawned.json"))]
assert spawned, "spawn must record a job.spawned receipt"
payload = spawned[-1].get("payload", spawned[-1])
assert payload.get("tab_id") == "w:t1", (
    "job.spawned must record the tab_id `wrk reap` later closes, got %r" % payload.get("tab_id"))
PY
echo "PASS sentinel-inherits-pinned-herdr-session"

# #603: `--keep` puts "keep": true on the job.spawned receipt, and a spawn
# without it writes the exact receipt payload it always did (no keep key, no
# other change).
for keep_case in kept plain; do
  keep_inbox="$TMP/spawn-keep-$keep_case"
  keep_args=()
  [[ "$keep_case" == kept ]] && keep_args=(--keep)
  env -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$keep_inbox" WRK_NO_SLEEP=1 WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/spawn-keep-herdr.log" WRK_COMPLETION_INTERVAL_S=1 \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
    "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture \
    --t T1 --job "spawn-keep-$keep_case" --owner lane-a ${keep_args[@]+"${keep_args[@]}"} >/dev/null ||
    fail "#603: spawn ($keep_case) must succeed"
  kill "$(cat "$keep_inbox/spawn-keep-$keep_case/completion-sentinel.pid" 2>/dev/null)" 2>/dev/null || true
done
python3 - "$TMP/spawn-keep-kept/spawn-keep-kept/events" "$TMP/spawn-keep-plain/spawn-keep-plain/events" <<'PY'
import glob, json, sys
def receipt(directory):
    paths = sorted(glob.glob(directory + "/*job.spawned.json"))
    assert len(paths) == 1, "exactly one job.spawned receipt, got %r" % paths
    return json.load(open(paths[0]))["payload"]
kept, plain = receipt(sys.argv[1]), receipt(sys.argv[2])
base = {"pane_id": "w:p1", "label": "fixture", "profile": "codex-terra", "workspace": "w", "tab_id": "w:t1"}
assert plain == base, "a spawn without --keep must write the unchanged receipt, got %r" % plain
assert kept == dict(base, keep=True), "--keep must record keep: true on the receipt, got %r" % kept
assert kept["keep"] is True, "the marker must be the JSON literal true"
PY
grep -q -- '--keep' <<<"$("$WRK" spawn --help)" || fail "#603: spawn --help must document --keep"
# bash 3.2 cannot `source <(...)`, so the two functions go through a file.
sed -n '/^wrk_option_token()/,/^}/p;/^spillover_hub_args()/,/^}/p' "$WRK" >"$TMP/spill-keep-funcs.sh"
spill_keep_err="$(bash -c '. "$1"; spillover_hub_args -m codex-terra -l fixture --keep' _ "$TMP/spill-keep-funcs.sh" 2>&1)" &&
  fail "#603: a hub spill-over must refuse --keep rather than silently drop the marker"
grep -q "option '--keep' is not permitted for a hub spawn" <<<"$spill_keep_err" ||
  fail "#603: the hub spill-over refusal must name --keep: $spill_keep_err"
echo "PASS spawn-keep-marks-receipt"

# ---------------------------------------------------------------------------
# completion idempotency: 같은 report artifact = 같은 round = 레코드 1건
# ---------------------------------------------------------------------------
# 445 재현: `wrk done` 이 쓴 뒤 센티널이 같은 report 를 독립 관측해 두 번째
# job.completed 를 썼다. 억제는 "이 report 내용의 canonical 완료가 이미 있는가"
# (멤버십) 판정이며 건수·임계값이 아니다.
IDEM_INBOX="$TMP/idem-inbox"
idem_arb() { env ARBITER_INBOX_ROOT="$IDEM_INBOX" XDG_DATA_HOME="$TMP/xdg-idem" "$ARBITER" "$@"; }
idem_claim() {
  idem_arb claim --job "$1" --lane lane-a --agent-label wrk-a --t T1 >/dev/null
  idem_arb event --job "$1" --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
}
panewire_call_count() { grep -cx -- '--' "$1" 2>/dev/null || true; }
sentinel_log_has() { [[ -f "$1" ]] && grep -q "$2" "$1"; }

# IDEM-1 — `wrk done` 재호출은 no-op 이다: 레코드 1건, emit 1회, 두 번째 호출은
# rc=0 + stderr 경고 + 지속 억제 로그. 세 번째 호출도 같다(멤버십, 카운트 아님).
idem_claim idem-double
IDEM_REPORT="$TMP/idem-report.md"
printf 'idem verdict line\n' >"$IDEM_REPORT"
IDEM_PW_LOG="$TMP/idem-panewire.log"
: >"$IDEM_PW_LOG"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" WRK_PANEWIRE_LOG="$IDEM_PW_LOG" \
  "$WRK" 'done' idem-double --report "$IDEM_REPORT" >/dev/null 2>&1
env ARBITER_INBOX_ROOT="$IDEM_INBOX" WRK_PANEWIRE_LOG="$IDEM_PW_LOG" \
  "$WRK" 'done' idem-double --report "$IDEM_REPORT" >"$TMP/idem-dup.out" 2>"$TMP/idem-dup.err"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" WRK_PANEWIRE_LOG="$IDEM_PW_LOG" \
  "$WRK" 'done' idem-double --report "$IDEM_REPORT" >/dev/null 2>&1
event_count_is "$IDEM_INBOX/idem-double/events" job.completed 1 ||
  fail "a same-report re-completion must not write a second record (got $(event_count "$IDEM_INBOX/idem-double/events" job.completed))"
grep -qxF "OK job=idem-double report=$IDEM_REPORT" "$TMP/idem-dup.out" ||
  fail "a suppressed duplicate still reports the completion as done: $(cat "$TMP/idem-dup.out")"
grep -q 'suppressed duplicate' "$TMP/idem-dup.err" ||
  fail "a suppressed duplicate must warn on stderr: $(cat "$TMP/idem-dup.err")"
grep -q 'suppressed-duplicate' "$IDEM_INBOX/idem-double/completion-suppressed.log" ||
  fail "a suppressed duplicate must leave a durable note in the job directory"
[[ "$(panewire_call_count "$IDEM_PW_LOG")" -eq 1 ]] ||
  fail "the owner lane is notified exactly once per canonical completion (got $(panewire_call_count "$IDEM_PW_LOG") emits)"
echo "PASS completion-done-recall-is-idempotent"

# IDEM-2 — 관측된 445 모양: `wrk done` 가 먼저 쓰고 센티널이 같은 report 를
# 나중에 관측한다. 센티널 판정은 completed 로 기록되지만 쓰기는 억제된다.
idem_claim idem-race
IDEM_RACE_REPORT="$TMP/idem-race-report.md"
printf 'race verdict line\n' >"$IDEM_RACE_REPORT"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" "$WRK" 'done' idem-race --report "$IDEM_RACE_REPORT" >/dev/null 2>&1
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$IDEM_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-idle WRK_COMPLETION_TIMEOUT_S=30 WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel idem-race lane-a wrk-a w1:p1 "$IDEM_RACE_REPORT" >/dev/null 2>&1 &
idem_race_pid=$!
wait_until 30 sentinel_log_has "$IDEM_INBOX/idem-race/completion-sentinel.log" 'action=completed' ||
  fail "the sentinel must still judge the settled report as completed"
sleep 1
event_count_is "$IDEM_INBOX/idem-race/events" job.completed 1 ||
  fail "the sentinel's observation of an already-completed report must be suppressed (got $(event_count "$IDEM_INBOX/idem-race/events" job.completed))"
grep -q 'suppressed-duplicate' "$IDEM_INBOX/idem-race/completion-suppressed.log" ||
  fail "the suppressed sentinel write must leave a durable note"
kill "$idem_race_pid" 2>/dev/null || true
wait "$idem_race_pid" 2>/dev/null || true
echo "PASS completion-sentinel-observation-after-done-is-suppressed"

# IDEM-3 — 후속 round 는 별개 1건: report 내용이 바뀌면 새 레코드가 쓰이고 두
# 레코드는 report_sha256 으로 서로 식별된다.
idem_claim idem-rounds
IDEM_ROUNDS_REPORT="$TMP/idem-rounds-report.md"
printf 'round one verdict\n' >"$IDEM_ROUNDS_REPORT"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" "$WRK" 'done' idem-rounds --report "$IDEM_ROUNDS_REPORT" >/dev/null 2>&1
printf 'round two verdict\n' >"$IDEM_ROUNDS_REPORT"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" "$WRK" 'done' idem-rounds --report "$IDEM_ROUNDS_REPORT" >/dev/null 2>&1
event_count_is "$IDEM_INBOX/idem-rounds/events" job.completed 2 ||
  fail "a new report artifact is a new round and must produce its own record (got $(event_count "$IDEM_INBOX/idem-rounds/events" job.completed))"
python3 - "$IDEM_INBOX/idem-rounds/events" <<'PY'
import glob, hashlib, json, sys
records = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.completed.json"))]
assert len(records) == 2, records
digests = {r.get("report_sha256") for r in records}
assert len(digests) == 2, "the two rounds must carry distinct identities: %r" % records
assert digests == {
    hashlib.sha256(b"round one verdict\n").hexdigest(),
    hashlib.sha256(b"round two verdict\n").hexdigest(),
}, digests
PY
echo "PASS completion-distinct-rounds-are-distinct-records"

# IDEM-4 — 센티널은 부분 작성된 report 로 먼저 나가지 않는다: 첫 관측은 pending
# 이고, settle 전에 내용이 바뀌면 최종본만 canonical 이 된다.
IDEM_PARTIAL_INBOX="$TMP/idem-partial-inbox"
IDEM_PARTIAL_REPORT="$TMP/idem-partial-report.md"
printf 'partial draft\n' >"$IDEM_PARTIAL_REPORT"
# The 3s interval leaves a whole settle window between the pending sighting and
# the completion decision — enough to swap in the final content deterministically.
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$IDEM_PARTIAL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-idle WRK_COMPLETION_TIMEOUT_S=60 WRK_COMPLETION_INTERVAL_S=3 \
  "$WRK" sentinel idem-partial lane-a wrk-a w1:p1 "$IDEM_PARTIAL_REPORT" >/dev/null 2>&1 &
idem_partial_pid=$!
wait_until 30 sentinel_log_has "$IDEM_PARTIAL_INBOX/idem-partial/completion-sentinel.log" 'action=pending' ||
  fail "the first sighting of a report must be a pending observation, not a completion"
event_count_is "$IDEM_PARTIAL_INBOX/idem-partial/events" job.completed 0 ||
  fail "a report observed only once is not yet final and must not be completed"
printf 'partial draft\nfinal verdict line\n' >"$IDEM_PARTIAL_REPORT"
wait_until 30 event_count_is "$IDEM_PARTIAL_INBOX/idem-partial/events" job.completed 1 ||
  fail "once the report settles the sentinel completes exactly once (got $(event_count "$IDEM_PARTIAL_INBOX/idem-partial/events" job.completed))"
python3 - "$IDEM_PARTIAL_INBOX/idem-partial/events" <<'PY'
import glob, hashlib, json, sys
records = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.completed.json"))]
assert len(records) == 1, records
assert records[0]["report_sha256"] == hashlib.sha256(b"partial draft\nfinal verdict line\n").hexdigest(), records[0]
assert records[0]["report_last_line"].startswith("final verdict line"), records[0]
PY
kill "$idem_partial_pid" 2>/dev/null || true
wait "$idem_partial_pid" 2>/dev/null || true
echo "PASS completion-sentinel-waits-for-report-to-settle"

# IDEM-5 — 구버전 레코드(report_sha256 없음)는 억제 근거가 되지 않는다.
# identity 부재는 "중복" 이 아니라 "증명 불가" 다 — 어떤 파일시스템 proxy
# (mtime·touch 롤백·cp -p·rsync -a 보존 복사 포함)로도 과거 본문을 증명할 수
# 없으므로 기록 쪽으로 fail-open 한다. 그리고 그 새 형식 레코드는 이후 재호출을
# 정상 억제한다.
idem_claim idem-legacy
IDEM_LEGACY_REPORT="$TMP/idem-legacy-report.md"
printf 'legacy verdict line\n' >"$IDEM_LEGACY_REPORT"
mkdir -p "$IDEM_INBOX/idem-legacy/events"
printf '%s\n' "{\"kind\":\"job.completed\",\"job_id\":\"idem-legacy\",\"owner_lane\":\"lane-a\",\"label\":\"wrk-a\",\"pane_id\":\"w1:p1\",\"host\":\"h\",\"report_path\":\"$IDEM_LEGACY_REPORT\",\"report_last_line\":\"legacy verdict line\",\"epoch\":1}" \
  >"$IDEM_INBOX/idem-legacy/events/00001-job.completed.json"
# mtime 보존 덮어쓰기(tester 의 cp -p/rsync -a 재현 모양)로도 억제되지 않아야 한다.
printf 'new round verdict line\n' >"$IDEM_LEGACY_REPORT"
touch -t 200001010000.00 "$IDEM_LEGACY_REPORT"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" "$WRK" 'done' idem-legacy --report "$IDEM_LEGACY_REPORT" >/dev/null 2>&1
event_count_is "$IDEM_INBOX/idem-legacy/events" job.completed 2 ||
  fail "a rewritten report must record even when its mtime is rolled back below a legacy record (got $(event_count "$IDEM_INBOX/idem-legacy/events" job.completed))"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" "$WRK" 'done' idem-legacy --report "$IDEM_LEGACY_REPORT" >/dev/null 2>&1
event_count_is "$IDEM_INBOX/idem-legacy/events" job.completed 2 ||
  fail "the new-format record must still suppress a same-report recall (got $(event_count "$IDEM_INBOX/idem-legacy/events" job.completed))"
grep -q 'suppressed-duplicate' "$IDEM_INBOX/idem-legacy/completion-suppressed.log" ||
  fail "the suppressed recall on a new-format record must leave a durable note"
echo "PASS completion-legacy-record-never-suppresses"

# ---------------------------------------------------------------------------
# wrk reap: 끝난 pane 회수
# ---------------------------------------------------------------------------
REAP_INBOX="$TMP/reap-inbox"
REAP_LOG="$TMP/reap-herdr.log"
# 종료 이벤트를 한 시간 전으로 새겨 --grace 를 양방향으로 시험한다(ARBITER_TEST_NOW
# 는 arbiter 가 제공하는 주입 지점이다 — 손으로 쓴 이벤트가 아니다).
REAP_TEST_NOW="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).replace(microsecond=0).isoformat())')"
reap_job() {
  local job="$1" pane="$2" tab="$3" lane="$4" terminal="$5"; shift 5
  local spawned="{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}"
  # tab="" builds the pre-PR shape: a job.spawned receipt with no tab_id at all.
  if [[ -n "$tab" ]]; then
    spawned="{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}"
  fi
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 "$@" >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "$spawned" >/dev/null
  if [[ -n "$terminal" ]]; then
    env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind "$terminal" \
      --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  fi
  unset ARBITER_TEST_NOW
}

# A builder job that was released and then reclaimed without --role: the reclaim
# payload carries the default role=worker, so a last-writer-wins role would strip
# the builder marking and hand a live builder pane to reap.
reap_builder_reclaimed_job() {
  local job="$1" pane="$2" lane="$3"
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 \
    --role builder --parent-lane lane-p >/dev/null
  # release is what moves a job to `released`; take the exclusive-lease route so
  # the reclaim below is the real arbiter transition, not a hand-written event.
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" lease \
    --job "$job" --resource "$TMP/reap-$job" --kind path >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" release \
    --job "$job" --resource "$TMP/reap-$job" --kind path --force >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim --reclaim-released \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"w1:t7\"}" >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.joined \
    --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  unset ARBITER_TEST_NOW
}
reap_job reap-ready w1:p1 w1:t1 lane-a job.completed
reap_job reap-working w1:p2 w1:t2 lane-a job.completed
reap_job reap-open w1:p3 w1:t3 lane-a ''
# The builder sits in the lane under test on purpose: with it in another lane the
# role guard is never reached, because --lane already filtered the job out.
reap_job reap-builder w1:p1 w1:t1 lane-a job.joined --role builder --parent-lane lane-p
reap_job reap-other-lane w1:p1 w1:t1 lane-b job.completed
reap_job reap-shared w1:p4 w1:t4 lane-a job.completed
# Pre-PR shape: no tab_id in job.spawned. The tab has to come from `agent get`,
# and the shared-tab guard must still see it.
reap_job reap-no-tab w1:p5 '' lane-a job.completed
reap_job reap-no-tab-shared w1:p4 '' lane-a job.completed
reap_job reap-lost-only w1:p6 w1:t6 lane-a job.lost
reap_builder_reclaimed_job reap-builder-reclaimed w1:p7 lane-a

# #508 A-1: a job that finished and was then picked up again is live work, even if
# its pane reads idle for a moment (devin/claude panes misreport idle|done during
# long turns). Every event comes from the real arbiter transition.
reap_revived_job() {
  local job="$1" pane="$2" tab="$3" how="$4"
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane lane-a --agent-label "$job" --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}" >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  case "$how" in
    reclaim)
      env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" lease \
        --job "$job" --resource "$TMP/reap-$job" --kind path >/dev/null
      env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" release \
        --job "$job" --resource "$TMP/reap-$job" --kind path --force >/dev/null
      env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim --reclaim-released \
        --job "$job" --lane lane-a --agent-label "$job" --t T1 >/dev/null
      ;;
    respawn|respawn-done)
      env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
        --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}" >/dev/null
      ;;
  esac
  if [[ "$how" == respawn-done ]]; then
    env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
      --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  fi
  unset ARBITER_TEST_NOW
}
reap_revived_job reap-revived w1:p10 w1:t10 reclaim
reap_revived_job reap-revived-spawn w1:p11 w1:t11 respawn
# Picked up again and then finished again: the latest terminal event wins, so
# this one is reapable — the revive guard must not over-refuse.
reap_revived_job reap-revived-done w1:p12 w1:t12 respawn-done

# #508 A-4: the shape of today's normally finished builder jobs (b505/b448/b449 in
# the live inbox): builder claim → spawned → completed* → joined → completed →
# job.lost. job.lost and quota_pool.* are not revivals; with --include-builders
# in the builder's own lane this job must stay a candidate.
export ARBITER_TEST_NOW="$REAP_TEST_NOW"
env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
  --job reap-b505-shape --lane b505-lane --agent-label reap-b505-shape --t T2 \
  --role builder --parent-lane director-x >/dev/null
env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job reap-b505-shape --kind quota_pool.record \
  --payload-json '{"pool":"claude"}' >/dev/null
env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job reap-b505-shape --kind job.spawned \
  --payload-json '{"owner_lane":"b505-lane","label":"reap-b505-shape","pane_id":"w1:p13","tab_id":"w1:t13"}' >/dev/null
for kind in job.completed job.joined job.completed job.lost; do
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job reap-b505-shape --kind "$kind" \
    --payload-json '{"owner_lane":"b505-lane","parent_lane":"director-x","pane_id":"w1:p13"}' >/dev/null
done
unset ARBITER_TEST_NOW

# #508 tester BLOCKER 1: pane and tab come from the newest job.spawned receipt as a
# unit. A respawn receipt without tab_id must not inherit the previous spawn's tab
# (that closed w1:t1 while the live pane was w1:p9), and a malformed newest receipt
# must not fall back to an older one.
reap_receipts_job() {
  local lane="$1" job="$2"; shift 2
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 >/dev/null
  local receipt
  for receipt in "$@"; do
    env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
      --payload-json "$receipt" >/dev/null
  done
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"$lane\",\"pane_id\":\"w1:p1\"}" >/dev/null
  unset ARBITER_TEST_NOW
}
reap_receipts_job receipt-lane reap-mixed-receipt \
  '{"owner_lane":"receipt-lane","pane_id":"w1:p14","tab_id":"w1:t14"}' \
  '{"owner_lane":"receipt-lane","pane_id":"w1:p15"}'
reap_receipts_job receipt-lane reap-broken-newest \
  '{"owner_lane":"receipt-lane","pane_id":"w1:p14","tab_id":"w1:t14"}' \
  '{"owner_lane":"receipt-lane","tab_id":"w1:t14"}'
# The recorded tab is not the tab herdr says the pane lives in (pane moved or the
# tab id was reused): neither tab may be closed.
reap_receipts_job receipt-lane reap-moved \
  '{"owner_lane":"receipt-lane","pane_id":"w1:p16","tab_id":"w1:t17"}'
# #508 tester BLOCKER 2: a pane joins the tab between reap's status probe and the
# close. The tab list must be read after the probe, right before the close.
reap_receipts_job race-lane reap-race \
  '{"owner_lane":"race-lane","pane_id":"w1:p18","tab_id":"w1:t18"}'

# Existing inboxes can contain a durable captain payload written before role
# normalization. Reap must protect it exactly like a new builder payload.
reap_legacy_captain_job() {
  local job="$1" pane="$2" lane="$3"
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 >/dev/null
  python3 - "$REAP_INBOX/$job/events/00001-job.claim.json" <<'PY'
import json, sys
path = sys.argv[1]
event = json.load(open(path))
assert set(event) == {"created_at", "job_id", "kind", "payload", "seq"}, event
event["payload"]["role"] = "captain"
event["payload"]["parent_lane"] = "parent-lane"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, separators=(",", ":"))
    handle.write("\n")
PY
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"w1:t1\"}" >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.joined \
    --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  unset ARBITER_TEST_NOW
}
reap_legacy_captain_job reap-captain-legacy w1:p1 lane-a

# The `wrk done` that shipped before be4dad1 glued parent_lane and role onto
# pane_id with tabs, and 23 such records sit in the live inbox. The spawn receipt
# stays the source of truth, and no candidate field may carry whitespace.
reap_poisoned_job() {
  local job="$1" spawn_pane="$2"
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane lane-a --agent-label "$job" --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"$job\",\"pane_id\":\"$spawn_pane\"}" >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"poisoned","pane_id":"w1:p1\t\tworker"}' >/dev/null
  unset ARBITER_TEST_NOW
}
reap_poisoned_job reap-poisoned w1:p8
reap_poisoned_job reap-poisoned-spawn 'w1:p8\t\tworker'

reap_run() {
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$REAP_INBOX" \
    WRK_FIXTURE_SCENARIO=reap WRK_FIXTURE_LOG="$REAP_LOG" "$WRK" reap "$@"
}

: >"$REAP_LOG"
dry_out="$(reap_run --lane lane-a)"
grep -q '^would-close job=reap-ready pane=w1:p1 tab=w1:t1 status=idle age=[0-9][0-9]*s$' <<<"$dry_out" ||
  fail "a terminal job whose pane is idle past the grace must be a reap candidate, with its tab and age in their own fields: $dry_out"
# A job.spawned with no tab_id must resolve its tab from `agent get`, and the age
# must never land in the tab field: `herdr tab close <seconds>` closes whatever
# tab happens to carry that number.
grep -q '^would-close job=reap-no-tab pane=w1:p5 tab=w1:t5 status=idle age=[0-9][0-9]*s$' <<<"$dry_out" ||
  fail "a job spawned before tab_id was recorded must resolve its tab through 'agent get', and its age must stay out of the tab field: $dry_out"
grep -q '^would-close job=reap-poisoned pane=w1:p8 tab=w1:t8 status=idle age=[0-9][0-9]*s$' <<<"$dry_out" ||
  fail "the spawn receipt is the source of truth for pane and tab; a completion record poisoned by the old done bug must not reach the candidate row: $dry_out"
grep -q 'tab=worker' <<<"$dry_out" &&
  fail "a value glued onto pane_id by tabs must never be read as a tab id: $dry_out"
grep -q '^skip job=reap-poisoned-spawn reason=malformed-record$' <<<"$dry_out" ||
  fail "when the spawn receipt itself carries whitespace in pane_id the evidence is broken and reap must skip, not guess: $dry_out"
[[ "$(grep -c '^would-close ' <<<"$dry_out")" -eq 4 ]] ||
  fail "only the finished, idle, past-grace jobs may be listed: $dry_out"
grep -q '^skip job=reap-revived reason=reclaimed-after-terminal$' <<<"$dry_out" ||
  fail "#508 A-1: a job reclaimed after its terminal event is live work and must be skipped with its reason: $dry_out"
grep -q '^skip job=reap-revived-spawn reason=reclaimed-after-terminal$' <<<"$dry_out" ||
  fail "#508 A-1: a job spawned again after its terminal event is live work and must be skipped with its reason: $dry_out"
grep -qE '^would-close job=reap-revived(-spawn)? ' <<<"$dry_out" &&
  fail "#508 A-1: a job picked up again after it finished must never be a reap candidate: $dry_out"
grep -q '^would-close job=reap-revived-done pane=w1:p12 tab=w1:t12 status=idle' <<<"$dry_out" ||
  fail "#508 A-4: a job that was picked up again and then finished again is reapable (the latest terminal wins): $dry_out"
grep -q 'reason=status=working' <<<"$dry_out" ||
  fail "a still-working pane must be skipped explicitly, never closed: $dry_out"
grep -q 'reap-open' <<<"$dry_out" &&
  fail "a job with no terminal event must not appear in reap output at all: $dry_out"
grep -q 'reap-lost-only' <<<"$dry_out" &&
  fail "job.lost is not a terminal event: a job the old sentinel wrongly declared lost must never be reaped: $dry_out"
grep -q 'reap-builder' <<<"$dry_out" &&
  fail "a builder pane in the lane under test must still be excluded without --include-builders: $dry_out"
grep -q 'reap-captain-legacy' <<<"$dry_out" &&
  fail "a legacy captain payload must still be excluded without --include-builders: $dry_out"
grep -q 'reap-other-lane' <<<"$dry_out" &&
  fail "--lane must filter by the claim owner_lane: $dry_out"
grep -q 'job=reap-shared .*reason=tab-shared' <<<"$dry_out" ||
  fail "a tab that still holds another pane must be skipped, not closed (closing it kills the sibling pane): $dry_out"
grep -q 'job=reap-no-tab-shared pane=w1:p4 tab=w1:t4 reason=tab-shared' <<<"$dry_out" ||
  fail "the shared-tab guard must also cover a tab resolved through 'agent get', not just one recorded at spawn: $dry_out"
grep -q '^tab close' "$REAP_LOG" &&
  fail "the default run is a dry run: no tab may be closed without --apply"
[[ "$(event_count "$REAP_INBOX/reap-ready/events" job.reaped)" -eq 0 ]] ||
  fail "a dry run must not record job.reaped"
echo "PASS reap-dry-run-lists-only-finished-idle-panes"

# #508 A-2: the shared-tab guard is fail-closed. A tab list that failed, did not
# parse, lacks the tab, or gives a pane_count that is not a confirmed 1 means
# "maybe shared" — never close. Both dry run and --apply must agree.
for mode in fail garbage no-result missing no-count string-count bool-count zero-count duplicate; do
  : >"$REAP_LOG"
  mode_out="$(WRK_FIXTURE_REAP_TABS="$mode" reap_run --lane lane-a)"
  grep -q '^would-close ' <<<"$mode_out" &&
    fail "#508 A-2 ($mode): an unconfirmed pane_count must not produce a candidate: $mode_out"
  grep -q '^skip job=reap-ready pane=w1:p1 tab=w1:t1 reason=tab-count-unknown$' <<<"$mode_out" ||
    fail "#508 A-2 ($mode): an unconfirmed tab must be skipped as tab-count-unknown: $mode_out"
  mode_apply="$(WRK_FIXTURE_REAP_TABS="$mode" reap_run --lane lane-a --apply)"
  grep -q '^tab close' "$REAP_LOG" &&
    fail "#508 A-2 ($mode): --apply must not close any tab when the tab list cannot confirm a single pane: $(cat "$REAP_LOG") / $mode_apply"
  grep -q 'reap: closed 0 tab(s)' <<<"$mode_apply" ||
    fail "#508 A-2 ($mode): --apply must report zero closed tabs: $mode_apply"
done
[[ "$(event_count "$REAP_INBOX/reap-ready/events" job.reaped)" -eq 0 ]] ||
  fail "#508 A-2: no job.reaped may be written while the tab list is untrustworthy"
echo "PASS reap-shared-tab-guard-fails-closed"

# #508 A-3: a lane-less --apply is refused before anything is looked at or closed.
: >"$REAP_LOG"
if nolane_out="$(reap_run --apply 2>&1)"; then
  fail "#508 A-3: --apply without --lane must exit nonzero: $nolane_out"
fi
grep -q -- '--apply requires --lane' <<<"$nolane_out" ||
  fail "#508 A-3: the refusal must say --lane is required: $nolane_out"
[[ ! -s "$REAP_LOG" ]] ||
  fail "#508 A-3: a refused lane-less --apply must not even call herdr: $(cat "$REAP_LOG")"
if find "$REAP_INBOX" -name '*job.reaped.json' | grep -q .; then
  fail "#508 A-3: a refused lane-less --apply must not record job.reaped"
fi
if nolane_builder_out="$(reap_run --apply --include-builders 2>&1)"; then
  fail "#508 A-3: --include-builders must not open a lane-less --apply: $nolane_builder_out"
fi
nolane_dry="$(reap_run)" ||
  fail "#508 A-3: a lane-less dry run is still allowed"
grep -q '^would-close job=reap-ready ' <<<"$nolane_dry" ||
  fail "#508 A-3: a lane-less dry run must still list candidates: $nolane_dry"
grep -q 'Requires --lane' <<<"$("$WRK" reap --help)" ||
  fail "#508: reap --help must document that --apply requires --lane"
grep -q 'reclaimed-after-terminal' <<<"$("$WRK" reap --help)" ||
  fail "#508: reap --help must document the reclaimed-after-terminal rule"
grep -q 'tab-count-unknown' <<<"$("$WRK" reap --help)" ||
  fail "#508: reap --help must document the fail-closed tab rule"
echo "PASS reap-apply-requires-lane"

# #508 A-4: the normally finished builder shape stays reapable (no over-refusal),
# and without --include-builders it stays excluded exactly as before.
b505_default="$(reap_run --lane b505-lane)"
grep -q 'reap-b505-shape' <<<"$b505_default" &&
  fail "#508 A-4: a builder job must still be excluded without --include-builders: $b505_default"
b505_out="$(reap_run --lane b505-lane --include-builders)"
grep -q '^would-close job=reap-b505-shape pane=w1:p13 tab=w1:t13 status=idle' <<<"$b505_out" ||
  fail "#508 A-4: a normally finished builder (… joined → completed → lost) must stay a candidate with --include-builders: $b505_out"
echo "PASS reap-normal-builder-shape-still-reapable"

: >"$REAP_LOG"
receipt_out="$(reap_run --lane receipt-lane --apply)"
grep -q '^closed job=reap-mixed-receipt pane=w1:p15 tab=w1:t15 ' <<<"$receipt_out" ||
  fail "#508 R1: a respawn receipt without tab_id must resolve the live pane's own tab, not inherit the older spawn's tab: $receipt_out"
grep -q '^tab close w1:t14$' "$REAP_LOG" &&
  fail "#508 R1: the previous spawn's tab (w1:t14) must never be closed for a newer pane: $(cat "$REAP_LOG")"
grep -q '^skip job=reap-broken-newest reason=malformed-record$' <<<"$receipt_out" ||
  fail "#508 R1: a malformed newest receipt must be skipped, never patched from an older receipt: $receipt_out"
grep -q '^skip job=reap-moved pane=w1:p16 tab=w1:t17 reason=tab-mismatch(pane-in=w1:t16)$' <<<"$receipt_out" ||
  fail "#508 R1: a recorded tab that is not the pane's current tab must be skipped as tab-mismatch: $receipt_out"
grep -qE '^tab close w1:t1[67]$' "$REAP_LOG" &&
  fail "#508 R1: neither the recorded nor the actual tab of a moved pane may be closed: $(cat "$REAP_LOG")"
[[ "$(grep -c '^tab close ' "$REAP_LOG")" -eq 1 ]] ||
  fail "#508 R1: only the mixed-receipt job's own tab may be closed: $(cat "$REAP_LOG")"
echo "PASS reap-newest-receipt-and-tab-mismatch"

: >"$REAP_LOG"
race_out="$(WRK_FIXTURE_REAP_TABS=race reap_run --lane race-lane --apply)"
grep -q '^tab close' "$REAP_LOG" &&
  fail "#508 R1: a pane that joined the tab after the status probe must stop the close: $(cat "$REAP_LOG") / $race_out"
grep -q '^skip job=reap-race pane=w1:p18 tab=w1:t18 reason=tab-shared(panes=2)$' <<<"$race_out" ||
  fail "#508 R1: the tab list read right before the close must see the joined pane: $race_out"
python3 - "$REAP_LOG" <<'PY'
import sys
lines = [line.strip() for line in open(sys.argv[1])]
probe = lines.index("agent get w1:p18")
listing = [i for i, line in enumerate(lines) if line == "tab list"]
assert listing and max(listing) > probe, (
    "#508 R1: the tab list deciding the close must be read after the pane probe: %r" % lines)
PY
echo "PASS reap-tab-list-reread-before-close"

grep -q 'reap: 0 candidate' <<<"$(reap_run --lane lane-a --grace 2h)" ||
  fail "a terminal event younger than --grace is not yet reapable"
if reap_run --lane lane-a --grace 10min >/dev/null 2>&1; then
  fail "an unparsable --grace must fail loudly; falling back to 0 would reap with no grace at all"
fi
builder_out="$(reap_run --lane lane-a --include-builders)"
python3 - "$builder_out" <<'PY'
import sys
assert "would-close job=reap-builder " in sys.argv[1], sys.argv[1]
assert "would-close job=reap-captain-legacy " in sys.argv[1], sys.argv[1]
PY
grep -q 'would-close job=reap-builder ' <<<"$builder_out" ||
  fail "--include-builders must let a finished builder pane in this lane be reaped: $builder_out"
grep -q 'would-close job=reap-builder-reclaimed ' <<<"$builder_out" ||
  fail "--include-builders must reach the reclaimed builder too: $builder_out"
grep -q 'would-close job=reap-captain-legacy ' <<<"$builder_out" ||
  fail "--include-builders must include a legacy captain payload: $builder_out"
captain_out="$(reap_run --lane lane-a --include-captains)"
grep -q 'would-close job=reap-builder ' <<<"$captain_out" ||
  fail "--include-captains must remain an alias for --include-builders: $captain_out"
grep -q 'would-close job=reap-captain-legacy ' <<<"$captain_out" ||
  fail "--include-captains must include a legacy captain payload: $captain_out"
echo "PASS reap-builder-and-captain-alias-filters"

: >"$REAP_LOG"
apply_out="$(reap_run --lane lane-a --apply)"
grep -q '^closed job=reap-ready pane=w1:p1 tab=w1:t1 status=idle' <<<"$apply_out" ||
  fail "--apply must close the candidate tab: $apply_out"
grep -q '^closed job=reap-no-tab pane=w1:p5 tab=w1:t5 status=idle' <<<"$apply_out" ||
  fail "--apply must close the tab it resolved through 'agent get', by tab id: $apply_out"
grep -q '^closed job=reap-poisoned pane=w1:p8 tab=w1:t8 status=idle' <<<"$apply_out" ||
  fail "--apply must close the tab from the spawn receipt, not one read out of a poisoned record: $apply_out"
[[ "$(grep -c '^tab close ' "$REAP_LOG")" -eq 4 ]] ||
  fail "only the four candidates' tabs may be closed: $(cat "$REAP_LOG")"
grep -qE '^tab close w1:t1[01]$' "$REAP_LOG" &&
  fail "#508 A-1: --apply must never close the tab of a job picked up again after it finished: $(cat "$REAP_LOG")"
[[ "$(event_count "$REAP_INBOX/reap-revived/events" job.reaped)" -eq 0 ]] ||
  fail "#508 A-1: a reclaimed-after-terminal job must not be recorded as reaped"
grep -q 'tab close worker' "$REAP_LOG" &&
  fail "reap must never pass a role name to herdr tab close: $(cat "$REAP_LOG")"
grep -q '^tab close w1:t1$' "$REAP_LOG" ||
  fail "reap must close the tab_id recorded at spawn: $(cat "$REAP_LOG")"
grep -q '^tab close w1:t5$' "$REAP_LOG" ||
  fail "reap must close a resolved tab by its id, never by an age or a number: $(cat "$REAP_LOG")"
grep -qE '^tab close [0-9]+$' "$REAP_LOG" &&
  fail "a bare number is never a tab id; that is a live tab's number: $(cat "$REAP_LOG")"
grep -q 'tab close w1:t7' "$REAP_LOG" &&
  fail "a builder tab must never be closed by a plain --apply run: $(cat "$REAP_LOG")"
[[ "$(event_count "$REAP_INBOX/reap-builder-reclaimed/events" job.reaped)" -eq 0 ]] ||
  fail "a builder that was released and reclaimed without --role keeps its builder marking"
[[ "$(event_count "$REAP_INBOX/reap-builder/events" job.reaped)" -eq 0 ]] ||
  fail "a builder job in the reaped lane must not be reaped without --include-builders"
[[ "$(event_count "$REAP_INBOX/reap-captain-legacy/events" job.reaped)" -eq 0 ]] ||
  fail "a legacy captain payload in the reaped lane must not be reaped without --include-builders"
python3 - "$REAP_INBOX/reap-no-tab/events" <<'PY'
import glob, json, sys
event = json.load(open(sorted(glob.glob(sys.argv[1] + "/*job.reaped.json"))[0]))
assert event.get("tab_id") == "w1:t5", (
    "job.reaped must record the tab id that was actually closed, not an age: %r" % event)
PY
python3 - "$REAP_INBOX/reap-ready/events" <<'PY'
import glob, json, sys
paths = sorted(glob.glob(sys.argv[1] + "/*job.reaped.json"))
assert len(paths) == 1, "a closed job records exactly one flat job.reaped event, got %d" % len(paths)
event = json.load(open(paths[0]))
assert event.get("kind") == "job.reaped", event
assert event.get("pane_id") == "w1:p1", "job.reaped must record the reaped pane_id: %r" % event
assert event.get("tab_id") == "w1:t1", "job.reaped must record the closed tab_id: %r" % event
assert event.get("at"), "job.reaped must record when the tab was closed: %r" % event
PY
grep -q 'reap: 0 candidate' <<<"$(reap_run --lane lane-a)" ||
  fail "an already reaped job must never be offered again"
echo "PASS reap-apply-closes-tab-and-records-job-reaped"

# #603: a protected job (`wrk spawn --keep` → "keep": true on its job.spawned
# receipt) is never closed. It is reported once it would otherwise have been a
# candidate, and only a JSON true counts. The unprotected control shares the
# lane, pane state and age, so the skip is caused by the marker alone.
KEEP_REAP_INBOX="$TMP/reap-keep-inbox"
reap_keep_job() {
  local job="$1" pane="$2" tab="$3" receipt_extra="$4" now="$5"
  export ARBITER_TEST_NOW="$now"
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane keep-lane --agent-label "$job" --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"keep-lane\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"$receipt_extra}" >/dev/null
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"keep-lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  unset ARBITER_TEST_NOW
}
KEEP_FRESH_NOW="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat())')"
reap_keep_job reap-kept w1:p1 w1:t1 ',"keep":true' "$REAP_TEST_NOW"
reap_keep_job reap-kept-string w1:p5 w1:t5 ',"keep":"true"' "$REAP_TEST_NOW"
reap_keep_job reap-kept-fresh w1:p3 w1:t3 ',"keep":true' "$KEEP_FRESH_NOW"
reap_keep_job reap-unkept w1:p6 w1:t6 '' "$REAP_TEST_NOW"
# The marker is sticky on claims and reclaims too. arbiter never writes it
# there, so the fixture edits the real claim/reclaim event, like the legacy
# captain case above.
reap_keep_marked_event_job() {
  local job="$1" pane="$2" tab="$3" marked_kind="$4"
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane keep-lane --agent-label "$job" --t T1 >/dev/null
  if [[ "$marked_kind" == job.reclaim ]]; then
    env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" lease \
      --job "$job" --resource "$TMP/reap-$job" --kind path >/dev/null
    env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" release \
      --job "$job" --resource "$TMP/reap-$job" --kind path --force >/dev/null
    env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" claim --reclaim-released \
      --job "$job" --lane keep-lane --agent-label "$job" --t T1 >/dev/null
  fi
  python3 - "$KEEP_REAP_INBOX/$job/events" "$marked_kind" <<'PY'
import glob, json, sys
events, kind = sys.argv[1:3]
paths = sorted(glob.glob(events + "/*-" + kind + ".json"))
assert len(paths) == 1, (kind, paths)
event = json.load(open(paths[0]))
event["payload"]["keep"] = True
with open(paths[0], "w", encoding="utf-8") as handle:
    json.dump(event, handle, separators=(",", ":"))
    handle.write("\n")
PY
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"keep-lane\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}" >/dev/null
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"keep-lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  unset ARBITER_TEST_NOW
}
reap_keep_marked_event_job reap-kept-claim w1:p7 w1:t7 job.claim
reap_keep_marked_event_job reap-kept-reclaim w1:p8 w1:t8 job.reclaim
keep_reap_run() {
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" \
    WRK_FIXTURE_SCENARIO=reap WRK_FIXTURE_LOG="$REAP_LOG" "$WRK" reap "$@"
}
: >"$REAP_LOG"
keep_out="$(keep_reap_run --lane keep-lane)"
grep -q '^skip job=reap-kept reason=protected$' <<<"$keep_out" ||
  fail "#603: a kept job past its grace must be skipped with reason=protected: $keep_out"
grep -q '^would-close job=reap-kept ' <<<"$keep_out" &&
  fail "#603: a kept job must never be a reap candidate: $keep_out"
grep -q '^would-close job=reap-unkept pane=w1:p6 tab=w1:t6 status=idle' <<<"$keep_out" ||
  fail "#603: the unprotected control in the same lane must stay a candidate: $keep_out"
grep -q '^would-close job=reap-kept-string pane=w1:p5 tab=w1:t5 status=idle' <<<"$keep_out" ||
  fail "#603: only a JSON true protects; the string \"true\" is not a marker: $keep_out"
grep -q 'reap-kept-fresh' <<<"$keep_out" &&
  fail "#603: a kept job still inside its grace stays silent like any other: $keep_out"
for kept_job in reap-kept-claim reap-kept-reclaim; do
  grep -q "^skip job=$kept_job reason=protected$" <<<"$keep_out" ||
    fail "#603: keep on a claim or reclaim protects the job too ($kept_job): $keep_out"
done
: >"$REAP_LOG"
keep_apply_out="$(keep_reap_run --lane keep-lane --apply)"
grep -q '^tab close w1:t1$' "$REAP_LOG" &&
  fail "#603: --apply must never close a kept job's tab: $(cat "$REAP_LOG")"
for kept_job in reap-kept reap-kept-claim reap-kept-reclaim; do
  [[ "$(event_count "$KEEP_REAP_INBOX/$kept_job/events" job.reaped)" -eq 0 ]] ||
    fail "#603: a kept job must not be recorded as reaped ($kept_job)"
done
grep -qE '^tab close w1:t[78]$' "$REAP_LOG" &&
  fail "#603: --apply must never close a tab whose job was kept by its claim or reclaim: $(cat "$REAP_LOG")"
grep -q '^closed job=reap-unkept ' <<<"$keep_apply_out" ||
  fail "#603: --apply must still close the unprotected control: $keep_apply_out"
echo "PASS reap-skips-kept-jobs"

# ── #499: done/escalate/joined hand over to `panewire job` only when it exists ──
# Deployment order must not matter: with a panewire that lacks the command (or
# no panewire at all) wrk behaves exactly as before, and whichever path runs,
# each event is written once — never zero times, never twice.
J499_INBOX="$TMP/j499-inbox"
J499_REPORT="$TMP/j499-report.md"
printf 'j499 report line\n' >"$J499_REPORT"
j499_claim() {
  env ARBITER_INBOX_ROOT="$J499_INBOX" XDG_DATA_HOME="$TMP/xdg-j499" "$ARBITER" claim \
    --job "$1" --lane lane-a --agent-label wrk-a --t T1 "${@:2}" >/dev/null
  env ARBITER_INBOX_ROOT="$J499_INBOX" XDG_DATA_HOME="$TMP/xdg-j499" "$ARBITER" event \
    --job "$1" --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
}
j499_run() {  # j499_run DELEGATE JOB_MODE TAG wrk-args...
  local delegate="$1" mode="$2" tag="$3"
  shift 3
  env WRK_JOB_DELEGATE="$delegate" ARBITER_INBOX_ROOT="$J499_INBOX" HOSTNAME=fixture-host \
    WRK_PANEWIRE_JOB="$mode" WRK_PANEWIRE_LOG="$TMP/j499-$tag-emit.log" \
    WRK_PANEWIRE_JOB_LOG="$TMP/j499-$tag-job.log" "$WRK" "$@"
}
j499_lines() { if [[ -f "$1" ]]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }
j499_calls() { if [[ -f "$1" ]]; then grep -cx -- '--' "$1" || true; else echo 0; fi; }

# present: wrk hands the exact arguments over and writes nothing of its own.
j499_claim j499-worker
j499_claim j499-builder --role builder --parent-lane parent-a
out="$(j499_run 1 present present 'done' j499-worker --report "$J499_REPORT")"
[[ "$out" == "fixture job done j499-worker --report $J499_REPORT" ]] ||
  fail "delegated done must pass panewire's stdout through: $out"
j499_run 1 present present escalate j499-builder --question 'two  spaces "and" quotes' >/dev/null
j499_run 1 present present joined j499-builder --pr https://example.invalid/pr/9 --head beef \
  --report "$J499_REPORT" >/dev/null
diff "$TMP/j499-present-job.log" <(printf '%s\n' \
  "HOSTNAME=fixture-host [done] [j499-worker] [--report] [$J499_REPORT]" \
  'HOSTNAME=fixture-host [escalate] [j499-builder] [--question] [two  spaces "and" quotes]' \
  "HOSTNAME=fixture-host [joined] [j499-builder] [--pr] [https://example.invalid/pr/9] [--head] [beef] [--report] [$J499_REPORT]") ||
  fail "delegation must hand panewire job the unmodified arguments"
[[ "$(event_count "$J499_INBOX/j499-worker/events" job.completed)" == 0 ]] ||
  fail "delegated done must not also write wrk's record"
[[ "$(event_count "$J499_INBOX/j499-builder/events" job.escalate)" == 0 ]] ||
  fail "delegated escalate must not also write wrk's record"
[[ "$(event_count "$J499_INBOX/j499-builder/events" job.joined)" == 0 ]] ||
  fail "delegated joined must not also write wrk's record"
[[ "$(j499_calls "$TMP/j499-present-emit.log")" == 0 ]] ||
  fail "delegated commands must not also run wrk's emit"
# A failing delegated call surfaces its own status and wrk does not retry it.
rc=0
WRK_PANEWIRE_JOB_RC=7 j499_run 1 present rc 'done' j499-worker --report "$J499_REPORT" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 7 ]] || fail "a failing panewire job must surface its own status, got rc=$rc"
[[ "$(event_count "$J499_INBOX/j499-worker/events" job.completed)" == 0 &&
   "$(j499_calls "$TMP/j499-rc-emit.log")" == 0 ]] ||
  fail "a failing panewire job must not fall back to a second write"
# Help stays wrk's own even when panewire has the command.
j499_run 1 present help escalate --help | grep -q '^Usage: wrk escalate JOB' ||
  fail "escalate --help must stay local"
[[ "$(j499_lines "$TMP/j499-help-job.log")" == 0 ]] || fail "escalate --help must not delegate"
echo "PASS j499-delegates-once-to-panewire-job"

# absent / garbage / hang / forced off: wrk's own path, exactly one record and
# one emit per command, zero delegated calls.
for mode in absent garbage hang off; do
  job_mode="$mode" delegate=1
  if [[ "$mode" == off ]]; then job_mode=present delegate=0; fi
  worker="j499-$mode-worker" builder="j499-$mode-builder"
  j499_claim "$worker"
  j499_claim "$builder" --role builder --parent-lane parent-a
  out="$(j499_run "$delegate" "$job_mode" "$mode" 'done' "$worker" --report "$J499_REPORT")"
  [[ "$out" == "OK job=$worker report=$J499_REPORT" ]] || fail "$mode: done output changed: $out"
  out="$(j499_run "$delegate" "$job_mode" "$mode" escalate "$builder" --question 'fallback question')"
  [[ "$out" == "OK job=$builder owner_lane=lane-a kind=job.escalate" ]] || fail "$mode: escalate output changed: $out"
  out="$(j499_run "$delegate" "$job_mode" "$mode" joined "$builder" --pr https://example.invalid/pr/8 \
    --head f00d --report "$J499_REPORT")"
  [[ "$out" == "OK job=$builder owner_lane=lane-a kind=job.joined pr=https://example.invalid/pr/8 head=f00d report=$J499_REPORT" ]] ||
    fail "$mode: joined output changed: $out"
  [[ "$(event_count "$J499_INBOX/$worker/events" job.completed)" == 1 ]] || fail "$mode: done must write exactly one record"
  [[ "$(event_count "$J499_INBOX/$builder/events" job.escalate)" == 1 ]] || fail "$mode: escalate must write exactly one record"
  [[ "$(event_count "$J499_INBOX/$builder/events" job.joined)" == 1 ]] || fail "$mode: joined must write exactly one record"
  [[ "$(j499_calls "$TMP/j499-$mode-emit.log")" == 3 ]] || fail "$mode: each command must emit exactly once"
  [[ "$(j499_lines "$TMP/j499-$mode-job.log")" == 0 ]] || fail "$mode: nothing may be delegated"
  [[ ! -e "$J499_INBOX/$worker/emit-failures.log" ]] || fail "$mode: a clean fallback must leave no emit failure"
  PYTHONPATH="$TMP" python3 - "$TMP/j499-$mode-emit.log" "$J499_INBOX/$worker/events" "$J499_INBOX/$builder/events" <<'PY'
import sys
import r20_emit as helper
log, worker, builder = sys.argv[1:]
done_call, escalate_call, joined_call = helper.calls(log)
helper.assert_matches_record(done_call, helper.record(worker, "job.completed"))
helper.assert_matches_record(escalate_call, helper.record(builder, "job.escalate"))
helper.assert_matches_record(joined_call, helper.record(builder, "job.joined"))
PY
done
echo "PASS j499-falls-back-to-own-path-without-panewire-job"

# no binary: wrk's own record, and the missing emit is marked exactly as before.
j499_claim j499-nobin-worker
out="$(env ARBITER_INBOX_ROOT="$J499_INBOX" HOSTNAME=fixture-host PANEWIRE_BIN="$TMP/no-such-panewire" \
  "$WRK" 'done' j499-nobin-worker --report "$J499_REPORT" 2>/dev/null)"
[[ "$out" == "OK job=j499-nobin-worker report=$J499_REPORT" ]] || fail "no panewire: done output changed: $out"
[[ "$(event_count "$J499_INBOX/j499-nobin-worker/events" job.completed)" == 1 ]] ||
  fail "no panewire: done must write exactly one record"
grep -Eq '^[0-9TZ:-]+ kind=job.completed rc=not_found$' "$J499_INBOX/j499-nobin-worker/emit-failures.log" ||
  fail "no panewire: the missing emit must still be marked"
echo "PASS j499-no-panewire-binary-keeps-own-path"

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
