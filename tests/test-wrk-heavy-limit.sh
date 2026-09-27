#!/usr/bin/env bash
# tests/test-wrk-heavy-limit.sh — #772 per-host wrk heavy concurrency limit
# (hosts.toml [local] heavy_max: 0 refuses rc 78 naming the host, N>1 opens N
# flock slots with kernel reclaim of dead holders, unset = 1) plus the
# wait-time JSONL log contract (host/job/task/cmd/wait_s/hold_s) and
# assertion-RED mutants over the wrk source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
TMP="$(mktemp -d)"

export WRK_HEAVY_LOCK="$TMP/heavy.lock"
export WRK_HEAVY_LOAD_FILE="$TMP/heavy-load"
export WRK_HEAVY_LOG="$TMP/heavy.log"
printf '0\n' >"$WRK_HEAVY_LOAD_FILE"
: >"$WRK_HEAVY_LOG"

HOSTNAME="$(python3 -c 'import socket; print(socket.gethostname())')"

fail() { echo "FAIL: $*" >&2; exit 1; }
pid_dead() { ! kill -0 "$1" 2>/dev/null; }

wait_until() {
  local limit="$1"; shift
  local deadline=$(( $(date +%s) + limit ))
  while (( $(date +%s) <= deadline )); do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  return 1
}

slot_holder_pid() { # pid recorded in a slot file's first field, or empty
  awk '{print $1}' "$1" 2>/dev/null | sed -n 's/^pid=//p'
}

cleanup() {
  local pid pidfile f
  # recorded holder pids are the wrk heavy python processes — killing them
  # releases the slot fds even while their commands linger as orphans
  for f in "$WRK_HEAVY_LOCK" "$WRK_HEAVY_LOCK".slot*; do
    pid="$(slot_holder_pid "$f")"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; fi
  done
  while IFS= read -r pidfile; do
    [[ -s "$pidfile" ]] || continue
    read -r pid <"$pidfile" || continue
    if [[ "$pid" =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; fi
  done < <(find "$TMP" -name '*.pid' 2>/dev/null)
  for pid in $(jobs -p); do kill "$pid" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

mkconfig() { # mkconfig <name> [heavy_max value] — no arg = section without the key
  local cfg="$TMP/hosts-$1.toml"
  if [[ -n "${2:-}" ]]; then
    printf '[local]\nheavy_max = %s\n' "$2" >"$cfg"
  else
    printf '[local]\nmax_active = 3\n' >"$cfg"
  fi
  printf '%s' "$cfg"
}

CFG0="$(mkconfig zero 0)"
CFG2="$(mkconfig two 2)"
CFGBAD="$(mkconfig bad banana)"
CFGNOKEY="$(mkconfig nokey)"
CFGMISSING="$TMP/absent-hosts.toml"

heavy_run() { # heavy_run <config> -- <cmd...>   (extra env goes on the caller)
  local cfg="$1"; shift
  [[ "${1:-}" == "--" ]] || fail "heavy_run needs --"
  shift
  env WRK_HOSTS_CONFIG="$cfg" "$WRK" heavy -- "$@"
}

# ── limit 0: refuse rc 78, name the host, point at desktop, log it ─────────
printf 'touch "%s"\n' "$TMP/refused-ran" >"$TMP/refused.sh"
rc=0
out="$(WRK_HOSTS_CONFIG="$CFG0" "$WRK" heavy -- bash "$TMP/refused.sh" 2>&1)" || rc=$?
[[ "$rc" -eq 78 ]] || fail "heavy_max=0 must refuse rc 78, got rc=$rc: $out"
grep -q "heavy_max=0" <<<"$out" || fail "refusal must name the config key: $out"
grep -q "$HOSTNAME" <<<"$out" || fail "refusal must name the host: $out"
grep -qi 'desktop' <<<"$out" || fail "refusal must point at desktop: $out"
[[ ! -e "$TMP/refused-ran" ]] || fail "command ran despite heavy_max=0"
# status is never refused: it must still report the effective limit
out="$(WRK_HOSTS_CONFIG="$CFG0" "$WRK" heavy status)" || fail "status refused under heavy_max=0"
grep -q 'limit 0' <<<"$out" || fail "status must show limit 0: $out"
grep -q "host $HOSTNAME" <<<"$out" || fail "status must name the host: $out"
# the refusal lands in the same log the director aggregates
python3 - "$WRK_HEAVY_LOG" "$HOSTNAME" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
r = [r for r in rows if r.get("kind") == "refused"]
assert r, "no refused record logged"
r = r[-1]
assert r["host"] == sys.argv[2], r
assert r["limit"] == 0 and "cmd" in r and "ts" in r, r
PY
# explicit env override is the documented one-invocation escape hatch
WRK_HOSTS_CONFIG="$CFG0" WRK_HEAVY_MAX=1 "$WRK" heavy -- true ||
  fail "WRK_HEAVY_MAX=1 must override a configured 0"
rc=0
out="$(WRK_HOSTS_CONFIG="$CFGMISSING" WRK_HEAVY_MAX=0 "$WRK" heavy -- true 2>&1)" || rc=$?
[[ "$rc" -eq 78 ]] || fail "WRK_HEAVY_MAX=0 must refuse even without config, got rc=$rc"
echo "PASS heavy-limit0-refuses"

# ── invalid limit: refuse rc 78, status stays readable ─────────────────────
rc=0
out="$(WRK_HOSTS_CONFIG="$CFGBAD" "$WRK" heavy -- true 2>&1)" || rc=$?
[[ "$rc" -eq 78 ]] || fail "invalid heavy_max must refuse rc 78, got rc=$rc: $out"
grep -qi 'invalid heavy limit' <<<"$out" || fail "invalid refusal must say why: $out"
out="$(WRK_HOSTS_CONFIG="$CFGBAD" "$WRK" heavy status)" || fail "status must not die on invalid limit"
grep -q 'invalid' <<<"$out" || fail "status must flag the invalid limit: $out"
echo "PASS heavy-limit-invalid-refuses"

# ── limit 1 (default, no key / no file): byte-identical serialization ──────
printf 'touch "%s"\nsleep 3\ntouch "%s"\n' "$TMP/l1-held" "$TMP/l1-done" >"$TMP/l1.sh"
out="$(WRK_HOSTS_CONFIG="$CFGMISSING" "$WRK" heavy status)"
grep -q 'limit 1 (default)' <<<"$out" || fail "unconfigured host must show default 1: $out"
out="$(WRK_HOSTS_CONFIG="$CFGNOKEY" "$WRK" heavy status)"
grep -q 'limit 1' <<<"$out" || fail "config without the key must show default 1: $out"
heavy_run "$CFGMISSING" -- bash "$TMP/l1.sh" &
holder_job=$!
wait_until 10 test -f "$TMP/l1-held" || fail "limit-1 holder never started"
heavy_run "$CFGMISSING" -- test -f "$TMP/l1-done" ||
  fail "limit-1 waiter ran before the holder released"
wait "$holder_job" || fail "limit-1 holder run failed"
echo "PASS heavy-limit1-serializes"

# ── limit 2: two holders overlap, a third queues ───────────────────────────
printf 'touch "%s"\nsleep 4\ntouch "%s"\n' "$TMP/a-start" "$TMP/a-done" >"$TMP/a.sh"
printf 'touch "%s"\nsleep 4\ntouch "%s"\n' "$TMP/b-start" "$TMP/b-done" >"$TMP/b.sh"
heavy_run "$CFG2" -- bash "$TMP/a.sh" &
pa=$!
wait_until 10 test -f "$TMP/a-start" || fail "holder A never started"
heavy_run "$CFG2" -- bash "$TMP/b.sh" &
pb=$!
wait_until 10 test -f "$TMP/b-start" || fail "holder B never started"
# B ran while A still held its slot — real concurrency, not fast serialization
[[ ! -e "$TMP/a-done" ]] || fail "slot-1 run did not overlap the slot-0 holder"
has_waiter() { WRK_HOSTS_CONFIG="$CFG2" "$WRK" heavy status | grep -q '^waiter pid='; }
heavy_run "$CFG2" -- touch "$TMP/c-ran" &
pc=$!
wait_until 10 has_waiter || fail "third run never queued as a waiter"
out="$(WRK_HOSTS_CONFIG="$CFG2" "$WRK" heavy status)"
grep -q 'limit 2' <<<"$out" || fail "status must show limit 2: $out"
grep -q '^holder slot=0 pid=' <<<"$out" || fail "status must name slot 0 holder: $out"
grep -q '^holder slot=1 pid=' <<<"$out" || fail "status must name slot 1 holder: $out"
[[ ! -e "$TMP/c-ran" ]] || fail "waiter ran while every slot was held"
wait "$pa" || fail "holder A failed"
wait "$pb" || fail "holder B failed"
wait "$pc" || fail "queued waiter failed"
[[ -e "$TMP/c-ran" ]] || fail "queued waiter never ran after a slot freed"
echo "PASS heavy-limit2-two-holders"

# ── dead holder: the kernel reclaims its flock slot immediately ────────────
printf 'touch "%s"\nsleep 20\ntouch "%s"\n' "$TMP/h-start" "$TMP/h-done" >"$TMP/h.sh"
printf 'echo $$ >"%s"\ntouch "%s"\nsleep 30\n' "$TMP/h-orphan.pid" "$TMP/k-start" >"$TMP/k.sh"
heavy_run "$CFG2" -- bash "$TMP/h.sh" &
ph=$!
wait_until 10 test -f "$TMP/h-start" || fail "reclaim holder A never started"
heavy_run "$CFG2" -- bash "$TMP/k.sh" &
wait_until 10 test -f "$TMP/k-start" || fail "reclaim holder B never started"
# whichever script took slot1, its wrk python pid is recorded there — kill it
# dead (-9) so no cleanup path runs: only the kernel can free the flock
victim="$(slot_holder_pid "$WRK_HEAVY_LOCK.slot1")"
[[ "$victim" =~ ^[0-9]+$ ]] || fail "no holder recorded in .slot1"
kill -9 "$victim" || fail "could not kill the slot-1 holder"
wait_until 10 pid_dead "$victim" || fail "holder did not die"
# a new run must take the freed slot while the survivor still holds its own
WRK_HEAVY_WAIT_CAP=10 heavy_run "$CFG2" -- touch "$TMP/reclaimed-ran" ||
  fail "dead holder's slot was not reclaimed within the cap"
[[ -e "$TMP/reclaimed-ran" ]] || fail "reclaimed run did not execute"
[[ ! -e "$TMP/h-done" ]] || fail "surviving holder was not still holding its slot"
out="$(WRK_HOSTS_CONFIG="$CFG2" "$WRK" heavy status)"
if [[ "$(grep -cE '^holder (pid=|slot=[0-9]+ )' <<<"$out")" -ne 1 ]]; then
  fail "status must show exactly the surviving holder: $out"
fi
wait "$ph" || fail "surviving holder run failed"
[[ -e "$TMP/h-done" ]] || fail "surviving holder never finished"
echo "PASS heavy-dead-holder-slot-reclaimed"

# ── wait-time log: every acquisition records the aggregation fields ────────
before="$(wc -l <"$WRK_HEAVY_LOG")"
ARBITER_JOB="job-772-test" HK_TASK_ID="772" heavy_run "$CFG2" -- true ||
  fail "logged run failed"
python3 - "$WRK_HEAVY_LOG" "$HOSTNAME" "$before" <<'PY'
import json, sys
path, host, before = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = [json.loads(l) for l in open(path, encoding="utf-8")]
runs = [r for r in rows[before:] if r.get("kind") == "run"]
assert runs, "no run record appended"
r = runs[-1]
for k in ("ts", "kind", "host", "job", "task", "pid", "slot", "limit",
          "cmd", "wait_s", "wait_lock_s", "wait_load_s", "hold_s", "rc"):
    assert k in r, (k, r)
assert r["host"] == host and r["job"] == "job-772-test" and r["task"] == "772", r
assert r["limit"] == 2 and r["slot"] in (0, 1) and r["rc"] == 0, r
assert r["cmd"].endswith("true"), r
assert r["wait_s"] >= 0 and r["hold_s"] >= 0, r
assert r["wait_lock_s"] >= 0 and r["wait_load_s"] >= 0, r
PY
# a run that had to wait logs real wait seconds
printf 'touch "%s"\nsleep 3\n' "$TMP/w-held" >"$TMP/w.sh"
heavy_run "$CFG2" -- bash "$TMP/w.sh" &
pw=$!
wait_until 10 test -f "$TMP/w-held" || fail "logging holder never started"
heavy_run "$CFG2" -- true || fail "waited run failed"
wait "$pw" || fail "logging holder failed"
python3 - "$WRK_HEAVY_LOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
waits = [r["wait_lock_s"] for r in rows if r.get("kind") == "run"]
assert any(w >= 0.4 for w in waits), ("no run logged a real wait", waits)
PY
echo "PASS heavy-log-fields"

# ── assertion-RED mutants over the wrk source ──────────────────────────────
mutant() { # mutant <name> <spec-file>; spec lines are 'OLD => NEW' (first match)
  local name="$1" spec="$2"
  python3 - "$WRK" "$TMP/$name-wrk" "$spec" <<'PY'
import sys
src_path, out_path, spec_path = sys.argv[1:]
src = open(src_path, encoding="utf-8").read()
for i, line in enumerate(open(spec_path, encoding="utf-8").read().splitlines()):
    old, sep, new = line.partition(" => ")
    assert sep, f"spec line {i}: {line!r}"
    assert old in src, f"spec line {i} not found in wrk: {old!r}"
    src = src.replace(old, new, 1)
open(out_path, "w", encoding="utf-8").write(src)
PY
  chmod +x "$TMP/$name-wrk"
}

# each spec anchor must be unique in the source or the first replace hits the
# wrong site
python3 - "$WRK" <<'PY'
src = open(__import__("sys").argv[1], encoding="utf-8").read()
for anchor in (
    "if limit == 0:",
    "for i in range(1, limit)]",
    "    heavy_limit=1",
    '"wait_s": round(run_at - started_at, 3),',
    "                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)",
    "                    fcntl.flock(sfd, fcntl.LOCK_EX | fcntl.LOCK_NB)",
):
    assert src.count(anchor) == 1, (anchor, src.count(anchor))
PY

# mutant norefuse: the heavy_max=0 gate is removed. RED proof: the refused run
# executes under the mutant — the rc-78 assertion is what credits the gate.
printf 'if limit == 0: => if False:\n' >"$TMP/spec-norefuse"
mutant norefuse "$TMP/spec-norefuse"
WRK_HOSTS_CONFIG="$CFG0" "$TMP/norefuse-wrk" heavy -- touch "$TMP/norefuse-ran" ||
  fail "mutant norefuse run failed"
[[ -e "$TMP/norefuse-ran" ]] || fail "mutant norefuse did not run the command"
rm -f "$TMP/norefuse-ran"
echo "PASS mutant-norefuse"

# mutant oneslot: every limit degenerates to the base slot. RED proof: under
# limit 2 the second run must NOT overlap the first holder — it hits the cap.
printf 'for i in range(1, limit)] => for i in range(1, 1)]\n' >"$TMP/spec-oneslot"
mutant oneslot "$TMP/spec-oneslot"
printf 'touch "%s"\nsleep 3\ntouch "%s"\n' "$TMP/m1-held" "$TMP/m1-done" >"$TMP/m1.sh"
WRK_HOSTS_CONFIG="$CFG2" "$TMP/oneslot-wrk" heavy -- bash "$TMP/m1.sh" &
pm=$!
wait_until 10 test -f "$TMP/m1-held" || fail "mutant oneslot holder never started"
set +e
WRK_HEAVY_WAIT_CAP=2 WRK_HOSTS_CONFIG="$CFG2" "$TMP/oneslot-wrk" heavy -- true >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 75 ]] ||
  fail "mutant oneslot let a second holder overlap (rc=$rc) — concurrency assertion is vacuous"
wait "$pm" || fail "mutant oneslot holder failed"
echo "PASS mutant-oneslot"

# mutant deflt2: an unconfigured host silently gets 2 slots — the default-1
# contract and the status line both lie.
printf '    heavy_limit=1 =>     heavy_limit=2\n' >"$TMP/spec-deflt2"
mutant deflt2 "$TMP/spec-deflt2"
out="$(WRK_HOSTS_CONFIG="$CFGMISSING" "$TMP/deflt2-wrk" heavy status)"
grep -q 'limit 2' <<<"$out" ||
  fail "mutant deflt2 still showed limit 1 — default-1 assertion is vacuous"
echo "PASS mutant-deflt2"

# mutant nowaitlog: run records drop wait_s — the aggregation contract the
# director reads silently loses its wait column.
printf '"wait_s": round(run_at - started_at, 3), => \n' >"$TMP/spec-nowaitlog"
mutant nowaitlog "$TMP/spec-nowaitlog"
WRK_HOSTS_CONFIG="$CFGNOKEY" "$TMP/nowaitlog-wrk" heavy -- true ||
  fail "mutant nowaitlog run failed"
python3 - "$WRK_HEAVY_LOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
runs = [r for r in rows if r.get("kind") == "run"]
assert runs and "wait_s" not in runs[-1], \
    "mutant nowaitlog still logged wait_s — field assertion is vacuous"
PY
echo "PASS mutant-nowaitlog"

# mutant blindstatus: the status probe never flocks — every slot reads free,
# so a live holder (or a dead one's stale record) is invisible. RED proof:
# status under a running holder must report 'holder none'.
printf 'fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB) => None\n' >"$TMP/spec-blindstatus"
mutant blindstatus "$TMP/spec-blindstatus"
printf 'touch "%s"\nsleep 5\n' "$TMP/bs-held" >"$TMP/bs.sh"
WRK_HOSTS_CONFIG="$CFG2" "$TMP/blindstatus-wrk" heavy -- bash "$TMP/bs.sh" &
pbs=$!
wait_until 10 test -f "$TMP/bs-held" || fail "mutant blindstatus holder never started"
out="$(WRK_HOSTS_CONFIG="$CFG2" "$TMP/blindstatus-wrk" heavy status)"
if ! grep -q 'holder none' <<<"$out"; then
  fail "mutant blindstatus still saw the live holder — status assertion is vacuous"
fi
kill "$(slot_holder_pid "$WRK_HEAVY_LOCK")" 2>/dev/null || true
wait "$pbs" 2>/dev/null || true
echo "PASS mutant-blindstatus"

# mutant noflock: acquire never flocks — mutual exclusion is gone even at
# limit 1. RED proof: a second run executes while the holder still holds.
printf 'fcntl.flock(sfd, fcntl.LOCK_EX | fcntl.LOCK_NB) => True\n' >"$TMP/spec-noflock"
mutant noflock "$TMP/spec-noflock"
printf 'touch "%s"\nsleep 3\ntouch "%s"\n' "$TMP/nf-held" "$TMP/nf-done" >"$TMP/nf.sh"
WRK_HOSTS_CONFIG="$CFGNOKEY" "$TMP/noflock-wrk" heavy -- bash "$TMP/nf.sh" &
pn=$!
wait_until 10 test -f "$TMP/nf-held" || fail "mutant noflock holder never started"
set +e
WRK_HOSTS_CONFIG="$CFGNOKEY" "$TMP/noflock-wrk" heavy -- test -f "$TMP/nf-done" >/dev/null 2>&1
rc=$?
set -e
# a real flock would have waited out the 3s hold and found nf-done (rc 0);
# the mutant runs immediately and finds nothing (rc 1)
[[ "$rc" -eq 1 ]] ||
  fail "mutant noflock still serialized (rc=$rc) — exclusion assertion is vacuous"
wait "$pn" || fail "mutant noflock holder failed"
echo "PASS mutant-noflock"

echo 'PASS test-wrk-heavy-limit'
