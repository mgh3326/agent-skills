#!/usr/bin/env bash
# shellcheck disable=SC2016 # child-shell snippets are literal and intentionally defer expansion
set -euo pipefail

# hk 2096: completion sentinels must survive the spawning process group and
# append one EXIT record after their action log. Every spawn uses fixture
# herdr/scopefuel/panewire binaries and every writable path is temporary.
export WRK_TEST_MODE=1
export WRK_TEST_REAL_SENTINEL=1
unset ARBITER_JOB HK_TASK_ID

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="${WRK_TEST_BIN:-$ROOT/bin/wrk}"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="$ROOT/bin/arbiter"
PANEWIRE="$ROOT/tests/fixtures/panewire"
HANDOFFKEEP="$ROOT/tests/fixtures/handoffkeep"
BASE_TMPDIR="${TMPDIR:-/tmp}"
TMPROOT="$(mktemp -d "$BASE_TMPDIR/wrk-sentinel-detach.XXXXXX")"
WRK_SOURCE="$WRK"
WRK="$TMPROOT/wrk"
cp "$WRK_SOURCE" "$WRK"
chmod +x "$WRK"
mkdir -p "$TMPROOT"/{tmp,home,xdg-data,xdg-cache,xdg-config,xdg-state,codex,claude}
chmod 700 "$TMPROOT/tmp"
export TMPDIR="$TMPROOT/tmp" HOME="$TMPROOT/home" CODEX_HOME="$TMPROOT/codex"
export CLAUDE_CONFIG_DIR="$TMPROOT/claude"
export XDG_DATA_HOME="$TMPROOT/xdg-data" XDG_CACHE_HOME="$TMPROOT/xdg-cache"
export XDG_CONFIG_HOME="$TMPROOT/xdg-config" XDG_STATE_HOME="$TMPROOT/xdg-state"
export XDG_RUNTIME_DIR="$TMPROOT/runtime"
mkdir -m 700 "$XDG_RUNTIME_DIR"
export ARBITER_INBOX_ROOT="$TMPROOT/inbox"
export HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER"
export PANEWIRE_BIN="$PANEWIRE" HANDOFFKEEP_BIN="$HANDOFFKEEP"
export WRK_HOSTS_CONFIG="$TMPROOT/no-hosts.toml" HK_MODE=new
export WRK_NO_SLEEP=1 WRK_COMPLETION_TIMEOUT_S=300 WRK_COMPLETION_INTERVAL_S=1
export WRK_SENTINEL_TRANSIENT_MAX=10 WRK_SENTINEL_LOST_GRACE=1800
export WRK_REFRESH_TIMEOUT_S=1
PROMPT="$TMPROOT/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"

# shellcheck disable=SC1091
. "$ROOT/tests/lib/tmp-writers.sh"
export TW_TMP="$TMPROOT"
OWNED_PIDS="$TMPROOT/owned-pids"
: >"$OWNED_PIDS"
own() { [[ "$1" =~ ^[0-9]+$ ]] || return 0; tw_register_pid "$OWNED_PIDS" "$1"; }

fail() { echo "FAIL hk2096: $*" >&2; exit 1; }
assertion_red() { printf 'ASSERT-RED: %s\n' "$1" >&2; return 1; }

cleanup() {
  local tw_rc=0
  while IFS= read -r pidfile; do tw_kill_pidfile "$pidfile" || true; done \
    < <(find "$ARBITER_INBOX_ROOT" -type f -name completion-sentinel.pid 2>/dev/null || true)
  tmp_writers_stop || tw_rc=$?
  if (( tw_rc == 0 )) && [[ -z "${TW_LEFTOVER_PIDS:-}" ]]; then
    rm -rf "$TMPROOT"
  else
    echo "FAIL hk2096: fixture writers survived teardown:${TW_LEFTOVER_PIDS:-}" >&2
    exit 1
  fi
}
trap cleanup EXIT

wait_until() {
  local limit="$1"; shift
  local deadline=$(( $(date +%s) + limit ))
  while (( $(date +%s) <= deadline )); do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  return 1
}

arb() { "$ARBITER" "$@"; }

case_group_survival() {
  local role="$1" job="$2" jobdir="$ARBITER_INBOX_ROOT/$2" report="$TMPROOT/$2-report.md"
  local label="lbl-$2" owner="owner-$2" pane="w:p1" hk_state="$TMPROOT/$2-hk.json"
  local pgid="" sentinel="" started="" log="$jobdir/completion-sentinel.log"
  local count_before=0 lib args=()
  mkdir -p "$jobdir"
  # hk 2042 containment: a --parent-job report must resolve under the parent or new job dir.
  report="$(cd "$jobdir" && pwd -P)/report.md"
  export HK_STATE="$hk_state"

  if [[ "$role" == builder ]]; then
    owner="lane-$job"
    "$HANDOFFKEEP" tasks add --id 1 --title "fixture task" --lane fixture >/dev/null
    args=(spawn -c "$ROOT" -m builder-sol -p "$PROMPT" -w w -l "$label" --t T1
      --task 1 --job "$job" --role builder --lane "lane-$job" --parent director-1 --report "$report")
  else
    "$HANDOFFKEEP" tasks add --id 2 --title "fixture task" --lane fixture >/dev/null
    arb claim --job "$job-parent" --lane "lane-$job-parent" --agent-label "lbl-$job-parent" \
      --t T1 --role builder --parent-lane director-1 --task-id 2 >/dev/null
    args=(spawn -c "$ROOT" -m sonnet -p "$PROMPT" -w w -l "$label" --t T1
      --job "$job" --role tester --owner "$owner" --parent-job "$job-parent" --report "$report")
  fi

  export SPAWNER_OUT="$TMPROOT/$2.out" SPAWNER_ERR="$TMPROOT/$2.err" SPAWNER_RC="$TMPROOT/$2.rc"
  local spawner_script='set +e
[[ "$(ps -o pgid= -p "$$" | tr -d "[:space:]")" == "$$" ]] || exit 91
"$@" >"$SPAWNER_OUT" 2>"$SPAWNER_ERR"
spawn_rc=$?
printf "%s\\n" "$spawn_rc" >"$SPAWNER_RC"
sleep 120
exit "$spawn_rc"'
  python3 -c 'import os, sys; os.setpgid(0, 0); os.execv("/bin/bash", ["/bin/bash", "-c", sys.argv[1], "group-spawner", *sys.argv[2:]])' \
    "$spawner_script" "$WRK" "${args[@]}" &
  local spawner=$!
  own "$spawner"

  if ! wait_until 30 test -s "$jobdir/completion-sentinel.pid"; then
    echo "SETUP hk2096 $role spawn did not write completion-sentinel.pid" >&2
    kill -- -"$spawner" 2>/dev/null || true
    wait "$spawner" 2>/dev/null || true
    cat "$SPAWNER_OUT" "$SPAWNER_ERR" >&2 2>/dev/null || true
    return 3
  fi
  if ! wait_until 30 test -s "$SPAWNER_RC"; then
    echo "SETUP hk2096 $role spawner did not return from wrk spawn" >&2
    kill -- -"$spawner" 2>/dev/null || true
    wait "$spawner" 2>/dev/null || true
    cat "$SPAWNER_OUT" "$SPAWNER_ERR" >&2 2>/dev/null || true
    return 3
  fi
  [[ "$(cat "$SPAWNER_RC")" == 0 ]] || {
    echo "SETUP hk2096 $role wrk spawn returned rc=$(cat "$SPAWNER_RC")" >&2
    cat "$SPAWNER_OUT" "$SPAWNER_ERR" >&2 2>/dev/null || true
    kill -- -"$spawner" 2>/dev/null || true
    wait "$spawner" 2>/dev/null || true
    return 3
  }
  sentinel="$(sed -n '1p' "$jobdir/completion-sentinel.pid")"
  started="$(sed -n 's/^started=//p' "$jobdir/completion-sentinel.pid")"
  [[ "$sentinel" =~ ^[0-9]+$ && "$started" =~ ^[0-9]+$ ]] || {
    echo "SETUP hk2096 $role pidfile fields are malformed" >&2; return 3;
  }
  own "$sentinel"
  wait_until 10 test -s "$log" || { echo "SETUP hk2096 $role sentinel has no first poll" >&2; return 3; }
  count_before="$(awk '/ status=/ {n++} END {print n+0}' "$log")"
  pgid="$(ps -o pgid= -p "$spawner" 2>/dev/null | tr -d '[:space:]')"
  [[ "$pgid" == "$spawner" ]] || { echo "SETUP hk2096 $role spawner pgid=$pgid pid=$spawner" >&2; return 3; }

  # Kill exactly the test-owned spawner process group, as a Codex exec teardown does.
  kill -- -"$pgid" 2>/dev/null || true
  wait "$spawner" 2>/dev/null || true

  if ! wait_until 8 awk -v n="$count_before" '/ status=/ {count++} END { exit !((count+0) > n) }' "$log"; then
    assertion_red "$role sentinel keeps polling after its spawner group is killed" || return 1
  fi
  if ! _tw_pid_alive "$sentinel"; then
    assertion_red "$role sentinel pid remains live after spawner group teardown" || return 1
  fi

  lib="$TMPROOT/$2-lib.sh"
  awk 'index($0, "case \"${1:-}\" in") == 1 {exit} {print}' "$WRK" >"$lib" || return 3
  env WRK_LIBFILE="$lib" bash -c '
    . "$WRK_LIBFILE"
    sentinel_pid_matches "$1" "$2" && sentinel_start_matches "$1" "$3"
  ' _ "$sentinel" "$job" "$started" || {
    assertion_red "$role pidfile names a sentinel accepted by both identity checks" || return 1
  }
  [[ "$(sed -n '1p' "$jobdir/completion-sentinel.pid")" == "$sentinel" ]] || {
    assertion_red "$role pidfile keeps the real sentinel pid" || return 1
  }
  local args_text
  args_text="$(ps -p "$sentinel" -o args= 2>/dev/null || true)"
  [[ "$args_text" == *"$WRK sentinel $job $owner $label $pane $report"* ]] || {
    assertion_red "$role sentinel final argv retains the wrk sentinel JOB OWNER LABEL PANE shape" || return 1
  }
  local sentinel_pgid
  sentinel_pgid="$(ps -o pgid= -p "$sentinel" 2>/dev/null | tr -d '[:space:]')"
  [[ "$sentinel_pgid" == "$sentinel" ]] || {
    assertion_red "$role sentinel is leader of its detached process group" || return 1
  }

  env WRK_LIBFILE="$lib" ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" bash -c \
    '. "$WRK_LIBFILE"; stop_completion_sentinel "$1"' _ "$job" || {
      echo "SETUP hk2096 $role exact sentinel cleanup failed" >&2; return 3;
    }
  wait_until 8 test '!' -e "$jobdir/completion-sentinel.pid" || { echo "SETUP hk2096 $role pidfile remained after stop" >&2; return 3; }
  printf 'PASS hk2096 %s group-kill survives and identity stays valid\n' "$role"
}

case_no_env_launch_survival() {
  local job=hk2096-no-env jobdir="$ARBITER_INBOX_ROOT/hk2096-no-env" report="$TMPROOT/no-env-report.md"
  local pidfile="$ARBITER_INBOX_ROOT/hk2096-no-env/completion-sentinel.pid" lib pid started args_text sentinel_pgid
  mkdir -p "$jobdir"; : >"$report"
  lib="$TMPROOT/no-env-lib.sh"
  awk 'index($0, "case \"${1:-}\" in") == 1 {exit} {print}' "$WRK" >"$lib"
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" \
    XDG_DATA_HOME="$XDG_DATA_HOME" WRK_COMPLETION_INTERVAL_S=1 WRK_LIBFILE="$lib" \
    bash -c '
      . "$WRK_LIBFILE"
      HERDR=""
      start_completion_sentinel "$@"
    ' "$WRK" "$pidfile" "$job" owner label w:p1 "$report" || return 3
  pid="$(sed -n '1p' "$pidfile")"; started="$(sed -n 's/^started=//p' "$pidfile")"
  [[ "$pid" =~ ^[0-9]+$ && "$started" =~ ^[0-9]+$ ]] || return 3
  own "$pid"
  wait_until 8 test -s "$jobdir/completion-sentinel.log" || return 3
  args_text="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  [[ "$args_text" == *"$WRK sentinel $job owner label w:p1 $report"* ]] || return 3
  sentinel_pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [[ "$sentinel_pgid" == "$pid" ]] || {
    assertion_red 'no-SENTINEL_ENV launcher starts the sentinel in its own session' || return 1
  }
  env WRK_LIBFILE="$lib" ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" bash -c \
    '. "$WRK_LIBFILE"; stop_completion_sentinel "$1"' _ "$job" || return 3
  wait_until 8 test '!' -e "$pidfile" || return 3
  printf 'PASS hk2096 no-SENTINEL_ENV launcher applies setsid through Python exec\n'
}

setup_sentinel_job() {
  local job="$1"
  arb claim --job "$job" --lane "lane-$job" --agent-label "lbl-$job" --t T1 >/dev/null
  arb event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-$job\",\"label\":\"lbl-$job\",\"pane_id\":\"w:p1\"}" >/dev/null
}

case_test_mode_optout_is_leak_checked() {
  local lib="$TMPROOT/default-mode-lib.sh"
  local pidfile="$ARBITER_INBOX_ROOT/default-mode/completion-sentinel.pid"
  local mutant="$TMPROOT/mutant-wrk-no-sentinel-optout"
  local mutant_lib="$TMPROOT/mutant-no-sentinel-optout-lib.sh"
  mkdir -p "$(dirname "$pidfile")"
  awk 'index($0, "case \"${1:-}\" in") == 1 {exit} {print}' "$WRK" >"$lib"

  env -u WRK_TEST_REAL_SENTINEL WRK_TEST_MODE=1 WRK_LIBFILE="$lib" \
    bash -c '. "$WRK_LIBFILE"; start_completion_sentinel "$@"' \
      "$WRK" "$pidfile" default-mode owner label w:p1 "$TMPROOT/report.md" || return 3
  [[ ! -e "$pidfile" ]] || {
    assertion_red 'WRK_TEST_MODE suppresses a sentinel without explicit opt-in' || return 1
  }

  python3 - "$WRK" "$mutant" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
guard = '''  if [[ "${WRK_TEST_MODE:-}" == 1 && "${WRK_TEST_REAL_SENTINEL:-}" != 1 ]]; then
    return 0
  fi
'''
assert source.count(guard) == 1, "test-mode sentinel opt-out not found exactly once"
pathlib.Path(sys.argv[2]).write_text(source.replace(guard, "", 1))
PY
  chmod +x "$mutant"
  awk 'index($0, "case \"${1:-}\" in") == 1 {exit} {print}' "$mutant" >"$mutant_lib"
  env -u WRK_TEST_REAL_SENTINEL WRK_TEST_MODE=1 WRK_LIBFILE="$mutant_lib" \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_SENTINEL_TRANSIENT_MAX=100 \
    HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" \
    bash -c '. "$WRK_LIBFILE"; start_completion_sentinel "$@"' \
      "$mutant" "$pidfile" mutant-default-mode owner label w:p1 "$TMPROOT/report.md" || return 3
  wait_until 10 test -s "$pidfile" || return 3
  local mutant_rc=0
  WRK_LEAK_ROOT="$TMPROOT" WRK_LEAK_COPY="$mutant" \
    python3 "$ROOT/tests/lib/assert-no-wrk-leaks.py" >"$TMPROOT/mutant-leak.out" 2>&1 || mutant_rc=$?
  [[ "$mutant_rc" -ne 0 ]] && grep -q 'FAIL: test left wrk-related processes alive' "$TMPROOT/mutant-leak.out" || {
    assertion_red 'dropping the test-mode opt-out is caught by the process leak assertion' || return 1
  }
  tw_kill_pidfile "$pidfile" || return 3
  wait_until 10 test '!' -e "$pidfile" || return 3
  echo 'PASS test-mode sentinel opt-out and leak assertion mutant'
}

case_exit_normal() {
  local job report log tail_lines exit_line expected_line
  job="hk2096-exit-normal-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
  report="$TMPROOT/$job-report.md"; log="$ARBITER_INBOX_ROOT/$job/completion-sentinel.log"
  mkdir -p "$ARBITER_INBOX_ROOT/$job"; printf 'complete\n' >"$report"; setup_sentinel_job "$job" || return 3
  env WRK_FIXTURE_SCENARIO=sentinel-done WRK_COMPLETION_INTERVAL_S=1 \
    "$WRK" sentinel "$job" "lane-$job" "lbl-$job" w:p1 "$report" >/dev/null 2>&1 || return 3
  local tail_lines; tail_lines="$(tail -n 2 "$log")"
  [[ "$(sed -n '2p' <<<"$tail_lines")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+Z\ sentinel-exit\ code=0\ line=[0-9]+$ ]] || {
    assertion_red 'normal completed sentinel logs time, exit code, and last command line'; return 1
  }
  [[ "$(sed -n '1p' <<<"$tail_lines")" == *'action=completed'* ]] || {
    assertion_red 'normal sentinel completion writes its action line before the EXIT line'; return 1
  }
  exit_line="$(sed -n 's/.*sentinel-exit code=0 line=\([0-9][0-9]*\)$/\1/p' <<<"$tail_lines")"
  expected_line="$(awk '/^      completed\)/ { in_completed=1; next } in_completed && index($0, "sentinel_self_exit \"$job\" 0") { expected=NR } /^      lost:\*/ { in_completed=0 } END { print expected+0 }' "$WRK")"
  [[ -n "$expected_line" && "$exit_line" == "$expected_line" ]] || {
    assertion_red "normal EXIT record line=$exit_line expected completion command line=$expected_line"; return 1
  }
  printf 'PASS hk2096 normal completion EXIT record follows action\n'
}

case_exit_signal() {
  local signal_name="$1" signal_code job report pidfile lib pid log exit_line sentinel_start sentinel_end
  case "$signal_name" in
    HUP) signal_code=129 ;;
    INT) signal_code=130 ;;
    QUIT) signal_code=131 ;;
    TERM) signal_code=143 ;;
    *) return 3 ;;
  esac
  job="hk2096-exit-signal-$signal_name-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
  report="$TMPROOT/$job-report.md"
  pidfile="$ARBITER_INBOX_ROOT/$job/completion-sentinel.pid"
  log="$ARBITER_INBOX_ROOT/$job/completion-sentinel.log"
  mkdir -p "$ARBITER_INBOX_ROOT/$job"; setup_sentinel_job "$job" || return 3
  lib="$TMPROOT/exit-term-lib.sh"; awk 'index($0, "case \"${1:-}\" in") == 1 {exit} {print}' "$WRK" >"$lib"
  env WRK_FIXTURE_SCENARIO=sentinel-working WRK_LIBFILE="$lib" \
    bash -c '. "$WRK_LIBFILE"; start_completion_sentinel "$@"' \
      "$WRK" "$pidfile" "$job" "lane-$job" "lbl-$job" w:p1 "$report" || return 3
  pid="$(sed -n '1p' "$pidfile")"; own "$pid"
  wait_until 8 test -s "$log" || return 3
  kill -"$signal_name" "$pid" 2>/dev/null || return 3
  wait_until 8 grep -Eq "sentinel-exit code=$signal_code line=[0-9]+ signal=$signal_name\$" "$log" || {
    assertion_red "$signal_name to the sentinel logs its signal name, exit status, and command line"; return 1
  }
  exit_line="$(sed -n "s/.*sentinel-exit code=$signal_code line=\\([0-9][0-9]*\\) signal=$signal_name$/\\1/p" "$log")"
  sentinel_start="$(awk '/^sentinel_cmd\(\) \{$/ { print NR; exit }' "$WRK")"
  sentinel_end="$(awk -v start="$sentinel_start" 'NR > start && /^}/ { print NR; exit }' "$WRK")"
  if [[ "$exit_line" =~ ^[0-9]+$ && "$sentinel_start" =~ ^[0-9]+$ && "$sentinel_end" =~ ^[0-9]+$ ]] &&
    (( exit_line >= sentinel_start && exit_line <= sentinel_end )); then
    :
  else
    assertion_red "$signal_name EXIT record line=$exit_line is outside sentinel_cmd"; return 1
  fi
  tw_kill_pidfile "$pidfile" || true
  printf 'PASS hk2096 %s EXIT record names %s\n' "$signal_name" "$signal_name"
}

case_exit_failure() {
  local job report log rc=0 exit_line expected_line
  job="hk2096-exit-failure-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
  report="$TMPROOT/$job-report.md"
  log="$ARBITER_INBOX_ROOT/$job/completion-sentinel.log"
  mkdir -p "$ARBITER_INBOX_ROOT/$job"; setup_sentinel_job "$job" || return 3
  env WRK_FIXTURE_SCENARIO=sentinel-working WRK_COMPLETION_INTERVAL_S=not-a-number \
    "$WRK" sentinel "$job" "lane-$job" "lbl-$job" w:p1 "$report" >"$TMPROOT/failure.out" 2>&1 || rc=$?
  (( rc != 0 )) || return 3
  grep -Eq 'sentinel-exit code=[1-9][0-9]* line=[0-9]+$' "$log" || {
    printf 'EXIT failure log:\n' >&2
    cat "$log" >&2 2>/dev/null || true
    cat "$TMPROOT/failure.out" >&2 2>/dev/null || true
    assertion_red 'forced failing sentinel command logs a nonzero exit code and command line'; return 1
  }
  exit_line="$(sed -n 's/.*sentinel-exit code=[1-9][0-9]* line=\([0-9][0-9]*\)$/\1/p' "$log" | tail -n 1)"
  expected_line="$(awk '$0 == "    sleep \"$interval\"" { print NR }' "$WRK")"
  [[ -n "$expected_line" && "$exit_line" == "$expected_line" ]] || {
    assertion_red "failing EXIT record line=$exit_line expected failing command line=$expected_line"; return 1
  }
  printf 'PASS hk2096 failing command EXIT record has nonzero status and line\n'
}

run_case() {
  local name="$1" fn="$2" rc=0 output=""; shift 2
  if output="$("$fn" "$@" 2>&1)"; then
    printf '%s\n' "$output"
    return 0
  else
    rc=$?
  fi
  printf 'FAIL hk2096 case %s rc=%s\n' "$name" "$rc" >&2
  printf '%s\n' "$output" >&2
  return "$rc"
}

expect_red() {
  local name="$1" fn="$2" expected="$3" rc=0 output=""; shift 3
  if output="$("$fn" "$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "$name mutant stayed green"
  else
    rc=$?
  fi
  (( rc != 3 )) || { printf '%s\n' "$output" >&2; fail "$name mutant setup failed"; }
  grep -Fq "$expected" <<<"$output" || { printf '%s\n' "$output" >&2; fail "$name did not fail at expected assertion"; }
  printf 'PASS hk2096 mutant %s is assertion-RED\n' "$name"
}

if [[ "${1:-}" == --red-first ]]; then
  expect_red 'base builder group teardown' case_group_survival \
    'ASSERT-RED: builder sentinel keeps polling after its spawner group is killed' \
    builder hk2096-red-builder
  expect_red 'base tester group teardown' case_group_survival \
    'ASSERT-RED: tester sentinel keeps polling after its spawner group is killed' \
    tester hk2096-red-tester
  expect_red 'base EXIT log' case_exit_normal \
    'ASSERT-RED: normal completed sentinel logs time, exit code, and last command line'
  echo "PASS hk2096 RED-first reproduced on $(git -C "$ROOT" rev-parse --short HEAD)"
  exit 0
fi
if [[ "${1:-}" == --exit-red-first ]]; then
  expect_red 'base EXIT log' case_exit_normal \
    'ASSERT-RED: normal completed sentinel logs time, exit code, and last command line'
  echo "PASS hk2096 EXIT RED-first reproduced on $(git -C "$ROOT" rev-parse --short HEAD)"
  exit 0
fi
if [[ "${1:-}" == --failure-only ]]; then run_case failure case_exit_failure; exit 0; fi

python3 -c 'import sys; assert sys.version_info >= (3, 11), sys.version'
run_case builder-group-kill case_group_survival builder hk2096-builder
run_case tester-group-kill case_group_survival tester hk2096-tester
run_case no-env-launch case_no_env_launch_survival
case_test_mode_optout_is_leak_checked
run_case normal-exit case_exit_normal
for signal_name in HUP INT QUIT TERM; do
  run_case "signal-exit-$signal_name" case_exit_signal "$signal_name"
done
run_case failing-exit case_exit_failure

# The mutants are intentionally source-level drops of only the new invariant.
# Each is exercised by the same role-specific or trap-line case that proves it.
MUTANT="$TMPROOT/wrk-no-setsid"
python3 - "$WRK" "$MUTANT" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
needle = "os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])"
assert needle in source, "sentinel Python exec launcher not found"
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, "os.execvp(sys.argv[1], sys.argv[1:])"))
PY
chmod +x "$MUTANT"
ORIGINAL_WRK="$WRK"; WRK="$MUTANT"
expect_red 'drop setsid builder' case_group_survival \
  'ASSERT-RED: builder sentinel keeps polling after its spawner group is killed' \
  builder hk2096-mutant-builder
expect_red 'drop setsid tester' case_group_survival \
  'ASSERT-RED: tester sentinel keeps polling after its spawner group is killed' \
  tester hk2096-mutant-tester
expect_red 'drop setsid no-env launch' case_no_env_launch_survival \
  'ASSERT-RED: no-SENTINEL_ENV launcher starts the sentinel in its own session'
WRK="$ORIGINAL_WRK"

MUTANT="$TMPROOT/wrk-no-exit-trap"
python3 - "$WRK" "$MUTANT" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text().splitlines(keepends=True)
mutant = [line for line in source if not ("trap 'sentinel_exit_trap " in line and " EXIT" in line)]
assert len(mutant) < len(source), "sentinel EXIT trap installer not found"
pathlib.Path(sys.argv[2]).write_text("".join(mutant))
PY
chmod +x "$MUTANT"
ORIGINAL_WRK="$WRK"; WRK="$MUTANT"
expect_red 'drop EXIT trap normal' case_exit_normal \
  'ASSERT-RED: normal completed sentinel logs time, exit code, and last command line'
expect_red 'drop EXIT trap TERM' case_exit_signal \
  'ASSERT-RED: TERM to the sentinel logs its signal name, exit status, and command line' TERM
expect_red 'drop EXIT trap failure' case_exit_failure \
  'ASSERT-RED: forced failing sentinel command logs a nonzero exit code and command line'
WRK="$ORIGINAL_WRK"
tmp_writers_stop
WRK_LEAK_ROOT="$TMPROOT" WRK_LEAK_COPY="$WRK" python3 "$ROOT/tests/lib/assert-no-wrk-leaks.py"
echo 'PASS test-wrk-sentinel-detach'
