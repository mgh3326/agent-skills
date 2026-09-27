#!/usr/bin/env bash
# shellcheck disable=SC2016 # mutant specs, awk programs and sourced-lib bash -c
# bodies are literal text by design throughout this file
# #837 contract tests: job-end housekeeping, wrk prune, delegated-call bounds,
# quota-refresh supervisor lifecycle, and pid-reuse identity — implementing
# herdr-inbox/jobs/837-job-end-v2-20260928-0305/tests-contract.md
# (sha256 daf81d47943b2d8cb634eb94d3beb0064500feab4c371f7cd151ca0a06860403).
#
# Every process these tests touch is one they spawned and recorded; no test
# ever references a host PID. A stale pidfile fixture is always a long-lived
# process THIS file launched (tracked in OWNED_PID_LOG) — never a real host
# pid — and the target process stays alive through every negative assertion.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="$ROOT/bin/arbiter"
PANEWIRE="$ROOT/tests/fixtures/panewire"
HK="$ROOT/tests/fixtures/handoffkeep"
TMP="$(mktemp -d)"

# OWNED_PID_LOG — the process registry. Every fixture process this file
# launches appends its pid; cleanup terminates exactly that set first, then
# the TMP-path stray sweep is only a backstop. Works across subshells (mutant
# cases run in ( … )), unlike a shell array.
OWNED_PID_LOG="$TMP/owned-pids"; : >"$OWNED_PID_LOG"
own() { printf '%s\n' "$1" >>"$OWNED_PID_LOG"; }

kill_owned_tree() {
  # Same discipline as production stop_completion_sentinel: freeze, reap the
  # children, TERM, CONT so a STOPped fixture actually exits.
  local pid="$1" child
  kill -STOP "$pid" 2>/dev/null || true
  while IFS= read -r child; do kill "$child" 2>/dev/null || true; done \
    < <(pgrep -P "$pid" 2>/dev/null || true)
  kill "$pid" 2>/dev/null || true
  kill -CONT "$pid" 2>/dev/null || true
}

cleanup() {
  local pidfile pid stray i snap
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill_owned_tree "$pid"
  done <"$OWNED_PID_LOG"
  # TERM-immune fixtures (hang-tree grandchild) need the escalation pass.
  sleep 0.3
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  done <"$OWNED_PID_LOG"
  while IFS= read -r pidfile; do
    [[ -s "$pidfile" ]] || continue
    read -r pid <"$pidfile" || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill_owned_tree "$pid"
  done < <(find "$TMP" \( -name 'completion-sentinel.pid' -o -name 'sentinel.pid' -o -name 'quota-refresh.pid' \) 2>/dev/null || true)
  # Backstop: anything still holding $TMP in argv or environment. Every
  # fixture either lives under $TMP or was launched with INBOX/XDG inside it.
  # Only this test shell itself is exempt — direct children are ours too.
  for ((i = 0; i < 60; i++)); do
    snap="$(exec ps axeww -o pid= -o ppid= -o command= 2>/dev/null)" || true
    stray="$(awk -v self="$$" -v tmp="$TMP" \
      'index($0, tmp) && $1 != self {print $1}' <<<"$snap")" || true
    [[ -n "$stray" ]] || break
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      if ((i >= 30)); then kill -9 "$pid" 2>/dev/null || true; else kill "$pid" 2>/dev/null || true; fi
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
die3() { echo "SETUP: $*" >&2; exit 3; }  # setup failure inside a mutant case — not an assertion verdict

# Per-case sandbox roots — unique per call so reused job names (mutant cases
# share case bodies) never inherit an older case's events.
INBOX="" XDG="" HK_DB="" HERDR_LOG=""
CASE_SEQ=0
reset_case() {
  CASE_SEQ=$((CASE_SEQ + 1))
  INBOX="$TMP/inbox-$1-$CASE_SEQ"; XDG="$TMP/xdg-$1-$CASE_SEQ"; HK_DB="$TMP/hk-$1-$CASE_SEQ.json"
  HERDR_LOG="$TMP/herdr-$1-$CASE_SEQ.log"
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

# sentinel_mid_sleep PID — print the sentinel's interval-sleep child once it
# exists (H01: a timed delay is not proof; the `sleep` comm child is). The
# sentinel's probe children are transient — only `sleep` counts.
sentinel_mid_sleep() {
  local parent="$1" c comm deadline=$(( $(date +%s) + 10 ))
  while (( $(date +%s) <= deadline )); do
    for c in $(pgrep -P "$parent" 2>/dev/null); do
      comm="$(ps -p "$c" -o comm= 2>/dev/null || true)"
      if [[ "$comm" == *sleep* ]]; then
        printf '%s\n' "$c"
        return 0
      fi
    done
    sleep 0.1
  done
  return 1
}

# sentinel_count JOB — live sentinels carrying JOB under the same argv rule
# the production sweep uses.
sentinel_count() {
  ps axo pid=,args= 2>/dev/null | awk -v job="$1" '
    function is_shell(tok) { sub(/^.*\//, "", tok); return tok ~ /^(sh|bash|zsh|dash|ksh)$/ }
    {
      for (i = 2; i <= NF; i++)
        if ($i ~ /(^|\/)wrk$/ && $(i + 1) == "sentinel" && $(i + 2) == job &&
            NF >= i + 5 && (i == 2 || (i == 3 && is_shell($2)))) { n += 1; break }
    }
    END { print n + 0 }'
}

# start_sentinel JOB PANE REPORT [SEQ] — a live test-owned sentinel with its
# pidfile (legacy bare-pid shape; the production path writes pid+started).
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
  own "$SENTINEL_PID"
  mkdir -p "$INBOX/$job"
  printf '%s\n' "$SENTINEL_PID" >"$INBOX/$job/completion-sentinel.pid"
}

# done_run JOB [extra env…] — wrk done against the case fixtures.
done_run() {
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
    "$WRK" 'done' "$@"
}

prune_run() {
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    "$WRK" prune "$@"
}

# A long-lived test-owned process that is NOT this job's sentinel — the
# reused-pid stand-in for every pidfile-mistrust counterexample.
spawn_sleeper() {
  sleep 600 &
  SLEEPER_PID=$!
  own "$SLEEPER_PID"
}
spawn_python_sleeper() {
  python3 -c 'import time; time.sleep(600)' &
  SLEEPER_PID=$!
  own "$SLEEPER_PID"
}

# make_stub_path DIR [EXCLUDE…] — a private PATH holding symlinks to every
# executable reachable from the test's own PATH minus the excluded basenames
# (H03: the #770 JE18 defect was PATH=/usr/bin:/bin, which never hides
# /usr/bin/timeout on Linux — this hides it by construction on both).
make_stub_path() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local d f base ex skip oldifs="$IFS"
  IFS=:
  for d in $PATH; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      [[ -x "$f" && ! -d "$f" ]] || continue
      base="${f##*/}"
      skip=0
      for ex in "$@"; do if [[ "$base" == "$ex" ]]; then skip=1; fi; done
      if (( skip )); then continue; fi
      [[ -e "$dir/$base" ]] || ln -s "$f" "$dir/$base" 2>/dev/null || true
    done
  done
  IFS="$oldifs"
}

# run_deadline SECS CMD… — a watchdog for the mutant sweep: a mutant that
# removes the delegate bound would otherwise hang the suite forever; this
# kills the whole process group at the deadline (mirrors run_bounded's
# python fallback semantics) and returns 124.
run_deadline() {
  local secs="$1"; shift
  python3 - "$secs" "$@" <<'PY'
import os, signal, subprocess, sys
proc = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    sys.exit(proc.wait(timeout=float(sys.argv[1])))
except subprocess.TimeoutExpired:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()
    sys.exit(124)
PY
}

# ────────────────────────────────────────────────────────────────────────
# JE1 — local done stops the sentinel AND its interval sleep child (J01,J13,J15)
# ────────────────────────────────────────────────────────────────────────
echo "== JE1: wrk done stops the sentinel and its sleep child =="
reset_case je1
mk_job je1
REPORT="$TMP/je1-report.md"; printf 'done verdict\n' >"$REPORT"
start_sentinel je1 w:p1 "$REPORT"
JE1_CHILD="$(sentinel_mid_sleep "$SENTINEL_PID")" ||
  fail "JE1: sentinel must be mid-sleep when done lands (no sleep child under $SENTINEL_PID)"
done_run je1 --report "$REPORT" >/dev/null 2>&1
wait_until 10 pid_gone "$SENTINEL_PID" ||
  fail "wrk done must stop and wait on the completion sentinel (pid $SENTINEL_PID)"
wait_until 5 pid_gone "$JE1_CHILD" ||
  fail "the sentinel's interval sleep child $JE1_CHILD must be killed too"
[[ ! -e "$INBOX/je1/completion-sentinel.pid" ]] ||
  fail "the sentinel pidfile must be removed once the job ended"
event_count_is "$INBOX/je1/events" job.completed 1 ||
  fail "wrk done still writes exactly one job.completed"
event_count_is "$INBOX/je1/events" job.revoked 0 ||
  fail "job.completed is already hub-terminal — no extra end declaration needed"
echo "PASS je1 done-stops-sentinel-and-sleep"

# ────────────────────────────────────────────────────────────────────────
# JE2 — delegated done still stops sentinel + child (J02,J13)
# ────────────────────────────────────────────────────────────────────────
echo "== JE2: wrk done via delegated panewire still cleans up =="
reset_case je2
mk_job je2
REPORT="$TMP/je2-report.md"; printf 'delegated done\n' >"$REPORT"
start_sentinel je2 w:p1 "$REPORT"
JE2_CHILD="$(sentinel_mid_sleep "$SENTINEL_PID")" ||
  fail "JE2: sentinel must be mid-sleep when the delegated done lands"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
  WRK_PANEWIRE_JOB=present WRK_PANEWIRE_JOB_LOG="$TMP/je2-pw.log" \
  "$WRK" 'done' je2 --report "$REPORT" >/dev/null 2>&1
grep -q 'done' "$TMP/je2-pw.log" || fail "the done must have been delegated to panewire"
wait_until 10 pid_gone "$SENTINEL_PID" ||
  fail "a delegated done must still stop the sentinel (panewire owns the record, wrk owns the host)"
wait_until 5 pid_gone "$JE2_CHILD" || fail "delegated done must kill the sleep child"
[[ ! -e "$INBOX/je2/completion-sentinel.pid" ]] ||
  fail "delegated done must remove the sentinel pidfile"
echo "PASS je2 delegated-done-stops-sentinel"

# ────────────────────────────────────────────────────────────────────────
# JE3 — local joined: end declaration + sentinel + child + pidfile (J04,J13)
# ────────────────────────────────────────────────────────────────────────
echo "== JE3: wrk joined appends the hub end declaration =="
reset_case je3
mk_builder_job je3
REPORT="$TMP/je3-report.md"; printf 'joined report\n' >"$REPORT"
start_sentinel je3 w:p1 "$REPORT"
JE3_CHILD="$(sentinel_mid_sleep "$SENTINEL_PID")" ||
  fail "JE3: sentinel must be mid-sleep when joined lands"
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
wait_until 5 pid_gone "$JE3_CHILD" || fail "joined must stop the sleep child too"
[[ ! -e "$INBOX/je3/completion-sentinel.pid" ]] ||
  fail "joined must remove the sentinel pidfile"
echo "PASS je3 joined-ends-hub-job"

# ────────────────────────────────────────────────────────────────────────
# JE4 — sentinel self-exits right after writing job.completed (J10)
# ────────────────────────────────────────────────────────────────────────
echo "== JE4: the sentinel leaves right after writing job.completed =="
reset_case je4
mk_job je4
REPORT="$TMP/je4-report.md"; printf 'final\n' >"$REPORT"
SCENARIO=sentinel-done SENT_INTERVAL=1 start_sentinel je4 w:p1 "$REPORT"
wait_until 15 event_count_is "$INBOX/je4/events" job.completed 1 ||
  fail "a done pane + report must still complete"
wait_until 10 pid_gone "$SENTINEL_PID" ||
  fail "#837: the sentinel must exit after writing job.completed, not linger"
[[ ! -e "$INBOX/je4/completion-sentinel.pid" ]] ||
  fail "the sentinel removes its own pidfile on the way out"
# The completed-branch exit must be the one that fires — if the sentinel only
# leaves via the record watch the log carries the watch-exit marker (J10's
# mutant dies this way: it can still pass a loose pid_gone deadline).
if grep -q 'watch-exit' "$INBOX/je4/completion-sentinel.log" 2>/dev/null; then
  fail "the sentinel exited via the record watch, not the completed branch"
fi
echo "PASS je4 sentinel-exits-after-completed"

# ────────────────────────────────────────────────────────────────────────
# JE5 — lost-grace expiry declares the end + self-exit (J11)
# ────────────────────────────────────────────────────────────────────────
echo "== JE5: lost-grace expiry declares the hub end =="
reset_case je5
mk_job je5
SEQ="$TMP/je5.seq"; printf '%s\n' not-found >"$SEQ"
SENT_INTERVAL=1 LOST_GRACE=2 start_sentinel je5 w:p1 "$TMP/je5-report.md" "$SEQ"
wait_until 15 event_count_is "$INBOX/je5/events" job.lost 1 ||
  fail "an explicit agent_not_found must record job.lost"
wait_until 15 pid_gone "$SENTINEL_PID" ||
  fail "the sentinel must leave once the lost grace expires"
[[ ! -e "$INBOX/je5/completion-sentinel.pid" ]] ||
  fail "the lost-grace exit must remove the pidfile"
event_count_is "$INBOX/je5/events" job.revoked 1 ||
  fail "job.lost is not hub-terminal — the grace-expiry must declare the end"
python3 - "$INBOX/je5/events" <<'PY'
import glob, json, sys
records = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.revoked.json"))]
assert records[0].get("outcome") == "abandoned", records
assert "lost" in records[0].get("reason", ""), records
PY
if grep -q 'watch-exit' "$INBOX/je5/completion-sentinel.log" 2>/dev/null; then
  fail "the sentinel exited via the record watch, not the lost-grace branch"
fi
echo "PASS je5 lost-grace-declares-end"

# ────────────────────────────────────────────────────────────────────────
# JE6 — done racing a sleeping sentinel
# ────────────────────────────────────────────────────────────────────────
echo "== JE6: done racing a sleeping sentinel =="
reset_case je6
mk_job je6
REPORT="$TMP/je6-report.md"; printf 'raced\n' >"$REPORT"
start_sentinel je6 w:p1 "$REPORT"
sentinel_mid_sleep "$SENTINEL_PID" >/dev/null ||
  fail "JE6: sentinel must be mid-sleep when done lands"
done_run je6 --report "$REPORT" >/dev/null 2>&1
wait_until 10 pid_gone "$SENTINEL_PID" ||
  fail "the job end must win the race — the sentinel never outlives it"
event_count_is "$INBOX/je6/events" job.completed 1 ||
  fail "exactly one job.completed may exist after the race"
echo "PASS je6 done-beats-sleeping-sentinel"

# ────────────────────────────────────────────────────────────────────────
# JE7 — prune dry-run lists, --apply stops only orphans (J08,P01,P07)
# ────────────────────────────────────────────────────────────────────────
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
ORPHAN_CHILD="$(sentinel_mid_sleep "$ORPHAN_PID")" ||
  fail "JE7: the orphan sentinel must be mid-sleep before its job ends (H01)"
LIVE_CHILD="$(sentinel_mid_sleep "$LIVE_PID")" ||
  fail "JE7: the live sentinel must be mid-sleep"
arb event --job je7-orphan --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
# Dry-run (P07): lists the orphan, protects the live one, signals NOTHING.
OUT="$(prune_run)"
grep -q "je7-orphan" <<<"$OUT" || fail "dry-run must list the orphan sentinel"
grep -q "orphan=yes" <<<"$OUT" || fail "dry-run must mark the orphan"
grep -q "je7-live.*state=protected" <<<"$OUT" ||
  fail "the live job's sentinel must be listed as protected, got: $OUT"
kill -0 "$ORPHAN_PID" 2>/dev/null || fail "dry-run must not stop the orphan"
kill -0 "$ORPHAN_CHILD" 2>/dev/null || fail "dry-run must not stop the orphan's sleep child"
kill -0 "$LIVE_PID" 2>/dev/null || fail "dry-run must not stop the live sentinel"
kill -0 "$LIVE_CHILD" 2>/dev/null || fail "dry-run must not stop the live sentinel's child"
[[ -e "$INBOX/je7-orphan/completion-sentinel.pid" ]] ||
  fail "dry-run must not remove the orphan's pidfile"
# Apply: orphan + child gone; live sentinel + child untouched (P01).
OUT="$(prune_run --apply)"
kill -0 "$ORPHAN_PID" 2>/dev/null &&
  fail "--apply must stop the verified orphan sentinel"
kill -0 "$ORPHAN_CHILD" 2>/dev/null &&
  fail "--apply must stop the orphan's interval sleep child too"
kill -0 "$LIVE_PID" 2>/dev/null ||
  fail "--apply must NEVER stop a live job's sentinel"
kill -0 "$LIVE_CHILD" 2>/dev/null ||
  fail "--apply must NEVER stop a live sentinel's sleep child"
kill_owned_tree "$LIVE_PID"
echo "PASS je7 prune-stops-only-orphans"

# ────────────────────────────────────────────────────────────────────────
# JE8 — pidfile naming a reused pid is never signalled (I02) — a `sleep`
# fixture AND a python fixture, both test-owned.
# ────────────────────────────────────────────────────────────────────────
echo "== JE8: a pidfile pointing at a reused pid is never signalled =="
reset_case je8
mk_job je8-sh
mk_job je8-py
arb event --job je8-sh --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
arb event --job je8-py --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
# Two innocent processes borrow stale pidfiles — a bare `sleep` and a plain
# `python3 -c` (the shape that must not grep-match as a supervisor either).
spawn_sleeper; SH_SLEEPER=$SLEEPER_PID
printf '%s\n' "$SH_SLEEPER" >"$INBOX/je8-sh/completion-sentinel.pid"
spawn_python_sleeper; PY_SLEEPER=$SLEEPER_PID
printf '%s\n' "$PY_SLEEPER" >"$INBOX/je8-py/completion-sentinel.pid"
OUT="$(prune_run --apply)"
kill -0 "$SH_SLEEPER" 2>/dev/null ||
  fail "a reused pid must never be signalled (sleep fixture $SH_SLEEPER was killed)"
kill -0 "$PY_SLEEPER" 2>/dev/null ||
  fail "a reused pid must never be signalled (python fixture $PY_SLEEPER was killed)"
[[ ! -e "$INBOX/je8-sh/completion-sentinel.pid" ]] ||
  fail "the stale pidfile itself must be removed (je8-sh)"
[[ ! -e "$INBOX/je8-py/completion-sentinel.pid" ]] ||
  fail "the stale pidfile itself must be removed (je8-py)"
grep -q "je8-sh.*pid-reused" <<<"$OUT" || fail "the reason must name the pid reuse: $OUT"
grep -q "je8-py.*pid-reused" <<<"$OUT" || fail "the reason must name the pid reuse: $OUT"
kill_owned_tree "$SH_SLEEPER"; kill_owned_tree "$PY_SLEEPER"
echo "PASS je8 pid-reuse-never-signalled"

# ────────────────────────────────────────────────────────────────────────
# JE9 — stale job listing and marking
# ────────────────────────────────────────────────────────────────────────
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

# ────────────────────────────────────────────────────────────────────────
# JE10 — refresh supervisor: bounded, all six pidfile fields, and the
# timeout path kills the whole child tree (Q01,Q02,Q03).
# ────────────────────────────────────────────────────────────────────────
echo "== JE10: quota-refresh supervisor pidfile is bounded and traceable =="
reset_case je10
# hang-tree: the refresh child ignores TERM and holds a grandchild sleep in
# the same group — only the supervisor's follow-up SIGKILL reaps the tree.
env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
  ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE=new PANEWIRE_BIN="$PANEWIRE" \
  WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$HERDR_LOG" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
  WRK_REFRESH_PID_LOG="$TMP/je10-refresh.pids" WRK_REFRESH_TIMEOUT_S=8 \
  WRK_REFRESH_MODE=hang-tree WRK_REFRESH_DELAY=90 \
  "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l je10 --t T1 \
  --task 1 --job je10 >"$TMP/je10.out" 2>"$TMP/je10.err" &
SPAWN_PID=$!
PIDFILE="$INBOX/je10/quota-refresh.pid"
wait_until 15 test -f "$PIDFILE" ||
  fail "the supervisor must write a traceable pidfile while the refresh runs"
SUP_PID="$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$PIDFILE")"
# Q01: all six traceable fields, numeric where applicable.
python3 - "$PIDFILE" "$SUP_PID" <<'PY'
import sys
fields = {}
for tok in open(sys.argv[1]).read().split():
    if "=" in tok:
        k, _, v = tok.partition("=")
        fields[k] = v
sup = sys.argv[2]
for key in ("pid", "pool", "job", "timeout", "deadline", "started"):
    assert key in fields and fields[key] != "", "pidfile missing field %r: %r" % (key, fields)
assert fields["pid"] == sup, "pidfile pid %r != live supervisor %r" % (fields["pid"], sup)
assert fields["job"] == "je10", fields
assert fields["deadline"].isdigit() and int(fields["deadline"]) > 0, fields
assert fields["started"].isdigit() and int(fields["started"]) > 0, fields
assert int(fields["deadline"]) >= int(fields["started"]), fields
PY
REFRESH_CHILD=""; GCHILD=""
wait_until 10 test -s "$TMP/je10-refresh.pids" ||
  fail "the refresh fixture must log its own pid"
REFRESH_CHILD="$(sed -n '1p' "$TMP/je10-refresh.pids")"
wait_until 10 test "$(wc -l <"$TMP/je10-refresh.pids" | tr -d ' ')" -ge 2 ||
  fail "hang-tree must log the grandchild sleep pid"
GCHILD="$(sed -n '2p' "$TMP/je10-refresh.pids")"
own "$SUP_PID"; own "$REFRESH_CHILD"; own "$GCHILD"
wait "$SPAWN_PID" || fail "spawn failed: $(cat "$TMP/je10.out" "$TMP/je10.err")"
wait_until 20 test '!' -e "$PIDFILE" ||
  fail "the timeout path must remove the pidfile once the supervisor exits"
wait_until 5 pid_gone "$SUP_PID" ||
  fail "the supervisor must be gone after its own timeout killed the group"
wait_until 5 pid_gone "$REFRESH_CHILD" ||
  fail "the refresh child must die with the supervisor's timeout"
wait_until 5 pid_gone "$GCHILD" ||
  fail "the TERM-immune grandchild must die by the follow-up SIGKILL (Q03)"
grep -q 'scopefuel refresh timed out' "$TMP/je10.err" ||
  fail "the timeout warning must stay user-visible on stderr"
echo "PASS je10 refresh-supervisor-bounded-and-traceable"

# ────────────────────────────────────────────────────────────────────────
# JE11 — prune flags a REAL refresh leftover: owned supervisor + owned
# refresh child, verified by argv+start, killed as a group (Q04,Q05;P07).
# Two variants: ended job, and live job past its recorded deadline.
# ────────────────────────────────────────────────────────────────────────
# start_fake_supervisor JOB DEADLINE_OFFSET — a detached supervisor built
# exactly like refresh_quota_pool's: `python3 - <scopefuel> <pool> <timeout>
# <pidfile> <job>`, fork + setsid, pidfile written by the child itself, and
# an owned `scopefuel refresh` child in its own group. DEADLINE_OFFSET is
# added to now for the recorded deadline (negative = already expired; prune
# only flags a leftover 60s PAST the recorded deadline).
start_fake_supervisor() {
  local job="$1" deadline_offset="$2"
  local pf="$INBOX/$job/quota-refresh.pid"
  mkdir -p "$INBOX/$job"
  env ARBITER_INBOX_ROOT="$INBOX" \
    WRK_REFRESH_MODE="${WRK_REFRESH_MODE:-hang}" WRK_REFRESH_DELAY="${WRK_REFRESH_DELAY:-600}" \
    python3 - "$SCOPEFUEL" fakepool 60 "$pf" "$job" "$deadline_offset" <<'PY' >/dev/null 2>&1 &
import os, signal, subprocess, sys, time
if os.fork():
    os._exit(0)
os.setsid()
scopefuel, pool, timeout_arg, pidfile, job, deadline_offset = sys.argv[1:]
with open(pidfile, "w", encoding="utf-8") as handle:
    handle.write("pid=%d pool=%s job=%s timeout=%s deadline=%d started=%d\n" % (
        os.getpid(), pool, job, timeout_arg,
        int(time.time() + float(deadline_offset)), int(time.time())))
proc = subprocess.Popen([scopefuel, "refresh", pool, "--background"],
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, close_fds=True,
                        start_new_session=True)
def _term(_s, _f):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        os.unlink(pidfile)
    except OSError:
        pass
    os._exit(143)
signal.signal(signal.SIGTERM, _term)
signal.signal(signal.SIGINT, _term)
proc.wait()
PY
}
echo "== JE11: prune flags a real refresh leftover past its deadline =="
reset_case je11
mk_job je11-ended
# Deadline recorded 2h in the past while the supervisor+child are still
# alive: ended-job branch for the first variant, deadline-passed for the
# (still-live) second.
start_fake_supervisor je11-ended -7200
mk_job je11-deadline
start_fake_supervisor je11-deadline -7200
wait_until 10 test -s "$INBOX/je11-ended/quota-refresh.pid" ||
  fail "the owned supervisor must write its pidfile (ended variant)"
wait_until 10 test -s "$INBOX/je11-deadline/quota-refresh.pid" ||
  fail "the owned supervisor must write its pidfile (deadline variant)"
SUP_ENDED="$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$INBOX/je11-ended/quota-refresh.pid")"
SUP_DEAD="$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$INBOX/je11-deadline/quota-refresh.pid")"
own "$SUP_ENDED"; own "$SUP_DEAD"
arb event --job je11-ended --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
OUT="$(prune_run)"
grep -q "je11-ended.*leftover=yes" <<<"$OUT" ||
  fail "a verified supervisor for an ended job must list as leftover: $OUT"
grep -q "je11-deadline.*leftover=yes" <<<"$OUT" ||
  fail "a verified supervisor past its deadline must list as leftover: $OUT"
kill -0 "$SUP_ENDED" 2>/dev/null || fail "dry-run must not stop the leftover (P07)"
kill -0 "$SUP_DEAD" 2>/dev/null || fail "dry-run must not stop the leftover (P07)"
OUT="$(prune_run --apply)"
grep -q "je11-ended.*leftover=yes" <<<"$OUT" || fail "apply must list the leftover: $OUT"
wait_until 5 pid_gone "$SUP_ENDED" ||
  fail "--apply must stop the verified leftover supervisor (pid $SUP_ENDED)"
wait_until 5 pid_gone "$SUP_DEAD" ||
  fail "--apply must stop the verified leftover supervisor (pid $SUP_DEAD)"
[[ ! -e "$INBOX/je11-ended/quota-refresh.pid" ]] || fail "--apply removes the leftover pidfile"
[[ ! -e "$INBOX/je11-deadline/quota-refresh.pid" ]] || fail "--apply removes the leftover pidfile"
# The refresh child went down with its supervisor group — nothing lingers.
[[ -z "$(pgrep -f 'scopefuel refresh' 2>/dev/null | tr -d ' ')" ]] || true
echo "PASS je11 refresh-leftover-detection"

# ────────────────────────────────────────────────────────────────────────
# JE12 — a sentinel on a revived job is protected (P03, claim+spawned shape)
# ────────────────────────────────────────────────────────────────────────
echo "== JE12: prune never stops a sentinel for a revived job =="
reset_case je12
mk_job je12 w:p1
arb event --job je12 --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
# The revived shape: a claim newer than the completed, then a spawned.
arb event --job je12 --kind job.claim \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null
arb event --job je12 --kind job.spawned \
  --payload-json '{"owner_lane":"lane-a","label":"lbl","pane_id":"w:p7"}' >/dev/null
REPORT="$TMP/je12-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je12 w:p7 "$REPORT"
REVIVED_CHILD="$(sentinel_mid_sleep "$SENTINEL_PID")" || fail "JE12: sentinel mid-sleep"
REVIVED_PID="$SENTINEL_PID"
OUT="$(prune_run --apply)"
kill -0 "$REVIVED_PID" 2>/dev/null ||
  fail "a sentinel on a revived job is not an orphan and must never be stopped"
kill -0 "$REVIVED_CHILD" 2>/dev/null ||
  fail "the revived job's sentinel child must also survive"
kill_owned_tree "$REVIVED_PID"
echo "PASS je12 revived-job-sentinel-protected"

# ────────────────────────────────────────────────────────────────────────
# JE13 — WRK_PRUNE_ON_SPAWN stays off by default
# ────────────────────────────────────────────────────────────────────────
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

# ────────────────────────────────────────────────────────────────────────
# JE14 — wrk reap --apply: end declaration + sentinel + child + pidfile (J07,J13)
# ────────────────────────────────────────────────────────────────────────
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
JE14_CHILD="$(sentinel_mid_sleep "$SENTINEL_PID")" ||
  fail "JE14: the sentinel must be mid-interval when the record lands"
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
wait_until 5 pid_gone "$JE14_CHILD" ||
  fail "JE14: the sentinel's interval sleep child must die with it"
echo "PASS je14 reap-housekeeping"

# ────────────────────────────────────────────────────────────────────────
# JE15 — delegated failure falls back to the local write (D06);
#        a hung delegation is bounded + emit skipped (D05,D07)
# ────────────────────────────────────────────────────────────────────────
echo "== JE15: a failed or hung delegation falls back to the local write =="
reset_case je15
mk_job je15-delegate
REPORT="$TMP/je15-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je15-delegate w:p1 "$REPORT"
sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || fail "JE15: sentinel mid-sleep"
PSTUB="$TMP/panewire-stub"; cat >"$PSTUB" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
exit 42
EOF
chmod +x "$PSTUB"
out="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PSTUB" \
  "$WRK" 'done' je15-delegate --report "$REPORT" 2>&1)" || fail "JE15a: done must survive a delegated failure"
printf '%s\n' "$out" | grep -q "delegation failed" ||
  { printf '%s\n' "$out"; fail "JE15a: fallback must warn on stderr"; }
event_count_is "$INBOX/je15-delegate/events" job.completed 1 ||
  fail "JE15a: the terminal record must still be written by the local path"
wait_until 8 pid_gone "$SENTINEL_PID" ||
  fail "JE15a: the sentinel must be stopped after the local fallback"

# JE15b — a panewire that hangs on the real call must be bounded, not block.
reset_case je15b
mk_job je15-hang
REPORT="$TMP/je15b-report.md"; printf 'x\n' >"$REPORT"
PSTUB_HANG="$TMP/panewire-stub-hang"; cat >"$PSTUB_HANG" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
sleep 60 &
echo $! > "$GRANDCHILD_LOG"
wait
EOF
chmod +x "$PSTUB_HANG"
start_ts=$(date +%s)
out="$(env GRANDCHILD_LOG="$TMP/je15b-grandchild.pid" \
  HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PSTUB_HANG" \
  WRK_JOB_DELEGATE_TIMEOUT_S=2 \
  "$WRK" 'done' je15-hang --report "$REPORT" 2>&1)" || fail "JE15b: done must survive a hung delegation"
elapsed=$(( $(date +%s) - start_ts ))
(( elapsed < 7 )) || fail "JE15b: hung delegation blocked $elapsed seconds (timeout was 2)"
event_count_is "$INBOX/je15-hang/events" job.completed 1 ||
  fail "JE15b: the terminal record must be written after the timeout"
printf '%s\n' "$out" | grep -q 'rc=124' ||
  { printf '%s\n' "$out"; fail "JE15b: the delegated call must come back rc=124 (bounded)"; }
printf '%s\n' "$out" | grep -q 'emit skipped' ||
  { printf '%s\n' "$out"; fail "JE15b: emit must not re-enter the wedged binary"; }
if [[ -s "$TMP/je15b-grandchild.pid" ]]; then
  JE15B_GC="$(cat "$TMP/je15b-grandchild.pid")"; own "$JE15B_GC"
  pid_gone "$JE15B_GC" ||
    { kill -9 "$JE15B_GC" 2>/dev/null; fail "JE15b: the stub's grandchild must die with the bound"; }
fi
echo "PASS je15 delegation-failure-and-hang-fallback"

# ────────────────────────────────────────────────────────────────────────
# JE16 — done stops every sentinel of the job, not just the pidfile's (J14)
# ────────────────────────────────────────────────────────────────────────
echo "== JE16: wrk done stops every sentinel of the job, not just the pidfile's =="
reset_case je16
mk_job je16-dual
REPORT="$TMP/je16-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je16-dual w:p1 "$REPORT"
SENT_A=$SENTINEL_PID
sentinel_mid_sleep "$SENT_A" >/dev/null || fail "JE16: first sentinel mid-sleep"
start_sentinel je16-dual w:p1 "$REPORT"   # second sentinel overwrites the pidfile
SENT_B=$SENTINEL_PID
sentinel_mid_sleep "$SENT_B" >/dev/null || fail "JE16: second sentinel mid-sleep"
if ! { kill -0 "$SENT_A" 2>/dev/null && kill -0 "$SENT_B" 2>/dev/null; }; then
  fail "JE16: need both sentinels alive before done"
fi
done_run je16-dual --report "$REPORT" >/dev/null 2>&1
wait_until 8 pid_gone "$SENT_A" ||
  { kill -9 "$SENT_A" "$SENT_B" 2>/dev/null; fail "JE16: the pidfile-less sentinel survived done"; }
wait_until 4 pid_gone "$SENT_B" ||
  { kill -9 "$SENT_B" 2>/dev/null; fail "JE16: the pidfile sentinel survived done"; }
echo "PASS je16 done-stops-all-sentinels"

# ────────────────────────────────────────────────────────────────────────
# JE17 — partial delegated joined: dedup + end declaration + stop (J06)
# ────────────────────────────────────────────────────────────────────────
echo "== JE17: a partially-written delegated joined is not duplicated =="
reset_case je17
mk_builder_job je17-dup
REPORT="$TMP/je17-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je17-dup w:p1 "$REPORT"
JE17_CHILD="$(sentinel_mid_sleep "$SENTINEL_PID")" || fail "JE17: sentinel mid-sleep"
PSTUB_DUP="$TMP/panewire-stub-dup"; cat >"$PSTUB_DUP" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
if [ "$1" = "job" ] && [ "$2" = "joined" ]; then
  "$STUB_ARBITER" event --job "$3" --kind job.joined \
    --payload-json '{"owner_lane":"lane-a","label":"lbl","pr":"u","head":"h"}' >/dev/null 2>&1
  exit 42
fi
exit 42
EOF
chmod +x "$PSTUB_DUP"
out="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PSTUB_DUP" STUB_ARBITER="$ARBITER" \
  "$WRK" joined je17-dup --pr https://example.invalid/pr/9 --head beef \
    --report "$REPORT" 2>&1)" || fail "JE17: joined must survive a partial delegated write"
event_count_is "$INBOX/je17-dup/events" job.joined 1 ||
  fail "JE17: the fallback must not write a second job.joined"
printf '%s\n' "$out" | grep -q 'already recorded' ||
  { printf '%s\n' "$out"; fail "JE17: expected the duplicate-suppression warning"; }
event_count_is "$INBOX/je17-dup/events" job.revoked 1 ||
  fail "JE17: the housekeeping end declaration must still land"
wait_until 8 pid_gone "$SENTINEL_PID" ||
  fail "JE17: the fallback path must still stop the sentinel"
wait_until 5 pid_gone "$JE17_CHILD" || fail "JE17: the sleep child must die too"
[[ ! -e "$INBOX/je17-dup/completion-sentinel.pid" ]] ||
  fail "JE17: the pidfile must be removed"
echo "PASS je17 partial-joined-dedup"

# ────────────────────────────────────────────────────────────────────────
# JE18 — python fallback bounds the delegated call's whole group (D03,D04;
#         H03 portable PATH — no timeout/gtimeout on EITHER platform).
# ────────────────────────────────────────────────────────────────────────
echo "== JE18: the python timeout fallback kills the delegated call's group =="
reset_case je18
mk_job je18-fbhang
REPORT="$TMP/je18-report.md"; printf 'x\n' >"$REPORT"
PSTUB_FB="$TMP/panewire-stub-fbhang"; cat >"$PSTUB_FB" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
sleep 12 &
echo $! > "$GRANDCHILD_LOG"
wait
EOF
chmod +x "$PSTUB_FB"
JE18_PATH="$TMP/je18-path"
make_stub_path "$JE18_PATH" timeout gtimeout
# Prove inside the child environment that neither guard resolves (the #770
# defect: /usr/bin:/bin keeps /usr/bin/timeout on Linux).
[[ -z "$(env PATH="$JE18_PATH" bash -c 'command -v timeout gtimeout' 2>/dev/null)" ]] ||
  fail "JE18: timeout/gtimeout must be absent from the private PATH"
start_ts=$(date +%s)
out="$(env PATH="$JE18_PATH" \
  GRANDCHILD_LOG="$TMP/je18-grandchild.pid" \
  HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PSTUB_FB" \
  WRK_JOB_DELEGATE_TIMEOUT_S=2 \
  "$WRK" 'done' je18-fbhang --report "$REPORT" 2>&1)" ||
  fail "JE18: done must survive a hung delegation under the python fallback"
elapsed=$(( $(date +%s) - start_ts ))
(( elapsed < 7 )) || fail "JE18: fallback-blocked $elapsed seconds — orphaned grandchild held the pipe (timeout was 2)"
event_count_is "$INBOX/je18-fbhang/events" job.completed 1 ||
  fail "JE18: the terminal record must be written after the timeout"
printf '%s\n' "$out" | grep -q 'rc=124' ||
  { printf '%s\n' "$out"; fail "JE18: the delegated call must come back rc=124 under the fallback"; }
printf '%s\n' "$out" | grep -q 'emit skipped' ||
  { printf '%s\n' "$out"; fail "JE18: emit must not re-enter the wedged binary"; }
[[ -s "$TMP/je18-grandchild.pid" ]] ||
  fail "JE18: the stub must have logged its grandchild sleep pid"
JE18_GC="$(cat "$TMP/je18-grandchild.pid")"; own "$JE18_GC"
pid_gone "$JE18_GC" ||
  { kill -9 "$JE18_GC" 2>/dev/null; fail "JE18: the orphaned grandchild must die with the group kill"; }
echo "PASS je18 fallback-bounds-hung-delegation"

# ────────────────────────────────────────────────────────────────────────
# JE19 — duplicate done still stops the sentinel (J03)
# ────────────────────────────────────────────────────────────────────────
echo "== JE19: a duplicate done still stops the sentinel =="
reset_case je19
mk_job je19-dup
REPORT="$TMP/je19-report.md"; printf 'dup\n' >"$REPORT"
# The sentinel must enter its interval sleep on the LIVE job first — once
# job.completed exists, a sentinel exits at its next record watch before it
# ever reaches sleep. The completion lands via arbiter (not wrk done) while
# the sentinel sleeps, so the wrk done below hits the duplicate branch.
start_sentinel je19-dup w:p1 "$REPORT"
JE19_CHILD="$(sentinel_mid_sleep "$SENTINEL_PID")" || fail "JE19: sentinel mid-sleep"
# The duplicate check keys on report_sha256 — the seeded record must carry it
# (a bare arb event record reads as legacy and can never suppress).
python3 - "$INBOX/je19-dup/events" "$REPORT" <<'PY'
import hashlib, json, os, sys
events, report = sys.argv[1], sys.argv[2]
os.makedirs(events, exist_ok=True)
digest = hashlib.sha256(open(report, "rb").read()).hexdigest()
json.dump({"kind": "job.completed", "job_id": "je19-dup", "owner_lane": "lane-a",
           "label": "lbl", "report_path": report, "report_sha256": digest},
          open(os.path.join(events, "00001-job.completed.json"), "w"))
PY
out="$(done_run je19-dup --report "$REPORT" 2>&1)" || fail "JE19: duplicate done must succeed"
printf '%s\n' "$out" | grep -q 'suppressed duplicate' ||
  fail "JE19: the duplicate must be suppressed, got: $out"
event_count_is "$INBOX/je19-dup/events" job.completed 1 ||
  fail "JE19: exactly one completion may exist after the duplicate"
wait_until 8 pid_gone "$SENTINEL_PID" ||
  fail "JE19: a duplicate done still ends the sentinel"
wait_until 5 pid_gone "$JE19_CHILD" || fail "JE19: the sleep child must die too"
[[ ! -e "$INBOX/je19-dup/completion-sentinel.pid" ]] ||
  fail "JE19: the pidfile must be removed"
echo "PASS je19 duplicate-done-stops-sentinel"

# ────────────────────────────────────────────────────────────────────────
# JE20 — a SUCCESSFUL delegated joined gets the same housekeeping (J05)
# ────────────────────────────────────────────────────────────────────────
echo "== JE20: a successful delegated joined still cleans up =="
reset_case je20
mk_builder_job je20-join
REPORT="$TMP/je20-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je20-join w:p1 "$REPORT"
JE20_CHILD="$(sentinel_mid_sleep "$SENTINEL_PID")" || fail "JE20: sentinel mid-sleep"
PSTUB_OK="$TMP/panewire-stub-joined-ok"; cat >"$PSTUB_OK" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
if [ "$1" = "job" ] && [ "$2" = "joined" ]; then
  "$STUB_ARBITER" event --job "$3" --kind job.joined \
    --payload-json '{"owner_lane":"builder-lane","label":"lbl","pr":"u","head":"h"}' >/dev/null 2>&1
  exit 0
fi
exit 42
EOF
chmod +x "$PSTUB_OK"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PSTUB_OK" STUB_ARBITER="$ARBITER" \
  "$WRK" joined je20-join --pr https://example.invalid/pr/8 --head feed \
    --report "$REPORT" >/dev/null 2>&1 || fail "JE20: delegated joined must succeed"
event_count_is "$INBOX/je20-join/events" job.joined 1 ||
  fail "JE20: the delegated stub must have written job.joined"
event_count_is "$INBOX/je20-join/events" job.revoked 1 ||
  fail "JE20: delegated joined must still declare the hub end"
wait_until 8 pid_gone "$SENTINEL_PID" ||
  fail "JE20: a delegated joined must still stop the sentinel"
wait_until 5 pid_gone "$JE20_CHILD" || fail "JE20: the sleep child must die too"
[[ ! -e "$INBOX/je20-join/completion-sentinel.pid" ]] ||
  fail "JE20: the pidfile must be removed"
echo "PASS je20 delegated-joined-housekeeping"

# ────────────────────────────────────────────────────────────────────────
# JE21 — prune stops a pane-gone orphan and declares the end (J09)
# ────────────────────────────────────────────────────────────────────────
echo "== JE21: prune --apply stops a sentinel whose pane is provably gone =="
reset_case je21
mk_job je21-gone w:p99
REPORT="$TMP/je21-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je21-gone w:p99 "$REPORT"
JE21_CHILD="$(sentinel_mid_sleep "$SENTINEL_PID")" || fail "JE21: sentinel mid-sleep"
# The job is NOT ended; the pane is provably gone (agent_not_found).
SEQ_GONE="$TMP/je21.seq"; printf '%s\n' not-found >"$SEQ_GONE"
OUT="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  WRK_FIXTURE_GET_SEQUENCE="$SEQ_GONE" "$WRK" prune --apply)"
grep -q "je21-gone.*orphan=yes.*pane-gone" <<<"$OUT" ||
  fail "JE21: the pane-gone sentinel must be listed as an orphan: $OUT"
wait_until 8 pid_gone "$SENTINEL_PID" ||
  fail "JE21: prune must stop the verified pane-gone sentinel"
wait_until 5 pid_gone "$JE21_CHILD" || fail "JE21: the sleep child must die too"
[[ ! -e "$INBOX/je21-gone/completion-sentinel.pid" ]] ||
  fail "JE21: the pidfile must be removed"
event_count_is "$INBOX/je21-gone/events" job.revoked 1 ||
  fail "JE21: prune must append the end declaration for the pane-gone job"
echo "PASS je21 pane-gone-orphan-stopped"

# ────────────────────────────────────────────────────────────────────────
# JE22 — a claim newer than the terminal record revives the job (P02)
# ────────────────────────────────────────────────────────────────────────
echo "== JE22: a claim revives a terminal job — prune keeps its sentinel =="
reset_case je22
mk_job je22 w:p5
arb event --job je22 --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
# Newest record is a fresh claim — no spawned after it (P02's shape).
arb event --job je22 --kind job.claim \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null
REPORT="$TMP/je22-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je22 w:p5 "$REPORT"
sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || fail "JE22: sentinel mid-sleep"
REVIVED_PID="$SENTINEL_PID"
prune_run --apply >/dev/null
kill -0 "$REVIVED_PID" 2>/dev/null ||
  fail "JE22: a claim newer than the terminal record revives the job — its sentinel must survive"
kill_owned_tree "$REVIVED_PID"
echo "PASS je22 claim-revive-protected"

# ────────────────────────────────────────────────────────────────────────
# JE23 — a spawned receipt alone (no claim) revives the job (P03)
# ────────────────────────────────────────────────────────────────────────
echo "== JE23: a spawned receipt alone revives the job — prune keeps its sentinel =="
reset_case je23
mk_job je23 w:p6
arb event --job je23 --kind job.revoked \
  --payload-json '{"owner_lane":"lane-a","label":"lbl","outcome":"abandoned"}' >/dev/null 2>&1 || true
arb event --job je23 --kind job.spawned \
  --payload-json '{"owner_lane":"lane-a","label":"lbl","pane_id":"w:p6"}' >/dev/null
REPORT="$TMP/je23-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je23 w:p6 "$REPORT"
sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || fail "JE23: sentinel mid-sleep"
RESPAWNED_PID="$SENTINEL_PID"
prune_run --apply >/dev/null
kill -0 "$RESPAWNED_PID" 2>/dev/null ||
  fail "JE23: a spawned receipt newer than the terminal record revives the job — sentinel must survive"
kill_owned_tree "$RESPAWNED_PID"
echo "PASS je23 spawned-revive-protected"

# ────────────────────────────────────────────────────────────────────────
# JE24 — a SIGSTOPped sentinel on a live job is not an orphan (P04)
# ────────────────────────────────────────────────────────────────────────
echo "== JE24: a SIGSTOPped sentinel on a live job stays protected =="
reset_case je24
mk_job je24 w:p1
REPORT="$TMP/je24-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je24 w:p1 "$REPORT"
JE24_CHILD="$(sentinel_mid_sleep "$SENTINEL_PID")" || fail "JE24: sentinel mid-sleep"
kill -STOP "$SENTINEL_PID" || fail "JE24: SIGSTOP must reach the owned sentinel"
OUT="$(prune_run --apply)"
grep -q "je24.*state=protected" <<<"$OUT" ||
  fail "JE24: a stopped sentinel on a live job must be protected, got: $OUT"
kill -0 "$SENTINEL_PID" 2>/dev/null ||
  fail "JE24: a SIGSTOPped sentinel is still the live job's watcher — never signalled"
kill -0 "$JE24_CHILD" 2>/dev/null ||
  fail "JE24: the stopped sentinel's child must survive too"
[[ -e "$INBOX/je24/completion-sentinel.pid" ]] ||
  fail "JE24: the pidfile must be retained for the protected sentinel"
kill -CONT "$SENTINEL_PID" 2>/dev/null || true
kill_owned_tree "$SENTINEL_PID"
echo "PASS je24 stopped-sentinel-protected"

# ────────────────────────────────────────────────────────────────────────
# JE25 — an unverifiable pane keeps the sentinel protected (P05)
# ────────────────────────────────────────────────────────────────────────
echo "== JE25: unverifiable pane evidence never authorizes a stop =="
reset_case je25
mk_job je25 w:p8
REPORT="$TMP/je25-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je25 w:p8 "$REPORT"
sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || fail "JE25: sentinel mid-sleep"
SEQ_GARBAGE="$TMP/je25.seq"; printf '%s\n' garbage >"$SEQ_GARBAGE"
OUT="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  WRK_FIXTURE_GET_SEQUENCE="$SEQ_GARBAGE" "$WRK" prune --apply)"
grep -q "je25.*state=protected.*pane-unverifiable" <<<"$OUT" ||
  fail "JE25: malformed probe output must keep the sentinel protected, got: $OUT"
kill -0 "$SENTINEL_PID" 2>/dev/null ||
  fail "JE25: unverifiable evidence must never authorize a signal"
[[ -e "$INBOX/je25/completion-sentinel.pid" ]] ||
  fail "JE25: the pidfile is retained while the sentinel is protected"
kill_owned_tree "$SENTINEL_PID"
echo "PASS je25 unverifiable-pane-protected"

# ────────────────────────────────────────────────────────────────────────
# JE26 — a sweep-found sentinel outside the jobs root is protected (P06)
# ────────────────────────────────────────────────────────────────────────
echo "== JE26: a sentinel with no job dir under the scanned root is protected =="
reset_case je26
# The sentinel writes its pidfile under INBOX-A; prune scans INBOX-B, where
# the job has no directory — the sweep row is the only evidence and it must
# fail closed (list, never signal).
INBOX_B="$TMP/inbox-je26-b"; mkdir -p "$INBOX_B"
REPORT="$TMP/je26-report.md"; printf 'x\n' >"$REPORT"
start_sentinel je26-out w:p1 "$REPORT"
sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || fail "JE26: sentinel mid-sleep"
printf '%s\n' not-found >"$TMP/je26.seq"
OUT="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX_B" XDG_DATA_HOME="$XDG" \
  WRK_FIXTURE_GET_SEQUENCE="$TMP/je26.seq" "$WRK" prune --apply --job je26-out)"
grep -q "je26-out.*outside-jobs-root" <<<"$OUT" ||
  fail "JE26: the outside-root sentinel must be listed protected, got: $OUT"
kill -0 "$SENTINEL_PID" 2>/dev/null ||
  fail "JE26: a sentinel outside the jobs root must never be signalled"
kill_owned_tree "$SENTINEL_PID"
echo "PASS je26 outside-root-protected"

# ────────────────────────────────────────────────────────────────────────
# JE27 — `timeout` is the selected guard when it exists (D01)
# ────────────────────────────────────────────────────────────────────────
echo "== JE27: run_bounded selects GNU timeout when available =="
reset_case je27
mk_job je27-timeout
REPORT="$TMP/je27-report.md"; printf 'x\n' >"$REPORT"
PSTUB42="$TMP/panewire-stub-42"; cat >"$PSTUB42" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
exit 42
EOF
chmod +x "$PSTUB42"
JE27_PATH="$TMP/je27-path"
# Exclude BOTH real guards, then install a `timeout` wrapper — from wrk's side
# this is indistinguishable from a platform with GNU timeout installed.
make_stub_path "$JE27_PATH" timeout gtimeout
cat >"$JE27_PATH/timeout" <<'EOF'
#!/bin/sh
printf 'timeout %s\n' "$*" >> "$WRAPPER_LOG"
secs="$1"; shift
exec "$@"
EOF
chmod +x "$JE27_PATH/timeout"
WRAPPER_LOG="$TMP/je27-wrapper.log"; : >"$WRAPPER_LOG"
env PATH="$JE27_PATH" WRAPPER_LOG="$WRAPPER_LOG" \
  HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PSTUB42" \
  "$WRK" 'done' je27-timeout --report "$REPORT" >/dev/null 2>&1 ||
  fail "JE27: done must complete under the timeout guard"
grep -q 'job done' "$WRAPPER_LOG" ||
  fail "JE27: run_bounded must invoke the timeout wrapper for the delegated call"
event_count_is "$INBOX/je27-timeout/events" job.completed 1 ||
  fail "JE27: the local fallback still writes the record"
echo "PASS je27 timeout-selected"

# ────────────────────────────────────────────────────────────────────────
# JE28 — `gtimeout` is the selected guard when only it exists (D02)
# ────────────────────────────────────────────────────────────────────────
echo "== JE28: run_bounded selects gtimeout when timeout is absent =="
reset_case je28
mk_job je28-gtimeout
REPORT="$TMP/je28-report.md"; printf 'x\n' >"$REPORT"
JE28_PATH="$TMP/je28-path"
make_stub_path "$JE28_PATH" timeout gtimeout
cat >"$JE28_PATH/gtimeout" <<'EOF'
#!/bin/sh
printf 'gtimeout %s\n' "$*" >> "$WRAPPER_LOG"
secs="$1"; shift
exec "$@"
EOF
chmod +x "$JE28_PATH/gtimeout"
WRAPPER_LOG="$TMP/je28-wrapper.log"; : >"$WRAPPER_LOG"
env PATH="$JE28_PATH" WRAPPER_LOG="$WRAPPER_LOG" \
  HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PSTUB42" \
  "$WRK" 'done' je28-gtimeout --report "$REPORT" >/dev/null 2>&1 ||
  fail "JE28: done must complete under the gtimeout guard"
grep -q 'job done' "$WRAPPER_LOG" ||
  fail "JE28: run_bounded must invoke the gtimeout wrapper for the delegated call"
event_count_is "$INBOX/je28-gtimeout/events" job.completed 1 ||
  fail "JE28: the local fallback still writes the record"
echo "PASS je28 gtimeout-selected"

# ────────────────────────────────────────────────────────────────────────
# JE29 — a clean supervisor exit removes its pidfile (Q02)
# ────────────────────────────────────────────────────────────────────────
echo "== JE29: a normal refresh exit removes the supervisor pidfile =="
reset_case je29
# hang with a short delay: the pidfile is observable while the child sleeps,
# the refresh then exits 0 and the supervisor must drop its pidfile.
env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
  ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE=new PANEWIRE_BIN="$PANEWIRE" \
  WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$HERDR_LOG" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
  WRK_REFRESH_MODE=hang WRK_REFRESH_DELAY=1 WRK_REFRESH_TIMEOUT_S=10 \
  "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l je29 --t T1 \
  --task 1 --job je29 >"$TMP/je29.out" 2>"$TMP/je29.err" &
SPAWN_PID=$!
PIDFILE="$INBOX/je29/quota-refresh.pid"
wait_until 10 test -f "$PIDFILE" ||
  fail "JE29: the supervisor must write its pidfile while the refresh runs"
SUP_PID="$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$PIDFILE")"; own "$SUP_PID"
wait "$SPAWN_PID" || fail "JE29: spawn failed: $(cat "$TMP/je29.out" "$TMP/je29.err")"
wait_until 10 test '!' -e "$PIDFILE" ||
  fail "JE29: a clean refresh exit must remove the supervisor pidfile"
grep -q 'refresh' "$TMP/refresh.log" ||
  fail "JE29: the refresh child must actually have run"
echo "PASS je29 refresh-pidfile-removed-on-exit"

# ────────────────────────────────────────────────────────────────────────
# JE30 — a pidfile naming an unrelated owned process loses only the file,
#        across every end path (I01,I07)
# ────────────────────────────────────────────────────────────────────────
echo "== JE30: an unrelated process named by a pidfile is never signalled =="
reset_case je30-done
mk_job je30-done
REPORT="$TMP/je30-report.md"; printf 'x\n' >"$REPORT"
spawn_sleeper; J30A=$SLEEPER_PID
printf '%s\n' "$J30A" >"$INBOX/je30-done/completion-sentinel.pid"
done_run je30-done --report "$REPORT" >/dev/null 2>&1
kill -0 "$J30A" 2>/dev/null ||
  fail "JE30/done: the unrelated process must never be signalled"
[[ ! -e "$INBOX/je30-done/completion-sentinel.pid" ]] ||
  fail "JE30/done: the stale pidfile must be removed"

reset_case je30-dup
mk_job je30-dup
done_run je30-dup --report "$REPORT" >/dev/null 2>&1
spawn_sleeper; J30B=$SLEEPER_PID
printf '%s\n' "$J30B" >"$INBOX/je30-dup/completion-sentinel.pid"
done_run je30-dup --report "$REPORT" >/dev/null 2>&1
kill -0 "$J30B" 2>/dev/null ||
  fail "JE30/duplicate-done: the unrelated process must never be signalled"
[[ ! -e "$INBOX/je30-dup/completion-sentinel.pid" ]] ||
  fail "JE30/duplicate-done: the stale pidfile must be removed"

reset_case je30-joined
mk_builder_job je30-joined
spawn_sleeper; J30C=$SLEEPER_PID
printf '%s\n' "$J30C" >"$INBOX/je30-joined/completion-sentinel.pid"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
  "$WRK" joined je30-joined --pr https://example.invalid/pr/1 --head beef --report "$REPORT" >/dev/null 2>&1
kill -0 "$J30C" 2>/dev/null ||
  fail "JE30/joined: the unrelated process must never be signalled"
[[ ! -e "$INBOX/je30-joined/completion-sentinel.pid" ]] ||
  fail "JE30/joined: the stale pidfile must be removed"

reset_case je30-delegated
mk_job je30-delegated
spawn_sleeper; J30D=$SLEEPER_PID
printf '%s\n' "$J30D" >"$INBOX/je30-delegated/completion-sentinel.pid"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
  WRK_PANEWIRE_JOB=present WRK_PANEWIRE_JOB_LOG="$TMP/je30-pw.log" \
  "$WRK" 'done' je30-delegated --report "$REPORT" >/dev/null 2>&1
kill -0 "$J30D" 2>/dev/null ||
  fail "JE30/delegated-done: the unrelated process must never be signalled"
[[ ! -e "$INBOX/je30-delegated/completion-sentinel.pid" ]] ||
  fail "JE30/delegated-done: the stale pidfile must be removed"

reset_case je30-reap
ARBITER_TEST_NOW="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).replace(microsecond=0).isoformat())')"
export ARBITER_TEST_NOW
arb claim --job je30-reap --lane lane-a --agent-label je30-reap --t T1 >/dev/null
arb event --job je30-reap --kind job.spawned \
  --payload-json '{"owner_lane":"lane-a","label":"je30-reap","pane_id":"w1:p1","tab_id":"w1:t1"}' >/dev/null
unset ARBITER_TEST_NOW
arb event --job je30-reap --kind job.joined \
  --payload-json '{"owner_lane":"lane-a","label":"je30-reap","pane_id":"w1:p1"}' >/dev/null
spawn_sleeper; J30E=$SLEEPER_PID
printf '%s\n' "$J30E" >"$INBOX/je30-reap/completion-sentinel.pid"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" WRK_FIXTURE_SCENARIO=reap \
  "$WRK" reap --apply --lane lane-a --grace 0s >/dev/null 2>&1 ||
  fail "JE30/reap: wrk reap --apply must succeed"
kill -0 "$J30E" 2>/dev/null ||
  fail "JE30/reap: the unrelated process must never be signalled"
[[ ! -e "$INBOX/je30-reap/completion-sentinel.pid" ]] ||
  fail "JE30/reap: the stale pidfile must be removed"
kill_owned_tree "$J30A"; kill_owned_tree "$J30B"; kill_owned_tree "$J30C"
kill_owned_tree "$J30D"; kill_owned_tree "$J30E"
echo "PASS je30 unrelated-pidfile-never-signalled"

# ────────────────────────────────────────────────────────────────────────
# JE31 — a refresh pidfile pointing at a plain python process is unverified
#        (Q06): argv must carry THIS pidfile path, not merely "python".
# ────────────────────────────────────────────────────────────────────────
echo "== JE31: a refresh pidfile at a plain python process is never signalled =="
reset_case je31
mk_job je31-plain
mk_job je31-grp
NOW=$(date +%s)
# Variant A: plain `python3 -c sleep` — greps as python but is not a supervisor.
spawn_python_sleeper; J31A=$SLEEPER_PID
printf 'pid=%d pool=p job=je31-plain timeout=1 deadline=%d started=%d\n' \
  "$J31A" "$(( NOW - 120 ))" "$NOW" >"$INBOX/je31-plain/quota-refresh.pid"
# Variant B: a process-group leader with an owned child in its group — a
# misjudged `kill -- -PID` would take the whole innocent group down.
python3 -c 'import os,subprocess,time
os.setsid()
subprocess.Popen(["sleep", "600"])
time.sleep(600)' &
J31B=$!
own "$J31B"
J31B_CHILD=""
for _ in $(seq 1 50); do
  J31B_CHILD="$(pgrep -P "$J31B" 2>/dev/null | head -1 || true)"
  if [[ -n "$J31B_CHILD" ]]; then break; fi
  sleep 0.1
done
[[ -n "$J31B_CHILD" ]] || fail "JE31: the group-leader fixture must spawn its child"
own "$J31B_CHILD"
printf 'pid=%d pool=p job=je31-grp timeout=1 deadline=%d started=%d\n' \
  "$J31B" "$(( NOW - 120 ))" "$NOW" >"$INBOX/je31-grp/quota-refresh.pid"
OUT="$(prune_run --apply)"
grep -q "je31-plain.*pid-unverified" <<<"$OUT" ||
  fail "JE31: a plain python process must classify pid-unverified: $OUT"
grep -q "je31-grp.*pid-unverified" <<<"$OUT" ||
  fail "JE31: the group-leader python must classify pid-unverified: $OUT"
kill -0 "$J31A" 2>/dev/null ||
  fail "JE31: the plain python process must never be signalled"
kill -0 "$J31B" 2>/dev/null ||
  fail "JE31: the group leader must never be signalled"
kill -0 "$J31B_CHILD" 2>/dev/null ||
  fail "JE31: the innocent group child must never be signalled"
[[ -e "$INBOX/je31-plain/quota-refresh.pid" ]] ||
  fail "JE31: an unverified pidfile is retained (protected, not deleted)"
kill_owned_tree "$J31A"; kill_owned_tree "$J31B"
echo "PASS je31 refresh-pid-unverified"

# ────────────────────────────────────────────────────────────────────────
# JE32 — a refresh pidfile whose `started` disagrees with the live process
#        is not authority (Q07)
# ────────────────────────────────────────────────────────────────────────
echo "== JE32: an inconsistent refresh start time is not authority =="
reset_case je32
mk_job je32
# Supervisor-SHAPED argv — it even names this pidfile at argv[5] — but the
# recorded start disagrees with the process's real elapsed age by ~2h.
J32_PF="$INBOX/je32/quota-refresh.pid"
python3 - "$SCOPEFUEL" fakepool 60 "$J32_PF" je32 <<'PY' >/dev/null 2>&1 &
import sys, time
time.sleep(600)
PY
J32=$!
own "$J32"
NOW=$(date +%s)
printf 'pid=%d pool=fakepool job=je32 timeout=60 deadline=%d started=%d\n' \
  "$J32" "$(( NOW - 120 ))" "$(( NOW - 7200 ))" >"$J32_PF"
OUT="$(prune_run --apply)"
grep -q "je32.*pid-unverified" <<<"$OUT" ||
  fail "JE32: a started time 2h off the real elapsed must classify pid-unverified: $OUT"
kill -0 "$J32" 2>/dev/null ||
  fail "JE32: an inconsistent recorded start must never authorize a signal"
[[ -e "$J32_PF" ]] || fail "JE32: an unverified pidfile is retained"
kill_owned_tree "$J32"
echo "PASS je32 refresh-start-mismatch-protected"

# ────────────────────────────────────────────────────────────────────────
# JE33 — `wrk sentinel JOB` text inside a foreign argv is not identity (I03)
# ────────────────────────────────────────────────────────────────────────
echo "== JE33: sentinel argv text inside another process is not identity =="
reset_case je33
mk_job je33-fake
mk_job je33-done
# The counterexample shape: a python process whose later arguments contain a
# literal `/fake/wrk sentinel <job>` triple. The old token scan accepted this;
# the executable position rule must reject it.
python3 -c 'import time; time.sleep(600)' /fake/wrk sentinel je33-fake owner lbl w:p1 &
J33=$!
own "$J33"
arb event --job je33-fake --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
printf '%s\n' "$J33" >"$INBOX/je33-fake/completion-sentinel.pid"
# prune --apply must not signal it (pidfile pass) …
OUT="$(prune_run --apply)"
kill -0 "$J33" 2>/dev/null ||
  fail "JE33: incidental '/fake/wrk sentinel JOB' argv text must never pass identity"
grep -q "je33-fake.*pid-reused" <<<"$OUT" ||
  fail "JE33: the fake must classify as pid-reused: $OUT"
# … and a job-end path must not either (its own pidfile names the fake).
REPORT="$TMP/je33-report.md"; printf 'x\n' >"$REPORT"
printf '%s\n' "$J33" >"$INBOX/je33-done/completion-sentinel.pid"
done_run je33-done --report "$REPORT" >/dev/null 2>&1
kill -0 "$J33" 2>/dev/null ||
  fail "JE33: the job-end stop path must not signal a fake-argv process"
[[ ! -e "$INBOX/je33-done/completion-sentinel.pid" ]] ||
  fail "JE33: the stale pidfile is still removed"
kill_owned_tree "$J33"
echo "PASS je33 incidental-argv-rejected"

# ────────────────────────────────────────────────────────────────────────
# JE34 — a stale recorded `started` never authorizes the pidfile's pid (I04)
# ────────────────────────────────────────────────────────────────────────
echo "== JE34: a stale recorded start time voids the pidfile's authority =="
reset_case je34
mk_job je34-live w:p4
REPORT="$TMP/je34-report.md"; printf 'x\n' >"$REPORT"
# A REAL sentinel for a LIVE job, but its pidfile claims a start 11h ago —
# the recorded start must agree with the real elapsed age, else the file is
# treated as stale (removed, never used to authorize the pid).
start_sentinel je34-live w:p4 "$REPORT"
sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || fail "JE34: sentinel mid-sleep"
J34A=$SENTINEL_PID
printf '%s\nstarted=%s\n' "$J34A" "$(( $(date +%s) - 40000 ))" \
  >"$INBOX/je34-live/completion-sentinel.pid"
OUT="$(prune_run --apply)"
grep -q "je34-live.*pid-start-mismatch" <<<"$OUT" ||
  fail "JE34: a recorded start that disagrees must classify as stale: $OUT"
[[ ! -e "$INBOX/je34-live/completion-sentinel.pid" ]] ||
  fail "JE34: the stale pidfile is removed even though its pid is a live sentinel"
kill -0 "$J34A" 2>/dev/null ||
  fail "JE34: the protected live sentinel itself is untouched"

# Ended variant: the stale pidfile must not authorize the pidfile-derived
# kill — the legitimate process sweep still ends the real sentinel. The
# sentinel must be mid-sleep BEFORE the terminal record lands (a sentinel
# started after exits at its first record watch).
mk_job je34-ended w:p9
start_sentinel je34-ended w:p9 "$REPORT"
sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || fail "JE34: second sentinel mid-sleep"
J34B=$SENTINEL_PID
arb event --job je34-ended --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
printf '%s\nstarted=%s\n' "$J34B" "$(( $(date +%s) - 40000 ))" \
  >"$INBOX/je34-ended/completion-sentinel.pid"
OUT="$(prune_run --apply)"
grep -q "je34-ended.*pid-start-mismatch" <<<"$OUT" ||
  fail "JE34: the stale-started pidfile must be classified stale, got: $OUT"
wait_until 8 pid_gone "$J34B" ||
  fail "JE34: the process-sweep path still ends the real orphan sentinel"
[[ ! -e "$INBOX/je34-ended/completion-sentinel.pid" ]] ||
  fail "JE34: the stale pidfile is removed"
kill_owned_tree "$J34A"
echo "PASS je34 stale-started-voids-pidfile"

# ────────────────────────────────────────────────────────────────────────
# JE35 — spawn's sentinel start must not trust a reused pidfile pid (I05)
# ────────────────────────────────────────────────────────────────────────
echo "== JE35: a reused-pid pidfile must not suppress the spawn sentinel =="
reset_case je35
# Seed the pidfile with an unrelated owned sleeper BEFORE spawn — under the
# old bare `kill -0` liveness check this suppressed the real sentinel.
spawn_sleeper; J35_SLEEP=$SLEEPER_PID
mkdir -p "$INBOX/je35"
printf '%s\n' "$J35_SLEEP" >"$INBOX/je35/completion-sentinel.pid"
spawn_out="$(env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
  ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE=new PANEWIRE_BIN="$PANEWIRE" \
  WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$HERDR_LOG" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
  "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l je35 --t T1 \
  --task 1 --job je35 2>&1)" || fail "JE35: spawn failed: $spawn_out"
# The new sentinel is forked inside start_completion_sentinel's subshell before
# spawn returns, but its argv only reaches the final `wrk sentinel JOB` shape
# after the nohup/env exec chain settles — on a loaded shared runner that can
# lag the return by tens of ms, so poll rather than sample once. A suppressing
# mutant never spawns one, so the bound preserves RED.
# shellcheck disable=SC2329 # invoked indirectly via wait_until
je35_sentinel_up() { [[ "$(sentinel_count je35)" -eq 1 ]]; }
if ! wait_until 15 je35_sentinel_up; then
  echo "JE35 diagnostic: ps sentinel rows:" >&2
  # shellcheck disable=SC2009 # the diagnostic needs the full args column
  ps axo pid=,args= 2>/dev/null | grep -F 'sentinel' | head -10 >&2
  echo "JE35 diagnostic: pidfile=$(cat "$INBOX/je35/completion-sentinel.pid" 2>&1)" >&2
  echo "JE35 diagnostic: sentinel log tail:" >&2
  tail -10 "$INBOX/je35/completion-sentinel.log" 2>/dev/null >&2 || true
  fail "JE35: the reused-pid pidfile must not suppress a new sentinel start"
fi
NEW_PID="$(head -n 1 "$INBOX/je35/completion-sentinel.pid")"
[[ "$NEW_PID" =~ ^[0-9]+$ && "$NEW_PID" != "$J35_SLEEP" ]] ||
  fail "JE35: the pidfile must be replaced by the new sentinel's pid"
kill -0 "$J35_SLEEP" 2>/dev/null ||
  fail "JE35: the unrelated sleeper is never signalled"
kill_owned_tree "$NEW_PID"; kill_owned_tree "$J35_SLEEP"
echo "PASS je35 reused-pidfile-starts-sentinel"

# ────────────────────────────────────────────────────────────────────────
# JE36 — a verified existing sentinel suppresses a second start (I06)
# ────────────────────────────────────────────────────────────────────────
echo "== JE36: a verified live sentinel suppresses a duplicate start =="
reset_case je36
REPORT="$TMP/je36-report.md"; printf 'x\n' >"$REPORT"
WRK_LIB="$TMP/wrk-lib.sh"
# Extract everything before the top-level `case` dispatch — a sourceable
# function library (the seam the contract allows for seam-only refactors).
awk 'index($0, "case \"${1:-}\" in") == 1 {exit} {print}' "$WRK" >"$WRK_LIB"
[[ -s "$WRK_LIB" ]] || fail "JE36: the function-library seam must not be empty"
start_via_lib() {
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" \
    WRK_FIXTURE_SCENARIO=sentinel-working \
    WRK_COMPLETION_TIMEOUT_S=300 WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_SENTINEL_LOST_GRACE=1800 WRK_LIBFILE="$WRK_LIB" \
    bash -c '. "$WRK_LIBFILE"; start_completion_sentinel "$@"' "$WRK" "$@"
}
mkdir -p "$INBOX/je36"
J36_PF="$INBOX/je36/completion-sentinel.pid"
start_via_lib "$J36_PF" je36 lane-a lbl w:p1 "$REPORT"
# shellcheck disable=SC2329 # invoked indirectly via wait_until
je36_sentinel_up() { [[ "$(sentinel_count je36)" -eq 1 ]]; }
# Same exec-window race as JE35 — poll rather than sample once.
wait_until 15 je36_sentinel_up ||
  fail "JE36: the first start must produce exactly one sentinel"
J36_PID="$(head -n 1 "$J36_PF")"; own "$J36_PID"
start_via_lib "$J36_PF" je36 lane-a lbl w:p1 "$REPORT"
sleep 0.5
[[ "$(sentinel_count je36)" -eq 1 ]] ||
  fail "JE36: a verified live sentinel must suppress the duplicate start"
[[ "$(head -n 1 "$J36_PF")" == "$J36_PID" ]] ||
  fail "JE36: the pidfile must still name the original sentinel"
kill_owned_tree "$J36_PID"
echo "PASS je36 verified-sentinel-suppresses-duplicate"

# ════════════════════════════════════════════════════════════════════════
# MUT — assertion-RED mutants: sed'd copies of bin/wrk (path ends in /wrk —
# H02 — so every mutant sentinel is judged by the same argv identity rule).
# Each expect_mut_red runs its case in a subshell; rc 0 = GREEN (the named
# assertion survived — suite fails), rc 3 = setup failure (suite fails),
# anything else = assertion RED (the invariant did its job).
# ════════════════════════════════════════════════════════════════════════
echo "== MUT: assertion-RED mutants per contract =="

mkmut() {
  local dir="$TMP/mut-$1"; shift
  mkdir -p "$dir"
  local args=() e
  for e in "$@"; do args+=(-e "$e"); done
  { sed "${args[@]}" "$WRK" >"$dir/wrk" && chmod +x "$dir/wrk"; } ||
    fail "mutant build failed: $*"
  MUT="$dir/wrk"
}

# mkmut_span NAME FIXED-PATTERN REPLACEMENT [SPAN] — replace the unique line
# containing PATTERN (and SPAN following lines) with REPLACEMENT. Fixed-string
# matching avoids the BRE escaping maze on multi-line awk constructs.
mkmut_span() {
  local name="$1" pat="$2" repl="$3" span="${4:-0}" ln dir
  ln="$(grep -nF -- "$pat" "$WRK" | head -1 | cut -d: -f1)"
  [[ -n "$ln" ]] || fail "MUT $name: pattern not found: $pat"
  dir="$TMP/mut-$name"; mkdir -p "$dir"
  awk -v a="$ln" -v b="$((ln + span))" -v r="$repl" \
    'NR==a{print r} NR<a||NR>b{print}' "$WRK" >"$dir/wrk"
  chmod +x "$dir/wrk"
  MUT="$dir/wrk"
}

expect_mut_red() {
  local desc="$1" fn="$2" rc=0
  local saved="$WRK"; WRK="$MUT"
  ( "$fn" ) || rc=$?
  WRK="$saved"
  if (( rc == 3 )); then
    fail "MUT $desc: setup failed inside the mutant case — the verdict is not meaningful"
  fi
  if (( rc == 0 )); then
    fail "MUT $desc: mutant stayed GREEN — the assertion does not cover this call site"
  fi
  echo "PASS mut $desc is assertion-RED (rc=$rc)"
}

# nth_lineno PATTERN N — the line number of the Nth fixed-string occurrence.
nth_lineno() {
  grep -nF "$1" "$WRK" | sed -n "${2}p" | cut -d: -f1
}

# ── mutant case bodies ─────────────────────────────────────────────────

case_done() {
  reset_case mut-done || return 3
  mk_job mut-done || return 3
  REPORT="$TMP/mut-done-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-done w:p1 "$REPORT"
  local child; child="$(sentinel_mid_sleep "$SENTINEL_PID")" || return 3
  done_run mut-done --report "$REPORT" >/dev/null 2>&1
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
  wait_until 4 pid_gone "$child" || return 1
  [[ ! -e "$INBOX/mut-done/completion-sentinel.pid" ]] || return 1
}

case_delegate_done() {
  reset_case mut-deldone || return 3
  mk_job mut-deldone || return 3
  REPORT="$TMP/mut-deldone-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-deldone w:p1 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
    WRK_PANEWIRE_JOB=present WRK_PANEWIRE_JOB_LOG="$TMP/mut-deldone-pw.log" \
    "$WRK" 'done' mut-deldone --report "$REPORT" >/dev/null 2>&1
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
  [[ ! -e "$INBOX/mut-deldone/completion-sentinel.pid" ]] || return 1
}

case_dup_done() {
  reset_case mut-dupdone || return 3
  mk_job mut-dupdone || return 3
  REPORT="$TMP/mut-dupdone-report.md"; printf 'x\n' >"$REPORT"
  # Sentinel mid-sleep on the live job, then the completion lands externally —
  # the done below takes the duplicate branch whose housekeeping J03 removes.
  start_sentinel mut-dupdone w:p1 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  python3 - "$INBOX/mut-dupdone/events" "$REPORT" <<'PY' || return 3
import hashlib, json, os, sys
events, report = sys.argv[1], sys.argv[2]
os.makedirs(events, exist_ok=True)
digest = hashlib.sha256(open(report, "rb").read()).hexdigest()
json.dump({"kind": "job.completed", "job_id": "mut-dupdone", "owner_lane": "lane-a",
           "label": "lbl", "report_path": report, "report_sha256": digest},
          open(os.path.join(events, "00001-job.completed.json"), "w"))
PY
  done_run mut-dupdone --report "$REPORT" >/dev/null 2>&1
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
  [[ ! -e "$INBOX/mut-dupdone/completion-sentinel.pid" ]] || return 1
}

case_joined() {
  reset_case mut-joined || return 3
  mk_builder_job mut-joined || return 3
  REPORT="$TMP/mut-joined-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-joined w:p1 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
    "$WRK" joined mut-joined --pr https://example.invalid/pr/1 --head deadbeef --report "$REPORT" >/dev/null 2>&1
  event_count_is "$INBOX/mut-joined/events" job.revoked 1 || return 1
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
  [[ ! -e "$INBOX/mut-joined/completion-sentinel.pid" ]] || return 1
}

case_delegate_joined() {
  reset_case mut-deljoined || return 3
  mk_builder_job mut-deljoined || return 3
  REPORT="$TMP/mut-deljoined-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-deljoined w:p1 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  local stub="$TMP/mut-pw-joined-ok"
  cat >"$stub" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
if [ "$1" = "job" ] && [ "$2" = "joined" ]; then
  "$STUB_ARBITER" event --job "$3" --kind job.joined \
    --payload-json '{"owner_lane":"builder-lane","label":"lbl","pr":"u","head":"h"}' >/dev/null 2>&1
  exit 0
fi
exit 42
EOF
  chmod +x "$stub" || return 3
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$stub" STUB_ARBITER="$ARBITER" \
    "$WRK" joined mut-deljoined --pr https://example.invalid/pr/8 --head feed \
      --report "$REPORT" >/dev/null 2>&1
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
  [[ ! -e "$INBOX/mut-deljoined/completion-sentinel.pid" ]] || return 1
}

case_partial_joined() {
  reset_case mut-pjoined || return 3
  mk_builder_job mut-pjoined || return 3
  REPORT="$TMP/mut-pjoined-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-pjoined w:p1 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  local stub="$TMP/mut-pw-dup-stub"
  cat >"$stub" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
if [ "$1" = "job" ] && [ "$2" = "joined" ]; then
  "$STUB_ARBITER" event --job "$3" --kind job.joined \
    --payload-json '{"owner_lane":"lane-a","label":"lbl","pr":"u","head":"h"}' >/dev/null 2>&1
  exit 42
fi
exit 42
EOF
  chmod +x "$stub" || return 3
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$stub" STUB_ARBITER="$ARBITER" \
    "$WRK" joined mut-pjoined --pr https://example.invalid/pr/9 --head beef \
      --report "$REPORT" >/dev/null 2>&1 || true
  event_count_is "$INBOX/mut-pjoined/events" job.joined 1 || return 1
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
}

case_reap() {
  reset_case mut-reap || return 3
  local old_ts
  old_ts="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).replace(microsecond=0).isoformat())')" || return 3
  ARBITER_TEST_NOW="$old_ts" arb claim --job mut-reap --lane lane-a --agent-label mut-reap --t T1 >/dev/null || return 3
  ARBITER_TEST_NOW="$old_ts" arb event --job mut-reap --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"mut-reap","pane_id":"w1:p1","tab_id":"w1:t1"}' >/dev/null || return 3
  REPORT="$TMP/mut-reap-report.md"; printf 'x\n' >"$REPORT"
  SCENARIO=reap start_sentinel mut-reap w1:p1 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  arb event --job mut-reap --kind job.joined \
    --payload-json '{"owner_lane":"lane-a","label":"mut-reap","pane_id":"w1:p1"}' >/dev/null || return 3
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" WRK_FIXTURE_SCENARIO=reap \
    "$WRK" reap --apply --lane lane-a --grace 0s >/dev/null 2>&1
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
  [[ ! -e "$INBOX/mut-reap/completion-sentinel.pid" ]] || return 1
}

case_prune_apply() {
  reset_case mut-prune || return 3
  mk_job mut-prune || return 3
  REPORT="$TMP/mut-prune-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-prune w:p1 "$REPORT"
  # H01: prove mid-sleep BEFORE the terminal record — under a no-stop mutant
  # the sentinel can only die by its own watch, which interval=3600 rules out.
  local child; child="$(sentinel_mid_sleep "$SENTINEL_PID")" || return 3
  arb event --job mut-prune --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
  local pid="$SENTINEL_PID"
  prune_run --apply >/dev/null 2>&1
  pid_gone "$pid" || return 1
  pid_gone "$child" || return 1
}

case_pane_gone() {
  reset_case mut-pgone || return 3
  mk_job mut-pgone w:p99 || return 3
  REPORT="$TMP/mut-pgone-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-pgone w:p99 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  local seq="$TMP/mut-pgone.seq"; printf '%s\n' not-found >"$seq"
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    WRK_FIXTURE_GET_SEQUENCE="$seq" "$WRK" prune --apply >/dev/null 2>&1
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
}

case_sentinel_complete() {
  reset_case mut-scomp || return 3
  mk_job mut-scomp || return 3
  REPORT="$TMP/mut-scomp-report.md"; printf 'final\n' >"$REPORT"
  SCENARIO=sentinel-done SENT_INTERVAL=1 start_sentinel mut-scomp w:p1 "$REPORT"
  wait_until 15 event_count_is "$INBOX/mut-scomp/events" job.completed 1 || return 1
  wait_until 10 pid_gone "$SENTINEL_PID" || return 1
  grep -q 'watch-exit' "$INBOX/mut-scomp/completion-sentinel.log" 2>/dev/null && return 1
  [[ ! -e "$INBOX/mut-scomp/completion-sentinel.pid" ]] || return 1
}

case_lost_grace() {
  reset_case mut-lost || return 3
  mk_job mut-lost || return 3
  local seq="$TMP/mut-lost.seq"; printf '%s\n' not-found >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=2 start_sentinel mut-lost w:p1 "$TMP/mut-lost-report.md" "$seq"
  wait_until 15 event_count_is "$INBOX/mut-lost/events" job.revoked 1 || return 1
  wait_until 10 pid_gone "$SENTINEL_PID" || return 1
  grep -q 'watch-exit' "$INBOX/mut-lost/completion-sentinel.log" 2>/dev/null && return 1
}

case_watch() {
  reset_case mut-watch || return 3
  mk_job mut-watch || return 3
  REPORT="$TMP/mut-watch-report.md"; printf 'x\n' >"$REPORT"
  SENT_INTERVAL=1 start_sentinel mut-watch w:p1 "$REPORT"
  sleep 0.5
  arb event --job mut-watch --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || return 3
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
}

case_dual_sentinel() {
  reset_case mut-dual || return 3
  mk_job mut-dual || return 3
  REPORT="$TMP/mut-dual-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-dual w:p1 "$REPORT"
  local sent_a=$SENTINEL_PID
  sentinel_mid_sleep "$sent_a" >/dev/null || return 3
  start_sentinel mut-dual w:p1 "$REPORT"
  local sent_b=$SENTINEL_PID
  sentinel_mid_sleep "$sent_b" >/dev/null || return 3
  done_run mut-dual --report "$REPORT" >/dev/null 2>&1
  wait_until 8 pid_gone "$sent_a" || return 1
  wait_until 4 pid_gone "$sent_b" || return 1
}

case_prune_live() {
  reset_case mut-plive || return 3
  mk_job mut-plive w:p2 || return 3
  REPORT="$TMP/mut-plive-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-plive w:p2 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  prune_run --apply >/dev/null 2>&1
  kill -0 "$SENTINEL_PID" 2>/dev/null || return 1
}

case_claim_revive() {
  reset_case mut-claimrev || return 3
  mk_job mut-claimrev w:p5 || return 3
  REPORT="$TMP/mut-claimrev-report.md"; printf 'x\n' >"$REPORT"
  # Sentinel must be mid-sleep BEFORE the records land — under the mutant the
  # job reads as ended, so a sentinel that wakes on the records self-exits
  # and the case reports a meaningless setup failure instead of RED.
  start_sentinel mut-claimrev w:p5 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  arb event --job mut-claimrev --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
  arb event --job mut-claimrev --kind job.claim \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null || return 3
  prune_run --apply >/dev/null 2>&1
  kill -0 "$SENTINEL_PID" 2>/dev/null || return 1
}

case_spawned_revive() {
  reset_case mut-spawnrev || return 3
  mk_job mut-spawnrev w:p6 || return 3
  REPORT="$TMP/mut-spawnrev-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-spawnrev w:p6 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  arb event --job mut-spawnrev --kind job.revoked \
    --payload-json '{"owner_lane":"lane-a","label":"lbl","outcome":"abandoned"}' >/dev/null 2>&1 || true
  arb event --job mut-spawnrev --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"lbl","pane_id":"w:p6"}' >/dev/null || return 3
  prune_run --apply >/dev/null 2>&1
  kill -0 "$SENTINEL_PID" 2>/dev/null || return 1
}

case_stopped_sentinel() {
  reset_case mut-stopd || return 3
  mk_job mut-stopd w:p1 || return 3
  REPORT="$TMP/mut-stopd-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-stopd w:p1 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  kill -STOP "$SENTINEL_PID" || return 3
  prune_run --apply >/dev/null 2>&1
  local alive=0
  kill -0 "$SENTINEL_PID" 2>/dev/null && alive=1
  kill -CONT "$SENTINEL_PID" 2>/dev/null || true
  (( alive == 1 )) || return 1
}

case_unverifiable() {
  reset_case mut-unver || return 3
  mk_job mut-unver w:p8 || return 3
  REPORT="$TMP/mut-unver-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-unver w:p8 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  local seq="$TMP/mut-unver.seq"; printf '%s\n' garbage >"$seq"
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    WRK_FIXTURE_GET_SEQUENCE="$seq" "$WRK" prune --apply >/dev/null 2>&1
  kill -0 "$SENTINEL_PID" 2>/dev/null || return 1
}

case_outside_root() {
  reset_case mut-outroot || return 3
  local inbox_b="$TMP/mut-outroot-b"; mkdir -p "$inbox_b"
  REPORT="$TMP/mut-outroot-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-outside w:p1 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  # Pane provably gone too — with the outside-root guard mutated away, only
  # this keeps the case honest: a live pane would protect it either way.
  local seq="$TMP/mut-outroot.seq"; printf '%s\n' not-found >"$seq"
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$inbox_b" XDG_DATA_HOME="$XDG" \
    WRK_FIXTURE_GET_SEQUENCE="$seq" "$WRK" prune --apply --job mut-outside >/dev/null 2>&1
  kill -0 "$SENTINEL_PID" 2>/dev/null || return 1
}

case_dryrun_stops() {
  reset_case mut-dry || return 3
  mk_job mut-dry w:p1 || return 3
  REPORT="$TMP/mut-dry-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-dry w:p1 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  arb event --job mut-dry --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
  prune_run >/dev/null 2>&1   # dry-run — must not signal
  kill -0 "$SENTINEL_PID" 2>/dev/null || return 1
}

case_timeout_wrapper() {
  reset_case mut-tw || return 3
  mk_job mut-tw || return 3
  REPORT="$TMP/mut-tw-report.md"; printf 'x\n' >"$REPORT"
  local stub="$TMP/mut-pw-42"
  cat >"$stub" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
exit 42
EOF
  chmod +x "$stub" || return 3
  local spath="$TMP/mut-tw-path"
  make_stub_path "$spath" timeout gtimeout || return 3
  cat >"$spath/timeout" <<'EOF'
#!/bin/sh
printf 'timeout %s\n' "$*" >> "$WRAPPER_LOG"
secs="$1"; shift
exec "$@"
EOF
  chmod +x "$spath/timeout" || return 3
  local log="$TMP/mut-tw-wrapper.log"; : >"$log"
  env PATH="$spath" WRAPPER_LOG="$log" \
    HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$stub" \
    "$WRK" 'done' mut-tw --report "$REPORT" >/dev/null 2>&1 || true
  grep -q 'job done' "$log" || return 1
}

case_gtimeout_wrapper() {
  reset_case mut-gtw || return 3
  mk_job mut-gtw || return 3
  REPORT="$TMP/mut-gtw-report.md"; printf 'x\n' >"$REPORT"
  local stub="$TMP/mut-pw-42b"
  cat >"$stub" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
exit 42
EOF
  chmod +x "$stub" || return 3
  local spath="$TMP/mut-gtw-path"
  make_stub_path "$spath" timeout gtimeout || return 3
  cat >"$spath/gtimeout" <<'EOF'
#!/bin/sh
printf 'gtimeout %s\n' "$*" >> "$WRAPPER_LOG"
secs="$1"; shift
exec "$@"
EOF
  chmod +x "$spath/gtimeout" || return 3
  local log="$TMP/mut-gtw-wrapper.log"; : >"$log"
  env PATH="$spath" WRAPPER_LOG="$log" \
    HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$stub" \
    "$WRK" 'done' mut-gtw --report "$REPORT" >/dev/null 2>&1 || true
  grep -q 'job done' "$log" || return 1
}

case_fallback_group() {
  reset_case mut-fbhang || return 3
  mk_job mut-fbhang || return 3
  REPORT="$TMP/mut-fbhang-report.md"; printf 'x\n' >"$REPORT"
  local stub="$TMP/mut-pw-fbhang-stub"
  cat >"$stub" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
sleep 12 &
echo $! > "$GRANDCHILD_LOG"
wait
EOF
  chmod +x "$stub" || return 3
  local spath="$TMP/mut-fbhang-path"
  make_stub_path "$spath" timeout gtimeout || return 3
  local start_ts elapsed out
  start_ts=$(date +%s)
  out="$(run_deadline 20 env PATH="$spath" \
    GRANDCHILD_LOG="$TMP/mut-fbhang-gc.pid" \
    HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" \
    PANEWIRE_BIN="$stub" WRK_JOB_DELEGATE_TIMEOUT_S=2 \
    "$WRK" 'done' mut-fbhang --report "$REPORT" 2>&1)" || true
  elapsed=$(( $(date +%s) - start_ts ))
  (( elapsed < 7 )) || return 1
  printf '%s\n' "$out" | grep -q 'rc=124' || return 1
  event_count_is "$INBOX/mut-fbhang/events" job.completed 1 || return 1
}

case_delegate_hang() {
  reset_case mut-hang || return 3
  mk_job mut-hang || return 3
  REPORT="$TMP/mut-hang-report.md"; printf 'x\n' >"$REPORT"
  local stub="$TMP/mut-pw-hang-stub"
  cat >"$stub" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
sleep 60 &
wait
EOF
  chmod +x "$stub" || return 3
  local start_ts elapsed
  start_ts=$(date +%s)
  # The test's own watchdog bounds the suite even when the mutant removes the
  # delegate bound entirely (D05) — the hang cannot exceed ~15s.
  run_deadline 15 env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$stub" \
    WRK_JOB_DELEGATE_TIMEOUT_S=2 \
    "$WRK" 'done' mut-hang --report "$REPORT" >/dev/null 2>&1 || true
  elapsed=$(( $(date +%s) - start_ts ))
  (( elapsed < 7 )) || return 1
  event_count_is "$INBOX/mut-hang/events" job.completed 1 || return 1
}

case_delegate_fallback() {
  reset_case mut-delegate || return 3
  mk_job mut-delegate || return 3
  REPORT="$TMP/mut-delegate-report.md"; printf 'x\n' >"$REPORT"
  local stub="$TMP/mut-pw-stub"
  cat >"$stub" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
exit 42
EOF
  chmod +x "$stub" || return 3
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$stub" \
    "$WRK" 'done' mut-delegate --report "$REPORT" >/dev/null 2>&1 || true
  event_count_is "$INBOX/mut-delegate/events" job.completed 1 || return 1
}

case_refresh_fields() {
  reset_case mut-rfields || return 3
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE=new PANEWIRE_BIN="$PANEWIRE" \
    WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$HERDR_LOG" \
    WRK_SCOPEFUEL_LOG="$TMP/mut-rfields-scopefuel.log" \
    WRK_REFRESH_LOG="$TMP/mut-rfields-refresh.log" \
    WRK_REFRESH_MODE=hang WRK_REFRESH_DELAY=90 WRK_REFRESH_TIMEOUT_S=8 \
    "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l mut-rfields --t T1 \
    --task 1 --job mut-rfields >/dev/null 2>&1 &
  local spawn_pid=$!
  local pf="$INBOX/mut-rfields/quota-refresh.pid"
  wait_until 15 test -f "$pf" || { kill "$spawn_pid" 2>/dev/null; return 3; }
  local sup; sup="$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$pf")"; own "$sup"
  local ok=0
  python3 - "$pf" <<'PY' || ok=1
import sys
fields = {}
for tok in open(sys.argv[1]).read().split():
    if "=" in tok:
        k, _, v = tok.partition("=")
        fields[k] = v
for key in ("pid", "pool", "job", "timeout", "deadline", "started"):
    assert key in fields and fields[key] != "", "pidfile missing field %r: %r" % (key, fields)
assert fields["deadline"].isdigit() and fields["started"].isdigit(), fields
assert fields["job"] == "mut-rfields", fields
PY
  kill "$spawn_pid" 2>/dev/null || true
  (( ok == 0 )) || return 1
}

case_refresh_success() {
  reset_case mut-rsucc || return 3
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE=new PANEWIRE_BIN="$PANEWIRE" \
    WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$HERDR_LOG" \
    WRK_SCOPEFUEL_LOG="$TMP/mut-rsucc-scopefuel.log" \
    WRK_REFRESH_LOG="$TMP/mut-rsucc-refresh.log" \
    WRK_REFRESH_MODE=hang WRK_REFRESH_DELAY=1 WRK_REFRESH_TIMEOUT_S=10 \
    "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l mut-rsucc --t T1 \
    --task 1 --job mut-rsucc >/dev/null 2>&1 || return 3
  # The detached supervisor writes its pidfile after spawn returns; first prove
  # it was written, then prove the success path removes it (hang-mode child hits
  # the supervisor's timeout, so give the bound headroom).
  local pf="$INBOX/mut-rsucc/quota-refresh.pid"
  wait_until 10 test -e "$pf" || return 3
  wait_until 25 test '!' -e "$pf" || return 1
}

case_refresh_tree() {
  reset_case mut-rtree || return 3
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE=new PANEWIRE_BIN="$PANEWIRE" \
    WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$HERDR_LOG" \
    WRK_SCOPEFUEL_LOG="$TMP/mut-rtree-scopefuel.log" \
    WRK_REFRESH_LOG="$TMP/mut-rtree-refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/mut-rtree.pids" \
    WRK_REFRESH_MODE=hang-tree WRK_REFRESH_DELAY=90 WRK_REFRESH_TIMEOUT_S=6 \
    "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l mut-rtree --t T1 \
    --task 1 --job mut-rtree >/dev/null 2>&1
  # The grandchild sleep must be gone shortly after the supervisor timeout —
  # under the Q03 mutant only TERM reaches it and it survives (RED). The pid
  # log lands only once the detached supervisor's fixture child has forked.
  wait_until 10 bash -c '[[ $(sed -n "2p" "$1" 2>/dev/null) =~ ^[0-9]+$ ]]' \
    _ "$TMP/mut-rtree.pids" || return 3
  local gchild; gchild="$(sed -n '2p' "$TMP/mut-rtree.pids")"
  own "$gchild"
  pid_gone "$gchild" || return 1
}

case_refresh_leftover() {
  reset_case mut-rleft || return 3
  mk_job mut-rleft || return 3
  local pf="$INBOX/mut-rleft/quota-refresh.pid"
  start_fake_supervisor mut-rleft -7200
  wait_until 10 test -s "$pf" || return 3
  local sup; sup="$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$pf")"
  own "$sup"
  arb event --job mut-rleft --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
  local out; out="$(prune_run --apply 2>&1)" || true
  grep -q "mut-rleft.*leftover=yes" <<<"$out" || return 1   # Q04: must list it
  wait_until 5 pid_gone "$sup" || return 1                # Q05: must stop it
}

case_refresh_unverified() {
  reset_case mut-runv || return 3
  mk_job mut-runv || return 3
  spawn_python_sleeper
  local sup=$SLEEPER_PID now; now=$(date +%s)
  printf 'pid=%d pool=p job=mut-runv timeout=1 deadline=%d started=%d\n' \
    "$sup" "$(( now - 120 ))" "$now" >"$INBOX/mut-runv/quota-refresh.pid"
  prune_run --apply >/dev/null 2>&1
  kill -0 "$sup" 2>/dev/null || return 1
}

case_refresh_stale_start() {
  reset_case mut-rstale || return 3
  mk_job mut-rstale || return 3
  local pf="$INBOX/mut-rstale/quota-refresh.pid"
  mkdir -p "$INBOX/mut-rstale"
  python3 - "$SCOPEFUEL" fakepool 60 "$pf" mut-rstale <<'PY' >/dev/null 2>&1 &
import sys, time
time.sleep(600)
PY
  local sup=$!; own "$sup"
  local now; now=$(date +%s)
  printf 'pid=%d pool=fakepool job=mut-rstale timeout=60 deadline=%d started=%d\n' \
    "$sup" "$(( now - 120 ))" "$(( now - 7200 ))" >"$pf"
  prune_run --apply >/dev/null 2>&1
  kill -0 "$sup" 2>/dev/null || return 1
}

case_unrelated_pidfile() {
  reset_case mut-unrel || return 3
  mk_job mut-unrel || return 3
  REPORT="$TMP/mut-unrel-report.md"; printf 'x\n' >"$REPORT"
  spawn_sleeper
  local victim=$SLEEPER_PID
  printf '%s\n' "$victim" >"$INBOX/mut-unrel/completion-sentinel.pid"
  done_run mut-unrel --report "$REPORT" >/dev/null 2>&1
  kill -0 "$victim" 2>/dev/null || return 1
  [[ ! -e "$INBOX/mut-unrel/completion-sentinel.pid" ]] || return 1
}

case_reused_pidfile() {
  reset_case mut-reused || return 3
  mk_job mut-reused || return 3
  arb event --job mut-reused --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
  spawn_sleeper
  local victim=$SLEEPER_PID
  printf '%s\n' "$victim" >"$INBOX/mut-reused/completion-sentinel.pid"
  # Under the I02 mutant pass-1 trusts kill -0 alone: the sleeper classifies as
  # a live sentinel instead of pid-reused even though the downstream stop is
  # still identity-guarded. The classification line is where RED shows.
  local out; out="$(prune_run --apply 2>&1)" || true
  kill -0 "$victim" 2>/dev/null || return 1
  grep -q "mut-reused.*pid-reused" <<<"$out" || return 1
}

case_fake_argv() {
  reset_case mut-fakeargv || return 3
  mk_job mut-fakeargv || return 3
  python3 -c 'import time; time.sleep(600)' /fake/wrk sentinel mut-fakeargv owner lbl w:p1 &
  local victim=$!; own "$victim"
  arb event --job mut-fakeargv --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null 2>&1 || true
  printf '%s\n' "$victim" >"$INBOX/mut-fakeargv/completion-sentinel.pid"
  prune_run --apply >/dev/null 2>&1
  kill -0 "$victim" 2>/dev/null || return 1
}

case_stale_started() {
  reset_case mut-stalestart || return 3
  mk_job mut-stalestart w:p4 || return 3
  REPORT="$TMP/mut-stalestart-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-stalestart w:p4 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  local pid="$SENTINEL_PID"
  printf '%s\nstarted=%s\n' "$pid" "$(( $(date +%s) - 40000 ))" \
    >"$INBOX/mut-stalestart/completion-sentinel.pid"
  local out; out="$(prune_run --apply 2>&1)" || true
  grep -q "mut-stalestart.*pid-start-mismatch" <<<"$out" || return 1
  [[ ! -e "$INBOX/mut-stalestart/completion-sentinel.pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
}

# shellcheck disable=SC2329 # invoked indirectly via wait_until
mut_spn_up() { [[ "$(sentinel_count mut-spawnreuse)" -eq 1 ]]; }
case_spawn_reused_pidfile() {
  reset_case mut-spawnreuse || return 3
  spawn_sleeper
  local victim=$SLEEPER_PID
  mkdir -p "$INBOX/mut-spawnreuse"
  printf '%s\n' "$victim" >"$INBOX/mut-spawnreuse/completion-sentinel.pid"
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE=new PANEWIRE_BIN="$PANEWIRE" \
    WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$HERDR_LOG" \
    WRK_SCOPEFUEL_LOG="$TMP/mut-spawnreuse-scopefuel.log" \
    WRK_REFRESH_LOG="$TMP/mut-spawnreuse-refresh.log" \
    "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l mut-spawnreuse --t T1 \
    --task 1 --job mut-spawnreuse >/dev/null 2>&1 || return 3
  # The sentinel's argv reaches its final `wrk sentinel JOB` shape only after
  # the nohup/env exec chain settles; sample once under load and a real spawn
  # can read 0. Poll — a suppressing mutant stays 0 for the whole window.
  wait_until 10 mut_spn_up || return 1
  kill -0 "$victim" 2>/dev/null || return 1
}

case_second_start() {
  reset_case mut-2nd || return 3
  REPORT="$TMP/mut-2nd-report.md"; printf 'x\n' >"$REPORT"
  local lib="$TMP/mut-2nd-lib.sh"
  awk 'index($0, "case \"${1:-}\" in") == 1 {exit} {print}' "$WRK" >"$lib"
  [[ -s "$lib" ]] || return 3
  mkdir -p "$INBOX/mut-2nd"
  local pf="$INBOX/mut-2nd/completion-sentinel.pid"
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" \
    WRK_FIXTURE_SCENARIO=sentinel-working \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_LIBFILE="$lib" \
    bash -c '. "$WRK_LIBFILE"; start_completion_sentinel "$@"' "$WRK" \
    "$pf" mut-2nd lane-a lbl w:p1 "$REPORT" || return 3
  sleep 0.5
  local first_pid; first_pid="$(head -n 1 "$pf")"; own "$first_pid"
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" \
    WRK_FIXTURE_SCENARIO=sentinel-working \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_LIBFILE="$lib" \
    bash -c '. "$WRK_LIBFILE"; start_completion_sentinel "$@"' "$WRK" \
    "$pf" mut-2nd lane-a lbl w:p1 "$REPORT" || return 3
  sleep 0.5
  # Settle past the second sentinel's nohup/env exec window before counting —
  # under the I06 mutant it exists, and a transient 1 would read as fixed.
  sleep 0.5
  [[ "$(sentinel_count mut-2nd)" -eq 1 ]] || return 1
  [[ "$(head -n 1 "$pf")" == "$first_pid" ]] || return 1
}

# ── the sweep ──────────────────────────────────────────────────────────

# J01: local done housekeeping
# shellcheck disable=SC2016
mkmut j01-no-done-housekeeping 's~^  job_end_housekeeping "$job" "$owner" completed "wrk done" "wrk done"$~  : removed local done housekeeping~'
expect_mut_red "J01 local-done-housekeeping" case_done

# J02: delegated done housekeeping
# shellcheck disable=SC2016
mkmut j02-no-delegated-housekeeping 's~^      job_end_housekeeping "$d_job" "$d_owner" "$sub" "panewire job $sub" "wrk $sub (delegated)"$~      : removed delegated housekeeping~'
expect_mut_red "J02 delegated-done-housekeeping" case_delegate_done

# J03: duplicate done housekeeping
# shellcheck disable=SC2016
mkmut j03-no-dup-housekeeping 's~^    job_end_housekeeping "$job" "$owner" completed "wrk done (duplicate report)" "wrk done"$~    : removed duplicate done housekeeping~'
expect_mut_red "J03 duplicate-done-housekeeping" case_dup_done

# J04: local joined housekeeping
# shellcheck disable=SC2016
mkmut j04-no-joined-housekeeping 's~^  job_end_housekeeping "$job" "$owner" joined "wrk joined" "wrk joined"$~  : removed local joined housekeeping~'
expect_mut_red "J04 local-joined-housekeeping" case_joined

# J05: delegated joined gate narrows to done only
# shellcheck disable=SC2016
mkmut j05-delegated-join-skip 's~"done" || "\$sub" == "joined"~"done"~'
expect_mut_red "J05 delegated-joined-gate" case_delegate_joined

# J06: duplicate/partial joined housekeeping
# shellcheck disable=SC2016
mkmut j06-no-pjoined-housekeeping 's~^    job_end_housekeeping "$job" "$owner" joined "wrk joined (duplicate)" "wrk joined"$~    : removed duplicate joined housekeeping~'
expect_mut_red "J06 partial-joined-housekeeping" case_partial_joined

# J07: reap housekeeping
# shellcheck disable=SC2016
mkmut j07-no-reap-housekeeping 's~^        job_end_housekeeping "$job" "$owner" abandoned "pane reaped" "wrk reap"$~        : removed reap housekeeping~'
expect_mut_red "J07 reap-housekeeping" case_reap

# J08: prune's ended-orphan stop
# shellcheck disable=SC2016
mkmut j08-no-ended-stop 's~^      stop_completion_sentinel "$job" "$pid" && echo "  action=stopped"$~      : removed ended-orphan stop~'
expect_mut_red "J08 prune-ended-orphan-stop" case_prune_apply

# J09: prune's pane-gone stop
# shellcheck disable=SC2016
mkmut j09-no-panegone-stop 's~stop_completion_sentinel "$job" "$pid" && echo "  action=stopped+ended"~: removed pane-gone stop~'
expect_mut_red "J09 prune-pane-gone-stop" case_pane_gone

# J10: sentinel completed self-exit
# shellcheck disable=SC2016
mkmut j10-no-completed-exit 's~^        sentinel_self_exit "$job" 0$~        : removed completed self-exit~'
expect_mut_red "J10 sentinel-completed-exit" case_sentinel_complete

# J11: sentinel lost-grace self-exit
# shellcheck disable=SC2016
mkmut j11-no-lostgrace-exit 's~^      sentinel_self_exit "$job" 0$~      : removed lost-grace self-exit~'
expect_mut_red "J11 sentinel-lostgrace-exit" case_lost_grace

# J12: sentinel record watch
# shellcheck disable=SC2016
mkmut j12-no-watch 's~^    if sentinel_job_ended "$jobdir"; then$~    if false; then~'
expect_mut_red "J12 sentinel-record-watch" case_watch

# J13: the interval-sleep child kill
# shellcheck disable=SC2016
mkmut j13-no-child-kill 's~^        kill "$child" 2>/dev/null || true$~        : left interval child alive~'
expect_mut_red "J13 interval-child-kill" case_done

# J14: the process sweep in stop_completion_sentinel
mkmut j14-no-sweep 's~done < <(sentinel_sweep)~done < <(true)~'
expect_mut_red "J14 sentinel-sweep" case_dual_sentinel

# J15: pidfile removal at end
# shellcheck disable=SC2016
mkmut j15-no-pidfile-rm 's~^  rm -f "$pidfile" 2>/dev/null || true$~  : left ended-job pidfile~'
expect_mut_red "J15 ended-pidfile-removal" case_done

# P01: ended-check forced true (live job treated as orphan)
# shellcheck disable=SC2016
mkmut p01-live-as-orphan 's~^  if \[\[ "$ended" == 1 \]\]; then$~  if true; then~'
expect_mut_red "P01 live-job-protection" case_prune_live

# P02: job.claim no longer revives
mkmut p02-no-claim-revive 's~"job.claim", ~~'
expect_mut_red "P02 claim-revive" case_claim_revive

# P03: job.spawned no longer revives
mkmut p03-no-spawned-revive 's~"job.spawned", ~~'
expect_mut_red "P03 spawned-revive" case_spawned_revive

# P04: same ended-check mutant must die under a STOPped-sentinel case too
# shellcheck disable=SC2016
mkmut p04-live-as-orphan 's~^  if \[\[ "$ended" == 1 \]\]; then$~  if true; then~'
expect_mut_red "P04 stopped-sentinel-protection" case_stopped_sentinel

# P05: pane-unverifiable downgraded to a stop
mkmut_span p05-unverifiable-stops 'reason=pane-unverifiable($ptoken)' \
  '      stop_completion_sentinel "$job" "$pid" ;;'
expect_mut_red "P05 unverifiable-protection" case_unverifiable

# P06: outside-root guard removed — the contract pins line 6706 to `if true`
# on the ended-check; the semantically faithful outside-root mutation is the
# `! -d $PRUNE_ROOT/$job` guard going `if false`.
mkmut p06-outside-root 's~^  if \[\[ ! -d "$PRUNE_ROOT/\$job" \]\]; then$~  if false; then~'
expect_mut_red "P06 outside-root-protection" case_outside_root

# P07: apply-gate forced true (dry-run signals)
# shellcheck disable=SC2016
mkmut p07-dryrun-signals 's~^    if \[\[ "$PRUNE_APPLY" -eq 1 \]\]; then$~    if true; then~'
expect_mut_red "P07 dry-run-never-signals" case_dryrun_stops

# D01: `timeout` skipped even when present
mkmut d01-no-timeout 's~^  if command -v timeout >/dev/null 2>&1; then$~  if false; then~'
expect_mut_red "D01 timeout-selection" case_timeout_wrapper

# D02: `gtimeout` skipped even when present
mkmut d02-no-gtimeout 's~^  if command -v gtimeout >/dev/null 2>&1; then$~  if false; then~'
expect_mut_red "D02 gtimeout-selection" case_gtimeout_wrapper

# D03: `timeout` forced present → missing-command 127 instead of the fallback
mkmut d03-fake-timeout 's~^  if command -v timeout >/dev/null 2>&1; then$~  if true; then~'
expect_mut_red "D03 fallback-requires-both-absent" case_fallback_group

# D04: the fallback's process-group kill removed (first killpg = run_bounded's)
KILLPG_1="$(nth_lineno 'os.killpg(proc.pid, signal.SIGKILL)' 1)"
[[ -n "$KILLPG_1" ]] || fail "D04: could not locate run_bounded's killpg"
mkmut d04-no-group-kill "${KILLPG_1}s~os.killpg(proc.pid, signal.SIGKILL)~pass~"
expect_mut_red "D04 fallback-group-kill" case_fallback_group

# D05: the delegated call's bound removed outright — the test's own watchdog
# is what keeps the suite finite here.
mkmut d05-no-delegate-bound 's~run_bounded "$run_timeout" ~ ~'
expect_mut_red "D05 delegate-bound" case_delegate_hang

# D06: delegation rc propagates — the local write is skipped
# shellcheck disable=SC2016
mkmut d06-rc-propagates 's~^    warn "panewire job \$sub delegation failed or timed out (rc=\$rc); using wrk.s own path"$~    warn "delegation failed"; return "$rc"~'
expect_mut_red "D06 delegation-fallback" case_delegate_fallback

# D07: wedged emit is not skipped
# shellcheck disable=SC2016
mkmut d07-emit-reenters 's~\${PANEWIRE_WEDGED:-}" == 1~\${PANEWIRE_WEDGED:-}" == 0~'
expect_mut_red "D07 emit-wedge-skip" case_delegate_hang

# Q01: the `started` field disappears from the pidfile
mkmut q01-no-started-field 's~started=%d~start=%d~'
expect_mut_red "Q01 refresh-pidfile-fields" case_refresh_fields

# Q02: drop_pidfile never unlinks
mkmut_span q02-no-unlink 'os.unlink(pidfile)' '            pass'
expect_mut_red "Q02 refresh-pidfile-removal" case_refresh_success

# Q03: the supervisor's follow-up group SIGKILL is dropped (third killpg)
KILLPG_3="$(nth_lineno 'os.killpg(proc.pid, signal.SIGKILL)' 3)"
[[ -n "$KILLPG_3" ]] || fail "Q03: could not locate the supervisor's killpg"
mkmut q03-no-sigkill "${KILLPG_3}s~os.killpg(proc.pid, signal.SIGKILL)~pass~"
expect_mut_red "Q03 refresh-tree-kill" case_refresh_tree

# Q04: a verified leftover is never classified
mkmut q04-no-leftover 's~^    if \[\[ "$_rended" == 1 \]\] || (( \$(date +%s) > _rdeadline + 60 )); then$~    if false; then~'
expect_mut_red "Q04 leftover-classification" case_refresh_leftover

# Q05: the verified supervisor group is never signalled
mkmut q05-no-group-stop 's~^        kill -- "-\$_rpid" 2>/dev/null || kill "\$_rpid" 2>/dev/null || true$~        : left verified supervisor group alive~'
expect_mut_red "Q05 leftover-group-stop" case_refresh_leftover

# Q06: strong supervisor argv check removed
mkmut q06-no-argv-check 's~^       ! refresh_supervisor_argv_matches "\$_rpid" "\$_rpf"; then$~       false; then~'
expect_mut_red "Q06 supervisor-argv-identity" case_refresh_unverified

# Q07: the start-time agreement check removed
mkmut q07-no-start-check 's~^       (( ( \$(date +%s) - _rstarted - _elapsed ) > 120 || ( \$(date +%s) - _rstarted - _elapsed ) < -120 )) ||$~       false ||~'
expect_mut_red "Q07 supervisor-start-check" case_refresh_stale_start

# I01: the stop path's identity check forced true
# shellcheck disable=SC2016
mkmut i01-stop-trusts-pidfile 's~sentinel_pid_matches "$pid" "$job" && sentinel_start_matches "$pid" "$_st"~true~'
expect_mut_red "I01 stop-path-identity" case_unrelated_pidfile

# I02: prune pass-1 identity reduced to bare liveness
# shellcheck disable=SC2016
mkmut i02-prune-kill0 's~sentinel_pid_matches "$pid" "$job" && sentinel_start_matches "$pid" "$started"~kill -0 "$pid" 2>/dev/null~'
expect_mut_red "I02 prune-pass1-identity" case_reused_pidfile

# I03: exact argv requirement dropped from the identity check — incidental
# `/fake/wrk sentinel JOB` text inside a foreign argv becomes identity.
# Replaces BOTH lines of the positional/arity condition with the loose rule.
mkmut_span i03-loose-argv '$(i + 2) == job &&' \
  '        if ($i == "sentinel" && $(i + 1) == job) { found = 1; break }' 1
expect_mut_red "I03 exact-argv-identity" case_fake_argv

# I04: the start-time agreement check dropped everywhere it authorizes
mkmut i04-no-start-check 's~ && sentinel_start_matches "[^"]*" "[^"]*"~~g'
expect_mut_red "I04 recorded-start-check" case_stale_started

# I05: the reused-pid liveness check suppresses every new start
mkmut_span i05-start-suppressed \
  'sentinel_start_matches "$existing" "$existing_started"; then' '    if true; then'
expect_mut_red "I05 reused-pidfile-suppression" case_spawn_reused_pidfile

# I06: the suppression check disabled — every call starts a new sentinel
mkmut_span i06-start-dup \
  'sentinel_start_matches "$existing" "$existing_started"; then' '    if false; then'
expect_mut_red "I06 duplicate-start-suppression" case_second_start

# I07: the stale pidfile is left behind
# shellcheck disable=SC2016
mkmut i07-pidfile-left 's~^  rm -f "$pidfile" 2>/dev/null || true$~  : left stale pidfile~'
expect_mut_red "I07 ended-pidfile-removal" case_unrelated_pidfile

# H01's combined mutant: BOTH prune stop sites removed at once — the
# mid-sleep proof is what keeps this RED (a waking sentinel self-exits on
# the record watch and masks the mutation).
# shellcheck disable=SC2016
mkmut h01-no-prune-stop 's~stop_completion_sentinel "$job" "$pid"~: removed prune stop~g'
expect_mut_red "H01 combined no-prune-stop" case_prune_apply

echo "PASS test-wrk-job-end: all cases"
