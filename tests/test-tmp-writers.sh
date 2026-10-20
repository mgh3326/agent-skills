#!/usr/bin/env bash
# tests/test-tmp-writers.sh — regression cases for tests/lib/tmp-writers.sh
# (hk1699 r2): renamed-copy sentinel argv, per-entry registry identities,
# refusal visibility in TW_LEFTOVER_PIDS, dead-entry caching bounds,
# recorded own-session group ownership, pending-descendant escalation,
# and the no-rm-while-a-tracked-writer-lives contract.
# (hk1746): the leftover pass proves recycling — a live pid whose stored
# start identity differs is named one per line on TW_RECYCLED_PIDS and
# can no longer fail teardown; matching or absent identities still can.
set -euo pipefail

# Standalone-safe isolation: never depend on the caller's environment.
export HOME="$(mktemp -d)"
export XDG_DATA_HOME="$HOME/xdg-data" XDG_CONFIG_HOME="$HOME/xdg-config"
export XDG_CACHE_HOME="$HOME/xdg-cache" XDG_STATE_HOME="$HOME/xdg-state"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/tests/lib/tmp-writers.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS $*"; }

# Every process this file spawns is tracked as "pid<TAB>identity" and is
# signalled during cleanup only while its CURRENT identity still matches —
# a recycled pid is never killed here either. Entries are dropped as soon
# as the process is confirmed dead; run dirs are removed only once every
# tracked writer is gone.
STRAYS=""
RUNS=""

track() {
  local pid="$1" ident
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  ident="$(_tw_pid_identity "$pid" 2>/dev/null || true)"
  [[ -n "$ident" ]] || return 0
  # Entries are newline-JOINED: untrack's $( ) strips the trailing
  # newline, so a trailing-newline format would fuse the next entry
  # onto the last line and hide it from stray_kill's $1 match.
  STRAYS="${STRAYS:+$STRAYS$'\n'}$pid"$'\t'"$ident"
}

untrack() { # PID — drop every ledger line for a confirmed-dead pid
  STRAYS="$(awk -F '\t' -v p="$1" '$1 != p' <<<"$STRAYS")"
}

stray_kill() { # PID — signal only if the tracked identity still holds
  local pid="$1" stored cur
  stored="$(awk -F '\t' -v p="$pid" '$1 == p { print $2; exit }' <<<"$STRAYS")"
  [[ -n "$stored" ]] || return 0
  cur="$(_tw_pid_identity "$pid" 2>/dev/null || true)"
  [[ -n "$cur" && "$cur" == "$stored" ]] || return 0
  kill -9 "$pid" 2>/dev/null || true
}

cleanup() {
  local pid n
  # Signal, then wait for every tracked writer to be gone before rm.
  for _ in 1 2 3 4 5; do
    while IFS=$'\t' read -r pid _; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      stray_kill "$pid"
    done <<<"$STRAYS"
    n=0
    while IFS=$'\t' read -r pid _; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      alive "$pid" && n=$(( n + 1 ))
    done <<<"$STRAYS"
    (( n == 0 )) && break
    sleep 0.2
  done
  if (( n != 0 )); then
    echo "FAIL: test writers still alive after cleanup: $STRAYS" >&2
    exit 1   # dirs preserved for inspection — no rm while a writer lives
  fi
  local r
  for r in $RUNS; do rm -rf "$r" 2>/dev/null || true; done
  rm -rf "$HOME" 2>/dev/null || true
}
trap cleanup EXIT

# new_run — fresh $TW_TMP / run window for one case.
new_run() {
  TW_TMP="$(mktemp -d)"
  export TW_TMP
  TW_LEFTOVER_PIDS=""
  TW_RECYCLED_PIDS=""
  TW_RUN_START="$(date +%s)"
  RUNS="$RUNS $TW_TMP"
}

# dead_pid — a pid we just watched exit (for stale fixtures).
dead_pid() {
  sleep 0.01 & local p=$!
  wait "$p" 2>/dev/null || true
  printf '%s\n' "$p"
}

alive() { kill -0 "$1" 2>/dev/null; }
dead() { ! alive "$1"; }
pid_gone() {  # wait until kill -0 fails
  local n=0
  while alive "$1"; do (( ++n > 100 )) && return 1; sleep 0.1; done
}
listed() { [[ " $TW_LEFTOVER_PIDS " == *" $1 "* ]]; }
recycled() { grep -qxF "$1" <<<"${TW_RECYCLED_PIDS:-}"; }

# mk_sentinel_script PATH — a fake wrk copy: writes its own sentinel
# pidfile (pid + started=EPOCH) into $SENT_JOBDIR, then holds a `sleep`
# child like the real interval loop.
mk_sentinel_script() {
  cat >"$1" <<'SH'
#!/usr/bin/env bash
mkdir -p "$SENT_JOBDIR"
printf '%s\nstarted=%s\n' "$$" "$(date +%s)" >"$SENT_JOBDIR/completion-sentinel.pid"
sleep 60 &
printf '%s\n' "$!" >"$SENT_JOBDIR/sentinel-child.pid"
wait
SH
}

# wait_pidfile PF — up to 1s for a nonempty pidfile.
wait_pidfile() {
  local _n
  for _n in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$1" ]] && return 0
    sleep 0.1
  done
  return 1
}

# wait_group_member PGID — up to ~5s for another process to appear in
# PGID's process group; prints the member pid.
wait_group_member() {
  local _n _m
  for _n in $(seq 1 50); do
    _m="$(pgrep -g "$1" 2>/dev/null | grep -vx "$1" | head -n 1 || true)"
    if [[ -n "$_m" ]]; then
      printf '%s\n' "$_m"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# ── T1: sentinels launched through renamed wrk copies are reaped ────────
new_run
spids=""
for name in mut-wrk-demo wrk-mutant wrk-hub-cwd; do
  jobdir="$TW_TMP/inbox/job-$name"
  mk_sentinel_script "$TW_TMP/$name"
  env SENT_JOBDIR="$jobdir" \
    bash "$TW_TMP/$name" sentinel "job-$name" lane lbl w1:p1 "$TW_TMP/r.json" &
  track "$!"
  wait_pidfile "$jobdir/completion-sentinel.pid" ||
    fail "T1 $name: sentinel pidfile missing"
  wait_pidfile "$jobdir/sentinel-child.pid" ||
    fail "T1 $name: sentinel child pidfile missing"
  track "$(cat "$jobdir/sentinel-child.pid")"
done
# … and one addressed by its jobdir path instead of the bare job id.
jobdir="$TW_TMP/inbox/job-patharg"
mk_sentinel_script "$TW_TMP/mut-wrk-patharg"
env SENT_JOBDIR="$jobdir" \
  bash "$TW_TMP/mut-wrk-patharg" sentinel "$jobdir" lane lbl w1:p1 "$TW_TMP/r2.json" &
track "$!"
wait_pidfile "$jobdir/completion-sentinel.pid" ||
  fail "T1 patharg: sentinel pidfile missing"
wait_pidfile "$jobdir/sentinel-child.pid" ||
  fail "T1 patharg: sentinel child pidfile missing"
track "$(cat "$jobdir/sentinel-child.pid")"
tmp_writers_stop || fail "T1: tmp_writers_stop rc=$? leftover=${TW_LEFTOVER_PIDS:-}"
[[ -z "${TW_LEFTOVER_PIDS:-}" ]] || fail "T1: leftovers:${TW_LEFTOVER_PIDS}"
while IFS=$'\t' read -r pid _; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  dead "$pid" || fail "T1: sentinel $pid survived"
  untrack "$pid"
done <<<"$STRAYS"
pass "T1 renamed-copy sentinels reaped"

# ── T2: a foreign process named by a forged sentinel pidfile survives ──
new_run
sleep 60 & fp=$!
track "$fp"
mkdir -p "$TW_TMP/inbox/forged"
printf '%s\nstarted=%s\n' "$fp" "$(date +%s)" \
  >"$TW_TMP/inbox/forged/completion-sentinel.pid"
rc=0
tmp_writers_stop || rc=$?
[[ "$rc" -ne 0 ]] || fail "T2: refused live pidfile must fail the sweep"
alive "$fp" || fail "T2: foreign sleep was signalled"
listed "$fp" || fail "T2: refused pid missing from TW_LEFTOVER_PIDS ($TW_LEFTOVER_PIDS)"
[[ -d "$TW_TMP" ]] || fail "T2: TMP must be preserved on refusal"
stray_kill "$fp"; pid_gone "$fp"; untrack "$fp"
pass "T2 forged sentinel pidfile refused, visible as leftover"

# ── T3: a stale pidfile (dead pid, no window) is harmless ──────────────
new_run
dp="$(dead_pid)"
mkdir -p "$TW_TMP/inbox/stale"
printf '%s\nstarted=%s\n' "$dp" "1000000000" \
  >"$TW_TMP/inbox/stale/completion-sentinel.pid"
tmp_writers_stop || fail "T3: stale pidfile must not fail the sweep"
[[ -z "${TW_LEFTOVER_PIDS:-}" ]] || fail "T3: leftover on a dead pid:${TW_LEFTOVER_PIDS}"
pass "T3 stale pidfile inert"

# ── T4: tw_register_pid'd process is reaped; identities precede pids ────
new_run
reg="$TW_TMP/refresh.pids"
sleep 60 & rp=$!
track "$rp"
tw_register_pid "$reg" "$rp"
[[ "$(tail -n 1 "$reg")" == "$rp" ]] || fail "T4: bare pid line missing"
grep -q "^$rp	." "$reg.identities" ||
  fail "T4: REGISTRY.identities must carry a per-entry start identity"
[[ "$(wc -l <"$reg")" -eq 1 ]] || fail "T4: registry keeps bare-numeric lines"
tmp_writers_stop || fail "T4: registered writer not reaped (${TW_LEFTOVER_PIDS:-})"
dead "$rp" || fail "T4: registered sleep survived"
untrack "$rp"
pass "T4 tw_register_pid writer reaped by per-entry identity"

# ── T5: no pid=pid registration remains at the own() call sites ─────────
if grep -nE 'own "[^"]*=\$!"' "$ROOT/tests/test-wrk.sh" \
     "$ROOT/tests/test-wrk-job-end.sh"; then
  fail "T5: own() still registers a pid=pid line"
fi
grep -q 'own() {.*tw_register_pid' "$ROOT/tests/test-wrk.sh" ||
  fail "T5: test-wrk.sh own() must go through tw_register_pid"
grep -q 'own() {.*tw_register_pid' "$ROOT/tests/test-wrk-job-end.sh" ||
  fail "T5: test-wrk-job-end.sh own() must go through tw_register_pid"
pass "T5 own() call sites all register through tw_register_pid"

# ── T6: stale per-entry token on an earlier line proves recycling ──────
new_run
reg="$TW_TMP/mixed.pids"
sleep 60 & fp=$!
track "$fp"
# Earlier line: a bare registry entry plus a token that is not fp's real
# start identity — the shape a dead-and-reused pid leaves behind. The
# sweep still refuses to signal it, and the leftover pass now proves it
# recycled: named on TW_RECYCLED_PIDS, out of TW_LEFTOVER_PIDS, rc 0.
printf '%s\t%s\n' "$fp" "0" >>"$reg.identities"
printf '%s\n' "$fp" >>"$reg"
sleep 60 & op=$!
track "$op"
tw_register_pid "$reg" "$op"
rc=0
tmp_writers_stop || rc=$?
[[ "$rc" -eq 0 ]] || fail "T6: proven-recycled pid must not fail the sweep"
alive "$fp" || fail "T6: foreign pid on a stale-token line was signalled"
dead "$op" || fail "T6: valid later entry was not reaped"
listed "$fp" && fail "T6: recycled pid must leave TW_LEFTOVER_PIDS"
recycled "$fp" || fail "T6: recycled pid missing from TW_RECYCLED_PIDS"
untrack "$op"
stray_kill "$fp"; pid_gone "$fp"; untrack "$fp"
pass "T6 stale per-entry token refuses signal, named recycled"

# ── T7: missing identity token is refused too ──────────────────────────
new_run
reg="$TW_TMP/notoken.pids"
sleep 60 & fp=$!
track "$fp"
printf '%s\n' "$fp" >>"$reg"   # bare line, no REGISTRY.identities at all
rc=0
tmp_writers_stop || rc=$?
[[ "$rc" -ne 0 ]] || fail "T7: tokenless live registry pid must fail"
alive "$fp" || fail "T7: tokenless foreign pid was signalled"
listed "$fp" || fail "T7: refused pid must appear in TW_LEFTOVER_PIDS"
stray_kill "$fp"; pid_gone "$fp"; untrack "$fp"
pass "T7 missing identity token refused"

# ── T8: tw_kill_pidfile — foreign survives, valid renamed script stops ──
new_run
sleep 60 & fp=$!
track "$fp"
mkdir -p "$TW_TMP/inbox/forged8"
printf '%s\nstarted=%s\n' "$fp" "$(date +%s)" \
  >"$TW_TMP/inbox/forged8/completion-sentinel.pid"
rc=0
tw_kill_pidfile "$TW_TMP/inbox/forged8/completion-sentinel.pid" || rc=$?
[[ "$rc" -ne 0 ]] || fail "T8: tw_kill_pidfile must refuse a foreign argv"
alive "$fp" || fail "T8: foreign pid was signalled"
stray_kill "$fp"; pid_gone "$fp"; untrack "$fp"
jobdir="$TW_TMP/inbox/job-t8"
mk_sentinel_script "$TW_TMP/mut-wrk-t8"
env SENT_JOBDIR="$jobdir" \
  bash "$TW_TMP/mut-wrk-t8" sentinel job-t8 lane lbl w1:p1 "$TW_TMP/r8.json" &
sp=$!
track "$sp"
wait_pidfile "$jobdir/completion-sentinel.pid" ||
  fail "T8: sentinel pidfile missing"
wait_pidfile "$jobdir/sentinel-child.pid" ||
  fail "T8: sentinel child pidfile missing"
track "$(cat "$jobdir/sentinel-child.pid")"
tw_kill_pidfile "$jobdir/completion-sentinel.pid" ||
  fail "T8: valid renamed-copy sentinel pidfile was refused"
pid_gone "$sp" || fail "T8: verified sentinel survived tw_kill_pidfile"
untrack "$sp"
# A pidfile outside this run's TW_TMP is refused even when it would verify.
mkdir -p "$HOME/outside"
printf '%s\nstarted=%s\n' "$sp" "$(date +%s)" \
  >"$HOME/outside/completion-sentinel.pid"
rc=0
tw_kill_pidfile "$HOME/outside/completion-sentinel.pid" || rc=$?
[[ "$rc" -ne 0 ]] || fail "T8: pidfile outside TW_TMP must be refused"
pass "T8 tw_kill_pidfile refuses foreign and out-of-run pidfiles"

# ── T9: own-session leader + TERM-immune descendant reaped ─────────────
new_run
cat >"$TW_TMP/orphan-leader.sh" <<'SH'
#!/usr/bin/env bash
( trap '' TERM; exec sleep 60 ) &
exec sleep 60
SH
tw_own_session bash "$TW_TMP/orphan-leader.sh" & sess=$!
track "$sess"
member="$(wait_group_member "$sess" || true)"
[[ "$member" =~ ^[0-9]+$ ]] || fail "T9: own-session member missing"
track "$member"
tmp_writers_stop || fail "T9: sweep failed (${TW_LEFTOVER_PIDS:-})"
dead "$sess" || fail "T9: own-session leader survived"
dead "$member" || fail "T9: TERM-immune descendant survived — no false success"
untrack "$sess"; untrack "$member"
pass "T9 own-session orphan + TERM-immune descendant reaped"

# ── T10: dead recorded own-session leader's orphan group is reaped ─────
new_run
tw_own_session bash -c '( trap "" TERM; exec sleep 60 ) & exec sleep 60' &
sess=$!
track "$sess"
member="$(wait_group_member "$sess" || true)"
[[ "$member" =~ ^[0-9]+$ ]] || fail "T10: own-session member missing"
track "$member"
kill -9 "$sess" 2>/dev/null || true
wait "$sess" 2>/dev/null || true
tmp_writers_stop || fail "T10: sweep failed (${TW_LEFTOVER_PIDS:-})"
dead "$member" ||
  fail "T10: dead recorded leader's orphan member was not reaped"
untrack "$sess"; untrack "$member"
pass "T10 self-recorded dead leader's group members reaped"

# ── T11: pending TERM-immune descendant of a NON-session parent ────────
# The parent leads no group of its own: only the pending-descendant
# ledger (with its captured start identity) can carry the child to the
# KILL rounds after the parent is gone.
new_run
reg="$TW_TMP/owned-pids"
bash -c '( trap "" TERM; exec sleep 60 ) & exec sleep 60' & par=$!
track "$par"
sleep 0.3
member="$(pgrep -P "$par" | head -n 1 || true)"
[[ "$member" =~ ^[0-9]+$ ]] || fail "T11: descendant missing"
track "$member"
[[ "$(ps -o pgid= -p "$par" | tr -d ' ')" != "$par" ]] ||
  fail "T11: parent must NOT be a group leader for this case"
tw_register_pid "$reg" "$par"
tmp_writers_stop || fail "T11: sweep failed (${TW_LEFTOVER_PIDS:-})"
dead "$par" || fail "T11: parent survived"
dead "$member" ||
  fail "T11: TERM-immune descendant survived — pending-member ledger failed"
untrack "$par"; untrack "$member"
pass "T11 pending descendant carried to KILL without group fallback"

# ── T12: a forged recent-start dead pidfile owns NO group ──────────────
# A foreign orphan group's dead leader pid is written into a pidfile as
# if it were ours (started= inside the run window). The group must not
# be touched: ownership needs verification or a self-record, never a
# timestamp.
new_run
# A foreign orphan group: own-session shape but launched with TW_TMP
# unset, so no self-record exists — ownership can never be established.
( unset TW_TMP; tw_own_session bash -c '( exec sleep 60 ) & exec sleep 1' ) &
fsess=$!
track "$fsess"
fmem="$(wait_group_member "$fsess" || true)"
[[ "$fmem" =~ ^[0-9]+$ ]] || fail "T12: foreign group member missing"
track "$fmem"
wait "$fsess" 2>/dev/null || true    # leader exits after ~1s on its own
pid_gone "$fsess" || fail "T12: foreign leader did not exit"
mkdir -p "$TW_TMP/inbox/forge-group"
printf '%s\nstarted=%s\n' "$fsess" "$(date +%s)" \
  >"$TW_TMP/inbox/forge-group/completion-sentinel.pid"
tmp_writers_stop || fail "T12: sweep failed (${TW_LEFTOVER_PIDS:-})"
alive "$fmem" ||
  fail "T12: forged recent-start pidfile let the sweep signal a foreign group"
stray_kill "$fmem"; pid_gone "$fmem"; untrack "$fmem"
untrack "$fsess"
pass "T12 forged recent-start dead pidfile owns no group"

# ── T13: stale entries scale — dead pids cost no repeated ps scans ──────
new_run
reg="$TW_TMP/stale.pids"
for i in $(seq 1 40); do
  dp="$(dead_pid)"
  mkdir -p "$TW_TMP/inbox/stale-$i"
  printf '%s\n' "$dp" >"$TW_TMP/inbox/stale-$i/completion-sentinel.pid"
done
for i in $(seq 1 20); do
  printf '%s\n' "$(dead_pid)" >>"$reg"
done
t0="$(date +%s)"
tmp_writers_stop || fail "T13: all-dead sweep must succeed"
elapsed=$(( $(date +%s) - t0 ))
(( elapsed < 20 )) ||
  fail "T13: dead-entry sweep took ${elapsed}s (repeated ps scans?)"
pass "T13 60 stale entries swept in ${elapsed}s"

# ── T14: ps-env / proc-environ source guard over tests/ ────────────────
# Filter for the AC regex `ps +[a-z-]*e[a-z]*` (word-matched): full-line
# comments and the one known JE35 echo literal are prose; every other
# match is a violation printed as path:line:text.
tw_ps_env_filter() {
  # stdin: grep -n "path:line:text"; print violations. Prose exemptions:
  # full-line comments, and exactly the one known echo command — the
  # literal is assembled so this file's own source carries no match.
  local ln file rest je35
  je35="JE35 diagnostic: p""s sentinel rows:"
  while IFS= read -r ln; do
    file="${ln%%:*}"; rest="${ln#*:}"; rest="${rest#*:}"
    [[ "$rest" =~ ^[[:space:]]*# ]] && continue
    [[ "$rest" =~ ^[[:space:]]*echo\ \"${je35}\"\ \>\&2[[:space:]]*$ ]] && continue
    printf '%s\n' "$ln"
  done
}
# in-memory self-test of the scanner (the flag-under-test is assembled so
# this file's own source stays clean of the pattern)
_e=e
_axe="ax${_e}ww"; _eLf="-${_e}f"
_je35="JE35 diagnostic: p""s sentinel rows:"
# in-memory self-test: raw source lines through the same grep -nw + filter
# pipeline the real scan uses. The exact known echo (with >&2) is prose;
# an injected-code echo or the phrase without the exact command is not.
self="$(printf '%s\n' \
  "ps $_axe" \
  "  ps $_eLf" \
  '  ps -o args= -p "$pid"' \
  "# ps $_axe was the old sweep" \
  "echo \"\$(ps $_axe)\"" \
  "echo \"${_je35}\" >&2" \
  "echo \"\$(ps $_axe)\"; echo \"${_je35}\" >&2" \
  "echo \"${_je35}\"" \
  | grep -nwE 'ps +[a-z-]*e[a-z]*' | sed 's/^/f:/' | tw_ps_env_filter)"
[[ "$self" == "f:1:ps ${_axe}"$'\n'"f:2:  ps ${_eLf}"$'\n'"f:5:echo \"\$(ps ${_axe})\""$'\n'"f:7:echo \"\$(ps ${_axe})\"; echo \"${_je35}\" >&2"$'\n'"f:8:echo \"${_je35}\"" ]] ||
  fail "T14: scanner self-test mismatch: $(printf '%q' "$self")"
viol="$(grep -rEnw 'ps +[a-z-]*e[a-z]*' "$ROOT/tests" 2>/dev/null \
        | tw_ps_env_filter || true)"
[[ -z "$viol" ]] || fail "T14: ps call with e modifier under tests/:
$viol"
_procpat='/proc/[^/ ]*'
pviol="$(grep -rEn "${_procpat}/env""iron" "$ROOT/tests" 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
[[ -z "$pviol" ]] || fail "T14: /proc environ read under tests/:
$pviol"
pass "T14 ps-env / proc-environ guard clean"

# ── T15: tw_register_pid tolerates the pid dying mid-registration ──────
# The pgid query may lose the process between identity capture and ps;
# under set -e/pipefail a failed ps must not abort the registration, and
# no group-ownership third field may be recorded for the vanished pid.
new_run
t15_out="$(
  set -euo pipefail
  reg="$TW_TMP/race.pids"
  sleep 60 & kpid=$!
  oident="$(_tw_pid_identity "$kpid")"
  [[ -n "$oident" ]] || exit 2
  rm -f "$TW_TMP/shim.hit"
  ps() {
    if [[ "$1" == "-o" && "${2:-}" == "pgid=" ]]; then
      # The pgid query runs after identity capture and before any write:
      # the identities file must not carry this pid yet.
      [[ ! -e "$reg.identities" ]] || return 8
      kill -9 "$kpid" 2>/dev/null
      wait "$kpid" 2>/dev/null || true   # not our child here; zombie is fine
      : >"$TW_TMP/shim.hit"              # fs beacon: ps runs in $( )
      return 1
    fi
    command ps "$@"
  }
  tw_register_pid "$reg" "$kpid" || exit 3
  [[ -e "$TW_TMP/shim.hit" ]] || exit 4
  # The recorded identity is the one captured before the process died.
  grep -q "^$kpid	$oident" "$reg.identities" || exit 5
  [[ "$(tail -n 1 "$reg")" == "$kpid" ]] || exit 6
  # No third (pgid) field: a vanished pid earns no group ownership.
  [[ -z "$(awk -F '\t' -v p="$kpid" '$1 == p { print $3 }' \
      "$reg.identities")" ]] || exit 7
  # And the now-dead pid is rejected by the per-entry check.
  _tw_registry_pid_ok "$kpid" "$reg" && exit 9
  printf 'inner-ok\n'
)" || t15_rc=$?
[[ "${t15_rc:-0}" == 0 && "$t15_out" == "inner-ok" ]] ||
  fail "T15: registration-race subtest rc=${t15_rc:-0} out=$t15_out"
pass "T15 tw_register_pid survives mid-registration death"

# ── T16: a fake-clock sentinel remains owned through its session record ─
new_run
jobdir="$TW_TMP/inbox/job-t16"
mkdir -p "$jobdir"
copy="$TW_TMP/fakeclock-wrk"
mk_sentinel_script "$copy"
python3 - "$copy" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = '"$(date +%s)"'
assert text.count(old) == 1, "expected one sentinel started timestamp expression"
open(path, "w", encoding="utf-8").write(text.replace(old, "1000", 1))
PY
wrapper="$TW_TMP/fakeclock-wrapper.sh"
cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
copy="$1"; jobdir="$2"
export SENT_JOBDIR="$jobdir"
bash "$copy" sentinel job-t16 lane lbl w1:p1 "$jobdir/report.json" &
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s "$jobdir/completion-sentinel.pid" &&
     -s "$jobdir/sentinel-child.pid" ]] && exit 0
  sleep 0.1
done
exit 1
SH
tw_own_session bash "$wrapper" "$copy" "$jobdir" &
leader=$!
track "$leader"
wait "$leader" || fail "T16: own-session wrapper did not finish"
record="$TW_TMP/tw-own-sessions/$leader"
[[ -s "$record" ]] || fail "T16: self-recorded session ownership missing"
IFS=$'\t' read -r record_pid record_ident record_pgid <"$record"
[[ "$record_pid" == "$leader" && "$record_pgid" == "$leader" &&
   -n "$record_ident" ]] || fail "T16: malformed session ownership record"
sentinel="$(head -n 1 "$jobdir/completion-sentinel.pid")"
child="$(cat "$jobdir/sentinel-child.pid")"
track "$sentinel"; track "$child"
started="$(_tw_pidfile_fields "$jobdir/completion-sentinel.pid")"
IFS=$'\t' read -r started_pid started_epoch <<<"$started"
[[ "$started_epoch" == 1000 ]] ||
  fail "T16: fixture did not preserve fake started=1000 ($started)"
sentinel_args="$(ps -p "$sentinel" -o args= 2>/dev/null)" ||
  fail "T16: sentinel argv unavailable"
_tw_sentinel_args_ok "$sentinel_args" "job-t16" "$jobdir" ||
  fail "T16: sentinel argv shape was not recognized"
if _tw_pidfile_verify "$jobdir/completion-sentinel.pid" "$sentinel" "$sentinel_args"; then
  fail "T16: stale fake-clock pidfile unexpectedly verified"
fi
dead "$leader" || fail "T16: own-session wrapper leader still alive"
tmp_writers_stop || fail "T16: sweep failed (${TW_LEFTOVER_PIDS:-})"
[[ -z "${TW_LEFTOVER_PIDS:-}" ]] ||
  fail "T16: leftovers after session-ledger reap:${TW_LEFTOVER_PIDS}"
dead "$sentinel" || fail "T16: fake-clock sentinel survived group reap"
dead "$child" || fail "T16: fake-clock sentinel child survived group reap"
untrack "$leader"; untrack "$sentinel"; untrack "$child"
grep -qF 'builder_grok_out="$(TEST_OWN_SESSION=1 ' "$ROOT/tests/test-wrk.sh" ||
  fail "T16: builder-grok fake-clock call lacks session opt-in"
grep -qF 'builder_kimi_out="$(TEST_OWN_SESSION=1 ' "$ROOT/tests/test-wrk.sh" ||
  fail "T16: builder-kimi fake-clock call lacks session opt-in"
grep -qF 'builder_luna_out="$(TEST_OWN_SESSION=1 ' "$ROOT/tests/test-wrk.sh" ||
  fail "T16: builder-luna fake-clock call lacks session opt-in"
pass "T16 fake-clock sentinel reaped by self-recorded own session"

# ── T17: group candidates are snapshotted before a slow first sweep ─────
new_run
jobdir="$TW_TMP/inbox/job-t17"
mkdir -p "$jobdir"
copy="$TW_TMP/fakeclock-slow-wrk"
mk_sentinel_script "$copy"
python3 - "$copy" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = '"$(date +%s)"'
assert text.count(old) == 1, "expected one sentinel started timestamp expression"
open(path, "w", encoding="utf-8").write(text.replace(old, "1000", 1))
PY
wrapper="$TW_TMP/fakeclock-slow-wrapper.sh"
cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
copy="$1"; jobdir="$2"
export SENT_JOBDIR="$jobdir"
bash "$copy" sentinel job-t17 lane lbl w1:p1 "$jobdir/report.json" &
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s "$jobdir/completion-sentinel.pid" &&
     -s "$jobdir/sentinel-child.pid" ]] && exit 0
  sleep 0.1
done
exit 1
SH
tw_own_session bash "$wrapper" "$copy" "$jobdir" &
leader=$!
track "$leader"
wait "$leader" || fail "T17: own-session wrapper did not finish"
record="$TW_TMP/tw-own-sessions/$leader"
[[ -s "$record" ]] || fail "T17: self-recorded session ownership missing"
IFS=$'\t' read -r record_pid record_ident record_pgid <"$record"
[[ "$record_pid" == "$leader" && "$record_pgid" == "$leader" &&
   -n "$record_ident" ]] || fail "T17: malformed session ownership record"
sentinel="$(head -n 1 "$jobdir/completion-sentinel.pid")"
child="$(cat "$jobdir/sentinel-child.pid")"
track "$sentinel"; track "$child"
started="$(_tw_pidfile_fields "$jobdir/completion-sentinel.pid")"
IFS=$'\t' read -r started_pid started_epoch <<<"$started"
[[ "$started_epoch" == 1000 ]] ||
  fail "T17: fixture did not preserve fake started=1000 ($started)"
sentinel_args="$(ps -p "$sentinel" -o args= 2>/dev/null)" ||
  fail "T17: sentinel argv unavailable"
_tw_sentinel_args_ok "$sentinel_args" "job-t17" "$jobdir" ||
  fail "T17: sentinel argv shape was not recognized"
if _tw_pidfile_verify "$jobdir/completion-sentinel.pid" "$sentinel" "$sentinel_args"; then
  fail "T17: stale fake-clock pidfile unexpectedly verified"
fi
dead "$leader" || fail "T17: own-session wrapper leader still alive"

eval "$(declare -f _tw_pidfile_verify | sed '1s/_tw_pidfile_verify/_t17_original_pidfile_verify/')"
t17_slow_once=0
_tw_pidfile_verify() {
  if (( t17_slow_once == 0 )); then
    t17_slow_once=1
    sleep 11
  fi
  _t17_original_pidfile_verify "$@"
}
t17_rc=0
tmp_writers_stop || t17_rc=$?
t17_slow_calls="$t17_slow_once"
eval "$(declare -f _t17_original_pidfile_verify | sed '1s/_t17_original_pidfile_verify/_tw_pidfile_verify/')"
unset -f _t17_original_pidfile_verify
unset t17_slow_once
[[ "$t17_slow_calls" == 1 ]] || fail "T17: verifier delay did not run exactly once"
[[ "$t17_rc" -eq 0 ]] ||
  fail "T17: first sweep missed pre-snapshot group members (rc=$t17_rc leftovers=${TW_LEFTOVER_PIDS:-})"
[[ -z "${TW_LEFTOVER_PIDS:-}" ]] ||
  fail "T17: leftovers after delayed first sweep:${TW_LEFTOVER_PIDS}"
dead "$sentinel" || fail "T17: fake-clock sentinel survived delayed first sweep"
dead "$child" || fail "T17: fake-clock child survived delayed first sweep"
untrack "$leader"; untrack "$sentinel"; untrack "$child"
pass "T17 first-sweep group candidates survive verifier delay"

# A self-record whose live leader identity mismatches is a candidate only:
# its group/member must remain untouched, and the leftover pass proves the
# leader recycled — named on TW_RECYCLED_PIDS, out of TW_LEFTOVER_PIDS.
new_run
wrapper="$TW_TMP/mismatch-wrapper.sh"
cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sleep 60 &
printf '%s\n' "$!" >"$1/member.pid"
wait
SH
tw_own_session bash "$wrapper" "$TW_TMP" &
proxy=$!
track "$proxy"
record="$TW_TMP/tw-own-sessions/$proxy"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s "$record" && -s "$TW_TMP/member.pid" ]] && break
  sleep 0.1
done
[[ -s "$record" && -s "$TW_TMP/member.pid" ]] ||
  fail "T17 negative: live proxy ownership fixtures missing"
member="$(cat "$TW_TMP/member.pid")"
track "$member"
IFS=$'\t' read -r record_pid record_ident record_pgid <"$record"
[[ "$record_pid" == "$proxy" && "$record_pgid" == "$proxy" &&
   -n "$record_ident" ]] || fail "T17 negative: malformed proxy record"
printf '%s\t%s\t%s\n' "$proxy" "mismatched-$record_ident" "$proxy" >"$record"
t17_rc=0
tmp_writers_stop || t17_rc=$?
[[ "$t17_rc" -eq 0 ]] ||
  fail "T17 negative: proven-recycled leader must not fail teardown"
listed "$proxy" &&
  fail "T17 negative: recycled leader stayed in TW_LEFTOVER_PIDS"
recycled "$proxy" ||
  fail "T17 negative: recycled leader missing from TW_RECYCLED_PIDS"
[[ -d "$TW_TMP" ]] || fail "T17 negative: TMP removed while proxy was alive"
alive "$proxy" || fail "T17 negative: mismatched live leader was signalled"
alive "$member" || fail "T17 negative: candidate group member was signalled"
# Clean only these explicitly tracked fixture pids, never their group.
stray_kill "$proxy"; stray_kill "$member"
wait "$proxy" 2>/dev/null || true
pid_gone "$proxy" || fail "T17 negative: proxy survived exact-pid cleanup"
pid_gone "$member" || fail "T17 negative: member survived exact-pid cleanup"
untrack "$proxy"; untrack "$member"
pass "T17 mismatched live session identity refuses leader and member"

# ── T18: the leftover pass separates proven-recycled from survivors ────
# Mutant invariant: a pid proven recycled never fails teardown, and a
# pid with a matching identity always does.
new_run
reg="$TW_TMP/reused.pids"
# A registered writer died and its number was reused by an unrelated
# test-owned process: the stored start identity belongs to the dead
# holder, not to the live process now carrying the pid.
sleep 0.2 & holder=$!
holder_ident="$(_tw_pid_identity "$holder" 2>/dev/null || true)"
[[ -n "$holder_ident" ]] || fail "T18: dead holder identity unavailable"
wait "$holder" 2>/dev/null || true
# macOS lstart has one-second granularity, and a live process's identity
# never changes. Launch the reuse process in a LATER second (the gap is
# over one full second) so its identity provably differs from the dead
# holder's on both platforms.
sleep 1
sleep 60 & reuse=$!
[[ "$(_tw_pid_identity "$reuse" 2>/dev/null || true)" != "$holder_ident" ]] ||
  fail "T18: fixture start identities did not diverge"
track "$reuse"
printf '%s\t%s\n' "$reuse" "$holder_ident" >>"$reg.identities"
printf '%s\n' "$reuse" >>"$reg"
rc=0
tmp_writers_stop || rc=$?
[[ "$rc" -eq 0 ]] ||
  fail "T18: proven-recycled registry pid failed teardown (${TW_LEFTOVER_PIDS:-})"
alive "$reuse" || fail "T18: recycled registry pid was signalled"
listed "$reuse" && fail "T18: recycled pid stayed in TW_LEFTOVER_PIDS"
recycled "$reuse" || fail "T18: recycled pid missing from TW_RECYCLED_PIDS"
stray_kill "$reuse"; pid_gone "$reuse"; untrack "$reuse"

# Same proof through a pidfile: the recorded writer started long ago, so
# the recently-started live pid cannot be it.
new_run
sleep 60 & fp=$!
track "$fp"
mkdir -p "$TW_TMP/inbox/reused-pf"
printf '%s\nstarted=%s\n' "$fp" "$(( $(date +%s) - 10000 ))" \
  >"$TW_TMP/inbox/reused-pf/completion-sentinel.pid"
rc=0
tmp_writers_stop || rc=$?
[[ "$rc" -eq 0 ]] ||
  fail "T18: proven-recycled pidfile pid failed teardown (${TW_LEFTOVER_PIDS:-})"
alive "$fp" || fail "T18: recycled pidfile pid was signalled"
listed "$fp" && fail "T18: recycled pidfile pid stayed in TW_LEFTOVER_PIDS"
recycled "$fp" || fail "T18: recycled pidfile pid missing from TW_RECYCLED_PIDS"
stray_kill "$fp"; pid_gone "$fp"; untrack "$fp"

# A live writer whose stored identity still matches is still a leftover:
# keep it alive by refusing its signal path only — the leftover pass
# must then count it and the run must return 1.
new_run
reg="$TW_TMP/match.pids"
sleep 60 & rp=$!
track "$rp"
tw_register_pid "$reg" "$rp"
eval "$(declare -f _tw_registry_pid_ok \
  | sed '1s/_tw_registry_pid_ok/_t18_orig_registry_pid_ok/')"
_tw_registry_pid_ok() { return 1; }
rc=0
tmp_writers_stop || rc=$?
eval "$(declare -f _t18_orig_registry_pid_ok \
  | sed '1s/_t18_orig_registry_pid_ok/_tw_registry_pid_ok/')"
unset -f _t18_orig_registry_pid_ok
[[ "$rc" -eq 1 ]] ||
  fail "T18: matching-identity live writer must fail teardown"
listed "$rp" || fail "T18: matching-identity writer missing from leftovers"
recycled "$rp" && fail "T18: matching-identity writer named recycled"
stray_kill "$rp"; pid_gone "$rp"; untrack "$rp"
pass "T18 leftover pass separates recycled from matching-identity pids"

# ── T19: leading-zero started= is decimal, never a fatal octal ─────────
# An invalid octal literal in the skew arithmetic is a fatal expansion
# error: it aborted the whole pass — rc 0 with no leftovers — hiding
# every later entry. The window checks must treat 08 as decimal.
new_run
sleep 60 & zpid=$!
track "$zpid"
sleep 60 & opid=$!
track "$opid"
mkdir -p "$TW_TMP/inbox/octal" "$TW_TMP/inbox/bare"
printf '%s\nstarted=08\n' "$zpid" >"$TW_TMP/inbox/octal/completion-sentinel.pid"
printf '%s\n' "$opid" >"$TW_TMP/inbox/bare/completion-sentinel.pid"
_tw_start_matches "$zpid" 08 &&
  fail "T19: started=08 must not match the live elapsed window"
_tw_pidfile_recycled "$zpid" 08 ||
  fail "T19: started=08 must be a positive recycling proof"
rc=0
tmp_writers_stop || rc=$?
[[ "$rc" -eq 1 ]] ||
  fail "T19: pass aborted instead of reporting the no-identity leftover"
listed "$opid" || fail "T19: no-identity pidfile pid missing from leftovers"
recycled "$zpid" || fail "T19: started=08 pid missing from TW_RECYCLED_PIDS"
alive "$zpid" || fail "T19: started=08 pid was signalled"
alive "$opid" || fail "T19: no-identity pid was signalled"
stray_kill "$zpid"; stray_kill "$opid"
pid_gone "$zpid" || fail "T19: zpid survived cleanup"
pid_gone "$opid" || fail "T19: opid survived cleanup"
untrack "$zpid"; untrack "$opid"
pass "T19 leading-zero started= stays decimal, no pass abort"

echo "PASS test-tmp-writers"
