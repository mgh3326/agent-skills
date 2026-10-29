#!/usr/bin/env bash
# tests/test-wrk-heavy-class.sh — hk 1533 wrk heavy priority class.
#
# WRK_HEAVY_CLASS=ci puts a waiter ahead of every lane waiter on a host's
# shared heavy lock: while a live ci waiter is queued, lane waiters skip the
# slots it could take (index below the limit it queued under) so the next
# slot to free goes to it. Nothing is preempted; a dead ci waiter's leftover
# record reserves nothing; a lane waiter stops deferring once it has spent
# WRK_HEAVY_CI_DEFER_MAX seconds (default 1800) actually deferring to a live
# ci waiter (time with none queued does not count); slots above the ci
# waiter's limit stay open to lanes (the desktop runner runs WRK_HEAVY_MAX=1).
# The order is read from the waiters dir, not a lock: records are published
# atomically, a lane pass already past its scan may still take a slot, and the
# documented windows are pinned below (heavy-class-documented-windows).
# hk 1545: the tmp side of a publication is an unpredictable mkstemp name
# (a symlink pre-planted at the old .<pid>.tmp is never followed), a waiters
# dir that is foreign-owned, a symlink, or group/other-writable without the
# sticky bit refuses the run rc 78 before anything is written, slot files
# open O_NOFOLLOW and refuse hardlink/foreign/non-regular inodes, and every
# record list/rename/unlink/read goes through the trusted dir fd.
#
# Stub commands only. HOME and every XDG dir point into a temp dir, every
# lock, waiters dir, load file and log is a temp path, and only pids this
# script started are ever signalled. Assertion-RED mutants over a copy of
# bin/wrk close the file.
set -euo pipefail
# hk 1894: trust-bearing wrk and arbiter commands honour this suite's temp-dir overrides
# (HOME, ARBITER_INBOX_ROOT, XDG_DATA_HOME, HANDOFFKEEP_BIN) only in test mode.
export WRK_TEST_MODE=1
unset WRK_TEST_REAL_SENTINEL

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
  local name="$1"; shift # HEAVY_BIN overrides the wrk binary (mutant copies)
  env "$@" "${HEAVY_BIN:-$WRK}" heavy -- bash "$TMP/$name.sh" >"$TMP/$name.out" 2>&1 &
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
  'kind=defer' 'preempt' 'not a lock' 'renamed into place' 'starting up' \
  'spent WRK_HEAVY_CI_DEFER_MAX'; do
  grep -qF -- "$token" <<<"$help_out" || fail "heavy --help must mention: $token"
done
for token in WRK_HEAVY_CLASS WRK_HEAVY_CI_DEFER_MAX 1800 kind=defer \
  '원자적' '약속하지 않는 것'; do
  grep -qF -- "$token" "$ROOT/ops/references/heavy.md" ||
    fail "ops/references/heavy.md must mention: $token"
done
python3 - "$WRK" <<'PY'
import ast, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
start = src.index("heavy_cmd() {")
half = src[start:src.index('\ncase "${1:-}" in', start)]
def signal_violations(source):
    match = re.search(r'python3 - "\$@" <<\'PY\'\n(.*?)\nPY', source, re.S)
    assert match, "heavy_cmd Python body not found"
    try:
        tree = ast.parse(match.group(1))
    except SyntaxError as exc:
        return ["heavy_cmd Python body does not parse: %s" % exc]
    errors = []
    kill_probes = 0
    allowed_signal_attrs = {"signal", "SIGHUP", "SIGTERM", "SIG_DFL", "SIG_IGN"}
    allowed_signal_numbers = {"SIGHUP", "SIGTERM"}
    allowed_signal_handlers = {"wait_signal", "SIG_DFL", "SIG_IGN"}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name == "signal" and alias.asname not in (None, "signal"):
                    errors.append("signal module aliases are not allowed")
        elif isinstance(node, ast.ImportFrom) and node.module == "signal":
            errors.append("from-signal imports are not allowed")
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "signal":
            if node.attr not in allowed_signal_attrs:
                errors.append("signal.%s is outside the allowlist" % node.attr)
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
            continue
        func = node.func
        receiver_is_os = isinstance(func.value, ast.Name) and func.value.id == "os"
        receiver_is_signal = isinstance(func.value, ast.Name) and func.value.id == "signal"
        if receiver_is_os and func.attr == "kill":
            kill_probes += 1
            if (len(node.args) != 2 or node.keywords or
                    not isinstance(node.args[1], ast.Constant) or node.args[1].value != 0):
                errors.append("every os.kill call must use literal signal 0")
        elif receiver_is_os and func.attr == "killpg":
            errors.append("os.killpg is forbidden in heavy_cmd")
        elif func.attr in {"kill", "terminate", "send_signal"} and not (receiver_is_os and func.attr == "kill"):
            errors.append(".%s is forbidden in heavy_cmd" % func.attr)
        if receiver_is_signal:
            valid_signal = (len(node.args) == 2 and not node.keywords and
                            isinstance(node.args[0], ast.Attribute) and
                            isinstance(node.args[0].value, ast.Name) and
                            node.args[0].value.id == "signal" and
                            node.args[0].attr in allowed_signal_numbers)
            handler = node.args[1] if len(node.args) == 2 else None
            valid_handler = (
                isinstance(handler, ast.Name) and handler.id in allowed_signal_handlers
            ) or (
                isinstance(handler, ast.Attribute) and
                isinstance(handler.value, ast.Name) and handler.value.id == "signal" and
                handler.attr in {"SIG_DFL", "SIG_IGN"}
            )
            if func.attr != "signal" or not valid_signal or not valid_handler:
                errors.append("signal calls must register/restore SIGHUP or SIGTERM handlers")
    if kill_probes < 1:
        errors.append("heavy_cmd must retain at least one os.kill(pid, 0) probe")
    return errors

# Allowlist owner-liveness probes and wait-only HUP/TERM cleanup; never permit
# the heavy path to signal a slot holder or use any other signal API.
assert not signal_violations(half), signal_violations(half)
for injected in ("    os.kill(pid, signal.SIGTERM)\n", "    os.killpg(pid, signal.SIGTERM)\n"):
    anchor = "def alive(pid):\n"
    assert half.count(anchor) == 1, "heavy signal mutant anchor must be unique"
    mutant = half.replace(anchor, anchor + injected, 1)
    assert signal_violations(mutant), ("heavy signal allowlist accepted mutant", injected)
# the waiter record is published by rename, never by open-then-write in place
assert "os.replace(record_tmp, me_name" in half, \
    "waiter record is not renamed into place"
assert 'open(me, "w"' not in half, "waiter record is written in place again"
# hk 1545: the tmp side of the rename is an unpredictable mkstemp name, the
# waiters dir is opened O_NOFOLLOW and checked before publication, slot
# opens never follow a planted symlink, and record ops go through dir_fd
assert "tempfile.mkstemp(dir=waiters_dir" in half, \
    "record tmp must come from mkstemp, not a predictable name"
assert "def waiters_dir_open" in half, "waiters dir trust check missing"
assert "os.O_NOFOLLOW" in half, "slot opens must not follow a planted symlink"
assert "os.O_DIRECTORY" in half, "waiters dir must open as a real directory"
assert "dir_fd=waiters_fd" in half, "record ops must use the trusted dir fd"
# r2: a planted hardlink or foreign inode at the slot name is not a slot
assert "st_nlink == 1" in half, "slot opens must refuse a hardlinked inode"
# r3: root-owned shared locks (desktop tmpfiles) stay usable
assert "def owner_trusted" in half, "root-owned shared locks must pass"
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
fcmp "$el" le 12 || fail "the lane kept deferring past WRK_HEAVY_CI_DEFER_MAX=2 (${el}s)"
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


# ── a ci record that becomes visible while a lane is already queued ────────
# Honoured from the lane's next pass: the freed slot is NOT taken, and the
# lane runs once the ci waiter is gone.
new_lock s2b
mkhold s2b-H; mkhold s2b-L
release s2b-L
bg_heavy s2b-H; ph=$BG
wait_until 10 started s2b-H || fail "s2b: holder never started"
bg_heavy s2b-L; pl=$BG
wait_until 10 queued s2b-L lane 1 || fail "s2b: lane never queued"
sleep 1.2 # several passes with no ci waiter at all
fake_ci 1
sleep 1.2 # the lane's next passes see it
release s2b-H
wait "$ph" || fail "s2b: holder failed"
sleep 3
started s2b-L && fail "s2b: the lane took the freed slot although a ci record had been visible for several passes"
kill_own "$FAKE"
wait_until 10 started s2b-L || fail "s2b: the lane never ran after the ci waiter died"
wait "$pl" || fail "s2b: lane run failed"
echo "PASS heavy-class-ci-record-honoured-from-next-pass"

# ── the guard counts only time actually spent deferring ────────────────────
# ci#1 is live ~2 s, nothing is queued for 6 s (the clock pauses), then a late
# ci#2 appears. With DEFER_MAX=7 the guard must fire after ~5 s more of
# deferring to ci#2, not at once. A clock that kept running through the gap
# (the previous behaviour) would be spent at ci#2's first pass.
new_lock s2c
mkhold s2c-H; mkhold s2c-L
release s2c-L
bg_heavy s2c-H; ph=$BG
wait_until 10 started s2c-H || fail "s2c: holder never started"
fake_ci 1
ci1=$FAKE
bg_heavy s2c-L WRK_HEAVY_CI_DEFER_MAX=7; pl=$BG
wait_until 10 queued s2c-L lane 1 || fail "s2c: lane never queued"
sleep 1.5
kill_own "$ci1"
sleep 6 # no live ci waiter: this must not count
fake_ci 1
sleep 1
release s2c-H
wait "$ph" || fail "s2c: holder failed"
sleep 2
started s2c-L && fail "s2c: the guard fired at the late ci waiter's first pass — idle time was counted"
wait_until 15 started s2c-L || fail "s2c: the guard never released the lane"
kill_own "$FAKE"
wait "$pl" || fail "s2c: lane run failed"
log_rows defer s2c-L | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin.read().splitlines()]
assert len(rows) == 1, rows
r = rows[0]
assert r["reason"] == "guard" and r["class"] == "lane", r
assert 6.5 <= r["defer_s"] <= 9.5, r
# the 6 s with no ci waiter are in wait_s but not in defer_s
assert r["wait_s"] - r["defer_s"] >= 5, r
'
echo "PASS heavy-class-guard-counts-only-deferred-time"

# ── waiter records are published atomically ────────────────────────────────
# A poller reads every record in the waiters dir as fast as it can while
# several ci waiters start. Every record it ever reads must be whole.
cat >"$TMP/poll.py" <<'POLL'
import os, sys, time
d, out, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
end = time.time() + secs
whole = bad = 0
while time.time() < end:
    try:
        names = os.listdir(d)
    except OSError:
        names = []
    for n in names:
        if n.startswith("."):
            continue
        try:
            with open(os.path.join(d, n), encoding="utf-8") as f:
                t = f.read()
        except OSError:
            continue
        if t.startswith("pid=") and " class=" in t and " cmd=" in t:
            whole += 1
        else:
            bad += 1
with open(out, "w", encoding="utf-8") as f:
    f.write("%d %d\n" % (whole, bad))
POLL
publish_flow() { # publish_flow <tag> <ci wrk binary>: "whole bad" counts -> $TMP/<tag>.poll
  local tag="$1" bin="$2" i ph pp
  new_lock "$tag"
  mkhold "$tag-H"
  bg_heavy "$tag-H"; ph=$BG
  wait_until 10 started "$tag-H" || fail "$tag: holder never started"
  python3 "$TMP/poll.py" "$WRK_HEAVY_LOCK.waiters" "$TMP/$tag.poll" 5 &
  pp=$!
  PIDS+=("$pp")
  for i in 1 2 3 4 5 6; do
    mkhold "$tag-C$i"
    release "$tag-C$i"
    HEAVY_BIN="$bin" bg_heavy "$tag-C$i" WRK_HEAVY_CLASS=ci
  done
  wait "$pp" || fail "$tag: poller failed"
  release "$tag-H"
  wait_until 40 test -e "$TMP/$tag-C1.done" -a -e "$TMP/$tag-C2.done" -a -e "$TMP/$tag-C3.done" \
    -a -e "$TMP/$tag-C4.done" -a -e "$TMP/$tag-C5.done" -a -e "$TMP/$tag-C6.done" ||
    fail "$tag: not every ci waiter ran after the holder was released"
  wait "$ph" || fail "$tag: holder failed"
}
publish_flow s10 "$WRK"
read -r whole bad <"$TMP/s10.poll"
[[ "$whole" -ge 6 && "$bad" -eq 0 ]] ||
  fail "s10: records were not published atomically (whole=$whole bad=$bad)"
echo "PASS heavy-class-records-published-atomically"

# ── the documented windows, pinned ─────────────────────────────────────────
# What the docs do NOT promise: a lane pass already past its record scan when
# a ci record appears may still take a slot that frees in that pass (the
# records are not re-read before the slot attempts). This is a model: a copy
# of wrk parks the pass right after the scan until a gate file exists. If
# someone adds a re-check, this goes RED and the docs must change with it.
mutant() { # mutant <name> <old> <new>: wrk copy with the unique <old> replaced
  python3 - "$WRK" "$TMP/$1-wrk" "$2" "$3" <<'MUT'
import sys
src_path, out_path, old, new = sys.argv[1:]
src = open(src_path, encoding="utf-8").read()
assert src.count(old) == 1, ("mutant anchor must be unique", old, src.count(old))
open(out_path, "w", encoding="utf-8").write(src.replace(old, new, 1))
MUT
  chmod +x "$TMP/$1-wrk"
}
mutant inflight $'                reserved = ci_reserved()\n' \
  $'                reserved = ci_reserved()\n                while not os.path.exists(os.environ["WRK_TEST_PASS_GATE"]):\n                    time.sleep(0.05)\n'
new_lock s11
mkhold s11-H; mkhold s11-L
release s11-L
bg_heavy s11-H; ph=$BG
wait_until 10 started s11-H || fail "s11: holder never started"
HEAVY_BIN="$TMP/inflight-wrk" bg_heavy s11-L WRK_TEST_PASS_GATE="$TMP/s11.gate"; pl=$BG
wait_until 10 queued s11-L lane 1 || fail "s11: lane never queued"
sleep 1 # the first pass is parked right after its scan, which read no ci record
fake_ci 1
release s11-H
wait "$ph" || fail "s11: holder failed"
started s11-L && fail "s11: the lane moved before the gate opened"
: >"$TMP/s11.gate"
wait_until 10 started s11-L ||
  fail "s11: the in-flight pass no longer takes the slot — the documented window changed, update the docs"
status_out | grep -q "^waiter pid=$FAKE class=ci limit=1 " ||
  fail "s11: the ci record must still be queued"
kill_own "$FAKE"
wait "$pl" || fail "s11: lane run failed"
echo "PASS heavy-class-documented-windows"

# ── assertion-RED mutants over a copy of bin/wrk ───────────────────────────

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
mutant noguard 'if defer_total + (now - defer_mark) >= defer_max:' 'if False:'
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
env WRK_HEAVY_CLASS=ci "$TMP/cidefers-wrk" heavy -- bash "$TMP/m6-C1.sh" >/dev/null 2>&1 &
mc1=$!
PIDS+=("$mc1")
env WRK_HEAVY_CLASS=ci "$TMP/cidefers-wrk" heavy -- bash "$TMP/m6-C2.sh" >/dev/null 2>&1 &
mc2=$!
PIDS+=("$mc2")
wait_until 10 queued m6-C1 ci 1 || fail "mutant cidefers: first ci waiter never queued"
wait_until 10 queued m6-C2 ci 1 || fail "mutant cidefers: second ci waiter never queued"
release m6-H
wait "$mh" || fail "mutant cidefers holder failed"
sleep 3
# the idle slot only proves deferral if both waiters were alive, still queued
# and the slot really free through the whole observation window
if ! { kill -0 "$mc1" 2>/dev/null && kill -0 "$mc2" 2>/dev/null; }; then
  fail "mutant cidefers: a waiter exited before the idle-slot check"
fi
if ! { queued m6-C1 ci 1 && queued m6-C2 ci 1; }; then
  fail "mutant cidefers: a ci waiter left the queue before the idle-slot check"
fi
status_out | grep -q '^holder none' ||
  fail "mutant cidefers: the slot was not free during the observation window"
if started m6-C1 || started m6-C2; then
  fail "mutant cidefers still let a ci waiter take the slot — never-defer assertion is vacuous"
fi
# end the experiment without a race on who caps out first: drop both waiter
# records so neither sees a ci waiter, and let each take the slot and exit
release m6-C1 m6-C2
rm -f "$WRK_HEAVY_LOCK".waiters/*
wait "$mc1" || fail "mutant cidefers: waiter 1 failed after the records were dropped"
wait "$mc2" || fail "mutant cidefers: waiter 2 failed after the records were dropped"
echo "PASS mutant-cidefers"


# nogapclock: the guard clock keeps running while no ci waiter is queued (the
# previous behaviour). RED proof: the late ci#2 of the s2c scenario finds the
# guard already spent, so the lane takes the freed slot at once.
mutant nogapclock $'                elif defer_mark is not None:\n' $'                elif False:\n'
new_lock m7
mkhold m7-H; mkhold m7-L
release m7-L
bg_heavy m7-H; ph=$BG
wait_until 10 started m7-H || fail "mutant nogapclock holder never started"
fake_ci 1
ci1=$FAKE
HEAVY_BIN="$TMP/nogapclock-wrk" bg_heavy m7-L WRK_HEAVY_CI_DEFER_MAX=5; pl=$BG
wait_until 10 queued m7-L lane 1 || fail "mutant nogapclock lane never queued"
sleep 1.5
kill_own "$ci1"
sleep 5 # a clock that runs through this gap is spent by now
fake_ci 1
sleep 1
release m7-H
wait "$ph" || fail "mutant nogapclock holder failed"
wait_until 4 started m7-L ||
  fail "mutant nogapclock still deferred — the gap-clock assertion is vacuous"
kill_own "$FAKE"
wait "$pl" || fail "mutant nogapclock lane failed"
echo "PASS mutant-nogapclock"

# nonatomic: the record is written in place, with the open-then-write gap
# widened to 0.4 s. RED proof: the poller reads empty records that the
# renaming code never exposes.
mutant nonatomic $'        os.replace(record_tmp, me_name,\n                   src_dir_fd=waiters_fd, dst_dir_fd=waiters_fd)\n' \
  $'        with open(os.path.join(waiters_dir, me_name), "w", encoding="utf-8") as f:\n            time.sleep(0.4)\n            f.write(info)\n'
publish_flow m8 "$TMP/nonatomic-wrk"
read -r whole bad <"$TMP/m8.poll"
[[ "$bad" -ge 1 ]] ||
  fail "mutant nonatomic still published whole records (whole=$whole bad=$bad) — the poller assertion is vacuous"
echo "PASS mutant-nonatomic"

# ── hk 1545: planted symlinks at the predictable names are never followed ──
# An attacker who can write the waiters dir pre-plants a symlink at the old
# predictable .<pid>.tmp (writes the record through it) and at the final
# <pid> record name (the rename must replace the link, not its target). The
# waiter's pid is not known ahead, so a python one-shot plants a range of
# both names first; the run's actual pid is read back as the only regular
# file in the dir and asserted to be inside the planted range.
plant_links() { # plant_links <waiters dir> <tmp victim> <record victim>
  python3 - "$1" "$2" "$3" <<'PY'
import os, sys
d, vtmp, vrec = sys.argv[1:4]
base = os.getpid()
for i in range(base + 1, base + 901):
    for name, target in ((".%d.tmp" % i, vtmp), (str(i), vrec)):
        try:
            os.symlink(target, os.path.join(d, name))
        except FileExistsError:
            pass
PY
}

symlink_flow() { # symlink_flow <tag> safe|vuln — safe pins the fix, vuln is the mutant proof
  local tag="$1" mode="$2" recs wpid ph pl
  new_lock "$tag"
  chmod 1777 "$WRK_HEAVY_LOCK.waiters" # a writable+sticky dir is the attack surface
  printf 'VICTIM-TMP-%s\n' "$tag" >"$TMP/victim-$tag-tmp"
  printf 'VICTIM-REC-%s\n' "$tag" >"$TMP/victim-$tag-rec"
  plant_links "$WRK_HEAVY_LOCK.waiters" "$TMP/victim-$tag-tmp" "$TMP/victim-$tag-rec"
  # a held slot keeps the tested run queued: its record stays visible as a
  # waiter instead of being published and removed inside one acquire pass
  mkhold "$tag-H"; mkhold "$tag-L"
  bg_heavy "$tag-H"; ph=$BG
  wait_until 10 started "$tag-H" || fail "$tag: holder never started"
  if [[ "$mode" == vuln ]]; then
    HEAVY_BIN="$TMP/predtmp-wrk" bg_heavy "$tag-L"
    # RED proof for the safe flow below: the restored predictable-name code
    # opens .<pid>.tmp through the planted symlink, so the victim now holds
    # record text. If this does not appear, the safe assertions are vacuous.
    wait_until 10 grep -q '^pid=' "$TMP/victim-$tag-tmp" ||
      fail "$tag: mutant predtmp did not follow the planted symlink — safe-mode assertions are vacuous"
    release "$tag-H" "$tag-L"
    wait "$ph" "$BG" || fail "$tag: mutant predtmp runs failed"
    return 0
  fi
  bg_heavy "$tag-L"
  pl=$BG
  wait_until 10 queued "$tag-L" lane 1 || fail "$tag: lane never queued"
  # exactly one record, a regular file (the planted <pid> link was replaced,
  # not followed), holding this waiter's own record text
  [[ "$(find "$WRK_HEAVY_LOCK.waiters" -maxdepth 1 -type f ! -name '.*' |
       wc -l | tr -d ' ')" -eq 1 ]] ||
    fail "$tag: expected exactly one regular record file"
  recs="$(find "$WRK_HEAVY_LOCK.waiters" -maxdepth 1 -type f ! -name '.*' -print)"
  wpid="$(basename "$recs")"
  [[ "$wpid" =~ ^[0-9]+$ ]] || fail "$tag: record name is not a pid: $wpid"
  grep -q "^pid=$wpid class=lane " "$recs" ||
    fail "$tag: published record content is wrong: $(cat "$recs")"
  # the waiter's pid must be inside the planted range, and the planted
  # .<pid>.tmp symlink must still be a symlink to the victim — publication
  # used an unpredictable name, not this one
  [[ -L "$WRK_HEAVY_LOCK.waiters/.$wpid.tmp" ]] ||
    fail "$tag: the waiter pid was outside the planted range — test inconclusive"
  [[ "$(readlink "$WRK_HEAVY_LOCK.waiters/.$wpid.tmp")" == "$TMP/victim-$tag-tmp" ]] ||
    fail "$tag: the planted tmp symlink was replaced, not left alone"
  [[ "$(cat "$TMP/victim-$tag-tmp")" == "VICTIM-TMP-$tag" ]] ||
    fail "$tag: the planted .pid.tmp symlink was followed — victim rewritten"
  [[ "$(cat "$TMP/victim-$tag-rec")" == "VICTIM-REC-$tag" ]] ||
    fail "$tag: the planted record-name symlink was followed — victim rewritten"
  release "$tag-H" "$tag-L"
  wait "$ph" "$pl" || fail "$tag: runs failed"
  # exit cleanup sweeps the old predictable name — and only removes the link
  [[ ! -e "$WRK_HEAVY_LOCK.waiters/.$wpid.tmp" && ! -L "$WRK_HEAVY_LOCK.waiters/.$wpid.tmp" ]] ||
    fail "$tag: the planted tmp symlink was not swept on exit"
  [[ "$(cat "$TMP/victim-$tag-tmp")" == "VICTIM-TMP-$tag" ]] ||
    fail "$tag: exit cleanup followed the planted symlink"
}
symlink_flow t1 safe
echo "PASS heavy-tmp-planted-symlinks-never-followed"

# ── hk 1545: an untrusted waiters dir refuses the run before any write ─────
# Group/other-writable WITHOUT the sticky bit: another local user could
# remove or replace records — refuse rc 78, run nothing, mint no slot file.
new_lock t2
chmod 0777 "$WRK_HEAVY_LOCK.waiters"
rc=0
out="$("$WRK" heavy -- touch "$TMP/t2-ran" 2>&1)" || rc=$?
[[ "$rc" -eq 78 ]] ||
  fail "t2: world-writable non-sticky waiters dir must refuse rc 78, got rc=$rc: $out"
grep -q 'untrusted waiters dir' <<<"$out" ||
  fail "t2: the refusal must name the waiters dir: $out"
[[ ! -e "$TMP/t2-ran" ]] || fail "t2: the command ran on an untrusted waiters dir"
[[ ! -e "$WRK_HEAVY_LOCK" ]] ||
  fail "t2: a slot file was minted although the run was refused"
"$WRK" heavy status >/dev/null ||
  fail "t2: status must stay readable on an untrusted waiters dir"
chmod 0770 "$WRK_HEAVY_LOCK.waiters"
rc=0
"$WRK" heavy -- true >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 78 ]] ||
  fail "t2: group-writable non-sticky waiters dir must refuse rc 78, got rc=$rc"
# the sticky bit restores usability for a writable dir owned by us, and a
# plain private dir still works — normal publication is unaffected
chmod 1777 "$WRK_HEAVY_LOCK.waiters"
"$WRK" heavy -- touch "$TMP/t2-ran" ||
  fail "t2: a sticky writable waiters dir owned by the user must be usable"
[[ -e "$TMP/t2-ran" ]] || fail "t2: the command did not run on a sticky waiters dir"
chmod 0755 "$WRK_HEAVY_LOCK.waiters"
"$WRK" heavy -- touch "$TMP/t2-ran2" ||
  fail "t2: a normal private waiters dir must not be refused"
[[ -e "$TMP/t2-ran2" ]] || fail "t2: the command did not run on a normal waiters dir"
echo "PASS heavy-tmp-untrusted-waiters-dir-refused"

# ── hk 1545: a symlink at the predictable slot path is refused ─────────────
new_lock t3
printf 'VICTIM-SLOT\n' >"$TMP/victim-slot"
ln -s "$TMP/victim-slot" "$WRK_HEAVY_LOCK"
rc=0
out="$("$WRK" heavy -- touch "$TMP/t3-ran" 2>&1)" || rc=$?
[[ "$rc" -eq 78 ]] ||
  fail "t3: a symlinked slot file must refuse rc 78, got rc=$rc: $out"
[[ "$(cat "$TMP/victim-slot")" == "VICTIM-SLOT" ]] ||
  fail "t3: the slot symlink was followed — victim rewritten"
[[ ! -e "$TMP/t3-ran" ]] || fail "t3: the command ran over a symlinked slot file"
"$WRK" heavy status | grep -q '^holder none' ||
  fail "t3: status must treat a symlinked slot as unheld"
echo "PASS heavy-tmp-slot-symlink-refused"

# ── hk 1545 r2: a hardlink at the predictable slot path is refused ─────────
# O_NOFOLLOW does not cover hardlinks: without the fstat check the slot
# open would succeed and the flock/truncate would rewrite the victim
# inode — the tester proved this destroys the target file on this host.
new_lock t3h
printf 'VICTIM-HARDLINK\n' >"$TMP/victim-hl"
ln "$TMP/victim-hl" "$WRK_HEAVY_LOCK"
rc=0
out="$("$WRK" heavy -- touch "$TMP/t3h-ran" 2>&1)" || rc=$?
[[ "$rc" -eq 78 ]] ||
  fail "t3h: a hardlinked slot file must refuse rc 78, got rc=$rc: $out"
[[ "$(cat "$TMP/victim-hl")" == "VICTIM-HARDLINK" ]] ||
  fail "t3h: the slot hardlink was used — victim rewritten"
[[ "$(stat -f%z "$TMP/victim-hl" 2>/dev/null || stat -c%s "$TMP/victim-hl")" == "16" ]] ||
  fail "t3h: the victim was truncated"
[[ ! -e "$TMP/t3h-ran" ]] || fail "t3h: the command ran over a hardlinked slot file"
"$WRK" heavy status | grep -q '^holder none' ||
  fail "t3h: status must treat a hardlinked slot as unheld"
# a fifo at the slot path fails closed the same way — cleanly, no traceback
rm "$WRK_HEAVY_LOCK"
mkfifo "$WRK_HEAVY_LOCK"
rc=0
out="$("$WRK" heavy -- touch "$TMP/t3f-ran" 2>&1)" || rc=$?
[[ "$rc" -eq 78 ]] ||
  fail "t3h: a fifo slot must refuse rc 78, got rc=$rc: $out"
[[ ! -e "$TMP/t3f-ran" ]] || fail "t3h: the command ran over a fifo slot file"
echo "PASS heavy-tmp-slot-hardlink-and-fifo-refused"

# ── hk 1545 r2: a symlinked waiters dir is refused, never repointed ────────
# The link's owner can repoint it after any stat-style check, so the dir
# open itself must not follow: the run refuses before any write.
new_lock t3s
rmdir "$WRK_HEAVY_LOCK.waiters"
mkdir "$TMP/t3s-target" && chmod 0700 "$TMP/t3s-target"
ln -s "$TMP/t3s-target" "$WRK_HEAVY_LOCK.waiters"
rc=0
out="$("$WRK" heavy -- touch "$TMP/t3s-ran" 2>&1)" || rc=$?
[[ "$rc" -eq 78 ]] ||
  fail "t3s: a symlinked waiters dir must refuse rc 78, got rc=$rc: $out"
grep -q 'untrusted waiters dir' <<<"$out" ||
  fail "t3s: the refusal must name the waiters dir: $out"
[[ ! -e "$TMP/t3s-ran" ]] || fail "t3s: the command ran over a symlinked waiters dir"
[[ -z "$(find "$TMP/t3s-target" -mindepth 1 -print -quit)" ]] ||
  fail "t3s: a record was written through the waiters-dir symlink"
"$WRK" heavy status >/dev/null ||
  fail "t3s: status must stay readable on a symlinked waiters dir"
echo "PASS heavy-tmp-symlinked-waiters-dir-refused"

# ── hk 1545 r3: a root-owned lock and waiters dir are still usable ─────────
# desktop's tmpfiles install creates /tmp/wrk-heavy-*.lock root-owned 0660
# (runner granted by ACL) and .waiters root-owned 1770; refusing uid-0
# objects would break every heavy run there. Simulated by a wrk copy whose
# getuid() reports a uid that owns nothing, with the trusted-root slot
# mapped onto our real uid — our own 0660 lock and 1770 dir play root's role.
python3 - "$WRK" "$TMP/desktop-wrk" "$UID" <<'PY'
import sys
src = open(sys.argv[1]).read()
me = sys.argv[3]
src = src.replace("os.getuid()", "42424242").replace(
    "42424242, 0", "42424242, " + me)
assert "owner_trusted" in src and ("42424242, " + me) in src
open(sys.argv[2], "w").write(src)
PY
chmod +x "$TMP/desktop-wrk"
new_lock t3d
: >"$WRK_HEAVY_LOCK"; chmod 0660 "$WRK_HEAVY_LOCK"
chmod 1770 "$WRK_HEAVY_LOCK.waiters"
"$TMP/desktop-wrk" heavy -- touch "$TMP/t3d-ran" ||
  fail "t3d: a root-owned shared lock and waiters dir must be usable (desktop tmpfiles layout)"
[[ -e "$TMP/t3d-ran" ]] || fail "t3d: the command did not run over the root-owned layout"
"$TMP/desktop-wrk" heavy status >/dev/null ||
  fail "t3d: status must stay readable over the root-owned layout"
echo "PASS heavy-tmp-root-owned-desktop-layout"

# ── hk 1545: a planted record symlink is never read ────────────────────────
# A live-looking ci record behind a symlink would otherwise reserve every
# slot for lanes; the scans read regular files only.
new_lock t4
printf 'pid=1 class=ci limit=9 since=2026-01-01T00:00:00 job=- cmd=planted\n' \
  >"$TMP/planted-src"
ln -s "$TMP/planted-src" "$WRK_HEAVY_LOCK.waiters/424242"
status_out | grep -q 'cmd=planted' &&
  fail "t4: status read a record through a planted symlink"
WRK_HEAVY_WAIT_CAP=8 "$WRK" heavy -- touch "$TMP/t4-ran" ||
  fail "t4: a lane was blocked by a record behind a planted symlink"
[[ -e "$TMP/t4-ran" ]] || fail "t4: the command did not run"
echo "PASS heavy-tmp-planted-record-symlink-ignored"

# ── hk 1545 assertion-RED mutants ──────────────────────────────────────────

# predtmp: the old predictable .<pid>.tmp publication is restored. RED proof:
# the same planted-symlink setup as t1 ends with record text inside the tmp
# victim — the symlink WAS followed.
mutant predtmp $'    fd, tmp = tempfile.mkstemp(dir=waiters_dir, prefix=".")\n    record_tmp = os.path.basename(tmp)\n    try:\n        with os.fdopen(fd, "w", encoding="utf-8") as f:\n' \
  $'    tmp = os.path.join(waiters_dir, ".%d.tmp" % os.getpid())\n    record_tmp = os.path.basename(tmp)\n    try:\n        with open(tmp, "w", encoding="utf-8") as f:\n'
symlink_flow m9 vuln
echo "PASS mutant-predtmp"

# trustopen: the waiters-dir trust check never refuses. RED proof: the 0777
# non-sticky dir that must refuse rc 78 accepts the run. The cut lands
# inside waiters_dir_open — dropping the caller-side guard would only
# crash the mutant on a -1 fd.
mutant trustopen '    if not trusted:' '    if False:'
new_lock m10
chmod 0777 "$WRK_HEAVY_LOCK.waiters"
"$TMP/trustopen-wrk" heavy -- touch "$TMP/m10-ran" ||
  fail "mutant trustopen still refused the untrusted dir — refusal assertion is vacuous"
[[ -e "$TMP/m10-ran" ]] || fail "mutant trustopen run did not execute"
echo "PASS mutant-trustopen"

# slotlink: the slot fstat check accepts a hardlink. RED proof: the run
# flocks the planted link and the holder record is written through it —
# the victim's own inode carries wrk's text while the slot is held.
mutant slotlink '_st.st_nlink == 1 and' 'True and'
new_lock m11
printf 'M11-VICTIM\n' >"$TMP/m11-victim"
ln "$TMP/m11-victim" "$WRK_HEAVY_LOCK"
mkhold m11-x
HEAVY_BIN="$TMP/slotlink-wrk" bg_heavy m11-x
wait_until 10 grep -q 'pid=' "$TMP/m11-victim" ||
  fail "mutant slotlink did not write the record into the victim — assertion is vacuous"
release m11-x
wait "$BG" || fail "mutant slotlink run failed"
echo "PASS mutant-slotlink"

python3 "$ROOT/tests/test_wrk_heavy_queue.py"
python3 "$ROOT/tests/test_wrk_heavy_position_guards.py"
WRK_LEAK_ROOT="$TMP" WRK_LEAK_COPY="$WRK" python3 "$ROOT/tests/lib/assert-no-wrk-leaks.py"
echo 'PASS test-wrk-heavy-class'
