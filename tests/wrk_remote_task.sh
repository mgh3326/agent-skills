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

# shellcheck disable=SC1091
. "$ROOT/tests/lib/tmp-writers.sh"
export TW_TMP="$TMP"
cleanup() {
  local rc=0
  tmp_writers_stop || rc=$?
  (( rc == 0 )) && rm -rf "$TMP"
  if (( rc != 0 )); then exit 1; fi
}
trap cleanup EXIT

export HK_STATE="$TMP/hk-state.json"
"$HK_FIXTURE" tasks add --id 1489 --title 'remote inherited task' --lane fixture >/dev/null
"$HK_FIXTURE" tasks add --id 9 --title 'explicit remote task' --lane fixture >/dev/null
"$HK_FIXTURE" tasks add --id 10 --title 'builder task' --lane fixture >/dev/null
"$HK_FIXTURE" tasks add --id 11 --title 'second builder task' --lane fixture >/dev/null
"$HK_FIXTURE" tasks add --id 12 --title 'third builder task' --lane fixture >/dev/null
"$HK_FIXTURE" tasks add --id 13 --title 'fourth builder task' --lane fixture >/dev/null
"$HK_FIXTURE" tasks add --id 14 --title 'fifth builder task' --lane fixture >/dev/null

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
export ARBITER_BIN="${WRK_REMOTE_ARBITER_BIN:-$root/bin/arbiter}"
export WRK_T10_REAL_ARBITER="$root/bin/arbiter"
export HANDOFFKEEP_BIN="$root/tests/fixtures/handoffkeep"
export HK_STATE="$tmp/hk-state.json"
export HERDR_BIN="$root/tests/fixtures/spillover-herdr"
export SCOPEFUEL_BIN="$root/tests/fixtures/scopefuel"
export PANEWIRE_BIN="${WRK_REMOTE_PANEWIRE_BIN:-$root/tests/fixtures/spillover-panewire}"
export WRK_HOSTS_CONFIG="${WRK_REMOTE_HOSTS_CONFIG:-$tmp/hosts.toml}"
export WRK_PANEWIRE_LANES_LOG="${WRK_REMOTE_LANES_LOG:-}"
export WRK_PROC_LOADAVG="$tmp/loadavg" WRK_TEST_NCPU=4 WRK_TEST_THROTTLED=0 WRK_NO_SLEEP=1
export WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$tmp/remote-herdr.log"
export WRK_SPILLOVER_LOG="$tmp/remote-spillover.log"
export WRK_SSH_BIN="$root/tests/fixtures/spillover-ssh" WRK_SCP_BIN="$root/tests/fixtures/spillover-scp"
export WRK_SSH_LOG="$tmp/remote-ssh.log" WRK_SCP_LOG="$tmp/remote-scp.log"
exec "${WRK_REMOTE_BINARY:-$root/bin/wrk}" "$@"
REMOTE_WRK
chmod +x "$TMP/remote-bin/wrk"

run_remote() {
  local binary="$1"; shift
  local model="${WRK_CASE_MODEL:-codex-luna}" label="${WRK_CASE_LABEL:-remote-child}"
  local job="${WRK_CASE_JOB:-remote-$RANDOM-$RANDOM}" config="${WRK_CASE_CONFIG:-$CONFIG}"
  local report_args=() arg
  for arg in "$@"; do
    if [[ "$arg" == --parent-job ]]; then
      report_args=(--report "$ARBITER_INBOX_ROOT/P/verdict.md"); break
    fi
  done
  env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
    XDG_STATE_HOME="$XDG_STATE_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" HERDR_BIN="$ROOT/tests/fixtures/spillover-herdr" \
    SCOPEFUEL_BIN="$ROOT/tests/fixtures/scopefuel" ARBITER_BIN="$ROOT/bin/arbiter" \
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
    WRK_REMOTE_BINARY="${WRK_CASE_REMOTE_BINARY:-}" \
    WRK_REMOTE_HOSTS_CONFIG="${WRK_CASE_REMOTE_CONFIG:-}" \
    WRK_REMOTE_LANES_LOG="${WRK_CASE_REMOTE_LANES_LOG:-}" \
    WRK_REMOTE_PANEWIRE_BIN="${WRK_CASE_REMOTE_PANEWIRE_BIN:-}" \
    WRK_REMOTE_ARBITER_BIN="${WRK_CASE_REMOTE_ARBITER_BIN:-}" \
    WRK_PANEWIRE_LANES_LS="${WRK_CASE_REMOTE_LANES_LS:-}" \
    WRK_T10_PANEWIRE_FIXTURE="${WRK_CASE_T10_PANEWIRE_FIXTURE:-}" \
    WRK_T10_PANEWIRE_STATE="${WRK_CASE_T10_PANEWIRE_STATE:-}" \
    "$binary" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w workers -l "$label" --t T1 --job "$job" "${report_args[@]+"${report_args[@]}"}" "$@"
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
python3 - "$TMP/ssh.argv0" "$TMP/remote-inbox/jobs/P/verdict.md" <<'PY'
import shlex, sys

records = [record.split(b"\0") for record in open(sys.argv[1], "rb").read().split(b"\0\0") if record]
spawn = next(record[-1].decode() for record in reversed(records) if b"wrk spawn" in record[-1])
command = spawn.split("; rc=$?;", 1)[0]
argv = shlex.split(command)
assert argv[:3] == ["env", "HERDR_SESSION=worker", "HK_TASK_ID=1489"], argv
assert argv.count("HK_TASK_ID=1489") == 1, argv
assert argv[argv.index("--parent-job") + 1] == "P", argv
assert argv.count("--owner") == 1 and argv[argv.index("--owner") + 1] == "fixture", "hk2042 missing transported parent owner: %r" % argv
assert argv.count("--report-relative") == 1 and argv[argv.index("--report-relative") + 1] == "P/verdict.md", "hk2042 relative report changed: %r" % argv
PY
# The actual target sentinel, not just the wire argv, watches the target path.
python3 - "$TMP/remote-inbox/jobs/t1-remote/completion-sentinel.pid" "$TMP/remote-inbox/jobs/P/verdict.md" <<'PATHCHECK'
import pathlib, shlex, subprocess, sys
pid = pathlib.Path(sys.argv[1]).read_text().split()[0]
command = subprocess.check_output(["ps", "-p", pid, "-o", "command="], text=True)
args = shlex.split(command)
# wrk resolves the inbox; macOS /var and /tmp are aliases of /private paths.
assert args[args.index("sentinel") + 5] == str(pathlib.Path(sys.argv[2]).resolve()), "hk2042 target sentinel report path: " + command
PATHCHECK
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

MUT_OWNER="$TMP/wrk-owner-dropped"
python3 - "$ROOT/bin/wrk" "$MUT_OWNER" <<'OWNER_MUT'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
line = '  [[ -z "${SPILL_REMOTE_OWNER:-}" ]] || remote_args+=(--owner "$SPILL_REMOTE_OWNER") # hk2042-ssh-owner\n'
assert source.count(line) == 1
Path(sys.argv[2]).write_text(source.replace(line, "", 1))
OWNER_MUT
chmod +x "$MUT_OWNER"
set +e
owner_out="$(WRK_CASE_JOB=owner-dropped run_remote "$MUT_OWNER" --host desktop --parent-job P 2>&1)"
owner_rc=$?
set -e
[[ "$owner_rc" -ne 0 ]] || { echo 'FAIL owner-drop mutant survived' >&2; exit 1; }
grep -q "parent job 'P' has no readable newest claim/reclaim" <<<"$owner_out" || {
  echo 'FAIL owner-drop mutant missed parent-owner refusal' >&2; exit 1;
}
printf '%s\n' 'PASS wrk-remote-task owner-transport-mutant-RED'

# Invalid wire paths and outside absolute reports refuse on the initiator.
for path in P/../escape.md /tmp/absolute.md; do
  : >"$TMP/ssh.log"
  rc=0
  run_remote "$ROOT/bin/wrk" --host desktop --parent-job P --report-relative "$path" >"$TMP/bad-relative.out" 2>&1 || rc=$?
  [[ "$rc" -eq 2 && ! -s "$TMP/ssh.log" ]] || { echo 'FAIL invalid relative report reached SSH' >&2; exit 1; }
done
: >"$TMP/ssh.log"
rc=0
run_remote "$ROOT/bin/wrk" --host desktop --parent-job P --report /tmp/outside.md >"$TMP/bad-report.out" 2>&1 || rc=$?
[[ "$rc" -eq 2 && ! -s "$TMP/ssh.log" ]] || { echo 'FAIL /tmp report reached SSH' >&2; exit 1; }
printf '%s\n' 'PASS wrk-remote-task report-refusals-before-SSH'
# An initiator-safe path can escape through a TARGET-only symlink. The target
# must repeat containment; this mutant changes only the target executable.
mkdir -p "$TMP/remote-inbox/jobs/P" "$TMP/target-outside"
ln -s "$TMP/target-outside" "$TMP/remote-inbox/jobs/P/escape"
target_containment_probe() {
  local binary="$1" rc=0
  WRK_CASE_REMOTE_BINARY="$binary" WRK_CASE_JOB=target-containment \
    run_remote "$ROOT/bin/wrk" --host desktop --parent-job P \
    --report-relative P/escape/verdict.md >"$TMP/target-containment.out" 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] || { echo 'FAIL target-only symlink containment was skipped' >&2; return 1; }
  grep -q 'must resolve under the parent or new job directory' "$TMP/target-containment.out" || {
    echo 'FAIL target containment refusal was missing' >&2; return 1;
  }
}
target_containment_probe "$ROOT/bin/wrk"
MUT_TARGET="$TMP/wrk-target-containment"
python3 - "$ROOT/bin/wrk" "$MUT_TARGET" <<'TARGET_MUT'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
old = '    if not any(base in path.parents for base in allowed): # hk2042-target-containment\n'
assert source.count(old) == 1
Path(sys.argv[2]).write_text(source.replace(old, '    if False: # target containment mutant\n', 1))
TARGET_MUT
chmod +x "$MUT_TARGET"
if target_containment_probe "$MUT_TARGET" >"$TMP/target-mutant.log" 2>&1; then
  echo 'FAIL target containment mutant survived' >&2; exit 1
fi
grep -q '^FAIL target-only symlink containment was skipped' "$TMP/target-mutant.log" || {
  echo 'FAIL target containment mutant did not fail the contract assertion' >&2; exit 1;
}
printf '%s\n' 'PASS wrk-remote-task target-containment-mutant-RED'

printf '%s\n' 'PASS wrk-remote-task mutants-red=4/4'

# T6 (hk 1446): a REAL remote wrk on the target holds a lanes token bound
# to the hosts.toml key the initiator reached it by — it self-registers
# the builder lane with that node token, prints lane_registered=self on
# its OK pane= line, and the initiator makes no lanes call of its own.
# The initiator keeps a fully configured [hub] (operator credential) so
# the zero lanes traffic is attributable to the marker alone.
T6_TOKEN="$TMP/t6-lanes.env"
printf 'HUB_MACHINE_ID=desktop\nHUB_TOKEN=fixture-t6-node-token\n' >"$T6_TOKEN"
chmod 600 "$T6_TOKEN"
T6_OP="$TMP/t6-operator.env"
printf 'OPERATOR_TOKEN=fixture-t6-operator-token\n' >"$T6_OP"
chmod 000 "$T6_OP"
T6_REMOTE_CONFIG="$TMP/t6-remote-hosts.toml"
printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
  '[hub]' 'hub_url = "https://hub.invalid"' \
  "lanes_token_env = \"$T6_TOKEN\"" 'machine_id = "desktop"' >"$T6_REMOTE_CONFIG"
T6_INIT_CONFIG="$TMP/t6-init-hosts.toml"
printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
  '[hub]' 'hub_url = "https://hub.invalid"' \
  "operator_token_env = \"$T6_OP\"" 'machine_id = "mac-personal"' '' \
  '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
  "cwd_map = {\"$ROOT\"=\"$REMOTE_CWD\"}" 'capacity = 3' >"$T6_INIT_CONFIG"
: >"$TMP/ssh.log"; : >"$TMP/scp.log"; : >"$TMP/wake.log"
t6_out="$(WRK_CASE_MODEL=builder-sol WRK_CASE_LABEL=t6b WRK_CASE_JOB=t6-builder \
  WRK_CASE_CONFIG="$T6_INIT_CONFIG" WRK_CASE_REMOTE_CONFIG="$T6_REMOTE_CONFIG" \
  WRK_CASE_REMOTE_PANEWIRE_BIN="$ROOT/tests/fixtures/panewire" \
  WRK_CASE_REMOTE_LANES_LOG="$TMP/t6-remote-lanes.log" \
  run_remote "$ROOT/bin/wrk" --host desktop --role builder --lane b1446-t6 --parent director-1 --task 10 2>&1)"
grep -q ' lane=b1446-t6@desktop$' <<<"$t6_out" || {
  echo 'FAIL T6 emitted line must end lane=b1446-t6@desktop' >&2; printf '%s\n' "$t6_out" >&2; exit 1;
}
! grep -q 'lane_registered' <<<"$t6_out" || {
  echo 'FAIL T6 the consumed marker reached the emitted line' >&2; exit 1;
}
grep -q -- '--lane-defer desktop' "$TMP/ssh.log" || {
  echo 'FAIL T6 the delegated spawn must carry --lane-defer desktop' >&2; exit 1;
}
! grep -q 'lanes' "$TMP/wake.log" || {
  echo 'FAIL T6 the initiator made a lanes call despite the marker' >&2
  cat "$TMP/wake.log" >&2; exit 1;
}
python3 - "$TMP/t6-remote-lanes.log" "$T6_TOKEN" <<'PY' || {
import sys
log, token = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("the remote wrk made no lanes call")
want = ["add", "b1446-t6", "--machine", "desktop", "--pane", "w:p1",
        "--parent", "director-1", "--hub-url", "https://hub.invalid",
        "--hub-token-env", token, "--"]
assert got == want, "remote self-add argv mismatch: got=%r want=%r" % (got, want)
PY
  echo 'FAIL T6 the remote wrk must self-add once with its lanes token' >&2; exit 1;
}
# The remote job's receipt records the same lane+machine the deferral
# would, so reap on the execution host removes it through the same guard.
python3 - "$TMP/remote-inbox/jobs" <<'PY' || {
import glob, json, sys
paths = glob.glob(sys.argv[1] + "/t6-builder/events/*job.spawned.json")
assert len(paths) == 1, paths
meta = json.load(open(paths[0]))["payload"]
assert meta.get("hub_lane") == "b1446-t6" and meta.get("hub_lane_machine") == "desktop", meta
PY
  echo 'FAIL T6 remote receipt must record lane+machine' >&2; exit 1;
}
printf '%s\n' 'PASS wrk-remote-task T6-remote-self-registers-with-lanes-token'

# T7 (hk 1446): the same end-to-end delegation WITHOUT a lanes token on
# the target keeps today's contract byte-for-byte — the remote wrk
# defers and the initiator registers the lane itself.
T7_INIT_CONFIG="$TMP/t7-init-hosts.toml"
printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
  '[hub]' 'hub_url = "https://hub.invalid"' \
  "operator_token_env = \"$T6_OP\"" 'machine_id = "mac-personal"' '' \
  '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
  "cwd_map = {\"$ROOT\"=\"$REMOTE_CWD\"}" 'capacity = 3' >"$T7_INIT_CONFIG"
T7_REMOTE_CONFIG="$TMP/t7-remote-hosts.toml"
printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
  '[hub]' 'hub_url = "https://hub.invalid"' 'machine_id = "desktop"' >"$T7_REMOTE_CONFIG"
: >"$TMP/ssh.log"; : >"$TMP/scp.log"; : >"$TMP/wake.log"
t7_out="$(WRK_CASE_MODEL=builder-sol WRK_CASE_LABEL=t7b WRK_CASE_JOB=t7-builder \
  WRK_CASE_CONFIG="$T7_INIT_CONFIG" WRK_CASE_REMOTE_CONFIG="$T7_REMOTE_CONFIG" \
  WRK_CASE_REMOTE_PANEWIRE_BIN="$ROOT/tests/fixtures/panewire" \
  run_remote "$ROOT/bin/wrk" --host desktop --role builder --lane b1446-t7 --parent director-1 --task 11 2>&1)"
grep -q ' lane=b1446-t7@desktop$' <<<"$t7_out" || {
  echo 'FAIL T7 emitted line must end lane=b1446-t7@desktop' >&2; printf '%s\n' "$t7_out" >&2; exit 1;
}
python3 - "$TMP/wake.log" "$T6_OP" <<'PY' || {
import sys
log, op = sys.argv[1:]
lines = [l.split() for l in open(log, encoding="utf-8")]
adds = [l for l in lines if l[:2] == ["lanes", "add"]]
assert len(adds) == 1, "exactly one initiator lanes add expected: %r" % lines
argv = adds[0]
assert argv[argv.index("--machine") + 1] == "desktop", argv
assert argv[argv.index("--hub-token-env") + 1] == op, argv
PY
  echo 'FAIL T7 the initiator must add the deferred lane itself' >&2
  cat "$TMP/wake.log" >&2; exit 1;
}
printf '%s\n' 'PASS wrk-remote-task T7-tokenless-remote-defers-to-initiator'

# T8 (hk 1446 regression): a remote node token with a trailing space in
# HUB_MACHINE_ID is not a byte match for the deferred machine id. The remote
# must defer without adding or printing lane_registered=self; the initiator
# then performs its ordinary operator-authenticated add.
T8_TOKEN="$TMP/t8-lanes.env"
printf 'HUB_MACHINE_ID=desktop \nHUB_TOKEN=fixture-t8-node-token\n' >"$T8_TOKEN"
chmod 600 "$T8_TOKEN"
T8_REMOTE_CONFIG="$TMP/t8-remote-hosts.toml"
printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
  '[hub]' 'hub_url = "https://hub.invalid"' \
  "lanes_token_env = \"$T8_TOKEN\"" 'machine_id = "desktop"' >"$T8_REMOTE_CONFIG"
: >"$TMP/ssh.log"; : >"$TMP/scp.log"; : >"$TMP/wake.log"
t8_out="$(WRK_CASE_MODEL=builder-sol WRK_CASE_LABEL=t8b WRK_CASE_JOB=t8-builder \
  WRK_CASE_CONFIG="$T7_INIT_CONFIG" WRK_CASE_REMOTE_CONFIG="$T8_REMOTE_CONFIG" \
  WRK_CASE_REMOTE_PANEWIRE_BIN="$ROOT/tests/fixtures/panewire" \
  WRK_CASE_REMOTE_LANES_LOG="$TMP/t8-remote-lanes.log" \
  run_remote "$ROOT/bin/wrk" --host desktop --role builder --lane b1446-t8 --parent director-1 --task 12 2>&1)"
grep -q ' lane=b1446-t8@desktop$' <<<"$t8_out" || {
  echo 'FAIL T8 emitted line must end lane=b1446-t8@desktop' >&2; printf '%s\n' "$t8_out" >&2; exit 1;
}
! grep -q 'lane_registered=self' <<<"$t8_out" || {
  echo 'FAIL T8 trailing-space machine id must not self-register' >&2; exit 1;
}
[[ ! -s "$TMP/t8-remote-lanes.log" ]] || {
  echo 'FAIL T8 remote lanes token with trailing-space machine id must defer' >&2
  cat "$TMP/t8-remote-lanes.log" >&2; exit 1;
}
python3 - "$TMP/wake.log" "$T6_OP" <<'PY' || {
import sys
log, op = sys.argv[1:]
lines = [l.split() for l in open(log, encoding="utf-8")]
adds = [l for l in lines if l[:2] == ["lanes", "add"]]
assert len(adds) == 1, "the initiator must add exactly once: %r" % lines
argv = adds[0]
assert argv[argv.index("--machine") + 1] == "desktop", argv
assert argv[argv.index("--hub-token-env") + 1] == op, argv
PY
  echo 'FAIL T8 the initiator must add the unregistered remote lane' >&2
  cat "$TMP/wake.log" >&2; exit 1;
}
printf '%s\n' 'PASS wrk-remote-task T8-trailing-space-machine-id-defers'

# T9 (hk 1446 B1): if the execution host has a matching lanes token but no
# arbiter job record, it must defer exactly as before. The initiator still
# adds the lane; that pre-existing orphan risk is out of scope.
: >"$TMP/ssh.log"; : >"$TMP/scp.log"; : >"$TMP/wake.log"
t9_out="$(WRK_CASE_MODEL=builder-sol WRK_CASE_LABEL=t9b WRK_CASE_JOB=t9-builder \
  WRK_CASE_CONFIG="$T7_INIT_CONFIG" WRK_CASE_REMOTE_CONFIG="$T6_REMOTE_CONFIG" \
  WRK_CASE_REMOTE_PANEWIRE_BIN="$ROOT/tests/fixtures/panewire" \
  WRK_CASE_REMOTE_ARBITER_BIN="$TMP/no-remote-arbiter" \
  WRK_CASE_REMOTE_LANES_LOG="$TMP/t9-remote-lanes.log" \
  run_remote "$ROOT/bin/wrk" --host desktop --role builder --lane b1446-t9 --parent director-1 --task 13 2>&1)"
grep -q ' lane=b1446-t9@desktop$' <<<"$t9_out" || {
  echo 'FAIL T9 emitted line must end lane=b1446-t9@desktop' >&2; printf '%s\n' "$t9_out" >&2; exit 1;
}
! grep -q 'lane_registered=self' <<<"$t9_out" || {
  echo 'FAIL T9 a remote with no job record must not self-register' >&2; exit 1;
}
[[ ! -s "$TMP/t9-remote-lanes.log" ]] || {
  echo 'FAIL T9 a remote with no job record must make no lanes add' >&2
  cat "$TMP/t9-remote-lanes.log" >&2; exit 1;
}
python3 - "$TMP/wake.log" "$T6_OP" <<'PY' || {
import sys
log, op = sys.argv[1:]
lines = [l.split() for l in open(log, encoding="utf-8")]
adds = [l for l in lines if l[:2] == ["lanes", "add"]]
assert len(adds) == 1, "initiator must add once when no marker is returned: %r" % lines
argv = adds[0]
assert argv[argv.index("--machine") + 1] == "desktop", argv
assert argv[argv.index("--hub-token-env") + 1] == op, argv
PY
  echo 'FAIL T9 initiator should add the unmarked remote lane' >&2
  cat "$TMP/wake.log" >&2; exit 1;
}
printf '%s\n' 'PASS wrk-remote-task T9-no-job-record-defers-self-registration'

# T10 (hk 1446 B1): if job.spawned receipt creation fails after a successful
# self-add, the execution host must remove the row with its lanes token after
# confirming the same machine and pane. The failed spawn answers 2 and leaves
# no row in the stateful panewire fixture; an initiator-owned row is untouched.
T10_PANEWIRE="$TMP/t10-stateful-panewire"
T10_STATE="$TMP/t10-lane-present"
T10_FAIL_ARBITER="$TMP/t10-fail-spawned-arbiter"
cat >"$T10_PANEWIRE" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
fixture="${WRK_T10_PANEWIRE_FIXTURE:?}"
state="${WRK_T10_PANEWIRE_STATE:?}"
if [[ "${1:-}" == lanes && "${2:-}" == ls ]]; then
  if [[ -e "$state" ]]; then
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"b1446-t10","machine":"desktop","pane":"w:p1","parent":"director-1","sink":false}]}'
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
cat >"$T10_FAIL_ARBITER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == event ]]; then
  for argument in "$@"; do
    [[ "$argument" != job.spawned ]] || exit 3
  done
fi
exec "${WRK_T10_REAL_ARBITER:?}" "$@"
SH
chmod +x "$T10_PANEWIRE" "$T10_FAIL_ARBITER"
: >"$TMP/ssh.log"; : >"$TMP/scp.log"; : >"$TMP/wake.log"
set +e
t10_out="$(WRK_CASE_MODEL=builder-sol WRK_CASE_LABEL=t10b WRK_CASE_JOB=t10-builder \
  WRK_CASE_CONFIG="$T7_INIT_CONFIG" WRK_CASE_REMOTE_CONFIG="$T6_REMOTE_CONFIG" \
  WRK_CASE_REMOTE_PANEWIRE_BIN="$T10_PANEWIRE" \
  WRK_CASE_REMOTE_ARBITER_BIN="$T10_FAIL_ARBITER" \
  WRK_CASE_REMOTE_LANES_LOG="$TMP/t10-remote-lanes.log" \
  WRK_CASE_T10_PANEWIRE_FIXTURE="$ROOT/tests/fixtures/panewire" \
  WRK_CASE_T10_PANEWIRE_STATE="$T10_STATE" \
  run_remote "$ROOT/bin/wrk" --host desktop --role builder --lane b1446-t10 --parent director-1 --task 14 2>&1)"
t10_rc=$?
set -e
[[ "$t10_rc" -eq 2 ]] || {
  echo "FAIL T10 receipt failure must answer 2, got $t10_rc" >&2; printf '%s\n' "$t10_out" >&2; exit 1;
}
! grep -q '^OK pane=' <<<"$t10_out" || {
  echo 'FAIL T10 receipt failure must not print an OK line' >&2; exit 1;
}
[[ ! -e "$T10_STATE" ]] || {
  echo 'FAIL T10 guarded removal must leave no lane in the fixture' >&2; exit 1;
}
python3 - "$TMP/t10-remote-lanes.log" "$T6_TOKEN" <<'PY' || {
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
assert [c[0] for c in calls] == ["add", "ls", "rm"], calls
add, listing, remove = calls
assert add[1] == "b1446-t10" and add[add.index("--machine") + 1] == "desktop", add
assert add[add.index("--pane") + 1] == "w:p1", add
assert remove[1] == "b1446-t10", remove
for args in calls:
    assert args[args.index("--hub-token-env") + 1] == token, args
PY
  echo 'FAIL T10 expected one self-add followed by guarded ls and rm with the lanes token' >&2
  cat "$TMP/t10-remote-lanes.log" >&2; exit 1;
}
! grep -q 'lanes add' "$TMP/wake.log" || {
  echo 'FAIL T10 the initiator must not add after the failed remote receipt' >&2; exit 1;
}
printf '%s\n' 'PASS wrk-remote-task T10-receipt-failure-compensates-self-add'
