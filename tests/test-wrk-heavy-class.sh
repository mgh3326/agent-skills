#!/usr/bin/env bash
# tests/test-wrk-heavy-class.sh — hk 1533 wrk heavy priority class.
#
# WRK_HEAVY_CLASS=ci puts a waiter ahead of every lane waiter on a host's
# shared heavy lock: while a live ci waiter is queued, lane waiters skip the
# slots it could take (index below the limit it queued under) so the next
# slot to free goes to it. Nothing is preempted; a dead ci waiter's leftover
# record reserves nothing; a lane waiter stops deferring after
# WRK_HEAVY_CI_DEFER_MAX seconds (default 1800); slots above the ci waiter's
# limit stay open to lanes (the desktop runner runs WRK_HEAVY_MAX=1).
#
# Stub commands only. HOME and every XDG dir point into a temp dir, every
# lock, waiters dir, load file and log is a temp path, and only pids this
# script started are ever signalled. Assertion-RED mutants over a copy of
# bin/wrk close the file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
TMP="$(mktemp -d)"
PIDS=()

fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
  local f pid
  # holder scripts poll for their release file: free them first so no
  # orphaned command outlives the temp dir, then signal only our own pids
  for f in "$TMP"/*.sh; do
    [[ -e "$f" ]] && : >"${f%.sh}.rel"
  done
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  # a command finishing its last touch can race the removal
  rm -rf "$TMP" 2>/dev/null || { sleep 1; rm -rf "$TMP" 2>/dev/null || true; }
}
trap cleanup EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state" \
  XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache" \
  XDG_RUNTIME_DIR="$HOME/run"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" \
  "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
unset ARBITER_JOB HK_TASK_ID WRK_HEAVY_HELD WRK_HEAVY_HELD_FD WRK_HEAVY_CLASS \
  WRK_HEAVY_MAX WRK_HEAVY_CI_DEFER_MAX WRK_HEAVY_LOCK
export WRK_HOSTS_CONFIG="$TMP/hosts.toml" # never written: limit defaults to 1
export WRK_HEAVY_LOAD_FILE="$TMP/load"
export WRK_HEAVY_LOG="$TMP/heavy.log"
# a safety net, not a behaviour under test: a waiter orphaned by a failed
# run gives up on its own instead of polling for the 20 minute default
export WRK_HEAVY_WAIT_CAP=120
printf '0\n' >"$WRK_HEAVY_LOAD_FILE"
: >"$WRK_HEAVY_LOG"

wait_until() {
  local limit="$1"; shift
  local deadline=$(( $(date +%s) + limit ))
  while (( $(date +%s) <= deadline )); do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  return 1
}

now() { python3 -c 'import time; print("%.3f" % time.time())'; }
since() { python3 -c 'import sys, time; print("%.2f" % (time.time() - float(sys.argv[1])))' "$1"; }
fcmp() { # fcmp <a> <op: ge|le> <b>
  python3 -c 'import operator, sys; sys.exit(0 if getattr(operator, sys.argv[2])(float(sys.argv[1]), float(sys.argv[3])) else 1)' "$@"
}

new_lock() { # a fresh lock + waiters dir per scenario: orphans never leak across
  export WRK_HEAVY_LOCK="$TMP/$1.lock"
  mkdir -p "$WRK_HEAVY_LOCK.waiters"
  : >"$TMP/order"
}

mkhold() { # mkhold <name>: logs <name>, touches <name>.start, waits for <name>.rel
  cat >"$TMP/$1.sh" <<EOF
trap 'echo $1 >>"$TMP/signals"' TERM INT HUP QUIT USR1 USR2
echo $1 >>"$TMP/order"
: >"$TMP/$1.start"
n=0
while [ ! -e "$TMP/$1.rel" ] && [ \$n -lt 300 ]; do sleep 0.2; n=\$((n + 1)); done
: >"$TMP/$1.done"
EOF
}

release() { local n; for n in "$@"; do : >"$TMP/$n.rel"; done; }

bg_heavy() { # bg_heavy <name> [VAR=val...]: <name>.sh under wrk heavy; pid -> BG
  local name="$1"; shift
  env "$@" "$WRK" heavy -- bash "$TMP/$name.sh" >"$TMP/$name.out" 2>&1 &
  BG=$!
  PIDS+=("$BG")
}

status_out() { "$WRK" heavy status; }
queued() { # queued <name> <class> <limit>: that waiter is on the status list
  status_out | grep -Eq "^waiter pid=[0-9]+ class=$2 limit=$3 .*cmd=bash $TMP/$1\\.sh\$"
}
started() { [[ -e "$TMP/$1.start" ]]; }

fake_ci() { # fake_ci <limit>: a live-looking ci waiter record (a sleeper's pid)
  sleep 300 &
  FAKE=$!
  PIDS+=("$FAKE")
  printf 'pid=%d class=ci limit=%s since=2026-01-01T00:00:00 job=- cmd=fake-ci\n' \
    "$FAKE" "$1" >"$WRK_HEAVY_LOCK.waiters/$FAKE"
}

kill_own() { # kill_own <pid>: a pid this script started, then reap it
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

log_rows() { # log_rows <kind> <cmd-substring>: matching heavy.log rows as JSON lines
  python3 - "$WRK_HEAVY_LOG" "$1" "$2" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(line)
    if r.get("kind") == sys.argv[2] and sys.argv[3] in r.get("cmd", ""):
        print(json.dumps(r, sort_keys=True))
PY
}

# ── static: docs name the class and the guard; no signal path exists ───────
help_out="$("$WRK" heavy --help)"
for token in WRK_HEAVY_CLASS WRK_HEAVY_CI_DEFER_MAX 1800 'class=ci|lane' \
  'kind=defer' 'preempt'; do
  grep -qF -- "$token" <<<"$help_out" || fail "heavy --help must mention: $token"
done
for token in WRK_HEAVY_CLASS WRK_HEAVY_CI_DEFER_MAX 1800 kind=defer; do
  grep -qF -- "$token" "$ROOT/spawn-worker/SKILL.md" ||
    fail "spawn-worker/SKILL.md heavy section must mention: $token"
done
python3 - "$WRK" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
start = src.index("heavy_cmd() {")
half = src[start:src.index('\ncase "${1:-}" in', start)]
sig = re.findall(r"os\.(?:kill|killpg)\([^)]*\)|\.(?:kill|terminate|send_signal)\(|"
                 r"import[^\n]*\bsignal\b|from signal\b", half)
# alive() probes with signal 0; nothing in the heavy path may signal a holder
assert sig == ["os.kill(pid, 0)"], ("a signal path exists in wrk heavy", sig)
PY
echo "PASS heavy-class-static-docs-and-no-signal-path"

# ── invalid class refuses rc 78; lane/empty/ci run; status stays readable ──
new_lock s1
for bad in CI Ci ' ci' ci2 foo 1 'ci lane'; do
  rm -f "$TMP/s1-ran"
  rc=0
  out="$(WRK_HEAVY_CLASS="$bad" "$WRK" heavy -- touch "$TMP/s1-ran" 2>&1)" || rc=$?
  [[ "$rc" -eq 78 ]] || fail "WRK_HEAVY_CLASS='$bad' must refuse rc 78, got rc=$rc: $out"
  grep -q 'WRK_HEAVY_CLASS' <<<"$out" || fail "refusal must name WRK_HEAVY_CLASS: $out"
  [[ ! -e "$TMP/s1-ran" ]] || fail "command ran under invalid class '$bad'"
  WRK_HEAVY_CLASS="$bad" "$WRK" heavy status >/dev/null ||
    fail "status must stay readable under invalid class '$bad'"
done
for ok in '' lane ci; do
  rm -f "$TMP/s1-ran"
  WRK_HEAVY_CLASS="$ok" "$WRK" heavy -- touch "$TMP/s1-ran" ||
    fail "WRK_HEAVY_CLASS='$ok' must run"
  [[ -e "$TMP/s1-ran" ]] || fail "class '$ok' run did not execute"
done
for badmax in abc -1 nan ''; do
  rc=0
  WRK_HEAVY_CI_DEFER_MAX="$badmax" "$WRK" heavy -- true >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] || fail "WRK_HEAVY_CI_DEFER_MAX='$badmax' must refuse rc 2, got rc=$rc"
done
echo "PASS heavy-class-invalid-refuses-rc78"

# ── a live ci waiter holds a lane back from a FREE slot; its death frees it
new_lock s2
fake_ci 1
mkhold s2-lane
release s2-lane
bg_heavy s2-lane
lane=$BG
wait_until 10 queued s2-lane lane 1 || fail "lane waiter never queued"
sleep 3
started s2-lane && fail "lane took the free slot while a live ci waiter was queued"
status_out | grep -q '^holder none' || fail "the slot was not free during the deferral"
status_out | grep -q "^waiter pid=$FAKE class=ci limit=1 " ||
  fail "status must list the ci waiter with its class and limit"
kill_own "$FAKE"
wait_until 10 started s2-lane || fail "lane never ran after the ci waiter died"
wait "$lane" || fail "lane run failed"
[[ "$(log_rows defer s2-lane | wc -l | tr -d ' ')" -eq 1 ]] ||
  fail "a deferred lane waiter writes exactly one defer row"
log_rows defer s2-lane | python3 -c '
import json, sys
r = json.loads(sys.stdin.read())
assert r["class"] == "lane" and r["reason"] == "acquired", r
assert r["wait_s"] >= 2.5 and r["defer_s"] >= 2.5, r
'
echo "PASS heavy-class-lane-defers-to-live-ci-waiter"

# ── a dead ci waiter record never blocks lanes ─────────────────────────────
new_lock s3
sleep 0.1 &
dead=$!
wait "$dead"
printf 'pid=%d class=ci limit=1 since=2026-01-01T00:00:00 job=- cmd=dead-ci\n' \
  "$dead" >"$WRK_HEAVY_LOCK.waiters/$dead"
t0="$(now)"
WRK_HEAVY_WAIT_CAP=10 "$WRK" heavy -- touch "$TMP/s3-ran" ||
  fail "a dead ci waiter record blocked a lane waiter"
[[ -e "$TMP/s3-ran" ]] || fail "lane command did not run"
fcmp "$(since "$t0")" le 3 || fail "lane waited on a dead ci waiter record"
[[ -z "$(log_rows defer s3-ran)" ]] || fail "a dead ci record caused a defer row"
echo "PASS heavy-class-dead-ci-waiter-ignored"

# ── text inside a command or an old-format record cannot forge a ci waiter ─
new_lock s3b
sleep 300 &
forged=$!
PIDS+=("$forged")
printf 'pid=%d since=2026-01-01T00:00:00 job=- cmd=env class=ci limit=1 true\n' \
  "$forged" >"$WRK_HEAVY_LOCK.waiters/$forged"
status_out | grep -q "^waiter pid=$forged class=lane since=" ||
  fail "an old-format waiter record must read as class=lane in status"
WRK_HEAVY_WAIT_CAP=10 "$WRK" heavy -- touch "$TMP/s3b-ran" ||
  fail "class= text inside a record command reserved the slot"
[[ -e "$TMP/s3b-ran" ]] || fail "lane command did not run"
kill_own "$forged"
echo "PASS heavy-class-record-text-cannot-forge-ci"

# ── ci gets the next free slot before an earlier-queued lane waiter ────────
# Two slots, both held; a lane waiter queues first, then a ci waiter. Free
# one slot: the ci waiter takes it, the lane waiter keeps waiting until a
# slot frees again. Three rounds, alternating which slot frees, because
# without priority whoever polls first wins (a coin flip per round).
ordering_round() { # ordering_round <tag> <holder to release: A|B>
  local tag="$1" rel="$2" pa pb pl pc out
  new_lock "$tag"
  mkhold "$tag-A"; mkhold "$tag-B"; mkhold "$tag-L"; mkhold "$tag-C"
  bg_heavy "$tag-A" WRK_HEAVY_MAX=2; pa=$BG
  wait_until 10 started "$tag-A" || fail "$tag: holder A never started"
  bg_heavy "$tag-B" WRK_HEAVY_MAX=2; pb=$BG
  wait_until 10 started "$tag-B" || fail "$tag: holder B never started"
  bg_heavy "$tag-L" WRK_HEAVY_MAX=2; pl=$BG
  wait_until 10 queued "$tag-L" lane 2 || fail "$tag: lane waiter never queued"
  bg_heavy "$tag-C" WRK_HEAVY_MAX=2 WRK_HEAVY_CLASS=ci; pc=$BG
  wait_until 10 queued "$tag-C" ci 2 || fail "$tag: ci waiter never queued"
  out="$(status_out)"
  grep -Eq "^holder slot=0 pid=[0-9]+ class=lane limit=2 " <<<"$out" ||
    fail "$tag: status must show the holder class and limit: $out"
  release "$tag-$rel"
  wait_until 10 started "$tag-C" || fail "$tag: ci waiter did not get the freed slot"
  started "$tag-L" && fail "$tag: lane waiter took the slot ahead of the queued ci waiter"
  status_out | grep -Eq "^holder slot=[01] pid=[0-9]+ class=ci limit=2 .*cmd=bash $TMP/$tag-C\\.sh\$" ||
    fail "$tag: status must show the ci holder with class=ci"
  sleep 1.5 # both slots are held again: the lane keeps waiting
  started "$tag-L" && fail "$tag: lane ran while both slots were held"
  release "$tag-C"
  wait_until 10 started "$tag-L" || fail "$tag: lane never ran once a slot freed"
  release "$tag-A" "$tag-B" "$tag-L"
  wait "$pa" || fail "$tag: holder A failed"
  wait "$pb" || fail "$tag: holder B failed"
  wait "$pc" || fail "$tag: ci run failed"
  wait "$pl" || fail "$tag: lane run failed"
  [[ "$(tr '\n' ' ' <"$TMP/order")" == "$tag-A $tag-B $tag-C $tag-L " ]] ||
    fail "$tag: start order was: $(tr '\n' ' ' <"$TMP/order")"
}
ordering_round s4a B
ordering_round s4b A
ordering_round s4c B
echo "PASS heavy-class-ci-takes-next-free-slot-before-lane"

# ── a ci waiter confined to slot 0 never leaves slot 1 idle ────────────────
# Pinned behaviour (brief note): a lane waiter defers only while a slot the
# ci waiter could take is free. Here the ci waiter runs under
# WRK_HEAVY_MAX=1 (the desktop runner), so slot 1 is open to lanes.
new_lock s5
mkhold s5-H; mkhold s5-C; mkhold s5-L; mkhold s5-M
bg_heavy s5-H WRK_HEAVY_MAX=2; ph=$BG
wait_until 10 started s5-H || fail "s5: holder never started"
bg_heavy s5-C WRK_HEAVY_MAX=1 WRK_HEAVY_CLASS=ci; pc=$BG
wait_until 10 queued s5-C ci 1 || fail "s5: ci waiter never queued"
bg_heavy s5-L WRK_HEAVY_MAX=2; pl=$BG
wait_until 10 started s5-L || fail "free slot 1 sat idle behind a ci waiter confined to slot 0"
started s5-C && fail "s5: the ci waiter ran before slot 0 freed"
status_out | grep -Eq "^holder slot=1 pid=[0-9]+ class=lane limit=2 .*cmd=bash $TMP/s5-L\\.sh\$" ||
  fail "s5: the lane must hold slot 1"
bg_heavy s5-M WRK_HEAVY_MAX=2; pm=$BG
wait_until 10 queued s5-M lane 2 || fail "s5: second lane never queued"
sleep 1.5
started s5-M && fail "s5: second lane ran with slot 0 reserved and slot 1 held"
release s5-H
wait_until 10 started s5-C || fail "s5: ci waiter did not take slot 0 when it freed"
started s5-M && fail "s5: second lane took slot 0 ahead of the ci waiter"
release s5-L
wait_until 10 started s5-M || fail "s5: second lane never ran once slot 1 freed"
release s5-C s5-M
wait "$ph" || fail "s5: holder failed"
wait "$pc" || fail "s5: ci run failed"
wait "$pl" || fail "s5: lane run failed"
wait "$pm" || fail "s5: second lane failed"
log_rows run s5-C.sh | python3 -c '
import json, sys
r = json.loads(sys.stdin.read().splitlines()[-1])
assert r["class"] == "ci" and r["slot"] == 0 and r["limit"] == 1, r
'
log_rows run s5-L.sh | python3 -c '
import json, sys
r = json.loads(sys.stdin.read().splitlines()[-1])
assert r["class"] == "lane" and r["slot"] == 1 and r["limit"] == 2, r
'
echo "PASS heavy-class-ci-limit-1-never-idles-slot-1"

# ── WRK_HEAVY_MAX override: a lane at 3 slots still uses 1 and 2 ───────────
new_lock s5b
mkhold s5b-H; mkhold s5b-X; mkhold s5b-Y
bg_heavy s5b-H WRK_HEAVY_MAX=3; ph=$BG
wait_until 10 started s5b-H || fail "s5b: holder never started"
fake_ci 1 # a ci waiter confined to slot 0, which the holder occupies
bg_heavy s5b-X WRK_HEAVY_MAX=3; px=$BG
wait_until 10 started s5b-X || fail "s5b: lane X blocked despite free slots above the ci limit"
bg_heavy s5b-Y WRK_HEAVY_MAX=3; py=$BG
wait_until 10 started s5b-Y || fail "s5b: lane Y blocked despite a free slot above the ci limit"
release s5b-H s5b-X s5b-Y
wait "$ph" "$px" "$py" || fail "s5b: a run failed"
kill_own "$FAKE"
echo "PASS heavy-class-max-override-keeps-slots-above-ci-limit"

# ── anti-starvation guard: a lane waiter stops deferring after the limit ───
new_lock s6
fake_ci 1
mkhold s6-lane
release s6-lane
t0="$(now)"
WRK_HEAVY_CI_DEFER_MAX=2 WRK_HEAVY_WAIT_CAP=30 "$WRK" heavy -- bash "$TMP/s6-lane.sh" ||
  fail "guard run failed"
el="$(since "$t0")"
fcmp "$el" ge 1.5 || fail "the lane did not defer at all (${el}s)"
fcmp "$el" le 8 || fail "the lane kept deferring past WRK_HEAVY_CI_DEFER_MAX=2 (${el}s)"
[[ "$(log_rows defer s6-lane | wc -l | tr -d ' ')" -eq 1 ]] ||
  fail "the guard run must write exactly one defer row"
log_rows defer s6-lane | python3 -c '
import json, sys
r = json.loads(sys.stdin.read())
assert r["kind"] == "defer" and r["class"] == "lane" and r["reason"] == "guard", r
assert r["wait_s"] >= 2 and r["defer_s"] >= 2 and r["limit"] == 1, r
'
# 0 turns the deferral off for the run: no wait, no defer row
rm -f "$TMP/s6-ran"
t0="$(now)"
WRK_HEAVY_CI_DEFER_MAX=0 WRK_HEAVY_WAIT_CAP=30 "$WRK" heavy -- touch "$TMP/s6-ran" ||
  fail "DEFER_MAX=0 run failed"
fcmp "$(since "$t0")" le 3 || fail "DEFER_MAX=0 still deferred"
[[ -z "$(log_rows defer s6-ran)" ]] || fail "DEFER_MAX=0 wrote a defer row"
kill_own "$FAKE"
echo "PASS heavy-class-starvation-guard"

# ── no preemption: a running holder is never signalled or displaced ────────
new_lock s7
rm -f "$TMP/signals"
mkhold s7-H; mkhold s7-C; mkhold s7-L
bg_heavy s7-H; ph=$BG
wait_until 10 started s7-H || fail "s7: holder never started"
holder_py="$(awk '{print $1}' "$WRK_HEAVY_LOCK" | sed -n 's/^pid=//p')"
[[ "$holder_py" =~ ^[0-9]+$ ]] || fail "s7: no holder pid recorded"
bg_heavy s7-C WRK_HEAVY_CLASS=ci; pc=$BG
wait_until 10 queued s7-C ci 1 || fail "s7: ci waiter never queued"
bg_heavy s7-L; pl=$BG
wait_until 10 queued s7-L lane 1 || fail "s7: lane waiter never queued"
sleep 3
kill -0 "$holder_py" 2>/dev/null || fail "s7: the holder's wrk heavy process was killed"
[[ ! -e "$TMP/s7-H.done" ]] || fail "s7: the holder was cut short"
[[ ! -e "$TMP/signals" ]] || fail "s7: the holder received a signal: $(cat "$TMP/signals")"
started s7-C && fail "s7: the ci waiter ran while the holder held the only slot"
release s7-H
wait "$ph" || fail "s7: holder failed"
wait_until 10 started s7-C || fail "s7: ci waiter never ran after the holder finished"
started s7-L && fail "s7: lane ran ahead of the ci waiter"
release s7-C
wait "$pc" || fail "s7: ci run failed"
wait_until 10 started s7-L || fail "s7: lane never ran"
release s7-L
wait "$pl" || fail "s7: lane run failed"
[[ -e "$TMP/s7-H.done" ]] || fail "s7: the holder never completed normally"
[[ ! -e "$TMP/signals" ]] || fail "s7: a signal reached a command: $(cat "$TMP/signals")"
echo "PASS heavy-class-no-preemption"

# ── ci waiters never defer to each other ───────────────────────────────────
new_lock s8
mkhold s8-H; mkhold s8-C1; mkhold s8-C2
bg_heavy s8-H; ph=$BG
wait_until 10 started s8-H || fail "s8: holder never started"
bg_heavy s8-C1 WRK_HEAVY_CLASS=ci; p1=$BG
bg_heavy s8-C2 WRK_HEAVY_CLASS=ci; p2=$BG
wait_until 10 queued s8-C1 ci 1 || fail "s8: first ci waiter never queued"
wait_until 10 queued s8-C2 ci 1 || fail "s8: second ci waiter never queued"
release s8-H
wait_until 10 test -e "$TMP/s8-C1.start" -o -e "$TMP/s8-C2.start" ||
  fail "s8: ci waiters deferred to each other and left the slot idle"
release s8-C1 s8-C2
wait "$ph" "$p1" "$p2" || fail "s8: a run failed"
[[ -z "$(log_rows defer s8-C)" ]] || fail "s8: a ci waiter wrote a defer row"
echo "PASS heavy-class-ci-never-defers"

# ── log rows carry the class: run and wait_cap ─────────────────────────────
new_lock s9
mkhold s9-H
bg_heavy s9-H; ph=$BG
wait_until 10 started s9-H || fail "s9: holder never started"
for cls in lane ci; do
  rc=0
  WRK_HEAVY_CLASS="$cls" WRK_HEAVY_WAIT_CAP=1 "$WRK" heavy -- touch "$TMP/s9-$cls-ran" \
    >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 75 ]] || fail "s9: capped $cls waiter must exit 75, got rc=$rc"
done
release s9-H
wait "$ph" || fail "s9: holder failed"
python3 - "$WRK_HEAVY_LOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
caps = {r["cmd"].split()[-1].split("/")[-1]: r for r in rows
        if r.get("kind") == "wait_cap"
        and r["cmd"].startswith("touch") and "s9-" in r["cmd"]}
assert caps["s9-lane-ran"]["class"] == "lane", caps
assert caps["s9-ci-ran"]["class"] == "ci", caps
runs = [r for r in rows if r.get("kind") == "run" and "s9-H.sh" in r["cmd"]]
assert runs and runs[-1]["class"] == "lane", runs
PY
echo "PASS heavy-class-log-rows-carry-class"

# ── assertion-RED mutants over a copy of bin/wrk ───────────────────────────
mutant() { # mutant <name> <old> <new>: wrk copy with the unique <old> replaced
  python3 - "$WRK" "$TMP/$1-wrk" "$2" "$3" <<'PY'
import sys
src_path, out_path, old, new = sys.argv[1:]
src = open(src_path, encoding="utf-8").read()
assert src.count(old) == 1, ("mutant anchor must be unique", old, src.count(old))
open(out_path, "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
  chmod +x "$TMP/$1-wrk"
}

# nopriority: lanes never defer. RED proof: with a live ci waiter and a free
# slot the lane runs at once — the s2 "kept waiting" assertion is what fails.
mutant nopriority 'if hclass != "ci" and defer_max > 0 and not defer_over:' 'if False:'
new_lock m1
fake_ci 1
WRK_HEAVY_WAIT_CAP=10 "$TMP/nopriority-wrk" heavy -- touch "$TMP/m1-ran" ||
  fail "mutant nopriority run failed"
[[ -e "$TMP/m1-ran" ]] || fail "mutant nopriority: the lane still deferred — s2 assertion is vacuous"
kill_own "$FAKE"
echo "PASS mutant-nopriority"

# noguard: the guard never fires. RED proof: the lane that must acquire after
# DEFER_MAX=1 instead waits out the cap (rc 75).
mutant noguard 'if now - defer_since >= defer_max:' 'if False:'
new_lock m2
fake_ci 1
rc=0
WRK_HEAVY_CI_DEFER_MAX=1 WRK_HEAVY_WAIT_CAP=4 "$TMP/noguard-wrk" heavy -- \
  touch "$TMP/m2-ran" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 75 && ! -e "$TMP/m2-ran" ]] ||
  fail "mutant noguard still released the lane (rc=$rc) — guard assertion is vacuous"
kill_own "$FAKE"
echo "PASS mutant-noguard"

# allslots: a live ci waiter reserves every slot, ignoring its limit. RED
# proof: the lane cannot use the free slot 1 and caps out.
mutant allslots '                if i < reserved:' '                if reserved:'
new_lock m3
mkhold m3-H
bg_heavy m3-H WRK_HEAVY_MAX=2
wait_until 10 started m3-H || fail "mutant allslots holder never started"
fake_ci 1
rc=0
WRK_HEAVY_MAX=2 WRK_HEAVY_WAIT_CAP=3 "$TMP/allslots-wrk" heavy -- \
  touch "$TMP/m3-ran" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 75 && ! -e "$TMP/m3-ran" ]] ||
  fail "mutant allslots still used slot 1 (rc=$rc) — idle-slot assertion is vacuous"
release m3-H
kill_own "$FAKE"
echo "PASS mutant-allslots"

# deadci: a dead ci waiter's record still reserves. RED proof: the lane that
# must run at once caps out behind the dead record.
mutant deadci 'if lim is None or lim < 1 or not alive(pid):' 'if lim is None or lim < 1:'
new_lock m4
sleep 0.1 &
dead=$!
wait "$dead"
printf 'pid=%d class=ci limit=1 since=2026-01-01T00:00:00 job=- cmd=dead-ci\n' \
  "$dead" >"$WRK_HEAVY_LOCK.waiters/$dead"
rc=0
WRK_HEAVY_WAIT_CAP=3 "$TMP/deadci-wrk" heavy -- touch "$TMP/m4-ran" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 75 && ! -e "$TMP/m4-ran" ]] ||
  fail "mutant deadci still ignored the dead record (rc=$rc) — liveness assertion is vacuous"
echo "PASS mutant-deadci"

# headscan: class= and limit= are read from anywhere in the record, so text
# inside a command forges a ci waiter. RED proof: the forged old-format
# record from the s3b test now blocks the lane.
mutant headscan $'"lane", None\n    toks = text.split(None, 3)[:3]' $'"lane", None\n    toks = text.split()'
new_lock m5
sleep 300 &
forged=$!
PIDS+=("$forged")
printf 'pid=%d since=2026-01-01T00:00:00 job=- cmd=env class=ci limit=1 true\n' \
  "$forged" >"$WRK_HEAVY_LOCK.waiters/$forged"
rc=0
WRK_HEAVY_WAIT_CAP=3 "$TMP/headscan-wrk" heavy -- touch "$TMP/m5-ran" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 75 && ! -e "$TMP/m5-ran" ]] ||
  fail "mutant headscan still ignored forged text (rc=$rc) — head-only assertion is vacuous"
kill_own "$forged"
echo "PASS mutant-headscan"

# cidefers: ci waiters defer like lanes. RED proof: two ci waiters both defer
# to each other and a freed slot sits idle.
mutant cidefers 'if hclass != "ci" and defer_max > 0 and not defer_over:' 'if defer_max > 0 and not defer_over:'
new_lock m6
mkhold m6-H; mkhold m6-C1; mkhold m6-C2
bg_heavy m6-H
wait_until 10 started m6-H || fail "mutant cidefers holder never started"
mh=$BG
# a short cap: the deferring mutant waiters end on their own (rc 75)
env WRK_HEAVY_CLASS=ci WRK_HEAVY_WAIT_CAP=8 "$TMP/cidefers-wrk" heavy -- \
  bash "$TMP/m6-C1.sh" >/dev/null 2>&1 &
mc1=$!
PIDS+=("$mc1")
env WRK_HEAVY_CLASS=ci WRK_HEAVY_WAIT_CAP=8 "$TMP/cidefers-wrk" heavy -- \
  bash "$TMP/m6-C2.sh" >/dev/null 2>&1 &
mc2=$!
PIDS+=("$mc2")
wait_until 10 queued m6-C1 ci 1 || fail "mutant cidefers: first ci waiter never queued"
wait_until 10 queued m6-C2 ci 1 || fail "mutant cidefers: second ci waiter never queued"
release m6-H
wait "$mh" || fail "mutant cidefers holder failed"
sleep 3
if started m6-C1 || started m6-C2; then
  fail "mutant cidefers still let a ci waiter take the slot — never-defer assertion is vacuous"
fi
rc=0
wait "$mc1" || rc=$?
[[ "$rc" -eq 75 ]] || fail "mutant cidefers waiter 1 must cap out rc 75, got rc=$rc"
rc=0
wait "$mc2" || rc=$?
[[ "$rc" -eq 75 ]] || fail "mutant cidefers waiter 2 must cap out rc 75, got rc=$rc"
echo "PASS mutant-cidefers"

echo 'PASS test-wrk-heavy-class'
