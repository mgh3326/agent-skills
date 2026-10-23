#!/usr/bin/env bash
# tests/test-wrk-heavy-fifo.sh — hk 1407 lane FIFO tickets and a durable
# place across a wait-cap exit.
#
# Lane waiters take a free slot in ticket order. A live older ticket reserves
# the slots that waiter could take (index below its own limit), the same
# shape as the hk 1533 ci reservation. ci waiters stay ahead of every lane
# waiter, and the ci starvation guard is unchanged. A keyed waiter that exits
# on the wait cap keeps its original ticket for WRK_HEAVY_REQUEUE_GRACE
# seconds. A dead pid reserves nothing. A ticketless lane record is
# skipped by the lane FIFO rule. A ticketless ci record still reserves:
# hk 1533 does not read tickets.
#
# Stub commands only. HOME, every XDG dir, CODEX_HOME and ARBITER_INBOX_ROOT
# point into a temp dir. Every lock, waiters dir, positions dir, load file
# and log is a temp path. Only pids this script started are signalled.
# Assertion-RED mutants over a copy of bin/wrk close the file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="${WRK_UNDER_TEST:-$ROOT/bin/wrk}"

if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
  py311="$(command -v python3.11 || true)"
  [[ -n "$py311" ]] || { echo "FAIL: python3 >= 3.11 required" >&2; exit 1; }
  PYBIN="$(mktemp -d /tmp/pyXXXXXX)"
  ln -s "$py311" "$PYBIN/python3"
  export PATH="$PYBIN:$PATH"
else
  PYBIN=""
fi

# Short TMPDIR: the macOS default is a long /var/folders path. The suite
# keeps TMPDIR under 40 characters and never uses the host heavy lock.
SHORT="$(mktemp -d /tmp/hf.XXXXXX)"
export TMPDIR="$SHORT"
TMP="$(mktemp -d "$TMPDIR/t.XXXXXX")"
PIDS=()
CLEANUP_KEEP_TMP=0
MAIN_BASHPID=$BASHPID

fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
  # Bash can run an EXIT trap in a subshell. Only the main shell may
  # kill the jobs it started and remove the temp tree.
  [[ "${BASHPID:-}" == "$MAIN_BASHPID" ]] || return 0
  local f pid
  for f in "$TMP"/*.sh; do
    [[ -e "$f" ]] && : >"${f%.sh}.rel"
  done
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  if [[ "$CLEANUP_KEEP_TMP" -eq 1 ]]; then
    return 0
  fi
  rm -rf "$SHORT" 2>/dev/null || { sleep 1; rm -rf "$SHORT" 2>/dev/null || true; }
  if [[ -n "$PYBIN" ]]; then
    rm -rf "$PYBIN"
  fi
}
trap cleanup EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state" \
  XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache" \
  XDG_RUNTIME_DIR="$HOME/run" CODEX_HOME="$TMP/codex" \
  ARBITER_INBOX_ROOT="$TMP/inbox"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" \
  "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$CODEX_HOME" "$ARBITER_INBOX_ROOT"
unset ARBITER_JOB HK_TASK_ID WRK_HEAVY_HELD WRK_HEAVY_HELD_FD WRK_HEAVY_CLASS \
  WRK_HEAVY_MAX WRK_HEAVY_CI_DEFER_MAX WRK_HEAVY_LOCK WRK_HEAVY_QUEUE_KEY \
  WRK_HEAVY_REQUEUE_GRACE WRK_TEST_FOREIGN_NAME WRK_TEST_PASS_GATE \
  WRK_TEST_PASS_MARK
export WRK_HOSTS_CONFIG="$TMP/hosts.toml"
export WRK_HEAVY_LOAD_FILE="$TMP/load"
export WRK_HEAVY_LOG="$TMP/heavy.log"
export WRK_HEAVY_WAIT_CAP=30
printf '0\n' >"$WRK_HEAVY_LOAD_FILE"
: >"$WRK_HEAVY_LOG"
HEAVY_BIN=""

wait_until() {
  local limit="$1"; shift
  local deadline=$(( $(date +%s) + limit ))
  while (( $(date +%s) <= deadline )); do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  return 1
}

settle_waiters() {
  # One poll is 0.5s. A record older than that has been visible to a pass
  # that starts now, so a release is not racing a scan that missed it.
  wait_until 10 python3 - "$WRK_HEAVY_LOCK.waiters" <<'PY'
import os, sys, time
d = sys.argv[1]
files = [os.path.join(d, n) for n in os.listdir(d) if not n.startswith(".")]
sys.exit(0 if files and all(time.time() - os.path.getmtime(f) > 0.6 for f in files) else 1)
PY
}

now() { python3 -c 'import time; print("%.3f" % time.time())'; }
since() { python3 -c 'import sys, time; print("%.2f" % (time.time() - float(sys.argv[1])))' "$1"; }
fcmp() {
  python3 -c 'import operator, sys; sys.exit(0 if getattr(operator, sys.argv[2])(float(sys.argv[1]), float(sys.argv[3])) else 1)' "$@"
}
ticket_lt() { # ticket_lt <a> <b> — a is strictly older
  python3 -c 'import sys
def p(t):
    n, _, i = t.partition(":")
    return (int(n), int(i))
sys.exit(0 if p(sys.argv[1]) < p(sys.argv[2]) else 1)' "$1" "$2"
}

new_lock() {
  export WRK_HEAVY_LOCK="$TMP/$1.lock"
  rm -rf "$WRK_HEAVY_LOCK.positions"
  # Mutant re-runs reuse this temp dir. A start file left by the real case
  # would make "started" true before the new holder has the slot.
  # Remove those markers before creating the waiters dir, so a glob
  # cannot land on the directory this function just created.
  rm -f "$TMP"/*.start "$TMP"/*.rel "$TMP"/*.done "$TMP"/*.out
  mkdir -p "$WRK_HEAVY_LOCK.waiters"
  : >"$TMP/order"
}

mkhold() {
  cat >"$TMP/$1.sh" <<EOF
trap 'echo $1 >>"$TMP/signals"' TERM INT HUP QUIT USR1 USR2
echo $1 >>"$TMP/order"
: >"$TMP/$1.start"
n=0
while [ ! -e "$TMP/$1.rel" ] && [ \$n -lt 400 ]; do sleep 0.2; n=\$((n + 1)); done
: >"$TMP/$1.done"
EOF
}

release() { local n; for n in "$@"; do : >"$TMP/$n.rel"; done; }

bg_heavy() {
  local name="$1"; shift
  env "$@" "$(wrk_bin)" heavy -- bash "$TMP/$name.sh" \
    >"$TMP/$name.out" 2>&1 &
  BG=$!
  PIDS+=("$BG")
}

bg_key() {
  local name="$1" key="$2"; shift 2
  env "$@" "$(wrk_bin)" heavy --queue-key "$key" -- \
    bash "$TMP/$name.sh" >"$TMP/$name.out" 2>&1 &
  BG=$!
  PIDS+=("$BG")
}

wrk_bin() { if [[ -n "$HEAVY_BIN" ]]; then printf '%s' "$HEAVY_BIN"; else printf '%s' "$WRK"; fi; }

status_out() { "$(wrk_bin)" heavy status; }
started() { [[ -e "$TMP/$1.start" ]]; }
queued() {
  status_out | grep -Eq "^waiter pid=[0-9]+ class=$2 limit=$3 .*cmd=bash $TMP/$1\\.sh\$"
}

kill_own() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

record_ticket_of() { # record_ticket_of <script-name>
  python3 - "$WRK_HEAVY_LOCK.waiters" "$TMP/$1.sh" <<'PY'
import os, sys
d, cmd = sys.argv[1:]
want = "cmd=bash " + cmd
for name in os.listdir(d):
    if name.startswith("."):
        continue
    path = os.path.join(d, name)
    if not os.path.isfile(path):
        continue
    text = open(path, encoding="utf-8").read()
    if want not in text:
        continue
    for tok in text.split()[:6]:
        if tok.startswith("ticket="):
            print(tok.split("=", 1)[1])
            raise SystemExit(0)
    raise SystemExit(2)
raise SystemExit(3)
PY
}

position_ticket() { # position_ticket <key>
  python3 - "$WRK_HEAVY_LOCK.positions/$1" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read().split()
fields = dict(tok.split("=", 1) for tok in text[:3])
print(fields["ticket"])
print(fields["expiry"])
PY
}

# ── help names the promise, the cap advice, and the trust limit ────────────
help_out="$("$WRK" heavy --help)"
for token in --queue-key WRK_HEAVY_QUEUE_KEY WRK_HEAVY_REQUEUE_GRACE 600 \
  Unity 'same-uid' 'does not bound' monotonic 'free-for-all' \
  'renamed into place' 'starting up' 'already read the records' \
  'class=ci|lane' 'WRK_HEAVY_CI_DEFER_MAX' 'lane FIFO rule' \
  'with or without a ticket'; do
  grep -qF -- "$token" <<<"$help_out" || fail "heavy --help must mention: $token"
done
echo "PASS heavy-fifo-help-promises"

# ── key grammar, including a non-ASCII letter under en_US.UTF-8 ────────────
new_lock keys
bad_locale_key="$(python3 -c 'print("caf\u00e9")')"
hangul_key="$(python3 -c 'print("\uac00")')"
long_key="$(python3 -c 'print("a"*65)')"
ok_key="$(python3 -c 'print("a"*64)')"
for lc in C en_US.UTF-8; do
  for bad in "$bad_locale_key" "$hangul_key" 'has space' 'a/b' '.' '..' \
    "$long_key" ''; do
    rm -f "$TMP/keys-ran"
    rc=0
    out="$(LC_ALL="$lc" "$WRK" heavy --queue-key "$bad" -- touch "$TMP/keys-ran" 2>&1)" || rc=$?
    [[ "$rc" -eq 78 ]] || fail "key $(printf '%q' "$bad") under $lc must refuse rc 78, got $rc: $out"
    [[ ! -e "$TMP/keys-ran" ]] || fail "command ran for a refused key"
    [[ ! -e "$WRK_HEAVY_LOCK" ]] || fail "a refused key minted a slot file"
  done
done
rc=0
WRK_HEAVY_QUEUE_KEY='' "$WRK" heavy -- true >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 78 ]] || fail "an empty WRK_HEAVY_QUEUE_KEY must refuse rc 78, got $rc"
rc=0
"$WRK" heavy --queue-key >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "--queue-key without a KEY must be rc 2, got $rc"
rc=0
WRK_HEAVY_REQUEUE_GRACE=abc "$WRK" heavy -- true >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "a bad grace must be rc 2, got $rc"
rc=0
WRK_HEAVY_REQUEUE_GRACE=-1 "$WRK" heavy -- true >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "a negative grace must be rc 2, got $rc"
"$WRK" heavy --queue-key "$ok_key" -- touch "$TMP/keys-ok" || fail "a 64-char key must run"
[[ -e "$TMP/keys-ok" ]] || fail "64-char key command did not run"
"$WRK" heavy --queue-key 'job-1407.w1' -- touch "$TMP/keys-job" || fail "a job-id key must run"
echo "PASS heavy-fifo-key-grammar"

# ── flag overrides the env; an unkeyed run writes no positions dir ─────────
new_lock over
mkhold over-h
bg_heavy over-h
wait_until 10 started over-h || fail "override holder never started"
rc=0
WRK_HEAVY_QUEUE_KEY=fromenv WRK_HEAVY_WAIT_CAP=2 \
  "$WRK" heavy --queue-key fromflag -- touch "$TMP/over-ran" >"$TMP/over.out" 2>&1 || rc=$?
[[ "$rc" -eq 75 ]] || fail "override waiter must hit the cap, got rc=$rc: $(cat "$TMP/over.out")"
[[ -f "$WRK_HEAVY_LOCK.positions/fromflag" ]] || fail "flag did not own the position file"
[[ ! -e "$WRK_HEAVY_LOCK.positions/fromenv" ]] || fail "env key was written beside the flag"
release over-h
wait "$BG" || fail "override holder failed"
new_lock bare
rm -rf "$WRK_HEAVY_LOCK.positions"
"$WRK" heavy -- touch "$TMP/bare-ran" || fail "unkeyed run failed"
[[ ! -e "$WRK_HEAVY_LOCK.positions" ]] || fail "an unkeyed run created a positions dir"
echo "PASS heavy-fifo-flag-overrides-env"

# ── three lane waiters receive the slot in ticket order ────────────────────
new_lock fifo
mkhold fifo-h; mkhold fifo-a; mkhold fifo-b; mkhold fifo-c
bg_heavy fifo-h; ph=$BG
wait_until 10 started fifo-h || fail "fifo holder never started"
bg_heavy fifo-a
wait_until 10 queued fifo-a lane 1 || fail "fifo A never queued"
bg_heavy fifo-b
wait_until 10 queued fifo-b lane 1 || fail "fifo B never queued"
bg_heavy fifo-c
wait_until 10 queued fifo-c lane 1 || fail "fifo C never queued"
ta="$(record_ticket_of fifo-a)"
tb="$(record_ticket_of fifo-b)"
tc="$(record_ticket_of fifo-c)"
ticket_lt "$ta" "$tb" || fail "fifo tickets not strictly increasing: $ta $tb $tc"
ticket_lt "$tb" "$tc" || fail "fifo tickets not strictly increasing: $ta $tb $tc"
# every record has been visible for a full poll, so the next pass scans
# the whole set before it tries the slot
settle_waiters || fail "fifo: waiter records were not visible for a full poll"
release fifo-h
wait_until 10 started fifo-a || fail "fifo: oldest ticket did not take the slot: $(tr '\n' ' ' <"$TMP/order")"
started fifo-b && fail "fifo: B ran before A finished"
started fifo-c && fail "fifo: C ran before A finished"
release fifo-a
wait_until 10 started fifo-b || fail "fifo: second ticket did not take the slot"
started fifo-c && fail "fifo: C ran before B finished"
release fifo-b
wait_until 10 started fifo-c || fail "fifo: third ticket did not take the slot"
release fifo-c
wait "$ph" || fail "fifo holder failed"
echo "PASS heavy-fifo-three-lane-order"

# ── a live older ticket blocks a younger waiter on a free slot ─────────────
# Deterministic: the older record is a sleeper, not a wrk, so a free-for-all
# would let the younger take the slot. The fixed code must not.
older_ticket_blocks() {
  new_lock blk
  sleep 300 &
  local sleeper=$!
  PIDS+=("$sleeper")
  printf 'pid=%s class=lane limit=1 ticket=1:1 since=2020-01-01T00:00:00 job=- cmd=old-ticket\n' \
    "$sleeper" >"$WRK_HEAVY_LOCK.waiters/$sleeper"
  mkhold blk-y
  bg_heavy blk-y
  local young=$BG
  # The refusal is "did not take the free slot", not "eventually showed up
  # in status". A mutant that ignores older tickets acquires at once and
  # never sits in the queue, so the start check has to come first.
  local n=0
  while [[ "$n" -lt 8 ]]; do
    if started blk-y; then
      fail "younger lane took a slot an older live ticket could take"
    fi
    sleep 0.25
    n=$((n + 1))
  done
  queued blk-y lane 1 || fail "block: younger never queued"
  status_out | grep -q '^holder none' || fail "block: the slot was not free"
  rm -f "$WRK_HEAVY_LOCK.waiters/$sleeper"
  release blk-y
  wait_until 10 started blk-y || fail "block: younger never ran after the older ticket was removed"
  wait "$young" || fail "block: younger failed"
  kill_own "$sleeper"
}
older_ticket_blocks
echo "PASS heavy-fifo-older-ticket-blocks"

# ── a younger waiter may take a slot the older limit does not cover ────────
new_lock above
sleep 300 &
above_sleeper=$!
PIDS+=("$above_sleeper")
printf 'pid=%s class=lane limit=1 ticket=1:1 since=2020-01-01T00:00:00 job=- cmd=limit-one\n' \
  "$above_sleeper" >"$WRK_HEAVY_LOCK.waiters/$above_sleeper"
mkhold above-y
bg_heavy above-y WRK_HEAVY_MAX=2
wait_until 10 started above-y || fail "above: younger did not take the free slot above the older limit"
above_status="$(status_out)"
grep -Eq '^holder slot=1 ' <<<"$above_status" ||
  fail "above: younger did not hold slot 1: $above_status"
grep -Eq '^holder slot=0 ' <<<"$above_status" &&
  fail "above: slot 0 was taken; the older ticket could take it: $above_status"
release above-y
wait "$BG" || fail "above: younger failed"
kill_own "$above_sleeper"
echo "PASS heavy-fifo-slot-above-older-limit"

# ── ci still takes the next free slot ahead of an older lane ticket ────────
new_lock ci
mkhold ci-h; mkhold ci-l; mkhold ci-c
bg_heavy ci-h; ph=$BG
wait_until 10 started ci-h || fail "ci: holder never started"
bg_heavy ci-l
wait_until 10 queued ci-l lane 1 || fail "ci: lane never queued"
bg_heavy ci-c WRK_HEAVY_CLASS=ci
wait_until 10 queued ci-c ci 1 || fail "ci: ci waiter never queued"
settle_waiters || fail "ci: records were not visible for a full poll"
release ci-h
wait_until 10 started ci-c || fail "ci: ci waiter did not take the freed slot"
started ci-l && fail "ci: older lane ticket ran ahead of the live ci waiter"
release ci-c
wait_until 10 started ci-l || fail "ci: lane never ran after the ci waiter finished"
release ci-l
wait "$ph" || fail "ci: holder failed"
echo "PASS heavy-fifo-ci-ahead-of-older-lane"

# ── starvation guard still stops ci deferral (hk 1533, unchanged) ──────────
new_lock guard
sleep 300 &
guard_ci=$!
PIDS+=("$guard_ci")
printf 'pid=%s class=ci limit=1 since=2026-01-01T00:00:00 job=- cmd=guard-ci\n' \
  "$guard_ci" >"$WRK_HEAVY_LOCK.waiters/$guard_ci"
mkhold guard-l
release guard-l
t0="$(now)"
WRK_HEAVY_CI_DEFER_MAX=2 WRK_HEAVY_WAIT_CAP=20 \
  "$WRK" heavy -- bash "$TMP/guard-l.sh" || fail "guard run failed"
el="$(since "$t0")"
fcmp "$el" ge 1.5 || fail "guard: the lane did not defer at all (${el}s)"
fcmp "$el" le 12 || fail "guard: the lane kept deferring past the cap (${el}s)"
kill_own "$guard_ci"
echo "PASS heavy-fifo-starvation-guard-unchanged"

# ── a dead pid with an old ticket reserves nothing ─────────────────────────
dead_pid_reserves_nothing() {
  new_lock deadp
  sleep 30 &
  local dead=$!
  PIDS+=("$dead")
  kill "$dead" 2>/dev/null || true
  wait "$dead" 2>/dev/null || true
  if kill -0 "$dead" 2>/dev/null; then
    fail "dead: sleeper is still alive"
  fi
  printf 'pid=%s class=lane limit=1 ticket=1:1 since=2020-01-01T00:00:00 job=- cmd=dead-ticket\n' \
    "$dead" >"$WRK_HEAVY_LOCK.waiters/$dead"
  local t0 rc=0
  t0="$(now)"
  WRK_HEAVY_WAIT_CAP=6 "$(wrk_bin)" heavy -- touch "$TMP/dead-ran" \
    >"$TMP/dead.out" 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || fail "dead pid blocked the lane (rc=$rc): $(cat "$TMP/dead.out")"
  [[ -e "$TMP/dead-ran" ]] || fail "dead: command did not run"
  fcmp "$(since "$t0")" le 4 || fail "dead: lane waited on a dead pid"
  status_out | grep -q 'dead-ticket' && fail "status left a dead waiter record"
  [[ ! -e "$WRK_HEAVY_LOCK.waiters/$dead" ]] || fail "dead record remains after status"
}
dead_pid_reserves_nothing
echo "PASS heavy-fifo-dead-pid-reserves-nothing"

# ── a ticketless lane waiter is skipped by lane FIFO ───────────────────────
new_lock mixed
sleep 300 &
mixed_old=$!
PIDS+=("$mixed_old")
printf 'pid=%s class=lane limit=1 since=2020-01-01T00:00:00 job=- cmd=ticket=1:1 old-wrk\n' \
  "$mixed_old" >"$WRK_HEAVY_LOCK.waiters/$mixed_old"
mixed_fourth=$(awk '{print $4}' "$WRK_HEAVY_LOCK.waiters/$mixed_old")
[[ "$mixed_fourth" == since=* ]] ||
  fail "mixed: lane fixture is not ticketless ($mixed_fourth)"
mkhold mixed-h; mkhold mixed-y
bg_heavy mixed-h; ph=$BG
wait_until 10 started mixed-h || fail "mixed: holder never started"
bg_heavy mixed-y
wait_until 10 queued mixed-y lane 1 || fail "mixed: younger never queued"
yt="$(record_ticket_of mixed-y)"
[[ -n "$yt" ]] || fail "mixed: the new waiter published no ticket"
release mixed-h
wait_until 8 started mixed-y || fail "mixed: a record with no ticket stalled the queue"
kill -0 "$mixed_old" 2>/dev/null || fail "mixed: the old waiter was not alive during the acquire"
release mixed-y
wait "$ph" || fail "mixed: holder failed"
kill_own "$mixed_old"
echo "PASS heavy-fifo-old-record-no-ticket"

# ── a ticketless ci waiter still reserves (hk 1533 does not read tickets) ──
new_lock tci
sleep 300 &
tci_ci=$!
PIDS+=("$tci_ci")
printf 'pid=%s class=ci limit=1 since=2026-01-01T00:00:00 job=- cmd=ticketless-ci\n' \
  "$tci_ci" >"$WRK_HEAVY_LOCK.waiters/$tci_ci"
tci_fourth=$(awk '{print $4}' "$WRK_HEAVY_LOCK.waiters/$tci_ci")
[[ "$tci_fourth" == since=* ]] ||
  fail "tci: ci fixture is not ticketless ($tci_fourth)"
mkhold tci-l
bg_heavy tci-l
tci_lane=$BG
wait_until 10 queued tci-l lane 1 || fail "tci: lane never queued"
settle_waiters || fail "tci: the ticketless ci record was not visible for a full poll"
started tci-l && fail "tci: a ticketless ci waiter did not reserve the slot"
kill_own "$tci_ci"
wait_until 10 started tci-l ||
  fail "tci: lane did not run after the ticketless ci pid died"
release tci-l
wait "$tci_lane" || fail "tci: lane failed"
echo "PASS heavy-fifo-ticketless-ci-still-reserves"

# ── wall-clock ticket, not a monotonic counter ─────────────────────────────
python3 - "$yt" <<'PY'
import sys, time
ns = int(sys.argv[1].split(":", 1)[0])
now = time.time_ns()
# monotonic time since boot is far below 1e18; wall epoch ns is not
assert ns > 10**18, ns
assert abs(ns - now) < 60 * 10**9, (ns, now)
PY
echo "PASS heavy-fifo-ticket-is-wall-clock"

# ── keyed re-queue within the grace keeps the original ticket ──────────────
requeue_within_grace() {
  new_lock grace
  mkhold grace-h; mkhold grace-b; mkhold grace-a2
  bg_heavy grace-h; local ph=$BG
  wait_until 10 started grace-h || fail "grace: holder never started"
  local rc=0
  WRK_HEAVY_WAIT_CAP=2 WRK_HEAVY_REQUEUE_GRACE=600 \
    "$(wrk_bin)" heavy --queue-key keyA -- touch "$TMP/grace-a-ran" \
    >"$TMP/grace-a.out" 2>&1 || rc=$?
  [[ "$rc" -eq 75 ]] || fail "grace: A did not hit the cap (rc=$rc): $(cat "$TMP/grace-a.out")"
  [[ ! -e "$TMP/grace-a-ran" ]] || fail "grace: A ran despite the cap"
  local saved exp
  saved="$(position_ticket keyA | sed -n '1p')"
  exp="$(position_ticket keyA | sed -n '2p')"
  [[ -n "$saved" && -n "$exp" ]] || fail "grace: position record was not written"
  bg_heavy grace-b
  local pb=$BG
  wait_until 10 queued grace-b lane 1 || fail "grace: B never queued"
  local tb
  tb="$(record_ticket_of grace-b)"
  ticket_lt "$saved" "$tb" || fail "grace: saved ticket $saved is not older than B $tb"
  bg_key grace-a2 keyA WRK_HEAVY_REQUEUE_GRACE=600
  local pa=$BG
  wait_until 10 queued grace-a2 lane 1 || fail "grace: A re-queue never queued"
  local ta
  ta="$(record_ticket_of grace-a2)"
  [[ "$ta" == "$saved" ]] || fail "grace: re-queue ticket $ta did not reuse $saved"
  settle_waiters || fail "grace: records were not visible for a full poll"
  release grace-h
  wait_until 10 started grace-a2 || fail "grace: reused ticket did not take the slot: $(tr '\n' ' ' <"$TMP/order")"
  started grace-b && fail "grace: B ran ahead of the reused ticket"
  release grace-a2
  wait_until 10 started grace-b || fail "grace: B never ran"
  release grace-b
  wait "$ph" || fail "grace: holder failed"
  wait "$pa" || fail "grace: A re-queue failed"
  wait "$pb" || fail "grace: B failed"
}
requeue_within_grace
echo "PASS heavy-fifo-requeue-within-grace"

# ── after the grace, and exactly at expiry, the place is not reused ────────
new_lock exp
mkhold exp-h; mkhold exp-b; mkhold exp-a
bg_heavy exp-h; ph=$BG
wait_until 10 started exp-h || fail "exp: holder never started"
rc=0
WRK_HEAVY_WAIT_CAP=2 WRK_HEAVY_REQUEUE_GRACE=1 \
  "$WRK" heavy --queue-key keyA -- touch "$TMP/exp-a-ran" >"$TMP/exp-a.out" 2>&1 || rc=$?
[[ "$rc" -eq 75 ]] || fail "exp: A did not hit the cap (rc=$rc)"
exp_at="$(position_ticket keyA | sed -n '2p')"
wait_until 8 python3 -c 'import sys, time; sys.exit(0 if time.time_ns() >= int(sys.argv[1]) else 1)' "$exp_at" ||
  fail "exp: clock never reached the position expiry"
bg_heavy exp-b
wait_until 10 queued exp-b lane 1 || fail "exp: B never queued"
tb="$(record_ticket_of exp-b)"
bg_key exp-a keyA
wait_until 10 queued exp-a lane 1 || fail "exp: A re-queue never queued"
ta="$(record_ticket_of exp-a)"
ticket_lt "$tb" "$ta" || fail "exp: expired place was reused ($ta vs B $tb)"
settle_waiters || fail "exp: records were not visible for a full poll"
release exp-h
wait_until 10 started exp-b || fail "exp: B did not go first after expiry"
started exp-a && fail "exp: A ran ahead of B after the grace"
release exp-b
wait_until 10 started exp-a || fail "exp: A never ran"
release exp-a exp-h
wait "$ph" || fail "exp: holder failed"
# exactly the expiry instant is already expired (now >= expiry)
new_lock exact
printf 'key=exact ticket=1:1 expiry=%s\n' "$(python3 -c 'import time; print(time.time_ns())')" \
  >"$TMP/exact-pos"
mkdir -p "$WRK_HEAVY_LOCK.positions"
# spin until the planted expiry is not in the future, then run
python3 - "$TMP/exact-pos" <<'PY'
import sys, time
exp = int(open(sys.argv[1], encoding="utf-8").read().split()[2].split("=", 1)[1])
while time.time_ns() < exp:
    pass
PY
cp "$TMP/exact-pos" "$WRK_HEAVY_LOCK.positions/exact"
mkhold exact-y
bg_key exact-y exact
wait_until 10 started exact-y || fail "exact: waiter stalled on an expiry-equal position"
et="$(python3 -c 'import pathlib,sys; t=pathlib.Path(sys.argv[1]).read_text();
import re; m=re.search(r"ticket=([0-9]+:[0-9]+)", t); print(m.group(1) if m else "")' "$WRK_HEAVY_LOCK")"
[[ "$et" != "1:1" ]] || fail "exact: ticket 1:1 was reused at expiry"
release exact-y
wait "$BG" || fail "exact: waiter failed"
echo "PASS heavy-fifo-requeue-after-grace"

# ── an unkeyed re-queue does not keep a place ──────────────────────────────
new_lock naked
mkhold naked-h; mkhold naked-b; mkhold naked-a
bg_heavy naked-h; ph=$BG
wait_until 10 started naked-h || fail "naked: holder never started"
rc=0
WRK_HEAVY_WAIT_CAP=2 "$WRK" heavy -- touch "$TMP/naked-a-ran" >"$TMP/naked-a.out" 2>&1 || rc=$?
[[ "$rc" -eq 75 ]] || fail "naked: A did not hit the cap (rc=$rc)"
[[ ! -e "$WRK_HEAVY_LOCK.positions" ]] || fail "naked: unkeyed cap wrote a positions dir"
bg_heavy naked-b
wait_until 10 queued naked-b lane 1 || fail "naked: B never queued"
tb="$(record_ticket_of naked-b)"
bg_heavy naked-a
wait_until 10 queued naked-a lane 1 || fail "naked: A re-queue never queued"
ta="$(record_ticket_of naked-a)"
ticket_lt "$tb" "$ta" || fail "naked: unkeyed re-queue $ta was not after B $tb"
settle_waiters || fail "naked: records were not visible for a full poll"
release naked-h
wait_until 10 started naked-b || fail "naked: B did not go first"
started naked-a && fail "naked: unkeyed A ran ahead of B"
release naked-b
wait_until 10 started naked-a || fail "naked: A never ran"
release naked-a
wait "$ph" || fail "naked: holder failed"
echo "PASS heavy-fifo-unkeyed-requeue-after"

# ── the place is consumed on acquisition ───────────────────────────────────
new_lock eat
mkdir -p "$WRK_HEAVY_LOCK.positions"
python3 -c 'import time; print("key=eat ticket=5:5 expiry=%d" % (time.time_ns() + 10**12))' \
  >"$WRK_HEAVY_LOCK.positions/eat"
mkhold eat-y
bg_key eat-y eat
wait_until 10 started eat-y || fail "eat: waiter never started"
grep -q 'ticket=5:5' "$WRK_HEAVY_LOCK" || fail "eat: acquired holder did not carry the saved ticket"
[[ ! -e "$WRK_HEAVY_LOCK.positions/eat" ]] || fail "eat: position was not consumed on acquisition"
release eat-y
wait "$BG" || fail "eat: waiter failed"
mkhold eat-z
bg_key eat-z eat
wait_until 10 started eat-z || fail "eat: second run never started"
grep -q 'ticket=5:5' "$WRK_HEAVY_LOCK" && fail "eat: consumed ticket was reused"
release eat-z
wait "$BG" || fail "eat: second run failed"
echo "PASS heavy-fifo-position-consumed-on-acquire"

# ── a second process that starts before the cap does not inherit a place ──
new_lock early
mkhold early-h; mkhold early-a; mkhold early-b
bg_heavy early-h; ph=$BG
wait_until 10 started early-h || fail "early: holder never started"
bg_key early-a keyE WRK_HEAVY_WAIT_CAP=20
wait_until 10 queued early-a lane 1 || fail "early: A never queued"
[[ ! -e "$WRK_HEAVY_LOCK.positions/keyE" ]] || fail "early: a position exists before the cap"
bg_key early-b keyE WRK_HEAVY_WAIT_CAP=20
wait_until 10 queued early-b lane 1 || fail "early: B never queued"
ta="$(record_ticket_of early-a)"
tb="$(record_ticket_of early-b)"
ticket_lt "$ta" "$tb" || fail "early: B reused a place A had not saved ($ta vs $tb)"
release early-a early-b early-h
wait "$ph" || fail "early: holder failed"
echo "PASS heavy-fifo-key-before-cap-is-fresh"

# ── same-uid forge is honoured within the grace; that is the trust limit ──
new_lock forge
mkdir -p "$WRK_HEAVY_LOCK.positions"
python3 -c 'import time; print("key=forge ticket=1:1 expiry=%d" % (time.time_ns() + 10**12))' \
  >"$WRK_HEAVY_LOCK.positions/forge"
mkhold forge-y
bg_key forge-y forge
wait_until 10 started forge-y || fail "forge: waiter never started"
grep -q 'ticket=1:1' "$WRK_HEAVY_LOCK" ||
  fail "forge: a same-uid position was not reused — the trust limit changed"
release forge-y
wait "$BG" || fail "forge: waiter failed"
echo "PASS heavy-fifo-same-uid-forged-ticket"

# ── symlink, fifo, hardlink, malformed, and a foreign uid do not stall ─────
new_lock odd
mkdir -p "$WRK_HEAVY_LOCK.positions"
printf 'VICTIM\n' >"$TMP/odd-victim"
ln -s "$TMP/odd-victim" "$WRK_HEAVY_LOCK.positions/linkey"
mkfifo "$WRK_HEAVY_LOCK.positions/fifokey"
python3 -c 'import time; print("key=hard ticket=1:1 expiry=%d" % (time.time_ns() + 10**12))' \
  >"$TMP/odd-hard-src"
ln "$TMP/odd-hard-src" "$WRK_HEAVY_LOCK.positions/hardkey"
printf 'this is not a position\n' >"$WRK_HEAVY_LOCK.positions/badkey"
python3 -c 'import time; print("key=foreign ticket=1:1 expiry=%d" % (time.time_ns() + 10**12))' \
  >"$WRK_HEAVY_LOCK.positions/foreignkey"
printf 'garbage\n' >"$WRK_HEAVY_LOCK.positions/.crash.tmp"
FOREIGN_PRE=()
if ! sudo -n chown nobody "$WRK_HEAVY_LOCK.positions/foreignkey" 2>/dev/null; then
  mkdir -p "$TMP/pyhook"
  cat >"$TMP/pyhook/sitecustomize.py" <<'PY'
import os
_name = os.environ.get("WRK_TEST_FOREIGN_NAME", "")
_stat = os.stat
class _Proxy:
    def __init__(self, st):
        self._st = st
        self.st_uid = 65534
    def __getattr__(self, item):
        return getattr(self._st, item)
def stat(path, *args, **kwargs):
    st = _stat(path, *args, **kwargs)
    base = path if isinstance(path, str) else ""
    if _name and os.path.basename(base) == _name:
        return _Proxy(st)
    return st
os.stat = stat
PY
  FOREIGN_PRE=(PYTHONPATH="$TMP/pyhook" WRK_TEST_FOREIGN_NAME=foreignkey)
fi
# a fifo at the key name must not block the open
t0="$(now)"
env "${FOREIGN_PRE[@]}" "$WRK" heavy --queue-key fifokey -- touch "$TMP/odd-fifo-ran" ||
  fail "odd: fifo position stalled or refused the queue"
fcmp "$(since "$t0")" le 4 || fail "odd: fifo position delayed the acquire"
[[ -e "$TMP/odd-fifo-ran" ]] || fail "odd: fifo key did not run"
[[ "$(cat "$TMP/odd-victim")" == "VICTIM" ]] || fail "odd: symlink position was followed"
# hardlink and malformed are ignored: a fresh ticket, not 1:1
for key in hardkey badkey linkey; do
  rm -f "$TMP/odd-ran"
  "$WRK" heavy --queue-key "$key" -- touch "$TMP/odd-ran" || fail "odd: key $key stalled"
  [[ -e "$TMP/odd-ran" ]] || fail "odd: key $key did not run"
  [[ -e "$WRK_HEAVY_LOCK.positions/$key" ]] || fail "odd: ignored position $key was removed"
  grep -q 'ticket=1:1' "$WRK_HEAVY_LOCK" && fail "odd: key $key reused a planted ticket"
done
rm -f "$TMP/odd-ran"
env "${FOREIGN_PRE[@]}" "$WRK" heavy --queue-key foreignkey -- touch "$TMP/odd-ran" ||
  fail "odd: foreign position stalled the queue"
# the foreign file's ancient ticket must not have been the one acquired.
# An untrusted record is left in place, and the holder carries a fresh ticket.
[[ -e "$WRK_HEAVY_LOCK.positions/foreignkey" ]] ||
  fail "odd: an untrusted position file was removed"
grep -q 'ticket=1:1' "$WRK_HEAVY_LOCK" &&
  fail "odd: a foreign-owned position ticket was reused"
[[ -e "$WRK_HEAVY_LOCK.positions/.crash.tmp" ]] || fail "odd: a dotfile was removed"
# a dotfile plus a valid position: the valid one is reused, the dotfile is not a place
python3 -c 'import time; print("key=good ticket=7:7 expiry=%d" % (time.time_ns() + 10**12))' \
  >"$WRK_HEAVY_LOCK.positions/good"
mkhold odd-g
bg_key odd-g good
wait_until 10 started odd-g || fail "odd: valid position next to a dotfile did not run"
grep -q 'ticket=7:7' "$WRK_HEAVY_LOCK" || fail "odd: valid position was not reused"
release odd-g
wait "$BG" || fail "odd: valid position run failed"
echo "PASS heavy-fifo-forged-positions-ignored"

# ── an untrusted positions dir refuses a keyed run and does not stall ──────
new_lock trust
mkdir -p "$WRK_HEAVY_LOCK.positions"
chmod 0777 "$WRK_HEAVY_LOCK.positions"
rc=0
out="$("$WRK" heavy --queue-key trustkey -- touch "$TMP/trust-ran" 2>&1)" || rc=$?
[[ "$rc" -eq 78 ]] || fail "trust: world-writable positions dir must refuse rc 78, got $rc: $out"
grep -q 'untrusted positions dir' <<<"$out" || fail "trust: refusal must name the positions dir: $out"
[[ ! -e "$TMP/trust-ran" ]] || fail "trust: command ran on an untrusted positions dir"
# no key: the positions dir is not consulted
"$WRK" heavy -- touch "$TMP/trust-free" || fail "trust: unkeyed run refused an untrusted positions dir"
chmod 1777 "$WRK_HEAVY_LOCK.positions"
"$WRK" heavy --queue-key trustkey -- touch "$TMP/trust-sticky" ||
  fail "trust: a sticky positions dir owned by the user must be usable"
rm -rf "$WRK_HEAVY_LOCK.positions"
mkdir -p "$TMP/trust-target"
ln -s "$TMP/trust-target" "$WRK_HEAVY_LOCK.positions"
rc=0
out="$("$WRK" heavy --queue-key trustkey -- touch "$TMP/trust-link" 2>&1)" || rc=$?
[[ "$rc" -eq 78 ]] || fail "trust: a symlinked positions dir must refuse rc 78, got $rc: $out"
[[ -z "$(find "$TMP/trust-target" -mindepth 1 -print -quit)" ]] ||
  fail "trust: a record was written through the positions symlink"
echo "PASS heavy-fifo-untrusted-positions-dir"

# ── status lists live tickets in order and live positions, and cleans stale
new_lock stat
sleep 300 &
s1=$!
PIDS+=("$s1")
sleep 300 &
s2=$!
PIDS+=("$s2")
sleep 300 &
s3=$!
PIDS+=("$s3")
sleep 30 &
sdead=$!
PIDS+=("$sdead")
kill "$sdead" 2>/dev/null || true
wait "$sdead" 2>/dev/null || true
mkdir -p "$WRK_HEAVY_LOCK.waiters"
printf 'pid=%s class=lane limit=1 ticket=300:9 since=2026-01-01T00:00:00 job=- cmd=t-third\n' "$s1" \
  >"$WRK_HEAVY_LOCK.waiters/$s1"
printf 'pid=%s class=lane limit=1 ticket=100:2 since=2026-01-01T00:00:00 job=- cmd=t-first\n' "$s2" \
  >"$WRK_HEAVY_LOCK.waiters/$s2"
printf 'pid=%s class=lane limit=1 ticket=200:4 since=2026-01-01T00:00:00 job=- cmd=t-second\n' "$s3" \
  >"$WRK_HEAVY_LOCK.waiters/$s3"
printf 'pid=%s class=lane limit=1 since=2020-01-01T00:00:00 job=- cmd=t-old\n' "$s1" \
  >"$WRK_HEAVY_LOCK.waiters/oldfmt"
# oldfmt uses a live pid too so status does not delete it as dead; the name
# is not the pid. Give it s1's live pid only if that pid is not already the
# file name... s1's file is the pid. Use a second live sleeper.
sleep 300 &
sold=$!
PIDS+=("$sold")
printf 'pid=%s class=lane limit=1 since=2020-01-01T00:00:00 job=- cmd=t-old\n' "$sold" \
  >"$WRK_HEAVY_LOCK.waiters/$sold"
rm -f "$WRK_HEAVY_LOCK.waiters/oldfmt"
printf 'pid=%s class=lane limit=1 ticket=1:1 since=2020-01-01T00:00:00 job=- cmd=t-dead\n' "$sdead" \
  >"$WRK_HEAVY_LOCK.waiters/$sdead"
mkdir -p "$WRK_HEAVY_LOCK.positions"
python3 -c 'import time; print("key=live ticket=9:9 expiry=%d" % (time.time_ns() + 10**12))' \
  >"$WRK_HEAVY_LOCK.positions/live"
printf 'key=gone ticket=1:1 expiry=1\n' >"$WRK_HEAVY_LOCK.positions/gone"
printf 'nope\n' >"$WRK_HEAVY_LOCK.positions/malformed"
printf 'dot\n' >"$WRK_HEAVY_LOCK.positions/.hidden"
before="$(python3 -c 'import os,sys; print("\n".join(sorted(os.listdir(sys.argv[1]))))' "$WRK_HEAVY_LOCK.positions")"
st="$(status_out)"
after="$(python3 -c 'import os,sys; print("\n".join(sorted(os.listdir(sys.argv[1]))))' "$WRK_HEAVY_LOCK.positions")"
printf '%s\n' "$st" | awk '/^waiter /{print}' >"$TMP/stat-waiters"
# ticketed lines are oldest-first, then the unticketed record
python3 - "$TMP/stat-waiters" <<'PY'
import sys
lines = [l.strip() for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
texts = [l.split("cmd=", 1)[-1] for l in lines]
want_prefix = ["t-first", "t-second", "t-third"]
got = [t for t in texts if t.startswith("t-")]
assert got[:3] == want_prefix, got
assert "t-old" in got, got
assert got.index("t-old") == 3, got
assert "t-dead" not in got, got
PY
grep -q 'position key=live ticket=9:9 expiry=' <<<"$st" || fail "status: live position missing: $st"
grep -q 'position key=gone ' <<<"$st" && fail "status: expired position was listed"
[[ "$before" == *gone* && "$before" == *live* && "$before" == *malformed* ]] ||
  fail "status: before listing was unexpected: $before"
[[ "$after" != *gone* ]] || fail "status: expired position was not removed: $after"
[[ "$after" == *live* && "$after" == *malformed* && "$after" == *.hidden* ]] ||
  fail "status: removed more than the expired position: $after"
# no positions dir: status does not create one, and says so
rm -rf "$WRK_HEAVY_LOCK.positions"
st2="$(status_out)"
grep -q 'positions none' <<<"$st2" || fail "status: missing positions dir must say positions none"
[[ ! -e "$WRK_HEAVY_LOCK.positions" ]] || fail "status created a positions dir"
kill_own "$s1"
kill_own "$s2"
kill_own "$s3"
kill_own "$sold"
echo "PASS heavy-fifo-status-lists-and-cleans"

# ── two waiters, one position, equal tickets: no deadlock ──────────────────
new_lock eq
mkdir -p "$WRK_HEAVY_LOCK.positions"
python3 -c 'import time; print("key=eq ticket=4:4 expiry=%d" % (time.time_ns() + 10**12))' \
  >"$WRK_HEAVY_LOCK.positions/eq"
mkhold eq-h; mkhold eq-a; mkhold eq-b
bg_heavy eq-h; ph=$BG
wait_until 10 started eq-h || fail "eq: holder never started"
bg_key eq-a eq WRK_HEAVY_WAIT_CAP=15
bg_key eq-b eq WRK_HEAVY_WAIT_CAP=15
wait_until 10 queued eq-a lane 1 || fail "eq: A never queued"
wait_until 10 queued eq-b lane 1 || fail "eq: B never queued"
ta="$(record_ticket_of eq-a)"
tb="$(record_ticket_of eq-b)"
[[ "$ta" == "4:4" && "$tb" == "4:4" ]] || fail "eq: both waiters did not reuse 4:4 ($ta $tb)"
release eq-h
either_eq() { [[ -e "$TMP/eq-a.start" || -e "$TMP/eq-b.start" ]]; }
wait_until 10 either_eq ||
  fail "eq: equal tickets left the slot idle"
if started eq-a; then
  release eq-a
  wait_until 10 started eq-b || fail "eq: the other equal ticket never ran"
  release eq-b
else
  release eq-b
  wait_until 10 started eq-a || fail "eq: the other equal ticket never ran"
  release eq-a
fi
wait "$ph" || fail "eq: holder failed"
echo "PASS heavy-fifo-same-key-no-deadlock"

# ── concurrent publish still yields a total ticket order, no stall ─────────
new_lock race
mkhold race-h; mkhold race-a; mkhold race-b; mkhold race-c
bg_heavy race-h; ph=$BG
wait_until 10 started race-h || fail "race: holder never started"
bg_heavy race-a
bg_heavy race-b
bg_heavy race-c
wait_until 10 queued race-a lane 1 || fail "race: A never queued"
wait_until 10 queued race-b lane 1 || fail "race: B never queued"
wait_until 10 queued race-c lane 1 || fail "race: C never queued"
settle_waiters || fail "race: records were not visible for a full poll"
ta="$(record_ticket_of race-a)"
tb="$(record_ticket_of race-b)"
tc="$(record_ticket_of race-c)"
python3 - "$ta" "$tb" "$tc" <<'PY'
import sys
def p(t):
    n, _, i = t.partition(":")
    return (int(n), int(i))
vals = [p(t) for t in sys.argv[1:]]
assert len(set(vals)) == 3, vals
PY
# release in ticket order by asking the oldest live waiter to run
release race-h
# the oldest of the three must be the one that starts
python3 - "$ta" "$tb" "$tc" >"$TMP/race-order" <<'PY'
import sys
names = ["race-a", "race-b", "race-c"]
def p(t):
    n, _, i = t.partition(":")
    return (int(n), int(i))
order = [n for _, n in sorted(zip((p(t) for t in sys.argv[1:]), names))]
print("\n".join(order))
PY
first="$(sed -n '1p' "$TMP/race-order")"
second="$(sed -n '2p' "$TMP/race-order")"
third="$(sed -n '3p' "$TMP/race-order")"
wait_until 10 started "$first" || fail "race: oldest $first did not take the slot"
started "$second" && fail "race: $second ran before $first finished"
started "$third" && fail "race: $third ran before $first finished"
release "$first"
wait_until 10 started "$second" || fail "race: $second did not take the next slot"
release "$second"
wait_until 10 started "$third" || fail "race: $third did not take the last slot"
release "$third"
wait "$ph" || fail "race: holder failed"
echo "PASS heavy-fifo-concurrent-publish-no-stall"

# ── a pass that already scanned does not see a ticket published mid-pass ───
mutant() {
  python3 - "$WRK" "$TMP/$1-wrk" "$2" "$3" <<'MUT'
import sys
src_path, out_path, old, new = sys.argv[1:]
src = open(src_path, encoding="utf-8").read()
assert src.count(old) == 1, ("mutant anchor must be unique", src.count(old))
open(out_path, "w", encoding="utf-8").write(src.replace(old, new, 1))
MUT
  chmod +x "$TMP/$1-wrk"
}
mutant scanwin $'                lane_hold = lane_reserved(my_ticket)\n' \
  $'                lane_hold = lane_reserved(my_ticket)\n                open(os.environ["WRK_TEST_PASS_MARK"], "w").close()\n                while not os.path.exists(os.environ["WRK_TEST_PASS_GATE"]):\n                    time.sleep(0.05)\n'
new_lock scan
mkhold scan-h; mkhold scan-y
bg_heavy scan-h; ph=$BG
wait_until 10 started scan-h || fail "scan: holder never started"
HEAVY_BIN="$TMP/scanwin-wrk" bg_heavy scan-y \
  WRK_TEST_PASS_MARK="$TMP/scan.mark" WRK_TEST_PASS_GATE="$TMP/scan.gate"
wait_until 10 queued scan-y lane 1 || fail "scan: lane never queued"
wait_until 10 test -e "$TMP/scan.mark" || fail "scan: the pass never reached its scan"
sleep 300 &
scan_old=$!
PIDS+=("$scan_old")
printf 'pid=%s class=lane limit=1 ticket=1:1 since=2020-01-01T00:00:00 job=- cmd=mid-scan\n' \
  "$scan_old" >"$WRK_HEAVY_LOCK.waiters/$scan_old"
# Free the slot while the pass is parked, and wait until the holder has
# dropped the fd. Opening the gate before that makes the parked pass miss
# the flock, sleep, and rescan — the next pass is a new scan, not this one.
release scan-h
wait "$ph" || fail "scan: holder failed"
started scan-y && fail "scan: the lane moved before the gate opened"
: >"$TMP/scan.gate"
wait_until 10 started scan-y ||
  fail "scan: the in-flight pass no longer takes the slot — the documented window changed"
release scan-y
wait "$BG" || fail "scan: lane failed"
kill_own "$scan_old"
HEAVY_BIN=""
echo "PASS heavy-fifo-documented-scan-window"

# ── mutants: each named case goes RED by assertion, not by a crash ─────────
run_mutant() { # run_mutant <name> <err-substring> <function>
  local name="$1" needle="$2" fn="$3" mrc
  HEAVY_BIN=""
  set +e
  (
    set -euo pipefail
    CLEANUP_KEEP_TMP=1
    PIDS=()
    HEAVY_BIN="$TMP/$name-wrk"
    export HEAVY_BIN
    "$fn"
  ) >"$TMP/mut-$name.out" 2>"$TMP/mut-$name.err"
  mrc=$?
  set -e
  HEAVY_BIN=""
  [[ "$mrc" -ne 0 ]] || fail "mutant $name still held the invariant — RED proof is vacuous"
  if grep -q 'Traceback' "$TMP/mut-$name.err"; then
    cat "$TMP/mut-$name.err" >&2
    fail "mutant $name crashed instead of failing an assertion"
  fi
  grep -q "$needle" "$TMP/mut-$name.err" || {
    echo "mutant $name rc=$mrc did not fail the named assertion" >&2
    cat "$TMP/mut-$name.err" >&2
    fail "mutant $name proof was not the named assertion"
  }
  echo "PASS mutant-$name"
}

mutant ignoreticket $'                lane_hold = lane_reserved(my_ticket)\n' \
  $'                lane_hold = 0\n'
run_mutant ignoreticket 'older live ticket' older_ticket_blocks

mutant noreuse $'    saved = load_saved_ticket()\n' \
  $'    saved = None\n'
run_mutant noreuse 'did not reuse' requeue_within_grace

mutant deadreserves $'        if not alive(pid) or lim is None or lim < 1:\n' \
  $'        if lim is None or lim < 1:\n'
run_mutant deadreserves 'dead pid blocked' dead_pid_reserves_nothing

echo 'PASS test-wrk-heavy-fifo'
