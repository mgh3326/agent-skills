#!/usr/bin/env bash
# #770 contract tests: job-end housekeeping across wrk + the prune command.
#
# AC1: every terminal path (wrk done — local and delegated — wrk joined,
#      the sentinel's own completed/lost judgements, wrk reap --apply) ends
#      the hub record and stops + waits on the completion sentinel and its
#      interval sleep child.
# AC2/AC3: `wrk prune` lists orphans and stale jobs read-only by default and
#      --apply touches only verified orphans — a sentinel on a live job, a
#      pidfile pointing at a reused pid, and anything unverifiable are never
#      signalled.
# AC4: the quota-refresh supervisor writes a bounded, traceable pidfile and
#      removes it on the way out; prune can still see a leftover.
#
# The MUT section at the end runs assertion-RED mutants — sed'd copies of
# bin/wrk that drop each call site — so a silently removed housekeeping step
# fails the suite instead of drifting.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="$ROOT/bin/arbiter"
PANEWIRE="$ROOT/tests/fixtures/panewire"
HK="$ROOT/tests/fixtures/handoffkeep"
TMP="$(mktemp -d)"

cleanup() {
  local pidfile pid child snap stray i
  while IFS= read -r pidfile; do
    [[ -s "$pidfile" ]] || continue
    read -r pid <"$pidfile" || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -STOP "$pid" 2>/dev/null || true
    while IFS= read -r child; do kill "$child" 2>/dev/null || true; done \
      < <(pgrep -P "$pid" 2>/dev/null || true)
    kill "$pid" 2>/dev/null || true
    kill -CONT "$pid" 2>/dev/null || true
  done < <(find "$TMP" -name 'completion-sentinel.pid' -o -name 'sentinel.pid' 2>/dev/null)
  # Detached supervisors and reparented sleeps all carry $TMP in their env;
  # sweep anything still holding it, excluding this shell and its children.
  for ((i = 0; i < 100; i++)); do
    snap="$(exec ps axeww -o pid= -o ppid= -o command= 2>/dev/null)" || true
    stray="$(awk -v self="$$" -v tmp="$TMP" \
      'index($0, tmp) && $1 != self && $2 != self {print $1}' <<<"$snap")" || true
    [[ -n "$stray" ]] || break
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      if ((i >= 50)); then kill -9 "$pid" 2>/dev/null || true; else kill "$pid" 2>/dev/null || true; fi
    done <<<"$stray"
    sleep 0.1
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

PROMPT="$TMP/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"
export CLINEPASS_GATE_KEY_FILE="$TMP/clinepass-gate-key.txt"
printf 'fixture-gate-key\n' >"$CLINEPASS_GATE_KEY_FILE"
export WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Per-case sandbox roots.
INBOX="" XDG="" HK_DB="" HERDR_LOG=""
reset_case() {
  INBOX="$TMP/inbox-$1"; XDG="$TMP/xdg-$1"; HK_DB="$TMP/hk-$1.json"
  HERDR_LOG="$TMP/herdr-$1.log"
  mkdir -p "$INBOX"
  HK_STATE="$HK_DB" "$HK" tasks add --id 1 --title "case task" --lane fixture >/dev/null
}

arb() { env ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" "$ARBITER" "$@"; }

# mk_job JOB [PANE] — claim + job.spawned receipt, the smallest live-job record.
mk_job() {
  arb claim --job "$1" --lane lane-a --agent-label lbl --t T1 >/dev/null
  arb event --job "$1" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl\",\"pane_id\":\"${2:-w:p1}\"}" >/dev/null
}

mk_builder_job() {
  arb claim --job "$1" --lane builder-lane --agent-label lbl --t T1 \
    --role builder --parent-lane parent-lane >/dev/null
  arb event --job "$1" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"builder-lane\",\"label\":\"lbl\",\"pane_id\":\"${2:-w:p1}\"}" >/dev/null
}

event_count() { find "$1" -name "*$2.json" 2>/dev/null | wc -l | tr -d ' '; }
event_count_is() { [[ "$(event_count "$1" "$2")" -eq "$3" ]]; }

wait_until() {
  local limit="$1"; shift
  local deadline=$(( $(date +%s) + limit ))
  while (( $(date +%s) <= deadline )); do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  return 1
}

pid_gone() { ! kill -0 "$1" 2>/dev/null; }

# start_sentinel JOB PANE REPORT [SEQ] — a live sentinel with its pidfile.
# Knobs: SCENARIO (fixture pane state), SENT_INTERVAL (default 3600 — the
# sentinel is mid-sleep when the end lands), TRANSIENT_MAX, LOST_GRACE.
start_sentinel() {
  local job="$1" pane="$2" report="$3" seq="${4:-}"
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" \
    WRK_FIXTURE_SCENARIO="${SCENARIO:-sentinel-working}" \
    ${seq:+WRK_FIXTURE_GET_SEQUENCE="$seq"} \
    WRK_COMPLETION_TIMEOUT_S="${SENT_TIMEOUT:-300}" \
    WRK_COMPLETION_INTERVAL_S="${SENT_INTERVAL:-3600}" \
    WRK_SENTINEL_TRANSIENT_MAX="${TRANSIENT_MAX:-10}" \
    WRK_SENTINEL_LOST_GRACE="${LOST_GRACE:-1800}" \
    "$WRK" sentinel "$job" lane-a lbl "$pane" "$report" >/dev/null 2>&1 &
  SENTINEL_PID=$!
  mkdir -p "$INBOX/$job"
  printf '%s\n' "$SENTINEL_PID" >"$INBOX/$job/completion-sentinel.pid"
}

# done_run JOB [extra env…] — wrk done against the case fixtures.
done_run() {
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
    "$WRK" 'done' "$@"
}

echo "== JE1: wrk done stops the sentinel and its sleep child =="
reset_case je1
mk_job je1
REPORT="$TMP/je1-report.md"; printf 'done verdict\n' >"$REPORT"
start_sentinel je1 w:p1 "$REPORT"
sleep 0.8
[[ -n "$(pgrep -P "$SENTINEL_PID" 2>/dev/null)" ]] ||
  fail "sentinel must be mid-sleep when done lands (no sleep child under $SENTINEL_PID)"
done_run je1 --report "$REPORT" >/dev/null 2>&1
wait_until 10 pid_gone "$SENTINEL_PID" ||
  fail "wrk done must stop and wait on the completion sentinel (pid $SENTINEL_PID)"
sleep 0.3
[[ -z "$(pgrep -P "$SENTINEL_PID" 2>/dev/null)" ]] ||
  fail "the sentinel's interval sleep child must be killed too"
[[ ! -e "$INBOX/je1/completion-sentinel.pid" ]] ||
  fail "the sentinel pidfile must be removed once the job ended"
event_count_is "$INBOX/je1/events" job.completed 1 ||
  fail "wrk done still writes exactly one job.completed"
event_count_is "$INBOX/je1/events" job.revoked 0 ||
  fail "job.completed is already hub-terminal — no extra end declaration needed"
echo "PASS je1 done-stops-sentinel-and-sleep"

echo "== JE2: wrk done via delegated panewire still cleans up =="
reset_case je2
mk_job je2
REPORT="$TMP/je2-report.md"; printf 'delegated done\n' >"$REPORT"
start_sentinel je2 w:p1 "$REPORT"
sleep 0.8
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
  WRK_PANEWIRE_JOB=present WRK_PANEWIRE_JOB_LOG="$TMP/je2-pw.log" \
  "$WRK" 'done' je2 --report "$REPORT" >/dev/null 2>&1
grep -q 'done' "$TMP/je2-pw.log" || fail "the done must have been delegated to panewire"
wait_until 10 pid_gone "$SENTINEL_PID" ||
  fail "a delegated done must still stop the sentinel (panewire owns the record, wrk owns the host)"
sleep 0.3
[[ -z "$(pgrep -P "$SENTINEL_PID" 2>/dev/null)" ]] || fail "delegated done must kill the sleep child"
echo "PASS je2 delegated-done-stops-sentinel"

echo "== JE3: wrk joined appends the hub end declaration =="
reset_case je3
mk_builder_job je3
REPORT="$TMP/je3-report.md"; printf 'joined report\n' >"$REPORT"
start_sentinel je3 w:p1 "$REPORT"
sleep 0.8
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
  "$WRK" joined je3 --pr https://example.invalid/pr/7 --head deadbeefcafe --report "$REPORT" >/dev/null 2>&1
event_count_is "$INBOX/je3/events" job.joined 1 || fail "job.joined must still be written"
event_count_is "$INBOX/je3/events" job.revoked 1 ||
  fail "job.joined is not hub-terminal — the end declaration must land (got $(event_count "$INBOX/je3/events" job.revoked))"
python3 - "$INBOX/je3/events" <<'PY'
import glob, json, sys
records = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.revoked.json"))]
assert len(records) == 1, records
rec = records[0]
assert rec.get("outcome") == "joined", rec
assert rec.get("source") == "wrk joined", rec
assert rec.get("job_id") == "je3", rec
PY
wait_until 10 pid_gone "$SENTINEL_PID" || fail "joined must stop the sentinel"
echo "PASS je3 joined-ends-hub-job"

echo "== JE4: the sentinel leaves right after writing job.completed =="
reset_case je4
mk_job je4
REPORT="$TMP/je4-report.md"; printf 'final\n' >"$REPORT"
SCENARIO=sentinel-done SENT_INTERVAL=1 start_sentinel je4 w:p1 "$REPORT"
wait_until 15 event_count_is "$INBOX/je4/events" job.completed 1 ||
  fail "a done pane + report must still complete"
wait_until 10 pid_gone "$SENTINEL_PID" ||
  fail "#770: the sentinel must exit after writing job.completed, not linger"
echo "PASS je4 sentinel-exits-after-completed"

echo "== JE5: lost-grace expiry declares the hub end =="
reset_case je5
mk_job je5
SEQ="$TMP/je5.seq"; printf '%s\n' not-found >"$SEQ"
SENT_INTERVAL=1 LOST_GRACE=2 start_sentinel je5 w:p1 "$TMP/je5-report.md" "$SEQ"
wait_until 15 event_count_is "$INBOX/je5/events" job.lost 1 ||
  fail "an explicit agent_not_found must record job.lost"
wait_until 15 pid_gone "$SENTINEL_PID" ||
  fail "the sentinel must leave once the lost grace expires"
event_count_is "$INBOX/je5/events" job.revoked 1 ||
  fail "job.lost is not hub-terminal — the grace-expiry must declare the end"
python3 - "$INBOX/je5/events" <<'PY'
import glob, json, sys
records = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.revoked.json"))]
assert records[0].get("outcome") == "abandoned", records
assert "lost" in records[0].get("reason", ""), records
PY
echo "PASS je5 lost-grace-declares-end"

echo "== JE6: done racing a sleeping sentinel =="
reset_case je6
mk_job je6
REPORT="$TMP/je6-report.md"; printf 'raced\n' >"$REPORT"
start_sentinel je6 w:p1 "$REPORT"
sleep 0.8
done_run je6 --report "$REPORT" >/dev/null 2>&1
wait_until 10 pid_gone "$SENTINEL_PID" ||
  fail "the job end must win the race — the sentinel never outlives it"
event_count_is "$INBOX/je6/events" job.completed 1 ||
  fail "exactly one job.completed may exist after the race"
echo "PASS je6 done-beats-sleeping-sentinel"

echo "== JE7: prune dry-run lists, --apply stops only orphans =="
reset_case je7
mk_job je7-orphan w:p1
mk_job je7-live w:p2
REPORT="$TMP/je7-report.md"; printf 'x\n' >"$REPORT"
# Both sentinels start while their jobs are still open — then the orphan's
# job ends while the sentinel is mid-sleep (interval 3600), the exact shape
# the operator saw: an old-window sentinel that outlives its job's end.
start_sentinel je7-orphan w:p1 "$REPORT"
ORPHAN_PID=$SENTINEL_PID
start_sentinel je7-live w:p2 "$REPORT"
LIVE_PID=$SENTINEL_PID
sleep 0.8
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  "$ARBITER" event --job je7-orphan --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
[[ -n "$ORPHAN_PID" && -n "$LIVE_PID" ]] || fail "both fixture sentinels must be running"
# The live job's pane must answer as alive — sentinel-working scenario returns working.
OUT="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" "$WRK" prune)"
grep -q "je7-orphan" <<<"$OUT" || fail "dry-run must list the orphan sentinel"
grep -q "orphan=yes" <<<"$OUT" || fail "dry-run must mark the orphan"
grep -q "je7-live.*state=protected" <<<"$OUT" ||
  fail "the live job's sentinel must be listed as protected, got: $OUT"
kill -0 "$ORPHAN_PID" 2>/dev/null || fail "dry-run must not stop the orphan"
kill -0 "$LIVE_PID" 2>/dev/null || fail "dry-run must not stop the live sentinel"
# Now apply.
OUT="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" "$WRK" prune --apply)"
kill -0 "$ORPHAN_PID" 2>/dev/null &&
  fail "--apply must stop the verified orphan sentinel"
kill -0 "$LIVE_PID" 2>/dev/null ||
  fail "--apply must NEVER stop a live job's sentinel"
kill "$LIVE_PID" 2>/dev/null || true
echo "PASS je7 prune-stops-only-orphans"

echo "== JE8: a pidfile pointing at a reused pid is never signalled =="
reset_case je8
mk_job je8
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  "$ARBITER" event --job je8 --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
# An innocent sleeping process borrows the stale pidfile.
sleep 600 &
INNOCENT=$!
printf '%s\n' "$INNOCENT" >"$INBOX/je8/completion-sentinel.pid"
OUT="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" "$WRK" prune --apply)"
kill -0 "$INNOCENT" 2>/dev/null ||
  fail "a reused pid must never be signalled (innocent pid $INNOCENT was killed)"
[[ ! -e "$INBOX/je8/completion-sentinel.pid" ]] ||
  fail "the stale pidfile itself must be removed"
grep -q "pid-reused" <<<"$OUT" || fail "the reason must name the pid reuse"
kill "$INNOCENT" 2>/dev/null || true
echo "PASS je8 pid-reuse-never-signalled"

echo "== JE9: stale job listing and marking =="
reset_case je9
# A job whose records are years old: created_at inside the record is the
# authority (a filesystem mtime can lie — cp -p and friends roll it back).
mkdir -p "$INBOX/je9-stale/events"
python3 - "$INBOX/je9-stale/events" <<'PY'
import json, sys
events = sys.argv[1]
json.dump({"kind": "job.claim", "job_id": "je9-stale",
           "payload": {"owner_lane": "lane-a", "label": "lbl"},
           "created_at": "2020-01-01T00:00:00Z"}, open(events + "/00001-job.claim.json", "w"))
json.dump({"kind": "job.spawned", "job_id": "je9-stale",
           "payload": {"owner_lane": "lane-a", "label": "lbl", "pane_id": "w:p1"},
           "created_at": "2020-01-01T00:00:01Z"}, open(events + "/00002-job.spawned.json", "w"))
PY
mk_job je9-alive w:p2
SEQ_GONE="$TMP/je9.seq"; printf '%s\n' not-found >"$SEQ_GONE"
OUT="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  WRK_FIXTURE_GET_SEQUENCE="$SEQ_GONE" "$WRK" prune --stale-age 1h)"
grep -q "je9-stale.*stale=yes" <<<"$OUT" ||
  fail "the silent+pane-gone job must be listed stale: $OUT"
if grep -q "je9-alive.*stale=yes" <<<"$OUT"; then
  fail "a fresh job must never be listed stale"
fi
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  WRK_FIXTURE_GET_SEQUENCE="$SEQ_GONE" "$WRK" prune --stale-age 1h --apply >/dev/null
event_count_is "$INBOX/je9-stale/events" job.revoked 1 ||
  fail "--apply must append the end declaration to the stale job"
[[ -f "$INBOX/je9-stale/events/00001-job.claim.json" ]] ||
  fail "stale marking must never delete the records"
echo "PASS je9 stale-job-marking"

echo "== JE10: quota-refresh supervisor pidfile is bounded and traceable =="
reset_case je10
# The refresh hangs past the supervisor's timeout: while it hangs the
# pidfile must exist (traceable), and the timeout path must remove it and
# kill the group — bounded lifetime. The supervisor's stderr stays attached
# to wrk, so the pidfile's whole lifecycle sits inside the spawn window:
# run spawn in the background and observe the file concurrently.
env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
  ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE=new PANEWIRE_BIN="$PANEWIRE" \
  WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$HERDR_LOG" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=8 \
  WRK_REFRESH_MODE=hang WRK_REFRESH_DELAY=90 \
  "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l je10 --t T1 \
  --task 1 --job je10 >"$TMP/je10.out" 2>"$TMP/je10.err" &
SPAWN_PID=$!
PIDFILE="$INBOX/je10/quota-refresh.pid"
wait_until 15 test -f "$PIDFILE" ||
  fail "the supervisor must write a traceable pidfile while the refresh runs"
SUP_PID="$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$PIDFILE")"
{ grep -q 'pool=' "$PIDFILE" && grep -q 'job=je10' "$PIDFILE" && grep -q 'deadline=' "$PIDFILE"; } ||
  fail "the pidfile must name pid/pool/job/deadline: $(cat "$PIDFILE")"
wait "$SPAWN_PID" || fail "spawn failed: $(cat "$TMP/je10.out" "$TMP/je10.err")"
wait_until 20 test '!' -e "$PIDFILE" ||
  fail "the timeout path must remove the pidfile once the supervisor exits"
pid_gone "$SUP_PID" ||
  fail "the supervisor must be gone after its own timeout killed the group"
grep -q 'scopefuel refresh timed out' "$TMP/je10.err" ||
  fail "the timeout warning must stay user-visible on stderr"
echo "PASS je10 refresh-supervisor-bounded-and-traceable"

echo "== JE11: prune flags a refresh leftover past its deadline =="
reset_case je11
mk_job je11
# A stand-in supervisor: a live python process whose recorded deadline is
# past. The verification requires elapsed≈recorded-start AND a python argv.
python3 -c 'import time; time.sleep(600)' &
SUP=$!
NOW=$(date +%s)
printf 'pid=%d pool=p job=je11 timeout=1 deadline=%d started=%d\n' \
  "$SUP" "$(( NOW - 120 ))" "$NOW" >"$INBOX/je11/quota-refresh.pid"
OUT="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" "$WRK" prune)"
grep -q "je11.*leftover=yes" <<<"$OUT" ||
  fail "a verified supervisor past its deadline must list as leftover: $OUT"
kill -0 "$SUP" 2>/dev/null || fail "dry-run must not stop the leftover"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" "$WRK" prune --apply >/dev/null
[[ ! -e "$INBOX/je11/quota-refresh.pid" ]] || fail "--apply removes the leftover pidfile"
wait_until 5 pid_gone "$SUP" ||
  fail "--apply must stop the verified leftover supervisor (pid $SUP)"
echo "PASS je11 refresh-leftover-detection"

echo "== JE12: prune never stops a sentinel for a revived job =="
reset_case je12
mk_job je12 w:p1
# completed then re-claimed: the job is live again — the newest revive wins.
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  "$ARBITER" event --job je12 --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
arb event --job je12 --kind job.spawned \
  --payload-json '{"owner_lane":"lane-a","label":"lbl","pane_id":"w:p7"}' >/dev/null
REPORT="$TMP/je12-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je12 w:p7 "$REPORT"
sleep 0.8
REVIVED_PID="$SENTINEL_PID"
OUT="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" "$WRK" prune --apply)"
kill -0 "$REVIVED_PID" 2>/dev/null ||
  fail "a sentinel on a revived job is not an orphan and must never be stopped"
kill "$REVIVED_PID" 2>/dev/null || true
echo "PASS je12 revived-job-sentinel-protected"

echo "== JE13: WRK_PRUNE_ON_SPAWN is off by default =="
reset_case je13
spawn_out="$(env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
  ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE=new PANEWIRE_BIN="$PANEWIRE" \
  WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$HERDR_LOG" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
  "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l je13 --t T1 \
  --task 1 --job je13 2>&1)" || fail "spawn failed: $spawn_out"
sleep 0.5
[[ ! -e "$INBOX/prune.log" ]] ||
  fail "the periodic prune hook must stay off by default (prune.log exists)"
echo "PASS je13 prune-hook-off-by-default"

echo "== JE14: wrk reap --apply stops the sentinel and declares the hub end =="
reset_case je14
ARBITER_TEST_NOW="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).replace(microsecond=0).isoformat())')"
export ARBITER_TEST_NOW
arb claim --job je14-reap --lane lane-a --agent-label je14-reap --t T1 >/dev/null
arb event --job je14-reap --kind job.spawned \
  --payload-json '{"owner_lane":"lane-a","label":"je14-reap","pane_id":"w1:p1","tab_id":"w1:t1"}' >/dev/null
unset ARBITER_TEST_NOW
REPORT="$TMP/je14-report.md"; printf 'x\n' >"$REPORT"
SCENARIO=reap start_sentinel je14-reap w1:p1 "$REPORT"
sleep 0.8
kill -0 "$SENTINEL_PID" 2>/dev/null ||
  fail "JE14: sentinel should still be asleep on the open job"
# The terminal record lands while the sentinel is mid-interval: only reap's
# housekeeping can end it before the next probe.
arb event --job je14-reap --kind job.joined \
  --payload-json '{"owner_lane":"lane-a","label":"je14-reap","pane_id":"w1:p1"}' >/dev/null
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" WRK_FIXTURE_SCENARIO=reap \
  WRK_FIXTURE_LOG="$HERDR_LOG" \
  "$WRK" reap --apply --lane lane-a --grace 0s >"$TMP/je14-reap.out" 2>&1 ||
  { cat "$TMP/je14-reap.out"; fail "JE14: wrk reap --apply failed"; }
event_count_is "$INBOX/je14-reap/events" job.reaped 1 ||
  { cat "$TMP/je14-reap.out"; fail "JE14: reap did not record job.reaped"; }
# job.joined is a work terminal, not a hub terminal — housekeeping must append
# the job.revoked declaration on top of the reaped record.
event_count_is "$INBOX/je14-reap/events" job.revoked 1 ||
  fail "JE14: reap housekeeping did not declare job.revoked for the joined job"
[[ ! -e "$INBOX/je14-reap/completion-sentinel.pid" ]] ||
  fail "JE14: reap left the completion-sentinel.pid behind"
wait_until 8 pid_gone "$SENTINEL_PID" ||
  { kill -9 "$SENTINEL_PID" 2>/dev/null; fail "JE14: sentinel survived wrk reap --apply"; }
echo "PASS je14 reap-housekeeping"

echo "== MUT: assertion-RED mutants per call site =="

mkmut() {
  local mut="$TMP/mut-$1"; shift
  { sed "$1" "$WRK" >"$mut" && chmod +x "$mut"; } || fail "mutant build failed: $1"
  MUT="$mut"
}

expect_mut_red() {
  local desc="$1" fn="$2"
  local saved="$WRK"; WRK="$MUT"
  if "$fn"; then
    fail "MUT $desc: mutant stayed GREEN — the assertion does not cover this call site"
  fi
  WRK="$saved"
  echo "PASS mut $desc is assertion-RED"
}

case_done() {
  reset_case mut-done
  mk_job mut-done
  REPORT="$TMP/mut-done-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-done w:p1 "$REPORT"
  sleep 0.8
  done_run mut-done --report "$REPORT" >/dev/null 2>&1
  wait_until 8 pid_gone "$SENTINEL_PID"
}

case_joined() {
  reset_case mut-joined
  mk_builder_job mut-joined
  REPORT="$TMP/mut-joined-report.md"; printf 'x\n' >"$REPORT"
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
    "$WRK" joined mut-joined --pr https://example.invalid/pr/1 --head deadbeef --report "$REPORT" >/dev/null 2>&1
  event_count_is "$INBOX/mut-joined/events" job.revoked 1
}

case_watch() {
  reset_case mut-watch
  mk_job mut-watch
  REPORT="$TMP/mut-watch-report.md"; printf 'x\n' >"$REPORT"
  # The record watch is what makes a sleeping sentinel die when done lands
  # before housekeeping can signal it — remove it and the race is lost.
  WRK_COMPLETION_INTERVAL_S=1 start_sentinel mut-watch w:p1 "$REPORT"
  sleep 0.5
  # Write a terminal record directly (as another end path would) — the
  # sentinel must observe it and leave on its own.
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    "$ARBITER" event --job mut-watch --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1
  wait_until 8 pid_gone "$SENTINEL_PID"
}

case_prune_apply() {
  reset_case mut-prune
  mk_job mut-prune
  REPORT="$TMP/mut-prune-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-prune w:p1 "$REPORT"
  sleep 0.8
  # The job ends while the sentinel sleeps an hour out — only prune's stop
  # can reach it in this window.
  arb event --job mut-prune --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
  local pid="$SENTINEL_PID"
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    "$WRK" prune --apply >/dev/null 2>&1
  pid_gone "$pid"
}

# shellcheck disable=SC2016 # the $VARs are literal sed pattern text for the wrk source lines
mkmut no-done-housekeeping 's/^  job_end_housekeeping "\$job" "\$owner" completed "wrk done" "wrk done"$/  : mutant removed done housekeeping/'
expect_mut_red "done housekeeping removal" case_done

# shellcheck disable=SC2016 # the $VARs are literal sed pattern text for the wrk source lines
mkmut no-joined-housekeeping 's/^  job_end_housekeeping "\$job" "\$owner" joined "wrk joined" "wrk joined"$/  : mutant removed joined housekeeping/'
expect_mut_red "joined housekeeping removal" case_joined

# shellcheck disable=SC2016 # the $VARs are literal sed pattern text for the wrk source lines
mkmut no-watch 's/^    if sentinel_job_ended "\$jobdir"; then$/    if false; then/'
expect_mut_red "sentinel record-watch removal" case_watch

# shellcheck disable=SC2016 # the $VARs are literal sed pattern text for the wrk source lines
mkmut no-prune-stop 's/stop_completion_sentinel "\$job" "\$pid"/: mutant removed prune stop/g'
expect_mut_red "prune orphan-stop removal" case_prune_apply

echo "PASS test-wrk-job-end: all cases"
