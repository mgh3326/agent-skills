# tests/lib/tmp-writers.sh — teardown detached writers by exact pid only.
#
# Replaces the old ps axeww teardown: no test may read another process's
# environment or kill by pattern. Every process this library signals is
# named by an exact pid this run knows, from exactly these sources:
#
#   1. pidfiles under the run's $TMP written by the process itself —
#      completion-sentinel.pid / sentinel.pid: the pid is signalled only
#      when its argv is literally `…/wrk sentinel <jobdir-name> …` and, when
#      the file recorded started=EPOCH, the process's real elapsed matches
#      (±120s, same window bin/wrk prune uses);
#      quota-refresh.pid: the pid is signalled only when its argv is the
#      supervisor shape `python* - <scopefuel> <pool> <timeout> PIDFILE
#      <job>` — the pidfile it babysits sits at argv[5] — and its recorded
#      start matches. Both checks are ports of bin/wrk's own pid-reuse
#      guards.
#   2. pid registries written by this run — any `*.pids` (or `owned-pids`)
#      file under $TMP, plus extra paths passed to tmp_writers_stop: the
#      scopefuel fixture logs its own pid to WRK_REFRESH_PID_LOG, and tests
#      log pids they launched themselves (own). A listed pid is signalled
#      only when it started inside this run's window (its elapsed cannot
#      exceed the time since this file was sourced, +5s slack) AND before
#      the registry's last write (its start must precede mtime +5s) — a pid
#      recycled after the write, or a foreign process that predates the
#      run, fails one side and is never signalled.
#   3. descendants of a verified pid, walked recursively with pgrep -P and
#      frozen with STOP as they are found — the STOP-first order is what
#      keeps a sentinel's interval sleep (or an in-flight probe/release
#      child) from being orphaned between the enumeration and the signal.
#   4. the process group of a tracked pid — only when the pid is itself
#      the group leader (setsid'd supervisors, sentinels a test launched
#      through tw_own_session). For a live verified leader `kill -- -pid`
#      reaps members the walk can no longer reach (children already
#      reparented to init stay in the group). For a dead leader, group
#      members are enumerated and signalled individually, each still
#      checked as this run's leftover (a bare `sleep N`, or an argv
#      carrying this run's $TMP or the repo root) that started inside the
#      run window — a pid recycled into a foreign group leader never
#      satisfies that.
#
# A pidfile or registry entry that fails its check is skipped, never
# signalled: a stale pidfile, a recycled pid, or a fake written to name an
# unrelated process is inert by construction. tmp_writers_stop loops until
# every tracked pid is gone (or the ~10s bound), then the caller rm -rf's:
# no rm while a tracked writer lives, matching the old bound.
#
# Public API:
#   TW_TMP=DIR                    — the run's tmp dir (set before teardown)
#   tmp_writers_stop [REG …]      — reap everything; extra registry paths
#                                   may be passed (files under $TW_TMP are
#                                   found anyway by the *.pids convention)
#   TW_LEFTOVER_PIDS              — tracked pids still alive when the bound
#                                   ran out (empty on success)
#   tw_kill_tree PID [SIG]        — STOP → kill descendants → group kill if
#                                   leader → kill pid → CONT (default TERM)
#   tw_own_session CMD …          — exec CMD in a new session so its whole
#                                   tree stays reachable by `kill -- -PID`;
#                                   use as `tw_own_session … & pid=$!`

# shellcheck shell=bash

TW_TMP=""
TW_LEFTOVER_PIDS=""
TW_TRACKED_LOG="${TW_TRACKED_LOG:-}"
TW_RUN_START="$(date +%s)"
_TW_ORPHAN_HITS=0

# _tw_track PID — when TW_TRACKED_LOG names a file, append each pid this
# run signals so the caller can kill -0 the exact tracked set afterwards.
_tw_track() {
  [[ -z "$TW_TRACKED_LOG" ]] || printf '%s\n' "$1" >>"$TW_TRACKED_LOG" 2>/dev/null || true
}

# ── process facts ────────────────────────────────────────────────────────

# _tw_pid_alive PID — kill -0 alone reports zombies alive; a reparented
# corpse is not a writer.
_tw_pid_alive() {
  local pid="$1" state
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  state="$(ps -p "$pid" -o stat= 2>/dev/null || true)"
  state="${state//[[:space:]]/}"
  [[ "$state" == Z* ]] && return 1
  return 0
}

# _tw_elapsed_s PID — process age in seconds from ps etime (macOS has no
# etimes); unparseable output fails. Port of bin/wrk's proc_elapsed_s.
_tw_elapsed_s() {
  local pid="$1" etime
  etime="$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')" || return 1
  [[ -n "$etime" ]] || return 1
  python3 - "$etime" <<'PY'
import re, sys
match = re.fullmatch(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)", sys.argv[1])
if not match:
    raise SystemExit(1)
days, hours, minutes, seconds = (int(g) if g else 0 for g in match.groups())
print(days * 86400 + hours * 3600 + minutes * 60 + seconds)
PY
}

# _tw_mtime FILE — file mtime as epoch (portable via python3, no stat
# dialect split between GNU and BSD).
_tw_mtime() {
  python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' \
    "$1" 2>/dev/null
}

# ── identity checks (ports of bin/wrk's pid-reuse guards) ───────────────

# _tw_pidfile_fields FILE — "pid<TAB>started" from either pidfile shape
# ("PID\nstarted=EPOCH", bare "PID", or flat "pid=N … started=E").
_tw_pidfile_fields() {
  local file="$1" line="" extra="" tok pid="" started=""
  if [[ -s "$file" ]]; then
    { IFS= read -r line; IFS= read -r extra || extra=""; } <"$file" 2>/dev/null || true
    for tok in $line $extra; do
      case "$tok" in
        pid=*) pid="${tok#pid=}" ;;
        started=*) started="${tok#started=}" ;;
        *)
          if [[ -z "$pid" && "$tok" =~ ^[0-9]+$ ]]; then pid="$tok"; fi ;;
      esac
    done
  fi
  printf '%s\t%s\n' "$pid" "$started"
}

# _tw_start_matches PID STARTED — when the pidfile recorded a start time,
# the live process's real elapsed must agree (±120s skew). No recorded
# start means no verdict — same call as bin/wrk's sentinel_start_matches.
_tw_start_matches() {
  local pid="$1" started="${2:-}" el skew
  [[ -n "$started" ]] || return 0
  [[ "$started" =~ ^[0-9]+$ ]] || return 1
  el="$(_tw_elapsed_s "$pid" 2>/dev/null)" || return 1
  skew=$(( $(date +%s) - started - el ))
  (( skew >= -120 && skew <= 120 ))
}

# _tw_sentinel_argv_ok PID JOB — the recorded pid is this job's sentinel
# only when its argv is literally `…/wrk sentinel JOB OWNER LABEL PANE
# [REPORT …]`. Port of bin/wrk's sentinel_pid_matches.
_tw_sentinel_argv_ok() {
  local pid="$1" job="$2"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  ps -p "$pid" -o args= 2>/dev/null | awk -v job="$job" '
    function is_shell(tok) { sub(/^.*\//, "", tok); return tok ~ /^(sh|bash|zsh|dash|ksh)$/ }
    {
      for (i = 1; i <= NF; i++)
        if ($i ~ /(^|\/)wrk$/ && $(i + 1) == "sentinel" && $(i + 2) == job &&
            NF >= i + 5 && (i == 1 || (i == 2 && is_shell($1)))) { found = 1; break }
    }
    END { exit(found ? 0 : 1) }'
}

# _tw_supervisor_argv_ok PID PIDFILE — the refresh supervisor's argv is
# `python* - <scopefuel> <pool> <timeout> THIS-PIDFILE <job>`: the pidfile
# it babysits sits at argv[5]. Port of bin/wrk's
# refresh_supervisor_argv_matches.
_tw_supervisor_argv_ok() {
  local pid="$1" pidfile="$2" args
  args="$(ps -p "$pid" -o args= 2>/dev/null)" || return 1
  [[ -n "$args" ]] || return 1
  python3 - "$args" "$pidfile" <<'PY'
import shlex, sys
args, pidfile = sys.argv[1], sys.argv[2]
try:
    toks = shlex.split(args)
except ValueError:
    toks = args.split()
ok = (len(toks) >= 6 and "python" in toks[0].rsplit("/", 1)[-1].lower()
      and toks[1] == "-" and toks[5] == pidfile)
sys.exit(0 if ok else 1)
PY
}

# _tw_registry_pid_ok PID MTIME — a registry-listed pid is this run's only
# when it started inside the run's window and before the registry's last
# write: elapsed <= run-age + slack (a foreign process that predates the
# run fails), and now-elapsed <= mtime + slack (a pid recycled after the
# write fails). Both bounds use start time only — no environments.
_tw_registry_pid_ok() {
  local pid="$1" mtime="$2" el now
  _tw_pid_alive "$pid" || return 1
  el="$(_tw_elapsed_s "$pid" 2>/dev/null)" || return 1
  now="$(date +%s)"
  (( el <= now - TW_RUN_START + 5 )) || return 1
  (( now - el <= mtime + 5 )) || return 1
  return 0
}

# _tw_leftover_argv_ok ARGS — a dead tracked leader's group member still
# counts as this run's leftover only when its argv is a bare `sleep N` (the
# sentinel interval child) or carries this run's $TMP / the repo root.
_tw_leftover_argv_ok() {
  local margs="$1"
  case "$margs" in
    "sleep "[0-9]*) return 0 ;;
  esac
  if [[ -n "${TW_TMP:-}" && "$margs" == *"$TW_TMP"* ]]; then return 0; fi
  if [[ -n "${ROOT:-}" && "$margs" == *"$ROOT"* ]]; then return 0; fi
  return 1
}

# ── signalling ──────────────────────────────────────────────────────────

# _tw_descendants PID — print every descendant of PID. Each pid is STOP'd
# as it is found so it can neither fork a new child mid-walk nor die and
# re-parent its own children out of the walk.
_tw_descendants() {
  local root="$1" queue=() p c
  queue+=("$root")
  while ((${#queue[@]} > 0)); do
    p="${queue[0]}"
    queue=("${queue[@]:1}")
    while IFS= read -r c; do
      [[ "$c" =~ ^[0-9]+$ ]] || continue
      kill -STOP "$c" 2>/dev/null || true
      printf '%s\n' "$c"
      queue+=("$c")
    done < <(pgrep -P "$p" 2>/dev/null || true)
  done
}

# _tw_reap_orphan_group PGID SIG — PGID names a tracked pid that is already
# dead. When it was a group leader its group can outlive it (children
# reparented to init keep the pgid); signal each remaining member that
# still verifies as this run's leftover (_tw_leftover_argv_ok) and started
# inside the run window. A pid recycled into a foreign group leader fails
# the member check. Sets _TW_ORPHAN_HITS to the signalled count.
_tw_reap_orphan_group() {
  local pgid="$1" sig="$2" mpid margs el
  _TW_ORPHAN_HITS=0
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 0
  while IFS=$'\t' read -r mpid margs; do
    [[ "$mpid" =~ ^[0-9]+$ ]] || continue
    _tw_leftover_argv_ok "$margs" || continue
    el="$(_tw_elapsed_s "$mpid" 2>/dev/null)" || continue
    (( el <= $(date +%s) - TW_RUN_START + 5 )) || continue
    kill "$sig" "$mpid" 2>/dev/null || true
    _TW_ORPHAN_HITS=$(( _TW_ORPHAN_HITS + 1 ))
  done < <(ps axo pid=,pgid=,args= 2>/dev/null \
             | awk -v g="$pgid" '$2 == g && $1 != g {
                 rest = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", rest);
                 print $1 "\t" rest }')
}

# tw_kill_tree PID [SIG] — signal PID's whole tree. STOP the root first so
# it cannot fork a fresh child or exit mid-walk; descendants are frozen as
# they are found, signalled, then released with CONT so a pending TERM can
# land. When PID leads its own group the group takes the same signal —
# orphaned members the walk cannot reach die with it. A dead PID is passed
# to _tw_reap_orphan_group. SIG defaults to -TERM.
tw_kill_tree() {
  local pid="$1" sig="${2:--TERM}" desc d pgid
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  if _tw_pid_alive "$pid"; then
    kill -STOP "$pid" 2>/dev/null || true
    desc="$(_tw_descendants "$pid")"
    while IFS= read -r d; do
      [[ -n "$d" ]] && kill "$sig" "$d" 2>/dev/null || true
    done <<<"$desc"
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$pgid" == "$pid" ]]; then
      kill "$sig" -- "-$pid" 2>/dev/null || true
    fi
    kill "$sig" "$pid" 2>/dev/null || true
    kill -CONT "$pid" 2>/dev/null || true
    while IFS= read -r d; do
      [[ -n "$d" ]] && kill -CONT "$d" 2>/dev/null || true
    done <<<"$desc"
  else
    _tw_reap_orphan_group "$pid" "$sig"
  fi
}

# tw_stop_sentinels DIR — argv-verified, start-checked STOP-walk-TERM of
# every sentinel named by a completion-sentinel.pid under DIR. A mid-suite
# reap (some suites reset fixture logs between cases and want the earlier
# spawns' sentinels gone); same checks as the teardown's pidfile pass, no
# wait loop.
tw_stop_sentinels() {
  local dir="$1" pf pid started job
  [[ -n "$dir" && -d "$dir" ]] || return 0
  while IFS= read -r pf; do
    IFS=$'\t' read -r pid started <<<"$(_tw_pidfile_fields "$pf")"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    job="${pf%/completion-sentinel.pid}"; job="${job##*/}"
    { _tw_sentinel_argv_ok "$pid" "$job" &&
      _tw_start_matches "$pid" "$started"; } || continue
    tw_kill_tree "$pid"
  done < <(find "$dir" -type f -name 'completion-sentinel.pid' 2>/dev/null || true)
}

# tw_own_session CMD … — exec CMD as the leader of a new session (pgid ==
# its pid), so the group stays reachable by `kill -- -PID` even after the
# leader dies. Meant for `tw_own_session … & pid=$!` launches; python3 is
# the portable setsid (macOS has no setsid(1)).
tw_own_session() {
  exec python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
}

# _tw_registries — every pid registry for this run: the *.pids / owned-pids
# convention under $TW_TMP plus any extra paths tmp_writers_stop was given.
_tw_registries() {
  {
    find "$TW_TMP" -type f \( -name '*.pids' -o -name 'owned-pids' \) 2>/dev/null
    for reg in ${_TW_EXTRA_REGS[@]+"${_TW_EXTRA_REGS[@]}"}; do
      printf '%s\n' "$reg"
    done
  } | sort -u
}

# ── the sweep ────────────────────────────────────────────────────────────

# tmp_writers_stop [REGISTRY …] — reap every tracked writer under $TW_TMP
# and wait until none remains, up to the ~10s bound the old sweeps used
# (100 × 0.1s rounds; TERM for the first half, KILL after). Sets
# TW_LEFTOVER_PIDS to any tracked pids still alive at the bound.
tmp_writers_stop() {
  local round sig quiet=0 alive
  local pf reg mtime pid started kind job
  local -a _TW_EXTRA_REGS=("$@")
  [[ -n "${TW_TMP:-}" && -d "$TW_TMP" ]] || return 0
  for ((round = 0; round < 100; round++)); do
    alive=0
    if (( round >= 50 )); then sig=-KILL; else sig=-TERM; fi
    # 1. pidfiles the writers wrote about themselves. A live pid is
    #    signalled only after the per-kind argv + recorded-start checks
    #    pass; a dead one only frees its group of verified leftovers.
    while IFS= read -r pf; do
      kind="${pf##*/}"
      IFS=$'\t' read -r pid started <<<"$(_tw_pidfile_fields "$pf")"
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      if _tw_pid_alive "$pid"; then
        case "$kind" in
          completion-sentinel.pid|sentinel.pid)
            job="${pf%/"$kind"}"; job="${job##*/}"
            { _tw_sentinel_argv_ok "$pid" "$job" &&
              _tw_start_matches "$pid" "$started"; } || continue
            ;;
          quota-refresh.pid)
            { _tw_supervisor_argv_ok "$pid" "$pf" &&
              _tw_start_matches "$pid" "$started"; } || continue
            ;;
          *) continue ;;
        esac
        _tw_track "$pid"
        tw_kill_tree "$pid" "$sig"
        alive=1
      else
        tw_kill_tree "$pid" "$sig"
        (( _TW_ORPHAN_HITS > 0 )) && alive=1
      fi
    done < <(find "$TW_TMP" -type f \
               \( -name 'completion-sentinel.pid' -o -name 'sentinel.pid' \
                  -o -name 'quota-refresh.pid' \) 2>/dev/null || true)
    # 2. registries written by this run.
    while IFS= read -r reg; do
      [[ -f "$reg" ]] || continue
      mtime="$(_tw_mtime "$reg")" || continue
      [[ "$mtime" =~ ^[0-9]+$ ]] || continue
      while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        if _tw_pid_alive "$pid"; then
          _tw_registry_pid_ok "$pid" "$mtime" || continue
          _tw_track "$pid"
          tw_kill_tree "$pid" "$sig"
          alive=1
        else
          tw_kill_tree "$pid" "$sig"
          (( _TW_ORPHAN_HITS > 0 )) && alive=1
        fi
      done <"$reg"
    done < <(_tw_registries)
    if (( alive == 0 )); then
      # five quiet rounds (0.5s) with no live tracked pid: enough slack for
      # a just-forked supervisor's pidfile to land before the caller rm's.
      (( ++quiet >= 5 )) && break
    else
      quiet=0
    fi
    sleep 0.1
  done
  # Report leftovers: verified tracked pids still alive after the bound.
  TW_LEFTOVER_PIDS=""
  while IFS= read -r pf; do
    kind="${pf##*/}"
    IFS=$'\t' read -r pid started <<<"$(_tw_pidfile_fields "$pf")"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    _tw_pid_alive "$pid" || continue
    case "$kind" in
      completion-sentinel.pid|sentinel.pid)
        job="${pf%/"$kind"}"; job="${job##*/}"
        { _tw_sentinel_argv_ok "$pid" "$job" &&
          _tw_start_matches "$pid" "$started"; } || continue
        ;;
      quota-refresh.pid)
        { _tw_supervisor_argv_ok "$pid" "$pf" &&
          _tw_start_matches "$pid" "$started"; } || continue
        ;;
      *) continue ;;
    esac
    TW_LEFTOVER_PIDS="$TW_LEFTOVER_PIDS $pid"
  done < <(find "$TW_TMP" -type f \
             \( -name 'completion-sentinel.pid' -o -name 'sentinel.pid' \
                -o -name 'quota-refresh.pid' \) 2>/dev/null || true)
  while IFS= read -r reg; do
    [[ -f "$reg" ]] || continue
    mtime="$(_tw_mtime "$reg")" || continue
    [[ "$mtime" =~ ^[0-9]+$ ]] || continue
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      if _tw_registry_pid_ok "$pid" "$mtime"; then
        TW_LEFTOVER_PIDS="$TW_LEFTOVER_PIDS $pid"
      fi
    done <"$reg"
  done < <(_tw_registries)
  return 0
}
