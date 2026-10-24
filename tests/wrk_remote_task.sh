#!/usr/bin/env bash
set -euo pipefail
# hk 1894: trust-bearing wrk and arbiter commands honour this suite's temp-dir overrides
# (HOME, ARBITER_INBOX_ROOT, XDG_DATA_HOME, HANDOFFKEEP_BIN) only in test mode.
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
unset HK_TASK_ID ARBITER_JOB

HOME="$TMP/home"
XDG_CONFIG_HOME="$TMP/xdg/config"
XDG_DATA_HOME="$TMP/xdg/data"
XDG_STATE_HOME="$TMP/xdg/state"
XDG_CACHE_HOME="$TMP/xdg/cache"
ARBITER_INBOX_ROOT="$TMP/initiator/inbox/jobs"
HK_FIXTURE="$ROOT/tests/fixtures/handoffkeep"
REMOTE_CWD="$TMP/remote/repo"
REMOTE_PROMPT_PATH="$TMP/remote/brief.md"
CONFIG="$TMP/hosts.toml"
HUB_CONFIG="$TMP/hub-hosts.toml"
PROMPT="$TMP/brief.md"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
  "$XDG_CACHE_HOME" "$ARBITER_INBOX_ROOT" "$REMOTE_CWD" "$TMP/remote-inbox/jobs" \
  "$TMP/remote-bin"
export HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ARBITER_INBOX_ROOT
printf '%s\n' 'remote task inheritance fixture brief' >"$PROMPT"
printf '%s\n' '0.20 0.10 0.10 1/1 1' >"$TMP/loadavg"
printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
  '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
  "cwd_map = {\"$ROOT\"=\"$REMOTE_CWD\"}" 'capacity = 3' >"$CONFIG"
printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
  '[hosts.hubtest]' 'via = "hub"' 'ssh = "hubtest"' 'herdr_session = "worker"' \
  'workspace = "workers"' "cwd_map = {\"$ROOT\"=\"$REMOTE_CWD\"}" \
  "cwd_keys = {\"$ROOT\"=\"repo-a\"}" 'capacity = 3' >"$HUB_CONFIG"

stop_owned_sentinels() {
  local root pidfile pid command_line job
  for root in "$ARBITER_INBOX_ROOT" "$TMP/remote-inbox/jobs"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r pidfile; do
      [[ -r "$pidfile" ]] || continue
      read -r pid <"$pidfile" || continue
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      job="${pidfile%/completion-sentinel.pid}"
      job="${job##*/}"
      command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      [[ "$command_line" == *"$ROOT/bin/wrk sentinel $job "* ]] || continue
      kill "$pid" 2>/dev/null || true
    done < <(find "$root" -type f -name completion-sentinel.pid -print 2>/dev/null || true)
  done
}

cleanup() {
  stop_owned_sentinels
  rm -rf "$TMP"
}
trap cleanup EXIT

export HK_STATE="$TMP/hk-state.json"
# hk 1897: mutant wrk copies live under $TMP, so their script_dir allowance
# never covers the repo's bin/arbiter — hand every spawn a temp copy.
cp "$ROOT/bin/arbiter" "$TMP/arbiter" && chmod 700 "$TMP/arbiter"
"$HK_FIXTURE" tasks add --id 1489 --title 'remote inherited task' --lane fixture >/dev/null
"$HK_FIXTURE" tasks add --id 9 --title 'explicit remote task' --lane fixture >/dev/null
"$HK_FIXTURE" tasks add --id 10 --title 'builder task' --lane fixture >/dev/null

seed_parent() {
  local job="$1" task_id="${2:-}"
  local args=(claim --job "$job" --agent-label "seed-${job}" --lane fixture --t T1)
  [[ -z "$task_id" ]] || args+=(--task-id "$task_id")
  env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
    XDG_STATE_HOME="$XDG_STATE_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" "$ROOT/bin/arbiter" "${args[@]}" >/dev/null
}

seed_parent P 1489
seed_parent P-conflict 8
seed_parent P-no-task

cat >"$TMP/remote-bin/wrk" <<'REMOTE_WRK'
#!/usr/bin/env bash
set -euo pipefail
root="${WRK_REMOTE_ROOT:?}"
tmp="${WRK_REMOTE_TMP:?}"
{
  printf 'HK_TASK_ID=%s\n' "${HK_TASK_ID:-<unset>}"
  printf 'ARGV='
  printf '<%s>' "$@"
  printf '\n'
} >"${WRK_REMOTE_WRK_LOG:?}"
HOME="$tmp/remote-home"
XDG_CONFIG_HOME="$tmp/remote-xdg/config"
XDG_DATA_HOME="$tmp/remote-xdg/data"
XDG_STATE_HOME="$tmp/remote-xdg/state"
XDG_CACHE_HOME="$tmp/remote-xdg/cache"
ARBITER_INBOX_ROOT="$tmp/remote-inbox/jobs"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
  "$XDG_CACHE_HOME" "$ARBITER_INBOX_ROOT"
export HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ARBITER_INBOX_ROOT
export ARBITER_BIN="$root/bin/arbiter"
export HANDOFFKEEP_BIN="$root/tests/fixtures/handoffkeep"
export HK_STATE="$tmp/hk-state.json"
export HERDR_BIN="$root/tests/fixtures/spillover-herdr"
export SCOPEFUEL_BIN="$root/tests/fixtures/scopefuel"
export PANEWIRE_BIN="$root/tests/fixtures/spillover-panewire"
export WRK_HOSTS_CONFIG="$tmp/hosts.toml"
export WRK_PROC_LOADAVG="$tmp/loadavg" WRK_TEST_NCPU=4 WRK_TEST_THROTTLED=0 WRK_NO_SLEEP=1
export WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$tmp/remote-herdr.log"
export WRK_SPILLOVER_LOG="$tmp/remote-spillover.log"
export WRK_SSH_BIN="$root/tests/fixtures/spillover-ssh" WRK_SCP_BIN="$root/tests/fixtures/spillover-scp"
export WRK_SSH_LOG="$tmp/remote-ssh.log" WRK_SCP_LOG="$tmp/remote-scp.log"
exec "$root/bin/wrk" "$@"
REMOTE_WRK
chmod +x "$TMP/remote-bin/wrk"

run_remote() {
  local binary="$1"; shift
  local model="${WRK_CASE_MODEL:-codex-luna}" label="${WRK_CASE_LABEL:-remote-child}"
  local job="${WRK_CASE_JOB:-remote-$RANDOM-$RANDOM}" config="${WRK_CASE_CONFIG:-$CONFIG}"
  env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
    XDG_STATE_HOME="$XDG_STATE_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" HERDR_BIN="$ROOT/tests/fixtures/spillover-herdr" \
    SCOPEFUEL_BIN="$ROOT/tests/fixtures/scopefuel" ARBITER_BIN="$TMP/arbiter" \
    HANDOFFKEEP_BIN="$HK_FIXTURE" HK_STATE="$HK_STATE" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_REFRESH_TIMEOUT_S=1 \
    WRK_HOSTS_CONFIG="$config" WRK_PROC_LOADAVG="$TMP/loadavg" WRK_TEST_NCPU=4 WRK_TEST_THROTTLED=0 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SPILLOVER_LOG="$TMP/spillover.log" \
    PANEWIRE_BIN="$ROOT/tests/fixtures/spillover-panewire" \
    WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" WRK_SCP_BIN="$ROOT/tests/fixtures/spillover-scp" \
    WRK_SSH_LOG="$TMP/ssh.log" WRK_SSH_ARGV_LOG="$TMP/ssh.argv0" \
    WRK_SCP_LOG="$TMP/scp.log" WRK_WAKE_LOG="$TMP/wake.log" \
    WRK_PLACE_SCENARIO="${WRK_CASE_PLACE_SCENARIO:-unavailable}" WRK_TEST_ACTIVE="${WRK_CASE_ACTIVE:-0}" \
    WRK_REMOTE_PROMPT_PATH="$REMOTE_PROMPT_PATH" WRK_REMOTE_ROOT="$ROOT" WRK_REMOTE_TMP="$TMP" \
    WRK_SSH_EXEC_REMOTE="${WRK_CASE_EXEC_REMOTE:-1}" WRK_REMOTE_WRK_LOG="${WRK_CASE_REMOTE_LOG:-$TMP/remote-wrk.log}" \
    WRK_PLACE_LOG="$TMP/place.log" PATH="$TMP/remote-bin:$PATH" \
    "$binary" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w workers -l "$label" --t T1 --job "$job" "$@"
}

# T1: the initiator resolves P locally, forwards one HK_TASK_ID env argv, and
# keeps --parent-job. The target's arbiter has no P record; its real wrk path
# succeeds through the existing HK_TASK_ID inheritance fallback.
: >"$TMP/ssh.log"; : >"$TMP/scp.log"
t1_out="$(WRK_CASE_JOB=t1-remote run_remote "$ROOT/bin/wrk" --host desktop --parent-job P 2>&1)"
grep -q '^OK pane=.* host=desktop ' <<<"$t1_out" || { echo 'FAIL T1 target wrk did not succeed' >&2; exit 1; }
grep -q 'HERDR_SESSION=worker HK_TASK_ID=1489 wrk spawn' "$TMP/ssh.log" || {
  echo 'FAIL T1 HK_TASK_ID was not in the remote env argv' >&2; exit 1;
}
grep -q -- '--parent-job P' "$TMP/ssh.log" || { echo 'FAIL T1 parent job was dropped' >&2; exit 1; }
grep -q '^HK_TASK_ID=1489$' "$TMP/remote-wrk.log" || { echo 'FAIL T1 target did not receive HK_TASK_ID' >&2; exit 1; }
grep -q -- '--parent-job><P>' "$TMP/remote-wrk.log" || { echo 'FAIL T1 target argv lost parent job' >&2; exit 1; }
[[ ! -e "$TMP/remote-inbox/jobs/P" ]] || { echo 'FAIL T1 remote arbiter unexpectedly knew P' >&2; exit 1; }
python3 - "$TMP/ssh.argv0" <<'PY'
import shlex, sys

records = [record.split(b"\0") for record in open(sys.argv[1], "rb").read().split(b"\0\0") if record]
spawn = next(record[-1].decode() for record in reversed(records) if b"wrk spawn" in record[-1])
command = spawn.split("; rc=$?;", 1)[0]
argv = shlex.split(command)
assert argv[:3] == ["env", "HERDR_SESSION=worker", "HK_TASK_ID=1489"], argv
assert argv.count("HK_TASK_ID=1489") == 1, argv
assert argv[argv.index("--parent-job") + 1] == "P", argv
PY
printf '%s\n' 'PASS wrk-remote-task T1-remote-env-and-empty-target-arbiter'

# The same pre-resolution applies to --host auto candidates which use SSH.
: >"$TMP/ssh.log"; : >"$TMP/ssh.argv0"; : >"$TMP/scp.log"
auto_out="$(WRK_CASE_JOB=t1-auto WRK_CASE_ACTIVE=4 run_remote "$ROOT/bin/wrk" --host auto --parent-job P 2>&1)"
grep -q '^OK pane=.* host=desktop ' <<<"$auto_out" || { echo 'FAIL auto candidate did not succeed' >&2; exit 1; }
grep -q 'HERDR_SESSION=worker HK_TASK_ID=1489 wrk spawn' "$TMP/ssh.log" || {
  echo 'FAIL auto SSH candidate did not receive HK_TASK_ID' >&2; exit 1;
}
printf '%s\n' 'PASS wrk-remote-task auto-ssh-candidate-inherits-task'

# T2: unresolved inheritance is refused on the initiator before even the
# remote capacity probe reaches the SSH stub.
: >"$TMP/ssh.log"
set +e
t2_out="$(WRK_CASE_JOB=t2-no-task run_remote "$ROOT/bin/wrk" --host desktop --parent-job P-no-task 2>&1)"
t2_rc=$?
set -e
[[ "$t2_rc" -eq 2 && ! -s "$TMP/ssh.log" ]] || { echo 'FAIL T2 did not refuse before SSH' >&2; exit 1; }
grep -q "parent job 'P-no-task' has no task_id" <<<"$t2_out" || { echo 'FAIL T2 existing error was lost' >&2; exit 1; }
grep -q 'for a remote spawn the initiator must know the task; pass --task' <<<"$t2_out" || {
  echo 'FAIL T2 remote-task hint was missing' >&2; exit 1;
}
grep -q 'resolution failed on host ' <<<"$t2_out" || { echo 'FAIL T2 host was not named' >&2; exit 1; }
printf '%s\n' 'PASS wrk-remote-task T2-fail-before-ssh'

# T3: the parent's task and an explicit HK_TASK_ID conflict is refused using
# the local conflict guard before SSH.
: >"$TMP/ssh.log"
set +e
export HK_TASK_ID=7
t3_out="$(WRK_CASE_JOB=t3-conflict run_remote "$ROOT/bin/wrk" --host desktop --parent-job P-conflict 2>&1)"
t3_rc=$?
unset HK_TASK_ID
set -e
[[ "$t3_rc" -eq 2 && ! -s "$TMP/ssh.log" ]] || { echo 'FAIL T3 did not refuse before SSH' >&2; exit 1; }
grep -q 'recorded task_id=8 but HK_TASK_ID=7 — refusing to guess' <<<"$t3_out" || {
  echo 'FAIL T3 conflict refusal changed' >&2; exit 1;
}
printf '%s\n' 'PASS wrk-remote-task T3-conflict-before-ssh'

# T4: explicit --task remains in the remote argv and adds no task environment.
: >"$TMP/ssh.log"; : >"$TMP/scp.log"
t4_out="$(WRK_CASE_JOB=t4-explicit run_remote "$ROOT/bin/wrk" --host desktop --task 9 2>&1)"
grep -q '^OK pane=.* host=desktop ' <<<"$t4_out" || { echo 'FAIL T4 explicit task spawn failed' >&2; exit 1; }
grep -q -- '--task 9' "$TMP/ssh.log" || { echo 'FAIL T4 explicit task was dropped' >&2; exit 1; }
! grep -q 'HK_TASK_ID=' "$TMP/ssh.log" || { echo 'FAIL T4 added an env task' >&2; exit 1; }
grep -q '^HK_TASK_ID=<unset>$' "$TMP/remote-wrk.log" || { echo 'FAIL T4 target received an added task env' >&2; exit 1; }
t4_baseline_args=(env HERDR_SESSION=worker wrk spawn -c "$REMOTE_CWD" -p "$REMOTE_PROMPT_PATH" --host local \
  -m codex-luna -w workers -l remote-child --t T1 --job t4-explicit --task 9)
printf -v t4_baseline_cmd '%q ' "${t4_baseline_args[@]}"
t4_expected_line="-o BatchMode=yes desktop ${t4_baseline_cmd}; rc=\$?; rm -f -- $(printf '%q' "$REMOTE_PROMPT_PATH"); exit \$rc"
[[ "$(tail -n 1 "$TMP/ssh.log")" == "$t4_expected_line" ]] || {
  echo 'FAIL T4 explicit-task remote argv changed' >&2; exit 1;
}
printf '%s\n' 'PASS wrk-remote-task T4-explicit-task-unchanged'

# T5: builder remote argv stays byte-for-byte at the pre-change shape, with
# --lane-defer and its own --task and no HK_TASK_ID assignment.
: >"$TMP/ssh.log"; : >"$TMP/scp.log"
t5_out="$(WRK_CASE_MODEL=builder-sol WRK_CASE_LABEL=buildercase WRK_CASE_JOB=t5-builder \
  WRK_CASE_EXEC_REMOTE=0 WRK_CASE_REMOTE_LOG="$TMP/builder-remote-wrk.log" \
  run_remote "$ROOT/bin/wrk" --host desktop --role builder --lane b1496-remotetask --parent director-1 --task 10 2>&1)"
grep -q '^OK pane=.* host=desktop ' <<<"$t5_out" || { echo 'FAIL T5 builder stub did not return OK' >&2; exit 1; }
baseline_args=(env HERDR_SESSION=worker wrk spawn -c "$REMOTE_CWD" -p "$REMOTE_PROMPT_PATH" --host local \
  --lane-defer desktop -m builder-sol -w workers -l buildercase --t T1 --job t5-builder \
  --role builder --lane b1496-remotetask --parent director-1 --task 10)
printf -v baseline_cmd '%q ' "${baseline_args[@]}"
expected_line="-o BatchMode=yes desktop ${baseline_cmd}; rc=\$?; rm -f -- $(printf '%q' "$REMOTE_PROMPT_PATH"); exit \$rc"
actual_line="$(tail -n 1 "$TMP/ssh.log")"
[[ "$actual_line" == "$expected_line" ]] || {
  echo 'FAIL T5 builder remote argv changed' >&2
  printf 'expected: %s\nactual:   %s\n' "$expected_line" "$actual_line" >&2
  exit 1
}
! grep -q 'HK_TASK_ID=' <<<"$actual_line" || { echo 'FAIL T5 builder got an inherited task env' >&2; exit 1; }
printf '%s\n' 'PASS wrk-remote-task T5-builder-argv-identical'

# R5: the existing via=hub payload has an argv field but no child-environment
# field. An inherited task is therefore refused before HTTP credentials or a
# hub request are touched. Explicit --task remains the supported hub shape.
: >"$TMP/ssh.log"
set +e
hub_out="$(WRK_CASE_CONFIG="$HUB_CONFIG" WRK_CASE_JOB=r5-hub-inherit \
  run_remote "$ROOT/bin/wrk" --host hubtest --parent-job P 2>&1)"
hub_rc=$?
set -e
[[ "$hub_rc" -eq 2 && ! -s "$TMP/ssh.log" ]] || { echo 'FAIL hub inheritance was not refused locally' >&2; exit 1; }
grep -q 'via=hub cannot forward an inherited task' <<<"$hub_out" || {
  echo 'FAIL hub task-transport limitation was not stated' >&2; exit 1;
}
[[ ! -e "$TMP/hub.log" ]] || { echo 'FAIL via=hub made an HTTP request' >&2; exit 1; }
printf '%s\n' 'PASS wrk-remote-task R5-via-hub-fails-closed-without-request'

# Mutant M1 drops HK_TASK_ID from the SSH env. The target's empty arbiter then
# cannot resolve P and the real remote wrk path fails, proving T1 is sensitive.
MUT_DROP="$TMP/wrk-env-dropped"
python3 - "$ROOT/bin/wrk" "$MUT_DROP" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
line = '  [[ -n "${SPILL_REMOTE_HK_TASK:-}" ]] && remote_args+=("HK_TASK_ID=$SPILL_REMOTE_HK_TASK")\n'
assert source.count(line) == 1
Path(sys.argv[2]).write_text(source.replace(line, "", 1))
PY
chmod +x "$MUT_DROP"
: >"$TMP/ssh.log"; : >"$TMP/scp.log"
set +e
mut_drop_out="$(WRK_CASE_JOB=m1-env-dropped WRK_CASE_REMOTE_LOG="$TMP/m1-remote-wrk.log" \
  run_remote "$MUT_DROP" --host desktop --parent-job P 2>&1)"
mut_drop_rc=$?
set -e
[[ "$mut_drop_rc" -ne 0 ]] || { echo 'FAIL M1 env-drop mutant survived' >&2; exit 1; }
grep -q '^HK_TASK_ID=<unset>$' "$TMP/m1-remote-wrk.log" || { echo 'FAIL M1 did not drop target env' >&2; exit 1; }
grep -q "parent job 'P' has no task_id" <<<"$mut_drop_out" || { echo 'FAIL M1 target did not fail task inheritance' >&2; exit 1; }
printf '%s\n' 'PASS wrk-remote-task M1-env-drop-red-then-restored-green'

# Mutant M2 moves task resolution until after the remote mktemp SSH leg. T2's
# zero-SSH assertion then goes red, proving local resolution precedes transport.
MUT_LATE="$TMP/wrk-task-resolved-late"
python3 - "$ROOT/bin/wrk" "$MUT_LATE" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
early = '  spillover_resolve_remote_task "${filtered[@]}"\n'
late_marker = '  spillover_remote_step "$host" scp\n'
assert source.count(early) == 1
assert source.count(late_marker) == 1
source = source.replace(early, "", 1)
source = source.replace(late_marker, '  spillover_resolve_remote_task "$@"\n' + late_marker, 1)
Path(sys.argv[2]).write_text(source)
PY
chmod +x "$MUT_LATE"
: >"$TMP/ssh.log"
set +e
mut_late_out="$(WRK_CASE_JOB=m2-resolved-late run_remote "$MUT_LATE" --host desktop --parent-job P-no-task 2>&1)"
mut_late_rc=$?
set -e
[[ "$mut_late_rc" -eq 2 && -s "$TMP/ssh.log" ]] || { echo 'FAIL M2 late-resolution mutant was not detected' >&2; exit 1; }
grep -q "parent job 'P-no-task' has no task_id" <<<"$mut_late_out" || {
  echo 'FAIL M2 lost the task resolution refusal' >&2; exit 1;
}
printf '%s\n' 'PASS wrk-remote-task M2-late-resolution-red-then-restored-green'

printf '%s\n' 'PASS wrk-remote-task mutants-red=2/2'
