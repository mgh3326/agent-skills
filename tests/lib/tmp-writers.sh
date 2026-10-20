# tests/lib/tmp-writers.sh — teardown detached writers by exact pid only.
#
# Replaces the old ps axeww teardown: no test may read another process's
# environment or kill by pattern. Every process this library signals is
# named by an exact pid this run knows, from exactly these sources:
#
#   1. pidfiles under the run's $TMP written by the process itself —
#      completion-sentinel.pid / sentinel.pid: the pid is signalled only
#      when its argv has `sentinel JOB …` directly after a wrk executable
#      position — the executable must be this repo's bin/wrk or a path
#      under this run's $TW_TMP (a renamed mutant copy still verifies; a
#      `bash -c …` program cannot), and the tokens after `sentinel` carry
#      this run's job id (or its jobdir under $TW_TMP) plus the required
#      trailing arguments — and, when the file recorded started=EPOCH, the
#      process's real elapsed matches (±120s, same window bin/wrk prune
#      uses);
#      quota-refresh.pid: the pid is signalled only when its argv is the
#      supervisor shape `python* - <scopefuel> <pool> <timeout> PIDFILE
#      <job>` — the pidfile it babysits sits at argv[5] — and its recorded
#      start matches. Both checks are ports of bin/wrk's own pid-reuse
#      guards.
#   2. pid registries written by this run — any `*.pids` (or `owned-pids`)
#      file under $TMP, plus extra paths passed to tmp_writers_stop: the
#      scopefuel fixture logs its own pid to WRK_REFRESH_PID_LOG, and tests
#      log pids they launched themselves (own → tw_register_pid). Every
#      registration also appends `PID<TAB>START-IDENTITY` to a companion
#      REGISTRY.identities file — Linux /proc/PID/stat start ticks, macOS
#      ps lstart — captured at registration time. A listed pid is
#      signalled only when its CURRENT start identity exactly equals the
#      stored entry; a missing or malformed identity, a pid recycled
#      after the write, or a foreign process sharing the line refuses —
#      there is no fallback to file mtime. The registry itself stays a
#      plain numeric-pid log for existing readers.
#   3. descendants of a verified pid, walked recursively with pgrep -P and
#      frozen with STOP as they are found — the STOP-first order is what
#      keeps a sentinel's interval sleep (or an in-flight probe/release
#      child) from being orphaned between the enumeration and the signal.
#      Found descendants stay pending across sweep rounds so a
#      TERM-immune child still takes the KILL after its parent dies.
#   4. the process group of a tracked pid — only when ownership is
#      established: the pid was verified while alive this sweep, or its
#      registration recorded pgid == pid (an observed group leader), or a
#      tw_own_session self-record under $TW_TMP/tw-own-sessions proves the
#      group is this run's own (a live recorded leader is signalled only
#      while its identity still matches the record). A stale pidfile or
#      an arbitrary registered pid owns no group. For a live verified
#      leader `kill -- -pid` reaps members the walk can no longer reach
#      (children already reparented to init stay in the group). For a
#      dead owned leader, group members are enumerated by exact pgid
#      (pgrep -g, never a whole-table scan) and signalled individually,
#      each still checked as this run's leftover (a bare `sleep N`, or an
#      argv carrying this run's $TMP or the repo root) that started
#      inside the run window — a stale numeric pidfile never owns a
#      group, and a pid recycled into a foreign group leader never
#      satisfies the member check.
#
# A pidfile or registry entry that fails its check is skipped, never
# signalled: a stale pidfile, a recycled pid, or a fake written to name an
# unrelated process is inert by construction — but it still shows up in
# TW_LEFTOVER_PIDS so the refusal is visible instead of hiding.
# tmp_writers_stop loops until every tracked pid is gone or a ~10s
# wall-clock deadline passes (TERM for the first half, KILL after), then
# returns nonzero with TW_LEFTOVER_PIDS set and the caller preserves TMP:
# no rm while a tracked writer lives. The leftover pass counts a live
# pid only while it can still be the tracked writer — its stored start
# identity matches, or none was ever recorded. A pid PROVEN recycled (a
# stored identity that differs from the live one) is a different process
# than the one this run tracked: it is named on its own line in
# TW_RECYCLED_PIDS for the log, never counted, never signalled.
#
# Public API:
#   TW_TMP=DIR                    — the run's tmp dir (set before teardown)
#   tmp_writers_stop [REG …]      — reap everything; extra registry paths
#                                   may be passed (files under $TW_TMP are
#                                   found anyway by the *.pids convention).
#                                   rc 0 = clean; rc 1 = live tracked
#                                   writers remain (TMP must be kept)
#   TW_LEFTOVER_PIDS              — tracked pids still alive when the bound
#                                   ran out (empty on success)
#   TW_RECYCLED_PIDS              — one pid per line: live pids proven
#                                   recycled (stored start identity
#                                   differs from the live one); excluded
#                                   from TW_LEFTOVER_PIDS, never signalled
#   tw_register_pid REGISTRY PID  — append PID to REGISTRY after recording
#                                   its start identity in REGISTRY.identities
#   tw_kill_pidfile FILE [SIG]    — verify one pidfile (argv + recorded
#                                   start) and kill its tree; rc 1 when the
#                                   pid is alive but refused
#   tw_kill_tree PID [SIG]        — STOP → kill descendants → group kill if
#                                   leader → kill pid → CONT (default TERM)
#   tw_own_session CMD …          — exec CMD in a new session so its whole
#                                   tree stays reachable by `kill -- -PID`;
#                                   use as `tw_own_session … & pid=$!`

# shellcheck shell=bash

TW_TMP=""
TW_LEFTOVER_PIDS=""
TW_RECYCLED_PIDS=""
TW_TRACKED_LOG="${TW_TRACKED_LOG:-}"
TW_RUN_START="$(date +%s)"
_TW_LAST_DESC=""
_TW_LAST_PGID=""

# _tw_track PID — when TW_TRACKED_LOG names a file, append each pid this
# run discovered (pidfiles, verified registries, descendants, group
# members) so the caller can kill -0 the exact tracked set afterwards.
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

# _tw_pid_identity PID — the process's start identity: Linux /proc stat
# start ticks (field 22, parsed after the comm ')' so a comm with spaces
# cannot shift it), macOS ps lstart. Fails when it cannot produce one —
# callers treat that as unverifiable, never as a fallback to file mtimes.
_tw_pid_identity() {
  local pid="$1" stat rest ident
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if [[ -d /proc ]]; then
    [[ -r "/proc/$pid/stat" ]] || return 1
    stat="$(<"/proc/$pid/stat")" || return 1
    rest="${stat##*) }"
    set -- $rest
    ident="${20:-}"
    [[ "$ident" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$ident"
    return 0
  fi
  ident="$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
  ident="${ident#"${ident%%[![:space:]]*}"}"
  ident="${ident%"${ident##*[![:space:]]}"}"
  [[ -n "$ident" ]] || return 1
  printf '%s\n' "$ident"
}

# tw_register_pid REGISTRY PID — the registration API every registry
# writer uses: record PID's start identity in REGISTRY.identities first
# (readers of the pid log only ever see the pid after its identity is
# stored), then append the bare pid line existing readers expect. When the
# pid already leads its own process group at registration time a third
# `pgid` field is recorded — the only way a registry entry can later own a
# dead leader's orphan group (a registered arbitrary pid is not group
# ownership). Write failures are loud: a lost live-writer registration
# must not fail silently.
tw_register_pid() {
  local reg="$1" pid="$2" ident="" pgid="" extra=""
  [[ -n "$reg" && "$pid" =~ ^[0-9]+$ ]] || return 1
  ident="$(_tw_pid_identity "$pid" 2>/dev/null || true)"
  pgid="$( { ps -o pgid= -p "$pid" 2>/dev/null || true; } | tr -d '[:space:]')"
  [[ -n "$pgid" && "$pgid" == "$pid" ]] && extra=$'\t'"$pgid"
  if [[ -n "$ident" ]]; then
    printf '%s\t%s%s\n' "$pid" "$ident" "$extra" >>"$reg.identities" || return 1
  fi
  printf '%s\n' "$pid" >>"$reg"
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

# _tw_lstart_epoch LSTART — epoch seconds for an LC_ALL=C `ps lstart`
# timestamp ("Www Mmm DD HH:MM:SS YYYY" on both GNU and BSD ps). Fails on
# unparseable input.
_tw_lstart_epoch() {
  python3 - "$1" <<'PY'
import sys, time
try:
    print(int(time.mktime(time.strptime(sys.argv[1], "%a %b %d %H:%M:%S %Y"))))
except Exception:
    raise SystemExit(1)
PY
}

# _tw_sentinel_args_ok ARGS JOB JOBDIR — the argv is this job's sentinel
# only when `sentinel JOB OWNER LABEL PANE [REPORT …]` sits directly
# after the executable position: the bare executable, or one shell token
# then the script path. The executable token must be this repo's bin/wrk
# or a path under this run's $TW_TMP — a renamed mutant copy passes,
# while `sentinel` inside a `bash -c` program or another tool's argv does
# not. JOBDIR (the directory the pidfile sits in) is accepted in place of
# the bare job id. Port of bin/wrk's sentinel_pid_matches.
_tw_sentinel_args_ok() {
  local args="$1" job="$2" jobdir="$3"
  [[ -n "$args" ]] || return 1
  awk -v job="$job" -v jobdir="$jobdir" \
      -v wrk="${ROOT:-}" -v tmp="${TW_TMP:-}" '
    function is_shell(tok) { sub(/^.*\//, "", tok); return tok ~ /^(sh|bash|zsh|dash|ksh)$/ }
    function is_wrk_path(tok) {
      return (wrk != "" && tok == wrk "/bin/wrk") ||
             (tmp != "" && index(tok, tmp "/") == 1)
    }
    {
      for (i = 1; i + 5 <= NF; i++)
        if ((i == 1 || (i == 2 && is_shell($1))) && is_wrk_path($i) &&
            $(i + 1) == "sentinel" &&
            ($(i + 2) == job || $(i + 2) == jobdir))
          { found = 1; break }
    }
    END { exit(found ? 0 : 1) }' <<<"$args"
}

_tw_sentinel_argv_ok() {
  local pid="$1" job="$2" jobdir="${3:-}" args
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  args="$(ps -p "$pid" -o args= 2>/dev/null)" || return 1
  _tw_sentinel_args_ok "$args" "$job" "$jobdir"
}

# _tw_supervisor_args_ok ARGS PIDFILE — the refresh supervisor's argv is
# `python* - <scopefuel> <pool> <timeout> THIS-PIDFILE <job>`: the pidfile
# it babysits sits at argv[5]. Port of bin/wrk's
# refresh_supervisor_argv_matches.
_tw_supervisor_args_ok() {
  local args="$1" pidfile="$2"
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

_tw_supervisor_argv_ok() {
  local pid="$1" pidfile="$2" args
  args="$(ps -p "$pid" -o args= 2>/dev/null)" || return 1
  [[ -n "$args" ]] || return 1
  _tw_supervisor_args_ok "$args" "$pidfile"
}

# _tw_pidfile_verify FILE PID ARGS — the per-kind pidfile check used by
# both the sweep and tw_kill_pidfile: argv shape plus the recorded start.
_tw_pidfile_verify() {
  local file="$1" pid="$2" args="$3" kind job jobdir started
  kind="${file##*/}"
  jobdir="${file%/"$kind"}"
  case "$kind" in
    completion-sentinel.pid|sentinel.pid)
      job="${jobdir##*/}"
      IFS=$'\t' read -r _ started <<<"$(_tw_pidfile_fields "$file")"
      { _tw_sentinel_args_ok "$args" "$job" "$jobdir" &&
        _tw_start_matches "$pid" "$started"; }
      ;;
    quota-refresh.pid)
      IFS=$'\t' read -r _ started <<<"$(_tw_pidfile_fields "$file")"
      { _tw_supervisor_args_ok "$args" "$file" &&
        _tw_start_matches "$pid" "$started"; }
      ;;
    *) return 1 ;;
  esac
}

# _tw_registered_identity PID FILE — the start identity REGISTRY recorded
# for PID (tab-separated field 2; last matching line wins). Empty output
# means this registry never captured one for the pid.
_tw_registered_identity() {
  awk -v p="$1" -F '\t' '$1 == p { i = $2 } END { printf "%s", i }' \
    "$2" 2>/dev/null
}

# _tw_registered_pgid PID FILE — field 3 of PID's identities entry: the
# process group it led at registration time. Only `pgid == pid` is ever
# recorded, so a nonempty result is proof the registered pid owned its
# group — registration of an arbitrary pid alone proves nothing.
_tw_registered_pgid() {
  awk -v p="$1" -F '\t' '$1 == p { i = $3 } END { printf "%s", i }' \
    "$2" 2>/dev/null
}

# _tw_registry_pid_ok PID REGISTRY — a registry-listed pid is this run's
# only when its CURRENT start identity exactly equals the identity the
# registration captured: a pid recycled after the write, a foreign
# process named by a stale earlier line, or an entry with no recorded
# identity all refuse. No mtime window is consulted.
_tw_registry_pid_ok() {
  local pid="$1" reg="$2" ident cur
  _tw_pid_alive "$pid" || return 1
  [[ -f "$reg.identities" ]] || return 1
  ident="$(_tw_registered_identity "$pid" "$reg.identities")"
  [[ -n "$ident" ]] || return 1
  cur="$(_tw_pid_identity "$pid" 2>/dev/null)" || return 1
  [[ -n "$cur" && "$cur" == "$ident" ]]
}

# _tw_identity_recycled PID STORED — rc 0 only as positive proof of
# recycling: a stored start identity exists, the live pid's current
# identity is readable, and they differ. An empty stored identity (the
# pid was never verified) or an unreadable current one is no proof —
# callers keep reporting the pid as before.
_tw_identity_recycled() {
  local pid="$1" stored="${2:-}" cur
  [[ -n "$stored" ]] || return 1
  cur="$(_tw_pid_identity "$pid" 2>/dev/null)" || return 1
  [[ -n "$cur" && "$cur" != "$stored" ]]
}

# _tw_pidfile_recycled PID STARTED — the pidfile form of the same proof:
# rc 0 only when the file recorded a numeric started= epoch AND the live
# pid's real elapsed provably disagrees with it (outside the ±120s window
# _tw_start_matches uses). A missing or malformed started= is no proof.
_tw_pidfile_recycled() {
  local pid="$1" started="${2:-}" el skew
  [[ "$started" =~ ^[0-9]+$ ]] || return 1
  el="$(_tw_elapsed_s "$pid" 2>/dev/null)" || return 1
  skew=$(( $(date +%s) - started - el ))
  (( skew < -120 || skew > 120 ))
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
      _tw_track "$c"
      printf '%s\n' "$c"
      queue+=("$c")
    done < <(pgrep -P "$p" 2>/dev/null || true)
  done
}

# tw_kill_tree PID [SIG] — signal PID's whole tree. STOP the root first so
# it cannot fork a fresh child or exit mid-walk; descendants are frozen as
# they are found, signalled, then released with CONT so a pending TERM can
# land — the found list is left in _TW_LAST_DESC so a TERM-immune child
# can stay pending across sweep rounds. When PID leads its own group the
# group takes the same signal — orphaned members the walk cannot reach die
# with it; the queried pgid is left in _TW_LAST_PGID so the caller can tell
# observed group leadership from a generic verified pid. A dead PID is
# never treated as group ownership here — the sweep's ownership-aware
# group ledger reaps dead leaders' groups. SIG defaults to -TERM.
tw_kill_tree() {
  local pid="$1" sig="${2:--TERM}" desc d pgid
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  _TW_LAST_DESC=""
  _TW_LAST_PGID=""
  if _tw_pid_alive "$pid"; then
    kill -STOP "$pid" 2>/dev/null || true
    desc="$(_tw_descendants "$pid")"
    _TW_LAST_DESC="$desc"
    while IFS= read -r d; do
      [[ -n "$d" ]] && kill "$sig" "$d" 2>/dev/null || true
    done <<<"$desc"
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    _TW_LAST_PGID="$pgid"
    if [[ "$pgid" == "$pid" ]]; then
      kill "$sig" -- "-$pid" 2>/dev/null || true
    fi
    kill "$sig" "$pid" 2>/dev/null || true
    kill -CONT "$pid" 2>/dev/null || true
    while IFS= read -r d; do
      [[ -n "$d" ]] && kill -CONT "$d" 2>/dev/null || true
    done <<<"$desc"
  fi
}

# tw_kill_pidfile FILE [SIG] — verify the pid named by one pidfile under
# this run's $TMP (per-kind argv shape plus the recorded start) and kill
# its tree. rc 0 when the pid is gone or was verified and signalled; rc 1
# when a live pid was refused — the refusal is still visible through the
# sweep's TW_LEFTOVER_PIDS pass.
tw_kill_pidfile() {
  local file="$1" sig="${2:--TERM}" pid args
  [[ -f "$file" ]] || return 0
  # Only this run's own pidfiles are actionable — a path outside $TW_TMP
  # is refused even when its contents would otherwise verify.
  [[ -n "${TW_TMP:-}" && "$file" == "$TW_TMP/"* ]] || return 1
  IFS=$'\t' read -r pid _ <<<"$(_tw_pidfile_fields "$file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  _tw_track "$pid"
  _tw_pid_alive "$pid" || return 0
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  _tw_pidfile_verify "$file" "$pid" "$args" || return 1
  tw_kill_tree "$pid" "$sig"
}

# tw_stop_sentinels DIR — argv-verified, start-checked STOP-walk-TERM of
# every sentinel named by a completion-sentinel.pid under DIR. A mid-suite
# reap (some suites reset fixture logs between cases and want the earlier
# spawns' sentinels gone); same checks as the teardown's pidfile pass, no
# wait loop.
tw_stop_sentinels() {
  local dir="$1" pf
  [[ -n "$dir" && -d "$dir" ]] || return 0
  while IFS= read -r pf; do
    tw_kill_pidfile "$pf" || true
  done < <(find "$dir" -type f -name 'completion-sentinel.pid' 2>/dev/null || true)
}

# tw_own_session CMD … — exec CMD as the leader of a new session (pgid ==
# its pid), so the group stays reachable by `kill -- -PID` even after the
# leader dies. After setsid and before exec it self-records ownership
# under $TW_TMP/tw-own-sessions/<pid> (pid, start identity, pgid) so the
# sweep can recover the orphan group even if the leader dies before any
# registry registration. Meant for `tw_own_session … & pid=$!` launches;
# python3 is the portable setsid (macOS has no setsid(1)).
tw_own_session() {
  exec python3 -c '
import os, sys
os.setsid()
tmp = os.environ.get("TW_TMP", "")
pid = str(os.getpid())
ident = ""
if tmp:
    try:
        stat = open("/proc/self/stat").read()
        ident = stat.rsplit(")", 1)[1].split()[19]
    except Exception:
        try:
            import subprocess
            ident = subprocess.check_output(
                ["ps", "-o", "lstart=", "-p", pid],
                env={"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}
            ).decode().strip()
        except Exception:
            ident = ""
    if ident:
        try:
            d = os.path.join(tmp, "tw-own-sessions")
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, pid), "w") as f:
                f.write("%s\t%s\t%s\n" % (pid, ident, os.getpgrp()))
        except OSError:
            pass
os.execvp(sys.argv[1], sys.argv[1:])' "$@"
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

# _tw_list_has LIST PID — membership in a space-separated pid ledger.
_tw_list_has() {
  [[ " $1 " == *" $2 "* ]]
}

# _tw_snap_field SNAP PID COL — one whitespace field from the snapshot.
_tw_snap_field() {
  awk -v p="$2" -v c="$3" '$1 == p { print $c; exit }' <<<"$1"
}

# _tw_snap_args SNAP PID — the args tail of a `pid stat lstart args` row:
# lstart in LC_ALL=C is always five tokens, so args begins at field 8.
_tw_snap_args() {
  awk -v p="$2" '$1 == p { for (i = 1; i <= 7; i++) $i = ""; sub(/^ +/, "");
                            print; exit }' <<<"$1"
}

# _tw_snap_lstart SNAP PID — the five-token LC_ALL=C lstart field.
_tw_snap_lstart() {
  awk -v p="$2" '$1 == p { print $3, $4, $5, $6, $7; exit }' <<<"$1"
}

# _tw_member_id PID — the start identity captured when a pending member
# was found; reads the "pid<TAB>ident" ledger on stdin.
_tw_member_id() {
  awk -F '\t' -v p="$1" '$1 == p { print $2; exit }'
}

# tmp_writers_stop [REGISTRY …] — reap every tracked writer under $TW_TMP
# and wait until none remains, bounded by a ~10s wall-clock deadline
# (TERM for the first five seconds, KILL after; five quiet 0.1s rounds
# settle the run). Each round takes ONE snapshot — `ps -o
# pid=,stat=,lstart=,args= -p <exact tracked pid list>` — never a
# whole-table scan, never an environment read; known orphan groups'
# members are enumerated by exact pgid (pgrep -g) BEFORE the snapshot so
# their rows come from it too. Dead entries are cached, so stale pidfiles
# cost no further process state. Verified descendants and orphan group
# members stay pending across rounds — each with the start identity
# captured when it was found, re-verified before every later signal — so
# a TERM-immune child still takes the KILL and a recycled member pid is
# never signalled. rc 0 when nothing tracked remains alive; rc 1 with
# TW_LEFTOVER_PIDS set otherwise — the caller must then preserve $TW_TMP
# instead of rm -rf'ing it. Live pids whose stored start identity
# provably differs (the tracked writer died and the number was reused)
# do not count: they are named one per line on TW_RECYCLED_PIDS instead.
tmp_writers_stop() {
  local round_start sig quiet=0 alive deadline now
  local pf reg pid started kind args stat dp cur
  local sfile spid sident spgid
  local tracked commalist snap members_at_snap gtok group_candidates
  local -a _TW_EXTRA_REGS=("$@")
  local _TW_DEAD="" _TW_OWNED="" _TW_GROUPS="" _TW_MEMBERS=""
  local _TW_MEMBERS_NEW="" _TW_MEMBERS_UNVER="" _TW_MEMBER_IDS=""
  local g glist gmembers gm="" mpid margs mstat mident mstored mepoch mlstart
  local next_members kept groups_prev
  local stored="" recycled=""
  TW_LEFTOVER_PIDS=""
  TW_RECYCLED_PIDS=""
  [[ -n "${TW_TMP:-}" && -d "$TW_TMP" ]] || return 0
  round_start="$(date +%s)"
  deadline=$(( round_start + 10 ))
  while :; do
    now="$(date +%s)"
    (( now >= deadline )) && break
    alive=0
    if (( now - round_start >= 5 )); then sig=-KILL; else sig=-TERM; fi
    _TW_MEMBERS_NEW=""
    groups_prev="$_TW_GROUPS"
    # 0. collect this round's tracked pids (dead entries are cached and
    #    never re-read). Group candidates come from prior authorization,
    #    self-recorded sessions, and registry entries that recorded
    #    pgid == pid. They are only snapshot candidates here, not yet
    #    authority to signal a group.
    tracked="$_TW_MEMBERS $_TW_MEMBERS_UNVER"
    group_candidates="$_TW_GROUPS"
    gm=""
    while IFS= read -r pf; do
      IFS=$'\t' read -r pid _ <<<"$(_tw_pidfile_fields "$pf")"
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      _tw_track "$pid"
      _tw_list_has "$_TW_DEAD" "$pid" || tracked="$tracked $pid"
    done < <(find "$TW_TMP" -type f \
               \( -name 'completion-sentinel.pid' -o -name 'sentinel.pid' \
                  -o -name 'quota-refresh.pid' \) 2>/dev/null || true)
    while IFS= read -r reg; do
      [[ -f "$reg" ]] || continue
      while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        _tw_list_has "$_TW_DEAD" "$pid" || tracked="$tracked $pid"
      done <"$reg"
      if [[ -f "$reg.identities" ]]; then
        while IFS= read -r g; do
          [[ "$g" =~ ^[0-9]+$ ]] || continue
          _tw_list_has "$group_candidates" "$g" ||
            group_candidates="$group_candidates $g"
        done < <(awk -F '\t' \
          '$1 ~ /^[0-9]+$/ && $2 != "" && $3 ~ /^[0-9]+$/ && $1 == $3 { print $3 }' \
          "$reg.identities" 2>/dev/null)
      fi
    done < <(_tw_registries)
    while IFS= read -r sfile; do
      IFS=$'\t' read -r spid sident spgid <"$sfile" 2>/dev/null || continue
      [[ "$spid" =~ ^[0-9]+$ ]] || continue
      _tw_track "$spid"
      _tw_list_has "$_TW_DEAD" "$spid" || tracked="$tracked $spid"
      if [[ "$spid" == "$spgid" && -n "$sident" ]]; then
        _tw_list_has "$group_candidates" "$spgid" ||
          group_candidates="$group_candidates $spgid"
      fi
    done < <(find "$TW_TMP/tw-own-sessions" -type f 2>/dev/null || true)
    # Enumerate all candidate groups by exact pgid before the one snapshot.
    # Candidates only add PIDs to that snapshot; step 5 still requires the
    # independent authorized _TW_GROUPS ledger before signalling members.
    for g in $group_candidates; do
      [[ "$g" =~ ^[0-9]+$ ]] || continue
      gmembers="$(pgrep -g "$g" 2>/dev/null | tr -s ' \n' ',,' || true)"
      gmembers="${gmembers#,}"; gmembers="${gmembers%,}"
      [[ -n "$gmembers" ]] || continue
      gm="$gm $g:$gmembers"
      tracked="$tracked ${gmembers//,/ }"
    done
    # 1. the round's single process snapshot: pid, state, start, argv of
    #    exactly this run's tracked pids (plus pending members and known
    #    orphan-group members).
    commalist="$(tr -s ' ' ',' <<<"${tracked# }")"
    commalist="${commalist#,}"; commalist="${commalist%,}"
    snap=""
    [[ -n "$commalist" ]] &&
      snap="$(LC_ALL=C ps -o pid=,stat=,lstart=,args= -p "$commalist" 2>/dev/null || true)"
    members_at_snap="$_TW_MEMBERS"
    # 2. pidfiles the writers wrote about themselves. A live pid is
    #    signalled only after the per-kind argv + recorded-start checks
    #    pass; a dead one frees its group only when it was verified while
    #    alive this sweep — a stale or forged numeric pidfile owns no
    #    group, whatever timestamp it carries.
    while IFS= read -r pf; do
      kind="${pf##*/}"
      IFS=$'\t' read -r pid started <<<"$(_tw_pidfile_fields "$pf")"
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      _tw_list_has "$_TW_DEAD" "$pid" && continue
      stat="$(_tw_snap_field "$snap" "$pid" 2)"
      if [[ -n "$stat" && "$stat" != Z* ]]; then
        args="$(_tw_snap_args "$snap" "$pid")"
        if _tw_pidfile_verify "$pf" "$pid" "$args"; then
          _tw_track "$pid"
          tw_kill_tree "$pid" "$sig"
          [[ "${_TW_LAST_PGID:-}" == "$pid" ]] && _TW_OWNED="$_TW_OWNED $pid"
          for dp in $_TW_LAST_DESC; do
            mident="$(_tw_pid_identity "$dp" 2>/dev/null || true)"
            if [[ -n "$mident" ]]; then
              { _tw_list_has "$_TW_MEMBERS" "$dp" ||
                _tw_list_has "$_TW_MEMBERS_NEW" "$dp"; } ||
                { _TW_MEMBERS_NEW="$_TW_MEMBERS_NEW $dp"
                  _TW_MEMBER_IDS="$_TW_MEMBER_IDS$dp"$'\t'"$mident"$'\n'; }
            else
              _tw_list_has "$_TW_MEMBERS_UNVER" "$dp" ||
                _TW_MEMBERS_UNVER="$_TW_MEMBERS_UNVER $dp"
            fi
          done
          alive=1
        fi
      else
        _TW_DEAD="$_TW_DEAD $pid"
        if _tw_list_has "$_TW_OWNED" "$pid"; then
          _tw_list_has "$_TW_GROUPS" "$pid" || _TW_GROUPS="$_TW_GROUPS $pid"
        fi
      fi
    done < <(find "$TW_TMP" -type f \
               \( -name 'completion-sentinel.pid' -o -name 'sentinel.pid' \
                  -o -name 'quota-refresh.pid' \) 2>/dev/null || true)
    # 3. registries written by this run (per-entry start identities). A
    #    dead entry owns its group only when its registration recorded
    #    pgid == pid (an observed group leader), or it was verified while
    #    alive this sweep — an arbitrary registered pid owns no group.
    while IFS= read -r reg; do
      [[ -f "$reg" ]] || continue
      while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        _tw_list_has "$_TW_DEAD" "$pid" && continue
        stat="$(_tw_snap_field "$snap" "$pid" 2)"
        if [[ -n "$stat" && "$stat" != Z* ]]; then
          if _tw_registry_pid_ok "$pid" "$reg"; then
            _tw_track "$pid"
            tw_kill_tree "$pid" "$sig"
            [[ "${_TW_LAST_PGID:-}" == "$pid" ]] && _TW_OWNED="$_TW_OWNED $pid"
            for dp in $_TW_LAST_DESC; do
              mident="$(_tw_pid_identity "$dp" 2>/dev/null || true)"
              if [[ -n "$mident" ]]; then
                { _tw_list_has "$_TW_MEMBERS" "$dp" ||
                  _tw_list_has "$_TW_MEMBERS_NEW" "$dp"; } ||
                  { _TW_MEMBERS_NEW="$_TW_MEMBERS_NEW $dp"
                    _TW_MEMBER_IDS="$_TW_MEMBER_IDS$dp"$'\t'"$mident"$'\n'; }
              else
                _tw_list_has "$_TW_MEMBERS_UNVER" "$dp" ||
                  _TW_MEMBERS_UNVER="$_TW_MEMBERS_UNVER $dp"
              fi
            done
            alive=1
          fi
        else
          _TW_DEAD="$_TW_DEAD $pid"
          if _tw_list_has "$_TW_OWNED" "$pid" ||
             { [[ -f "$reg.identities" ]] &&
               [[ "$(_tw_registered_pgid "$pid" "$reg.identities")" == "$pid" ]]; }; then
            _tw_list_has "$_TW_GROUPS" "$pid" || _TW_GROUPS="$_TW_GROUPS $pid"
          fi
        fi
      done <"$reg"
    done < <(_tw_registries)
    # 4. self-recorded own-session leaders ($TW_TMP/tw-own-sessions/):
    #    the record was written between setsid and exec, so the stored
    #    identity is this run's proof of group ownership. A dead recorded
    #    leader frees its recorded pgid; a live one is signalled only
    #    while its current identity still matches the record — a recycled
    #    pid leading the group is never signalled (its members are still
    #    checked individually through the group pass).
    while IFS= read -r sfile; do
      IFS=$'\t' read -r spid sident spgid <"$sfile" 2>/dev/null || continue
      [[ "$spid" =~ ^[0-9]+$ && "$spgid" =~ ^[0-9]+$ ]] || continue
      _tw_list_has "$_TW_DEAD" "$spid" && continue
      stat="$(_tw_snap_field "$snap" "$spid" 2)"
      if [[ -n "$stat" && "$stat" != Z* ]]; then
        cur="$(_tw_pid_identity "$spid" 2>/dev/null || true)"
        if [[ -n "$sident" && "$cur" == "$sident" ]]; then
          _tw_track "$spid"
          tw_kill_tree "$spid" "$sig"
          [[ "${_TW_LAST_PGID:-}" == "$spid" ]] && _TW_OWNED="$_TW_OWNED $spid"
          for dp in $_TW_LAST_DESC; do
            mident="$(_tw_pid_identity "$dp" 2>/dev/null || true)"
            if [[ -n "$mident" ]]; then
              { _tw_list_has "$_TW_MEMBERS" "$dp" ||
                _tw_list_has "$_TW_MEMBERS_NEW" "$dp"; } ||
                { _TW_MEMBERS_NEW="$_TW_MEMBERS_NEW $dp"
                  _TW_MEMBER_IDS="$_TW_MEMBER_IDS$dp"$'\t'"$mident"$'\n'; }
            else
              _tw_list_has "$_TW_MEMBERS_UNVER" "$dp" ||
                _TW_MEMBERS_UNVER="$_TW_MEMBERS_UNVER $dp"
            fi
          done
          alive=1
        fi
        # A live recorded leader whose identity no longer matches the
        # record is a recycled pid: it is never signalled and its group
        # is never enqueued — it just stays visible as a leftover.
      else
        _TW_DEAD="$_TW_DEAD $spid"
        _tw_list_has "$_TW_GROUPS" "$spgid" || _TW_GROUPS="$_TW_GROUPS $spgid"
      fi
    done < <(find "$TW_TMP/tw-own-sessions" -type f 2>/dev/null || true)
    # 5. pending orphan groups: candidates were enumerated by exact pgid
    #    before the snapshot, but only independently authorized groups
    #    may signal members. Each member still verifies as this run's
    #    leftover argv and started inside the run window (snapshot lstart).
    for gtok in $gm; do
      g="${gtok%%:*}"; glist="${gtok#*:}"
      _tw_list_has "$_TW_GROUPS" "$g" || continue
      for mpid in ${glist//,/ }; do
        [[ "$mpid" =~ ^[0-9]+$ ]] || continue
        [[ "$mpid" == "$g" ]] && continue
        mstat="$(_tw_snap_field "$snap" "$mpid" 2)"
        [[ -n "$mstat" && "$mstat" != Z* ]] || continue
        margs="$(_tw_snap_args "$snap" "$mpid")"
        _tw_leftover_argv_ok "$margs" || continue
        mlstart="$(_tw_snap_lstart "$snap" "$mpid")"
        mepoch="$(_tw_lstart_epoch "$mlstart" 2>/dev/null)" || continue
        (( mepoch >= TW_RUN_START - 5 && mepoch <= now + 5 )) || continue
        kill "$sig" "$mpid" 2>/dev/null || true
        _tw_track "$mpid"
        mident="$(_tw_pid_identity "$mpid" 2>/dev/null || true)"
        if [[ -n "$mident" ]]; then
          { _tw_list_has "$_TW_MEMBERS" "$mpid" ||
            _tw_list_has "$_TW_MEMBERS_NEW" "$mpid"; } ||
            { _TW_MEMBERS_NEW="$_TW_MEMBERS_NEW $mpid"
              _TW_MEMBER_IDS="$_TW_MEMBER_IDS$mpid"$'\t'"$mident"$'\n'; }
        else
          _tw_list_has "$_TW_MEMBERS_UNVER" "$mpid" ||
            _TW_MEMBERS_UNVER="$_TW_MEMBERS_UNVER $mpid"
        fi
        alive=1
      done
    done
    # A group stays pending while pgrep still reports members (gm was
    # built from this round's live pgrep); groups with no members left
    # are dropped, groups queued this round keep until first scan.
    kept=""
    for g in $_TW_GROUPS; do
      if _tw_list_has "$groups_prev" "$g"; then
        [[ " $gm " == *" $g:"* ]] && kept="$kept $g"
      else
        kept="$kept $g"
      fi
    done
    _TW_GROUPS="$kept"
    # 6. pending members found before this round's snapshot: verify each
    #    one's CURRENT identity against what was captured at discovery
    #    before re-signalling — a recycled member pid is never touched.
    #    Members found this round (_TW_MEMBERS_NEW) are not in snap, so
    #    they carry over untouched until the next snapshot sees them.
    next_members=""
    for mpid in $members_at_snap; do
      mstat="$(_tw_snap_field "$snap" "$mpid" 2)"
      [[ -n "$mstat" && "$mstat" != Z* ]] || continue
      mstored="$(_tw_member_id "$mpid" <<<"$_TW_MEMBER_IDS")"
      cur="$(_tw_pid_identity "$mpid" 2>/dev/null || true)"
      [[ -n "$mstored" && "$cur" == "$mstored" ]] || continue
      kill "$sig" "$mpid" 2>/dev/null || true
      next_members="$next_members $mpid"
      alive=1
    done
    _TW_MEMBERS="${next_members# }$_TW_MEMBERS_NEW"
    if (( alive == 0 )); then
      # five quiet rounds (0.5s) with no live tracked pid: enough slack for
      # a just-forked supervisor's pidfile to land before the caller rm's.
      (( ++quiet >= 5 )) && break
    else
      quiet=0
    fi
    sleep 0.1
  done
  # Report leftovers: every live pid found in this run's own pidfiles,
  # registries and session records — including ones verification refused
  # — plus pending members still alive. A live pid counts as a leftover
  # only while it can still be the tracked writer: its stored start
  # identity still matches (pidfile started= inside the ±120s window;
  # registry/session/member identity byte-equal), or none was ever
  # recorded so it was never verified. A pid PROVEN recycled — a stored
  # identity that differs from the live one — is a different process
  # than the writer this run tracked: it is named on its own line in
  # TW_RECYCLED_PIDS for the log, never counted, and (as in every pass
  # here) never signalled. A refused live writer still shows up as a
  # leftover instead of hiding, and a nonzero return keeps the caller
  # from rm -rf'ing TMP.
  # Pass one: prove recycling per source so a pid named by several
  # records is excluded by ANY of them — a no-identity listing elsewhere
  # cannot resurrect a pid another record proves dead-and-reused.
  while IFS= read -r pf; do
    IFS=$'\t' read -r pid started <<<"$(_tw_pidfile_fields "$pf")"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    _tw_pid_alive "$pid" || continue
    _tw_list_has "$recycled" "$pid" && continue
    _tw_pidfile_recycled "$pid" "$started" &&
      recycled="$recycled $pid"
  done < <(find "$TW_TMP" -type f \
             \( -name 'completion-sentinel.pid' -o -name 'sentinel.pid' \
                -o -name 'quota-refresh.pid' \) 2>/dev/null || true)
  while IFS= read -r reg; do
    [[ -f "$reg" ]] || continue
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      _tw_pid_alive "$pid" || continue
      _tw_list_has "$recycled" "$pid" && continue
      stored=""
      [[ -f "$reg.identities" ]] &&
        stored="$(_tw_registered_identity "$pid" "$reg.identities")"
      _tw_identity_recycled "$pid" "$stored" &&
        recycled="$recycled $pid"
    done <"$reg"
  done < <(_tw_registries)
  while IFS= read -r sfile; do
    IFS=$'\t' read -r spid sident _ <"$sfile" 2>/dev/null || continue
    [[ "$spid" =~ ^[0-9]+$ ]] || continue
    _tw_pid_alive "$spid" || continue
    _tw_list_has "$recycled" "$spid" && continue
    _tw_identity_recycled "$spid" "$sident" &&
      recycled="$recycled $spid"
  done < <(find "$TW_TMP/tw-own-sessions" -type f 2>/dev/null || true)
  for mpid in $_TW_MEMBERS; do
    _tw_pid_alive "$mpid" || continue
    _tw_list_has "$recycled" "$mpid" && continue
    mstored="$(_tw_member_id "$mpid" <<<"$_TW_MEMBER_IDS")"
    _tw_identity_recycled "$mpid" "$mstored" &&
      recycled="$recycled $mpid"
  done
  for pid in $recycled; do
    TW_RECYCLED_PIDS="${TW_RECYCLED_PIDS}${pid}"$'\n'
  done
  # Pass two: leftovers are the live tracked pids no record proved
  # recycled.
  while IFS= read -r pf; do
    IFS=$'\t' read -r pid _ <<<"$(_tw_pidfile_fields "$pf")"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    _tw_pid_alive "$pid" || continue
    _tw_list_has "$recycled" "$pid" && continue
    TW_LEFTOVER_PIDS="$TW_LEFTOVER_PIDS $pid"
  done < <(find "$TW_TMP" -type f \
             \( -name 'completion-sentinel.pid' -o -name 'sentinel.pid' \
                -o -name 'quota-refresh.pid' \) 2>/dev/null || true)
  while IFS= read -r reg; do
    [[ -f "$reg" ]] || continue
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      _tw_pid_alive "$pid" || continue
      _tw_list_has "$recycled" "$pid" && continue
      TW_LEFTOVER_PIDS="$TW_LEFTOVER_PIDS $pid"
    done <"$reg"
  done < <(_tw_registries)
  while IFS= read -r sfile; do
    IFS=$'\t' read -r spid _ _ <"$sfile" 2>/dev/null || continue
    [[ "$spid" =~ ^[0-9]+$ ]] || continue
    _tw_pid_alive "$spid" || continue
    _tw_list_has "$recycled" "$spid" && continue
    TW_LEFTOVER_PIDS="$TW_LEFTOVER_PIDS $spid"
  done < <(find "$TW_TMP/tw-own-sessions" -type f 2>/dev/null || true)
  for mpid in $_TW_MEMBERS $_TW_MEMBERS_UNVER; do
    _tw_pid_alive "$mpid" || continue
    _tw_list_has "$recycled" "$mpid" && continue
    TW_LEFTOVER_PIDS="$TW_LEFTOVER_PIDS $mpid"
  done
  [[ -z "$TW_LEFTOVER_PIDS" ]]
}
