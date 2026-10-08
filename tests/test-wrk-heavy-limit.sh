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

# ── dead holder: the kernel reclaims its flock slot once its tree dies ─────
printf 'touch "%s"\nsleep 20\ntouch "%s"\n' "$TMP/h-start" "$TMP/h-done" >"$TMP/h.sh"
# k.sh execs so the recorded pid is the final command pid holding the slot fd
printf 'echo $$ >"%s"\ntouch "%s"\nexec sleep 30\n' "$TMP/k-cmd.pid" "$TMP/k-start" >"$TMP/k.sh"
heavy_run "$CFG2" -- bash "$TMP/h.sh" &
ph=$!
wait_until 10 test -f "$TMP/h-start" || fail "reclaim holder A never started"
heavy_run "$CFG2" -- bash "$TMP/k.sh" &
wait_until 10 test -f "$TMP/k-start" || fail "reclaim holder B never started"
# holder B deterministically sits in slot1 (A acquires slot0 first — k.sh is
# launched only after h-start). Kill its wrk python dead (-9) so no cleanup
# path runs.
victim="$(slot_holder_pid "$WRK_HEAVY_LOCK.slot1")"
[[ "$victim" =~ ^[0-9]+$ ]] || fail "no holder recorded in .slot1"
kill -9 "$victim" || fail "could not kill the slot-1 holder"
wait_until 10 pid_dead "$victim" || fail "holder did not die"
# under the nested-fd contract the command inherits the slot fd: the dead
# holder's slot stays held while its orphaned command lives — a fresh run
# must still cap out.
set +e
out="$(WRK_HEAVY_WAIT_CAP=3 heavy_run "$CFG2" -- touch "$TMP/early-ran" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 75 && ! -e "$TMP/early-ran" ]] ||
  fail "dead holder's slot freed while its orphaned command still lived (rc=$rc): $out"
# kill the orphan tree — only then does the kernel release the slot fd.
orphan="$(cat "$TMP/k-cmd.pid")"
kill -9 "$orphan" || fail "could not kill the orphaned command"
wait_until 10 pid_dead "$orphan" || fail "orphaned command did not die"
# a new run must take the freed slot while the survivor still holds its own
WRK_HEAVY_WAIT_CAP=10 heavy_run "$CFG2" -- touch "$TMP/reclaimed-ran" ||
  fail "dead holder's slot was not reclaimed once its tree died"
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

# ── nested detection: real runs bypass, every forgery does not ────────────
# WRK_HEAVY_HELD pid text and held-slot file text are both caller-writable —
# nested detection must ignore them entirely (#772 tester r1-r2).
printf 'pid=%d since=x job=- cmd=forged\n' $$ >"$WRK_HEAVY_LOCK"
set +e
out="$(WRK_HEAVY_HELD="$WRK_HEAVY_LOCK:$$" heavy_run "$CFGNOKEY" -- touch "$TMP/forge-ran" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 && -e "$TMP/forge-ran" ]] || fail "forged-env run failed: rc=$rc $out"
! grep -q 'already holding' <<<"$out" ||
  fail "slot text + live ancestor pid triggered the nested path: $out"
python3 - "$WRK_HEAVY_LOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
runs = [r for r in rows if r.get("kind") == "run" and "forge-ran" in r.get("cmd", "")]
assert runs, "forged-env run bypassed acquisition logging"
PY
# the r2 held-slot attack: rewrite a genuinely flock-held slot's pid= text
# to this process's pid while forging the env — must still queue.
printf 'touch "%s"\nsleep 30\n' "$TMP/rh-held" >"$TMP/rh.sh"
heavy_run "$CFGNOKEY" -- bash "$TMP/rh.sh" &
prh=$!
wait_until 10 test -f "$TMP/rh-held" || fail "real holder never started"
rp="$(slot_holder_pid "$WRK_HEAVY_LOCK")"
[[ "$rp" =~ ^[0-9]+$ ]] || fail "no holder pid recorded in held slot"
set +e
out="$(WRK_HEAVY_HELD="$WRK_HEAVY_LOCK:$rp" WRK_HEAVY_WAIT_CAP=2 \
  heavy_run "$CFGNOKEY" -- touch "$TMP/rh-forged" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "forged held-pid bypassed the slot queue (rc=$rc): $out"
[[ ! -e "$TMP/rh-forged" ]] || fail "forged run executed while the slot was held"
! grep -q 'already holding' <<<"$out" ||
  fail "non-ancestor holder pid triggered the nested path: $out"
# rewrite the HELD slot's pid= text to this pid and forge the env — the r2
# bypass: held-text + ancestor used to pass. fd proof makes both irrelevant.
python3 - "$WRK_HEAVY_LOCK" <<PY
import re, sys
p = sys.argv[1]
open(p, "w").write(re.sub(r"pid=\\d+", "pid=%d" % $$, open(p).read()))
PY
set +e
out="$(WRK_HEAVY_HELD="$WRK_HEAVY_LOCK:$$" WRK_HEAVY_WAIT_CAP=2 \
  heavy_run "$CFGNOKEY" -- touch "$TMP/hh-ran" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 75 ]] || fail "held-slot pid rewrite bypassed the queue (rc=$rc): $out"
[[ ! -e "$TMP/hh-ran" ]] || fail "held-slot pid rewrite ran over the limit"
! grep -q 'already holding' <<<"$out" ||
  fail "rewritten held-slot pid triggered the nested path: $out"
# forge WRK_HEAVY_HELD_FD with a fresh-open fd on the held slot file — the
# fd names the right inode but sits on a different OFD, so the relock must
# fail and the run must queue.
exec 9<>"$WRK_HEAVY_LOCK"
set +e
out="$(WRK_HEAVY_HELD_FD="9:$WRK_HEAVY_LOCK" WRK_HEAVY_WAIT_CAP=2 \
  heavy_run "$CFGNOKEY" -- touch "$TMP/fd-ran" 2>&1)"
rc=$?
set -e
exec 9>&-
[[ "$rc" -eq 75 ]] || fail "forged slot fd bypassed the queue (rc=$rc): $out"
[[ ! -e "$TMP/fd-ran" ]] || fail "forged slot fd ran over the limit"
! grep -q 'already holding' <<<"$out" ||
  fail "fresh-open slot fd triggered the nested path: $out"
# phantom slots: a self-flocked caller-made .slotN that wrk never minted (or
# that sits outside the current limit, including .slot0 which is always the
# base file) must not satisfy the nested proof — the run must queue on the
# real slots instead.
python3 - "$WRK_HEAVY_LOCK" "$CFGNOKEY" "$WRK" "$TMP" <<'PY'
import fcntl, os, subprocess, sys
lock, cfg, wrk, tmp = sys.argv[1:]
env = dict(os.environ, WRK_HOSTS_CONFIG=cfg, WRK_HEAVY_WAIT_CAP="2")
for i, ghost in enumerate((lock + ".slot0", lock + ".slot5")):
    fd = os.open(ghost, os.O_RDWR | os.O_CREAT, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)
    m = os.path.join(tmp, "phantom%d-ran" % i)
    r = subprocess.run([wrk, "heavy", "--", "touch", m],
                       env=dict(env, WRK_HEAVY_HELD_FD="%d:%s" % (fd, ghost)),
                       pass_fds={fd}, capture_output=True, text=True)
    assert r.returncode == 75 and not os.path.exists(m), \
        ("phantom slot %s bypassed the queue" % ghost, r.returncode, r.stderr)
    assert "already holding" not in r.stderr, r.stderr
    os.close(fd)
    os.unlink(ghost)
PY
# residual (accepted, documented): a same-uid caller can rename the live
# slot inode away and self-lock a replacement at the same path — the
# pre-existing N1 namespace-split hazard, not a nested-check defect. The
# forged child then legitimately holds a lock on that path, so nested is
# honored — but the run can no longer evade aggregation: it is logged as a
# kind=nested record.
d="$TMP/r3"; mkdir -p "$d"; RL="$d/lock"; RLOG="$d/log"; : >"$RLOG"
printf '0\n' >"$d/load"
python3 - "$RL" "$CFGNOKEY" "$WRK" "$TMP/r3-ran" "$RLOG" "$d/load" <<'PY'
import fcntl, json, os, subprocess, sys, time
lock, cfg, wrk, marker, log, load = sys.argv[1:]
env = dict(os.environ, WRK_HEAVY_LOCK=lock, WRK_HOSTS_CONFIG=cfg,
           WRK_HEAVY_LOG=log, WRK_HEAVY_LOAD_FILE=load, WRK_HEAVY_WAIT_CAP="2")
holder = subprocess.Popen([wrk, "heavy", "--", "sh", "-c", "sleep 6"],
                          env=env, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL)
time.sleep(1.0)
orig = os.open(lock, os.O_RDWR)
os.rename(lock, lock + ".stolen")
os.close(orig)
fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
r = subprocess.run([wrk, "heavy", "--", "touch", marker],
                   env=dict(env, WRK_HEAVY_HELD_FD="%d:%s" % (fd, lock)),
                   pass_fds={fd}, capture_output=True, text=True)
assert holder.poll() is None, "holder exited early"
assert os.path.exists(marker) and "already holding" in r.stderr, \
    ("expected nested run on the replacement inode", r.returncode, r.stderr)
os.close(fd)
holder.wait()
rows = [json.loads(x) for x in open(log)]
nested = [x for x in rows if x.get("kind") == "nested"
          and marker in x.get("cmd", "")]
assert nested, "the namespace-split run escaped aggregation logging"
PY
[[ -e "$TMP/r3-ran" ]] || fail "namespace-split nested run did not execute"
# hostile PATH: a fake `ps` earlier in PATH must not matter — detection is a
# kernel fd check, and a real nested run still takes the nested path.
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\necho forged >&2\nexit 1\n' >"$TMP/fakebin/ps"
printf '#!/bin/sh\nexit 1\n' >"$TMP/fakebin/lsof"
chmod +x "$TMP/fakebin/ps" "$TMP/fakebin/lsof"
set +e
out="$(heavy_run "$CFGNOKEY" -- \
  env PATH="$TMP/fakebin:$PATH" "$WRK" heavy -- touch "$TMP/nested-ran" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 && -e "$TMP/nested-ran" ]] || fail "real nested run failed: rc=$rc $out"
grep -q 'already holding' <<<"$out" ||
  fail "real nested run did not take the nested path under hostile PATH: $out"
wait "$prh" || fail "real holder run failed"
echo "PASS heavy-held-forged-not-nested"

# ── #1241 heavy_load_wait: per-host switch for the post-slot load gate ────
# [local] heavy_load_wait rides the same strict scanner as [local] spawn:
# absent or true is exactly today's wait; false skips ONLY the load wait
# (the heavy_max slot, its lock, nice -n 10 and the wait cap are
# unchanged); every malformed spelling refuses rc 70 before a slot is
# taken or the command runs.
hlw_cfg() { # hlw_cfg <name> <toml-line>... — writes the lines under [local]
  local cfg="$TMP/hlw-$1.toml"; shift
  { printf '[local]\n'; printf '%s\n' "$@"; } >"$cfg"
  printf '%s' "$cfg"
}
CFGHLW_ON="$(hlw_cfg on 'heavy_load_wait = true')"
CFGHLW_OFF="$(hlw_cfg off 'heavy_load_wait = false')"
# CFGHLW_OFF is deliberately the addendum file: a [local] section with ONLY
# 'heavy_load_wait = false' — no [hosts.*], no [hub] — what desk writes on
# M1. CFGMISSING (no file at all) is the pre-desk state.
printf '1.5\n' >"$WRK_HEAVY_LOAD_FILE"

# AC1+AC2+addendum-A: no file, a [local] without the key and '= true' are
# byte-identical to main — the run waits on load5/ncpu and expires rc 75 at
# the cap without running.
for hlw_cfgf in "$CFGMISSING" "$CFGNOKEY" "$CFGHLW_ON"; do
  rm -f "$TMP/hlw-ran"
  set +e
  out="$(WRK_HEAVY_WAIT_CAP=3 heavy_run "$hlw_cfgf" -- touch "$TMP/hlw-ran" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 75 ]] ||
    fail "1241 AC1/2 ($hlw_cfgf): the load wait must expire rc 75, got rc=$rc: $out"
  grep -q 'waiting for load5/ncpu 1.50 < 1.0' <<<"$out" ||
    fail "1241 AC1/2 ($hlw_cfgf): expiry must name the load wait: $out"
  [[ ! -e "$TMP/hlw-ran" ]] ||
    fail "1241 AC1/2 ($hlw_cfgf): command ran despite the load wait"
done
# the cap records prove all three runs died on the LOAD phase, not the slot
python3 - "$WRK_HEAVY_LOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
caps = [r for r in rows[-3:]
        if r.get("kind") == "wait_cap" and r.get("phase") == "load"]
assert len(caps) == 3, ("expected three phase=load wait_cap records", rows[-3:])
PY
echo "PASS heavy-load-wait-absent-and-true"

# AC3a: '= false' skips only the load wait — the command runs at once at
# ratio 1.5, still inside a held slot and still under nice -n 10.
printf 'ps -o nice= -p $$ | tr -d " " > "%s"\nsleep 4\ntouch "%s"\n' \
  "$TMP/hlw-nice.val" "$TMP/hlw-off-ran" >"$TMP/hlw-off.sh"
t0="$(date +%s)"
WRK_HEAVY_WAIT_CAP=8 heavy_run "$CFGHLW_OFF" -- bash "$TMP/hlw-off.sh" &
poff=$!
wait_until 10 test -f "$TMP/hlw-nice.val" ||
  fail "1241 AC3: the load_wait=false run never started"
out="$(WRK_HOSTS_CONFIG="$CFGHLW_OFF" "$WRK" heavy status)"
grep -qE '^holder (slot=[0-9]+ )?pid=' <<<"$out" ||
  fail "1241 AC3: no slot is held during the off run: $out"
grep -q 'load_wait false' <<<"$out" ||
  fail "1241 AC3: status must show load_wait false: $out"
grep -q 'limit 1 (default)' <<<"$out" ||
  fail "1241 AC3/C: the [local]-only file must keep the heavy_max default 1: $out"
wait "$poff" || fail "1241 AC3: the load_wait=false run failed"
[[ -e "$TMP/hlw-off-ran" ]] || fail "1241 AC3: the command did not run"
elapsed=$(( $(date +%s) - t0 ))
[[ "$elapsed" -lt 8 ]] ||
  fail "1241 AC3: run took ${elapsed}s at ratio 1.5 — the load wait was not skipped"
read -r nv <"$TMP/hlw-nice.val" || nv=""
suite_nice="$(ps -o nice= -p "$$" | tr -d ' ')"
nice_probe="$(nice -n 10 sh -c 'ps -o nice= -p $$' 2>/dev/null | tr -d ' ')"
nice_ceiling="$(nice -n 40 sh -c 'ps -o nice= -p $$' 2>/dev/null | tr -d ' ')"
if [[ "$suite_nice" =~ ^[0-9]+$ && "$nice_probe" =~ ^[0-9]+$ &&
      "$nice_ceiling" =~ ^[0-9]+$ && "$nice_probe" -gt "$suite_nice" ]]; then
  expected=$(( suite_nice + 10 ))
  (( expected > nice_ceiling )) && expected="$nice_ceiling"
  [[ "$nv" =~ ^[0-9]+$ && "$nv" -ge "$expected" ]] ||
    fail "1241 AC3: command not under nice -n 10 (suite=$suite_nice got=$nv want>=$expected)"
else
  echo "SKIP 1241 nice assertion: nice(1) has no observable effect here"
fi
echo "PASS heavy-load-wait-off-runs-under-load"

# addendum C: the [local]-only file runs at once at the M1-class load ratio
# 3.2 too — the gate is off, not relaxed.
printf '3.2\n' >"$WRK_HEAVY_LOAD_FILE"
t0="$(date +%s)"
WRK_HEAVY_WAIT_CAP=8 heavy_run "$CFGHLW_OFF" -- touch "$TMP/hlw-32-ran" ||
  fail "1241 C: the [local]-only file must run at once at ratio 3.2"
[[ -e "$TMP/hlw-32-ran" ]] || fail "1241 C: the command never ran"
[[ $(( $(date +%s) - t0 )) -lt 8 ]] ||
  fail "1241 C: the run waited on load at ratio 3.2"
echo "PASS heavy-load-wait-off-ratio-3.2"

# AC3b: 'false' still respects the slot — with the base slot held the run
# queues on the LOCK (never the load) and expires rc 75 at the cap.
printf 'touch "%s"\nsleep 5\n' "$TMP/hlw-holder-start" >"$TMP/hlw-holder.sh"
heavy_run "$CFGHLW_OFF" -- bash "$TMP/hlw-holder.sh" &
phold=$!
wait_until 10 test -f "$TMP/hlw-holder-start" ||
  fail "1241 AC3: the slot holder never started"
set +e
out="$(WRK_HEAVY_WAIT_CAP=2 heavy_run "$CFGHLW_OFF" -- touch "$TMP/hlw-slot-ran" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 75 ]] ||
  fail "1241 AC3: the slot wait under load_wait=false must expire rc 75, got rc=$rc: $out"
grep -q 'waiting for a heavy slot' <<<"$out" ||
  fail "1241 AC3: expiry must name the slot wait, not the load wait: $out"
[[ ! -e "$TMP/hlw-slot-ran" ]] || fail "1241 AC3: command ran over a held slot"
python3 - "$WRK_HEAVY_LOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
caps = [r for r in rows if r.get("kind") == "wait_cap"]
assert caps and caps[-1]["phase"] == "slot", \
    ("the off run must cap on the slot phase", caps[-1] if caps else "none")
PY
wait "$phold" || fail "1241 AC3: the slot holder failed"
echo "PASS heavy-load-wait-off-still-takes-a-slot"

# AC3c (r2, B1): a slot granted AFTER the total cap must still refuse —
# the flock pass that wins never re-checks the deadline, and with the load
# wait off no second gate existed. A held slot released past a tiny cap:
# whichever gate catches it, the contract is identical — rc 75, the slot
# wait message, the command never run, exactly one phase=slot wait_cap row.
printf '3.2\n' >"$WRK_HEAVY_LOAD_FILE"
printf 'touch "%s"\nsleep 0.8\n' "$TMP/hlw-late-held" >"$TMP/hlw-late-holder.sh"
heavy_run "$CFGHLW_OFF" -- bash "$TMP/hlw-late-holder.sh" &
plate=$!
wait_until 10 test -f "$TMP/hlw-late-held" ||
  fail "1241 r2 AC3c: the late-release holder never started"
log_rows_before=$(wc -l <"$WRK_HEAVY_LOG")
set +e
out="$(WRK_HEAVY_WAIT_CAP=0.25 heavy_run "$CFGHLW_OFF" -- touch "$TMP/hlw-late-ran" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 75 ]] ||
  fail "1241 r2 AC3c: a post-cap slot grant must refuse rc=75, got rc=$rc: $out"
grep -q 'waiting for a heavy slot' <<<"$out" ||
  fail "1241 r2 AC3c: expiry must name the slot wait: $out"
[[ ! -e "$TMP/hlw-late-ran" ]] ||
  fail "1241 r2 AC3c: the command ran on a slot granted after the cap"
python3 - "$WRK_HEAVY_LOG" "$log_rows_before" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
new = rows[int(sys.argv[2]):]
caps = [r for r in new if r.get("kind") == "wait_cap"]
assert len(caps) == 1 and caps[0]["phase"] == "slot", \
    ("the late grant must log exactly one phase=slot wait_cap", new)
PY
wait "$plate" || fail "1241 r2 AC3c: the late-release holder failed"
echo "PASS heavy-load-wait-off-late-slot-refuses-75"

# AC3d (r2 boundary): the release-right-at-cap edge pinned deterministically —
# WRK_HEAVY_WAIT_CAP=0 makes the deadline precede any acquisition, so even a
# free slot granted on the first poll arrives "after the cap": only the
# post-acquire gate can catch it (the slot loop never checks on a winning
# pass, and the load wait is off). Under 'true'/absent the load loop is the
# only post-acquire gate — cap 0 with an idle load still runs, exactly as
# main does, so both stay byte-identical.
printf '0\n' >"$WRK_HEAVY_LOAD_FILE"
log_rows_before=$(wc -l <"$WRK_HEAVY_LOG")
set +e
out="$(WRK_HEAVY_WAIT_CAP=0 heavy_run "$CFGHLW_OFF" -- touch "$TMP/hlw-cap0-ran" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 75 ]] ||
  fail "1241 r2 AC3d: a load-off run must never start after the cap, got rc=$rc: $out"
grep -q 'waiting for a heavy slot' <<<"$out" ||
  fail "1241 r2 AC3d: the post-cap refusal must name the slot wait: $out"
[[ ! -e "$TMP/hlw-cap0-ran" ]] ||
  fail "1241 r2 AC3d: the command ran at cap 0 with the load wait off"
python3 - "$WRK_HEAVY_LOG" "$log_rows_before" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
new = rows[int(sys.argv[2]):]
caps = [r for r in new if r.get("kind") == "wait_cap"]
assert len(caps) == 1 and caps[0]["phase"] == "slot", \
    ("cap-0 admission must log exactly one phase=slot wait_cap", new)
PY
for hlw_cfgf in "$CFGMISSING" "$CFGHLW_ON"; do
  rm -f "$TMP/hlw-cap0-on-ran"
  WRK_HEAVY_WAIT_CAP=0 heavy_run "$hlw_cfgf" -- touch "$TMP/hlw-cap0-on-ran" ||
    fail "1241 r2 AC3d ($hlw_cfgf): load-wait-on must stay main-identical — the load loop is the only post-acquire gate at cap 0"
  [[ -e "$TMP/hlw-cap0-on-ran" ]] ||
    fail "1241 r2 AC3d ($hlw_cfgf): the load-wait-on run at cap 0 must run like main"
done
echo "PASS heavy-load-wait-cap0-boundary-and-on-unchanged"

# AC4: every malformed spelling of the key — and any malformed [local]
# surface — refuses rc 70 naming the file line, before a slot is taken or
# the command runs.
for hlw_bad in value-quoted value-case value-int value-empty key-twice \
    key-bare key-colon key-eqeq key-quoted hdr-comment; do
  hlw_hdr='[local]' hlw_body='heavy_load_wait = false'
  case "$hlw_bad" in
    value-quoted) hlw_body='heavy_load_wait = "false"'
      hlw_want='accepts only the bare TOML booleans true or false' ;;
    value-case)   hlw_body='heavy_load_wait = False'
      hlw_want='accepts only the bare TOML booleans true or false' ;;
    value-int)    hlw_body='heavy_load_wait = 0'
      hlw_want='accepts only the bare TOML booleans true or false' ;;
    value-empty)  hlw_body='heavy_load_wait ='
      hlw_want='accepts only the bare TOML booleans true or false' ;;
    key-twice)    hlw_body='heavy_load_wait = true
heavy_load_wait = false'
      hlw_want='duplicate heavy_load_wait key in [local]' ;;
    key-bare|key-colon|key-eqeq|key-quoted)
      hlw_want='malformed heavy_load_wait assignment in [local]'
      case "$hlw_bad" in
        key-bare)   hlw_body='heavy_load_wait' ;;
        key-colon)  hlw_body='heavy_load_wait: false' ;;
        key-eqeq)   hlw_body='heavy_load_wait == false' ;;
        key-quoted) hlw_body='"heavy_load_wait" = false' ;;
      esac ;;
    hdr-comment)  hlw_hdr='[local] # closed by ops'
      hlw_want="must be exactly '[local]' on its own line" ;;
  esac
  hlw_badcfg="$TMP/hlw-bad-$hlw_bad.toml"
  printf '%s\n' "$hlw_hdr" "$hlw_body" >"$hlw_badcfg"
  rm -f "$TMP/hlw-bad-ran"
  set +e
  out="$(heavy_run "$hlw_badcfg" -- touch "$TMP/hlw-bad-ran" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 70 ]] ||
    fail "1241 AC4 $hlw_bad: malformed heavy_load_wait must refuse rc=70, got rc=$rc: $out"
  grep -q 'line [0-9]' <<<"$out" ||
    fail "1241 AC4 $hlw_bad: the refusal must name the file line: $out"
  grep -qF "$hlw_want" <<<"$out" ||
    fail "1241 AC4 $hlw_bad: wrong refusal reason: $out"
  grep -qF 'refusing heavy run' <<<"$out" ||
    fail "1241 AC4 $hlw_bad: refusal must come from the bash gate before python runs: $out"
  [[ ! -e "$TMP/hlw-bad-ran" ]] ||
    fail "1241 AC4 $hlw_bad: the command ran despite the refusal"
done
# nothing took a slot or queued for any of those refusals
out="$(WRK_HOSTS_CONFIG="$CFGNOKEY" "$WRK" heavy status)"
grep -q 'holder none' <<<"$out" ||
  fail "1241 AC4: a refused run left a slot held: $out"
grep -q 'waiters none' <<<"$out" ||
  fail "1241 AC4: a refused run left a waiter behind: $out"
# rc 70 vs 78: a malformed [local] refuses before heavy_max is validated;
# a clean [local] with a bad heavy_max still refuses 78, and the
# heavy_max=0 gate is untouched by the switch.
printf '[local]\nheavy_load_wait = bogus\nheavy_max = banana\n' >"$TMP/hlw-both-bad.toml"
set +e
out="$(heavy_run "$TMP/hlw-both-bad.toml" -- true 2>&1)"; rc=$?
set -e
[[ "$rc" -eq 70 ]] ||
  fail "1241 AC4: the scan refusal must precede the heavy_max check, got rc=$rc: $out"
printf '[local]\nheavy_load_wait = false\nheavy_max = 0\n' >"$TMP/hlw-off-zero.toml"
set +e
out="$(heavy_run "$TMP/hlw-off-zero.toml" -- true 2>&1)"; rc=$?
set -e
[[ "$rc" -eq 78 ]] ||
  fail "1241 AC4: heavy_max=0 must still refuse rc 78 under load_wait=false, got rc=$rc: $out"
echo "PASS heavy-load-wait-bad-refuses-70"

# AC5: wrk hosts and wrk heavy status report true/false/error — and stay
# rc 0 on a scan error (reporting commands).
for hlw_state in absent true false error; do
  hlw_want="$hlw_state"
  case "$hlw_state" in
    absent) hlw_cfgf="$CFGMISSING" hlw_want=true ;;
    true)   hlw_cfgf="$CFGHLW_ON" ;;
    false)  hlw_cfgf="$CFGHLW_OFF" ;;
    error)  hlw_cfgf="$TMP/hlw-bad-value-quoted.toml" ;;
  esac
  out="$(WRK_HOSTS_CONFIG="$hlw_cfgf" "$WRK" hosts)" ||
    fail "1241 AC5: wrk hosts must stay rc 0 (state=$hlw_state)"
  if [[ "$hlw_state" == error ]]; then
    grep -qF 'local heavy_load_wait=error (' <<<"$out" ||
      fail "1241 AC5: hosts must print =error (...): $out"
    grep -qF 'local spawn=error (' <<<"$out" ||
      fail "1241 AC5: the one scan error must show on the spawn line too: $out"
  else
    grep -qxF "local heavy_load_wait=$hlw_want" <<<"$out" ||
      fail "1241 AC5: hosts must print 'local heavy_load_wait=$hlw_want' (state=$hlw_state): $out"
  fi
  out="$(WRK_HOSTS_CONFIG="$hlw_cfgf" "$WRK" heavy status)" ||
    fail "1241 AC5: wrk heavy status must stay rc 0 (state=$hlw_state)"
  case "$hlw_state" in
    error)
      grep -qF 'load_wait error (' <<<"$out" ||
        fail "1241 AC5: status must print 'load_wait error (...)': $out" ;;
    absent|true)
      grep -qF 'load_wait true ' <<<"$out" ||
        fail "1241 AC5: status must print 'load_wait true': $out" ;;
    false)
      grep -qF 'load_wait false ' <<<"$out" ||
        fail "1241 AC5: status must print 'load_wait false': $out" ;;
  esac
done
echo "PASS heavy-load-wait-hosts-and-status"

printf '0\n' >"$WRK_HEAVY_LOAD_FILE"

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
    "        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)",
    "                    fcntl.flock(sfd, fcntl.LOCK_EX | fcntl.LOCK_NB)",
    "fcntl.flock(env_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)",
    "    if not flock_held(env_path):",
    "    if (fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino):",
    "not 0 < int(m.group(1)) < limit",
    "    while load_wait:",
    "    if not load_wait and acquired_at >= deadline:",
    '             return "$WRK_EXIT_CONFIG_REFUSED" ;;',
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

# mutant norelock: the relock proof is skipped — any fd on the held slot
# file counts as inherited. RED proof: the fresh-open forged-fd attack from
# the fixed test must take the nested path under the mutant.
printf 'fcntl.flock(env_fd, fcntl.LOCK_EX | fcntl.LOCK_NB) => None\n' \
  >"$TMP/spec-norelock"
mutant norelock "$TMP/spec-norelock"
printf 'touch "%s"\nsleep 5\n' "$TMP/nr-held" >"$TMP/nr.sh"
WRK_HOSTS_CONFIG="$CFGNOKEY" "$TMP/norelock-wrk" heavy -- bash "$TMP/nr.sh" &
pnr=$!
wait_until 10 test -f "$TMP/nr-held" || fail "mutant norelock holder never started"
exec 9<>"$WRK_HEAVY_LOCK"
set +e
out="$(WRK_HEAVY_HELD_FD="9:$WRK_HEAVY_LOCK" WRK_HEAVY_WAIT_CAP=2 \
  WRK_HOSTS_CONFIG="$CFGNOKEY" "$TMP/norelock-wrk" heavy -- touch "$TMP/nr-ran" 2>&1)"
rc=$?
set -e
exec 9>&-
[[ "$rc" -eq 0 && -e "$TMP/nr-ran" ]] ||
  fail "mutant norelock forged fd did not bypass (rc=$rc): $out"
grep -q 'already holding' <<<"$out" ||
  fail "mutant norelock still relocked the fd — relock assertion is vacuous"
wait "$pnr" || fail "mutant norelock holder failed"
echo "PASS mutant-norelock"

# mutant noheldcheck: the slot-held gate is skipped — any unlocked fd on the
# slot path forges nesting with no holder at all. RED proof: a self-opened
# fd on a FREE lock takes the nested path under the mutant.
printf '    if not flock_held(env_path): =>     if False:\n' \
  >"$TMP/spec-noheldcheck"
mutant noheldcheck "$TMP/spec-noheldcheck"
python3 - "$WRK_HEAVY_LOCK" "$CFGNOKEY" "$TMP/noheldcheck-wrk" \
  "$TMP/nh-ran" <<'PY'
import os, subprocess, sys
lock, cfg, wrk, marker = sys.argv[1:]
fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o644)  # unlocked fd
r = subprocess.run([wrk, "heavy", "--", "touch", marker],
                   env=dict(os.environ,
                            WRK_HEAVY_HELD_FD="%d:%s" % (fd, lock),
                            WRK_HOSTS_CONFIG=cfg),
                   pass_fds={fd}, capture_output=True, text=True)
assert r.returncode == 0 and "already holding" in r.stderr, \
    "mutant noheldcheck still checked the slot — gate assertion is vacuous"
os.close(fd)
PY
[[ -e "$TMP/nh-ran" ]] || fail "mutant noheldcheck nested run did not execute"
echo "PASS mutant-noheldcheck"

# mutant nodevino: the fd's inode is never matched to the slot path — any
# file the caller holds satisfies the slot path it names. RED proof: a fd
# on a caller-locked file plus the real lock path must take the nested path.
printf '    if (fst.st_dev, fst.st_ino) != (lst.st_dev, lst.st_ino): =>     if False:\n' \
  >"$TMP/spec-nodevino"
mutant nodevino "$TMP/spec-nodevino"
printf 'touch "%s"\nsleep 5\n' "$TMP/nd-held" >"$TMP/nd.sh"
WRK_HOSTS_CONFIG="$CFGNOKEY" "$TMP/nodevino-wrk" heavy -- bash "$TMP/nd.sh" &
pnd=$!
wait_until 10 test -f "$TMP/nd-held" || fail "mutant nodevino holder never started"
python3 - "$TMP/ownproof" "$WRK_HEAVY_LOCK" "$CFGNOKEY" \
  "$TMP/nodevino-wrk" "$TMP/nd-ran" <<'PY'
import fcntl, os, subprocess, sys
own, lock, cfg, wrk, marker = sys.argv[1:]
fd = os.open(own, os.O_RDWR | os.O_CREAT, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)  # the caller's own lock — not the slot's
r = subprocess.run([wrk, "heavy", "--", "touch", marker],
                   env=dict(os.environ,
                            WRK_HEAVY_HELD_FD="%d:%s" % (fd, lock),
                            WRK_HOSTS_CONFIG=cfg, WRK_HEAVY_WAIT_CAP="2"),
                   pass_fds={fd}, capture_output=True, text=True)
assert r.returncode == 0 and "already holding" in r.stderr, \
    "mutant nodevino still checked the inode — ino assertion is vacuous"
os.close(fd)
PY
[[ -e "$TMP/nd-ran" ]] || fail "mutant nodevino nested run did not execute"
kill "$(slot_holder_pid "$WRK_HEAVY_LOCK")" 2>/dev/null || true
wait "$pnd" 2>/dev/null || true
echo "PASS mutant-nodevino"

# mutant noslotbound: the slot-index bound is skipped — a caller-minted
# .slotN outside the current limit satisfies the env path again. RED proof:
# the phantom-slot probe from the fixed test takes the nested path.
printf 'not 0 < int(m.group(1)) < limit => False\n' >"$TMP/spec-noslotbound"
mutant noslotbound "$TMP/spec-noslotbound"
python3 - "$WRK_HEAVY_LOCK" "$CFGNOKEY" "$TMP/noslotbound-wrk" \
  "$TMP/nb-ran" <<'PY'
import fcntl, os, subprocess, sys
lock, cfg, wrk, marker = sys.argv[1:]
ghost = lock + ".slot5"  # never minted under limit=1
fd = os.open(ghost, os.O_RDWR | os.O_CREAT, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
r = subprocess.run([wrk, "heavy", "--", "touch", marker],
                   env=dict(os.environ,
                            WRK_HEAVY_HELD_FD="%d:%s" % (fd, ghost),
                            WRK_HOSTS_CONFIG=cfg),
                   pass_fds={fd}, capture_output=True, text=True)
assert r.returncode == 0 and "already holding" in r.stderr, \
    "mutant noslotbound still bounded the slot — assertion is vacuous"
os.close(fd)
os.unlink(ghost)
PY
[[ -e "$TMP/nb-ran" ]] || fail "mutant noslotbound nested run did not execute"
echo "PASS mutant-noslotbound"

# ── #1241 mutants: the heavy_load_wait invariants ─────────────────────────
# M1 "heavy_load_wait = false never waits on load" — the mutant restores
# `while True:` (ignores the key): the AC3a run-at-once assertion goes RED
# because the off-config run waits out the cap at ratio 1.5.
printf '    while load_wait: =>     while True:\n' >"$TMP/spec-hlw-ignore"
mutant hlwignore "$TMP/spec-hlw-ignore"
printf '1.5\n' >"$WRK_HEAVY_LOAD_FILE"
# a fresh lock path: earlier mutants leave orphaned command children whose
# inherited slot fds still hold $WRK_HEAVY_LOCK for a few seconds
set +e
out="$(WRK_HEAVY_WAIT_CAP=2 WRK_HEAVY_LOCK="$TMP/hlw-m1.lock" \
  WRK_HOSTS_CONFIG="$CFGHLW_OFF" \
  "$TMP/hlwignore-wrk" heavy -- touch "$TMP/hlw-m1-ran" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 75 && ! -e "$TMP/hlw-m1-ran" ]] ||
  fail "mutant hlwignore did not wait on load (rc=$rc) — the AC3a assertion is vacuous"
grep -q 'load5/ncpu' <<<"$out" ||
  fail "mutant hlwignore expiry must still name the load wait: $out"
echo "PASS mutant-hlw-ignore-key: 'false never waits on load' RED — AC3a 'runs at once' fails (rc=75, command not run)"

# M2 "heavy_load_wait = false still respects heavy_max slots" — the mutant
# skips the flock when the wait is off: the AC3b slot-cap assertion goes
# RED because a second off run executes over the held slot.
printf 'fcntl.flock(sfd, fcntl.LOCK_EX | fcntl.LOCK_NB) => (fcntl.flock(sfd, fcntl.LOCK_EX | fcntl.LOCK_NB) if load_wait else None)\n' \
  >"$TMP/spec-hlw-noslot"
mutant hlwnoslot "$TMP/spec-hlw-noslot"
printf 'touch "%s"\nsleep 4\n' "$TMP/hlw-m2-held" >"$TMP/hlw-m2.sh"
WRK_HEAVY_LOCK="$TMP/hlw-m2.lock" WRK_HOSTS_CONFIG="$CFGHLW_OFF" \
  "$TMP/hlwnoslot-wrk" heavy -- bash "$TMP/hlw-m2.sh" &
pm2=$!
wait_until 10 test -f "$TMP/hlw-m2-held" ||
  fail "mutant hlwnoslot holder never started"
set +e
out="$(WRK_HEAVY_WAIT_CAP=2 WRK_HEAVY_LOCK="$TMP/hlw-m2.lock" \
  WRK_HOSTS_CONFIG="$CFGHLW_OFF" \
  "$TMP/hlwnoslot-wrk" heavy -- touch "$TMP/hlw-m2-ran" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 && -e "$TMP/hlw-m2-ran" ]] ||
  fail "mutant hlwnoslot still queued on the held slot (rc=$rc): $out — the AC3b assertion is vacuous"
wait "$pm2" || fail "mutant hlwnoslot holder failed"
echo "PASS mutant-hlw-noslot: 'false still respects slots' RED — AC3b 'expires rc 75' fails (rc=0, ran over the held slot)"

# M3 "a bad heavy_load_wait never runs the command" — the mutant turns the
# bad-value refusal into a no-op, so AC4's rc-70 assertion goes RED: the
# quoted value is silently ignored and the command executes.
# shellcheck disable=SC2016 # the spec literal must not expand in this shell
printf '             return "$WRK_EXIT_CONFIG_REFUSED" ;; =>              true ;;\n' \
  >"$TMP/spec-hlw-badok"
mutant hlwbadok "$TMP/spec-hlw-badok"
printf '0\n' >"$WRK_HEAVY_LOAD_FILE"
set +e
out="$(WRK_HEAVY_LOCK="$TMP/hlw-m3.lock" \
  WRK_HOSTS_CONFIG="$TMP/hlw-bad-value-quoted.toml" \
  "$TMP/hlwbadok-wrk" heavy -- touch "$TMP/hlw-m3-ran" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 && -e "$TMP/hlw-m3-ran" ]] ||
  fail "mutant hlwbadok still refused the bad value (rc=$rc): $out — the AC4 assertion is vacuous"
echo "PASS mutant-hlw-bad-ok: 'a bad value never runs' RED — AC4 'refuses rc 70' fails (rc=0, command ran)"

# M4 (r2) "a load-off run never starts after the cap" — the mutant drops
# the post-acquire gate: the deterministic cap-0 boundary run goes RED —
# the command executes where the fixed source refuses rc 75.
printf '    if not load_wait and acquired_at >= deadline: =>     if False:\n' \
  >"$TMP/spec-hlw-postcap"
mutant hlwpostcap "$TMP/spec-hlw-postcap"
printf '0\n' >"$WRK_HEAVY_LOAD_FILE"
set +e
out="$(WRK_HEAVY_WAIT_CAP=0 WRK_HEAVY_LOCK="$TMP/hlw-m4.lock" \
  WRK_HOSTS_CONFIG="$CFGHLW_OFF" \
  "$TMP/hlwpostcap-wrk" heavy -- touch "$TMP/hlw-m4-ran" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 && -e "$TMP/hlw-m4-ran" ]] ||
  fail "mutant hlwpostcap still refused the post-cap admission (rc=$rc): $out — the AC3d assertion is vacuous"
echo "PASS mutant-hlw-postcap: 'a load-off run never starts after the cap' RED — AC3d 'refuses rc 75' fails (rc=0, command ran)"

echo 'PASS test-wrk-heavy-limit'
