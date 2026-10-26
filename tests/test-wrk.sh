#!/usr/bin/env bash
set -euo pipefail
# hk 1894: trust-bearing wrk and arbiter commands honour this suite's temp-dir overrides
# (HOME, ARBITER_INBOX_ROOT, XDG_DATA_HOME, HANDOFFKEEP_BIN) only in test mode.
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="$ROOT/bin/arbiter"
TMP="$(mktemp -d)"
# shellcheck disable=SC1091
. "$ROOT/tests/lib/tmp-writers.sh"
export TW_TMP="$TMP"
# OWNED_PIDS — every background pid this file launches registers here; the
# teardown's *.pids registry pass signals exactly that set (direct `wrk
# sentinel … &` runs carry no pidfile of their own).
OWNED_PIDS="$TMP/owned.pids"; : >"$OWNED_PIDS"
own() { [[ "$1" =~ ^[0-9]+$ ]] || return 0; tw_register_pid "$OWNED_PIDS" "$1"; }
# spawn 이 띄운 센티널은 nohup 으로 분리되어 있다 — 스위트가 끝나면 그 자식
# (interval 동안 살아남는 sleep)과 함께 거둔다. 센티널만 죽이면 sleep 이 orphan
# 으로 남아 잡 디렉토리의 flock fd 를 interval 내내 잡고 있는다(#637, #682).
# tests/lib/tmp-writers.sh 가 pidfile·레지스트리·자식 walk·test-owned 그룹
# 만으로 각 writer 를 정확한 pid 로 거둔다 — 다른 프로세스의 환경을 읽거나
# 패턴 매치로 죽이지 않는다.
cleanup() {
  local tw_rc=0
  tmp_writers_stop || tw_rc=$?
  # A refused or unkillable tracked writer keeps TMP and fails the suite —
  # never rm -rf while one lives.
  (( tw_rc == 0 )) && rm -rf "$TMP"
  # 회귀 게이트: teardown 이 추적한 writer 를 놓치면 조용히 새는 게 아니라
  # 스위트가 실패해야 한다.
  if [[ "$tw_rc" -ne 0 || -n "${TW_LEFTOVER_PIDS:-}" ]]; then
    echo "FAIL: tracked writers survived teardown:${TW_LEFTOVER_PIDS:-}" >&2
    exit 1
  fi
}
trap cleanup EXIT
PROMPT="$TMP/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"

# ROB-1252: cc-qwen38/cc-glm read the clinepass gate key from this file at
# spawn time (never from ~/.claude/); point it at a harmless fixture value.
export CLINEPASS_GATE_KEY_FILE="$TMP/clinepass-gate-key.txt"
printf 'fixture-gate-key\n' >"$CLINEPASS_GATE_KEY_FILE"

# hk 1449: a builder join needs one non-voided recorded round. The seed file's
# name is not a numeric prefix, so event numbering stays on the golden names.
seed_join_round() {
  local root="$1" job="$2"
  local events="$root/$job/events"
  mkdir -p "$events"
  if [[ -e "$events/seed-job.round.json" ]]; then
    return 0
  fi
  printf '%s\n' "{\"kind\":\"job.round\",\"job_id\":\"$job\",\"round\":1,\"head\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}" >"$events/seed-job.round.json"
  # hk 1900: a round counts toward the join only with a recorded verdict.
  printf '%s\n' "{\"kind\":\"job.verdict\",\"job_id\":\"$job\",\"round\":1,\"head\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"verdict\":\"PASS\"}" >"$events/seed-job.verdict.json"
}

# ROB-1199: the suite must never reach a real arbiter state db or the real inbox.
# ARBITER_BIN points at nothing by default, so every pre-existing case keeps
# exercising the installation-transition path; the arbiter section below opts in.
export ARBITER_BIN="$TMP/absent-arbiter"
# hk 1439: the suite never reaches the real scopefuel through bin/arbiter's PATH
# fallback (scopefuel_bin). SCOPEFUEL_BIN is suite-wide; per-command overrides stay.
# Tripwire: scopefuel/devin/kimi shims sit first on PATH, log their argv and exit 99,
# and the end-of-suite check fails on any logged call. Every PATH edit below only
# prepends, so the shim dir stays reachable.
export SCOPEFUEL_BIN="$SCOPEFUEL"
TRIPWIRE_LOG="$TMP/tripwire.log"; : >"$TRIPWIRE_LOG"
export TRIPWIRE_LOG
mkdir -p "$TMP/tripwire-bin"
for tw_name in scopefuel devin kimi; do
  printf '%s\n' '#!/bin/sh' \
    "printf '%s\\n' \"$tw_name \$*\" >>\"\$TRIPWIRE_LOG\"" 'exit 99' >"$TMP/tripwire-bin/$tw_name"
  chmod +x "$TMP/tripwire-bin/$tw_name"
done
export PATH="$TMP/tripwire-bin:$PATH"
export XDG_DATA_HOME="$TMP/xdg"
export XDG_CACHE_HOME="$TMP/xdg-cache"
export XDG_CONFIG_HOME="$TMP/xdg-config"
export XDG_STATE_HOME="$TMP/xdg-state"
mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
# #951: claude-kind spawns seed folder trust into ${CLAUDE_CONFIG_DIR:-$HOME}/
# .claude.json — the operator's real config must never be touched by a fixture
# spawn, so suite HOME is a fixture and ambient CLAUDE_CONFIG_DIR is unset (it
# would relocate the store; the dedicated #951 cases set it explicitly).
export HOME="$TMP/home"
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR
# #912: devin-kind spawns register the spawn cwd in devin's trusted-workspaces
# store ($XDG_DATA_HOME/devin/cli/trusted_workspaces.json) before any pane
# exists, and refuse closed when the store is missing or corrupt. Seed the
# fixture store with $ROOT so every spawn_base devin case below is a covered
# no-op; the dedicated #912 cases run against their own fixture XDG roots.
mkdir -p "$XDG_DATA_HOME/devin/cli"
python3 - "$XDG_DATA_HOME/devin/cli/trusted_workspaces.json" "$ROOT" <<'PY'
import json, sys
json.dump({"trusted_paths": [sys.argv[2]]}, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY
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

# Document uploads are also opt-in below; the R21 section installs its own
# scripted handoffkeep. #768 made every spawn bind a task, so the spawn paths
# point at the deterministic fixture: pre-existing cases inherit one seeded
# suite task through HK_TASK_ID (the same env a spawned pane receives), while
# spawn_base mints a fresh --task per call so owner-mode claims run for real.
export HANDOFFKEEP_BIN="$ROOT/tests/fixtures/handoffkeep"
export HK_STATE="$TMP/hk-state.json"
export HK_TASK_ID=76801
"$HANDOFFKEEP_BIN" tasks add --id "$HK_TASK_ID" --title "suite-inherited-task" --lane fixture >/dev/null
# Pre-mint the owner-mode task pool: spawn_base only bumps the counter file,
# never calls the fixture at spawn time — some cases stub python3 (the fixture
# is python) to probe the awk TOML fallback, and minting must not die there.
python3 - "$HK_STATE" <<'PY'
import json, sys
path = sys.argv[1]
try:
    state = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    state = {"tasks": {}}
for i in range(768001, 769200):
    state["tasks"][str(i)] = {
        "id": i, "lane": "", "title": "spawn-base pool", "kind": "implement",
        "state": "backlog", "priority": 0, "refs": {}, "claimed_by": "",
        "created_by": "fixture", "created_at": "2026-01-01T00:00:00+00:00",
        "updated_at": "2026-01-01T00:00:00+00:00", "events": []}
json.dump(state, open(path, "w", encoding="utf-8"))
PY

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

# mint_task — next id from the pre-minted pool. File-backed so it survives the
# command-substitution subshells most spawn callers use.
mint_task() {
  local id=$(( $(cat "$TMP/mint-seq" 2>/dev/null || echo 768000) + 1 ))
  # The fixture pool above pre-mints 768001-769199 only; an id past it mints
  # a task that does not exist and the failure surfaces as a swallowed rc 2
  # in a later spawn, far from the real cause — stop loudly instead (#1010/N7).
  (( id <= 769199 )) ||
    fail "mint_task: task pool exhausted (id $id exceeds the pre-minted 768001-769199 range)"
  printf '%s\n' "$id" >"$TMP/mint-seq"
  printf '%s\n' "$id"
}

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
track_test_spawn_sentinel() {
  local job="$1" jobdir="$ARBITER_INBOX_ROOT/$1"
  local pidfile="$jobdir/completion-sentinel.pid" pid="" attempt
  [[ -s "$pidfile" ]] || { echo "expected sentinel pidfile for $job" >&2; return 1; }
  IFS= read -r pid <"$pidfile" || { echo "could not read sentinel pid for $job" >&2; return 1; }
  [[ "$pid" =~ ^[0123456789]+$ ]] || { echo "malformed sentinel pid for $job" >&2; return 1; }
  for ((attempt = 0; attempt < 50; attempt++)); do
    _tw_pid_alive "$pid" || return 0
    if _tw_sentinel_argv_ok "$pid" "$job" "$jobdir"; then
      # Fake-clock cases intentionally make the pidfile's started= fail the
      # production age check. Capture this exact test-owned PID's real start
      # identity and process group so teardown can reap its detached session.
      tw_register_pid "$OWNED_PIDS" "$pid"
      return
    fi
    sleep 0.2
  done
  echo "sentinel $pid for $job stayed alive without its final argv" >&2
  return 1
}

spawn_base() {
  local model="$1"; shift
  local extra=("$@")
  local spawn_rc=0 session_job="" session_pid="" i
  local -a spawn_cmd=()
  # The fake clock records started=1000, which correctly fails the real
  # process-start check. In the opt-in cases, the self-recorded session
  # keeps the orphan sentinel owned independently of that pidfile.
  case " ${extra[*]-} " in *" --t "*) ;; *) extra+=(--t T1) ;; esac
  # #768: every spawn binds an hk task. Mint a fresh fixture task per spawn so
  # owner-mode claims stay claimable; a case that supplies --task/--parent-job
  # or unsets the task entirely (TEST_NO_TASK=1, e.g. usage-error probes)
  # overrides this.
  case " ${extra[*]-} " in
    *" --task "*|*" --parent-job "*) ;;
    *)
      if [[ -z "${TEST_NO_TASK:-}" ]]; then
        SPAWN_BASE_TASK="$(mint_task)"
        extra+=(--task "$SPAWN_BASE_TASK")
      fi ;;
  esac
  # Record the effective --task each call carries. spawn_base often runs
  # inside $(...), so a global is lost to the parent shell — a log file is
  # the subshell-safe channel (tail -1 after a call = that call's task).
  local resolved_task=""
  for ((i = 0; i < ${#extra[@]}; i++)); do
    [[ "${extra[$i]}" == "--task" ]] && resolved_task="${extra[$((i + 1))]}"
    if [[ "${extra[$i]}" == "--job" && $((i + 1)) -lt ${#extra[@]} ]]; then
      session_job="${extra[$((i + 1))]}"
    fi
  done
  [[ -n "$resolved_task" ]] && printf '%s\n' "$resolved_task" >>"$TMP/spawn-task.log"
  # A registered job leaves a detached sentinel behind, and that sentinel keeps
  # calling the fixture herdr — which appends every invocation to the shared
  # WRK_FIXTURE_LOG. At the default 30s interval one of those probes lands, about
  # once in three runs, between a case's `rm -f "$TMP/herdr.log"` and its
  # `[[ ! -e "$TMP/herdr.log" ]]`, and the suite dies there with no message.
  # Park the probes past the end of the run instead.
  spawn_cmd=(env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="${TEST_ARBITER_BIN:-$TMP/absent-arbiter}" \
    WRK_COMPLETION_INTERVAL_S="${WRK_COMPLETION_INTERVAL_S:-3600}" \
    WRK_FIXTURE_SCENARIO="${TEST_FIXTURE_SCENARIO:-spawn}" WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_FIXTURE_MARKER="${WRK_FIXTURE_MARKER:-}" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S="${WRK_REFRESH_TIMEOUT_S:-5}" \
    "${WRK_UNDER_TEST:-$WRK}" spawn \
    -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture "${extra[@]}")
  if [[ "${TEST_OWN_SESSION:-0}" == 1 ]]; then
    tw_own_session "${spawn_cmd[@]}" &
    session_pid=$!
    if wait "$session_pid"; then
      :
    else
      spawn_rc=$?
    fi
  elif "${spawn_cmd[@]}"; then
    :
  else
    spawn_rc=$?
  fi
  if [[ "${TEST_OWN_SESSION:-0}" == 1 && -n "$session_job" ]]; then
    track_test_spawn_sentinel "$session_job" || return 1
  fi
  return "$spawn_rc"
}

run_terra_refusal_tests() {
# ROB-1190 ④-2: wrk profiles — 기계 판독 가능한 프로필 목록. oc-omni 가 포함돼야 한다
# (드리프트 방지: scopefuel 이 추천하는데 wrk 가 못 띄우는 상태 방지).
profiles_out="$("$WRK" profiles)"
grep -qx 'oc-omni' <<<"$profiles_out"
grep -qx 'oc-solar4' <<<"$profiles_out"
grep -qx 'kimi-k3' <<<"$profiles_out"
grep -qx 'kimi-k27' <<<"$profiles_out"
grep -qx 'kimi-k27-code' <<<"$profiles_out"
grep -qx 'kimi-k3-low' <<<"$profiles_out"
grep -qx 'codex-luna-max' <<<"$profiles_out"
for barred_profile in codex-terra codex-terra-max codex-med \
  builder-terra-high builder-terra-xhigh builder-terra-max; do
  if grep -qx "$barred_profile" <<<"$profiles_out"; then
    fail "wrk profiles must omit barred profile $barred_profile"
  fi
done
profiles_help_out="$($WRK profiles --help)"
grep -q 'operator 2026-10-12 noterra' <<<"$profiles_help_out" ||
  fail "wrk profiles --help must name the Terra refusal decision"
grep -qx 'builder-opus' <<<"$profiles_out"
grep -qx 'builder-sol' <<<"$profiles_out"
grep -qx 'builder-devin' <<<"$profiles_out"
grep -qx 'builder-devin-medium' <<<"$profiles_out"
grep -qx 'builder-devin-max' <<<"$profiles_out"
grep -qx 'builder-ds41' <<<"$profiles_out"
grep -qx 'builder-ds41-max' <<<"$profiles_out"
grep -qx 'builder-grok' <<<"$profiles_out"
grep -qx 'builder-kimi' <<<"$profiles_out"
grep -qx 'builder-luna' <<<"$profiles_out"
grep -qx 'builder-sonnet' <<<"$profiles_out" ||
  fail "wrk profiles lost builder-sonnet (#921)"
# #704 (#594 E6) + #737 (decision 4088) + hk 1796: the per-rung builder spellings.
for e6_profile in builder-opus-low builder-opus-medium builder-sonnet-xhigh builder-sonnet-max \
  builder-sol-high builder-sol-max builder-sol-medium builder-luna-max \
  builder-kimi-high builder-kimi-max \
  builder-grok-low builder-grok-medium builder-grok-xhigh \
  builder-sonnet-medium builder-haiku-low builder-luna-low builder-luna-medium \
  builder-sol-low builder-haiku-high builder-haiku-xhigh builder-haiku-max builder-sonnet-low; do
  grep -qx "$e6_profile" <<<"$profiles_out" || fail "wrk profiles lost $e6_profile"
done
# hk 2043: builder-sol-xhigh is a normal pinned spelling (no E6 marker),
# builder-luna-high is the luna family's high E6 rung and builder-haiku-medium
# is the haiku family's medium E6 rung.
for pinned_profile in builder-sol-xhigh builder-luna-high builder-haiku-medium; do
  grep -qx "$pinned_profile" <<<"$profiles_out" || fail "wrk profiles lost $pinned_profile"
done
grep -qx 'captain-opus' <<<"$profiles_out"
grep -qx 'captain-sol' <<<"$profiles_out"
grep -qx 'codex-astra' <<<"$profiles_out"
# ROB-591 rollback spellings (gpt-5.6-sol/gpt-5.6-luna) must remain spawnable.
grep -qx 'codex-sol56' <<<"$profiles_out"
grep -qx 'codex-luna56' <<<"$profiles_out"
# #1026 rollback spellings (gpt-6-sol) join the same list.
grep -qx 'codex-sol6' <<<"$profiles_out"
grep -qx 'builder-sol6' <<<"$profiles_out"
# task #526: the astra builder spellings were removed — astra is counsel-only
# (hk:doc decision/2026-09-21/astra-allowed-purposes-approved).
if grep -qx 'builder-astra' <<<"$profiles_out"; then exit 1; fi
if grep -qx 'captain-astra' <<<"$profiles_out"; then exit 1; fi
[[ "$(grep -xc 'devin-swe2' <<<"$profiles_out")" -eq 1 ]]
grep -qx 'devin-glm52' <<<"$profiles_out"
grep -qx 'devin-swe17' <<<"$profiles_out"
grep -qx 'devin-ds41' <<<"$profiles_out"
# #635: the devin effort rungs are named profiles (effort sits inside the
# devin model id — no --effort flag exists). The scopefuel catalog lists all
# three, so the wrk⊇scopefuel cross-check needs them here.
grep -qx 'devin-swe2-medium' <<<"$profiles_out"
grep -qx 'devin-swe2-max' <<<"$profiles_out"
grep -qx 'devin-ds41-max' <<<"$profiles_out"
# hk 1380: the paid fusion spellings (operator decision 2026-10-10) must be
# spawnable profiles — worker/tester-only, no builder-* variants.
grep -qx 'devin-fusion-opus55' <<<"$profiles_out"
grep -qx 'devin-fusion-sonnet55' <<<"$profiles_out"
if grep -qx 'builder-fusion-opus55' <<<"$profiles_out"; then exit 1; fi
if grep -qx 'builder-fusion-sonnet55' <<<"$profiles_out"; then exit 1; fi
if grep -qx 'codex-ultra' <<<"$profiles_out"; then exit 1; fi
if grep -qx 'codex-luna-ultra' <<<"$profiles_out"; then exit 1; fi

# T-A1/T-A2: every Terra spelling refuses before quota, arbiter, task claim,
# worktree, pane, or hub work. Only fixture agent binaries are reachable here.
TERRA_PROBE_SEQ=0
terra_refusal_probe() {
  local executable="$1" profile="$2" role_path="$3" case_name="$4"
  local profile_flag="${5:--m}" expected_model="${6:-gpt-5.6-terra}" extra_opt="${7:-}"
  local root="$TMP/noterra/$case_name" home data cache config state inbox
  local out err herdr_log scopefuel_log panewire_log db before_tree after_tree before_hk after_hk task_id job rc=0
  TERRA_PROBE_SEQ=$((TERRA_PROBE_SEQ + 1))
  mkdir -p "$root"; home="$root/home"; data="$root/data"; cache="$root/cache"
  config="$root/config"; state="$root/state"; inbox="$root/inbox/jobs"
  mkdir -p "$home" "$data" "$cache" "$config" "$state" "$inbox"
  out="$root/out"; err="$root/err"; herdr_log="$root/herdr.log"
  scopefuel_log="$root/scopefuel.log"; panewire_log="$root/panewire.log"
  : >"$herdr_log"; : >"$scopefuel_log"; : >"$panewire_log"
  before_tree="$(git -C "$ROOT" worktree list --porcelain | sha256sum | awk '{print $1}')"
  before_hk="$(sha256sum "$HK_STATE" | awk '{print $1}')"
  task_id="$(mint_task)"; job="noterra-$case_name"
  local args=(spawn -c "$ROOT" "$profile_flag" "$profile" -p "$PROMPT" -w w -l "nr-$TERRA_PROBE_SEQ" --t T1 --job "$job")
  case "$role_path" in
    worker) args+=(--role worker --task "$task_id") ;;
    builder) args+=(--role builder --lane "nr-lane-$TERRA_PROBE_SEQ" --parent parent-lane --task "$task_id") ;;
    tester) args+=(--parent-job "$HK_TASK_ID") ;;
    counsel) args+=(--role counsel) ;;
    *) return 1 ;;
  esac
  if [[ -n "$extra_opt" ]]; then
    local extra_arr=()
    read -ra extra_arr <<<"$extra_opt"
    args+=("${extra_arr[@]}")
  fi
  set +e
  env HOME="$home" XDG_DATA_HOME="$data" XDG_CACHE_HOME="$cache" \
    XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
    HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$inbox" HANDOFFKEEP_BIN="$HANDOFFKEEP_BIN" HK_STATE="$HK_STATE" \
    PANEWIRE_BIN="$PANEWIRE" WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$herdr_log" \
    WRK_SCOPEFUEL_LOG="$scopefuel_log" WRK_PANEWIRE_LOG="$panewire_log" \
    "$executable" "${args[@]}" >"$out" 2>"$err"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || { echo "T-A1 $profile/$role_path unexpectedly spawned" >&2; return 1; }
  db="$data/arbiter/state.db"
  python3 - "$db" <<'PY' || { echo "T-A1 arbiter gained a job or quota record" >&2; return 1; }
import pathlib, sqlite3, sys
path = pathlib.Path(sys.argv[1])
if path.exists():
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        assert con.execute("SELECT COUNT(*) FROM jobs").fetchone()[0] == 0
        assert con.execute("SELECT COUNT(*) FROM quota_pool_records").fetchone()[0] == 0
    finally:
        con.close()
PY
  [[ ! -s "$herdr_log" && ! -s "$scopefuel_log" && ! -s "$panewire_log" ]] || { echo "T-A1 fixture was called for $profile/$role_path" >&2; return 1; }
  [[ "$(wc -l <"$err" | tr -d ' ')" == 1 ]] || { echo "T-A1 expected one stderr line for $profile/$role_path: $(<"$err")" >&2; return 1; }
  grep -q "profile $profile refused: $expected_model is barred" "$err" || { echo "T-A1 missing named refusal: $(<"$err")" >&2; return 1; }
  grep -q 'operator 2026-10-12 noterra; use codex-sol or codex-luna' "$err" || { echo "T-A1 missing decision/replacements: $(<"$err")" >&2; return 1; }
  [[ -z "$(find "$inbox" -type f -print -quit)" ]] || { echo "T-A1 inbox changed for $profile/$role_path" >&2; return 1; }
  after_tree="$(git -C "$ROOT" worktree list --porcelain | sha256sum | awk '{print $1}')"
  [[ "$before_tree" == "$after_tree" ]] || { echo "T-A1 worktree set changed for $profile/$role_path" >&2; return 1; }
  after_hk="$(sha256sum "$HK_STATE" | awk '{print $1}')"
  [[ "$before_hk" == "$after_hk" ]] || { echo "T-A1 task store changed for $profile/$role_path" >&2; return 1; }
}

for barred_profile in codex-terra codex-terra-max codex-med \
  builder-terra-high builder-terra-xhigh builder-terra-max; do
  for refusal_path in worker builder tester; do
    terra_refusal_probe "$WRK" "$barred_profile" "$refusal_path" \
      "known-${barred_profile}-${refusal_path}" || fail "T-A1 refused $barred_profile/$refusal_path with no side effects"
  done
  terra_refusal_probe "$WRK" "$barred_profile" tester \
    "profile-option-${barred_profile}" --profile ||
    fail "T-A1 --profile refused $barred_profile tester path with no side effects"
done
echo "PASS T-A1: all six Terra spellings refuse worker/builder/tester paths via -m and tester --profile before side effects"
SCOPEFUEL_E6_ARM=codex-terra@high terra_refusal_probe "$WRK" codex-terra worker e6-arm-codex ||
  fail "T-A2 codex-terra@high arm must be refused before side effects"
SCOPEFUEL_E6_ARM=codex-terra@high terra_refusal_probe "$WRK" builder-terra-high builder e6-arm-builder ||
  fail "T-A2 builder-terra-high arm must be refused before side effects"
echo "PASS T-A2: Terra E6 markers cannot reach gate or spawn"

# T-A1 model-id guard pin: inject an unlisted alias into a throwaway wrk copy.
# The alias resolves to gpt-9.9-terra — a terra model id the original
# gpt-5.6-terra-only enumeration did not know — and gets no catalog mapping, so
# the resolver literal is exactly the model id the guard sees. A guard that
# matches only the enumerated literal spawns it: this is the hk 1810 gap.
make_future_terra_wrk() {
  local output="$1" move_after_claim="${2:-0}"
  python3 - "$WRK" "$output" "$move_after_claim" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
dst = Path(sys.argv[2])
dst.parent.mkdir(parents=True, exist_ok=True)
replacements = (
    ("codex-terra|codex-med) PROFILE_KIND=codex; PROFILE_MODEL=gpt-5.6-terra; DEFAULT_EFFORT=medium; EFFORT_SUPPORTED=1 ;;",
     "codex-terra|codex-med) PROFILE_KIND=codex; PROFILE_MODEL=gpt-5.6-terra; DEFAULT_EFFORT=medium; EFFORT_SUPPORTED=1 ;;\n    future-terra-alias) PROFILE_KIND=codex; PROFILE_MODEL=gpt-9.9-terra; DEFAULT_EFFORT=medium; EFFORT_SUPPORTED=1 ;;"),
    ("codex-terra|codex-med|codex-terra-max) GATE_PROFILE=codex-terra-max ;;",
     "codex-terra|codex-med|codex-terra-max|future-terra-alias) GATE_PROFILE=codex-terra-max ;;"),
)
for old, new in replacements:
    if src.count(old) != 1:
        raise SystemExit(f"expected one resolver clause: {old}")
    src = src.replace(old, new, 1)
if sys.argv[3] == "1":
    guard = '  refuse_barred_launcher_model\n'
    claim = '  arbiter_admit\n'
    if src.count(guard) != 1 or src.count(claim) != 1:
        raise SystemExit("resolved guard or arbiter admission call is not unique")
    src = src.replace(guard, "", 1).replace(claim, claim + guard, 1)
dst.write_text(src)
dst.chmod(0o755)
PY
}
FUTURE_TERRA_WRK="$TMP/noterra/future-terra-wrk"
make_future_terra_wrk "$FUTURE_TERRA_WRK"
terra_refusal_probe "$FUTURE_TERRA_WRK" future-terra-alias worker model-id-alias -m gpt-9.9-terra ||
  fail "T-A1 model-id guard must refuse a future alias that resolves to Terra"
echo "PASS T-A1 model-id pin: unlisted Terra-resolving alias is refused"
# The same bar holds when the canon — not the resolver table — is what hands a
# non-Terra spelling a terra model id (WRK_LAUNCH_MODEL_OVERRIDE on the fixture
# scopefuel is the catalog injection surface, hk 1810 repro).
WRK_LAUNCH_MODEL_OVERRIDE=gpt-9.9-terra \
  terra_refusal_probe "$WRK" codex-luna worker catalog-terra-override -m gpt-9.9-terra ||
  fail "T-A1 catalog-served terra model id must be refused for a non-Terra spelling"
echo "PASS T-A1 catalog pin: a canon-served Terra model id is refused on codex-luna"
# The bar also covers the non-codex launch channels: grok consumes the canon
# model id via PROFILE_MODEL_ARG -> argv -m, fable via --model in ARGS.
WRK_LAUNCH_MODEL_OVERRIDE=gpt-9.9-terra \
  terra_refusal_probe "$WRK" grok-hi worker catalog-terra-grok -m gpt-9.9-terra ||
  fail "T-A1 catalog-served terra model id must be refused on the grok argv channel"
echo "PASS T-A1 catalog pin: a canon-served Terra model id is refused on grok-hi"
WRK_LAUNCH_MODEL_OVERRIDE=gpt-9.9-terra \
  terra_refusal_probe "$WRK" fable counsel catalog-terra-fable -m gpt-9.9-terra "--operator-request hk:doc/decision/2026-09-21/astra-allowed-purposes-approved" ||
  fail "T-A1 catalog-served terra model id must be refused on the fable ARGS channel"
echo "PASS T-A1 catalog pin: a canon-served Terra model id is refused on fable"

# Named mutants: dropping the model-id check, moving it beyond arbiter
# admission, or re-narrowing it to the old literal enumeration must each make a
# named probe assertion red. Probe output is captured per mutant and the
# specific tripped assertion is pinned — a probe that dies on an unrelated
# check (syntax error, missing refusal text) cannot count as a caught mutant,
# and expected-RED diagnostics stop leaking into passing logs looking like a
# real failed assertion. Only fixtures are reachable.
expect_probe_red() {
  local log="$1" want_line="$2" label="$3"
  grep -qF "$want_line" "$log" ||
    fail "$label must trip the '$want_line' assertion, not a different check: $(<"$log")"
}

M1_FUTURE_TERRA_WRK="$TMP/noterra/m1-no-model-check-wrk"
python3 - "$FUTURE_TERRA_WRK" "$M1_FUTURE_TERRA_WRK" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
guard = '  refuse_barred_launcher_model\n'
if src.count(guard) != 1:
    raise SystemExit("m1 target guard is not unique")
Path(sys.argv[2]).write_text(src.replace(guard, "", 1))
Path(sys.argv[2]).chmod(0o755)
PY
m1_probe_log="$TMP/noterra/m1-probe.log"
if terra_refusal_probe "$M1_FUTURE_TERRA_WRK" future-terra-alias worker mutant-m1 -m gpt-9.9-terra >"$m1_probe_log" 2>&1; then
  fail "m1 mutant survived the resolved-model refusal pin"
fi
expect_probe_red "$m1_probe_log" "T-A1 future-terra-alias/worker unexpectedly spawned" "mutant m1"
echo "PASS mutant m1: resolved-model refusal assertion goes RED"

M2_FUTURE_TERRA_WRK="$TMP/noterra/m2-post-claim-wrk"
make_future_terra_wrk "$M2_FUTURE_TERRA_WRK" 1
m2_probe_log="$TMP/noterra/m2-probe.log"
if terra_refusal_probe "$M2_FUTURE_TERRA_WRK" future-terra-alias worker mutant-m2 -m gpt-9.9-terra >"$m2_probe_log" 2>&1; then
  fail "m2 mutant survived the no-side-effect refusal pin"
fi
expect_probe_red "$m2_probe_log" "T-A1 arbiter gained a job or quota record" "mutant m2"
echo "PASS mutant m2: no-side-effect assertion goes RED"

# m3: the pre-hk-1810 enumeration knows gpt-5.6-terra only — restoring it lets
# the alias spawn, so the unexpected-spawn assertion must be the one that trips.
M3_FUTURE_TERRA_WRK="$TMP/noterra/m3-literal-only-wrk"
python3 - "$FUTURE_TERRA_WRK" "$M3_FUTURE_TERRA_WRK" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
widened = "    terra|*-terra|*-terra-*)\n"
narrowed = "    gpt-5.6-terra|gpt-5.6-terra-*)\n"
if src.count(widened) != 1:
    raise SystemExit("m3 target pattern is not unique")
Path(sys.argv[2]).write_text(src.replace(widened, narrowed, 1))
Path(sys.argv[2]).chmod(0o755)
PY
m3_probe_log="$TMP/noterra/m3-probe.log"
if terra_refusal_probe "$M3_FUTURE_TERRA_WRK" future-terra-alias worker mutant-m3 -m gpt-9.9-terra >"$m3_probe_log" 2>&1; then
  fail "m3 mutant (literal-only enumeration) survived the terra model-id pin"
fi
expect_probe_red "$m3_probe_log" "T-A1 future-terra-alias/worker unexpectedly spawned" "mutant m3"
echo "PASS mutant m3: the literal-only enumeration goes RED"

# T-A3: permitted Sol and Luna profiles still traverse this fixture-backed path.
for allowed_codex in codex-sol codex-luna; do
  allowed_out="$(spawn_base "$allowed_codex" --job "noterra-allowed-$allowed_codex" --t T1 2>&1)" ||
    fail "T-A3 $allowed_codex was blocked by the Terra refusal: $allowed_out"
  grep -q "model=$allowed_codex" <<<"$allowed_out" || fail "T-A3 missing $allowed_codex launch: $allowed_out"
done
echo "PASS T-A3: codex-sol and codex-luna remain spawnable"
}

if [[ "${WRK_TEST_ONLY_TERRA:-0}" -eq 1 ]]; then
  run_terra_refusal_tests
  exit 0
fi

# -- #912 devin trusted-workspaces helpers -----------------------------------
# wrk registers the resolved spawn cwd — and only it — in devin's trusted
# store ($XDG_DATA_HOME/devin/cli/trusted_workspaces.json) before any pane
# exists: append-only, inherited-coverage no-op, fail-closed on a missing or
# corrupt store. Every case uses a fixture XDG root under $TMP; the real user
# store is never touched. devin_spawn_at mirrors spawn_base's env but takes
# the XDG root and -c cwd as parameters.
devin_spawn_at() {
  local xdg="$1" dcwd="$2" label="$3" task="$4"; shift 4
  case "$xdg" in
    "$TMP"/*) ;;
    *) fail "devin_spawn_at requires a fixture XDG root under TMP: $xdg" ;;
  esac
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    XDG_DATA_HOME="$xdg" \
    ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO="${TEST_FIXTURE_SCENARIO:-devin-idle}" \
    WRK_FIXTURE_LOG="$TMP/herdr-$label.log" WRK_FIXTURE_MARKER="" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel-$label.log" \
    WRK_REFRESH_LOG="$TMP/refresh-$label.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh-$label.pids" WRK_REFRESH_TIMEOUT_S=5 \
    WRK_TEST_TRUST_DELAY_S="${WRK_TEST_TRUST_DELAY_S:-}" \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$dcwd" -m devin-swe2 -p "$PROMPT" \
    -w w -l "$label" --t T1 --task "$task" "$@"
}

devin_trust_seed_store() {  # XDG_ROOT ENTRY...
  local xdg="$1"; shift
  mkdir -p "$xdg/devin/cli"
  python3 - "$xdg/devin/cli/trusted_workspaces.json" "$@" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"trusted_paths": list(sys.argv[2:])}, handle, indent=2)
PY
}

devin_trust_paths() {  # XDG_ROOT — entries one per line; fails if unparsable
  python3 - "$1/devin/cli/trusted_workspaces.json" <<'PY'
import json, sys
for entry in json.load(open(sys.argv[1], encoding="utf-8"))["trusted_paths"]:
    print(entry)
PY
}

# A piped grep -q exits on the first hit and SIGPIPEs this writer. Under
# pipefail that is a failure even when the entry is present: the #912
# concurrent check died as BrokenPipeError on a later print. Capture the
# list, then grep the text. Same shape as the #994 AC7 note.
devin_trust_has() {  # XDG_ROOT ENTRY
  local paths
  paths="$(devin_trust_paths "$1")" || return 1
  grep -qxF -- "$2" <<<"$paths"
}

devin_trust_mutant() {  # NAME OLD NEW — writes $TMP/mut-wrk-NAME, asserts applied
  python3 - "$WRK" "$TMP/mut-wrk-$1" "$2" "$3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old, new = sys.argv[3], sys.argv[4]
assert src.count(old) == 1, "mutant anchor not unique: %r" % old
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
  chmod +x "$TMP/mut-wrk-$1"
  grep -qF "$3" "$TMP/mut-wrk-$1" || fail "devin trust mutant $1 did not apply"
}

# -- #951 claude folder-trust helpers ----------------------------------------
# wrk records projects[<resolved cwd>].hasTrustDialogAccepted = true in
# ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json for PROFILE_KIND=claude before any
# pane exists — fail-open, atomic, other keys and projects preserved. Every
# case uses a fixture HOME under $TMP; the real user config is never touched.
# claude_spawn_at mirrors devin_spawn_at but parametrizes HOME (and unsets
# CLAUDE_CONFIG_DIR so the default path is exercised); MODEL defaults to
# sonnet so non-claude kinds can be driven through the same helper.
claude_spawn_at() {
  local home="$1" ccwd="$2" label="$3" task="$4" model="${5:-sonnet}"
  case "$home" in
    "$TMP"/*) ;;
    *) fail "claude_spawn_at requires a fixture HOME under TMP: $home" ;;
  esac
  shift 4
  if (($#)); then shift; fi  # drop the optional MODEL; rest are extra wrk args
  env -u CLAUDE_CONFIG_DIR HOME="$home" HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/herdr-$label.log" WRK_FIXTURE_MARKER="" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel-$label.log" \
    WRK_REFRESH_LOG="$TMP/refresh-$label.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh-$label.pids" WRK_REFRESH_TIMEOUT_S=5 \
    WRK_TEST_TRUST_DELAY_S="${WRK_TEST_TRUST_DELAY_S:-}" \
    WRK_TEST_TRUST_LOCK_TIMEOUT_S="${WRK_TEST_TRUST_LOCK_TIMEOUT_S:-}" \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$ccwd" -m "$model" -p "$PROMPT" \
    -w w -l "$label" --t T1 --task "$task" "$@"
}

claude_trust_entry() {  # STORE_PATH ABS_CWD — prints the projects entry (JSON), "absent" if none
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    print("absent")
    raise SystemExit(0)
entry = data.get("projects", {}).get(sys.argv[2])
print("absent" if entry is None else json.dumps(entry, sort_keys=True, separators=(",", ":")))
PY
}

claude_trust_mutant() {  # NAME OLD NEW — same generic source replace as devin_trust_mutant
  devin_trust_mutant "$@"
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
    ARBITER_BIN="${HUB_QUOTA_ARBITER_BIN:-$ARBITER}" XDG_DATA_HOME="$TMP/hub-quota-xdg-$name" \
    ARBITER_INBOX_ROOT="$TMP/hub-quota-inbox-$name" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$HUB_QUOTA_HERDR_LOG" WRK_SCOPEFUEL_LOG="$TMP/hub-quota-scopefuel.log" \
    WRK_REFRESH_LOG="$TMP/hub-quota-refresh.log" WRK_REFRESH_PID_LOG="$TMP/hub-quota-refresh.pids" \
    WRK_REFRESH_TIMEOUT_S=5 WRK_HOSTS_CONFIG="$config" \
    WRK_SPILLOVER_LOG="$HUB_QUOTA_SPILLOVER_LOG" \
    WRK_PANEWIRE_LOG="$HUB_QUOTA_PANEWIRE_LOG" WRK_PANEWIRE_RC="$hub_rc" \
    WRK_GATE_MODE="$gate_mode" \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l fixture --t T1 --host local \
    >"$HUB_QUOTA_OUT" 2>"$HUB_QUOTA_ERR"
  HUB_QUOTA_RC=$?
  set -e
}

hub_quota_expect_rc() {
  local name="$1" want="$2"
  [[ "$HUB_QUOTA_RC" -eq "$want" ]] ||
    fail "hub quota combination $name expected exit $want, got $HUB_QUOTA_RC: $(cat "$HUB_QUOTA_ERR")"
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

# #1138: the skipped-gate warning — counted as whole lines equal to the exact
# text, so "exactly once" is a count assertion, not a substring presence.
HUB_QUOTA_WARN_TEXT='wrk: warning: [hub] hub_url is set but hub_token_env is not; hub quota gate skipped (local scopefuel gate only)'
hub_quota_warn_count() { grep -cxF "$HUB_QUOTA_WARN_TEXT" "$HUB_QUOTA_ERR" || true; }

hub_quota_expect_warn() {  # NAME WANT_COUNT — the #1138 skipped-gate warning
  local name="$1" want="$2" got
  got="$(hub_quota_warn_count)"
  [[ "$got" -eq "$want" ]] ||
    fail "hub quota combination $name expected $want skipped-gate warning(s), got $got: $(cat "$HUB_QUOTA_ERR")"
}

# ---------------------------------------------------------------------------
# #1045 (scopefuel #1024): a broken config makes `policy launch` print a long
# "scopefuel: warning:" line ahead of the refusal, and the old squeeze+cut of
# all stderr kept the warning while truncating the actual reason away. The
# reason is now built from non-warning lines only — the warnings are
# re-emitted verbatim on stderr — with a last-non-empty-line fallback and the
# same 240-char cap. The slice lives this early so its ONLY gate can run
# before the spill-over sections (they reach real ssh on some hosts).
# ---------------------------------------------------------------------------
run_t1045_catalog_reason_tests() {
  # codex-astra is the clean refusal vehicle: its default architect purpose
  # passes the quota gate while WRK_LAUNCH_MODE=refused makes the catalog
  # refuse rc 3, so the held-back catalog die — not the gate — is what speaks.
  local t1045_warn t1045_warn_line t1045_warn_b t1045_warn_two
  t1045_warn="$TMP/cfg home path/.config/scopefuel/config.toml: TOML parse error at line 12, column 5 — duplicate table 'bench'; falling back to defaults"
  t1045_warn_line="scopefuel: warning: $t1045_warn"
  t1045_warn_b="the same broken config is still being read; check the file"
  t1045_warn_two="$t1045_warn"$'\n'"$t1045_warn_b"

  # AC1 body — warning + refusal stderr: the die quotes the refusal, not the
  # warning; the warning reaches stderr verbatim twice — once re-printed by
  # apply_catalog for the refused launch, once through the quota gate's own
  # scopefuel call whose stderr passes straight through (#1226 fixture: a
  # broken config warns on every invocation). $1 tags the job so mutant runs
  # do not collide with the green one.
  t1045_ac1_body() {
    local tag="${1:-green}" out rc=0 die_line
    out="$(WRK_LAUNCH_MODE=refused WRK_LAUNCH_CONFIG_WARN="$t1045_warn" \
      spawn_base codex-astra --job "t1045-ac1-$tag" --t T0 2>&1)" || rc=$?
    [[ "$rc" -eq 2 ]] ||
      fail "1045 AC1: the catalog refusal must die rc 2, got rc $rc: $out"
    die_line="$(grep -F "refused profile 'codex-astra'" <<<"$out")" ||
      fail "1045 AC1: no catalog refusal die line: $out"
    grep -qF "consult_only; pass --operator-request" <<<"$die_line" ||
      fail "1045 AC1: a leading scopefuel warning never hides the refusal reason: $die_line"
    if grep -qF 'scopefuel: warning:' <<<"$die_line"; then
      fail "1045 AC1: a leading scopefuel warning never hides the refusal reason: $die_line"
    fi
    [[ "$(grep -cxF "$t1045_warn_line" <<<"$out")" -eq 2 ]] ||
      fail "1045 AC1: the warning must reach stderr verbatim twice (launch re-print + gate passthrough): $out"
  }
  # AC2b body — only warning lines on stderr: the reason falls back to the
  # last non-empty line (the second warning), never 'no reason reported'.
  t1045_ac2b_body() {
    local tag="${1:-green}" out rc=0 die_line
    out="$(WRK_LAUNCH_MODE=refused WRK_LAUNCH_REFUSE_QUIET=1 \
      WRK_LAUNCH_CONFIG_WARN="$t1045_warn_two" \
      spawn_base codex-astra --job "t1045-ac2b-$tag" --t T0 2>&1)" || rc=$?
    [[ "$rc" -eq 2 ]] ||
      fail "1045 AC2: the quiet catalog refusal must die rc 2, got rc $rc: $out"
    die_line="$(grep -F "refused profile 'codex-astra'" <<<"$out")" ||
      fail "1045 AC2: no catalog refusal die line: $out"
    if grep -qF 'no reason reported' <<<"$die_line"; then
      fail "1045 AC2: an all-warning stderr still yields a reason: $die_line"
    fi
    grep -qF "scopefuel: warning: $t1045_warn_b" <<<"$die_line" ||
      fail "1045 AC2: the fallback reason must be the last non-empty line: $die_line"
  }
  t1045_warn_probe() { ( WRK_UNDER_TEST="$1" t1045_ac1_body "$2" ); }
  t1045_fallback_probe() { ( WRK_UNDER_TEST="$1" t1045_ac2b_body "$2" ); }
  # Same contract as the expect_red helper in the #921 mutants block below —
  # redeclared here so this slice's early gate needs no late definitions.
  t1045_expect_red() {
    local label="$1"; shift
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 1 ]] || fail "mutant $label: expected assertion RED (rc 1), got rc $rc"
  }

  # AC1
  t1045_ac1_body
  echo "PASS 1045-AC1-warning-does-not-hide-the-refusal-reason"

  # AC2a — refusal with no warning line: the die message is identical to main.
  # (The refusal line's trailing newline squeezes to one trailing space, so the
  # expected line ends in a space.)
  local t1045_ac2a_out t1045_ac2a_rc=0 t1045_die
  t1045_ac2a_out="$(WRK_LAUNCH_MODE=refused spawn_base codex-astra --job t1045-ac2a --t T0 2>&1)" || t1045_ac2a_rc=$?
  [[ "$t1045_ac2a_rc" -eq 2 ]] ||
    fail "1045 AC2: the plain refusal must die rc 2, got rc $t1045_ac2a_rc: $t1045_ac2a_out"
  t1045_die="$(grep -F "refused profile 'codex-astra'" <<<"$t1045_ac2a_out")" ||
    fail "1045 AC2: no catalog refusal die line: $t1045_ac2a_out"
  [[ "$t1045_die" == "wrk: scopefuel policy launch refused profile 'codex-astra' (catalog profile 'codex-astra'): error: profile 'codex-astra' is consult_only; pass --operator-request " ]] ||
    fail "1045 AC2: the no-warning die message drifted from main: <$t1045_die>"

  # AC2b — only warning lines: fall back to the last non-empty line.
  t1045_ac2b_body

  # AC2c — empty stderr: no reason reported, as on main.
  local t1045_ac2c_out t1045_ac2c_rc=0
  t1045_ac2c_out="$(WRK_LAUNCH_MODE=refused WRK_LAUNCH_REFUSE_QUIET=1 \
    spawn_base codex-astra --job t1045-ac2c --t T0 2>&1)" || t1045_ac2c_rc=$?
  [[ "$t1045_ac2c_rc" -eq 2 ]] ||
    fail "1045 AC2: the silent refusal must die rc 2, got rc $t1045_ac2c_rc: $t1045_ac2c_out"
  t1045_die="$(grep -F "refused profile 'codex-astra'" <<<"$t1045_ac2c_out")" ||
    fail "1045 AC2: no catalog refusal die line: $t1045_ac2c_out"
  [[ "$t1045_die" == "wrk: scopefuel policy launch refused profile 'codex-astra' (catalog profile 'codex-astra'): no reason reported" ]] ||
    fail "1045 AC2: an empty stderr must report no reason, as on main: <$t1045_die>"
  echo "PASS 1045-AC2-plain-identical-warnonly-fallback-empty-none"

  # AC3 — a refusal line longer than 240 characters is still cut at 240.
  local t1045_long t1045_ac3_out t1045_ac3_rc=0
  t1045_long="$(printf 'x%.0s' {1..300})"
  t1045_ac3_out="$(WRK_LAUNCH_MODE=refused WRK_LAUNCH_CONFIG_WARN="$t1045_warn" \
    WRK_LAUNCH_REFUSE_TEXT="$t1045_long" \
    spawn_base codex-astra --job t1045-ac3 --t T0 2>&1)" || t1045_ac3_rc=$?
  [[ "$t1045_ac3_rc" -eq 2 ]] ||
    fail "1045 AC3: the long refusal must die rc 2, got rc $t1045_ac3_rc: $t1045_ac3_out"
  t1045_die="$(grep -F "refused profile 'codex-astra'" <<<"$t1045_ac3_out")" ||
    fail "1045 AC3: no catalog refusal die line: $t1045_ac3_out"
  [[ "$t1045_die" == "wrk: scopefuel policy launch refused profile 'codex-astra' (catalog profile 'codex-astra'): ${t1045_long:0:240}" ]] ||
    fail "1045 AC3: a >240-char refusal reason must still be cut at 240: <${t1045_die:0:60}…>"
  echo "PASS 1045-AC3-refusal-still-cut-at-240"

  # AC4 — assertion-RED mutants (devin_trust_mutant is the suite's generic
  # one-site source replace; expect_red's late definition is why this slice
  # carries its own check).
  # M1 — invariant "a leading scopefuel warning never hides the refusal
  # reason": keeping the warning lines in the reason restores the truncation.
  devin_trust_mutant t1045-warnkept \
    "CATALOG_REFUSE_REASON=\"\$(grep -v '^scopefuel: warning:' \"\$err_file\" | tr -s '[:space:]' ' ' | cut -c1-240 || true)\"" \
    "CATALOG_REFUSE_REASON=\"\$(cat \"\$err_file\" | tr -s '[:space:]' ' ' | cut -c1-240)\""
  # M2 — invariant "an all-warning stderr still yields a reason": dropping the
  # fallback leaves the die at 'no reason reported'.
  devin_trust_mutant t1045-nofallback \
    "    if [[ -z \"\${CATALOG_REFUSE_REASON//[[:space:]]/}\" ]]; then
      CATALOG_REFUSE_REASON=\"\$(grep '[^[:space:]]' \"\$err_file\" | tail -n 1 | tr -s '[:space:]' ' ' | cut -c1-240 || true)\"
    fi" \
    "    :"
  t1045_expect_red leading-warning-hides-reason t1045_warn_probe "$TMP/mut-wrk-t1045-warnkept" m1
  t1045_expect_red all-warning-yields-no-reason t1045_fallback_probe "$TMP/mut-wrk-t1045-nofallback" m2
  echo "PASS 1045-AC4-mutants-red (M1 keep-warning, M2 no-fallback)"

  # -- #1226: S1 re-emit only on failure, S2 stderr-only, S3 blank reason ----
  # Attribution: the launch's stderr is captured into err_file, so the only
  # way a launch warning reaches wrk stderr is apply_catalog's re-print. The
  # gate fixture emits the same config warning (a broken config warns on
  # every invocation) and quota_gate lets that stderr pass straight through —
  # so a warned spawn's stderr carries one copy per `gate -m` call (1, read
  # off scopefuel.log) plus the launch re-print (0 or 1).
  t1226_ac1_body() {  # success: nothing re-printed from the launch call
    local tag="${1:-green}" launch_log rc=0 warns
    launch_log="$TMP/t1226-ac1-$tag.launch"
    rm -f "$TMP/scopefuel.log" "$launch_log"
    WRK_LAUNCH_LOG="$launch_log" WRK_LAUNCH_CONFIG_WARN="$t1045_warn" \
      spawn_base sonnet --job "t1226-ac1-$tag" --t T0 \
      >"$TMP/t1226-ac1-$tag.out" 2>"$TMP/t1226-ac1-$tag.err" || rc=$?
    [[ "$rc" -eq 0 ]] ||
      fail "1226 AC1: the warned launch must succeed, got rc $rc: $(cat "$TMP/t1226-ac1-$tag.err")"
    [[ "$(grep -c 'policy launch' "$launch_log")" -eq 1 ]] ||
      fail "1226 AC1: expected exactly one policy launch call: $(cat "$launch_log")"
    [[ "$(grep -c 'gate -m' "$TMP/scopefuel.log")" -eq 1 ]] ||
      fail "1226 AC1: expected exactly one gate call: $(cat "$TMP/scopefuel.log")"
    warns="$(grep -cxF "$t1045_warn_line" "$TMP/t1226-ac1-$tag.err" || true)"
    [[ "$warns" -eq 1 ]] ||
      fail "1226 AC1: a successful launch never re-prints the warning — stderr must carry only the gate passthrough copy (1), got $warns: $(cat "$TMP/t1226-ac1-$tag.err")"
  }

  t1226_ac2_body() {  # refusal: re-printed exactly once from the launch call
    local tag="${1:-green}" launch_log rc=0 warns die_line
    launch_log="$TMP/t1226-ac2-$tag.launch"
    rm -f "$TMP/scopefuel.log" "$launch_log"
    WRK_LAUNCH_LOG="$launch_log" WRK_LAUNCH_MODE=refused \
      WRK_LAUNCH_CONFIG_WARN="$t1045_warn" \
      spawn_base codex-astra --job "t1226-ac2-$tag" --t T0 \
      >"$TMP/t1226-ac2-$tag.out" 2>"$TMP/t1226-ac2-$tag.err" || rc=$?
    [[ "$rc" -eq 2 ]] ||
      fail "1226 AC2: the catalog refusal must die rc 2, got rc $rc: $(cat "$TMP/t1226-ac2-$tag.err")"
    die_line="$(grep -F "refused profile 'codex-astra'" "$TMP/t1226-ac2-$tag.err")" ||
      fail "1226 AC2: no catalog refusal die line: $(cat "$TMP/t1226-ac2-$tag.err")"
    grep -qF "consult_only; pass --operator-request" <<<"$die_line" ||
      fail "1226 AC2: the reason must be the refusal text: $die_line"
    [[ "$(grep -c 'policy launch' "$launch_log")" -eq 1 &&
       "$(grep -c 'gate -m' "$TMP/scopefuel.log")" -eq 1 ]] ||
      fail "1226 AC2: expected one launch and one gate call"
    warns="$(grep -cxF "$t1045_warn_line" "$TMP/t1226-ac2-$tag.err" || true)"
    [[ "$warns" -eq 2 ]] ||
      fail "1226 AC2: a refused launch re-prints the warning exactly once — plus the gate passthrough (2 total), got $warns: $(cat "$TMP/t1226-ac2-$tag.err")"
  }

  t1226_ac3_body() {  # stream split: warnings land on stderr only
    local tag="${1:-green}" rc=0
    WRK_LAUNCH_MODE=refused WRK_LAUNCH_CONFIG_WARN="$t1045_warn" \
      spawn_base codex-astra --job "t1226-ac3-$tag" --t T0 \
      >"$TMP/t1226-ac3-$tag.out" 2>"$TMP/t1226-ac3-$tag.err" || rc=$?
    [[ "$rc" -eq 2 ]] ||
      fail "1226 AC3: the catalog refusal must die rc 2, got rc $rc: $(cat "$TMP/t1226-ac3-$tag.err")"
    [[ "$(grep -cxF "$t1045_warn_line" "$TMP/t1226-ac3-$tag.err" || true)" -ge 1 ]] ||
      fail "1226 AC3: the re-printed warning must reach stderr: $(cat "$TMP/t1226-ac3-$tag.err")"
    [[ "$(grep -cxF "$t1045_warn_line" "$TMP/t1226-ac3-$tag.out" || true)" -eq 0 ]] ||
      fail "1226 AC3: warnings go to stderr only, never stdout: $(cat "$TMP/t1226-ac3-$tag.out")"
  }

  t1226_ac4_body() {  # warning + blank line: the reason is not a blank
    local tag="${1:-green}" out rc=0 die_line
    out="$(WRK_LAUNCH_MODE=refused WRK_LAUNCH_REFUSE_QUIET=1 \
      WRK_LAUNCH_CONFIG_WARN="$t1045_warn" WRK_LAUNCH_STDERR_RAW="" \
      spawn_base codex-astra --job "t1226-ac4-$tag" --t T0 2>&1)" || rc=$?
    [[ "$rc" -eq 2 ]] ||
      fail "1226 AC4: the quiet refusal must die rc 2, got rc $rc: $out"
    die_line="$(grep -F "refused profile 'codex-astra'" <<<"$out")" ||
      fail "1226 AC4: no catalog refusal die line: $out"
    grep -qF "$t1045_warn_line" <<<"$die_line" ||
      fail "1226 AC4: a whitespace-only reason never reaches the die line — the reason must be the last non-empty line: $die_line"
  }

  # AC1 — a successful warned spawn emits only the gate's passthrough copy.
  t1226_ac1_body
  echo "PASS 1226-AC1-successful-launch-reprints-nothing"

  # AC2 — a refused warned spawn re-prints once, gate copy counted separately.
  t1226_ac2_body green
  echo "PASS 1226-AC2-refused-launch-reprints-once"

  # AC3 — the re-print is routed to stderr, never stdout.
  t1226_ac3_body
  echo "PASS 1226-AC3-warnings-on-stderr-only"

  # AC4 — a warning followed by a blank line yields the warning as the
  # reason, not a blank; a trailing whitespace-only line is never picked.
  t1226_ac4_body
  local t1226_ac4b_out t1226_ac4b_rc=0
  t1226_ac4b_out="$(WRK_LAUNCH_MODE=refused WRK_LAUNCH_REFUSE_QUIET=1 \
    WRK_LAUNCH_CONFIG_WARN="$t1045_warn_two" WRK_LAUNCH_STDERR_RAW="   " \
    spawn_base codex-astra --job t1226-ac4b --t T0 2>&1)" || t1226_ac4b_rc=$?
  [[ "$t1226_ac4b_rc" -eq 2 ]] ||
    fail "1226 AC4: the quiet refusal must die rc 2, got rc $t1226_ac4b_rc: $t1226_ac4b_out"
  t1045_die="$(grep -F "refused profile 'codex-astra'" <<<"$t1226_ac4b_out")" ||
    fail "1226 AC4: no catalog refusal die line: $t1226_ac4b_out"
  grep -qF "$t1045_warn_b" <<<"$t1045_die" ||
    fail "1226 AC4: the fallback must pick the last non-whitespace line, got: $t1045_die"
  echo "PASS 1226-AC4-blank-and-whitespace-lines-fall-back"

  # AC5 — assertion-RED mutants.
  # M1 — invariant "a successful launch never re-prints the warning": dropping
  # the rc guard restores the unconditional re-print (the #1045 behaviour).
  devin_trust_mutant t1226-rc0reprint \
    "    if [[ \"\$rc\" -ne 0 ]]; then
      grep '^scopefuel: warning:' \"\$err_file\" >&2 || true
    fi" \
    "    grep '^scopefuel: warning:' \"\$err_file\" >&2 || true"
  # M2 — invariant "warnings go to stderr only": the re-print lands on stdout.
  devin_trust_mutant t1226-warnstdout \
    "      grep '^scopefuel: warning:' \"\$err_file\" >&2 || true" \
    "      grep '^scopefuel: warning:' \"\$err_file\" || true"
  # M3 — invariant "a whitespace-only reason never reaches the die line":
  # without the trim, a warning followed by a blank line dies blank.
  devin_trust_mutant t1226-notrim \
    "if [[ -z \"\${CATALOG_REFUSE_REASON//[[:space:]]/}\" ]]" \
    "if [[ -z \"\$CATALOG_REFUSE_REASON\" ]]"
  t1226_ok_probe() { ( WRK_UNDER_TEST="$1" t1226_ac1_body "$2" ); }
  t1226_stream_probe() { ( WRK_UNDER_TEST="$1" t1226_ac3_body "$2" ); }
  t1226_blank_probe() { ( WRK_UNDER_TEST="$1" t1226_ac4_body "$2" ); }
  t1045_expect_red rc0-reprints-warning t1226_ok_probe "$TMP/mut-wrk-t1226-rc0reprint" m1
  t1045_expect_red warnings-on-stdout t1226_stream_probe "$TMP/mut-wrk-t1226-warnstdout" m2
  t1045_expect_red whitespace-reason-dies-blank t1226_blank_probe "$TMP/mut-wrk-t1226-notrim" m3
  echo "PASS 1226-AC5-mutants-red (M1 rc0-reprint, M2 warn-on-stdout, M3 no-trim)"
}

# Slice gate: WRK_TEST_ONLY_CATALOG_REASON=1 runs only this section after the
# shared fixture setup — every spawn is fixture-backed, no real agent runs.
if [[ "${WRK_TEST_ONLY_CATALOG_REASON:-0}" -eq 1 ]]; then
  run_t1045_catalog_reason_tests
  exit 0
fi
run_t1045_catalog_reason_tests

run_t1090_remote_err_tests() {
  # -- #1090: a failed remote spawn must say why -------------------------------
  # The remote legs used to swallow the remote's own words: the probe and the
  # prepare check ran under 2>/dev/null, a refused candidate was skipped without
  # a line, and the router's last message carried an initialized rc=1 naming no
  # step. The contract pinned here: remote stderr and non-OK remote stdout land
  # on the local stderr, and the final line names the failed step and its rc.
  T1090_LOAD="$TMP/t1090-loadavg"
  printf '0.20 0.10 0.10 1/1 1\n' >"$T1090_LOAD"
  T1090_HOSTS="$TMP/t1090-hosts.toml"
  printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
    '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' >"$T1090_HOSTS"
  # A suffix-kind mapping actually opens the prepare leg (exact mappings return
  # before any remote check). The .wt sibling directory stands in for a derived
  # worktree path so the sh -s leg is exercised end to end.
  T1090_SUFFIX_ROOT="$TMP/t1090-lrepo"
  mkdir -p "$T1090_SUFFIX_ROOT" "${T1090_SUFFIX_ROOT}.wt"
  T1090_HOSTS_SUFFIX="$TMP/t1090-hosts-suffix.toml"
  printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
    '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$T1090_SUFFIX_ROOT\"=\"/remote/lrepo\"}" 'capacity = 3' >"$T1090_HOSTS_SUFFIX"
  # The router refuses remote placement while the arbiter lookup is unreadable;
  # a seeded claim makes the block-private inbox a real database for preflight
  # to read — it stays out of the shared $TMP/inbox other sections assert on.
  T1090_INBOX="$TMP/t1090-inbox" T1090_XDG="$TMP/t1090-xdg"
  env ARBITER_INBOX_ROOT="$T1090_INBOX" XDG_DATA_HOME="$T1090_XDG" \
    "$ARBITER" claim --job t1090-seed --agent-label t1090-seed --lane t1090 --t T1 >/dev/null
  # --host auto needs the local side pressured (ratio >= max_load_ratio) so the
  # router enumerates every configured host as a candidate in file order.
  T1090_LOAD_HIGH="$TMP/t1090-loadavg-high"
  printf '4.00 4.00 4.00 1/1 1\n' >"$T1090_LOAD_HIGH"
  T1090_HOSTS_AUTO="$TMP/t1090-hosts-auto.toml"
  printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
    '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' '' \
    '[hosts.mac-work]' 'ssh = "mac-work"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 2' >"$T1090_HOSTS_AUTO"

  t1090_spawn() {  # env knobs per call include T1090_{SSH,SCP}_SCENARIO*, delay, host, cwd, and fixture controls
    exec env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
      ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$T1090_INBOX" XDG_DATA_HOME="$T1090_XDG" \
      WRK_HOSTS_CONFIG="${T1090_HOSTS_OVERRIDE:-$T1090_HOSTS}" \
      WRK_PROC_LOADAVG="${T1090_LOAD_FILE:-$T1090_LOAD}" \
      WRK_TEST_NCPU=4 WRK_TEST_THROTTLED=0 \
      WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/t1090-herdr.log" \
      WRK_SPILLOVER_LOG="$TMP/t1090-spillover.log" \
      PANEWIRE_BIN="$PANEWIRE" WRK_WAKE_LOG="$TMP/t1090-wake.log" \
      WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" \
      WRK_SCP_BIN="${T1090_SCP:-$ROOT/tests/fixtures/spillover-scp}" \
      WRK_SSH_LOG="$TMP/t1090-ssh.log" WRK_SCP_LOG="$TMP/t1090-scp.log" \
      WRK_SSH_DELAY_SECONDS_DESKTOP="${T1090_SSH_DELAY_SECONDS_DESKTOP:-}" \
      WRK_SSH_SCENARIO="${T1090_SSH_SCENARIO:-ok}" \
      WRK_SSH_SCENARIO_DESKTOP="${T1090_SSH_SCENARIO_DESKTOP:-}" \
      WRK_SSH_SCENARIO_MAC_WORK="${T1090_SSH_SCENARIO_MAC_WORK:-}" \
      WRK_SCP_SCENARIO="${T1090_SCP_SCENARIO:-ok}" \
      WRK_SCP_SCENARIO_DESKTOP="${T1090_SCP_SCENARIO_DESKTOP:-}" \
      WRK_REMOTE_RC="${T1090_REMOTE_RC:-}" \
      WRK_REMOTE_SLEEP_SECONDS="${T1090_REMOTE_SLEEP_SECONDS:-1}" \
      WRK_REMOTE_STDERR_BINARY="${T1090_REMOTE_STDERR_BINARY:-0}" \
      WRK_REMOTE_STDERR_LINE="${T1090_REMOTE_STDERR_LINE:-}" \
      WRK_REMOTE_STDOUT_LINE="${T1090_REMOTE_STDOUT_LINE:-}" \
      "${T1090_WRK:-$WRK}" spawn -c "${T1090_CWD:-$ROOT}" -m codex-luna -p "$PROMPT" \
      -w w -l fixture --t T1 --job "t1090-$RANDOM-$RANDOM" --host "${T1090_HOST_ARG:-desktop}"
  }

  t1090_check_steps() {
    local err_file="$1" host="$2" tag="$3"
    shift 3
    local want_file="$TMP/$tag.want-steps" raw_file="$TMP/$tag.raw-steps"
    local got_file="$TMP/$tag.got-steps" bad_file="$TMP/$tag.bad-steps"
    printf '%s\n' "$@" >"$want_file"
    grep -E "^wrk: remote host '$host' step " "$err_file" >"$raw_file" || true
    if grep -Ev "^wrk: remote host '$host' step (probe|cwd-map|prepare|mktemp|scp|remote wrk|lane) elapsed=[0-9]+s$" \
        "$raw_file" >"$bad_file"; then
      fail "$tag: malformed progress line: $(cat "$bad_file")"
    fi
    sed -E "s/^wrk: remote host '$host' step (.*) elapsed=[0-9]+s$/\\1/" "$raw_file" >"$got_file"
    cmp -s "$want_file" "$got_file" ||
      fail "$tag: progress steps differ: $(cat "$got_file")"
  }

  # AC1: the remote wrk dies on stderr — the die line reaches the local stderr
  # and the final line names the remote wrk step and its rc.
  set +e
  ( T1090_SSH_SCENARIO=remote-die-stderr t1090_spawn ) >"$TMP/t1090-ac1.out" 2>"$TMP/t1090-ac1.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] || fail "AC1: remote rc=1 must propagate, got $t1090_rc"
  grep -qF "hk task 1037 is already bound to job 'other-job'" "$TMP/t1090-ac1.err" ||
    fail "AC1: remote stderr die line never reached local stderr: $(cat "$TMP/t1090-ac1.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac1.err")"
  [[ "$t1090_last" == *"rc=1"* && "$t1090_last" == *"remote wrk"* && "$t1090_last" == *"no local fallback"* ]] ||
    fail "AC1: final line must name the remote wrk step and rc=1, got: $t1090_last"
  [[ ! -s "$TMP/t1090-ac1.out" ]] || fail "AC1: a failed spawn must not write to stdout: $(cat "$TMP/t1090-ac1.out")"
  echo "PASS t1090 AC1 remote-stderr-relayed"

  # AC2: the remote wrk prints its refusal on stdout — same contract, and the
  # line must move to stderr rather than masquerade on the OK stream.
  set +e
  ( T1090_SSH_SCENARIO=remote-die-stdout t1090_spawn ) >"$TMP/t1090-ac2.out" 2>"$TMP/t1090-ac2.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] || fail "AC2: remote rc=1 must propagate, got $t1090_rc"
  grep -qF "hk task 1037 is already bound to job 'other-job'" "$TMP/t1090-ac2.err" ||
    fail "AC2: remote stdout refusal never reached local stderr: $(cat "$TMP/t1090-ac2.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac2.err")"
  [[ "$t1090_last" == *"rc=1"* && "$t1090_last" == *"remote wrk"* ]] ||
    fail "AC2: final line must name the remote wrk step and rc=1, got: $t1090_last"
  ! grep -qF 'already bound' "$TMP/t1090-ac2.out" ||
    fail "AC2: remote refusal must not stay on stdout: $(cat "$TMP/t1090-ac2.out")"
  echo "PASS t1090 AC2 remote-stdout-relayed"

  # AC3: prepare, mktemp and scp failures each name their step on the final
  # line, and each leg's stderr reaches the local stderr.
  set +e
  ( T1090_HOSTS_OVERRIDE="$T1090_HOSTS_SUFFIX" T1090_CWD="${T1090_SUFFIX_ROOT}.wt" \
    T1090_SSH_SCENARIO=prepare-fails t1090_spawn ) >"$TMP/t1090-ac3a.out" 2>"$TMP/t1090-ac3a.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 255 ]] || fail "AC3 prepare: ssh rc must propagate, got $t1090_rc"
  t1090_check_steps "$TMP/t1090-ac3a.err" desktop t1090-prepare probe cwd-map prepare
  grep -qF 'Connection refused' "$TMP/t1090-ac3a.err" ||
    fail "AC3 prepare: remote check stderr dropped: $(cat "$TMP/t1090-ac3a.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac3a.err")"
  [[ "$t1090_last" == *"rc=255"* && "$t1090_last" == *"prepare"* ]] ||
    fail "AC3 prepare: final line must name the prepare step and rc, got: $t1090_last"

  set +e
  ( T1090_SSH_SCENARIO=mktemp-fails t1090_spawn ) >"$TMP/t1090-ac3b.out" 2>"$TMP/t1090-ac3b.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] || fail "AC3 mktemp: remote rc must propagate, got $t1090_rc"
  grep -qF 'No space left on device' "$TMP/t1090-ac3b.err" ||
    fail "AC3 mktemp: remote mktemp stderr dropped: $(cat "$TMP/t1090-ac3b.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac3b.err")"
  [[ "$t1090_last" == *"rc=1"* && "$t1090_last" == *"mktemp"* ]] ||
    fail "AC3 mktemp: final line must name the mktemp step and rc, got: $t1090_last"

  set +e
  ( T1090_SCP_SCENARIO=fail t1090_spawn ) >"$TMP/t1090-ac3c.out" 2>"$TMP/t1090-ac3c.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] || fail "AC3 scp: scp rc must propagate, got $t1090_rc"
  t1090_check_steps "$TMP/t1090-ac3c.err" desktop t1090-scp probe cwd-map mktemp scp
  t1090_scp_step="$(grep -E "^wrk: remote host 'desktop' step scp elapsed=[0-9]+s$" "$TMP/t1090-ac3c.err" | tail -n 1)"
  t1090_scp_step_line="$(grep -nF "$t1090_scp_step" "$TMP/t1090-ac3c.err" | tail -n 1 | cut -d: -f1)"
  t1090_scp_error_line="$(grep -nF 'scp: dest open' "$TMP/t1090-ac3c.err" | head -n 1 | cut -d: -f1)"
  [[ -n "$t1090_scp_error_line" && "$t1090_scp_step_line" -lt "$t1090_scp_error_line" ]] ||
    fail "AC3 scp: the progress line must precede the scp error: $(cat "$TMP/t1090-ac3c.err")"
  grep -qF 'scp: dest open' "$TMP/t1090-ac3c.err" ||
    fail "AC3 scp: scp stderr missing: $(cat "$TMP/t1090-ac3c.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac3c.err")"
  [[ "$t1090_last" == *"rc=1"* && "$t1090_last" == *"scp"* ]] ||
    fail "AC3 scp: final line must name the scp step and rc, got: $t1090_last"

  # The scp progress assertion is an assertion-RED mutant: omitting this
  # helper call must make the expected step sequence fail.
  T1493_M1="$TMP/t1493-wrk-no-scp-progress"
  # shellcheck disable=SC2016 # $host is literal source text in the mutation pattern
  sed 's/spillover_remote_step "$host" scp/:/' "$WRK" >"$T1493_M1"
  chmod +x "$T1493_M1"
  # shellcheck disable=SC2016 # the searched wrk source text is literal
  grep -qF 'spillover_remote_step "$host" scp' "$T1493_M1" &&
    fail "T2 mutant did not apply: scp progress helper call remains"
  set +e
  ( T1090_WRK="$T1493_M1" T1090_SCP_SCENARIO=fail t1090_spawn ) \
    >"$TMP/t1493-m1.out" 2>"$TMP/t1493-m1.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] ||
    fail "T2 mutant: scp failure rc changed under the missing-progress mutant: $t1090_rc"
  if ( t1090_check_steps "$TMP/t1493-m1.err" desktop t1493-m1 probe cwd-map mktemp scp ) >/dev/null 2>&1; then
    fail "T2 mutant survived: the last-step assertion accepted a missing scp progress line"
  fi
  echo "PASS t1493 M1: missing-scp-progress mutant goes RED at the last-step assertion"

  # A refused probe is the failure that produced the incident's bare rc=1 line:
  # the probe reason and the remote's stderr must be named, the step is 'probe'.
  set +e
  ( T1090_SSH_SCENARIO=probe-herdr-missing t1090_spawn ) >"$TMP/t1090-ac3d.out" 2>"$TMP/t1090-ac3d.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] || fail "AC3 probe: expected rc=1, got $t1090_rc"
  grep -qF 'herdr: command not found' "$TMP/t1090-ac3d.err" ||
    fail "AC3 probe: remote probe stderr dropped: $(cat "$TMP/t1090-ac3d.err")"
  grep -q 'remote-full' "$TMP/t1090-ac3d.err" ||
    fail "AC3 probe: refusal reason missing: $(cat "$TMP/t1090-ac3d.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac3d.err")"
  [[ "$t1090_last" == *"rc=1"* && "$t1090_last" == *"probe"* ]] ||
    fail "AC3 probe: final line must name the probe step and rc, got: $t1090_last"
  echo "PASS t1090 AC3 failed-steps-named"

  # R1-A: --host auto holds per-candidate diagnostics until the round settles.
  # desktop is unreachable, mac-work answers: the spawn lands on mac-work and
  # stderr stays byte-identical to main — empty, not a word about desktop.
  set +e
  ( T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_SCENARIO_DESKTOP=probe-unreachable \
      T1090_SSH_SCENARIO_MAC_WORK=ok t1090_spawn ) >"$TMP/t1090-auto1.out" 2>"$TMP/t1090-auto1.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] ||
    fail "R1 auto-success: expected rc=0, got $t1090_rc: $(cat "$TMP/t1090-auto1.err")"
  printf '%s\n' 'OK pane=mac-work:p7 host=mac-work model=codex-luna label=fixture status=working landed=yes' >"$TMP/t1090-auto1.want"
  cmp -s "$TMP/t1090-auto1.want" "$TMP/t1090-auto1.out" ||
    fail "R1 auto-success: stdout differs from the pinned mac-work OK line: $(cat "$TMP/t1090-auto1.out")"
  [[ ! -s "$TMP/t1090-auto1.err" ]] ||
    fail "R1 auto-success: skipped-host diagnostics must stay silent on success: $(cat "$TMP/t1090-auto1.err")"
  echo "PASS t1090 R1 auto-success-silent"

  # R1-B: with every candidate failing, the buffered diagnostics flush before
  # the local fallback — one attributed line per host (step + rc), with the
  # remote's own words ahead of it.
  set +e
  ( T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_DELAY_SECONDS_DESKTOP=2 \
      T1090_SSH_SCENARIO_DESKTOP=probe-unreachable \
      T1090_SSH_SCENARIO_MAC_WORK=probe-herdr-missing t1090_spawn ) >"$TMP/t1090-auto2.out" 2>"$TMP/t1090-auto2.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] ||
    fail "R1 auto-all-fail: local fallback should still land, got rc=$t1090_rc: $(cat "$TMP/t1090-auto2.err")"
  grep -qF "remote host 'desktop' probe failed (ssh-unreachable, rc=255)" "$TMP/t1090-auto2.err" ||
    fail "R1 auto-all-fail: desktop probe line missing: $(cat "$TMP/t1090-auto2.err")"
  grep -qF "remote host 'desktop' failed (rc=255) at step 'probe'" "$TMP/t1090-auto2.err" ||
    fail "R1 auto-all-fail: desktop summary missing: $(cat "$TMP/t1090-auto2.err")"
  grep -qF 'herdr: command not found' "$TMP/t1090-auto2.err" ||
    fail "R1 auto-all-fail: mac-work probe stderr dropped: $(cat "$TMP/t1090-auto2.err")"
  grep -qF "remote host 'mac-work' skipped: remote-full (active unknown capacity 2)" "$TMP/t1090-auto2.err" ||
    fail "R1 auto-all-fail: mac-work skipped line missing: $(cat "$TMP/t1090-auto2.err")"
  grep -qF "remote host 'mac-work' failed (rc=1) at step 'probe'" "$TMP/t1090-auto2.err" ||
    fail "R1 auto-all-fail: mac-work summary missing: $(cat "$TMP/t1090-auto2.err")"
  grep -qE "^wrk: remote host 'desktop' step probe elapsed=[0-9]+s$" "$TMP/t1090-auto2.err" ||
    fail "R1 auto-all-fail: desktop's captured progress line is missing: $(cat "$TMP/t1090-auto2.err")"
  grep -qE "^wrk: remote host 'mac-work' step probe elapsed=[0-9]+s$" "$TMP/t1090-auto2.err" ||
    fail "R1 auto-all-fail: mac-work's captured progress line is missing: $(cat "$TMP/t1090-auto2.err")"
  t1090_mac_probe_line="$(grep -E "^wrk: remote host 'mac-work' step probe elapsed=[0-9]+s$" "$TMP/t1090-auto2.err")"
  if [[ "$t1090_mac_probe_line" =~ elapsed=([0-9]+)s$ ]]; then
    t1090_mac_probe_elapsed="${BASH_REMATCH[1]}"
  else
    fail "R1 auto-all-fail: second candidate's elapsed value is malformed"
  fi
  [[ "$t1090_mac_probe_elapsed" -ge 2 ]] ||
    fail "R1 auto-all-fail: second candidate did not include time spent in the first remote leg"
  grep -qF 'falling back to local' "$TMP/t1090-auto2.err" ||
    fail "R1 auto-all-fail: fallback warning missing: $(cat "$TMP/t1090-auto2.err")"
  grep -q 'host=local' "$TMP/t1090-auto2.out" ||
    fail "R1 auto-all-fail: expected a local landing on stdout: $(cat "$TMP/t1090-auto2.out")"
  echo "PASS t1090 R1 auto-all-fail-per-host-lines"

  # R1-C: a transport leg exiting 2 must not look like an admission refusal —
  # desktop's scp dies with rc 2, the router maps it to a transport failure
  # and the spawn lands on mac-work with stderr still empty.
  set +e
  ( T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SCP_SCENARIO_DESKTOP=fail2 \
      T1090_SSH_SCENARIO_MAC_WORK=ok t1090_spawn ) >"$TMP/t1090-auto3.out" 2>"$TMP/t1090-auto3.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] ||
    fail "R1 auto-transport-2: expected failover to mac-work (rc=0), got $t1090_rc: $(cat "$TMP/t1090-auto3.err")"
  cmp -s "$TMP/t1090-auto1.want" "$TMP/t1090-auto3.out" ||
    fail "R1 auto-transport-2: expected the mac-work OK line: $(cat "$TMP/t1090-auto3.out")"
  [[ ! -s "$TMP/t1090-auto3.err" ]] ||
    fail "R1 auto-transport-2: skipped-host diagnostics must stay silent on success: $(cat "$TMP/t1090-auto3.err")"
  grep -q 'desktop:' "$TMP/t1090-scp.log" ||
    fail "R1 auto-transport-2: desktop scp attempt missing from the fixture log"
  echo "PASS t1090 R1 auto-transport-rc2-fails-over"

  # R1-D: probe rc fidelity — an ssh probe exiting 2 (a router fail-closed
  # code) must report the real rc=2 on the probe line while the returned rc
  # stays normalized to 1, so the explicit final line keeps main's shape.
  set +e
  ( T1090_SSH_SCENARIO=probe-exit2 t1090_spawn ) >"$TMP/t1090-p2.out" 2>"$TMP/t1090-p2.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] || fail "R1 probe-rc2: expected rc=1, got $t1090_rc"
  grep -q "probe failed (ssh-unreachable, rc=2)" "$TMP/t1090-p2.err" ||
    fail "R1 probe-rc2: probe line must carry the real ssh rc=2: $(cat "$TMP/t1090-p2.err")"
  grep -q "remote spawn on explicit host 'desktop' failed (rc=1) at step 'probe'" "$TMP/t1090-p2.err" ||
    fail "R1 probe-rc2: router-visible rc must stay normalized to 1: $(cat "$TMP/t1090-p2.err")"
  echo "PASS t1090 R1 probe-rc2-fidelity"

  # R2-A: the winner's own stderr is not sacrificed to the capture — a remote
  # wrk that warns on stderr and succeeds must surface that line on a
  # successful auto spawn (main streamed it live), while the skipped host's
  # diagnostics stay dropped.
  set +e
  ( T1090_REMOTE_STDERR_BINARY=1 T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_SCENARIO_DESKTOP=probe-unreachable \
      T1090_SSH_SCENARIO_MAC_WORK=remote-warn-ok t1090_spawn ) >"$TMP/t1090-auto4.out" 2>"$TMP/t1090-auto4.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] ||
    fail "R2 winner-stderr: expected rc=0, got $t1090_rc: $(cat "$TMP/t1090-auto4.err")"
  cmp -s "$TMP/t1090-auto1.want" "$TMP/t1090-auto4.out" ||
    fail "R2 winner-stderr: stdout differs from the pinned mac-work OK line: $(cat "$TMP/t1090-auto4.out")"
  printf '%s\n' 'wrk: note: remote herdr quota nearly full on mac-work' >"$TMP/t1090-auto4.want"
  printf 'wrk: binary warning \377\000 tail\n' >>"$TMP/t1090-auto4.want"
  cmp -s "$TMP/t1090-auto4.want" "$TMP/t1090-auto4.err" ||
    fail "R2 winner-stderr: stderr must equal the winner's live byte stream"
  echo "PASS t1090 R2 winner-stderr-replayed"

  # R2 mutant — invariant "a successful auto spawn keeps the winner's own
  # stderr": dropping the winner's replay must turn R2-A red.
  T1090_M4="$TMP/t1090-wrk-no-winner-replay"
  # shellcheck disable=SC2016 # the sed pattern is bin/wrk source text, not an expansion site
  sed 's/        spillover_replay_success_stderr "\$cand_err"/        :/' "$WRK" >"$T1090_M4"
  chmod +x "$T1090_M4"
  # shellcheck disable=SC2016 # the grep pattern is literal bin/wrk source text
  grep -qF 'spillover_replay_success_stderr "$cand_err"' "$T1090_M4" && fail 'R2 mutant did not apply: winner replay still present'
  set +e
  ( T1090_WRK="$T1090_M4" T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_SCENARIO_DESKTOP=probe-unreachable \
      T1090_SSH_SCENARIO_MAC_WORK=remote-warn-ok t1090_spawn ) >"$TMP/t1090-m4.out" 2>"$TMP/t1090-m4.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] || fail "R2 mutant: the spawn itself should still succeed (rc=$t1090_rc)"
  grep -q 'quota nearly full' "$TMP/t1090-m4.err" &&
    fail "R2 mutant: winner stderr survived without the replay — mutant did not diverge"
  echo "PASS t1090 R2 mutant: no-replay mutant goes RED (R2-A assertion: winner's stderr missing)"

  # R1 mutant — invariant "a successful auto spawn prints nothing about
  # skipped hosts": printing the captured diagnostics eagerly (dropping the
  # per-candidate stderr capture) must turn R1-A red.
  T1090_M3="$TMP/t1090-wrk-eager-diag"
  # shellcheck disable=SC2016 # the sed pattern is bin/wrk source text, not an expansion site
  sed 's/ ) 2>"\$cand_err"/ )/' "$WRK" >"$T1090_M3"
  chmod +x "$T1090_M3"
  # shellcheck disable=SC2016 # the grep pattern is literal bin/wrk source text
  grep -qF '2>"$cand_err"' "$T1090_M3" && fail 'R1 mutant did not apply: capture redirect still present'
  set +e
  ( T1090_WRK="$T1090_M3" T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_SCENARIO_DESKTOP=probe-unreachable \
      T1090_SSH_SCENARIO_MAC_WORK=ok t1090_spawn ) >"$TMP/t1090-m3.out" 2>"$TMP/t1090-m3.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] || fail "R1 mutant: the spawn itself should still succeed (rc=$t1090_rc)"
  if [[ ! -s "$TMP/t1090-m3.err" ]]; then
    fail "R1 mutant: eager diagnostics must turn the silence check red, but stderr stayed empty"
  fi
  echo "PASS t1090 R1 mutant: eager-diagnostics mutant goes RED (R1-A assertion: stderr no longer empty)"

  # AC4: the success stdout remains byte-identical; explicit remote stderr has
  # one progress line for each leg reached.
  set +e
  ( t1090_spawn ) >"$TMP/t1090-ac4.out" 2>"$TMP/t1090-ac4.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] || fail "AC4: success rc must stay 0, got $t1090_rc"
  printf '%s\n' 'OK pane=desktop:p7 host=desktop model=codex-luna label=fixture status=working landed=yes' >"$TMP/t1090-ac4.want"
  cmp -s "$TMP/t1090-ac4.want" "$TMP/t1090-ac4.out" ||
    fail "AC4: success stdout differs from the pinned OK line: $(cat "$TMP/t1090-ac4.out")"
  t1090_check_steps "$TMP/t1090-ac4.err" desktop t1090-explicit-success \
    probe cwd-map mktemp scp "remote wrk"
  echo "PASS t1090 AC4 explicit-success-progress-and-stdout-byte-identical"

  # A derived cwd mapping uses the prepare leg between cwd-map and mktemp.
  T1090_FAKE_REMOTE="$TMP/t1090-fake-remote"
  mkdir -p "$T1090_FAKE_REMOTE/remote/lrepo.wt"
  set +e
  ( T1090_HOSTS_OVERRIDE="$T1090_HOSTS_SUFFIX" T1090_CWD="${T1090_SUFFIX_ROOT}.wt" \
    WRK_FAKE_REMOTE="$T1090_FAKE_REMOTE" t1090_spawn ) \
    >"$TMP/t1090-prepare-success.out" 2>"$TMP/t1090-prepare-success.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] ||
    fail "AC4 derived cwd success: prepare should pass, got rc=$t1090_rc: $(cat "$TMP/t1090-prepare-success.err")"
  t1090_check_steps "$TMP/t1090-prepare-success.err" desktop t1090-derived-success \
    probe cwd-map prepare mktemp scp "remote wrk"
  echo "PASS t1090 AC4 derived-cwd-prepare-progress"

  # t1090_spawn execs env so this test's PID is the wrk process itself. Cut it
  # off while the delegated remote wrk is sleeping; stderr must end at the
  # last reached step and wait must report SIGTERM for that exact PID.
  ( T1090_SSH_SCENARIO=remote-sleep T1090_REMOTE_SLEEP_SECONDS=5 t1090_spawn ) \
    >"$TMP/t1090-cutoff.out" 2>"$TMP/t1090-cutoff.err" &
  t1090_cutoff_pid=$!
  t1090_cutoff_seen=0
  for ((t1090_wait = 0; t1090_wait < 100; t1090_wait++)); do
    if grep -qE "^wrk: remote host 'desktop' step remote wrk elapsed=[0-9]+s$" "$TMP/t1090-cutoff.err"; then
      t1090_cutoff_seen=1
      break
    fi
    sleep 0.02
  done
  if [[ "$t1090_cutoff_seen" -ne 1 ]]; then
    kill -TERM "$t1090_cutoff_pid" 2>/dev/null || true
    wait "$t1090_cutoff_pid" 2>/dev/null || true
    fail "T3 cutoff: remote wrk progress line did not arrive: $(cat "$TMP/t1090-cutoff.err")"
  fi
  kill -TERM "$t1090_cutoff_pid"
  set +e
  wait "$t1090_cutoff_pid"
  t1090_cutoff_rc=$?
  set -e
  [[ "$t1090_cutoff_rc" -eq 143 ]] ||
    fail "T3 cutoff: expected the started wrk PID to exit on SIGTERM (rc=143), got $t1090_cutoff_rc"
  t1090_cutoff_last="$(tail -n 1 "$TMP/t1090-cutoff.err")"
  printf '%s\n' "$t1090_cutoff_last" | grep -Eq "^wrk: remote host 'desktop' step remote wrk elapsed=[0-9]+s$" ||
    fail "T3 cutoff: stderr must end at remote wrk after signal (rc=$t1090_cutoff_rc): $(cat "$TMP/t1090-cutoff.err")"
  echo "PASS t1090 T3 cutoff-ends-at-remote-wrk"

  # AC5 invariants as assertion-RED mutants.
  # M1 'a remote failure is never silent': dropping the stderr relay and the
  # failure-mode stdout routing must turn AC1 red.
  T1090_M1="$TMP/t1090-wrk-no-relay"
  # shellcheck disable=SC2016 # the sed patterns are bin/wrk source text, not expansions
  sed -e 's/spillover_relay_remote_err "\$remote_err"/:/' \
      -e 's/spillover_emit_host "\$host" "\$out" "\$rc"/spillover_emit_host "$host" "$out"/' \
      "$WRK" >"$T1090_M1"
  chmod +x "$T1090_M1"
  # shellcheck disable=SC2016 # the grep pattern is bin/wrk source text
  grep -qF 'spillover_emit_host "$host" "$out"' "$T1090_M1" || fail 'M1 mutant did not apply'
  set +e
  ( T1090_WRK="$T1090_M1" T1090_SSH_SCENARIO=remote-die-stderr t1090_spawn ) >"$TMP/t1090-m1.out" 2>"$TMP/t1090-m1.err"
  set -e
  if grep -qF "hk task 1037 is already bound to job 'other-job'" "$TMP/t1090-m1.err"; then
    fail "M1: dropping the remote relay must turn AC1 red, but the die line survived"
  fi
  echo "PASS t1090 M1: silent-failure mutant goes RED (AC1 assertion: remote die line absent from stderr)"

  # M2 'the success path is unchanged': also forwarding remote stdout to stderr
  # on a successful leg must turn AC4 red.
  T1090_M2="$TMP/t1090-wrk-stdout-forward"
  # shellcheck disable=SC2016 # the sed pattern is bin/wrk source text, not an expansion site
  sed 's/spillover_emit_host "\$host" "\$out" "\$rc"/cat "\$out" >\&2; spillover_emit_host "$host" "$out" "$rc"/' \
      "$WRK" >"$T1090_M2"
  chmod +x "$T1090_M2"
  # shellcheck disable=SC2016 # the grep pattern is mutant source text
  grep -qF 'cat "$out" >&2' "$T1090_M2" || fail 'M2 mutant did not apply'
  set +e
  ( T1090_WRK="$T1090_M2" t1090_spawn ) >"$TMP/t1090-m2.out" 2>"$TMP/t1090-m2.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] || fail "M2: mutant spawn itself failed (rc=$t1090_rc)"
  if cmp -s "$TMP/t1090-ac4.want" "$TMP/t1090-m2.out" && [[ ! -s "$TMP/t1090-m2.err" ]]; then
    fail "M2: forwarding stdout on success must turn AC4 red, but output stayed identical"
  fi
  echo "PASS t1090 M2: stdout-on-success mutant goes RED (AC4 assertion: stderr no longer empty)"

  # -- #1154: under --host auto a remote config error (rc 70) stops the round --
  # A remote wrk's own fail-closed answer (its quota gate refusing a malformed
  # [hub] config on the execution host) must never reach the local fallback —
  # the spawning host may be closed to spawns. Transport legs are normalized
  # away from 70, so a router-visible 70 is always the remote wrk's own answer.
  T1154_REMOTE_MSG='wrk: [hub] quota_gate accepts only "local"; refusing spawn'
  T1154_ATTR_DESKTOP="wrk: remote host 'desktop' refused the spawn with a config error (rc=70); not falling back to local"
  T1154_ATTR_MAC_WORK="wrk: remote host 'mac-work' refused the spawn with a config error (rc=70); not falling back to local"

  # AC1: the first candidate's remote wrk exits 70 — the round returns 70,
  # tries no second candidate and never runs a local spawn_cmd; the remote's
  # message and the attribution line land on stderr exactly once.
  rm -f "$TMP/t1090-herdr.log" "$TMP/t1090-ssh.log"
  set +e
  ( T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_SCENARIO_DESKTOP=remote-config-refused \
      T1090_SSH_SCENARIO_MAC_WORK=ok t1090_spawn ) >"$TMP/t1154-ac1.out" 2>"$TMP/t1154-ac1.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 70 ]] ||
    fail "1154 AC1: a remote config error must return rc 70, got $t1090_rc: $(cat "$TMP/t1154-ac1.err")"
  # The local pressure probe itself calls `herdr agent list`; a local pane
  # exists only once `tab create` runs.
  ! grep -q 'tab create' "$TMP/t1090-herdr.log" ||
    fail "1154 AC1: a remote config error landed a local pane: $(cat "$TMP/t1090-herdr.log")"
  [[ ! -s "$TMP/t1154-ac1.out" ]] ||
    fail "1154 AC1: a refused spawn must not write to stdout: $(cat "$TMP/t1154-ac1.out")"
  grep -q 'desktop' "$TMP/t1090-ssh.log" ||
    fail "1154 AC1: the first candidate was never tried: $(cat "$TMP/t1090-ssh.log" 2>/dev/null)"
  ! grep -q 'mac-work' "$TMP/t1090-ssh.log" ||
    fail "1154 AC1: the round tried the second candidate after rc 70: $(cat "$TMP/t1090-ssh.log")"
  [[ "$(grep -cxF "$T1154_REMOTE_MSG" "$TMP/t1154-ac1.err")" -eq 1 ]] ||
    fail "1154 AC1: the remote refusal line must appear exactly once: $(cat "$TMP/t1154-ac1.err")"
  [[ "$(grep -cxF "$T1154_ATTR_DESKTOP" "$TMP/t1154-ac1.err")" -eq 1 ]] ||
    fail "1154 AC1: the attribution line must appear exactly once: $(cat "$TMP/t1154-ac1.err")"
  ! grep -qF 'no remote spill-over candidate completed' "$TMP/t1154-ac1.err" ||
    fail "1154 AC1: the fallback warning must not fire on a config stop: $(cat "$TMP/t1154-ac1.err")"
  echo "PASS t1154 AC1 remote-config-error-stops-round"

  # A transport failure on candidate one still moves on to the next remote —
  # the control case the M2 mutant turns RED by mapping that 255 to 70.
  rm -f "$TMP/t1090-herdr.log" "$TMP/t1090-ssh.log"
  set +e
  ( T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_SCENARIO_DESKTOP=probe-unreachable \
      T1090_SSH_SCENARIO_MAC_WORK=ok t1090_spawn ) >"$TMP/t1154-tf.out" 2>"$TMP/t1154-tf.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] ||
    fail "1154 transport-failover: expected rc=0, got $t1090_rc: $(cat "$TMP/t1154-tf.err")"
  cmp -s "$TMP/t1090-auto1.want" "$TMP/t1154-tf.out" ||
    fail "1154 transport-failover: expected the mac-work OK line: $(cat "$TMP/t1154-tf.out")"
  echo "PASS t1154 transport-failover-control"

  # AC2: a transport failure on candidate one moves on; the second
  # candidate's remote wrk config error (rc 70) still stops the round.
  rm -f "$TMP/t1090-herdr.log" "$TMP/t1090-ssh.log"
  set +e
  ( T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_SCENARIO_DESKTOP=probe-unreachable \
      T1090_SSH_SCENARIO_MAC_WORK=remote-config-refused t1090_spawn ) >"$TMP/t1154-ac2.out" 2>"$TMP/t1154-ac2.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 70 ]] ||
    fail "1154 AC2: rc must be 70 after the second candidate's config error, got $t1090_rc: $(cat "$TMP/t1154-ac2.err")"
  ! grep -q 'tab create' "$TMP/t1090-herdr.log" ||
    fail "1154 AC2: a remote config error landed a local pane: $(cat "$TMP/t1090-herdr.log")"
  [[ ! -s "$TMP/t1154-ac2.out" ]] ||
    fail "1154 AC2: a refused spawn must not write to stdout: $(cat "$TMP/t1154-ac2.out")"
  grep -qF "remote host 'desktop' probe failed (ssh-unreachable, rc=255)" "$TMP/t1154-ac2.err" ||
    fail "1154 AC2: desktop probe line missing: $(cat "$TMP/t1154-ac2.err")"
  [[ "$(grep -cxF "$T1154_ATTR_MAC_WORK" "$TMP/t1154-ac2.err")" -eq 1 ]] ||
    fail "1154 AC2: the mac-work attribution line must appear exactly once: $(cat "$TMP/t1154-ac2.err")"
  ! grep -qF 'no remote spill-over candidate completed' "$TMP/t1154-ac2.err" ||
    fail "1154 AC2: the fallback warning must not fire on a config stop: $(cat "$TMP/t1154-ac2.err")"
  echo "PASS t1154 AC2 transport-failure-then-config-error-stops"

  # AC3: all-remote non-stop failures keep main's local fallback — remote rc 1
  # on both candidates, then a remote quota refusal (rc 4) on the first.
  rm -f "$TMP/t1090-herdr.log" "$TMP/t1090-ssh.log"
  set +e
  ( T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_SCENARIO_DESKTOP=remote-die-stderr \
      T1090_SSH_SCENARIO_MAC_WORK=remote-die-stderr t1090_spawn ) >"$TMP/t1154-ac3.out" 2>"$TMP/t1154-ac3.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] ||
    fail "1154 AC3: non-stop remote failures must keep the local fallback, got rc=$t1090_rc: $(cat "$TMP/t1154-ac3.err")"
  grep -q 'host=local' "$TMP/t1154-ac3.out" ||
    fail "1154 AC3: expected a local landing on stdout: $(cat "$TMP/t1154-ac3.out")"
  grep -qF 'no remote spill-over candidate completed' "$TMP/t1154-ac3.err" ||
    fail "1154 AC3: the fallback warning is missing: $(cat "$TMP/t1154-ac3.err")"
  grep -q 'tab create' "$TMP/t1090-herdr.log" ||
    fail "1154 AC3: the local fallback never created a pane: $(cat "$TMP/t1090-herdr.log")"
  grep -q 'mac-work' "$TMP/t1090-ssh.log" ||
    fail "1154 AC3: the round never tried the second candidate"

  rm -f "$TMP/t1090-herdr.log" "$TMP/t1090-ssh.log"
  set +e
  ( T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_SCENARIO_DESKTOP=remote-die-stderr T1090_REMOTE_RC=4 \
      T1090_SSH_SCENARIO_MAC_WORK=probe-unreachable t1090_spawn ) >"$TMP/t1154-ac3b.out" 2>"$TMP/t1154-ac3b.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] ||
    fail "1154 AC3 rc4: a remote rc 4 must keep the local fallback, got rc=$t1090_rc: $(cat "$TMP/t1154-ac3b.err")"
  grep -q 'host=local' "$TMP/t1154-ac3b.out" ||
    fail "1154 AC3 rc4: expected a local landing on stdout: $(cat "$TMP/t1154-ac3b.out")"
  grep -qF 'no remote spill-over candidate completed' "$TMP/t1154-ac3b.err" ||
    fail "1154 AC3 rc4: the fallback warning is missing: $(cat "$TMP/t1154-ac3b.err")"
  echo "PASS t1154 AC3 non-stop-rcs-still-fall-back"

  # AC4: explicit --host NAME is unchanged — the remote's own words stream
  # live, the named-host failure line keeps its main shape, and rc propagates.
  rm -f "$TMP/t1090-herdr.log" "$TMP/t1090-ssh.log"
  set +e
  ( T1090_SSH_SCENARIO=remote-config-refused t1090_spawn ) >"$TMP/t1154-ac4.out" 2>"$TMP/t1154-ac4.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 70 ]] ||
    fail "1154 AC4: an explicit host must propagate rc 70, got $t1090_rc: $(cat "$TMP/t1154-ac4.err")"
  grep -qF "$T1154_REMOTE_MSG" "$TMP/t1154-ac4.err" ||
    fail "1154 AC4: the remote refusal line is missing: $(cat "$TMP/t1154-ac4.err")"
  grep -qF "wrk: remote spawn on explicit host 'desktop' failed (rc=70) at step 'remote wrk'; no local fallback — fix the remote or use --host local" "$TMP/t1154-ac4.err" ||
    fail "1154 AC4: the explicit-host failure line changed shape: $(cat "$TMP/t1154-ac4.err")"
  ! grep -qF 'refused the spawn with a config error' "$TMP/t1154-ac4.err" ||
    fail "1154 AC4: the auto attribution line must not appear on an explicit host: $(cat "$TMP/t1154-ac4.err")"
  ! grep -q 'tab create' "$TMP/t1090-herdr.log" ||
    fail "1154 AC4: an explicit-host refusal must not create a local pane"
  echo "PASS t1154 AC4 explicit-host-unchanged"

  # AC5 assertion-RED mutants.
  # M1 "a remote config error never lands a local pane": dropping 70 from the
  # stop set reproduces the #1146 N4 bug — the round falls through, the local
  # fallback lands a pane, and the AC1 no-local-pane assertion goes RED.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant t1154-no-70-stop \
    '      "$WRK_EXIT_CONFIG_REFUSED")' \
    '      970)'
  rm -f "$TMP/t1090-herdr.log" "$TMP/t1090-ssh.log"
  set +e
  ( T1090_WRK="$TMP/mut-wrk-t1154-no-70-stop" \
      T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_SCENARIO_DESKTOP=remote-config-refused \
      T1090_SSH_SCENARIO_MAC_WORK=probe-unreachable t1090_spawn ) >"$TMP/t1154-m1.out" 2>"$TMP/t1154-m1.err"
  t1090_rc=$?
  set -e
  if [[ "$t1090_rc" -eq 70 ]]; then
    fail "1154 M1 mutant survived: dropping 70 from the stop set still stopped the round"
  fi
  grep -q 'host=local' "$TMP/t1154-m1.out" ||
    fail "1154 M1: the mutant should land the local fallback pane main produced"
  grep -q 'tab create' "$TMP/t1090-herdr.log" ||
    fail "1154 M1: the mutant should show the forbidden local pane creation"
  echo "PASS t1154 M1: no-70-stop mutant goes RED (AC1 assertion 'a remote config error lands no local pane' fails: rc=$t1090_rc, local pane created)"

  # M2 "only the remote wrk's own 70 stops the round": the mutant maps every
  # transport-leg failure to 70, so a dead probe (ssh 255) is misread as a
  # config refusal — the transport-failover control above goes RED.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant t1154-transport-to-70 \
    "    *) printf '%s' \"\$1\" ;;" \
    "    *) printf '70' ;;"
  rm -f "$TMP/t1090-herdr.log" "$TMP/t1090-ssh.log"
  set +e
  ( T1090_WRK="$TMP/mut-wrk-t1154-transport-to-70" \
      T1090_HOST_ARG=auto T1090_HOSTS_OVERRIDE="$T1090_HOSTS_AUTO" \
      T1090_LOAD_FILE="$T1090_LOAD_HIGH" \
      T1090_SSH_SCENARIO_DESKTOP=probe-unreachable \
      T1090_SSH_SCENARIO_MAC_WORK=ok t1090_spawn ) >"$TMP/t1154-m2.out" 2>"$TMP/t1154-m2.err"
  t1090_rc=$?
  set -e
  if [[ "$t1090_rc" -eq 0 ]] && cmp -s "$TMP/t1090-auto1.want" "$TMP/t1154-m2.out"; then
    fail "1154 M2 mutant survived: a transport failure still failed over to mac-work"
  fi
  [[ "$t1090_rc" -eq 70 ]] ||
    fail "1154 M2: the mutant should stop the round with rc 70, got $t1090_rc"
  ! grep -q 'mac-work' "$TMP/t1090-ssh.log" ||
    fail "1154 M2: the mutant must stop before the second candidate"
  echo "PASS t1154 M2: transport-to-70 mutant goes RED (transport-failover assertion 'rc 0 + mac-work OK line' fails: rc=$t1090_rc)"
}

# Slice gate: WRK_TEST_ONLY_REMOTE_ERR=1 runs only this section after the
# shared fixture setup — the remote legs are fakes, so no real ssh/spawn runs.
if [[ "${WRK_TEST_ONLY_REMOTE_ERR:-0}" -eq 1 ]]; then
  run_t1090_remote_err_tests
  exit 0
fi
run_t1090_remote_err_tests

run_t1155_local_spawn_off_tests() {
  # -- #1155: [local] spawn = false closes this host to local spawns ---------
  # A host-level switch the operator sets per machine. When it is off, --host
  # auto treats local as an unavailable candidate, --host local refuses before
  # any side effect (rc 80), and a remote host with the flag answers its
  # delegated spawn with 80 — an answer that must not stop the spawning
  # host's candidate round.
  T1155_LOAD="$TMP/t1155-loadavg"
  printf '0.20 0.10 0.10 1/1 1\n' >"$T1155_LOAD"
  T1155_LOAD_HIGH="$TMP/t1155-loadavg-high"
  printf '4.00 4.00 4.00 1/1 1\n' >"$T1155_LOAD_HIGH"
  # Same private arbiter inbox convention as the t1090 block.
  T1155_INBOX="$TMP/t1155-inbox" T1155_XDG="$TMP/t1155-xdg"
  env ARBITER_INBOX_ROOT="$T1155_INBOX" XDG_DATA_HOME="$T1155_XDG" \
    "$ARBITER" claim --job t1155-seed --agent-label t1155-seed --lane t1155 --t T1 >/dev/null

  # One two-remote topology under the three flag states the contract
  # distinguishes: refused (off), explicit allow (on) and the absent key,
  # which must stay byte-identical to main.
  T1155_HOSTS_OFF="$TMP/t1155-hosts-off.toml"
  T1155_HOSTS_ON="$TMP/t1155-hosts-on.toml"
  T1155_HOSTS_ABSENT="$TMP/t1155-hosts-absent.toml"
  printf '%s\n' '[local]' 'spawn = false' 'max_load_ratio = 0.5' 'max_active = 4' '' \
    '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' '' \
    '[hosts.mac-work]' 'ssh = "mac-work"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 2' >"$T1155_HOSTS_OFF"
  sed 's/^spawn = false$/spawn = true/' "$T1155_HOSTS_OFF" >"$T1155_HOSTS_ON"
  sed '/^spawn = false$/d' "$T1155_HOSTS_OFF" >"$T1155_HOSTS_ABSENT"
  # A hub-configured variant of the disabled host for the placement arm that
  # consults panewire first.
  T1155_HOSTS_OFF_HUB="$TMP/t1155-hosts-off-hub.toml"
  printf '%s\n' '[local]' 'spawn = false' 'max_load_ratio = 0.5' 'max_active = 4' '' \
    '[hub]' 'hub_url = "https://hub.invalid"' 'hub_token_env = "/tmp/t1155-token.env"' '' \
    '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' '' \
    '[hosts.mac-work]' 'ssh = "mac-work"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 2' >"$T1155_HOSTS_OFF_HUB"

  t1155_spawn() {  # env knobs mirror t1090_spawn; T1155_* prefixed
    # T1155_TASK rides a real --task so a surviving spawn must leave an hk
    # claim line; T1155_ARBITER points ARBITER_BIN elsewhere (e.g. absent).
    local t1155_task_args=()
    [[ -z "${T1155_TASK:-}" ]] || t1155_task_args=(--task "$T1155_TASK")
    env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
      ARBITER_BIN="${T1155_ARBITER:-$ARBITER}" ARBITER_INBOX_ROOT="$T1155_INBOX" XDG_DATA_HOME="$T1155_XDG" \
      WRK_HOSTS_CONFIG="${T1155_HOSTS_OVERRIDE:-$T1155_HOSTS_OFF}" \
      WRK_PROC_LOADAVG="${T1155_LOAD_FILE:-$T1155_LOAD}" \
      WRK_TEST_NCPU=4 WRK_TEST_THROTTLED=0 \
      WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/t1155-herdr.log" \
      WRK_SPILLOVER_LOG="$TMP/t1155-spillover.log" \
      PANEWIRE_BIN="${T1155_PANEWIRE:-$PANEWIRE}" WRK_WAKE_LOG="$TMP/t1155-wake.log" \
      WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" \
      WRK_SCP_BIN="${T1155_SCP:-$ROOT/tests/fixtures/spillover-scp}" \
      WRK_SSH_LOG="$TMP/t1155-ssh.log" WRK_SCP_LOG="$TMP/t1155-scp.log" \
      WRK_SSH_SCENARIO="${T1155_SSH_SCENARIO:-ok}" \
      WRK_SSH_SCENARIO_DESKTOP="${T1155_SSH_SCENARIO_DESKTOP:-}" \
      WRK_SSH_SCENARIO_MAC_WORK="${T1155_SSH_SCENARIO_MAC_WORK:-}" \
      WRK_SCP_SCENARIO="${T1155_SCP_SCENARIO:-ok}" \
      WRK_REMOTE_RC="${T1155_REMOTE_RC:-}" \
      WRK_REMOTE_STDERR_LINE="${T1155_REMOTE_STDERR_LINE:-}" \
      WRK_PLACE_SCENARIO="${T1155_PLACE_SCENARIO:-unavailable}" \
      HK_LOG="${T1155_HK_LOG:-$TMP/t1155-hk.log}" \
      "${T1155_WRK:-$WRK}" spawn -c "${T1155_CWD:-$ROOT}" -m codex-luna -p "$PROMPT" \
      -w w -l fixture --t T1 --job "${T1155_JOB:-t1155-$RANDOM-$RANDOM}" --host "${T1155_HOST_ARG:-desktop}" \
      ${t1155_task_args[@]+"${t1155_task_args[@]}"}
  }

  local t1155_rc t1155_last

  # AC1: local pressure is low, which on main spawns locally — with the flag
  # off the round uses the first remote instead and never opens a local pane.
  rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log"
  set +e
  ( T1155_HOST_ARG=auto T1155_SSH_SCENARIO_DESKTOP=ok \
      T1155_SSH_SCENARIO_MAC_WORK=ok t1155_spawn ) >"$TMP/t1155-ac1.out" 2>"$TMP/t1155-ac1.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 0 ]] ||
    fail "1155 AC1: a disabled local must hand the spawn to a remote, got rc=$t1155_rc: $(cat "$TMP/t1155-ac1.err")"
  printf '%s\n' 'OK pane=desktop:p7 host=desktop model=codex-luna label=fixture status=working landed=yes' >"$TMP/t1155-ac1.want"
  cmp -s "$TMP/t1155-ac1.want" "$TMP/t1155-ac1.out" ||
    fail "1155 AC1: expected the desktop OK line: $(cat "$TMP/t1155-ac1.out")"
  ! grep -q 'tab create' "$TMP/t1155-herdr.log" ||
    fail "1155 AC1: a local pane was created on a disabled host: $(cat "$TMP/t1155-herdr.log")"
  [[ ! -s "$TMP/t1155-ac1.err" ]] ||
    fail "1155 AC1: skipped-local diagnostics must stay silent on success: $(cat "$TMP/t1155-ac1.err")"
  grep -q 'reason=local-spawn-disabled' "$TMP/t1155-spillover.log" ||
    fail "1155 AC1: the spill-over log must name the flag reason: $(cat "$TMP/t1155-spillover.log")"
  echo "PASS t1155 AC1 disabled-local-auto-uses-remote"

  # AC2: every remote fails — the all-fail path refuses rc 80 with one
  # attributed line per host and the disabled line last, never the local
  # fallback.
  rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log"
  set +e
  ( T1155_HOST_ARG=auto \
      T1155_SSH_SCENARIO_DESKTOP=probe-unreachable \
      T1155_SSH_SCENARIO_MAC_WORK=remote-die-stderr t1155_spawn ) >"$TMP/t1155-ac2.out" 2>"$TMP/t1155-ac2.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 80 ]] ||
    fail "1155 AC2: all-fail on a disabled host must refuse rc=80, got $t1155_rc: $(cat "$TMP/t1155-ac2.err")"
  [[ ! -s "$TMP/t1155-ac2.out" ]] ||
    fail "1155 AC2: a refused spawn must not write stdout: $(cat "$TMP/t1155-ac2.out")"
  ! grep -q 'tab create' "$TMP/t1155-herdr.log" ||
    fail "1155 AC2: a local pane was created on a disabled host"
  grep -qF "remote host 'desktop' probe failed (ssh-unreachable, rc=255)" "$TMP/t1155-ac2.err" ||
    fail "1155 AC2: desktop probe line missing: $(cat "$TMP/t1155-ac2.err")"
  grep -qF "remote host 'desktop' failed (rc=255) at step 'probe'" "$TMP/t1155-ac2.err" ||
    fail "1155 AC2: desktop summary missing: $(cat "$TMP/t1155-ac2.err")"
  grep -qF "hk task 1037 is already bound to job 'other-job'" "$TMP/t1155-ac2.err" ||
    fail "1155 AC2: mac-work refusal line missing: $(cat "$TMP/t1155-ac2.err")"
  grep -qF "remote host 'mac-work' failed (rc=1) at step 'remote wrk'" "$TMP/t1155-ac2.err" ||
    fail "1155 AC2: mac-work summary missing: $(cat "$TMP/t1155-ac2.err")"
  ! grep -qF 'no remote spill-over candidate completed' "$TMP/t1155-ac2.err" ||
    fail "1155 AC2: the local-fallback warning must not fire on a disabled host: $(cat "$TMP/t1155-ac2.err")"
  t1155_last="$(tail -n 1 "$TMP/t1155-ac2.err")"
  [[ "$t1155_last" == 'wrk: local spawns are disabled on this host ([local] spawn = false); no remote candidate completed.' ]] ||
    fail "1155 AC2: last line must be the disabled answer, got: $t1155_last"
  echo "PASS t1155 AC2 all-fail-refuses-80"

  # AC3: --host local refuses before any side effect — no pane, no arbiter
  # record, no hk claim. A minted --task rides along so a claim written
  # before the refusal would land in the log (the t1163 claim control below
  # proves a surviving spawn does claim).
  local t1155_ac3_task
  t1155_ac3_task="$(mint_task)"
  rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ac3-hk.log"
  set +e
  ( T1155_HOST_ARG=local T1155_JOB=t1155-ac3 T1155_TASK="$t1155_ac3_task" \
      T1155_HK_LOG="$TMP/t1155-ac3-hk.log" \
      t1155_spawn ) >"$TMP/t1155-ac3.out" 2>"$TMP/t1155-ac3.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 80 ]] ||
    fail "1155 AC3: --host local on a disabled host must refuse rc=80, got $t1155_rc: $(cat "$TMP/t1155-ac3.err")"
  [[ ! -s "$TMP/t1155-ac3.out" ]] ||
    fail "1155 AC3: a refused spawn must not write stdout: $(cat "$TMP/t1155-ac3.out")"
  grep -qF 'wrk: local spawns are disabled on this host ([local] spawn = false)' "$TMP/t1155-ac3.err" ||
    fail "1155 AC3: the refusal must name the key: $(cat "$TMP/t1155-ac3.err")"
  { [[ ! -e "$TMP/t1155-herdr.log" ]] || ! grep -q 'tab create' "$TMP/t1155-herdr.log"; } ||
    fail "1155 AC3: the refusal created a local pane"
  [[ ! -e "$T1155_INBOX/t1155-ac3" ]] ||
    fail "1155 AC3: the refusal left an arbiter record for t1155-ac3"
  { [[ ! -e "$TMP/t1155-ac3-hk.log" ]] || ! grep -q "claim id=$t1155_ac3_task " "$TMP/t1155-ac3-hk.log"; } ||
    fail "1155 AC3: the refusal claimed task $t1155_ac3_task: $(cat "$TMP/t1155-ac3-hk.log")"
  echo "PASS t1155 AC3 host-local-refused-before-side-effects"

  # AC4: the REMOTE's own disabled answer (its [local] spawn = false answering
  # the delegated --host local with rc 80) is not a stop-set member — the
  # round moves on to the next remote.
  rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log"
  set +e
  ( T1155_HOST_ARG=auto T1155_HOSTS_OVERRIDE="$T1155_HOSTS_ABSENT" \
      T1155_LOAD_FILE="$T1155_LOAD_HIGH" \
      T1155_SSH_SCENARIO_DESKTOP=remote-spawn-disabled \
      T1155_SSH_SCENARIO_MAC_WORK=ok t1155_spawn ) >"$TMP/t1155-ac4.out" 2>"$TMP/t1155-ac4.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 0 ]] ||
    fail "1155 AC4: a remote 80 answer must fail over, got rc=$t1155_rc: $(cat "$TMP/t1155-ac4.err")"
  printf '%s\n' 'OK pane=mac-work:p7 host=mac-work model=codex-luna label=fixture status=working landed=yes' >"$TMP/t1155-ac4.want"
  cmp -s "$TMP/t1155-ac4.want" "$TMP/t1155-ac4.out" ||
    fail "1155 AC4: expected the mac-work OK line: $(cat "$TMP/t1155-ac4.out")"
  grep -q 'wrk spawn' "$TMP/t1155-ssh.log" ||
    fail "1155 AC4: desktop's delegated-spawn leg never ran: $(cat "$TMP/t1155-ssh.log")"
  [[ ! -s "$TMP/t1155-ac4.err" ]] ||
    fail "1155 AC4: the skipped remote's diagnostics must stay silent on success: $(cat "$TMP/t1155-ac4.err")"
  echo "PASS t1155 AC4 remote-80-fails-over"

  # A remote 80 under an explicit --host NAME keeps the named-host contract:
  # the rc propagates and the advice does not suggest a refused override.
  rm -f "$TMP/t1155-ssh.log"
  set +e
  ( T1155_HOST_ARG=desktop T1155_SSH_SCENARIO_DESKTOP=remote-spawn-disabled \
      t1155_spawn ) >"$TMP/t1155-ac4b.out" 2>"$TMP/t1155-ac4b.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 80 ]] ||
    fail "1155 AC4b: an explicit host must propagate the remote 80, got $t1155_rc: $(cat "$TMP/t1155-ac4b.err")"
  grep -qF "wrk: local spawns are disabled on this host ([local] spawn = false); refusing --host local" "$TMP/t1155-ac4b.err" ||
    fail "1155 AC4b: the remote's own refusal line is missing: $(cat "$TMP/t1155-ac4b.err")"
  grep -qF "fix the remote (local spawns are disabled on this host: [local] spawn = false)" "$TMP/t1155-ac4b.err" ||
    fail "1155 AC4b: the explicit-host line must not advise --host local: $(cat "$TMP/t1155-ac4b.err")"
  echo "PASS t1155 AC4b explicit-host-remote-80"

  # AC5a: absent key and spawn = true are byte-identical to main — a forced
  # local spawn lands the pinned OK line, and stderr carries the same
  # arbiter-record progress line main writes.
  rm -f "$TMP/t1155-herdr.log"
  for variant in absent on; do
    cfg="$T1155_HOSTS_ABSENT"; [[ "$variant" == on ]] && cfg="$T1155_HOSTS_ON"
    set +e
    ( T1155_HOST_ARG=local T1155_HOSTS_OVERRIDE="$cfg" \
        T1155_JOB="t1155-local-$variant" t1155_spawn ) >"$TMP/t1155-ac5a-$variant.out" 2>"$TMP/t1155-ac5a-$variant.err"
    t1155_rc=$?
    set -e
    [[ "$t1155_rc" -eq 0 ]] ||
      fail "1155 AC5 $variant-local: expected rc=0, got $t1155_rc: $(cat "$TMP/t1155-ac5a-$variant.err")"
    grep -qxF "OK pane=w:p1 host=local model=codex-luna label=fixture status=working landed=yes job=t1155-local-$variant quota_record=codex/quota_pool" \
      "$TMP/t1155-ac5a-$variant.out" ||
      fail "1155 AC5 $variant-local: stdout differs from the pinned OK line: $(cat "$TMP/t1155-ac5a-$variant.out")"
    grep -qxF "wrk: arbiter quota-pool record pool=codex profile=codex-luna-max launch_profile=codex-luna@medium job=t1155-local-$variant" \
      "$TMP/t1155-ac5a-$variant.err" ||
      fail "1155 AC5 $variant-local: stderr differs from the pinned arbiter line: $(cat "$TMP/t1155-ac5a-$variant.err")"
  done
  # The two runs differ only in the minted job id.
  sed 's/job=[^ ]*/job=J/' "$TMP/t1155-ac5a-absent.out" >"$TMP/t1155-ac5a-absent.out.norm"
  sed 's/job=[^ ]*/job=J/' "$TMP/t1155-ac5a-on.out" >"$TMP/t1155-ac5a-on.out.norm"
  cmp -s "$TMP/t1155-ac5a-absent.out.norm" "$TMP/t1155-ac5a-on.out.norm" ||
    fail "1155 AC5: absent-key and spawn=true local stdout differ"
  sed 's/job=[^ ]*/job=J/' "$TMP/t1155-ac5a-absent.err" >"$TMP/t1155-ac5a-absent.err.norm"
  sed 's/job=[^ ]*/job=J/' "$TMP/t1155-ac5a-on.err" >"$TMP/t1155-ac5a-on.err.norm"
  cmp -s "$TMP/t1155-ac5a-absent.err.norm" "$TMP/t1155-ac5a-on.err.norm" ||
    fail "1155 AC5: absent-key and spawn=true local stderr differ"

  # AC5b: the auto all-fail local fallback is equivalent too — same
  # per-candidate diagnostics, the same fallback warning, a local landing.
  for variant in absent on; do
    cfg="$T1155_HOSTS_ABSENT"; [[ "$variant" == on ]] && cfg="$T1155_HOSTS_ON"
    rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log"
    set +e
    ( T1155_HOST_ARG=auto T1155_HOSTS_OVERRIDE="$cfg" \
        T1155_LOAD_FILE="$T1155_LOAD_HIGH" T1155_JOB="t1155-fb-$variant" \
        T1155_SSH_SCENARIO_DESKTOP=probe-unreachable \
        T1155_SSH_SCENARIO_MAC_WORK=probe-herdr-missing t1155_spawn ) \
      >"$TMP/t1155-ac5b-$variant.out" 2>"$TMP/t1155-ac5b-$variant.err"
    t1155_rc=$?
    set -e
    [[ "$t1155_rc" -eq 0 ]] ||
      fail "1155 AC5 $variant-fallback: expected rc=0, got $t1155_rc: $(cat "$TMP/t1155-ac5b-$variant.err")"
    grep -q 'host=local' "$TMP/t1155-ac5b-$variant.out" ||
      fail "1155 AC5 $variant-fallback: expected a local landing on stdout: $(cat "$TMP/t1155-ac5b-$variant.out")"
    grep -qF 'no remote spill-over candidate completed; falling back to local' "$TMP/t1155-ac5b-$variant.err" ||
      fail "1155 AC5 $variant-fallback: fallback warning missing: $(cat "$TMP/t1155-ac5b-$variant.err")"
    grep -q 'tab create' "$TMP/t1155-herdr.log" ||
      fail "1155 AC5 $variant-fallback: the local fallback never created a pane"
  done
  # The two runs differ in the minted job id and elapsed seconds; everything
  # else must match between the absent key and an explicit true.
  sed 's/job=[^ ]*/job=J/' "$TMP/t1155-ac5b-absent.out" >"$TMP/t1155-ac5b-absent.out.norm"
  sed 's/job=[^ ]*/job=J/' "$TMP/t1155-ac5b-on.out" >"$TMP/t1155-ac5b-on.out.norm"
  cmp -s "$TMP/t1155-ac5b-absent.out.norm" "$TMP/t1155-ac5b-on.out.norm" ||
    fail "1155 AC5: absent-key and spawn=true fallback stdout differ"
  sed -e 's/job=[^ ]*/job=J/' -e 's/elapsed=[0-9]*s/elapsed=Ns/' \
    "$TMP/t1155-ac5b-absent.err" >"$TMP/t1155-ac5b-absent.err.norm"
  sed -e 's/job=[^ ]*/job=J/' -e 's/elapsed=[0-9]*s/elapsed=Ns/' \
    "$TMP/t1155-ac5b-on.err" >"$TMP/t1155-ac5b-on.err.norm"
  cmp -s "$TMP/t1155-ac5b-absent.err.norm" "$TMP/t1155-ac5b-on.err.norm" ||
    fail "1155 AC5: absent-key and spawn=true fallback stderr differ"
  echo "PASS t1155 AC5 absent-and-true-equivalent"

  # AC5c: any other value is a config error — bare or quoted, a non-boolean
  # refuses rc 70 naming the key. Quoted "true"/"false" are strings, not the
  # TOML booleans this key accepts (documented decision), so they refuse too.
  local bad_idx=0 bad_val bad_cfg
  for bad_val in '0' 'maybe' '"no"' '"true"' '"false"' ''; do
    bad_idx=$((bad_idx + 1))
    bad_cfg="$TMP/t1155-hosts-bad-$bad_idx.toml"
    sed "s/^spawn = false$/spawn = $bad_val/" "$T1155_HOSTS_OFF" >"$bad_cfg"
    set +e
    ( T1155_HOST_ARG=local T1155_HOSTS_OVERRIDE="$bad_cfg" \
        T1155_JOB="t1155-bad-$bad_idx" t1155_spawn ) >"$TMP/t1155-bad-$bad_idx.out" 2>"$TMP/t1155-bad-$bad_idx.err"
    t1155_rc=$?
    set -e
    [[ "$t1155_rc" -eq 70 ]] ||
      fail "1155 AC5 invalid '$bad_val': expected rc=70, got $t1155_rc: $(cat "$TMP/t1155-bad-$bad_idx.err")"
    grep -qF "[local] spawn accepts only the bare TOML booleans true or false" "$TMP/t1155-bad-$bad_idx.err" ||
      fail "1155 AC5 invalid '$bad_val': refusal must name key and accepted values: $(cat "$TMP/t1155-bad-$bad_idx.err")"
    [[ ! -s "$TMP/t1155-bad-$bad_idx.out" ]] ||
      fail "1155 AC5 invalid '$bad_val': refused spawn must not write stdout"
  done
  # An invalid value is a config error on every placement, not only local.
  set +e
  ( T1155_HOST_ARG=auto T1155_HOSTS_OVERRIDE="$TMP/t1155-hosts-bad-1.toml" \
      T1155_LOAD_FILE="$T1155_LOAD_HIGH" t1155_spawn ) >"$TMP/t1155-badauto.out" 2>"$TMP/t1155-badauto.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 70 ]] ||
    fail "1155 AC5 invalid auto: expected rc=70, got $t1155_rc: $(cat "$TMP/t1155-badauto.err")"
  echo "PASS t1155 AC5 invalid-values-refuse-70"

  # The hub arm honors the flag too: a placement reply picking local leaves
  # no eligible remote, so the round ends with the disabled answer, rc 80.
  rm -f "$TMP/t1155-herdr.log"
  set +e
  ( T1155_HOST_ARG=auto T1155_HOSTS_OVERRIDE="$T1155_HOSTS_OFF_HUB" \
      T1155_PANEWIRE="$ROOT/tests/fixtures/spillover-panewire" \
      T1155_PLACE_SCENARIO=local t1155_spawn ) >"$TMP/t1155-hublocal.out" 2>"$TMP/t1155-hublocal.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 80 ]] ||
    fail "1155 hub-local: a hub-picked local on a disabled host must refuse rc=80, got $t1155_rc: $(cat "$TMP/t1155-hublocal.err")"
  ! grep -q 'tab create' "$TMP/t1155-herdr.log" ||
    fail "1155 hub-local: a local pane was created on a disabled host"
  grep -qF 'wrk: local spawns are disabled on this host ([local] spawn = false); no remote candidate completed.' "$TMP/t1155-hublocal.err" ||
    fail "1155 hub-local: the disabled answer is missing: $(cat "$TMP/t1155-hublocal.err")"
  echo "PASS t1155 hub-picked-local-refused"

  # A normal hub decision for a remote is unaffected by the flag.
  rm -f "$TMP/t1155-herdr.log"
  set +e
  ( T1155_HOST_ARG=auto T1155_HOSTS_OVERRIDE="$T1155_HOSTS_OFF_HUB" \
      T1155_PANEWIRE="$ROOT/tests/fixtures/spillover-panewire" \
      T1155_PLACE_SCENARIO=advance T1155_SSH_SCENARIO_DESKTOP=ok \
      t1155_spawn ) >"$TMP/t1155-hubremote.out" 2>"$TMP/t1155-hubremote.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 0 ]] ||
    fail "1155 hub-remote: expected rc=0 on the hub-picked remote, got $t1155_rc: $(cat "$TMP/t1155-hubremote.err")"
  grep -q 'host=desktop' "$TMP/t1155-hubremote.out" ||
    fail "1155 hub-remote: expected the desktop OK line: $(cat "$TMP/t1155-hubremote.out")"
  echo "PASS t1155 hub-remote-unaffected"

  # -- #1154 S1: a transport leg answering rc 70 fails over, never stops -----
  # The probe is a transport leg; a 70 there is normalized to 1 like every
  # other non-admission transport rc, so the round reaches the next remote.
  rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log" "$TMP/t1155-calls"
  set +e
  ( WRK_SSH_CALL_COUNT_FILE="$TMP/t1155-calls" WRK_SSH_FAIL_CALLS=1 WRK_SSH_FAIL_CODE=70 \
      T1155_HOST_ARG=auto T1155_HOSTS_OVERRIDE="$T1155_HOSTS_ABSENT" \
      T1155_LOAD_FILE="$T1155_LOAD_HIGH" \
      T1155_SSH_SCENARIO_MAC_WORK=ok t1155_spawn ) >"$TMP/t1155-s1.out" 2>"$TMP/t1155-s1.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 0 ]] ||
    fail "1155 S1: a transport-70 must fail over to the next remote, got rc=$t1155_rc: $(cat "$TMP/t1155-s1.err")"
  cmp -s "$TMP/t1155-ac4.want" "$TMP/t1155-s1.out" ||
    fail "1155 S1: expected the mac-work OK line: $(cat "$TMP/t1155-s1.out")"
  [[ ! -s "$TMP/t1155-s1.err" ]] ||
    fail "1155 S1: skipped-host diagnostics must stay silent on success: $(cat "$TMP/t1155-s1.err")"
  echo "PASS t1155 S1 transport-70-fails-over"

  # -- assertion-RED mutants -------------------------------------------------
  # M1 "a host with local spawns disabled never lands a local pane under
  # auto" — the mutant keeps the local fallback. The flag is enforced twice
  # on that path (the tail guard and the spawn_cmd backstop), so the mutant
  # must bypass both for the regression to be observable.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant t1155-keep-fallback \
    '  if [[ "$LOCAL_SPAWN_ALLOWED" -eq 0 ]]; then' \
    '  if false; then'
  python3 - "$TMP/mut-wrk-t1155-keep-fallback" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
old = ('local_spawn_resolve || return\n'
       '  if [[ "${LOCAL_SPAWN_ALLOWED:-1}" -eq 0 ]]; then')
new = ('local_spawn_resolve || return\n'
       '  if false; then')
assert src.count(old) == 1, "mutant anchor not unique: %r" % old
open(p, "w", encoding="utf-8").write(src.replace(old, new))
PY
  rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log"
  set +e
  ( T1155_WRK="$TMP/mut-wrk-t1155-keep-fallback" \
      T1155_HOST_ARG=auto \
      T1155_SSH_SCENARIO_DESKTOP=probe-unreachable \
      T1155_SSH_SCENARIO_MAC_WORK=remote-die-stderr t1155_spawn ) >"$TMP/t1155-m1.out" 2>"$TMP/t1155-m1.err"
  t1155_rc=$?
  set -e
  if [[ "$t1155_rc" -eq 80 ]]; then
    fail "1155 M1 mutant survived: the all-fail path still refused rc=80"
  fi
  grep -q 'host=local' "$TMP/t1155-m1.out" ||
    fail "1155 M1: the mutant should land the local fallback pane main produced"
  grep -q 'tab create' "$TMP/t1155-herdr.log" ||
    fail "1155 M1: the mutant should show the forbidden local pane creation"
  echo "PASS t1155 M1: keep-fallback mutant goes RED (AC2 assertion 'rc=80, no local pane' fails: rc=$t1155_rc, local pane created)"

  # M2 "the local placement arm respects the flag" — the mutant drops the
  # flag from the pressure decision, so a healthy local spawns locally again.
  # As in M1 the spawn_cmd backstop is the second enforcement layer on the
  # local landing, so the mutant bypasses it too.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant t1155-arm-ignores-flag \
    'if [[ "$LOCAL_SPAWN_ALLOWED" -eq 1 ]] && ! spillover_local_is_pressured; then' \
    'if ! spillover_local_is_pressured; then'
  python3 - "$TMP/mut-wrk-t1155-arm-ignores-flag" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
old = ('local_spawn_resolve || return\n'
       '  if [[ "${LOCAL_SPAWN_ALLOWED:-1}" -eq 0 ]]; then')
new = ('local_spawn_resolve || return\n'
       '  if false; then')
assert src.count(old) == 1, "mutant anchor not unique: %r" % old
open(p, "w", encoding="utf-8").write(src.replace(old, new))
PY
  rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log"
  set +e
  ( T1155_WRK="$TMP/mut-wrk-t1155-arm-ignores-flag" \
      T1155_HOST_ARG=auto T1155_SSH_SCENARIO_DESKTOP=ok \
      t1155_spawn ) >"$TMP/t1155-m2.out" 2>"$TMP/t1155-m2.err"
  t1155_rc=$?
  set -e
  if cmp -s "$TMP/t1155-ac1.want" "$TMP/t1155-m2.out"; then
    fail "1155 M2 mutant survived: the arm still picked the remote"
  fi
  grep -q 'host=local' "$TMP/t1155-m2.out" ||
    fail "1155 M2: the mutant should land the local pane an unflagged arm produces"
  grep -q 'tab create' "$TMP/t1155-herdr.log" ||
    fail "1155 M2: the mutant should show the local pane creation"
  echo "PASS t1155 M2: arm-ignores-flag mutant goes RED (AC1 assertion 'desktop OK line, no local pane' fails: rc=$t1155_rc, local pane created)"

  # M3 "a remote's disabled answer never stops the round" — the mutant adds
  # the new constant to the stop set, so AC4's remote-80 stops the round.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant t1155-80-stops \
    '      2|"$WRK_EXIT_ACTIVE_JOB_DUPLICATE"|"$WRK_EXIT_JOB_STATE_UNREADABLE"|"$WRK_EXIT_LANE_UNREGISTERED")' \
    '      2|"$WRK_EXIT_ACTIVE_JOB_DUPLICATE"|"$WRK_EXIT_JOB_STATE_UNREADABLE"|"$WRK_EXIT_LANE_UNREGISTERED"|"$WRK_EXIT_LOCAL_SPAWN_DISABLED")'
  rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log"
  set +e
  ( T1155_WRK="$TMP/mut-wrk-t1155-80-stops" \
      T1155_HOST_ARG=auto T1155_HOSTS_OVERRIDE="$T1155_HOSTS_ABSENT" \
      T1155_LOAD_FILE="$T1155_LOAD_HIGH" \
      T1155_SSH_SCENARIO_DESKTOP=remote-spawn-disabled \
      T1155_SSH_SCENARIO_MAC_WORK=ok t1155_spawn ) >"$TMP/t1155-m3.out" 2>"$TMP/t1155-m3.err"
  t1155_rc=$?
  set -e
  if [[ "$t1155_rc" -eq 0 ]] && cmp -s "$TMP/t1155-ac4.want" "$TMP/t1155-m3.out"; then
    fail "1155 M3 mutant survived: the remote 80 still failed over"
  fi
  [[ "$t1155_rc" -eq 80 ]] ||
    fail "1155 M3: the mutant should stop the round with rc 80, got $t1155_rc"
  ! grep -q 'mac-work' "$TMP/t1155-ssh.log" ||
    fail "1155 M3: the mutant must stop before the second candidate"
  echo "PASS t1155 M3: 80-in-stop-set mutant goes RED (AC4 assertion 'rc 0 + mac-work OK line' fails: rc=$t1155_rc)"

  # M4 "a transport-leg 70 is normalized to 1" — the mutant deletes the
  # WRK_EXIT_CONFIG_REFUSED arm from spillover_transport_rc, so S1's
  # transport-70 reaches the router as the remote's own config refusal.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant t1155-transport-keeps-70 \
    '    2|"$WRK_EXIT_ACTIVE_JOB_DUPLICATE"|"$WRK_EXIT_JOB_STATE_UNREADABLE"|"$WRK_EXIT_CONFIG_REFUSED"|"$WRK_EXIT_LANE_UNREGISTERED") printf '"'"'1'"'"' ;;' \
    '    2|"$WRK_EXIT_ACTIVE_JOB_DUPLICATE"|"$WRK_EXIT_JOB_STATE_UNREADABLE"|"$WRK_EXIT_LANE_UNREGISTERED") printf '"'"'1'"'"' ;;'
  rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log" "$TMP/t1155-calls"
  set +e
  ( T1155_WRK="$TMP/mut-wrk-t1155-transport-keeps-70" \
      WRK_SSH_CALL_COUNT_FILE="$TMP/t1155-calls" WRK_SSH_FAIL_CALLS=1 WRK_SSH_FAIL_CODE=70 \
      T1155_HOST_ARG=auto T1155_HOSTS_OVERRIDE="$T1155_HOSTS_ABSENT" \
      T1155_LOAD_FILE="$T1155_LOAD_HIGH" \
      T1155_SSH_SCENARIO_MAC_WORK=ok t1155_spawn ) >"$TMP/t1155-m4.out" 2>"$TMP/t1155-m4.err"
  t1155_rc=$?
  set -e
  if [[ "$t1155_rc" -eq 0 ]] && cmp -s "$TMP/t1155-ac4.want" "$TMP/t1155-m4.out"; then
    fail "1155 M4 mutant survived: a transport-70 still failed over"
  fi
  [[ "$t1155_rc" -eq 70 ]] ||
    fail "1155 M4: the mutant should stop the round with rc 70, got $t1155_rc"
  ! grep -q 'mac-work' "$TMP/t1155-ssh.log" ||
    fail "1155 M4: the mutant must stop before the second candidate"
  echo "PASS t1155 M4: transport-keeps-70 mutant goes RED (S1 assertion 'rc 0 + mac-work OK line' fails: rc=$t1155_rc)"

  # N1: the --host help must say transport failures and non-stop remote
  # answers move on, while remote 2/70/74/75, a cwd_map miss and a via=hub
  # candidate end the round.
  "$WRK" spawn --help >"$TMP/t1155-help.out" 2>"$TMP/t1155-help.err" ||
    fail "1155 N1: wrk spawn --help failed"
  grep -qF 'rc 2, 74 or 75' "$TMP/t1155-help.out" ||
    fail "1155 N1: help does not name the remote stop rcs"
  grep -qF 'cwd_map miss' "$TMP/t1155-help.out" ||
    fail "1155 N1: help does not name the cwd_map stop"
  grep -qF 'via=hub' "$TMP/t1155-help.out" ||
    fail "1155 N1: help does not name the via=hub stop"
  grep -qF 'Transport-leg failures' "$TMP/t1155-help.out" ||
    fail "1155 N1: help does not say transport legs move on"
  grep -qF 'spawn = false' "$TMP/t1155-help.out" ||
    fail "1155 N1: help does not document [local] spawn"
  echo "PASS t1155 N1 help-wording"

  # -- #1163: a malformed [local] is a config error, never "allowed" --------
  # AC1: every spelling that names the local table or its spawn key without
  # being exactly '[local]' + one 'spawn = true|false' refuses rc 70 on BOTH
  # --host local and --host auto — before any pane, arbiter record or hk
  # claim, and on auto before any remote leg runs. --task rides along so a
  # spawn that survived would leave an hk claim line (control proves the
  # claim is observable).
  local t1163_bad bad_hdr bad_body bad_rc want_frag t1163_task host_arg
  for t1163_bad in header-comment header-spaced header-quoted header-trailing \
      header-array header-unterminated header-twice key-twice key-bare \
      key-colon key-eqeq key-quoted value-int value-quoted \
      root-dotted root-quoted-dotted root-inline root-stray \
      bom-first bom-inside; do
    bad_hdr='[local]' bad_body='spawn = false'
    case "$t1163_bad" in
      header-comment)      bad_hdr='[local] # closed by ops' ;;
      header-spaced)       bad_hdr='[ local ]' ;;
      header-quoted)       bad_hdr='["local"]' ;;
      header-trailing)     bad_hdr='[local]junk' ;;
      header-array)        bad_hdr='[[local]]' ;;
      header-unterminated) bad_hdr='[local' ;;
      header-twice)        bad_body='[local]
spawn = false' ;;
      key-twice)           bad_body='spawn = true
spawn = false' ;;
      key-bare)            bad_body='spawn' ;;
      key-colon)           bad_body='spawn: false' ;;
      key-eqeq)            bad_body='spawn == false' ;;
      key-quoted)          bad_body='"spawn" = false' ;;
      value-int)           bad_body='spawn = 0' ;;
      value-quoted)        bad_body='spawn = "false"' ;;
      # Valid TOML closures that are not the [local] flag: root-table keys
      # (dotted, quoted-dotted, inline table) and stray text before any
      # header. The root table must be empty — every one refuses.
      root-dotted)        bad_hdr='local.spawn = false' bad_body='' ;;
      root-quoted-dotted) bad_hdr='"local".spawn = false' bad_body='' ;;
      root-inline)        bad_hdr='local = { spawn = false }' bad_body='' ;;
      root-stray)         bad_hdr='ops-note: desk is closed' bad_body='' ;;
      # A UTF-8 BOM at any line start is not a valid hosts.toml line.
      bom-first)   bad_hdr=$'\xef\xbb\xbf[local]' ;;
      bom-inside)  bad_body=$'\xef\xbb\xbfspawn = false' ;;
    esac
    {
      printf '%s\n' "$bad_hdr"
      [[ "$t1163_bad" == root-* ]] || printf '%s\n' "$bad_body"
      printf '%s\n' '' '[hosts.desktop]' 'ssh = "desktop"' 'capacity = 3' \
        "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}"
    } >"$TMP/t1163-$t1163_bad.toml"
    case "$t1163_bad" in
      header-twice) want_frag="duplicate [local] table header" ;;
      header-*)  want_frag="must be exactly '[local]' on its own line" ;;
      key-twice) want_frag="duplicate spawn key in [local]" ;;
      key-*)     want_frag="malformed spawn assignment in [local]" ;;
      value-*)   want_frag="accepts only the bare TOML booleans true or false" ;;
      root-*)    want_frag="root table must be empty in hosts.toml" ;;
      bom-*)     want_frag="UTF-8 BOM at a line start" ;;
    esac
    for host_arg in local auto; do
      t1163_task="$(mint_task)"
      rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log" "$TMP/t1163-hk.log"
      set +e
      ( T1155_HOST_ARG="$host_arg" T1155_HOSTS_OVERRIDE="$TMP/t1163-$t1163_bad.toml" \
          T1155_JOB="t1163-$t1163_bad-$host_arg" T1155_TASK="$t1163_task" \
          T1155_HK_LOG="$TMP/t1163-hk.log" t1155_spawn ) \
        >"$TMP/t1163-$t1163_bad-$host_arg.out" 2>"$TMP/t1163-$t1163_bad-$host_arg.err"
      bad_rc=$?
      set -e
      [[ "$bad_rc" -eq 70 ]] ||
        fail "1163 AC1 $t1163_bad/$host_arg: malformed [local] must refuse rc=70, got $bad_rc: $(cat "$TMP/t1163-$t1163_bad-$host_arg.err")"
      [[ ! -s "$TMP/t1163-$t1163_bad-$host_arg.out" ]] ||
        fail "1163 AC1 $t1163_bad/$host_arg: a refused spawn must not write stdout: $(cat "$TMP/t1163-$t1163_bad-$host_arg.out")"
      grep -q 'line [0-9]' "$TMP/t1163-$t1163_bad-$host_arg.err" ||
        fail "1163 AC1 $t1163_bad/$host_arg: the refusal must name the file line: $(cat "$TMP/t1163-$t1163_bad-$host_arg.err")"
      grep -qF "$want_frag" "$TMP/t1163-$t1163_bad-$host_arg.err" ||
        fail "1163 AC1 $t1163_bad/$host_arg: wrong refusal reason: $(cat "$TMP/t1163-$t1163_bad-$host_arg.err")"
      { [[ ! -e "$TMP/t1155-herdr.log" ]] || ! grep -q 'tab create' "$TMP/t1155-herdr.log"; } ||
        fail "1163 AC1 $t1163_bad/$host_arg: the refusal created a local pane"
      [[ ! -e "$T1155_INBOX/t1163-$t1163_bad-$host_arg" ]] ||
        fail "1163 AC1 $t1163_bad/$host_arg: the refusal left an arbiter record"
      { [[ ! -e "$TMP/t1163-hk.log" ]] || ! grep -q "claim id=$t1163_task " "$TMP/t1163-hk.log"; } ||
        fail "1163 AC1 $t1163_bad/$host_arg: the refusal claimed task $t1163_task: $(cat "$TMP/t1163-hk.log")"
      [[ "$host_arg" != auto || ! -s "$TMP/t1155-ssh.log" ]] ||
        fail "1163 AC1 $t1163_bad/$host_arg: a refused round still ran remote legs: $(cat "$TMP/t1155-ssh.log")"
    done
  done
  # A hosts.toml that exists but is unreadable fails closed the same way.
  printf '%s\n' '[local]' 'spawn = false' >"$TMP/t1163-unreadable.toml"
  chmod 000 "$TMP/t1163-unreadable.toml"
  for host_arg in local auto; do
    set +e
    ( T1155_HOST_ARG="$host_arg" T1155_HOSTS_OVERRIDE="$TMP/t1163-unreadable.toml" \
        T1155_JOB="t1163-unread-$host_arg" T1155_TASK="$(mint_task)" t1155_spawn ) \
      >"$TMP/t1163-unread-$host_arg.out" 2>"$TMP/t1163-unread-$host_arg.err"
    bad_rc=$?
    set -e
    [[ "$bad_rc" -eq 70 ]] ||
      fail "1163 AC1 unreadable/$host_arg: expected rc=70, got $bad_rc: $(cat "$TMP/t1163-unread-$host_arg.err")"
    grep -qF 'not a readable regular file' "$TMP/t1163-unread-$host_arg.err" ||
      fail "1163 AC1 unreadable/$host_arg: wrong refusal reason: $(cat "$TMP/t1163-unread-$host_arg.err")"
    [[ ! -e "$T1155_INBOX/t1163-unread-$host_arg" ]] ||
      fail "1163 AC1 unreadable/$host_arg: the refusal left an arbiter record"
  done
  chmod 644 "$TMP/t1163-unreadable.toml"
  # N3: 'readable regular file' is load-bearing — a directory, a FIFO and a
  # dangling symlink all exist (or -L) yet must refuse rc 70, never read as
  # allowed. (On the no--f mutant a directory opens fine and reads EOF, so
  # it would land a pane — the M-mutant below pins that RED.)
  mkdir "$TMP/t1163-isdir.toml"
  mkfifo "$TMP/t1163-isfifo.toml"
  ln -s "$TMP/t1163-no-such-target" "$TMP/t1163-dangling.toml"
  local t1163_kind
  for t1163_kind in isdir isfifo dangling; do
    for host_arg in local auto; do
      rm -f "$TMP/t1155-herdr.log"
      set +e
      ( T1155_HOST_ARG="$host_arg" T1155_HOSTS_OVERRIDE="$TMP/t1163-$t1163_kind.toml" \
          T1155_JOB="t1163-$t1163_kind-$host_arg" T1155_TASK="$(mint_task)" t1155_spawn ) \
        >"$TMP/t1163-$t1163_kind-$host_arg.out" 2>"$TMP/t1163-$t1163_kind-$host_arg.err"
      bad_rc=$?
      set -e
      [[ "$bad_rc" -eq 70 ]] ||
        fail "1163 N3 $t1163_kind/$host_arg: expected rc=70, got $bad_rc: $(cat "$TMP/t1163-$t1163_kind-$host_arg.err")"
      grep -qF 'not a readable regular file' "$TMP/t1163-$t1163_kind-$host_arg.err" ||
        fail "1163 N3 $t1163_kind/$host_arg: wrong refusal reason: $(cat "$TMP/t1163-$t1163_kind-$host_arg.err")"
      { [[ ! -e "$TMP/t1155-herdr.log" ]] || ! grep -q 'tab create' "$TMP/t1155-herdr.log"; } ||
        fail "1163 N3 $t1163_kind/$host_arg: the refusal created a local pane"
    done
  done
  # S3: an unsearchable parent makes 'absent' unprovable — refuse rc 70
  # where a truly nonexistent path stays allowed. Cover both the config's
  # own directory and a deeper missing path under the unsearchable parent.
  mkdir -p "$TMP/t1163-nosearch" && chmod 000 "$TMP/t1163-nosearch"
  for t1163_kind in "$TMP/t1163-nosearch/hosts.toml" "$TMP/t1163-nosearch/deeper/hosts.toml"; do
    set +e
    ( T1155_HOST_ARG=local T1155_HOSTS_OVERRIDE="$t1163_kind" \
        T1155_JOB=t1163-nosearch t1155_spawn ) \
      >"$TMP/t1163-nosearch.out" 2>"$TMP/t1163-nosearch.err"
    bad_rc=$?
    set -e
    [[ "$bad_rc" -eq 70 ]] ||
      fail "1163 S3 nosearch ($t1163_kind): expected rc=70, got $bad_rc: $(cat "$TMP/t1163-nosearch.err")"
    grep -qF 'not searchable' "$TMP/t1163-nosearch.err" ||
      fail "1163 S3 nosearch ($t1163_kind): wrong refusal reason: $(cat "$TMP/t1163-nosearch.err")"
  done
  chmod 700 "$TMP/t1163-nosearch"
  # Control: under the same machinery a truly nonexistent file stays allowed.
  rm -f "$TMP/t1155-herdr.log"
  set +e
  ( T1155_HOST_ARG=local T1155_HOSTS_OVERRIDE="$TMP/t1163-nosearch/absent.toml" \
      T1155_JOB=t1163-absent t1155_spawn ) \
    >"$TMP/t1163-absent.out" 2>"$TMP/t1163-absent.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 0 ]] ||
    fail "1163 S3 absent control: a nonexistent hosts.toml must stay allowed, got $t1155_rc: $(cat "$TMP/t1163-absent.err")"
  grep -q 'host=local' "$TMP/t1163-absent.out" ||
    fail "1163 S3 absent control: expected the local OK line: $(cat "$TMP/t1163-absent.out")"
  # Control for every no-claim assertion above: the same --task spawn on a
  # well-formed [local] does record the hk claim — the absence is real.
  t1163_task="$(mint_task)"
  rm -f "$TMP/t1163-hk-ok.log"
  set +e
  ( T1155_HOST_ARG=local T1155_HOSTS_OVERRIDE="$T1155_HOSTS_ON" \
      T1155_JOB=t1163-claim-ok T1155_TASK="$t1163_task" \
      T1155_HK_LOG="$TMP/t1163-hk-ok.log" t1155_spawn ) \
    >"$TMP/t1163-claim-ok.out" 2>"$TMP/t1163-claim-ok.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 0 ]] ||
    fail "1163 claim control: expected rc=0 on a well-formed config, got $t1155_rc: $(cat "$TMP/t1163-claim-ok.err")"
  grep -q "claim id=$t1163_task " "$TMP/t1163-hk-ok.log" ||
    fail "1163 claim control: a surviving spawn never claimed task $t1163_task: $(cat "$TMP/t1163-hk-ok.log" 2>/dev/null)"
  echo "PASS t1163 AC1 malformed-local-refuses-70 (20 spellings x local/auto + unreadable + dir/fifo/dangling + unsearchable parent, no pane/arbiter/hk)"

  # AC2: well-formed [local] surfaces keep the pinned main behavior — a file
  # without [local], a commented value, a tight 'spawn=false' and a
  # whitespace-padded header all resolve exactly like the canonical forms.
  printf '%s\n' '[hosts.desktop]' 'ssh = "desktop"' 'capacity = 3' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" >"$TMP/t1163-nolocal.toml"
  printf '%s\n' '[local]' 'spawn = false   # closed by ops' '' '[hosts.desktop]' \
    'ssh = "desktop"' 'capacity = 3' "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" \
    >"$TMP/t1163-off-comment.toml"
  printf '%s\n' '[local]' 'spawn=false' '' '[hosts.desktop]' 'ssh = "desktop"' \
    'capacity = 3' "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" >"$TMP/t1163-off-tight.toml"
  printf '%s\n' '   [local]   ' 'spawn = false' '' '[hosts.desktop]' 'ssh = "desktop"' \
    'capacity = 3' "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" >"$TMP/t1163-off-padheader.toml"
  for variant in nolocal off-comment off-tight off-padheader; do
    rm -f "$TMP/t1155-herdr.log"
    set +e
    ( T1155_HOST_ARG=local T1155_HOSTS_OVERRIDE="$TMP/t1163-$variant.toml" \
        T1155_JOB="t1163-v2-$variant" t1155_spawn ) \
      >"$TMP/t1163-v2-$variant.out" 2>"$TMP/t1163-v2-$variant.err"
    t1155_rc=$?
    set -e
    if [[ "$variant" == nolocal ]]; then
      [[ "$t1155_rc" -eq 0 ]] ||
        fail "1163 AC2 $variant: expected rc=0, got $t1155_rc: $(cat "$TMP/t1163-v2-$variant.err")"
      grep -qxF "OK pane=w:p1 host=local model=codex-luna label=fixture status=working landed=yes job=t1163-v2-$variant quota_record=codex/quota_pool" \
        "$TMP/t1163-v2-$variant.out" ||
        fail "1163 AC2 $variant: stdout differs from the pinned main OK line: $(cat "$TMP/t1163-v2-$variant.out")"
      grep -qxF "wrk: arbiter quota-pool record pool=codex profile=codex-luna-max launch_profile=codex-luna@medium job=t1163-v2-$variant" \
        "$TMP/t1163-v2-$variant.err" ||
        fail "1163 AC2 $variant: stderr differs from the pinned main arbiter line: $(cat "$TMP/t1163-v2-$variant.err")"
    else
      [[ "$t1155_rc" -eq 80 ]] ||
        fail "1163 AC2 $variant: spawn=false spellings must keep rc=80, got $t1155_rc: $(cat "$TMP/t1163-v2-$variant.err")"
      [[ ! -s "$TMP/t1163-v2-$variant.out" ]] ||
        fail "1163 AC2 $variant: a refused spawn must not write stdout"
      grep -qxF 'wrk: local spawns are disabled on this host ([local] spawn = false); refusing --host local' \
        "$TMP/t1163-v2-$variant.err" ||
        fail "1163 AC2 $variant: stderr differs from the pinned main refusal: $(cat "$TMP/t1163-v2-$variant.err")"
    fi
  done
  # The absent-file and no-spawn-key arms are pinned by the t1155 AC5 block
  # (absent key + spawn = true byte-identical local and auto paths).
  echo "PASS t1163 AC2 valid-forms-byte-identical (no [local], commented value, tight =, padded header)"

  # AC3+AC4: `wrk hosts` reports the flag via the same strict resolver and
  # stays rc 0 in every state; the remote probe table is unchanged, showing
  # the other hosts.toml readers are unaffected.
  t1163_hosts() {
    env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" PANEWIRE_BIN="$PANEWIRE" \
      WRK_HOSTS_CONFIG="$1" WRK_PROC_LOADAVG="$T1155_LOAD" WRK_TEST_NCPU=4 \
      WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" \
      WRK_SSH_LOG="$TMP/t1163-hosts-ssh.log" WRK_SSH_SCENARIO=ok \
      ARBITER_BIN="$TMP/t1163-absent-arbiter" "$WRK" hosts
  }
  rm -f "$TMP/t1163-hosts-ssh.log"
  t1163_hosts "$T1155_HOSTS_OFF" >"$TMP/t1163-hosts-off.out" 2>"$TMP/t1163-hosts-off.err" ||
    fail "1163 AC4: wrk hosts must stay rc=0 on a disabled flag"
  grep -qxF 'local spawn=disabled' "$TMP/t1163-hosts-off.out" ||
    fail "1163 AC4: wrk hosts must print 'local spawn=disabled': $(cat "$TMP/t1163-hosts-off.out")"
  grep -qxF $'desktop\tavailable\t0.10\t0' "$TMP/t1163-hosts-off.out" ||
    fail "1163 AC3: remote probe row for desktop changed: $(cat "$TMP/t1163-hosts-off.out")"
  grep -qxF $'mac-work\tavailable\t0.10\t0' "$TMP/t1163-hosts-off.out" ||
    fail "1163 AC3: remote probe row for mac-work changed: $(cat "$TMP/t1163-hosts-off.out")"
  t1163_hosts "$T1155_HOSTS_ON" >"$TMP/t1163-hosts-on.out" 2>"$TMP/t1163-hosts-on.err" ||
    fail "1163 AC4: wrk hosts must stay rc=0 on an allowed flag"
  grep -qxF 'local spawn=allowed' "$TMP/t1163-hosts-on.out" ||
    fail "1163 AC4: wrk hosts must print 'local spawn=allowed': $(cat "$TMP/t1163-hosts-on.out")"
  t1163_hosts "$TMP/t1163-header-comment.toml" >"$TMP/t1163-hosts-err.out" 2>"$TMP/t1163-hosts-err.err" ||
    fail "1163 AC4: wrk hosts must stay rc=0 even on a malformed flag"
  grep -qF 'local spawn=error (' "$TMP/t1163-hosts-err.out" ||
    fail "1163 AC4: wrk hosts must print 'local spawn=error (...)': $(cat "$TMP/t1163-hosts-err.out")"
  grep -qF "must be exactly '[local]' on its own line" "$TMP/t1163-hosts-err.out" ||
    fail "1163 AC4: the error state must carry the refusal reason: $(cat "$TMP/t1163-hosts-err.out")"
  # AC3: a well-formed [local] holding every sibling key still resolves —
  # the strict scan reads only the spawn key, and spillover_value callers
  # (max_load_ratio/max_active/heavy_max, hosts.* tables) are untouched.
  printf '%s\n' '[local]' 'spawn = true' 'max_load_ratio = 0.5' 'max_active = 4' \
    'heavy_max = 1' '' '[hosts.desktop]' 'ssh = "desktop"' 'capacity = 3' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" >"$TMP/t1163-siblings.toml"
  rm -f "$TMP/t1155-herdr.log"
  set +e
  ( T1155_HOST_ARG=local T1155_HOSTS_OVERRIDE="$TMP/t1163-siblings.toml" \
      T1155_JOB=t1163-siblings t1155_spawn ) \
    >"$TMP/t1163-siblings.out" 2>"$TMP/t1163-siblings.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 0 ]] ||
    fail "1163 AC3: sibling keys must not disturb spawn resolution: $(cat "$TMP/t1163-siblings.err")"
  grep -qxF "OK pane=w:p1 host=local model=codex-luna label=fixture status=working landed=yes job=t1163-siblings quota_record=codex/quota_pool" \
    "$TMP/t1163-siblings.out" ||
    fail "1163 AC3: stdout differs from the pinned OK line: $(cat "$TMP/t1163-siblings.out")"
  echo "PASS t1163 AC3+AC4 wrk-hosts-flag (allowed/disabled/error rc 0, remote table unchanged)"

  # M5 base: the empty-root rule ends at the first header — 'local.spawn'
  # under [hosts.x] is hosts.x.local.spawn, not the flag, and stays ignored.
  printf '%s\n' '[hosts.desktop]' 'ssh = "desktop"' 'local.spawn = false' \
    'capacity = 3' "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" \
    >"$TMP/t1163-hostskey.toml"
  rm -f "$TMP/t1155-herdr.log"
  set +e
  ( T1155_HOST_ARG=local T1155_HOSTS_OVERRIDE="$TMP/t1163-hostskey.toml" \
      T1155_JOB=t1163-hostskey t1155_spawn ) \
    >"$TMP/t1163-hostskey.out" 2>"$TMP/t1163-hostskey.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 0 ]] ||
    fail "1163 M5: 'local.spawn' under [hosts.x] must stay ignored, got $t1155_rc: $(cat "$TMP/t1163-hostskey.err")"
  grep -qxF "OK pane=w:p1 host=local model=codex-luna label=fixture status=working landed=yes job=t1163-hostskey quota_record=codex/quota_pool" \
    "$TMP/t1163-hostskey.out" ||
    fail "1163 M5: stdout differs from the pinned OK line: $(cat "$TMP/t1163-hostskey.out")"
  echo "PASS t1163 M5-base local.spawn-under-hosts.x-ignored"

  # S3(a): the spawn_cmd backstop is the only guard on the arbiter-
  # unavailable path — an unreadable arbiter hands the whole spawn to
  # spawn_cmd, so on a closed host that backstop alone must refuse rc 80.
  rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log"
  set +e
  ( T1155_HOST_ARG=auto T1155_ARBITER="$TMP/t1163-absent-arbiter" \
      T1155_JOB=t1163-arbdown t1155_spawn ) \
    >"$TMP/t1163-arbdown.out" 2>"$TMP/t1163-arbdown.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 80 ]] ||
    fail "1163 S3a: the arbiter-unavailable path must refuse rc=80 on a closed host, got $t1155_rc: $(cat "$TMP/t1163-arbdown.err")"
  grep -qF 'wrk: local spawns are disabled on this host ([local] spawn = false)' "$TMP/t1163-arbdown.err" ||
    fail "1163 S3a: the backstop refusal line is missing: $(cat "$TMP/t1163-arbdown.err")"
  { [[ ! -e "$TMP/t1155-herdr.log" ]] || ! grep -q 'tab create' "$TMP/t1155-herdr.log"; } ||
    fail "1163 S3a: a local pane was created on a closed host"
  [[ ! -e "$T1155_INBOX/t1163-arbdown" ]] ||
    fail "1163 S3a: the refusal left an arbiter record"
  echo "PASS t1163 S3a arbiter-unavailable-backstop-refuses"

  # N1: help wins over a config refusal — --help/-h print rc 0 even when the
  # [local] surface is malformed (a closed host still needs its docs).
  for help_arg in --help -h; do
    set +e
    env WRK_HOSTS_CONFIG="$TMP/t1163-header-comment.toml" \
      "$WRK" spawn "$help_arg" >"$TMP/t1163-help.out" 2>"$TMP/t1163-help.err"
    t1155_rc=$?
    set -e
    [[ "$t1155_rc" -eq 0 ]] ||
      fail "1163 N1: 'wrk spawn $help_arg' must print help rc=0 on a malformed config, got $t1155_rc"
    grep -qF 'spawn = false' "$TMP/t1163-help.out" ||
      fail "1163 N1: help output missing the [local] spawn documentation"
  done
  echo "PASS t1163 N1 help-rc0-on-malformed"

  # -- #1241 addendum B: a [local]-only hosts.toml carrying just
  # 'heavy_load_wait = false' — the file desk creates on M1 — must change
  # nothing versus no hosts.toml at all. Spawn routing (--host auto with no
  # remote candidates AND --host local) lands identically, the fallback
  # defaults (max_load_ratio/max_active) and the heavy_max default are
  # untouched, and wrk hosts output differs only in the config path and the
  # one new 'local heavy_load_wait=' line.
  T1241_NOFILE="$TMP/t1241-no-such-hosts.toml"
  rm -f "$T1241_NOFILE"
  printf '%s\n' '[local]' 'heavy_load_wait = false' >"$TMP/t1241-localonly.toml"
  for t1241_arg in auto local; do
    for variant in nofile localonly; do
      cfg="$T1241_NOFILE"
      [[ "$variant" == localonly ]] && cfg="$TMP/t1241-localonly.toml"
      rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log" "$TMP/t1155-spillover.log"
      set +e
      ( T1155_HOST_ARG="$t1241_arg" T1155_HOSTS_OVERRIDE="$cfg" \
          T1155_JOB="t1241-$t1241_arg-$variant" t1155_spawn ) \
        >"$TMP/t1241-$t1241_arg-$variant.out" 2>"$TMP/t1241-$t1241_arg-$variant.err"
      t1155_rc=$?
      set -e
      [[ "$t1155_rc" -eq 0 ]] ||
        fail "1241B $t1241_arg/$variant: spawn must land local rc=0, got $t1155_rc: $(cat "$TMP/t1241-$t1241_arg-$variant.err")"
      # a local landing is the fixture's own 'tab create' + landed=yes — the
      # direct local OK line carries no host= field (only the remote/fallback
      # emit path injects one)
      grep -q 'landed=yes' "$TMP/t1241-$t1241_arg-$variant.out" ||
        fail "1241B $t1241_arg/$variant: the spawn did not land: $(cat "$TMP/t1241-$t1241_arg-$variant.out")"
      grep -q 'tab create' "$TMP/t1155-herdr.log" ||
        fail "1241B $t1241_arg/$variant: expected a local pane creation"
    done
    # Byte-identical apart from the minted job id, the config path and — on
    # --host auto only — the ONE pre-existing difference any readable hosts
    # file makes (since #58, unrelated to this diff): the router annotates
    # the local landing's OK line with host=local, while the no-file fast
    # path prints spawn_cmd's bare line.  Pin that difference, then require
    # everything else to be identical.
    if [[ "$t1241_arg" == auto ]]; then
      grep -qF 'OK pane=w:p1 host=local ' "$TMP/t1241-auto-localonly.out" ||
        fail "1241B auto: the router's host=local annotation vanished: $(cat "$TMP/t1241-auto-localonly.out")"
      ! grep -q 'host=' "$TMP/t1241-auto-nofile.out" ||
        fail "1241B auto: the no-file OK line grew a host field: $(cat "$TMP/t1241-auto-nofile.out")"
      sed -i '' -e 's/ host=local//' "$TMP/t1241-auto-localonly.out" 2>/dev/null ||
        sed -i -e 's/ host=local//' "$TMP/t1241-auto-localonly.out"
    fi
    for stream in out err; do
      sed -e 's/job=[^ ]*/job=J/' -e "s|$T1241_NOFILE|CFG|g" \
        "$TMP/t1241-$t1241_arg-nofile.$stream" >"$TMP/t1241-$t1241_arg-nofile.$stream.norm"
      sed -e 's/job=[^ ]*/job=J/' -e "s|$TMP/t1241-localonly.toml|CFG|g" \
        "$TMP/t1241-$t1241_arg-localonly.$stream" >"$TMP/t1241-$t1241_arg-localonly.$stream.norm"
      cmp -s "$TMP/t1241-$t1241_arg-nofile.$stream.norm" "$TMP/t1241-$t1241_arg-localonly.$stream.norm" ||
        fail "1241B $t1241_arg: a [local]-only file changed spawn $stream vs no file: $(diff "$TMP/t1241-$t1241_arg-nofile.$stream.norm" "$TMP/t1241-$t1241_arg-localonly.$stream.norm" || true)"
    done
  done
  # wrk hosts: every line identical apart from config= and the new line
  rm -f "$TMP/t1163-hosts-ssh.log"
  t1163_hosts "$T1241_NOFILE" >"$TMP/t1241-hosts-nofile.out" 2>"$TMP/t1241-hosts-nofile.err" ||
    fail "1241B: wrk hosts must stay rc 0 with no file"
  t1163_hosts "$TMP/t1241-localonly.toml" >"$TMP/t1241-hosts-localonly.out" 2>"$TMP/t1241-hosts-localonly.err" ||
    fail "1241B: wrk hosts must stay rc 0 on the [local]-only file"
  grep -qxF 'local heavy_load_wait=true' "$TMP/t1241-hosts-nofile.out" ||
    fail "1241B: no file must read the switch as on: $(cat "$TMP/t1241-hosts-nofile.out")"
  grep -qxF 'local heavy_load_wait=false' "$TMP/t1241-hosts-localonly.out" ||
    fail "1241B: the [local]-only file must read the switch as off: $(cat "$TMP/t1241-hosts-localonly.out")"
  grep -vxF -e "config=$T1241_NOFILE" -e 'local heavy_load_wait=true' \
    "$TMP/t1241-hosts-nofile.out" >"$TMP/t1241-hosts-nofile.norm"
  grep -vxF -e "config=$TMP/t1241-localonly.toml" -e 'local heavy_load_wait=false' \
    "$TMP/t1241-hosts-localonly.out" >"$TMP/t1241-hosts-localonly.norm"
  cmp -s "$TMP/t1241-hosts-nofile.norm" "$TMP/t1241-hosts-localonly.norm" ||
    fail "1241B: wrk hosts output differs beyond the config path and the new line: $(diff "$TMP/t1241-hosts-nofile.norm" "$TMP/t1241-hosts-localonly.norm" || true)"
  echo "PASS t1241 B local-only-file-identical-to-nofile (spawn auto+local, wrk hosts)"

  # -- #1163 assertion-RED mutants ------------------------------------------
  # M1 "a commented [local] header never reads as spawn allowed" — the
  # mutant restores main's old behavior whole: non-exact local-naming
  # headers are skipped silently AND root lines pass unread, so
  # '[local] # comment' leaves spawn unseen = allowed.
  python3 - "$WRK" "$TMP/mut-wrk-t1163-skip-loose-header" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('      elif [[ "$name" == local ]]; then\n'
       '        LOCAL_SPAWN_ERROR="$config line $n: [local] table header must be exactly \'[local]\' on its own line"\n'
       '        return "$WRK_EXIT_CONFIG_REFUSED"\n')
new = ('      elif [[ "$name" == local ]]; then\n'
       '        :\n')
assert src.count(old) == 1, "mutant anchor not unique: %r" % old
src = src.replace(old, new)
old2 = """    if [[ -z "$current" ]]; then
      # The root table must be empty: every line before the first table
      # header that is not blank or a comment — 'local.spawn = false',
      # '"local".spawn = false', 'local = { spawn = false }', any other key
      # or stray text — is refused rather than read or ignored.
      LOCAL_SPAWN_ERROR="$config line $n: root table must be empty in hosts.toml (keys belong under a [table] header)"
      return "$WRK_EXIT_CONFIG_REFUSED"
    fi
"""
new2 = "    [[ -z \"$current\" ]] || continue\n"
assert src.count(old2) == 1, "mutant anchor not unique: %r" % old2
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old2, new2))
PY
  chmod +x "$TMP/mut-wrk-t1163-skip-loose-header"
  rm -f "$TMP/t1155-herdr.log"
  set +e
  ( T1155_WRK="$TMP/mut-wrk-t1163-skip-loose-header" T1155_HOST_ARG=local \
      T1155_HOSTS_OVERRIDE="$TMP/t1163-header-comment.toml" \
      T1155_JOB=t1163-m1 t1155_spawn ) >"$TMP/t1163-m1.out" 2>"$TMP/t1163-m1.err"
  t1155_rc=$?
  set -e
  if [[ "$t1155_rc" -eq 70 ]]; then
    fail "1163 M1 mutant survived: a commented header still refused rc=70"
  fi
  grep -q 'host=local' "$TMP/t1163-m1.out" ||
    fail "1163 M1: the mutant should land the local pane the loose header silently allows"
  echo "PASS t1163 M1: skip-loose-header mutant goes RED (AC1 assertion 'header-comment refuses rc=70' fails: rc=$t1155_rc, local pane created)"

  # M2 "duplicate spawn keys refuse" — the mutant takes the first key and
  # skips the rest: 'spawn = true' then 'spawn = false' reads allowed.
  python3 - "$WRK" "$TMP/mut-wrk-t1163-dup-first-wins" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    spawn_seen=$((spawn_seen + 1))\n'
       '    if [[ "$spawn_seen" -gt 1 ]]; then\n'
       '      LOCAL_SPAWN_ERROR="$config line $n: duplicate spawn key in [local]"\n'
       '      return "$WRK_EXIT_CONFIG_REFUSED"\n'
       '    fi\n')
new = ('    spawn_seen=$((spawn_seen + 1))\n'
       '    if [[ "$spawn_seen" -gt 1 ]]; then\n'
       '      continue\n'
       '    fi\n')
assert src.count(old) == 1, "mutant anchor not unique: %r" % old
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
  chmod +x "$TMP/mut-wrk-t1163-dup-first-wins"
  rm -f "$TMP/t1155-herdr.log"
  set +e
  ( T1155_WRK="$TMP/mut-wrk-t1163-dup-first-wins" T1155_HOST_ARG=local \
      T1155_HOSTS_OVERRIDE="$TMP/t1163-key-twice.toml" \
      T1155_JOB=t1163-m2 t1155_spawn ) >"$TMP/t1163-m2.out" 2>"$TMP/t1163-m2.err"
  t1155_rc=$?
  set -e
  if [[ "$t1155_rc" -eq 70 ]]; then
    fail "1163 M2 mutant survived: duplicate keys still refused rc=70"
  fi
  grep -q 'host=local' "$TMP/t1163-m2.out" ||
    fail "1163 M2: the mutant should land the local pane first-wins allows"
  echo "PASS t1163 M2: dup-first-wins mutant goes RED (AC1 assertion 'key-twice refuses rc=70' fails: rc=$t1155_rc, local pane created)"

  # M3 "the spawn_cmd backstop alone blocks the arbiter-unavailable path" —
  # the mutant removes only that guard, so the S3(a) run above must go RED:
  # an unreadable arbiter hands the closed-host spawn to an unguarded
  # spawn_cmd, which then lands the forbidden local pane.
  python3 - "$WRK" "$TMP/mut-wrk-t1163-no-backstop" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('  local_spawn_resolve || return\n'
       '  if [[ "${LOCAL_SPAWN_ALLOWED:-1}" -eq 0 ]]; then\n'
       '    echo "wrk: local spawns are disabled on this host ([local] spawn = false); refusing spawn" >&2\n'
       '    return "$WRK_EXIT_LOCAL_SPAWN_DISABLED"\n'
       '  fi\n')
assert src.count(old) == 1, "mutant anchor not unique: %r" % old
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, ""))
PY
  chmod +x "$TMP/mut-wrk-t1163-no-backstop"
  rm -f "$TMP/t1155-herdr.log" "$TMP/t1155-ssh.log"
  set +e
  ( T1155_WRK="$TMP/mut-wrk-t1163-no-backstop" T1155_HOST_ARG=auto \
      T1155_ARBITER="$TMP/t1163-absent-arbiter" T1155_JOB=t1163-m3 \
      t1155_spawn ) >"$TMP/t1163-m3.out" 2>"$TMP/t1163-m3.err"
  t1155_rc=$?
  set -e
  if [[ "$t1155_rc" -eq 80 ]]; then
    fail "1163 M3 mutant survived: the arbiter-unavailable path still refused rc=80"
  fi
  grep -q 'host=local' "$TMP/t1163-m3.out" ||
    fail "1163 M3: the mutant should land the local pane the missing backstop allows"
  grep -q 'tab create' "$TMP/t1155-herdr.log" ||
    fail "1163 M3: the mutant should show the forbidden local pane creation"
  echo "PASS t1163 M3: no-backstop mutant goes RED (S3a assertion 'rc=80, no local pane' fails: rc=$t1155_rc, local pane created)"

  # M4 "a key in the root table never reads as spawn allowed" — the mutant
  # silently skips root lines, so 'local.spawn = false' before any header
  # is never seen and the spawn is allowed.
  python3 - "$WRK" "$TMP/mut-wrk-t1163-skip-root" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = """    if [[ -z "$current" ]]; then
      # The root table must be empty: every line before the first table
      # header that is not blank or a comment — 'local.spawn = false',
      # '"local".spawn = false', 'local = { spawn = false }', any other key
      # or stray text — is refused rather than read or ignored.
      LOCAL_SPAWN_ERROR="$config line $n: root table must be empty in hosts.toml (keys belong under a [table] header)"
      return "$WRK_EXIT_CONFIG_REFUSED"
    fi
"""
new = "    [[ -z \"$current\" ]] || continue\n"
assert src.count(old) == 1, "mutant anchor not unique: %r" % old
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
  chmod +x "$TMP/mut-wrk-t1163-skip-root"
  rm -f "$TMP/t1155-herdr.log"
  set +e
  ( T1155_WRK="$TMP/mut-wrk-t1163-skip-root" T1155_HOST_ARG=local \
      T1155_HOSTS_OVERRIDE="$TMP/t1163-root-dotted.toml" \
      T1155_JOB=t1163-m4 t1155_spawn ) >"$TMP/t1163-m4.out" 2>"$TMP/t1163-m4.err"
  t1155_rc=$?
  set -e
  if [[ "$t1155_rc" -eq 70 ]]; then
    fail "1163 M4 mutant survived: a root key still refused rc=70"
  fi
  grep -q 'host=local' "$TMP/t1163-m4.out" ||
    fail "1163 M4: the mutant should land the local pane the skipped root line allows"
  echo "PASS t1163 M4: skip-root-lines mutant goes RED (AC1 assertion 'root-dotted refuses rc=70' fails: rc=$t1155_rc, local pane created)"

  # M5 "local.spawn under [hosts.x] is ignored" — the mutant applies the
  # empty-root check to every line, so the hostskey file's 'ssh = ...' key
  # under [hosts.desktop] refuses: the M5-base spawn goes RED.
  python3 - "$WRK" "$TMP/mut-wrk-t1163-root-everywhere" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = """    if [[ -z "$current" ]]; then
      # The root table must be empty: every line before the first table
      # header that is not blank or a comment — 'local.spawn = false',
      # '"local".spawn = false', 'local = { spawn = false }', any other key
      # or stray text — is refused rather than read or ignored.
      LOCAL_SPAWN_ERROR="$config line $n: root table must be empty in hosts.toml (keys belong under a [table] header)"
      return "$WRK_EXIT_CONFIG_REFUSED"
    fi
"""
new = """    if [[ -n "$line" ]]; then
      LOCAL_SPAWN_ERROR="$config line $n: root table must be empty in hosts.toml (keys belong under a [table] header)"
      return "$WRK_EXIT_CONFIG_REFUSED"
    fi
"""
assert src.count(old) == 1, "mutant anchor not unique: %r" % old
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
  chmod +x "$TMP/mut-wrk-t1163-root-everywhere"
  set +e
  ( T1155_WRK="$TMP/mut-wrk-t1163-root-everywhere" T1155_HOST_ARG=local \
      T1155_HOSTS_OVERRIDE="$TMP/t1163-hostskey.toml" \
      T1155_JOB=t1163-m5 t1155_spawn ) >"$TMP/t1163-m5.out" 2>"$TMP/t1163-m5.err"
  t1155_rc=$?
  set -e
  if [[ "$t1155_rc" -eq 0 ]]; then
    fail "1163 M5 mutant survived: [hosts.x] keys still ignored"
  fi
  [[ "$t1155_rc" -eq 70 ]] ||
    fail "1163 M5: expected the everywhere-mutant to refuse rc=70, got $t1155_rc: $(cat "$TMP/t1163-m5.err")"
  echo "PASS t1163 M5: root-check-everywhere mutant goes RED (M5-base assertion 'local.spawn under [hosts.x] ignored, rc=0 + pinned OK line' fails: rc=$t1155_rc, refused)"

  # M6 "a BOM line refuses" — the mutant strips the BOM silently, so a
  # BOM-prefixed '[local] spawn = true' parses clean and lands a pane.
  printf '\xef\xbb\xbf[local]\nspawn = true\n\n[hosts.desktop]\nssh = "desktop"\ncapacity = 3\ncwd_map = {"%s"="/remote/agent-skills"}\n' \
    "$ROOT" >"$TMP/t1163-bom-allow.toml"
  set +e
  ( T1155_HOST_ARG=local T1155_HOSTS_OVERRIDE="$TMP/t1163-bom-allow.toml" \
      T1155_JOB=t1163-bomallow t1155_spawn ) \
    >"$TMP/t1163-bomallow.out" 2>"$TMP/t1163-bomallow.err"
  t1155_rc=$?
  set -e
  [[ "$t1155_rc" -eq 70 ]] ||
    fail "1163 M6 base: a BOM line must refuse rc=70, got $t1155_rc: $(cat "$TMP/t1163-bomallow.err")"
  python3 - "$WRK" "$TMP/mut-wrk-t1163-strip-bom" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = """    if [[ "$line" == $'\\xef\\xbb\\xbf'* ]]; then
      LOCAL_SPAWN_ERROR="$config line $n: UTF-8 BOM at a line start is not valid hosts.toml"
      return "$WRK_EXIT_CONFIG_REFUSED"
    fi
"""
new = """    line="${line#$'\\xef\\xbb\\xbf'}"
"""
assert src.count(old) == 1, "mutant anchor not unique: %r" % old
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
  chmod +x "$TMP/mut-wrk-t1163-strip-bom"
  rm -f "$TMP/t1155-herdr.log"
  set +e
  ( T1155_WRK="$TMP/mut-wrk-t1163-strip-bom" T1155_HOST_ARG=local \
      T1155_HOSTS_OVERRIDE="$TMP/t1163-bom-allow.toml" \
      T1155_JOB=t1163-m6 t1155_spawn ) >"$TMP/t1163-m6.out" 2>"$TMP/t1163-m6.err"
  t1155_rc=$?
  set -e
  if [[ "$t1155_rc" -eq 70 ]]; then
    fail "1163 M6 mutant survived: a BOM line still refused rc=70"
  fi
  grep -q 'host=local' "$TMP/t1163-m6.out" ||
    fail "1163 M6: the mutant should land the local pane the stripped BOM silently allows"
  echo "PASS t1163 M6: strip-bom mutant goes RED (BOM assertion 'bom-allow refuses rc=70' fails: rc=$t1155_rc, local pane created)"

  # N3 mutant: dropping the regular-file check sends a directory past the
  # resolver — the pinned rc 70 refusal never fires (the spawn then dies
  # downstream on the same directory read, or lands a pane where read(2)
  # returns EOF): either way the 'isdir refuses rc=70' assertion goes RED.
  python3 - "$WRK" "$TMP/mut-wrk-t1163-no-fcheck" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '  if [[ ! -f "$config" || ! -r "$config" ]]; then\n'
new = '  if [[ ! -r "$config" ]]; then\n'
assert src.count(old) == 1, "mutant anchor not unique: %r" % old
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
  chmod +x "$TMP/mut-wrk-t1163-no-fcheck"
  rm -f "$TMP/t1155-herdr.log"
  set +e
  ( T1155_WRK="$TMP/mut-wrk-t1163-no-fcheck" T1155_HOST_ARG=local \
      T1155_HOSTS_OVERRIDE="$TMP/t1163-isdir.toml" \
      T1155_JOB=t1163-mn3 t1155_spawn ) >"$TMP/t1163-mn3.out" 2>"$TMP/t1163-mn3.err"
  t1155_rc=$?
  set -e
  if [[ "$t1155_rc" -eq 70 ]]; then
    fail "1163 N3 mutant survived: a directory still refused rc=70"
  fi
  echo "PASS t1163 N3-mutant: no-regular-file-check mutant goes RED (N3 assertion 'isdir/local refuses rc=70' fails: rc=$t1155_rc, no refusal)"
}

if [[ "${WRK_TEST_ONLY_LOCAL_SPAWN_OFF:-0}" -eq 1 ]]; then
  run_t1155_local_spawn_off_tests
  exit 0
fi
run_t1155_local_spawn_off_tests

run_t1239_desktop_wake_tests() {
  # -- #1239: wake a default-off remote on demand when capacity runs short ---
  # desktop is the wake-capable host (wake = "panewire"); mac-work stands in
  # for m1b. Every run is fixtures only — spillover-ssh answers probes, the
  # panewire fixture answers burst requests, and the node "coming up" is the
  # fixture creating $T1239_AWAKE.
  T1239_LOAD="$TMP/t1239-loadavg"
  printf '0.20 0.10 0.10 1/1 1\n' >"$T1239_LOAD"
  T1239_LOAD_HIGH="$TMP/t1239-loadavg-high"
  printf '4.00 4.00 4.00 1/1 1\n' >"$T1239_LOAD_HIGH"
  T1239_INBOX="$TMP/t1239-inbox" T1239_XDG="$TMP/t1239-xdg"
  env ARBITER_INBOX_ROOT="$T1239_INBOX" XDG_DATA_HOME="$T1239_XDG" \
    "$ARBITER" claim --job t1239-seed --agent-label t1239-seed --lane t1239 --t T1 >/dev/null
  T1239_OPERATOR="$TMP/t1239-operator.env"
  T1239_NODE_TOKEN="$TMP/t1239-node.env"
  printf 'HUB_MACHINE_ID=operator\nHUB_TOKEN=fixture-operator-token\n' >"$T1239_OPERATOR"
  printf 'HUB_MACHINE_ID=mac-personal\nHUB_TOKEN=fixture-node-token\n' >"$T1239_NODE_TOKEN"
  T1239_AWAKE="$TMP/t1239-desktop-awake"
  # The desk's real shape: quota_gate = "local" plus operator_token_env and
  # NO hub_token_env — the wake must never need the quota-gate key.
  T1239_HOSTS="$TMP/t1239-hosts.toml"
  # hub_url is wss:// on purpose — the wake must convert it to the https
  # operator base like every other hub path (AC1 asserts the logged argv).
  printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
    '[hub]' 'hub_url = "wss://hub.fixture.invalid"' \
    "operator_token_env = \"$T1239_OPERATOR\"" 'quota_gate = "local"' '' \
    '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' \
    'wake = "panewire"' 'wake_hold = 10' 'wake_wait = 2' '' \
    '[hosts.mac-work]' 'ssh = "mac-work"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 2' >"$T1239_HOSTS"
  # Credential variants: both keys (operator must win), the node token only
  # (fallback), and neither (clear skip + failure path).
  T1239_HOSTS_BOTH="$TMP/t1239-hosts-both.toml"
  sed "s|^quota_gate = \"local\"$|hub_token_env = \"$T1239_NODE_TOKEN\"|" "$T1239_HOSTS" >"$T1239_HOSTS_BOTH"
  T1239_HOSTS_TOKEN_ONLY="$TMP/t1239-hosts-token-only.toml"
  printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
    '[hub]' 'hub_url = "https://hub.fixture.invalid"' "hub_token_env = \"$T1239_NODE_TOKEN\"" '' \
    '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' \
    'wake = "panewire"' 'wake_hold = 10' 'wake_wait = 2' '' \
    '[hosts.mac-work]' 'ssh = "mac-work"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 2' >"$T1239_HOSTS_TOKEN_ONLY"
  T1239_HOSTS_NO_CRED="$TMP/t1239-hosts-no-cred.toml"
  sed "/^operator_token_env =/d" "$T1239_HOSTS" >"$T1239_HOSTS_NO_CRED"
  # Round-2 live-order fixture (tester B1): the real candidate order on this
  # Mac — desktop, oci, mac-dev, rpi. oci has a cwd_map but no entry for the
  # repos exercised and no capacity key; rpi has no cwd_map at all. Both are
  # skipped BEFORE their probe under --host auto and count neither for nor
  # against the wake. desktop and mac-dev map both repos; mac-dev answers
  # remote-full and supplies the capacity evidence the wake needs.
  T1239_TRADER="$TMP/t1239-auto_trader"; mkdir -p "$T1239_TRADER"
  T1239_HOSTS_LIVE="$TMP/t1239-hosts-live.toml"
  printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
    '[hub]' 'hub_url = "wss://hub.fixture.invalid"' \
    "operator_token_env = \"$T1239_OPERATOR\"" 'quota_gate = "local"' '' \
    '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "w1"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\" \"$T1239_TRADER\"=\"/remote/auto_trader\"}" 'capacity = 4' \
    'wake = "panewire"' 'wake_hold = 10' 'wake_wait = 2' '' \
    '[hosts.oci]' 'ssh = "oci"' 'herdr_session = "worker"' 'workspace = "w1"' \
    'cwd_map = {"/nonexistent-local"="/remote/unrelated"}' '' \
    '[hosts.mac-dev]' 'ssh = "mac-dev"' 'herdr_session = "worker"' 'workspace = "w1"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\" \"$T1239_TRADER\"=\"/remote/auto_trader\"}" 'capacity = 3' '' \
    '[hosts.rpi]' 'ssh = "rpi"' 'herdr_session = "worker"' 'workspace = "w1"' >"$T1239_HOSTS_LIVE"
  # R2(b): the same order with oci mapped for agent-skills and free — the
  # job lands on oci and no wake fires.
  T1239_HOSTS_LIVE_OCI="$TMP/t1239-hosts-live-oci.toml"
  sed "s|cwd_map = {\"/nonexistent-local\"=\"/remote/unrelated\"}|cwd_map = {\"$ROOT\"=\"/remote/oci-work\"} capacity = 3|" \
    "$T1239_HOSTS_LIVE" >"$T1239_HOSTS_LIVE_OCI"
  # R2(c): rpi mapped too, so it can answer remote-full while mac-dev
  # refuses for a non-capacity reason (rc 80 or a transport failure).
  T1239_HOSTS_LIVE_RPI="$TMP/t1239-hosts-live-rpi.toml"
  printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
    '[hub]' 'hub_url = "wss://hub.fixture.invalid"' \
    "operator_token_env = \"$T1239_OPERATOR\"" 'quota_gate = "local"' '' \
    '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "w1"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 4' \
    'wake = "panewire"' 'wake_hold = 10' 'wake_wait = 2' '' \
    '[hosts.oci]' 'ssh = "oci"' 'herdr_session = "worker"' 'workspace = "w1"' \
    'cwd_map = {"/nonexistent-local"="/remote/unrelated"}' '' \
    '[hosts.mac-dev]' 'ssh = "mac-dev"' 'herdr_session = "worker"' 'workspace = "w1"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' '' \
    '[hosts.rpi]' 'ssh = "rpi"' 'herdr_session = "worker"' 'workspace = "w1"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 2' >"$T1239_HOSTS_LIVE_RPI"
  # R2(d): same live order with local spawns disabled — when no candidate
  # answers remote-full there is no wake and no local pane.
  T1239_HOSTS_LIVE_NOLOCAL="$TMP/t1239-hosts-live-nolocal.toml"
  sed 's/^max_active = 4$/max_active = 4\nspawn = false/' "$T1239_HOSTS_LIVE" >"$T1239_HOSTS_LIVE_NOLOCAL"

  t1239_spawn() {  # env knobs mirror t1155_spawn; T1239_* prefixed
    env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
      ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$T1239_INBOX" XDG_DATA_HOME="$T1239_XDG" \
      WRK_HOSTS_CONFIG="${T1239_HOSTS_OVERRIDE:-$T1239_HOSTS}" \
      WRK_PROC_LOADAVG="${T1239_LOAD_FILE:-$T1239_LOAD_HIGH}" \
      WRK_TEST_NCPU=4 WRK_TEST_THROTTLED=0 \
      WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/t1239-herdr.log" \
      WRK_SPILLOVER_LOG="$TMP/t1239-spillover.log" \
      PANEWIRE_BIN="${T1239_PANEWIRE:-$ROOT/tests/fixtures/spillover-panewire}" \
      WRK_WAKE_LOG="$TMP/t1239-wake.log" \
      WRK_PLACE_SCENARIO="${T1239_PLACE_SCENARIO:-unavailable}" \
      WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" \
      WRK_SCP_BIN="$ROOT/tests/fixtures/spillover-scp" \
      WRK_SSH_LOG="$TMP/t1239-ssh.log" WRK_SCP_LOG="$TMP/t1239-scp.log" \
      WRK_SSH_SCENARIO="${T1239_SSH_SCENARIO:-ok}" \
      WRK_SSH_SCENARIO_DESKTOP="${T1239_SSH_SCENARIO_DESKTOP:-}" \
      WRK_SSH_SCENARIO_MAC_WORK="${T1239_SSH_SCENARIO_MAC_WORK:-}" \
      WRK_SSH_SCENARIO_OCI="${T1239_SSH_SCENARIO_OCI:-}" \
      WRK_SSH_SCENARIO_MAC_DEV="${T1239_SSH_SCENARIO_MAC_DEV:-}" \
      WRK_SSH_SCENARIO_RPI="${T1239_SSH_SCENARIO_RPI:-}" \
      WRK_BURST_SCENARIO="${T1239_BURST_SCENARIO:-up}" \
      WRK_DESKTOP_AWAKE="$T1239_AWAKE" \
      WRK_WAKE_POLL_S="${T1239_POLL_S:-0.2}" \
      "${T1239_WRK:-$WRK}" spawn -c "${T1239_CWD:-$ROOT}" -m codex-luna -p "$PROMPT" \
      -w w -l fixture --t T1 --job "${T1239_JOB:-t1239-$RANDOM-$RANDOM}" --host "${T1239_HOST_ARG:-auto}"
  }

  local t1239_rc t1239_last t1239_wake_line t1239_scenario t1239_reason t1239_p1 t1239_p2 t1239_rc1 t1239_rc2

  # AC1: local pressured + mac-work remote-full + desktop asleep — the round
  # finishes, ONE burst request goes out with the operator credential, the
  # node comes up and the job lands on desktop.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_JOB=t1239-ac1 t1239_spawn ) >"$TMP/t1239-ac1.out" 2>"$TMP/t1239-ac1.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 0 ]] ||
    fail "1239 AC1: expected rc=0 after the wake, got $t1239_rc: $(cat "$TMP/t1239-ac1.err")"
  printf '%s\n' 'OK pane=desktop:p7 host=desktop model=codex-luna label=fixture status=working landed=yes' >"$TMP/t1239-ac1.want"
  cmp -s "$TMP/t1239-ac1.want" "$TMP/t1239-ac1.out" ||
    fail "1239 AC1: expected the desktop OK line: $(cat "$TMP/t1239-ac1.out")"
  [[ "$(grep -c '^burst request ' "$TMP/t1239-wake.log")" -eq 1 ]] ||
    fail "1239 AC1: expected exactly one burst request: $(cat "$TMP/t1239-wake.log" 2>/dev/null || true)"
  t1239_wake_line="$(grep '^burst request ' "$TMP/t1239-wake.log")"
  [[ "$t1239_wake_line" == *'--target desktop'* ]] ||
    fail "1239 AC1: burst request missing --target desktop: $t1239_wake_line"
  [[ "$t1239_wake_line" == *"--hub-token-env $T1239_OPERATOR"* ]] ||
    fail "1239 AC1: burst request must carry operator_token_env: $t1239_wake_line"
  [[ "$t1239_wake_line" == *'--hub-url https://hub.fixture.invalid'* ]] ||
    fail "1239 AC1: burst request missing --hub-url: $t1239_wake_line"
  [[ "$t1239_wake_line" == *'--hold 10m'* && "$t1239_wake_line" == *'--timeout 2s'* ]] ||
    fail "1239 AC1: burst request must carry the configured hold/wait: $t1239_wake_line"
  grep -q 'mac-work' "$TMP/t1239-ssh.log" ||
    fail "1239 AC1: the round must probe mac-work before waking desktop"
  ! grep -q 'tab create' "$TMP/t1239-herdr.log" ||
    fail "1239 AC1: a local pane was created: $(cat "$TMP/t1239-herdr.log")"
  ! grep -q 'quota gate' "$TMP/t1239-ac1.err" ||
    fail "1239 AC1: the wake path must not arm the hub quota gate: $(cat "$TMP/t1239-ac1.err")"
  grep -qF "wrk: waking remote host 'desktop'" "$TMP/t1239-ac1.err" ||
    fail "1239 AC1: the wake action line is missing: $(cat "$TMP/t1239-ac1.err")"
  ! grep -qE "^wrk: remote host '[^']+' step " "$TMP/t1239-ac1.err" ||
    fail "1239 AC1: successful wake placement leaked captured remote progress lines"
  echo "PASS t1239 AC1 deferred-wake-lands-desktop"

  # AC2 (director-1's case): same pressure picture, the node never connects
  # inside wake_wait — rc 81, the timeout line, the held per-candidate
  # diagnostics, no local pane, no second burst request.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  set +e
  ( T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_BURST_SCENARIO=no-up T1239_JOB=t1239-ac2 t1239_spawn ) \
      >"$TMP/t1239-ac2.out" 2>"$TMP/t1239-ac2.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 81 ]] ||
    fail "1239 AC2: a timed-out wake must answer rc=81, got $t1239_rc: $(cat "$TMP/t1239-ac2.err")"
  [[ ! -s "$TMP/t1239-ac2.out" ]] ||
    fail "1239 AC2: a refused spawn must not write stdout: $(cat "$TMP/t1239-ac2.out")"
  t1239_last="$(tail -n 1 "$TMP/t1239-ac2.err")"
  [[ "$t1239_last" == "wrk: remote host 'desktop' wake timed out after 2s (burst hold requested, node not connected); not falling back to local" ]] ||
    fail "1239 AC2: expected the timeout line, got: $t1239_last"
  grep -qF "remote host 'desktop' probe failed (ssh-unreachable, rc=255)" "$TMP/t1239-ac2.err" ||
    fail "1239 AC2: the held desktop diagnostics are missing: $(cat "$TMP/t1239-ac2.err")"
  grep -qF "remote host 'mac-work' skipped: remote-full" "$TMP/t1239-ac2.err" ||
    fail "1239 AC2: the held mac-work diagnostics are missing: $(cat "$TMP/t1239-ac2.err")"
  grep -qF "remote host 'desktop' failed (rc=255) at step 'probe'" "$TMP/t1239-ac2.err" ||
    fail "1239 AC2: the held desktop summary is missing: $(cat "$TMP/t1239-ac2.err")"
  [[ "$(grep -c '^burst request ' "$TMP/t1239-wake.log")" -eq 1 ]] ||
    fail "1239 AC2: a timed-out wake must not stack a second burst request"
  ! grep -q 'tab create' "$TMP/t1239-herdr.log" ||
    fail "1239 AC2: a local pane was created after a wake attempt"
  # The hub-side timeout answers the same way through the reason JSON.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  set +e
  ( T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_BURST_SCENARIO=target-timeout T1239_JOB=t1239-ac2b t1239_spawn ) \
      >"$TMP/t1239-ac2b.out" 2>"$TMP/t1239-ac2b.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 81 ]] ||
    fail "1239 AC2b: a hub target_timeout must answer rc=81, got $t1239_rc"
  t1239_last="$(tail -n 1 "$TMP/t1239-ac2b.err")"
  [[ "$t1239_last" == "wrk: remote host 'desktop' wake timed out after 2s (burst hold requested, node not connected); not falling back to local" ]] ||
    fail "1239 AC2b: expected the timeout line, got: $t1239_last"
  echo "PASS t1239 AC2 wake-timeout-refuses-81"

  # AC3: every burst refusal form fails closed — the JSON reasons, a CLI
  # rejection, and a transport failure. cooldown_active is the concurrency
  # answer, not a refusal: it waits on the in-flight wake, so a cooldown
  # whose node never arrives ends on the wrk-side timeout (still rc 81).
  for t1239_scenario in target-unavailable wake-via-unavailable invalid-request; do
    t1239_reason="${t1239_scenario//-/_}"
    rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
    set +e
    ( T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
        T1239_BURST_SCENARIO="$t1239_scenario" T1239_JOB="t1239-ac3-$t1239_scenario" \
        t1239_spawn ) >"$TMP/t1239-ac3-$t1239_scenario.out" 2>"$TMP/t1239-ac3-$t1239_scenario.err"
    t1239_rc=$?
    set -e
    [[ "$t1239_rc" -eq 81 ]] ||
      fail "1239 AC3 $t1239_scenario: expected rc=81, got $t1239_rc: $(cat "$TMP/t1239-ac3-$t1239_scenario.err")"
    t1239_last="$(tail -n 1 "$TMP/t1239-ac3-$t1239_scenario.err")"
    [[ "$t1239_last" == "wrk: remote host 'desktop' wake refused ($t1239_reason); not falling back to local" ]] ||
      fail "1239 AC3 $t1239_scenario: expected the refusal line, got: $t1239_last"
    ! grep -q 'tab create' "$TMP/t1239-herdr.log" ||
      fail "1239 AC3 $t1239_scenario: a local pane was created after a wake refusal"
    [[ "$(grep -c '^burst request ' "$TMP/t1239-wake.log")" -eq 1 ]] ||
      fail "1239 AC3 $t1239_scenario: expected one burst request"
  done
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  set +e
  ( T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_BURST_SCENARIO=cooldown T1239_JOB=t1239-ac3-cooldown t1239_spawn ) \
      >"$TMP/t1239-ac3-cooldown.out" 2>"$TMP/t1239-ac3-cooldown.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 81 ]] ||
    fail "1239 AC3 cooldown: expected rc=81, got $t1239_rc"
  t1239_last="$(tail -n 1 "$TMP/t1239-ac3-cooldown.err")"
  [[ "$t1239_last" == "wrk: remote host 'desktop' wake timed out after 2s (cooldown_active: a wake is already in progress, node not connected); not falling back to local" ]] ||
    fail "1239 AC3 cooldown: expected the cooldown-wait timeout line, got: $t1239_last"
  ! grep -q 'tab create' "$TMP/t1239-herdr.log" ||
    fail "1239 AC3 cooldown: a local pane was created"
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  set +e
  ( T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_BURST_SCENARIO=cli-fail T1239_JOB=t1239-ac3-cli t1239_spawn ) \
      >"$TMP/t1239-ac3-cli.out" 2>"$TMP/t1239-ac3-cli.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 81 ]] ||
    fail "1239 AC3 cli-fail: expected rc=81, got $t1239_rc"
  t1239_last="$(tail -n 1 "$TMP/t1239-ac3-cli.err")"
  [[ "$t1239_last" == "wrk: remote host 'desktop' wake failed (panewire burst request exited 5: burst rejected: invalid operator token env); not falling back to local" ]] ||
    fail "1239 AC3 cli-fail: expected the CLI failure line, got: $t1239_last"
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  set +e
  ( T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_BURST_SCENARIO=unavailable T1239_JOB=t1239-ac3-unavail t1239_spawn ) \
      >"$TMP/t1239-ac3-unavail.out" 2>"$TMP/t1239-ac3-unavail.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 81 ]] ||
    fail "1239 AC3 unavailable: expected rc=81, got $t1239_rc"
  t1239_last="$(tail -n 1 "$TMP/t1239-ac3-unavail.err")"
  [[ "$t1239_last" == "wrk: remote host 'desktop' wake failed (burst unavailable); not falling back to local" ]] ||
    fail "1239 AC3 unavailable: expected the transport failure line, got: $t1239_last"
  echo "PASS t1239 AC3 burst-refusals-and-cli-failure"

  # AC4(a): mac-work has a free slot — the job lands there without a burst.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  set +e
  ( T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=ok \
      T1239_JOB=t1239-ac4a t1239_spawn ) >"$TMP/t1239-ac4a.out" 2>"$TMP/t1239-ac4a.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 0 ]] ||
    fail "1239 AC4a: expected rc=0 landing on mac-work, got $t1239_rc: $(cat "$TMP/t1239-ac4a.err")"
  grep -qF 'OK pane=mac-work:p7 host=mac-work' "$TMP/t1239-ac4a.out" ||
    fail "1239 AC4a: expected the mac-work OK line: $(cat "$TMP/t1239-ac4a.out")"
  if [[ -f "$TMP/t1239-wake.log" ]]; then
    ! grep -q '^burst ' "$TMP/t1239-wake.log" ||
      fail "1239 AC4a: a burst request fired while mac-work had a free slot"
  fi
  # AC4(b): local is healthy — the spawn stays local and desktop is never
  # woken (it is not even probed).
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  set +e
  ( T1239_LOAD_FILE="$T1239_LOAD" T1239_SSH_SCENARIO_DESKTOP=desktop-asleep \
      T1239_JOB=t1239-ac4b t1239_spawn ) >"$TMP/t1239-ac4b.out" 2>"$TMP/t1239-ac4b.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 0 ]] ||
    fail "1239 AC4b: expected rc=0 landing local, got $t1239_rc: $(cat "$TMP/t1239-ac4b.err")"
  grep -q 'host=local' "$TMP/t1239-ac4b.out" ||
    fail "1239 AC4b: expected a local landing: $(cat "$TMP/t1239-ac4b.out")"
  grep -q 'tab create' "$TMP/t1239-herdr.log" ||
    fail "1239 AC4b: the local pane was not created: $(cat "$TMP/t1239-herdr.log")"
  if [[ -f "$TMP/t1239-wake.log" ]]; then
    ! grep -q '^burst ' "$TMP/t1239-wake.log" ||
      fail "1239 AC4b: a burst request fired while local was healthy"
  fi
  # AC4(c): desktop already reachable — no burst, the job just lands.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  set +e
  ( T1239_SSH_SCENARIO_MAC_WORK=probe-full T1239_JOB=t1239-ac4c t1239_spawn ) \
      >"$TMP/t1239-ac4c.out" 2>"$TMP/t1239-ac4c.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 0 ]] ||
    fail "1239 AC4c: expected rc=0 landing on reachable desktop, got $t1239_rc: $(cat "$TMP/t1239-ac4c.err")"
  cmp -s "$TMP/t1239-ac1.want" "$TMP/t1239-ac4c.out" ||
    fail "1239 AC4c: expected the desktop OK line: $(cat "$TMP/t1239-ac4c.out")"
  if [[ -f "$TMP/t1239-wake.log" ]]; then
    ! grep -q '^burst ' "$TMP/t1239-wake.log" ||
      fail "1239 AC4c: a burst request fired while desktop was already reachable"
  fi
  echo "PASS t1239 AC4 no-wake-when-unneeded"

  # AC5(a): with BOTH credentials configured the wake must carry
  # operator_token_env — never hub_token_env.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  set +e
  ( T1239_HOSTS_OVERRIDE="$T1239_HOSTS_BOTH" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_JOB=t1239-ac5a t1239_spawn ) >"$TMP/t1239-ac5a.out" 2>"$TMP/t1239-ac5a.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 0 ]] ||
    fail "1239 AC5a: expected rc=0, got $t1239_rc: $(cat "$TMP/t1239-ac5a.err")"
  t1239_wake_line="$(grep '^burst request ' "$TMP/t1239-wake.log")"
  [[ "$t1239_wake_line" == *"--hub-token-env $T1239_OPERATOR"* ]] ||
    fail "1239 AC5a: the wake must carry operator_token_env: $t1239_wake_line"
  [[ "$t1239_wake_line" != *"$T1239_NODE_TOKEN"* ]] ||
    fail "1239 AC5a: the wake must never carry hub_token_env when operator_token_env is set: $t1239_wake_line"
  # AC5(b): hub_token_env alone is the fallback credential.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  set +e
  ( T1239_HOSTS_OVERRIDE="$T1239_HOSTS_TOKEN_ONLY" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_JOB=t1239-ac5b t1239_spawn ) >"$TMP/t1239-ac5b.out" 2>"$TMP/t1239-ac5b.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 0 ]] ||
    fail "1239 AC5b: expected rc=0 with the hub_token_env fallback, got $t1239_rc: $(cat "$TMP/t1239-ac5b.err")"
  t1239_wake_line="$(grep '^burst request ' "$TMP/t1239-wake.log")"
  [[ "$t1239_wake_line" == *"--hub-token-env $T1239_NODE_TOKEN"* ]] ||
    fail "1239 AC5b: the fallback must carry hub_token_env: $t1239_wake_line"
  # AC5(c): neither credential — a clear skip message on the same failure
  # path, and no burst call at all.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  set +e
  ( T1239_HOSTS_OVERRIDE="$T1239_HOSTS_NO_CRED" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_JOB=t1239-ac5c t1239_spawn ) >"$TMP/t1239-ac5c.out" 2>"$TMP/t1239-ac5c.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 81 ]] ||
    fail "1239 AC5c: expected rc=81 with no credential, got $t1239_rc: $(cat "$TMP/t1239-ac5c.err")"
  t1239_last="$(tail -n 1 "$TMP/t1239-ac5c.err")"
  [[ "$t1239_last" == "wrk: remote host 'desktop' wake skipped ([hub] needs hub_url plus an operator credential: operator_token_env, else hub_token_env); not falling back to local" ]] ||
    fail "1239 AC5c: expected the skip message, got: $t1239_last"
  if [[ -f "$TMP/t1239-wake.log" ]]; then
    ! grep -q '^burst ' "$TMP/t1239-wake.log" ||
      fail "1239 AC5c: a burst request fired with no credential configured"
  fi
  echo "PASS t1239 AC5 credential-routing"

  # AC6: two concurrent auto spawns both needing desktop — the first burst
  # takes the atomic held marker and wakes the node; the second answers
  # cooldown_active, waits on the in-flight wake, probes, and still lands.
  # Both rc 0, both desktop OK lines, exactly two burst requests.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_BURST_SCENARIO=cooldown-after-first T1239_JOB=t1239-ac6-a \
      t1239_spawn ) >"$TMP/t1239-ac6a.out" 2>"$TMP/t1239-ac6a.err" &
  t1239_p1=$!
  ( T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_BURST_SCENARIO=cooldown-after-first T1239_JOB=t1239-ac6-b \
      t1239_spawn ) >"$TMP/t1239-ac6b.out" 2>"$TMP/t1239-ac6b.err" &
  t1239_p2=$!
  wait "$t1239_p1"; t1239_rc1=$?
  wait "$t1239_p2"; t1239_rc2=$?
  set -e
  [[ "$t1239_rc1" -eq 0 && "$t1239_rc2" -eq 0 ]] ||
    fail "1239 AC6: both concurrent spawns must land (rc1=$t1239_rc1 rc2=$t1239_rc2): $(cat "$TMP/t1239-ac6a.err" "$TMP/t1239-ac6b.err")"
  cmp -s "$TMP/t1239-ac1.want" "$TMP/t1239-ac6a.out" ||
    fail "1239 AC6a: expected the desktop OK line: $(cat "$TMP/t1239-ac6a.out")"
  cmp -s "$TMP/t1239-ac1.want" "$TMP/t1239-ac6b.out" ||
    fail "1239 AC6b: expected the desktop OK line: $(cat "$TMP/t1239-ac6b.out")"
  [[ "$(grep -c '^burst request ' "$TMP/t1239-wake.log")" -eq 2 ]] ||
    fail "1239 AC6: expected two burst requests (one wake, one cooldown answer): $(cat "$TMP/t1239-wake.log")"
  echo "PASS t1239 AC6 concurrent-wake-cooldown-waits"

  # An explicit --host NAME on an unreachable wake host wakes it too —
  # the hosts.toml key is the opt-in — and times out the same way.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_HOST_ARG=desktop T1239_SSH_SCENARIO_DESKTOP=desktop-asleep \
      T1239_JOB=t1239-exp1 t1239_spawn ) >"$TMP/t1239-exp1.out" 2>"$TMP/t1239-exp1.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 0 ]] ||
    fail "1239 explicit-host: expected rc=0 after the wake, got $t1239_rc: $(cat "$TMP/t1239-exp1.err")"
  cmp -s "$TMP/t1239-ac1.want" "$TMP/t1239-exp1.out" ||
    fail "1239 explicit-host: expected the desktop OK line: $(cat "$TMP/t1239-exp1.out")"
  [[ "$(grep -c '^burst request ' "$TMP/t1239-wake.log")" -eq 1 ]] ||
    fail "1239 explicit-host: expected one burst request: $(cat "$TMP/t1239-wake.log")"
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_HOST_ARG=desktop T1239_SSH_SCENARIO_DESKTOP=desktop-asleep \
      T1239_BURST_SCENARIO=no-up T1239_JOB=t1239-exp2 t1239_spawn ) \
      >"$TMP/t1239-exp2.out" 2>"$TMP/t1239-exp2.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 81 ]] ||
    fail "1239 explicit-host timeout: expected rc=81, got $t1239_rc: $(cat "$TMP/t1239-exp2.err")"
  t1239_last="$(tail -n 1 "$TMP/t1239-exp2.err")"
  [[ "$t1239_last" == "wrk: remote host 'desktop' wake timed out after 2s (burst hold requested, node not connected); not falling back to local" ]] ||
    fail "1239 explicit-host timeout: expected the timeout line, got: $t1239_last"
  ! grep -q 'tab create' "$TMP/t1239-herdr.log" ||
    fail "1239 explicit-host timeout: a local pane was created"
  echo "PASS t1239 explicit-host-wake"

  # -- Round-2 fix tests (tester B1/B2, verdict 1239-verify-20261002-0149) --

  # R2(a) live candidate order: desktop asleep+wake, oci reachable but
  # unmapped for this cwd (skipped BEFORE its probe — no stop, no latch),
  # mac-dev remote-full, rpi unmapped. The wake fires and the job lands on
  # desktop — for an agent-skills cwd AND for an auto_trader cwd.
  for t1239_cwd_name in agent-skills auto_trader; do
    if [[ "$t1239_cwd_name" == agent-skills ]]; then
      t1239_scenario_cwd="$ROOT"
    else
      t1239_scenario_cwd="$T1239_TRADER"
    fi
    rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
    rm -rf "$T1239_AWAKE.held"
    set +e
    ( T1239_HOSTS_OVERRIDE="$T1239_HOSTS_LIVE" T1239_CWD="$t1239_scenario_cwd" \
        T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_DEV=probe-full \
        T1239_JOB="t1239-r2a-$t1239_cwd_name" t1239_spawn ) \
        >"$TMP/t1239-r2a-$t1239_cwd_name.out" 2>"$TMP/t1239-r2a-$t1239_cwd_name.err"
    t1239_rc=$?
    set -e
    [[ "$t1239_rc" -eq 0 ]] ||
      fail "1239 R2a($t1239_cwd_name): expected rc=0 after the wake, got $t1239_rc: $(cat "$TMP/t1239-r2a-$t1239_cwd_name.err")"
    cmp -s "$TMP/t1239-ac1.want" "$TMP/t1239-r2a-$t1239_cwd_name.out" ||
      fail "1239 R2a($t1239_cwd_name): expected the desktop OK line: $(cat "$TMP/t1239-r2a-$t1239_cwd_name.out")"
    [[ "$(grep -c '^burst request ' "$TMP/t1239-wake.log")" -eq 1 ]] ||
      fail "1239 R2a($t1239_cwd_name): expected exactly one burst request: $(cat "$TMP/t1239-wake.log" 2>/dev/null || true)"
    t1239_wake_line="$(grep '^burst request ' "$TMP/t1239-wake.log")"
    [[ "$t1239_wake_line" == *'--target desktop'* ]] ||
      fail "1239 R2a($t1239_cwd_name): burst request missing --target desktop: $t1239_wake_line"
    ! grep -q 'no cwd_map entry' "$TMP/t1239-r2a-$t1239_cwd_name.err" ||
      fail "1239 R2a($t1239_cwd_name): skipped-candidate diagnostics must stay silent on a landed round: $(cat "$TMP/t1239-r2a-$t1239_cwd_name.err")"
    ! grep -q 'oci' "$TMP/t1239-ssh.log" ||
      fail "1239 R2a($t1239_cwd_name): the unmapped candidate must be skipped before its probe: $(cat "$TMP/t1239-ssh.log")"
  done
  echo "PASS t1239 R2a live-order-wake-lands-desktop (agent-skills + auto_trader)"

  # R2(b) same live order, but oci mapped and free — the job lands on oci
  # and no wake fires (the unmapped rpi still skips pre-probe).
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_HOSTS_OVERRIDE="$T1239_HOSTS_LIVE_OCI" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_DEV=probe-full \
      T1239_JOB=t1239-r2b t1239_spawn ) >"$TMP/t1239-r2b.out" 2>"$TMP/t1239-r2b.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 0 ]] ||
    fail "1239 R2b: expected rc=0 landing on oci, got $t1239_rc: $(cat "$TMP/t1239-r2b.err")"
  grep -qF 'OK pane=oci:p7 host=oci' "$TMP/t1239-r2b.out" ||
    fail "1239 R2b: expected the oci OK line: $(cat "$TMP/t1239-r2b.out")"
  if [[ -f "$TMP/t1239-wake.log" ]]; then
    ! grep -q '^burst ' "$TMP/t1239-wake.log" ||
      fail "1239 R2b: a burst request fired although oci had a free slot"
  fi
  echo "PASS t1239 R2b oci-free-lands-no-wake"

  # R2(c) a non-capacity remote answer (rc 80, or a transport failure) does
  # NOT suppress the wake while another candidate answered remote-full.
  for t1239_reason in rc80 transport; do
    rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
    rm -rf "$T1239_AWAKE.held"
    if [[ "$t1239_reason" == rc80 ]]; then
      t1239_scenario=remote-spawn-disabled
    else
      t1239_scenario=probe-unreachable
    fi
    set +e
    ( T1239_HOSTS_OVERRIDE="$T1239_HOSTS_LIVE_RPI" \
        T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_DEV="$t1239_scenario" \
        T1239_SSH_SCENARIO_RPI=probe-full T1239_JOB="t1239-r2c-$t1239_reason" t1239_spawn ) \
        >"$TMP/t1239-r2c-$t1239_reason.out" 2>"$TMP/t1239-r2c-$t1239_reason.err"
    t1239_rc=$?
    set -e
    [[ "$t1239_rc" -eq 0 ]] ||
      fail "1239 R2c($t1239_reason): expected rc=0 after the wake, got $t1239_rc: $(cat "$TMP/t1239-r2c-$t1239_reason.err")"
    cmp -s "$TMP/t1239-ac1.want" "$TMP/t1239-r2c-$t1239_reason.out" ||
      fail "1239 R2c($t1239_reason): expected the desktop OK line: $(cat "$TMP/t1239-r2c-$t1239_reason.out")"
    [[ "$(grep -c '^burst request ' "$TMP/t1239-wake.log")" -eq 1 ]] ||
      fail "1239 R2c($t1239_reason): the wake must still fire: $(cat "$TMP/t1239-wake.log" 2>/dev/null || true)"
  done
  echo "PASS t1239 R2c non-capacity-answer-still-wakes (rc80 + transport)"

  # R2(d) no remote-full evidence anywhere (mac-dev unreachable, oci and
  # rpi unmapped, local spawns disabled): no wake, the all-fail path answers
  # non-zero with the held diagnostics, and no local pane is created.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_HOSTS_OVERRIDE="$T1239_HOSTS_LIVE_NOLOCAL" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_DEV=probe-unreachable \
      T1239_JOB=t1239-r2d t1239_spawn ) >"$TMP/t1239-r2d.out" 2>"$TMP/t1239-r2d.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 80 ]] ||
    fail "1239 R2d: expected rc=80 (local disabled, all-fail), got $t1239_rc: $(cat "$TMP/t1239-r2d.err")"
  grep -qF "wrk: remote host 'oci' skipped: no cwd_map entry for" "$TMP/t1239-r2d.err" ||
    fail "1239 R2d: the all-fail round must replay the held skip diagnostic: $(cat "$TMP/t1239-r2d.err")"
  grep -qF "wrk: remote host 'rpi' skipped: no cwd_map entry for" "$TMP/t1239-r2d.err" ||
    fail "1239 R2d: the all-fail round must replay the held skip diagnostic for rpi: $(cat "$TMP/t1239-r2d.err")"
  grep -qF "wrk: remote host 'desktop' probe failed" "$TMP/t1239-r2d.err" ||
    fail "1239 R2d: the all-fail round must replay the desktop probe line: $(cat "$TMP/t1239-r2d.err")"
  if [[ -f "$TMP/t1239-wake.log" ]]; then
    ! grep -q '^burst ' "$TMP/t1239-wake.log" ||
      fail "1239 R2d: a burst request fired with no remote-full evidence"
  fi
  ! grep -q 'tab create' "$TMP/t1239-herdr.log" ||
    fail "1239 R2d: a local pane was created although local spawns are disabled"
  echo "PASS t1239 R2d no-remote-full-no-wake"

  # R2(e) post-wake placement failure under auto propagates the remote rc —
  # the tester reproduced rc 42 exiting as 0 because last_rc read the `if`.
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_HOSTS_OVERRIDE="$T1239_HOSTS_LIVE" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep-fail42 T1239_SSH_SCENARIO_MAC_DEV=probe-full \
      T1239_JOB=t1239-r2e t1239_spawn ) >"$TMP/t1239-r2e.out" 2>"$TMP/t1239-r2e.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 42 ]] ||
    fail "1239 R2e: a post-wake placement failure must propagate rc=42, got $t1239_rc: $(cat "$TMP/t1239-r2e.err")"
  grep -qF "wrk: remote host 'desktop' answered its wake but the spawn still failed (rc=42); not falling back to local" \
    "$TMP/t1239-r2e.err" ||
    fail "1239 R2e: the failure line must name the real rc: $(cat "$TMP/t1239-r2e.err")"
  ! grep -q 'tab create' "$TMP/t1239-herdr.log" ||
    fail "1239 R2e: a local pane was created after a wake attempt"
  echo "PASS t1239 R2e post-wake-failure-propagates-42"

  # AC7 assertion-RED mutants — each breaks exactly one invariant.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  # M1 "a failed wake never lands a local pane" — the mutant drops the
  # rc-81 return so a failed wake falls through to the local fallback;
  # AC2's assertion fails.
  devin_trust_mutant t1239-wake-local-fallback \
    '    echo "wrk: $SPILL_WAKE_ERR; not falling back to local" >&2
    return "$WRK_EXIT_WAKE_FAILED"' \
    '    warn "$SPILL_WAKE_ERR; falling back to local anyway"'
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_WRK="$TMP/mut-wrk-t1239-wake-local-fallback" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_BURST_SCENARIO=no-up T1239_JOB=t1239-m1 t1239_spawn ) \
      >"$TMP/t1239-m1.out" 2>"$TMP/t1239-m1.err"
  t1239_rc=$?
  set -e
  if [[ "$t1239_rc" -eq 81 ]]; then
    fail "1239 M1 mutant survived: the failed wake still refused rc=81"
  fi
  grep -q 'host=local' "$TMP/t1239-m1.out" ||
    fail "1239 M1: the mutant should land the local fallback pane"
  grep -q 'tab create' "$TMP/t1239-herdr.log" ||
    fail "1239 M1: the mutant should show the forbidden local pane creation"
  echo "PASS t1239 M1: wake-local-fallback mutant goes RED (AC2 assertion 'rc=81, no local pane' fails: rc=$t1239_rc, local pane created)"

# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  # M2 "desktop is woken only after every other candidate refused for
  # capacity" — the mutant wakes on first sight inside the probe-fail arm,
  # so AC4(a)'s 'm1b has a free slot, no burst' assertion fails.
  devin_trust_mutant t1239-wake-first-sight \
    '  if ! spillover_probe_host "$candidate"; then
    # #1239: a wake-capable host is NOT woken here, on first sight' \
    '  if ! spillover_probe_host "$candidate"; then
    [[ "$SPILL_PROBE_REASON" == ssh-unreachable ]] && { spillover_wake_request "$candidate" || true; }
    # #1239: a wake-capable host is NOT woken here, on first sight'
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_WRK="$TMP/mut-wrk-t1239-wake-first-sight" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=ok \
      T1239_JOB=t1239-m2 t1239_spawn ) >"$TMP/t1239-m2.out" 2>"$TMP/t1239-m2.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 0 ]] ||
    fail "1239 M2: the mutant should still land on mac-work, got rc=$t1239_rc"
  grep -qF 'OK pane=mac-work:p7 host=mac-work' "$TMP/t1239-m2.out" ||
    fail "1239 M2: the mutant should land mac-work: $(cat "$TMP/t1239-m2.out")"
  grep -q '^burst request ' "$TMP/t1239-wake.log" ||
    fail "1239 M2: the first-sight mutant must show a burst request"
  echo "PASS t1239 M2: wake-on-first-sight mutant goes RED (AC4 assertion 'm1b free slot lands with no burst request' fails: burst request present)"

# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  # M3 "the wake never uses hub_token_env when operator_token_env is set" —
  # the mutant swaps the precedence; AC5(a)'s argv assertion fails.
  devin_trust_mutant t1239-wake-cred-swap \
    '  token_env="$(spillover_value hub operator_token_env 2>/dev/null || true)"
  if [[ -z "$token_env" ]]; then
    token_env="$(spillover_value hub hub_token_env 2>/dev/null || true)"
  fi' \
    '  token_env="$(spillover_value hub hub_token_env 2>/dev/null || true)"
  if [[ -z "$token_env" ]]; then
    token_env="$(spillover_value hub operator_token_env 2>/dev/null || true)"
  fi'
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_WRK="$TMP/mut-wrk-t1239-wake-cred-swap" \
      T1239_HOSTS_OVERRIDE="$T1239_HOSTS_BOTH" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_WORK=probe-full \
      T1239_JOB=t1239-m3 t1239_spawn ) >"$TMP/t1239-m3.out" 2>"$TMP/t1239-m3.err"
  t1239_rc=$?
  set -e
  [[ "$t1239_rc" -eq 0 ]] ||
    fail "1239 M3: the mutant should still land on desktop, got rc=$t1239_rc: $(cat "$TMP/t1239-m3.err")"
  t1239_wake_line="$(grep '^burst request ' "$TMP/t1239-wake.log")"
  [[ "$t1239_wake_line" == *"--hub-token-env $T1239_NODE_TOKEN"* ]] ||
    fail "1239 M3: the precedence-swapped mutant must carry hub_token_env: $t1239_wake_line"
  echo "PASS t1239 M3: cred-swap mutant goes RED (AC5 assertion 'burst carries operator_token_env' fails: argv carried $T1239_NODE_TOKEN)"

# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  # M4 "an unmapped candidate never ends an auto round" — the mutant keeps
  # the rc-2 stop by disabling the pre-probe skip: oci probes reachable,
  # its remote refuses rc 2 at cwd-map, the stop set ends the round before
  # the post-round wake; R2(a)'s 'wake fires, lands desktop' fails.
  devin_trust_mutant t1239-unmapped-stops-round \
    '      if [[ "$SPILL_DECISION_SOURCE" == local-fallback ]] &&
         ! spillover_cwd_map "$candidate" "$cwd"; then' \
    '      if false &&
         ! spillover_cwd_map "$candidate" "$cwd"; then'
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_WRK="$TMP/mut-wrk-t1239-unmapped-stops-round" \
      T1239_HOSTS_OVERRIDE="$T1239_HOSTS_LIVE" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_DEV=probe-full \
      T1239_JOB=t1239-m4 t1239_spawn ) >"$TMP/t1239-m4.out" 2>"$TMP/t1239-m4.err"
  t1239_rc=$?
  set -e
  if [[ "$t1239_rc" -eq 0 ]]; then
    fail "1239 M4 mutant survived: the unmapped candidate no longer ends the round"
  fi
  grep -q 'cwd-map' "$TMP/t1239-m4.err" ||
    fail "1239 M4: the mutant should end the round on the cwd-map rc 2: $(cat "$TMP/t1239-m4.err")"
  echo "PASS t1239 M4: unmapped-stops-round mutant goes RED (R2a assertion 'wake fires, job lands on desktop' fails: rc=$t1239_rc)"

# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  # M5 "a post-wake placement failure is never rc 0" — the mutant restores
  # the missing else so last_rc reads the if-statement's status; R2(e)'s
  # 'rc=42 propagates' fails.
  devin_trust_mutant t1239-wake-rc-swallowed \
    '          return 0
        else
          last_rc=$?
        fi
        cat "$cand_err" >>"$auto_diag"' \
    '          return 0
        fi
        last_rc=$?
        cat "$cand_err" >>"$auto_diag"'
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_WRK="$TMP/mut-wrk-t1239-wake-rc-swallowed" \
      T1239_HOSTS_OVERRIDE="$T1239_HOSTS_LIVE" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep-fail42 T1239_SSH_SCENARIO_MAC_DEV=probe-full \
      T1239_JOB=t1239-m5 t1239_spawn ) >"$TMP/t1239-m5.out" 2>"$TMP/t1239-m5.err"
  t1239_rc=$?
  set -e
  if [[ "$t1239_rc" -eq 42 ]]; then
    fail "1239 M5 mutant survived: the post-wake failure still exited 42"
  fi
  grep -qF 'spawn still failed (rc=0)' "$TMP/t1239-m5.err" ||
    fail "1239 M5: the mutant should report the swallowed rc as 0: $(cat "$TMP/t1239-m5.err")"
  echo "PASS t1239 M5: wake-rc-swallowed mutant goes RED (R2e assertion 'rc=42 propagates' fails: rc=$t1239_rc, line reports rc=0)"

# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  # M6 "no wake without remote-full evidence" — the mutant drops condition
  # (d); R2(d)'s 'no burst request' fails.
  devin_trust_mutant t1239-wake-no-evidence \
    '    if [[ -n "$wake_pending" && "$remote_full_seen" -eq 1 ]] &&' \
    '    if [[ -n "$wake_pending" ]] &&'
  rm -f "$TMP/t1239-wake.log" "$TMP/t1239-ssh.log" "$TMP/t1239-herdr.log" "$T1239_AWAKE"
  rm -rf "$T1239_AWAKE.held"
  set +e
  ( T1239_WRK="$TMP/mut-wrk-t1239-wake-no-evidence" \
      T1239_HOSTS_OVERRIDE="$T1239_HOSTS_LIVE_NOLOCAL" \
      T1239_SSH_SCENARIO_DESKTOP=desktop-asleep T1239_SSH_SCENARIO_MAC_DEV=probe-unreachable \
      T1239_JOB=t1239-m6 t1239_spawn ) >"$TMP/t1239-m6.out" 2>"$TMP/t1239-m6.err"
  t1239_rc=$?
  set -e
  grep -q '^burst request ' "$TMP/t1239-wake.log" ||
    fail "1239 M6 mutant survived: no wake fired without remote-full evidence"
  echo "PASS t1239 M6: wake-no-evidence mutant goes RED (R2d assertion 'no wake without remote-full' fails: burst request present)"
}

# Slice gate: WRK_TEST_ONLY_DESKTOP_WAKE=1 runs only this section after the
# shared setup — the full suite still runs it in order.
if [[ "${WRK_TEST_ONLY_DESKTOP_WAKE:-0}" -eq 1 ]]; then
  run_t1239_desktop_wake_tests
  exit 0
fi
run_t1239_desktop_wake_tests

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
  grep -q 'gate blocked profile=codex-luna-max' "$HUB_QUOTA_ERR" ||
    fail "W1 scopefuel exit 3 stderr was not preserved"
  echo "PASS hub-quota-local-contract exit-3=deny"

  hub_quota_run_case local-contract-4 0 4 "$unconfigured"
  hub_quota_expect_rc local-contract-4 4
  hub_quota_expect_spawn local-contract-4 0
  grep -q 'gate measurement unavailable profile=codex-luna-max' "$HUB_QUOTA_ERR" ||
    fail "W1 scopefuel exit 4 stderr was not preserved"
  echo "PASS hub-quota-local-contract exit-4=unknown"

  # The scopefuel success payload remains the exact two-line prefix consumed by
  # arbiter. The hub call receives only the pool emitted by scopefuel.
  hub_quota_run_case allow-local-0 0 ok "$configured"
  hub_quota_expect_rc allow/local-0 0
  hub_quota_expect_spawn allow/local-0 1
  [[ "$(sed -n '1p' "$HUB_QUOTA_OUT")" == 'profile=codex-luna-max pool=codex used_pct=12.5 class=preserve' ]] ||
    fail "scopefuel gate stdout line 1 was not reprinted verbatim"
  [[ "$(sed -n '2p' "$HUB_QUOTA_OUT")" == 'gate allowed profile=codex-luna-max' ]] ||
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
  hub_quota_expect_warn allow/local-0 0
  echo "PASS hub-quota-combination allow/0=allow"

  # Local denial/unknown terminates before hub policy can override it. The fake
  # hub is configured to allow, and non-invocation is part of the assertion.
  hub_quota_run_case allow-local-3 0 3 "$configured"
  hub_quota_expect_rc allow/local-3 3
  hub_quota_expect_spawn allow/local-3 0
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "hub allow was consulted after local exit 3"
  grep -q 'gate blocked profile=codex-luna-max' "$HUB_QUOTA_ERR" ||
    fail "scopefuel exit 3 stderr was not preserved"
  echo "PASS hub-quota-combination allow/3=deny"

  hub_quota_run_case allow-local-4 0 4 "$configured"
  hub_quota_expect_rc allow/local-4 4
  hub_quota_expect_spawn allow/local-4 0
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "hub allow was consulted after local exit 4"
  grep -q 'gate measurement unavailable profile=codex-luna-max' "$HUB_QUOTA_ERR" ||
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
  [[ "$(sed -n '1p' "$HUB_QUOTA_OUT")" == 'profile=codex-luna-max pool=codex used_pct=12.5 class=preserve' ]] ||
    fail "hub-unconfigured path changed local gate stdout"
  # No [hub] section: stderr keeps its main shape — the #1138 warning is
  # reachable only when hub_url is set.
  hub_quota_expect_warn unconfigured/local-0 0
  echo "PASS hub-quota-unconfigured-preserves-local-only"

  # #1037: the opt-in is the operator credential alone — a configured
  # hub_token_env. hub_url (with or without hub_cf_env) and a lanes-only
  # lanes_token_env must not switch the gate on: they run the exact
  # local-only path above. (Before #1037 any hub key opted in, so each of
  # these used to refuse every spawn with rc 70.)
  local url_only="$TMP/hub-quota-url-only.toml"
  local url_cf="$TMP/hub-quota-url-cf.toml"
  local lanes_only="$TMP/hub-quota-lanes-only.toml"
  local token_only="$TMP/hub-quota-token-only.toml"
  printf '[hub]\nhub_url = "https://hub.invalid"\n' >"$url_only"
  printf '[hub]\nhub_url = "https://hub.invalid"\nhub_cf_env = "%s"\n' "$cf_file" >"$url_cf"
  printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\n' "$token_file" >"$lanes_only"
  printf '[hub]\nhub_token_env = "%s"\n' "$token_file" >"$token_only"

  hub_quota_run_case url-only-local-0 70 ok "$url_only"
  hub_quota_expect_rc url-only-local-0 0
  hub_quota_expect_spawn url-only-local-0 1
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "hub_url without a token key invoked panewire"
  # #1138: the local-only path is now said out loud — exactly one warning line.
  hub_quota_expect_warn url-only-local-0 1
  echo "PASS hub-quota-url-only-stays-local"

  hub_quota_run_case url-cf-local-0 70 ok "$url_cf"
  hub_quota_expect_rc url-cf-local-0 0
  hub_quota_expect_spawn url-cf-local-0 1
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "hub_url+hub_cf_env without hub_token_env invoked panewire"
  hub_quota_expect_warn url-cf-local-0 1
  echo "PASS hub-quota-url-cf-stays-local"

  hub_quota_run_case lanes-only-local-0 70 ok "$lanes_only"
  hub_quota_expect_rc lanes-only-local-0 0
  hub_quota_expect_spawn lanes-only-local-0 1
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "a lanes-only [hub] must not invoke panewire place"
  hub_quota_expect_warn lanes-only-local-0 1
  echo "PASS hub-quota-lanes-only-never-opts-in"

  # #1138: the warning is emitted at the top of the gate, before the
  # ARBITER_JOB_REGISTERED/GATE_READY evidence early-returns — a spawn whose
  # arbiter is absent (installation transition) still warns exactly once.
  HUB_QUOTA_ARBITER_BIN="$TMP/absent-arbiter" \
    hub_quota_run_case url-only-no-arbiter 70 ok "$url_only"
  unset HUB_QUOTA_ARBITER_BIN
  hub_quota_expect_rc url-only-no-arbiter 0
  hub_quota_expect_spawn url-only-no-arbiter 1
  hub_quota_expect_warn url-only-no-arbiter 1
  echo "PASS hub-quota-url-only-warns-once-on-early-return"

  # The genuinely partial gate config — hub_token_env without hub_url —
  # keeps its rc-70 fail-closed refusal.
  hub_quota_run_case token-no-url 0 ok "$token_only"
  hub_quota_expect_rc token-no-url 70
  hub_quota_expect_spawn token-no-url 0
  grep -q 'hub quota gate configuration is incomplete' "$HUB_QUOTA_ERR" ||
    fail "hub_token_env without hub_url must keep the incomplete-config refusal"
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "a partial gate config invoked panewire"
  # #1138: hub_url is empty here, so the skipped-gate warning stays silent.
  hub_quota_expect_warn token-no-url 0
  echo "PASS hub-quota-token-without-url-fails-closed"

  # -- #1138 quota_gate key --------------------------------------------------
  # quota_gate = "local" is the deliberate opt-out a lanes-only host uses:
  # the same local-only path without the warning. Any other value — and
  # "local" next to the hub_token_env that opts the gate in — is a config
  # error refusing the spawn fail-closed (rc 70).
  local gate_local="$TMP/hub-quota-gate-local.toml"
  local gate_local_lanes="$TMP/hub-quota-gate-local-lanes.toml"
  local gate_bogus="$TMP/hub-quota-gate-bogus.toml"
  local gate_local_token="$TMP/hub-quota-gate-local-token.toml"
  printf '[hub]\nhub_url = "https://hub.invalid"\nquota_gate = "local"\n' >"$gate_local"
  printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\nquota_gate = "local"\n' \
    "$token_file" >"$gate_local_lanes"
  printf '[hub]\nhub_url = "https://hub.invalid"\nquota_gate = "hub"\n' >"$gate_bogus"
  printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nquota_gate = "local"\n' \
    "$token_file" >"$gate_local_token"

  hub_quota_run_case gate-local 70 ok "$gate_local"
  hub_quota_expect_rc gate-local 0
  hub_quota_expect_spawn gate-local 1
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "quota_gate=local invoked panewire"
  hub_quota_expect_warn gate-local 0
  echo "PASS hub-quota-gate-local-stays-silent"

  hub_quota_run_case gate-local-lanes 70 ok "$gate_local_lanes"
  hub_quota_expect_rc gate-local-lanes 0
  hub_quota_expect_spawn gate-local-lanes 1
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "a lanes-only [hub] with quota_gate=local invoked panewire place"
  hub_quota_expect_warn gate-local-lanes 0
  echo "PASS hub-quota-gate-local-lanes-stays-silent"

  hub_quota_run_case gate-bogus 0 ok "$gate_bogus"
  hub_quota_expect_rc gate-bogus 70
  hub_quota_expect_spawn gate-bogus 0
  grep -q 'quota_gate accepts only "local"' "$HUB_QUOTA_ERR" ||
    fail "an unknown quota_gate value must refuse naming the accepted value: $(cat "$HUB_QUOTA_ERR")"
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "a malformed quota_gate invoked panewire"
  hub_quota_expect_warn gate-bogus 0
  echo "PASS hub-quota-gate-unknown-value-fails-closed"

  hub_quota_run_case gate-local-token 0 ok "$gate_local_token"
  hub_quota_expect_rc gate-local-token 70
  hub_quota_expect_spawn gate-local-token 0
  grep -q 'quota_gate = "local" contradicts hub_token_env' "$HUB_QUOTA_ERR" ||
    fail "quota_gate=local with hub_token_env must refuse naming both keys: $(cat "$HUB_QUOTA_ERR")"
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "a contradictory quota_gate config invoked panewire"
  echo "PASS hub-quota-gate-local-contradicts-token"

  # The credential files are passed by path only. Neither their contents nor
  # panewire output can enter wrk's stdout, stderr, or spill-over audit log.
  for output in "$TMP"/hub-quota-*.out "$TMP"/hub-quota-*.err "$TMP"/hub-quota-*-spillover.log; do
    if grep -Fq "$token_value" "$output"; then
      fail "hub token leaked into ${output##*/}"
    fi
  done
  echo "PASS hub-quota-token-redaction"

  # -- #1138 assertion-RED mutants ------------------------------------------
  # M1: "a hub_url-without-hub_token_env config always warns" — the mutant
  # drops the warning, so the url-only count assertion above goes RED (the
  # mutant run itself must show zero warning lines).
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant hub-1138-nowarn \
    '  if [[ -n "$hub_url" && -z "$token_env" && "${HUB_QUOTA_GATE_WARNED:-0}" -eq 0 ]]; then' \
    '  if false; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-hub-1138-nowarn" \
    hub_quota_run_case mut-nowarn 70 ok "$url_only"
  if [[ "$(hub_quota_warn_count)" -ne 0 ]]; then
    fail "#1138 M1 mutant survived: the url-only spawn still warned"
  fi
  echo "PASS 1138-hub M1: dropping the warning goes RED"

  # M2: "the warning prints once per spawn" — the mutant emits it twice, so
  # the exact-count assertions go RED.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant hub-1138-warntwice \
    '    warn "[hub] hub_url is set but hub_token_env is not; hub quota gate skipped (local scopefuel gate only)"' \
    '    warn "[hub] hub_url is set but hub_token_env is not; hub quota gate skipped (local scopefuel gate only)"
    warn "[hub] hub_url is set but hub_token_env is not; hub quota gate skipped (local scopefuel gate only)"'
  WRK_UNDER_TEST="$TMP/mut-wrk-hub-1138-warntwice" \
    hub_quota_run_case mut-warntwice 70 ok "$url_only"
  if [[ "$(hub_quota_warn_count)" -ne 2 ]]; then
    fail "#1138 M2 mutant survived: the doubled warning did not reach stderr"
  fi
  echo "PASS 1138-hub M2: emitting the warning twice goes RED"

  # M3: "an unknown quota_gate value is a config error" — the mutant treats an
  # unknown value as absent, so gate-bogus spawns rc 0 instead of refusing.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant hub-1138-gateabsent \
    '    if [[ "$quota_gate" != local ]]; then' \
    '    if false; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-hub-1138-gateabsent" \
    hub_quota_run_case mut-gateabsent 70 ok "$gate_bogus"
  if [[ "$HUB_QUOTA_RC" -eq 70 ]]; then
    fail "#1138 M3 mutant survived: an unknown quota_gate value still refused"
  fi
  echo "PASS 1138-hub M3: treating an unknown quota_gate as absent goes RED"
}

if [[ "${WRK_TEST_ONLY_HUB_QUOTA:-0}" -eq 1 ]]; then
  run_hub_quota_gate_tests
  exit 0
fi
run_hub_quota_gate_tests

# ---------------------------------------------------------------------------
# #965: a worker spawned under a hub-mapped herdr session registers a lane
# ---------------------------------------------------------------------------
# A host can run a second panewire daemon serving a non-fleet herdr session;
# hosts.toml's [hub] session_machine_ids maps the session to that daemon's hub
# machine id. A local --role worker spawn under a mapped session then runs
# `panewire lanes add` exactly once — after the pane is provably up, before the
# job.spawned receipt so the lane lands in the same job meta — and
# `wrk reap --apply` removes exactly that lane. Registration is warn-only at
# every step: an unmapped session, a missing --owner and a panewire refusal all
# spawn unregistered, and builder spawns never reach the call at all.
LANES_CFG="$TMP/lanes-hosts.toml"
LANES_TOKEN_FILE="$TMP/lanes-token.env"
LANES_CF_FILE="$TMP/lanes-cf.env"
LANES_TOKEN_VALUE="fixture-lanes-token-must-not-leak"
LANES_CF_VALUE="fixture-lanes-cf-must-not-leak"
printf 'HUB_TOKEN=%s\n' "$LANES_TOKEN_VALUE" >"$LANES_TOKEN_FILE"
printf 'CF_ACCESS_CLIENT_ID=fixture\nCF_ACCESS_CLIENT_SECRET=%s\n' "$LANES_CF_VALUE" >"$LANES_CF_FILE"
printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nhub_cf_env = "%s"\nsession_machine_ids = { "default" = "mac-work-default" }\n' \
  "$LANES_TOKEN_FILE" "$LANES_CF_FILE" >"$LANES_CFG"
# AC7's tripwire: the paths are passed to panewire, never opened — chmod 000
# turns a silent read of either file into a loud failure instead.
chmod 000 "$LANES_TOKEN_FILE" "$LANES_CF_FILE"
# A config with [hub] but no session_machine_ids key: the installation has not
# opted in, so the spawn stays silent — no warning, no call.
LANES_CFG_NOMAP="$TMP/lanes-nomap-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nhub_cf_env = "%s"\n' \
  "$LANES_TOKEN_FILE" "$LANES_CF_FILE" >"$LANES_CFG_NOMAP"

# #1037: a dedicated lanes credential — a node token file (HUB_MACHINE_ID/
# HUB_TOKEN) the lanes routes use instead of the operator file. Mode 0600,
# not the 000 tripwire above: wrk reads its HUB_MACHINE_ID line for the
# mismatch precheck, while HUB_TOKEN must still never reach any output.
LANES_NODE_FILE="$TMP/lanes-node.env"
LANES_NODE_TOKEN_VALUE="fixture-lanes-node-token-must-not-leak"
printf 'HUB_MACHINE_ID=mac-work-default\nHUB_TOKEN=%s\n' "$LANES_NODE_TOKEN_VALUE" >"$LANES_NODE_FILE"
chmod 600 "$LANES_NODE_FILE"
LANES_NODE_OTHER_FILE="$TMP/lanes-node-other.env"
LANES_NODE_OTHER_VALUE="fixture-lanes-node-other-must-not-leak"
printf 'HUB_MACHINE_ID=mac-work-other\nHUB_TOKEN=%s\n' "$LANES_NODE_OTHER_VALUE" >"$LANES_NODE_OTHER_FILE"
chmod 600 "$LANES_NODE_OTHER_FILE"
# Lanes-only [hub]: hub_url + lanes_token_env + session_machine_ids — no
# hub_token_env — must still register lanes yet never opt into the quota gate.
LANES_CFG_NODE="$TMP/lanes-node-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\nhub_cf_env = "%s"\nsession_machine_ids = { "default" = "mac-work-default" }\n' \
  "$LANES_NODE_FILE" "$LANES_CF_FILE" >"$LANES_CFG_NODE"
# Both credentials: the lanes routes take lanes_token_env while the quota
# gate keeps hub_token_env.
LANES_CFG_BOTH="$TMP/lanes-both-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nlanes_token_env = "%s"\nhub_cf_env = "%s"\nsession_machine_ids = { "default" = "mac-work-default" }\n' \
  "$LANES_TOKEN_FILE" "$LANES_NODE_FILE" "$LANES_CF_FILE" >"$LANES_CFG_BOTH"
# Same lanes-only shape, but the node token is bound to another machine.
LANES_CFG_MISMATCH="$TMP/lanes-mismatch-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\nsession_machine_ids = { "default" = "mac-work-default" }\n' \
  "$LANES_NODE_OTHER_FILE" >"$LANES_CFG_MISMATCH"
# B1: a one-line node file — spillover_env_key returns the whole post-= tail,
# so the "machine id" is 'mac-work-other HUB_TOKEN=<secret>'. Never a valid
# bare id; any warning that echoed it would print the token to stderr.
LANES_NODE_INLINE_FILE="$TMP/lanes-node-inline.env"
LANES_NODE_INLINE_VALUE="fixture-lanes-inline-token-must-not-leak"
printf 'HUB_MACHINE_ID=mac-work-other HUB_TOKEN=%s\n' "$LANES_NODE_INLINE_VALUE" >"$LANES_NODE_INLINE_FILE"
chmod 600 "$LANES_NODE_INLINE_FILE"
LANES_CFG_INLINE="$TMP/lanes-inline-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\nsession_machine_ids = { "default" = "mac-work-default" }\n' \
  "$LANES_NODE_INLINE_FILE" >"$LANES_CFG_INLINE"
# A prefix-shaped id: mac-work is a proper prefix of mac-work-default — only
# an exact compare may warn; a prefix match would silently register the lane.
LANES_NODE_PREFIX_FILE="$TMP/lanes-node-prefix.env"
LANES_NODE_PREFIX_VALUE="fixture-lanes-prefix-token-must-not-leak"
printf 'HUB_MACHINE_ID=mac-work\nHUB_TOKEN=%s\n' "$LANES_NODE_PREFIX_VALUE" >"$LANES_NODE_PREFIX_FILE"
chmod 600 "$LANES_NODE_PREFIX_FILE"
LANES_CFG_PREFIX="$TMP/lanes-prefix-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\nsession_machine_ids = { "default" = "mac-work-default" }\n' \
  "$LANES_NODE_PREFIX_FILE" >"$LANES_CFG_PREFIX"
# #1138: the same lanes-only shape plus quota_gate = "local" — the deliberate
# opt-out that takes the identical local-only path without the warning.
LANES_CFG_NODE_LOCAL="$TMP/lanes-node-local-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\nhub_cf_env = "%s"\nsession_machine_ids = { "default" = "mac-work-default" }\nquota_gate = "local"\n' \
  "$LANES_NODE_FILE" "$LANES_CF_FILE" >"$LANES_CFG_NODE_LOCAL"
# #1138: the skipped-gate warning's exact line, counted on a spawn's stderr.
HUB_GATE_WARN_TEXT='wrk: warning: [hub] hub_url is set but hub_token_env is not; hub quota gate skipped (local scopefuel gate only)'
# #1397: an operator-token [hub] (operator_token_env, no lanes/hub token) plus
# machine_id — the mbp shape the builder machine_id fallback exists for. The
# credential is mode 000 like the lanes token: it reaches panewire as a path,
# and a read attempt fails the suite instead of leaking.
LANES_OP_FILE="$TMP/lanes-1397-operator.env"
LANES_OP_VALUE="fixture-1397-operator-token-must-not-leak"
printf 'OPERATOR_TOKEN=%s\n' "$LANES_OP_VALUE" >"$LANES_OP_FILE"
chmod 000 "$LANES_OP_FILE"
LANES_CFG_OP="$TMP/lanes-1397-op-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\noperator_token_env = "%s"\nhub_cf_env = "%s"\nmachine_id = "mac-personal"\n' \
  "$LANES_OP_FILE" "$LANES_CF_FILE" >"$LANES_CFG_OP"
# Same operator config plus a session map: the mapped session must win over
# the machine_id fallback for the local spawn.
LANES_CFG_OP_MAP="$TMP/lanes-1397-opmap-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\noperator_token_env = "%s"\nhub_cf_env = "%s"\nmachine_id = "mac-personal"\nsession_machine_ids = { "default" = "mac-work-default" }\n' \
  "$LANES_OP_FILE" "$LANES_CF_FILE" >"$LANES_CFG_OP_MAP"
# Operator config with neither map nor machine_id: the builder has no machine.
LANES_CFG_OP_NOID="$TMP/lanes-1397-noid-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\noperator_token_env = "%s"\n' \
  "$LANES_OP_FILE" >"$LANES_CFG_OP_NOID"
# machine_id but no hub_url; hub_url but no lanes credential at all.
LANES_CFG_NOURL="$TMP/lanes-1397-nourl-hosts.toml"
printf '[hub]\noperator_token_env = "%s"\nmachine_id = "mac-personal"\n' \
  "$LANES_OP_FILE" >"$LANES_CFG_NOURL"
LANES_CFG_NOCRED="$TMP/lanes-1397-nocred-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nmachine_id = "mac-personal"\n' \
  >"$LANES_CFG_NOCRED"
# The --host desktop delegation: [hosts.desktop] feeds the remote spawn,
# [hub] feeds the initiator-side `lanes add` (machine = the hosts.toml key).
LANES_CFG_REMOTE="$TMP/lanes-1397-remote-hosts.toml"
printf '%s\n' '[hub]' 'hub_url = "https://hub.invalid"' \
  "operator_token_env = \"$LANES_OP_FILE\"" "hub_cf_env = \"$LANES_CF_FILE\"" \
  'machine_id = "mac-personal"' '' \
  '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' \
  'workspace = "workers"' "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" \
  'capacity = 3' >"$LANES_CFG_REMOTE"
# Same delegation config plus a session_machine_ids entry — used to prove a
# remote --host worker spawn makes ZERO lanes calls on the initiator even
# when the initiator's config is fully hub-enabled and session-mapped (the
# execution host's own lookup is the plain #965 worker path after the
# delegated `--host local`, covered by the 965 assertions).
LANES_CFG_REMOTE_WMAP="$TMP/lanes-1397-remote-wmap-hosts.toml"
printf '%s\n' '[hub]' 'hub_url = "https://hub.invalid"' \
  "operator_token_env = \"$LANES_OP_FILE\"" "hub_cf_env = \"$LANES_CF_FILE\"" \
  'machine_id = "mac-personal"' \
  'session_machine_ids = { "worker" = "target-9s" }' '' \
  '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' \
  'workspace = "workers"' "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" \
  'capacity = 3' >"$LANES_CFG_REMOTE_WMAP"
# The remote add writes a lane on another machine — when the initiator has
# BOTH a node-scoped lanes token and the operator credential, the remote
# path must reach for operator_token_env first.
LANES_CFG_REMOTE_BOTH="$TMP/lanes-1397-remote-both-hosts.toml"
printf '%s\n' '[hub]' 'hub_url = "https://hub.invalid"' \
  "lanes_token_env = \"$LANES_TOKEN_FILE\"" \
  "operator_token_env = \"$LANES_OP_FILE\"" "hub_cf_env = \"$LANES_CF_FILE\"" \
  'machine_id = "mac-personal"' '' \
  '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' \
  'workspace = "workers"' "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" \
  'capacity = 3' >"$LANES_CFG_REMOTE_BOTH"
# A two-candidate delegation config for --host auto: pressured local means
# the router walks desktop then mac-work in file order, so stop-set and
# transport-normalization behavior around rc 82 is observable in -ssh.log.
LANES_CFG_REMOTE_AUTO="$TMP/lanes-1397-remote-auto-hosts.toml"
printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
  '[hub]' 'hub_url = "https://hub.invalid"' \
  "operator_token_env = \"$LANES_OP_FILE\"" "hub_cf_env = \"$LANES_CF_FILE\"" \
  'machine_id = "mac-personal"' '' \
  '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' \
  'workspace = "workers"' "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" \
  'capacity = 3' '' \
  '[hosts.mac-work]' 'ssh = "mac-work"' 'herdr_session = "worker"' \
  'workspace = "workers"' "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" \
  'capacity = 2' >"$LANES_CFG_REMOTE_AUTO"
T1397_LOAD_HIGH="$TMP/t1397-loadavg-high"
printf '4.00 4.00 4.00 1/1 1\n' >"$T1397_LOAD_HIGH"
# A session map that maps SOME OTHER session plus machine_id — proves the
# machine_id fallback never leaks to workers (tester mu02). The credential is
# hub_token_env, one a worker DOES read: an operator-only config could never
# register the mutated worker and the mutant would survive unproven.
LANES_CFG_OTHERMAP="$TMP/lanes-1397-othermap-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nhub_cf_env = "%s"\nmachine_id = "mac-personal"\nsession_machine_ids = { "other-session" = "other-machine" }\n' \
  "$LANES_TOKEN_FILE" "$LANES_CF_FILE" >"$LANES_CFG_OTHERMAP"
# Mapped + hub_token_env + operator_token_env (B1-r4 pin): a WORKER lane keeps
# the pre-#1397 chain and must reach panewire with the hub_token file — never
# the operator file — while a BUILDER on the same config takes the operator.
LANES_CFG_WBOTH="$TMP/lanes-1397-wboth-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\noperator_token_env = "%s"\nhub_cf_env = "%s"\nsession_machine_ids = { "default" = "mac-work-default" }\n' \
  "$LANES_TOKEN_FILE" "$LANES_OP_FILE" "$LANES_CF_FILE" >"$LANES_CFG_WBOTH"

# hk 1446: a lanes token bound to the DEFERRED machine id — the hosts.toml
# key the initiator reaches the execution host by (desktop) — lets the
# delegated remote builder register its own lane. The config also carries
# operator_token_env so the argv pin proves the self-add took the node
# token and never the operator credential.
LANES_NODE_DESKTOP_FILE="$TMP/lanes-node-desktop.env"
LANES_NODE_DESKTOP_VALUE="fixture-lanes-desktop-token-must-not-leak"
printf 'HUB_MACHINE_ID=desktop\nHUB_TOKEN=%s\n' "$LANES_NODE_DESKTOP_VALUE" >"$LANES_NODE_DESKTOP_FILE"
chmod 600 "$LANES_NODE_DESKTOP_FILE"
LANES_CFG_DEFER_SELF="$TMP/lanes-1446-self-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\noperator_token_env = "%s"\nhub_cf_env = "%s"\nmachine_id = "desktop"\n' \
  "$LANES_NODE_DESKTOP_FILE" "$LANES_OP_FILE" "$LANES_CF_FILE" >"$LANES_CFG_DEFER_SELF"
# Same shape but the token names another machine: the deferred spawn must
# behave exactly as it does without a token.
LANES_CFG_DEFER_MISMATCH="$TMP/lanes-1446-mismatch-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\noperator_token_env = "%s"\nmachine_id = "desktop"\n' \
  "$LANES_NODE_OTHER_FILE" "$LANES_OP_FILE" >"$LANES_CFG_DEFER_MISMATCH"
# An OPERATOR credential that also carries HUB_MACHINE_ID: the remote side
# never resolves operator_token_env, so a deferred spawn on this config
# still makes zero lanes calls — while a mutant that falls back to the
# operator file would find a matching id and self-register.
LANES_OP_ID_FILE="$TMP/lanes-1446-opid.env"
printf 'OPERATOR_TOKEN=%s\nHUB_MACHINE_ID=desktop\n' "$LANES_OP_VALUE" >"$LANES_OP_ID_FILE"
chmod 600 "$LANES_OP_ID_FILE"
LANES_CFG_OPID="$TMP/lanes-1446-opid-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\noperator_token_env = "%s"\nhub_cf_env = "%s"\nmachine_id = "desktop"\n' \
  "$LANES_OP_ID_FILE" "$LANES_CF_FILE" >"$LANES_CFG_OPID"
# A lanes token whose machine id differs only by case/whitespace — the
# equality is byte-exact, so these defer too.
LANES_NODE_DESKTOP_CASE_FILE="$TMP/lanes-node-desktop-case.env"
printf 'HUB_MACHINE_ID=Desktop \nHUB_TOKEN=%s\n' "$LANES_NODE_DESKTOP_VALUE" >"$LANES_NODE_DESKTOP_CASE_FILE"
chmod 600 "$LANES_NODE_DESKTOP_CASE_FILE"
LANES_CFG_DEFER_CASE="$TMP/lanes-1446-case-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\noperator_token_env = "%s"\nmachine_id = "desktop"\n' \
  "$LANES_NODE_DESKTOP_CASE_FILE" "$LANES_OP_FILE" >"$LANES_CFG_DEFER_CASE"
# A whitespace-only mismatch must not be normalized into the deferred
# machine id. The line terminator is syntax; the trailing space is value.
LANES_NODE_DESKTOP_SPACE_FILE="$TMP/lanes-node-desktop-space.env"
printf 'HUB_MACHINE_ID=desktop \nHUB_TOKEN=%s\n' "$LANES_NODE_DESKTOP_VALUE" >"$LANES_NODE_DESKTOP_SPACE_FILE"
chmod 600 "$LANES_NODE_DESKTOP_SPACE_FILE"
LANES_CFG_DEFER_SPACE="$TMP/lanes-1446-space-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\noperator_token_env = "%s"\nmachine_id = "desktop"\n' \
  "$LANES_NODE_DESKTOP_SPACE_FILE" "$LANES_OP_FILE" >"$LANES_CFG_DEFER_SPACE"

lanes_spawn() {
  # NAME [spawn args...] — a forced-local spawn against the #965 hosts.toml.
  # stdout/stderr, both panewire logs and the inbox land in per-case paths;
  # the exit code lands in LANES_RC. LANES_CFG_OVERRIDE swaps the hosts.toml,
  # LANES_MODEL the profile.
  local name="$1"; shift
  LANES_OUT="$TMP/lanes-$name.out" LANES_ERR="$TMP/lanes-$name.err"
  LANES_CALLS="$TMP/lanes-$name-calls.log" LANES_HERDR_LOG="$TMP/lanes-$name-herdr.log"
  LANES_PANEWIRE_LOG="$TMP/lanes-$name-panewire.log"
  LANES_INBOX="$TMP/lanes-inbox-$name"
  set +e
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" PANEWIRE_BIN="$PANEWIRE" \
    ARBITER_BIN="${LANES_ARBITER_BIN:-$ARBITER}" ARBITER_INBOX_ROOT="$LANES_INBOX" \
    XDG_DATA_HOME="$TMP/lanes-xdg-$name" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$LANES_HERDR_LOG" \
    WRK_SCOPEFUEL_LOG="$TMP/lanes-scopefuel-$name.log" \
    WRK_REFRESH_LOG="$TMP/lanes-refresh-$name.log" \
    WRK_REFRESH_PID_LOG="$TMP/lanes-refresh-$name.pids" WRK_REFRESH_TIMEOUT_S=5 \
    WRK_HOSTS_CONFIG="${LANES_CFG_OVERRIDE:-$LANES_CFG}" \
    WRK_PANEWIRE_LOG="$LANES_PANEWIRE_LOG" \
    WRK_PANEWIRE_LANES_LOG="$LANES_CALLS" \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$ROOT" -m "${LANES_MODEL:-codex-luna}" \
    -p "$PROMPT" -w w -l "$name" --t T1 --job "$name" --task "$(mint_task)" \
    --host local "$@" >"$LANES_OUT" 2>"$LANES_ERR"
  LANES_RC=$?
  set -e
}

# Zero lanes traffic means no dedicated argv block AND no `lanes` subcommand
# reaching the shared panewire log (place/prompt calls are unrelated).
lanes_assert_no_lanes_call() {
  local name="$1"
  [[ ! -s "$TMP/lanes-$name-calls.log" ]] ||
    fail "#965 $name: expected zero lanes calls, got: $(cat "$TMP/lanes-$name-calls.log")"
  if [[ -f "$TMP/lanes-$name-panewire.log" ]] && grep -q '^lanes$' "$TMP/lanes-$name-panewire.log"; then
    fail "#965 $name: a lanes subcommand reached panewire"
  fi
}

t1397_remote_spawn() {
  # NAME [extra spawn args...] — a builder spawn delegated to desktop through
  # the ssh/scp fixtures. The delegated argv lands in -ssh.log, the
  # spawner-side lanes calls in -calls.log, the emitted output in -out.
  local name="$1"; shift
  T1397_OUT="$TMP/t1397-$name.out" T1397_ERR="$TMP/t1397-$name.err"
  T1397_CALLS="$TMP/t1397-$name-calls.log" T1397_SSH="$TMP/t1397-$name-ssh.log"
  # Seed the case's arbiter db: the router's duplicate-job preflight reads
  # job-get against it and an un-initialized store answers storage-error
  # rather than not-found, which reroutes an explicit --host spawn into the
  # local path (same seed t1090 does).
  env ARBITER_INBOX_ROOT="$TMP/t1397-inbox-$name" XDG_DATA_HOME="$TMP/t1397-xdg-$name" \
    "$ARBITER" claim --job "t1397-seed-$name" --agent-label "t1397-seed-$name" \
    --lane t1397-seed --t T1 >/dev/null
  set +e
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" PANEWIRE_BIN="$PANEWIRE" \
    ARBITER_BIN="${T1397_ARBITER_BIN:-$ARBITER}" ARBITER_INBOX_ROOT="$TMP/t1397-inbox-$name" \
    XDG_DATA_HOME="$TMP/t1397-xdg-$name" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/t1397-$name-herdr.log" \
    WRK_SCOPEFUEL_LOG="$TMP/t1397-$name-scopefuel.log" \
    WRK_SSH_BIN="${T1397_SSH_BIN:-$ROOT/tests/fixtures/spillover-ssh}" \
    WRK_SCP_BIN="$ROOT/tests/fixtures/spillover-scp" \
    WRK_SSH_LOG="$T1397_SSH" WRK_SCP_LOG="$TMP/t1397-$name-scp.log" \
    WRK_SSH_SCENARIO="${T1397_SSH_SCENARIO:-ok}" \
    WRK_SSH_SCENARIO_DESKTOP="${T1397_SSH_SCENARIO_DESKTOP:-}" \
    WRK_SSH_SCENARIO_MAC_WORK="${T1397_SSH_SCENARIO_MAC_WORK:-}" \
    WRK_SSH_CALL_COUNT_FILE="${T1397_SSH_CALL_COUNT_FILE:-}" \
    WRK_SSH_FAIL_CALLS="${T1397_SSH_FAIL_CALLS:-}" \
    WRK_SSH_FAIL_CODE="${T1397_SSH_FAIL_CODE:-}" \
    WRK_REMOTE_RC="${T1397_REMOTE_RC:-}" \
    WRK_PROC_LOADAVG="${T1397_LOAD_FILE:-}" \
    WRK_TEST_NCPU=4 WRK_TEST_THROTTLED=0 \
    WRK_HOSTS_CONFIG="${T1397_CFG_OVERRIDE:-$LANES_CFG_REMOTE}" \
    WRK_PANEWIRE_LANES_LOG="$T1397_CALLS" \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$ROOT" -m builder-sol \
    -p "$PROMPT" -w w -l "$name" --t T1 --job "$name" --task "$(mint_task)" \
    --role builder --lane "$name" --parent director-x \
    --host "${T1397_HOST:-desktop}" "$@" >"$T1397_OUT" 2>"$T1397_ERR"
  T1397_RC=$?
  set -e
}

t1397_remote_worker() {
  # NAME [extra spawn args...] — the worker half of a remote spawn: same
  # delegation to desktop, no --role/--lane/--parent. Used to prove a remote
  # worker keeps #965: no --lane-defer on the wire, no initiator-side add.
  local name="$1"; shift
  T1397_OUT="$TMP/t1397-$name.out" T1397_ERR="$TMP/t1397-$name.err"
  T1397_CALLS="$TMP/t1397-$name-calls.log" T1397_SSH="$TMP/t1397-$name-ssh.log"
  env ARBITER_INBOX_ROOT="$TMP/t1397-inbox-$name" XDG_DATA_HOME="$TMP/t1397-xdg-$name" \
    "$ARBITER" claim --job "t1397-seed-$name" --agent-label "t1397-seed-$name" \
    --lane t1397-seed --t T1 >/dev/null
  set +e
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" PANEWIRE_BIN="$PANEWIRE" \
    ARBITER_BIN="${T1397_ARBITER_BIN:-$ARBITER}" ARBITER_INBOX_ROOT="$TMP/t1397-inbox-$name" \
    XDG_DATA_HOME="$TMP/t1397-xdg-$name" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/t1397-$name-herdr.log" \
    WRK_SCOPEFUEL_LOG="$TMP/t1397-$name-scopefuel.log" \
    WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" \
    WRK_SCP_BIN="$ROOT/tests/fixtures/spillover-scp" \
    WRK_SSH_LOG="$T1397_SSH" WRK_SCP_LOG="$TMP/t1397-$name-scp.log" \
    WRK_SSH_SCENARIO="${T1397_SSH_SCENARIO:-ok}" \
    WRK_HOSTS_CONFIG="${T1397_CFG_OVERRIDE:-$LANES_CFG_REMOTE}" \
    WRK_PANEWIRE_LANES_LOG="$T1397_CALLS" \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$ROOT" -m codex-luna \
    -p "$PROMPT" -w w -l "$name" --t T1 --job "$name" --task "$(mint_task)" \
    --host "${T1397_HOST:-desktop}" "$@" >"$T1397_OUT" 2>"$T1397_ERR"
  T1397_RC=$?
  set -e
}

t1397_lanes_missing() {
  # NAME — `wrk lanes-missing` against the audit inbox; rc lands in T1397_LM_RC.
  local name="$1"; shift
  T1397_LM_OUT="$TMP/t1397-lm-$name.out" T1397_LM_ERR="$TMP/t1397-lm-$name.err"
  T1397_LM_LOG="$TMP/t1397-lm-$name-calls.log"
  set +e
  env HERDR_BIN="$HERDR" PANEWIRE_BIN="$PANEWIRE" \
    ARBITER_INBOX_ROOT="$T1397_LM_INBOX" \
    WRK_HOSTS_CONFIG="${T1397_LM_CFG:-$LANES_CFG_OP}" \
    WRK_PANEWIRE_LANES_LOG="$T1397_LM_LOG" \
    "${WRK_UNDER_TEST:-$WRK}" lanes-missing "$@" >"$T1397_LM_OUT" 2>"$T1397_LM_ERR"
  T1397_LM_RC=$?
  set -e
}

lanes_spawned_payload() {
  # NAME — print the single job.spawned receipt payload.
  python3 - "$TMP/lanes-inbox-$1/$1/events" <<'PY'
import glob, json, sys
paths = sorted(glob.glob(sys.argv[1] + "/*job.spawned.json"))
assert len(paths) == 1, "exactly one job.spawned receipt expected: %r" % paths
print(json.dumps(json.load(open(paths[0]))["payload"], sort_keys=True))
PY
}

lanes_reap_run() {
  # NAME [reap args...] — wrk reap against LANES_REAP_INBOX with the #965
  # hosts.toml; lanes rm argv lands in $TMP/lanes-rm-$name.log.
  local name="$1"; shift
  LANES_REAP_OUT="$TMP/lanes-reap-$name.out" LANES_REAP_ERR="$TMP/lanes-reap-$name.err"
  LANES_RM_LOG="$TMP/lanes-rm-$name.log"
  set +e
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" \
    WRK_FIXTURE_SCENARIO=reap WRK_FIXTURE_LOG="$LANES_REAP_HERDR_LOG" \
    WRK_HOSTS_CONFIG="${LANES_REAP_CFG_OVERRIDE:-$LANES_CFG}" \
    WRK_PANEWIRE_LANES_LOG="$LANES_RM_LOG" \
    "${WRK_UNDER_TEST:-$WRK}" reap "$@" >"$LANES_REAP_OUT" 2>"$LANES_REAP_ERR"
  LANES_REAP_RC=$?
  set -e
}

lanes_reap_job() {
  # JOB PANE TAB LANE HUB_LANE [LABEL [MACHINE [ROLE [LANE_ROLE]]]] — claim +
  # job.spawned (+hub_lane/hub_lane_machine/lane_role when HUB_LANE is
  # nonempty) + job.completed, all backdated past the default grace. LABEL
  # defaults to JOB (#994 needs lane != job != label so a remove-by-job-id
  # regression cannot pass silently). ROLE defaults to worker — the claim
  # records it, and the --include-builders filter reads it (#1397). The
  # credential chain reads the receipt's lane_role instead (#1438): LANE_ROLE
  # defaults to ROLE, as a real spawn registers a lane under its own role,
  # and "-" writes the legacy receipt that carries none.
  local job="$1" pane="$2" tab="$3" lane="$4" hub_lane="$5" label="${6:-$1}" machine="${7:-mac-work-default}" role="${8:-worker}"
  local lane_role="${9:-$role}"
  local spawned="{\"owner_lane\":\"$lane\",\"label\":\"$label\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}"
  if [[ -n "$hub_lane" ]]; then
    spawned="{\"owner_lane\":\"$lane\",\"label\":\"$label\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\",\"hub_lane\":\"$hub_lane\",\"hub_lane_machine\":\"$machine\""
    [[ "$lane_role" == - ]] || spawned+=",\"lane_role\":\"$lane_role\""
    spawned+="}"
  fi
  local claim_role=(--role "$role")
  [[ "$role" == builder ]] && claim_role+=(--parent-lane director-x)
  export ARBITER_TEST_NOW="$LANES_REAP_NOW"
  env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 "${claim_role[@]}" >/dev/null
  env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "$spawned" >/dev/null
  env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  unset ARBITER_TEST_NOW
}

lanes_reap_reused_job() {
  # JOB PANE TAB LANE HUB_LANE LABEL MACHINE LANE_ROLE... — a job id first
  # claimed as a builder, released, reclaimed by a worker spawn (#1438; the
  # reap_builder_reclaimed_job shape), whose job.spawned receipts then land in
  # order, one per LANE_ROLE argument ("-" writes a legacy receipt with no
  # lane_role), each naming HUB_LANE on MACHINE — then job.completed. The
  # cumulative claim role stays builder; only the receipts say what the
  # lane is.
  local job="$1" pane="$2" tab="$3" lane="$4" hub_lane="$5" label="$6" machine="$7"
  shift 7
  local lane_role receipt
  export ARBITER_TEST_NOW="$LANES_REAP_NOW"
  env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 \
    --role builder --parent-lane director-x >/dev/null
  env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" lease \
    --job "$job" --resource "$TMP/reap-$job" --kind path >/dev/null
  env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" release \
    --job "$job" --resource "$TMP/reap-$job" --kind path --force >/dev/null
  env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" claim --reclaim-released \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 >/dev/null
  for lane_role in "$@"; do
    receipt="{\"owner_lane\":\"$lane\",\"label\":\"$label\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\",\"hub_lane\":\"$hub_lane\",\"hub_lane_machine\":\"$machine\""
    [[ "$lane_role" == - ]] || receipt+=",\"lane_role\":\"$lane_role\""
    env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
      --payload-json "$receipt}" >/dev/null
  done
  env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  unset ARBITER_TEST_NOW
}

# Asserts one `lanes ls` + `lanes rm LANE` pair reached panewire, each
# carrying WANT as its only hub token path and never OTHER.
t1438_assert_rm_chain() {  # LOG WANT OTHER LANE
  python3 - "$@" <<'PY'
import sys
log, want, other, lane = sys.argv[1:5]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
envs = [got[i + 1] for i, x in enumerate(got) if x == "--hub-token-env"]
assert envs == [want, want], "ls+rm must each carry %r, got %r" % (want, got)
assert other not in got, "the other credential reached panewire argv: %r" % got
assert got.count("rm") == 1 and got[got.index("rm") + 1] == lane, \
    "exactly one rm of %r expected: %r" % (lane, got)
PY
}
# The lane_role the single spawn receipt of NAME carries, or "absent".
t1438_receipt_lane_role() {  # NAME
  lanes_spawned_payload "$1" | python3 -c '
import json, sys
print(json.loads(sys.stdin.read()).get("lane_role", "absent"))'
}
T1438_LS='{"lanes":[{"lane":"%s","machine":"%s","pane":"%s","parent":"work-kairos","sink":false}]}'
# shellcheck disable=SC2059 # the template is the fixture's own format string
t1438_ls() { printf "$T1438_LS" "$1" "$2" "$3"; }  # LANE MACHINE PANE

run_lanes_tests() {
  # AC1 — mapped session + --owner: exactly one `lanes add` carrying the
  # configured machine, the spawned pane, the owner lane as parent and every
  # configured credential path. The OK line gains lane=LABEL@MACHINE and the
  # job meta records both fields.
  HERDR_SESSION=default lanes_spawn lane-ac1 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#965 AC1: mapped worker spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" "$LANES_TOKEN_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, token_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
want = ["add", "lane-ac1", "--machine", "mac-work-default", "--pane", "w:p1",
        "--parent", "work-kairos", "--hub-url", "https://hub.invalid",
        "--hub-token-env", token_file, "--hub-cf-env", cf_file, "--"]
assert got == want, "lanes add argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#965 AC1: lanes add must run exactly once with machine/pane/parent/credentials"
  grep -q '^OK pane=w:p1 ' "$LANES_OUT" ||
    fail "#965 AC1: the OK line is missing: $(cat "$LANES_OUT")"
  grep -q ' lane=lane-ac1@mac-work-default$' "$LANES_OUT" ||
    fail "#965 AC1: the OK line must end with lane=lane-ac1@mac-work-default: $(cat "$LANES_OUT")"
  lanes_spawned_payload lane-ac1 | python3 -c '
import json, sys
payload = json.loads(sys.stdin.read())
assert payload.get("hub_lane") == "lane-ac1", payload
assert payload.get("hub_lane_machine") == "mac-work-default", payload' ||
    fail "#965 AC1: job.spawned meta must carry hub_lane/hub_lane_machine"
  echo "PASS 965-lanes AC1: mapped worker spawn registers the lane"

  # Session resolution: WRK_SENTINEL_HERDR_SESSION wins over HERDR_SESSION;
  # with neither set the herdr default session is what gets mapped.
  WRK_SENTINEL_HERDR_SESSION=default HERDR_SESSION=worker \
    lanes_spawn lane-prec --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] || fail "#965: sentinel-session override spawn failed"
  python3 - "$LANES_CALLS" <<'PY' ||
import sys
got = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert got[:2] == ["add", "lane-prec"], "sentinel session must win: %r" % got
assert got[2:4] == ["--machine", "mac-work-default"], got
PY
    fail "#965: WRK_SENTINEL_HERDR_SESSION must win over HERDR_SESSION"
  HERDR_SESSION='' WRK_SENTINEL_HERDR_SESSION='' lanes_spawn lane-def --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] || fail "#965: default-session spawn failed"
  python3 - "$LANES_CALLS" <<'PY' ||
import sys
got = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert got[:4] == ["add", "lane-def", "--machine", "mac-work-default"], \
    "an unset session must resolve to the herdr default: %r" % got
PY
    fail "#965: an unset herdr session must resolve to the default session"
  echo "PASS 965-lanes session precedence (sentinel override, default fallback)"

  # AC2 — mapped config but an unmapped session: zero lanes calls, exactly one
  # warning naming the session, and the OK line carries nothing appended.
  HERDR_SESSION=worker lanes_spawn lane-ac2 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#965 AC2: an unmapped-session spawn still succeeds (rc=$LANES_RC)"
  lanes_assert_no_lanes_call lane-ac2
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#965 AC2: exactly one warning expected: $(cat "$LANES_ERR")"
  grep -q "herdr session 'worker'" "$LANES_ERR" ||
    fail "#965 AC2: the warning must name the session: $(cat "$LANES_ERR")"
  grep -qxF 'OK pane=w:p1 host=local model=codex-luna label=lane-ac2 status=working landed=yes job=lane-ac2 quota_record=codex/quota_pool' "$LANES_OUT" ||
    fail "#965 AC2: the OK line changed beyond 'nothing appended': $(cat "$LANES_OUT")"
  # And a config without the key at all stays silent (opt-in absent).
  LANES_CFG_OVERRIDE="$LANES_CFG_NOMAP" HERDR_SESSION=default lanes_spawn lane-ac2b --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] || fail "#965 AC2: unconfigured-map spawn failed"
  lanes_assert_no_lanes_call lane-ac2b
  ! grep -q 'hub lane' "$LANES_ERR" ||
    fail "#965 AC2: no session_machine_ids key must stay silent: $(cat "$LANES_ERR")"
  echo "PASS 965-lanes AC2: unmapped session warns once and spawns clean"

  # AC3 — a builder spawn registers its own lane (#1397: builder lanes are no
  # longer the director's manual job — job.joined and job.escalate route to
  # the owner lane's parent, so the builder lane must exist). lane = --lane,
  # parent = --parent, machine/pane as the worker path.
  LANES_MODEL=builder-sol HERDR_SESSION=default \
    lanes_spawn lane-ac3 --role builder --lane b965-builder --parent director-x
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#965 AC3: builder spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" "$LANES_TOKEN_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, token_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
want = ["add", "b965-builder", "--machine", "mac-work-default", "--pane", "w:p1",
        "--parent", "director-x", "--hub-url", "https://hub.invalid",
        "--hub-token-env", token_file, "--hub-cf-env", cf_file, "--"]
assert got == want, "builder lanes argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#965 AC3: a builder registers --lane under --parent on the mapped machine"
  grep -q ' lane=b965-builder@mac-work-default$' "$LANES_OUT" ||
    fail "#965 AC3: the builder OK line must end with the registered lane: $(cat "$LANES_OUT")"
  lanes_spawned_payload lane-ac3 | python3 -c '
import json, sys
meta = json.loads(sys.stdin.read())
assert meta["hub_lane"] == "b965-builder" and meta["hub_lane_machine"] == "mac-work-default", meta' ||
    fail "#965 AC3: the receipt must carry the builder hub lane fields"
  # The job's owner lane is the builder lane — the route joined/escalate take.
  env XDG_DATA_HOME="$TMP/lanes-xdg-lane-ac3" "$ARBITER" job-get --job lane-ac3 --json \
    >"$TMP/lanes-ac3-jobs.json"
  python3 - "$TMP/lanes-ac3-jobs.json" <<'PY' ||
import json, sys
job = json.load(open(sys.argv[1]))
assert job["owner_lane"] == "b965-builder", job
PY
    fail "#965 AC3: the builder job must be claimed under --lane"
  echo "PASS 965-lanes AC3: a builder registers --lane under --parent"

  # AC4 — mapped session, missing --owner: zero calls, one warning, rc
  # unchanged (the spawn is still a success — a missing lane is pre-#965
  # behaviour, not a new failure).
  HERDR_SESSION=default lanes_spawn lane-ac4
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#965 AC4: a missing --owner must not fail the spawn (rc=$LANES_RC)"
  lanes_assert_no_lanes_call lane-ac4
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#965 AC4: exactly one warning expected: $(cat "$LANES_ERR")"
  grep -q -- '--owner' "$LANES_ERR" ||
    fail "#965 AC4: the warning must point at --owner: $(cat "$LANES_ERR")"
  grep -q '^OK pane=w:p1 ' "$LANES_OUT" || fail "#965 AC4: OK line missing"
  ! grep -q ' lane=' "$LANES_OUT" || fail "#965 AC4: nothing may be appended"
  echo "PASS 965-lanes AC4: missing --owner warns once and spawns unregistered"

  # AC5 — panewire refuses the lane (rc 5): the spawn still exits 0 with its
  # OK line, one warning carries 'hub lane not registered', and the receipt
  # stays free of hub_lane.
  WRK_PANEWIRE_LANES_RC=5 HERDR_SESSION=default lanes_spawn lane-ac5 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#965 AC5: a lanes refusal must not fail the spawn (rc=$LANES_RC)"
  [[ "$(grep -c '^add$' "$LANES_CALLS")" -eq 1 ]] ||
    fail "#965 AC5: the registration call must still be attempted once"
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#965 AC5: one 'hub lane not registered' warning expected: $(cat "$LANES_ERR")"
  grep -q '^OK pane=w:p1 ' "$LANES_OUT" || fail "#965 AC5: OK line missing"
  ! grep -q ' lane=' "$LANES_OUT" || fail "#965 AC5: a refused lane must not be printed"
  ! lanes_spawned_payload lane-ac5 | grep -q 'hub_lane' ||
    fail "#965 AC5: a refused lane must not land in job meta"
  echo "PASS 965-lanes AC5: lanes add rc!=0 warns and keeps the spawn"

  # AC7 — the credential files go to panewire as verbatim paths and are never
  # opened by wrk (they are chmod 000 here — a read would have died). The
  # secret values must appear in no output this feature produced.
  for output in "$TMP"/lanes-*.out "$TMP"/lanes-*.err; do
    if grep -Fq "$LANES_TOKEN_VALUE" "$output"; then
      fail "#965 AC7: the token env contents leaked into ${output##*/}"
    fi
    if grep -Fq "$LANES_CF_VALUE" "$output"; then
      fail "#965 AC7: the CF env contents leaked into ${output##*/}"
    fi
  done
  echo "PASS 965-lanes AC7: credential paths passed verbatim, contents unread"

  # AC6 — reap --apply removes exactly the recorded lane, only after the tab
  # close is confirmed; a dry run and a lane-less job call nothing.
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox"
  LANES_REAP_HERDR_LOG="$TMP/lanes-reap-herdr.log"
  LANES_REAP_NOW="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).replace(microsecond=0).isoformat())')"
  lanes_reap_job lanes-reap-ok w1:p5 w1:t5 lane-965 lanes-reap-ok
  lanes_reap_job lanes-reap-plain w1:p6 w1:t6 lane-965 ''
  lanes_reap_job lanes-reap-fail w1:p7 w1:t7 lane-965-f lanes-reap-fail
  # The M3 mutant below reaps its own lane: the AC6 apply above already closed
  # lane-965's jobs, and a reaped job is never a candidate again.
  lanes_reap_job lanes-m3-ok w1:p8 w1:t8 lane-965-m3 lanes-m3-ok
  lanes_reap_job lanes-m3-plain w1:p10 w1:t10 lane-965-m3 ''

  lanes_reap_run dry --lane lane-965
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#965 AC6: dry run failed"
  [[ ! -e "$LANES_RM_LOG" ]] || fail "#965 AC6: a dry run must not call lanes rm"
  ! grep -q '^tab close ' "$LANES_REAP_HERDR_LOG" ||
    fail "#965 AC6: a dry run must not close a tab"
  grep -q '^would-close job=lanes-reap-ok ' "$LANES_REAP_OUT" ||
    fail "#965 AC6: the lane job must still be a dry-run candidate"
  echo "PASS 965-lanes AC6a: dry run registers no removal"

  # #994: rm now fires only after `lanes ls` confirms the row still belongs
  # to the recorded machine+pane — the apply case answers it with the
  # recorded route.
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lanes-reap-ok","machine":"mac-work-default","pane":"w1:p5","parent":"lane-965","sink":false}]}' \
    lanes_reap_run apply --lane lane-965 --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#965 AC6: apply failed: $(cat "$LANES_REAP_ERR")"
  python3 - "$LANES_RM_LOG" "$LANES_TOKEN_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, token_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
creds = ["--hub-url", "https://hub.invalid",
         "--hub-token-env", token_file, "--hub-cf-env", cf_file]
want = (["ls"] + creds + ["--"]
        + ["rm", "lanes-reap-ok"] + creds + ["--"])
assert got == want, "lanes ls+rm argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#965 AC6: reap must confirm the row with lanes ls, then rm exactly once, with the recorded lane and identical credentials"
  grep -q '^closed job=lanes-reap-ok ' "$LANES_REAP_OUT" ||
    fail "#965 AC6: the lane job must close: $(cat "$LANES_REAP_OUT")"
  grep -q '^closed job=lanes-reap-plain ' "$LANES_REAP_OUT" ||
    fail "#965 AC6: the lane-less job must still close: $(cat "$LANES_REAP_OUT")"
  echo "PASS 965-lanes AC6b: apply removes only the recorded lane"

  # A removal failure warns; the confirmed close still stands. `lanes ls`
  # confirms the row first, so LANES_RC still reaches the rm call (#994).
  WRK_PANEWIRE_LANES_RC=5 \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lanes-reap-fail","machine":"mac-work-default","pane":"w1:p7","parent":"lane-965-f","sink":false}]}' \
    lanes_reap_run rmfail --lane lane-965-f --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#965: reap apply must survive an rm failure"
  grep -q "wrk: warning: hub lane 'lanes-reap-fail' not removed" "$LANES_REAP_ERR" ||
    fail "#965: an rm failure must warn: $(cat "$LANES_REAP_ERR")"
  grep -q '^closed job=lanes-reap-fail ' "$LANES_REAP_OUT" ||
    fail "#965: the pane must stay closed after an rm failure: $(cat "$LANES_REAP_OUT")"
  echo "PASS 965-lanes: lanes rm failure warns and the close stands"

  # -- assertion-RED mutants -------------------------------------------------
  # Each mutant kills one invariant; each run must produce the bad outcome the
  # matching assertion above rejects, proving the assertion is live.
  # M1: "a mapped session registers exactly one lane" — skip registration.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-skip \
    '  [[ "$ROLE" == worker || "$ROLE" == builder ]] || return 0' \
    '  return 0'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-skip" HERDR_SESSION=default \
    lanes_spawn lane-ac1m --owner work-kairos
  if [[ -s "$LANES_CALLS" ]]; then
    fail "#965 M1 mutant survived: the lane was still registered"
  fi
  ! grep -q ' lane=' "$LANES_OUT" ||
    fail "#965 M1 mutant survived: lane= still reached the OK line"
  echo "PASS 965-lanes M1: skipping registration goes RED"

  # M2: "registration failure never fails the spawn" — exit on lanes add rc!=0.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-fatal \
    '    warn "hub lane not registered (panewire lanes add exited $rc)"' \
    '    warn "hub lane not registered (panewire lanes add exited $rc)"; exit "$rc"'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-fatal" WRK_PANEWIRE_LANES_RC=5 \
    HERDR_SESSION=default lanes_spawn lane-ac5m --owner work-kairos
  [[ "$LANES_RC" -ne 0 ]] ||
    fail "#965 M2 mutant survived: the spawn still exited 0 after a refused lane"
  echo "PASS 965-lanes M2: failing the spawn on a lane refusal goes RED"

  # M3: "reap removes only the lane it registered" — rm for every closed job.
  # The mutant removes by job id and carries no expected machine/pane, so the
  # #994 `lanes ls` check must see rows that match empty wants (sink-shaped
  # rows) for the sweep to be observable at all.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-rmall \
    '        [[ -z "$hub_lane" ]] || hub_lane_remove "$hub_lane" "$hub_lane_machine" "$pane" "${lane_role:-worker}"' \
    '        hub_lane_remove "$job"'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-rmall" \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lanes-m3-ok","machine":"","pane":"","parent":"","sink":true},{"lane":"lanes-m3-plain","machine":"","pane":"","parent":"","sink":true}]}' \
    lanes_reap_run rmall --lane lane-965-m3 --apply
  if ! grep -q 'lanes-m3-plain' "$LANES_RM_LOG" 2>/dev/null; then
    fail "#965 M3 mutant survived: the lane-less job was not swept"
  fi
  echo "PASS 965-lanes M3: removing every job lane goes RED"

  # ------------------------------------------------------------------
  # #994 — no unreapable rows, safe removal, clearer docs
  # ------------------------------------------------------------------
  # AC1 — the arbiter is absent (no job record, ARBITER_JOB_REGISTERED=0) on
  # a mapped session with --owner: zero lanes calls, one warning naming the
  # missing job record, spawn still rc 0. A lane registered here could never
  # be reaped, so registration must not happen.
  LANES_ARBITER_BIN="$TMP/absent-arbiter" HERDR_SESSION=default \
    lanes_spawn lane-994-ac1 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#994 AC1: arbiter-less spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call lane-994-ac1
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#994 AC1: exactly one lane warning expected: $(cat "$LANES_ERR")"
  grep -q 'arbiter job record' "$LANES_ERR" ||
    fail "#994 AC1: the warning must name the missing job record: $(cat "$LANES_ERR")"
  ! grep -q ' lane=' "$LANES_OUT" ||
    fail "#994 AC1: an unregistered lane must not reach the OK line"
  echo "PASS 994-lanes AC1: no job record, no lane"

  # AC2 — the job.spawned receipt write fails after the lane was registered:
  # one compensating `lanes rm` for that lane with the same credentials (a
  # `lanes ls` confirmation precedes it), one warning narrates the
  # deregistration, the spawn still exits 0.
  LANES_ARB_FAIL="$TMP/arbiter-fail-spawned"
# shellcheck disable=SC2016 # the printf template is wrapper source, not an expansion site
  printf '#!/usr/bin/env bash\nif [[ "$1" == event && " $* " == *" job.spawned "* ]]; then exit 3; fi\nexec "%s" "$@"\n' \
    "$ARBITER" >"$LANES_ARB_FAIL"
  chmod +x "$LANES_ARB_FAIL"
  LANES_ARBITER_BIN="$LANES_ARB_FAIL" HERDR_SESSION=default \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-994-ac2","machine":"mac-work-default","pane":"w:p1","parent":"work-kairos","sink":false}]}' \
    lanes_spawn lane-994-ac2 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#994 AC2: a failed receipt must not fail the spawn (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" "$LANES_TOKEN_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, token_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
creds = ["--hub-url", "https://hub.invalid",
         "--hub-token-env", token_file, "--hub-cf-env", cf_file]
want = (["add", "lane-994-ac2", "--machine", "mac-work-default", "--pane", "w:p1",
         "--parent", "work-kairos"] + creds + ["--"]
        + ["ls"] + creds + ["--"]
        + ["rm", "lane-994-ac2"] + creds + ["--"])
assert got == want, "compensation argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#994 AC2: exactly one lanes rm for the registered lane, with the same credentials"
  [[ "$(grep -c 'job.spawned receipt failed' "$LANES_ERR")" -eq 1 ]] ||
    fail "#994 AC2: the receipt failure must warn once: $(cat "$LANES_ERR")"
  [[ "$(grep -c 'deregistering it' "$LANES_ERR")" -eq 1 ]] ||
    fail "#994 AC2: one deregistration warning expected: $(cat "$LANES_ERR")"
  ! grep -q ' lane=' "$LANES_OUT" ||
    fail "#994 AC2: an unrecorded lane must not reach the OK line"
  echo "PASS 994-lanes AC2: a lost spawn receipt deregisters the lane"

  # AC3 — lane != job id != label (#965's fixture reused the job id as the
  # lane, which let a remove-by-job-id regression pass): `lanes rm` must
  # carry the recorded lane value and nothing else.
  lanes_reap_job j994-distinct w1:p11 w1:t11 own-994-d lane-994-distinct lbl-994-d
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-994-distinct","machine":"mac-work-default","pane":"w1:p11","parent":"x","sink":false}]}' \
    lanes_reap_run ac3 --lane own-994-d --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#994 AC3: apply failed: $(cat "$LANES_REAP_ERR")"
  python3 - "$LANES_RM_LOG" "$LANES_TOKEN_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, token_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
creds = ["--hub-url", "https://hub.invalid",
         "--hub-token-env", token_file, "--hub-cf-env", cf_file]
want = (["ls"] + creds + ["--"]
        + ["rm", "lane-994-distinct"] + creds + ["--"])
assert got == want, "reap argv mismatch: got=%r want=%r" % (got, want)
for stray in ("j994-distinct", "lbl-994-d", "own-994-d"):
    assert stray not in got, "job/label/owner must never be an rm operand: %r" % stray
PY
    fail "#994 AC3: lanes rm must carry the recorded lane only"
  grep -q '^closed job=j994-distinct ' "$LANES_REAP_OUT" ||
    fail "#994 AC3: the job must close: $(cat "$LANES_REAP_OUT")"
  echo "PASS 994-lanes AC3: rm carries the recorded lane, never job/label"

  # AC4 — a flag-shaped (or otherwise invalid) lane value in the receipt
  # never reaches panewire argv: the name check fires before any lanes call,
  # one warning is logged and the pane still closes.
  lanes_reap_job j994-flag w1:p12 w1:t12 own-994-f --hub-url=x lbl-994-f
  lanes_reap_run ac4 --lane own-994-f --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#994 AC4: apply failed: $(cat "$LANES_REAP_ERR")"
  grep -q '^closed job=j994-flag ' "$LANES_REAP_OUT" ||
    fail "#994 AC4: the pane must still close: $(cat "$LANES_REAP_OUT")"
  if [[ -f "$LANES_RM_LOG" ]]; then
    ! grep -qxF -- '--hub-url=x' "$LANES_RM_LOG" ||
      fail "#994 AC4: the flag-shaped lane reached panewire argv: $(cat "$LANES_RM_LOG")"
    ! grep -qxF 'rm' "$LANES_RM_LOG" ||
      fail "#994 AC4: no lanes rm may run for an invalid lane: $(cat "$LANES_RM_LOG")"
  fi
  [[ "$(grep -c "hub lane '--hub-url=x' not removed" "$LANES_REAP_ERR")" -eq 1 ]] ||
    fail "#994 AC4: one invalid-name warning expected: $(cat "$LANES_REAP_ERR")"
  echo "PASS 994-lanes AC4: an invalid lane name never reaches panewire"

  # AC5 — `lanes ls` decides removal: a row moved to another pane is never
  # removed (a reused label must not lose the newer job's live row), a
  # matching machine+pane row is removed exactly once, and a failed listing
  # removes nothing (never remove blind).
  lanes_reap_job j994-moved w1:p13 w1:t13 own-994-m lane-994-moved lbl-994-m
  lanes_reap_job j994-match w1:p14 w1:t14 own-994-t lane-994-match lbl-994-t
  lanes_reap_job j994-lsfail w1:p15 w1:t15 own-994-l lane-994-lsfail lbl-994-l
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-994-moved","machine":"mac-work-default","pane":"w1:p99","parent":"x","sink":false}]}' \
    lanes_reap_run ac5a --lane own-994-m --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#994 AC5: apply failed: $(cat "$LANES_REAP_ERR")"
  grep -q '^closed job=j994-moved ' "$LANES_REAP_OUT" ||
    fail "#994 AC5: the pane must still close: $(cat "$LANES_REAP_OUT")"
  if [[ -f "$LANES_RM_LOG" ]]; then
    ! grep -qxF 'rm' "$LANES_RM_LOG" ||
      fail "#994 AC5: a moved row must not be removed: $(cat "$LANES_RM_LOG")"
  fi
  [[ "$(grep -c "lane now belongs to" "$LANES_REAP_ERR")" -eq 1 ]] ||
    fail "#994 AC5: one belongs-to-another-pane warning expected: $(cat "$LANES_REAP_ERR")"
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-994-match","machine":"mac-work-default","pane":"w1:p14","parent":"x","sink":false}]}' \
    lanes_reap_run ac5b --lane own-994-t --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#994 AC5: apply failed: $(cat "$LANES_REAP_ERR")"
  [[ "$(grep -cxF 'rm' "$LANES_RM_LOG")" -eq 1 &&
     "$(awk 'f{print; exit} /^rm$/{f=1}' "$LANES_RM_LOG")" == "lane-994-match" ]] ||
    fail "#994 AC5: exactly one lanes rm for the matching lane: $(cat "$LANES_RM_LOG")"
  WRK_PANEWIRE_LANES_LS_RC=7 lanes_reap_run ac5c --lane own-994-l --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#994 AC5: an ls failure must not fail the reap"
  grep -q '^closed job=j994-lsfail ' "$LANES_REAP_OUT" ||
    fail "#994 AC5: the pane must still close after an ls failure"
  if [[ -f "$LANES_RM_LOG" ]]; then
    ! grep -qxF 'rm' "$LANES_RM_LOG" ||
      fail "#994 AC5: a failed listing must never remove: $(cat "$LANES_RM_LOG")"
  fi
  [[ "$(grep -c "lanes ls exited 7" "$LANES_REAP_ERR")" -eq 1 ]] ||
    fail "#994 AC5: one ls-failure warning expected: $(cat "$LANES_REAP_ERR")"
  echo "PASS 994-lanes AC5: ls-confirmed removal only (moved/match/ls-fail)"

  # AC6 — a session_machine_ids value the one-line matcher cannot read warns
  # that the map could not be parsed; a parsed map without the session keeps
  # the old "no entry" wording (#965 AC2 above still asserts it).
  printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\n%s\n' \
    "$LANES_TOKEN_FILE" "session_machine_ids = { 'default' = 'mac-work-default' }" \
    >"$TMP/lanes-bad-squot.toml"
  printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nsession_machine_ids = {\n  "default" = "mac-work-default"\n}\n' \
    "$LANES_TOKEN_FILE" >"$TMP/lanes-bad-multiline.toml"
  LANES_CFG_OVERRIDE="$TMP/lanes-bad-squot.toml" HERDR_SESSION=default \
    lanes_spawn lane-994-squot --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] || fail "#994 AC6: spawn failed on a bad map (rc=$LANES_RC)"
  lanes_assert_no_lanes_call lane-994-squot
  grep -q 'session_machine_ids value could not be parsed' "$LANES_ERR" ||
    fail "#994 AC6: single-quoted keys must warn could-not-be-parsed: $(cat "$LANES_ERR")"
  ! grep -q 'has no session_machine_ids entry' "$LANES_ERR" ||
    fail "#994 AC6: a bad map must not read as a missing entry: $(cat "$LANES_ERR")"
  LANES_CFG_OVERRIDE="$TMP/lanes-bad-multiline.toml" HERDR_SESSION=default \
    lanes_spawn lane-994-multi --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] || fail "#994 AC6: spawn failed on a multi-line map (rc=$LANES_RC)"
  grep -q 'session_machine_ids value could not be parsed' "$LANES_ERR" ||
    fail "#994 AC6: a multi-line table must warn could-not-be-parsed: $(cat "$LANES_ERR")"
  echo "PASS 994-lanes AC6: unparseable map warns could-not-be-parsed"

  # AC7 — the non-fleet-only sentence is in --help and the README (grep). The
  # help text is captured before grepping: a piped `grep -q` can exit on the
  # match while the writer still has output buffered, which pipefail reads as
  # a SIGPIPE failure.
  ac7_help_out="$("$WRK" spawn --help)"
  grep -qi 'session_machine_ids is for non-fleet herdr sessions' <<<"$ac7_help_out" ||
    fail "#994 AC7: spawn --help must carry the non-fleet sentence"
  grep -qi 'non-fleet' "$ROOT/README.md" ||
    fail "#994 AC7: README must carry the non-fleet sentence"
  echo "PASS 994-lanes AC7: docs say non-fleet sessions only"

  # -- #994 assertion-RED mutants -------------------------------------------
  # M1: "no lane without a receipt" — drop the arbiter gate; AC1's zero-call
  # assertion must then fail.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-994-nogate \
    '  if [[ "${ARBITER_JOB_REGISTERED:-0}" -ne 1 ]]; then' \
    '  if false; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-994-nogate" \
    LANES_ARBITER_BIN="$TMP/absent-arbiter" HERDR_SESSION=default \
    lanes_spawn lane-994-m1 --owner work-kairos
  if [[ ! -s "$LANES_CALLS" ]]; then
    fail "#994 M1 mutant survived: no lanes add ran without a job record"
  fi
  echo "PASS 994-lanes M1: dropping the arbiter gate goes RED"

  # M2: "reap never removes another pane's lane" — skip the machine/pane
  # compare; AC5's no-rm assertion must then fail.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-994-blindrm \
    '        if machine == want_machine and pane == want_pane:' \
    '        if True:'
  lanes_reap_job j994-m2 w1:p16 w1:t16 own-994-m2 lane-994-m2 lbl-994-m2
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-994-blindrm" \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-994-m2","machine":"mac-work-default","pane":"w1:p88","parent":"x","sink":false}]}' \
    lanes_reap_run m2 --lane own-994-m2 --apply
  if [[ ! -f "$LANES_RM_LOG" ]] || ! grep -qxF 'rm' "$LANES_RM_LOG"; then
    fail "#994 M2 mutant survived: the moved lane was not swept"
  fi
  echo "PASS 994-lanes M2: skipping the lanes ls compare goes RED"

  # M3: "only valid lane names reach panewire" — drop the name check in
  # hub_lane_remove; AC4's no-argv assertion must then fail.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-994-novalidate \
    '  if ! hub_lane_name_valid "$lane"; then
    warn "hub lane '\''$lane'\'' not removed (not a valid panewire lane name)"
    return 0
  fi' \
    '  if false; then
    warn "hub lane '\''$lane'\'' not removed (not a valid panewire lane name)"
    return 0
  fi'
  lanes_reap_job j994-m3 w1:p17 w1:t17 own-994-m3 --hub-url=x lbl-994-m3
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-994-novalidate" \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"--hub-url=x","machine":"mac-work-default","pane":"w1:p17","parent":"x","sink":false}]}' \
    lanes_reap_run m3 --lane own-994-m3 --apply
  if [[ ! -f "$LANES_RM_LOG" ]] || ! grep -qxF -- '--hub-url=x' "$LANES_RM_LOG"; then
    fail "#994 M3 mutant survived: the flag-shaped lane never reached argv"
  fi
  echo "PASS 994-lanes M3: dropping lane-name validation goes RED"

  # ------------------------------------------------------------------
  # #1010 — lane test gaps from the #994 tester
  # ------------------------------------------------------------------
  # S1 — same pane, another machine: AC5 above moves only the pane, so the
  # machine half of the `lanes ls` compare could be deleted with the suite
  # green (#994 tester mutant MD). A row bound to another machine on the
  # recorded pane is never removed, and the close still stands.
  lanes_reap_job j1010-s1 w1:p10 w1:t10 own-1010-s1 lane-1010-s1 lbl-1010-s1
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1010-s1","machine":"mac-work-other","pane":"w1:p10","parent":"x","sink":false}]}' \
    lanes_reap_run s1 --lane own-1010-s1 --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1010 S1: apply failed: $(cat "$LANES_REAP_ERR")"
  grep -q '^closed job=j1010-s1 ' "$LANES_REAP_OUT" ||
    fail "#1010 S1: the pane must still close: $(cat "$LANES_REAP_OUT")"
  if [[ -f "$LANES_RM_LOG" ]]; then
    ! grep -qxF 'rm' "$LANES_RM_LOG" ||
      fail "#1010 S1: a row bound to another machine on the same pane was removed: $(cat "$LANES_RM_LOG")"
  fi
  [[ "$(grep -c "lane now belongs to" "$LANES_REAP_ERR")" -eq 1 ]] ||
    fail "#1010 S1: one belongs-to-another-machine warning expected: $(cat "$LANES_REAP_ERR")"
  echo "PASS 1010-lanes S1: a same-pane row on another machine is never removed"

  # N2 — the lookup row used to come back as a TSV read with IFS=tab, where
  # tab is IFS whitespace: an empty field collapses (machine "m-a<TAB>w1:p11"
  # with an empty pane read back as machine m-a, pane w1:p11 — a false match)
  # and an embedded newline truncates the row the same way. The compare now
  # runs inside python on the parsed fields, so neither shape can match. Both
  # rows are stub-only: real panewire refuses them at lanes add.
  lanes_reap_job j1010-emptyf w1:p11 w1:t11 own-1010-e lane-1010-empty lbl-1010-e m-a
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1010-empty","machine":"m-a\tw1:p11","pane":"","parent":"x","sink":false}]}' \
    lanes_reap_run n2a --lane own-1010-e --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1010 N2: apply failed: $(cat "$LANES_REAP_ERR")"
  grep -q '^closed job=j1010-emptyf ' "$LANES_REAP_OUT" ||
    fail "#1010 N2: the pane must still close: $(cat "$LANES_REAP_OUT")"
  if [[ -f "$LANES_RM_LOG" ]]; then
    ! grep -qxF 'rm' "$LANES_RM_LOG" ||
      fail "#1010 N2: an empty-field row must never match (the IFS collapse is gone): $(cat "$LANES_RM_LOG")"
  fi
  [[ "$(grep -c "lane now belongs to" "$LANES_REAP_ERR")" -eq 1 ]] ||
    fail "#1010 N2: one belongs-to warning expected for the empty-field row: $(cat "$LANES_REAP_ERR")"
  lanes_reap_job j1010-nlpane w1:p12 w1:t12 own-1010-n lane-1010-nl lbl-1010-n m-b
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1010-nl","machine":"m-b","pane":"w1:p12\nzz","parent":"x","sink":false}]}' \
    lanes_reap_run n2b --lane own-1010-n --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1010 N2: apply failed: $(cat "$LANES_REAP_ERR")"
  grep -q '^closed job=j1010-nlpane ' "$LANES_REAP_OUT" ||
    fail "#1010 N2: the pane must still close: $(cat "$LANES_REAP_OUT")"
  if [[ -f "$LANES_RM_LOG" ]]; then
    ! grep -qxF 'rm' "$LANES_RM_LOG" ||
      fail "#1010 N2: a newline-carrying pane must never match (the read truncated at the newline): $(cat "$LANES_RM_LOG")"
  fi
  [[ "$(grep -c "lane now belongs to" "$LANES_REAP_ERR")" -eq 1 ]] ||
    fail "#1010 N2: one belongs-to warning expected for the newline row: $(cat "$LANES_REAP_ERR")"
  echo "PASS 1010-lanes N2: malformed lookup rows never match"

  # N1 — the fixture's default `lanes ls` output must be valid JSON (the
  # escaped braces once printed "\{"lanes":[]\}", which nothing could parse).
  ( unset WRK_PANEWIRE_LANES_LS WRK_PANEWIRE_LANES_LS_RC WRK_PANEWIRE_LANES_LOG
    "$PANEWIRE" lanes ls ) |
    python3 -c 'import json,sys; json.load(sys.stdin)' ||
    fail "#1010 N1: the fixture default lanes ls output must parse as JSON"
  echo "PASS 1010-lanes N1: fixture default lanes ls output is valid JSON"

  # N5 — a session_machine_ids value the matcher can only PARTIALLY read is a
  # parse failure, not "no entry"; likewise a crashed interpreter. Neither may
  # register, and the interpreter's stderr stays out of the spawn's.
  printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nsession_machine_ids = { default = "mac-work-default", "other" = "m2" }\n' \
    "$LANES_TOKEN_FILE" >"$TMP/lanes-bad-partial.toml"
  LANES_CFG_OVERRIDE="$TMP/lanes-bad-partial.toml" HERDR_SESSION=default \
    lanes_spawn lane-1010-partial --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1010 N5: spawn failed on a partially parsed map (rc=$LANES_RC): $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call lane-1010-partial
  grep -q 'session_machine_ids value could not be parsed' "$LANES_ERR" ||
    fail "#1010 N5: a partially parsed map must warn could-not-be-parsed: $(cat "$LANES_ERR")"
  ! grep -q 'has no session_machine_ids entry' "$LANES_ERR" ||
    fail "#1010 N5: a partially parsed map must not read as a missing entry: $(cat "$LANES_ERR")"
  # A crashed python3 (the stub below exits 139 only for the
  # `python3 - <session> <{raw}>` probe and delegates every other call) takes
  # the same parse-failure wording — and its traceback never reaches stderr.
  LANES_PY3_STUB="$TMP/py3stub"
  mkdir -p "$LANES_PY3_STUB"
  LANES_REAL_PY3="$(command -v python3)"
# shellcheck disable=SC2016 # the stub's $N are its own argv, not expansions here
  printf '#!/usr/bin/env bash\nif [[ "${WRK_TEST_PY3_CRASH:-0}" == 1 && "${1:-}" == "-" && "${2:-}" != /* && "${3:-}" == \\{* ]]; then\n  echo "Traceback (most recent call last):" >&2\n  echo "RuntimeError: fixture crash" >&2\n  exit 139\nfi\nexec "%s" "$@"\n' \
    "$LANES_REAL_PY3" >"$LANES_PY3_STUB/python3"
  chmod +x "$LANES_PY3_STUB/python3"
  PATH="$LANES_PY3_STUB:$PATH" WRK_TEST_PY3_CRASH=1 HERDR_SESSION=default \
    lanes_spawn lane-1010-crash --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1010 N5: a crashed interpreter must not fail the spawn (rc=$LANES_RC): $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call lane-1010-crash
  grep -q 'session_machine_ids value could not be parsed' "$LANES_ERR" ||
    fail "#1010 N5: a crashed interpreter must warn could-not-be-parsed, not no-entry: $(cat "$LANES_ERR")"
  ! grep -q 'has no session_machine_ids entry' "$LANES_ERR" ||
    fail "#1010 N5: a crashed interpreter must not read as a missing entry: $(cat "$LANES_ERR")"
  ! grep -q 'Traceback' "$LANES_ERR" ||
    fail "#1010 N5: interpreter stderr must stay out of the spawn's: $(cat "$LANES_ERR")"
  # And on the normal path nothing from the interpreter leaks either.
  HERDR_SESSION=default lanes_spawn lane-1010-quiet --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] || fail "#1010 N5: quiet-path spawn failed (rc=$LANES_RC)"
  ! grep -q 'Traceback' "$LANES_ERR" ||
    fail "#1010 N5: stray interpreter stderr on the normal path: $(cat "$LANES_ERR")"
  echo "PASS 1010-lanes N5: parse failure warns could-not-be-parsed, stderr stays silent"

  # N7 — mint_task stops loudly at the end of the pre-minted pool
  # (768001-769199) instead of minting an id the fixture never created, which
  # surfaced as a swallowed rc 2 in a later spawn.
  lanes_mint_saved="$(cat "$TMP/mint-seq" 2>/dev/null || echo 768000)"
  printf '769199\n' >"$TMP/mint-seq"
  set +e
  lanes_mint_out="$(mint_task 2>&1)"
  lanes_mint_rc=$?
  set -e
  printf '%s\n' "$lanes_mint_saved" >"$TMP/mint-seq"
  [[ "$lanes_mint_rc" -ne 0 ]] ||
    fail "#1010 N7: mint_task must fail once the pool is exhausted"
  grep -q 'task pool exhausted' <<<"$lanes_mint_out" ||
    fail "#1010 N7: the exhaustion message must name the pool: $lanes_mint_out"
  echo "PASS 1010-lanes N7: mint_task fails loudly at pool exhaustion"

  # -- #1010 assertion-RED mutants ------------------------------------------
  # M1: "reap never removes a lane whose machine differs even when the pane
  # matches" — drop the machine half of the compare (#994 tester mutant MD,
  # which slipped through the suite); S1's no-rm assertion must then fail.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1010-nomachine \
    '        if machine == want_machine and pane == want_pane:' \
    '        if pane == want_pane:'
  lanes_reap_job j1010-m1 w1:p13 w1:t13 own-1010-m1 lane-1010-m1 lbl-1010-m1
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1010-nomachine" \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1010-m1","machine":"mac-work-other","pane":"w1:p13","parent":"x","sink":false}]}' \
    lanes_reap_run m1010a --lane own-1010-m1 --apply
  if [[ ! -f "$LANES_RM_LOG" ]] || ! grep -qxF 'rm' "$LANES_RM_LOG"; then
    fail "#1010 M1 mutant survived: a same-pane row on another machine was not swept"
  fi
  echo "PASS 1010-lanes M1: dropping the machine half of the compare goes RED"

  # M2: "a malformed lookup row never matches" — restore the old IFS=tab read
  # semantics in the compare (tab-split with empty-field collapse, truncated
  # at the first newline); N2's no-rm assertions must then fail.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1010-ifsread \
    '        if machine == want_machine and pane == want_pane:' \
    '        if [p for p in ("%s\t%s" % (machine, pane)).split("\n")[0].split("\t") if p] == [want_machine, want_pane]:'
  lanes_reap_job j1010-m2a w1:p14 w1:t14 own-1010-m2a lane-1010-m2a lbl-1010-m2a m-c
  lanes_reap_job j1010-m2b w1:p15 w1:t15 own-1010-m2b lane-1010-m2b lbl-1010-m2b m-d
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1010-ifsread" \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1010-m2a","machine":"m-c\tw1:p14","pane":"","parent":"x","sink":false}]}' \
    lanes_reap_run m1010b --lane own-1010-m2a --apply
  if [[ ! -f "$LANES_RM_LOG" ]] || ! grep -qxF 'rm' "$LANES_RM_LOG"; then
    fail "#1010 M2 mutant survived: the empty-field row did not falsely match"
  fi
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1010-ifsread" \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1010-m2b","machine":"m-d","pane":"w1:p15\nzz","parent":"x","sink":false}]}' \
    lanes_reap_run m1010c --lane own-1010-m2b --apply
  if [[ ! -f "$LANES_RM_LOG" ]] || ! grep -qxF 'rm' "$LANES_RM_LOG"; then
    fail "#1010 M2 mutant survived: the newline-carrying row did not falsely match"
  fi
  echo "PASS 1010-lanes M2: restoring the IFS=tab read goes RED"

  # ------------------------------------------------------------------
  # #1037 — lanes_token_env: a lanes-only credential that never gates
  # ------------------------------------------------------------------
  # AC1 — a lanes-only [hub] (hub_url + lanes_token_env + session_machine_ids,
  # no hub_token_env) still registers the lane, with the lanes credential as
  # --hub-token-env, and never opts into the quota gate: no `place` call may
  # reach panewire.
  LANES_CFG_OVERRIDE="$LANES_CFG_NODE" HERDR_SESSION=default \
    lanes_spawn lane-1037-ac1 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1037 AC1: lanes-only spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" "$LANES_NODE_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, token_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
want = ["add", "lane-1037-ac1", "--machine", "mac-work-default", "--pane", "w:p1",
        "--parent", "work-kairos", "--hub-url", "https://hub.invalid",
        "--hub-token-env", token_file, "--hub-cf-env", cf_file, "--"]
assert got == want, "lanes add argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#1037 AC1: lanes add must run once with the lanes credential"
  if [[ -f "$LANES_PANEWIRE_LOG" ]] && grep -qxF 'place' "$LANES_PANEWIRE_LOG"; then
    fail "#1037 AC1: a lanes-only config must never invoke the quota gate"
  fi
  grep -q ' lane=lane-1037-ac1@mac-work-default$' "$LANES_OUT" ||
    fail "#1037 AC1: the OK line must carry the registered lane"
  # #1138 AC8d: a lanes-only [hub] without quota_gate still registers the lane
  # AND prints the skipped-gate warning exactly once.
  [[ "$(grep -cxF "$HUB_GATE_WARN_TEXT" "$LANES_ERR")" -eq 1 ]] ||
    fail "#1138 AC8d: a lanes-only spawn must warn exactly once: $(cat "$LANES_ERR")"
  echo "PASS 1037-lanes AC1: lanes-only registers, quota gate stays off"

  # #1138 AC8c: the same lanes-only shape plus quota_gate = "local" takes the
  # identical local-only path silently — lane registered, no warning.
  LANES_CFG_OVERRIDE="$LANES_CFG_NODE_LOCAL" HERDR_SESSION=default \
    lanes_spawn lane-1138-local --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1138 AC8c: a quota_gate=local spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" <<'PY' ||
import sys
try:
    got = open(sys.argv[1], encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
assert got[:2] == ["add", "lane-1138-local"], \
    "quota_gate=local must leave lanes registration intact: %r" % got
PY
    fail "#1138 AC8c: quota_gate=local must still register the lane"
  [[ "$(grep -cxF "$HUB_GATE_WARN_TEXT" "$LANES_ERR")" -eq 0 ]] ||
    fail "#1138 AC8c: quota_gate=local must suppress the warning: $(cat "$LANES_ERR")"
  if [[ -f "$LANES_PANEWIRE_LOG" ]] && grep -qxF 'place' "$LANES_PANEWIRE_LOG"; then
    fail "#1138 AC8c: quota_gate=local must never invoke the quota gate"
  fi
  echo "PASS 1138-lanes: quota_gate=local registers the lane without the warning"

  # AC2 — both credentials: lanes routes use lanes_token_env while the quota
  # gate keeps hub_token_env. Assert each panewire call's exact argv.
  LANES_CFG_OVERRIDE="$LANES_CFG_BOTH" HERDR_SESSION=default \
    lanes_spawn lane-1037-ac2 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1037 AC2: dual-credential spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_PANEWIRE_LOG" "$LANES_CALLS" "$ROOT" "$LANES_TOKEN_FILE" "$LANES_NODE_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
shared_path, lanes_path, cwd, op_file, node_file, cf_file = sys.argv[1:]
def blocks(path):
    out, cur = [], []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return out
    for line in lines:
        if line == "--":
            out.append(cur)
            cur = []
        else:
            cur.append(line)
    return out
shared = [b for b in blocks(shared_path) if b]
lanes = [b for b in blocks(lanes_path) if b]
place = [b for b in shared if b[0] == "place"]
assert len(place) == 1, "exactly one place call expected: %r" % (shared,)
want_place = ["place", "--class", "worker", "--cwd", cwd, "--pool", "codex",
              "--hub-url", "https://hub.invalid", "--hub-token-env", op_file,
              "--hub-cf-env", cf_file]
assert place[0] == want_place, "place argv mismatch: got=%r want=%r" % (place[0], want_place)
want_add = ["add", "lane-1037-ac2", "--machine", "mac-work-default",
            "--pane", "w:p1", "--parent", "work-kairos",
            "--hub-url", "https://hub.invalid", "--hub-token-env", node_file,
            "--hub-cf-env", cf_file]
assert lanes == [want_add], "lanes add argv mismatch: got=%r want=%r" % (lanes, want_add)
PY
    fail "#1037 AC2: place must use hub_token_env, lanes add must use lanes_token_env"
  echo "PASS 1037-lanes AC2: the lanes credential reaches lanes only, place keeps the operator file"

  # AC4 — under a lanes-only config, reap's `lanes ls` confirmation and
  # `lanes rm` also carry the lanes credential.
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox-1037"
  lanes_reap_job j1037-reap w1:p1 w1:t1 own-1037 lane-1037-reap lbl-1037
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1037-reap","machine":"mac-work-default","pane":"w1:p1","parent":"own-1037","sink":false}]}' \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_NODE" \
    lanes_reap_run ac4 --lane own-1037 --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1037 AC4: apply failed: $(cat "$LANES_REAP_ERR")"
  python3 - "$LANES_RM_LOG" "$LANES_NODE_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, node_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
creds = ["--hub-url", "https://hub.invalid",
         "--hub-token-env", node_file, "--hub-cf-env", cf_file]
want = (["ls"] + creds + ["--"]
        + ["rm", "lane-1037-reap"] + creds + ["--"])
assert got == want, "reap lanes argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#1037 AC4: reap ls+rm must carry the lanes credential"
  grep -q '^closed job=j1037-reap ' "$LANES_REAP_OUT" ||
    fail "#1037 AC4: the job must close: $(cat "$LANES_REAP_OUT")"
  echo "PASS 1037-lanes AC4: reap ls+rm use lanes_token_env"

  # AC5 — a lanes credential bound to another machine never reaches the hub:
  # wrk compares the token file's HUB_MACHINE_ID line with the session's
  # mapped machine, warns once, and skips the registration it would 403.
  LANES_CFG_OVERRIDE="$LANES_CFG_MISMATCH" HERDR_SESSION=default \
    lanes_spawn lane-1037-ac5 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1037 AC5: a mismatched lanes credential must not fail the spawn (rc=$LANES_RC)"
  lanes_assert_no_lanes_call lane-1037-ac5
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#1037 AC5: exactly one warning expected: $(cat "$LANES_ERR")"
  grep -q "does not match the session's machine" "$LANES_ERR" ||
    fail "#1037 AC5: the warning must name the machine mismatch: $(cat "$LANES_ERR")"
  ! grep -q ' lane=' "$LANES_OUT" || fail "#1037 AC5: nothing may be appended"
  echo "PASS 1037-lanes AC5: machine mismatch warns once and skips"

  # B1 — the extracted id reaches a compare or output ONLY as a bare machine
  # id: a one-line file "HUB_MACHINE_ID=mac-work-other HUB_TOKEN=<secret>"
  # yields a tail that is never charset-valid, so wrk warns once WITHOUT the
  # value and skips. (Before the allowlist the mismatch warning echoed the
  # raw tail — token included — to stderr on every spawn.)
  LANES_CFG_OVERRIDE="$LANES_CFG_INLINE" HERDR_SESSION=default \
    lanes_spawn lane-1037-malformed --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1037 malformed: a bad lanes id must not fail the spawn (rc=$LANES_RC)"
  lanes_assert_no_lanes_call lane-1037-malformed
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#1037 malformed: exactly one warning expected: $(cat "$LANES_ERR")"
  grep -qF 'lanes_token_env HUB_MACHINE_ID is malformed' "$LANES_ERR" ||
    fail "#1037 malformed: the warning must be the value-free malformed one: $(cat "$LANES_ERR")"
  echo "PASS 1037-lanes malformed id warns once without the value and skips"

  # A prefix-shaped id is still a mismatch: mac-work vs mac-work-default must
  # warn once carrying the (charset-valid) value — a prefix compare would
  # silently register the lane against the wrong machine instead.
  LANES_CFG_OVERRIDE="$LANES_CFG_PREFIX" HERDR_SESSION=default \
    lanes_spawn lane-1037-prefix --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1037 prefix: a mismatched lanes id must not fail the spawn (rc=$LANES_RC)"
  lanes_assert_no_lanes_call lane-1037-prefix
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#1037 prefix: exactly one warning expected: $(cat "$LANES_ERR")"
  grep -qF "HUB_MACHINE_ID 'mac-work' does not match the session's machine 'mac-work-default'" "$LANES_ERR" ||
    fail "#1037 prefix: the warning must carry the exact-compare mismatch: $(cat "$LANES_ERR")"
  echo "PASS 1037-lanes prefix id warns once as a mismatch and skips"

  # The node token values appear nowhere: the paths travel, the contents do
  # not — wrk extracts only the HUB_MACHINE_ID assignment, never HUB_TOKEN.
  for output in "$TMP"/lanes-lane-1037-* "$TMP"/lanes-reap-ac4.*; do
    [[ -f "$output" ]] || continue
    for secret in "$LANES_NODE_TOKEN_VALUE" "$LANES_NODE_OTHER_VALUE" \
                  "$LANES_NODE_INLINE_VALUE" "$LANES_NODE_PREFIX_VALUE"; do
      if grep -Fq "$secret" "$output"; then
        fail "#1037: the lanes token contents leaked into ${output##*/}"
      fi
    done
  done
  echo "PASS 1037-lanes: node token contents never printed"

  # -- #1037 assertion-RED mutants ------------------------------------------
  # M1: "a lanes-only config never switches on the quota gate" — the mutant
  # opts in on hub_url alone, so AC1's no-`place` assertion (or its rc) would
  # fail: the lanes-only spawn must visibly reach the gate or be refused.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1037-gateurl \
    '  if [[ -z "$token_env" ]]; then
    return 0
  fi
  if [[ -z "$hub_url" ]]; then' \
    '  if [[ -z "$token_env" && -z "$hub_url" ]]; then
    return 0
  fi
  if [[ -z "$hub_url" ]]; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1037-gateurl" \
    LANES_CFG_OVERRIDE="$LANES_CFG_NODE" HERDR_SESSION=default \
    lanes_spawn lane-1037-m1 --owner work-kairos
  if [[ "$LANES_RC" -eq 0 ]] &&
     ! { [[ -f "$LANES_PANEWIRE_LOG" ]] && grep -qxF 'place' "$LANES_PANEWIRE_LOG"; }; then
    fail "#1037 M1 mutant survived: hub_url still did not opt into the gate"
  fi
  echo "PASS 1037-lanes M1: opting in on hub_url goes RED"

  # M2: "the lanes credential never reaches place" — the mutant has the gate
  # read lanes_token_env, so AC2's exact place argv (operator file on
  # --hub-token-env) would fail: the node file must appear in the place call.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1037-gateread \
    '  token_env="$(spillover_value hub hub_token_env 2>/dev/null || true)"
  cf_env="$(spillover_value hub hub_cf_env 2>/dev/null || true)"

  # Only the operator credential opts this gate in' \
    '  token_env="$(spillover_value hub lanes_token_env 2>/dev/null || true)"
  cf_env="$(spillover_value hub hub_cf_env 2>/dev/null || true)"

  # Only the operator credential opts this gate in'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1037-gateread" \
    LANES_CFG_OVERRIDE="$LANES_CFG_BOTH" HERDR_SESSION=default \
    lanes_spawn lane-1037-m2 --owner work-kairos
  if [[ ! -f "$LANES_PANEWIRE_LOG" ]] ||
     ! grep -qxF "$LANES_NODE_FILE" "$LANES_PANEWIRE_LOG"; then
    fail "#1037 M2 mutant survived: the lanes credential never reached place"
  fi
  echo "PASS 1037-lanes M2: the gate reading lanes_token_env goes RED"

  # M3: "a malformed lanes machine id never reaches output" — the mutant
  # drops the charset gate, so the inline file's raw tail (same-line
  # HUB_TOKEN included) flows into the mismatch warning and the canary must
  # appear in stderr. GREEN restores the value-free malformed warning.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1037-noidcheck \
    "      if ! ascii_re \"\$lanes_machine\" '^[A-Za-z0-9._-]{1,64}\$'; then" \
    '      if false; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1037-noidcheck" \
    LANES_CFG_OVERRIDE="$LANES_CFG_INLINE" HERDR_SESSION=default \
    lanes_spawn lane-1037-m3 --owner work-kairos
  if ! grep -Fq "$LANES_NODE_INLINE_VALUE" "$LANES_ERR"; then
    fail "#1037 M3 mutant survived: a malformed lanes machine id never reaches output"
  fi
  echo "PASS 1037-lanes M3: dropping the charset check goes RED"

  # ------------------------------------------------------------------
  # #1397 — builder lanes: operator credential, machine_id fallback,
  # fail-loud lane=UNREGISTERED, WRK_LANE_STRICT, --lane-defer remote
  # registration and the read-only lanes-missing audit
  # ------------------------------------------------------------------
  # AC1a — the mbp shape: no session map, so [hub] machine_id supplies the
  # machine and operator_token_env supplies the credential (PUT /v1/lanes
  # wants the operator token). Exactly one add: lane = --lane, parent =
  # --parent, machine = mac-personal; the OK line ends lane=...@mac-personal
  # and the receipt carries both hub fields. The operator token VALUE never
  # reaches any output — the file is mode 000, a path only.
  LANES_CFG_OVERRIDE="$LANES_CFG_OP" LANES_MODEL=builder-sol \
    lanes_spawn b1397-op --role builder --lane b1397-op --parent director-x
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1397 AC1a: operator-credential builder spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" "$LANES_OP_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, op_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
want = ["add", "b1397-op", "--machine", "mac-personal", "--pane", "w:p1",
        "--parent", "director-x", "--hub-url", "https://hub.invalid",
        "--hub-token-env", op_file, "--hub-cf-env", cf_file, "--"]
assert got == want, "operator lanes argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#1397 AC1a: lanes add must use machine_id fallback and the operator credential"
  grep -q ' lane=b1397-op@mac-personal$' "$LANES_OUT" ||
    fail "#1397 AC1a: the OK line must end with the registered lane: $(cat "$LANES_OUT")"
  lanes_spawned_payload b1397-op | python3 -c '
import json, sys
meta = json.loads(sys.stdin.read())
assert meta["hub_lane"] == "b1397-op" and meta["hub_lane_machine"] == "mac-personal", meta' ||
    fail "#1397 AC1a: the receipt must carry the builder hub lane fields"
  ! grep -Fq "$LANES_OP_VALUE" "$LANES_OUT" ||
    fail "#1397 AC1a: the operator token value leaked into stdout"
  ! grep -Fq "$LANES_OP_VALUE" "$LANES_ERR" ||
    fail "#1397 AC1a: the operator token value leaked into stderr"
  echo "PASS 1397-lanes AC1a: machine_id fallback + operator credential registers"

  # AC1b — a mapped session wins over machine_id: the map is consulted first,
  # so the same operator config with a session_machine_ids entry registers on
  # the mapped machine, not mac-personal.
  LANES_CFG_OVERRIDE="$LANES_CFG_OP_MAP" LANES_MODEL=builder-sol HERDR_SESSION=default \
    lanes_spawn b1397-map --role builder --lane b1397-map --parent director-x
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1397 AC1b: mapped builder spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" <<'PY' ||
import sys
try:
    got = open(sys.argv[1], encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
assert got[1:2] == ["b1397-map"] and got[3:4] == ["mac-work-default"], \
    "a mapped session must win over machine_id: %r" % got
PY
    fail "#1397 AC1b: the mapped machine must win over [hub] machine_id"
  grep -q ' lane=b1397-map@mac-work-default$' "$LANES_OUT" ||
    fail "#1397 AC1b: the OK line must carry the mapped machine: $(cat "$LANES_OUT")"
  echo "PASS 1397-lanes AC1b: a mapped session wins over machine_id"

  # AC1c — reap is symmetric: a job whose receipt records hub_lane +
  # hub_lane_machine=mac-personal is removed only while `lanes ls` shows the
  # row bound to that machine+pane, and the rm carries the operator file.
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox-1397"
  lanes_reap_job j1397-reap w1:p13 w1:t13 b1397-reap lane-1397-reap lbl-1397 mac-personal builder
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1397-reap","machine":"mac-personal","pane":"w1:p13","parent":"director-x","sink":false}]}' \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_OP" \
    lanes_reap_run ac1c --lane b1397-reap --apply --include-builders
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1397 AC1c: apply failed: $(cat "$LANES_REAP_ERR")"
  python3 - "$LANES_RM_LOG" "$LANES_OP_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, op_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
creds = ["--hub-url", "https://hub.invalid",
         "--hub-token-env", op_file, "--hub-cf-env", cf_file]
want = (["ls"] + creds + ["--"]
        + ["rm", "lane-1397-reap"] + creds + ["--"])
assert got == want, "reap argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#1397 AC1c: reap must ls-confirm then rm once with the operator credential"
  grep -q '^closed job=j1397-reap ' "$LANES_REAP_OUT" ||
    fail "#1397 AC1c: the job must close: $(cat "$LANES_REAP_OUT")"
  echo "PASS 1397-lanes AC1c: reap removes the recorded lane, operator credential carried"

  # AC2a — remote --host desktop: the delegated wrk gets --lane-defer desktop
  # (an argv flag, never an env var that would leak into the pane), performs
  # no lanes call itself, and records hub_lane/hub_lane_machine=desktop in
  # ITS job.spawned receipt — the receipt lives with the job on the
  # execution host, where `wrk reap` is the only place the pane check can
  # pass. The ssh initiator runs `lanes add` after the remote answers, with
  # machine = the hosts.toml key it reached the host by.
  t1397_remote_spawn b1397-remote
  [[ "$T1397_RC" -eq 0 ]] ||
    fail "#1397 AC2a: remote builder spawn failed (rc=$T1397_RC): $(cat "$T1397_ERR")"
  grep -qE "^wrk: remote host 'desktop' step lane elapsed=[0-9]+s$" "$T1397_ERR" ||
    fail "#1397 AC2a: initiator-side builder lane registration progress line is missing: $(cat "$T1397_ERR")"
  grep -q -- '--lane-defer desktop' "$T1397_SSH" ||
    fail "#1397 AC2a: the delegated spawn must carry --lane-defer desktop: $(cat "$T1397_SSH")"
  grep -q -- '--host local' "$T1397_SSH" ||
    fail "#1397 AC2a: the delegated spawn must run --host local on the target"
  python3 - "$T1397_CALLS" "$LANES_OP_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, op_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
want = ["add", "b1397-remote", "--machine", "desktop", "--pane", "desktop:p7",
        "--parent", "director-x", "--hub-url", "https://hub.invalid",
        "--hub-token-env", op_file, "--hub-cf-env", cf_file, "--"]
assert got == want, "remote lanes argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#1397 AC2a: the initiator-side lanes add must use machine=desktop (the hosts.toml key)"
  grep -q '^OK pane=desktop:p7 host=desktop ' "$T1397_OUT" ||
    fail "#1397 AC2a: the emitted OK line must carry host=desktop: $(cat "$T1397_OUT")"
  grep -q ' lane=b1397-remote@desktop$' "$T1397_OUT" ||
    fail "#1397 AC2a: the OK line must end lane=<lane>@desktop: $(cat "$T1397_OUT")"
  echo "PASS 1397-lanes AC2a: remote builder registers via the initiator, machine=host key"

  # AC2b — what --lane-defer makes the EXECUTION host do: no lanes call, the
  # receipt records lane+machine, and the OK line carries lane=@<defer id>
  # (the initiator's emitted line replaces it with the add outcome). A local
  # spawn with the flag stands in for the remote wrk — same code path.
  LANES_MODEL=builder-sol HERDR_SESSION=default \
    lanes_spawn b1397-defer --role builder --lane b1397-defer --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1397 AC2b: deferred builder spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call b1397-defer
  grep -q ' lane=b1397-defer@desktop$' "$LANES_OUT" ||
    fail "#1397 AC2b: the deferred OK line must carry the deferred id: $(cat "$LANES_OUT")"
  lanes_spawned_payload b1397-defer | python3 -c '
import json, sys
meta = json.loads(sys.stdin.read())
assert meta["hub_lane"] == "b1397-defer" and meta["hub_lane_machine"] == "desktop", meta' ||
    fail "#1397 AC2b: the execution-host receipt must record lane+defer machine"
  # A deferred WORKER is refused outright (tester N1): --lane-defer is
  # builder-only — a worker handed the flag would print a lane= field it
  # never registered. rc 2 (usage), no pane, zero lanes calls.
  HERDR_SESSION=default lanes_spawn w1397-defer --owner work-kairos --lane-defer desktop
  [[ "$LANES_RC" -eq 2 ]] ||
    fail "#1397 AC2b: --lane-defer on a worker must refuse rc 2 (rc=$LANES_RC): $(cat "$LANES_ERR")"
  grep -q -- '--lane-defer requires --role builder' "$LANES_ERR" ||
    fail "#1397 AC2b: the refusal must name the builder-only rule: $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call w1397-defer
  # And a malformed defer id answers the same charset as [hub] machine_id.
  LANES_MODEL=builder-sol \
    lanes_spawn b1397-deferbad --role builder --lane b1397-deferbad --parent director-x --lane-defer 'bad/host'
  [[ "$LANES_RC" -eq 2 ]] ||
    fail "#1397 AC2b: a malformed --lane-defer must refuse rc 2 (rc=$LANES_RC): $(cat "$LANES_ERR")"
  grep -q 'matching \[A-Za-z0-9._-\]' "$LANES_ERR" ||
    fail "#1397 AC2b: the refusal must name the machine-id charset: $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call b1397-deferbad
  echo "PASS 1397-lanes AC2b: --lane-defer is builder-only, validated, and never calls panewire"

  # AC2c — reap on the execution host removes a remote-registered lane the
  # same way: hub_lane_machine is the host key, and `lanes ls` must still
  # show that machine+pane.
  lanes_reap_job j1397-rreap w1:p14 w1:t14 b1397-x lane-1397-remote lbl-1397r desktop builder
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1397-remote","machine":"desktop","pane":"w1:p14","parent":"director-x","sink":false}]}' \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_OP" \
    lanes_reap_run ac2c --lane b1397-x --apply --include-builders
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1397 AC2c: apply failed: $(cat "$LANES_REAP_ERR")"
  [[ "$(grep -cxF 'rm' "$LANES_RM_LOG")" -eq 1 &&
     "$(awk 'f{print; exit} /^rm$/{f=1}' "$LANES_RM_LOG")" == "lane-1397-remote" ]] ||
    fail "#1397 AC2c: exactly one rm for the remote-recorded lane: $(cat "$LANES_RM_LOG")"
  echo "PASS 1397-lanes AC2c: reap removes the remote-registered lane symmetrically"

  # AC2d — a remote --host WORKER keeps the #965 contract end-to-end: no
  # --lane-defer on the wire, and zero `lanes add` from the initiator even
  # though the initiator's config carries hub credentials AND a session map.
  # The execution host's own session-map registration is the ordinary #965
  # worker path (the delegated command is `--host local`), covered by the
  # 965 assertions above; the ssh fixture answers with a canned OK line, so
  # the observable here is the delegated argv and the untouched lane= field.
  T1397_CFG_OVERRIDE="$LANES_CFG_REMOTE_WMAP" \
    t1397_remote_worker w1397-remote --owner work-kairos
  [[ "$T1397_RC" -eq 0 ]] ||
    fail "#1397 AC2d: remote worker spawn failed (rc=$T1397_RC): $(cat "$T1397_ERR")"
  if grep -q -- '--lane-defer' "$T1397_SSH"; then
    fail "#1397 AC2d: --lane-defer must never reach a worker's delegated argv: $(cat "$T1397_SSH")"
  fi
  [[ ! -s "$T1397_CALLS" ]] ||
    fail "#1397 AC2d: the initiator must make zero lanes calls for a remote worker: $(cat "$T1397_CALLS")"
  if grep -q ' lane=' "$T1397_OUT"; then
    fail "#1397 AC2d: no lane= field may be invented for a remote worker: $(cat "$T1397_OUT")"
  fi
  grep -q 'host=desktop' "$T1397_OUT" ||
    fail "#1397 AC2d: the emitted OK line must carry host=desktop: $(cat "$T1397_OUT")"
  echo "PASS 1397-lanes AC2d: remote worker defers nothing; initiator adds nothing"

  # AC2e — a deferred spawn whose job.spawned receipt cannot be written must
  # FAIL the remote leg: the receipt is the only record linking the job to
  # the lane the initiator is about to lanes-add, so a lost write would leave
  # a hub row no reap can attribute. Under --lane-defer the receipt failure
  # answers 2 (a remote stop-set answer) instead of warn-only — a local spawn
  # carrying the flag runs the remote wrk's own code path. A non-deferred
  # spawn keeps the #994 contract: warn, deregister, rc 0.
  T1397_FAIL_ARBITER="$TMP/t1397-arbiter-norcpt"
  cat >"$T1397_FAIL_ARBITER" <<SH
#!/bin/bash
# Delegates to the real arbiter except event --kind job.spawned, which
# answers rc 3 — a forced receipt write failure.
if [[ "\$1" == event ]]; then
  for a in "\$@"; do
    [[ "\$a" == job.spawned ]] && exit 3
  done
fi
exec "$ARBITER" "\$@"
SH
  chmod +x "$T1397_FAIL_ARBITER"
  LANES_CFG_OVERRIDE="$LANES_CFG_OP" LANES_MODEL=builder-sol \
    LANES_ARBITER_BIN="$T1397_FAIL_ARBITER" \
    lanes_spawn b1397-norcpt --role builder --lane b1397-norcpt --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 2 ]] ||
    fail "#1397 AC2e: a deferred receipt failure must answer nonzero (rc=$LANES_RC): $(cat "$LANES_ERR")"
  if grep -q '^OK pane=' "$LANES_OUT"; then
    fail "#1397 AC2e: no OK line may survive a failed deferred receipt: $(cat "$LANES_OUT")"
  fi
  grep -q 'receipt failed under --lane-defer' "$LANES_ERR" ||
    fail "#1397 AC2e: the failure must name --lane-defer: $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call b1397-norcpt
  LANES_CFG_OVERRIDE="$LANES_CFG_OP" LANES_MODEL=builder-sol \
    LANES_ARBITER_BIN="$T1397_FAIL_ARBITER" \
    lanes_spawn b1397-rcptok --role builder --lane b1397-rcptok --parent director-x
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1397 AC2e: a non-deferred receipt failure must stay warn-only (rc=$LANES_RC): $(cat "$LANES_ERR")"
  grep -q '^OK pane=' "$LANES_OUT" ||
    fail "#1397 AC2e: the non-deferred spawn still prints its OK line: $(cat "$LANES_OUT")"
  # The initiator half of the same guarantee: ANY nonzero remote answer —
  # the receipt failure above included — skips the initiator's lanes add.
  T1397_SSH_SCENARIO=remote-die-stderr t1397_remote_spawn b1397-nodie
  [[ "$T1397_RC" -ne 0 ]] ||
    fail "#1397 AC2e: a failed remote spawn must answer nonzero (rc=$T1397_RC)"
  [[ ! -s "$T1397_CALLS" ]] ||
    fail "#1397 AC2e: the initiator must not lanes-add when the remote answers nonzero: $(cat "$T1397_CALLS")"
  echo "PASS 1397-lanes AC2e: a failed deferred receipt adds no lane and answers 2"

  # AC2f — the remote add writes a lane on ANOTHER machine: a node-scoped
  # lanes_token_env only authorizes this host's own lanes, so when the
  # initiator has both configured the remote add must carry
  # operator_token_env, not the shared chain's first hit.
  T1397_CFG_OVERRIDE="$LANES_CFG_REMOTE_BOTH" t1397_remote_spawn b1397-opcred
  [[ "$T1397_RC" -eq 0 ]] ||
    fail "#1397 AC2f: remote builder spawn failed (rc=$T1397_RC): $(cat "$T1397_ERR")"
  python3 - "$T1397_CALLS" "$LANES_OP_FILE" "$LANES_TOKEN_FILE" <<'PY' ||
import sys
log, op_file, lanes_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
assert "add" in got, "the initiator must still add the remote builder lane: %r" % got
i = got.index("--hub-token-env")
assert got[i + 1] == op_file, \
    "the remote add must carry operator_token_env, not the node-scoped lanes token: %r" % got
assert lanes_file not in got, "lanes_token_env must not authorize a cross-machine add: %r" % got
PY
    fail "#1397 AC2f: the remote add must prefer operator_token_env over lanes_token_env"
  echo "PASS 1397-lanes AC2f: the remote add prefers operator_token_env"

  # AC2g — an OK pane= line settles the builder lane whatever the remote rc
  # (tester B1): a deferred remote builder that prints its OK line then
  # exits nonzero — landing-strict's 76 leaves the pane up — must NOT pass
  # its unconfirmed lane= through. rc 76 runs the initiator add as rc 0
  # does; a failed add, or a non-pane-valid rc, rewrites the field to
  # lane=UNREGISTERED. The fixture's printed lane=fixture@desktop is the
  # exact pass-through this guards against.
  T1397_SSH_SCENARIO=remote-ok-nonzero T1397_REMOTE_RC=76 \
    t1397_remote_spawn b1397-ok76
  [[ "$T1397_RC" -eq 76 ]] ||
    fail "#1397 AC2g: the remote's 76 must propagate (rc=$T1397_RC): $(cat "$T1397_ERR")"
  grep -qxF 'add' "$T1397_CALLS" ||
    fail "#1397 AC2g: rc 76 leaves the pane up — the add must run: $(cat "$T1397_CALLS")"
  grep -q ' lane=b1397-ok76@desktop$' "$T1397_OUT" ||
    fail "#1397 AC2g: a confirmed add keeps lane=L@HOST: $(cat "$T1397_OUT")"
  ! grep -q 'fixture@desktop' "$T1397_OUT" ||
    fail "#1397 AC2g: the unconfirmed remote lane= must never pass through"
  WRK_PANEWIRE_LANES_RC=5 T1397_SSH_SCENARIO=remote-ok-nonzero T1397_REMOTE_RC=76 \
    t1397_remote_spawn b1397-ok76fail
  [[ "$T1397_RC" -eq 76 ]] ||
    fail "#1397 AC2g: rc 76 still propagates when the add fails (rc=$T1397_RC): $(cat "$T1397_ERR")"
  grep -q ' lane=UNREGISTERED$' "$T1397_OUT" ||
    fail "#1397 AC2g: a failed add rewrites the field to UNREGISTERED: $(cat "$T1397_OUT")"
  ! grep -q 'fixture@desktop' "$T1397_OUT" ||
    fail "#1397 AC2g: the unconfirmed remote lane= must never pass through"
  T1397_SSH_SCENARIO=remote-ok-nonzero T1397_REMOTE_RC=42 \
    t1397_remote_spawn b1397-ok42
  [[ "$T1397_RC" -eq 42 ]] ||
    fail "#1397 AC2g: a non-pane-valid rc propagates (rc=$T1397_RC): $(cat "$T1397_ERR")"
  [[ ! -s "$T1397_CALLS" ]] ||
    fail "#1397 AC2g: rc 42 is not pane-valid — no add may run: $(cat "$T1397_CALLS")"
  grep -q ' lane=UNREGISTERED$' "$T1397_OUT" ||
    fail "#1397 AC2g: an unconfirmed lane= is still settled to UNREGISTERED: $(cat "$T1397_OUT")"
  echo "PASS 1397-lanes AC2g: an OK line settles the lane whatever the remote rc"

  # AC3 — every builder registration failure is loud on the OK line but
  # never fails the spawn: rc 0, `OK pane=w:p1` still there (the pane is not
  # orphaned), ` lane=UNREGISTERED` ends the line, exactly one warning.
  # 3a: no hub_url.
  LANES_CFG_OVERRIDE="$LANES_CFG_NOURL" LANES_MODEL=builder-sol \
    lanes_spawn b1397-nourl --role builder --lane b1397-nourl --parent director-x
  [[ "$LANES_RC" -eq 0 ]] || fail "#1397 AC3a: rc=$LANES_RC: $(cat "$LANES_ERR")"
  grep -q '^OK pane=w:p1 ' "$LANES_OUT" || fail "#1397 AC3a: the pane must stay up"
  grep -q ' lane=UNREGISTERED$' "$LANES_OUT" ||
    fail "#1397 AC3a: lane=UNREGISTERED expected: $(cat "$LANES_OUT")"
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#1397 AC3a: exactly one warning expected: $(cat "$LANES_ERR")"
  grep -q 'hub_url' "$LANES_ERR" || fail "#1397 AC3a: the warning must name hub_url"
  lanes_assert_no_lanes_call b1397-nourl
  # 3b: hub_url but no credential of any kind.
  LANES_CFG_OVERRIDE="$LANES_CFG_NOCRED" LANES_MODEL=builder-sol \
    lanes_spawn b1397-nocred --role builder --lane b1397-nocred --parent director-x
  [[ "$LANES_RC" -eq 0 ]] || fail "#1397 AC3b: rc=$LANES_RC: $(cat "$LANES_ERR")"
  grep -q ' lane=UNREGISTERED$' "$LANES_OUT" ||
    fail "#1397 AC3b: lane=UNREGISTERED expected: $(cat "$LANES_OUT")"
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#1397 AC3b: exactly one warning expected: $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call b1397-nocred
  # 3c: no session map AND no machine_id — the builder has no machine.
  LANES_CFG_OVERRIDE="$LANES_CFG_OP_NOID" LANES_MODEL=builder-sol \
    lanes_spawn b1397-unmapped --role builder --lane b1397-unmapped --parent director-x
  [[ "$LANES_RC" -eq 0 ]] || fail "#1397 AC3c: rc=$LANES_RC: $(cat "$LANES_ERR")"
  grep -q ' lane=UNREGISTERED$' "$LANES_OUT" ||
    fail "#1397 AC3c: lane=UNREGISTERED expected: $(cat "$LANES_OUT")"
  grep -q 'machine_id is unset' "$LANES_ERR" ||
    fail "#1397 AC3c: the warning must name the missing machine_id: $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call b1397-unmapped
  # 3d: panewire refuses the add — the attempt is visible in the calls log.
  LANES_CFG_OVERRIDE="$LANES_CFG_OP" LANES_MODEL=builder-sol \
    WRK_PANEWIRE_LANES_RC=5 \
    lanes_spawn b1397-addfail --role builder --lane b1397-addfail --parent director-x
  [[ "$LANES_RC" -eq 0 ]] || fail "#1397 AC3d: rc=$LANES_RC: $(cat "$LANES_ERR")"
  grep -q ' lane=UNREGISTERED$' "$LANES_OUT" ||
    fail "#1397 AC3d: lane=UNREGISTERED expected: $(cat "$LANES_OUT")"
  grep -q 'panewire lanes add exited 5' "$LANES_ERR" ||
    fail "#1397 AC3d: the warning must carry the panewire rc: $(cat "$LANES_ERR")"
  grep -qxF 'add' "$LANES_CALLS" ||
    fail "#1397 AC3d: the refused add must still have been attempted"
  # 3e: an invalid lane name (panewire's own rule) warns and never reaches argv.
  LANES_CFG_OVERRIDE="$LANES_CFG_OP" LANES_MODEL=builder-sol \
    lanes_spawn b1397-badlane --role builder --lane 'BAD_LANE' --parent director-x
  [[ "$LANES_RC" -eq 0 ]] || fail "#1397 AC3e: rc=$LANES_RC: $(cat "$LANES_ERR")"
  grep -q ' lane=UNREGISTERED$' "$LANES_OUT" ||
    fail "#1397 AC3e: lane=UNREGISTERED expected: $(cat "$LANES_OUT")"
  grep -q 'not a valid panewire lane name' "$LANES_ERR" ||
    fail "#1397 AC3e: the warning must name the lane rule: $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call b1397-badlane
  echo "PASS 1397-lanes AC3: every unregistered builder case is loud but warn-only"

  # 3f — WRK_LANE_STRICT=1 turns the same case into rc 82 AFTER the pane is
  # up and the OK line has printed; the pane is never reaped or hidden.
  LANES_CFG_OVERRIDE="$LANES_CFG_NOURL" LANES_MODEL=builder-sol \
    WRK_LANE_STRICT=1 \
    lanes_spawn b1397-strict --role builder --lane b1397-strict --parent director-x
  [[ "$LANES_RC" -eq 82 ]] ||
    fail "#1397 AC3f: strict must answer 82 (rc=$LANES_RC): $(cat "$LANES_ERR")"
  grep -q '^OK pane=w:p1 ' "$LANES_OUT" ||
    fail "#1397 AC3f: the OK line still prints under strict: $(cat "$LANES_OUT")"
  grep -q ' lane=UNREGISTERED$' "$LANES_OUT" ||
    fail "#1397 AC3f: lane=UNREGISTERED still marks the line: $(cat "$LANES_OUT")"
  grep -q 'strict_exit=82' "$LANES_ERR" ||
    fail "#1397 AC3f: the strict warning must name the exit: $(cat "$LANES_ERR")"
  # And the remote leg: a refused initiator-side add answers 82 under strict
  # (default stays warn-only).
  WRK_PANEWIRE_LANES_RC=5 t1397_remote_spawn b1397-runreg
  [[ "$T1397_RC" -eq 0 ]] ||
    fail "#1397 AC3g: warn-only remote unregistered must stay rc 0: $(cat "$T1397_ERR")"
  grep -q ' lane=UNREGISTERED$' "$T1397_OUT" ||
    fail "#1397 AC3g: the remote OK line must be rewritten to UNREGISTERED: $(cat "$T1397_OUT")"
  grep -q 'host=desktop' "$T1397_OUT" ||
    fail "#1397 AC3g: host= must still be rewritten: $(cat "$T1397_OUT")"
  WRK_PANEWIRE_LANES_RC=5 WRK_LANE_STRICT=1 t1397_remote_spawn b1397-rstrict
  [[ "$T1397_RC" -eq 82 ]] ||
    fail "#1397 AC3h: strict remote unregistered must answer 82 (rc=$T1397_RC): $(cat "$T1397_ERR")"
  grep -q ' lane=UNREGISTERED$' "$T1397_OUT" ||
    fail "#1397 AC3h: the strict remote OK line must still print: $(cat "$T1397_OUT")"
  echo "PASS 1397-lanes AC3f-h: WRK_LANE_STRICT answers 82 local and remote"

  # AC4 is carried by the unchanged #965 worker assertions above — the
  # worker contract (silent absent map, --owner parent, warn-only failures,
  # no lane= on failure) was diffed, not rewritten.

  # AC5 — lanes-missing audits open jobs read-only: one `lanes ls`, then a
  # per-job line for each absent builder lane or absent parent. Jobs: one
  # fully routed (no finding), one lane missing, one parent missing, one
  # missing but already closed (not reported).
  T1397_LM_INBOX="$TMP/lanes-missing-inbox"
  mkdir -p "$T1397_LM_INBOX"
  env ARBITER_INBOX_ROOT="$T1397_LM_INBOX" "$ARBITER" claim \
    --job lm-present --lane b-lm-present --agent-label lm-present \
    --role builder --parent-lane director-x --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$T1397_LM_INBOX" "$ARBITER" event --job lm-present \
    --kind job.spawned --payload-json '{"owner_lane":"b-lm-present","label":"lm-present","pane_id":"w1:p1","tab_id":"w1:t1","hub_lane":"b-lm-present","hub_lane_machine":"mac-personal"}' >/dev/null
  env ARBITER_INBOX_ROOT="$T1397_LM_INBOX" "$ARBITER" claim \
    --job lm-absent --lane b-lm-absent --agent-label lm-absent \
    --role builder --parent-lane director-x --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$T1397_LM_INBOX" "$ARBITER" event --job lm-absent \
    --kind job.spawned --payload-json '{"owner_lane":"b-lm-absent","label":"lm-absent","pane_id":"w1:p2","tab_id":"w1:t2"}' >/dev/null
  env ARBITER_INBOX_ROOT="$T1397_LM_INBOX" "$ARBITER" claim \
    --job lm-parent --lane b-lm-parent --agent-label lm-parent \
    --role builder --parent-lane parent-ghost --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$T1397_LM_INBOX" "$ARBITER" event --job lm-parent \
    --kind job.spawned --payload-json '{"owner_lane":"b-lm-parent","label":"lm-parent","pane_id":"w1:p3","tab_id":"w1:t3"}' >/dev/null
  env ARBITER_INBOX_ROOT="$T1397_LM_INBOX" "$ARBITER" claim \
    --job lm-closed --lane b-lm-closed --agent-label lm-closed \
    --role builder --parent-lane director-x --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$T1397_LM_INBOX" "$ARBITER" event --job lm-closed \
    --kind job.spawned --payload-json '{"owner_lane":"b-lm-closed","label":"lm-closed","pane_id":"w1:p4","tab_id":"w1:t4"}' >/dev/null
  env ARBITER_INBOX_ROOT="$T1397_LM_INBOX" "$ARBITER" event --job lm-closed \
    --kind job.completed --payload-json '{"owner_lane":"b-lm-closed","label":"lm-closed","pane_id":"w1:p4"}' >/dev/null
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"b-lm-present","machine":"mac-personal","pane":"w1:p1","parent":"director-x","sink":false},{"lane":"director-x","machine":"mac-personal","pane":"w1:p9","parent":"","sink":false},{"lane":"b-lm-parent","machine":"mac-personal","pane":"w1:p3","parent":"parent-ghost","sink":false}]}' \
    t1397_lanes_missing audit
  [[ "$T1397_LM_RC" -eq 0 ]] ||
    fail "#1397 AC5: lanes-missing must answer rc 0 (rc=$T1397_LM_RC): $(cat "$T1397_LM_ERR")"
  python3 - "$T1397_LM_OUT" <<'PY' ||
import sys
want = ["missing job=lm-absent lane=b-lm-absent absent=lane role=builder",
        "missing job=lm-parent lane=b-lm-parent parent=parent-ghost absent=parent role=builder",
        "lanes-missing: audited 3 open job(s), 2 missing"]
got = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert got == want, "lanes-missing output mismatch: got=%r want=%r" % (got, want)
PY
    fail "#1397 AC5: findings must name absent lanes and parents exactly"
  # Read-only: the lanes log holds exactly one call and it is `ls` — never a
  # second listing (tester mu16), an add or an rm.
  python3 - "$T1397_LM_LOG" <<'PY' ||
import sys
try:
    got = [line for line in open(sys.argv[1], encoding="utf-8").read().splitlines() if line != "--"]
except OSError:
    raise SystemExit("lanes-missing made no panewire call")
assert got[0] == "ls" and got.count("ls") == 1 and "add" not in got and "rm" not in got, \
    "lanes-missing must call `lanes ls` exactly once: %r" % got
PY
    fail "#1397 AC5: the audit may only call lanes ls, exactly once"
  # A failed listing dies nonzero; a host with no hub credential does too —
  # the audit must never guess.
  WRK_PANEWIRE_LANES_LS_RC=9 t1397_lanes_missing lsfail
  [[ "$T1397_LM_RC" -ne 0 ]] ||
    fail "#1397 AC5: a failed lanes ls must answer nonzero"
  T1397_LM_CFG="$LANES_CFG_NOCRED" t1397_lanes_missing nocred
  [[ "$T1397_LM_RC" -ne 0 ]] ||
    fail "#1397 AC5: a missing credential must answer nonzero"
  T1397_LM_CFG='' WRK_PANEWIRE_LANES_LS='{"lanes":[]}' t1397_lanes_missing help --help
  [[ "$T1397_LM_RC" -eq 0 ]] ||
    fail "#1397 AC5: lanes-missing --help must answer rc 0"
  echo "PASS 1397-lanes AC5: lanes-missing audits read-only and dies on bad input"

  # AC6 — the [hub] machine_id fallback is builder-only (tester mu02): a
  # worker whose session is not in the map must NOT inherit the host's own
  # machine id — a fleet worker never becomes a global lane. The map maps
  # another session, so the lookup runs and misses; machine_id is set, and a
  # worker-fallback mutant would register it on mac-personal.
  LANES_CFG_OVERRIDE="$LANES_CFG_OTHERMAP" HERDR_SESSION=default \
    lanes_spawn w1397-wmap --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1397 AC6: an unmapped worker still spawns warn-only (rc=$LANES_RC): $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call w1397-wmap
  grep -q "session 'default' has no session_machine_ids entry" "$LANES_ERR" ||
    fail "#1397 AC6: the worker warning must name the unmapped session: $(cat "$LANES_ERR")"
  ! grep -q 'machine_id is unset' "$LANES_ERR" ||
    fail "#1397 AC6: a worker must never reach the machine_id fallback: $(cat "$LANES_ERR")"
  ! grep -q ' lane=' "$LANES_OUT" ||
    fail "#1397 AC6: an unmapped worker's OK line carries no lane= field"
  echo "PASS 1397-lanes AC6: the machine_id fallback never applies to workers"

  # AC7 — under --host auto a remote 82 stops the candidate round (tester
  # mu09): the pane exists on that host, so re-placing the job on the next
  # candidate would double-spawn it. Two 82 sources: the remote wrk's own
  # strict answer, and the initiator's strict rewrite after a refused add.
  T1397_HOST=auto T1397_CFG_OVERRIDE="$LANES_CFG_REMOTE_AUTO" \
    T1397_LOAD_FILE="$T1397_LOAD_HIGH" \
    T1397_SSH_SCENARIO_DESKTOP=remote-die-stderr T1397_REMOTE_RC=82 \
    t1397_remote_spawn b1397-auto82
  [[ "$T1397_RC" -eq 82 ]] ||
    fail "#1397 AC7: a remote 82 must propagate (rc=$T1397_RC): $(cat "$T1397_ERR")"
  ! grep -q 'mac-work' "$T1397_SSH" ||
    fail "#1397 AC7: a remote 82 must stop the round before mac-work: $(cat "$T1397_SSH")"
  T1397_HOST=auto T1397_CFG_OVERRIDE="$LANES_CFG_REMOTE_AUTO" \
    T1397_LOAD_FILE="$T1397_LOAD_HIGH" \
    WRK_LANE_STRICT=1 WRK_PANEWIRE_LANES_RC=5 \
    t1397_remote_spawn b1397-strictauto
  [[ "$T1397_RC" -eq 82 ]] ||
    fail "#1397 AC7: strict must turn the refused add into 82 (rc=$T1397_RC): $(cat "$T1397_ERR")"
  ! grep -q 'mac-work' "$T1397_SSH" ||
    fail "#1397 AC7: a strict 82 must stop the round — no double spawn on mac-work: $(cat "$T1397_SSH")"
  grep -q ' lane=UNREGISTERED$' "$T1397_OUT" ||
    fail "#1397 AC7: the OK line still marks UNREGISTERED under strict: $(cat "$T1397_OUT")"
  echo "PASS 1397-lanes AC7: a remote or initiator 82 stops the auto round"

  # AC8 — a TRANSPORT leg exiting 82 normalizes to 1 and the round moves on
  # (tester mu10): an admission code may only be the remote wrk's own answer.
  # The first ssh call is desktop's probe; failing it with 82 must hand the
  # spawn to mac-work, not stop the round.
  T1397_HOST=auto T1397_CFG_OVERRIDE="$LANES_CFG_REMOTE_AUTO" \
    T1397_LOAD_FILE="$T1397_LOAD_HIGH" \
    T1397_SSH_CALL_COUNT_FILE="$TMP/t1397-ssh-count-ac8" \
    T1397_SSH_FAIL_CALLS=1 T1397_SSH_FAIL_CODE=82 \
    t1397_remote_spawn b1397-t82
  [[ "$T1397_RC" -eq 0 ]] ||
    fail "#1397 AC8: a transport 82 must normalize and let mac-work win (rc=$T1397_RC): $(cat "$T1397_ERR")"
  grep -q 'mac-work.*wrk spawn' "$T1397_SSH" ||
    fail "#1397 AC8: the round must reach mac-work: $(cat "$T1397_SSH")"
  echo "PASS 1397-lanes AC8: a transport-leg 82 normalizes and the round moves on"

  # AC9 — WRK_LANE_STRICT is builder-only (tester mu11): an unregistered
  # worker stays rc 0 under strict — strict marks the builder lane contract,
  # never the worker's warn-only #965 path.
  WRK_LANE_STRICT=1 LANES_CFG_OVERRIDE="$LANES_CFG_NOCRED" \
    lanes_spawn w1397-strict --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1397 AC9: strict must never apply to a worker (rc=$LANES_RC): $(cat "$LANES_ERR")"
  grep -q '^OK pane=w:p1 ' "$LANES_OUT" ||
    fail "#1397 AC9: the worker OK line still prints: $(cat "$LANES_OUT")"
  lanes_assert_no_lanes_call w1397-strict
  echo "PASS 1397-lanes AC9: WRK_LANE_STRICT never applies to workers"

  # AC10 — the worker credential chain is the pre-#1397 one (tester B1-r4,
  # operator ruling): a WORKER lane resolves lanes_token_env then
  # hub_token_env and NEVER reads operator_token_env, for register AND reap;
  # a builder lane inserts operator_token_env between the two.
  # (a) mapped worker on hub_token_env + operator_token_env: the add, the ls
  # and the rm all carry the hub_token file — never the operator file.
  LANES_CFG_OVERRIDE="$LANES_CFG_WBOTH" HERDR_SESSION=default \
    lanes_spawn w1397-wboth --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1397 AC10a: mapped worker spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" "$LANES_TOKEN_FILE" "$LANES_OP_FILE" <<'PY' ||
import sys
log, token_file, op_file = sys.argv[1:]
got = open(log, encoding="utf-8").read().splitlines()
i = got.index("--hub-token-env")
assert got[i + 1] == token_file, \
    "a worker must carry hub_token_env, not the operator file: %r" % got
assert op_file not in got, "the operator path must never reach worker argv: %r" % got
PY
    fail "#1397 AC10a: the worker add must carry the hub_token file, never operator"
  grep -q ' lane=w1397-wboth@mac-work-default$' "$LANES_OUT" ||
    fail "#1397 AC10a: the worker OK line must carry the lane: $(cat "$LANES_OUT")"
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox-wboth"
  lanes_reap_job j1397-wboth w1:p16 w1:t16 own-1397wb lane-1397-wboth lbl-1397wb mac-work-default
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1397-wboth","machine":"mac-work-default","pane":"w1:p16","parent":"work-kairos","sink":false}]}' \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_WBOTH" \
    lanes_reap_run wboth --lane own-1397wb --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1397 AC10a: worker apply failed: $(cat "$LANES_REAP_ERR")"
  python3 - "$LANES_RM_LOG" "$LANES_TOKEN_FILE" "$LANES_OP_FILE" <<'PY' ||
import sys
log, token_file, op_file = sys.argv[1:]
got = open(log, encoding="utf-8").read().splitlines()
envs = [got[i + 1] for i, x in enumerate(got) if x == "--hub-token-env"]
assert envs == [token_file, token_file], \
    "worker ls+rm must carry hub_token_env twice, got %r" % got
assert op_file not in got, "the operator path must never reach worker reap argv: %r" % got
PY
    fail "#1397 AC10a: worker reap ls+rm must carry the hub_token file, never operator"
  echo "PASS 1397-lanes AC10a: a mapped worker keeps the hub_token credential end to end"

  # (b) mapped worker on operator_token_env only: the worker chain sees no
  # lanes credential at all — zero calls, no lane= on the OK line, exactly
  # one warning with main's wording.
  LANES_CFG_OVERRIDE="$LANES_CFG_OP_MAP" HERDR_SESSION=default \
    lanes_spawn w1397-wop --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1397 AC10b: operator-only worker spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call w1397-wop
  ! grep -q ' lane=' "$LANES_OUT" ||
    fail "#1397 AC10b: an operator-only worker must not claim a lane: $(cat "$LANES_OUT")"
  grep -q 'neither hub_token_env nor lanes_token_env set' "$LANES_ERR" ||
    fail "#1397 AC10b: the warning must keep main's worker wording: $(cat "$LANES_ERR")"
  # A worker lane receipt reaped on the same config also makes zero calls —
  # the removal half of the worker contract.
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox-wop"
  lanes_reap_job j1397-wop w1:p17 w1:t17 own-1397wop lane-1397-wop lbl-1397wop mac-work-default
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1397-wop","machine":"mac-work-default","pane":"w1:p17","parent":"work-kairos","sink":false}]}' \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_OP_MAP" \
    lanes_reap_run wop --lane own-1397wop --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1397 AC10b: worker apply failed: $(cat "$LANES_REAP_ERR")"
  if [[ -s "$LANES_RM_LOG" ]]; then
    fail "#1397 AC10b: an operator-only host must not ls/rm a worker lane: $(cat "$LANES_RM_LOG")"
  fi
  echo "PASS 1397-lanes AC10b: operator_token_env never reaches a worker (register + reap)"

  # (c) the builder control on the same two configs: the operator file still
  # wins where the builder chain says so — AC1a/AC1b/AC1c pin the argv above;
  # this case adds the hub_token+operator mix, where the builder picks the
  # operator file the worker just refused.
  LANES_CFG_OVERRIDE="$LANES_CFG_WBOTH" LANES_MODEL=builder-sol HERDR_SESSION=default \
    lanes_spawn b1397-wboth --role builder --lane b1397-wboth --parent director-x
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1397 AC10c: builder spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" "$LANES_OP_FILE" <<'PY' ||
import sys
log, op_file = sys.argv[1:]
got = open(log, encoding="utf-8").read().splitlines()
i = got.index("--hub-token-env")
assert got[i + 1] == op_file, \
    "a builder on hub_token+operator must carry the operator file: %r" % got
PY
    fail "#1397 AC10c: the builder add must carry the operator file"
  echo "PASS 1397-lanes AC10c: the builder chain still prefers the operator credential"

  # -- #1397 assertion-RED mutants -----------------------------------------
  # M1: the builder gate back to worker-only — the mapped builder spawn then
  # registers nothing and answers UNREGISTERED, exactly what AC1a rejects.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-workergate \
    '  [[ "$ROLE" == worker || "$ROLE" == builder ]] || return 0' \
    '  [[ "$ROLE" == worker ]] || return 0'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-workergate" \
    LANES_CFG_OVERRIDE="$LANES_CFG" LANES_MODEL=builder-sol HERDR_SESSION=default \
    lanes_spawn b1397-m1 --role builder --lane b1397-m1 --parent director-x
  if [[ -s "$LANES_CALLS" ]]; then
    fail "#1397 M1 mutant survived: the builder lane was still registered"
  fi
  grep -q ' lane=UNREGISTERED$' "$LANES_OUT" ||
    fail "#1397 M1: a skipped builder registration must still be loud"
  echo "PASS 1397-lanes M1: reverting the gate to worker-only goes RED"

  # M2: operator_token_env dropped from the credential chain — the
  # operator-only config can then never register, and AC1a's argv
  # assertion goes RED.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-noop \
    '  if [[ "$role" == builder && -z "$v" ]]; then
    v="$(spillover_value hub operator_token_env 2>/dev/null || true)"
  fi' \
    '  :'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-noop" \
    LANES_CFG_OVERRIDE="$LANES_CFG_OP" LANES_MODEL=builder-sol \
    lanes_spawn b1397-m2 --role builder --lane b1397-m2 --parent director-x
  if [[ -s "$LANES_CALLS" ]]; then
    fail "#1397 M2 mutant survived: the operator credential still authorized lanes"
  fi
  echo "PASS 1397-lanes M2: ignoring operator_token_env goes RED"

  # M3: the remote add registers against the wrong machine id — the argv
  # the fixture records then carries a machine that is not the host key.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-wrongmachine \
    '  args=(lanes add "$lane" --machine "$host" --pane "$pane" --parent "$parent"' \
    '  args=(lanes add "$lane" --machine "wrong-$host" --pane "$pane" --parent "$parent"'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-wrongmachine" \
    t1397_remote_spawn b1397-m3
  if ! grep -qxF 'wrong-desktop' "$T1397_CALLS"; then
    fail "#1397 M3 mutant survived: the remote add still used the host key"
  fi
  echo "PASS 1397-lanes M3: a wrong remote machine id goes RED"

  # M4: reap without the machine+pane check sweeps a row that belongs to a
  # different pane — the guard every reap assertion above leans on.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-blindrm \
    '        if machine == want_machine and pane == want_pane:' \
    '        if True:'
  lanes_reap_job j1397-m4 w1:p15 w1:t15 own-1397m4 lane-1397-m4 lbl-1397m4 mac-personal builder
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-blindrm" \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1397-m4","machine":"mac-personal","pane":"w1:p99","parent":"x","sink":false}]}' \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_OP" \
    lanes_reap_run m4 --lane own-1397m4 --apply --include-builders
  if [[ ! -f "$LANES_RM_LOG" ]] || ! grep -qxF 'rm' "$LANES_RM_LOG"; then
    fail "#1397 M4 mutant survived: a moved row was not swept"
  fi
  echo "PASS 1397-lanes M4: dropping the machine+pane reap check goes RED"

  # M5: --lane-defer forwarded for workers again — the wire flag alone mutes
  # the execution host's own session_machine_ids check, so AC2d's "no
  # --lane-defer in the delegated argv" assertion goes RED the moment the
  # flag leaks back in.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-deferall \
    '  [[ "$remote_lane_role" == builder ]] && remote_args+=("--lane-defer" "$host")' \
    '  remote_args+=("--lane-defer" "$host")'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-deferall" \
    T1397_CFG_OVERRIDE="$LANES_CFG_REMOTE_WMAP" \
    t1397_remote_worker w1397-m5 --owner work-kairos
  if ! grep -q -- '--lane-defer' "$T1397_SSH"; then
    fail "#1397 M5 mutant survived: the worker spawn carried no --lane-defer"
  fi
  echo "PASS 1397-lanes M5: forwarding --lane-defer to a worker goes RED"

  # M6: the initiator registers a remote worker — the harmful half of the
  # review finding: the worker lane then lands on machine=<host key>, which
  # AC2d's add-argv assertion rejects.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-workeradd \
    '  if [[ "$remote_lane_role" == builder && -n "$remote_lane_name" ]]; then' \
    '  if [[ -n "$remote_lane_name" ]]; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-workeradd" \
    T1397_CFG_OVERRIDE="$LANES_CFG_REMOTE_WMAP" \
    t1397_remote_worker w1397-m6 --owner work-kairos
  if ! grep -qxF 'desktop' "$T1397_CALLS"; then
    fail "#1397 M6 mutant survived: no worker lane was added on machine=desktop"
  fi
  echo "PASS 1397-lanes M6: registering a remote worker on the initiator goes RED"

  # M7: the remote add dropping back to the shared lane credential chain —
  # a node-scoped lanes token then "wins" a cross-machine write that only
  # the operator credential can authorize, and AC2f's argv check goes RED.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-remoteop \
    '  token_env="$(spillover_value hub operator_token_env 2>/dev/null || true)"
  [[ -n "$token_env" ]] || token_env="$(hub_lanes_credential builder 2>/dev/null || true)"' \
    '  token_env="$(hub_lanes_credential builder 2>/dev/null || true)"'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-remoteop" \
    T1397_CFG_OVERRIDE="$LANES_CFG_REMOTE_BOTH" \
    t1397_remote_spawn b1397-m7
  python3 - "$T1397_CALLS" "$LANES_TOKEN_FILE" <<'PY' ||
import sys
log, lanes_file = sys.argv[1:]
got = open(log, encoding="utf-8").read().splitlines()
i = got.index("--hub-token-env")
assert got[i + 1] == lanes_file, \
    "the mutant must reach panewire with the lanes token (divergence shown): %r" % got
PY
    fail "#1397 M7 mutant survived: the remote add still preferred the operator credential"
  echo "PASS 1397-lanes M7: shared-chain credential order on the remote add goes RED"

  # M8: the rc-0 gate back on the settle block (tester B1/mu06-shaped): an
  # OK-line-plus-nonzero remote then keeps its unconfirmed lane=fixture@
  # through, which AC2g rejects on BOTH halves — no add ran, and the field
  # was never rewritten.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-r0gate \
    '    if [[ -n "$remote_pane" ]]; then' \
    '    if [[ "$rc" -eq 0 && -n "$remote_pane" ]]; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-r0gate" \
    T1397_SSH_SCENARIO=remote-ok-nonzero T1397_REMOTE_RC=76 \
    t1397_remote_spawn b1397-m8
  if [[ -s "$T1397_CALLS" ]] || ! grep -q 'fixture@desktop' "$T1397_OUT"; then
    fail "#1397 M8 mutant survived: the rc 76 lane was still settled"
  fi
  echo "PASS 1397-lanes M8: restoring the rc-0 settle gate goes RED"

  # M9: machine_id fallback applied to workers (tester mu02) — a worker
  # whose session misses the map then registers on the host's own machine
  # id, which AC6's zero-calls assertion rejects.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-workmachine \
    '  if [[ -z "$machine" && "$ROLE" == builder ]]; then' \
    '  if [[ -z "$machine" ]]; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-workmachine" \
    LANES_CFG_OVERRIDE="$LANES_CFG_OTHERMAP" HERDR_SESSION=default \
    lanes_spawn w1397-m9 --owner work-kairos
  if [[ ! -s "$LANES_CALLS" ]]; then
    fail "#1397 M9 mutant survived: the worker still did not register"
  fi
  echo "PASS 1397-lanes M9: the machine_id fallback reaching workers goes RED"

  # M10: 82 out of the auto-router stop set (tester mu09) — the strict
  # remote answer then falls through and the job double-spawns on mac-work,
  # which AC7's no-mac-work assertion rejects.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-stopset \
    '    case "$last_rc" in
      2|"$WRK_EXIT_ACTIVE_JOB_DUPLICATE"|"$WRK_EXIT_JOB_STATE_UNREADABLE"|"$WRK_EXIT_LANE_UNREGISTERED")' \
    '    case "$last_rc" in
      2|"$WRK_EXIT_ACTIVE_JOB_DUPLICATE"|"$WRK_EXIT_JOB_STATE_UNREADABLE")'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-stopset" \
    T1397_HOST=auto T1397_CFG_OVERRIDE="$LANES_CFG_REMOTE_AUTO" \
    T1397_LOAD_FILE="$T1397_LOAD_HIGH" \
    T1397_SSH_SCENARIO_DESKTOP=remote-die-stderr T1397_REMOTE_RC=82 \
    t1397_remote_spawn b1397-m10
  if ! grep -q 'mac-work.*wrk spawn' "$T1397_SSH"; then
    fail "#1397 M10 mutant survived: mac-work was never double-spawned"
  fi
  echo "PASS 1397-lanes M10: removing 82 from the auto stop set goes RED"

  # M11: 82 out of the transport normalizer (tester mu10) — a transport-leg
  # 82 then reads as an admission answer and stops the round, which AC8's
  # mac-work-win assertion rejects.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-transport82 \
    '    2|"$WRK_EXIT_ACTIVE_JOB_DUPLICATE"|"$WRK_EXIT_JOB_STATE_UNREADABLE"|"$WRK_EXIT_CONFIG_REFUSED"|"$WRK_EXIT_LANE_UNREGISTERED") printf '"'"'1'"'"' ;;' \
    '    2|"$WRK_EXIT_ACTIVE_JOB_DUPLICATE"|"$WRK_EXIT_JOB_STATE_UNREADABLE"|"$WRK_EXIT_CONFIG_REFUSED") printf '"'"'1'"'"' ;;'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-transport82" \
    T1397_HOST=auto T1397_CFG_OVERRIDE="$LANES_CFG_REMOTE_AUTO" \
    T1397_LOAD_FILE="$T1397_LOAD_HIGH" \
    T1397_SSH_CALL_COUNT_FILE="$TMP/t1397-ssh-count-m11" \
    T1397_SSH_FAIL_CALLS=1 T1397_SSH_FAIL_CODE=82 \
    t1397_remote_spawn b1397-m11
  if [[ "$T1397_RC" -eq 0 ]]; then
    fail "#1397 M11 mutant survived: the transport 82 still normalized"
  fi
  echo "PASS 1397-lanes M11: a transport leg keeping 82 goes RED"

  # M12: WRK_LANE_STRICT applied to workers (tester mu11) — an unregistered
  # worker then answers 82, which AC9's rc-0 assertion rejects.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-strictworker \
    '  if [[ "$ROLE" == builder && -z "${HUB_LANE:-}" && "${WRK_LANE_STRICT:-0}" == 1 ]]; then' \
    '  if [[ -z "${HUB_LANE:-}" && "${WRK_LANE_STRICT:-0}" == 1 ]]; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-strictworker" \
    WRK_LANE_STRICT=1 LANES_CFG_OVERRIDE="$LANES_CFG_NOCRED" \
    lanes_spawn w1397-m12 --owner work-kairos
  if [[ "$LANES_RC" -ne 82 ]]; then
    fail "#1397 M12 mutant survived: the worker did not answer 82"
  fi
  echo "PASS 1397-lanes M12: strict reaching workers goes RED"

  # M13: re-widening the worker credential chain (tester B1-r4) — letting a
  # worker lane read operator_token_env again. Register side: the
  # operator-only worker spawn must now call lanes add, which AC10b's
  # zero-call assertion would reject on the fixed code.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1397-widerworker \
    '  if [[ "$role" == builder && -z "$v" ]]; then' \
    '  if [[ -z "$v" ]]; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-widerworker" \
    LANES_CFG_OVERRIDE="$LANES_CFG_OP_MAP" HERDR_SESSION=default \
    lanes_spawn w1397-m13 --owner work-kairos
  if [[ ! -s "$LANES_CALLS" ]]; then
    fail "#1397 M13 mutant survived: the worker still ignores operator_token_env"
  fi
  # Reap side: a worker lane receipt reaped on the same operator-only
  # config must now run ls+rm where the fixed code warns and skips. The
  # pane/tab pair must be one the herdr fixture's tab list carries —
  # a tab the list does not know is a tab-count-unknown skip, and the
  # removal never runs at all.
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox-m13"
  lanes_reap_job j1397-m13 w1:p16 w1:t16 own-1397m13 lane-1397-m13 lbl-1397m13 mac-work-default
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1397-widerworker" \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1397-m13","machine":"mac-work-default","pane":"w1:p16","parent":"work-kairos","sink":false}]}' \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_OP_MAP" \
    lanes_reap_run m13 --lane own-1397m13 --apply
  if [[ ! -f "$LANES_RM_LOG" ]] || ! grep -qxF 'rm' "$LANES_RM_LOG"; then
    fail "#1397 M13 mutant survived: the worker reap still skips operator_token_env"
  fi
  echo "PASS 1397-lanes M13: re-widening the worker chain goes RED (register + reap)"

  # ------------------------------------------------------------------
  # hk 1446 — a remote --host builder whose execution host holds a lanes
  # token bound to the deferred machine id registers its own hub lane: the
  # remote wrk runs `lanes add` itself, marks its OK line
  # lane_registered=self, and the initiator skips its add. Every other
  # shape defers exactly as before.
  # ------------------------------------------------------------------
  # AC1 — the execution host holds a matching lanes token: exactly one
  # `lanes add` runs on THIS side of the defer, carrying the lanes file
  # (never the operator credential the same config also holds), the
  # deferred machine id, the spawned pane and --parent. The OK line ends
  # with lane=L@HOST lane_registered=self and the receipt records the same
  # lane+machine the deferral would have.
  LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_SELF" \
    lanes_spawn b1446-self --role builder --lane b1446-self --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1446 AC1: self-registering deferred spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" "$LANES_NODE_DESKTOP_FILE" "$LANES_OP_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, lanes_file, op_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
want = ["add", "b1446-self", "--machine", "desktop", "--pane", "w:p1",
        "--parent", "director-x", "--hub-url", "https://hub.invalid",
        "--hub-token-env", lanes_file, "--hub-cf-env", cf_file, "--"]
assert got == want, "self-registration argv mismatch: got=%r want=%r" % (got, want)
assert op_file not in got, "operator_token_env must never reach the remote side: %r" % got
PY
    fail "#1446 AC1: the self-add must run once with the lanes token, never the operator file"
  grep -q ' lane=b1446-self@desktop lane_registered=self$' "$LANES_OUT" ||
    fail "#1446 AC1: the OK line must end lane=L@desktop lane_registered=self: $(cat "$LANES_OUT")"
  lanes_spawned_payload b1446-self | python3 -c '
import json, sys
meta = json.loads(sys.stdin.read())
assert meta["hub_lane"] == "b1446-self" and meta["hub_lane_machine"] == "desktop", meta' ||
    fail "#1446 AC1: the receipt must still record lane+deferred machine"
  echo "PASS 1446-lanes AC1: a matching lanes token self-registers the deferred builder lane"

  # AC2 — the token's HUB_MACHINE_ID names another machine (or only differs
  # by case/whitespace): identical to no token at all — zero lanes calls,
  # no marker, no warning, and the receipt still records the deferral.
  LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_MISMATCH" \
    lanes_spawn b1446-mism --role builder --lane b1446-mism --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1446 AC2: a mismatched-token deferred spawn must still succeed (rc=$LANES_RC)"
  lanes_assert_no_lanes_call b1446-mism
  grep -q ' lane=b1446-mism@desktop$' "$LANES_OUT" ||
    fail "#1446 AC2: the deferred OK line must be unchanged: $(cat "$LANES_OUT")"
  ! grep -q 'lane_registered' "$LANES_OUT" ||
    fail "#1446 AC2: no marker may appear on a mismatched token"
  ! grep -q 'self-registration' "$LANES_ERR" ||
    fail "#1446 AC2: a mismatch defers silently: $(cat "$LANES_ERR")"
  lanes_spawned_payload b1446-mism | python3 -c '
import json, sys
meta = json.loads(sys.stdin.read())
assert meta["hub_lane"] == "b1446-mism" and meta["hub_lane_machine"] == "desktop", meta' ||
    fail "#1446 AC2: the receipt must still record the deferred lane"
  LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_CASE" \
    lanes_spawn b1446-case --role builder --lane b1446-case --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 0 ]] || fail "#1446 AC2: a case-mismatched token spawn failed"
  lanes_assert_no_lanes_call b1446-case
  ! grep -q 'lane_registered' "$LANES_OUT" ||
    fail "#1446 AC2: the machine-id compare must be byte-exact"
  LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_SPACE" \
    lanes_spawn b1446-space --role builder --lane b1446-space --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 0 ]] || fail "#1446 AC2: a whitespace-mismatched token spawn failed"
  lanes_assert_no_lanes_call b1446-space
  ! grep -q 'lane_registered' "$LANES_OUT" ||
    fail "#1446 AC2: a trailing space in HUB_MACHINE_ID must not be trimmed into a match"
  echo "PASS 1446-lanes AC2: a lanes token naming another machine defers byte-exactly"

  # AC3 — no lanes token at all (operator credential only): byte-for-byte
  # today's behavior — zero lanes calls, lane=L@HOST ending the OK line,
  # the deferred receipt. A tester role carrying the flag is refused
  # outright, so a non-builder seat can never self-register either.
  LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_OP" \
    lanes_spawn b1446-notok --role builder --lane b1446-notok --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1446 AC3: a tokenless deferred spawn must succeed (rc=$LANES_RC)"
  lanes_assert_no_lanes_call b1446-notok
  grep -q ' lane=b1446-notok@desktop$' "$LANES_OUT" ||
    fail "#1446 AC3: the OK line must be identical to today's: $(cat "$LANES_OUT")"
  # An operator file that DOES carry HUB_MACHINE_ID still cannot
  # self-register: only lanes_token_env counts on the remote side.
  LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_OPID" \
    lanes_spawn b1446-opid --role builder --lane b1446-opid --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1446 AC3: an operator-credential spawn must succeed (rc=$LANES_RC)"
  lanes_assert_no_lanes_call b1446-opid
  ! grep -q 'lane_registered' "$LANES_OUT" ||
    fail "#1446 AC3: operator_token_env must never self-register"
  # A tester seat can never self-register either: --lane-defer is
  # builder-only even on a host holding a matching token.
  HERDR_SESSION=default LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_SELF" \
    lanes_spawn t1446-self --role tester --owner work-kairos --lane-defer desktop
  [[ "$LANES_RC" -eq 2 ]] ||
    fail "#1446 AC3: --lane-defer on a tester must refuse rc 2 (rc=$LANES_RC): $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call t1446-self
  echo "PASS 1446-lanes AC3: no lanes token keeps the deferral byte-identical"

  # AC4 — the self-add is refused by panewire: exactly one warning naming
  # the failure, the deferral stands (receipt + OK line unchanged), the
  # spawn still answers 0. The initiator then adds the lane as today.
  WRK_PANEWIRE_LANES_RC=5 LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_SELF" \
    lanes_spawn b1446-addfail --role builder --lane b1446-addfail --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1446 AC4: a refused self-add must never fail the spawn (rc=$LANES_RC)"
  [[ "$(grep -cxF 'add' "$LANES_CALLS")" -eq 1 ]] ||
    fail "#1446 AC4: the self-add must still be attempted once: $(cat "$LANES_CALLS")"
  [[ "$(grep -c 'self-registration failed' "$LANES_ERR")" -eq 1 ]] ||
    fail "#1446 AC4: exactly one self-registration warning expected: $(cat "$LANES_ERR")"
  grep -q ' lane=b1446-addfail@desktop$' "$LANES_OUT" ||
    fail "#1446 AC4: a failed self-add falls back to the plain deferral: $(cat "$LANES_OUT")"
  echo "PASS 1446-lanes AC4: a refused self-add warns once and defers"

  # AC5 — the initiator half: the remote OK pane= line carries
  # lane_registered=self, so THIS host runs zero lanes calls and still
  # emits lane=L@HOST. The consumed marker never reaches the operator's
  # line. The stub answers the spawn leg itself and delegates every other
  # leg to the shared fixture.
  T1446_SSH_SELFREG="$TMP/t1446-ssh-selfreg"
  cat >"$T1446_SSH_SELFREG" <<'SH'
#!/usr/bin/env bash
remote="${*: -1}"
if [[ "$remote" == *'wrk spawn'* ]]; then
  printf '%s\n' "$*" >>"${WRK_SSH_LOG:?}"
  printf 'OK pane=desktop:p7 host=local model=builder-sol label=fixture status=working landed=yes job=fixture lane=fixture@desktop lane_registered=self\n'
  exit "${WRK_REMOTE_RC:-0}"
fi
exec "${T1446_FIXTURE_SSH:?}" "$@"
SH
  chmod +x "$T1446_SSH_SELFREG"
  T1446_FIXTURE_SSH="$ROOT/tests/fixtures/spillover-ssh" T1397_SSH_BIN="$T1446_SSH_SELFREG" \
    t1397_remote_spawn b1446-initskip
  [[ "$T1397_RC" -eq 0 ]] ||
    fail "#1446 AC5: a self-registered remote spawn failed (rc=$T1397_RC): $(cat "$T1397_ERR")"
  [[ ! -s "$T1397_CALLS" ]] ||
    fail "#1446 AC5: the initiator must make zero lanes calls after lane_registered=self: $(cat "$T1397_CALLS")"
  grep -q ' lane=b1446-initskip@desktop$' "$T1397_OUT" ||
    fail "#1446 AC5: the emitted line must keep lane=L@desktop: $(cat "$T1397_OUT")"
  ! grep -q 'lane_registered' "$T1397_OUT" ||
    fail "#1446 AC5: the consumed marker must not reach the emitted line: $(cat "$T1397_OUT")"
  echo "PASS 1446-lanes AC5: lane_registered=self skips the initiator add"

  # AC6 — a forged marker never counts: the same text on a non-OK stdout
  # line and inside an OK-line field VALUE leaves the initiator's add
  # untouched. Only the OK pane= line's own lane_registered=self field is
  # the remote's word.
  T1446_SSH_FORGED="$TMP/t1446-ssh-forged"
  cat >"$T1446_SSH_FORGED" <<'SH'
#!/usr/bin/env bash
remote="${*: -1}"
if [[ "$remote" == *'wrk spawn'* ]]; then
  printf '%s\n' "$*" >>"${WRK_SSH_LOG:?}"
  printf 'lane_registered=self\n'
  printf 'wrk: note: lane_registered=self in a warning-shaped line\n'
  printf 'OK pane=desktop:p7 host=local model=builder-sol label=lane_registered=self-ish status=working landed=yes job=fixture note=lane_registered=self lane=fixture@desktop\n'
  exit 0
fi
exec "${T1446_FIXTURE_SSH:?}" "$@"
SH
  chmod +x "$T1446_SSH_FORGED"
  T1446_FIXTURE_SSH="$ROOT/tests/fixtures/spillover-ssh" T1397_SSH_BIN="$T1446_SSH_FORGED" \
    t1397_remote_spawn b1446-forged
  [[ "$T1397_RC" -eq 0 ]] ||
    fail "#1446 AC6: the forged-marker spawn failed (rc=$T1397_RC): $(cat "$T1397_ERR")"
  grep -qxF 'add' "$T1397_CALLS" ||
    fail "#1446 AC6: a forged marker must not suppress the initiator add: $(cat "$T1397_CALLS")"
  grep -q ' lane=b1446-forged@desktop$' "$T1397_OUT" ||
    fail "#1446 AC6: the confirmed add keeps lane=L@desktop: $(cat "$T1397_OUT")"
  echo "PASS 1446-lanes AC6: only the OK line's own marker field counts"

  # AC7 — WRK_LANE_STRICT=1: a self-registered lane is confirmed, so the
  # strict gate must not fire.
  WRK_LANE_STRICT=1 \
    T1446_FIXTURE_SSH="$ROOT/tests/fixtures/spillover-ssh" T1397_SSH_BIN="$T1446_SSH_SELFREG" \
    t1397_remote_spawn b1446-strict
  [[ "$T1397_RC" -eq 0 ]] ||
    fail "#1446 AC7: a self-registered lane must not strict-exit (rc=$T1397_RC): $(cat "$T1397_ERR")"
  grep -q ' lane=b1446-strict@desktop$' "$T1397_OUT" ||
    fail "#1446 AC7: the emitted line must keep lane=L@desktop: $(cat "$T1397_OUT")"
  echo "PASS 1446-lanes AC7: WRK_LANE_STRICT accepts a self-registered lane"

  # AC8 — reap on the execution host removes the self-registered lane
  # through the same machine+pane guard, carrying the node lanes token the
  # builder chain resolves first.
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox-1446"
  lanes_reap_job j1446-reap w1:p14 w1:t14 b1446-x lane-1446-self lbl-1446 desktop builder
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-1446-self","machine":"desktop","pane":"w1:p14","parent":"director-x","sink":false}]}' \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_DEFER_SELF" \
    lanes_reap_run 1446-reap --lane b1446-x --apply --include-builders
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1446 AC8: apply failed: $(cat "$LANES_REAP_ERR")"
  t1438_assert_rm_chain "$LANES_RM_LOG" "$LANES_NODE_DESKTOP_FILE" "$LANES_OP_FILE" lane-1446-self ||
    fail "#1446 AC8: reap must remove the self-registered lane with its lanes token"
  echo "PASS 1446-lanes AC8: reap removes a self-registered lane with the lanes token"

  # M1 'the machine-id equality check guards the self-add': dropping it
  # lets a token bound to another machine self-register — AC2's zero-call
  # assertion would then go RED.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1446-nomatch \
    '  [[ "$lanes_machine" == "$LANE_DEFER" ]] || return 1' \
    '  :'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1446-nomatch" \
    LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_MISMATCH" \
    lanes_spawn b1446-m1 --role builder --lane b1446-m1 --parent director-x --lane-defer desktop
  if [[ ! -s "$LANES_CALLS" ]]; then
    fail "#1446 M1 mutant survived: the mismatched token still defers"
  fi
  echo "PASS 1446-lanes M1: dropping the machine-id check goes RED"

  # M2 'the remote side never reads operator_token_env': a mutant that
  # falls back to the operator file self-registers on a tokenless host —
  # AC3's zero-call assertion would then go RED.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1446-opcred \
    '  [[ -n "$lanes_env" ]] || return 1' \
    '  [[ -n "$lanes_env" ]] || lanes_env="$(spillover_value hub operator_token_env 2>/dev/null || true)"
  [[ -n "$lanes_env" ]] || return 1'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1446-opcred" \
    LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_OPID" \
    lanes_spawn b1446-m2 --role builder --lane b1446-m2 --parent director-x --lane-defer desktop
  if [[ ! -s "$LANES_CALLS" ]]; then
    fail "#1446 M2 mutant survived: operator_token_env still cannot self-register"
  fi
  echo "PASS 1446-lanes M2: an operator fallback on the remote goes RED"

  # M3 'the initiator honors the marker': a mutant that ignores
  # lane_registered=self adds the lane a second time — AC5's zero-call
  # assertion would then go RED.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1446-nomarker \
    '      if [[ "$remote_selfreg" == yes ]]; then' \
    '      if false; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1446-nomarker" \
    T1446_FIXTURE_SSH="$ROOT/tests/fixtures/spillover-ssh" T1397_SSH_BIN="$T1446_SSH_SELFREG" \
    t1397_remote_spawn b1446-m3
  if [[ ! -s "$T1397_CALLS" ]]; then
    fail "#1446 M3 mutant survived: the initiator still skips the marked lane"
  fi
  echo "PASS 1446-lanes M3: ignoring the self-registration marker goes RED"

  # B1 AC1 — the execution host only self-registers once it has a durable
  # arbiter job record. A missing arbiter leaves the existing deferred lane
  # outcome unchanged: no remote lanes add and no lane_registered marker.
  LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_SELF" \
    LANES_ARBITER_BIN="$TMP/absent-arbiter-b1446" \
    lanes_spawn b1446-nojob --role builder --lane b1446-nojob --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1446 B1 AC1: a missing arbiter must not fail the deferred spawn (rc=$LANES_RC)"
  lanes_assert_no_lanes_call b1446-nojob
  grep -q ' lane=b1446-nojob@desktop$' "$LANES_OUT" ||
    fail "#1446 B1 AC1: no-job deferral must keep the ordinary lane field: $(cat "$LANES_OUT")"
  ! grep -q 'lane_registered=self' "$LANES_OUT" ||
    fail "#1446 B1 AC1: a deferred lane without a job receipt must not self-register"
  echo "PASS 1446 B1 AC1: no arbiter job record keeps the remote deferral"

  # B1 AC2 — if the self-add succeeds but job.spawned fails, compensate
  # through the same builder credential chain and machine+pane guard before
  # returning rc 2. The stateful fixture marks the row on add and deletes it
  # only after the guarded rm succeeds.
  T1446_SELF_LANE_STATE="$TMP/t1446-self-lane-state"
  T1446_STATEFUL_PANEWIRE="$TMP/t1446-stateful-panewire"
  cat >"$T1446_STATEFUL_PANEWIRE" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
fixture="${LANES_PANEWIRE_FIXTURE:?}"
state="${LANES_PANEWIRE_STATE:?}"
lane="${LANES_PANEWIRE_LANE:?}"
if [[ "${1:-}" == lanes && "${2:-}" == ls ]]; then
  if [[ -e "$state" ]]; then
    WRK_PANEWIRE_LANES_LS="{\"lanes\":[{\"lane\":\"$lane\",\"machine\":\"desktop\",\"pane\":\"w:p1\",\"parent\":\"director-x\",\"sink\":false}]}"
  else
    WRK_PANEWIRE_LANES_LS='{"lanes":[]}'
  fi
  export WRK_PANEWIRE_LANES_LS
fi
set +e
"$fixture" "$@"
rc=$?
set -e
if [[ "$rc" -eq 0 && "${1:-}" == lanes && "${2:-}" == add ]]; then : >"$state"; fi
if [[ "$rc" -eq 0 && "${1:-}" == lanes && "${2:-}" == rm ]]; then rm -f "$state"; fi
exit "$rc"
SH
  chmod +x "$T1446_STATEFUL_PANEWIRE"
  LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_SELF" \
    LANES_ARBITER_BIN="$T1397_FAIL_ARBITER" PANEWIRE="$T1446_STATEFUL_PANEWIRE" \
    LANES_PANEWIRE_FIXTURE="$ROOT/tests/fixtures/panewire" \
    LANES_PANEWIRE_STATE="$T1446_SELF_LANE_STATE" \
    LANES_PANEWIRE_LANE=b1446-receipt \
    lanes_spawn b1446-receipt --role builder --lane b1446-receipt --parent director-x --lane-defer desktop
  PANEWIRE="$ROOT/tests/fixtures/panewire"
  [[ "$LANES_RC" -eq 2 ]] ||
    fail "#1446 B1 AC2: a deferred receipt failure must answer 2 (rc=$LANES_RC): $(cat "$LANES_ERR")"
  if grep -q '^OK pane=' "$LANES_OUT"; then
    fail "#1446 B1 AC2: no OK line may survive a failed deferred receipt: $(cat "$LANES_OUT")"
  fi
  [[ ! -e "$T1446_SELF_LANE_STATE" ]] ||
    fail "#1446 B1 AC2: the guarded self-add compensation must remove the fixture row"
  python3 - "$LANES_CALLS" "$LANES_NODE_DESKTOP_FILE" <<'PY' ||
import sys
log, token = sys.argv[1:]
rows = open(log, encoding="utf-8").read().splitlines()
calls, call = [], []
for row in rows:
    if row == "--":
        calls.append(call)
        call = []
    else:
        call.append(row)
assert [args[0] for args in calls] == ["add", "ls", "rm"], calls
add, listing, remove = calls
assert add[1] == "b1446-receipt", add
assert add[add.index("--machine") + 1] == "desktop", add
assert add[add.index("--pane") + 1] == "w:p1", add
assert remove[1] == "b1446-receipt", remove
assert all(args[args.index("--hub-token-env") + 1] == token for args in calls), calls
PY
    fail "#1446 B1 AC2: one lanes-token add must be followed by guarded ls+rm"
  echo "PASS 1446 B1 AC2: receipt failure removes the self-added guarded row"

  # B1 AC3 — exercise the receipt-payload preparation failure before the
  # arbiter event call. It must use the same guarded compensation as an event
  # write failure.
  T1446_PYTHON_DIR="$TMP/t1446-python"
  T1446_FAIL_PYTHON="$T1446_PYTHON_DIR/python3"
  T1446_REAL_PYTHON="$(command -v python3)"
  mkdir -p "$T1446_PYTHON_DIR"
  cat >"$T1446_FAIL_PYTHON" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
real_python="${WRK_T1446_REAL_PYTHON:?}"
if [[ "${1:-}" == "-" ]]; then
  script="$(mktemp)"
  cat >"$script"
  if grep -qF 'pane_id, label, profile, workspace, tab_id, keep, task_id, hub_lane, hub_lane_machine, lane_role = sys.argv[1:]' "$script"; then
    rm -f "$script"
    exit 1
  fi
  set +e
  "$real_python" "$@" <"$script"
  rc=$?
  set -e
  rm -f "$script"
  exit "$rc"
fi
exec "$real_python" "$@"
SH
  chmod +x "$T1446_FAIL_PYTHON"
  LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_SELF" \
    LANES_ARBITER_BIN="$ARBITER" PANEWIRE="$T1446_STATEFUL_PANEWIRE" \
    LANES_PANEWIRE_FIXTURE="$ROOT/tests/fixtures/panewire" \
    LANES_PANEWIRE_STATE="$T1446_SELF_LANE_STATE" \
    LANES_PANEWIRE_LANE=b1446-prep-fail \
    WRK_T1446_REAL_PYTHON="$T1446_REAL_PYTHON" PATH="$T1446_PYTHON_DIR:$PATH" \
    lanes_spawn b1446-prep-fail --role builder --lane b1446-prep-fail --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 2 ]] ||
    fail "#1446 B1 AC3: receipt preparation failure must answer 2 (rc=$LANES_RC): $(cat "$LANES_ERR")"
  [[ ! -e "$T1446_SELF_LANE_STATE" ]] ||
    fail "#1446 B1 AC3: preparation failure must remove the self-added fixture row"
  python3 - "$LANES_CALLS" "$LANES_NODE_DESKTOP_FILE" <<'PY' ||
import sys
log, token = sys.argv[1:]
rows = open(log, encoding="utf-8").read().splitlines()
calls, call = [], []
for row in rows:
    if row == "--":
        calls.append(call)
        call = []
    else:
        call.append(row)
assert [args[0] for args in calls] == ["add", "ls", "rm"], calls
assert all(args[args.index("--hub-token-env") + 1] == token for args in calls), calls
PY
    fail "#1446 B1 AC3: preparation failure must add then guardedly remove with the lanes token"
  echo "PASS 1446 B1 AC3: receipt preparation failure compensates the self-add"

  # Mutant B1 M1 — drop the job-record gate. AC1 then observes a remote add
  # despite the missing receipt.
# shellcheck disable=SC2016 # these literals are bin/wrk source anchors
  devin_trust_mutant lanes-1446-no-job-gate \
    '      if [[ "$ROLE" == builder && "${ARBITER_JOB_REGISTERED:-0}" -eq 1 ]] &&
         hub_lane_self_register; then' \
    '      if [[ "$ROLE" == builder ]] &&
         hub_lane_self_register; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1446-no-job-gate" \
    LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_SELF" \
    LANES_ARBITER_BIN="$TMP/absent-arbiter-b1446-mut" \
    lanes_spawn b1446-m1-job --role builder --lane b1446-m1-job --parent director-x --lane-defer desktop
  if [[ ! -s "$LANES_CALLS" ]]; then
    fail "#1446 B1 M1 mutant survived: dropping the job-record gate still deferred"
  fi
  echo "PASS 1446 B1 M1: dropping the job-record gate goes RED"

  # Mutant B1 M2 — skip removal for a self-registered deferred lane. AC2's
  # stateful fixture then retains the unreceipted row.
# shellcheck disable=SC2016 # this literal is a bin/wrk source anchor
  devin_trust_mutant lanes-1446-skip-self-rm \
    '    [[ "${HUB_LANE_SELF:-0}" -eq 1 ]] || return 0' \
    '    return 0'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1446-skip-self-rm" \
    LANES_MODEL=builder-sol LANES_CFG_OVERRIDE="$LANES_CFG_DEFER_SELF" \
    LANES_ARBITER_BIN="$T1397_FAIL_ARBITER" PANEWIRE="$T1446_STATEFUL_PANEWIRE" \
    LANES_PANEWIRE_FIXTURE="$ROOT/tests/fixtures/panewire" \
    LANES_PANEWIRE_STATE="$T1446_SELF_LANE_STATE" \
    LANES_PANEWIRE_LANE=b1446-receipt \
    lanes_spawn b1446-m2-rm --role builder --lane b1446-receipt --parent director-x --lane-defer desktop
  if [[ ! -e "$T1446_SELF_LANE_STATE" ]]; then
    fail "#1446 B1 M2 mutant survived: skipping guarded rm still removed the lane"
  fi
  rm -f "$T1446_SELF_LANE_STATE"
  echo "PASS 1446 B1 M2: skipping self-add compensation goes RED"

  # ------------------------------------------------------------------
  # #1438 — reap resolves a lane's credential chain from the role that
  # registered it (the job.spawned receipt's lane_role), not from the
  # cumulative claim role: a job id first claimed as builder, released and
  # reused by a worker spawn must never lose its worker lane to the
  # operator credential
  # ------------------------------------------------------------------
  # AC1 — claim as builder, release, reclaim as worker: the cumulative role
  # is builder (so --include-builders is needed), but the receipt says the
  # lane is a worker lane. Both the ls confirmation and the rm carry the
  # hub_token file of the worker chain — never the operator credential the
  # same config also holds.
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox-1438"
  lanes_reap_reused_job j1438-reuse w1:p10 w1:t10 own-1438a lane-1438-reuse lbl-1438a mac-work-default worker
  WRK_PANEWIRE_LANES_LS="$(t1438_ls lane-1438-reuse mac-work-default w1:p10)" \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_WBOTH" \
    lanes_reap_run 1438-ac1 --lane own-1438a --apply --include-builders
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1438 AC1: apply failed: $(cat "$LANES_REAP_ERR")"
  grep -q '^closed job=j1438-reuse ' "$LANES_REAP_OUT" ||
    fail "#1438 AC1: the reused job must close: $(cat "$LANES_REAP_OUT")"
  t1438_assert_rm_chain "$LANES_RM_LOG" "$LANES_TOKEN_FILE" "$LANES_OP_FILE" lane-1438-reuse ||
    fail "#1438 AC1: a builder-then-worker job id must remove its worker lane with the hub_token file, never the operator credential"
  echo "PASS 1438-lanes AC1: a reused job id's worker lane is removed with the worker chain"

  # AC2 — the reverse: a builder spawn receipt (lane_role builder) keeps the
  # builder chain on the same config, so the narrower reading never reaches a
  # real builder lane. (AC1c pins the operator-only host.)
  lanes_reap_job j1438-bld w1:p11 w1:t11 own-1438b lane-1438-bld lbl-1438b mac-work-default builder
  WRK_PANEWIRE_LANES_LS="$(t1438_ls lane-1438-bld mac-work-default w1:p11)" \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_WBOTH" \
    lanes_reap_run 1438-ac2 --lane own-1438b --apply --include-builders
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1438 AC2: apply failed: $(cat "$LANES_REAP_ERR")"
  t1438_assert_rm_chain "$LANES_RM_LOG" "$LANES_OP_FILE" "$LANES_TOKEN_FILE" lane-1438-bld ||
    fail "#1438 AC2: a builder lane receipt must keep the operator credential"
  echo "PASS 1438-lanes AC2: a builder receipt still removes with the builder chain"

  # AC3 — a legacy receipt (hub_lane, no lane_role) is the worker chain even
  # when the claim says builder: on a host holding both credentials it takes
  # the hub_token file; on an operator-only host nothing is called, the
  # existing worker warning names the missing credential, and the job still
  # closes — the row stays for the lanes-missing audit.
  lanes_reap_job j1438-legacy w1:p12 w1:t12 own-1438c lane-1438-legacy lbl-1438c mac-work-default builder -
  WRK_PANEWIRE_LANES_LS="$(t1438_ls lane-1438-legacy mac-work-default w1:p12)" \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_WBOTH" \
    lanes_reap_run 1438-ac3a --lane own-1438c --apply --include-builders
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1438 AC3: legacy apply failed: $(cat "$LANES_REAP_ERR")"
  t1438_assert_rm_chain "$LANES_RM_LOG" "$LANES_TOKEN_FILE" "$LANES_OP_FILE" lane-1438-legacy ||
    fail "#1438 AC3: a legacy receipt must use the worker chain"
  lanes_reap_job j1438-legacy-op w1:p13 w1:t13 own-1438e lane-1438-legacy-op lbl-1438e mac-personal builder -
  WRK_PANEWIRE_LANES_LS="$(t1438_ls lane-1438-legacy-op mac-personal w1:p13)" \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_OP" \
    lanes_reap_run 1438-ac3b --lane own-1438e --apply --include-builders
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1438 AC3: legacy operator-only apply failed: $(cat "$LANES_REAP_ERR")"
  grep -q '^closed job=j1438-legacy-op ' "$LANES_REAP_OUT" ||
    fail "#1438 AC3: the legacy job must still close: $(cat "$LANES_REAP_OUT")"
  [[ ! -s "$LANES_RM_LOG" ]] ||
    fail "#1438 AC3: an operator-only host must not ls/rm a legacy lane: $(cat "$LANES_RM_LOG")"
  grep -q "hub lane 'lane-1438-legacy-op' not removed (hub_url missing or neither hub_token_env nor lanes_token_env set" "$LANES_REAP_ERR" ||
    fail "#1438 AC3: the existing worker warning must name the skipped removal: $(cat "$LANES_REAP_ERR")"
  echo "PASS 1438-lanes AC3: a legacy receipt takes the worker chain (operator-only host skips with the warning)"

  # AC4 — a respawned job carries two receipts for one lane: the newest one
  # owns the live lane, in both orders. builder-then-worker takes the worker
  # chain, worker-then-builder the builder chain.
  lanes_reap_reused_job j1438-respawn-w w1:p14 w1:t14 own-1438d lane-1438-respawn-w lbl-1438d mac-work-default builder worker
  WRK_PANEWIRE_LANES_LS="$(t1438_ls lane-1438-respawn-w mac-work-default w1:p14)" \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_WBOTH" \
    lanes_reap_run 1438-ac4a --lane own-1438d --apply --include-builders
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1438 AC4: respawn apply failed: $(cat "$LANES_REAP_ERR")"
  t1438_assert_rm_chain "$LANES_RM_LOG" "$LANES_TOKEN_FILE" "$LANES_OP_FILE" lane-1438-respawn-w ||
    fail "#1438 AC4: the newest (worker) receipt must win over the older builder one"
  lanes_reap_reused_job j1438-respawn-b w1:p15 w1:t15 own-1438f lane-1438-respawn-b lbl-1438f mac-work-default worker builder
  WRK_PANEWIRE_LANES_LS="$(t1438_ls lane-1438-respawn-b mac-work-default w1:p15)" \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_WBOTH" \
    lanes_reap_run 1438-ac4b --lane own-1438f --apply --include-builders
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#1438 AC4: respawn apply failed: $(cat "$LANES_REAP_ERR")"
  t1438_assert_rm_chain "$LANES_RM_LOG" "$LANES_OP_FILE" "$LANES_TOKEN_FILE" lane-1438-respawn-b ||
    fail "#1438 AC4: the newest (builder) receipt must win over the older worker one"
  echo "PASS 1438-lanes AC4: the newest job.spawned receipt decides the chain, in both orders"

  # AC5 — the receipt writer. lane_role is the normalized registration role,
  # and rides only with a hub_lane: a worker, a tester seat (leaf worker lane),
  # a builder and a --lane-defer builder (the remote execution host's path)
  # each record theirs; a spawn that registered no lane leaves the receipt
  # exactly as before.
  HERDR_SESSION=default lanes_spawn w1438-worker --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1438 AC5: worker spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  [[ "$(t1438_receipt_lane_role w1438-worker)" == worker ]] ||
    fail "#1438 AC5: a worker receipt must record lane_role worker"
  HERDR_SESSION=default lanes_spawn w1438-tester --owner work-kairos --role tester
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1438 AC5: tester spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  [[ "$(t1438_receipt_lane_role w1438-tester)" == worker ]] ||
    fail "#1438 AC5: a tester seat registers a worker lane and must record lane_role worker"
  LANES_CFG_OVERRIDE="$LANES_CFG_OP" LANES_MODEL=builder-sol \
    lanes_spawn b1438-builder --role builder --lane b1438-builder --parent director-x
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1438 AC5: builder spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  [[ "$(t1438_receipt_lane_role b1438-builder)" == builder ]] ||
    fail "#1438 AC5: a builder receipt must record lane_role builder"
  LANES_MODEL=builder-sol HERDR_SESSION=default \
    lanes_spawn b1438-defer --role builder --lane b1438-defer --parent director-x --lane-defer desktop
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1438 AC5: deferred builder spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  [[ "$(t1438_receipt_lane_role b1438-defer)" == builder ]] ||
    fail "#1438 AC5: a --lane-defer builder receipt must record lane_role builder"
  HERDR_SESSION=worker lanes_spawn w1438-nolane --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#1438 AC5: unmapped worker spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  lanes_spawned_payload w1438-nolane | python3 -c '
import json, sys
payload = json.loads(sys.stdin.read())
assert set(payload) == {"pane_id", "label", "profile", "workspace", "tab_id", "task_id"}, payload' ||
    fail "#1438 AC5: a receipt without a hub_lane must keep exactly its pre-change fields"
  echo "PASS 1438-lanes AC5: lane_role is recorded with the lane, by every receipt writer path"

  # -- #1438 assertion-RED mutants -----------------------------------------
  # M1: the cumulative claim role printed as the 9th field again — AC1's
  # reused worker lane then carries the operator credential.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1438-cumulative \
    'spawned_hub_lane_machine or "-", spawned_lane_role if spawned_hub_lane else "-", sep="\t")' \
    'spawned_hub_lane_machine or "-", role or "-", sep="\t")'
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox-1438-m1"
  lanes_reap_reused_job j1438-m1 w1:p10 w1:t10 own-1438m1 lane-1438-m1 lbl-1438m1 mac-work-default worker
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1438-cumulative" \
    WRK_PANEWIRE_LANES_LS="$(t1438_ls lane-1438-m1 mac-work-default w1:p10)" \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_WBOTH" \
    lanes_reap_run 1438-m1 --lane own-1438m1 --apply --include-builders
  if ! grep -qxF "$LANES_OP_FILE" "$LANES_RM_LOG"; then
    fail "#1438 M1 mutant survived: the cumulative role no longer reaches the worker lane"
  fi
  echo "PASS 1438-lanes M1: printing the cumulative role as the 9th field goes RED"

  # M2: lane_role dropped from the receipt — every spawn then writes a
  # receipt AC5 rejects, and reap would read every builder lane as legacy.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1438-nolanerole \
    '    receipt["lane_role"] = lane_role' \
    '    pass'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1438-nolanerole" \
    LANES_CFG_OVERRIDE="$LANES_CFG_OP" LANES_MODEL=builder-sol \
    lanes_spawn b1438-m2 --role builder --lane b1438-m2 --parent director-x
  [[ "$LANES_RC" -eq 0 ]] || fail "#1438 M2: mutant builder spawn failed: $(cat "$LANES_ERR")"
  if [[ "$(t1438_receipt_lane_role b1438-m2)" != absent ]]; then
    fail "#1438 M2 mutant survived: the receipt still carries lane_role"
  fi
  echo "PASS 1438-lanes M2: dropping lane_role from the receipt goes RED"

  # M3: lane_role read from the oldest job.spawned instead of the newest —
  # AC4's builder-then-worker respawn then removes the lane with operator.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1438-oldest \
    '            spawned_lane_role = "builder" if payload.get("lane_role") == "builder" else "worker"' \
    '            spawned_lane_role = spawned_lane_role or ("builder" if payload.get("lane_role") == "builder" else "worker")'
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox-1438-m3"
  lanes_reap_reused_job j1438-m3 w1:p14 w1:t14 own-1438m3 lane-1438-m3 lbl-1438m3 mac-work-default builder worker
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1438-oldest" \
    WRK_PANEWIRE_LANES_LS="$(t1438_ls lane-1438-m3 mac-work-default w1:p14)" \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_WBOTH" \
    lanes_reap_run 1438-m3 --lane own-1438m3 --apply --include-builders
  if ! grep -qxF "$LANES_OP_FILE" "$LANES_RM_LOG"; then
    fail "#1438 M3 mutant survived: the oldest receipt no longer decides the chain"
  fi
  echo "PASS 1438-lanes M3: reading lane_role from the oldest receipt goes RED"

  # M4: a legacy receipt inheriting the cumulative claim role — AC3's legacy
  # builder-claimed lane then takes the operator credential again.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-1438-legacyrole \
    'spawned_lane_role = "builder" if payload.get("lane_role") == "builder" else "worker"' \
    'spawned_lane_role = "builder" if payload.get("lane_role", role) == "builder" else "worker"'
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox-1438-m4"
  lanes_reap_job j1438-m4 w1:p12 w1:t12 own-1438m4 lane-1438-m4 lbl-1438m4 mac-work-default builder -
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-1438-legacyrole" \
    WRK_PANEWIRE_LANES_LS="$(t1438_ls lane-1438-m4 mac-work-default w1:p12)" \
    LANES_REAP_CFG_OVERRIDE="$LANES_CFG_WBOTH" \
    lanes_reap_run 1438-m4 --lane own-1438m4 --apply --include-builders
  if ! grep -qxF "$LANES_OP_FILE" "$LANES_RM_LOG"; then
    fail "#1438 M4 mutant survived: a legacy receipt no longer inherits the claim role"
  fi
  echo "PASS 1438-lanes M4: a legacy receipt inheriting the claim role goes RED"
}

if [[ "${WRK_TEST_ONLY_LANES:-0}" -eq 1 ]]; then
  run_lanes_tests
  exit 0
fi
run_lanes_tests

arb() { "$ARBITER" "$@"; }

"$WRK" --help >/dev/null
spawn_help_out="$("$WRK" spawn --help)"
grep -q -- '--landing-strict' <<<"$spawn_help_out"
grep -q -- '--role worker|builder|tester|reviewer|counsel (legacy alias: captain)' <<<"$spawn_help_out"
grep -q -- 'builder-opus' <<<"$spawn_help_out"
grep -q -- 'builder-sonnet' <<<"$spawn_help_out" ||
  fail "spawn --help must document builder-sonnet (#921)"
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
# #979: hosts called the never-defined hosts_help — --help and -h must print
# the usage and exit 0, while an unknown flag still dies as a usage error.
hosts_help_out="$("$WRK" hosts --help)"
grep -q 'Usage: wrk hosts' <<<"$hosts_help_out" ||
  fail "hosts --help must print the hosts usage: $hosts_help_out"
"$WRK" hosts -h >/dev/null || fail "hosts -h must exit 0"
run_fail "$WRK" hosts --bogus
run_fail "$WRK" hosts extra
run_fail "$WRK" spawn -c "$ROOT" -p "$PROMPT" -w w -l fixture
run_fail "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l fixture --bogus
run_fail "$WRK" nope

run_terra_refusal_tests

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
canonical_out="$(spawn_base codex-luna --effort max)"
grep -q 'codex-luna-max' "$TMP/scopefuel.log"
grep -q -- '-m gpt-6-luna' "$TMP/herdr.log"
grep -q 'model_reasoning_effort=max' "$TMP/herdr.log"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
grep -q 'model=codex-luna' <<<"$canonical_out"

profiles=(
  "opus:opus" "sonnet:sonnet" "sonnet-med:sonnet" "haiku:haiku"
  "devin-swe2:devin-swe2"
  "devin-glm52:devin-glm52" "devin-swe17:devin-swe17" "devin-ds41:devin-ds41"
  "devin-swe2-medium:devin-swe2-medium" "devin-swe2-max:devin-swe2-max" "devin-ds41-max:devin-ds41-max"
  "devin-fusion-opus55:devin-fusion-opus55" "devin-fusion-sonnet55:devin-fusion-sonnet55"
  "codex:codex-max" "codex-sol:codex-max" "codex-luna:codex-luna-max"
  "codex-luna-hi:codex-luna-max" "codex-max:codex-max"
  "codex-luna-max:codex-luna-max"
  "codex-sol56:codex-max" "codex-luna56:codex-luna-max"
  "codex-sol6:codex-max"
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
# #979 N1: the substitution must be guarded — when every probe read fails the
# spawn exits nonzero and an unguarded $(...) dies silently under set -e.
devin_idle_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-swe2 2>&1)" ||
  fail "devin-idle spawn failed: $devin_idle_out"
grep -q 'model=devin-swe2' <<<"$devin_idle_out"
grep -q 'status=idle' <<<"$devin_idle_out"
grep -q 'landed=yes' <<<"$devin_idle_out"
[[ "$(grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
devin_run_line="$(grep '^pane run w:p1 devin ' "$TMP/herdr.log")"
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
devin_run_no="$(grep -n '^pane run w:p1 devin ' "$TMP/herdr.log" | cut -d: -f1)"
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

# #604: the 2026-09-23 incident shape — explain answers a well-formed envelope
# whose matched_rule is absent because no identity rule claimed the screen
# (first-open trust prompt hypothesis). Since #649 this bare envelope carries
# no evaluated_rules proving the screen is just the command line, so it is an
# "unmatched" screen: polled to the window, then the spawn still fails and
# the pane's screen, transcript, explain JSON and process-info must survive
# the pane.
devin_readiness_failure_case devin-explain-no-rule 1
grep -q 'agent explain matched no identity rule within 30000ms (unmatched screen x120)' <<<"$DEVIN_CASE_OUT" ||
  fail "no-rule explain lost the bounded-window diagnostic: $DEVIN_CASE_OUT"
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 120 ]] ||
  fail "no-rule explain must poll to the 30000/250 attempt cap"
grep -q 'Devin spawn failure artifacts preserved under ' <<<"$DEVIN_CASE_OUT" ||
  fail "604 failure artifacts were not announced: $DEVIN_CASE_OUT"
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 artifact dir missing: $artifact_dir"
[[ "$artifact_dir" == "$TMP/inbox/fixture/devin-spawn-failure-"* ||
   "$artifact_dir" == "$(cd "$TMP" && pwd -P)/inbox/fixture/devin-spawn-failure-"* ]] ||
  fail "604 artifacts must live in the job dir: $artifact_dir"
grep -q 'reason=agent explain matched no identity rule within 30000ms' "$artifact_dir/reason.txt" ||
  fail "604 reason.txt lost the failure reason"
grep -q '"matched_rule":null' "$artifact_dir/explain.out" ||
  fail "604 the explain envelope that failed was not preserved"
grep -q 'fixture welcome screen' "$artifact_dir/screen-visible.txt" ||
  fail "604 visible screen was not preserved"
grep -q 'fixture welcome screen' "$artifact_dir/transcript.txt" ||
  fail "604 transcript was not preserved"
grep -q 'pane_id' "$artifact_dir/process-info.out" ||
  fail "604 process-info was not preserved"
# The jobs root is scanned for event envelopes with rglob("*.json"); a raw
# capture that is not an event envelope must not carry the .json extension
# (a 'not json at all' explain.out broke exactly that scan on CI 2026-09-24).
if find "$artifact_dir" -name '*.json' | grep -q .; then
  fail "604 artifact dir must not contain .json files: $artifact_dir"
fi
echo "PASS 604-explain-no-rule-artifacts-preserved"

# #604 hypothesis variant: a rule did match — the trust prompt — so the spawn
# fails on the rule id, and the preserved visible screen carries the actual
# cause the pane was showing.
devin_readiness_failure_case devin-trust-screen 1
grep -q 'expected agent=devin rule=welcome_prompt_footer, got agent=devin rule=trust_directory' <<<"$DEVIN_CASE_OUT" ||
  fail "trust-screen explain lost its rule diagnostic: $DEVIN_CASE_OUT"
# #649: a matched non-welcome rule is a terminal state — judged on the first
# explain, never polled (a mutant that retries matched rules turns this red).
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "trust-screen must be judged on the first explain, not polled"
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 trust-screen artifact dir missing"
grep -q 'trust_directory' "$artifact_dir/explain.out" ||
  fail "604 trust-screen explain.out was not preserved"
grep -q 'Do you trust the contents of this directory?' "$artifact_dir/screen-visible.txt" ||
  fail "604 trust-screen visible capture lost the prompt"
echo "PASS 604-trust-screen-artifacts-preserved"

# #604: preservation also covers the non-explain failures, and a failed
# capture must never mask the spawn failure it documents. explain-fail leaves
# explain.rc=4 instead of a stolen success.
devin_readiness_failure_case devin-explain-fail 4
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" && -f "$artifact_dir/explain.rc" ]] ||
  fail "604 explain-fail must still leave an artifact dir: $DEVIN_CASE_OUT"
grep -qx 'rc=4' "$artifact_dir/explain.rc" ||
  fail "604 explain-fail must record the explain rc: $(cat "$artifact_dir/explain.rc" 2>/dev/null)"
echo "PASS 604-explain-fail-artifacts-preserved"

# #604 (CodeRabbit major on PR #122): explain answering rc=0 with EMPTY stdout
# is a supplied failing response, not an absent one. Preservation must save
# that response verbatim (a 0-byte explain.out plus an explicit rc=0) and must
# not re-query — a second explain would overwrite the artifact with a later,
# different response (the fixture answers a valid envelope from call 2 on, so
# a re-querying mutant turns this red).
devin_readiness_failure_case devin-explain-empty 1
grep -q 'agent explain returned an invalid identity envelope' <<<"$DEVIN_CASE_OUT" ||
  fail "empty explain response lost the invalid-envelope diagnostic: $DEVIN_CASE_OUT"
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 explain-empty artifact dir missing: $DEVIN_CASE_OUT"
[[ -f "$artifact_dir/explain.out" && ! -s "$artifact_dir/explain.out" ]] ||
  fail "604 explain-empty must preserve the empty response verbatim: $(ls -l "$artifact_dir" 2>/dev/null)"
grep -qx 'rc=0' "$artifact_dir/explain.rc" ||
  fail "604 explain-empty must record the supplied explain rc=0: $(cat "$artifact_dir/explain.rc" 2>/dev/null)"
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "604 explain-empty must not re-query explain over the failing response"
echo "PASS 604-explain-empty-response-preserved"

# #604 (tester round 1): a pre-detection failure must not query agent
# endpoints, but it still owes the artifact set an explicit explain outcome —
# rc=skipped, not an absent file that reads as "preservation forgot it".
devin_readiness_failure_case devin-get-error 1
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 get-error artifact dir missing: $DEVIN_CASE_OUT"
grep -qx 'rc=skipped' "$artifact_dir/explain.rc" ||
  fail "604 pre-detection failure must record explain rc=skipped: $(cat "$artifact_dir/explain.rc" 2>/dev/null)"
echo "PASS 604-pre-detection-explain-skip-recorded"

# #604 (tester round 1, minor): a failed pane-read capture must not mask,
# replace or worsen the spawn failure it documents — rc stays 1 and the rest
# of the artifact set is still written.
devin_readiness_failure_case devin-read-fail 1
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 read-fail artifact dir missing: $DEVIN_CASE_OUT"
grep -qx 'rc=9' "$artifact_dir/screen-visible.rc" ||
  fail "604 read-fail must record the capture rc: $(cat "$artifact_dir/screen-visible.rc" 2>/dev/null)"
grep -q '"matched_rule":null' "$artifact_dir/explain.out" ||
  fail "604 read-fail must still preserve the explain envelope"
echo "PASS 604-capture-failure-does-not-mask-spawn-rc"

devin_readiness_failure_case devin-never-detect 1
grep -q "Devin pane startup failed: agent not detected within 30000ms (agent_not_found x120)" <<<"$DEVIN_CASE_OUT" ||
  fail "never-detected Devin lost its bounded-window diagnostic: $DEVIN_CASE_OUT"
[[ "$(grep -c '^agent get w:p1$' "$TMP/herdr.log")" -eq 120 ]] ||
  fail "never-detected Devin must poll exactly the 30000/250 attempt cap"
if grep -q '^agent wait \|^agent explain ' "$TMP/herdr.log"; then
  fail "never-detected Devin waited or explained an undetected pane"
fi
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 never-detect artifact dir missing: $DEVIN_CASE_OUT"
grep -qx 'rc=skipped' "$artifact_dir/explain.rc" ||
  fail "604 never-detect must record explain rc=skipped: $(cat "$artifact_dir/explain.rc" 2>/dev/null)"

# #649 (m1b): a slow devin reaches the identity check before its TUI is
# painted — explain answers a well-formed envelope with every rule unmatched
# and the evaluated region still holds only the typed command line. That is
# "still starting", not a spawn failure: explain is re-polled with backoff
# inside the same START_TIMEOUT window. A mutant that fails on the first
# unmatched envelope turns the success assertion red.
: >"$TMP/herdr.log"
devin_starting_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO=devin-explain-starting spawn_base devin-swe2 2>&1)" ||
  fail "still-starting Devin must spawn once the welcome footer appears: $devin_starting_out"
grep -q 'landed=yes' <<<"$devin_starting_out" ||
  fail "still-starting Devin did not land: $devin_starting_out"
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 4 ]] ||
  fail "starting Devin must poll explain until a rule matches: $(grep -c '^agent explain ' "$TMP/herdr.log")"
grep -qx 'agent rename w:p1 fixture' "$TMP/herdr.log" ||
  fail "still-starting Devin must rename the tab-create pane id"
[[ "$(grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "still-starting Devin must receive exactly one brief"
echo "PASS 649-starting-polls-then-succeeds"

# The same command-line-only screen that never resolves: the window closes
# and the spawn fails closed with the #604 artifact set and a reason naming
# the still-starting shape — "on timeout, the existing fail-closed path".
devin_readiness_failure_case devin-explain-starting-stuck 1
grep -q 'Devin pane startup failed: agent explain still starting within 30000ms (command-line-only screen x120)' <<<"$DEVIN_CASE_OUT" ||
  fail "never-starting Devin lost its bounded-window diagnostic: $DEVIN_CASE_OUT"
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 120 ]] ||
  fail "never-starting Devin must poll explain exactly the 30000/250 attempt cap"
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "649 starting-stuck artifact dir missing: $artifact_dir"
grep -q '"matched_rule":null' "$artifact_dir/explain.out" ||
  fail "649 starting-stuck must preserve the last explain envelope"
echo "PASS 649-starting-window-fails-closed"

# Unknown screen — unmatched rules AND the evaluated region is not the
# command line: also rides the window out, then fails ("fail after the
# window"), distinct from a matched dialog's immediate judgement. A mutant
# that fails it on the first explain turns the poll-count assertion red.
devin_readiness_failure_case devin-explain-unknown 1
grep -q 'Devin pane startup failed: agent explain matched no identity rule within 30000ms (unmatched screen x120)' <<<"$DEVIN_CASE_OUT" ||
  fail "unknown-screen Devin lost its bounded-window diagnostic: $DEVIN_CASE_OUT"
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 120 ]] ||
  fail "unknown-screen Devin must poll explain exactly the 30000/250 attempt cap"
echo "PASS 649-unknown-screen-window-fails-closed"

# Detection on the window edge: a fake clock (only `date +%s` is faked) puts
# the window deadline between detection and the idle wait. Detection succeeds
# on the first get, but no time is left, so wrk must fail before agent wait
# instead of handing it a zero or negative timeout.
mkdir -p "$TMP/fakeclock"
# #979: the readiness probe adds one `date +%s` call to the start path — the
# readiness loop's deadline check on the iteration that sends the probe —
# so the clock now stays in-window for the first two calls (started_at, the
# probe-send iteration) and jumps on the third: the post-detection
# remaining_ms check, or the first failed get's deadline check.
cat >"$TMP/fakeclock/date" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == +%s ]]; then
  calls=0
  [[ -e "$FAKECLOCK_STATE" ]] && calls="$(cat "$FAKECLOCK_STATE")"
  calls=$(( calls + 1 ))
  printf '%s\n' "$calls" >"$FAKECLOCK_STATE"
  if (( calls > ${FAKECLOCK_AFTER_CALLS:-2} )); then echo 1031; else echo 1000; fi
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

# Every other kind keeps the generic `agent start` path — its argv arrives
# through herdr alone. #1016 adds the readiness probe before it: the only
# `pane run` a non-Devin spawn may issue is the probe line itself. The clock
# is frozen so the probe's share of the shared window (#1199) reads 0 and the
# first start still sees the full --timeout.
: >"$TMP/herdr.log"
PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 spawn_base codex-luna >/dev/null
grep -qx 'agent start fixture --kind codex --pane w:p1 --timeout 120000 -- --yolo -m gpt-6-luna -c model_reasoning_effort=medium' "$TMP/herdr.log" ||
  fail "non-Devin agent-start path drifted"
[[ "$(grep -c '^pane run ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "non-Devin kind must type only the readiness probe: $(grep '^pane run ' "$TMP/herdr.log")"
grep -qE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-[0-9]+-[0-9]+-[0-9]+'$" "$TMP/herdr.log" ||
  fail "the only non-Devin pane run must be exactly the readiness probe: $(grep '^pane run ' "$TMP/herdr.log")"

# #606: a fresh pane whose shell is still running rc subprocesses answers
# `agent start` with agent_pane_busy (real herdr 0.9.0 envelope, stderr, rc=1).
# Inside the START_TIMEOUT window that is retried with the 250ms poll; every
# other start failure still fails at once. Removing the retry turns the
# shell-busy cases red; retrying every error turns the non-busy cases red.
for shell_busy_pair in "opus:claude" "codex-luna:codex"; do
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
grep -q 'agent start failed: shell not ready within the 30000ms window (readiness probe used 0ms, agent_pane_busy x120); pane=w:p1' <<<"$shell_never_out" ||
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

# hk 1895: a failed spawn saves the pane's screen into the job dir (mode 0600,
# never echoed to stdout/stderr), still closes the pane and keeps rc=1.
T1895_JOBDIR="$TMP/inbox/fixture"
T1895_SCREEN="$T1895_JOBDIR/spawn-failure-screen.txt"
rm -rf "$T1895_JOBDIR"
: >"$TMP/herdr.log"
set +e
t1895_out="$(umask 002; TEST_FIXTURE_SCENARIO=start-not-ready spawn_base opus 2>&1)"
t1895_rc=$?
set -e
[[ "$t1895_rc" -eq 1 ]] || fail "1895 screen case expected rc=1, got $t1895_rc: $t1895_out"
[[ -f "$T1895_SCREEN" ]] ||
  fail "1895 failed spawn left no spawn-failure-screen.txt: $t1895_out"
grep -q 'fixture welcome screen' "$T1895_SCREEN" ||
  fail "1895 screen file lost the fixture screen text"
grep -q 'ACTUAL SCREEN LAST LINE' "$T1895_SCREEN" ||
  fail "1895 screen file lost the screen tail"
[[ "$(stat -c %a "$T1895_SCREEN" 2>/dev/null || stat -f %Lp "$T1895_SCREEN")" == 600 ]] ||
  fail "1895 screen file must be mode 0600 under a loose umask"
grep -q "wrk: saved failed pane screen to $T1895_SCREEN" <<<"$t1895_out" ||
  fail "1895 lost the saved-screen line: $t1895_out"
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "1895 must still close the failed pane"
if grep -q 'fixture welcome screen\|ACTUAL SCREEN LAST LINE' <<<"$t1895_out"; then
  fail "1895 leaked the pane screen to stdout/stderr"
fi

# WRK_KEEP_FAILED_PANE=1 captures the same file but leaves the pane up.
rm -rf "$T1895_JOBDIR"
: >"$TMP/herdr.log"
set +e
t1895_keep_out="$(WRK_KEEP_FAILED_PANE=1 TEST_FIXTURE_SCENARIO=start-not-ready spawn_base opus 2>&1)"
t1895_keep_rc=$?
set -e
[[ "$t1895_keep_rc" -eq 1 ]] ||
  fail "1895 keep case expected rc=1, got $t1895_keep_rc: $t1895_keep_out"
[[ -f "$T1895_SCREEN" ]] ||
  fail "1895 keep case left no spawn-failure-screen.txt: $t1895_keep_out"
if grep -q '^pane close ' "$TMP/herdr.log"; then
  fail "WRK_KEEP_FAILED_PANE=1 still closed the pane"
fi
grep -q 'wrk: kept failed pane w:p1 (WRK_KEEP_FAILED_PANE=1); close it with herdr pane close w:p1' <<<"$t1895_keep_out" ||
  fail "1895 keep case lost the kept-pane line: $t1895_keep_out"

# Any other value behaves as unset: the pane is closed.
rm -rf "$T1895_JOBDIR"
: >"$TMP/herdr.log"
set +e
t1895_yes_out="$(WRK_KEEP_FAILED_PANE=yes TEST_FIXTURE_SCENARIO=start-not-ready spawn_base opus 2>&1)"
t1895_yes_rc=$?
set -e
[[ "$t1895_yes_rc" -eq 1 ]] || fail "1895 keep=yes case expected rc=1, got $t1895_yes_rc"
grep -qx 'pane close w:p1' "$TMP/herdr.log" ||
  fail "WRK_KEEP_FAILED_PANE=yes must behave as unset and close the pane"
if grep -q 'kept failed pane' <<<"$t1895_yes_out"; then
  fail "WRK_KEEP_FAILED_PANE=yes must not print the kept-pane line"
fi

# A pane read that fails is best-effort: rc and the close are unchanged and at
# most one warn line is printed; the saved-screen line is absent.
rm -rf "$T1895_JOBDIR"
: >"$TMP/herdr.log"
set +e
t1895_readfail_out="$(WRK_FIXTURE_PANE_READ200_FAIL=1 TEST_FIXTURE_SCENARIO=start-not-ready spawn_base opus 2>&1)"
t1895_readfail_rc=$?
set -e
[[ "$t1895_readfail_rc" -eq 1 ]] ||
  fail "1895 read-fail case expected rc=1, got $t1895_readfail_rc: $t1895_readfail_out"
grep -qx 'pane close w:p1' "$TMP/herdr.log" ||
  fail "1895 read-fail case must still close the pane"
[[ "$(grep -c 'failed-pane screen capture failed' <<<"$t1895_readfail_out")" -eq 1 ]] ||
  fail "1895 read-fail case printed more than one warn line: $t1895_readfail_out"
if grep -q 'saved failed pane screen' <<<"$t1895_readfail_out"; then
  fail "1895 read-fail case must not claim a saved screen"
fi

# Two failures of the same job id keep both files, the first untouched.
T1895_DUP_JOBDIR="$TMP/inbox/t1895-dup"
rm -rf "$T1895_DUP_JOBDIR"
for t1895_n in 1 2; do
  : >"$TMP/herdr.log"
  set +e
  TEST_FIXTURE_SCENARIO=start-not-ready spawn_base opus --job t1895-dup >/dev/null 2>&1
  t1895_dup_rc=$?
  set -e
  [[ "$t1895_dup_rc" -eq 1 ]] || fail "1895 dup failure $t1895_n expected rc=1, got $t1895_dup_rc"
done
[[ -f "$T1895_DUP_JOBDIR/spawn-failure-screen.txt" &&
   -f "$T1895_DUP_JOBDIR/spawn-failure-screen-2.txt" ]] ||
  fail "1895 second failure must write spawn-failure-screen-2.txt"
grep -q 'fixture welcome screen' "$T1895_DUP_JOBDIR/spawn-failure-screen.txt" ||
  fail "1895 first screen file was overwritten"
echo "PASS hk1895 failed-pane screen capture and WRK_KEEP_FAILED_PANE"

# ---------------------------------------------------------------------------
# hk 2011: run_bounded kills a TERM-ignoring child, the failed-pane capture
# name is exclusive under a race, WRK_KEEP_FAILED_PANE reaches a remote leg,
# and the kept-pane hint names herdr pane close.
# ---------------------------------------------------------------------------
# t2011_term_case FILE — run_bounded 1 on a child that traps TERM and sleeps
# 30 s, extracted from FILE. Prints "RC ELAPSED_SECONDS". Main holds the whole
# 30 s; the bound is secs plus the kill grace, so 6 s is a generous ceiling.
t2011_term_case() {
  local file="$1" start rc=0
  start="$SECONDS"
  # shellcheck disable=SC1090 # FILE is the run_bounded extract from bin/wrk
  ( . "$file"; run_bounded 1 sh -c 'trap "" TERM; sleep 30' ) >/dev/null 2>&1 || rc=$?
  printf '%s %s\n' "$rc" "$((SECONDS - start))"
}
T2011_RB="$TMP/run-bounded-2011.sh"
sed -n '/^run_bounded() {/,/^}/p' "$WRK" >"$T2011_RB"
grep -q '^run_bounded() {' "$T2011_RB" || fail "hk2011: run_bounded is not in bin/wrk"
read -r t2011_rc t2011_elapsed <<<"$(t2011_term_case "$T2011_RB")"
if [[ "$t2011_rc" -ne 124 && "$t2011_rc" -ne 137 ]] || (( t2011_elapsed > 6 )); then
  fail "hk2011: run_bounded 1 left a TERM-ignoring child running (rc=$t2011_rc, ${t2011_elapsed}s; bound 1s plus kill grace)"
fi
# The same case with only gtimeout on PATH (a shim that execs the real timeout),
# so the gtimeout branch is the one that runs. macOS has no timeout binary and
# uses the python fallback, so the case is skipped there.
if T2011_REAL_TIMEOUT="$(command -v timeout)"; then
  T2011_GT="$TMP/gtimeout-only"
  rm -rf "$T2011_GT"
  mkdir -p "$T2011_GT"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$T2011_REAL_TIMEOUT" >"$T2011_GT/gtimeout"
  chmod +x "$T2011_GT/gtimeout"
  ln -s "$(command -v sh)" "$T2011_GT/sh"
  ln -s "$(command -v sleep)" "$T2011_GT/sleep"
  read -r t2011_rc t2011_elapsed <<<"$(PATH="$T2011_GT" t2011_term_case "$T2011_RB")"
  if [[ "$t2011_rc" -ne 124 && "$t2011_rc" -ne 137 ]] || (( t2011_elapsed > 6 )); then
    fail "hk2011: gtimeout path left a TERM-ignoring child running (rc=$t2011_rc, ${t2011_elapsed}s)"
  fi
else
  echo "SKIP hk2011 gtimeout branch: no timeout binary on this host"
fi
echo "PASS hk2011 run_bounded bound holds for a TERM-ignoring child"

# t2011_capture_pair JOB WRK — two failed-pane captures of one job. The first
# parks inside the name-pick window (capture-name seam); the second runs to
# completion meanwhile. Returns 0 only when both screens survive as two files.
t2011_capture_pair() {
  local job="$1" bin="$2" pause dir a_pid a_rc b_rc i
  pause="$TMP/pause-$job"
  rm -rf "$pause"
  mkdir -p "$pause"
  dir="$TMP/inbox/$job"
  rm -rf "$dir"
  set +e
  WRK_UNDER_TEST="$bin" TEST_FIXTURE_SCENARIO=start-not-ready \
    WRK_TEST_PAUSE_AT=capture-name WRK_TEST_PAUSE_DIR="$pause" \
    spawn_base opus --job "$job" --job-dup-ok >"$pause/a.out" 2>&1 &
  a_pid=$!
  own "$a_pid"
  i=0
  while [[ ! -e "$pause/paused" && "$i" -lt 200 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [[ ! -e "$pause/paused" ]]; then
    : >"$pause/release"
    wait "$a_pid"
    set -e
    return 1
  fi
  WRK_UNDER_TEST="$bin" TEST_FIXTURE_SCENARIO=start-not-ready \
    spawn_base opus --job "$job" --job-dup-ok >"$pause/b.out" 2>&1
  b_rc=$?
  : >"$pause/release"
  wait "$a_pid"
  a_rc=$?
  set -e
  [[ "$a_rc" -eq 1 && "$b_rc" -eq 1 ]] || return 1
  [[ -f "$dir/spawn-failure-screen.txt" && -f "$dir/spawn-failure-screen-2.txt" ]] || return 1
  grep -q 'fixture welcome screen' "$dir/spawn-failure-screen.txt" || return 1
  grep -q 'fixture welcome screen' "$dir/spawn-failure-screen-2.txt"
}
t2011_capture_pair concurrent-capture "$WRK" ||
  fail "hk2011: two failed-pane captures of one job collided on spawn-failure-screen.txt"
echo "PASS hk2011 concurrent failed-pane captures keep two files"

# hk 2011 forwarding: a spill-over spawn carries WRK_KEEP_FAILED_PANE to the
# remote leg (only when set), next to HERDR_SESSION.
T2011_FWD="$TMP/fwd-2011"
rm -rf "$T2011_FWD"
mkdir -p "$T2011_FWD"
printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
  '[hub]' 'hub_url = "https://example.invalid"' 'hub_token_env = "/tmp/example-token.env"' 'hub_cf_env = "/tmp/example-cf.env"' '' \
  '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
  "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' >"$T2011_FWD/hosts.toml"
printf '%s\n' '0.20 0.10 0.10 1/1 1' >"$T2011_FWD/loadavg"
# t2011_fwd_spawn JOB [KEEP] — a spawn that spills to the desktop host.
t2011_fwd_spawn() {
  local job="$1" keep="${2:-}" task keep_env=()
  [[ -z "$keep" ]] || keep_env=(WRK_KEEP_FAILED_PANE="$keep")
  task="$(mint_task)"
  : >"$T2011_FWD/ssh.log"
  env -u WRK_KEEP_FAILED_PANE ${keep_env[@]+"${keep_env[@]}"} \
    WRK_TEST_MODE=1 ARBITER_INBOX_ROOT="$TMP/inbox" XDG_DATA_HOME="$TMP/xdg" ARBITER_BIN="$ARBITER" \
    HERDR_BIN="$ROOT/tests/fixtures/spillover-herdr" SCOPEFUEL_BIN="$SCOPEFUEL" \
    WRK_NO_SLEEP=1 WRK_HOSTS_CONFIG="${T2011_HOSTS:-$T2011_FWD/hosts.toml}" WRK_PROC_LOADAVG="$T2011_FWD/loadavg" \
    WRK_TEST_NCPU=4 WRK_TEST_THROTTLED=0 WRK_PLACE_SCENARIO=unavailable WRK_TEST_ACTIVE=4 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$T2011_FWD/herdr.log" WRK_SPILLOVER_LOG="$T2011_FWD/spill.log" \
    PANEWIRE_BIN="$ROOT/tests/fixtures/spillover-panewire" WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" \
    WRK_SCP_BIN="$ROOT/tests/fixtures/spillover-scp" WRK_SSH_LOG="$T2011_FWD/ssh.log" WRK_SCP_LOG="$T2011_FWD/scp.log" \
    WRK_WAKE_LOG="$T2011_FWD/wake.log" WRK_PLACE_LOG="$T2011_FWD/place.log" \
    WRK_SPILLOVER_CANDIDATES_LOG="$T2011_FWD/cand.log" WRK_COMPLETION_INTERVAL_S=3600 \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -l fixture -w w --t T1 \
    --job "$job" --task "$task"
}
t2011_fwd_spawn fwd-keep 1 >"$T2011_FWD/keep.out" 2>&1 ||
  fail "hk2011 forward: spill-over spawn failed: $(cat "$T2011_FWD/keep.out")"
grep -q '^OK pane=desktop:p7 host=desktop ' "$T2011_FWD/keep.out" ||
  fail "hk2011 forward: spawn did not land on the desktop host: $(cat "$T2011_FWD/keep.out")"
grep -q 'HERDR_SESSION=worker .*WRK_KEEP_FAILED_PANE=1 wrk spawn' "$T2011_FWD/ssh.log" ||
  fail "hk2011: WRK_KEEP_FAILED_PANE=1 was not forwarded to the remote leg: $(cat "$T2011_FWD/ssh.log")"
t2011_fwd_spawn fwd-plain >"$T2011_FWD/plain.out" 2>&1 ||
  fail "hk2011 forward: unset-variable spawn failed: $(cat "$T2011_FWD/plain.out")"
if grep -q 'WRK_KEEP_FAILED_PANE' "$T2011_FWD/ssh.log"; then
  fail "hk2011: an unset WRK_KEEP_FAILED_PANE must not be forwarded: $(cat "$T2011_FWD/ssh.log")"
fi
echo "PASS hk2011 WRK_KEEP_FAILED_PANE forwards to the remote leg"

# hk 2011 kept pane: a remote leg that kept its failed pane (WRK_KEEP_FAILED_PANE
# is forwarded) ends the auto round at that host. The second candidate and the
# local fallback must never spawn: one pane, one remote spawn leg.
T2011_TWO="$T2011_FWD/hosts-two.toml"
cp "$T2011_FWD/hosts.toml" "$T2011_TWO"
printf '%s\n' '' '[hosts.mac-work]' 'ssh = "mac-work"' 'herdr_session = "worker"' 'workspace = "workers"' \
  "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' >>"$T2011_TWO"
set +e
t2011_kept_out="$(T2011_HOSTS="$T2011_TWO" WRK_SSH_SCENARIO_DESKTOP=remote-die-stderr WRK_REMOTE_RC=1 \
  WRK_REMOTE_STDERR_LINE='wrk: kept failed pane desktop:p7 (WRK_KEEP_FAILED_PANE=1); close it with herdr pane close desktop:p7' \
  t2011_fwd_spawn fwd-kept 1 2>&1)"
t2011_kept_rc=$?
set -e
[[ "$t2011_kept_rc" -ne 0 ]] ||
  fail "hk2011 kept pane: the remote failure must fail the auto spawn: $t2011_kept_out"
[[ "$(grep -c 'kept failed pane' <<<"$t2011_kept_out")" -eq 1 ]] ||
  fail "hk2011 kept pane: the kept pane must be printed exactly once: $t2011_kept_out"
grep -q "left failed pane desktop:p7 open" <<<"$t2011_kept_out" ||
  fail "hk2011 kept pane: the round must say the pane is still open: $t2011_kept_out"
[[ "$(grep -c '^OK pane=' <<<"$t2011_kept_out")" -eq 0 ]] ||
  fail "hk2011 kept pane: no candidate may land a second pane: $t2011_kept_out"
[[ "$(grep -c 'wrk spawn' "$T2011_FWD/ssh.log")" -eq 1 ]] ||
  fail "hk2011 kept pane: exactly one remote spawn leg is allowed: $(cat "$T2011_FWD/ssh.log")"
if grep -q 'mac-work' "$T2011_FWD/ssh.log"; then
  fail "hk2011 kept pane: the second candidate must not be tried: $(cat "$T2011_FWD/ssh.log")"
fi
echo "PASS hk2011 kept remote pane ends the auto round: one pane, no second candidate"

# The kept-pane hint names the pane to close (herdr pane close PANE), never a tab.
T2011_HINT="$(WRK_KEEP_FAILED_PANE=1 TEST_FIXTURE_SCENARIO=start-not-ready spawn_base opus 2>&1)" || true
grep -q 'close it with herdr pane close w:p1' <<<"$T2011_HINT" ||
  fail "hk2011: kept-pane hint must name herdr pane close w:p1: $T2011_HINT"
if grep -q 'herdr tab close' <<<"$T2011_HINT"; then
  fail "hk2011: kept-pane hint must not name herdr tab close"
fi
rm -f "$TMP/herdr.log"
echo "PASS hk2011 kept-pane hint names herdr pane close"

# Mutants: each must make its named case fail.
# shellcheck disable=SC2016 # the mutant anchors are bin/wrk source text, not expansions
# nokill needs timeout or gtimeout on PATH: the python fallback kills on its own
# (SIGKILL), so the mutant cannot differ there and the check is skipped. The
# extract is the mutant's run_bounded block only; the whole mutant file ends in
# a dispatcher that exits 2 before run_bounded exists.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  devin_trust_mutant nokill '    timeout -k "$kill_grace" "$secs" "$@"' '    timeout "$secs" "$@"'
  sed -n '/^run_bounded() {/,/^}/p' "$TMP/mut-wrk-nokill" >"$TMP/run-bounded-nokill.sh"
  [[ -s "$TMP/run-bounded-nokill.sh" ]] ||
    fail "hk2011 mutant nokill: run_bounded is not in the mutant copy"
  read -r t2011_rc t2011_elapsed <<<"$(t2011_term_case "$TMP/run-bounded-nokill.sh")"
  # RED for the right reason: the TERM-ignoring child outlived the bound (rc 124
  # after the full sleep), not a non-124 rc from a broken extract.
  if [[ "$t2011_rc" -ne 124 ]] || (( t2011_elapsed <= 6 )); then
    fail "hk2011 mutant nokill (no -k) must go RED on the timing: rc=$t2011_rc elapsed=${t2011_elapsed}s"
  fi
else
  echo "SKIP hk2011 mutant nokill: no timeout or gtimeout on this host"
fi
# shellcheck disable=SC2016 # the mutant anchors are bin/wrk source text, not expansions
devin_trust_mutant nonexcl 'set -C; : >"$screen"' ': >"$screen"'
t2011_capture_pair mut-nonexcl "$TMP/mut-wrk-nonexcl" &&
  fail "hk2011 mutant nonexcl (non-exclusive create) must fail the concurrent case"
# shellcheck disable=SC2016 # the mutant anchors are bin/wrk source text, not expansions
devin_trust_mutant noforward '  [[ -n "${WRK_KEEP_FAILED_PANE:-}" ]] && remote_args+=("WRK_KEEP_FAILED_PANE=$WRK_KEEP_FAILED_PANE")' '  :'
WRK_UNDER_TEST="$TMP/mut-wrk-noforward" t2011_fwd_spawn fwd-mut 1 >/dev/null 2>&1 || true
grep -q 'HERDR_SESSION=worker .*WRK_KEEP_FAILED_PANE=1 wrk spawn' "$T2011_FWD/ssh.log" &&
  fail "hk2011 mutant noforward (no forward) must fail the forwarding case"
# A capture that prints no warning for a failed read must fail the
# exactly-one-warning assertion above.
# shellcheck disable=SC2016 # the mutant anchors are bin/wrk source text, not expansions
devin_trust_mutant nowarn 'warn "failed-pane screen capture failed for pane $PANE"' ': "failed-pane screen capture failed for pane $PANE"'
t2011_rf_out="$(WRK_UNDER_TEST="$TMP/mut-wrk-nowarn" WRK_FIXTURE_PANE_READ200_FAIL=1 TEST_FIXTURE_SCENARIO=start-not-ready spawn_base opus 2>&1)" || true
[[ "$(grep -c 'failed-pane screen capture failed' <<<"$t2011_rf_out")" -eq 1 ]] &&
  fail "hk2011 mutant nowarn (zero warnings) must fail the exactly-one-warning case"
echo "PASS hk2011 mutants applied"


# #609: an accepted `agent start` whose binary never reaches the pane
# foreground — the m1b shape, zsh answered "command not found: codex" — must
# not receive a brief. Before any injection wrk polls process-info until a
# foreground process's argv0 is the kind's canonical executable; the shell
# alone, a shell child or an unrelated process are all "not the agent", and
# the bounded window ends in fail-closed: pane closed, zero injections through
# either path (panewire prompt or a direct agent prompt/send-keys).
FG_PW_LOG="$TMP/foreground-panewire.log"
fg_failure_case() {
  local model="$1" scenario="$2" want_rc="$3" out rc
  : >"$TMP/herdr.log"
  rm -f "$FG_PW_LOG" "$FG_PW_LOG".*
  set +e
  out="$(WRK_PANEWIRE_PROMPT_LOG="$FG_PW_LOG" TEST_FIXTURE_SCENARIO="$scenario" spawn_base "$model" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq "$want_rc" ]] ||
    fail "$model/$scenario expected rc=$want_rc, got rc=$rc: $out"
  grep -q 'agent foreground check failed:' <<<"$out" ||
    fail "$model/$scenario lost its foreground diagnostic: $out"
  grep -qx 'pane close w:p1' "$TMP/herdr.log" ||
    fail "$model/$scenario leaked the agent-less pane"
  if grep -q '^agent prompt \|^agent send-keys \|^pane run .*-p\b' "$TMP/herdr.log"; then
    fail "$model/$scenario injected into a pane without its agent"
  fi
  [[ ! -e "$FG_PW_LOG" ]] ||
    fail "$model/$scenario delivered a panewire prompt without its agent"
  FG_CASE_OUT="$out"
}

# The bare shell in the foreground is the incident shape, for a start-path
# kind and for Devin's pane-run path alike.
fg_failure_case opus agent-never-foreground 1
grep -q 'agent not foreground within 10000ms (not-foreground x40)' <<<"$FG_CASE_OUT" ||
  fail "never-foreground claude lost its bounded-window diagnostic: $FG_CASE_OUT"
# 41 = the 10000/250 cap plus one diagnostic; #1016's readiness probe adds
# its own single process-info read before agent start.
[[ "$(grep -c '^pane process-info --pane w:p1' "$TMP/herdr.log")" -eq 42 ]] ||
  fail "never-foreground claude must stop at the 10000/250 cap plus one diagnostic (plus the #1016 probe's one)"
fg_failure_case codex-luna agent-never-foreground 1
fg_failure_case devin-swe2 agent-never-foreground 1
# kiro's pre-brief /effort prompt is also an injection; the gate precedes it.
# (`agent start` argv legitimately carries `--effort`, so assert on the prompt
# verb, not the word.)
fg_failure_case kiro agent-never-foreground 1
if grep -q '^agent prompt w:p1 /effort' "$TMP/herdr.log"; then
  fail "kiro /effort prompt reached a pane whose agent never foregrounded"
fi
# An unrelated process holding the foreground is not the agent either.
fg_failure_case opus agent-foreground-other 1
# Unreadable answers fail closed at once, like the Devin pre-run check.
fg_failure_case opus agent-foreground-info-fail 1
grep -q 'pane process-info exited 3 before brief injection' <<<"$FG_CASE_OUT" ||
  fail "process-info failure lost its diagnostic: $FG_CASE_OUT"
# #1016: the readiness probe's own process-info read (answered normally —
# the scenario only fails once an agent holds the foreground) precedes the
# failing check and the diagnostic.
[[ "$(grep -c '^pane process-info --pane w:p1' "$TMP/herdr.log")" -eq 3 ]] ||
  fail "process-info rc failure must fail on the first check, not be retried"
fg_failure_case opus agent-foreground-garbage 1
grep -q 'pane process-info returned an invalid envelope before brief injection' <<<"$FG_CASE_OUT" ||
  fail "invalid foreground envelope lost its diagnostic: $FG_CASE_OUT"

# The poll is real: a pane that foregrounds the agent two reads late still
# spawns and lands exactly one brief.
: >"$TMP/herdr.log"
fg_late_out="$(TEST_FIXTURE_SCENARIO=agent-late-foreground spawn_base opus 2>&1)" ||
  fail "late-foreground agent must still spawn: $fg_late_out"
grep -q 'landed=yes' <<<"$fg_late_out" ||
  fail "late-foreground agent did not land: $fg_late_out"
[[ "$(grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "late-foreground agent must receive exactly one brief"
[[ "$(grep -c '^pane process-info --pane w:p1' "$TMP/herdr.log")" -eq 3 ]] ||
  fail "late-foreground agent must be admitted on the third process-info read"
if grep -q '^pane close ' "$TMP/herdr.log"; then fail "late-foreground pane was closed"; fi
echo "PASS task609 pre-injection foreground-agent check"

# Regression: the kind's herdr --kind name is not always its pane argv0.
# Measured on live panes 2026-09-24 — kimi lands as argv0 "kimi-code", codex
# as a node leader plus a native "codex" child — so the fixture emits those
# real values and every kind below must still be admitted (the #609 follow-up
# hotfix: matching only the kind string fail-closed every real kimi spawn).
for fg_kind_pair in opus:claude codex-luna:codex devin-swe2:devin kimi-k3:kimi grok:grok kiro:kiro oc-glm:opencode agy-flash:agy; do
  fg_model="${fg_kind_pair%%:*}"; fg_kind="${fg_kind_pair##*:}"
  : >"$TMP/herdr.log"
  set +e
  fg_real_out="$(KIMI_CODE_HOME="$TMP/kimi-$fg_model-home" TEST_FIXTURE_SCENARIO=spawn spawn_base "$fg_model" 2>&1)"
  fg_real_rc=$?
  set -e
  [[ "$fg_real_rc" -eq 0 ]] ||
    fail "$fg_model (kind $fg_kind) must spawn under its real argv0 (rc=$fg_real_rc): $fg_real_out"
  grep -q 'landed=yes' <<<"$fg_real_out" ||
    fail "$fg_model (kind $fg_kind) was not admitted under its real argv0: $fg_real_out"
done
echo "PASS foreground check admits every kind under its real argv0"

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
  grep -q 'shell not ready within the 30000ms window (readiness probe used 0ms, agent_pane_busy x1); pane=w:p1' <<<"$SHELL_WINDOW_OUT" ||
    fail "retry at ${shell_window_jump}s lost its window diagnostic: $SHELL_WINDOW_OUT"
  [[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "retry at ${shell_window_jump}s must not start again past the window"
  grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "retry at ${shell_window_jump}s leaked its pane"
  if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "retry at ${shell_window_jump}s delivered a brief"; fi
done

# #1492: the optional [local] window can lengthen every kind's readiness
# wait, never shorten it, and refuses malformed or out-of-range values. The
# fake clock advances the configured seconds after a probe is typed, so no
# case sleeps for its 30s/90s/120s window.
t1492_default_out=""
: >"$TMP/herdr.log"
set +e
t1492_default_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER='pane run w:p1' FAKECLOCK_JUMP=31 \
  TEST_FIXTURE_SCENARIO=devin-read-never-ends spawn_base opus --host local 2>&1)"
t1492_default_rc=$?
set -e
[[ "$t1492_default_rc" -eq 1 ]] || fail "1492 default window expected rc=1, got $t1492_default_rc: $t1492_default_out"
grep -q 'shell did not execute a readiness probe within 30000ms' <<<"$t1492_default_out" ||
  fail "1492 without a key must keep the 30000ms default: $t1492_default_out"
grep -q 'timeout source: claude kind default' <<<"$t1492_default_out" ||
  fail "1492 default failure must name its source: $t1492_default_out"
echo "PASS 1492 T1: default readiness window remains 30000ms"

t1492_cfg90="$TMP/t1492-shell-ready-90000.toml"
printf '[local]\nshell_ready_timeout_ms = 90000\n' >"$t1492_cfg90"
: >"$TMP/herdr.log"
set +e
t1492_90_out="$(WRK_HOSTS_CONFIG="$t1492_cfg90" PATH="$TMP/jumpclock:$PATH" \
  FAKECLOCK_AFTER='pane run w:p1' FAKECLOCK_JUMP=91 TEST_FIXTURE_SCENARIO=devin-read-never-ends \
  spawn_base opus --host local 2>&1)"
t1492_90_rc=$?
set -e
[[ "$t1492_90_rc" -eq 1 ]] || fail "1492 configured window expected rc=1, got $t1492_90_rc: $t1492_90_out"
grep -q 'shell did not execute a readiness probe within 90000ms' <<<"$t1492_90_out" ||
  fail "1492 claude must use the configured 90000ms window: $t1492_90_out"
grep -qF "timeout source: $t1492_cfg90 [local] shell_ready_timeout_ms" <<<"$t1492_90_out" ||
  fail "1492 configured failure must name the hosts.toml key: $t1492_90_out"
echo "PASS 1492 T2: claude uses configured 90000ms window and names its source"

t1492_cfg60="$TMP/t1492-shell-ready-60000.toml"
printf '[local]\nshell_ready_timeout_ms = 60000\n' >"$t1492_cfg60"
: >"$TMP/herdr.log"
set +e
t1492_codex_out="$(WRK_HOSTS_CONFIG="$t1492_cfg60" PATH="$TMP/jumpclock:$PATH" \
  FAKECLOCK_AFTER='pane run w:p1' FAKECLOCK_JUMP=121 TEST_FIXTURE_SCENARIO=devin-read-never-ends \
  spawn_base codex-luna --host local 2>&1)"
t1492_codex_rc=$?
set -e
[[ "$t1492_codex_rc" -eq 1 ]] || fail "1492 codex window expected rc=1, got $t1492_codex_rc: $t1492_codex_out"
grep -q 'shell did not execute a readiness probe within 120000ms' <<<"$t1492_codex_out" ||
  fail "1492 configured 60000ms must not shorten codex's 120000ms default: $t1492_codex_out"
grep -q 'timeout source: codex kind default' <<<"$t1492_codex_out" ||
  fail "1492 codex failure must name the winning kind default: $t1492_codex_out"
echo "PASS 1492 T3: configured 60000ms cannot shorten codex's 120000ms window"

for t1492_bad in 1000 999999 90s duplicate; do
  t1492_badcfg="$TMP/t1492-shell-ready-bad-$t1492_bad.toml"
  case "$t1492_bad" in
    duplicate) printf '[local]\nshell_ready_timeout_ms = 90000\nshell_ready_timeout_ms = 120000\n' >"$t1492_badcfg" ;;
    *) printf '[local]\nshell_ready_timeout_ms = %s\n' "$t1492_bad" >"$t1492_badcfg" ;;
  esac
  : >"$TMP/herdr.log"
  set +e
  t1492_bad_out="$(WRK_HOSTS_CONFIG="$t1492_badcfg" TEST_FIXTURE_SCENARIO=spawn \
    spawn_base opus --host local 2>&1)"
  t1492_bad_rc=$?
  set -e
  [[ "$t1492_bad_rc" -eq 70 ]] ||
    fail "1492 invalid value $t1492_bad must refuse rc=70, got $t1492_bad_rc: $t1492_bad_out"
  grep -qF 'shell_ready_timeout_ms' <<<"$t1492_bad_out" ||
    fail "1492 refusal for $t1492_bad must name the key: $t1492_bad_out"
  grep -qF 'refusing spawn' <<<"$t1492_bad_out" ||
    fail "1492 refusal for $t1492_bad must use the spawn config refusal style: $t1492_bad_out"
  if [[ "$t1492_bad" == duplicate ]]; then
    grep -qF 'duplicate shell_ready_timeout_ms key in [local]' <<<"$t1492_bad_out" ||
      fail "1492 duplicate refusal lost its reason: $t1492_bad_out"
  else
    grep -qF 'line ' <<<"$t1492_bad_out" || fail "1492 refusal must name its config line: $t1492_bad_out"
  fi
  if grep -q '^tab create ' "$TMP/herdr.log"; then
    fail "1492 invalid value $t1492_bad created a pane: $(grep '^tab create ' "$TMP/herdr.log")"
  fi
done
echo "PASS 1492 T4: out-of-range, malformed and duplicate values refuse before pane creation"

# A shell probe that is answered only after the fake clock advances 40s must
# still pass with the configured 90s window; agent start receives the 50s left.
: >"$TMP/herdr.log"
t1492_delayed_out="$(WRK_HOSTS_CONFIG="$t1492_cfg90" PATH="$TMP/jumpclock:$PATH" \
  FAKECLOCK_AFTER='pane read w:p1' FAKECLOCK_JUMP=40 WRK_FIXTURE_RC_READS=6 \
  TEST_FIXTURE_SCENARIO=devin-slow-rc spawn_base opus --host local 2>&1)" ||
  fail "1492 readiness probe answered after 40s must pass: $t1492_delayed_out"
grep -q 'landed=yes' <<<"$t1492_delayed_out" ||
  fail "1492 delayed readiness probe did not land the spawn: $t1492_delayed_out"
grep -q '^agent start fixture --kind claude --pane w:p1 --timeout 50000 -- ' "$TMP/herdr.log" ||
  fail "1492 40s readiness cost must leave 50000ms for agent start: $(grep '^agent start ' "$TMP/herdr.log")"
echo "PASS 1492 T5: configured 90000ms window admits a probe answered after 40s"

# Mutant checks are scoped to the contract cases above: using min instead of
# max makes T3 report 60000ms; dropping the range check lets 1000 spawn.
python3 - "$WRK" "$TMP/t1492-mut-min" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
old = "if (( ${LOCAL_SHELL_READY_TIMEOUT_MS:-0} >= START_TIMEOUT )); then"
new = "if (( ${LOCAL_SHELL_READY_TIMEOUT_MS:-0} <= START_TIMEOUT )); then"
assert source.count(old) == 1, "expected one max comparison"
path = pathlib.Path(sys.argv[2])
path.write_text(source.replace(old, new, 1), encoding="utf-8")
path.chmod(0o755)
PY
: >"$TMP/herdr.log"
set +e
t1492_min_mutant_out="$(WRK_UNDER_TEST="$TMP/t1492-mut-min" WRK_HOSTS_CONFIG="$t1492_cfg60" \
  PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER='pane run w:p1' FAKECLOCK_JUMP=121 \
  TEST_FIXTURE_SCENARIO=devin-read-never-ends spawn_base codex-luna --host local 2>&1)"
t1492_min_mutant_rc=$?
set -e
[[ "$t1492_min_mutant_rc" -eq 1 ]] || fail "1492 min mutant should fail its bounded readiness probe: $t1492_min_mutant_out"
grep -q 'shell did not execute a readiness probe within 60000ms' <<<"$t1492_min_mutant_out" ||
  fail "1492 T3 did not kill the min mutant: $t1492_min_mutant_out"
echo "PASS 1492 mutant: min instead of max makes T3 RED"

python3 - "$WRK" "$TMP/t1492-mut-no-range" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
old = '''        if (( ${#value} > 6 )) || (( 10#$value < 30000 || 10#$value > 300000 )); then
          LOCAL_SPAWN_ERROR="$config line $n: [local] shell_ready_timeout_ms must be from 30000 to 300000 (got '$value')"
          return "$WRK_EXIT_CONFIG_REFUSED"
        fi
'''
assert source.count(old) == 1, "expected one timeout range guard"
path = pathlib.Path(sys.argv[2])
path.write_text(source.replace(old, "        : # mutant: range check removed\n", 1), encoding="utf-8")
path.chmod(0o755)
PY
t1492_range_mutant_cfg="$TMP/t1492-shell-ready-1000.toml"
printf '[local]\nshell_ready_timeout_ms = 1000\n' >"$t1492_range_mutant_cfg"
: >"$TMP/herdr.log"
t1492_range_mutant_out="$(WRK_UNDER_TEST="$TMP/t1492-mut-no-range" \
  WRK_HOSTS_CONFIG="$t1492_range_mutant_cfg" TEST_FIXTURE_SCENARIO=spawn \
  spawn_base opus --host local 2>&1)" ||
  fail "1492 T4 range mutant should be exposed by allowing 1000: $t1492_range_mutant_out"
grep -q 'landed=yes' <<<"$t1492_range_mutant_out" ||
  fail "1492 range mutant did not bypass the invalid-value refusal: $t1492_range_mutant_out"
grep -q '^tab create ' "$TMP/herdr.log" ||
  fail "1492 range mutant did not create the pane that T4 forbids"
echo "PASS 1492 mutant: dropping the range check makes T4 RED"

# #1199: the probe's wait is charged to the window — a second ticking over
# while the probe runs leaves the first `agent start` only the remaining
# --timeout 29000 (pre-#1199 it still got the full 30000).
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
grep -q '^agent start fixture --kind claude --pane w:p1 --timeout 29000 -- ' "$TMP/herdr.log" ||
  fail "the probe's tick must come out of the first start's window (--timeout 29000): $(grep '^agent start ' "$TMP/herdr.log")"
shell_window_case codex-luna shell-busy 'agent start ' 31
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
devin_shell_run_no="$(grep -n '^pane run w:p1 devin ' "$TMP/herdr.log" | cut -d: -f1)"
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
  DEVIN_CASE_OUT="$out"
}
devin_shell_failure_case devin-shell-never-ready 'shell not ready within 30000ms (foreground busy x120)'
# hk 1541: an unreadable reply is "not ready yet" for up to PINFO_BAD_MAX
# consecutive polls inside the same window — a run of them fails closed with
# the old reason text plus the count, and the pane count is the run plus the
# one diagnostic capture (5 + 1 = 6).
devin_shell_failure_case devin-process-info-fail 'pane process-info exited 3 before pane run (consecutive bad replies x5)'
[[ "$(grep -c '^pane process-info ' "$TMP/herdr.log")" -eq 6 ]] ||
  fail "a failed process-info must be tolerated up to the consecutive-bad budget (5 checks + one diagnostic)"
devin_shell_failure_case devin-process-info-garbage 'pane process-info returned an invalid envelope before pane run (consecutive bad replies x5)'
[[ "$(grep -c '^pane process-info ' "$TMP/herdr.log")" -eq 6 ]] ||
  fail "an unreadable process-info must be tolerated up to the consecutive-bad budget (5 checks + one diagnostic)"
# The failure artifacts carry the captured first/last bad reply verbatim.
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -f "$artifact_dir/pinfo-bad" ]] ||
  fail "1541 the devin failure artifacts must include the pinfo-bad record: $artifact_dir"
grep -q 'shell_pid.*4242' "$artifact_dir/pinfo-bad" ||
  fail "1541 pinfo-bad lost the unreadable reply's raw stdout: $(cat "$artifact_dir/pinfo-bad" 2>/dev/null)"
grep -q '=== first class=envelope rc=0 ===' "$artifact_dir/pinfo-bad" ||
  fail "1541 pinfo-bad must record the first bad reply's class and rc: $(cat "$artifact_dir/pinfo-bad" 2>/dev/null)"
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

# #604/m1b (hk:doc evidence/2026-09-24/task604-m1b-repro): the m1b herdr 0.9.0
# process-info reply has no "result" wrapper and no foreground_process_group_id
# but still names shell_pid and the foreground list. While the foreground is
# an rc-file subprocess (compinit's grep) the answer is "not ready yet" and
# must be polled inside the window — the observed m1b failure was this
# readable reply being classified as an invalid envelope after one check.
# Mutant: removing the wait types the devin argv into the busy shell (pane run
# fires on poll 1), and strict-parsing the envelope fails the spawn outright.
: >"$TMP/herdr.log"
devin_m1b_out="$(TEST_FIXTURE_SCENARIO=devin-shell-busy-m1b spawn_base devin-swe2 2>&1)" ||
  fail "m1b-shape shell ready on the fourth poll must still spawn: $devin_m1b_out"
grep -q 'landed=yes' <<<"$devin_m1b_out" ||
  fail "m1b-shape late-shell Devin did not land: $devin_m1b_out"
devin_m1b_run_no="$(grep -n '^pane run w:p1 devin ' "$TMP/herdr.log" | cut -d: -f1)"
[[ "$(head -n "$devin_m1b_run_no" "$TMP/herdr.log" | grep -c '^pane process-info --pane w:p1$')" -eq 4 ]] ||
  fail "m1b-shape Devin must poll process-info until the shell is alone in the foreground"
if grep -q '^pane close ' "$TMP/herdr.log"; then fail "m1b-shape late-shell Devin pane was closed"; fi
devin_shell_failure_case devin-shell-never-ready-m1b 'shell not ready within 30000ms (foreground busy x120)'
echo "PASS 604-m1b-envelope: unwrapped process-info polls shell-busy foreground, fail-closed at window"

# ── hk 1541: a transient unreadable process-info reply is "not ready yet" ───
# m1b 2026-10-13 08:18-08:22: a fresh pane's first process-info reply came
# back unreadable under load while a re-query moments later held a ready
# shell, and the poll discarded the raw reply so nobody ever saw it. Inside
# the same START_TIMEOUT window an unreadable reply (a non-zero rc or an
# envelope the parser cannot read) is tolerated for up to PINFO_BAD_MAX
# consecutive polls; a readable reply — ready or not — resets the run. The
# stdout, stderr and rc of the first and last bad reply land in the job's
# pinfo-bad file (every kind) and in the Devin failure artifacts.
# The frozen clock (FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0) keeps every poll
# inside the window so only the counters — never the wall clock — decide.
pinfo_seq_case() {  # NAME MODEL TOKENS... — one WRK_FIXTURE_PINFO_SEQUENCE per case
  local name="$1" model="$2"; shift 2
  printf '%s\n' "$@" >"$TMP/pinfo-seq-$name"
  rm -f "$TMP/pinfo-seq-$name.calls" "$TMP/inbox/fixture/pinfo-bad"
  mkdir -p "$TMP/pinfo-tmpdir"
  : >"$TMP/herdr.log"
  set +e
  PINFO_CASE_OUT="$(WRK_FIXTURE_PINFO_SEQUENCE="$TMP/pinfo-seq-$name" \
    TMPDIR="$TMP/pinfo-tmpdir" \
    PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 \
    TEST_FIXTURE_SCENARIO=spawn spawn_base "$model" 2>&1)"
  PINFO_CASE_RC=$?
  set -e
}

# One garbage stdout line then a ready shell: the spawn proceeds and the
# pinfo-bad file holds the reply that used to be thrown away.
pinfo_seq_case garbage-then-good devin-swe2 garbage
[[ "$PINFO_CASE_RC" -eq 0 ]] ||
  fail "1541 a single garbage reply must not fail the spawn: $PINFO_CASE_OUT"
grep -q 'landed=yes' <<<"$PINFO_CASE_OUT" ||
  fail "1541 garbage-then-good devin did not land: $PINFO_CASE_OUT"
devin_run_no="$(grep -n '^pane run w:p1 devin ' "$TMP/herdr.log" | cut -d: -f1)"
[[ "$(head -n "$devin_run_no" "$TMP/herdr.log" | grep -c '^pane process-info --pane w:p1$')" -eq 2 ]] ||
  fail "1541 the ready reply after one garbage must admit the shell on the second poll"
[[ -f "$TMP/inbox/fixture/pinfo-bad" ]] ||
  fail "1541 the raw unreadable reply was not preserved next to the spawn log"
grep -q 'not json at all' "$TMP/inbox/fixture/pinfo-bad" ||
  fail "1541 pinfo-bad lost the garbage reply's raw stdout: $(cat "$TMP/inbox/fixture/pinfo-bad" 2>/dev/null)"
grep -q '=== first class=envelope rc=0 ===' "$TMP/inbox/fixture/pinfo-bad" ||
  fail "1541 pinfo-bad must record the first bad reply's class and rc"
# The same transient on the shared non-devin path (agent start).
pinfo_seq_case claude-garbage-then-good opus garbage
[[ "$PINFO_CASE_RC" -eq 0 ]] ||
  fail "1541 a single garbage reply must not fail a claude spawn: $PINFO_CASE_OUT"
grep -q 'landed=yes' <<<"$PINFO_CASE_OUT" ||
  fail "1541 garbage-then-good claude did not land: $PINFO_CASE_OUT"
grep -q 'not json at all' "$TMP/inbox/fixture/pinfo-bad" ||
  fail "1541 claude's pinfo-bad lost the garbage reply: $(cat "$TMP/inbox/fixture/pinfo-bad" 2>/dev/null)"

# A non-zero process-info rc once, then a valid reply: proceeds, and the
# file holds the reply's rc and stderr.
pinfo_seq_case rc-then-good opus exit3
[[ "$PINFO_CASE_RC" -eq 0 ]] ||
  fail "1541 one bad rc then valid must still spawn: $PINFO_CASE_OUT"
grep -q 'landed=yes' <<<"$PINFO_CASE_OUT" ||
  fail "1541 rc-then-good claude did not land: $PINFO_CASE_OUT"
grep -q '=== first class=exit rc=3 ===' "$TMP/inbox/fixture/pinfo-bad" ||
  fail "1541 pinfo-bad must record the failed reply's rc: $(cat "$TMP/inbox/fixture/pinfo-bad" 2>/dev/null)"
grep -q 'pane_not_found' "$TMP/inbox/fixture/pinfo-bad" ||
  fail "1541 pinfo-bad lost the failed reply's raw stderr: $(cat "$TMP/inbox/fixture/pinfo-bad" 2>/dev/null)"

# PINFO_BAD_MAX consecutive unreadable replies still fail closed on the
# shared non-devin path, with the old reason text plus the count, inside the
# window — a genuinely dead pane does not spawn. 5 polls + one diagnostic.
: >"$TMP/herdr.log"; rm -f "$TMP/inbox/fixture/pinfo-bad"
set +e
pinfo_dead_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 \
  TEST_FIXTURE_SCENARIO=devin-process-info-garbage spawn_base opus 2>&1)"
pinfo_dead_rc=$?
set -e
[[ "$pinfo_dead_rc" -eq 1 ]] ||
  fail "1541 a run of unreadable replies must fail closed, got rc=$pinfo_dead_rc: $pinfo_dead_out"
grep -q 'agent start failed: pane process-info returned an invalid envelope before agent start (consecutive bad replies x5); pane=w:p1' <<<"$pinfo_dead_out" ||
  fail "1541 the fail-closed line lost the old reason text or the count: $pinfo_dead_out"
[[ "$(grep -c '^pane process-info --pane w:p1' "$TMP/herdr.log")" -eq 6 ]] ||
  fail "1541 the unreadable run must stop at the budget (5 checks + one diagnostic)"
if grep -q '^agent start ' "$TMP/herdr.log"; then
  fail "1541 agent start was called on a dead pane"
fi
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "1541 the dead pane leaked"
grep -q '=== last class=envelope rc=0 ===' "$TMP/inbox/fixture/pinfo-bad" ||
  fail "1541 the dead-pane run must still leave its last bad reply: $(cat "$TMP/inbox/fixture/pinfo-bad" 2>/dev/null)"
# The same for a non-zero-rc run on the shared path.
: >"$TMP/herdr.log"; rm -f "$TMP/inbox/fixture/pinfo-bad"
set +e
pinfo_deadrc_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 \
  TEST_FIXTURE_SCENARIO=devin-process-info-fail spawn_base opus 2>&1)"
pinfo_deadrc_rc=$?
set -e
[[ "$pinfo_deadrc_rc" -eq 1 ]] ||
  fail "1541 a run of failed calls must fail closed, got rc=$pinfo_deadrc_rc: $pinfo_deadrc_out"
grep -q 'pane process-info exited 3 before agent start (consecutive bad replies x5)' <<<"$pinfo_deadrc_out" ||
  fail "1541 the failed-rc run lost its reason or count: $pinfo_deadrc_out"

# Reset invariant: alternating bad/valid replies never form a consecutive
# run, so six bad replies interleaved with valid ones must still succeed —
# and a mutant that never resets the counter must fail on the fifth bad.
pinfo_seq_case alternating devin-swe2 \
  garbage busy garbage busy garbage busy garbage busy garbage busy garbage busy
[[ "$PINFO_CASE_RC" -eq 0 ]] ||
  fail "1541 alternating bad/valid must still spawn: $PINFO_CASE_OUT"
grep -q 'landed=yes' <<<"$PINFO_CASE_OUT" ||
  fail "1541 alternating replies did not land: $PINFO_CASE_OUT"
devin_run_no="$(grep -n '^pane run w:p1 devin ' "$TMP/herdr.log" | cut -d: -f1)"
[[ "$(head -n "$devin_run_no" "$TMP/herdr.log" | grep -c '^pane process-info --pane w:p1$')" -eq 13 ]] ||
  fail "1541 the alternating run must be admitted by the first post-sequence ready reply"
grep -q 'bad_total=6' "$TMP/inbox/fixture/pinfo-bad" ||
  fail "1541 pinfo-bad must count every bad reply it saw: $(cat "$TMP/inbox/fixture/pinfo-bad" 2>/dev/null)"
grep -q 'consecutive_bad=1' "$TMP/inbox/fixture/pinfo-bad" ||
  fail "1541 a valid reply must reset the consecutive count: $(cat "$TMP/inbox/fixture/pinfo-bad" 2>/dev/null)"
# tester D1: the poll's stderr scratch file is consumed and deleted — after
# six bad + seven good polls the scratch TMPDIR must hold nothing.
if find "$TMP/pinfo-tmpdir" -name 'wrk-pinfo-err.*' | grep -q .; then
  fail "1541 the stderr scratch file leaked into TMPDIR: $(ls "$TMP/pinfo-tmpdir")"
fi
# shellcheck disable=SC2016  # the pattern is bin/wrk source text, not an expansion
devin_trust_mutant t1541-no-reset \
  '          # stderr scratch file was never consumed; drop it here.
          pinfo_bad=0' \
  '          # stderr scratch file was never consumed; drop it here.
          :'
: >"$TMP/herdr.log"; rm -f "$TMP/pinfo-seq-alternating.calls" "$TMP/inbox/fixture/pinfo-bad"
set +e
pinfo_mut_out="$(WRK_FIXTURE_PINFO_SEQUENCE="$TMP/pinfo-seq-alternating" \
  PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 \
  TEST_FIXTURE_SCENARIO=spawn WRK_UNDER_TEST="$TMP/mut-wrk-t1541-no-reset" \
  spawn_base devin-swe2 2>&1)"
pinfo_mut_rc=$?
set -e
[[ "$pinfo_mut_rc" -eq 1 ]] ||
  fail "1541 no-reset mutant: the fifth accumulated bad reply must fail closed: $pinfo_mut_out"
grep -q 'consecutive bad replies x5' <<<"$pinfo_mut_out" ||
  fail "1541 no-reset mutant must hit the consecutive budget: $pinfo_mut_out"

# The budget cannot exceed the window: on a ticking clock the first
# unreadable reply already spent 31s of the 30s window, so the run ends on
# the window — one poll — not on the bad counter.
: >"$TMP/herdr.log"; rm -f "$TMP/inbox/fixture/pinfo-bad"
set +e
pinfo_window_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER='pane process-info ' FAKECLOCK_JUMP=31 \
  TEST_FIXTURE_SCENARIO=devin-process-info-garbage spawn_base devin-swe2 2>&1)"
pinfo_window_rc=$?
set -e
[[ "$pinfo_window_rc" -eq 1 ]] ||
  fail "1541 a spent window must close the run, got rc=$pinfo_window_rc: $pinfo_window_out"
grep -q 'shell not ready within 30000ms (foreground busy x1, unreadable replies x1)' <<<"$pinfo_window_out" ||
  fail "1541 the window failure must name the unreadable count: $pinfo_window_out"
[[ "$(grep -c '^pane process-info ' "$TMP/herdr.log")" -eq 2 ]] ||
  fail "1541 the retry budget must not exceed the window (one poll + one diagnostic)"
echo "PASS 1541: transient unreadable process-info tolerated, counted, preserved, window-bound"

# #979 (Pi incident, jobs/971-stale-race-20260929-1848): a fresh pane can hold
# the shell alone in the foreground while zsh sits in a pending rc-file read
# — omz's update check holds `read -k 1`, which ate the `d` of the typed
# `devin` and left `evin` to run. process-info cannot see it, so after the
# foreground check passes wrk types a space-prefixed printf probe carrying a
# fresh token and requires the token back as its own output line before the
# agent argv is typed; ANY token this spawn typed counts, because lines
# queued behind a still-sourcing rc all execute when the prompt arrives and
# a `read -k 1` that ate the leading space still runs the remainder. An
# unanswered probe is only ever RETYPED — never interrupted: fix-round-1
# showed ctrl+c during rc sourcing SIGINTs the rest of the rc and leaves the
# agent in a truncated environment. The `herdr pane run` call site that
# types into a fresh shell pane is devin_start_in_pane; #1016 then runs the
# same probe inside agent_start_in_pane too, because `agent start` has
# herdr type the argv into that same fresh shell behind the identical
# foreground gate (the #1016 cases below cover that path).
t979_xdg="$TMP/t979-xdg"
devin_trust_seed_store "$t979_xdg" "$ROOT" "$(cd "$ROOT" && pwd -P)"

# AC3: an ordinary ready shell — exactly one probe line and one agent command
# typed, the probe's token answered on the first pane read, spawn rc 0.
: >"$TMP/herdr-t979-normal.log"; rm -f "$TMP/herdr-t979-normal.log.executed"
devin_normal_out="$(TEST_FIXTURE_SCENARIO=devin-idle devin_spawn_at "$t979_xdg" "$ROOT" t979-normal "$(mint_task)" 2>&1)" ||
  fail "ready-shell devin spawn failed: $devin_normal_out"
grep -q 'landed=yes' <<<"$devin_normal_out" || fail "ready-shell devin did not land: $devin_normal_out"
t979_log="$TMP/herdr-t979-normal.log"
[[ "$(grep -c '^pane run ' "$t979_log")" -eq 2 ]] ||
  fail "ready shell must see exactly one probe and one agent run: $(grep '^pane run ' "$t979_log")"
grep -qE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-[0-9-]+'" "$t979_log" ||
  fail "probe line missing or not space-prefixed printf: $(grep '^pane run ' "$t979_log")"
[[ "$(grep -c '^pane read w:p1 ' "$t979_log")" -eq 1 ]] ||
  fail "answered probe must cost exactly one pane read (one poll): $(grep -c '^pane read ' "$t979_log")"
t979_probe_no="$(grep -nE "^pane run w:p1 +printf" "$t979_log" | cut -d: -f1)"
t979_read_no="$(grep -n '^pane read w:p1 ' "$t979_log" | cut -d: -f1)"
t979_agent_no="$(grep -n '^pane run w:p1 devin ' "$t979_log" | cut -d: -f1)"
(( t979_probe_no < t979_read_no && t979_read_no < t979_agent_no )) ||
  fail "probe must be typed, its output read, and only then the agent command"
if grep -q '^pane send-keys ' "$t979_log"; then
  fail "wrk must never interrupt a shell that may still be sourcing its rc file: $(grep '^pane send-keys ' "$t979_log")"
fi
echo "PASS 979-AC3 ready shell: one probe, one read, one agent run"

# The Pi shape exactly: `read -k 1` eats the first CHARACTER (the probe's
# leading space) and the remainder `printf …` still runs — the probe passes
# on the first try with no retype and no interrupt.
: >"$TMP/herdr-t979-key.log"; rm -f "$TMP/herdr-t979-key.log.executed"
devin_key_out="$(TEST_FIXTURE_SCENARIO=devin-read-eats-key devin_spawn_at "$t979_xdg" "$ROOT" t979-key "$(mint_task)" 2>&1)" ||
  fail "Devin behind a pending read -k 1 must still spawn: $devin_key_out"
grep -q 'landed=yes' <<<"$devin_key_out" || fail "read -k 1 devin did not land: $devin_key_out"
t979_log="$TMP/herdr-t979-key.log"
[[ "$(grep -cE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-" "$t979_log")" -eq 1 ]] ||
  fail "a read -k 1-eaten probe must still execute its remainder: $(grep '^pane run ' "$t979_log")"
[[ "$(grep -c '^pane run w:p1 devin ' "$t979_log")" -eq 1 ]] ||
  fail "devin argv must be typed exactly once, after the shell proved it runs lines"
grep -qx 'devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' \
  "$t979_log.executed" ||
  fail "the fake shell must execute the full devin argv: $(cat "$t979_log.executed")"
if grep -q '^pane send-keys ' "$t979_log"; then
  fail "wrk must never interrupt a shell that may still be sourcing its rc file: $(grep '^pane send-keys ' "$t979_log")"
fi
echo "PASS 979 eaten first char (read -k 1): probe remainder ran, no retype"

# AC1: a pending full-line read consumes the first typed line — the probe
# goes unanswered, it is retyped with a new token (retype only, never an
# interrupt), and the full devin argv then lands unharmed.
: >"$TMP/herdr-t979-eaten.log"; rm -f "$TMP/herdr-t979-eaten.log.executed"
devin_eaten_out="$(TEST_FIXTURE_SCENARIO=devin-read-eats-line devin_spawn_at "$t979_xdg" "$ROOT" t979-eaten "$(mint_task)" 2>&1)" ||
  fail "Devin behind a pending read must still spawn: $devin_eaten_out"
grep -q 'landed=yes' <<<"$devin_eaten_out" || fail "eaten-line devin did not land: $devin_eaten_out"
t979_log="$TMP/herdr-t979-eaten.log"
[[ "$(grep -cE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-" "$t979_log")" -eq 2 ]] ||
  fail "unanswered probe must be retyped with a fresh token: $(grep '^pane run ' "$t979_log")"
if grep -q '^pane send-keys ' "$t979_log"; then
  fail "wrk must never interrupt a shell that may still be sourcing its rc file: $(grep '^pane send-keys ' "$t979_log")"
fi
[[ "$(grep -c '^pane run w:p1 devin ' "$t979_log")" -eq 1 ]] ||
  fail "devin argv must be typed exactly once, after the shell proved it runs lines"
grep -qx 'devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' \
  "$t979_log.executed" ||
  fail "the fake shell must execute the full devin argv: $(cat "$t979_log.executed")"
[[ "$(grep -c 'wrk-ready-' "$t979_log.executed")" -eq 1 ]] ||
  fail "the retried probe — and not the eaten one — must be the only executed probe"
grep -qx 'env=full' "$t979_log.devenv" ||
  fail "devin must inherit the fully-sourced rc environment: $(cat "$t979_log.devenv" 2>/dev/null)"
echo "PASS 979-AC1 eaten first line: probe retried, agent argv intact, rc 0"

# The fix-round-1 hazard: rc still sourcing while probes are typed. Lines
# queue and ALL execute when rc finishes — the answer to an earlier probe is
# proof, the spawn lands with the full environment, and no ctrl+c is sent.
: >"$TMP/herdr-t979-slowrc.log"; rm -f "$TMP/herdr-t979-slowrc.log.executed" "$TMP/herdr-t979-slowrc.log.devenv"
devin_slowrc_out="$(TEST_FIXTURE_SCENARIO=devin-slow-rc devin_spawn_at "$t979_xdg" "$ROOT" t979-slowrc "$(mint_task)" 2>&1)" ||
  fail "Devin behind a slow rc file must still spawn: $devin_slowrc_out"
grep -q 'landed=yes' <<<"$devin_slowrc_out" || fail "slow-rc devin did not land: $devin_slowrc_out"
t979_log="$TMP/herdr-t979-slowrc.log"
[[ "$(grep -cE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-" "$t979_log")" -gt 1 ]] ||
  fail "an unanswered probe behind a slow rc must be retyped inside the window: $(grep '^pane run ' "$t979_log")"
if grep -q '^pane send-keys ' "$t979_log"; then
  fail "wrk must never interrupt a shell that may still be sourcing its rc file: $(grep '^pane send-keys ' "$t979_log")"
fi
grep -qx 'env=full' "$t979_log.devenv" ||
  fail "devin must inherit the fully-sourced rc environment, not a ctrl+c-truncated one: $(cat "$t979_log.devenv" 2>/dev/null)"
grep -qx 'devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' \
  "$t979_log.executed" ||
  fail "the fake shell must execute the full devin argv: $(cat "$t979_log.executed")"
echo "PASS 979 slow rc: queued probes answered late, full env, no interrupt"

# AC2: a pending read that never ends — the probe is never answered, the
# spawn fails inside START_TIMEOUT with its own reason, the pane is cleaned
# up as today, and the agent command is never typed.
: >"$TMP/herdr-t979-stuck.log"
set +e
devin_stuck_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 \
  TEST_FIXTURE_SCENARIO=devin-read-never-ends devin_spawn_at "$t979_xdg" "$ROOT" t979-stuck "$(mint_task)" 2>&1)"
devin_stuck_rc=$?
set -e
[[ "$devin_stuck_rc" -eq 1 ]] || fail "never-answering probe expected rc=1, got $devin_stuck_rc: $devin_stuck_out"
grep -q 'Devin pane startup failed: shell did not execute a readiness probe within 30000ms' <<<"$devin_stuck_out" ||
  fail "never-answering probe lost its distinct diagnostic: $devin_stuck_out"
t979_log="$TMP/herdr-t979-stuck.log"
[[ "$(grep -cE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-" "$t979_log")" -gt 1 ]] ||
  fail "an unanswered probe must be retyped inside the window"
if grep -q '^pane send-keys ' "$t979_log"; then
  fail "wrk must never interrupt a shell that may still be sourcing its rc file: $(grep '^pane send-keys ' "$t979_log")"
fi
if grep -q '^pane run w:p1 devin ' "$t979_log"; then
  fail "agent command was typed into a shell that never executed a probe"
fi
grep -qx 'pane close w:p1' "$t979_log" || fail "never-answering probe leaked its pane"
if grep -q '^agent prompt ' "$t979_log"; then fail "never-answering probe delivered a brief"; fi
grep -q 'Devin spawn failure artifacts preserved under ' <<<"$devin_stuck_out" ||
  fail "never-answering probe must keep the existing diagnostics path: $devin_stuck_out"
echo "PASS 979-AC2 probe never answered: distinct reason, pane closed, no agent run"

# No devin scenario may ever send pane keys — a ctrl+c into a still-sourcing
# rc truncates the environment the agent then inherits.
for t979_log in "$TMP"/herdr*.log; do
  if grep -q '^pane send-keys ' "$t979_log" 2>/dev/null; then
    fail "pane send-keys reached a devin pane in $t979_log: $(grep '^pane send-keys ' "$t979_log")"
  fi
done

# AC6 mutants — assertion-RED invariants:
#   M1 "the agent command is typed only after the shell has executed a probe"
#      (mutant: ready foreground returns immediately, skipping the probe)
#   M2 "a probe line that echoed but did not run is not proof"
#      (mutant: substring match accepts the echoed command line)
#   M3 "wrk never interrupts a shell that may still be sourcing its rc file"
#      (mutant: ctrl+c after the miss count, then retype)
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
devin_trust_mutant t979-no-probe \
  'if [[ "$ready" == yes ]]; then devin_probe_send || return 1; fi' \
  'if [[ "$ready" == yes ]]; then return 0; fi'
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
devin_trust_mutant t979-echo-match \
  'grep -qxF "$probe_any"' \
  'grep -qF "$probe_any"'
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
devin_trust_mutant t979-ctrl-c \
  '(( probe_misses >= DEVIN_PROBE_MISS_POLLS )) && probe_token=""' \
  '(( probe_misses >= DEVIN_PROBE_MISS_POLLS )) && { "$HERDR" pane send-keys "$PANE" ctrl+c >/dev/null 2>&1 || true; probe_token=""; }'
set +e
t979_m1_out="$(TEST_FIXTURE_SCENARIO=devin-read-eats-line WRK_UNDER_TEST="$TMP/mut-wrk-t979-no-probe" \
  devin_spawn_at "$t979_xdg" "$ROOT" t979-m1 "$(mint_task)" 2>&1)"
t979_m1_rc=$?
t979_m2_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 \
  TEST_FIXTURE_SCENARIO=devin-read-never-ends WRK_UNDER_TEST="$TMP/mut-wrk-t979-echo-match" \
  devin_spawn_at "$t979_xdg" "$ROOT" t979-m2 "$(mint_task)" 2>&1)"
t979_m2_rc=$?
rm -f "$TMP/herdr-t979-m3.log.devenv"
t979_m3_out="$(TEST_FIXTURE_SCENARIO=devin-slow-rc WRK_UNDER_TEST="$TMP/mut-wrk-t979-ctrl-c" \
  devin_spawn_at "$t979_xdg" "$ROOT" t979-m3 "$(mint_task)" 2>&1)"
t979_m3_rc=$?
set -e
# M1 under AC1's eaten-line pane: the devin argv itself is consumed, so the
# spawn must NOT reach the OK line (real run expects rc 0 + landed=yes).
[[ "$t979_m1_rc" -ne 0 ]] ||
  fail "M1 (probe skipped): spawn succeeded despite the eaten agent line: $t979_m1_out"
if grep -q '^OK ' <<<"$t979_m1_out"; then
  fail "M1 (probe skipped): OK line printed for an eaten agent command: $t979_m1_out"
fi
# M2 under AC2's never-ending read: the echoed probe is accepted as proof, so
# the agent command gets typed into the dead shell — the spawn must fail, and
# NOT with the never-answered reason the real check produces.
[[ "$t979_m2_rc" -ne 0 ]] ||
  fail "M2 (echo accepted): spawn succeeded on a pane that only echoes: $t979_m2_out"
if grep -q 'shell did not execute a readiness probe' <<<"$t979_m2_out"; then
  fail "M2 (echo accepted) lost the divergence: substring match must pass the echo and fail downstream"
fi
grep -q '^pane run w:p1 devin ' "$TMP/herdr-t979-m2.log" ||
  fail "M2 (echo accepted) proof — the agent command must have been (wrongly) typed"
# M3 under the slow-rc pane: the ctrl+c ends rc early — the spawn still lands
# (queued probes run), but the devin argv executes in a truncated
# environment. The real assertion it breaks is the slow-rc case's env=full.
[[ "$t979_m3_rc" -eq 0 ]] ||
  fail "M3 (ctrl+c sent): spawn was expected to land truncated, not fail: $t979_m3_out"
grep -qx 'env=truncated' "$TMP/herdr-t979-m3.log.devenv" ||
  fail "M3 (ctrl+c sent) must truncate the rc environment devin inherits: $(cat "$TMP/herdr-t979-m3.log.devenv" 2>/dev/null)"
grep -q '^pane send-keys w:p1 ctrl+c' "$TMP/herdr-t979-m3.log" ||
  fail "M3 (ctrl+c sent) proof — the interrupt must appear in the herdr log"
echo "PASS 979-AC6 mutants red: M1 skip-probe, M2 echo-as-proof, M3 ctrl+c"

# #1016 (979 tester SHOULD S2): `agent start` types the agent argv into the
# same fresh pane shell and gates only on agent_pane_busy — the foreground
# check a pending rc-file read defeats. wrk now runs the identical
# retype-only readiness probe before the first agent start for every
# non-devin kind, inside the same START_TIMEOUT window — and #1199 makes
# that sharing real by charging the probe's cost to the first start's
# --timeout. These cases rerun the 979 pending-read scenarios against every
# non-devin kind wrk supports (S3: claude, codex, grok, kimi, kiro,
# opencode, agy); the fixture records every line the fake shell executes in
# $LOG.executed, so an eaten first character shows up as the truncated argv
# (e.g. `laude`).
T1016_KIND_PAIRS=(
  'opus|claude --model opus --dangerously-skip-permissions --effort high'
  'codex-luna|codex --yolo -m gpt-6-luna -c model_reasoning_effort=medium'
  'grok|grok --always-approve -m grok-4.7 --effort high'
  'kimi-k3|kimi --auto -m kimi-code/k3'
  'kiro|kiro chat --v3 --trust-all-tools --require-mcp-startup --effort high'
  'oc-solar4|opencode --auto --model upstage/solar-pro4'
  'agy-flash|agy --model gemini-3.7-flash-high --dangerously-skip-permissions'
)
# S2: the probe-line assertion is whole-line anchored — the logged
# `pane run` must be exactly the space-prefixed printf token line, so an
# argv appended to it (mutant below) does not pass.
t1016_probe_line() {  # LOG — print the probe `pane run` line count (retypes count too)
  grep -cE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-[0-9]+-[0-9]+-[0-9]+'$" "$1"
}

# AC1 (the Pi shape): `read -k 1` eats the probe's leading space, the
# printf remainder still runs and returns the token, and only then herdr
# types the agent argv — whole.
for t1016_pair in "${T1016_KIND_PAIRS[@]}"; do
  t1016_model="${t1016_pair%%|*}"; t1016_argv="${t1016_pair#*|}"
  : >"$TMP/herdr.log"; rm -f "$TMP/herdr.log.executed"
  t1016_out="$(TEST_FIXTURE_SCENARIO=devin-read-eats-key spawn_base "$t1016_model" 2>&1)" ||
    fail "$t1016_model behind a pending read -k 1 must still spawn: $t1016_out"
  grep -q 'landed=yes' <<<"$t1016_out" ||
    fail "$t1016_model behind a pending read -k 1 did not land: $t1016_out"
  [[ "$(t1016_probe_line "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$t1016_model: a read -k 1-eaten probe must still execute its remainder: $(grep '^pane run ' "$TMP/herdr.log")"
  [[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$t1016_model: agent start must run exactly once, after the shell proved it runs lines"
  t1016_probe_no="$(grep -nE "^pane run w:p1 +printf" "$TMP/herdr.log" | cut -d: -f1)"
  t1016_start_no="$(grep -n '^agent start ' "$TMP/herdr.log" | cut -d: -f1)"
  (( t1016_probe_no < t1016_start_no )) ||
    fail "$t1016_model: the readiness probe must be typed before agent start"
  grep -qx "$t1016_argv" "$TMP/herdr.log.executed" ||
    fail "$t1016_model: the fake shell must execute the whole agent argv: $(cat "$TMP/herdr.log.executed" 2>/dev/null)"
  if grep -q '^pane send-keys ' "$TMP/herdr.log"; then
    fail "$t1016_model: wrk must never interrupt a shell that may still be sourcing its rc file"
  fi
done
echo "PASS 1016-AC1 read -k 1: probe remainder runs, argv typed whole (all 7 non-devin kinds)"

# AC1 whole-line variant: a pending `read` consumes the first probe, it is
# retyped with a fresh token, and the agent argv lands unharmed.
for t1016_pair in "${T1016_KIND_PAIRS[@]}"; do
  t1016_model="${t1016_pair%%|*}"; t1016_argv="${t1016_pair#*|}"
  : >"$TMP/herdr.log"; rm -f "$TMP/herdr.log.executed"
  t1016_out="$(TEST_FIXTURE_SCENARIO=devin-read-eats-line spawn_base "$t1016_model" 2>&1)" ||
    fail "$t1016_model behind a pending read must still spawn: $t1016_out"
  grep -q 'landed=yes' <<<"$t1016_out" || fail "eaten-line $t1016_model did not land: $t1016_out"
  [[ "$(t1016_probe_line "$TMP/herdr.log")" -eq 2 ]] ||
    fail "$t1016_model: unanswered probe must be retyped with a fresh token: $(grep '^pane run ' "$TMP/herdr.log")"
  grep -qx "$t1016_argv" "$TMP/herdr.log.executed" ||
    fail "$t1016_model: the fake shell must execute the whole agent argv: $(cat "$TMP/herdr.log.executed" 2>/dev/null)"
  if grep -q '^pane send-keys ' "$TMP/herdr.log"; then
    fail "$t1016_model: wrk must never interrupt a shell that may still be sourcing its rc file"
  fi
done
echo "PASS 1016-AC1 eaten first line: probe retried, argv intact (all 7 kinds)"

# And the still-sourcing rc: probes queue unexecuted until rc finishes,
# every queued line then runs in order, and the agent argv lands whole.
for t1016_pair in "${T1016_KIND_PAIRS[@]}"; do
  t1016_model="${t1016_pair%%|*}"; t1016_argv="${t1016_pair#*|}"
  : >"$TMP/herdr.log"; rm -f "$TMP/herdr.log.executed"
  t1016_out="$(TEST_FIXTURE_SCENARIO=devin-slow-rc spawn_base "$t1016_model" 2>&1)" ||
    fail "$t1016_model behind a slow rc file must still spawn: $t1016_out"
  grep -q 'landed=yes' <<<"$t1016_out" || fail "slow-rc $t1016_model did not land: $t1016_out"
  [[ "$(t1016_probe_line "$TMP/herdr.log")" -gt 1 ]] ||
    fail "$t1016_model: an unanswered probe behind a slow rc must be retyped inside the window: $(grep '^pane run ' "$TMP/herdr.log")"
  grep -qx "$t1016_argv" "$TMP/herdr.log.executed" ||
    fail "$t1016_model: the fake shell must execute the whole agent argv: $(cat "$TMP/herdr.log.executed" 2>/dev/null)"
  if grep -q '^pane send-keys ' "$TMP/herdr.log"; then
    fail "$t1016_model: wrk must never interrupt a shell that may still be sourcing its rc file"
  fi
done
echo "PASS 1016-AC1 slow rc: queued probes answered late, argv whole (all 7 kinds)"

# AC2: a pending read that never ends — the probe is never answered, the
# spawn fails inside START_TIMEOUT with its own reason (distinct from the
# agent_pane_busy refusal above), the pane is closed, and `agent start` is
# never called.
for t1016_pair in "${T1016_KIND_PAIRS[@]}"; do
  t1016_model="${t1016_pair%%|*}"; t1016_argv="${t1016_pair#*|}"
  t1016_kind="${t1016_argv%% *}"
  case "$t1016_kind" in
    codex|kiro) t1016_window=120000 ;;
    kimi) t1016_window=90000 ;;
    *) t1016_window=30000 ;;
  esac
  : >"$TMP/herdr.log"
  set +e
  t1016_never_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 \
    TEST_FIXTURE_SCENARIO=devin-read-never-ends spawn_base "$t1016_model" 2>&1)"
  t1016_never_rc=$?
  set -e
  [[ "$t1016_never_rc" -eq 1 ]] ||
    fail "$t1016_model: never-answering probe expected rc=1, got $t1016_never_rc: $t1016_never_out"
  grep -q "agent start failed: shell did not execute a readiness probe within ${t1016_window}ms (probes typed x" <<<"$t1016_never_out" ||
    fail "$t1016_model: never-answering probe lost its distinct diagnostic: $t1016_never_out"
  [[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 0 ]] ||
    fail "$t1016_model: agent start must never be called for a shell that never executed a probe"
  grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "$t1016_model: never-answering probe leaked its pane"
  if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "$t1016_model: never-answering probe delivered a brief"; fi
done
echo "PASS 1016-AC2 never-ready shell: distinct reason, pane closed, no agent start (all 7 kinds)"

# AC3: an ordinary ready shell — exactly one probe (one `pane run` + one
# `pane read`) and one `agent start` per non-devin spawn, probe strictly
# first.
for t1016_pair in "${T1016_KIND_PAIRS[@]}"; do
  t1016_model="${t1016_pair%%|*}"; t1016_argv="${t1016_pair#*|}"
  : >"$TMP/herdr.log"; rm -f "$TMP/herdr.log.executed"
  t1016_out="$(TEST_FIXTURE_SCENARIO=spawn spawn_base "$t1016_model" 2>&1)" ||
    fail "$t1016_model: ready-shell spawn failed: $t1016_out"
  grep -q 'landed=yes' <<<"$t1016_out" || fail "$t1016_model: ready shell did not land: $t1016_out"
  [[ "$(grep -c '^pane run ' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$t1016_model: a normal agent spawn must type only the probe: $(grep '^pane run ' "$TMP/herdr.log")"
  [[ "$(t1016_probe_line "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$t1016_model: probe line missing or not exactly the space-prefixed printf token: $(grep '^pane run ' "$TMP/herdr.log")"
  [[ "$(grep -c '^pane read w:p1 ' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$t1016_model: answered probe must cost exactly one pane read: $(grep -c '^pane read ' "$TMP/herdr.log")"
  [[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$t1016_model: ready shell must see exactly one agent start"
  t1016_probe_no="$(grep -nE "^pane run w:p1 +printf" "$TMP/herdr.log" | cut -d: -f1)"
  t1016_read_no="$(grep -n '^pane read w:p1 ' "$TMP/herdr.log" | cut -d: -f1)"
  t1016_start_no="$(grep -n '^agent start ' "$TMP/herdr.log" | cut -d: -f1)"
  (( t1016_probe_no < t1016_read_no && t1016_read_no < t1016_start_no )) ||
    fail "$t1016_model: probe must be typed, its output read, and only then agent start"
  grep -qx "$t1016_argv" "$TMP/herdr.log.executed" ||
    fail "$t1016_model: the fake shell must execute the whole agent argv: $(cat "$TMP/herdr.log.executed" 2>/dev/null)"
  if grep -q '^pane send-keys ' "$TMP/herdr.log"; then
    fail "$t1016_model: wrk must never interrupt a shell that may still be sourcing its rc file"
  fi
done
echo "PASS 1016-AC3 normal path: one probe, one read, one agent start, argv whole (all 7 kinds)"

# #1199 AC1 — the probe and the agent start retries share ONE window. A
# two-stage fake clock models a probe answered 26s in (the first `pane
# read` after it) plus 3s more once `agent start` has run: the first start
# must be handed only the window the probe left (assert the exact argv),
# and a busy answer after that must close the window with a line naming
# the probe's 26s share — not "agent_pane_busy x1" alone.
mkdir -p "$TMP/probeclock"
cat >"$TMP/probeclock/date" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == +%s ]]; then
  if grep -q '^agent start ' "$WRK_FIXTURE_LOG" 2>/dev/null; then echo 200000;
  elif grep -q '^pane read ' "$WRK_FIXTURE_LOG" 2>/dev/null; then echo 1026;
  else echo 1000; fi
  exit 0
fi
exec /bin/date "$@"
SH
chmod +x "$TMP/probeclock/date"
for t1199_pair in "${T1016_KIND_PAIRS[@]}"; do
  t1199_model="${t1199_pair%%|*}"; t1199_argv="${t1199_pair#*|}"
  t1199_kind="${t1199_argv%% *}"; t1199_args="${t1199_argv#* }"
  case "$t1199_kind" in
    codex|kiro) t1199_window=120000 ;;
    kimi) t1199_window=90000 ;;
    *) t1199_window=30000 ;;
  esac
  t1199_timeout=$(( t1199_window - 26000 ))
  : >"$TMP/herdr.log"; rm -f "$TMP/herdr.log.executed"
  t1199_out="$(PATH="$TMP/probeclock:$PATH" TEST_FIXTURE_SCENARIO=spawn spawn_base "$t1199_model" 2>&1)" ||
    fail "$t1199_model: spawn behind a 26s probe must still land: $t1199_out"
  grep -q 'landed=yes' <<<"$t1199_out" ||
    fail "$t1199_model: late-probe spawn did not land: $t1199_out"
  grep -qx "agent start fixture --kind $t1199_kind --pane w:p1 --timeout $t1199_timeout -- $t1199_args" "$TMP/herdr.log" ||
    fail "$t1199_model: the probe and agent start share one window — first start must get the ${t1199_timeout}ms the probe left: $(grep '^agent start ' "$TMP/herdr.log")"
  [[ "$(t1016_probe_line "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$t1199_model: exactly one probe line expected: $(grep '^pane run ' "$TMP/herdr.log")"
  grep -qx "$t1199_argv" "$TMP/herdr.log.executed" ||
    fail "$t1199_model: the fake shell must execute the whole agent argv: $(cat "$TMP/herdr.log.executed" 2>/dev/null)"
done
echo "PASS 1199-AC1 late probe: first start gets the window's remainder (all 7 kinds)"

# A busy answer on that reduced start then hits the window guard — and the
# failure line must name the probe's 26s share next to the busy count.
for t1199_pair in "${T1016_KIND_PAIRS[@]}"; do
  t1199_model="${t1199_pair%%|*}"; t1199_argv="${t1199_pair#*|}"
  t1199_kind="${t1199_argv%% *}"
  case "$t1199_kind" in
    codex|kiro) t1199_window=120000 ;;
    kimi) t1199_window=90000 ;;
    *) t1199_window=30000 ;;
  esac
  : >"$TMP/herdr.log"
  set +e
  t1199_busy_out="$(PATH="$TMP/probeclock:$PATH" TEST_FIXTURE_SCENARIO=shell-busy spawn_base "$t1199_model" 2>&1)"
  t1199_busy_rc=$?
  set -e
  [[ "$t1199_busy_rc" -eq 1 ]] ||
    fail "$t1199_model: busy after a late probe must fail closed, got rc=$t1199_busy_rc: $t1199_busy_out"
  grep -q "shell not ready within the ${t1199_window}ms window (readiness probe used 26000ms, agent_pane_busy x1); pane=w:p1" <<<"$t1199_busy_out" ||
    fail "$t1199_model: the spent-window line must name the probe's share: $t1199_busy_out"
  [[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$t1199_model: one busy start, then the window must close"
  grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "$t1199_model: spent-window spawn leaked its pane"
done
echo "PASS 1199-AC1 busy after late probe: failure names the probe's share (all 7 kinds)"

# AC4/AC5 mutants — assertion-RED invariants:
#   M1 "a non-devin argv is never typed before the shell has executed a
#      probe" (mutant: skip the wait in agent_start_in_pane) -> AC1 fails
#   M2 "a never-ready shell never gets agent start" (mutant: ignore the
#      wait's failure) -> AC2 fails
#   M3 "the probe and agent start share one window" (mutant: the first
#      start is handed the full window again) -> 1199-AC1 fails
#   M4 "the probe pane-run line is asserted whole" (mutant: an argv is
#      appended to the probe line) -> AC3's anchored probe assertion fails
#   M5 "every non-devin kind is probed" (mutant: the probe is skipped for
#      kimi only) -> AC1's kimi case fails on the eaten argv
# Anchors: the gate if-block followed by the #1199 refresh lines is unique
# to agent_start_in_pane — devin_start_in_pane ends its own identical
# if-block with `set +e`, and `probe_used_ms` exists only on this path.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
devin_trust_mutant t1016-no-wait \
  'if ! devin_wait_shell_ready "$started_at"; then
    spawn_pane_cleanup
    return 1
  fi
  # #1199: the probe shares that window only if its cost is charged to it —
  # re-read the clock at the gate exit so the first `agent start` is handed
  # just the remaining window, and keep the probe share in probe_used_ms so
  # a spent window names the phase that consumed it.
  now="$(date +%s)"
  probe_used_ms=$(( (now - started_at) * 1000 ))
  max_attempts' \
  'now="$(date +%s)"
  probe_used_ms=$(( (now - started_at) * 1000 ))
  max_attempts'
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
devin_trust_mutant t1016-ignore-wait \
  'if ! devin_wait_shell_ready "$started_at"; then
    spawn_pane_cleanup
    return 1
  fi
  # #1199: the probe shares that window only if its cost is charged to it —
  # re-read the clock at the gate exit so the first `agent start` is handed
  # just the remaining window, and keep the probe share in probe_used_ms so
  # a spent window names the phase that consumed it.
  now="$(date +%s)"
  probe_used_ms=$(( (now - started_at) * 1000 ))
  max_attempts' \
  'devin_wait_shell_ready "$started_at" || true
  # #1199: the probe shares that window only if its cost is charged to it —
  # re-read the clock at the gate exit so the first `agent start` is handed
  # just the remaining window, and keep the probe share in probe_used_ms so
  # a spent window names the phase that consumed it.
  now="$(date +%s)"
  probe_used_ms=$(( (now - started_at) * 1000 ))
  max_attempts'
# M3: the pre-#1199 shape — the post-gate clock is never refreshed, so the
# first start is handed the full window no matter what the probe spent.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
devin_trust_mutant t1199-full-window \
  'now="$(date +%s)"
  probe_used_ms=$(( (now - started_at) * 1000 ))
  max_attempts' \
  'now="$started_at"
  probe_used_ms=0
  max_attempts'
# M4: an argv appended to the probe line — the probe still executes, but
# the whole-line assertion must reject the polluted `pane run`.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
devin_trust_mutant t1199-probe-extra-arg \
  '"$HERDR" pane run "$PANE" " printf '"'"'%s\\n'"'"' '"'"'$probe_token'"'"'" >/dev/null' \
  '"$HERDR" pane run "$PANE" " printf '"'"'%s\\n'"'"' '"'"'$probe_token'"'"' && echo polluted" >/dev/null'
# M5: skip the probe for kimi only — the kimi AC1 case must go RED on the
# eaten argv while every other kind still lands.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
devin_trust_mutant t1199-skip-kimi \
  'if ! devin_wait_shell_ready "$started_at"; then
    spawn_pane_cleanup
    return 1
  fi
  # #1199: the probe shares that window only if its cost is charged to it —' \
  'if [[ "$PROFILE_KIND" == kimi ]] || devin_wait_shell_ready "$started_at"; then :; else
    spawn_pane_cleanup
    return 1
  fi
  # #1199: the probe shares that window only if its cost is charged to it —'
set +e
: >"$TMP/herdr.log"; rm -f "$TMP/herdr.log.executed"
t1016_m1_out="$(TEST_FIXTURE_SCENARIO=devin-read-eats-key WRK_UNDER_TEST="$TMP/mut-wrk-t1016-no-wait" \
  spawn_base opus 2>&1)"
t1016_m1_rc=$?
# M1's evidence is captured before M2 resets the shared log — the
# never-ends pane below never executes a line, so it leaves no record.
t1016_m1_starts="$(grep -c '^agent start ' "$TMP/herdr.log" 2>/dev/null || true)"
t1016_m1_laude=0
grep -qx 'laude --model opus --dangerously-skip-permissions --effort high' \
  "$TMP/herdr.log.executed" 2>/dev/null && t1016_m1_laude=1
: >"$TMP/herdr.log"; rm -f "$TMP/herdr.log.executed"
t1016_m2_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 \
  TEST_FIXTURE_SCENARIO=devin-read-never-ends WRK_UNDER_TEST="$TMP/mut-wrk-t1016-ignore-wait" \
  spawn_base opus 2>&1)"
t1016_m2_rc=$?
: >"$TMP/herdr.log"; rm -f "$TMP/herdr.log.executed"
t1199_m3_out="$(PATH="$TMP/probeclock:$PATH" TEST_FIXTURE_SCENARIO=spawn \
  WRK_UNDER_TEST="$TMP/mut-wrk-t1199-full-window" spawn_base opus 2>&1)"
t1199_m3_rc=$?
t1199_m3_start="$(grep '^agent start ' "$TMP/herdr.log" 2>/dev/null || true)"
: >"$TMP/herdr.log"; rm -f "$TMP/herdr.log.executed"
t1199_m4_out="$(TEST_FIXTURE_SCENARIO=spawn WRK_UNDER_TEST="$TMP/mut-wrk-t1199-probe-extra-arg" \
  spawn_base opus 2>&1)"
t1199_m4_rc=$?
t1199_m4_anchored=0
[[ "$(t1016_probe_line "$TMP/herdr.log")" -eq 1 ]] && t1199_m4_anchored=1
: >"$TMP/herdr.log"; rm -f "$TMP/herdr.log.executed"
t1199_m5_out="$(TEST_FIXTURE_SCENARIO=devin-read-eats-key WRK_UNDER_TEST="$TMP/mut-wrk-t1199-skip-kimi" \
  spawn_base kimi-k3 2>&1)"
t1199_m5_rc=$?
t1199_m5_eaten=0
grep -qx 'imi --auto -m kimi-code/k3' "$TMP/herdr.log.executed" 2>/dev/null && t1199_m5_eaten=1
# Control: the same mutant must leave every other kind's probe in place.
: >"$TMP/herdr.log"; rm -f "$TMP/herdr.log.executed"
t1199_m5_ctl_out="$(TEST_FIXTURE_SCENARIO=devin-read-eats-key WRK_UNDER_TEST="$TMP/mut-wrk-t1199-skip-kimi" \
  spawn_base opus 2>&1)"
t1199_m5_ctl_rc=$?
set -e
# M1 under AC1's eaten-key pane: the argv is typed into the pending read,
# its first character is eaten (`laude` runs to command-not-found), and
# the spawn dies at the foreground gate — the AC1 assertion
# "must still spawn" goes RED.
[[ "$t1016_m1_rc" -ne 0 ]] ||
  fail "M1 (wait skipped): claude spawn succeeded despite the eaten argv: $t1016_m1_out"
[[ "$t1016_m1_starts" -eq 1 && "$t1016_m1_laude" -eq 1 ]] ||
  fail "M1 (wait skipped): the eaten argv must show up truncated in the exec record"
# M2 under AC2's never-ending read: the wait fails but is ignored, so
# `agent start` IS called — the AC2 assertion "agent start must never be
# called" goes RED — while the typed argv is consumed and the spawn still
# dies at the foreground gate.
[[ "$t1016_m2_rc" -ne 0 ]] ||
  fail "M2 (wait failure ignored): claude spawn succeeded on a dead-read pane: $t1016_m2_out"
[[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "M2 (wait failure ignored): agent start must have been (wrongly) called"
grep -q 'agent foreground check failed: agent not foreground' <<<"$t1016_m2_out" ||
  fail "M2 (wait failure ignored): the typed argv must not have foregrounded an agent: $t1016_m2_out"
# M3 under AC1's 26s probe: the spawn lands but the start was handed the
# full 30000ms — the AC1 assertion "the probe and agent start share one
# window" goes RED on --timeout 4000 vs 30000.
[[ "$t1199_m3_rc" -eq 0 ]] ||
  fail "M3 (full window): spawn should still land — the bug is only the timeout: $t1199_m3_out"
[[ "$t1199_m3_start" == 'agent start fixture --kind claude --pane w:p1 --timeout 30000 -- --model opus --dangerously-skip-permissions --effort high' ]] ||
  fail "M3 (full window): divergence lost — the mutant must hand the full 30000ms window: $t1199_m3_start"
# M4 under AC3's normal path: the probe still executes (the token is
# answered, the spawn lands) but its `pane run` line no longer matches the
# anchored whole-line assertion.
[[ "$t1199_m4_rc" -eq 0 ]] ||
  fail "M4 (probe argv appended): the probe still runs — the spawn must land: $t1199_m4_out"
[[ "$t1199_m4_anchored" -eq 0 ]] ||
  fail "M4 (probe argv appended): the anchored assertion did not go red on the appended argv"
# M5 under AC1's eaten-key pane for kimi: the probe is skipped, the argv is
# typed into the pending read and its first character eaten (`imi`), and
# the spawn dies at the foreground gate — the kimi AC1 assertion "must
# still spawn" goes RED; the opus control must still land.
[[ "$t1199_m5_rc" -ne 0 ]] ||
  fail "M5 (kimi probe skipped): kimi spawn succeeded despite the eaten argv: $t1199_m5_out"
[[ "$t1199_m5_eaten" -eq 1 ]] ||
  fail "M5 (kimi probe skipped): the eaten kimi argv must show up truncated in the exec record"
[[ "$t1199_m5_ctl_rc" -eq 0 ]] ||
  fail "M5 (kimi probe skipped): the opus control must still be probed and land: $t1199_m5_ctl_out"
echo "PASS 1016-AC4/1199-AC5 mutants red: M1 skip-wait, M2 ignore-wait-failure, M3 full-window, M4 probe-arg, M5 skip-kimi"

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
# the --model name differs — and reject --effort like devin-swe2. #635 adds
# the effort rungs as named profiles (effort lives inside the model id), same
# argv skeleton and same --effort rejection.
for devin_pair in "devin-glm52:glm-5-2" "devin-swe17:swe-1-7" "devin-ds41:deepseek-v4-1-flash-high" \
  "devin-swe2-medium:swe-2-medium" "devin-swe2-max:swe-2-max" "devin-ds41-max:deepseek-v4-1-flash-max" \
  "devin-fusion-opus55:fusion-claude-opus-5-5-high-sidekick-swe-2-medium" \
  "devin-fusion-sonnet55:fusion-claude-sonnet-5-5-high-sidekick-swe-2-medium"; do
  devin_profile="${devin_pair%%:*}"
  devin_model="${devin_pair#*:}"
  : >"$TMP/herdr.log"
  devin_variant_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base "$devin_profile" 2>&1)"
  grep -q "model=$devin_profile" <<<"$devin_variant_out" ||
    fail "$devin_profile spawn output lost its model: $devin_variant_out"
  grep -q 'status=idle' <<<"$devin_variant_out" ||
    fail "$devin_profile did not reach idle landing: $devin_variant_out"
  devin_variant_run="$(grep '^pane run w:p1 devin ' "$TMP/herdr.log")"
  [[ "$devin_variant_run" == "pane run w:p1 devin --model $devin_model --permission-mode dangerous --respect-workspace-trust false" ]] ||
    fail "$devin_profile run argv snapshot mismatch: $devin_variant_run"
  [[ " $devin_variant_run " != *' --effort '* ]] ||
    fail "$devin_profile run argv must not contain effort"
  expect_exit 2 spawn_base "$devin_profile" --effort high
done
echo "PASS devin-glm52/devin-swe17/devin-ds41 + #635 effort-variant + hk 1380 fusion worker kind/argv/no-effort snapshots"

# #635 AC2: an unknown effort token is still refused on the new spellings —
# the generic unknown-effort die fires before the devin no-effort guard.
expect_exit 2 spawn_base devin-swe2-max --effort bogus
expect_exit 2 spawn_base devin-ds41-max --effort medium

# -- #912: devin trusted-workspaces seeding ----------------------------------
# Helpers (devin_spawn_at / devin_trust_seed_store / devin_trust_paths /
# devin_trust_mutant) live with spawn_base above so earlier sections can seed
# their own fixture XDG stores.

# AC1: an uncovered spawn cwd is appended — resolved to its physical path —
# alongside the pre-existing entry, and a dated backup is written first.
mkdir -p "$TMP/t912-add/deep/nest" "$TMP/t912-elsewhere"
t912_xdg="$TMP/t912-xdg-add"
devin_trust_seed_store "$t912_xdg" "$TMP/t912-elsewhere"
t912_out="$(devin_spawn_at "$t912_xdg" "$TMP/t912-add/deep/nest" devin912a "$(mint_task)" 2>&1)" ||
  fail "devin spawn over an uncovered cwd failed: $t912_out"
grep -q '^OK ' <<<"$t912_out" || fail "devin trust-seed spawn lost its OK line: $t912_out"
t912_resolved="$(cd "$TMP/t912-add/deep/nest" && pwd -P)"
devin_trust_has "$t912_xdg" "$t912_resolved" ||
  fail "resolved spawn cwd was not added: $(devin_trust_paths "$t912_xdg")"
[[ "$(devin_trust_paths "$t912_xdg" | wc -l | tr -d ' ')" -eq 2 ]] ||
  fail "store gained more than the spawn cwd: $(devin_trust_paths "$t912_xdg")"
devin_trust_has "$t912_xdg" "$TMP/t912-elsewhere" ||
  fail "pre-existing entry was removed: $(devin_trust_paths "$t912_xdg")"
compgen -G "$t912_xdg/devin/cli/trusted_workspaces.json.bak-*" >/dev/null ||
  fail "trust write produced no backup"
echo "PASS 912-devin-trust adds only the resolved spawn cwd"

# AC1: an already-trusted cwd is a pure no-op — bytes and backup dir unchanged.
mkdir -p "$TMP/t912-same"
t912_xdg="$TMP/t912-xdg-same"
devin_trust_seed_store "$t912_xdg" "$(cd "$TMP/t912-same" && pwd -P)"
cp "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-same.before"
devin_spawn_at "$t912_xdg" "$TMP/t912-same" devin912b "$(mint_task)" >/dev/null ||
  fail "devin spawn over an already-trusted cwd failed"
cmp -s "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-same.before" ||
  fail "already-trusted cwd rewrote the store"
if compgen -G "$t912_xdg/devin/cli/trusted_workspaces.json.bak-*" >/dev/null; then
  fail "no-op trust check produced a backup"
fi
echo "PASS 912-devin-trust already-trusted is a pure no-op"

# AC1: a parent-covered cwd is also a pure no-op — inherited trust counts, the
# child path is never appended, and the parent is what stays trusted.
mkdir -p "$TMP/t912-parent/child"
t912_xdg="$TMP/t912-xdg-parent"
devin_trust_seed_store "$t912_xdg" "$(cd "$TMP/t912-parent" && pwd -P)"
cp "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-parent.before"
devin_spawn_at "$t912_xdg" "$TMP/t912-parent/child" devin912c "$(mint_task)" >/dev/null ||
  fail "devin spawn over a parent-covered cwd failed"
cmp -s "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-parent.before" ||
  fail "parent-covered cwd rewrote the store"
devin_trust_has "$t912_xdg" "$(cd "$TMP/t912-parent/child" && pwd -P)" &&
  fail "parent-covered cwd appended the child path"
echo "PASS 912-devin-trust parent-covered is a pure no-op"

# AC1: a trusted *sibling* does not cover the target — only ancestors do.
mkdir -p "$TMP/t912-sib/trusted" "$TMP/t912-sib/untrusted"
t912_xdg="$TMP/t912-xdg-sib"
devin_trust_seed_store "$t912_xdg" "$(cd "$TMP/t912-sib/trusted" && pwd -P)"
devin_spawn_at "$t912_xdg" "$TMP/t912-sib/untrusted" devin912sib "$(mint_task)" >/dev/null ||
  fail "devin spawn next to a trusted sibling failed"
devin_trust_has "$t912_xdg" "$(cd "$TMP/t912-sib/untrusted" && pwd -P)" ||
  fail "trusted sibling wrongly covered the spawn cwd"
echo "PASS 912-devin-trust sibling trust does not cover"

# AC2: a corrupt store is refused before any pane — bytes preserved verbatim.
mkdir -p "$TMP/t912-cwd-corrupt"
t912_xdg="$TMP/t912-xdg-corrupt"
mkdir -p "$t912_xdg/devin/cli"
printf '{ not json\n' >"$t912_xdg/devin/cli/trusted_workspaces.json"
cp "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-corrupt.before"
set +e
t912_out="$(devin_spawn_at "$t912_xdg" "$TMP/t912-cwd-corrupt" devin912d "$(mint_task)" 2>&1)"
t912_rc=$?
set -e
[[ "$t912_rc" -ne 0 ]] || fail "corrupt devin trust store did not refuse the spawn"
grep -q 'not valid JSON' <<<"$t912_out" ||
  fail "corrupt refusal lost its diagnostic: $t912_out"
cmp -s "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-corrupt.before" ||
  fail "corrupt store was overwritten"
[[ ! -e "$TMP/herdr-devin912d.log" ]] ||
  fail "corrupt-store refusal still reached herdr"
echo "PASS 912-devin-trust corrupt store refused, bytes preserved"

# AC2: an unparsable *shape* (trusted_paths not a string list) is refused the
# same way — valid JSON alone must not be enough to write.
mkdir -p "$TMP/t912-cwd-shape"
t912_xdg="$TMP/t912-xdg-shape"
mkdir -p "$t912_xdg/devin/cli"
printf '{"trusted_paths": "yes"}\n' >"$t912_xdg/devin/cli/trusted_workspaces.json"
cp "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-shape.before"
set +e
t912_out="$(devin_spawn_at "$t912_xdg" "$TMP/t912-cwd-shape" devin912sh "$(mint_task)" 2>&1)"
t912_rc=$?
set -e
[[ "$t912_rc" -ne 0 ]] || fail "malformed trusted_paths did not refuse the spawn"
grep -q 'trusted_paths' <<<"$t912_out" ||
  fail "shape refusal lost its diagnostic: $t912_out"
cmp -s "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-shape.before" ||
  fail "malformed store was overwritten"
echo "PASS 912-devin-trust malformed shape refused, bytes preserved"

# AC2: a missing store is refused closed — nothing is created, no pane runs.
mkdir -p "$TMP/t912-cwd-missing"
t912_xdg="$TMP/t912-xdg-missing"
mkdir -p "$t912_xdg/devin/cli"
set +e
t912_out="$(devin_spawn_at "$t912_xdg" "$TMP/t912-cwd-missing" devin912e "$(mint_task)" 2>&1)"
t912_rc=$?
set -e
[[ "$t912_rc" -ne 0 ]] || fail "missing devin trust store did not refuse the spawn"
grep -q 'store missing' <<<"$t912_out" ||
  fail "missing-store refusal lost its diagnostic: $t912_out"
[[ ! -e "$t912_xdg/devin/cli/trusted_workspaces.json" ]] ||
  fail "missing store was created by the spawn"
[[ ! -e "$TMP/herdr-devin912e.log" ]] ||
  fail "missing-store refusal still reached herdr"
echo "PASS 912-devin-trust missing store refused, nothing created"

# AC1/AC3: two concurrent spawns into the same store — both entries must land
# and the pre-existing entry must survive. The test delay holds each writer's
# read->write gap open so a lost update would be deterministic, not luck.
devin_trust_seed_store "$TMP/t912-xdg-race" "$TMP/t912-race-origin"
mkdir -p "$TMP/t912-race-a" "$TMP/t912-race-b" "$TMP/t912-race-origin"
t912_ta="$(mint_task)" t912_tb="$(mint_task)"
WRK_TEST_TRUST_DELAY_S=0.5 \
  devin_spawn_at "$TMP/t912-xdg-race" "$TMP/t912-race-a" devin912fa "$t912_ta" \
  >"$TMP/t912-race-a.out" 2>&1 &
t912_pa=$!
own "$t912_pa"
WRK_TEST_TRUST_DELAY_S=0.5 \
  devin_spawn_at "$TMP/t912-xdg-race" "$TMP/t912-race-b" devin912fb "$t912_tb" \
  >"$TMP/t912-race-b.out" 2>&1 &
t912_pb=$!
own "$t912_pb"
set +e
wait "$t912_pa"; t912_ra=$?
wait "$t912_pb"; t912_rb=$?
set -e
[[ "$t912_ra" -eq 0 && "$t912_rb" -eq 0 ]] ||
  fail "concurrent devin spawns failed rc=$t912_ra/$t912_rb: $(cat "$TMP/t912-race-a.out" "$TMP/t912-race-b.out")"
t912_ra_path="$(cd "$TMP/t912-race-a" && pwd -P)"
t912_rb_path="$(cd "$TMP/t912-race-b" && pwd -P)"
devin_trust_has "$TMP/t912-xdg-race" "$t912_ra_path" ||
  fail "concurrent spawn lost entry A: $(devin_trust_paths "$TMP/t912-xdg-race")"
devin_trust_has "$TMP/t912-xdg-race" "$t912_rb_path" ||
  fail "concurrent spawn lost entry B: $(devin_trust_paths "$TMP/t912-xdg-race")"
devin_trust_has "$TMP/t912-xdg-race" "$TMP/t912-race-origin" ||
  fail "concurrent spawn removed the pre-existing entry"
[[ "$(devin_trust_paths "$TMP/t912-xdg-race" | wc -l | tr -d ' ')" -eq 3 ]] ||
  fail "concurrent spawn produced wrong entry count"
echo "PASS 912-devin-trust concurrent spawns keep both entries"

# AC3: with XDG_DATA_HOME unset the store resolves under the fixture HOME —
# the real HOME store is never consulted.
t912_home="$TMP/t912-home"
mkdir -p "$t912_home/.local/share/devin/cli" "$TMP/t912-cwd-home"
printf '{"trusted_paths": []}\n' >"$t912_home/.local/share/devin/cli/trusted_workspaces.json"
t912_home_out="$(env -u XDG_DATA_HOME HOME="$t912_home" \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=devin-idle WRK_FIXTURE_LOG="$TMP/herdr-devin912h.log" \
  WRK_FIXTURE_MARKER="" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel-devin912h.log" \
  WRK_REFRESH_LOG="$TMP/refresh-devin912h.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh-devin912h.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$TMP/t912-cwd-home" -m devin-swe2 -p "$PROMPT" -w w \
  -l devin912h --t T1 --task "$(mint_task)" 2>&1)" ||
  fail "HOME-fallback devin spawn failed: $t912_home_out"
devin_trust_has "$t912_home/.local/share" "$(cd "$TMP/t912-cwd-home" && pwd -P)" ||
  fail "HOME-fallback store did not gain the spawn cwd"
echo "PASS 912-devin-trust XDG unset falls back to fixture HOME"

# -- assertion-RED mutants -------------------------------------------------
# Each mutant weakens exactly one rule; each run must produce the bad outcome
# the corresponding assertion above rejects, proving the assertion is live.
# 1) widening: store the parent instead of the cwd.
mkdir -p "$TMP/t912-m1/deep/nest"
devin_trust_seed_store "$TMP/t912-xdg-m1" "$TMP/t912-m1-else"
devin_trust_mutant widen \
  'data["trusted_paths"] = paths + [cwd]' \
  'data["trusted_paths"] = paths + [os.path.dirname(cwd)]'
WRK_UNDER_TEST="$TMP/mut-wrk-widen" \
  devin_spawn_at "$TMP/t912-xdg-m1" "$TMP/t912-m1/deep/nest" devin912m1 "$(mint_task)" \
  >/dev/null 2>&1 || true
if devin_trust_has "$TMP/t912-xdg-m1" "$(cd "$TMP/t912-m1/deep/nest" && pwd -P)"; then
  fail "parent-widening mutant survived: the spawn cwd was still added"
fi
devin_trust_has "$TMP/t912-xdg-m1" "$(cd "$TMP/t912-m1/deep" && pwd -P)" ||
  fail "parent-widening mutant did not apply (parent entry absent)"
echo "PASS 912-devin-trust mutant: parent widening goes RED"

# 2) coverage degraded to equality: a parent-covered cwd gets appended.
mkdir -p "$TMP/t912-m2/parent/child"
devin_trust_seed_store "$TMP/t912-xdg-m2" "$(cd "$TMP/t912-m2/parent" && pwd -P)"
cp "$TMP/t912-xdg-m2/devin/cli/trusted_workspaces.json" "$TMP/t912-m2.before"
devin_trust_mutant eqcover \
  'if os.path.commonpath((base, target)) == base:' \
  'if base == target:'
WRK_UNDER_TEST="$TMP/mut-wrk-eqcover" \
  devin_spawn_at "$TMP/t912-xdg-m2" "$TMP/t912-m2/parent/child" devin912m2 "$(mint_task)" \
  >/dev/null 2>&1 || true
cmp -s "$TMP/t912-xdg-m2/devin/cli/trusted_workspaces.json" "$TMP/t912-m2.before" &&
  fail "ancestor-coverage mutant survived: parent-covered cwd left the store untouched"
echo "PASS 912-devin-trust mutant: equality-only coverage goes RED"

# 3) coverage skipped entirely: an already-trusted cwd gets appended again.
mkdir -p "$TMP/t912-m3"
devin_trust_seed_store "$TMP/t912-xdg-m3" "$(cd "$TMP/t912-m3" && pwd -P)"
cp "$TMP/t912-xdg-m3/devin/cli/trusted_workspaces.json" "$TMP/t912-m3.before"
devin_trust_mutant always 'if covered():' 'if False:'
WRK_UNDER_TEST="$TMP/mut-wrk-always" \
  devin_spawn_at "$TMP/t912-xdg-m3" "$TMP/t912-m3" devin912m3 "$(mint_task)" \
  >/dev/null 2>&1 || true
cmp -s "$TMP/t912-xdg-m3/devin/cli/trusted_workspaces.json" "$TMP/t912-m3.before" &&
  fail "coverage-skip mutant survived: already-trusted cwd left the store untouched"
echo "PASS 912-devin-trust mutant: skipped coverage check goes RED"

# 4) corrupt tolerated: invalid JSON silently replaced by an empty store.
mkdir -p "$TMP/t912-m4-cwd" "$TMP/t912-xdg-m4/devin/cli"
printf '{ not json\n' >"$TMP/t912-xdg-m4/devin/cli/trusted_workspaces.json"
cp "$TMP/t912-xdg-m4/devin/cli/trusted_workspaces.json" "$TMP/t912-m4.before"
devin_trust_mutant corrupt-ok \
  'refuse("store is not valid JSON: %s (%s) — refusing to overwrite a corrupt file" % (path, exc))' \
  'data = {"trusted_paths": []}'
WRK_UNDER_TEST="$TMP/mut-wrk-corrupt-ok" \
  devin_spawn_at "$TMP/t912-xdg-m4" "$TMP/t912-m4-cwd" devin912m4 "$(mint_task)" \
  >/dev/null 2>&1 || true
cmp -s "$TMP/t912-xdg-m4/devin/cli/trusted_workspaces.json" "$TMP/t912-m4.before" &&
  fail "corrupt-tolerant mutant survived: corrupt store was never rewritten"
echo "PASS 912-devin-trust mutant: corrupt tolerated goes RED"

# 5) entries dropped: append becomes replace.
mkdir -p "$TMP/t912-m5-cwd" "$TMP/t912-m5-keep"
devin_trust_seed_store "$TMP/t912-xdg-m5" "$TMP/t912-m5-keep"
devin_trust_mutant drop \
  'data["trusted_paths"] = paths + [cwd]' \
  'data["trusted_paths"] = [cwd]'
WRK_UNDER_TEST="$TMP/mut-wrk-drop" \
  devin_spawn_at "$TMP/t912-xdg-m5" "$TMP/t912-m5-cwd" devin912m5 "$(mint_task)" \
  >/dev/null 2>&1 || true
if devin_trust_has "$TMP/t912-xdg-m5" "$TMP/t912-m5-keep"; then
  fail "entry-dropping mutant survived: pre-existing entry still present"
fi
echo "PASS 912-devin-trust mutant: dropped entries go RED"

# 6) missing store silently created instead of refused.
mkdir -p "$TMP/t912-m6-cwd" "$TMP/t912-xdg-m6/devin/cli"
devin_trust_mutant missing-create \
  'refuse("store missing: %s — trust a directory in devin once or restore the file; not creating it" % path)' \
  'open(path, "w").write('"'"'{"trusted_paths": []}'"'"')'
WRK_UNDER_TEST="$TMP/mut-wrk-missing-create" \
  devin_spawn_at "$TMP/t912-xdg-m6" "$TMP/t912-m6-cwd" devin912m6 "$(mint_task)" \
  >/dev/null 2>&1 || true
[[ -e "$TMP/t912-xdg-m6/devin/cli/trusted_workspaces.json" ]] ||
  fail "missing-store-creating mutant survived: store still absent"
echo "PASS 912-devin-trust mutant: missing store created goes RED"

# 7) lock dropped: with the read->write gap held open, two writers lose one
# entry — the concurrency assertions above must fail against this mutant.
devin_trust_seed_store "$TMP/t912-xdg-m7" "$TMP/t912-m7-origin"
mkdir -p "$TMP/t912-m7-a" "$TMP/t912-m7-b" "$TMP/t912-m7-origin"
# The flock line also exists verbatim in #951's claude block — anchor on the
# devin-only `try:\n        try:` that follows it.
devin_trust_mutant nolock \
  '    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    try:
        try:' \
  '    pass  # mutant: no flock
    try:
        try:'
t912_ma="$(mint_task)" t912_mb="$(mint_task)"
WRK_TEST_TRUST_DELAY_S=0.6 WRK_UNDER_TEST="$TMP/mut-wrk-nolock" \
  devin_spawn_at "$TMP/t912-xdg-m7" "$TMP/t912-m7-a" devin912ma "$t912_ma" \
  >/dev/null 2>&1 &
t912_pa=$!
own "$t912_pa"
WRK_TEST_TRUST_DELAY_S=0.6 WRK_UNDER_TEST="$TMP/mut-wrk-nolock" \
  devin_spawn_at "$TMP/t912-xdg-m7" "$TMP/t912-m7-b" devin912mb "$t912_mb" \
  >/dev/null 2>&1 &
t912_pb=$!
own "$t912_pb"
wait "$t912_pa" "$t912_pb" || true
t912_m7_count="$(devin_trust_paths "$TMP/t912-xdg-m7" | wc -l | tr -d ' ')"
[[ "$t912_m7_count" -lt 3 ]] ||
  fail "lockless mutant survived: both concurrent entries landed anyway"
echo "PASS 912-devin-trust mutant: dropped lock goes RED"

# -- #951: claude folder-trust seeding ---------------------------------------
# Helpers (claude_spawn_at / claude_trust_entry / claude_trust_mutant) live
# with spawn_base above. Every case runs on a fixture HOME under $TMP.

# AC1: fresh HOME — no .claude.json — gets exactly one projects entry keyed by
# the resolved spawn cwd, file mode 0600, and the spawn proceeds.
t951_home="$TMP/t951-home-fresh"; mkdir -p "$t951_home" "$TMP/t951-cwd-fresh"
t951_out="$(claude_spawn_at "$t951_home" "$TMP/t951-cwd-fresh" t951a "$(mint_task)" 2>&1)" ||
  fail "claude spawn over a fresh HOME failed: $t951_out"
grep -q '^OK ' <<<"$t951_out" || fail "claude trust-seed spawn lost its OK line: $t951_out"
t951_resolved="$(cd "$TMP/t951-cwd-fresh" && pwd -P)"
[[ "$(claude_trust_entry "$t951_home/.claude.json" "$t951_resolved")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "fresh .claude.json lacks the trust entry: $(claude_trust_entry "$t951_home/.claude.json" "$t951_resolved")"
[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$t951_home/.claude.json")" == 0o600 ]] ||
  fail "fresh .claude.json mode is not 0600"
[[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["projects"]))' "$t951_home/.claude.json")" == 1 ]] ||
  fail "fresh .claude.json gained extra project entries"
echo "PASS 951-claude-trust fresh HOME seeds only the resolved cwd"

# AC1/AC2: an existing store keeps every other key and every other project
# entry; only hasTrustDialogAccepted is set on the spawn cwd's own entry —
# entry keys it already had survive, file mode preserved.
t951_home="$TMP/t951-home-keep"; mkdir -p "$t951_home" "$TMP/t951-cwd-keep"
t951_resolved="$(cd "$TMP/t951-cwd-keep" && pwd -P)"
python3 - "$t951_home/.claude.json" "$t951_resolved" <<'PY'
import json, sys
doc = {"userID": "fixture-user", "numStartups": 7, "greeting": "한글 claude",
       "projects": {"/other/trusted": {"hasTrustDialogAccepted": True, "allowedTools": ["Bash(ls)"]},
                    "/other/untrusted": {"hasTrustDialogAccepted": False, "note": "keep"},
                    sys.argv[2]: {"note": "pre-existing"}}}
with open(sys.argv[1], "w", encoding="utf-8") as h:
    json.dump(doc, h, indent=2, ensure_ascii=False)
PY
chmod 640 "$t951_home/.claude.json"
claude_spawn_at "$t951_home" "$TMP/t951-cwd-keep" t951b "$(mint_task)" >/dev/null ||
  fail "claude spawn over an existing store failed"
python3 - "$t951_home/.claude.json" "$t951_resolved" <<'PY' || fail "seeded store lost keys, projects, or entry keys"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["userID"] == "fixture-user" and data["numStartups"] == 7
projs = data["projects"]
assert len(projs) == 3
assert projs["/other/trusted"] == {"hasTrustDialogAccepted": True, "allowedTools": ["Bash(ls)"]}
assert projs["/other/untrusted"] == {"hasTrustDialogAccepted": False, "note": "keep"}
assert projs[sys.argv[2]] == {"hasTrustDialogAccepted": True, "note": "pre-existing"}
PY
# r2 nit N1: non-ASCII content must survive as raw UTF-8, not XXXX escapes.
grep -q '한글' "$t951_home/.claude.json" ||
  fail "non-ASCII value was escaped to \\uXXXX escapes"
[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$t951_home/.claude.json")" == 0o640 ]] ||
  fail "existing store mode changed"
echo "PASS 951-claude-trust preserves other keys, projects, entry keys, mode"

# AC1: a projects entry that says hasTrustDialogAccepted=false is flipped to
# true; an already-true entry is a pure no-op — bytes unchanged.
t951_home="$TMP/t951-home-flip"; mkdir -p "$t951_home" "$TMP/t951-cwd-flip"
t951_resolved="$(cd "$TMP/t951-cwd-flip" && pwd -P)"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":false,"keep":"x"}}}\n' "$t951_resolved" >"$t951_home/.claude.json"
claude_spawn_at "$t951_home" "$TMP/t951-cwd-flip" t951c "$(mint_task)" >/dev/null ||
  fail "claude spawn over a false-flag entry failed"
[[ "$(claude_trust_entry "$t951_home/.claude.json" "$t951_resolved")" == '{"hasTrustDialogAccepted":true,"keep":"x"}' ]] ||
  fail "false flag was not flipped or entry keys were lost: $(claude_trust_entry "$t951_home/.claude.json" "$t951_resolved")"
t951_home="$TMP/t951-home-same"; mkdir -p "$t951_home" "$TMP/t951-cwd-same"
t951_resolved="$(cd "$TMP/t951-cwd-same" && pwd -P)"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$t951_resolved" >"$t951_home/.claude.json"
cp "$t951_home/.claude.json" "$TMP/t951-same.before"
claude_spawn_at "$t951_home" "$TMP/t951-cwd-same" t951d "$(mint_task)" >/dev/null ||
  fail "claude spawn over an already-trusted cwd failed"
cmp -s "$t951_home/.claude.json" "$TMP/t951-same.before" ||
  fail "already-trusted cwd rewrote the store"
echo "PASS 951-claude-trust false-flag flips, already-trusted is a pure no-op"

# AC1: the projects key is the physical path — a -c through a symlink records
# the resolved directory, never the link spelling.
mkdir -p "$TMP/t951-real/deep" "$TMP/t951-home-link"
ln -s "$TMP/t951-real/deep" "$TMP/t951-link"
claude_spawn_at "$TMP/t951-home-link" "$TMP/t951-link" t951e "$(mint_task)" >/dev/null ||
  fail "claude spawn over a symlinked cwd failed"
t951_resolved="$(cd "$TMP/t951-link" && pwd -P)"
[[ "$t951_resolved" != "$TMP/t951-link" ]] || fail "fixture flaw: symlink resolved to itself"
[[ "$(claude_trust_entry "$TMP/t951-home-link/.claude.json" "$t951_resolved")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "resolved path was not keyed: $(claude_trust_entry "$TMP/t951-home-link/.claude.json" "$t951_resolved")"
[[ "$(claude_trust_entry "$TMP/t951-home-link/.claude.json" "$TMP/t951-link")" == absent ]] ||
  fail "symlink spelling was recorded as a projects key"
echo "PASS 951-claude-trust keys the resolved physical path"

# AC1: CLAUDE_CONFIG_DIR relocates the store — the flag lands under the config
# dir and the HOME-level file is never created.
t951_home="$TMP/t951-home-cfg"; t951_cfg="$TMP/t951-cfgdir"
mkdir -p "$t951_home" "$t951_cfg" "$TMP/t951-cwd-cfg"
env HOME="$t951_home" CLAUDE_CONFIG_DIR="$t951_cfg" \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr-t951cfg.log" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel-t951cfg.log" WRK_REFRESH_LOG="$TMP/refresh-t951cfg.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh-t951cfg.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$TMP/t951-cwd-cfg" -m sonnet -p "$PROMPT" -w w -l t951cfg \
  --t T1 --task "$(mint_task)" >/dev/null ||
  fail "CLAUDE_CONFIG_DIR claude spawn failed"
t951_resolved="$(cd "$TMP/t951-cwd-cfg" && pwd -P)"
[[ "$(claude_trust_entry "$t951_cfg/.claude.json" "$t951_resolved")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "CLAUDE_CONFIG_DIR store lacks the trust entry"
[[ ! -e "$t951_home/.claude.json" ]] ||
  fail "HOME-level .claude.json was written despite CLAUDE_CONFIG_DIR"
echo "PASS 951-claude-trust honors CLAUDE_CONFIG_DIR"

# AC2: an unwritable store warns and the spawn continues — fail-open, never a
# denial. The lock file pre-exists so the refusal lands on the atomic write.
t951_home="$TMP/t951-home-ro"; mkdir -p "$t951_home" "$TMP/t951-cwd-ro"
printf '{"projects":{}}\n' >"$t951_home/.claude.json"
: >"$t951_home/.claude.json.wrk.lock"
chmod 555 "$t951_home"
set +e
t951_out="$(claude_spawn_at "$t951_home" "$TMP/t951-cwd-ro" t951f "$(mint_task)" 2>&1)"
t951_rc=$?
set -e
chmod 755 "$t951_home"
[[ "$t951_rc" -eq 0 ]] || fail "unwritable store denied the spawn rc=$t951_rc: $t951_out"
grep -q 'Claude folder trust' <<<"$t951_out" ||
  fail "unwritable store lost its warning: $t951_out"
grep -q '^OK ' <<<"$t951_out" || fail "unwritable-store spawn lost its OK line: $t951_out"
[[ "$(cat "$t951_home/.claude.json")" == '{"projects":{}}' ]] ||
  fail "unwritable store was modified"
echo "PASS 951-claude-trust unwritable store warns and continues"

# AC2: a corrupt store warns, is not overwritten, and the spawn continues.
t951_home="$TMP/t951-home-corrupt"; mkdir -p "$t951_home" "$TMP/t951-cwd-corrupt"
printf '{ not json\n' >"$t951_home/.claude.json"
cp "$t951_home/.claude.json" "$TMP/t951-corrupt.before"
set +e
t951_out="$(claude_spawn_at "$t951_home" "$TMP/t951-cwd-corrupt" t951g "$(mint_task)" 2>&1)"
t951_rc=$?
set -e
[[ "$t951_rc" -eq 0 ]] || fail "corrupt store denied the spawn rc=$t951_rc: $t951_out"
grep -q 'not valid JSON' <<<"$t951_out" ||
  fail "corrupt-store warning lost its diagnostic: $t951_out"
grep -q '^OK ' <<<"$t951_out" || fail "corrupt-store spawn lost its OK line: $t951_out"
cmp -s "$t951_home/.claude.json" "$TMP/t951-corrupt.before" ||
  fail "corrupt store was overwritten"
echo "PASS 951-claude-trust corrupt store warns, untouched, spawn continues"

# AC3: a non-claude-kind spawn never touches .claude.json.
t951_home="$TMP/t951-home-codex"; mkdir -p "$t951_home"
claude_spawn_at "$t951_home" "$ROOT" t951h "$(mint_task)" codex-luna >/dev/null ||
  fail "codex-kind spawn failed"
[[ ! -e "$t951_home/.claude.json" ]] ||
  fail "non-claude spawn wrote .claude.json"
[[ ! -e "$t951_home/.claude.json.wrk.lock" ]] ||
  fail "non-claude spawn left a lock file"
echo "PASS 951-claude-trust non-claude kinds never touch the store"

# AC1/AC2: two concurrent spawns into the same store — both entries must land.
# The test delay holds each writer's read->write gap open so a lost update
# would be deterministic, not luck.
t951_home="$TMP/t951-home-race"; mkdir -p "$t951_home" "$TMP/t951-race-a" "$TMP/t951-race-b"
t951_ta="$(mint_task)" t951_tb="$(mint_task)"
WRK_TEST_TRUST_DELAY_S=0.5 \
  claude_spawn_at "$t951_home" "$TMP/t951-race-a" t951ra "$t951_ta" \
  >"$TMP/t951-race-a.out" 2>&1 &
t951_pa=$!
own "$t951_pa"
WRK_TEST_TRUST_DELAY_S=0.5 \
  claude_spawn_at "$t951_home" "$TMP/t951-race-b" t951rb "$t951_tb" \
  >"$TMP/t951-race-b.out" 2>&1 &
t951_pb=$!
own "$t951_pb"
set +e
wait "$t951_pa"; t951_ra=$?
wait "$t951_pb"; t951_rb=$?
set -e
[[ "$t951_ra" -eq 0 && "$t951_rb" -eq 0 ]] ||
  fail "concurrent claude spawns failed rc=$t951_ra/$t951_rb: $(cat "$TMP/t951-race-a.out" "$TMP/t951-race-b.out")"
t951_ra_path="$(cd "$TMP/t951-race-a" && pwd -P)"
t951_rb_path="$(cd "$TMP/t951-race-b" && pwd -P)"
[[ "$(claude_trust_entry "$t951_home/.claude.json" "$t951_ra_path")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "concurrent spawn lost entry A"
[[ "$(claude_trust_entry "$t951_home/.claude.json" "$t951_rb_path")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "concurrent spawn lost entry B"
echo "PASS 951-claude-trust concurrent spawns keep both entries"

# AC2 (r2 blocker B1): HOME unset entirely must warn and continue — under
# set -u an unguarded $HOME expansion aborts before the fail-open guard.
mkdir -p "$TMP/t951-cwd-nohome" "$TMP/t951-xdg-nohome"
set +e
t951_out="$(env -u HOME -u CLAUDE_CONFIG_DIR \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
  XDG_DATA_HOME="$TMP/t951-xdg-nohome" \
  ARBITER_INBOX_ROOT="$TMP/t951-inbox-noh" \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr-t951noh.log" \
  WRK_FIXTURE_MARKER="" WRK_SCOPEFUEL_LOG="$TMP/scopefuel-t951noh.log" \
  WRK_REFRESH_LOG="$TMP/refresh-t951noh.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh-t951noh.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$TMP/t951-cwd-nohome" -m sonnet -p "$PROMPT" -w w \
  -l t951noh --t T1 --task "$(mint_task)" 2>&1)"
t951_rc=$?
set -e
[[ "$t951_rc" -eq 0 ]] || fail "unset HOME denied the spawn rc=$t951_rc: $t951_out"
grep -q 'Claude folder trust' <<<"$t951_out" ||
  fail "unset-HOME spawn lost its warning: $t951_out"
grep -q '^OK ' <<<"$t951_out" || fail "unset-HOME spawn lost its OK line: $t951_out"
# HOME unset + CLAUDE_CONFIG_DIR set still seeds — the cfg dir does not need HOME.
t951_cfg="$TMP/t951-cfg-nohome"; mkdir -p "$t951_cfg" "$TMP/t951-cwd-nohome2"
env -u HOME CLAUDE_CONFIG_DIR="$t951_cfg" \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
  XDG_DATA_HOME="$TMP/t951-xdg-nohome" \
  ARBITER_INBOX_ROOT="$TMP/t951-inbox-noh" \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr-t951noh2.log" \
  WRK_FIXTURE_MARKER="" WRK_SCOPEFUEL_LOG="$TMP/scopefuel-t951noh2.log" \
  WRK_REFRESH_LOG="$TMP/refresh-t951noh2.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh-t951noh2.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$TMP/t951-cwd-nohome2" -m sonnet -p "$PROMPT" -w w \
  -l t951noh2 --t T1 --task "$(mint_task)" >/dev/null ||
  fail "HOME-unset + CLAUDE_CONFIG_DIR spawn failed"
t951_resolved="$(cd "$TMP/t951-cwd-nohome2" && pwd -P)"
[[ "$(claude_trust_entry "$t951_cfg/.claude.json" "$t951_resolved")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "HOME-unset + CLAUDE_CONFIG_DIR store lacks the trust entry"
echo "PASS 951-claude-trust unset HOME warns and continues"

# AC2 (r2 blocker B2): a lock held by a wedged process must time out and
# continue, not block the spawn forever. The holder keeps LOCK_EX for 15s —
# well past the seeder's 2s test deadline — and is killed once asserted.
t951_home="$TMP/t951-home-held"; mkdir -p "$t951_home" "$TMP/t951-cwd-held"
python3 - "$t951_home/.claude.json.wrk.lock" "$TMP/t951-held.ready" <<'PY' &
import fcntl, sys, time
fd = open(sys.argv[1], "w")
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(15)
PY
t951_holder=$!
own "$t951_holder"
for _ in $(seq 100); do [[ -e "$TMP/t951-held.ready" ]] && break; sleep 0.05; done
[[ -e "$TMP/t951-held.ready" ]] || fail "lock holder never acquired"
set +e
t951_out="$(WRK_TEST_TRUST_LOCK_TIMEOUT_S=2 \
  claude_spawn_at "$t951_home" "$TMP/t951-cwd-held" t951held "$(mint_task)" 2>&1)"
t951_rc=$?
set -e
kill "$t951_holder" 2>/dev/null || true
wait "$t951_holder" 2>/dev/null || true
[[ "$t951_rc" -eq 0 ]] || fail "held lock denied the spawn rc=$t951_rc: $t951_out"
grep -q 'timed out waiting for lock' <<<"$t951_out" ||
  fail "held lock lost its timeout warning: $t951_out"
grep -q '^OK ' <<<"$t951_out" || fail "held-lock spawn lost its OK line: $t951_out"
echo "PASS 951-claude-trust held lock times out, spawn continues"

# -- assertion-RED mutants ---------------------------------------------------
# 1) other keys dropped: the write must carry the whole document, not just our
#    entry — a mutant that rewrites only the projects subtree loses data.
t951_home="$TMP/t951-home-m1"; mkdir -p "$t951_home" "$TMP/t951-m1-cwd"
python3 - "$t951_home/.claude.json" <<'PY'
import json, sys
json.dump({"keep": 1, "projects": {"/other": {"hasTrustDialogAccepted": True}}},
          open(sys.argv[1], "w", encoding="utf-8"))
PY
# ensure_ascii=False keeps this anchor unique — devin's blob line lacks it.
claude_trust_mutant drop-keys \
  '        blob = json.dumps(data, indent=2, ensure_ascii=False).encode("utf-8")
' \
  '        blob = json.dumps({"projects": {target: entry}}, indent=2, ensure_ascii=False).encode("utf-8")
'
WRK_UNDER_TEST="$TMP/mut-wrk-drop-keys" \
  claude_spawn_at "$t951_home" "$TMP/t951-m1-cwd" t951m1 "$(mint_task)" \
  >/dev/null 2>&1 || true
python3 - "$t951_home/.claude.json" <<'PY' || fail "key-dropping mutant survived: all keys were preserved anyway"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert "keep" not in data and len(data["projects"]) == 1, \
    "mutant did not take effect: %r" % data
PY
echo "PASS 951-claude-trust mutant: dropped keys go RED"

# 2) fail-open stripped: without the || warn guard the helper's refusal
#    propagates under set -e and the corrupt-store spawn dies — the exact
#    denial the AC forbids.
t951_home="$TMP/t951-home-m2"; mkdir -p "$t951_home" "$TMP/t951-m2-cwd"
printf '{ not json\n' >"$t951_home/.claude.json"
claude_trust_mutant no-failopen \
  "<<'PY' || warn \"Claude folder trust seed failed; spawn continues\"" \
  "<<'PY'"
set +e
WRK_UNDER_TEST="$TMP/mut-wrk-no-failopen" \
  claude_spawn_at "$t951_home" "$TMP/t951-m2-cwd" t951m2 "$(mint_task)" \
  >/dev/null 2>&1
t951_rc=$?
set -e
[[ "$t951_rc" -ne 0 ]] ||
  fail "fail-open-stripping mutant survived: corrupt store still spawned"
echo "PASS 951-claude-trust mutant: stripped fail-open guard goes RED"

# 3) lock dropped: with the read->write gap held open, two writers lose one
#    entry — the concurrency assertions above must fail against this mutant.
#    The LOCK_NB spelling keeps this anchor unique to claude's poll loop
#    (devin's flock is a bare LOCK_EX before 'try:try').
t951_home="$TMP/t951-home-m7"; mkdir -p "$t951_home" "$TMP/t951-m7-a" "$TMP/t951-m7-b"
claude_trust_mutant nolock \
  '            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break' \
  '            pass  # mutant: no flock
            break'
t951_ma="$(mint_task)" t951_mb="$(mint_task)"
WRK_TEST_TRUST_DELAY_S=0.6 WRK_UNDER_TEST="$TMP/mut-wrk-nolock" \
  claude_spawn_at "$t951_home" "$TMP/t951-m7-a" t951ma "$t951_ma" \
  >/dev/null 2>&1 &
t951_pa=$!
own "$t951_pa"
WRK_TEST_TRUST_DELAY_S=0.6 WRK_UNDER_TEST="$TMP/mut-wrk-nolock" \
  claude_spawn_at "$t951_home" "$TMP/t951-m7-b" t951mb "$t951_mb" \
  >/dev/null 2>&1 &
t951_pb=$!
own "$t951_pb"
wait "$t951_pa" "$t951_pb" || true
t951_m7_entries="$(python3 - "$t951_home/.claude.json" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1], encoding="utf-8"))["projects"]))
PY
)"
[[ "$t951_m7_entries" -lt 2 ]] ||
  fail "lockless mutant survived: both concurrent entries landed anyway"
echo "PASS 951-claude-trust mutant: dropped lock goes RED"

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
spawn_base codex-luna >/dev/null
grep -q 'model_reasoning_effort=medium' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base codex-luna --effort high >/dev/null
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

# #1199: the probe's share of the window reaches the first start's --timeout
# — frozen clock so the argv snapshots stay whole-window exact.
: >"$TMP/herdr.log"
PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 spawn_base kimi-k3 >/dev/null
kimi_k3_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$kimi_k3_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/k3' ]] ||
  fail "kimi-k3 start argv snapshot mismatch: $kimi_k3_start"
: >"$TMP/herdr.log"
PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 spawn_base kimi-k27 >/dev/null
kimi_k27_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$kimi_k27_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/kimi-for-coding' ]] ||
  fail "kimi-k27 start argv snapshot mismatch: $kimi_k27_start"
: >"$TMP/herdr.log"
PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 spawn_base kimi-k27-code >/dev/null
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
PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 spawn_base kimi-k3-low >/dev/null
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
else
  # Suite HOME is a fixture that starts without the file — a settings write
  # under it is exactly the regression this check exists to catch.
  [[ ! -f "$SETTINGS_PATH" ]] ||
    fail "claude spawns created ~/.claude/settings.json"
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
oc_solar4_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 spawn_base oc-solar4 2>&1)"
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
  -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l fixture --t T1 2>&1)"
grep -q 'model=codex-luna' <<<"$once_out"
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
marker_out="$(TEST_FIXTURE_SCENARIO=landing-marker WRK_FIXTURE_MARKER="$marker_expected" spawn_base codex-luna 2>&1)"
grep -q 'landed=yes' <<<"$marker_out"
grep -q "$marker_first_line" "$TMP/herdr.log"
[[ "$(grep -c '^agent prompt ' "$TMP/herdr.log")" -eq 1 ]]
echo "PASS marker-positive-landed: $marker_out"

PROMPT="$TMP/prompt.md"
: >"$TMP/herdr.log"
# AC1 RED before ROB-1321: the old implementation emits landed=yes here
# solely because the freshly booted agent reports working. A complete first
# observation window must instead re-inject once and then report landed=no.
working_no_marker_out="$(TEST_FIXTURE_SCENARIO=landing-working-no-marker spawn_base codex-luna 2>&1)"
grep -q 'landed=no' <<<"$working_no_marker_out"
grep -q 'action=reinject-once' <<<"$working_no_marker_out"
grep -q 'last_status=working' <<<"$working_no_marker_out"
# #717: pin the codex window itself, not just the verdict path — a ticks-only
# mutant (33 -> 18) or a window mutant (60 -> 30) must both fail here.
grep -q 'window=60s checks=33' <<<"$working_no_marker_out" ||
  fail "codex landing window must stay 60s/33 ticks: $working_no_marker_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS ac1-working-without-marker-retries-then-no: $working_no_marker_out"

: >"$TMP/herdr.log"
delayed_marker_out="$(TEST_FIXTURE_SCENARIO=landing-delayed-marker spawn_base codex-luna 2>&1)"
grep -q 'landed=yes' <<<"$delayed_marker_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
[[ "$(grep -c -- '--source recent-unwrapped' "$TMP/herdr.log")" -ge 3 ]]
echo "PASS ac2-delayed-marker-no-retry: $delayed_marker_out"

: >"$TMP/herdr.log"
retry_out="$(TEST_FIXTURE_SCENARIO=landing-retry spawn_base codex-luna 2>&1)"
grep -q 'landed=retry' <<<"$retry_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS ac3-swallowed-then-retry: $retry_out"

: >"$TMP/herdr.log"
set +e
no_landing_out="$(TEST_FIXTURE_SCENARIO=landing-no spawn_base codex-luna 2>&1)"
no_landing_rc=$?
set -e
[[ "$no_landing_rc" -eq 0 ]]
grep -q 'landed=no' <<<"$no_landing_out"
grep -q 'spawn succeeded but brief landed=no' <<<"$no_landing_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS landed-no-default-exit=$no_landing_rc: $no_landing_out"

: >"$TMP/herdr.log"
set +e
strict_no_landing_out="$(TEST_FIXTURE_SCENARIO=landing-working-no-marker spawn_base codex-luna --landing-strict 2>&1)"
strict_no_landing_rc=$?
set -e
[[ "$strict_no_landing_rc" -eq 76 ]]
grep -q '^OK pane=w:p1 .*landed=no' <<<"$strict_no_landing_out"
grep -q 'spawn succeeded but brief landed=no' <<<"$strict_no_landing_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS ac4-landing-strict exit=$strict_no_landing_rc: $strict_no_landing_out"

: >"$TMP/herdr.log"
scrollout_out="$(TEST_FIXTURE_SCENARIO=landing-scrollback-marker spawn_base codex-luna 2>&1)"
grep -q 'landed=yes' <<<"$scrollout_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
grep -q 'agent read w:p1 --source recent-unwrapped --lines 200' "$TMP/herdr.log"
echo "PASS ac5-scrollback-marker-no-duplicate: $scrollout_out"

: >"$TMP/herdr.log"
pasted_out="$(TEST_FIXTURE_SCENARIO=landing-pasted spawn_base codex-luna 2>&1)"
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
# post-injection screen, so the observation is a confirmed non-landing rather
# than an ambiguous chip. A fixture that hardcodes the echo would keep showing
# the chip and fail this case. Even then grok is never re-injected (#701).
echo_prompt_b="$TMP/grok-echo-prompt-b.md"
printf 'brief without the queued contract phrase\n' >"$echo_prompt_b"
PROMPT="$echo_prompt_b"
: >"$TMP/herdr.log"
grok_echo_b_out="$(TEST_FIXTURE_SCENARIO=grok-echo spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_echo_b_out" ||
  fail "payload-derived echo screen changed the verdict path: $grok_echo_b_out"
grep -q 'action=reinject-once' <<<"$grok_echo_b_out" &&
  fail "grok must never re-inject: $grok_echo_b_out"
grep -q 'retry=skipped reason=grok-never-reinjected' <<<"$grok_echo_b_out" ||
  fail "grok skip must name its reason: $grok_echo_b_out"
[[ "$(grep -c '^agent prompt ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "payload-derived echo triggered a re-injection: $grok_echo_b_out"
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
grep -q 'action=reinject-once' <<<"$grok_zero_out" &&
  fail "0 queued is not a chip, but grok is still never re-injected: $grok_zero_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "0 queued triggered a grok re-injection: $grok_zero_out"
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
# #701: grok's echo outlives even its extended window, so a confirmed-looking
# non-landing stays landed=no, is never re-injected, and tells the operator to
# re-check the pane after 2 minutes.
grok_no_chip_out="$(TEST_FIXTURE_SCENARIO=landing-working-no-marker spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_no_chip_out" ||
  fail "grok without the queued footer must stay landed=no: $grok_no_chip_out"
grep -q 'action=reinject-once' <<<"$grok_no_chip_out" &&
  fail "grok negative path must not re-inject: $grok_no_chip_out"
grep -q 'retry=skipped reason=grok-never-reinjected' <<<"$grok_no_chip_out" ||
  fail "grok negative path lost its skip reason: $grok_no_chip_out"
grep -q 'window=150s checks=78' <<<"$grok_no_chip_out" ||
  fail "grok must keep the extended 150s/78-tick landing window: $grok_no_chip_out"
grep -q 're-check the pane after 2 minutes' <<<"$grok_no_chip_out" ||
  fail "grok landed=no must print the re-check hint: $grok_no_chip_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "grok negative path triggered a re-injection: $grok_no_chip_out"
echo "PASS grok-no-chip-negative: $grok_no_chip_out"

# #701: a grok echo that lands past the default 30s/18-tick window but inside
# grok's 150s/78-tick window is positive evidence — landed=yes, one injection.
: >"$TMP/herdr.log"
grok_slow_out="$(TEST_FIXTURE_SCENARIO=grok-slow-marker spawn_base grok 2>&1)"
grep -q 'landed=yes' <<<"$grok_slow_out" ||
  fail "grok echo inside the extended window must land: $grok_slow_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "grok slow-marker triggered a re-injection: $grok_slow_out"
[[ "$(grep -c -- '--source recent-unwrapped' "$TMP/herdr.log")" -ge 60 ]] ||
  fail "grok slow-marker landed before its late echo: $grok_slow_out"
echo "PASS grok-slow-echo-landed: $grok_slow_out"

: >"$TMP/herdr.log"
claude_grok_chip_out="$(TEST_FIXTURE_SCENARIO=grok-queued spawn_base sonnet 2>&1)"
grep -q 'landed=no' <<<"$claude_grok_chip_out" ||
  fail "claude pane must not treat the grok footer as evidence: $claude_grok_chip_out"
# #717: pin the default window on a non-codex non-grok kind.
grep -q 'window=30s checks=18' <<<"$claude_grok_chip_out" ||
  fail "default landing window must stay 30s/18 ticks: $claude_grok_chip_out"
echo "PASS claude-ignores-grok-queued-chip: $claude_grok_chip_out"

: >"$TMP/herdr.log"
opencode_retry_out="$(TEST_FIXTURE_SCENARIO=opencode-retry spawn_base oc-omni 2>&1)"
grep -q 'landed=retry' <<<"$opencode_retry_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS opencode-landing-retry: $opencode_retry_out"

: >"$TMP/herdr.log"
observation_fail_out="$(TEST_FIXTURE_SCENARIO=landing-observation-fails spawn_base codex-luna 2>&1)"
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
pw_out="$(pw_spawn codex-luna 2>&1)"
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

# #717: the panewire --timeout is a budget of its own, decoupled from the
# landing window — the daemon only proves claude/codex submissions, so for
# every other kind a window-length timeout is dead polling before wrk's own
# observation starts. Pin it per kind: codex 60s (asserted above), grok and
# the default both 30s even though grok's landing window is 150s. The grok
# pin is what kills a re-coupling mutant — codex's timeout equals its window
# either way.
pw_reset
pw_spawn grok >/dev/null 2>&1
grep -q ' timeout=30s ' "$PW_LOG" ||
  fail "grok panewire timeout must be the 30s default, not its 150s window: $(cat "$PW_LOG")"
pw_reset
pw_spawn sonnet >/dev/null 2>&1
grep -q ' timeout=30s ' "$PW_LOG" ||
  fail "default-kind panewire timeout must be 30s: $(cat "$PW_LOG")"
echo "PASS 717-panewire-timeout-decoupled"

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
  WRK_GATE_MODE="$gate_mode" pw_spawn codex-luna >/dev/null 2>&1 && fail "498 gate $gate_mode must refuse"
  [[ "$(pw_calls)" -eq 0 && "$(herdr_briefs)" -eq 0 ]] || fail "498 gate $gate_mode refusal still prompted"
done
pw_reset
TEST_FIXTURE_SCENARIO=tab-create-fails pw_spawn codex-luna >/dev/null 2>&1 && fail "498 tab create failure must fail the spawn"
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
    "$WRK" spawn -c "$TMP/pw-cwd-link" -m codex-luna -p "$PROMPT" -w w -l fixture --t T1 2>&1)"
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
  "$WRK" spawn -c "$TMP/pw-cwd-link" -m codex-luna -p "$PROMPT" -w w -l fixture --t T1 2>&1)"
[[ "$(head -n1 "$PW_LOG.1")" == "expect: name=fixture cwd=$pw_cwd_physical" ]] || fail "498 foreign cwd adopted"
grep -q 'landed=no' <<<"$elsewhere_out" || fail "498 cwd mismatch must be landed=no: $elsewhere_out"
grep -q 'panewire_rc=5 submit=unsent' <<<"$elsewhere_out" || fail "498 cwd mismatch detail: $elsewhere_out"
[[ "$(herdr_briefs)" -eq 0 ]] || fail "498 cwd mismatch must not inject (no fallback on rc 5)"
echo "PASS 498-c3-cwd-normalized"

# A-6 ①: no uptake mode — a cold-booting pane that already reports working
# still gets the brief (the fixture refuses working targets when uptake is
# set, as prompt.go does).
pw_reset
working_out="$(TEST_FIXTURE_SCENARIO=landing-scrollback-marker pw_spawn codex-luna 2>&1)"
[[ "$(herdr_briefs)" -eq 1 ]] || fail "498 working target must still receive the brief: $working_out"
grep -q 'landed=yes' <<<"$working_out" || fail "498 working target landing: $working_out"
echo "PASS 498-a6-working-target-injected"

# A-6 ②: panewire's negative verdict on a brief that did land (claude/codex
# rc 6 "submission evidence unproven", transcript shows the brief) is
# corrected by read-only corroboration — landed=yes and no second brief.
for pw_mode in unproven composer; do
  pw_reset
  fn_out="$(WRK_PANEWIRE_PROMPT="$pw_mode" pw_spawn codex-luna 2>&1)"
  grep -q 'landed=yes' <<<"$fn_out" || fail "498 false negative ($pw_mode) must land: $fn_out"
  [[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "498 false negative ($pw_mode) re-injected"
  grep -q 'reinject' <<<"$fn_out" && fail "498 false negative ($pw_mode) announced a reinject: $fn_out"
done
echo "PASS 498-a6-false-negative-no-duplicate"

# I2: confirmed non-landing re-injects once, through panewire, as a new file.
pw_reset
pw_retry_out="$(TEST_FIXTURE_SCENARIO=landing-retry pw_spawn codex-luna 2>&1)"
grep -q 'landed=retry' <<<"$pw_retry_out" || fail "498 retry: $pw_retry_out"
[[ "$(pw_calls)" -eq 2 && "$(herdr_briefs)" -eq 2 ]] || fail "498 retry must be one extra panewire delivery"
first_file="$(sed -n '1s/.* file=\([^ ]*\) .*/\1/p' "$PW_LOG")"
second_file="$(sed -n '2s/.* file=\([^ ]*\) .*/\1/p' "$PW_LOG")"
[[ -n "$first_file" && "$first_file" != "$second_file" ]] || fail "498 re-injection must use a new file path"
[[ "$first_file" == "$TMP/inbox/fixture/"* || "$first_file" == "$(cd "$TMP" && pwd -P)/inbox/fixture/"* ]] ||
  fail "498 prompt file must live in the (fixture) job dir: $first_file"
pw_reset
pw_never_out="$(TEST_FIXTURE_SCENARIO=landing-no pw_spawn codex-luna 2>&1)"
grep -q 'landed=no' <<<"$pw_never_out" || fail "498 never-lands: $pw_never_out"
[[ "$(pw_calls)" -eq 2 && "$(herdr_briefs)" -eq 2 ]] || fail "498 at most one re-injection"
echo "PASS 498-i2-reinject-once-new-file"

# A-5: rc 4 (no daemon socket = guaranteed unsent) and only rc 4 falls back to
# one direct herdr injection, visible on the OK line; never twice.
pw_reset
fb_out="$(WRK_PANEWIRE_PROMPT=daemon-down pw_spawn codex-luna 2>&1)"
grep -q '^OK pane=w:p1 .*landed=yes.* via=herdr-fallback$' <<<"$fb_out" || fail "498 fallback OK line: $fb_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "498 fallback must inject exactly once"
pw_reset
set +e
fb_no_out="$(WRK_PANEWIRE_PROMPT=daemon-down TEST_FIXTURE_SCENARIO=landing-working-no-marker pw_spawn codex-luna --landing-strict 2>&1)"
fb_no_rc=$?
set -e
[[ "$fb_no_rc" -eq 76 ]] || fail "498 fallback landed=no strict exit: $fb_no_rc"
grep -q '^OK pane=w:p1 .*landed=no.* via=herdr-fallback$' <<<"$fb_no_out" || fail "498 fallback no OK line: $fb_no_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "498 fallback must never repeat: $(herdr_briefs)"
grep -q 'reason=fallback-once' <<<"$fb_no_out" || fail "498 fallback no-retry reason: $fb_no_out"
pw_reset
missing_out="$(PANEWIRE_BIN="$TMP/absent-panewire" pw_spawn codex-luna 2>&1)"
grep -q 'landed=yes.* via=herdr-fallback$' <<<"$missing_out" || fail "498 missing panewire binary: $missing_out"
[[ "$(herdr_briefs)" -eq 1 ]] || fail "498 missing panewire: one injection"
# rc 3, rc 5 and both rc 6 flavors never fall back.
for pw_mode in timeout expect-fail rejected-unsent rejected; do
  pw_reset
  set +e
  nf_out="$(WRK_PANEWIRE_PROMPT="$pw_mode" TEST_FIXTURE_SCENARIO=landing-no pw_spawn codex-luna --landing-strict 2>&1)"
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
# not a folded marker — an unindented break mid-line, an unindented break at a
# line start, a UI tab on one line (no line break), and an indented break
# mid-line (not after `❭`/line start). A leftmost-match matcher returns on the
# first variant, so ordering is part of the test: every discriminating variant
# must be evaluated. With no other evidence this is confirmed non-landing:
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
blocked3="$(WRK_GATE_MODE=3 spawn_base codex-luna 2>&1 || true)"
grep -q 'gate blocked' <<<"$blocked3"
[[ ! -e "$TMP/herdr.log" ]]
blocked4="$(WRK_GATE_MODE=4 spawn_base codex-luna 2>&1 || true)"
grep -q 'measurement unavailable' <<<"$blocked4"
[[ ! -e "$TMP/herdr.log" ]]
rm -f "$TMP/herdr.log"
unsupported="$(WRK_GATE_MODE=unsupported spawn_base codex-luna 2>&1)"
grep -q 'no gate subcommand' <<<"$unsupported"
[[ -e "$TMP/herdr.log" ]]
rm -f "$TMP/herdr.log"
run_fail env WRK_GATE_MODE=broken HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l fixture --t T1
SCOPEFUEL_BIN="$TMP/missing-scopefuel" HERDR_BIN="$HERDR" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l fixture \
  --t T1 >"$TMP/missing.out" 2>&1
grep -q 'scopefuel unavailable; quota gate skipped' "$TMP/missing.out"
grep -q 'scopefuel refresh skipped; gate/arbiter did not provide a pool' "$TMP/missing.out"
grep -q 'model=codex-luna' "$TMP/missing.out"

# ROB-1227 D4: refresh is detached, uses the gate-provided pool, and exposes
# failure/timeout warnings without changing the successful spawn.
# A total-spawn stopwatch also measures trust/gate/task setup, which made the
# old 1800ms assertions fail on both main and the heavy-queue head. Instead,
# hold the refresh fixture at a fifo and observe spawn/refresh events. The
# shared loose deadline still rejects a gross delay or a missing timeout.
refresh_bound_s=10
refresh_start_case() {
  local name="$1" timeout="$2"
  refresh_ready="$TMP/refresh-$name.ready"
  refresh_fifo="$TMP/refresh-$name.release"
  refresh_done="$TMP/refresh-$name.done"
  refresh_rc="$TMP/refresh-$name.rc"
  refresh_out="$TMP/refresh-$name.out"
  mkfifo "$refresh_fifo"
  refresh_deadline=$(( SECONDS + refresh_bound_s ))
  (
    set +e
    TEST_OWN_SESSION=0 WRK_REFRESH_MODE=hold WRK_REFRESH_TIMEOUT_S="$timeout" \
      WRK_REFRESH_READY_FILE="$refresh_ready" WRK_REFRESH_RELEASE_FIFO="$refresh_fifo" \
      spawn_base codex-luna >"$refresh_out" 2>&1
    printf '%s\n' "$?" >"$refresh_rc"
    : >"$refresh_done"
  ) &
  refresh_spawn_pid=$!
  own "$refresh_spawn_pid"
}
refresh_wait() {
  local failure="$1"; shift
  local remaining=$(( refresh_deadline - SECONDS ))
  if (( remaining <= 0 )) || ! wait_until "$remaining" "$@"; then
    fail "D4 $failure (loose ${refresh_bound_s}s bound)"
  fi
}
refresh_spawn_ready() {
  [[ -s "$refresh_ready" && -e "$refresh_done" ]]
}
refresh_child_dead() {
  ! ps -p "$(cat "$refresh_ready")" -o pid= | grep -q '[0-9]'
}
refresh_timeout_finished() {
  refresh_spawn_ready &&
    grep -q 'scopefuel refresh timed out for pool=codex; spawn already succeeded' "$refresh_out" &&
    refresh_child_dead
}
: >"$TMP/refresh.log"
refresh_start_case detached 30
refresh_wait 'spawn did not return while refresh was held' refresh_spawn_ready
wait "$refresh_spawn_pid"
[[ "$(cat "$refresh_rc")" -eq 0 ]] || fail 'D4 detached spawn failed'
success_out="$(cat "$refresh_out")"
grep -q 'model=codex-luna' <<<"$success_out"
ps -p "$(cat "$refresh_ready")" -o pid= | grep -q '[0-9]' ||
  fail 'D4 spawn did not return while refresh was held at the fifo'
[[ ! -s "$TMP/refresh.log" ]] || fail 'D4 held refresh completed before release'
python3 - "$refresh_fifo" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)
try:
    os.write(fd, b"\n")
finally:
    os.close(fd)
PY
refresh_wait 'released refresh did not log its pool/background arguments' \
  grep -q '^refresh codex --background$' "$TMP/refresh.log"
refresh_wait 'released refresh child did not exit' refresh_child_dead
echo 'PASS D4-refresh-detached-until-fixture-release'

failed_out="$(WRK_REFRESH_MODE=fail spawn_base codex-luna 2>&1)"
grep -q 'scopefuel refresh failed for pool=codex; spawn already succeeded' <<<"$failed_out"
grep -q 'model=codex-luna' <<<"$failed_out"

: >"$TMP/refresh.pids"
: >"$TMP/refresh.log"
refresh_start_case timeout 0.2
refresh_wait 'refresh did not time out and reap its unreleased fixture' refresh_timeout_finished
wait "$refresh_spawn_pid"
[[ "$(cat "$refresh_rc")" -eq 0 ]] || fail 'D4 timed-out refresh changed spawn success'
timeout_out="$(cat "$refresh_out")"
grep -q 'scopefuel refresh timed out for pool=codex; spawn already succeeded' <<<"$timeout_out"
grep -q 'model=codex-luna' <<<"$timeout_out"
# No writer ever released this fifo: the supervisor timed out and reaped the
# blocked fixture, rather than waiting for a chosen sleep duration to finish.
[[ ! -s "$TMP/refresh.log" ]] || fail 'D4 timed-out fixture passed the unreleased fifo'
while IFS= read -r refresh_pid; do
  [[ -z "$refresh_pid" ]] || ! ps -p "$refresh_pid" -o pid= | grep -q '[0-9]'
done <"$TMP/refresh.pids"
echo 'PASS D4-refresh-timeout-reaps-unreleased-fixture'

cp "$SCOPEFUEL" "$TMP/non-executable-scopefuel"
chmod -x "$TMP/non-executable-scopefuel"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$TMP/non-executable-scopefuel" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l fixture --t T1

# ---------------------------------------------------------------------------
# ROB-1199/ROB-1201: arbiter admission control. wrk holds no pool mapping — arbiter reads
# the pool out of scopefuel's own gate output and validates it against
# `scopefuel --json`. There is no bypass flag; only an absent/too-old arbiter is
# tolerated, and only with a warning.
# ---------------------------------------------------------------------------

# ⑦ arbiter not installed at all → warn, spawn proceeds (installation transition).
rm -f "$TMP/herdr.log"
absent_out="$(spawn_base codex-luna 2>&1)"
grep -q 'arbiter unavailable' <<<"$absent_out"
grep -q 'model=codex-luna' <<<"$absent_out"
[[ -e "$TMP/herdr.log" ]]

# ⑦ installed arbiter that predates the lease subcommand → warn, spawn proceeds.
rm -f "$TMP/herdr.log"
export TEST_ARBITER_BIN="$ROOT/tests/fixtures/arbiter-legacy"
legacy_out="$(spawn_base codex-luna 2>&1)"
grep -q 'no lease subcommand' <<<"$legacy_out"
grep -q 'model=codex-luna' <<<"$legacy_out"
[[ -e "$TMP/herdr.log" ]]
unset TEST_ARBITER_BIN

# An arbiter command failure is observational for quota_pool; spawning continues.
cp "$ARBITER" "$TMP/non-executable-arbiter"
chmod -x "$TMP/non-executable-arbiter"
rm -f "$TMP/herdr.log"
export TEST_ARBITER_BIN="$TMP/non-executable-arbiter"
nonexec_out="$(spawn_base codex-luna 2>&1)"
grep -q 'quota-pool record unavailable' <<<"$nonexec_out"
grep -q 'model=codex-luna' <<<"$nonexec_out"
[[ -e "$TMP/herdr.log" ]]
unset TEST_ARBITER_BIN

# ⑥ record: the gate passes, arbiter records the pool scopefuel resolved, and the
# worker is handed its own job/resource/profile identity.
export TEST_ARBITER_BIN="$ARBITER"
rm -f "$TMP/herdr.log"
admit_out="$(spawn_base codex-luna --job arb-ok --t T2 2>&1)"
grep -q 'quota_record=codex/quota_pool' <<<"$admit_out"
grep -q 'job=arb-ok' <<<"$admit_out"
grep -q 'ARBITER_JOB=arb-ok' "$TMP/herdr.log"
grep -q 'ARBITER_RESOURCE=codex' "$TMP/herdr.log"
grep -q 'ARBITER_KIND=quota_pool' "$TMP/herdr.log"
grep -q 'ARBITER_PROFILE=codex-luna-max' "$TMP/herdr.log"
grep -q 'ARBITER_STARTED_AT=' "$TMP/herdr.log"
arb status --job arb-ok --json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["quota_pool_records"]; assert len(r)==1 and r[0]["pool"]=="codex" and r[0]["profile"]=="codex-luna-max", d'
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

# ---------------------------------------------------------------------------
# task #677: the quota_pool.record launch_profile must carry the canonical
# catalog profile, not the launcher spelling. codex-sol/codex-max/codex/
# builder-sol/captain-sol all run gpt-6.1-sol (#1026), whose catalog profile is
# codex-sol (scopefuel PROFILE_ALIASES: codex-max -> codex-sol; `policy launch
# builder-sol` is not in the catalog at all). Recording the raw spelling split
# reps/usage attribution across names the grade table cannot read — 2026-09-25:
# a builder-sol xhigh spawn recorded launch_profile=builder-sol@xhigh and
# profile=codex-max while its pane ran gpt-6-sol xhigh. The ROB-1213
# cross-checked fields stay put (pool from scopefuel, profile gate-normalized);
# non-codex pools keep their literal spelling@effort, so no other pool's records
# change; rollback spellings (codex-sol56, codex-sol6) stay literal by design —
# builder-sol6 still records codex-sol@high through its grade consult even
# though its model id stays literal.
# Mutant: revert the canonical-name mapping in arbiter_admit -> these go RED.
# ---------------------------------------------------------------------------
# Own arbiter state (like the R20/R21/idempotency sections): these successful
# spawns leave durable quota records behind, and the shared suite inbox later
# asserts on the exact record set (e.g. no claude records after a released
# spawn). Records written here must not leak into that set.
T677_INBOX="$TMP/inbox-677"
T677_XDG="$TMP/xdg-677"
# #912: the devin launch_profile case below is a real spawn; its fixture XDG
# root needs a store that covers $ROOT, like the suite-level seed does.
devin_trust_seed_store "$T677_XDG" "$ROOT"
launch_profile_case() {
  local model="$1" job="$2" expected="$3"; shift 3
  ARBITER_INBOX_ROOT="$T677_INBOX" XDG_DATA_HOME="$T677_XDG" \
    spawn_base "$model" --job "$job" --t T1 "$@" >/dev/null
  python3 - "$T677_INBOX/$job/events" "$expected" "$model" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(event for event in events if event["kind"] == "quota_pool.record")
got = record["payload"]["launch_profile"]
assert got == sys.argv[2], f"{sys.argv[3]}: launch_profile={got!r} expected {sys.argv[2]!r}"
PY
}
# Every codex spelling: the raw aliases collapse onto the canonical catalog
# profile, the spellings that already are canonical stay put, and the ROB-591
# rollback spellings stay literal (they pin the superseded model).
launch_profile_case codex-sol codex-sol-xhigh 'codex-sol@xhigh' --effort xhigh
launch_profile_case builder-sol builder-sol-canon 'codex-sol@high' --role builder --lane builder-sol-lane --parent parent-lane
launch_profile_case captain-sol captain-sol-canon 'codex-sol@high' --role builder --lane captain-sol-lane --parent parent-lane
launch_profile_case codex-max codex-max-canon 'codex-sol@max'
launch_profile_case codex codex-canon 'codex-sol@high'
launch_profile_case codex-sol56 codex-sol56-rollback 'codex-sol56@max'
# #1026: codex-sol6 records its literal spelling@effort like codex-sol56, while
# builder-sol6 still lands on the canonical consult rung codex-sol@high.
launch_profile_case codex-sol6 codex-sol6-rollback 'codex-sol6@max'
launch_profile_case builder-sol6 builder-sol6-canon 'codex-sol@high' --role builder --lane builder-sol6-lane --parent parent-lane
launch_profile_case codex-luna codex-luna-canon 'codex-luna@medium'
launch_profile_case codex-luna-max codex-luna-max-canon 'codex-luna-max@max'
launch_profile_case codex-luna-hi codex-luna-hi-canon 'codex-luna@high'
launch_profile_case codex-luna56 codex-luna56-rollback 'codex-luna56@medium'
launch_profile_case builder-luna builder-luna-canon 'codex-luna@xhigh' --role builder --lane builder-luna-lane --parent parent-lane
# #921: builder-sonnet records the canonical catalog rung on the claude pool,
# not the launcher spelling — sonnet@xhigh by default, sonnet@max on the
# seat-rule exception rung.
launch_profile_case builder-sonnet builder-sonnet-canon 'sonnet@xhigh' --role builder --lane builder-sonnet-canon-lane --parent parent-lane
launch_profile_case builder-sonnet builder-sonnet-canon-max 'sonnet@max' --role builder --lane builder-sonnet-canon-max-lane --parent parent-lane --effort max
launch_profile_case builder-sonnet builder-sonnet-canon-high 'sonnet@high' --role builder --lane builder-sonnet-canon-high-lane --parent parent-lane --effort high
launch_profile_case codex-astra codex-astra-canon 'codex-astra@xhigh'
# hk 2043: the normal pinned sol spelling records its canonical rung — no E6
# marker, but the gate judges codex-sol@xhigh (an escalation rung, so the
# fixture gate takes the operator REF).
launch_profile_case builder-sol-xhigh builder-sol-xhigh-canon 'codex-sol@xhigh' \
  --role builder --lane builder-sol-xhigh-lane --parent parent-lane --operator-request hk:task/2043
# Other pools keep their literal spelling@effort — no other pool's record moves.
launch_profile_case devin-swe2 devin-launch-literal 'devin-swe2'
launch_profile_case builder-opus builder-opus-launch-literal 'builder-opus@high' --role builder --lane builder-opus-lane --parent parent-lane
launch_profile_case grok grok-launch-literal 'grok@high'
python3 - "$T677_INBOX/codex-sol-xhigh/events" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(event for event in events if event["kind"] == "quota_pool.record")
assert record["payload"]["pool"] == "codex", record
assert record["payload"]["profile"] == "codex-max", record
PY
echo "PASS 677 launch_profile carries the canonical catalog profile for codex aliases"

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

# hk 1604: devin-ds41 is judged as itself, still on scopefuel's single devin
# pool. The spawn receipt keeps the launcher spelling (here the same name).
rm -f "$TMP/herdr.log" "$TMP/scopefuel.log"
ds41_admit_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-ds41 --job arb-devin-ds41 --t T1 2>&1)"
grep -qx 'profile=devin-ds41 pool=devin used_pct=12.5 class=preserve' <<<"$ds41_admit_out"
grep -q 'quota_record=devin/quota_pool' <<<"$ds41_admit_out"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == 'devin-ds41' ]]
arb status --job arb-devin-ds41 --json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["quota_pool_records"]; assert len(r)==1 and r[0]["pool"]=="devin" and r[0]["profile"]=="devin-ds41", d'
python3 - "$ARBITER_INBOX_ROOT/arb-devin-ds41/events" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
spawned = next(event for event in events if event["kind"] == "job.spawned")
assert spawned["payload"]["profile"] == "devin-ds41", spawned
PY
echo "PASS devin-ds41 gates as itself on the devin quota pool"

# ⑥ the pool is a record, not a mutex: another job asking for the same pool
# succeeds and both records remain visible.
rm -f "$TMP/herdr.log"
second_out="$(spawn_base codex-luna --job arb-second --t T2 2>&1)"
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
active_dup_out="$(spawn_base codex-luna --job idem-active --t T2 2>&1)"
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
arb lease --job idem-released --kind quota_pool --profile codex-luna-max --gate-output <("$SCOPEFUEL" gate -m codex-luna-max) >/dev/null
arb release --job idem-released --resource codex --kind quota_pool >/dev/null
rm -f "$TMP/herdr.log"
released_dup_out="$(spawn_base codex-luna --job idem-released --t T3 2>&1)"
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
unknown_dup_out="$(spawn_base codex-luna --job idem-unknown --t T1 2>&1)"
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
override_out="$(spawn_base codex-luna --job idem-override --t T1 --job-dup-ok 2>&1)"
grep -q '^OK ' <<<"$override_out"
grep -q 'job-dup-ok override' <<<"$override_out"
grep -q 'state=claimed' <<<"$override_out"
[[ -e "$TMP/herdr.log" ]] || { echo "explicit duplicate override did not reach Herdr spawn" >&2; exit 1; }
echo "PASS ROB-1326 AC8 explicit active duplicate override: $override_out"

# AC6: a successful fixture spawn writes a queryable receipt.  Its recording
# failure is non-transactional: the pane remains successful but job-get says
# receipt=absent, and wrk emits a warning.
rm -f "$TMP/herdr.log"
receipt_out="$(spawn_base codex-luna --job idem-receipt --t T1 2>&1)"
grep -q '^OK pane=w:p1' <<<"$receipt_out"
arb job-get --job idem-receipt --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = d["receipt"]
assert r["pane_id"] == "w:p1", d
assert r["spawned_at"], d
assert r["label"] == "fixture", d
assert r["profile"] == "codex-luna", d
assert r["workspace"] == "w", d
assert "job.spawned" in d["recent_event_kinds"], d
'
export REAL_ARBITER="$ARBITER"
export WRK_ARBITER_PROXY_MODE=spawn-receipt-fails
export TEST_ARBITER_BIN="$ROOT/tests/fixtures/arbiter-proxy"
rm -f "$TMP/herdr.log"
receipt_fail_out="$(spawn_base codex-luna --job idem-receipt-fail --t T1 2>&1)"
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
record_failed_out="$(spawn_base codex-luna --job arb-record-fail --t T1 2>&1)"
grep -q 'arbiter quota-pool record failed' <<<"$record_failed_out"
grep -q 'model=codex-luna' <<<"$record_failed_out"
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
  local extra=("$@")
  # #768: --role builder requires --task before the gate these cases probe.
  # Draw from the same pre-minted pool spawn_base uses; worker-role calls keep
  # the suite's HK_TASK_ID env inheritance instead.
  case " ${extra[*]-} " in
    *" --task "*|*" --parent-job "*) ;;
    *" --role builder "*)
      extra+=(--task "$(mint_task)")
      printf '%s\n' "${extra[@]: -1}" >>"$TMP/spawn-task.log" ;;
  esac
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="${TEST_ARBITER_BIN:-$TMP/absent-arbiter}" \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml" \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$log" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
    "$WRK" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture "${extra[@]}"
}

# AC-1: without an operator request an implicit fable spawn cannot take a
# counsel seat; it is refused before catalog/gate and never reaches Herdr.
set +e
esc_denied_out="$(spawn_deny "$TMP/herdr-esc-denied.log" fable --job esc-denied --t T1 2>&1)"
esc_denied_rc=$?
set -e
[[ "$esc_denied_rc" -eq 2 ]] ||
  fail "fable without --operator-request must stay refused (rc=$esc_denied_rc): $esc_denied_out"
grep -q 'astra/fable worker role forbidden' <<<"$esc_denied_out" ||
  fail "fable denial lost the role-condition reason: $esc_denied_out"
[[ ! -e "$TMP/herdr-esc-denied.log" ]] ||
  fail "a refused unqualified fable spawn reached Herdr"
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

# --requested-by alone does not qualify implicit fable as counsel. The worker
# role condition refuses before catalog/gate; no Herdr call is permitted.
set +e
esc_orphan_out="$(spawn_deny "$TMP/herdr-esc-orphan.log" fable --job esc-orphan --t T1 \
  --requested-by operator 2>&1)"
esc_orphan_rc=$?
set -e
[[ "$esc_orphan_rc" -eq 2 ]] ||
  fail "implicit orphan --requested-by must stay refused (rc=$esc_orphan_rc): $esc_orphan_out"
grep -q 'astra/fable worker role forbidden' <<<"$esc_orphan_out" ||
  fail "orphan requested-by lost the role-condition reason: $esc_orphan_out"
[[ ! -e "$TMP/herdr-esc-orphan.log" ]] ||
  fail "an orphan requested-by reached Herdr"
echo "PASS orphan-requested-by-denied rc=$esc_orphan_rc"

# The explicitly named counsel seat still exercises the gate's orphan audit
# contract, independently of implicit-role eligibility.
set +e
esc_counsel_orphan_out="$(spawn_deny "$TMP/herdr-esc-counsel-orphan.log" fable \
  --role counsel --job esc-counsel-orphan --t T1 --requested-by operator 2>&1)"
esc_counsel_orphan_rc=$?
set -e
[[ "$esc_counsel_orphan_rc" -eq 3 ]] ||
  fail "explicit counsel orphan must stay gate-denied (rc=$esc_counsel_orphan_rc): $esc_counsel_orphan_out"
grep -q 'requested_by_requires_operator_request' <<<"$esc_counsel_orphan_out" ||
  fail "counsel orphan lost the gate's reason: $esc_counsel_orphan_out"
[[ ! -e "$TMP/herdr-esc-counsel-orphan.log" ]] ||
  fail "an explicit counsel orphan reached Herdr"
echo "PASS explicit-counsel-orphan-requested-by-gate-denied rc=$esc_counsel_orphan_rc"

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
plain_out="$(spawn_base codex-luna --job esc-plain --t T1 2>&1)"
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
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l fixture --t T1 --purpose

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

# Explicit counsel role denial: a disallowed purpose is refused by the gate with rc 5, which
# wrk remaps to exit 77 — exit 5 is already quota_hub_policy_gate's
# hub-quota-policy denial, so sharing it would let a caller misread a role
# denial as a quota stop.
set +e
role_denied_out="$(spawn_deny "$TMP/herdr-astra-role.log" codex-astra --job astra-role --t T1 \
  --role counsel --purpose worker 2>&1)"
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
plain_purpose_out="$(spawn_base codex-luna --job plain-purpose --t T1 --purpose builder 2>&1)"
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
python3 - "$ARBITER_INBOX_ROOT/builder-opus-job/events/00001-job.claim.json" "$(tail -n 1 "$TMP/spawn-task.log")" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert set(event) == {"created_at", "job_id", "kind", "payload", "seq"}, event
assert event["kind"] == "job.claim", event
assert event["payload"] == {
    "agent_label": "fixture", "owner_lane": "builder-lane", "parent_lane": "parent-lane",
    "role": "builder", "t_level": "T1", "task_id": int(sys.argv[2]),
}, event
PY
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" escalate builder-opus-job --question 'need parent decision' >/dev/null
seed_join_round "$ARBITER_INBOX_ROOT" builder-opus-job
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

# hk 1672: no unverified builder seat; removed aliases retain their diagnostic.
builder_reject_astra() {
  local model="$1" tag="$2"; shift 2
  local job="builder-astra-reject-${model}-${tag}" output rc
  set +e
  output="$(spawn_base "$model" "$@" --job "$job" --t T1 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 2 ]] || fail "--role builder must reject $model (rc=$rc): $output"
  if [[ "$model" == codex-astra ]]; then
    grep -q 'requires --purpose round-extension and verified --round-ext REF' <<<"$output" ||
      fail "unverified builder must name its required grant: $output"
  else
    grep -q -- "--role builder rejects astra profile '$model'" <<<"$output" ||
      fail "removed astra alias must retain its builder diagnostic: $output"
    grep -q 'hk:doc decision/2026-09-21/astra-allowed-purposes-approved' <<<"$output" ||
      fail "removed alias must cite the operator decision: $output"
  fi
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
  output="$(spawn_base codex-luna --role "$rejected_role" --job "$job" --t T1 2>&1)"
  rc=$?
  set -e
  python3 - "$rc" "$rejected_role" "$output" <<'PY'
import sys
assert int(sys.argv[1]) == 2, "unknown --role %r must be a usage error, rc=%s output=%s" % (sys.argv[2], sys.argv[1], sys.argv[3])
PY
  grep -Fqx -- 'wrk: --role accepts worker, builder, tester, reviewer or counsel (legacy alias: captain)' <<<"$output" ||
    fail "unknown --role '$rejected_role' must hit role validation: $output"
  [[ ! -e "$ARBITER_INBOX_ROOT/$job/events/00001-job.claim.json" ]] || fail "unknown role must not claim $job"
}
role_must_fail admiral role-unknown-admiral
role_must_fail observer role-unknown-observer

role_must_require_value() {
  local job="$1" output rc
  set +e
  output="$(spawn_base codex-luna --role '' --job "$job" --t T1 2>&1)"
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
expect_exit 2 spawn_base codex-luna --role worker --lane worker-lane --parent parent-lane --job worker-hierarchy-regression
echo "PASS builder-parent-and-director-lane-guards"

for builder_profile in builder-opus captain-opus builder-sol builder-sol6 captain-sol builder-devin builder-grok builder-kimi builder-luna builder-sonnet \
  builder-opus-low builder-opus-medium builder-sonnet-xhigh builder-sonnet-max builder-sol-high builder-sol-xhigh builder-sol-max builder-sol-medium \
  builder-luna-max builder-kimi-high builder-kimi-max \
  builder-grok-low builder-grok-medium builder-grok-xhigh \
  builder-sonnet-medium builder-haiku-low builder-luna-low builder-luna-high builder-luna-medium \
  builder-sol-low builder-haiku-medium builder-haiku-high builder-haiku-xhigh builder-haiku-max builder-sonnet-low; do
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
accept_line="$(grep -nF 'builder-opus|builder-sol|builder-sol6|builder-devin|builder-devin-medium|builder-devin-max|builder-ds41|builder-ds41-max|builder-grok|builder-kimi|builder-luna|builder-sonnet|builder-opus-low|builder-opus-medium|builder-sonnet-xhigh|builder-sonnet-max|builder-sol-high|builder-sol-xhigh|builder-sol-max|builder-sol-medium|builder-luna-max|builder-kimi-high|builder-kimi-max|builder-grok-low|builder-grok-medium|builder-grok-xhigh|builder-sonnet-medium|builder-haiku-low|builder-haiku-medium|builder-luna-low|builder-luna-high|builder-luna-medium|builder-sol-low|builder-haiku-high|builder-haiku-xhigh|builder-haiku-max|builder-sonnet-low|devin-swe2|devin-swe2-medium|devin-swe2-max|grok|grok-hi|kimi-k3|captain-opus|captain-sol) ;;' "$ROOT/bin/wrk")"
[[ -n "$accept_line" ]] || fail "--role builder accept list drifted or was not found"
[[ "$(wc -l <<<"$accept_line" | tr -d ' ')" == 1 ]] ||
  fail "accept-list pattern is not unique: $accept_line"
# Token pattern covers the whole accept set: builder-*/captain-* spellings plus
# the pilot worker spellings. Bare 'grok' is not extracted (it also matches
# inside builder-grok); grok-hi presence covers it, and the literal accept-line
# pin above guards the list itself. `builder-level` is prose, `captain-NN` is a
# session name in SKILL.md — neither is a profile.
builder_tokens() { grep -oE '(builder|captain)-[a-z0-9-]+|devin-swe2-medium|devin-swe2-max|devin-swe2|grok-hi|kimi-k3' | grep -vxE 'builder-level|captain-[0-9]+' | grep -v '^builder-terra-' | sort -u; }
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
seed_join_round "$ARBITER_INBOX_ROOT" builder-reclaim-job
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
: >"$TMP/herdr.log" "$TMP/scopefuel.log" "$TMP/launch.log" 2>/dev/null || true
builder_sol_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base builder-sol --role builder --lane builder-sol-lane --parent parent-lane --job builder-sol-job --t T1 2>&1)"
grep -q 'model=builder-sol' <<<"$builder_sol_out"
grep -q -- '-m gpt-6.1-sol' "$TMP/herdr.log" ||
  fail "builder-sol must launch gpt-6.1-sol (#1026): $(cat "$TMP/herdr.log")"
# 2026-09-26 (decision 4088 B): builder-sol defaults to the high rung (the
# no-max seat refusal was repealed by hk 1863/hk 1864; the default stays high) —
# builder-sol runs codex-sol at effort high and consults the catalog at high.
grep -q 'model_reasoning_effort=high' "$TMP/herdr.log" ||
  fail "builder-sol must launch codex-sol at effort high: $(cat "$TMP/herdr.log")"
grep -q 'policy launch codex-sol effort=high' "$TMP/launch.log" ||
  fail "builder-sol must consult the catalog for codex-sol at effort high"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "codex-max" ]]

# ---------------------------------------------------------------------------
# #1026 (2026-09-30 operator decision): the codex-sol family switches to
# gpt-6.1-sol. AC1 — every switched spelling carries -m gpt-6.1-sol at today's
# effort, from the canon when it answers and from PROFILE_MODEL when it cannot.
# ---------------------------------------------------------------------------
sol61_case() {
  local model="$1" effort="$2"; shift 2
  : >"$TMP/herdr.log"
  spawn_base "$model" --job "sol61-$model" --t T1 "$@" >/dev/null
  grep -q -- '-m gpt-6.1-sol' "$TMP/herdr.log" ||
    fail "$model must carry -m gpt-6.1-sol from the canon: $(cat "$TMP/herdr.log")"
  grep -q "model_reasoning_effort=$effort" "$TMP/herdr.log" ||
    fail "$model must keep today's $effort rung: $(cat "$TMP/herdr.log")"
  # Unreachable canon: the literal PROFILE_MODEL must agree with the canon.
  : >"$TMP/herdr.log"
  WRK_LAUNCH_MODE=broken spawn_base "$model" --job "sol61-fb-$model" --t T1 "$@" >/dev/null
  grep -q -- '-m gpt-6.1-sol' "$TMP/herdr.log" ||
    fail "$model fallback must agree with the canon (-m gpt-6.1-sol): $(cat "$TMP/herdr.log")"
  grep -q "model_reasoning_effort=$effort" "$TMP/herdr.log" ||
    fail "$model fallback must keep today's $effort rung: $(cat "$TMP/herdr.log")"
}
sol61_case codex high
sol61_case codex-sol max
sol61_case codex-max max
sol61_case builder-sol high --role builder --lane sol61-builder-lane --parent parent-lane
sol61_case captain-sol high --role builder --lane sol61-captain-lane --parent parent-lane
# The E6 builder rungs are switched spellings too. hk 2043 made
# builder-sol-max a normal pinned spelling, so it is spawned here with no
# SCOPEFUEL_E6_ARM marker (its own case is below).
SCOPEFUEL_E6_ARM=codex-sol@high sol61_case builder-sol-high high --role builder --lane sol61-e6h-lane --parent parent-lane
sol61_case builder-sol-max max --role builder --lane sol61-e6x-lane --parent parent-lane
SCOPEFUEL_E6_ARM=codex-sol@medium sol61_case builder-sol-medium medium --role builder --lane sol61-e6m-lane --parent parent-lane
SCOPEFUEL_E6_ARM=codex-sol@low sol61_case builder-sol-low low --role builder --lane sol61-e6l-lane --parent parent-lane
# hk 2043: builder-sol-xhigh is the normal pinned xhigh spelling — same canon
# model id, xhigh rung, no E6 marker (the S+ escalation row still takes a REF).
sol61_case builder-sol-xhigh xhigh --role builder --lane sol61-xhigh-lane --parent parent-lane \
  --operator-request hk:task/2043
echo "PASS 1026-AC1-switched-spellings-carry-gpt-6.1-sol"

# AC2 — the rollback spellings pin the literal gpt-6-sol even though the fake
# canon now answers gpt-6.1-sol for codex-sol. codex-sol6 never consults the
# catalog at all (ROB-591 shape, like codex-sol56); builder-sol6 still gets the
# builder-seat consult at codex-sol@high but keeps the literal model id.
# NB: `: >a >b >c` needs a `>` per file — `: >a b c` passes b and c as
# arguments and only truncates a (see the one-file-per-line convention above).
: >"$TMP/herdr.log"
: >"$TMP/scopefuel.log"
: >"$TMP/launch.log"
sol6_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base codex-sol6 --job codex-sol6-job --t T1 2>&1)"
grep -q 'model=codex-sol6' <<<"$sol6_out"
grep -q -- '-m gpt-6-sol' "$TMP/herdr.log" ||
  fail "codex-sol6 must keep the literal -m gpt-6-sol: $(cat "$TMP/herdr.log")"
grep -q 'model_reasoning_effort=max' "$TMP/herdr.log" ||
  fail "codex-sol6 must keep codex-sol's max default: $(cat "$TMP/herdr.log")"
if grep -q 'gpt-6.1-sol' "$TMP/herdr.log"; then
  fail "codex-sol6 took the canon's model id: $(cat "$TMP/herdr.log")"
fi
[[ ! -s "$TMP/launch.log" ]] ||
  fail "codex-sol6 must not consult the catalog at all: $(cat "$TMP/launch.log")"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "codex-max" ]]

: >"$TMP/herdr.log"
: >"$TMP/scopefuel.log"
: >"$TMP/launch.log"
bsol6_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base builder-sol6 --role builder \
  --lane builder-sol6-lane --parent parent-lane --job builder-sol6-job --t T1 2>&1)"
grep -q 'model=builder-sol6' <<<"$bsol6_out" ||
  fail "builder-sol6 must be admitted under --role builder: $bsol6_out"
grep -q -- '-m gpt-6-sol' "$TMP/herdr.log" ||
  fail "builder-sol6 must keep the literal -m gpt-6-sol (canon serves gpt-6.1-sol): $(cat "$TMP/herdr.log")"
grep -q 'model_reasoning_effort=high' "$TMP/herdr.log" ||
  fail "builder-sol6 must launch at the builder-seat high rung: $(cat "$TMP/herdr.log")"
if grep -q 'gpt-6.1-sol' "$TMP/herdr.log"; then
  fail "builder-sol6 took the canon's model id: $(cat "$TMP/herdr.log")"
fi
# Exactly one consult, at exactly the graded rung — not a stray codex-sol6
# line, not an unpinned consult that would hand back the max default.
[[ "$(cat "$TMP/launch.log")" == 'policy launch codex-sol effort=high operator=0' ]] ||
  fail "builder-sol6 must still consult the catalog at codex-sol@high: $(cat "$TMP/launch.log")"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "codex-max" ]]
echo "PASS 1026-AC2-rollback-spellings-pin-gpt-6-sol"
# The AC4 assertion-RED mutants live in the mutants section below (mut_wrk /
# expect_red are defined there).

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

# A purpose outside #527's list cannot normalize an implicit worker to counsel.
# The named role-condition refusal happens before catalog/gate.
expect_exit 2 spawn_base codex-astra --purpose builder --job astra-bad-purpose --t T0
echo "PASS 593-astra-disallowed-purpose-role-condition-denied-2"

# 🔴 fable is NOT astra: #527 AC⑤ forbids relaxing its consult gate, so a
# purpose must never become a second key to it. Only --operator-request opens
# it. Without that request the implicit role stays worker and is refused
# before catalog/gate; a purpose alone must not normalize it to counsel.
fable_purpose_out="$(spawn_base fable --purpose architect --job fable-purpose --t T1 2>&1 || true)"
grep -q 'astra/fable worker role forbidden' <<<"$fable_purpose_out" ||
  fail "a purpose must not satisfy fable's consult_only: $fable_purpose_out"
echo "PASS 593-fable-not-unlocked-by-purpose"

# Mutants: a worker-grade profile, missing parent, and a non-high Opus effort
# must all stop before gate/claim/tab creation.
expect_exit 2 spawn_base codex-luna --role builder --lane builder-lane --parent parent-lane --job builder-worker-profile-mutant
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
builder_devin_run="$(grep '^pane run w:p1 devin ' "$TMP/herdr.log")"
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

# #635: devin effort is inside the model id, so "builder-devin takes the
# effort too" lands as the swe-2 effort spellings admitted under --role
# builder — same admission mechanism as the devin-swe2 pilot spelling.
for devin_builder_pair in "devin-swe2-medium:swe-2-medium" "devin-swe2-max:swe-2-max"; do
  devin_builder_profile="${devin_builder_pair%%:*}"
  devin_builder_model="${devin_builder_pair#*:}"
  : >"$TMP/herdr.log" "$TMP/scopefuel.log"
  set +e
  devin_variant_builder_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base "$devin_builder_profile" --role builder --lane "builder-${devin_builder_profile}-lane" --parent parent-lane --job "builder-${devin_builder_profile}-job" --t T1 2>&1)"
  devin_variant_builder_rc=$?
  set -e
  [[ "$devin_variant_builder_rc" -eq 0 ]] ||
    fail "$devin_builder_profile must be admitted under --role builder (rc=$devin_variant_builder_rc): $devin_variant_builder_out"
  grep -q "model=$devin_builder_profile" <<<"$devin_variant_builder_out" ||
    fail "$devin_builder_profile builder spawn output lost its model: $devin_variant_builder_out"
  devin_variant_builder_run="$(grep '^pane run w:p1 devin ' "$TMP/herdr.log")"
  [[ "$devin_variant_builder_run" == "pane run w:p1 devin --model $devin_builder_model --permission-mode dangerous --respect-workspace-trust false" ]] ||
    fail "$devin_builder_profile builder argv mismatch: $devin_variant_builder_run"
  [[ " $devin_variant_builder_run " != *' --effort '* ]] ||
    fail "$devin_builder_profile builder argv must not gain an effort flag"
  [[ "$(tail -n 1 "$TMP/scopefuel.log")" == "$devin_builder_profile" ]] ||
    fail "$devin_builder_profile must gate as itself (hk 1604), got: $(tail -n 1 "$TMP/scopefuel.log")"
  python3 - "$ARBITER_INBOX_ROOT/builder-${devin_builder_profile}-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
done
echo "PASS devin-swe2 effort spellings admitted under --role builder (#635)"

: >"$TMP/herdr.log" "$TMP/scopefuel.log"
set +e
builder_grok_out="$(TEST_OWN_SESSION=1 PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 spawn_base builder-grok --role builder --lane builder-grok-lane --parent parent-lane --job builder-grok-job --t T1 2>&1)"
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
# #737: builder-grok stays the un-pinned spelling — its gate argv carries no
# --effort and no marker is required (the E6 rungs own the rung pins).
if grep -q -- '--effort' "$TMP/scopefuel.log"; then
  fail "builder-grok must not forward a gate --effort: $(cat "$TMP/scopefuel.log")"
fi
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
builder_kimi_out="$(TEST_OWN_SESSION=1 KIMI_CODE_HOME="$TMP/kimi-builder-home" PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 spawn_base builder-kimi --role builder --lane builder-kimi-lane --parent parent-lane --job builder-kimi-job --t T1 2>&1)"
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

# #633 (#594 E3): builder-luna is codex-luna under --role builder, launched at
# the E3 effort (xhigh) and gated as the scopefuel-known codex-luna-max
# spelling like every other luna variant.
: >"$TMP/herdr.log" "$TMP/scopefuel.log"
set +e
builder_luna_out="$(TEST_OWN_SESSION=1 WRK_LAUNCH_LOG="$TMP/launch.log" PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 spawn_base builder-luna --role builder --lane builder-luna-lane --parent parent-lane --job builder-luna-job --t T1 2>&1)"
builder_luna_rc=$?
set -e
[[ "$builder_luna_rc" -eq 0 ]] ||
  fail "builder-luna must be admitted under --role builder (rc=$builder_luna_rc): $builder_luna_out"
grep -q 'model=builder-luna' <<<"$builder_luna_out" ||
  fail "builder-luna spawn output lost its model: $builder_luna_out"
builder_luna_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_luna_start" == 'agent start fixture --kind codex --pane w:p1 --timeout 120000 -- --yolo -m gpt-6-luna -c model_reasoning_effort=xhigh' ]] ||
  fail "builder-luna must launch the codex-luna argv at effort xhigh: $builder_luna_start"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "codex-luna-max" ]] ||
  fail "builder-luna must gate as the scopefuel-known codex-luna-max spelling"
grep -q 'policy launch codex-luna effort=xhigh' "$TMP/launch.log" ||
  fail "builder-luna must consult the catalog for codex-luna at effort xhigh"
python3 - "$ARBITER_INBOX_ROOT/builder-luna-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["owner_lane"] == "builder-luna-lane", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
# 급 가드 (grade guard): the catalog grades codex-luna per effort
# (medium=B, max=A+) and the E3 sample is rated at xhigh, so any other
# --effort is refused before gate/claim, exactly like builder-opus@high.
expect_exit 2 spawn_base builder-luna --role builder --lane builder-luna-lane --parent parent-lane --effort max --job builder-luna-effort-mutant
expect_exit 2 spawn_base builder-luna --role builder --lane builder-luna-lane --parent parent-lane --effort medium --job builder-luna-effort-low-mutant
expect_exit 2 spawn_base builder-luna --job builder-luna-role-mutant --t T1
echo "PASS builder-luna E3 profile launches codex-luna argv at xhigh"

# ---------------------------------------------------------------------------
# task #921 (operator report 2026-09-29, Sonnet 5.5 experiments E1/E2):
# builder-sonnet is the non-rung Sonnet builder seat — the builder-opus argv
# shape on the sonnet alias, a closed effort set (high|xhigh|max, default
# xhigh), and (until hk 1864 repealed the no-max seat rule) its only named max
# exception. It is NOT an E6 rung:
# no SCOPEFUEL_E6_ARM, no GATE_EFFORT_PIN — the gate sees bare `-m sonnet`
# (the fixture refuses a sonnet@xhigh/sonnet@max rung gate, so forwarding the
# effort would close the seat). The catalog consult pins the requested rung so
# a bare spawn cannot drift to sonnet's ordinary high default, and the quota
# record carries the canonical launch_profile sonnet@<effort> on pool=claude.
# ---------------------------------------------------------------------------
: >"$TMP/herdr.log" "$TMP/scopefuel.log" "$TMP/launch.log"
set +e
builder_sonnet_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base builder-sonnet \
  --role builder --lane builder-sonnet-lane --parent parent-lane \
  --job builder-sonnet-job --t T1 2>&1)"
builder_sonnet_rc=$?
set -e
[[ "$builder_sonnet_rc" -eq 0 ]] ||
  fail "builder-sonnet must be admitted under --role builder (rc=$builder_sonnet_rc): $builder_sonnet_out"
grep -q 'model=builder-sonnet' <<<"$builder_sonnet_out" ||
  fail "builder-sonnet spawn output lost its model: $builder_sonnet_out"
builder_sonnet_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_sonnet_start" == *' -- --model sonnet --dangerously-skip-permissions --effort xhigh' ]] ||
  fail "builder-sonnet must launch the builder-opus argv shape on sonnet at xhigh: $builder_sonnet_start"
grep -q 'policy launch sonnet effort=xhigh' "$TMP/launch.log" ||
  fail "builder-sonnet must consult the catalog for sonnet pinned at xhigh: $(cat "$TMP/launch.log")"
grep -qF 'gate -m sonnet' "$TMP/scopefuel.log" ||
  fail "builder-sonnet must gate as the sonnet spelling: $(cat "$TMP/scopefuel.log")"
if grep -qF 'gate -m sonnet --effort' "$TMP/scopefuel.log"; then
  fail "builder-sonnet is not a rung spelling — the gate must not see --effort: $(cat "$TMP/scopefuel.log")"
fi
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == sonnet ]] ||
  fail "builder-sonnet must gate as sonnet: $(cat "$TMP/scopefuel.log")"
python3 - "$ARBITER_INBOX_ROOT/builder-sonnet-job/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
claim = next(e for e in events if e["kind"] == "job.claim")
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert claim["payload"]["role"] == "builder", claim
assert claim["payload"]["parent_lane"] == "parent-lane", claim
assert claim["payload"]["owner_lane"] == "builder-sonnet-lane", claim
assert record["payload"]["launch_profile"] == "sonnet@xhigh", record
assert record["payload"]["pool"] == "claude", record
PY

# Explicit rungs restate or move within the closed set; the spawned argv and
# the canonical record track the selected rung.
: >"$TMP/herdr.log" "$TMP/scopefuel.log" "$TMP/launch.log"
builder_sonnet_high_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base builder-sonnet \
  --role builder --lane builder-sonnet-high-lane --parent parent-lane \
  --effort high --job builder-sonnet-high-job --t T1 2>&1)"
grep -q 'model=builder-sonnet' <<<"$builder_sonnet_high_out"
builder_sonnet_high_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_sonnet_high_start" == *' -- --model sonnet --dangerously-skip-permissions --effort high' ]] ||
  fail "builder-sonnet --effort high must carry the high rung in argv: $builder_sonnet_high_start"
grep -q 'policy launch sonnet effort=high' "$TMP/launch.log" ||
  fail "builder-sonnet --effort high must pin the catalog consult to high: $(cat "$TMP/launch.log")"
# --effort max: experiment E2 (no longer an exception since hk 1864). Admitted, argv and
# record both carry max.
: >"$TMP/herdr.log" "$TMP/scopefuel.log" "$TMP/launch.log"
builder_sonnet_max_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base builder-sonnet \
  --role builder --lane builder-sonnet-max-lane --parent parent-lane \
  --effort max --job builder-sonnet-max-job --t T1 2>&1)"
grep -q 'model=builder-sonnet' <<<"$builder_sonnet_max_out" ||
  fail "builder-sonnet --effort max must be admitted (named seat exception): $builder_sonnet_max_out"
builder_sonnet_max_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_sonnet_max_start" == *' -- --model sonnet --dangerously-skip-permissions --effort max' ]] ||
  fail "builder-sonnet --effort max must carry the max rung in argv: $builder_sonnet_max_start"
grep -q 'policy launch sonnet effort=max' "$TMP/launch.log" ||
  fail "builder-sonnet --effort max must pin the catalog consult to max: $(cat "$TMP/launch.log")"
python3 - "$ARBITER_INBOX_ROOT/builder-sonnet-max-job/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert record["payload"]["launch_profile"] == "sonnet@max", record
assert record["payload"]["pool"] == "claude", record
PY

# The effort set is closed: low, medium and ultra die on the builder-sonnet
# arm before resolve_profile (ultra would also die on the seat rule — the arm
# refuses it first, keeping the error on the closed set).
for sonnet_bad_effort in low medium ultra bogus; do
  set +e
  sonnet_bad_out="$(spawn_base builder-sonnet --role builder --lane builder-sonnet-bad-lane \
    --parent parent-lane --effort "$sonnet_bad_effort" --job "builder-sonnet-bad-$sonnet_bad_effort" --t T1 2>&1)"
  sonnet_bad_rc=$?
  set -e
  [[ "$sonnet_bad_rc" -eq 2 ]] ||
    fail "builder-sonnet --effort $sonnet_bad_effort must die rc 2 (rc=$sonnet_bad_rc): $sonnet_bad_out"
  grep -q 'builder-sonnet accepts only --effort high|xhigh|max' <<<"$sonnet_bad_out" ||
    fail "builder-sonnet --effort $sonnet_bad_effort refusal must name the closed set: $sonnet_bad_out"
  [[ ! -e "$ARBITER_INBOX_ROOT/builder-sonnet-bad-$sonnet_bad_effort/events/00001-job.claim.json" ]] ||
    fail "rejected builder-sonnet --effort $sonnet_bad_effort must not claim"
done
echo "PASS 921 builder-sonnet launches sonnet argv at high/xhigh/max, gates bare sonnet, records sonnet@<effort>"

# Assertion-RED mutants: each probes a copy of bin/wrk with exactly one
# behaviour removed. The probe must fail through an assertion (rc 1) — a
# usage error (rc 2+) or a silent pass (rc 0) means the check does not see
# the contract it claims to pin.
expect_red() {
  local label="$1"; shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] || fail "mutant $label: expected assertion RED (rc 1), got rc $rc"
}
mut_wrk() {  # dst old new — replace exactly one occurrence in a copy of bin/wrk
  python3 - "$WRK" "$1" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:]
text = open(src, encoding="utf-8").read()
assert text.count(old) == 1, "mutant source must occur exactly once: %r" % old
open(dst, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
  chmod +x "$1"
}
# $1=wrk path, $2=job tag, $3=expected argv tail; extra spawn flags after.
# Returns 0 iff the spawn is admitted and the pane argv ends " -- <tail>".
sonnet_builder_probe() {
  local wrk="$1" tag="$2" want_tail="$3"; shift 3
  : >"$TMP/herdr.log" "$TMP/scopefuel.log"
  local out start
  out="$(WRK="$wrk" spawn_base builder-sonnet --role builder --lane "mut-$tag-lane" \
    --parent parent-lane --job "mut-$tag" --t T1 "$@" 2>&1)" || return 1
  grep -q 'model=builder-sonnet' <<<"$out" || return 1
  start="$(grep '^agent start ' "$TMP/herdr.log")" || return 1
  [[ "$start" == *" -- $want_tail" ]] || return 1
}
# $1=wrk path, $2=model, $3=job tag; extra spawn flags after.
# Returns 0 iff the spawn is refused with rc 2.
builder_refused_probe() {
  local wrk="$1" model="$2" tag="$3"; shift 3
  local out rc
  out="$(WRK="$wrk" spawn_base "$model" --role builder --lane "mutr-$tag-lane" \
    --parent parent-lane --job "mutr-$tag" --t T1 "$@" 2>&1)"
  rc=$?
  [[ "$rc" -eq 2 ]] || return 1
}
# $1=wrk path, $2=job tag — 0 iff the quota record is sonnet@xhigh.
sonnet_builder_record_probe() {
  local wrk="$1" tag="$2"
  ARBITER_INBOX_ROOT="$TMP/mut-inbox-$tag" XDG_DATA_HOME="$TMP/mut-xdg-$tag" \
    WRK="$wrk" spawn_base builder-sonnet --role builder --lane "mutq-$tag-lane" \
    --parent parent-lane --job "mutq-$tag" --t T1 >/dev/null 2>&1 || return 1
  python3 - "$TMP/mut-inbox-$tag/mutq-$tag/events" <<'PY' || return 1
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert record["payload"]["launch_profile"] == "sonnet@xhigh", record
PY
}
MUT921="$TMP/mutants-921"
mkdir -p "$MUT921"
# 1. Model mapping: the sonnet alias swapped for opus turns the argv probe RED.
mut_wrk "$MUT921/wrk-model" \
  'builder-sonnet) PROFILE_KIND=claude; DEFAULT_EFFORT=xhigh; EFFORT_SUPPORTED=1; ARGS=(--model sonnet --dangerously-skip-permissions) ;;' \
  'builder-sonnet) PROFILE_KIND=claude; DEFAULT_EFFORT=xhigh; EFFORT_SUPPORTED=1; ARGS=(--model opus --dangerously-skip-permissions) ;;'
# 2. Effort validation: widening the closed set admits --effort low, which the
#    refusal probe must still see die.
mut_wrk "$MUT921/wrk-effortset" \
  'high|xhigh|max) ;;' \
  'high|xhigh|max|low) ;;'
# 3. Effort propagation: dropping the claude --effort append strips the rung
#    from the pane argv entirely.
# shellcheck disable=SC2016 # the pattern is bin/wrk source text, not an expansion
mut_wrk "$MUT921/wrk-effortflag" \
  '        ARGS+=(--effort "$EFFECTIVE_EFFORT")' \
  '        :'
# 4. launch_profile canonicalization: the builder-sonnet arm must record the
#    catalog name sonnet@<effort>, not the launcher spelling.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
mut_wrk "$MUT921/wrk-launchname" \
  'elif [[ "$MODEL" == builder-sonnet ]]; then' \
  'elif [[ "$MODEL" == builder-sonnet-removed ]]; then'
# 5. Seat rule: since hk 1864 the builder seat refuses ultra only (the
#    builder-sonnet max exception is moot). Dropping the ultra arm opens ultra
#    for every builder — builder-sol --effort ultra must still die.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
mut_wrk "$MUT921/wrk-seat" \
  '    case "$seat_effort" in
      ultra)' \
  '    case "$seat_effort" in
      never)'
# 6. Catalog pin: without the ${EFFORT:-xhigh} pin the consult returns sonnet's
#    ordinary high default and a bare spawn silently launches high.
# shellcheck disable=SC2016 # the pattern is bin/wrk source text, not an expansion
mut_wrk "$MUT921/wrk-catalogpin" \
  'builder-sonnet) CATALOG_PROFILE=sonnet; CATALOG_EFFORT_PIN="${EFFORT:-xhigh}" ;;' \
  'builder-sonnet) CATALOG_PROFILE=sonnet ;;'
expect_red model-swapped-to-opus sonnet_builder_probe "$MUT921/wrk-model" m1 '--model sonnet --dangerously-skip-permissions --effort xhigh'
expect_red effort-set-widened builder_refused_probe "$MUT921/wrk-effortset" builder-sonnet e1 --effort low
expect_red effort-flag-dropped sonnet_builder_probe "$MUT921/wrk-effortflag" e2 '--model sonnet --dangerously-skip-permissions --effort xhigh'
expect_red launch-name-literal sonnet_builder_record_probe "$MUT921/wrk-launchname" q1
expect_red seat-ultra-arm-dropped builder_refused_probe "$MUT921/wrk-seat" builder-sol s1 --effort ultra
expect_red catalog-pin-dropped sonnet_builder_probe "$MUT921/wrk-catalogpin" c1 '--model sonnet --dangerously-skip-permissions --effort xhigh'
echo "PASS 921 mutants assertion-red=6/6 (model map, effort set, effort flag, launch_profile, seat ultra arm, catalog pin)"

# ---------------------------------------------------------------------------
# #1026 AC4 — assertion-RED mutants for the gpt-6.1-sol switch.
# ---------------------------------------------------------------------------
# $1=wrk path; 0 iff a codex-sol6 spawn keeps the literal gpt-6-sol argv.
sol6_literal_probe() {
  local wrk="$1" out start
  : >"$TMP/herdr.log"
  out="$(WRK="$wrk" spawn_base codex-sol6 --job "mut-sol6" --t T1 2>&1)" || return 1
  start="$(grep '^agent start ' "$TMP/herdr.log")" || return 1
  [[ "$start" == *" -m gpt-6-sol "* ]] || return 1
}
# $1=wrk path; 0 iff an unreachable-canon codex-sol spawn carries gpt-6.1-sol.
sol_fallback_probe() {
  local wrk="$1" out start
  : >"$TMP/herdr.log"
  out="$(WRK="$wrk" WRK_LAUNCH_MODE=broken spawn_base codex-sol --job "mut-solfb" --t T1 2>&1)" || return 1
  start="$(grep '^agent start ' "$TMP/herdr.log")" || return 1
  [[ "$start" == *" -m gpt-6.1-sol "* ]] || return 1
}
MUT1026="$TMP/mutants-1026"
mkdir -p "$MUT1026"
# M1 — invariant: a rollback spelling never takes the canon's model id.
# Mapping codex-sol6 into resolve_catalog_profile lets the served gpt-6.1-sol
# through; the literal argv probe goes RED.
mut_wrk "$MUT1026/wrk-sol6-canon" \
  'codex-sol|codex-max) CATALOG_PROFILE=codex-sol ;;' \
  'codex-sol|codex-max|codex-sol6) CATALOG_PROFILE=codex-sol ;;'
# M2 — invariant: the fallback table agrees with the canon. A literal left on
# gpt-6-sol silently rolls an unreachable-canon launch back; the fallback
# probe goes RED.
mut_wrk "$MUT1026/wrk-fallback" \
  'codex-sol) PROFILE_KIND=codex; PROFILE_MODEL=gpt-6.1-sol; DEFAULT_EFFORT=max' \
  'codex-sol) PROFILE_KIND=codex; PROFILE_MODEL=gpt-6-sol; DEFAULT_EFFORT=max'
expect_red sol6-takes-canon-model sol6_literal_probe "$MUT1026/wrk-sol6-canon"
expect_red fallback-table-stale sol_fallback_probe "$MUT1026/wrk-fallback"
echo "PASS 1026-AC4-mutants-red"

# #666: the devin effort rungs exist as named builder spellings — same
# unattended argv as the worker variants, refused without --role builder.
# hk 1604: each seat gates as its runtime profile (scopefuel grades.py
# _BUILDER_RUNGS), not as devin-swe2. builder-ds41[-max] is the paid rung
# admitted per the operator's ds41-builder policy; the ds41 worker spellings
# stay worker-only (the refusal loop below pins that).
for devin_builder_pair in \
  "builder-devin-medium:swe-2-medium:devin-swe2-medium" \
  "builder-devin-max:swe-2-max:devin-swe2-max" \
  "builder-ds41:deepseek-v4-1-flash-high:devin-ds41" \
  "builder-ds41-max:deepseek-v4-1-flash-max:devin-ds41-max"; do
  devin_builder_profile="${devin_builder_pair%%:*}"
  devin_builder_rest="${devin_builder_pair#*:}"
  devin_builder_model="${devin_builder_rest%%:*}"
  devin_builder_gate="${devin_builder_rest#*:}"
  : >"$TMP/herdr.log" "$TMP/scopefuel.log"
  set +e
  devin_builder_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base "$devin_builder_profile" --role builder --lane "$devin_builder_profile-lane" --parent parent-lane --job "$devin_builder_profile-job" --t T1 2>&1)"
  devin_builder_rc=$?
  set -e
  [[ "$devin_builder_rc" -eq 0 ]] ||
    fail "$devin_builder_profile must be admitted under --role builder (rc=$devin_builder_rc): $devin_builder_out"
  grep -q "model=$devin_builder_profile" <<<"$devin_builder_out" ||
    fail "$devin_builder_profile spawn output lost its model: $devin_builder_out"
  devin_builder_run="$(grep '^pane run w:p1 devin ' "$TMP/herdr.log")"
  [[ "$devin_builder_run" == "pane run w:p1 devin --model $devin_builder_model --permission-mode dangerous --respect-workspace-trust false" ]] ||
    fail "$devin_builder_profile must reuse the worker variant's argv verbatim: $devin_builder_run"
  [[ " $devin_builder_run " != *' --effort '* ]] ||
    fail "$devin_builder_run run argv must not contain effort"
  [[ "$(tail -n 1 "$TMP/scopefuel.log")" == "$devin_builder_gate" ]] ||
    fail "$devin_builder_profile must gate as $devin_builder_gate (hk 1604), got: $(tail -n 1 "$TMP/scopefuel.log")"
  python3 - "$ARBITER_INBOX_ROOT/$devin_builder_profile-job/events/00001-job.claim.json" "$devin_builder_profile" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["owner_lane"] == "%s-lane" % sys.argv[2], event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
  expect_exit 2 spawn_base "$devin_builder_profile" --role builder --lane "$devin_builder_profile-lane" --parent parent-lane --effort high --job "$devin_builder_profile-effort-mutant"
  expect_exit 2 spawn_base "$devin_builder_profile" --job "$devin_builder_profile-role-mutant" --t T1
done
echo "PASS #666 devin builder variants reuse the worker argv and need --role builder"

# ---------------------------------------------------------------------------
# #704 (#594 E6) + #737 (decision 4088 grok rungs): per-rung builder spellings
# — the name's last segment IS the pinned rung. Each must launch the exact
# model argv at that effort, ask the gate about <gate profile>@<rung> (wrk
# forwards --effort to the gate for these profiles only), record
# launch_profile=<canonical>@<rung> (#677), and spawn only when
# SCOPEFUEL_E6_ARM names that exact rung. The fixture's escalation model
# still demands --operator-request on its marked rungs (sonnet@xhigh in
# both modes, opus@low in the default mode — see the #740 block below);
# the real installed gate skips the escalation ladder on --effort-named
# rungs (#716), so that demand is fixture-model behaviour, not installed
# behaviour. The kimi pair takes
# its rung from the pinned clone home (kimi has no --effort); the grok rungs
# are plain marker-gated (not escalation).
# Mutants: dropping GATE_EFFORT_PIN, the marker check, the clone-effort check,
# the canonical launch_name, or the gate's --effort forward turns this RED.
# ---------------------------------------------------------------------------

# The kimi rungs read their effort from clone homes (bin/kimi-clone-home
# --effort). Build both from the fixture source the kimi-k3-low block used;
# the clone script itself rejects an unknown effort spelling.
E6_KIMI_HIGH_HOME="$TMP/kimi-e6-high-home"
E6_KIMI_MAX_HOME="$TMP/kimi-e6-max-home"
env KIMI_CODE_SRC="$CLONE_SRC" KIMI_CODE_HIGH_HOME="$E6_KIMI_HIGH_HOME" \
  "$ROOT/bin/kimi-clone-home" --effort high >/dev/null
env KIMI_CODE_SRC="$CLONE_SRC" KIMI_CODE_MAX_HOME="$E6_KIMI_MAX_HOME" \
  "$ROOT/bin/kimi-clone-home" --effort max >/dev/null
grep -q 'effort = "high"' "$E6_KIMI_HIGH_HOME/config.toml" ||
  fail "kimi-clone-home --effort high must pin the clone to high"
grep -q 'effort = "max"' "$E6_KIMI_MAX_HOME/config.toml" ||
  fail "kimi-clone-home --effort max must pin the clone to max"
run_fail env KIMI_CODE_SRC="$CLONE_SRC" "$ROOT/bin/kimi-clone-home" --effort ultra
run_fail env KIMI_CODE_SRC="$CLONE_SRC" "$ROOT/bin/kimi-clone-home" --bogus-flag

# Own inbox: the measurement records stay out of the shared suite inbox.
E6_INBOX="$TMP/inbox-e6"
E6_XDG="$TMP/xdg-e6"

e6_builder_case() {
  local model="$1" gate="$2" rung="$3" argv_tail="$4"; shift 4
  local job="e6-${model}-job" out rc start
  : >"$TMP/herdr.log" "$TMP/scopefuel.log"
  set +e
  out="$(SCOPEFUEL_E6_ARM="$gate@$rung" \
    KIMI_CODE_HIGH_HOME="$E6_KIMI_HIGH_HOME" KIMI_CODE_MAX_HOME="$E6_KIMI_MAX_HOME" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base "$model" --role builder --lane "$model-lane" --parent parent-lane \
    --job "$job" --t T1 "$@" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || fail "$model must be admitted under --role builder (rc=$rc): $out"
  grep -q "model=$model" <<<"$out" || fail "$model spawn output lost its model: $out"
  start="$(grep '^agent start ' "$TMP/herdr.log")"
  # The exact argv tail pins model + effort — no silent default is possible:
  # for claude/codex the rung is in argv; for kimi it is the clone home.
  [[ "$start" == *" -- $argv_tail" ]] ||
    fail "$model must launch the exact $rung rung argv: $start"
  [[ "$(tail -n 1 "$TMP/scopefuel.log")" == "$gate" ]] ||
    fail "$model must gate as $gate: $(cat "$TMP/scopefuel.log")"
  grep -qF "gate -m $gate --effort $rung" "$TMP/scopefuel.log" ||
    fail "$model must ask the gate about the $rung rung: $(cat "$TMP/scopefuel.log")"
  if [[ "$model" == builder-kimi-* ]]; then
    local want_home
    case "$rung" in
      high) want_home="$E6_KIMI_HIGH_HOME" ;;
      max) want_home="$E6_KIMI_MAX_HOME" ;;
    esac
    grep -qF -- "--env KIMI_CODE_HOME=$want_home" "$TMP/herdr.log" ||
      fail "$model must pin KIMI_CODE_HOME to the $rung clone: $(cat "$TMP/herdr.log")"
  fi
  python3 - "$E6_INBOX/$job/events" "$gate@$rung" "$model" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
claim = next(e for e in events if e["kind"] == "job.claim")
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert claim["payload"]["role"] == "builder", claim
assert claim["payload"]["parent_lane"] == "parent-lane", claim
assert record["payload"]["launch_profile"] == sys.argv[2], (sys.argv[3], record)
PY
}

e6_builder_case builder-opus-low     opus        low    '--model opus --dangerously-skip-permissions --effort low'     --operator-request hk:task/704
e6_builder_case builder-opus-medium  opus        medium '--model opus --dangerously-skip-permissions --effort medium'
e6_builder_case builder-sonnet-xhigh sonnet      xhigh  '--model sonnet --dangerously-skip-permissions --effort xhigh' --operator-request hk:task/704
e6_builder_case builder-sol-high     codex-sol   high   '--yolo -m gpt-6.1-sol -c model_reasoning_effort=high'
# #737: codex-sol@medium joins the sol E6 rungs on the same pin rule.
e6_builder_case builder-sol-medium   codex-sol   medium '--yolo -m gpt-6.1-sol -c model_reasoning_effort=medium'
e6_builder_case builder-kimi-high    kimi-k3     high   '--auto -m kimi-code/k3'
# #737 (decision 4088): the grok E6 rungs — grok-hi@low/medium/xhigh, same
# generic grok argv shape as builder-grok, marker-gated at the pinned rung.
e6_builder_case builder-grok-low     grok-hi     low    '--always-approve -m grok-4.7 --effort low'
e6_builder_case builder-grok-medium  grok-hi     medium '--always-approve -m grok-4.7 --effort medium'
e6_builder_case builder-grok-xhigh   grok-hi     xhigh  '--always-approve -m grok-4.7 --effort xhigh'
# hk 1796: the four hk 1786 arms on the same pin rule. All four are placed
# canon rows — no --operator-request anywhere. The luna pair must gate at
# codex-luna@<rung> (NOT codex-luna-max) and take its model id from the
# catalog row: the fixture serves gpt-5.6-luna for codex-luna@low, so a
# launcher that hard-coded gpt-6-luna on the low spelling goes RED here.
e6_builder_case builder-sonnet-medium sonnet     medium '--model sonnet --dangerously-skip-permissions --effort medium'
e6_builder_case builder-haiku-low    haiku      low    '--model haiku --dangerously-skip-permissions --effort low'
e6_builder_case builder-luna-low     codex-luna low    '--yolo -m gpt-5.6-luna -c model_reasoning_effort=low'
e6_builder_case builder-luna-medium  codex-luna medium '--yolo -m gpt-6-luna -c model_reasoning_effort=medium'
# hk 2043: builder-luna-high is the luna family's high E6 rung — the same pin
# rule and marker as the low/medium pair (director-1, 2026-10-26, for the
# r1026luna L-A+ arm).
e6_builder_case builder-luna-high    codex-luna high   '--yolo -m gpt-6-luna -c model_reasoning_effort=high'
# hk 2043: builder-haiku-medium is the haiku family's medium E6 rung (the
# r1026effdown arm B haiku@high vs haiku@medium) on the same pin rule and
# marker as builder-haiku-low.
e6_builder_case builder-haiku-medium haiku      medium '--model haiku --dangerously-skip-permissions --effort medium'
# hk 1863: the five hk 1786 borrow-down and promote-up spellings on the same
# pin rule. builder-sol-low takes its model id from the codex-sol catalog row
# (the fixture serves gpt-6.1-sol) and gates at codex-sol@low; the haiku and
# sonnet spellings reuse the haiku and sonnet worker argv shape. builder-haiku-max
# is admitted at max in the max-rung block below (hk 1864). sonnet@low has no
# canon row in production — the fixture catalog answers it, so this case
# proves wrk's wiring, not that the real gate admits the rung today.
e6_builder_case builder-sol-low      codex-sol  low    '--yolo -m gpt-6.1-sol -c model_reasoning_effort=low'
e6_builder_case builder-haiku-high   haiku      high   '--model haiku --dangerously-skip-permissions --effort high'
e6_builder_case builder-haiku-xhigh  haiku      xhigh  '--model haiku --dangerously-skip-permissions --effort xhigh'
e6_builder_case builder-sonnet-low   sonnet     low    '--model sonnet --dangerously-skip-permissions --effort low'
# builder-sol-low must read its model id from the catalog row, never a launcher
# literal: serve an id that exists nowhere in bin/wrk and assert the argv
# carries it, and that the catalog consult asked for codex-sol at low.
: >"$TMP/herdr.log" "$TMP/scopefuel.log" "$TMP/launch.log"
sol_low_out="$(SCOPEFUEL_E6_ARM=codex-sol@low WRK_LAUNCH_LOG="$TMP/launch.log" \
  WRK_LAUNCH_MODEL_OVERRIDE=gpt-9.9-sol \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-sol-low --role builder --lane e6-sol-low-catalog-lane --parent parent-lane \
  --job e6-sol-low-catalog --t T1 2>&1)" ||
  fail "builder-sol-low with a catalog-served model id must be admitted: $sol_low_out"
[[ "$(grep '^agent start ' "$TMP/herdr.log")" == *' -- --yolo -m gpt-9.9-sol -c model_reasoning_effort=low' ]] ||
  fail "builder-sol-low must carry the catalog row's model id: $(cat "$TMP/herdr.log")"
grep -q 'policy launch codex-sol effort=low' "$TMP/launch.log" ||
  fail "builder-sol-low must consult the catalog for codex-sol at low: $(cat "$TMP/launch.log")"
echo "PASS 704+737+1796+1863 E6 builder rungs launch exact argv, gate at their rung, record canonical launch_profile"

# hk 1864 (operator 2026-10-23): the no-max builder-seat refusal of the
# 2026-09-26 decision 4088 B is repealed, so the max-rung builder spellings are
# admitted with their exact SCOPEFUEL_E6_ARM marker armed and launch at the max
# rung (the kimi one through the max clone home). builder-sol-max left this E6
# set in hk 2043 (normal pinned spelling — its own case below).
e6_builder_case builder-sonnet-max   sonnet     max    '--model sonnet --dangerously-skip-permissions --effort max'
e6_builder_case builder-luna-max     codex-luna max    '--yolo -m gpt-6-luna -c model_reasoning_effort=max'
e6_builder_case builder-kimi-max     kimi-k3    max    '--auto -m kimi-code/k3'
e6_builder_case builder-haiku-max    haiku      max    '--model haiku --dangerously-skip-permissions --effort max'
# hk 2043 (operator r1026solmax, revision 3): builder-sol-xhigh and
# builder-sol-max are NORMAL pinned spellings — the rung is pinned exactly like
# an E6 spelling (catalog and gate consult, model, default effort, different
# effort refusal) but spawn takes no SCOPEFUEL_E6_ARM marker. builder-sol-max
# is the S+ gate=default row, so it also takes no --operator-request;
# builder-sol-xhigh is an escalation rung, so the gate still demands a REF.
normal_pinned_spawn() {
  # The brief's case is "SCOPEFUEL_E6_ARM unset", not merely empty: a stale
  # ambient marker must not be read as an E6 arm.
  unset SCOPEFUEL_E6_ARM
  spawn_base "$@"
}
normal_pinned_case() {
  local model="$1" gate="$2" rung="$3" argv_tail="$4"; shift 4
  local job="np-${model}-job" out rc start
  : >"$TMP/herdr.log" "$TMP/scopefuel.log"
  set +e
  out="$(ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    normal_pinned_spawn "$model" --role builder --lane "$model-lane" --parent parent-lane \
    --job "$job" --t T1 "$@" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] ||
    fail "$model must be admitted with SCOPEFUEL_E6_ARM unset (rc=$rc): $out"
  start="$(grep '^agent start ' "$TMP/herdr.log")"
  [[ "$start" == *" -- $argv_tail" ]] ||
    fail "$model must launch the exact $rung rung argv: $start"
  grep -qF "gate -m $gate --effort $rung" "$TMP/scopefuel.log" ||
    fail "$model must ask the gate about the $rung rung: $(cat "$TMP/scopefuel.log")"
  python3 - "$E6_INBOX/$job/events" "$gate@$rung" "$model" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert record["payload"]["launch_profile"] == sys.argv[2], (sys.argv[3], record)
PY
}

normal_pinned_case builder-sol-xhigh codex-sol xhigh \
  '--yolo -m gpt-6.1-sol -c model_reasoning_effort=xhigh' --operator-request hk:task/2043
normal_pinned_case builder-sol-max codex-sol max \
  '--yolo -m gpt-6.1-sol -c model_reasoning_effort=max'

# hk 2043 item 6: the gate still decides admission. codex-sol@xhigh is an
# escalation rung at S+, so a bare spawn is refused by the gate (rc 3) and the
# same spawn with a valid operator REF is admitted (the case above).
: >"$TMP/herdr.log"
set +e
np_esc_out="$(normal_pinned_spawn builder-sol-xhigh --role builder --lane np-xhigh-esc-lane \
  --parent parent-lane --job np-xhigh-esc --t T1 2>&1)"
np_esc_rc=$?
set -e
[[ "$np_esc_rc" -eq 3 ]] ||
  fail "builder-sol-xhigh without --operator-request must hit the gate escalation refusal (rc=$np_esc_rc): $np_esc_out"
grep -q 'escalation' <<<"$np_esc_out" ||
  fail "builder-sol-xhigh refusal must be the gate's escalation denial: $np_esc_out"

# A stale marker (another rung of the same profile) must not gate or label a
# normal pinned spelling: the spawn is admitted and the record still reads
# codex-sol@max — never an E6 arm.
: >"$TMP/herdr.log" "$TMP/scopefuel.log"
np_stale_out="$(SCOPEFUEL_E6_ARM=codex-sol@high ARBITER_INBOX_ROOT="$E6_INBOX" \
  XDG_DATA_HOME="$E6_XDG" spawn_base builder-sol-max --role builder \
  --lane np-sol-max-stale-lane --parent parent-lane --job np-sol-max-stale --t T1 2>&1)" ||
  fail "a stale SCOPEFUEL_E6_ARM must not refuse builder-sol-max: $np_stale_out"
python3 - "$E6_INBOX/np-sol-max-stale/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert record["payload"]["launch_profile"] == "codex-sol@max", record
PY
echo "PASS hk 2043 normal pinned sol spellings take no marker, record their canon rung, and stay gate-decided"

# hk 2043 item 4: an unpinned builder spelling whose catalog consult is pinned
# to one rung refuses a different --effort instead of silently consulting the
# pin while launching another rung. The line names the matching pinned
# spelling when the family has one.
np_mismatch_case() {
  local model="$1" effort="$2" want="$3"
  local out rc
  set +e
  out="$(normal_pinned_spawn "$model" --role builder --lane "np-mm-$model-lane" \
    --parent parent-lane --job "np-mm-$model-$effort" --t T1 --effort "$effort" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 2 ]] ||
    fail "$model --effort $effort must die rc 2 (rc=$rc): $out"
  grep -qF "$want" <<<"$out" ||
    fail "$model --effort $effort refusal must name '$want': $out"
}
np_mismatch_case builder-sol xhigh 'use builder-sol-xhigh for --effort xhigh'
np_mismatch_case builder-sol max 'use builder-sol-max for --effort max'
np_mismatch_case builder-sol medium 'use builder-sol-medium for --effort medium'
np_mismatch_case builder-sol6 max 'use --effort high'
np_mismatch_case builder-grok low 'use builder-grok-low for --effort low'
# builder-sol --effort high is unchanged (no refusal, launches high).
: >"$TMP/herdr.log"
normal_pinned_spawn builder-sol --role builder --lane np-sol-high-lane \
  --parent parent-lane --job np-sol-high --t T1 --effort high >/dev/null
[[ "$(grep '^agent start ' "$TMP/herdr.log")" == *' -- --yolo -m gpt-6.1-sol -c model_reasoning_effort=high' ]] ||
  fail "builder-sol --effort high must still launch the high rung: $(cat "$TMP/herdr.log")"
echo "PASS hk 2043 unpinned builder spellings refuse an off-consult effort and name the pinned spelling"

# Mutants, each applied at the real call site (bin/wrk source), never to the
# repository file. Every mutant must turn its probe RED.
np_probe() {  # $1=wrk path, $2=tag, $3=model; extra spawn flags after
  local wrk="$1" tag="$2" model="$3"; shift 3
  WRK="$wrk" ARBITER_INBOX_ROOT="$TMP/npm-inbox-$tag" XDG_DATA_HOME="$TMP/npm-xdg-$tag" \
    normal_pinned_spawn "$model" --role builder --lane "npm-$tag-lane" \
    --parent parent-lane --job "npm-$tag" --t T1 "$@" >/dev/null 2>&1 || return 1
}
np_marker_required_probe() {  # 0 iff the no-marker spawn is refused
  local wrk="$1" tag="$2" model="$3"
  ! WRK="$wrk" ARBITER_INBOX_ROOT="$TMP/npm-inbox-$tag" XDG_DATA_HOME="$TMP/npm-xdg-$tag" \
    normal_pinned_spawn "$model" --role builder --lane "npm-$tag-lane" \
    --parent parent-lane --job "npm-$tag" --t T1 >/dev/null 2>&1
}
np_consult_probe() {  # 0 iff builder-sol-xhigh's catalog consult asks xhigh
  local wrk="$1" tag="$2"
  : >"$TMP/launch.log"
  WRK="$wrk" WRK_LAUNCH_LOG="$TMP/launch.log" ARBITER_INBOX_ROOT="$TMP/npm-inbox-$tag" \
    XDG_DATA_HOME="$TMP/npm-xdg-$tag" normal_pinned_spawn builder-sol-xhigh \
    --role builder --lane "npm-$tag-lane" --parent parent-lane --job "npm-$tag" \
    --t T1 --operator-request hk:task/2043 >/dev/null 2>&1 || return 1
  grep -q 'policy launch codex-sol effort=xhigh' "$TMP/launch.log"
}
np_mismatch_probe() {  # 0 iff builder-sol --effort xhigh is refused
  local wrk="$1" tag="$2"
  ! WRK="$wrk" ARBITER_INBOX_ROOT="$TMP/npm-inbox-$tag" XDG_DATA_HOME="$TMP/npm-xdg-$tag" \
    normal_pinned_spawn builder-sol --role builder --lane "npm-$tag-lane" \
    --parent parent-lane --job "npm-$tag" --t T1 --effort xhigh >/dev/null 2>&1
}
np_probe "$WRK" real-solmax builder-sol-max ||
  fail "builder-sol-max probe must be admitted on the real wrk"
np_marker_required_probe "$WRK" real-haikumax builder-haiku-max ||
  fail "builder-haiku-max probe must be refused without a marker on the real wrk"
np_consult_probe "$WRK" real-consult ||
  fail "builder-sol-xhigh probe must consult codex-sol@xhigh on the real wrk"
np_mismatch_probe "$WRK" real-mismatch ||
  fail "builder-sol --effort xhigh probe must be refused on the real wrk"
# Invariant: requiring the marker for builder-sol-max turns the no-marker case
# RED.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
mut_wrk "$TMP/wrk-np-marker-required" \
  'if ! normal_pinned_builder "$MODEL"; then' 'if true; then'
expect_red "normal-pinned-marker-required" np_probe "$TMP/wrk-np-marker-required" mut-solmax builder-sol-max
# Invariant: exempting every pinned spelling from the marker turns the
# builder-haiku-max marker case RED.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
mut_wrk "$TMP/wrk-np-marker-exempt-all" \
  'if ! normal_pinned_builder "$MODEL"; then' 'if false; then'
expect_red "normal-pinned-marker-exempt-all" np_marker_required_probe \
  "$TMP/wrk-np-marker-exempt-all" mut-haikumax builder-haiku-max
# Invariant: mapping builder-sol-xhigh's catalog consult to high turns the
# consult case RED.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
mut_wrk "$TMP/wrk-np-consult-high" \
  '    builder-sol-high|builder-sol-xhigh|builder-sol-max|builder-sol-medium|builder-sol-low) CATALOG_PROFILE=codex-sol; CATALOG_EFFORT_PIN="${MODEL##*-}" ;;' \
  '    builder-sol-xhigh) CATALOG_PROFILE=codex-sol; CATALOG_EFFORT_PIN=high ;;
    builder-sol-high|builder-sol-max|builder-sol-medium|builder-sol-low) CATALOG_PROFILE=codex-sol; CATALOG_EFFORT_PIN="${MODEL##*-}" ;;'
expect_red "normal-pinned-consult-high" np_consult_probe "$TMP/wrk-np-consult-high" mut-consult
# Invariant: dropping the unpinned-mismatch refusal turns the builder-sol
# --effort xhigh case RED.
mut_wrk "$TMP/wrk-np-mismatch-dropped" \
  '      builder-sol|captain-sol)' '      captain-sol)'
expect_red "normal-pinned-mismatch-dropped" np_mismatch_probe \
  "$TMP/wrk-np-mismatch-dropped" mut-mismatch
echo "PASS hk 2043 normal-pinned and unpinned-mismatch mutants go RED"

# codex `ultra` is the max tier plus subagents — hk 1864 opened max only, so
# the seat rule still refuses ultra.
set +e
e6_max_out="$(spawn_base builder-sol --role builder --lane e6-effort-ultra-lane --parent parent-lane \
  --effort ultra --job e6-builder-sol-effort-ultra --t T1 2>&1)"
e6_max_rc=$?
set -e
[[ "$e6_max_rc" -eq 2 ]] ||
  fail "builder-sol --effort ultra must die rc 2 (rc=$e6_max_rc): $e6_max_out"
grep -q 'builder seats never take an ultra rung' <<<"$e6_max_out" ||
  fail "builder-sol --effort ultra refusal must name the builder-seat rule: $e6_max_out"
# Mutant: restoring the repealed max refusal must fail the admitted-max probe.
# The probe spawns builder-haiku-max with its exact marker; it must pass on the
# real wrk and go RED (rc 1) on a copy whose seat rule refuses max again.
builder_max_open_probe() {
  local wrk="$1" tag="$2"
  SCOPEFUEL_E6_ARM=haiku@max WRK="$wrk" \
    ARBITER_INBOX_ROOT="$TMP/mut-inbox-$tag" XDG_DATA_HOME="$TMP/mut-xdg-$tag" \
    spawn_base builder-haiku-max --role builder --lane "mutm-$tag-lane" \
    --parent parent-lane --job "mutm-$tag" --t T1 >/dev/null 2>&1 || return 1
}
builder_max_open_probe "$WRK" real ||
  fail "builder-haiku-max probe must be admitted on the real wrk"
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
mut_wrk "$TMP/wrk-max-refusal-restored" \
  '    case "$seat_effort" in
      ultra)' \
  '    case "$seat_effort" in
      max|ultra)'
expect_red "max-refusal-restored" builder_max_open_probe "$TMP/wrk-max-refusal-restored" restored
echo "PASS hk 1864 max-rung builder spellings admitted on the builder seat, ultra still refused, restored refusal goes RED"

# #748 / hk 1864: the unflagged kimi spellings admitted as builders
# (builder-kimi, kimi-k3) leave EFFECTIVE_EFFORT empty — the seat rule reads
# the home's [thinking] effort instead. Since hk 1864 a home pinned to max is
# admitted like any other rung (max is open on the builder seat); the seat rule
# keeps refusing an ultra-effort home, asserted in the blocks below with
# hand-built homes (bin/kimi-clone-home itself cannot mint an ultra clone).
for e6_kimi_builder in builder-kimi kimi-k3; do
  : >"$TMP/herdr.log"
  set +e
  e6_kmax_out="$(KIMI_CODE_HOME="$E6_KIMI_MAX_HOME" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base "$e6_kimi_builder" --role builder --lane "kmax-$e6_kimi_builder-lane" --parent parent-lane \
    --job "e6-khome-max-$e6_kimi_builder" --t T1 2>&1)"
  e6_kmax_rc=$?
  set -e
  [[ "$e6_kmax_rc" -eq 0 ]] ||
    fail "$e6_kimi_builder on a max-effort kimi home must be admitted (rc=$e6_kmax_rc): $e6_kmax_out"
  [[ "$(grep '^agent start ' "$TMP/herdr.log")" == *' -- --auto -m kimi-code/k3' ]] ||
    fail "$e6_kimi_builder on a max home must reuse the kimi-k3 argv verbatim: $(cat "$TMP/herdr.log")"
done
# A high-effort kimi home stays admitted — same argv as before, no --effort
# anywhere (the CLI has no flag; the rung lives only in the clone config).
: >"$TMP/herdr.log"
set +e
e6_khigh_out="$(KIMI_CODE_HOME="$E6_KIMI_HIGH_HOME" \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane khigh-builder-kimi-lane --parent parent-lane \
  --job e6-khome-high-builder-kimi --t T1 2>&1)"
e6_khigh_rc=$?
set -e
[[ "$e6_khigh_rc" -eq 0 ]] ||
  fail "builder-kimi on a high-effort kimi home must be admitted (rc=$e6_khigh_rc): $e6_khigh_out"
e6_khigh_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$e6_khigh_start" == *' -- --auto -m kimi-code/k3' ]] ||
  fail "builder-kimi on a high home must reuse the kimi-k3 argv verbatim: $e6_khigh_start"
# The seat rule stays builder-scoped: the max home on a worker spawn is
# unaffected (worker max rungs are a separate reservation, not this rule).
set +e
e6_kworker_out="$(KIMI_CODE_HOME="$E6_KIMI_MAX_HOME" \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base kimi-k3 --job e6-khome-max-worker --t T1 2>&1)"
e6_kworker_rc=$?
set -e
[[ "$e6_kworker_rc" -eq 0 ]] ||
  fail "kimi-k3 worker on a max-effort home must stay admitted (rc=$e6_kworker_rc): $e6_kworker_out"
echo "PASS 748 kimi builder spellings admit a max-effort home (hk 1864)"

# #748r2 (tester round 1): the seat read must resolve what Kimi Code actually
# runs, not just a double-quoted [thinking] effort. Valid TOML literal
# (single-quoted) strings, a missing [thinking] with the spawned model's
# default_effort = "ultra", and an unsupported [thinking] value falling back to
# an ultra default all resolve to ultra — each must die on the seat rule. Mutants
# in test-assignment-defaults.sh pin the resolver itself.
e6_khome() { # build a minimal kimi home: $1=dest, config.toml on stdin
  local dest="$1"
  mkdir -p "$dest/credentials" "$dest/oauth"
  cat >"$dest/config.toml"
  printf 'x\n' >"$dest/credentials/kimi-code.json"
  printf 'x\n' >"$dest/oauth/kimi-code"
  printf 'x\n' >"$dest/device_id"
}
e6_khome "$TMP/kimi-sq-ultra" <<'EOF'
[models."kimi-code/k3"]
provider = "managed:kimi-code"
support_efforts = [ "low", "high", "ultra" ]
default_effort = "high"
[thinking]
effort = 'ultra'
EOF
e6_khome "$TMP/kimi-default-ultra" <<'EOF'
default_model = "kimi-code/k3"
[models."kimi-code/k3"]
provider = "managed:kimi-code"
support_efforts = [ "low", "high", "ultra" ]
default_effort = "ultra"
EOF
e6_khome "$TMP/kimi-fallback-ultra" <<'EOF'
[models."kimi-code/k3"]
provider = "managed:kimi-code"
support_efforts = [ "low", "high", "ultra" ]
default_effort = "ultra"
[thinking]
effort = "xhigh"
EOF
for e6_khome_case in kimi-sq-ultra kimi-default-ultra kimi-fallback-ultra; do
  set +e
  e6_kout="$(KIMI_CODE_HOME="$TMP/$e6_khome_case" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base builder-kimi --role builder --lane "$e6_khome_case-lane" --parent parent-lane \
    --job "e6-$e6_khome_case" --t T1 2>&1)"
  e6_krc=$?
  set -e
  [[ "$e6_krc" -eq 2 ]] ||
    fail "builder-kimi on a home resolving to ultra ($e6_khome_case) must die rc 2 (rc=$e6_krc): $e6_kout"
  grep -q 'builder seats never take an ultra rung' <<<"$e6_kout" ||
    fail "$e6_khome_case refusal must name the builder-seat rule: $e6_kout"
done
# The same fallback semantics admit when they resolve below ultra: a
# single-quoted 'high' is a valid TOML rung, and an unsupported 'xhigh'
# request falls back to the model's high default — both launch normally.
e6_khome "$TMP/kimi-sq-high" <<'EOF'
[models."kimi-code/k3"]
provider = "managed:kimi-code"
support_efforts = [ "low", "high", "ultra" ]
default_effort = "high"
[thinking]
effort = 'high'
EOF
e6_khome "$TMP/kimi-fallback-high" <<'EOF'
[models."kimi-code/k3"]
provider = "managed:kimi-code"
support_efforts = [ "low", "high", "ultra" ]
default_effort = "high"
[thinking]
effort = "xhigh"
EOF
for e6_khome_case in kimi-sq-high kimi-fallback-high; do
  : >"$TMP/herdr.log"
  set +e
  e6_kout="$(KIMI_CODE_HOME="$TMP/$e6_khome_case" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base builder-kimi --role builder --lane "$e6_khome_case-lane" --parent parent-lane \
    --job "e6-$e6_khome_case" --t T1 2>&1)"
  e6_krc=$?
  set -e
  [[ "$e6_krc" -eq 0 ]] ||
    fail "builder-kimi on a home resolving below ultra ($e6_khome_case) must be admitted (rc=$e6_krc): $e6_kout"
  [[ "$(grep '^agent start ' "$TMP/herdr.log")" == *' -- --auto -m kimi-code/k3' ]] ||
    fail "$e6_khome_case must launch the unchanged kimi-k3 argv: $(cat "$TMP/herdr.log")"
done
echo "PASS 748r2 kimi seat rule resolves literal strings and model default_effort fallbacks"

# #748r3 (tester round 2): the resolution must be a real TOML parse — dotted
# keys, inline tables, multiline/escaped strings, indented headers,
# [models."<id>".overrides] entries and comments inside arrays are all
# equivalent spellings Kimi accepts; and KIMI_MODEL_THINKING_EFFORT overrides
# the effort at runtime. [thinking].enabled=false resolves to off_effort.
e6_khome "$TMP/kimi-dotted-thinking" <<'EOF'
thinking.effort = "ultra"
[models."kimi-code/k3"]
provider = "x"
support_efforts = [ "low", "high", "ultra" ]
default_effort = "high"
EOF
e6_khome "$TMP/kimi-dotted-model" <<'EOF'
models."kimi-code/k3".provider = "x"
models."kimi-code/k3".support_efforts = [ "low", "high", "ultra" ]
models."kimi-code/k3".default_effort = "ultra"
EOF
e6_khome "$TMP/kimi-inline-models" <<'EOF'
models = { "kimi-code/k3" = { support_efforts = [ "low", "high", "ultra" ], default_effort = "ultra" } }
EOF
e6_khome "$TMP/kimi-multiline-ultra" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "ultra" ]
default_effort = "high"
[thinking]
effort = """ultra"""
EOF
# The effort value below is the TOML escape m + ́x: the file literally
# contains "ultr\u0061", which a real TOML decode turns into "ultra".
e6_khome "$TMP/kimi-escaped-ultra" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "ultra" ]
default_effort = "high"
[thinking]
effort = "ultr\u0061"
EOF
e6_khome "$TMP/kimi-indented-ultra" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "ultra" ]
default_effort = "high"
  [thinking]
  effort = "ultra"
EOF
e6_khome "$TMP/kimi-override-ultra" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "ultra" ]
default_effort = "high"
[models."kimi-code/k3".overrides]
default_effort = "ultra"
EOF
e6_khome "$TMP/kimi-comment-support" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "ultra" ] # "xhigh" intentionally unsupported
default_effort = "ultra"
[thinking]
effort = "xhigh"
EOF
e6_khome "$TMP/kimi-off-effort-ultra" <<'EOF'
[models."kimi-code/k3"]
off_effort = "ultra"
[thinking]
enabled = false
effort = "high"
EOF
# always-thinking also arrives as a capabilities tag or a boolean field —
# enabled=false does not switch the model off in either shape.
e6_khome "$TMP/kimi-at-cap-ultra" <<'EOF'
[models."kimi-code/k3"]
capabilities = [ "thinking", "always_thinking" ]
default_effort = "high"
[thinking]
enabled = false
effort = "ultra"
EOF
e6_khome "$TMP/kimi-at-field-ultra" <<'EOF'
[models."kimi-code/k3"]
always_thinking = true
default_effort = "high"
[thinking]
enabled = false
effort = "ultra"
EOF
# A malformed config (duplicate keys) can still carry an ultra line: the python
# parse refuses to decode it, so the awk fallback's scan must stay
# conservative and refuse.
e6_khome "$TMP/kimi-dup-invalid" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "ultra" ]
default_effort = "high"
[thinking]
effort = "high"
effort = "ultra"
EOF
for e6_khome_case in kimi-dotted-thinking kimi-dotted-model kimi-inline-models \
    kimi-multiline-ultra kimi-escaped-ultra kimi-indented-ultra kimi-override-ultra \
    kimi-comment-support kimi-off-effort-ultra kimi-at-cap-ultra kimi-at-field-ultra \
    kimi-dup-invalid; do
  set +e
  e6_kout="$(KIMI_CODE_HOME="$TMP/$e6_khome_case" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base builder-kimi --role builder --lane "$e6_khome_case-lane" --parent parent-lane \
    --job "e6-$e6_khome_case" --t T1 2>&1)"
  e6_krc=$?
  set -e
  [[ "$e6_krc" -eq 2 ]] ||
    fail "builder-kimi on a home resolving to ultra ($e6_khome_case) must die rc 2 (rc=$e6_krc): $e6_kout"
  grep -q 'builder seats never take an ultra rung' <<<"$e6_kout" ||
    fail "$e6_khome_case refusal must name the builder-seat rule: $e6_kout"
done
# The env overlay is the rung when exported — even with a below-ultra home.
e6_khome "$TMP/kimi-env-below" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "ultra" ]
default_effort = "high"
[thinking]
effort = "high"
EOF
set +e
e6_kout="$(KIMI_CODE_HOME="$TMP/kimi-env-below" KIMI_MODEL_THINKING_EFFORT=ULTRA \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane kimi-env-ultra-lane --parent parent-lane \
  --job e6-kimi-env-ultra --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 2 ]] ||
  fail "builder-kimi with KIMI_MODEL_THINKING_EFFORT=ULTRA exported must die rc 2 (rc=$e6_krc): $e6_kout"
grep -q 'builder seats never take an ultra rung' <<<"$e6_kout" ||
  fail "env-ultra refusal must name the builder-seat rule: $e6_kout"
# CodeRabbit #153: the env overlay resolves even with no config file (kimi
# applies it with an empty home too) — and must normalize like the real parse
# or ULTRA bypasses the case-sensitive seat match on spelling alone.
mkdir -p "$TMP/kimi-no-cfg"
set +e
e6_kout="$(KIMI_CODE_HOME="$TMP/kimi-no-cfg" KIMI_MODEL_THINKING_EFFORT=ULTRA \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane kimi-nocfg-ultra-lane --parent parent-lane \
  --job e6-kimi-nocfg-ultra --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 2 ]] ||
  fail "builder-kimi with KIMI_MODEL_THINKING_EFFORT=ULTRA and no config must die rc 2 (rc=$e6_krc): $e6_kout"
grep -q 'builder seats never take an ultra rung' <<<"$e6_kout" ||
  fail "no-config env-ultra refusal must name the builder-seat rule: $e6_kout"
# An env spelling outside the documented rungs is not a rung — fail-open like
# an unparseable config, but only after the bounded check sees it.
: >"$TMP/herdr.log"
set +e
e6_kout="$(KIMI_CODE_HOME="$TMP/kimi-no-cfg" KIMI_MODEL_THINKING_EFFORT=banana \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane kimi-nocfg-bogus-lane --parent parent-lane \
  --job e6-kimi-nocfg-bogus --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 0 ]] ||
  fail "builder-kimi with an undocumented env effort and no config must be admitted (rc=$e6_krc): $e6_kout"
[[ "$(grep '^agent start ' "$TMP/herdr.log")" == *' -- --auto -m kimi-code/k3' ]] ||
  fail "bogus-env admission must launch the unchanged kimi-k3 argv: $(cat "$TMP/herdr.log")"
# The pinned rung must come from a real clone file, not the env overlay: a
# missing clone config fails closed even when the env names the pinned rung.
set +e
e6_kout="$(SCOPEFUEL_E6_ARM=kimi-k3@high KIMI_CODE_HIGH_HOME="$TMP/kimi-no-cfg" \
  KIMI_MODEL_THINKING_EFFORT=high \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi-high --role builder --lane kimi-nocfg-pin-lane --parent parent-lane \
  --job e6-kimi-nocfg-pin --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 2 ]] ||
  fail "builder-kimi-high on a missing clone must die rc 2 even with the pinned rung in env (rc=$e6_krc): $e6_kout"
grep -q 'config.toml missing' <<<"$e6_kout" ||
  fail "missing-clone refusal must name the missing config: $e6_kout"
# The awk fallback (no importable TOML lib) must resolve a quoted-key
# [models."<id>".overrides] header the same way the real parse does — strip
# only the .overrides suffix, never the closing quote.
mkdir -p "$TMP/nopy3bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/nopy3bin/python3"
chmod +x "$TMP/nopy3bin/python3"
e6_khome "$TMP/kimi-awk-override" <<'EOF'
[models."kimi-code/k3".overrides]
default_effort = "ultra"
EOF
set +e
e6_kout="$(PATH="$TMP/nopy3bin:$PATH" KIMI_CODE_HOME="$TMP/kimi-awk-override" \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane kimi-awk-over-lane --parent parent-lane \
  --job e6-kimi-awk-override --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 2 ]] ||
  fail "builder-kimi on an overrides-default ultra home must die rc 2 via the awk fallback too (rc=$e6_krc): $e6_kout"
grep -q 'builder seats never take an ultra rung' <<<"$e6_kout" ||
  fail "awk-path overrides-ultra refusal must name the builder-seat rule: $e6_kout"
# Admitted paths: the env overlay wins over the config (ultra home + high env),
# and disabled Thinking resolves to off_effort (absent → no rung) even when a
# configured effort or default is ultra.
e6_khome "$TMP/kimi-env-over-ultra" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "ultra" ]
default_effort = "ultra"
[thinking]
effort = "ultra"
EOF
e6_khome "$TMP/kimi-disabled-ultra" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "ultra" ]
default_effort = "high"
[thinking]
enabled = false
effort = "ultra"
EOF
e6_khome "$TMP/kimi-disabled-defultra" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "ultra" ]
default_effort = "ultra"
[thinking]
enabled = false
EOF
# effort="off" is a valid off spelling — no rung even with an ultra default;
# an unrecognised env value is not a rung either and falls back to config.
e6_khome "$TMP/kimi-effort-off" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "ultra" ]
default_effort = "ultra"
[thinking]
effort = "off"
EOF
: >"$TMP/herdr.log"
set +e
e6_kout="$(KIMI_CODE_HOME="$TMP/kimi-env-over-ultra" KIMI_MODEL_THINKING_EFFORT=high \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane kimi-env-high-lane --parent parent-lane \
  --job e6-kimi-env-high --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 0 ]] ||
  fail "KIMI_MODEL_THINKING_EFFORT=high must override an ultra home and be admitted (rc=$e6_krc): $e6_kout"
[[ "$(grep '^agent start ' "$TMP/herdr.log")" == *' -- --auto -m kimi-code/k3' ]] ||
  fail "env-high admission must launch the unchanged kimi-k3 argv: $(cat "$TMP/herdr.log")"
for e6_khome_case in kimi-disabled-ultra kimi-disabled-defultra kimi-effort-off; do
  : >"$TMP/herdr.log"
  set +e
  e6_kout="$(KIMI_CODE_HOME="$TMP/$e6_khome_case" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base builder-kimi --role builder --lane "$e6_khome_case-lane" --parent parent-lane \
    --job "e6-$e6_khome_case" --t T1 2>&1)"
  e6_krc=$?
  set -e
  [[ "$e6_krc" -eq 0 ]] ||
    fail "builder-kimi with Thinking disabled ($e6_khome_case) must be admitted (rc=$e6_krc): $e6_kout"
  [[ "$(grep '^agent start ' "$TMP/herdr.log")" == *' -- --auto -m kimi-code/k3' ]] ||
    fail "$e6_khome_case must launch the unchanged kimi-k3 argv: $(cat "$TMP/herdr.log")"
done
echo "PASS 748r3 kimi seat rule resolves real TOML, env overlay, and disabled Thinking"

# Marker mutants: no marker, and a marker naming a different rung, both die on
# wrk's own guard (rc 2, before the gate is asked) — the installed gate then
# fail-closes the unmeasured C rungs a second time for good measure.
# hk 1864: the max-rung spellings are in the loop too — the builder-seat rule
# no longer refuses them, so a missing marker is the operative refusal.
for e6_model in builder-opus-low builder-opus-medium builder-sonnet-xhigh \
  builder-sol-high builder-sol-medium \
  builder-kimi-high builder-grok-low builder-grok-medium builder-grok-xhigh \
  builder-sonnet-medium builder-haiku-low builder-luna-low builder-luna-high builder-luna-medium \
  builder-sol-low builder-haiku-medium builder-haiku-high builder-haiku-xhigh builder-sonnet-low \
  builder-sonnet-max builder-luna-max builder-kimi-max builder-haiku-max; do
  set +e
  e6_missing_out="$(SCOPEFUEL_E6_ARM='' \
    KIMI_CODE_HIGH_HOME="$E6_KIMI_HIGH_HOME" KIMI_CODE_MAX_HOME="$E6_KIMI_MAX_HOME" \
    spawn_base "$e6_model" --role builder --lane "$e6_model-lane" --parent parent-lane \
    --job "e6-nomarker-$e6_model" --t T1 2>&1)"
  e6_missing_rc=$?
  set -e
  [[ "$e6_missing_rc" -eq 2 ]] ||
    fail "$e6_model without SCOPEFUEL_E6_ARM must die rc 2 (rc=$e6_missing_rc): $e6_missing_out"
  grep -q 'E6 measurement profile' <<<"$e6_missing_out" ||
    fail "$e6_model missing-marker refusal must name the marker: $e6_missing_out"
done
set +e
e6_wrong_out="$(SCOPEFUEL_E6_ARM=kimi-k3@high \
  spawn_base builder-sonnet-xhigh --role builder --lane e6-wrong-lane --parent parent-lane \
  --job e6-wrong-marker --t T1 2>&1)"
e6_wrong_rc=$?
set -e
[[ "$e6_wrong_rc" -eq 2 ]] ||
  fail "builder-sonnet-xhigh with a mismatched marker must die rc 2 (rc=$e6_wrong_rc): $e6_wrong_out"
grep -q 'SCOPEFUEL_E6_ARM=sonnet@xhigh' <<<"$e6_wrong_out" ||
  fail "wrong-marker refusal must name the required marker: $e6_wrong_out"
# A correct marker for a different rung of the same gate profile also refuses.
set +e
e6_rung_out="$(SCOPEFUEL_E6_ARM=kimi-k3@max KIMI_CODE_HIGH_HOME="$E6_KIMI_HIGH_HOME" \
  spawn_base builder-kimi-high --role builder --lane e6-wrong-rung-lane --parent parent-lane \
  --job e6-wrong-rung --t T1 2>&1)"
e6_rung_rc=$?
set -e
[[ "$e6_rung_rc" -eq 2 ]] ||
  fail "builder-kimi-high with a same-profile wrong-rung marker must die rc 2 (rc=$e6_rung_rc): $e6_rung_out"
# #737: same-profile wrong-rung marker on a grok rung refuses too — a
# grok-hi@medium arm does not open builder-grok-low's grok-hi@low rung.
set +e
e6_rung_out="$(SCOPEFUEL_E6_ARM=grok-hi@medium \
  spawn_base builder-grok-low --role builder --lane e6-grok-wrong-rung-lane --parent parent-lane \
  --job e6-grok-wrong-rung --t T1 2>&1)"
e6_rung_rc=$?
set -e
[[ "$e6_rung_rc" -eq 2 ]] ||
  fail "builder-grok-low with a same-profile wrong-rung marker must die rc 2 (rc=$e6_rung_rc): $e6_rung_out"
grep -q 'SCOPEFUEL_E6_ARM=grok-hi@low' <<<"$e6_rung_out" ||
  fail "wrong-rung refusal must name the required marker: $e6_rung_out"
# #737 sol rung: the existing codex-sol@high marker must not open
# builder-sol-medium's codex-sol@medium rung.
set +e
e6_rung_out="$(SCOPEFUEL_E6_ARM=codex-sol@high \
  spawn_base builder-sol-medium --role builder --lane e6-sol-wrong-rung-lane --parent parent-lane \
  --job e6-sol-wrong-rung --t T1 2>&1)"
e6_rung_rc=$?
set -e
[[ "$e6_rung_rc" -eq 2 ]] ||
  fail "builder-sol-medium with a same-profile wrong-rung marker must die rc 2 (rc=$e6_rung_rc): $e6_rung_out"
grep -q 'SCOPEFUEL_E6_ARM=codex-sol@medium' <<<"$e6_rung_out" ||
  fail "wrong-rung refusal must name the required marker: $e6_rung_out"
# hk 1796: same-profile wrong-rung markers refuse on each of the four new
# spellings too — a marker for a different rung of the same gate profile
# does not open the pinned rung.
set +e
e6_rung_out="$(SCOPEFUEL_E6_ARM=sonnet@xhigh \
  spawn_base builder-sonnet-medium --role builder --lane e6-smed-wrong-rung-lane --parent parent-lane \
  --job e6-smed-wrong-rung --t T1 2>&1)"
e6_rung_rc=$?
set -e
[[ "$e6_rung_rc" -eq 2 ]] ||
  fail "builder-sonnet-medium with a same-profile wrong-rung marker must die rc 2 (rc=$e6_rung_rc): $e6_rung_out"
grep -q 'SCOPEFUEL_E6_ARM=sonnet@medium' <<<"$e6_rung_out" ||
  fail "wrong-rung refusal must name the required marker: $e6_rung_out"
set +e
e6_rung_out="$(SCOPEFUEL_E6_ARM=haiku@medium \
  spawn_base builder-haiku-low --role builder --lane e6-hkw-wrong-rung-lane --parent parent-lane \
  --job e6-hkw-wrong-rung --t T1 2>&1)"
e6_rung_rc=$?
set -e
[[ "$e6_rung_rc" -eq 2 ]] ||
  fail "builder-haiku-low with a same-profile wrong-rung marker must die rc 2 (rc=$e6_rung_rc): $e6_rung_out"
grep -q 'SCOPEFUEL_E6_ARM=haiku@low' <<<"$e6_rung_out" ||
  fail "wrong-rung refusal must name the required marker: $e6_rung_out"
set +e
e6_rung_out="$(SCOPEFUEL_E6_ARM=codex-luna@medium \
  spawn_base builder-luna-low --role builder --lane e6-llow-wrong-rung-lane --parent parent-lane \
  --job e6-llow-wrong-rung --t T1 2>&1)"
e6_rung_rc=$?
set -e
[[ "$e6_rung_rc" -eq 2 ]] ||
  fail "builder-luna-low with a same-profile wrong-rung marker must die rc 2 (rc=$e6_rung_rc): $e6_rung_out"
grep -q 'SCOPEFUEL_E6_ARM=codex-luna@low' <<<"$e6_rung_out" ||
  fail "wrong-rung refusal must name the required marker: $e6_rung_out"
set +e
e6_rung_out="$(SCOPEFUEL_E6_ARM=codex-luna@low \
  spawn_base builder-luna-medium --role builder --lane e6-lmed-wrong-rung-lane --parent parent-lane \
  --job e6-lmed-wrong-rung --t T1 2>&1)"
e6_rung_rc=$?
set -e
[[ "$e6_rung_rc" -eq 2 ]] ||
  fail "builder-luna-medium with a same-profile wrong-rung marker must die rc 2 (rc=$e6_rung_rc): $e6_rung_out"
grep -q 'SCOPEFUEL_E6_ARM=codex-luna@medium' <<<"$e6_rung_out" ||
  fail "wrong-rung refusal must name the required marker: $e6_rung_out"
# hk 1863: a marker for the wrong rung of the same profile refuses on each of
# the open new spellings and the max rungs hk 1864 opened.
for e6_wr in builder-sol-low:codex-sol@high:codex-sol@low \
  builder-haiku-high:haiku@low:haiku@high builder-haiku-xhigh:haiku@high:haiku@xhigh \
  builder-sonnet-low:sonnet@medium:sonnet@low \
  builder-haiku-max:haiku@xhigh:haiku@max builder-luna-high:codex-luna@medium:codex-luna@high \
  builder-haiku-medium:haiku@high:haiku@medium \
  builder-sonnet-max:sonnet@xhigh:sonnet@max builder-luna-max:codex-luna@medium:codex-luna@max; do
  IFS=: read -r e6_wr_model e6_wr_marker e6_wr_want <<<"$e6_wr"
  set +e
  e6_rung_out="$(SCOPEFUEL_E6_ARM="$e6_wr_marker" \
    spawn_base "$e6_wr_model" --role builder --lane "$e6_wr_model-wr-lane" --parent parent-lane \
    --job "$e6_wr_model-wr" --t T1 2>&1)"
  e6_rung_rc=$?
  set -e
  [[ "$e6_rung_rc" -eq 2 ]] ||
    fail "$e6_wr_model with a same-profile wrong-rung marker must die rc 2 (rc=$e6_rung_rc): $e6_rung_out"
  grep -q "SCOPEFUEL_E6_ARM=$e6_wr_want" <<<"$e6_rung_out" ||
    fail "$e6_wr_model wrong-rung refusal must name the required marker: $e6_rung_out"
done
echo "PASS 704+737+1796+1863 E6 marker mutants refuse missing and mismatched SCOPEFUEL_E6_ARM"

# Escalation rung (fixture default escalation model — strict; NOT the
# installed gate, whose #716 rule skips the ladder for --effort rungs): the
# marker alone does not open opus@low — the model gate demands
# --operator-request, and its rc 3 propagates.
set +e
e6_esc_out="$(SCOPEFUEL_E6_ARM=opus@low \
  spawn_base builder-opus-low --role builder --lane e6-esc-lane --parent parent-lane \
  --job e6-esc-noopreq --t T1 2>&1)"
e6_esc_rc=$?
set -e
[[ "$e6_esc_rc" -eq 3 ]] ||
  fail "opus@low without --operator-request must hit the gate escalation refusal (rc=$e6_esc_rc): $e6_esc_out"
grep -q 'escalation' <<<"$e6_esc_out" ||
  fail "opus@low refusal must be the escalation denial: $e6_esc_out"
echo "PASS 704 E6 escalation rung still requires --operator-request (fixture escalation model)"

# ---------------------------------------------------------------------------
# #740 (scopefuel #738 / b5b0ad2): post-#738 opus@low is an ordinary S rung —
# builder-opus-low must spawn on its SCOPEFUEL_E6_ARM marker alone (wrk
# neither adds nor demands --operator-request), and a caller-supplied REF is
# forwarded verbatim into the gate's own operator_request_not_applicable
# rc 3. sonnet@xhigh stays escalation-gated across the fixture's two modes
# (model claim — real #716+ gates skip the ladder on --effort rungs for it
# too; whether the gate should enforce it is a separate decision). The knob
# WRK_GATE_738=1 selects the post-#738 gate (matches real b5b0ad2 for
# opus@low); the default is a synthetic strict escalation model — the real
# installed gate does NOT demand a REF on --effort-named rungs (scopefuel
# #716), so the default exercises refusal propagation, not installed
# behaviour. Mutants: wrk auto-adding --operator-request for opus@low, wrk
# locally demanding it, or the fixture keeping opus@low escalation-marked
# under WRK_GATE_738 all turn this block RED.
# ---------------------------------------------------------------------------

# Help text: the escalation-gated list must name sonnet@xhigh only — a stale
# opus@low entry teaches callers to pass a REF the post-#738 gate refuses.
grep -qF 'marks escalation (sonnet@xhigh)' <<<"$spawn_help_out" ||
  fail "spawn --help lost the sonnet@xhigh escalation note"
if grep -qF 'opus@low, sonnet@xhigh' <<<"$spawn_help_out"; then
  fail "spawn --help still lists opus@low as escalation-gated"
fi

# Returns 0 iff a bare builder-opus-low spawn is admitted on its marker alone:
# exact rung argv, gate asked about opus@low with no --operator-request in the
# argv, and the quota record carries the canonical launch_profile with no REF
# fields. Returns nonzero on ANY failed check (assertion failure, not exit) so
# the same predicate can be run against both gate worlds below. The body is a
# subshell on purpose: the internal set +e/set -e toggles and the failing
# return must not leak into the caller — a `{ }` body would re-enable -e
# globally and the mutant call below would kill the suite instead of
# producing a captured nonzero rc.
e6_opus_low_marker_only() (
  local job="$1" out rc start
  # NOTE: each file needs its own redirection — `: >a b` would leave
  # scopefuel.log untruncated and the no-REF assertion below would trip on
  # stale --operator-request lines from the earlier escalation cases.
  : >"$TMP/herdr.log"
  : >"$TMP/scopefuel.log"
  set +e
  out="$(SCOPEFUEL_E6_ARM=opus@low \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base builder-opus-low --role builder --lane e6-740-lane --parent parent-lane \
    --job "$job" --t T1 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || return 1
  grep -q 'model=builder-opus-low' <<<"$out" || return 1
  start="$(grep '^agent start ' "$TMP/herdr.log")"
  [[ "$start" == *' -- --model opus --dangerously-skip-permissions --effort low' ]] || return 1
  [[ "$(tail -n 1 "$TMP/scopefuel.log")" == opus ]] || return 1
  grep -qF 'gate -m opus --effort low' "$TMP/scopefuel.log" || return 1
  ! grep -q -- '--operator-request' "$TMP/scopefuel.log" || return 1
  ! grep -q -- '--requested-by' "$TMP/scopefuel.log" || return 1
  python3 - "$E6_INBOX/$job/events" <<'PY' || return 1
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
claim = next(e for e in events if e["kind"] == "job.claim")
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert claim["payload"]["role"] == "builder", claim
p = record["payload"]
assert p["launch_profile"] == "opus@low", p
for key in ("escalation_override", "operator_request_ref", "requested_by", "ref_resolution"):
    assert key not in p, p
PY
)

# Post-#738 gate: marker-only spawn is admitted with a REF-free gate argv.
WRK_GATE_738=1 e6_opus_low_marker_only e6-740-marker-only ||
  fail "post-#738 gate must admit builder-opus-low on its marker alone"
echo "PASS 740 post-738 builder-opus-low spawns on its E6 marker alone"

# Assertion-RED mutant: the identical assertions under the escalation-model
# gate MUST fail — the marker-only spawn is model-refused there
# (escalation), so a GREEN here would prove the predicate cannot tell the
# two gate behaviours apart (and a wrk that auto-added the REF would fail
# the no-REF check under WRK_GATE_738 the same way).
set +e
e6_opus_low_marker_only e6-740-mutant
e6_mutant_rc=$?
set -e
[[ "$e6_mutant_rc" -ne 0 ]] ||
  fail "assertion mutant: marker-only assertions passed under the escalation-model gate — they do not discriminate"
echo "PASS 740 marker-only assertions go RED on the escalation-model gate (mutant)"

# Post-#738 gate: a caller-supplied REF on opus@low is still forwarded
# verbatim and dies on the gate's own not_applicable refusal — wrk never
# pre-judges applicability.
set +e
e6_738_ref_out="$(SCOPEFUEL_E6_ARM=opus@low WRK_GATE_738=1 \
  spawn_deny "$TMP/herdr-740-ref.log" builder-opus-low --role builder --lane e6-740ref-lane --parent parent-lane \
  --job e6-740-ref --t T1 --operator-request hk:task/740 2>&1)"
e6_738_ref_rc=$?
set -e
[[ "$e6_738_ref_rc" -eq 3 ]] ||
  fail "post-#738 opus@low + REF must hit the gate not_applicable refusal (rc=$e6_738_ref_rc): $e6_738_ref_out"
grep -q 'operator_request_not_applicable' <<<"$e6_738_ref_out" ||
  fail "post-#738 REF refusal lost its reason: $e6_738_ref_out"
grep -qF -- '--operator-request hk:task/740' "$TMP/scopefuel.log" ||
  fail "the REF must still reach the gate verbatim: $(cat "$TMP/scopefuel.log")"
[[ ! -e "$TMP/herdr-740-ref.log" ]] ||
  fail "a not_applicable REF reached Herdr"
echo "PASS 740 post-738 opus@low + REF is gate-refused not_applicable, verbatim forward"

# sonnet@xhigh stays escalation-gated in BOTH fixture modes: marker alone is
# refused (rc 3), marker + REF is admitted.
set +e
e6_sx_def_out="$(SCOPEFUEL_E6_ARM=sonnet@xhigh \
  spawn_deny "$TMP/herdr-740-sx-def.log" builder-sonnet-xhigh --role builder --lane e6-sxdef-lane --parent parent-lane \
  --job e6-740-sx-def --t T1 2>&1)"
e6_sx_def_rc=$?
set -e
[[ "$e6_sx_def_rc" -eq 3 ]] ||
  fail "escalation-model sonnet@xhigh without REF must stay escalation-denied (rc=$e6_sx_def_rc): $e6_sx_def_out"
grep -q 'escalation' <<<"$e6_sx_def_out" ||
  fail "escalation-model sonnet@xhigh refusal must stay the escalation denial: $e6_sx_def_out"
[[ ! -e "$TMP/herdr-740-sx-def.log" ]] ||
  fail "a denied sonnet@xhigh spawn reached Herdr"
set +e
e6_738_sx_out="$(SCOPEFUEL_E6_ARM=sonnet@xhigh WRK_GATE_738=1 \
  spawn_deny "$TMP/herdr-740-sx.log" builder-sonnet-xhigh --role builder --lane e6-740sx-lane --parent parent-lane \
  --job e6-740-sx-noref --t T1 2>&1)"
e6_738_sx_rc=$?
set -e
[[ "$e6_738_sx_rc" -eq 3 ]] ||
  fail "post-#738 sonnet@xhigh without REF must stay escalation-denied (rc=$e6_738_sx_rc): $e6_738_sx_out"
grep -q 'escalation' <<<"$e6_738_sx_out" ||
  fail "sonnet@xhigh refusal must stay the escalation denial: $e6_738_sx_out"
[[ ! -e "$TMP/herdr-740-sx.log" ]] ||
  fail "a denied sonnet@xhigh spawn reached Herdr"
: >"$TMP/herdr.log"
: >"$TMP/scopefuel.log"
set +e
e6_738_sxok_out="$(SCOPEFUEL_E6_ARM=sonnet@xhigh WRK_GATE_738=1 \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-sonnet-xhigh --role builder --lane e6-740sxok-lane --parent parent-lane \
  --job e6-740-sx-ok --t T1 --operator-request hk:task/740 2>&1)"
e6_738_sxok_rc=$?
set -e
[[ "$e6_738_sxok_rc" -eq 0 ]] ||
  fail "post-#738 sonnet@xhigh + REF spawn refused (rc=$e6_738_sxok_rc): $e6_738_sxok_out"
grep -q '^OK pane=' <<<"$e6_738_sxok_out" ||
  fail "post-#738 sonnet@xhigh + REF did not spawn: $e6_738_sxok_out"
grep -qF 'gate -m sonnet --effort xhigh --operator-request hk:task/740' "$TMP/scopefuel.log" ||
  fail "sonnet@xhigh REF must reach the gate verbatim: $(cat "$TMP/scopefuel.log")"
grep -q 'escalation_override=true' <<<"$e6_738_sxok_out" ||
  fail "sonnet@xhigh must keep escalation_override=true: $e6_738_sxok_out"
echo "PASS 740 sonnet@xhigh stays escalation-gated under both fixture modes"

# Effort mutants: off-rung --effort is refused on the pin; the same rung
# spelled out is accepted; kimi refuses --effort outright (no CLI flag); a
# clone home at the wrong effort — or missing entirely — fails closed.
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=opus@medium \
  spawn_base builder-opus-low --role builder --lane e6-eff-lane --parent parent-lane \
  --effort medium --operator-request hk:task/704 --job e6-eff-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-opus-low --effort medium must die on the pin (rc=$e6_eff_rc): $e6_eff_out"
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=codex-sol@high \
  spawn_base builder-sol-high --role builder --lane e6-eff2-lane --parent parent-lane \
  --effort max --job e6-eff2-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-sol-high --effort max must die on the pin (rc=$e6_eff_rc): $e6_eff_out"
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=codex-sol@medium \
  spawn_base builder-sol-medium --role builder --lane e6-sol-eff-lane --parent parent-lane \
  --effort high --job e6-sol-eff-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-sol-medium --effort high must die on the pin (rc=$e6_eff_rc): $e6_eff_out"
# hk 1796: off-rung --effort dies on the pin for the four new spellings too.
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=sonnet@medium \
  spawn_base builder-sonnet-medium --role builder --lane e6-smed-eff-lane --parent parent-lane \
  --effort high --job e6-smed-eff-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-sonnet-medium --effort high must die on the pin (rc=$e6_eff_rc): $e6_eff_out"
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=haiku@low \
  spawn_base builder-haiku-low --role builder --lane e6-hkw-eff-lane --parent parent-lane \
  --effort medium --job e6-hkw-eff-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-haiku-low --effort medium must die on the pin (rc=$e6_eff_rc): $e6_eff_out"
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=codex-luna@low \
  spawn_base builder-luna-low --role builder --lane e6-llow-eff-lane --parent parent-lane \
  --effort medium --job e6-llow-eff-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-luna-low --effort medium must die on the pin (rc=$e6_eff_rc): $e6_eff_out"
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=codex-luna@medium \
  spawn_base builder-luna-medium --role builder --lane e6-lmed-eff-lane --parent parent-lane \
  --effort low --job e6-lmed-eff-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-luna-medium --effort low must die on the pin (rc=$e6_eff_rc): $e6_eff_out"
# hk 1863: off-rung --effort dies on the pin for the five new spellings; the
# rung spelled out is the allowed restatement (covered by e6_builder_case).
for e6_ef in builder-sol-low:codex-sol@low:medium builder-haiku-high:haiku@high:low \
  builder-haiku-xhigh:haiku@xhigh:high builder-haiku-max:haiku@max:xhigh \
  builder-sonnet-low:sonnet@low:medium builder-haiku-medium:haiku@medium:high; do
  IFS=: read -r e6_ef_model e6_ef_marker e6_ef_off <<<"$e6_ef"
  set +e
  e6_eff_out="$(SCOPEFUEL_E6_ARM="$e6_ef_marker" \
    spawn_base "$e6_ef_model" --role builder --lane "$e6_ef_model-eff-lane" --parent parent-lane \
    --effort "$e6_ef_off" --job "$e6_ef_model-eff-mutant" --t T1 2>&1)"
  e6_eff_rc=$?
  set -e
  [[ "$e6_eff_rc" -eq 2 ]] ||
    fail "$e6_ef_model --effort $e6_ef_off must die on the pin (rc=$e6_eff_rc): $e6_eff_out"
  grep -q "$e6_ef_model is pinned to effort" <<<"$e6_eff_out" ||
    fail "$e6_ef_model --effort $e6_ef_off must die on the pin rule: $e6_eff_out"
done
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=kimi-k3@high KIMI_CODE_HIGH_HOME="$E6_KIMI_HIGH_HOME" \
  spawn_base builder-kimi-high --role builder --lane e6-kimi-eff-lane --parent parent-lane \
  --effort high --job e6-kimi-eff-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-kimi-high --effort must die rc 2 — kimi has no CLI effort flag (rc=$e6_eff_rc): $e6_eff_out"
set +e
e6_clone_out="$(SCOPEFUEL_E6_ARM=kimi-k3@high KIMI_CODE_HIGH_HOME="$E6_KIMI_MAX_HOME" \
  spawn_base builder-kimi-high --role builder --lane e6-clone-lane --parent parent-lane \
  --job e6-clone-mutant --t T1 2>&1)"
e6_clone_rc=$?
set -e
[[ "$e6_clone_rc" -eq 2 ]] ||
  fail "builder-kimi-high on a max clone must die rc 2 (rc=$e6_clone_rc): $e6_clone_out"
grep -q 'kimi-clone-home --effort high' <<<"$e6_clone_out" ||
  fail "clone-mismatch refusal must name the fix: $e6_clone_out"
set +e
e6_clone_out="$(SCOPEFUEL_E6_ARM=kimi-k3@high KIMI_CODE_HIGH_HOME="$TMP/kimi-no-such-home" \
  spawn_base builder-kimi-high --role builder --lane e6-clone2-lane --parent parent-lane \
  --job e6-clone-missing --t T1 2>&1)"
e6_clone_rc=$?
set -e
[[ "$e6_clone_rc" -eq 2 ]] ||
  fail "builder-kimi-high with a missing clone home must die rc 2 (rc=$e6_clone_rc): $e6_clone_out"
# The pinned rung spelled out explicitly is allowed.
: >"$TMP/herdr.log"
set +e
e6_same_out="$(SCOPEFUEL_E6_ARM=codex-sol@high \
  spawn_base builder-sol-high --role builder --lane e6-same-lane --parent parent-lane \
  --effort high --job e6-same-effort --t T1 2>&1)"
e6_same_rc=$?
set -e
[[ "$e6_same_rc" -eq 0 ]] ||
  fail "builder-sol-high --effort high (the pinned rung) must be admitted (rc=$e6_same_rc): $e6_same_out"
grep -q 'model_reasoning_effort=high' "$TMP/herdr.log" ||
  fail "builder-sol-high --effort high must keep the pinned rung: $e6_same_out"
# Role/hierarchy mutants for the new spellings.
set +e
e6_hier_out="$(SCOPEFUEL_E6_ARM=codex-sol@high \
  spawn_base builder-sol-high --role builder --lane e6-noparent-lane --job e6-noparent --t T1 2>&1)"
e6_hier_rc=$?
set -e
[[ "$e6_hier_rc" -eq 2 ]] ||
  fail "builder-sol-high --role builder without --parent must die rc 2 (rc=$e6_hier_rc): $e6_hier_out"
set +e
e6_hier_out="$(SCOPEFUEL_E6_ARM=sonnet@max \
  spawn_base builder-sonnet-max --job e6-worker-role --t T1 2>&1)"
e6_hier_rc=$?
set -e
[[ "$e6_hier_rc" -eq 2 ]] ||
  fail "builder-sonnet-max without --role builder must die rc 2 (rc=$e6_hier_rc): $e6_hier_out"
echo "PASS 704 E6 effort pin, clone-home, and hierarchy mutants"
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
# refusal enumerates the builder profiles by name plus the worker-only
# devin model variants (task 281, #635 ds41-max, #666 builder spellings —
# the ds41 worker spellings stay refused under --role builder).
for rejected in codex-sol codex-luna oc-solar4 devin-ds41 devin-ds41-max; do
  set +e
  rejected_out="$(spawn_base "$rejected" --role builder --lane builder-lane --parent parent-lane --job "builder-reject-$rejected" --t T1 2>&1)"
  rejected_rc=$?
  set -e
  [[ "$rejected_rc" -eq 2 ]] ||
    fail "--role builder must still reject $rejected with exit 2, got $rejected_rc: $rejected_out"
  for named in builder-devin builder-devin-medium builder-devin-max builder-ds41 builder-ds41-max builder-grok builder-kimi builder-luna builder-sonnet devin-glm52 devin-swe17 devin-ds41 devin-ds41-max devin-fusion-opus55 devin-fusion-sonnet55; do
    grep -q "$named" <<<"$rejected_out" ||
      fail "the --role builder refusal must list $named: $rejected_out"
  done
done
echo "PASS builder-pilot-allowlist-rejects-outsiders-with-named-message"

# hk 1380: the fusion spellings are worker/tester-only — --role builder refuses
# each with its own named refusal citing the pending hk 1382 decision (the
# generic allowlist message must not be what speaks).
for fusion_rejected in devin-fusion-opus55 devin-fusion-sonnet55; do
  set +e
  fusion_rejected_out="$(spawn_base "$fusion_rejected" --role builder --lane builder-lane --parent parent-lane --job "builder-reject-$fusion_rejected" --t T1 2>&1)"
  fusion_rejected_rc=$?
  set -e
  [[ "$fusion_rejected_rc" -eq 2 ]] ||
    fail "--role builder must reject $fusion_rejected with exit 2, got $fusion_rejected_rc: $fusion_rejected_out"
  grep -qF -e "--role builder rejects '$fusion_rejected': the devin fusion spellings are worker/tester-only" <<<"$fusion_rejected_out" ||
    fail "$fusion_rejected lost its named fusion refusal: $fusion_rejected_out"
  grep -q 'hk 1382' <<<"$fusion_rejected_out" ||
    fail "$fusion_rejected refusal must cite the pending hk 1382 decision: $fusion_rejected_out"
done
echo "PASS builder-allowlist-rejects-fusion-spellings-with-named-message"

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
tmp_writers_stop ||
  fail "tracked writers survived the mid-case teardown:${TW_LEFTOVER_PIDS:-}"
rm -rf "$TMP/xdg/arbiter"
unset TEST_ARBITER_BIN

# ROB-1198 §③: an unclassified job is refused outright — no default T, and the
# refusal happens before the gate, the claim and the spawn.
spawn_untyped() {
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="${TEST_ARBITER_BIN:-$TMP/absent-arbiter}" WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
    "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l fixture "$@"
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
    "$WRK" spawn -c "$cwd" -m codex-luna -p "$PROMPT" -w w -l fixture --t T1
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
import json, re, sys
event = json.load(open(sys.argv[1]))
assert set(event) == {"kind", "job_id", "owner_lane", "label", "pane_id", "host", "report_path", "report_last_line", "epoch", "report_sha256", "at"}, event
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z", event["at"]), event
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
  seed_join_round "$R20_FIXTURE_INBOX" captain-fixture
  env ARBITER_INBOX_ROOT="$R20_FIXTURE_INBOX" HOSTNAME=fixture-host \
    WRK_PANEWIRE_LOG="$R20_FIXTURE_LOG" "$WRK" joined captain-fixture \
    --pr https://example.invalid/pr/1 --head deadbeef --report report.md >/dev/null
)
# hk 1750 adds one required member: at is appended last as a UTC ISO
# millisecond timestamp. Strip exactly that member and require the remaining
# bytes to stay identical to the committed R19a fixture.
r20_strip_at() {
  python3 - "$1" "$2" <<'PY'
import re, sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
stripped = re.sub(r',"at":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z"(?=})', "", text)
assert stripped != text, text
open(target, "w", encoding="utf-8").write(stripped)
PY
}
r20_strip_at "$R20_FIXTURE_INBOX/captain-fixture/events/00003-job.escalate.json" "$TMP/r20-escalate-norm.json"
r20_strip_at "$R20_FIXTURE_INBOX/captain-fixture/events/00004-job.joined.json" "$TMP/r20-joined-norm.json"
cmp "$R20_FIXTURE/00003-job.escalate.json" "$TMP/r20-escalate-norm.json"
cmp "$R20_FIXTURE/00004-job.joined.json" "$TMP/r20-joined-norm.json"
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
r20_done_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" XDG_DATA_HOME="$TMP/xdg-r20" \
  ARBITER_BIN="$ARBITER" HOSTNAME=fixture-host \
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
r20_escalate_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" XDG_DATA_HOME="$TMP/xdg-r20" \
  ARBITER_BIN="$ARBITER" HOSTNAME=fixture-host \
  WRK_PANEWIRE_LOG="$R20_BUILDER_LOG" "$WRK" escalate r20-builder \
  --question 'need parent decision')"
seed_join_round "$R20_INBOX" r20-builder
r20_joined_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" XDG_DATA_HOME="$TMP/xdg-r20" \
  ARBITER_BIN="$ARBITER" HOSTNAME=fixture-host \
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
r20_absent_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" XDG_DATA_HOME="$TMP/xdg-r20" \
  ARBITER_BIN="$ARBITER" PANEWIRE_BIN="$TMP/absent-panewire" \
  HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
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
r20_fail_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" XDG_DATA_HOME="$TMP/xdg-r20" \
  ARBITER_BIN="$ARBITER" WRK_PANEWIRE_RC=3 \
  HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  "$WRK" 'done' r20-fail --report "$R20_REPORT" 2>"$R20_FAIL_ERR")"
r20_fail_rc=$?
set -e
[[ "$r20_fail_rc" -eq 0 ]]
[[ -f "$R20_INBOX/r20-fail/events/00003-job.completed.json" ]]
# #1014: a failed emit is loud twice — the report path in the warning and
# relay=file-only on the OK line.
grep -qxF "OK job=r20-fail report=$R20_REPORT relay=file-only" <<<"$r20_fail_out"
grep -qxF 'wrk: warning: handoffkeep not found; report document not uploaded (job=r20-fail)' "$R20_FAIL_ERR"
grep -qxF "wrk: warning: panewire emit failed (rc=3 job=r20-fail kind=job.completed report=$R20_REPORT); relay event left as file only" "$R20_FAIL_ERR"
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
r20_slow_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" XDG_DATA_HOME="$TMP/xdg-r20" \
  ARBITER_BIN="$ARBITER" WRK_PANEWIRE_SLEEP=30 \
  "$WRK" 'done' r20-slow --report "$R20_REPORT" 2>"$R20_SLOW_ERR")"
r20_slow_rc=$?
set -e
r20_slow_ms="$(( ($(python3 -c 'import time; print(time.time_ns())') - r20_slow_start_ns) / 1000000 ))"
echo "r20 wedged-emit: elapsed_ms=$r20_slow_ms rc=$r20_slow_rc"
[[ "$r20_slow_rc" -eq 0 ]]
[[ "$r20_slow_ms" -lt 10000 ]]
[[ -f "$R20_INBOX/r20-slow/events/00003-job.completed.json" ]]
# #1014: the emit timed out, so the OK line marks the relay file-only.
grep -qxF "OK job=r20-slow report=$R20_REPORT relay=file-only" <<<"$r20_slow_out"
grep -q 'panewire emit failed' "$R20_SLOW_ERR"
echo "PASS r20-wedged-emit-is-bounded-by-the-timeout-guard"

# TW7 — job.lost is not one of panewire's relay kinds, so the sentinel path
# must not emit at all; passing it would only pile up usage warnings.
R20_LOST_LOG="$TMP/r20-lost-emit.log"
R20_LOST_INBOX="$TMP/r20-lost-inbox"
R20_LOST_SEQ="$TMP/r20-lost.seq"
printf 'not-found\n' >"$R20_LOST_SEQ"
set +e
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" XDG_DATA_HOME="$TMP/xdg-r20" \
  ARBITER_INBOX_ROOT="$R20_LOST_INBOX" WRK_PANEWIRE_LOG="$R20_LOST_LOG" \
  WRK_FIXTURE_GET_SEQUENCE="$R20_LOST_SEQ" WRK_COMPLETION_TIMEOUT_S=1 WRK_COMPLETION_INTERVAL_S=1 \
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
env ARBITER_INBOX_ROOT="$R20_INBOX" XDG_DATA_HOME="$TMP/xdg-r20" \
  ARBITER_BIN="$ARBITER" HOSTNAME=fixture-host \
  WRK_PANEWIRE_REQUIRE_INBOX_ROOT=1 WRK_PANEWIRE_LOG="$R20_ROOT_LOG" \
  "$WRK" 'done' r20-root-done --report "$R20_REPORT" 2>"$R20_ROOT_ERR" >/dev/null
env ARBITER_INBOX_ROOT="$R20_INBOX" XDG_DATA_HOME="$TMP/xdg-r20" \
  ARBITER_BIN="$ARBITER" HOSTNAME=fixture-host \
  WRK_PANEWIRE_REQUIRE_INBOX_ROOT=1 WRK_PANEWIRE_LOG="$R20_ROOT_LOG" \
  "$WRK" escalate r20-root-builder --question 'need parent decision' \
  2>>"$R20_ROOT_ERR" >/dev/null
seed_join_round "$R20_INBOX" r20-root-builder
env ARBITER_INBOX_ROOT="$R20_INBOX" XDG_DATA_HOME="$TMP/xdg-r20" \
  ARBITER_BIN="$ARBITER" HOSTNAME=fixture-host \
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
r21_done_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" ARBITER_BIN="$ARBITER" \
  XDG_DATA_HOME="$TMP/xdg-r21" HOSTNAME=fixture-host \
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
env ARBITER_INBOX_ROOT="$R21_INBOX" ARBITER_BIN="$ARBITER" \
  XDG_DATA_HOME="$TMP/xdg-r21" HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
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
r21_fail_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" ARBITER_BIN="$ARBITER" \
  XDG_DATA_HOME="$TMP/xdg-r21" HOSTNAME=fixture-host \
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
r21_absent_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" ARBITER_BIN="$ARBITER" \
  XDG_DATA_HOME="$TMP/xdg-r21" HOSTNAME=fixture-host \
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
r21_slow_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" ARBITER_BIN="$ARBITER" \
  XDG_DATA_HOME="$TMP/xdg-r21" HOSTNAME=fixture-host \
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
seed_join_round "$R21_INBOX" "$R21_JOINED_JOB"
env ARBITER_INBOX_ROOT="$R21_INBOX" ARBITER_BIN="$ARBITER" \
  XDG_DATA_HOME="$TMP/xdg-r21" HOSTNAME=fixture-host HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
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
env ARBITER_INBOX_ROOT="$R21_INBOX" ARBITER_BIN="$ARBITER" \
  XDG_DATA_HOME="$TMP/xdg-r21" HOSTNAME=fixture-host HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
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
env ARBITER_INBOX_ROOT="$R21_INBOX" ARBITER_BIN="$ARBITER" \
  XDG_DATA_HOME="$TMP/xdg-r21" HOSTNAME=fixture-host HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
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
env ARBITER_INBOX_ROOT="$R21_INBOX" ARBITER_BIN="$ARBITER" \
  XDG_DATA_HOME="$TMP/xdg-r21" HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
  WRK_HANDOFFKEEP_LOG="$R21_ESC_MISSING_HK_LOG" "$WRK" escalate "$R21_ESC_MISSING_JOB" \
  --question 'need a decision' --report "$TMP/no-such-report.md" >/dev/null 2>&1
r21_esc_missing_rc=$?
set -e
[[ "$r21_esc_missing_rc" -ne 0 ]]
[[ ! -s "$R21_ESC_MISSING_HK_LOG" ]]
echo "PASS r21-escalate-report-optional-and-missing-path-is-fatal"

# ── #1014: a later-round `wrk done` must relay, not collide ─────────────────
# panewire's emit outbox key is (kind, job, epoch, report_path, reason), and
# the fixture now refuses a same-key emit for a different record with rc 6
# exactly like writeEmitRecord. A fix round that updates report.md in place
# must therefore be relayed under a fresh artifact path: the durable record,
# the handoffkeep document upload, the emit argv and the OK line all name it.
# ARBITER_INBOX_ROOT ends in /jobs here so the emit --inbox-root (the parent
# directory) resolves <root>/jobs/<job>/events to this very events dir — the
# fixture's duplicate-key scan is then exercised rather than vacuous.
RND_INBOX="$TMP/rnd-inbox"
RND_JOBS="$RND_INBOX/jobs"
mkdir -p "$RND_JOBS"
rnd_arb() { env ARBITER_INBOX_ROOT="$RND_JOBS" XDG_DATA_HOME="$TMP/xdg-rnd" "$ARBITER" "$@"; }
rnd_claim() {
  rnd_arb claim --job "$1" --lane lane-a --agent-label wrk-a --t T1 "${@:2}" >/dev/null
  rnd_arb event --job "$1" --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
}
rnd_report() {
  local path="$RND_JOBS/$1/$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$3" >"$path"
  printf '%s\n' "$path"
}

# AC1 — round 2 on the same path: snapshot to report-r2.md and relay under it.
RND1_JOB="rnd-same-path"
RND1_HK_LOG="$TMP/rnd1-handoffkeep.log"
RND1_PW_LOG="$TMP/rnd1-panewire.log"
rnd_claim "$RND1_JOB"
rnd1_report="$(rnd_report "$RND1_JOB" report.md 'round one terminal line')"
env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND1_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND1_PW_LOG" "$WRK" 'done' "$RND1_JOB" --report "$rnd1_report" >/dev/null
printf 'round two terminal line\n' >"$rnd1_report"
rnd1_second="$(env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND1_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND1_PW_LOG" "$WRK" 'done' "$RND1_JOB" --report "$rnd1_report")"
rnd1_snapshot="$RND_JOBS/$RND1_JOB/report-r2.md"
[[ -f "$rnd1_snapshot" ]] ||
  fail "a changed report.md on an already-completed path must be snapshot to report-r2.md"
grep -qxF "OK job=$RND1_JOB report=$rnd1_snapshot" <<<"$rnd1_second" ||
  fail "the OK line must name the snapshot path: $rnd1_second"
grep -qxF 'round two terminal line' "$rnd1_report" ||
  fail "the original report.md must stay untouched"
grep -qxF 'round two terminal line' "$rnd1_snapshot" ||
  fail "the snapshot must carry the new report content"
PYTHONPATH="$TMP" python3 - "$RND1_HK_LOG" "$RND1_PW_LOG" \
  "$RND_JOBS/$RND1_JOB/events" "$rnd1_report" "$rnd1_snapshot" <<'PY'
import glob, hashlib, json, pathlib, sys
import r20_emit as helper

handoff_log, panewire_log, events, report, snapshot = sys.argv[1:]
uploads = helper.calls(handoff_log)
assert len(uploads) == 2, uploads
assert uploads[0][3] == "reports/rnd-same-path/report.md" and uploads[0][-1] == report, uploads[0]
assert uploads[1][3] == "reports/rnd-same-path/report-r2.md" and uploads[1][-1] == snapshot, uploads[1]
emits = helper.calls(panewire_log)
assert len(emits) == 2, emits
assert helper.flags(emits[0])["--report"] == report, emits[0]
assert helper.flags(emits[1])["--report"] == snapshot, emits[1]
records = [json.loads(p.read_text()) for p in sorted(pathlib.Path(events).glob("*job.completed.json"))]
assert [r["report_path"] for r in records] == [report, snapshot], records
assert records[1]["report_sha256"] == hashlib.sha256(pathlib.Path(snapshot).read_bytes()).hexdigest()
assert records[0]["report_sha256"] != records[1]["report_sha256"], records
helper.assert_matches_record(emits[1], records[1])
assert records[1]["report_last_line"].endswith(" doc:reports/rnd-same-path/report-r2.md"), records[1]
PY
echo "PASS 1014-ac1-later-round-done-relays-under-snapshot-path"

# AC2 — unchanged content on the same path stays a suppressed duplicate: no
# second record, no second emit, no snapshot file.
RND2_JOB="rnd-identical"
RND2_HK_LOG="$TMP/rnd2-handoffkeep.log"
RND2_PW_LOG="$TMP/rnd2-panewire.log"
RND2_ERR="$TMP/rnd2.err"
rnd_claim "$RND2_JOB"
rnd2_report="$(rnd_report "$RND2_JOB" report.md 'same terminal line')"
env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND2_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND2_PW_LOG" "$WRK" 'done' "$RND2_JOB" --report "$rnd2_report" >/dev/null
rnd2_second="$(env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND2_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND2_PW_LOG" "$WRK" 'done' "$RND2_JOB" --report "$rnd2_report" 2>"$RND2_ERR")"
grep -qxF "OK job=$RND2_JOB report=$rnd2_report" <<<"$rnd2_second" ||
  fail "a suppressed duplicate still prints the caller's report path: $rnd2_second"
grep -q 'job.completed already recorded for this report; suppressed duplicate' "$RND2_ERR" ||
  fail "the duplicate suppression must stay a warning, got: $(cat "$RND2_ERR")"
grep -q "suppressed-duplicate report=$rnd2_report" "$RND_JOBS/$RND2_JOB/completion-suppressed.log" ||
  fail "the suppressed duplicate must leave its durable note"
[[ "$(find "$RND_JOBS/$RND2_JOB/events" -name '*job.completed.json' | wc -l | tr -d ' ')" == 1 ]] ||
  fail "a suppressed duplicate writes no second job.completed record"
[[ ! -e "$RND_JOBS/$RND2_JOB/report-r2.md" ]] ||
  fail "an identical report must not be snapshot"
PYTHONPATH="$TMP" python3 - "$RND2_HK_LOG" "$RND2_PW_LOG" <<'PY'
import sys
import r20_emit as helper

assert len(helper.calls(sys.argv[1])) == 1, helper.calls(sys.argv[1])
assert len(helper.calls(sys.argv[2])) == 1, helper.calls(sys.argv[2])
PY
echo "PASS 1014-ac2-identical-report-still-suppressed"

# AC3 — a caller that already names a fresh path gets no second snapshot: the
# record, upload and emit use report-r2.md verbatim.
RND3_JOB="rnd-new-path"
RND3_HK_LOG="$TMP/rnd3-handoffkeep.log"
RND3_PW_LOG="$TMP/rnd3-panewire.log"
rnd_claim "$RND3_JOB"
rnd3_first="$(rnd_report "$RND3_JOB" report.md 'round one terminal line')"
env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND3_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND3_PW_LOG" "$WRK" 'done' "$RND3_JOB" --report "$rnd3_first" >/dev/null
rnd3_report="$(rnd_report "$RND3_JOB" report-r2.md 'explicit round two path')"
rnd3_out="$(env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND3_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND3_PW_LOG" "$WRK" 'done' "$RND3_JOB" --report "$rnd3_report")"
grep -qxF "OK job=$RND3_JOB report=$rnd3_report" <<<"$rnd3_out" ||
  fail "an explicit fresh path must be used verbatim: $rnd3_out"
[[ ! -e "$RND_JOBS/$RND3_JOB/report-r3.md" ]] ||
  fail "an explicit new path must not be snapshot again"
PYTHONPATH="$TMP" python3 - "$RND3_HK_LOG" "$RND3_PW_LOG" \
  "$RND_JOBS/$RND3_JOB/events" "$rnd3_report" <<'PY'
import json, pathlib, sys
import r20_emit as helper

handoff_log, panewire_log, events, report = sys.argv[1:]
uploads = helper.calls(handoff_log)
assert len(uploads) == 2, uploads
assert uploads[1][3] == "reports/rnd-new-path/report-r2.md" and uploads[1][-1] == report, uploads[1]
emits = helper.calls(panewire_log)
assert len(emits) == 2, emits
assert helper.flags(emits[1])["--report"] == report, emits[1]
records = [json.loads(p.read_text()) for p in sorted(pathlib.Path(events).glob("*job.completed.json"))]
assert records[-1]["report_path"] == report, records
helper.assert_matches_record(emits[1], records[-1])
PY
echo "PASS 1014-ac3-explicit-new-path-needs-no-snapshot"

# AC4 — the completion sentinel and `wrk done` racing on the same changed
# report land exactly one record for the round and exactly one snapshot file:
# the events lock serializes the resolve-and-write decision.
RND4_JOB="rnd-sentinel-race"
RND4_PW_LOG="$TMP/rnd4-panewire.log"
rnd_claim "$RND4_JOB"
rnd4_report="$(rnd_report "$RND4_JOB" report.md 'round one terminal line')"
env ARBITER_INBOX_ROOT="$RND_JOBS" HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  WRK_PANEWIRE_LOG="$RND4_PW_LOG" "$WRK" 'done' "$RND4_JOB" --report "$rnd4_report" >/dev/null
# A fix round revives the job — a spawned record newer than the round-1
# terminal keeps the sentinel watching instead of watch-exiting.
rnd_arb event --job "$RND4_JOB" --kind job.spawned \
  --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
printf 'round two terminal line\n' >"$rnd4_report"
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" XDG_DATA_HOME="$TMP/xdg-rnd" \
  ARBITER_INBOX_ROOT="$RND_JOBS" \
  WRK_FIXTURE_SCENARIO=sentinel-done WRK_COMPLETION_TIMEOUT_S=30 \
  WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel "$RND4_JOB" lane-a wrk-a w1:p1 "$rnd4_report" >/dev/null 2>&1 &
rnd4_sentinel=$!
own "$rnd4_sentinel"
# done lands inside the sentinel's settle window, so both processes reach
# completion_event on the same changed report.
sleep 2
env ARBITER_INBOX_ROOT="$RND_JOBS" HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  WRK_PANEWIRE_LOG="$RND4_PW_LOG" "$WRK" 'done' "$RND4_JOB" --report "$rnd4_report" >/dev/null 2>&1
rnd4_done_rc=$?
# Whichever side won, both left: done returned above, and the sentinel exits
# on its own completed write or on the watch-exit check that follows it.
wait_until 20 bash -c "! kill -0 $rnd4_sentinel 2>/dev/null" ||
  fail "the sentinel must exit once the raced round completed"
wait "$rnd4_sentinel" 2>/dev/null || true
[[ "$rnd4_done_rc" -eq 0 ]] || fail "wrk done during a sentinel race must still exit 0"
[[ -f "$RND_JOBS/$RND4_JOB/report-r2.md" ]] ||
  fail "the raced round must have produced exactly the report-r2.md snapshot"
[[ ! -e "$RND_JOBS/$RND4_JOB/report-r3.md" ]] ||
  fail "the events lock must prevent a second snapshot of the same round"
PYTHONPATH="$TMP" python3 - "$RND4_PW_LOG" "$RND_JOBS/$RND4_JOB/events" \
  "$rnd4_report" "$RND_JOBS/$RND4_JOB/report-r2.md" <<'PY'
import hashlib, json, pathlib, sys
import r20_emit as helper

panewire_log, events, report, snapshot = sys.argv[1:]
records = [json.loads(p.read_text()) for p in sorted(pathlib.Path(events).glob("*job.completed.json"))]
paths = [r["report_path"] for r in records]
assert paths == [report, snapshot], paths
assert records[1]["report_sha256"] == hashlib.sha256(pathlib.Path(snapshot).read_bytes()).hexdigest()
round_two_emits = [c for c in helper.calls(panewire_log)
                   if helper.flags(c)["--report"] == snapshot]
assert len(round_two_emits) <= 1, round_two_emits
PY
echo "PASS 1014-ac4-sentinel-done-race-yields-one-record-one-snapshot"

# AC5 — a non-zero emit is loud: stderr names the job, report path and rc, and
# the OK line carries relay=file-only; the exit status stays what it was.
RND5_JOB="rnd-loud-failure"
RND5_ERR="$TMP/rnd5.err"
rnd_claim "$RND5_JOB"
rnd5_report="$(rnd_report "$RND5_JOB" report.md 'loud failure line')"
set +e
rnd5_out="$(env ARBITER_INBOX_ROOT="$RND_JOBS" WRK_PANEWIRE_RC=6 \
  HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  "$WRK" 'done' "$RND5_JOB" --report "$rnd5_report" 2>"$RND5_ERR")"
rnd5_rc=$?
set -e
[[ "$rnd5_rc" -eq 0 ]] ||
  fail "a failed emit must not change the done exit status, got $rnd5_rc"
grep -qxF "OK job=$RND5_JOB report=$rnd5_report relay=file-only" <<<"$rnd5_out" ||
  fail "a failed emit must mark the OK line relay=file-only: $rnd5_out"
grep -qxF "wrk: warning: panewire emit failed (rc=6 job=$RND5_JOB kind=job.completed report=$rnd5_report); relay event left as file only" "$RND5_ERR" ||
  fail "a failed emit must name job, report path and rc on stderr: $(cat "$RND5_ERR")"
echo "PASS 1014-ac5-failed-emit-is-loud-and-exit-status-unchanged"

# S3 — the delegated path (WRK_PANEWIRE_JOB=present, probe → panewire-job/1)
# must carry the snapshot path too: `panewire job done` records and emits
# whatever --report it is handed, so resolve runs before delegate_job_cmd.
# The fixture's job-done writes the record itself and refuses a same
# outbox-key/different-content call with rc 6, so a leaked original path is
# observable as both a wrong argv and a failing delegated call.
RND6_JOB="rnd-delegated"
RND6_PW_JOB_LOG="$TMP/rnd6-pw-job.log"
RND6_ERR="$TMP/rnd6.err"
rnd_claim "$RND6_JOB"
rnd6_report="$(rnd_report "$RND6_JOB" report.md 'delegated round one')"
rnd6_snap2="$RND_JOBS/$RND6_JOB/report-r2.md"
rnd6_snap3="$RND_JOBS/$RND6_JOB/report-r3.md"
rnd6_done() {
  env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
    HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" PANEWIRE_BIN="$PANEWIRE" \
    WRK_PANEWIRE_JOB=present WRK_PANEWIRE_JOB_LOG="$RND6_PW_JOB_LOG" \
    "$WRK" 'done' "$RND6_JOB" --report "$rnd6_report"
}
rnd6_first="$(rnd6_done)"
[[ "$rnd6_first" == "fixture job done $RND6_JOB --report $rnd6_report" ]] ||
  fail "rnd-delegated r1: delegated stdout must pass through: $rnd6_first"
grep -qxF "HOSTNAME=fixture-host [done] [$RND6_JOB] [--report] [$rnd6_report]" "$RND6_PW_JOB_LOG" ||
  fail "rnd-delegated r1: delegated argv must name report.md: $(cat "$RND6_PW_JOB_LOG")"

printf 'delegated round two\n' >"$rnd6_report"
rnd6_second="$(rnd6_done 2>"$RND6_ERR")"
[[ "$rnd6_second" == "fixture job done $RND6_JOB --report $rnd6_snap2" ]] ||
  fail "rnd-delegated r2: delegated argv must name the snapshot: $rnd6_second"
grep -qxF "HOSTNAME=fixture-host [done] [$RND6_JOB] [--report] [$rnd6_snap2]" "$RND6_PW_JOB_LOG" ||
  fail "rnd-delegated r2: panewire must be handed report-r2.md: $(cat "$RND6_PW_JOB_LOG")"
! grep -q 'delegation failed' "$RND6_ERR" ||
  fail "rnd-delegated r2: the delegated call must not hit the duplicate-key rc 6: $(cat "$RND6_ERR")"

printf 'delegated round three\n' >"$rnd6_report"
rnd6_third="$(rnd6_done 2>"$RND6_ERR")"
[[ "$rnd6_third" == "fixture job done $RND6_JOB --report $rnd6_snap3" ]] ||
  fail "rnd-delegated r3: delegated argv must name the snapshot: $rnd6_third"
grep -qxF "HOSTNAME=fixture-host [done] [$RND6_JOB] [--report] [$rnd6_snap3]" "$RND6_PW_JOB_LOG" ||
  fail "rnd-delegated r3: panewire must be handed report-r3.md: $(cat "$RND6_PW_JOB_LOG")"
! grep -q 'delegation failed' "$RND6_ERR" ||
  fail "rnd-delegated r3: the delegated call must not hit the duplicate-key rc 6: $(cat "$RND6_ERR")"

# Identical re-done: the delegated round-3 record carries report_sha256, so the
# wrk-side resolve suppresses it before delegation — the job log stays at 3.
rnd6_dup="$(rnd6_done 2>"$RND6_ERR")"
[[ "$rnd6_dup" == "OK job=$RND6_JOB report=$rnd6_report" ]] ||
  fail "rnd-delegated identical: suppression prints the caller's path: $rnd6_dup"
grep -q 'suppressed duplicate' "$RND6_ERR" ||
  fail "rnd-delegated identical: suppression must warn: $(cat "$RND6_ERR")"
[[ "$(wc -l <"$RND6_PW_JOB_LOG" | tr -d ' ')" == 3 ]] ||
  fail "rnd-delegated identical: a suppressed round must not delegate: $(cat "$RND6_PW_JOB_LOG")"
python3 - "$RND_JOBS/$RND6_JOB/events" "$rnd6_report" "$rnd6_snap2" "$rnd6_snap3" <<'PY'
import json, os, sys
events, p1, p2, p3 = sys.argv[1:]
paths = []
for name in sorted(os.listdir(events)):
    if "job.completed" in name and name.endswith(".json"):
        with open(os.path.join(events, name)) as f:
            paths.append(json.load(f).get("report_path"))
assert paths == [p1, p2, p3], f"delegated rounds must record {p1}, {p2}, {p3}; got {paths}"
PY
echo "PASS 1014-s3-delegated-later-rounds-name-snapshots"

# S1 (TOCTOU): completion_event must hash the bytes it snapshots, so the
# record's report_sha256 always equals the sha256 of the file it names even
# when report.md is rewritten while resolve waits on the events lock.
RND7_JOB="rnd-toctou"
RND7_ERR="$TMP/rnd7.err"
rnd_claim "$RND7_JOB"
rnd7_report="$(rnd_report "$RND7_JOB" report.md 'toctou round one')"
env ARBITER_INBOX_ROOT="$RND_JOBS" HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  "$WRK" 'done' "$RND7_JOB" --report "$rnd7_report" >/dev/null
python3 - "$RND_JOBS/$RND7_JOB/.wrk-events.lock" "$TMP/rnd7-lock-held" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1], "w")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").write("held")
time.sleep(5)
PY
rnd7_holder=$!
own "$rnd7_holder"
wait_until 10 test -f "$TMP/rnd7-lock-held" ||
  fail "rnd-toctou: the lock helper must take the events lock"
printf 'toctou round two\n' >"$rnd7_report"
env ARBITER_INBOX_ROOT="$RND_JOBS" HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  "$WRK" 'done' "$RND7_JOB" --report "$rnd7_report" >"$TMP/rnd7.out" 2>"$RND7_ERR" &
rnd7_done=$!
own "$rnd7_done"
sleep 1
printf 'toctou round three\n' >"$rnd7_report"
wait "$rnd7_holder"
rnd7_rc=0
wait "$rnd7_done" || rnd7_rc=$?
[[ "$rnd7_rc" -eq 0 ]] || fail "rnd-toctou: done must exit 0, got $rnd7_rc: $(cat "$RND7_ERR")"
python3 - "$RND_JOBS/$RND7_JOB/events" <<'PY'
import hashlib, json, os, sys
events = sys.argv[1]
recs = []
for name in sorted(os.listdir(events)):
    if "job.completed" in name and name.endswith(".json"):
        with open(os.path.join(events, name)) as f:
            recs.append(json.load(f))
assert len(recs) == 2, f"expected 2 completion records, got {len(recs)}"
rec = recs[-1]
actual = hashlib.sha256(open(rec["report_path"], "rb").read()).hexdigest()
assert actual == rec["report_sha256"], \
    f"record names {rec['report_path']} whose sha256 {actual} != report_sha256 {rec['report_sha256']}"
PY
echo "PASS 1014-s1-snapshot-bytes-match-record-digest"

# R18 completion sentinel: a report alone is never completion evidence. A
# worker still working past the watch window must not emit job.completed, and
# since hk 1888 the live pane is not job.lost either: the sentinel only leaves.
SENTINEL_REPORT="$TMP/sentinel-report.md"
printf 'sentinel final line\n' >"$SENTINEL_REPORT"
SENTINEL_INBOX="$TMP/sentinel-inbox"
set +e
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$SENTINEL_INBOX" \
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
if find "$SENTINEL_INBOX/sentinel-working/events" -name '*job.lost.json' -o -name '*job.revoked.json' | grep -q .; then
  echo "an expired watch window on a live pane must not write job.lost or job.revoked" >&2
  exit 1
fi
grep -q 'action=watch-expired elapsed=' "$SENTINEL_INBOX/sentinel-working/completion-sentinel.log"
echo "PASS r18-sentinel-requires-terminal-status"

# Automatic discovery must work on macOS too, and the observation key must be
# stable for an unchanged report but advance when that same report is updated.
SENTINEL_INBOX="$TMP/sentinel-dedupe-inbox"
env ARBITER_INBOX_ROOT="$SENTINEL_INBOX" "$ARBITER" claim \
  --job sentinel-idle --lane test-lane --agent-label test-label --t T1 >/dev/null
env ARBITER_INBOX_ROOT="$SENTINEL_INBOX" "$ARBITER" event --job sentinel-idle \
  --kind job.spawned --payload-json '{"owner_lane":"test-lane","label":"test-label","pane_id":"test:pane"}' >/dev/null
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$SENTINEL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-idle WRK_COMPLETION_TIMEOUT_S=20 WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel sentinel-idle lane worker test:pane "" >/dev/null 2>&1 &
sentinel_idle_pid=$!
own "$sentinel_idle_pid"
sleep 2
event_count_is "$SENTINEL_INBOX/sentinel-idle/events" job.completed 0 ||
  fail "a job with no report is not complete, whatever the pane status says (got $(event_count "$SENTINEL_INBOX/sentinel-idle/events" job.completed))"
cp "$SENTINEL_REPORT" "$SENTINEL_INBOX/sentinel-idle/report.md"
# the report must sit unchanged for one interval before it counts as final —
# the first sighting only logs action=pending.
wait_until 30 event_count_is "$SENTINEL_INBOX/sentinel-idle/events" job.completed 1 ||
  fail "an idle pane plus a settled report is exactly one job.completed (got $(event_count "$SENTINEL_INBOX/sentinel-idle/events" job.completed))"
# #770: the sentinel exits right after job.completed — a later report update
# can no longer mint a second completion, and the watcher must be gone.
wait_until 30 bash -c "! kill -0 $sentinel_idle_pid 2>/dev/null" ||
  fail "the completion sentinel must exit once job.completed lands"
printf 'updated report line\n' >>"$SENTINEL_INBOX/sentinel-idle/report.md"
sleep 2
event_count_is "$SENTINEL_INBOX/sentinel-idle/events" job.completed 1 ||
  fail "no sentinel remains after job.completed, so a report update writes no second record (got $(event_count "$SENTINEL_INBOX/sentinel-idle/events" job.completed))"
wait "$sentinel_idle_pid" 2>/dev/null || true
echo "PASS r18-sentinel-portable-discovery-and-dedupe"

# Both terminal statuses are accepted; `done` is tested separately so this is
# an explicit status-set contract rather than an idle-only implementation.
SENTINEL_INBOX="$TMP/sentinel-done-inbox"
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$SENTINEL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-done WRK_COMPLETION_TIMEOUT_S=20 WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel sentinel-done lane worker w:p1 "$SENTINEL_REPORT" >/dev/null 2>&1 &
sentinel_done_pid=$!
own "$sentinel_done_pid"
wait_until 30 event_count_is "$SENTINEL_INBOX/sentinel-done/events" job.completed 1 ||
  fail "a done pane plus a settled report is exactly one job.completed (got $(event_count "$SENTINEL_INBOX/sentinel-done/events" job.completed))"
tw_kill_tree "$sentinel_done_pid" 2>/dev/null || true
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
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$TRANSIENT_INBOX" \
  WRK_FIXTURE_GET_SEQUENCE="$TRANSIENT_SEQ" \
  WRK_COMPLETION_TIMEOUT_S=120 WRK_COMPLETION_INTERVAL_S=1 \
  WRK_SENTINEL_TRANSIENT_MAX=10 WRK_SENTINEL_LOST_GRACE=0 \
  "$WRK" sentinel sentinel-transient lane-a worker w1:p1 "$SENTINEL_REPORT" >/dev/null 2>&1 &
transient_pid=$!
own "$transient_pid"
TRANSIENT_EVENTS="$TRANSIENT_INBOX/sentinel-transient/events"
wait_until 30 event_count_is "$TRANSIENT_EVENTS" job.completed 1 ||
  fail "transient herdr failures below WRK_SENTINEL_TRANSIENT_MAX must still reach job.completed (got $(event_count "$TRANSIENT_EVENTS" job.completed))"
tw_kill_tree "$transient_pid" 2>/dev/null || true
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
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$GRACE_INBOX" \
  WRK_FIXTURE_GET_SEQUENCE="$GRACE_SEQ" \
  WRK_COMPLETION_TIMEOUT_S=300 WRK_COMPLETION_INTERVAL_S=1 \
  WRK_SENTINEL_TRANSIENT_MAX=3 WRK_SENTINEL_LOST_GRACE=120 \
  "$WRK" sentinel sentinel-grace lane-a worker w1:p1 "$GRACE_REPORT" >/dev/null 2>&1 &
grace_pid=$!
own "$grace_pid"
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
grace_lines="$(awk '/ status=/ { n++ } END { print n+0 }' "$grace_log")"
grace_calls="$(awk 'END{print NR}' "$GRACE_SEQ.calls")"
[[ "$grace_lines" -eq "$grace_calls" ]] ||
  fail "completion-sentinel.log must hold exactly one decision per observation: $grace_lines decisions for $grace_calls observations"
grep -q 'action=lost:herdr_unreachable' "$grace_log" ||
  fail "the decision log must name the lost reason it wrote (action=lost:herdr_unreachable)"
grep -q 'action=completed' "$grace_log" ||
  fail "the decision log must record the post-lost completion"
echo "PASS sentinel-lost-grace-still-completes"

# (b) 확정 소멸 코드는 즉시 lost 다 — 여기서만 재시도가 없다.
GONE_INBOX="$TMP/sentinel-gone-inbox"
GONE_SEQ="$TMP/sentinel-gone.seq"
printf '%s\n' not-found >"$GONE_SEQ"
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$GONE_INBOX" \
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
[[ "$(awk '/ status=/ { n++ } END { print n+0 }' "$gone_log")" -eq 1 ]] ||
  fail "one observation is one decision log entry"
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
  "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l fixture \
  --t T1 --job sentinel-env --owner lane-a >/dev/null
ENV_PIDFILE="$ENV_INBOX/sentinel-env/completion-sentinel.pid"
[[ -s "$ENV_PIDFILE" ]] || fail "spawn must start a completion sentinel once the job is registered"
wait_until 30 grep -q 'HERDR_SESSION=host-a' "$ENV_LOG" ||
  fail "the sentinel must query herdr with the session wrk pinned into it (HERDR_SESSION=host-a), saw: $(tr '\n' '|' <"$ENV_LOG")"
grep -q 'HERDR_SOCKET_PATH=/tmp/host-a.sock' "$ENV_LOG" ||
  fail "the sentinel must query herdr through the socket wrk pinned into it"
tw_kill_pidfile "$ENV_PIDFILE" 2>/dev/null || true
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
    "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l fixture \
    --t T1 --job "spawn-keep-$keep_case" --owner lane-a ${keep_args[@]+"${keep_args[@]}"} >/dev/null ||
    fail "#603: spawn ($keep_case) must succeed"
  tw_kill_pidfile "$keep_inbox/spawn-keep-$keep_case/completion-sentinel.pid" 2>/dev/null || true
done
python3 - "$TMP/spawn-keep-kept/spawn-keep-kept/events" "$TMP/spawn-keep-plain/spawn-keep-plain/events" <<'PY'
import glob, json, sys
def receipt(directory):
    paths = sorted(glob.glob(directory + "/*job.spawned.json"))
    assert len(paths) == 1, "exactly one job.spawned receipt, got %r" % paths
    return json.load(open(paths[0]))["payload"]
kept, plain = receipt(sys.argv[1]), receipt(sys.argv[2])
base = {"pane_id": "w:p1", "label": "fixture", "profile": "codex-luna", "workspace": "w", "tab_id": "w:t1",
        "task_id": 76801}
assert plain == base, "a spawn without --keep must write the unchanged receipt, got %r" % plain
assert kept == dict(base, keep=True), "--keep must record keep: true on the receipt, got %r" % kept
assert kept["keep"] is True, "the marker must be the JSON literal true"
PY
grep -q -- '--keep' <<<"$("$WRK" spawn --help)" || fail "#603: spawn --help must document --keep"
# bash 3.2 cannot `source <(...)`, so the two functions go through a file.
sed -n '/^wrk_option_token()/,/^}/p;/^spillover_hub_args()/,/^}/p' "$WRK" >"$TMP/spill-keep-funcs.sh"
spill_keep_err="$(bash -c '. "$1"; spillover_hub_args -m codex-luna -l fixture --keep' _ "$TMP/spill-keep-funcs.sh" 2>&1)" &&
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
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" XDG_DATA_HOME="$TMP/xdg-idem" \
  ARBITER_INBOX_ROOT="$IDEM_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-idle WRK_COMPLETION_TIMEOUT_S=30 WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel idem-race lane-a wrk-a w1:p1 "$IDEM_RACE_REPORT" >/dev/null 2>&1 &
idem_race_pid=$!
own "$idem_race_pid"
# #770: the sentinel sees the work-terminal record on its first watch and
# exits — it never mints a second completion for an already-done job.
wait_until 30 sentinel_log_has "$IDEM_INBOX/idem-race/completion-sentinel.log" 'action=watch-exit' ||
  fail "a sentinel started after job.completed must notice the terminal and leave"
sleep 1
event_count_is "$IDEM_INBOX/idem-race/events" job.completed 1 ||
  fail "a sentinel observing an already-completed job must not write a second record (got $(event_count "$IDEM_INBOX/idem-race/events" job.completed))"
wait_until 15 bash -c "! kill -0 $idem_race_pid 2>/dev/null" ||
  fail "the sentinel must exit once it sees the job already ended"
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
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" XDG_DATA_HOME="$TMP/xdg-idem" \
  ARBITER_INBOX_ROOT="$IDEM_PARTIAL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-idle WRK_COMPLETION_TIMEOUT_S=60 WRK_COMPLETION_INTERVAL_S=3 \
  "$WRK" sentinel idem-partial lane-a wrk-a w1:p1 "$IDEM_PARTIAL_REPORT" >/dev/null 2>&1 &
idem_partial_pid=$!
own "$idem_partial_pid"
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
tw_kill_tree "$idem_partial_pid" 2>/dev/null || true
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

# hk1823: explicit job selection must bound both dry-run output and the later
# close set. Use one shared lane with three exact-name lookalikes.
printf 'idle\n%.0s' {1..100} >"$TMP/reap-job-idle-sequence"
export WRK_FIXTURE_GET_SEQUENCE="$TMP/reap-job-idle-sequence"
reap_job b1 w1:p1 w1:t1 lane-a job.completed
reap_job b10 w1:p2 w1:t2 lane-a job.completed
reap_job xb1 w1:p4 w1:t4 lane-a job.completed
selected_out="$(reap_run --lane lane-a --job b1)"
grep -q '^would-close job=b1 ' <<<"$selected_out" || fail "--job b1 must select the exact b1 job: $selected_out"
for unselected in b10 xb1; do
  grep -q "$unselected" <<<"$selected_out" && fail "--job b1 must omit $unselected entirely: $selected_out"
done
multi_out="$(reap_run --lane lane-a --job b10 --job xb1)"
grep -q '^would-close job=b10 ' <<<"$multi_out" || fail "repeated --job must retain its first id: $multi_out"
grep -q '^\(would-close\|skip\) job=xb1 ' <<<"$multi_out" || fail "repeated --job must retain its second id: $multi_out"
comma_out="$(reap_run --lane lane-a --job b10,xb1)"
if ! grep -q 'job=b10 ' <<<"$comma_out" || ! grep -q 'job=xb1 ' <<<"$comma_out"; then
  fail "comma-separated --job must select both named jobs: $comma_out"
fi
: >"$REAP_LOG"
selected_apply="$(reap_run --lane lane-a --job b1 --apply)"
grep -q '^closed job=b1 ' <<<"$selected_apply" || fail "--apply must close selected b1: $selected_apply"
[[ "$(grep -c '^tab close ' "$REAP_LOG")" -eq 1 ]] || fail "--job b1 must close exactly one tab: $(cat "$REAP_LOG")"
grep -q '^tab close w1:t1$' "$REAP_LOG" || fail "selected job's tab was not closed: $(cat "$REAP_LOG")"
for unselected in b10 xb1; do
  [[ "$(event_count "$REAP_INBOX/$unselected/events" job.reaped)" -eq 0 ]] || fail "unnamed job $unselected was reaped"
done
echo "PASS reap-job-filter-exact-and-apply"

if invalid_job_out="$(reap_run --lane lane-a --job '' 2>&1)"; then
  fail "an empty --job value must fail: $invalid_job_out"
fi
grep -q -- '--job requires a non-empty value' <<<"$invalid_job_out" || fail "empty --job error must be clear: $invalid_job_out"
if invalid_job_out="$(reap_run --lane lane-a --job ,b1 2>&1)"; then
  fail "an empty id in --job list must fail: $invalid_job_out"
fi
grep -q -- '--job contains an empty job id' <<<"$invalid_job_out" || fail "empty list item error must be clear: $invalid_job_out"

# Recheck pane status during --apply. A named job that became working since
# the dry run is explicitly reported as no longer a candidate and stays open.
printf 'idle\nworking\n' >"$TMP/reap-job-status-sequence"
rm -f "$TMP/reap-job-status-sequence.calls"
reap_job reap-changes w1:p1 w1:t1 lane-a job.completed
WRK_FIXTURE_GET_SEQUENCE="$TMP/reap-job-status-sequence" reap_run --lane lane-a --job reap-changes >/dev/null
: >"$REAP_LOG"
changed_out="$(WRK_FIXTURE_GET_SEQUENCE="$TMP/reap-job-status-sequence" reap_run --lane lane-a --job reap-changes --apply)"
grep -q '^skip job=reap-changes reason=not-candidate$' <<<"$changed_out" || fail "a selected job that became working must be not-candidate: $changed_out"
! grep -q '^tab close ' "$REAP_LOG" || fail "a job that became working must remain open: $(cat "$REAP_LOG")"
echo "PASS reap-job-apply-time-candidate-change"

# hk1823 M1: dropping only the apply-path selector must close the unnamed
# control job, which the real close log detects.
reap_job reap-filter-target w1:p1 w1:t1 reap-filter-lane job.completed
reap_job reap-filter-extra w1:p2 w1:t2 reap-filter-lane job.completed
M1823_APPLY="$TMP/wrk-reap-no-apply-filter"
# shellcheck disable=SC2016 # sed source is the literal wrk apply guard.
sed 's/if ! reap_job_selected "$job_filter" "$job"; then continue; fi # hk1823-apply-job-filter/: # hk1823 mutant drops apply filter/' \
  "$WRK" >"$M1823_APPLY"
chmod +x "$M1823_APPLY"
grep -qF 'hk1823 mutant drops apply filter' "$M1823_APPLY" || fail "hk1823 M1 did not mutate the apply call site"
: >"$REAP_LOG"
saved_wrk="$WRK"
WRK="$M1823_APPLY"
m1_out="$(reap_run --lane reap-filter-lane --job reap-filter-target --apply)"
WRK="$saved_wrk"
grep -q '^closed job=reap-filter-extra ' <<<"$m1_out" || fail "hk1823 M1 survived: dropping the apply filter did not close the unnamed job: $m1_out / $(cat "$REAP_LOG")"
echo "PASS hk1823 M1: dropping apply-only filter goes RED at the close-log assertion"

# hk1823 M2: a prefix comparison admits b10 when only b1 was named.
M1823_PREFIX="$TMP/wrk-reap-prefix-match"
# shellcheck disable=SC2016 # sed source is the literal selector comparison.
sed 's/\[\[ "$candidate" == "$job" \]\]/[[ "$job" == "$candidate"* ]]/' "$saved_wrk" >"$M1823_PREFIX"
chmod +x "$M1823_PREFIX"
# shellcheck disable=SC2016 # the grep pattern is the literal mutant.
grep -qF '[[ "$job" == "$candidate"* ]]' "$M1823_PREFIX" || fail "hk1823 M2 did not mutate the selector comparison"
WRK="$M1823_PREFIX"
m2_out="$(reap_run --lane lane-a --job b1)"
WRK="$saved_wrk"
grep -q 'job=b10 ' <<<"$m2_out" || fail "hk1823 M2 survived: prefix mutant did not admit b10: $m2_out"
echo "PASS hk1823 M2: prefix-match mutant goes RED on exact-id output assertion"

# hk1823 M3: ignoring the second selector must omit xb1 from the repeated form.
M1823_SECOND="$TMP/wrk-reap-first-job-only"
# shellcheck disable=SC2016 # sed source is the literal --job parser append.
sed 's/job_filter+="$job_value"/[[ -n "$job_filter" ]] || job_filter="$job_value"; :/' "$saved_wrk" >"$M1823_SECOND"
chmod +x "$M1823_SECOND"
# shellcheck disable=SC2016 # the grep pattern is the literal mutant.
grep -qF '[[ -n "$job_filter" ]] || job_filter="$job_value"; :' "$M1823_SECOND" || fail "hk1823 M3 did not mutate repeated --job parsing"
WRK="$M1823_SECOND"
m3_out="$(reap_run --lane lane-a --job b10 --job xb1)"
WRK="$saved_wrk"
if grep -q '^would-close job=xb1 ' <<<"$m3_out"; then fail "hk1823 M3 survived: second --job still appeared: $m3_out"; fi
echo "PASS hk1823 M3: ignored-second-job mutant goes RED on repeated-id assertion"

# No selector preserves the existing byte output contract.
baseline_out="$(reap_run --lane lane-a)"
next_baseline_out="$(reap_run --lane lane-a)"
baseline_out="$(sed -E 's/ age=[0-9]+s$/ age=AGE/' <<<"$baseline_out")"
next_baseline_out="$(sed -E 's/ age=[0-9]+s$/ age=AGE/' <<<"$next_baseline_out")"
[[ "$next_baseline_out" == "$baseline_out" ]] || fail "reap output changed without --job"
echo "PASS reap-job-filter-default-output"



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
seed_join_round "$J499_INBOX" j499-builder
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
[[ "$(event_count "$J499_INBOX/j499-worker/events" job.completed)" == 1 ]] ||
  fail "delegated done must leave exactly one record (the delegated binary's own)"
grep -l '"via": "fixture-job-done"' "$J499_INBOX/j499-worker/events"/*-job.completed.json >/dev/null ||
  fail "the delegated record must be panewire's own write, not wrk's"
[[ "$(event_count "$J499_INBOX/j499-builder/events" job.escalate)" == 0 ]] ||
  fail "delegated escalate must not also write wrk's record"
[[ "$(event_count "$J499_INBOX/j499-builder/events" job.joined)" == 0 ]] ||
  fail "delegated joined must not also write wrk's record"
[[ "$(j499_calls "$TMP/j499-present-emit.log")" == 0 ]] ||
  fail "delegated commands must not also run wrk's emit"
# A failing delegated call falls back to wrk's own write path (#770 tester
# BLOCKER 1): the terminal record must not ride down with panewire's rc.
# Fresh job — j499-worker already holds the delegated round-1 record, so an
# identical re-done would be suppressed before delegation ever runs (#1014).
j499_claim j499-rc-worker
rc=0
out="$(WRK_PANEWIRE_JOB_RC=7 j499_run 1 present rc 'done' j499-rc-worker --report "$J499_REPORT" 2>&1)" || rc=$?
[[ "$rc" == 0 ]] || fail "a failing delegated done must fall back to wrk's own path, got rc=$rc"
printf '%s\n' "$out" | grep -q 'delegation failed' ||
  fail "the fallback must warn on stderr: $out"
[[ "$(event_count "$J499_INBOX/j499-rc-worker/events" job.completed)" == 1 &&
   "$(j499_calls "$TMP/j499-rc-emit.log")" == 1 ]] ||
  fail "the fallback must write and emit the record exactly once, locally"
# Help stays wrk's own even when panewire has the command.
j499_run 1 present help escalate --help | grep -q '^Usage: wrk escalate JOB' ||
  fail "escalate --help must stay local"
[[ "$(j499_lines "$TMP/j499-help-job.log")" == 0 ]] || fail "escalate --help must not delegate"
echo "PASS j499-delegates-once-to-panewire-job"

# absent / garbage / forced off: wrk's own path, exactly one record and
# one emit per command, zero delegated calls.
for mode in absent garbage off; do
  job_mode="$mode" delegate=1
  if [[ "$mode" == off ]]; then job_mode=present delegate=0; fi
  worker="j499-$mode-worker" builder="j499-$mode-builder"
  j499_claim "$worker"
  j499_claim "$builder" --role builder --parent-lane parent-a
  seed_join_round "$J499_INBOX" "$builder"
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

# hang: the fixture sleeps inside `panewire job probe`, so the probe is killed
# by WRK_JOB_DELEGATE_TIMEOUT_S and the invocation marks panewire wedged. The
# local path still writes exactly one record per command, but emit must not
# re-enter the wedged binary: zero emit calls, one delegate_timeout marker
# per skipped emit, and no delegated job call ever reaches the fixture log.
mode=hang
worker="j499-$mode-worker" builder="j499-$mode-builder"
j499_claim "$worker"
j499_claim "$builder" --role builder --parent-lane parent-a
seed_join_round "$J499_INBOX" "$builder"
out="$(WRK_JOB_DELEGATE_TIMEOUT_S=2 j499_run 1 hang hang 'done' "$worker" --report "$J499_REPORT")"
[[ "$out" == "OK job=$worker report=$J499_REPORT" ]] || fail "hang: done output changed: $out"
out="$(WRK_JOB_DELEGATE_TIMEOUT_S=2 j499_run 1 hang hang escalate "$builder" --question 'fallback question')"
[[ "$out" == "OK job=$builder owner_lane=lane-a kind=job.escalate" ]] || fail "hang: escalate output changed: $out"
out="$(WRK_JOB_DELEGATE_TIMEOUT_S=2 j499_run 1 hang hang joined "$builder" --pr https://example.invalid/pr/8 \
  --head f00d --report "$J499_REPORT")"
[[ "$out" == "OK job=$builder owner_lane=lane-a kind=job.joined pr=https://example.invalid/pr/8 head=f00d report=$J499_REPORT" ]] ||
  fail "hang: joined output changed: $out"
[[ "$(event_count "$J499_INBOX/$worker/events" job.completed)" == 1 ]] || fail "hang: done must write exactly one record"
[[ "$(event_count "$J499_INBOX/$builder/events" job.escalate)" == 1 ]] || fail "hang: escalate must write exactly one record"
[[ "$(event_count "$J499_INBOX/$builder/events" job.joined)" == 1 ]] || fail "hang: joined must write exactly one record"
[[ "$(j499_calls "$TMP/j499-hang-emit.log")" == 0 ]] || fail "hang: emit must not re-enter the wedged panewire"
[[ "$(j499_lines "$TMP/j499-hang-job.log")" == 0 ]] || fail "hang: nothing may be delegated past the hung probe"
grep -Eq '^[0-9TZ:-]+ kind=job.completed rc=delegate_timeout$' "$J499_INBOX/$worker/emit-failures.log" ||
  fail "hang: done must mark the skipped emit as delegate_timeout"
[[ "$(grep -c 'rc=delegate_timeout$' "$J499_INBOX/$builder/emit-failures.log")" == 2 ]] ||
  fail "hang: escalate+joined must each mark a delegate_timeout"
echo "PASS j499-hang-wedges-panewire-and-skips-emit"

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

# ---------------------------------------------------------------------------
# wrk heavy — per-host serialization lock for >1min local runs (#721)
# ---------------------------------------------------------------------------
HEAVY_LOCK="$TMP/heavy.lock"
HEAVY_LOAD="$TMP/heavy-load"
printf '0\n' >"$HEAVY_LOAD"
export WRK_HEAVY_LOCK="$HEAVY_LOCK" WRK_HEAVY_LOAD_FILE="$HEAVY_LOAD" \
  WRK_HEAVY_LOG="$TMP/heavy.log"

# Capture before grep -q. A pipe closes on the first hit, and under pipefail
# the status writer's later lines (waiters none) become a SIGPIPE failure
# even when the matched line is present. Same shape as devin_trust_has.
heavy_status_has_waiter() {
  local out
  out="$("$WRK" heavy status)" || return 1
  grep -q 'waiter pid=' <<<"$out"
}
pid_dead() { ! kill -0 "$1" 2>/dev/null; }
heavy_dead() { wait_until 10 pid_dead "$1"; }
heavy_touch() { printf 'touch "%s"\n' "$1" >"$2"; }

# Small command scripts stand in for real suites (sleep marks the "hold").
# held-start is touched only after the holder has the lock and its command
# has started — waiting on it removes the launch race (no sleep-N guessing).
printf 'touch "%s"\nsleep 2\ntouch "%s"\n' "$TMP/heavy-held-start" "$TMP/heavy-holder-done" >"$TMP/holder2.sh"
printf 'touch "%s"\nsleep 6\n' "$TMP/heavy-stat-held" >"$TMP/holder6.sh"
printf 'touch "%s"\nsleep 8\n' "$TMP/heavy-cap-held" >"$TMP/holder8.sh"
printf 'sleep 60 &\necho $! > "%s"\n' "$TMP/heavy-orphan.pid" >"$TMP/orphan.sh"
printf 'ps -o nice= -p $$ | tr -d " " > "%s"\n' "$TMP/heavy-nice.val" >"$TMP/nice.sh"
heavy_touch "$TMP/heavy-cap-ran" "$TMP/touch-cap.sh"
heavy_touch "$TMP/heavy-load-ran" "$TMP/touch-load.sh"
heavy_touch "$TMP/heavy-load-ran2" "$TMP/touch-load2.sh"
heavy_touch "$TMP/heavy-load-ran3" "$TMP/touch-load3.sh"

expect_exit 0 "$WRK" heavy --help
expect_exit 2 "$WRK" heavy
expect_exit 2 "$WRK" heavy no-double-dash
expect_exit 2 "$WRK" heavy --
expect_exit 2 "$WRK" heavy status extra
expect_exit 0 "$WRK" heavy status
heavy_out="$("$WRK" heavy status)" || fail "free lock status failed: $heavy_out"
grep -q 'holder none' <<<"$heavy_out" ||
  fail "free lock must report 'holder none': $heavy_out"
"$WRK" heavy -- true || fail "simple run must succeed"
expect_exit 1 "$WRK" heavy -- false
expect_exit 127 "$WRK" heavy -- definitely-not-a-real-binary-721

# the default lock path resolves to the per-host /tmp file — asserted
# through `wrk heavy status` output only. Never rm the real lock file or
# its .waiters dir: other sessions serialize on that inode, and unlinking
# it mid-hold splits the host queue (r2 finding N1).
default_lock="$(python3 -c 'import socket; print("/tmp/wrk-heavy-%s.lock" % socket.gethostname())')"
default_out="$(env -u WRK_HEAVY_LOCK "$WRK" heavy status)" ||
  fail "default lock status failed: $default_out"
grep -qF "lock $default_lock" <<<"$default_out" ||
  fail "default lock path not used: $default_out"

# the command runs under nice -n 10 — asserted relative to this suite's own
# nice value so the check still has teeth when the suite itself is already
# niced by an outer wrk heavy (dogfood run). The probe gates hosts where
# nice is inert (some CI macOS images report 0 for a niced child).
suite_nice="$(ps -o nice= -p "$$" | tr -d ' ')"
nice_probe="$(nice -n 10 sh -c 'ps -o nice= -p $$' 2>/dev/null | tr -d ' ')"
nice_ceiling="$(nice -n 40 sh -c 'ps -o nice= -p $$' 2>/dev/null | tr -d ' ')"
if [[ "$suite_nice" =~ ^[0-9]+$ && "$nice_probe" =~ ^[0-9]+$ &&
      "$nice_ceiling" =~ ^[0-9]+$ && "$nice_probe" -gt "$suite_nice" ]]; then
  expected=$(( suite_nice + 10 ))
  (( expected > nice_ceiling )) && expected="$nice_ceiling"
  "$WRK" heavy -- bash "$TMP/nice.sh" || fail "nice check run failed"
  nice_val=""
  read -r nice_val <"$TMP/heavy-nice.val" || true
  [[ "$nice_val" =~ ^[0-9]+$ && "$nice_val" -ge "$expected" ]] ||
    fail "command not under nice -n 10 (suite=$suite_nice got=$nice_val want>=$expected)"
else
  echo "SKIP nice assertion: nice(1) has no observable effect here"
fi

# a released lock leaves no stale holder record behind.
[[ ! -s "$HEAVY_LOCK" ]] || fail "released lock file still carries holder info"
echo "PASS heavy-basic-contract"

# holder + waiter: the waiter's command runs only after the holder releases.
"$WRK" heavy -- bash "$TMP/holder2.sh" &
holder_job=$!
own "$holder_job"
wait_until 10 test -f "$TMP/heavy-held-start" || fail "holder never took the lock"
"$WRK" heavy -- test -f "$TMP/heavy-holder-done" ||
  fail "waiter ran before the holder released the lock"
wait "$holder_job" || fail "holder run failed"
echo "PASS heavy-serializes-holder-and-waiter"

# status shows the holder and the queued waiters — including a waiter whose
# own command text contains a pid= token (must not be mistaken for dead).
"$WRK" heavy -- bash "$TMP/holder6.sh" &
holder_job=$!
own "$holder_job"
wait_until 10 test -f "$TMP/heavy-stat-held" || fail "status holder never started"
out="$("$WRK" heavy status)"
grep -q 'holder pid=' <<<"$out" || fail "status must show the holder: $out"
grep -q 'cmd=' <<<"$out" || fail "status must show the holder command: $out"
"$WRK" heavy -- env pid=999999 true &
waiter_job=$!
own "$waiter_job"
wait_until 10 heavy_status_has_waiter || fail "status never showed the waiter"
wait "$waiter_job" || fail "queued waiter never ran"
wait "$holder_job" || fail "holder run failed"
out="$("$WRK" heavy status)"
grep -q 'holder none' <<<"$out" || fail "status must show a free lock after release: $out"
echo "PASS heavy-status-shows-holder-and-waiters"

# a nested wrk heavy on the same lock must not deadlock against itself — it
# runs the inner command directly (the outer already serializes the host).
rc=0
out="$(WRK_HEAVY_WAIT_CAP=5 "$WRK" heavy -- "$WRK" heavy -- true 2>&1)" || rc=$?
[[ "$rc" == 0 ]] || fail "nested wrk heavy must not block to the cap, got rc=$rc"
grep -q 'already holding' <<<"$out" || fail "nested run must say it skipped the lock: $out"
echo "PASS heavy-nested-run-does-not-deadlock"

# a stale or forged WRK_HEAVY_HELD must not bypass the lock — bypass needs a
# pid that is alive AND recorded as the holder in the lock file (an orphan
# that outlives its holder still carries the env var).
out="$(WRK_HEAVY_HELD="$HEAVY_LOCK:999999" "$WRK" heavy -- true 2>&1)"
if grep -q 'already holding' <<<"$out"; then
  fail "dead-pid WRK_HEAVY_HELD bypassed the lock"
fi
out="$(WRK_HEAVY_HELD="$HEAVY_LOCK:$$" "$WRK" heavy -- true 2>&1)"
if grep -q 'already holding' <<<"$out"; then
  fail "live non-holder WRK_HEAVY_HELD bypassed the lock"
fi
echo "PASS heavy-held-env-needs-live-holder"

# a command killed by a signal maps to 128+sig (TERM → 143).
expect_exit 143 "$WRK" heavy -- sh -c 'kill -TERM $$'
echo "PASS heavy-signal-exit-mapped"

# wait cap: a waiter gives up with rc 75 once the cap is exceeded, without
# running its command.
"$WRK" heavy -- bash "$TMP/holder8.sh" &
holder_job=$!
own "$holder_job"
wait_until 10 test -f "$TMP/heavy-cap-held" || fail "cap holder never started"
rc=0
out="$(WRK_HEAVY_WAIT_CAP=3 "$WRK" heavy -- bash "$TMP/touch-cap.sh" 2>&1)" || rc=$?
[[ "$rc" == 75 ]] || fail "wait cap must exit 75, got rc=$rc"
grep -q 'wait cap' <<<"$out" || fail "cap expiry must say why: $out"
[[ ! -e "$TMP/heavy-cap-ran" ]] || fail "command ran despite the wait cap"
wait "$holder_job" || fail "cap holder run failed"
echo "PASS heavy-wait-cap-exits-75"

# the slot fd is deliberately inherited (nested-proof): an orphaned child
# keeps the slot while it lives — resource accounting tracks the work tree,
# not the wrapper — and releases it the moment the orphan dies.
"$WRK" heavy -- bash "$TMP/orphan.sh" || fail "orphan-spawning run failed"
read -r orphan_pid <"$TMP/heavy-orphan.pid"
own "$orphan_pid"
kill -0 "$orphan_pid" 2>/dev/null || fail "orphan did not survive its parent"
rc=0
out="$(WRK_HEAVY_WAIT_CAP=3 "$WRK" heavy -- true 2>&1)" || rc=$?
[[ "$rc" == 75 ]] ||
  fail "slot must stay held while the orphan lives (rc=$rc): $out"
kill "$orphan_pid" 2>/dev/null || true
heavy_dead "$orphan_pid" || fail "orphan sleep did not die"
WRK_HEAVY_WAIT_CAP=5 "$WRK" heavy -- true ||
  fail "slot not reclaimed after the whole holder tree died"
echo "PASS heavy-orphan-slot-dies-with-tree"

# load gate: load5/ncpu >= 1.0 blocks the start and is bounded by the same cap.
# The boundary is exact: a ratio of precisely 1.0 still blocks (the gate is
# "wait while >= 1.0", not ">").
printf '9.9\n' >"$HEAVY_LOAD"
rc=0
out="$(WRK_HEAVY_WAIT_CAP=3 "$WRK" heavy -- bash "$TMP/touch-load.sh" 2>&1)" || rc=$?
[[ "$rc" == 75 ]] || fail "load gate must exit 75 at the cap, got rc=$rc"
grep -q 'load5/ncpu' <<<"$out" || fail "load-gate expiry must say why: $out"
[[ ! -e "$TMP/heavy-load-ran" ]] || fail "command ran despite the load gate"
printf '1.0\n' >"$HEAVY_LOAD"
rc=0
out="$(WRK_HEAVY_WAIT_CAP=3 "$WRK" heavy -- bash "$TMP/touch-load3.sh" 2>&1)" || rc=$?
[[ "$rc" == 75 ]] || fail "load ratio 1.0 must still block, got rc=$rc"
[[ ! -e "$TMP/heavy-load-ran3" ]] || fail "command ran at the 1.0 boundary"
printf '9.9\n' >"$HEAVY_LOAD"
"$WRK" heavy -- bash "$TMP/touch-load2.sh" &
waiter_job=$!
own "$waiter_job"
sleep 2
printf '0\n' >"$HEAVY_LOAD"
wait "$waiter_job" || fail "run did not start after the load gate opened"
[[ -e "$TMP/heavy-load-ran2" ]] || fail "load-gated run never executed"
echo "PASS heavy-load-gate-bounds-the-start"

# ── hk 1750: job event order must not depend on two writers' numbering ─────
# The fixture copies the measured b1729-luna layout: arbiter envelopes carry
# created_at, wrk records carry no time field, and the respawn (00009) sorts
# before the terminal (00011) by name. mtimes are the measured event times, so
# a name-ordered reader sees a terminal last and a time-ordered reader does not.
ORDER_INBOX="$TMP/order-inbox"
ORDER_LIB="$TMP/order-wrk-lib"
python3 - "$WRK" "$ORDER_LIB" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(text.rsplit('case "${1:-}" in', 1)[0])
PY

order_fixture() {
  # NAME [--no-respawn] — write the b1729-luna event layout under ORDER_INBOX.
  local name="$1" variant="${2:-}"
  local dir="$ORDER_INBOX/$name/events"
  mkdir -p "$dir"
  python3 - "$dir" "$name" "$variant" <<'PY'
import datetime, json, os, sys
directory, job, variant = sys.argv[1:]
# The fixture herdr derives a pane's tab as w1:t<rest>; the no-respawn variant
# must reach the pane probe as a closable single-pane tab, so it uses w1:p1.
pane, tab = ("w1:p1", "w1:t1") if variant == "--no-respawn" else ("w1:pJK", "w1:t1")
rows = [
    ("00001-job.claim", "job.claim", "2026-10-20T11:34:00+09:00", None,
     {"owner_lane": "w1", "label": "luna", "pane_id": pane, "task_id": 1729}),
    ("00004-job.spawned", "job.spawned", "2026-10-20T11:34:30+09:00", None,
     {"owner_lane": "w1", "label": "luna", "pane_id": pane, "tab_id": tab}),
    ("00005-job.escalate", "job.escalate", None, "2026-10-20T13:15:00+09:00",
     {"owner_lane": "w1", "label": "luna"}),
    ("00009-job.escalate", "job.escalate", None, "2026-10-20T15:58:00+09:00",
     {"owner_lane": "w1", "label": "luna"}),
    ("00010-job.verdict", "job.verdict", None, "2026-10-20T16:26:14+09:00",
     {"owner_lane": "w1", "label": "luna", "verdict": "PASS", "head": "a" * 40}),
    ("00011-job.completed", "job.completed", None, "2026-10-20T16:26:27+09:00",
     {"owner_lane": "w1", "label": "luna", "pane_id": pane}),
    ("00005-quota_pool.release", "quota_pool.release", "2026-10-20T16:26:27+09:00", None,
     {"owner_lane": "w1"}),
]
if variant != "--no-respawn":
    rows += [
        ("00006-job.reclaim", "job.reclaim", "2026-10-20T16:29:44+09:00", None,
         {"owner_lane": "w1", "label": "luna", "pane_id": "w1:pJS", "task_id": 1729}),
        ("00007-quota_pool.record", "quota_pool.record", "2026-10-20T16:29:45+09:00", None,
         {"owner_lane": "w1"}),
        ("00008-job.task_link", "job.task_link", "2026-10-20T16:30:08+09:00", None,
         {"owner_lane": "w1"}),
        ("00009-job.spawned", "job.spawned", "2026-10-20T16:30:08+09:00", None,
         {"owner_lane": "w1", "label": "luna", "pane_id": "w1:pJS", "tab_id": "w1:t9"}),
    ]
for name, kind, created, mtime, payload in rows:
    doc = {"kind": kind, "job_id": job, "payload": payload, "epoch": 1}
    if created:
        doc["created_at"] = created
    path = os.path.join(directory, name + ".json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle)
    when = datetime.datetime.fromisoformat(created or mtime).timestamp()
    os.utime(path, (when, when))
PY
}

order_scan() {
  # NAME — job_events_scan through the sourced wrk library.
  # shellcheck disable=SC2016 # $1..$3 are the child shell's argv
  env ARBITER_INBOX_ROOT="$ORDER_INBOX" \
    bash -c 'set -euo pipefail; . "$1"; job_events_scan "$2/$3/events"' _ \
    "$ORDER_LIB" "$ORDER_INBOX" "$1"
}

order_reap() {
  # OUT — dry-run reap over ORDER_INBOX with the fixture herdr.
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$ORDER_INBOX" WRK_FIXTURE_SCENARIO=reap \
    "$WRK" reap --lane w1 --grace 0 >"$1" 2>"$1.err"
}

order_fixture b1729-luna
order_reap "$TMP/order-reap.out" ||
  fail "reap over the b1729 fixture failed: $(cat "$TMP/order-reap.out.err")"
grep -qx 'skip job=b1729-luna reason=reclaimed-after-terminal' "$TMP/order-reap.out" ||
  fail "b1729-luna must be skipped as reclaimed-after-terminal: $(cat "$TMP/order-reap.out")"
if grep -q '^would-close job=b1729-luna ' "$TMP/order-reap.out"; then
  fail "a job respawned after its terminal is never a reap candidate"
fi
scan="$(order_scan b1729-luna)"
[[ "$(cut -f2 <<<"$scan")" == 0 ]] ||
  fail "job_events_scan must report ended 0 for b1729-luna: $scan"
[[ "$(cut -f4 <<<"$scan")" == "-" ]] ||
  fail "job_events_scan must report no terminal kind for b1729-luna: $scan"
[[ "$(cut -f10 <<<"$scan")" == "w1:pJS" ]] ||
  fail "job_events_scan must take the newest spawned pane: $scan"
echo "PASS hk1750-reap-skips-reclaimed-after-terminal"

order_fixture b1729-nospawn --no-respawn
order_reap "$TMP/order-reap2.out" ||
  fail "reap over the no-respawn fixture failed: $(cat "$TMP/order-reap2.out.err")"
grep -q '^would-close job=b1729-nospawn ' "$TMP/order-reap2.out" ||
  fail "without the respawn the completed job stays a candidate: $(cat "$TMP/order-reap2.out")"
scan="$(order_scan b1729-nospawn)"
[[ "$(cut -f2 <<<"$scan")" == 1 ]] ||
  fail "job_events_scan must report ended 1 without the respawn: $scan"
echo "PASS hk1750-completed-without-respawn-stays-a-candidate"

# hk 1770: job.recovered closes a loss episode. It is not a terminal and not a
# revive, so a finished job stays finished and a live job stays live.
[[ "$(grep -c 'NEUTRAL = {"job.lost", "job.recovered"}' "$WRK")" -eq 4 ]] ||
  fail "job.lost and job.recovered must be on the neutral allowlist of all four readers"
[[ "$(grep -c 'neutral event kind is also terminal or revive' "$WRK")" -eq 4 ]] ||
  fail "each neutral allowlist must reject a kind that is also terminal or revive"
RECOV_INBOX="$TMP/recovered-inbox"
python3 - "$RECOV_INBOX" <<'PY'
import json, os, sys
root = sys.argv[1]

def write(job, name, doc):
    directory = os.path.join(root, job, "events")
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
        json.dump(doc, handle)
        handle.write("\n")

write("recov-ended", "00001-job.claim.json",
      {"kind": "job.claim", "at": "2020-01-01T00:00:00Z",
       "payload": {"owner_lane": "w1", "label": "lbl", "role": "worker"}})
write("recov-ended", "00002-job.spawned.json",
      {"kind": "job.spawned", "at": "2020-01-01T00:00:01Z",
       "payload": {"pane_id": "w1:p1", "tab_id": "w1:t1"}})
write("recov-ended", "00003-job.completed.json",
      {"kind": "job.completed", "at": "2020-01-02T00:00:00Z",
       "payload": {"owner_lane": "w1", "pane_id": "w1:p1"}})
write("recov-ended", "00004-job.recovered.json",
      {"kind": "job.recovered", "at": "2020-06-01T00:00:00Z",
       "job_id": "recov-ended", "owner_lane": "w1", "reason": "agent_not_found",
       "lost_duration_s": 3})
write("recov-live", "00001-job.claim.json",
      {"kind": "job.claim", "at": "2020-01-01T00:00:00Z",
       "payload": {"owner_lane": "w1", "label": "lbl"}})
write("recov-live", "00002-job.spawned.json",
      {"kind": "job.spawned", "at": "2020-01-01T00:00:01Z",
       "payload": {"pane_id": "w1:p3", "tab_id": "w1:t3"}})
write("recov-live", "00003-job.lost.json",
      {"kind": "job.lost", "at": "2020-01-01T00:01:00Z", "reason": "agent_not_found"})
write("recov-live", "00004-job.recovered.json",
      {"kind": "job.recovered", "at": "2020-01-01T00:02:00Z",
       "reason": "agent_not_found", "lost_duration_s": 60})
PY
# shellcheck disable=SC2016 # $1..$3 are the child shell's argv
recov_scan() {
  env ARBITER_INBOX_ROOT="$RECOV_INBOX" \
    bash -c 'set -euo pipefail; . "$1"; job_events_scan "$2/$3/events"' _ \
    "$ORDER_LIB" "$RECOV_INBOX" "$1"
}
scan="$(recov_scan recov-ended)"
[[ "$(cut -f2 <<<"$scan")" == 1 ]] ||
  fail "job.recovered after completed must stay ended: $scan"
[[ "$(cut -f4 <<<"$scan")" == job.completed ]] ||
  fail "job.recovered must not replace the terminal kind: $scan"
[[ "$(cut -f6 <<<"$scan")" == job.recovered ]] ||
  fail "job.recovered may be the newest kind without ending or reviving: $scan"
scan="$(recov_scan recov-live)"
[[ "$(cut -f2 <<<"$scan")" == 0 ]] ||
  fail "claim, lost, and recovered with no terminal must stay not ended: $scan"
[[ "$(cut -f4 <<<"$scan")" == "-" ]] ||
  fail "job.recovered must not become a terminal kind: $scan"
[[ "$(cut -f6 <<<"$scan")" == job.recovered ]] ||
  fail "the live job's newest kind is job.recovered: $scan"
recov_reap="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$RECOV_INBOX" \
  WRK_FIXTURE_SCENARIO=reap "$WRK" reap --lane w1 --grace 0 2>&1)" ||
  fail "reap over recovered fixtures failed: $recov_reap"
grep -q '^would-close job=recov-ended ' <<<"$recov_reap" ||
  fail "completed then recovered stays a reap candidate: $recov_reap"
if grep -q 'job=recov-live' <<<"$recov_reap"; then
  fail "lost plus recovered with no terminal is not a reap candidate: $recov_reap"
fi
# shellcheck disable=SC2016 # $1 and $2 are the child shell's argv
recov_end="$(env ARBITER_INBOX_ROOT="$RECOV_INBOX" \
  bash -c 'set -euo pipefail; . "$1"; job_end_record "$2" w1 abandoned probe test' _ \
  "$ORDER_LIB" recov-live)"
[[ "$recov_end" == created ]] ||
  fail "job.recovered must not block a later end declaration: $recov_end"
# shellcheck disable=SC2016 # $1 and $2 are the child shell's argv
recov_end="$(env ARBITER_INBOX_ROOT="$RECOV_INBOX" \
  bash -c 'set -euo pipefail; . "$1"; job_end_record "$2" w1 abandoned probe test' _ \
  "$ORDER_LIB" recov-ended)"
[[ "$recov_end" == already-ended ]] ||
  fail "a completed job stays ended after job.recovered: $recov_end"
echo "PASS hk1770-recovered-is-neutral"

# Two wrk writers of the same kind racing on one directory: both records land
# and neither overwrites the other (exclusive create + bounded retry).
CONC_DIR="$ORDER_INBOX/order-conc/events"
mkdir -p "$CONC_DIR"
printf 'first report\n' >"$TMP/order-report-a.md"
printf 'second report\n' >"$TMP/order-report-b.md"
# shellcheck disable=SC2016 # $1..$3 are the child shell's argv
env ARBITER_INBOX_ROOT="$ORDER_INBOX" bash -c '
  set -euo pipefail
  . "$1"
  completion_event order-conc w1 lbl w1:p1 "$2" job.completed "" record >/dev/null &
  completion_event order-conc w1 lbl w1:p1 "$3" job.completed "" record >/dev/null &
  wait
' _ "$ORDER_LIB" "$TMP/order-report-a.md" "$TMP/order-report-b.md" ||
  fail "concurrent completion_event writers failed"
conc_count="$(find "$CONC_DIR" -name '*-job.completed.json' | wc -l | tr -d ' ')"
[[ "$conc_count" -eq 2 ]] ||
  fail "two concurrent writers must both land (got $conc_count)"
python3 - "$CONC_DIR" <<'PY'
import glob, json, os, re, sys
paths = sorted(glob.glob(os.path.join(sys.argv[1], "*-job.completed.json")))
assert len(paths) == 2, paths
digests = set()
for path in paths:
    doc = json.load(open(path, encoding="utf-8"))
    assert doc["kind"] == "job.completed", doc
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z", doc.get("at", "")), doc
    digests.add(doc["report_sha256"])
assert len(digests) == 2, digests
PY
echo "PASS hk1750-concurrent-writers-both-land"

# A writer that computes a number already taken retries at the next number and
# never replaces the existing record. The collision is forced (both writers
# see highest=1) against an existing 00002 sentinel, so an os.replace writer
# cannot pass by choosing a free name and the sentinel hash must survive.
COLLIDE_DIR="$ORDER_INBOX/order-collide/events"
mkdir -p "$COLLIDE_DIR"
printf '{"kind":"job.completed","job_id":"order-collide","sentinel":1}\n' \
  >"$COLLIDE_DIR/00001-job.completed.json"
printf '{"kind":"job.completed","job_id":"order-collide","sentinel":2}\n' \
  >"$COLLIDE_DIR/00002-job.completed.json"
collide_before="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$COLLIDE_DIR/00002-job.completed.json")"
cat >"$TMP/order-collide.py" <<'PY'
import os, sys
exec(os.environ["WRK_EVENTS_PY"])
events = sys.argv[1]
real = wrk_event_highest
calls = {"n": 0}
def wrk_event_highest(path):
    # Each writer's first attempt sees highest=1 (00002 is taken); its retry
    # sees the real directory again.
    calls["n"] += 1
    return 1 if calls["n"] % 2 == 1 else real(path)
for tag in ("first", "second"):
    wrk_event_commit(events, "job.completed",
                     {"kind": "job.completed", "job_id": "order-collide", "tag": tag})
PY
# shellcheck disable=SC2016 # $1..$3 are the child shell's argv
env ARBITER_INBOX_ROOT="$ORDER_INBOX" bash -c '. "$1"; wrk_py "$2" "$3"' _ \
  "$ORDER_LIB" "$TMP/order-collide.py" "$COLLIDE_DIR" ||
  fail "collision retry write failed"
collide_after="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$COLLIDE_DIR/00002-job.completed.json")"
[[ "$collide_before" == "$collide_after" ]] ||
  fail "an existing event file was overwritten"
python3 - "$COLLIDE_DIR" <<'PY'
import glob, json, os, sys
tags = {}
for path in glob.glob(os.path.join(sys.argv[1], "*-job.completed.json")):
    doc = json.load(open(path, encoding="utf-8"))
    if "tag" in doc:
        tags[doc["tag"]] = os.path.basename(path)
assert sorted(tags) == ["first", "second"], tags
assert tags["first"] != tags["second"], tags
PY
echo "PASS hk1750-existing-event-never-overwritten"

# A wrk terminal at hh:mm:ss.429 followed by an arbiter revive at
# hh:mm:ss.000+300ms must order terminal-then-revive: event time is compared
# at whole seconds and the mtime (write time) breaks the sub-second tie.
SUB_DIR="$ORDER_INBOX/order-subsecond/events"
mkdir -p "$SUB_DIR"
python3 - "$SUB_DIR" <<'PY'
import datetime, json, os, sys
directory = sys.argv[1]
rows = [
    ("00001-job.claim", "job.claim", "2026-10-20T10:00:00+00:00", None, {"owner_lane": "w1", "pane_id": "w1:p1"}),
    ("00002-job.spawned", "job.spawned", "2026-10-20T10:00:01+00:00", None, {"owner_lane": "w1", "pane_id": "w1:p1", "tab_id": "w1:t1"}),
    ("00003-job.completed", "job.completed", None, "2026-10-20T10:00:05.429+00:00", {"owner_lane": "w1", "pane_id": "w1:p1"}),
    ("00004-job.reclaim", "job.reclaim", "2026-10-20T10:00:05+00:00", None, {"owner_lane": "w1", "pane_id": "w1:p1"}),
]
for name, kind, created, mtime, payload in rows:
    doc = {"kind": kind, "job_id": "order-subsecond", "payload": payload, "epoch": 1}
    if created:
        doc["created_at"] = created
    if kind == "job.completed":
        doc["at"] = "2026-10-20T10:00:05.429Z"
    path = os.path.join(directory, name + ".json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle)
    when = datetime.datetime.fromisoformat(created or mtime).timestamp()
    if kind == "job.reclaim":
        # Written 300 ms after the terminal at hh:mm:ss.429.
        when = datetime.datetime.fromisoformat(
            "2026-10-20T10:00:05.429+00:00").timestamp() + 0.300
    os.utime(path, (when, when))
PY
scan="$(order_scan order-subsecond)"
[[ "$(cut -f2 <<<"$scan")" == 0 ]] ||
  fail "a sub-second revive after the terminal must report ended 0: $scan"
order_reap "$TMP/order-reap-sub.out" ||
  fail "reap over the sub-second fixture failed: $(cat "$TMP/order-reap-sub.out.err")"
grep -qx 'skip job=order-subsecond reason=reclaimed-after-terminal' "$TMP/order-reap-sub.out" ||
  fail "sub-second revive must keep the job out of reap: $(cat "$TMP/order-reap-sub.out")"
echo "PASS hk1750-subsecond-revive-beats-second-precision-terminal"

# Event time wins over mtime; top-level and payload time fields both count.
# Ignoring event time, reading only top-level fields, or sorting mtime first
# changes this order (and the ended verdict below).
TIME_DIR="$ORDER_INBOX/order-time/events"
mkdir -p "$TIME_DIR"
python3 - "$TIME_DIR" <<'PY'
import datetime, json, os, sys
directory = sys.argv[1]
rows = [
    ("00001-job.completed", "job.completed", "2026-10-20T10:00:05.000Z", "2026-10-20T12:00:00+00:00"),
    ("00002-job.escalate", "job.escalate", None, "2026-10-20T08:00:00+00:00"),
    ("00003-job.spawned", "job.spawned", "2026-10-20T10:00:10+00:00", "2026-10-20T09:00:00+00:00"),
]
for name, kind, created, mtime in rows:
    doc = {"kind": kind, "job_id": "order-time", "epoch": 1, "payload": {"owner_lane": "live"}}
    if kind == "job.completed":
        doc["at"] = created
    elif kind == "job.escalate":
        doc["payload"]["at"] = "2026-10-20T10:00:07.000Z"
    else:
        doc["created_at"] = created
    path = os.path.join(directory, name + ".json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle)
    when = datetime.datetime.fromisoformat(mtime).timestamp()
    os.utime(path, (when, when))
PY
cat >"$TMP/order-print.py" <<'PY'
import os, sys
exec(os.environ["WRK_EVENTS_PY"])
print("\n".join(name for name, _, _ in wrk_events_ordered(sys.argv[1])))
PY
# shellcheck disable=SC2016 # $1..$3 are the child shell's argv
time_order="$(env ARBITER_INBOX_ROOT="$ORDER_INBOX" bash -c '. "$1"; wrk_py "$2" "$3"' _ \
  "$ORDER_LIB" "$TMP/order-print.py" "$TIME_DIR")" ||
  fail "ordered names failed"
[[ "$time_order" == $'00001-job.completed.json\n00002-job.escalate.json\n00003-job.spawned.json' ]] ||
  fail "event time must beat mtime and payload at must count: $time_order"
scan="$(order_scan order-time)"
[[ "$(cut -f2 <<<"$scan")" == 0 ]] ||
  fail "the time-ordered job must report ended 0: $scan"
echo "PASS hk1750-event-time-beats-mtime-and-reads-payload"

# The arbiter and the two wrk writers that used to publish unlocked must wait
# on the shared events lock while another writer holds it.
cat >"$TMP/order-lock-hold.py" <<'PY'
import fcntl, sys, time
lock = open(sys.argv[1], "w", encoding="utf-8")
fcntl.flock(lock, fcntl.LOCK_EX)
time.sleep(float(sys.argv[2]))
PY
LOCK_DIR="$ORDER_INBOX/order-lock/events"
mkdir -p "$LOCK_DIR"
env ARBITER_INBOX_ROOT="$ORDER_INBOX" "$ARBITER" claim --job order-lock --lane live --t T1 >/dev/null
python3 "$TMP/order-lock-hold.py" "$ORDER_INBOX/order-lock/.wrk-events.lock" 2 &
lock_holder=$!
sleep 0.4
env ARBITER_INBOX_ROOT="$ORDER_INBOX" "$ARBITER" event --job order-lock --kind job.task_link \
  --payload-json '{}' --json >/dev/null &
lock_writer=$!
sleep 0.5
[[ ! -e "$LOCK_DIR/00002-job.task_link.json" ]] ||
  fail "arbiter event did not wait on the shared events lock"
wait "$lock_writer" || fail "arbiter event failed after the lock released"
wait "$lock_holder" || true
[[ -e "$LOCK_DIR/00002-job.task_link.json" ]] ||
  fail "arbiter event did not land after the lock released"

LOCK_WRK_DIR="$ORDER_INBOX/order-lock-wrk/events"
mkdir -p "$LOCK_WRK_DIR"
python3 "$TMP/order-lock-hold.py" "$ORDER_INBOX/order-lock-wrk/.wrk-events.lock" 2 &
lock_holder=$!
sleep 0.4
# shellcheck disable=SC2016 # $1 is the child shell's argv
env ARBITER_INBOX_ROOT="$ORDER_INBOX" bash -c \
  '. "$1"; builder_flat_event order-lock-wrk live lbl w1:p1 director-1 job.escalate "" "" "q" "" ""' \
  _ "$ORDER_LIB" >/dev/null 2>&1 &
lock_writer=$!
sleep 0.5
[[ ! -e "$LOCK_WRK_DIR/00001-job.escalate.json" ]] ||
  fail "builder_flat_event did not wait on the shared events lock"
wait "$lock_writer" || fail "builder_flat_event failed after the lock released"
wait "$lock_holder" || true
[[ -e "$LOCK_WRK_DIR/00001-job.escalate.json" ]] ||
  fail "builder_flat_event did not land after the lock released"

LOCK_REAP_DIR="$ORDER_INBOX/order-lock-reap/events"
mkdir -p "$LOCK_REAP_DIR"
python3 "$TMP/order-lock-hold.py" "$ORDER_INBOX/order-lock-reap/.wrk-events.lock" 2 &
lock_holder=$!
sleep 0.4
# shellcheck disable=SC2016 # $1 is the child shell's argv
env ARBITER_INBOX_ROOT="$ORDER_INBOX" bash -c '. "$1"; reap_event order-lock-reap live w1:p1 w1:t1' \
  _ "$ORDER_LIB" >/dev/null 2>&1 &
lock_writer=$!
sleep 0.5
[[ ! -e "$LOCK_REAP_DIR/00001-job.reaped.json" ]] ||
  fail "reap_event did not wait on the shared events lock"
wait "$lock_writer" || fail "reap_event failed after the lock released"
wait "$lock_holder" || true
[[ -e "$LOCK_REAP_DIR/00001-job.reaped.json" ]] ||
  fail "reap_event did not land after the lock released"
echo "PASS hk1750-writers-wait-on-shared-events-lock"

# The helper's O_EXCL fallback (no hard links) still publishes, and a stuck
# number raises instead of overwriting.
cat >"$TMP/order-helper-paths.py" <<'PY'
import errno, os, sys
exec(os.environ["WRK_EVENTS_PY"])
mode, events = sys.argv[1], sys.argv[2]
if mode == "fallback":
    def no_link(*args, **kwargs):
        raise OSError(errno.EPERM, "no hard links here")
    _os.link = no_link
    wrk_event_commit(events, "job.escalate",
                     {"kind": "job.escalate", "job_id": "helper", "tag": "fallback"})
elif mode == "exhausted":
    def stuck(path):
        return 1
    wrk_event_highest = stuck
    try:
        wrk_event_commit(events, "job.escalate", {"kind": "job.escalate", "job_id": "helper"})
    except OSError as exc:
        print("EXHAUSTED", exc)
    else:
        raise SystemExit("expected OSError")
PY
FALLBACK_DIR="$ORDER_INBOX/order-fallback/events"
mkdir -p "$FALLBACK_DIR"
# shellcheck disable=SC2016 # $1..$3 are the child shell's argv
env ARBITER_INBOX_ROOT="$ORDER_INBOX" bash -c '. "$1"; wrk_py "$2" fallback "$3"' _ \
  "$ORDER_LIB" "$TMP/order-helper-paths.py" "$FALLBACK_DIR" ||
  fail "O_EXCL fallback publish failed"
python3 - "$FALLBACK_DIR" <<'PY'
import glob, json, sys
docs = [json.load(open(p, encoding="utf-8")) for p in glob.glob(sys.argv[1] + "/*job.escalate.json")]
assert [d.get("tag") for d in docs] == ["fallback"], docs
PY
EXHAUST_DIR="$ORDER_INBOX/order-exhaust/events"
mkdir -p "$EXHAUST_DIR"
printf '{"kind":"job.escalate","sentinel":true}\n' >"$EXHAUST_DIR/00002-job.escalate.json"
exhaust_before="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$EXHAUST_DIR/00002-job.escalate.json")"
# shellcheck disable=SC2016 # $1..$3 are the child shell's argv
exhaust_out="$(env ARBITER_INBOX_ROOT="$ORDER_INBOX" bash -c '. "$1"; wrk_py "$2" exhausted "$3"' _ \
  "$ORDER_LIB" "$TMP/order-helper-paths.py" "$EXHAUST_DIR")" ||
  fail "exhausted numbering must exit non-zero: $exhaust_out"
grep -q '^EXHAUSTED ' <<<"$exhaust_out" ||
  fail "exhausted numbering must raise OSError: $exhaust_out"
exhaust_after="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$EXHAUST_DIR/00002-job.escalate.json")"
[[ "$exhaust_before" == "$exhaust_after" ]] ||
  fail "exhausted numbering overwrote the existing record"
echo "PASS hk1750-helper-fallback-and-bounded-exhaustion"

# ------------------------------------------------------------------
# hk 1137 — the machine/job-id allowlist must be ASCII under any locale
# ------------------------------------------------------------------
# bin/wrk gates ids with bash =~ ranges like ^[A-Za-z0-9._-]{1,64}$. Those
# ranges follow the caller's locale collation: under en_US.UTF-8 they also
# match ~2000 non-ASCII letters and symbols (e-acute included), and the
# accepted value can then echo into a warning. Every site must match under
# LC_ALL=C. These probes drive each site with a non-ASCII id under both
# locale shapes — LC_ALL=en_US.UTF-8, and LANG=en_US.UTF-8 with LC_ALL
# unset — and prove refusal plus a message that carries no raw non-ASCII
# bytes. ASCII boundary ids (64 accepted, 65 refused, . _ - accepted) are
# unchanged.

T1137_LOCALE=""
for _t1137_cand in en_US.UTF-8 en_US.utf8; do
  if locale -a 2>/dev/null | grep -qiF "$_t1137_cand"; then
    T1137_LOCALE="$_t1137_cand"
    break
  fi
done
unset _t1137_cand

# A non-ASCII id byte sequence must never appear in stderr/stdout. grep in
# C locale treats the file as bytes; the pattern is the UTF-8 encoding of
# U+00E9 (e-acute).
t1137_no_raw_eacute() {  # FILE TAG — fail when the raw bytes are present
  ! LC_ALL=C grep -q $'\xc3\xa9' "$1" ||
    fail "hk1137 $2: raw non-ASCII bytes reached $1: $(cat "$1")"
}

# Usage-stage probes (--lane-defer/--parent-job/--takeover-from): a minimal
# spawn env; validation dies before any fixture is needed. The caller sets
# the locale through the command's env prefix.
t1137_usage() {
  set +e
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" PANEWIRE_BIN="$PANEWIRE" \
    ARBITER_BIN="$TMP/absent-arbiter" ARBITER_INBOX_ROOT="$TMP/t1137-inbox" \
    XDG_DATA_HOME="$TMP/t1137-xdg" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/t1137-usage-herdr.log" \
    WRK_SCOPEFUEL_LOG="$TMP/t1137-usage-scopefuel.log" \
    WRK_HOSTS_CONFIG="$TMP/t1137-no-such-hosts.toml" \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$ROOT" -m "${T1137_MODEL:-codex-luna}" -p "$PROMPT" \
    -w w -l t1137-usage --t T1 "$@" >"$T1137_OUT" 2>"$T1137_ERR"
  T1137_RC=$?
  set -e
}

T1137_OUT="$TMP/t1137.out" T1137_ERR="$TMP/t1137.err" T1137_RC=0
T1137_EACUTE_ID=$'mach\u00e9ne'          # non-ASCII machine-shaped id
T1137_EACUTE_JOB=$'j\u00e9b'             # non-ASCII job-shaped id
T1137_ID64="a$(printf 'b%.0s' {1..62})c" # exactly 64 ASCII chars
T1137_ID65="a$(printf 'b%.0s' {1..63})c" # 65 — one past the bound
[[ ${#T1137_ID64} -eq 64 && ${#T1137_ID65} -eq 65 ]] ||
  fail "hk1137: boundary fixtures miscounted"

# Configs for the hub_lane_register sites: a [hub] machine_id fallback with
# a non-ASCII value, a session_machine_ids entry with a non-ASCII machine,
# and a lanes node token file whose HUB_MACHINE_ID is non-ASCII.
T1137_CFG_BADMID="$TMP/t1137-badmid-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\noperator_token_env = "%s"\nhub_cf_env = "%s"\nmachine_id = "%s"\n' \
  "$LANES_OP_FILE" "$LANES_CF_FILE" "$T1137_EACUTE_ID" >"$T1137_CFG_BADMID"
T1137_CFG_BADMAP="$TMP/t1137-badmap-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\nsession_machine_ids = { "default" = "%s" }\n' \
  "$LANES_NODE_FILE" "$T1137_EACUTE_ID" >"$T1137_CFG_BADMAP"
T1137_NODE_BAD="$TMP/t1137-node-bad.env"
printf 'HUB_MACHINE_ID=%s\nHUB_TOKEN=fixture-t1137-node-token\n' "$T1137_EACUTE_ID" >"$T1137_NODE_BAD"
chmod 600 "$T1137_NODE_BAD"
T1137_CFG_BADNODE="$TMP/t1137-badnode-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\nsession_machine_ids = { "default" = "mac-work-default" }\n' \
  "$T1137_NODE_BAD" >"$T1137_CFG_BADNODE"
# Boundary configs: 64-char machine_id (accepted, registers), 65-char
# (refused), and a lanes node file carrying a 64-char HUB_MACHINE_ID that
# matches the session machine.
T1137_CFG_MID64="$TMP/t1137-mid64-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\noperator_token_env = "%s"\nhub_cf_env = "%s"\nmachine_id = "%s"\n' \
  "$LANES_OP_FILE" "$LANES_CF_FILE" "$T1137_ID64" >"$T1137_CFG_MID64"
T1137_CFG_MID65="$TMP/t1137-mid65-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\noperator_token_env = "%s"\nhub_cf_env = "%s"\nmachine_id = "%s"\n' \
  "$LANES_OP_FILE" "$LANES_CF_FILE" "$T1137_ID65" >"$T1137_CFG_MID65"
T1137_NODE_64="$TMP/t1137-node-64.env"
printf 'HUB_MACHINE_ID=%s\nHUB_TOKEN=fixture-t1137-node64-token\n' "$T1137_ID64" >"$T1137_NODE_64"
chmod 600 "$T1137_NODE_64"
T1137_CFG_NODE64="$TMP/t1137-node64-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nlanes_token_env = "%s"\nsession_machine_ids = { "default" = "%s" }\n' \
  "$T1137_NODE_64" "$T1137_ID64" >"$T1137_CFG_NODE64"
T1137_CFG_DOTID="$TMP/t1137-dotid-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\noperator_token_env = "%s"\nhub_cf_env = "%s"\nmachine_id = "mac.x_y-z"\n' \
  "$LANES_OP_FILE" "$LANES_CF_FILE" >"$T1137_CFG_DOTID"

# ASCII boundary behaviour is locale-independent — run it unconditionally so
# a runner without en_US.UTF-8 still proves the allowlist kept its shape.
# Site: --lane-defer (die path).
LC_ALL=C T1137_MODEL=builder-sol t1137_usage --role builder --lane t1137-b64 --parent director-x \
  --task 1 --lane-defer "$T1137_ID64"
! grep -q 'expects a machine id' "$T1137_ERR" ||
  fail "hk1137: a 64-char --lane-defer must be accepted: $(cat "$T1137_ERR")"
LC_ALL=C T1137_MODEL=builder-sol t1137_usage --role builder --lane t1137-b65 --parent director-x \
  --task 1 --lane-defer "$T1137_ID65"
[[ "$T1137_RC" -eq 2 ]] ||
  fail "hk1137: a 65-char --lane-defer must refuse rc 2 (rc=$T1137_RC): $(cat "$T1137_ERR")"
grep -q 'matching \[A-Za-z0-9._-\]' "$T1137_ERR" ||
  fail "hk1137: the 65-char refusal must name the charset: $(cat "$T1137_ERR")"
LC_ALL=C T1137_MODEL=builder-sol t1137_usage --role builder --lane t1137-bdot --parent director-x \
  --task 1 --lane-defer 'a.b_c-d'
! grep -q 'expects a machine id' "$T1137_ERR" ||
  fail "hk1137: . _ - must stay accepted in --lane-defer: $(cat "$T1137_ERR")"
# Site: --parent-job (die path). Job ids have no length cap; only the
# charset matters.
LC_ALL=C t1137_usage --role tester --parent-job 'job.a_b-9'
! grep -q 'must be a job id' "$T1137_ERR" ||
  fail "hk1137: . _ - must stay accepted in --parent-job: $(cat "$T1137_ERR")"
LC_ALL=C t1137_usage --role tester --parent-job 'job/bad'
[[ "$T1137_RC" -eq 2 ]] ||
  fail "hk1137: a slash in --parent-job must still refuse rc 2 (rc=$T1137_RC)"
# Site: --takeover-from (die path, same job-id charset).
LC_ALL=C T1137_MODEL=builder-sol t1137_usage --role builder --lane t1137-tk --parent director-x \
  --task 1 --takeover-from 'job.a_b-9'
! grep -q 'must be a job id' "$T1137_ERR" ||
  fail "hk1137: . _ - must stay accepted in --takeover-from: $(cat "$T1137_ERR")"
# Site: [hub] machine_id fallback — 64 chars registers, 65 warns malformed.
LANES_CFG_OVERRIDE="$T1137_CFG_MID64" LANES_MODEL=builder-sol \
  lanes_spawn t1137-m64 --role builder --lane t1137-m64 --parent director-x
[[ "$LANES_RC" -eq 0 ]] ||
  fail "hk1137: 64-char machine_id spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
grep -q ' lane=t1137-m64@'"$T1137_ID64"'$' "$LANES_OUT" ||
  fail "hk1137: the 64-char machine_id must register: $(cat "$LANES_OUT")"
LANES_CFG_OVERRIDE="$T1137_CFG_MID65" LANES_MODEL=builder-sol \
  lanes_spawn t1137-m65 --role builder --lane t1137-m65 --parent director-x
grep -q 'machine_id is malformed' "$LANES_ERR" ||
  fail "hk1137: a 65-char machine_id must warn malformed: $(cat "$LANES_ERR")"
# Site: '.', '_' and '-' inside machine_id stay accepted.
LANES_CFG_OVERRIDE="$T1137_CFG_DOTID" LANES_MODEL=builder-sol \
  lanes_spawn t1137-mdot --role builder --lane t1137-mdot --parent director-x
[[ "$LANES_RC" -eq 0 ]] ||
  fail "hk1137: mac.x_y-z machine_id spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
grep -q ' lane=t1137-mdot@mac\.x_y-z$' "$LANES_OUT" ||
  fail "hk1137: mac.x_y-z must register as the machine: $(cat "$LANES_OUT")"
# Site: lanes_token_env HUB_MACHINE_ID — 64 chars registers, matched against
# the session machine.
LANES_CFG_OVERRIDE="$T1137_CFG_NODE64" HERDR_SESSION=default \
  lanes_spawn t1137-n64 --owner work-kairos
[[ "$LANES_RC" -eq 0 ]] ||
  fail "hk1137: 64-char HUB_MACHINE_ID spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
grep -q ' lane=t1137-n64@'"$T1137_ID64"'$' "$LANES_OUT" ||
  fail "hk1137: the 64-char HUB_MACHINE_ID must register: $(cat "$LANES_OUT")"
echo "PASS hk1137-ascii boundaries: 64 accepted, 65 refused, . _ - accepted"

if [[ -z "$T1137_LOCALE" ]]; then
  # The refusal probes NEED a UTF-8 locale — under C even an unpinned =~
  # refuses e-acute, so a green run would be vacuous. Say SKIP with the
  # reason; never let the section pass silently.
  echo "SKIP hk1137-ascii refusal probes: no en_US.UTF-8 locale on this runner"
else
  # Run every site probe under both locale shapes: LC_ALL pinned, and
  # LANG-only with LC_ALL unset (the second is the ambient-locale path —
  # LANG only applies when LC_ALL is absent). The probes are shell
  # functions, so the locale is set at suite level per mode and restored
  # after the loop.
  t1137_had_lc=0; [[ -n "${LC_ALL+x}" ]] && t1137_had_lc=1
  t1137_had_lang=0; [[ -n "${LANG+x}" ]] && t1137_had_lang=1
  t1137_saved_lc="${LC_ALL-}" t1137_saved_lang="${LANG-}"
  for t1137_mode in LC_ALL LANG_ONLY; do
    if [[ "$t1137_mode" == LC_ALL ]]; then
      export LC_ALL="$T1137_LOCALE"
      t1137_tag=lcall
    else
      t1137_tag=lang
      unset LC_ALL
      export LANG="$T1137_LOCALE"
    fi

    # Site: --lane-defer. Fixed build: rc 2 + charset message + no raw é.
    # Unfixed: é passes validation and the spawn proceeds — rc != 2 and no
    # refusal line.
    T1137_MODEL=builder-sol t1137_usage --role builder --lane t1137-ld --parent director-x \
      --task "$(mint_task)" --lane-defer "$T1137_EACUTE_ID"
    [[ "$T1137_RC" -eq 2 ]] ||
      fail "hk1137/$t1137_mode: non-ASCII --lane-defer must refuse rc 2 (rc=$T1137_RC): $(cat "$T1137_ERR")"
    grep -q 'matching \[A-Za-z0-9._-\]' "$T1137_ERR" ||
      fail "hk1137/$t1137_mode: the --lane-defer refusal must name the charset: $(cat "$T1137_ERR")"
    t1137_no_raw_eacute "$T1137_ERR" "lane-defer/$t1137_mode"

    # Site: --parent-job. Fixed build: rc 2; the die may name the value only
    # scrubbed — the raw é bytes must not reach stderr.
    t1137_usage --role tester --parent-job "$T1137_EACUTE_JOB"
    [[ "$T1137_RC" -eq 2 ]] ||
      fail "hk1137/$t1137_mode: non-ASCII --parent-job must refuse rc 2 (rc=$T1137_RC): $(cat "$T1137_ERR")"
    grep -q 'must be a job id' "$T1137_ERR" ||
      fail "hk1137/$t1137_mode: the --parent-job refusal must name the rule: $(cat "$T1137_ERR")"
    t1137_no_raw_eacute "$T1137_ERR" "parent-job/$t1137_mode"

    # Site: --takeover-from — same job-id charset, builder-only flag.
    T1137_MODEL=builder-sol t1137_usage --role builder --lane t1137-tk2 --parent director-x \
      --task 1 --takeover-from "$T1137_EACUTE_JOB"
    [[ "$T1137_RC" -eq 2 ]] ||
      fail "hk1137/$t1137_mode: non-ASCII --takeover-from must refuse rc 2 (rc=$T1137_RC): $(cat "$T1137_ERR")"
    grep -q 'must be a job id' "$T1137_ERR" ||
      fail "hk1137/$t1137_mode: the --takeover-from refusal must name the rule: $(cat "$T1137_ERR")"
    t1137_no_raw_eacute "$T1137_ERR" "takeover-from/$t1137_mode"

    # Site: [hub] machine_id fallback. Fixed build: the value-free malformed
    # warning and no lanes call. Unfixed: é registers a lane on 'machéne'.
    LANES_CFG_OVERRIDE="$T1137_CFG_BADMID" LANES_MODEL=builder-sol \
      lanes_spawn "t1137-mid-$t1137_tag" --role builder --lane "t1137-mid-$t1137_tag" --parent director-x
    grep -q 'machine_id is malformed' "$LANES_ERR" ||
      fail "hk1137/$t1137_mode: a non-ASCII machine_id must warn malformed: $(cat "$LANES_ERR")"
    t1137_no_raw_eacute "$LANES_ERR" "machine_id/$t1137_mode"
    lanes_assert_no_lanes_call "t1137-mid-$t1137_tag"

    # Site: session_machine_ids value. Fixed build: refuse closed with a
    # value-free warning; unfixed, the non-ASCII machine reaches lanes add
    # and the lane= field.
    LANES_CFG_OVERRIDE="$T1137_CFG_BADMAP" HERDR_SESSION=default \
      lanes_spawn "t1137-map-$t1137_tag" --owner work-kairos
    grep -q "session's machine id is malformed" "$LANES_ERR" ||
      fail "hk1137/$t1137_mode: a non-ASCII session machine must warn malformed: $(cat "$LANES_ERR")"
    t1137_no_raw_eacute "$LANES_ERR" "session-map/$t1137_mode"
    lanes_assert_no_lanes_call "t1137-map-$t1137_tag"

    # Site: lanes_token_env HUB_MACHINE_ID. Fixed build: value-free
    # malformed warning. Unfixed: é passes the charset check and the
    # mismatch warning echoes 'machéne' verbatim.
    LANES_CFG_OVERRIDE="$T1137_CFG_BADNODE" HERDR_SESSION=default \
      lanes_spawn "t1137-node-$t1137_tag" --owner work-kairos
    grep -q 'lanes_token_env HUB_MACHINE_ID is malformed' "$LANES_ERR" ||
      fail "hk1137/$t1137_mode: a non-ASCII HUB_MACHINE_ID must warn malformed: $(cat "$LANES_ERR")"
    t1137_no_raw_eacute "$LANES_ERR" "lanes-machine/$t1137_mode"
    lanes_assert_no_lanes_call "t1137-node-$t1137_tag"
  done
  # Restore the suite's original locale env.
  if (( t1137_had_lc )); then export LC_ALL="$t1137_saved_lc"; else unset LC_ALL; fi
  if (( t1137_had_lang )); then export LANG="$t1137_saved_lang"; else unset LANG; fi
  echo "PASS hk1137-ascii refusals: non-ASCII refused at every site under LC_ALL and LANG"

  # Mutant — drop the locale pin at the --lane-defer site and that site's
  # probe must go RED: é is accepted again, so there is no rc-2 refusal.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant t1137-unpin \
    "ascii_re \"\$LANE_DEFER\" '^[A-Za-z0-9._-]{1,64}\$'" \
    '[[ "$LANE_DEFER" =~ ^[A-Za-z0-9._-]{1,64}$ ]]'
  LC_ALL="$T1137_LOCALE" WRK_UNDER_TEST="$TMP/mut-wrk-t1137-unpin" \
    T1137_MODEL=builder-sol t1137_usage --role builder --lane t1137-mut --parent director-x \
    --task "$(mint_task)" --lane-defer "$T1137_EACUTE_ID"
  [[ "$T1137_RC" -ne 2 || ! -s "$T1137_ERR" ]] ||
    fail "hk1137 M1 mutant survived: --lane-defer still refused the non-ASCII id without the locale pin"
  echo "PASS hk1137-ascii M1: removing the --lane-defer locale pin goes RED"
fi

# hk 1439: deliberate check — with SCOPEFUEL_BIN unset, a profile lease falls back
# to PATH, must hit the tripwire shim (rc 99 via the lease error), then the log is
# restored to its prior content so the end-of-suite check still means something.
tw_job=tripwire-deliberate
"$ARBITER" claim --job "$tw_job" --agent-label fixture --lane fixture --t T1 >/dev/null
# the gate text must carry a pool so resolve_pool goes on to known_pools (scopefuel --json)
printf '%s\n' 'profile=codex-luna-max pool=codex' >"$TMP/tw-gate.txt"
tw_rc=0
cp "$TRIPWIRE_LOG" "$TMP/tripwire.before"
( unset SCOPEFUEL_BIN
  "$ARBITER" lease --job "$tw_job" --kind quota_pool --profile codex-luna-max \
    --gate-output "$TMP/tw-gate.txt" --json >"$TMP/tw-lease.out" 2>"$TMP/tw-lease.err" ) || tw_rc=$?
[[ "$tw_rc" -ne 0 ]] || fail "hk1439: lease without SCOPEFUEL_BIN unexpectedly succeeded"
[[ "$(wc -l <"$TRIPWIRE_LOG")" -gt "$(wc -l <"$TMP/tripwire.before")" ]] ||
  fail "hk1439: tripwire did not fire for a lease without SCOPEFUEL_BIN: $(cat "$TMP/tw-lease.err")"
grep -q 'exit 99' "$TMP/tw-lease.err" "$TMP/tw-lease.out" ||
  fail "hk1439: lease error did not show the tripwire rc 99: $(cat "$TMP/tw-lease.err")"
cp "$TMP/tripwire.before" "$TRIPWIRE_LOG" # drop only this case's own line
echo "PASS hk1439 tripwire fires when SCOPEFUEL_BIN is unset"
if [[ -s "$TRIPWIRE_LOG" ]]; then
  echo "FAIL: hk1439 real-binary tripwire hit (caller argv):" >&2
  cat "$TRIPWIRE_LOG" >&2
  exit 1
fi

bash "$ROOT/tests/test-shellcheck-capped.sh"
# hk 1604: devin gate-profile contract. The real-scopefuel smoke stays opt-in
# (SCOPEFUEL_SMOKE_REPO), so this CI invocation does not need a checkout.
bash "$ROOT/tests/test-devin-gate-profile.sh"
# hk 1990: preserve durable operator refs at the actual apply_catalog call site.
python3 -m unittest discover -s "$ROOT/tests" -p 'test_wrk_operator_ref.py' -v
bash "$ROOT/tests/test-pi-launcher.sh"
echo 'PASS test-wrk'
