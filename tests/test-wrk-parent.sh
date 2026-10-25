#!/usr/bin/env bash
# hk2042 parent completion contract tests: wrk spawn --task binds the handoffkeep task and the
# arbiter job. Every AC maps to cases below; the MUT section at the end runs
# assertion-RED mutants — sed'd copies of bin/wrk that drop each call site —
# so a silently removed linkage step fails the suite instead of drifting.
set -euo pipefail
# hk 1894: trust-bearing wrk and arbiter commands honour this suite's temp-dir overrides
# (HOME, ARBITER_INBOX_ROOT, XDG_DATA_HOME, HANDOFFKEEP_BIN) only in test mode.
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="${WRK_UNDER_TEST:-$ROOT/bin/wrk}"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="$ROOT/bin/arbiter"
PANEWIRE="$ROOT/tests/fixtures/panewire"
HK="$ROOT/tests/fixtures/handoffkeep"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wp2042.XXXXXX")"
# Keep an injected mutant inside THIS run's root so tmp-writers can prove
# ownership and stop its sentinels without a teardown failure masking RED.
if [[ -n "${WRK_UNDER_TEST:-}" ]]; then
  cp "$WRK" "$TMP/wrk-under-test"
  WRK="$TMP/wrk-under-test"
fi
# shellcheck disable=SC1091
. "$ROOT/tests/lib/tmp-writers.sh"
export TW_TMP="$TMP"

cleanup() {
  # kill alone does not suffice — a TERM'd writer can still be mid-append,
  # and refresh_quota_pool's detached supervisor plus its scopefuel child
  # outlive their wrk. A dentry recreated while rm walks the tree makes
  # rm -rf exit "Directory not empty" (CI runs 36283072131/36288704921).
  # tests/lib/tmp-writers.sh reaps each one by an exact verified pid —
  # completion-sentinel.pid / quota-refresh.pid / the WRK_REFRESH_PID_LOG
  # registry / a descendant walk — never a process-table pattern match.
  local tw_rc=0
  tmp_writers_stop || tw_rc=$?
  (( tw_rc == 0 )) && rm -rf "$TMP"
  if [[ "$tw_rc" -ne 0 || -n "${TW_LEFTOVER_PIDS:-}" ]]; then
    echo "FAIL: tracked writers survived teardown:${TW_LEFTOVER_PIDS:-}" >&2
    exit 1
  fi
}
trap cleanup EXIT

PROMPT="$TMP/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"
export CLINEPASS_GATE_KEY_FILE="$TMP/clinepass-gate-key.txt"
printf 'fixture-gate-key\n' >"$CLINEPASS_GATE_KEY_FILE"
# #951: MODEL is parameterizable; a claude-kind MODEL would seed folder trust
# into ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json — fixture HOME keeps the
# operator's real config untouched either way.
export HOME="$TMP/home"
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR
export XDG_CONFIG_HOME="$TMP/config" XDG_DATA_HOME="$TMP/data"
export XDG_CACHE_HOME="$TMP/cache" XDG_STATE_HOME="$TMP/state" XDG_RUNTIME_DIR="$TMP/runtime"
export CODEX_HOME="$TMP/codex" ARBITER_INBOX_ROOT="$TMP/inbox" TMPDIR="$TMP"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" \
  "$XDG_RUNTIME_DIR" "$CODEX_HOME" "$ARBITER_INBOX_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Per-case sandbox roots so claim events and the fixture db never bleed
# between cases. reset_case NAME rotates them.
INBOX="" HK_DB="" HK_LOG="" HERDR_LOG=""
reset_case() {
  INBOX="$TMP/inbox-$1"; HK_DB="$TMP/hk-$1.json"; HK_LOG="$TMP/hk-$1.log"
  HERDR_LOG="$TMP/herdr-$1.log"
  mkdir -p "$INBOX"
  HK_STATE="$HK_DB" "$HK" tasks add --id 1 --title "case task" --lane fixture >/dev/null
}

hk_add() { HK_STATE="$HK_DB" "$HK" tasks add "$@"; }
hk_show() { HK_STATE="$HK_DB" "$HK" tasks show "$1"; }
hk_field() { hk_show "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get(sys.argv[1]) or "")' "$2"; }
hk_refs_job() { hk_show "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("refs") or {}).get("job_id") or "")'; }
claim_count() { if [[ -f "$HK_LOG" ]]; then grep -c '^claim ' "$HK_LOG" || true; else echo 0; fi; }

event_payload() {
  python3 - "$INBOX/$1/events" "$2" <<'PY'
import glob, json, sys
files = sorted(glob.glob(sys.argv[1] + "/*-" + sys.argv[2] + ".json"))
print(json.dumps(json.load(open(files[-1]))["payload"]) if files else "")
PY
}

# spawn_try [-e NAME=VAL ...] -- <wrk args>: run one spawn; rc in SPAWN_RC,
# stderr in $TMP/stderr[-$OUT_TAG].txt. Never aborts on a nonzero exit.
# Case knobs (set as call-prefix vars): SCENARIO, HK_MODE, LABEL, OUT_TAG,
# SKIP_RESET_LOGS (concurrency cases manage truncation themselves).
SPAWN_RC=0
spawn_try() {
  local extra_env=()
  while [[ "${1:-}" == "-e" ]]; do extra_env+=("$2"); shift 2; done
  [[ "${1:-}" == "--" ]] && shift
  local err_file="$TMP/stderr${OUT_TAG:+-$OUT_TAG}.txt"
  local out_file="$TMP/stdout${OUT_TAG:+-$OUT_TAG}.txt"
  if [[ -z "${SKIP_RESET_LOGS:-}" ]]; then : >"$err_file"; : >"$HERDR_LOG"; rm -f "$HK_LOG"; fi
  set +e
  # -u scrubs the ambient session env: a builder/tester run of this suite is
  # itself a spawned job and would otherwise inherit ARBITER_JOB/HK_TASK_ID.
  env -u ARBITER_JOB -u HK_TASK_ID \
    HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    XDG_DATA_HOME="$TMP/xdg-$RANDOM" ARBITER_INBOX_ROOT="$INBOX" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE="${HK_MODE:-new}" \
    HK_LOG="$HK_LOG" PANEWIRE_BIN="$PANEWIRE" \
    WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO="${SCENARIO:-spawn}" WRK_FIXTURE_LOG="$HERDR_LOG" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
    WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml" \
    "${extra_env[@]+"${extra_env[@]}"}" \
    "$WRK" spawn -c "$ROOT" -m "${MODEL:-codex-luna}" -p "$PROMPT" -w w \
      -l "${LABEL:-fixture}" --t T1 "$@" </dev/null >"$out_file" 2>"$err_file"
  SPAWN_RC=$?
  set -e
  SCENARIO="" HK_MODE="" LABEL="" OUT_TAG="" SKIP_RESET_LOGS="" MODEL=""
}

expect_rc() {
  local want="$1" what="$2"
  [[ "$SPAWN_RC" -eq "$want" ]] ||
    fail "$what: expected rc $want, got $SPAWN_RC: $(tail -n 3 "$TMP/stderr${OUT_TAG:+-$OUT_TAG}.txt" 2>/dev/null)"
}
expect_grep() { grep -q -- "$1" "$2" || fail "$3 (missing '$1' in $2: $(tail -n 3 "$2" 2>/dev/null))"; }
no_job_dir() { [[ ! -d "$INBOX/$1" ]] || fail "$2 (unexpected job dir $INBOX/$1)"; }
no_pane() { [[ ! -s "$HERDR_LOG" ]] || fail "$1 (unexpected herdr calls: $(cat "$HERDR_LOG"))"; }
no_claim() { [[ "$(claim_count)" -eq 0 ]] || fail "$1 (hk claim ran: $(cat "$HK_LOG"))"; }
rebind_count() { if [[ -f "$HK_LOG" ]]; then grep -c '^rebind ' "$HK_LOG" || true; else echo 0; fi; }
job_event_doc() {
  python3 - "$INBOX/$1/events" "$2" <<'PY'
import glob, json, sys
files = sorted(glob.glob(sys.argv[1] + "/*-" + sys.argv[2] + ".json"))
if files:
    doc = json.load(open(files[-1]))
    print(json.dumps(doc.get("payload", doc)))
else:
    print("")
PY
}
# hk 2042: a tester completion must route to the newest parent owner.
reset_case parent-owner
mkdir -p "$INBOX/parent/events"
printf '%s\n' '{"kind":"job.claim","payload":{"task_id":1,"owner_lane":"builder-old"}}' \
  >"$INBOX/parent/events/00001-job.claim.json"
printf '%s\n' '{"kind":"job.reclaim","payload":{"task_id":1,"owner_lane":"builder-current"}}' \
  >"$INBOX/parent/events/00002-job.reclaim.json"
spawn_try -- --role tester --parent-job parent --job child --report "$INBOX/parent/verdict.md"
expect_rc 0 "parent-job tester with parent report"
python3 - "$INBOX/child/completion-sentinel.pid" "$INBOX/parent/verdict.md" <<'LOCAL_PATH'
from pathlib import Path
import subprocess, sys
pid = Path(sys.argv[1]).read_text().split()[0]
command = subprocess.check_output(["ps", "-p", pid, "-o", "command="], text=True)
assert sys.argv[2] in command, "local sentinel report path: " + command
LOCAL_PATH
claim_payload="$(event_payload child job.claim)"
grep -qE '"owner_lane" *: *"builder-current"' <<<"$claim_payload" ||
  fail "hk2042 parent owner must use newest reclaim, got: $claim_payload"
grep -qE '"task_inherited_from" *: *"parent"' <<<"$claim_payload" ||
  fail "hk2042 parent task provenance must remain intact"
echo "PASS hk2042 newest parent owner inherited"

# Stable report + done/idle must reach the inherited lane through the real
# completion sentinel and existing herdr/panewire fixtures.
tw_kill_pidfile "$INBOX/child/completion-sentinel.pid"
printf 'done\n' >"$TMP/get-sequence"
printf 'VERDICT: PASS @%040d\n' 0 >"$INBOX/parent/verdict.md"
for status in "done" idle; do
  child="completion-$status"
  spawn_try -- --role tester --parent-job parent --job "$child" --report "$INBOX/parent/verdict.md"
  expect_rc 0 "$status tester spawn"
  tw_kill_pidfile "$INBOX/$child/completion-sentinel.pid"
  printf '%s\n' "$status" >"$TMP/get-sequence"
  env HERDR_BIN="$HERDR" PANEWIRE_BIN="$PANEWIRE" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$TMP/sentinel-xdg" \
    WRK_PANEWIRE_LOG="$TMP/relay-$status.log" WRK_FIXTURE_GET_SEQUENCE="$TMP/get-sequence" \
    WRK_COMPLETION_INTERVAL_S=0 WRK_COMPLETION_TIMEOUT_S=0 WRK_NO_SLEEP=1 \
    "$WRK" sentinel "$child" builder-current fixture w:p1 "$INBOX/parent/verdict.md" \
    >"$TMP/sentinel-$status.out" 2>"$TMP/sentinel-$status.err"
  completed="$(job_event_doc "$child" job.completed)"
  grep -qE '"owner_lane" *: *"builder-current"' <<<"$completed" || fail "completion owner missing: $completed"
  grep -q 'action=completed' "$INBOX/$child/completion-sentinel.log" || fail "sentinel must observe stable report"
done
echo "PASS hk2042 done/idle completion records name parent lane"

# The existing done-to-panewire relay must use that same inherited owner.
spawn_try -- --role tester --parent-job parent --job relay-child --report "$INBOX/parent/relay.md"
expect_rc 0 "relay tester spawn"
printf 'tester relay report\n' >"$INBOX/parent/relay.md"
env HERDR_BIN="$HERDR" PANEWIRE_BIN="$PANEWIRE" ARBITER_BIN="$ARBITER" \
  ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$TMP/relay-xdg" \
  WRK_PANEWIRE_LOG="$TMP/relay.log" \
  "$WRK" 'done' relay-child --report "$INBOX/parent/relay.md" >"$TMP/done.out" 2>"$TMP/done.err"
python3 - "$TMP/relay.log" <<'RELAY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
assert lines[0] == "emit", lines
assert lines[lines.index("--owner-lane") + 1] == "builder-current", lines
assert lines[lines.index("--kind") + 1] == "job.completed", lines
RELAY
echo "PASS hk2042 completion relay targets parent lane"

spawn_try -- --parent-job parent --job explicit-child --owner director-explicit --report "$INBOX/explicit-child/report.md"
expect_rc 0 "explicit owner and own-job report"
claim_payload="$(event_payload explicit-child job.claim)"
grep -qE '"owner_lane" *: *"director-explicit"' <<<"$claim_payload" || fail "explicit owner must win"
tw_kill_pidfile "$INBOX/explicit-child/completion-sentinel.pid"
echo "PASS hk2042 explicit owner wins and own-job report accepted"

# Each refusal precedes pane, job, task writes and quota admission. Capture the
# missing-report error as exactly one line, before the trust-mode warning.
for role in worker tester reviewer; do
  spawn_try -- --role "$role" --parent-job parent --job missing-report
  expect_rc 2 "missing report for $role"
  [[ "$(wc -l <"$TMP/stderr.txt" | tr -d ' ')" == 1 ]] || fail "missing report must give one line"
  expect_grep 'requires --report' "$TMP/stderr.txt" "missing report refusal"
  no_job_dir missing-report "missing report"; no_pane "missing report"; no_claim "missing report"
done
mkdir -p "$TMP/outside" "$INBOX/parent/sub"
ln -s "$TMP/outside" "$INBOX/parent/link"
ln -s "$TMP/outside/verdict.md" "$INBOX/parent/symlink.md"
for path in /tmp/hk2042-verdict.md "$TMP/outside/report.md" "$INBOX/parent/link/report.md" \
  "$INBOX/parent/symlink.md" "$INBOX/parent/sub/../../escape.md" relative.md; do
  spawn_try -- --parent-job parent --job bad-report --owner explicit --report "$path"
  expect_rc 2 "report outside allowed job directories: $path"
  expect_grep '\--report' "$TMP/stderr.txt" "report refusal"
  no_job_dir bad-report "bad report"; no_pane "bad report"; no_claim "bad report"
done
for path in parent/../escape.md /tmp/absolute.md other/report.md; do
  spawn_try -- --parent-job parent --job bad-relative --owner explicit --report-relative "$path"
  expect_rc 2 "bad relative report: $path"
  no_job_dir bad-relative "bad relative report"; no_pane "bad relative report"
done
spawn_try -- --parent-job parent --job relative-child --report-relative parent/relative.md
expect_rc 0 "relative report re-roots locally"
tw_kill_pidfile "$INBOX/relative-child/completion-sentinel.pid"
echo "PASS hk2042 report refusals and relative report re-root"

spawn_try -e HK_TASK_ID=1 -- --parent-job absent-parent --job no-parent --report "$INBOX/absent-parent/report.md"
expect_rc 2 "missing parent claim cannot fall back to HK_TASK_ID for ownership"
expect_grep 'no readable newest claim/reclaim' "$TMP/stderr.txt" "missing claim refusal"
no_job_dir no-parent "missing parent"; no_job_dir absent-parent "missing parent read cannot write"
no_pane "missing parent"; no_claim "missing parent"
echo "PASS hk2042 missing parent refuses without writes"

# Mutations change the actual production call sites. The same assertion suite
# must fail with a named FAIL, never an interpreter error or a bad patch.
if [[ "${WRK_PARENT_MUTANT:-0}" != 1 ]]; then
  for mutant in owner required containment; do
    mutant_path="$TMP/wrk-$mutant"
    python3 - "$WRK" "$mutant_path" "$mutant" <<'MUT'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
kind = sys.argv[3]
if kind == "owner":
    old = '        owner = inherited_owner\n'
    replacement = '        owner = "default"\n'
elif kind == "required":
    old = '    worker|tester|reviewer) [[ -n "$report" ]] || die "--parent-job $parent requires --report for --role $role" ;; # hk2042-report-required\n'
    replacement = '    worker|tester|reviewer) : ;; # mutant accepts missing report\n'
else:
    old = '    if not any(base in path.parents for base in allowed): # hk2042-target-containment\n'
    replacement = '    if False: # mutant skips target containment\n'
assert source.count(old) == 1, kind
Path(sys.argv[2]).write_text(source.replace(old, replacement, 1))
MUT
    chmod +x "$mutant_path"
    mutant_rc=0
    WRK_PARENT_MUTANT=1 WRK_UNDER_TEST="$mutant_path" bash "$ROOT/tests/test-wrk-parent.sh" >"$TMP/mutant-$mutant.log" 2>&1 || mutant_rc=$?
    [[ "$mutant_rc" -ne 0 ]] || fail "$mutant mutant survived"
    case "$mutant" in
      owner) expected='FAIL: hk2042 parent owner must use newest reclaim' ;;
      required) expected='FAIL: missing report for worker: expected rc 2, got 0' ;;
      containment) expected='FAIL: report outside allowed job directories: /tmp/hk2042-verdict.md: expected rc 2, got 0' ;;
    esac
    grep -qF "$expected" "$TMP/mutant-$mutant.log" || fail "$mutant mutant missed its contract assertion: $(tail -n 5 "$TMP/mutant-$mutant.log")"
    ! grep -q 'tracked writers survived teardown' "$TMP/mutant-$mutant.log" || fail "$mutant left writers alive"
    echo "PASS hk2042 $mutant mutant assertion RED"
  done
fi
echo "PASS hk2042 parent-job completion contract"
