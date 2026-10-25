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
# hk 1894: trust-bearing wrk and arbiter commands honour this suite's temp-dir overrides
# (HOME, ARBITER_INBOX_ROOT, XDG_DATA_HOME, HANDOFFKEEP_BIN) only in test mode.
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="${WRK_TEST_BIN:-$ROOT/bin/wrk}"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="${ARBITER_TEST_BIN:-$ROOT/bin/arbiter}"
PANEWIRE="$ROOT/tests/fixtures/panewire"
HK="$ROOT/tests/fixtures/handoffkeep"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wrk-job-end.XXXXXX")"
# shellcheck disable=SC1091
. "$ROOT/tests/lib/tmp-writers.sh"
export TW_TMP="$TMP"

# OWNED_PID_LOG — the process registry. Every fixture process this file
# launches appends its pid; cleanup terminates exactly that set. Works
# across subshells (mutant cases run in ( … )), unlike a shell array. The
# owned-pids name is part of tests/lib/tmp-writers.sh's registry
# convention, so teardown picks it up without being told.
OWNED_PID_LOG="$TMP/owned-pids"; : >"$OWNED_PID_LOG"
own() { [[ "$1" =~ ^[0-9]+$ ]] || return 0; tw_register_pid "$OWNED_PID_LOG" "$1"; }

kill_owned_tree() {
  # Same discipline as production stop_completion_sentinel: freeze, reap
  # the children, TERM, CONT so a STOPped fixture actually exits — plus the
  # group/leader pass tests/lib/tmp-writers.sh adds for own-session
  # fixtures and orphaned members.
  tw_kill_tree "$1"
}

cleanup() {
  # tmp_writers_stop reaps every tracked writer by an exact verified pid —
  # this registry, the *.pids fixture logs, the sentinel/refresh pidfiles,
  # descendant walks and test-owned process groups — and waits until none
  # remain before the rm. It never reads another process's environment and
  # never kills by pattern.
  local tw_rc=0
  tmp_writers_stop || tw_rc=$?
  (( tw_rc == 0 )) && rm -rf "$TMP"
  if [[ "$tw_rc" -ne 0 || -n "${TW_LEFTOVER_PIDS:-}" ]]; then
    echo "FAIL: tracked writers survived teardown:${TW_LEFTOVER_PIDS:-}" >&2
    exit 1
  fi
}
trap cleanup EXIT

PROMPT="$TMP/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"
export CLINEPASS_GATE_KEY_FILE="$TMP/clinepass-gate-key.txt"
printf 'fixture-gate-key\n' >"$CLINEPASS_GATE_KEY_FILE"
export WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml"

# hk1798 round 2: no invocation this file makes may fall back to the
# operator's tools — a wrk call that forgets its fixture env resolves the
# repo's stub arbiter/scopefuel and a throwaway XDG home, never the live
# ~/.local/bin or ~/.local/share. Per-call env still wins where a case needs
# its own stub.
export ARBITER_BIN="$ARBITER" SCOPEFUEL_BIN="$SCOPEFUEL"
export XDG_DATA_HOME="$TMP/xdg-default"
mkdir -p "$XDG_DATA_HOME"

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

arb() {
  env SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" "$ARBITER" "$@"
}

# fixture_claim_event JOB KIND PAYLOAD_JSON — writes a claim-kind events artifact
# straight into JOB's events dir, numbered and shaped the way arbiter's writer
# does: next prefix, same file name, same sorted JSON body, same clock as
# ARBITER_TEST_NOW. Only the DB row is skipped, because arbiter event refuses
# claim kinds. Each call site says why arbiter claim cannot mint its scenario.
fixture_claim_event() {
  python3 - "$INBOX/$1/events" "$1" "$2" "$3" <<'PY'
import datetime, json, os, re, sys
events, job, kind, payload = sys.argv[1:5]
fixed = os.environ.get("ARBITER_TEST_NOW") or ""
moment = datetime.datetime.fromisoformat(fixed) if fixed else datetime.datetime.now(datetime.timezone.utc)
seq = max((int(name[:5]) for name in os.listdir(events) if re.match(r"\d{5}-", name)), default=0) + 1
body = json.dumps({"created_at": moment.replace(microsecond=0).isoformat(), "job_id": job, "kind": kind,
                   "payload": json.loads(payload), "seq": seq}, ensure_ascii=False, sort_keys=True)
with open(os.path.join(events, "%05d-%s.json" % (seq, kind)), "x", encoding="utf-8") as handle:
    handle.write(body + "\n")
PY
}

# mk_job JOB [PANE] — claim + job.spawned receipt, the smallest live-job record.
mk_job() {
  arb claim --job "$1" --lane lane-a --agent-label lbl --t T1 >/dev/null
  arb event --job "$1" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl\",\"pane_id\":\"${2:-w:p1}\"}" >/dev/null
}

# hk 1449: a builder join needs one non-voided recorded round. The seed file's
# name is not a numeric prefix, so event numbering is unchanged.
seed_join_round() {
  local root="$1" job="$2"
  local events="$root/$job/events"
  mkdir -p "$events"
  if [[ -e "$events/seed-job.round.json" ]]; then
    return 0
  fi
  printf '%s\n' "{\"kind\":\"job.round\",\"job_id\":\"$job\",\"round\":1,\"head\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}" >"$events/seed-job.round.json"
  # hk 1900: a round counts toward the join only with a recorded verdict.
  printf '%s\n' "{\"kind\":\"job.verdict\",\"job_id\":\"$job\",\"round\":1,\"head\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"verdict\":\"PASS\"}" >"$events/seed-job.verdict.json"
}

mk_builder_job() {
  arb claim --job "$1" --lane builder-lane --agent-label lbl --t T1 \
    --role builder --parent-lane parent-lane >/dev/null
  arb event --job "$1" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"builder-lane\",\"label\":\"lbl\",\"pane_id\":\"${2:-w:p1}\"}" >/dev/null
  seed_join_round "$INBOX" "$1"
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
  # tw_own_session gives the sentinel its own process group (pgid == its
  # pid): a mutant or a mid-run kill that drops the child reaping still
  # leaves the interval sleep inside a group teardown can name exactly —
  # `kill -- -SENTINEL_PID` reaches orphans that re-parented to init.
  tw_own_session env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" \
    ARBITER_BIN="${RECOVERY_ARBITER:-$ARBITER}" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    ${RECOVERY_STUB_LOG:+RECOVERY_STUB_LOG="$RECOVERY_STUB_LOG"} \
    WRK_FIXTURE_SCENARIO="${SCENARIO:-sentinel-working}" \
    ${seq:+WRK_FIXTURE_GET_SEQUENCE="$seq"} \
    WRK_COMPLETION_TIMEOUT_S="${SENT_TIMEOUT:-300}" \
    WRK_COMPLETION_INTERVAL_S="${SENT_INTERVAL:-3600}" \
    WRK_SENTINEL_TRANSIENT_MAX="${TRANSIENT_MAX:-10}" \
    WRK_SENTINEL_LOST_GRACE="${LOST_GRACE:-1800}" \
    "$WRK" sentinel "$job" "${SENT_OWNER:-lane-a}" lbl "$pane" "$report" >/dev/null 2>&1 &
  SENTINEL_PID=$!
  own "$SENTINEL_PID"
  mkdir -p "$INBOX/$job"
  printf '%s\n' "$SENTINEL_PID" >"$INBOX/$job/completion-sentinel.pid"
}

# Quota stub for the sentinel's release_job_quota_pool. The real arbiter is
# left alone: the sentinel gets this executable and its case-local XDG/inbox.
recovery_arm_stub() {
  RECOVERY_ARBITER="$TMP/recovery-arbiter-$CASE_SEQ"
  RECOVERY_STUB_LOG="$TMP/recovery-stub-$CASE_SEQ.log"
  : >"$RECOVERY_STUB_LOG"
  cat >"$RECOVERY_ARBITER" <<EOF
#!/bin/bash
set -euo pipefail
if [[ "\${1:-}" == status ]]; then
  job=""
  while ((\$#)); do
    if [[ "\$1" == --job && \$# -ge 2 ]]; then job="\$2"; break; fi
    shift
  done
  printf '{"quota_pool_records":[{"job_id":"%s","pool":"claude"}]}\\n' "\$job"
  exit 0
fi
if [[ "\${1:-}" == release ]]; then
  printf '%s\\n' "\$*" >>"$RECOVERY_STUB_LOG"
  exit 0
fi
exit 0
EOF
  chmod +x "$RECOVERY_ARBITER"
}

recovery_release_count() {
  local n=0
  if [[ -n "${RECOVERY_ARBITER:-}" && -f "$TMP/recovery-stub-$CASE_SEQ.log" ]]; then
    n="$(grep -c '^release ' "$TMP/recovery-stub-$CASE_SEQ.log" || true)"
  fi
  printf '%s\n' "${n:-0}"
}

# recovery_release_count_is N — wait_until target: polls the stub log so a
# release that lands just after the job.revoked event still counts (macOS
# ordering raced the single-read check, hk 1798 round 1 rerun).
recovery_release_count_is() {
  [[ "$(recovery_release_count)" == "$1" ]]
}

recovery_calls_at_least() {
  local n=0
  if [[ -f "$1" ]]; then
    n="$(awk 'END{print NR+0}' "$1")"
  fi
  [[ "${n:-0}" -ge "$2" ]]
}

recovery_lost_reasons() {
  python3 - "$1" <<'PY'
import glob, json, sys
reasons = []
for path in sorted(glob.glob(sys.argv[1] + "/*job.lost.json")):
    reasons.append(json.load(open(path, encoding="utf-8")).get("reason") or "")
print(" ".join(reasons))
PY
}

recovery_assert_record() {
  python3 - "$1" "$2" "$3" <<'PY' || return 1
import glob, json, sys
events, reason, minimum = sys.argv[1:]
paths = sorted(glob.glob(events + "/*job.recovered.json"))
assert len(paths) == 1, paths
doc = json.load(open(paths[0], encoding="utf-8"))
assert doc.get("kind") == "job.recovered", doc
assert doc.get("reason") == reason, doc
duration = doc.get("lost_duration_s")
assert isinstance(duration, int) and not isinstance(duration, bool), doc
assert duration >= int(minimum), doc
PY
}

# Drop the recovery knobs. A prefix on start_sentinel does not survive the
# function, but an assignment here would, and the mutant sweep needs the
# file defaults: interval 3600 so a removed stop cannot be saved by a wake,
# grace 1800, and the working scenario.
recovery_stop() {
  if [[ -n "${SENTINEL_PID:-}" ]]; then
    if kill -0 "$SENTINEL_PID" 2>/dev/null; then
      kill_owned_tree "$SENTINEL_PID" || true
    fi
    wait "$SENTINEL_PID" 2>/dev/null || true
  fi
  unset LOST_GRACE SENT_INTERVAL SENT_TIMEOUT SCENARIO TRANSIENT_MAX RECOVERY_ARBITER RECOVERY_STUB_LOG
}

recovery_fail() {
  echo "FAIL: $*" >&2
  recovery_stop
  return 1
}

# done_run JOB [extra env…] — wrk done against the case fixtures.
done_run() {
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
    "$WRK" 'done' "$@"
}

prune_run() {
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" \
    "$WRK" prune "$@"
}

# ── hk1798: quota_pool record release at every job end path ──────────────
# The "stub arbiter" is the real bin/arbiter bound to the per-case
# XDG_DATA_HOME/ARBITER_INBOX_ROOT temp dirs: a release it "saw" is the
# quota_pool.release event artifact in the job's event stream, and "gone
# from the stub DB" is an empty status --job --json quota_pool_records list.
GATE_OUT=""
quota_gate_out() {
  if [[ -z "$GATE_OUT" ]]; then
    GATE_OUT="$TMP/gate.out"
    "$SCOPEFUEL" gate -m codex-luna >"$GATE_OUT"
  fi
  printf '%s\n' "$GATE_OUT"
}

# arb_lease JOB [PROFILE] — a live quota_pool record for JOB in the case DB.
arb_lease() {
  arb lease --job "$1" --kind quota_pool --profile "${2:-codex-luna}" \
    --gate-output "$(quota_gate_out)" >/dev/null
}

quota_rows() {
  arb status --job "$1" --json | python3 -c \
    'import json,sys; print(len(json.load(sys.stdin).get("quota_pool_records") or []))'
}

# shellcheck disable=SC2329 # invoked indirectly via wait_until
quota_is_zero() { [[ "$(quota_rows "$1")" == 0 ]]; }

release_events() { event_count "$INBOX/$1/events" quota_pool.release; }

# quota_spawn JOB [args…] — a stubbed wrk spawn against the real fixture
# arbiter: job.claim, a live quota_pool record, and a completion sentinel.
# Case knobs (QR_* prefix, consumed per call): QR_MODEL, QR_SCENARIO,
# QR_INTERVAL, QR_LOST_GRACE, QR_GET_SEQUENCE, QR_HERDR, QR_ARBITER.
quota_spawn() {
  local job="$1"; shift
  env -u ARBITER_JOB -u HK_TASK_ID \
    HERDR_BIN="${QR_HERDR:-$HERDR}" SCOPEFUEL_BIN="$SCOPEFUEL" \
    ARBITER_BIN="${QR_ARBITER:-$ARBITER}" \
    XDG_DATA_HOME="$XDG" ARBITER_INBOX_ROOT="$INBOX" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE=new \
    PANEWIRE_BIN="${QR_PANEWIRE:-$PANEWIRE}" \
    WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S="${QR_INTERVAL:-3600}" \
    WRK_SENTINEL_LOST_GRACE="${QR_LOST_GRACE:-1800}" \
    WRK_FIXTURE_SCENARIO="${QR_SCENARIO:-spawn}" \
    ${QR_GET_SEQUENCE:+WRK_FIXTURE_GET_SEQUENCE="$QR_GET_SEQUENCE"} \
    WRK_FIXTURE_LOG="$HERDR_LOG" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel-$CASE_SEQ.log" \
    WRK_REFRESH_LOG="$TMP/refresh-$CASE_SEQ.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh-$CASE_SEQ.pids" WRK_REFRESH_TIMEOUT_S=2 \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$ROOT" -m "${QR_MODEL:-codex-luna}" \
      -p "$PROMPT" -w w -l "lbl-$job" --t T1 --task 1 --job "$job" "$@"
}

# A live record after spawn is a precondition of every release test, not an
# assertion about the end path.
quota_spawn_ok() {
  local job="$1" out
  out="$(quota_spawn "$@" 2>&1)" || return 1
  [[ "$(quota_rows "$job")" == 1 ]] || return 1
  printf '%s\n' "$out" | grep -q 'quota_record=' || return 1
}

quota_wait_sentinel_sleep() {
  local job="$1" pidfile pid
  pidfile="$INBOX/$job/completion-sentinel.pid"
  [[ -s "$pidfile" ]] || return 1
  pid="$(head -n 1 "$pidfile")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  sentinel_mid_sleep "$pid" >/dev/null
}

assert_quota_released() {
  [[ "$(quota_rows "$1")" == 0 ]] ||
    fail "$2: live quota_pool record survived the end of $1"
  [[ "$(release_events "$1")" -ge 1 ]] ||
    fail "$2: no quota_pool.release event landed for $1"
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
  "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l je10 --t T1 \
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
    WRK_REFRESH_PID_LOG="$TMP/fake-supervisors.pids" \
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
# The revived shape: a claim newer than the completed, then a spawned. arbiter
# claim mints job.claim only as a first claim, and a re-claim of a released job
# mints job.reclaim, so this record is written as a fixture file (see above).
fixture_claim_event je12 job.claim '{"owner_lane":"lane-a","label":"lbl"}'
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
  "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l je13 --t T1 \
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
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" XDG_DATA_HOME="$XDG" \
  ARBITER_INBOX_ROOT="$INBOX" WRK_FIXTURE_SCENARIO=reap \
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
# Newest record is a fresh claim — no spawned after it (P02's shape). The job is
# still claimed, so arbiter claim cannot mint this job.claim; it is written as a
# fixture file (see fixture_claim_event).
fixture_claim_event je22 job.claim '{"owner_lane":"lane-a","label":"lbl"}'
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
  "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l je29 --t T1 \
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
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" XDG_DATA_HOME="$XDG" \
  ARBITER_INBOX_ROOT="$INBOX" WRK_FIXTURE_SCENARIO=reap \
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
  "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l je35 --t T1 \
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

# hk 1770: lost clears when the same probe that lost the agent finds it again.
# Grace counts only the current episode. These bodies are also the mutant
# targets, so every check returns instead of exiting the suite.

case_recovery_stays() {
  reset_case je37 || return 3
  mk_job je37 || return 3
  recovery_arm_stub
  local seq="$TMP/je37-$CASE_SEQ.seq" events="$INBOX/je37/events"
  printf '%s\n' not-found working >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=8 TRANSIENT_MAX=10 \
    start_sentinel je37 w:p1 "$TMP/je37-report.md" "$seq"
  wait_until 20 event_count_is "$events" job.recovered 1 ||
    recovery_fail "agent return must record one job.recovered" || return
  event_count_is "$events" job.lost 1 ||
    recovery_fail "one loss episode is one job.lost" || return
  event_count_is "$events" job.revoked 0 ||
    recovery_fail "return inside the grace must not revoke" || return
  [[ "$(recovery_release_count)" -eq 0 ]] ||
    recovery_fail "return inside the grace must not release quota" || return
  recovery_assert_record "$events" agent_not_found 0 ||
    recovery_fail "job.recovered must name agent_not_found and a duration" || return
  grep -q 'action=recovered:agent_not_found' "$INBOX/je37/completion-sentinel.log" ||
    recovery_fail "the decision log must name the recovery" || return
  sleep 3
  event_count_is "$events" job.revoked 0 ||
    recovery_fail "still inside the original grace, no revoke" || return
  sleep 6
  event_count_is "$events" job.revoked 0 ||
    recovery_fail "agent present after recovery must never be revoked" || return
  event_count_is "$events" job.lost 1 ||
    recovery_fail "later polls must not open another loss" || return
  event_count_is "$events" job.recovered 1 ||
    recovery_fail "later polls must not record another recovery" || return
  [[ "$(recovery_release_count)" -eq 0 ]] ||
    recovery_fail "a live recovered job must keep its quota" || return
  kill -0 "$SENTINEL_PID" 2>/dev/null ||
    recovery_fail "the sentinel must stay up after recovery" || return
  if grep -q 'watch-exit' "$INBOX/je37/completion-sentinel.log"; then
    recovery_fail "recovery must not watch-exit" || return
  fi
  recovery_stop
}

case_recovery_expires() {
  reset_case je38 || return 3
  mk_job je38 || return 3
  recovery_arm_stub
  local seq="$TMP/je38-$CASE_SEQ.seq" events="$INBOX/je38/events"
  printf '%s\n' not-found >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=2 TRANSIENT_MAX=10 \
    start_sentinel je38 w:p1 "$TMP/je38-report.md" "$seq"
  wait_until 20 event_count_is "$events" job.revoked 1 ||
    recovery_fail "continuous loss past the grace must revoke" || return
  wait_until 10 pid_gone "$SENTINEL_PID" ||
    recovery_fail "the sentinel must leave after the grace" || return
  event_count_is "$events" job.lost 1 ||
    recovery_fail "continuous loss is one job.lost" || return
  event_count_is "$events" job.recovered 0 ||
    recovery_fail "continuous loss must not recover" || return
  wait_until 15 recovery_release_count_is 1 ||
    recovery_fail "grace expiry must release quota once (got $(recovery_release_count))" || return
  if grep -q 'watch-exit' "$INBOX/je38/completion-sentinel.log"; then
    recovery_fail "grace expiry must not watch-exit" || return
  fi
  python3 - "$events" <<'PY' || recovery_fail "grace expiry must abandon the job" || return
import glob, json, sys
records = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.revoked.json"))]
assert len(records) == 1, records
assert records[0].get("outcome") == "abandoned", records
assert "lost" in (records[0].get("reason") or ""), records
PY
  recovery_stop
}

case_recovery_flap() {
  reset_case je39 || return 3
  mk_job je39 || return 3
  recovery_arm_stub
  local seq="$TMP/je39-$CASE_SEQ.seq" events="$INBOX/je39/events" reasons
  printf '%s\n' not-found working working not-found >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=2 TRANSIENT_MAX=10 \
    start_sentinel je39 w:p1 "$TMP/je39-report.md" "$seq"
  wait_until 20 event_count_is "$events" job.lost 2 ||
    recovery_fail "a flap must record two job.lost" || return
  # The second loss starts its own clock, so this poll cannot already be revoked.
  event_count_is "$events" job.revoked 0 ||
    recovery_fail "the second loss must not already be past its own grace" || return
  event_count_is "$events" job.recovered 1 ||
    recovery_fail "the flap must record one job.recovered" || return
  wait_until 15 event_count_is "$events" job.revoked 1 ||
    recovery_fail "the second episode past the grace must revoke once" || return
  event_count_is "$events" job.lost 2 ||
    recovery_fail "revoke must not add a loss event" || return
  event_count_is "$events" job.recovered 1 ||
    recovery_fail "revoke must not add a recovery" || return
  wait_until 15 recovery_release_count_is 1 ||
    recovery_fail "one revoke releases quota once (got $(recovery_release_count))" || return
  if grep -q 'watch-exit' "$INBOX/je39/completion-sentinel.log"; then
    recovery_fail "flap revoke must not watch-exit" || return
  fi
  reasons="$(recovery_lost_reasons "$events")"
  [[ "$reasons" == "agent_not_found agent_not_found" ]] ||
    recovery_fail "both episodes are agent_not_found ($reasons)" || return
  recovery_stop
}

case_recovery_boundary() {
  reset_case je40 || return 3
  mk_job je40 || return 3
  recovery_arm_stub
  local seq="$TMP/je40-$CASE_SEQ.seq" events="$INBOX/je40/events"
  local deadline saw=0
  printf '%s\n' not-found working >"$seq"
  SENT_INTERVAL=3 LOST_GRACE=2 TRANSIENT_MAX=10 \
    start_sentinel je40 w:p1 "$TMP/je40-report.md" "$seq"
  deadline=$(( $(date +%s) + 20 ))
  while (( $(date +%s) <= deadline )); do
    if event_count_is "$events" job.revoked 1; then
      recovery_fail "a wake past the grace must recover instead of revoking" || return
    fi
    if event_count_is "$events" job.recovered 1; then
      saw=1
      break
    fi
    sleep 0.2
  done
  [[ "$saw" -eq 1 ]] ||
    recovery_fail "recovery must land after the sleep that crosses the grace" || return
  recovery_assert_record "$events" agent_not_found 2 ||
    recovery_fail "duration must cover the sleep across the grace" || return
  sleep 6
  event_count_is "$events" job.revoked 0 ||
    recovery_fail "recovered job must stay unrevoked past the old grace" || return
  [[ "$(recovery_release_count)" -eq 0 ]] ||
    recovery_fail "cross-boundary recovery must not release" || return
  kill -0 "$SENTINEL_PID" 2>/dev/null ||
    recovery_fail "sentinel must stay up after a late recovery" || return
  if grep -q 'watch-exit' "$INBOX/je40/completion-sentinel.log"; then
    recovery_fail "cross-boundary recovery must not watch-exit" || return
  fi
  recovery_stop
}

case_recovery_pane_only() {
  reset_case je41 || return 3
  mk_job je41 || return 3
  recovery_arm_stub
  local seq="$TMP/je41-$CASE_SEQ.seq" events="$INBOX/je41/events"
  printf '%s\n' not-found pane-only pane-only pane-only >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=30 TRANSIENT_MAX=10 \
    start_sentinel je41 w:p1 "$TMP/je41-report.md" "$seq"
  wait_until 20 recovery_calls_at_least "$seq.calls" 4 ||
    recovery_fail "pane-only polls did not run" || return
  event_count_is "$events" job.recovered 0 ||
    recovery_fail "a pane without agent_status must not recover" || return
  event_count_is "$events" job.lost 1 ||
    recovery_fail "the initial loss must still be recorded" || return
  event_count_is "$events" job.revoked 0 ||
    recovery_fail "pane-only must not revoke inside a long grace" || return
  printf '%s\n' working >>"$seq"
  wait_until 20 event_count_is "$events" job.recovered 1 ||
    recovery_fail "class=ok after pane-only must recover once" || return
  event_count_is "$events" job.lost 1 ||
    recovery_fail "finding the agent must not add a loss" || return
  event_count_is "$events" job.recovered 1 ||
    recovery_fail "finding the agent records one recovery" || return
  recovery_assert_record "$events" agent_not_found 0 ||
    recovery_fail "pane-only recovery must still name agent_not_found" || return
  recovery_stop
}

case_recovery_herdr_back() {
  reset_case je42 || return 3
  mk_job je42 || return 3
  recovery_arm_stub
  local seq="$TMP/je42-$CASE_SEQ.seq" events="$INBOX/je42/events" reasons
  printf '%s\n' empty empty empty empty working >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=30 TRANSIENT_MAX=3 \
    start_sentinel je42 w:p1 "$TMP/je42-report.md" "$seq"
  wait_until 20 event_count_is "$events" job.recovered 1 ||
    recovery_fail "herdr reachable again must recover" || return
  event_count_is "$events" job.lost 1 ||
    recovery_fail "one herdr_unreachable episode" || return
  event_count_is "$events" job.revoked 0 ||
    recovery_fail "herdr recovery must not revoke" || return
  [[ "$(recovery_release_count)" -eq 0 ]] ||
    recovery_fail "herdr recovery must not release" || return
  reasons="$(recovery_lost_reasons "$events")"
  [[ "$reasons" == herdr_unreachable ]] ||
    recovery_fail "lost reason must be herdr_unreachable ($reasons)" || return
  recovery_assert_record "$events" herdr_unreachable 0 ||
    recovery_fail "job.recovered must name herdr_unreachable" || return
  recovery_stop
}

case_recovery_herdr_gone() {
  reset_case je43 || return 3
  mk_job je43 || return 3
  recovery_arm_stub
  local seq="$TMP/je43-$CASE_SEQ.seq" events="$INBOX/je43/events" reasons
  printf '%s\n' empty empty empty empty not-found >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=30 TRANSIENT_MAX=3 \
    start_sentinel je43 w:p1 "$TMP/je43-report.md" "$seq"
  wait_until 20 event_count_is "$events" job.lost 2 ||
    recovery_fail "gone after unreachable must open a new loss" || return
  event_count_is "$events" job.recovered 1 ||
    recovery_fail "herdr answering must recover the unreachable episode" || return
  event_count_is "$events" job.revoked 0 ||
    recovery_fail "the new episode must restart the grace" || return
  [[ "$(recovery_release_count)" -eq 0 ]] ||
    recovery_fail "rearm must not release" || return
  reasons="$(recovery_lost_reasons "$events")"
  [[ "$reasons" == "herdr_unreachable agent_not_found" ]] ||
    recovery_fail "episode order ($reasons)" || return
  recovery_assert_record "$events" herdr_unreachable 0 ||
    recovery_fail "recovered the unreachable episode" || return
  recovery_stop
}

echo "== JE37: agent missing inside the grace, then found, stays live =="
case_recovery_stays || fail "JE37 agent return must clear lost"
echo "PASS je37 recovery-clears-lost"

echo "== JE38: continuous loss past the grace still abandons and releases =="
case_recovery_expires || fail "JE38 continuous loss must revoke and release"
echo "PASS je38 continuous-loss-revokes"

echo "== JE39: flap revokes once, from the second loss =="
case_recovery_flap || fail "JE39 flap must revoke once from the second episode"
echo "PASS je39 flap-revokes-from-second-loss"

echo "== JE40: a wake that slept across the grace recovers =="
case_recovery_boundary || fail "JE40 recovery must win over a grace crossed while asleep"
echo "PASS je40 recovery-across-grace-boundary"

echo "== JE41: a pane envelope without agent_status does not recover =="
case_recovery_pane_only || fail "JE41 pane-only must not count as the agent returning"
echo "PASS je41 pane-without-status-is-not-recovery"

echo "== JE42: herdr_unreachable recovers when herdr answers =="
case_recovery_herdr_back || fail "JE42 herdr reachable again must recover"
echo "PASS je42 herdr-unreachable-recovers"

echo "== JE43: herdr answering gone rearms agent_not_found =="
case_recovery_herdr_gone || fail "JE43 herdr gone answer must rearm the loss"
echo "PASS je43 herdr-unreachable-rearms-on-gone"

# live_quota_still_held JOB — the real arbiter row seeded by arb_lease is still
# unreleased and no quota_pool.release event landed. A stub that always answers
# "one row" proves a release call, but only a real row proves the row survived
# (hk1888 round 2: the call-only release mutant survived the stub-only check).
live_quota_still_held() {
  [[ "$(quota_rows "$1")" == 1 && "$(release_events "$1")" -eq 0 ]]
}

# A strict gone/ok flap must not postpone the watch window. The sequence is
# long enough that the run ends while the lines are still alternating: the
# fixture repeats only its last line. hk1888: the window now ends at the first
# poll past it that sees the agent, so the flap ends in watch-expired with the
# job live, not in a timeout loss.
case_recovery_window_flap() {
  reset_case je44 || return 3
  mk_job je44 || return 3
  arb_lease je44 || return 3
  [[ "$(quota_rows je44)" == 1 ]] || return 3
  local seq="$TMP/je44-$CASE_SEQ.seq" events="$INBOX/je44/events" reasons i
  : >"$seq"
  for ((i = 0; i < 40; i++)); do
    printf '%s\n' not-found working >>"$seq"
  done
  SENT_INTERVAL=1 LOST_GRACE=3 SENT_TIMEOUT=4 TRANSIENT_MAX=10 \
    start_sentinel je44 w:p1 "$TMP/je44-report.md" "$seq"
  wait_until 20 pid_gone "$SENTINEL_PID" ||
    recovery_fail "the sentinel must leave at the first live poll past the window" || return
  grep -q 'action=watch-expired elapsed=' "$INBOX/je44/completion-sentinel.log" ||
    recovery_fail "the windowed flap must end in watch-expired" || return
  event_count_is "$events" job.revoked 0 ||
    recovery_fail "a live flap must not revoke" || return
  if event_count_is "$events" job.recovered 0; then
    recovery_fail "the flap must recover the absence episodes" || return
  fi
  live_quota_still_held je44 ||
    recovery_fail "a live flap must leave the job's quota row in place" || return
  if grep -q 'watch-exit' "$INBOX/je44/completion-sentinel.log"; then
    recovery_fail "the windowed flap must not watch-exit" || return
  fi
  reasons="$(recovery_lost_reasons "$events")"
  case " $reasons " in
    *" timeout "*) recovery_fail "the live flap must not write a timeout loss ($reasons)" || return ;;
  esac
  recovery_stop
}

echo "== JE44: a gone/ok flap still hits the watch window =="
case_recovery_window_flap || fail "JE44 gone/ok flap must not postpone the watch window"
echo "PASS je44 flap-cannot-postpone-watch-window"

# hk1888: the watch window is not an absence. A live pane past the window ends
# the watch only: no job.lost, no end record, no quota release, no recovered.
# live_window_case JOB SCENARIO — the pane keeps answering SCENARIO.
live_window_case() {
  local job="$1" scenario="$2" events
  reset_case "$job" || return 3
  mk_job "$job" || return 3
  arb_lease "$job" || return 3
  [[ "$(quota_rows "$job")" == 1 ]] || return 3
  events="$INBOX/$job/events"
  SCENARIO="$scenario" SENT_INTERVAL=1 LOST_GRACE=2 SENT_TIMEOUT=3 \
    start_sentinel "$job" w:p1 "$TMP/$job-report.md"
  wait_until 20 pid_gone "$SENTINEL_PID" ||
    recovery_fail "$job: the sentinel must leave after the window" || return
  event_count_is "$events" job.lost 0 ||
    recovery_fail "$job: a live pane past the window must not write job.lost" || return
  event_count_is "$events" job.revoked 0 ||
    recovery_fail "$job: a live pane past the window must not be revoked" || return
  event_count_is "$events" job.recovered 0 ||
    recovery_fail "$job: watch-expired is not a recovery" || return
  live_quota_still_held "$job" ||
    recovery_fail "$job: a live pane past the window must leave the job's quota row in place" || return
  grep -q 'action=watch-expired elapsed=[0-9]*s' "$INBOX/$job/completion-sentinel.log" ||
    recovery_fail "$job: the log must carry watch-expired with the elapsed seconds" || return
  if grep -q 'action=lost:' "$INBOX/$job/completion-sentinel.log"; then
    recovery_fail "$job: no lost action may be logged for a live pane" || return
  fi
  recovery_stop
}

live_window_working_case() { live_window_case je45 sentinel-working; }
echo "== JE45: a live working pane past the window is not lost =="
live_window_working_case || fail "JE45 live working pane must keep its job"
echo "PASS je45 live-working-pane-watch-expired"

echo "== JE46: a live idle pane with no report past the window is not lost =="
live_window_case je46 sentinel-idle || fail "JE46 live idle pane must keep its job"
echo "PASS je46 live-idle-pane-watch-expired"

# dead_window_case JOB LAST_REASON TRANSIENT_MAX LINES… — the pane is working
# for the first poll and then answers the given lines (the fixture repeats the
# last one). One leading working keeps the case independent of poll timing:
# the first poll is always inside the window. The loss must still end in a revoke and a release.
dead_window_case() {
  local job="$1" want="$2" tmax="$3" seq events reasons
  shift 3
  reset_case "$job" || return 3
  mk_job "$job" || return 3
  recovery_arm_stub
  events="$INBOX/$job/events"
  seq="$TMP/$job-$CASE_SEQ.seq"
  printf '%s\n' working "$@" >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=2 SENT_TIMEOUT=2 TRANSIENT_MAX="$tmax" \
    start_sentinel "$job" w:p1 "$TMP/$job-report.md" "$seq"
  wait_until 30 event_count_is "$events" job.revoked 1 ||
    recovery_fail "$job: a dead pane past the window must still be revoked" || return
  wait_until 10 pid_gone "$SENTINEL_PID" ||
    recovery_fail "$job: the sentinel must leave after the revoke" || return
  wait_until 15 recovery_release_count_is 1 ||
    recovery_fail "$job: a dead pane releases quota once (got $(recovery_release_count))" || return
  reasons="$(recovery_lost_reasons "$events")"
  [[ "$reasons" == "$want" ]] ||
    recovery_fail "$job: lost reason must be $want (got $reasons)" || return
  if grep -q 'watch-expired' "$INBOX/$job/completion-sentinel.log"; then
    recovery_fail "$job: a dead pane must not log watch-expired" || return
  fi
  recovery_stop
}

echo "== JE47: a gone pane at the window still revokes and releases =="
dead_window_case je47 agent_not_found 10 not-found || fail "JE47 gone pane must be cleaned up"
echo "PASS je47 gone-pane-past-window-revokes"

echo "== JE48: an unknown answer at the window is still lost:timeout =="
dead_window_case je48 timeout 10 empty || fail "JE48 unknown answer at the window must stay lost:timeout"
echo "PASS je48 unknown-at-window-is-lost-timeout"

echo "== JE49: herdr unreachable past the window revokes and releases =="
dead_window_case je49 herdr_unreachable 0 socket || fail "JE49 herdr unreachable must be cleaned up"
echo "PASS je49 herdr-unreachable-past-window-revokes"

# A flap that ends dead: the pane flaps once and then stays gone while the
# window passes. No poll past the window saw the agent, so the dead job is
# revoked through the grace. Only one ok poll, early, keeps this independent of
# poll timing (a later ok poll past the window would correctly watch-expire).
case_flap_then_dead() {
  reset_case je50 || return 3
  mk_job je50 || return 3
  recovery_arm_stub
  local seq="$TMP/je50-$CASE_SEQ.seq" events="$INBOX/je50/events"
  printf '%s\n' not-found working not-found >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=2 SENT_TIMEOUT=4 TRANSIENT_MAX=10 \
    start_sentinel je50 w:p1 "$TMP/je50-report.md" "$seq"
  wait_until 30 event_count_is "$events" job.revoked 1 ||
    recovery_fail "a flap that ends dead must still be revoked" || return
  wait_until 10 pid_gone "$SENTINEL_PID" ||
    recovery_fail "the sentinel must leave after the revoke" || return
  wait_until 15 recovery_release_count_is 1 ||
    recovery_fail "a flap that ends dead releases quota once (got $(recovery_release_count))" || return
  if grep -q 'watch-expired' "$INBOX/je50/completion-sentinel.log"; then
    recovery_fail "no poll past the window saw the agent, so no watch-expired" || return
  fi
  recovery_stop
}

echo "== JE50: a flap that ends dead is still cleaned up =="
case_flap_then_dead || fail "JE50 a flap that ends dead must be revoked"
echo "PASS je50 flap-then-dead-revokes"

# ── hk1959: a report first seen after the watch deadline gets one
# confirmation poll, then the watch expires ──────────────────────────────
# The pane answers working through the window — the first three 2s polls all
# land inside the 6s deadline — and turns idle only from the fourth poll on,
# which three full interval sleeps always place past it. The report's first
# observation is therefore itself a late one: action=pending once with
# late=1, and the next poll decides.

# quota_fully_released JOB — wait_until-able form of the released-row check.
quota_fully_released() {
  [[ "$(quota_rows "$1")" == 0 && "$(release_events "$1")" -ge 1 ]]
}

# late_window_case JOB VARIANT — stable keeps the report identical so the
# confirmation poll completes; unstable rewrites it under every poll so the
# second post-deadline pending takes the watch-expired exit; working-again
# flips the token back to working right after the late pending.
late_window_case() {
  local job="$1" variant="$2" events seq report log
  reset_case "$job" || return 3
  mk_job "$job" || return 3
  arb_lease "$job" || return 3
  [[ "$(quota_rows "$job")" == 1 ]] || return 3
  events="$INBOX/$job/events"
  seq="$TMP/$job-$CASE_SEQ.seq"
  report="$TMP/$job-report.md"
  log="$INBOX/$job/completion-sentinel.log"
  printf 'late report\n' >"$report"
  case "$variant" in
    working-again) printf '%s\n' working working working idle working >"$seq" ;;
    *) printf '%s\n' working working working idle >"$seq" ;;
  esac
  SENT_INTERVAL=2 LOST_GRACE=3 SENT_TIMEOUT=6 TRANSIENT_MAX=10 \
    start_sentinel "$job" w:p1 "$report" "$seq"
  if [[ "$variant" == unstable ]]; then
    # A new observation key on every poll: the file grows under the sentinel.
    # Self-bounded and self-stopping — on main (the RED shape) the sentinel
    # never leaves, so the recovery_stop kill is what ends this loop.
    ( for _ in $(seq 1 300); do
        kill -0 "$SENTINEL_PID" 2>/dev/null || break
        printf 'churn\n' >>"$report"
        sleep 0.3
      done ) &
    own "$!"
  fi
  wait_until 30 pid_gone "$SENTINEL_PID" ||
    recovery_fail "$job: the sentinel must leave once the late pending resolves" || return
  [[ "$(grep -c 'action=pending late=1' "$log" || true)" == 1 ]] ||
    recovery_fail "$job: the late sighting must log exactly one action=pending late=1" || return
  [[ "$(grep -c 'action=pending' "$log" || true)" == 1 ]] ||
    recovery_fail "$job: exactly one pending line is expected" || return
  if [[ "$variant" == stable ]]; then
    event_count_is "$events" job.completed 1 ||
      recovery_fail "$job: the confirmed late report must complete" || return
    event_count_is "$events" job.lost 0 ||
      recovery_fail "$job: a completed late report must not write job.lost" || return
    event_count_is "$events" job.revoked 0 ||
      recovery_fail "$job: a completed late report must not be revoked" || return
    if grep -q 'watch-expired' "$log"; then
      recovery_fail "$job: a confirmed late report must not watch-expire" || return
    fi
    wait_until 15 quota_fully_released "$job" ||
      recovery_fail "$job: a completed late report releases the quota row" || return
  else
    grep -q 'action=watch-expired elapsed=[0-9]*s' "$log" ||
      recovery_fail "$job: the next poll after the late pending must log watch-expired with elapsed" || return
    event_count_is "$events" job.completed 0 ||
      recovery_fail "$job: an unconfirmed late report must not complete" || return
    event_count_is "$events" job.lost 0 ||
      recovery_fail "$job: a live pane past the deadline must not write job.lost" || return
    event_count_is "$events" job.revoked 0 ||
      recovery_fail "$job: watch-expired is not an end record" || return
    live_quota_still_held "$job" ||
      recovery_fail "$job: watch-expired must leave the job's quota row in place" || return
  fi
  recovery_stop
}

echo "== JE51: a report first seen past the deadline completes on its confirmation poll =="
late_window_case je51 stable ||
  fail "JE51 confirmed late report must complete and release"
echo "PASS je51 late-report-confirmed-completes"

echo "== JE52: an unstable late report watch-expires after one confirmation poll =="
late_window_case je52 unstable ||
  fail "JE52 unstable late report must end the watch"
echo "PASS je52 late-report-unstable-watch-expires"

echo "== JE53: a late pending followed by a working poll watch-expires =="
late_window_case je53 working-again ||
  fail "JE53 late pending then working must end the watch"
echo "PASS je53 late-pending-then-working-watch-expires"

# ════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════
# QR — hk1798: every job end path returns the job's live quota_pool records
# ════════════════════════════════════════════════════════════════════════

# QR1 — wrk done (local path)
echo "== QR1: wrk done releases the job's live quota_pool record =="
reset_case qr1
quota_spawn_ok qr1 || die3 "QR1 setup: spawn did not leave a live record"
quota_wait_sentinel_sleep qr1 || die3 "QR1 setup: sentinel did not reach its sleep"
REPORT="$TMP/qr1-report.md"; printf 'done verdict\n' >"$REPORT"
done_run qr1 --report "$REPORT" >/dev/null 2>&1 ||
  fail "QR1: wrk done must still succeed with a releasable record"
assert_quota_released qr1 "wrk done"
echo "PASS qr1 done-releases-quota"

# QR2 — wrk joined (builder job)
echo "== QR2: wrk joined releases the job's live quota_pool record =="
reset_case qr2
QR_MODEL=builder-sol quota_spawn_ok qr2 \
  --role builder --lane qr2-lane --parent director-1 ||
  die3 "QR2 setup: builder spawn did not leave a live record"
quota_wait_sentinel_sleep qr2 || die3 "QR2 setup: sentinel did not reach its sleep"
REPORT="$TMP/qr2-report.md"; printf 'joined report\n' >"$REPORT"
seed_join_round "$INBOX" qr2
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
  XDG_DATA_HOME="$XDG" HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" \
  PANEWIRE_BIN="$PANEWIRE" \
  "$WRK" joined qr2 --pr https://example.invalid/pr/2 --head deadbeef \
  --report "$REPORT" >/dev/null 2>&1 || fail "QR2: wrk joined must succeed"
assert_quota_released qr2 "wrk joined"
echo "PASS qr2 joined-releases-quota"

# QR3 — delegated `panewire job done` still releases via wrk housekeeping
echo "== QR3: delegated done releases the record =="
reset_case qr3
quota_spawn_ok qr3 || die3 "QR3 setup"
quota_wait_sentinel_sleep qr3 || die3 "QR3 setup: sentinel did not reach its sleep"
REPORT="$TMP/qr3-report.md"; printf 'x\n' >"$REPORT"
QR3_STUB="$TMP/qr3-panewire"
cat >"$QR3_STUB" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
if [ "$1" = "job" ] && [ "$2" = "done" ]; then
  "$STUB_ARBITER" event --job "$3" --kind job.completed \
    --payload-json '{"owner_lane":"default","label":"lbl-qr3","pane_id":"w:p1"}' >/dev/null 2>&1
  exit 0
fi
exit 42
EOF
chmod +x "$QR3_STUB"
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
  XDG_DATA_HOME="$XDG" HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" \
  PANEWIRE_BIN="$QR3_STUB" STUB_ARBITER="$ARBITER" \
  "$WRK" 'done' qr3 --report "$REPORT" >/dev/null 2>&1 ||
  fail "QR3: delegated done must succeed"
assert_quota_released qr3 "delegated done"
echo "PASS qr3 delegated-done-releases-quota"

# QR4 — sentinel completed path releases through the shared helper
echo "== QR4: sentinel-completed releases the record =="
reset_case qr4
QR_GET_SEQUENCE="$TMP/qr4.seq"; printf 'working\n' >"$QR_GET_SEQUENCE"
QR_INTERVAL=1 quota_spawn_ok qr4 ||
  die3 "QR4 setup"
printf 'done\n' >"$QR_GET_SEQUENCE"; : >"${QR_GET_SEQUENCE}.calls"
printf 'final report\n' >"$INBOX/qr4/report.md"
wait_until 20 event_count_is "$INBOX/qr4/events" job.completed 1 ||
  fail "QR4: sentinel must record job.completed once the report is stable"
wait_until 15 quota_is_zero qr4 ||
  fail "QR4: sentinel-completed must release the live record"
assert_quota_released qr4 "sentinel completed"
QR_GET_SEQUENCE=""
echo "PASS qr4 sentinel-completed-releases-quota"

# QR5 — sentinel lost-grace expiry releases
echo "== QR5: sentinel lost-grace releases the record =="
reset_case qr5
QR_GET_SEQUENCE="$TMP/qr5.seq"; printf 'working\n' >"$QR_GET_SEQUENCE"
QR_INTERVAL=1 QR_LOST_GRACE=2 quota_spawn_ok qr5 ||
  die3 "QR5 setup"
printf 'not-found\n' >"$QR_GET_SEQUENCE"; : >"${QR_GET_SEQUENCE}.calls"
wait_until 25 event_count_is "$INBOX/qr5/events" job.revoked 1 ||
  fail "QR5: lost grace expiry must end the job"
wait_until 15 quota_is_zero qr5 ||
  fail "QR5: lost-grace must release the live record"
assert_quota_released qr5 "sentinel lost-grace"
QR_GET_SEQUENCE=""
echo "PASS qr5 lost-grace-releases-quota"

# QR6 — a sentinel that wakes to an externally ended job releases leftovers
echo "== QR6: sentinel watch-exit releases leftover records =="
reset_case qr6
QR_INTERVAL=1 quota_spawn_ok qr6 || die3 "QR6 setup"
arb event --job qr6 --kind job.completed \
  --payload-json '{"owner_lane":"default","label":"lbl-qr6"}' >/dev/null
wait_until 15 quota_is_zero qr6 ||
  fail "QR6: the watch-exit must release the leftover record"
assert_quota_released qr6 "sentinel watch-exit"
echo "PASS qr6 watch-exit-releases-quota"

# QR7 — reap --apply releases remaining records BEFORE the tab close
echo "== QR7: reap releases records before closing the tab =="
reset_case qr7
QR7_ORDER="$TMP/qr7-order.log"; : >"$QR7_ORDER"
QR7_HERDR="$TMP/qr7-herdr"
cat >"$QR7_HERDR" <<EOF
#!/bin/sh
if [ "\$1" = "tab" ] && [ "\$2" = "close" ]; then
  printf 'tabclose %s\n' "\$3" >>"$QR7_ORDER"
fi
exec "$HERDR" "\$@"
EOF
chmod +x "$QR7_HERDR"
QR7_ARB="$TMP/qr7-arbiter"
cat >"$QR7_ARB" <<EOF
#!/bin/sh
if [ "\$1" = "release" ]; then
  printf 'release %s\n' "\$*" >>"$QR7_ORDER"
fi
exec "$ARBITER" "\$@"
EOF
chmod +x "$QR7_ARB"
QR_HERDR="$QR7_HERDR" QR_ARBITER="$QR7_ARB" quota_spawn_ok qr7 --owner qr7lane ||
  die3 "QR7 setup"
quota_wait_sentinel_sleep qr7 || die3 "QR7 setup: sentinel did not reach its sleep"
# The spawn's recorded pane/tab live in workspace w; the reap fixture's tab
# census only knows w1:* — point the newest receipt at a reapable pair.
arb event --job qr7 --kind job.spawned \
  --payload-json '{"owner_lane":"qr7lane","label":"lbl-qr7","pane_id":"w1:p1","tab_id":"w1:t1"}' >/dev/null
arb event --job qr7 --kind job.completed \
  --payload-json '{"owner_lane":"qr7lane","label":"lbl-qr7","pane_id":"w1:p1"}' >/dev/null
env HERDR_BIN="$QR7_HERDR" ARBITER_BIN="$QR7_ARB" ARBITER_INBOX_ROOT="$INBOX" \
  XDG_DATA_HOME="$XDG" WRK_FIXTURE_SCENARIO=reap WRK_FIXTURE_LOG="$HERDR_LOG" \
  "$WRK" reap --apply --lane qr7lane --grace 0s >/"$TMP/qr7-reap.out" 2>&1 ||
  fail "QR7: reap --apply must succeed: $(cat "$TMP/qr7-reap.out")"
grep -q 'closed job=qr7' "$TMP/qr7-reap.out" ||
  fail "QR7: the ended job's tab must close: $(cat "$TMP/qr7-reap.out")"
python3 - "$QR7_ORDER" <<'PY' ||
import sys
lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
release_at = next((i for i, line in enumerate(lines) if line.startswith("release ")), None)
close_at = next((i for i, line in enumerate(lines) if line.startswith("tabclose")), None)
assert release_at is not None, f"no release call recorded: {lines}"
assert close_at is not None, f"no tab close recorded: {lines}"
assert release_at < close_at, f"release must precede the tab close: {lines}"
PY
  fail "QR7: release must run before the tab close"
assert_quota_released qr7 "reap --apply"
echo "PASS qr7 reap-releases-before-close"

# QR8 — prune --apply on an ended job's orphan sentinel releases leftovers
echo "== QR8: prune releases an ended job's leftover record =="
reset_case qr8
quota_spawn_ok qr8 || die3 "QR8 setup"
quota_wait_sentinel_sleep qr8 || die3 "QR8 setup: sentinel did not reach its sleep"
arb event --job qr8 --kind job.completed \
  --payload-json '{"owner_lane":"default","label":"lbl-qr8"}' >/dev/null
prune_run --apply >/dev/null 2>&1 || fail "QR8: prune --apply must succeed"
assert_quota_released qr8 "prune ended-orphan"
echo "PASS qr8 prune-ended-releases-quota"

# QR9 — prune --apply on a pane-gone sentinel ends and releases
echo "== QR9: prune pane-gone path ends and releases =="
reset_case qr9
quota_spawn_ok qr9 || die3 "QR9 setup"
quota_wait_sentinel_sleep qr9 || die3 "QR9 setup: sentinel did not reach its sleep"
QR9_SEQ="$TMP/qr9.seq"; printf 'not-found\n' >"$QR9_SEQ"
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
  XDG_DATA_HOME="$XDG" WRK_FIXTURE_GET_SEQUENCE="$QR9_SEQ" \
  "$WRK" prune --apply >/dev/null 2>&1 || fail "QR9: prune --apply must succeed"
event_count_is "$INBOX/qr9/events" job.revoked 1 ||
  fail "QR9: a pane-gone job must gain the end declaration"
assert_quota_released qr9 "prune pane-gone"
echo "PASS qr9 prune-pane-gone-releases-quota"

# QR10 — prune's stale-job pass ends and releases (no live sentinel)
echo "== QR10: prune stale-job pass ends and releases =="
reset_case qr10
quota_spawn_ok qr10 || die3 "QR10 setup"
# Isolate pass 3: remove the live sentinel and its pidfile so only the
# stale-job sweep can act.
QR10_PID="$(head -n 1 "$INBOX/qr10/completion-sentinel.pid")"
own "$QR10_PID"; kill_owned_tree "$QR10_PID"
rm -f "$INBOX/qr10/completion-sentinel.pid"
QR10_SEQ="$TMP/qr10.seq"; printf 'not-found\n' >"$QR10_SEQ"
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
  XDG_DATA_HOME="$XDG" WRK_FIXTURE_GET_SEQUENCE="$QR10_SEQ" \
  "$WRK" prune --apply --stale-age 0s >/"$TMP/qr10-prune.out" 2>&1 ||
  fail "QR10: prune --apply must succeed"
grep -q "qr10.*stale=yes" "$TMP/qr10-prune.out" ||
  fail "QR10: the silent pane-gone job must be flagged stale: $(cat "$TMP/qr10-prune.out")"
event_count_is "$INBOX/qr10/events" job.revoked 1 ||
  fail "QR10: stale marking must append the end declaration"
assert_quota_released qr10 "prune stale-job"
echo "PASS qr10 prune-stale-releases-quota"

# QR11 — takeover hand-off releases the OLD job's leftover record
echo "== QR11: takeover hand-off releases the old job's record =="
reset_case qr11
HK_STATE="$HK_DB" "$HK" tasks add --id 1 --state claimed \
  --claimed-by old-label --job-id qr11-old >/dev/null
QR11_OLDEV="$INBOX/qr11-old/events"; mkdir -p "$QR11_OLDEV"
printf '%s\n' '{"kind":"job.claim","at":"2026-10-18T00:00:00Z","payload":{"job_id":"qr11-old","owner_lane":"old-lane","label":"old-label","role":"builder","task_id":1}}' >"$QR11_OLDEV/00001-job.claim.json"
printf '%s\n' '{"kind":"job.spawned","at":"2026-10-18T00:00:01Z","payload":{"job_id":"qr11-old","pane_id":"w1:p10","tab_id":"w1:t10"}}' >"$QR11_OLDEV/00002-job.spawned.json"
printf '%s\n' '{"kind":"job.revoked","at":"2026-10-19T00:00:00Z","payload":{"job_id":"qr11-old","owner_lane":"old-lane"}}' >"$QR11_OLDEV/00020-job.revoked.json"
# The leaked row pre-dates the terminal: backdated claim+lease artifacts keep
# the revoked record the newest event.
ARBITER_TEST_NOW="2026-10-17T00:00:00Z" arb claim --job qr11-old \
  --lane old-lane --agent-label old-label --t T1 >/dev/null
ARBITER_TEST_NOW="2026-10-17T00:00:01Z" arb_lease qr11-old
[[ "$(quota_rows qr11-old)" == 1 ]] || die3 "QR11 setup: old job needs a live record"
arb claim --job qr11-unrelated --lane unrelated-lane \
  --agent-label unrelated-label --t T1 >/dev/null
arb_lease qr11-unrelated
[[ "$(quota_rows qr11-unrelated)" == 1 ]] ||
  die3 "QR11 setup: unrelated job needs its own live record"
QR_MODEL=builder-sol quota_spawn_ok qr11-new \
  --role builder --lane qr11-lane --parent director-1 \
  --takeover-from qr11-old >/dev/null ||
  die3 "QR11 setup: takeover spawn failed"
event_count_is "$QR11_OLDEV" job.handed_off 1 ||
  fail "QR11: takeover must write job.handed_off on the old job"
assert_quota_released qr11-old "takeover hand-off"
[[ "$(quota_rows qr11-unrelated)" == 1 ]] ||
  fail "QR11: takeover must not release an unrelated job's record"
[[ "$(release_events qr11-unrelated)" == 0 ]] ||
  fail "QR11: takeover must not write an unrelated job's release event"
[[ "$(quota_rows qr11-new)" == 1 ]] ||
  fail "QR11: takeover must leave the new job's record live"
echo "PASS qr11 takeover-releases-old-job-quota"

# QR12 — released once, re-recorded, then ended: the end still releases
echo "== QR12: a re-recorded record is released at job end =="
reset_case qr12
quota_spawn_ok qr12 || die3 "QR12 setup"
quota_wait_sentinel_sleep qr12 || die3 "QR12 setup: sentinel did not reach its sleep"
arb release --job qr12 --resource codex --kind quota_pool >/dev/null ||
  die3 "QR12 setup: first release"
arb_lease qr12 || die3 "QR12 setup: re-record"
[[ "$(quota_rows qr12)" == 1 ]] || die3 "QR12 setup: the re-record must be live"
REPORT="$TMP/qr12-report.md"; printf 'second round\n' >"$REPORT"
done_run qr12 --report "$REPORT" >/dev/null 2>&1 ||
  fail "QR12: done must succeed"
[[ "$(quota_rows qr12)" == 0 ]] ||
  fail "QR12: the re-recorded record must be released at end"
[[ "$(release_events qr12)" -ge 2 ]] ||
  fail "QR12: expected a second quota_pool.release event"
echo "PASS qr12 re-recorded-release"

# QR13 — a failed release is logged (rc, job, pool) and the end still lands
echo "== QR13: release failure is logged and never fails the end path =="
reset_case qr13
QR13_ARB="$TMP/qr13-arbiter"
cat >"$QR13_ARB" <<EOF
#!/bin/sh
if [ "\$1" = "release" ]; then
  echo "fixture release failure" >&2
  exit 7
fi
exec "$ARBITER" "\$@"
EOF
chmod +x "$QR13_ARB"
QR_ARBITER="$QR13_ARB" quota_spawn_ok qr13 || die3 "QR13 setup"
quota_wait_sentinel_sleep qr13 || die3 "QR13 setup: sentinel did not reach its sleep"
REPORT="$TMP/qr13-report.md"; printf 'x\n' >"$REPORT"
QR13_OUT="$(env HERDR_BIN="$HERDR" ARBITER_BIN="$QR13_ARB" \
  ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
  HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
  "$WRK" 'done' qr13 --report "$REPORT" 2>&1)" ||
  fail "QR13: a failed release must not fail wrk done: $QR13_OUT"
grep -q 'quota-release-failed' "$INBOX/qr13/completion-sentinel.log" ||
  fail "QR13: the sentinel log must carry the release failure"
grep -q 'rc=7' "$INBOX/qr13/completion-sentinel.log" ||
  fail "QR13: the logged failure must carry the release rc"
grep -q 'job=qr13' "$INBOX/qr13/completion-sentinel.log" ||
  fail "QR13: the logged failure must name the job"
grep -q 'pool=codex' "$INBOX/qr13/completion-sentinel.log" ||
  fail "QR13: the logged failure must name the pool"
[[ "$(grep -c 'action=quota-release-failed' "$INBOX/qr13/completion-sentinel.log")" == 1 ]] ||
  fail "QR13: one failed release must write exactly one durable log line"
event_count_is "$INBOX/qr13/events" job.completed 1 ||
  fail "QR13: job.completed must land despite the release failure"
echo "PASS qr13 release-failure-logged"

case_live_revival_prune_pane_gone() {
  reset_case mut-ractive || return 3
  quota_spawn mut-ractive >/dev/null 2>&1 || return 3
  quota_wait_sentinel_sleep mut-ractive || return 3
  ARBITER_TEST_NOW=2099-01-01T00:00:00Z arb release --job mut-ractive \
    --resource codex --kind quota_pool >/dev/null || return 3
  ARBITER_TEST_NOW=2099-01-02T00:00:00Z arb event --job mut-ractive --kind job.completed \
    --payload-json '{"owner_lane":"default","label":"lbl-mut-ractive","pane_id":"w:p1"}' >/dev/null ||
    return 3
  # The release above left the job released, so the re-claim is the production
  # job.reclaim from arbiter claim --reclaim-released.
  ARBITER_TEST_NOW=2099-01-03T00:00:00Z arb claim --job mut-ractive --lane default --t T1 \
    --agent-label lbl-mut-ractive --reclaim-released >/dev/null || return 3
  ARBITER_TEST_NOW=2099-01-04T00:00:00Z arb event --job mut-ractive --kind job.spawned \
    --payload-json '{"owner_lane":"default","label":"lbl-mut-ractive","pane_id":"w:p2"}' >/dev/null ||
    return 3
  ARBITER_TEST_NOW=2099-01-05T00:00:00Z arb_lease mut-ractive || return 3
  [[ "$(quota_rows mut-ractive)" == 1 ]] || return 3
  # Point the pidfile sentinel at the NEWEST spawn pane so this case exercises
  # the pane-gone end-gate; the stale round-one watcher (w:p1) is what the
  # superseded gate then stops in the sweep pass (hk1798 round 2).
  REPORT="$TMP/mut-ractive-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-ractive w:p2 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  local seq="$TMP/mut-ractive.seq"; printf 'not-found\n' >"$seq"
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" WRK_FIXTURE_GET_SEQUENCE="$seq" \
    "$WRK" prune --apply --job mut-ractive >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-ractive)" == 1 ]] || return 1
  event_count_is "$INBOX/mut-ractive/events" job.revoked 0 || return 1
  [[ "$(release_events mut-ractive)" == 1 ]] || return 1
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
}

case_duplicate_done_after_revival() {
  reset_case mut-rduplicate || return 3
  QR_INTERVAL=3600 quota_spawn mut-rduplicate >/dev/null 2>&1 || return 3
  quota_wait_sentinel_sleep mut-rduplicate || return 3
  local report="$TMP/mut-rduplicate-report.md"
  printf 'round one report\n' >"$report"
  done_run mut-rduplicate --report "$report" >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rduplicate)" == 0 ]] || return 3
  # done_run released the quota pool, so the job is released and the re-claim is
  # the production job.reclaim from arbiter claim --reclaim-released.
  ARBITER_TEST_NOW=2099-02-01T00:00:00Z arb claim --job mut-rduplicate --lane default --t T1 \
    --agent-label lbl-mut-rduplicate --reclaim-released >/dev/null || return 3
  ARBITER_TEST_NOW=2099-02-02T00:00:00Z arb event --job mut-rduplicate \
    --kind job.spawned --payload-json \
    '{"owner_lane":"default","label":"lbl-mut-rduplicate","pane_id":"w:p2"}' >/dev/null || return 3
  ARBITER_TEST_NOW=2099-02-03T00:00:00Z arb_lease mut-rduplicate || return 3
  [[ "$(quota_rows mut-rduplicate)" == 1 ]] || return 3
  done_run mut-rduplicate --report "$report" >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rduplicate)" == 1 ]] || {
    assertion_red 'R11 duplicate completion preserves the revived quota row'
    return 1
  }
  [[ "$(release_events mut-rduplicate)" == 1 ]] || return 1
}

# QR14 — pane-gone prune must not release a revived job's live round record.
echo "== QR14: pane-gone prune preserves a revived job's quota row =="
case_live_revival_prune_pane_gone || fail "QR14: pane-gone prune must preserve a revived round"
echo "PASS qr14 pane-gone-prune-preserves-revived-record"

# QR15 — a duplicate completion after a revive must not release the new round.
echo "== QR15: duplicate done after revive preserves the live round record =="
case_duplicate_done_after_revival ||
  fail "QR15: duplicate done must preserve the revived round's record"
echo "PASS qr15 duplicate-done-after-revive-preserves-record"

# A revive with NO work-terminal before it: claim, spawned w:p0, record, a
# job.lost, the stale record released, then a --reclaim-released claim, a new
# spawned on a different pane and a fresh live record. No terminal ever lands,
# so the end-gate alone cannot see that round two is live — only the newest
# job.spawned pane names it. Shared by QR16 (prune) and QR17 (lost grace).
revive_noterminal_setup() {
  local job="$1" oldpane="$2" newpane="$3"
  arb claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 >/dev/null || return 3
  arb event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl-$job\",\"pane_id\":\"$oldpane\",\"tab_id\":\"w:t0\"}" >/dev/null ||
    return 3
  arb_lease "$job" || return 3
  arb event --job "$job" --kind job.lost \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl-$job\",\"reason\":\"agent_not_found\"}" >/dev/null ||
    return 3
  arb release --job "$job" --resource codex --kind quota_pool >/dev/null || return 3
  arb claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 \
    --reclaim-released >/dev/null || return 3
  arb event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl-$job\",\"pane_id\":\"$newpane\",\"tab_id\":\"w:t2\"}" >/dev/null ||
    return 3
  arb_lease "$job" || return 3
  [[ "$(quota_rows "$job")" == 1 ]] || return 3
}

# The stale round-one sentinel kept its pidfile across the respawn and still
# watches the dead old pane. Prune may stop it, but the watched pane is not
# the job's newest spawn, so no end declaration or release may follow.
case_revive_noterminal_prune_superseded() {
  reset_case mut-rsupp || return 3
  revive_noterminal_setup mut-rsupp w:p0 w:p2 || return 3
  REPORT="$TMP/mut-rsupp-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-rsupp w:p0 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  local seq="$TMP/mut-rsupp.seq"; printf 'not-found\n' >"$seq"
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" WRK_FIXTURE_GET_SEQUENCE="$seq" \
    "$WRK" prune --apply --job mut-rsupp >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rsupp)" == 1 ]] || return 1
  event_count_is "$INBOX/mut-rsupp/events" job.revoked 0 || return 1
  [[ "$(release_events mut-rsupp)" == 1 ]] || return 1
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
}

# Same revive through the sentinel's own lost grace: the stale watcher
# records job.lost on the dead pane, the job is reclaimed and respawned on a
# new pane, and the grace then expires. The superseded sentinel must leave
# without declaring the end or releasing the live round.
case_revive_noterminal_lostgrace_superseded() {
  reset_case mut-rsupg || return 3
  arb claim --job mut-rsupg --lane lane-a --agent-label lbl-mut-rsupg --t T1 >/dev/null || return 3
  arb event --job mut-rsupg --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"lbl-mut-rsupg","pane_id":"w:p0","tab_id":"w:t0"}' >/dev/null ||
    return 3
  arb_lease mut-rsupg || return 3
  local seq="$TMP/mut-rsupg.seq"; printf 'not-found\n' >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=5 start_sentinel mut-rsupg w:p0 "$TMP/mut-rsupg-report.md" "$seq"
  wait_until 15 event_count_is "$INBOX/mut-rsupg/events" job.lost 1 || return 3
  arb release --job mut-rsupg --resource codex --kind quota_pool >/dev/null || return 3
  arb claim --job mut-rsupg --lane lane-a --agent-label lbl-mut-rsupg --t T1 \
    --reclaim-released >/dev/null || return 3
  arb event --job mut-rsupg --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"lbl-mut-rsupg","pane_id":"w:p1","tab_id":"w:t1"}' >/dev/null ||
    return 3
  arb_lease mut-rsupg || return 3
  [[ "$(quota_rows mut-rsupg)" == 1 ]] || return 3
  wait_until 15 pid_gone "$SENTINEL_PID" || return 1
  event_count_is "$INBOX/mut-rsupg/events" job.revoked 0 || return 1
  [[ "$(quota_rows mut-rsupg)" == 1 ]] || return 1
  [[ "$(release_events mut-rsupg)" == 1 ]] || return 1
  grep -q 'superseded' "$INBOX/mut-rsupg/completion-sentinel.log" || return 1
}

# QR16 — prune must supersede a stale sentinel on a terminal-less revive:
# stop it without declaring the end or releasing the live round's record.
echo "== QR16: pane-gone prune supersedes a stale sentinel without ending the revived job =="
case_revive_noterminal_prune_superseded ||
  fail "QR16: prune must supersede the stale sentinel, not end the revived job"
echo "PASS qr16 pane-gone-prune-superseded-preserves-record"

# QR17 — the same revive through the sentinel's own lost grace.
echo "== QR17: a superseded sentinel's lost grace ends nothing =="
case_revive_noterminal_lostgrace_superseded ||
  fail "QR17: the superseded sentinel must exit without end or release"
echo "PASS qr17 lost-grace-superseded-preserves-record"

# The in-flight respawn window (round-3 CE8): the reclaim and the fresh
# quota record have landed but the new job.spawned receipt has not — the
# scan's newest spawned pane is still the stale watcher's own pane, so only
# the claim-after-spawn half of job_watch_current can catch it. Shared by
# QR18 (prune) and QR19 (lost grace).
revive_inflight_setup() {
  local job="$1"
  arb claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 >/dev/null || return 3
  arb event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl-$job\",\"pane_id\":\"w:p0\",\"tab_id\":\"w:t0\"}" >/dev/null ||
    return 3
  arb_lease "$job" || return 3
  arb event --job "$job" --kind job.lost \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl-$job\",\"reason\":\"agent_not_found\"}" >/dev/null ||
    return 3
  arb release --job "$job" --resource codex --kind quota_pool >/dev/null || return 3
  arb claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 \
    --reclaim-released >/dev/null || return 3
  arb_lease "$job" || return 3
  [[ "$(quota_rows "$job")" == 1 ]] || return 3
}

case_revive_inflight_prune_superseded() {
  reset_case mut-isfp || return 3
  revive_inflight_setup mut-isfp || return 3
  REPORT="$TMP/mut-isfp-report.md"; printf 'x\n' >"$REPORT"
  start_sentinel mut-isfp w:p0 "$REPORT"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
  local seq="$TMP/mut-isfp.seq"; printf 'not-found\n' >"$seq"
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" WRK_FIXTURE_GET_SEQUENCE="$seq" \
    "$WRK" prune --apply --job mut-isfp >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-isfp)" == 1 ]] || return 1
  event_count_is "$INBOX/mut-isfp/events" job.revoked 0 || return 1
  [[ "$(release_events mut-isfp)" == 1 ]] || return 1
  wait_until 8 pid_gone "$SENTINEL_PID" || return 1
}

case_revive_inflight_lostgrace_superseded() {
  reset_case mut-isfg || return 3
  arb claim --job mut-isfg --lane lane-a --agent-label lbl-mut-isfg --t T1 >/dev/null || return 3
  arb event --job mut-isfg --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"lbl-mut-isfg","pane_id":"w:p0","tab_id":"w:t0"}' >/dev/null ||
    return 3
  arb_lease mut-isfg || return 3
  local seq="$TMP/mut-isfg.seq"; printf 'not-found\n' >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=5 start_sentinel mut-isfg w:p0 "$TMP/mut-isfg-report.md" "$seq"
  wait_until 15 event_count_is "$INBOX/mut-isfg/events" job.lost 1 || return 3
  arb release --job mut-isfg --resource codex --kind quota_pool >/dev/null || return 3
  arb claim --job mut-isfg --lane lane-a --agent-label lbl-mut-isfg --t T1 \
    --reclaim-released >/dev/null || return 3
  arb_lease mut-isfg || return 3
  [[ "$(quota_rows mut-isfg)" == 1 ]] || return 3
  wait_until 15 pid_gone "$SENTINEL_PID" || return 1
  event_count_is "$INBOX/mut-isfg/events" job.revoked 0 || return 1
  [[ "$(quota_rows mut-isfg)" == 1 ]] || return 1
  [[ "$(release_events mut-isfg)" == 1 ]] || return 1
  grep -q 'superseded' "$INBOX/mut-isfg/completion-sentinel.log" || return 1
}

# QR18 — the in-flight respawn window through prune: a stale sentinel whose
# watched pane still equals the newest spawn is superseded, not terminal.
echo "== QR18: prune supersedes a stale sentinel during an in-flight respawn =="
case_revive_inflight_prune_superseded ||
  fail "QR18: prune must supersede the stale sentinel during the respawn window"
echo "PASS qr18 pane-gone-prune-superseded-inflight"

# QR19 — the same window through the sentinel's own lost grace.
echo "== QR19: lost grace during an in-flight respawn ends nothing =="
case_revive_inflight_lostgrace_superseded ||
  fail "QR19: the superseded sentinel must exit during the respawn window"
echo "PASS qr19 lost-grace-superseded-inflight"

# QR20 — an owner lane containing a space must not shift the argv pane
# parse (round-3 T3): a live job's sentinel stays protected, never stopped.
echo "== QR20: a space in the owner lane does not stop a live sentinel =="
reset_case qr20
arb claim --job qr20 --lane 'lane a' --agent-label lbl-qr20 --t T1 >/dev/null
arb event --job qr20 --kind job.spawned \
  --payload-json '{"owner_lane":"lane a","label":"lbl-qr20","pane_id":"w:p1","tab_id":"w:t0"}' >/dev/null
arb_lease qr20
REPORT="$TMP/qr20-report.md"; printf 'x\n' >"$REPORT"
SENT_OWNER='lane a' start_sentinel qr20 w:p1 "$REPORT"
sentinel_mid_sleep "$SENTINEL_PID" >/dev/null ||
  fail "QR20: sentinel must reach its interval sleep"
prune_run --apply --job qr20 >"$TMP/qr20-prune.out" 2>&1 ||
  fail "QR20: prune --apply must succeed"
kill -0 "$SENTINEL_PID" 2>/dev/null ||
  { cat "$TMP/qr20-prune.out"; fail "QR20: a live job's sentinel must not be stopped"; }
grep -q 'protected' "$TMP/qr20-prune.out" ||
  { cat "$TMP/qr20-prune.out"; fail "QR20: the verdict must stay protected"; }
event_count_is "$INBOX/qr20/events" job.revoked 0 ||
  fail "QR20: a live job must never be ended"
[[ "$(quota_rows qr20)" == 1 ]] ||
  fail "QR20: a live job's record must stay leased"
recovery_stop
echo "PASS qr20 space-in-owner-sentinel-protected"

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
  local desc="$1" fn="$2" expected="${3:-}" rc=0 output=""
  local saved="$WRK"; WRK="$MUT"
  if [[ -n "$expected" ]]; then
    output="$( ( "$fn" ) 2>&1)" || rc=$?
  else
    ( "$fn" ) || rc=$?
  fi
  WRK="$saved"
  if (( rc == 3 )); then
    printf '%s\n' "$output" >&2
    fail "MUT $desc: setup failed inside the mutant case — the verdict is not meaningful"
  fi
  if (( rc == 0 )); then
    fail "MUT $desc: mutant stayed GREEN — the assertion does not cover this call site"
  fi
  if [[ -n "$expected" ]] && ! grep -Fq -- "$expected" <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "MUT $desc: RED did not come from the pinned assertion '$expected'"
  fi
  echo "PASS mut $desc is assertion-RED (rc=$rc${expected:+, assertion=$expected})"
}

assertion_red() {
  printf 'ASSERT-RED: %s\n' "$1" >&2
  return 1
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
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" XDG_DATA_HOME="$XDG" \
    ARBITER_INBOX_ROOT="$INBOX" WRK_FIXTURE_SCENARIO=reap \
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
  # A job.claim after the completed record cannot come from arbiter claim on an
  # existing job, so the record is written as a fixture file (see fixture_claim_event).
  fixture_claim_event mut-claimrev job.claim '{"owner_lane":"lane-a","label":"lbl"}' || return 3
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
    "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l mut-rfields --t T1 \
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
    "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l mut-rsucc --t T1 \
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
    "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l mut-rtree --t T1 \
    --task 1 --job mut-rtree >/dev/null 2>&1
  # The grandchild sleep must be gone shortly after the supervisor timeout —
  # under the Q03 mutant only TERM reaches it and it survives (RED). The pid
  # log lands only once the detached supervisor's fixture child has forked.
  wait_until 10 bash -c '[[ $(sed -n "2p" "$1" 2>/dev/null) =~ ^[0-9]+$ ]]' \
    _ "$TMP/mut-rtree.pids" || return 3
  local gchild; gchild="$(sed -n '2p' "$TMP/mut-rtree.pids")"
  own "$gchild"
  if ! pid_gone "$gchild"; then
    # hang-tree's grandchild ignores TERM (trap '' TERM before exec sleep).
    # This pid was recorded by this case; reap it here so a slow teardown
    # sweep cannot leave it past the sweep's SIGKILL deadline.
    kill -KILL "$gchild" 2>/dev/null || true
    return 1
  fi
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
  start_fake_supervisor mut-rstale -7200
  wait_until 10 test -s "$pf" || return 3
  local sup; sup="$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$pf")"; own "$sup"
  local stale_started; stale_started=$(( $(date +%s) - 7200 ))
  python3 - "$pf" "$stale_started" <<'PY' || return 3
import pathlib, sys
path, started = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8")
parts = [token for token in text.split() if not token.startswith("started=")]
parts.append("started=" + started)
path.write_text(" ".join(parts) + "\n", encoding="utf-8")
PY
  local out
  out="$(prune_run --apply 2>&1)" || return 3
  if ! grep -q "mut-rstale.*reason=pid-unverified" <<<"$out" || [[ ! -e "$pf" ]]; then
    assertion_red 'Q07 inconsistent start time leaves the refresh pidfile protected' || return 1
  fi
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
    "$WRK" spawn -c "$ROOT" -m codex-luna -p "$PROMPT" -w w -l mut-spawnreuse --t T1 \
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
mkmut j01-no-done-housekeeping 's~^  job_end_housekeeping "$job" "$owner" completed "wrk done" "wrk done" "$pane"$~  : removed local done housekeeping~'
expect_mut_red "J01 local-done-housekeeping" case_done

# J02: delegated done housekeeping
# shellcheck disable=SC2016
mkmut j02-no-delegated-housekeeping 's~^      job_end_housekeeping "$d_job" "$d_owner" "$sub" "panewire job $sub" "wrk $sub (delegated)" "$d_pane"$~      : removed delegated housekeeping~'
expect_mut_red "J02 delegated-done-housekeeping" case_delegate_done

# J03: duplicate done housekeeping
# shellcheck disable=SC2016
mkmut j03-no-dup-housekeeping 's~^    job_end_housekeeping "$job" "$owner" completed "wrk done (duplicate report)" "wrk done" "$pane"$~    : removed duplicate done housekeeping~'
expect_mut_red "J03 duplicate-done-housekeeping" case_dup_done

# J04: local joined housekeeping
# shellcheck disable=SC2016
mkmut j04-no-joined-housekeeping 's~^  job_end_housekeeping "$job" "$owner" joined "wrk joined" "wrk joined" "$pane"$~  : removed local joined housekeeping~'
expect_mut_red "J04 local-joined-housekeeping" case_joined

# J05: delegated joined gate narrows to done only
# shellcheck disable=SC2016
mkmut j05-delegated-join-skip 's~"done" || "\$sub" == "joined"~"done"~'
expect_mut_red "J05 delegated-joined-gate" case_delegate_joined

# J06: duplicate/partial joined housekeeping
# shellcheck disable=SC2016
mkmut j06-no-pjoined-housekeeping 's~^    job_end_housekeeping "$job" "$owner" joined "wrk joined (duplicate)" "wrk joined" "$pane"$~    : removed duplicate joined housekeeping~'
expect_mut_red "J06 partial-joined-housekeeping" case_partial_joined

# J07: reap housekeeping
# shellcheck disable=SC2016
mkmut j07-no-reap-housekeeping 's~^        job_end_housekeeping "$job" "$owner" abandoned "pane reaped" "wrk reap" "$pane"$~        : removed reap housekeeping~'
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

# hk1770: clearing lost is what stops the grace. Leaving it set revokes a live agent.
mkmut j1770-no-clear 's/lost=0 # hk1770 clear/lost=1 # hk1770 clear/'
expect_mut_red "J1770 recovery-clears-lost" case_recovery_stays

# hk1770: the grace check is the abandon path.
# shellcheck disable=SC2016
mkmut j1770-no-grace 's~^    if \[\[ "\$lost" -eq 1 \]\] && (( now - lost_at >= lost_grace )); then$~    if false; then~'
expect_mut_red "J1770 continuous-loss-revokes" case_recovery_expires

# hk1770: a new episode must start its own clock.
# shellcheck disable=SC2016
mkmut j1770-stale-clock 's/lost_at="\$now" # hk1770 episode start/: # hk1770 episode start/'
expect_mut_red "J1770 grace-restarts-at-latest-loss" case_recovery_flap

# hk1770: class=ok requires agent_status. Any parsed document is not enough.
mkmut j1770-pane-exists 's/if status:/if True:/'
expect_mut_red "J1770 agent-found-is-class-ok" case_recovery_pane_only

mkmut_span j1770-window-stuck \
  '&& ( "$lost" -eq 0 || -n "$recover_reason" )' \
  '    if [[ "$action" == none && "$lost" -eq 0 ]] && (( now - started >= timeout )); then'
expect_mut_red "J1770 flap-cannot-postpone-window" case_recovery_window_flap

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
expect_mut_red "Q07 supervisor-start-check" case_refresh_stale_start \
  'ASSERT-RED: Q07 inconsistent start time leaves the refresh pidfile protected'

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

# ── hk1798 mutant cases: every end path's release call is load-bearing ────

case_release_done() {
  reset_case mut-rdone || return 3
  quota_spawn mut-rdone >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rdone)" == 1 ]] || return 3
  quota_wait_sentinel_sleep mut-rdone || return 3
  REPORT="$TMP/mut-rdone-report.md"; printf 'x\n' >"$REPORT"
  done_run mut-rdone --report "$REPORT" >/dev/null 2>&1
  [[ "$(quota_rows mut-rdone)" == 0 ]] || return 1
}

case_release_joined() {
  reset_case mut-rjoined || return 3
  QR_MODEL=builder-sol quota_spawn mut-rjoined \
    --role builder --lane mut-rjoined-lane --parent director-1 >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rjoined)" == 1 ]] || return 3
  quota_wait_sentinel_sleep mut-rjoined || return 3
  REPORT="$TMP/mut-rjoined-report.md"; printf 'x\n' >"$REPORT"
  seed_join_round "$INBOX" mut-rjoined
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" \
    PANEWIRE_BIN="$PANEWIRE" \
    "$WRK" joined mut-rjoined --pr https://example.invalid/pr/1 \
      --head deadbeef --report "$REPORT" >/dev/null 2>&1
  [[ "$(quota_rows mut-rjoined)" == 0 ]] || return 1
}

case_release_delegate_done() {
  reset_case mut-rdel || return 3
  quota_spawn mut-rdel >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rdel)" == 1 ]] || return 3
  quota_wait_sentinel_sleep mut-rdel || return 3
  REPORT="$TMP/mut-rdel-report.md"; printf 'x\n' >"$REPORT"
  local stub="$TMP/mut-rdel-panewire"
  cat >"$stub" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
if [ "$1" = "job" ] && [ "$2" = "done" ]; then
  "$STUB_ARBITER" event --job "$3" --kind job.completed \
    --payload-json '{"owner_lane":"default","label":"lbl-mut-rdel","pane_id":"w:p1"}' >/dev/null 2>&1
  exit 0
fi
exit 42
EOF
  chmod +x "$stub" || return 3
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" \
    PANEWIRE_BIN="$stub" STUB_ARBITER="$ARBITER" \
    "$WRK" 'done' mut-rdel --report "$REPORT" >/dev/null 2>&1
  [[ "$(quota_rows mut-rdel)" == 0 ]] || return 1
}

case_release_sentinel_completed() {
  reset_case mut-rsc || return 3
  QR_GET_SEQUENCE="$TMP/mut-rsc.seq"; printf 'working\n' >"$QR_GET_SEQUENCE"
  QR_INTERVAL=1 quota_spawn mut-rsc >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rsc)" == 1 ]] || return 3
  printf 'done\n' >"$QR_GET_SEQUENCE"; : >"${QR_GET_SEQUENCE}.calls"
  printf 'x\n' >"$INBOX/mut-rsc/report.md"
  wait_until 20 event_count_is "$INBOX/mut-rsc/events" job.completed 1 || return 3
  wait_until 15 quota_is_zero mut-rsc || return 1
}

case_release_watch_exit() {
  reset_case mut-rwx || return 3
  QR_INTERVAL=1 quota_spawn mut-rwx >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rwx)" == 1 ]] || return 3
  arb event --job mut-rwx --kind job.completed \
    --payload-json '{"owner_lane":"default","label":"lbl-mut-rwx"}' >/dev/null || return 3
  wait_until 15 quota_is_zero mut-rwx || return 1
}

case_release_lost_grace() {
  reset_case mut-rlg || return 3
  QR_GET_SEQUENCE="$TMP/mut-rlg.seq"; printf 'working\n' >"$QR_GET_SEQUENCE"
  QR_INTERVAL=1 QR_LOST_GRACE=2 quota_spawn mut-rlg >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rlg)" == 1 ]] || return 3
  printf 'not-found\n' >"$QR_GET_SEQUENCE"; : >"${QR_GET_SEQUENCE}.calls"
  wait_until 25 event_count_is "$INBOX/mut-rlg/events" job.revoked 1 || return 3
  wait_until 15 quota_is_zero mut-rlg || return 1
}

case_release_reap_order() {
  reset_case mut-rreap || return 3
  local order="$TMP/mut-rreap-order.log"; : >"$order"
  local hwrap="$TMP/mut-rreap-herdr" astub="$TMP/mut-rreap-arbiter"
  cat >"$hwrap" <<EOF || return 3
#!/bin/sh
if [ "\$1" = "tab" ] && [ "\$2" = "close" ]; then
  printf 'tabclose %s\n' "\$3" >>"$order"
fi
exec "$HERDR" "\$@"
EOF
  cat >"$astub" <<EOF || return 3
#!/bin/sh
if [ "\$1" = "release" ]; then
  printf 'release %s\n' "\$*" >>"$order"
fi
exec "$ARBITER" "\$@"
EOF
  chmod +x "$hwrap" "$astub" || return 3
  QR_HERDR="$hwrap" QR_ARBITER="$astub" quota_spawn mut-rreap --owner mutrrlane >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rreap)" == 1 ]] || return 3
  quota_wait_sentinel_sleep mut-rreap || return 3
  arb event --job mut-rreap --kind job.spawned \
    --payload-json '{"owner_lane":"mutrrlane","label":"lbl-mut-rreap","pane_id":"w1:p1","tab_id":"w1:t1"}' >/dev/null || return 3
  arb event --job mut-rreap --kind job.completed \
    --payload-json '{"owner_lane":"mutrrlane","label":"lbl-mut-rreap","pane_id":"w1:p1"}' >/dev/null || return 3
  env HERDR_BIN="$hwrap" ARBITER_BIN="$astub" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" WRK_FIXTURE_SCENARIO=reap WRK_FIXTURE_LOG="$HERDR_LOG" \
    "$WRK" reap --apply --lane mutrrlane --grace 0s >/dev/null 2>&1
  [[ "$(quota_rows mut-rreap)" == 0 ]] || return 1
  python3 - "$order" <<'PY' || return 1
import sys
lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
release_at = next((i for i, line in enumerate(lines) if line.startswith("release ")), None)
close_at = next((i for i, line in enumerate(lines) if line.startswith("tabclose")), None)
assert release_at is not None and close_at is not None, lines
assert release_at < close_at, lines
PY
}

case_release_prune_orphan() {
  reset_case mut-rpo || return 3
  QR_INTERVAL=3600 quota_spawn mut-rpo >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rpo)" == 1 ]] || return 3
  quota_wait_sentinel_sleep mut-rpo || return 3
  local pid
  IFS= read -r pid <"$INBOX/mut-rpo/completion-sentinel.pid" || return 3
  own "$pid"
  kill_owned_tree "$pid" || return 3
  wait_until 5 pid_gone "$pid" || return 3
  rm -f "$INBOX/mut-rpo/completion-sentinel.pid"
  arb event --job mut-rpo --kind job.completed \
    --payload-json '{"owner_lane":"default","label":"lbl-mut-rpo"}' >/dev/null || return 3
  prune_run --apply >/dev/null 2>&1
  [[ "$(quota_rows mut-rpo)" == 0 ]] || {
    assertion_red 'R6 prune releases an ended orphan quota row'
    return 1
  }
}

case_release_prune_panegone() {
  reset_case mut-rpg || return 3
  quota_spawn mut-rpg >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rpg)" == 1 ]] || return 3
  quota_wait_sentinel_sleep mut-rpg || return 3
  local seq="$TMP/mut-rpg.seq"; printf 'not-found\n' >"$seq"
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" WRK_FIXTURE_GET_SEQUENCE="$seq" \
    "$WRK" prune --apply >/dev/null 2>&1
  [[ "$(quota_rows mut-rpg)" == 0 ]] || return 1
}

case_release_prune_stale() {
  reset_case mut-rps || return 3
  quota_spawn mut-rps >/dev/null 2>&1 || return 3
  [[ "$(quota_rows mut-rps)" == 1 ]] || return 3
  local pid; pid="$(head -n 1 "$INBOX/mut-rps/completion-sentinel.pid" 2>/dev/null)"
  own "$pid"; kill_owned_tree "$pid"; rm -f "$INBOX/mut-rps/completion-sentinel.pid"
  local seq="$TMP/mut-rps.seq"; printf 'not-found\n' >"$seq"
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" WRK_FIXTURE_GET_SEQUENCE="$seq" \
    "$WRK" prune --apply --stale-age 0s >/dev/null 2>&1
  [[ "$(quota_rows mut-rps)" == 0 ]] || return 1
}

case_release_takeover() {
  reset_case mut-rtk || return 3
  HK_STATE="$HK_DB" "$HK" tasks add --id 1 --state claimed \
    --claimed-by old-label --job-id mut-rtk-old >/dev/null || return 3
  local oev="$INBOX/mut-rtk-old/events"; mkdir -p "$oev"
  printf '%s\n' '{"kind":"job.claim","at":"2026-10-18T00:00:00Z","payload":{"job_id":"mut-rtk-old","owner_lane":"old-lane","label":"old-label","role":"builder","task_id":1}}' >"$oev/00001-job.claim.json"
  printf '%s\n' '{"kind":"job.spawned","at":"2026-10-18T00:00:01Z","payload":{"job_id":"mut-rtk-old","pane_id":"w1:p10","tab_id":"w1:t10"}}' >"$oev/00002-job.spawned.json"
  printf '%s\n' '{"kind":"job.revoked","at":"2026-10-19T00:00:00Z","payload":{"job_id":"mut-rtk-old","owner_lane":"old-lane"}}' >"$oev/00020-job.revoked.json"
  ARBITER_TEST_NOW="2026-10-17T00:00:00Z" arb claim --job mut-rtk-old \
    --lane old-lane --agent-label old-label --t T1 >/dev/null || return 3
  ARBITER_TEST_NOW="2026-10-17T00:00:01Z" arb_lease mut-rtk-old || return 3
  [[ "$(quota_rows mut-rtk-old)" == 1 ]] || return 3
  QR_MODEL=builder-sol quota_spawn mut-rtk-new \
    --role builder --lane mut-rtk-lane --parent director-1 \
    --takeover-from mut-rtk-old >/dev/null 2>&1 || return 3
  event_count_is "$oev" job.handed_off 1 || return 3
  [[ "$(quota_rows mut-rtk-old)" == 0 ]] || return 1
}

# A release-time guard may safely skip quota cleanup after takeover has already
# committed the task rebind and hand-off records. That skip must not abort the
# spawn before arbiter admission and pane creation continue.
case_takeover_release_guard_skip_continues_spawn() {
  reset_case mut-1813-takeover-skip || return 3
  local lib out rc=0
  lib="$(wrk_test_library)" || return 3
  out="$(env WRK_LIBFILE="$lib" bash -c '
    set -euo pipefail
    . "$WRK_LIBFILE"
    hk_task_takeover_precheck() { :; }
    hk_bin() { printf "%s\n" /fixture/handoffkeep; }
    hk_cmd() { printf "%s\n" '\''{"state":"claimed","claimed_by":"new-label","refs":{"job_id":"new-job"}}'\''; }
    takeover_event_pair_commit() { printf "%s\n" event-pair-committed; }
    release_job_quota_pool() { return 2; }
    TASK_ID=1 TAKEOVER_FROM=old-job JOB_ID=new-job LABEL=new-label
    BUILDER_LANE=builder-lane PARENT_LANE=director-1 TAKEOVER_ROUNDS_USED=1
    hk_task_takeover_rebind
    printf "%s\n" spawn-continued
  ' 2>&1)" || rc=$?
  grep -Fq event-pair-committed <<<"$out" || {
    printf '%s\n' "$out" >&2
    return 3
  }
  if (( rc != 0 )) || ! grep -Fq spawn-continued <<<"$out"; then
    assertion_red 'R30 takeover continues spawn when the release guard skips cleanup' || return 1
  fi
}

# hk1813 helpers: make a sourceable wrk library from the current under-test
# file so mutations exercise the same functions as the production entrypoint.
wrk_test_library() {
  local path="$TMP/wrk-lib-$CASE_SEQ-$RANDOM.sh"
  awk 'index($0, "case \"${1:-}\" in") == 1 {exit} {print}' "$WRK" >"$path"
  [[ -s "$path" ]] || return 1
  printf '%s\n' "$path"
}

job_watch_current_from_library() {
  local lib="$1" events="$2" pane="$3"
  env WRK_LIBFILE="$lib" bash -c \
    '. "$WRK_LIBFILE"; job_watch_current "$@"' "$WRK" "$events" "$pane"
}

quota_release_current_from_library() {
  local lib="$1"; shift
  env HERDR_BIN="$HERDR" ARBITER_BIN="${RECOVERY_ARBITER:-$ARBITER}" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" WRK_LIBFILE="$lib" \
    bash -c '. "$WRK_LIBFILE"; quota_release_round_current "$@"' "$WRK" "$@"
}

start_completion_from_library() {
  local pidfile="$1" job="$2" owner="$3" label="$4" pane="$5" report="$6"
  local lib pid
  lib="$(wrk_test_library)" || return 1
  env HERDR_BIN="$HERDR" ARBITER_BIN="${RECOVERY_ARBITER:-$ARBITER}" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    WRK_FIXTURE_SCENARIO="${SCENARIO:-sentinel-working}" \
    ${WRK_FIXTURE_GET_SEQUENCE:+WRK_FIXTURE_GET_SEQUENCE="$WRK_FIXTURE_GET_SEQUENCE"} \
    WRK_LIBFILE="$lib" WRK_COMPLETION_TIMEOUT_S="${SENT_TIMEOUT:-300}" \
    WRK_COMPLETION_INTERVAL_S="${SENT_INTERVAL:-3600}" \
    WRK_SENTINEL_LOST_GRACE="${LOST_GRACE:-1800}" \
    WRK_SENTINEL_TRANSIENT_MAX="${TRANSIENT_MAX:-10}" \
    bash -c '. "$WRK_LIBFILE"; start_completion_sentinel "$@"' \
      "$WRK" "$pidfile" "$job" "$owner" "$label" "$pane" "$report" || return 1
  IFS= read -r pid <"$pidfile" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  SENTINEL_PID="$pid"
  own "$pid"
}

case_release_prune_sentinel_orphan() {
  reset_case mut-1813-prune-sentinel-orphan || return 3
  local job=mut-1813-prune-sentinel-orphan pidfile pid started lib out
  local report="$TMP/1813-r29-report.md"
  mk_job "$job" w:p1 || return 3
  arb_lease "$job" || return 3
  pidfile="$INBOX/$job/completion-sentinel.pid"
  SENT_INTERVAL=3600 start_completion_from_library \
    "$pidfile" "$job" lane-a "lbl-$job" w:p1 "$report" || return 3
  pid="$SENTINEL_PID"
  sentinel_mid_sleep "$pid" >/dev/null || return 3
  lib="$(wrk_test_library)" || return 3
  IFS=$'\t' read -r pid started < <(env WRK_LIBFILE="$lib" bash -c \
    '. "$WRK_LIBFILE"; sentinel_pidfile_fields "$1"' "$WRK" "$pidfile") || return 3
  # Keep the sentinel live while its stream becomes terminal. Otherwise its
  # own watch loop can exit between the terminal receipt and prune's scan.
  kill -STOP "$pid" || return 3
  arb event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"default\",\"label\":\"lbl-$job\"}" >/dev/null || return 3
  out="$(env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    WRK_LIBFILE="$lib" PRUNE_ROOT="$INBOX" PRUNE_APPLY=1 PRUNE_LANE="" \
    PRUNE_ORPHANS=0 bash -c '
      . "$WRK_LIBFILE"
      PRUNE_SCAN="$(job_events_scan "$PRUNE_ROOT/$1/events")"
      prune_sentinel_row "$1" "$2" "$3" "" "" "$4"
    ' "$WRK" "$job" "$pid" "$pidfile" "$started" 2>&1)" || return 3
  # The direct release-site test owns the sentinel process, so clean it up by
  # its recorded PID even if prune has already made it a short-lived zombie.
  kill_owned_tree "$pid" || true
  rm -f "$pidfile"
  grep -q 'reason=job-ended' <<<"$out" || return 1
  if [[ "$(quota_rows "$job")" != 0 ]]; then
    assertion_red 'R29 prune orphan-sentinel path releases the ended live quota row' || return 1
  fi
  [[ "$(release_events "$job")" == 1 ]] || {
    assertion_red 'R29 prune orphan-sentinel path releases exactly once' || return 1
  }
}

re_record_quota_round() {
  local job="$1" pane="$2" tab="$3"
  arb release --job "$job" --resource codex --kind quota_pool >/dev/null || return 1
  arb claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 \
    --reclaim-released >/dev/null || return 1
  arb event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl-$job\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}" \
    >/dev/null || return 1
  arb_lease "$job" || return 1
  [[ "$(quota_rows "$job")" == 1 ]]
}

seed_ended_rerecorded_quota() {
  local job="$1" pid
  quota_spawn "$job" >/dev/null 2>&1 || return 3
  quota_wait_sentinel_sleep "$job" || return 3
  IFS= read -r pid <"$INBOX/$job/completion-sentinel.pid" || return 3
  kill_owned_tree "$pid" || return 3
  wait_until 5 pid_gone "$pid" || return 3
  rm -f "$INBOX/$job/completion-sentinel.pid"
  arb event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"default\",\"label\":\"lbl-$job\"}" \
    >/dev/null || return 3
  arb release --job "$job" --resource codex --kind quota_pool >/dev/null || return 3
  arb_lease "$job" || return 3
  [[ "$(quota_rows "$job")" == 1 ]] || return 3
}

run_red_first_case() {
  local desc="$1" fn="$2" expected="$3" rc=0 output=""
  output="$( ( "$fn" ) 2>&1)" || rc=$?
  if (( rc == 0 )); then
    fail "RED-first $desc: the base unexpectedly passed"
  fi
  if (( rc == 3 )); then
    printf '%s\n' "$output" >&2
    fail "RED-first $desc: fixture setup failed, not an assertion"
  fi
  if ! grep -Fq -- "$expected" <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "RED-first $desc: expected assertion marker '$expected' was absent"
  fi
  printf 'RED on base: %s — %s\n' "$desc" "$expected"
}

run_green_contract_case() {
  local desc="$1" fn="$2" output="$TMP/hk1813-$CASE_SEQ.out"
  if ! "$fn" >"$output" 2>&1; then
    cat "$output" >&2
    fail "hk1813 $desc: contract assertion failed"
  fi
  printf 'PASS hk1813 %s\n' "$desc"
}

# Item 1 — a reclaim and a fresh quota row land after reap's candidate scan,
# while its pane and tab probes are still in progress.
case_reap_revived_since_scan() {
  reset_case mut-1813-reap || return 3
  local job=mut-1813-reap close_log="$TMP/1813-reap-close.log"
  local injected="$TMP/1813-reap-injected" hwrap="$TMP/1813-reap-herdr"
  local gatefile="$TMP/1813-reap-gate" out pid
  quota_spawn "$job" --owner r16lane >/dev/null 2>&1 || return 3
  quota_wait_sentinel_sleep "$job" || return 3
  IFS= read -r pid <"$INBOX/$job/completion-sentinel.pid" || return 3
  kill_owned_tree "$pid" || return 3
  wait_until 5 pid_gone "$pid" || return 3
  rm -f "$INBOX/$job/completion-sentinel.pid"
  arb event --job "$job" --kind job.spawned \
    --payload-json '{"owner_lane":"r16lane","label":"lbl-mut-1813-reap","pane_id":"w1:p1","tab_id":"w1:t1"}' \
    >/dev/null || return 3
  arb event --job "$job" --kind job.completed \
    --payload-json '{"owner_lane":"r16lane","label":"lbl-mut-1813-reap","pane_id":"w1:p1"}' \
    >/dev/null || return 3
  quota_gate_out >"$gatefile" || return 3
  : >"$close_log"
  cat >"$hwrap" <<EOF || return 3
#!/bin/bash
set -euo pipefail
if [[ "\${1:-}" == tab && "\${2:-}" == list && ! -e "$injected" ]]; then
  : >"$injected"
  "$ARBITER" release --job "$job" --resource codex --kind quota_pool >/dev/null
  "$ARBITER" claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 --reclaim-released >/dev/null
  "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"lbl-$job","pane_id":"w:p2","tab_id":"w:t2"}' >/dev/null
  "$ARBITER" lease --job "$job" --kind quota_pool --profile codex-luna \
    --gate-output "\$(cat "$gatefile")" >/dev/null
fi
if [[ "\${1:-}" == tab && "\${2:-}" == close ]]; then printf '%s\n' "close \$3" >>"$close_log"; fi
exec "$HERDR" "\$@"
EOF
  chmod +x "$hwrap" || return 3
  out="$(env HERDR_BIN="$hwrap" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    WRK_FIXTURE_SCENARIO=reap "$WRK" reap --apply --lane r16lane --grace 0s 2>&1)" || return 3
  if ! grep -Fq "skip job=$job reason=revived-since-scan" <<<"$out"; then
    printf '%s\n' "$out" >&2
    assertion_red 'R16 reap skips a candidate revived after the scan' || return 1
  fi
  [[ "$(quota_rows "$job")" == 1 ]] || {
    assertion_red 'R16 the revived round quota row stays live' || return 1
  }
  [[ ! -s "$close_log" ]] || {
    assertion_red 'R16 reap does not close the revived round tab' || return 1
  }
}

# Item 2 — the old sentinel sees a new report key on pane p1 after the job
# has reclaimed and spawned pane p2. It must not manufacture job.completed.
case_sentinel_completed_superseded() {
  reset_case mut-1813-completed || return 3
  local job=mut-1813-completed seq="$TMP/1813-completed.seq" pid
  printf 'working\n' >"$seq"
  QR_INTERVAL=1 QR_GET_SEQUENCE="$seq" quota_spawn "$job" >/dev/null 2>&1 || return 3
  [[ "$(quota_rows "$job")" == 1 ]] || return 3
  quota_wait_sentinel_sleep "$job" || return 3
  IFS= read -r pid <"$INBOX/$job/completion-sentinel.pid" || return 3
  re_record_quota_round "$job" w:p2 w:t2 || return 3
  printf 'new round report\n' >"$INBOX/$job/report.md"
  printf 'done\n' >"$seq"
  wait_until 20 pid_gone "$pid" || return 3
  if [[ "$(event_count "$INBOX/$job/events" job.completed)" != 0 ]]; then
    assertion_red 'R17 superseded sentinel writes no job.completed' || return 1
  fi
  if [[ "$(quota_rows "$job")" != 1 ]]; then
    assertion_red 'R17 superseded sentinel releases no live quota row' || return 1
  fi
  grep -q 'action=superseded' "$INBOX/$job/completion-sentinel.log" || {
    assertion_red 'R17 superseded sentinel logs its exit reason' || return 1
  }
}

# Item 3 — a foreground release failure is visible on stderr, while a
# detached sentinel writes one durable line and does not duplicate it.
make_release_failure_arbiter() {
  local path="$1" calls="$2"
  cat >"$path" <<EOF
#!/bin/bash
set -euo pipefail
if [[ "\${1:-}" == release ]]; then printf '%s\n' "release \$*" >>"$calls"; exit 7; fi
exec "$ARBITER" "\$@"
EOF
  chmod +x "$path"
}

case_release_failure_logging_modes() {
  reset_case mut-1813-foreground || return 3
  local fg=mut-1813-foreground fg_stub="$TMP/1813-fg-arbiter"
  local fg_calls="$TMP/1813-fg-calls" report="$TMP/1813-fg-report.md" out n
  mk_job "$fg" || return 3
  arb_lease "$fg" || return 3
  make_release_failure_arbiter "$fg_stub" "$fg_calls" || return 3
  printf 'foreground report\n' >"$report"
  out="$(env HERDR_BIN="$HERDR" ARBITER_BIN="$fg_stub" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" PANEWIRE_BIN="$PANEWIRE" \
    "$WRK" 'done' "$fg" --report "$report" 2>&1)" || return 3
  n="$(grep -c 'arbiter quota_pool release failed' <<<"$out" || true)"
  if [[ "$n" != 1 ]]; then
    assertion_red 'R18 foreground release failure warns once on stderr' || return 1
  fi
  n="$(grep -c 'action=quota-release-failed' "$INBOX/$fg/completion-sentinel.log" 2>/dev/null || true)"
  [[ "$n" == 1 ]] || {
    assertion_red 'R18 foreground release failure keeps one durable line' || return 1
  }

  reset_case mut-1813-detached || return 3
  local bg=mut-1813-detached bg_stub="$TMP/1813-bg-arbiter"
  local bg_calls="$TMP/1813-bg-calls" seq="$TMP/1813-bg.seq" bg_report="$INBOX/$bg/report.md"
  mk_job "$bg" || return 3
  arb_lease "$bg" || return 3
  make_release_failure_arbiter "$bg_stub" "$bg_calls" || return 3
  printf 'working\n' >"$seq"
  RECOVERY_ARBITER="$bg_stub" WRK_FIXTURE_GET_SEQUENCE="$seq" SENT_INTERVAL=1 start_completion_from_library \
    "$INBOX/$bg/completion-sentinel.pid" "$bg" lane-a "lbl-$bg" w:p1 "$bg_report" || return 3
  local bg_pid="$SENTINEL_PID"
  sentinel_mid_sleep "$bg_pid" >/dev/null || return 3
  printf 'detached report\n' >"$bg_report"
  printf 'done\n' >"$seq"
  wait_until 20 pid_gone "$bg_pid" || return 3
  n="$(grep -c 'action=quota-release-failed' "$INBOX/$bg/completion-sentinel.log" 2>/dev/null || true)"
  if [[ "$n" != 1 ]]; then
    assertion_red 'R18 detached sentinel has exactly one durable failure line' || return 1
  fi
  n="$(grep -c 'arbiter quota_pool release failed' "$INBOX/$bg/completion-sentinel.log" 2>/dev/null || true)"
  [[ "$n" == 0 ]] || {
    assertion_red 'R18 detached sentinel does not duplicate the warning line' || return 1
  }
}

# Item 4 — a first spawn receipt can be missing, and a later malformed
# job.spawned receipt must clear the pane from the previous receipt.
case_t4_claim_without_spawn_is_current() {
  reset_case mut-1813-t4 || return 3
  local job=mut-1813-t4 lib
  arb claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 >/dev/null || return 3
  arb_lease "$job" || return 3
  lib="$(wrk_test_library)" || return 3
  if ! job_watch_current_from_library "$lib" "$INBOX/$job/events" w:p1; then
    assertion_red 'R19 claim-only first round is current without a spawn receipt' || return 1
  fi
}

# A failed first spawned receipt leaves one claim and no pane receipt. If that
# first round's quota row is released and the same job is reclaimed before a
# new spawned receipt lands, the old watcher must become superseded. This is
# the receipt-less form of the QR18/QR19 in-flight window.
receiptless_first_claim_setup() {
  local job="$1"
  arb claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 >/dev/null || return 3
  arb_lease "$job" || return 3
}

case_t4_receiptless_inflight_lostgrace() {
  reset_case mut-1813-t4-lostgrace || return 3
  local job=mut-1813-t4-lostgrace seq="$TMP/1813-t4-lostgrace.seq" report="$TMP/1813-t4-lostgrace.md"
  receiptless_first_claim_setup "$job" || return 3
  printf 'not-found\n' >"$seq"
  SENT_INTERVAL=1 LOST_GRACE=5 start_sentinel "$job" w:p1 "$report" "$seq"
  wait_until 10 event_count_is "$INBOX/$job/events" job.lost 1 || return 3
  # The lost-grace watch began on round 1. Round 2 is now claimed and leased,
  # but its job.spawned receipt is missing, exactly the T4 receipt-failure case.
  arb release --job "$job" --resource codex --kind quota_pool >/dev/null || return 3
  arb claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 \
    --reclaim-released >/dev/null || return 3
  arb_lease "$job" || return 3
  wait_until 15 pid_gone "$SENTINEL_PID" || return 3
  if [[ "$(quota_rows "$job")" != 1 ]]; then
    assertion_red 'R26 receipt-less in-flight lost-grace leaves the revived quota row live' || return 1
  fi
  if [[ "$(event_count "$INBOX/$job/events" job.revoked)" != 0 ]]; then
    assertion_red 'R26 receipt-less in-flight lost-grace writes no job.revoked' || return 1
  fi
  [[ "$(release_events "$job")" == 1 ]] || return 1
  grep -q 'superseded' "$INBOX/$job/completion-sentinel.log" || return 1
}

case_t4_receiptless_inflight_completed() {
  reset_case mut-1813-t4-completed || return 3
  local job=mut-1813-t4-completed seq="$TMP/1813-t4-completed.seq"
  local report="$INBOX/$job/report.md" pid
  receiptless_first_claim_setup "$job" || return 3
  printf 'working\n' >"$seq"
  SENT_INTERVAL=1 start_sentinel "$job" w:p1 "$report" "$seq"
  pid="$SENTINEL_PID"
  sentinel_mid_sleep "$pid" >/dev/null || return 3
  arb release --job "$job" --resource codex --kind quota_pool >/dev/null || return 3
  arb claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 \
    --reclaim-released >/dev/null || return 3
  arb_lease "$job" || return 3
  printf 'new round report\n' >"$report"
  printf 'done\n' >"$seq"
  wait_until 20 pid_gone "$pid" || return 3
  if [[ "$(event_count "$INBOX/$job/events" job.completed)" != 0 ]]; then
    assertion_red 'R28 receipt-less in-flight completion writes no job.completed' || return 1
  fi
  if [[ "$(quota_rows "$job")" != 1 ]]; then
    assertion_red 'R28 receipt-less in-flight completion leaves the revived quota row live' || return 1
  fi
  [[ "$(release_events "$job")" == 1 ]] || return 1
  grep -q 'superseded' "$INBOX/$job/completion-sentinel.log" || return 1
}

case_t4_receiptless_inflight_prune() {
  reset_case mut-1813-t4-prune || return 3
  local job=mut-1813-t4-prune seq="$TMP/1813-t4-prune.seq" report="$TMP/1813-t4-prune.md" pid out
  # Keep the old watcher alive and asleep while prune probes its now-gone pane.
  arb claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 >/dev/null || return 3
  arb_lease "$job" || return 3
  SENT_INTERVAL=3600 start_sentinel "$job" w:p1 "$report"
  pid="$SENTINEL_PID"
  sentinel_mid_sleep "$pid" >/dev/null || return 3
  arb release --job "$job" --resource codex --kind quota_pool >/dev/null || return 3
  arb claim --job "$job" --lane lane-a --agent-label "lbl-$job" --t T1 \
    --reclaim-released >/dev/null || return 3
  arb_lease "$job" || return 3
  printf 'not-found\n' >"$seq"
  out="$(env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    WRK_FIXTURE_GET_SEQUENCE="$seq" "$WRK" prune --apply --job "$job" 2>&1)" || return 3
  if [[ "$(quota_rows "$job")" != 1 ]]; then
    assertion_red 'R27 receipt-less in-flight prune leaves the revived quota row live' || return 1
  fi
  if [[ "$(event_count "$INBOX/$job/events" job.revoked)" != 0 ]]; then
    assertion_red 'R27 receipt-less in-flight prune writes no job.revoked' || return 1
  fi
  [[ "$(release_events "$job")" == 1 ]] || return 1
  grep -q 'action=stopped-superseded' <<<"$out" || return 1
  wait_until 8 pid_gone "$pid" || return 1
}

case_t4_missing_pane_resets_previous_spawn() {
  reset_case mut-1813-t4-reset || return 3
  local job=mut-1813-t4-reset lib
  mk_job "$job" w:p1 || return 3
  arb event --job "$job" --kind job.spawned --payload-json '{"owner_lane":"lane-a","label":"lbl-mut-1813-t4-reset"}' >/dev/null || return 3
  lib="$(wrk_test_library)" || return 3
  if job_watch_current_from_library "$lib" "$INBOX/$job/events" w:p1; then
    assertion_red 'R20 pane-less newest spawn does not inherit the prior pane' || return 1
  fi
}

# N6 — replace the stale p1 watcher on respawn, then prove that a repeated
# request for current pane p2 leaves the replacement process alive.
case_respawn_replaces_only_stale_sentinel() {
  reset_case mut-1813-n6 || return 3
  local job=mut-1813-n6 report="$TMP/1813-n6-report.md" old_pid new_pid
  printf 'watch\n' >"$report"
  mk_job "$job" w:p1 || return 3
  start_completion_from_library "$INBOX/$job/completion-sentinel.pid" \
    "$job" lane-a "lbl-$job" w:p1 "$report" || return 3
  old_pid="$SENTINEL_PID"
  sentinel_mid_sleep "$old_pid" >/dev/null || return 3
  # No release is possible here: the job has no lease or quota record, and adding
  # one would add events this case does not model. The job.reclaim is therefore
  # written as a fixture file (see fixture_claim_event).
  fixture_claim_event "$job" job.reclaim "{\"owner_lane\":\"lane-a\",\"label\":\"lbl-$job\"}" || return 3
  arb event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl-$job\",\"pane_id\":\"w:p2\"}" >/dev/null || return 3
  start_completion_from_library "$INBOX/$job/completion-sentinel.pid" \
    "$job" lane-a "lbl-$job" w:p2 "$report" || return 3
  new_pid="$SENTINEL_PID"
  if [[ "$new_pid" == "$old_pid" ]] || ! wait_until 8 pid_gone "$old_pid"; then
    assertion_red 'R21 respawn replaces the old pane sentinel by its exact pid' || return 1
  fi
  sentinel_mid_sleep "$new_pid" >/dev/null || return 3
  start_completion_from_library "$INBOX/$job/completion-sentinel.pid" \
    "$job" lane-a "lbl-$job" w:p2 "$report" || return 3
  if [[ "$SENTINEL_PID" != "$new_pid" ]] || ! kill -0 "$new_pid" 2>/dev/null; then
    assertion_red 'R21 repeated current-pane start preserves the live sentinel' || return 1
  fi
}

# N7 — after a terminal and revive, a spawned pane that has been absent for
# the configured stale grace is the end of that current round.
case_dead_current_round_ends_after_grace() {
  reset_case mut-1813-n7 || return 3
  local job=mut-1813-n7 seq="$TMP/1813-n7.seq" out
  ARBITER_TEST_NOW=2026-10-20T00:00:00Z arb claim --job "$job" --lane lane-a \
    --agent-label "lbl-$job" --t T1 >/dev/null || return 3
  ARBITER_TEST_NOW=2026-10-20T00:00:01Z arb event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl-$job\",\"pane_id\":\"w:p1\",\"tab_id\":\"w:t1\"}" >/dev/null || return 3
  ARBITER_TEST_NOW=2026-10-20T00:00:02Z arb_lease "$job" || return 3
  ARBITER_TEST_NOW=2026-10-20T00:00:03Z arb event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl-$job\"}" >/dev/null || return 3
  ARBITER_TEST_NOW=2026-10-20T00:00:04Z arb release --job "$job" --resource codex --kind quota_pool >/dev/null || return 3
  ARBITER_TEST_NOW=2026-10-20T00:00:05Z arb claim --job "$job" --lane lane-a \
    --agent-label "lbl-$job" --t T1 --reclaim-released >/dev/null || return 3
  ARBITER_TEST_NOW=2026-10-20T00:00:06Z arb event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"lbl-$job\",\"pane_id\":\"w:p2\",\"tab_id\":\"w:t2\"}" >/dev/null || return 3
  ARBITER_TEST_NOW=2026-10-20T00:00:07Z arb_lease "$job" || return 3
  printf 'not-found\n' >"$seq"
  out="$(env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    WRK_FIXTURE_GET_SEQUENCE="$seq" "$WRK" prune --apply --job "$job" \
      --stale-age 1s 2>&1)" || return 3
  if [[ "$(event_count "$INBOX/$job/events" job.revoked)" != 1 ]]; then
    assertion_red 'R22 pane-gone revived round ends after the grace period' || return 1
  fi
  if [[ "$(quota_rows "$job")" != 0 ]]; then
    assertion_red 'R22 ended dead round releases its quota row' || return 1
  fi
  grep -q 'action=end-declaration' <<<"$out" || {
    assertion_red 'R22 prune records the dead current round end' || return 1
  }
}

# Item 6 — the prune pass reports and releases terminal jobs with no live
# sentinel. The fixture also models a historical release followed by a newer
# quota_pool.record for the same job and pool.
case_prune_terminal_quota_dry_run() {
  reset_case mut-1813-prune-dry || return 3
  local job=mut-1813-prune-dry out
  seed_ended_rerecorded_quota "$job" || return $?
  out="$(prune_run --job "$job" --stale-age 0s 2>&1)" || return 3
  if ! grep -Fq "would-release job=$job" <<<"$out"; then
    assertion_red 'R23 prune dry-run lists ended live quota rows' || return 1
  fi
  if [[ "$(grep -Fc "would-release job=$job" <<<"$out")" != 1 ]]; then
    assertion_red 'R23 prune dry-run logs one line for the job' || return 1
  fi
  [[ "$(quota_rows "$job")" == 1 ]] || {
    assertion_red 'R23 dry-run leaves the arbiter row untouched' || return 1
  }

  reset_case mut-1813-prune-live-sentinel || return 3
  job=mut-1813-prune-live-sentinel
  quota_spawn "$job" >/dev/null 2>&1 || return 3
  quota_wait_sentinel_sleep "$job" || return 3
  arb event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"default\",\"label\":\"lbl-$job\"}" >/dev/null || return 3
  out="$(prune_run --job "$job" --stale-age 0s 2>&1)" || return 3
  if grep -Fq "would-release job=$job" <<<"$out"; then
    assertion_red 'R23 prune leaves ended rows alone while a sentinel is live' || return 1
  fi
}

case_prune_historical_release_releases_rerecord() {
  reset_case mut-1813-prune-history || return 3
  local job=mut-1813-prune-history out
  seed_ended_rerecorded_quota "$job" || return $?
  [[ "$(release_events "$job")" == 1 ]] || return 3
  python3 - "$INBOX/$job/events" <<'PY' || return 3
import glob, json, os, sys
rows = []
paths = glob.glob(os.path.join(sys.argv[1], "*.json"))
for path in sorted(paths, key=lambda value: int(os.path.basename(value).split("-", 1)[0])):
    with open(path, encoding="utf-8") as source:
        event = json.load(source)
    if event.get("kind") in ("quota_pool.release", "quota_pool.record"):
        rows.append((event.get("kind"), event.get("payload", {}).get("pool")))
assert rows[-2:] == [("quota_pool.release", "codex"), ("quota_pool.record", "codex")], rows
PY
  out="$(prune_run --apply --job "$job" --stale-age 0s 2>&1)" || return 3
  if [[ "$(quota_rows "$job")" != 0 ]]; then
    assertion_red 'R25 a historical release does not hide a newer live record' || return 1
  fi
  [[ "$(release_events "$job")" == 2 ]] || {
    assertion_red 'R25 the later quota row gets its own release event' || return 1
  }
  [[ "$(grep -Fc "release-attempted job=$job" <<<"$out")" == 1 ]] || {
    assertion_red 'R25 prune logs one release line for the job' || return 1
  }
}

# A receipt-less reclaimed round can still have a later terminal proving the
# job ended. Pass 4 should release its row when no watcher remains to own it.
case_prune_receiptless_ended_quota() {
  reset_case mut-1813-prune-receiptless-ended || return 3
  local job=mut-1813-prune-receiptless-ended out
  mk_job "$job" w:p1 || return 3
  arb_lease "$job" || return 3
  arb release --job "$job" --resource codex --kind quota_pool >/dev/null || return 3
  arb claim --job "$job" --lane lane-a --agent-label lbl --t T1 \
    --reclaim-released >/dev/null || return 3
  arb_lease "$job" || return 3
  arb event --job "$job" --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null || return 3
  [[ "$(quota_rows "$job")" == 1 ]] || return 3
  out="$(prune_run --job "$job" --stale-age 0s 2>&1)" || return 3
  if ! grep -Fq "would-release job=$job" <<<"$out"; then
    assertion_red 'R31 prune dry-run includes an ended receipt-less reclaimed quota row' || return 1
  fi
  [[ "$(quota_rows "$job")" == 1 ]] || return 3
  out="$(prune_run --apply --job "$job" --stale-age 0s 2>&1)" || return 3
  if [[ "$(quota_rows "$job")" != 0 ]]; then
    assertion_red 'R31 prune apply releases an ended receipt-less reclaimed quota row' || return 1
  fi
  [[ "$(grep -Fc "release-attempted job=$job" <<<"$out")" == 1 ]] || {
    assertion_red 'R31 prune logs one release for the ended receipt-less reclaimed job' || return 1
  }
}

# The ended-no-sentinel release mode is still fail-closed if a live watcher
# appears after prune's candidate scan.
case_ended_quota_release_requires_no_live_sentinel() {
  reset_case mut-1813-ended-live-sentinel || return 3
  local job=mut-1813-ended-live-sentinel report="$TMP/1813-ended-live-sentinel.md"
  local lib out rc=0 pid
  mk_job "$job" w:p1 || return 3
  arb_lease "$job" || return 3
  printf 'watch\n' >"$report"
  SENT_INTERVAL=3600 start_completion_from_library \
    "$INBOX/$job/completion-sentinel.pid" "$job" lane-a "lbl-$job" w:p1 "$report" || return 3
  pid="$SENTINEL_PID"
  sentinel_mid_sleep "$pid" >/dev/null || return 3
  arb event --job "$job" --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null || return 3
  lib="$(wrk_test_library)" || return 3
  out="$(quota_release_current_from_library "$lib" "$job" w:p1 ended-no-sentinel 2>&1)" || rc=$?
  kill_owned_tree "$pid" || true
  if (( rc != 2 )) || ! grep -Fq "skip job=$job reason=live-sentinel" <<<"$out"; then
    assertion_red 'R32 ended quota release skips while a live sentinel exists' || return 1
  fi
}

# If a revive races the lost-grace release check, the sentinel must leave
# through sentinel_self_exit even though the guarded release returns rc=2.
case_lostgrace_guard_skip_removes_pidfile() {
  reset_case mut-1813-lostgrace-skip || return 3
  # Green and mutant cases run in the same test process/TMP root; isolate all
  # race-control files by reset_case's sequence so the green injection cannot
  # suppress the mutant's injection or satisfy its trace assertion.
  local job=mut-1813-lostgrace-skip seq="$TMP/1813-lostgrace-seq-$CASE_SEQ"
  local injected="$TMP/1813-lostgrace-injected-$CASE_SEQ" arbwrap="$TMP/1813-lostgrace-arbiter-$CASE_SEQ"
  local gatefile="$TMP/1813-lostgrace-gate-$CASE_SEQ" trace="$TMP/1813-lostgrace-trace-$CASE_SEQ" pid pidfile
  mk_job "$job" w:p1 || return 3
  arb_lease "$job" || return 3
  # Re-record a fresh quota row before the loss terminal. The wrapper below
  # injects only the reclaim receipt after job.revoked, avoiding cross-process
  # arbiter-root changes in the sentinel fixture.
  arb release --job "$job" --resource codex --kind quota_pool >/dev/null || return 3
  arb_lease "$job" || return 3
  quota_gate_out >"$gatefile" || return 3
  printf 'not-found\n' >"$seq"
  cat >"$arbwrap" <<EOF || return 3
#!/bin/bash
set -euo pipefail
printf 'call=%s\n' "\$*" >>"$trace"
if [[ "\${1:-}" == status && "\${3:-}" == "$job" && ! -e "$injected" ]] &&
    compgen -G "$INBOX/$job/events/*-job.revoked.json" >/dev/null; then
  printf 'inject\n' >>"$trace"
  : >"$injected"
  python3 - "$INBOX/$job/events" "$job" <<'PY' || {
import datetime, fcntl, json, os, sys, tempfile
events, job = sys.argv[1:]
os.makedirs(events, exist_ok=True)
lock_path = os.path.join(os.path.dirname(events), ".wrk-events.lock")
with open(lock_path, "w", encoding="utf-8") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    seqs = []
    for name in os.listdir(events):
        try:
            seqs.append(int(name.split("-", 1)[0]))
        except (ValueError, IndexError):
            pass
    seq = max(seqs, default=0) + 1
    record = {
        "job_id": job,
        "seq": seq,
        "kind": "job.reclaim",
        "payload": {"owner_lane": "lane-a", "label": "lbl"},
        "created_at": datetime.datetime.now(datetime.timezone.utc)
        .isoformat(timespec="milliseconds").replace("+00:00", "Z"),
    }
    fd, temporary = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=events)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(record, output, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        final = os.path.join(events, f"{seq:05d}-job.reclaim.json")
        os.link(temporary, final)
    finally:
        try:
            os.unlink(temporary)
        except OSError:
            pass
PY
    printf 'inject-reclaim-failed\n' >>"$trace"; exit 83;
  }
  compgen -G "$INBOX/$job/events/*-job.reclaim.json" >/dev/null || {
    printf 'inject-reclaim-artifact-missing\n' >>"$trace"; exit 84;
  }
  printf 'inject-complete\n' >>"$trace"
fi
exec env ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" "$ARBITER" "\$@"
EOF
  chmod +x "$arbwrap" || return 3
  RECOVERY_ARBITER="$arbwrap" SENT_INTERVAL=1 LOST_GRACE=1 \
    WRK_FIXTURE_GET_SEQUENCE="$seq" \
    start_completion_from_library "$INBOX/$job/completion-sentinel.pid" \
      "$job" lane-a "lbl-$job" w:p1 "$TMP/1813-lostgrace-report.md" || return 3
  pid="$SENTINEL_PID"
  pidfile="$INBOX/$job/completion-sentinel.pid"
  wait_until 20 pid_gone "$pid" || return 3
  grep -Fq 'inject-complete' "$trace" || { cat "$trace" >&2; return 3; }
  local reclaim_count
  reclaim_count="$(event_count "$INBOX/$job/events" job.reclaim)"
  [[ "$reclaim_count" == 1 ]] || {
    printf 'R33 setup: reclaim-count=%s event-dir=%s\n' \
      "$reclaim_count" "$INBOX/$job/events" >&2
    cat "$trace" >&2
    find "$INBOX/$job/events" -maxdepth 1 -type f -print >&2
    return 3
  }
  if [[ -s "$pidfile" ]]; then
    assertion_red 'R33 lost-grace guarded release skip removes the sentinel pidfile' || return 1
  fi
  [[ "$(quota_rows "$job")" == 1 ]] || {
    cat "$trace" >&2
    find "$INBOX/$job/events" -maxdepth 1 -type f -print >&2
    assertion_red 'R33 lost-grace revive keeps the reclaimed quota row live' || return 1
  }
}

case_prune_revived_during_release_scan() {
  reset_case mut-1813-prune-race || return 3
  local job=mut-1813-prune-race pid
  local injected="$TMP/1813-prune-injected" arbwrap="$TMP/1813-prune-arbiter"
  local gatefile="$TMP/1813-prune-gate" out
  seed_ended_rerecorded_quota "$job" || return $?
  quota_gate_out >"$gatefile" || return 3
  cat >"$arbwrap" <<EOF || return 3
#!/bin/bash
set -euo pipefail
if [[ "\${1:-}" == status ]]; then
  status_out="\$("$ARBITER" "\$@")" || exit \$?
  if [[ "\${3:-}" == "$job" && ! -e "$injected" ]]; then
    : >"$injected"
    "$ARBITER" release --job "$job" --resource codex --kind quota_pool >/dev/null
    "$ARBITER" claim --job "$job" --lane lane-a --agent-label "lbl-$job" \
      --t T1 --reclaim-released >/dev/null
    "$ARBITER" lease --job "$job" --kind quota_pool --profile codex-luna \
      --gate-output "\$(cat "$gatefile")" >/dev/null
  fi
  printf '%s\n' "\$status_out"
  exit 0
fi
exec "$ARBITER" "\$@"
EOF
  chmod +x "$arbwrap" || return 3
  out="$(env HERDR_BIN="$HERDR" ARBITER_BIN="$arbwrap" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    "$WRK" prune --apply --job "$job" --stale-age 0s 2>&1)" || return 3
  if ! grep -Fq "skip job=$job reason=revived-since-scan" <<<"$out"; then
    assertion_red 'R24 prune skips a job revived after its release scan' || return 1
  fi
  [[ "$(quota_rows "$job")" == 1 ]] || {
    assertion_red 'R24 prune leaves the re-recorded row live' || return 1
  }
}

# R1: the release inside shared job_end_housekeeping — covers wrk done,
# wrk joined and the delegated panewire path alike.
mkmut_span r1-no-housekeep-release \
  'hk1798-housekeeping-release' \
  '      : removed hk1798 housekeeping release'
expect_mut_red "R1a done-quota-release" case_release_done
expect_mut_red "R1b joined-quota-release" case_release_joined
expect_mut_red "R1c delegated-done-quota-release" case_release_delegate_done

# R2: the sentinel completed path's release
mkmut_span r2-no-sentinel-release \
  'hk1798-sentinel-completed-release' \
  '        : removed hk1798 sentinel-completed release'
expect_mut_red "R2 sentinel-completed-release" case_release_sentinel_completed

# R3: the sentinel lost-grace release (keep the end record; drop the release)
mkmut_span r3-no-lostgrace-release \
  'hk1798-lost-grace-release' \
  '        created|already-ended) : ;; # removed hk1798 lost-grace release'
expect_mut_red "R3 lost-grace-release" case_release_lost_grace

# R4: the watch-exit release
mkmut_span r4-no-watchexit-release \
  'hk1798-sentinel-watch-exit-release' \
  '      : removed hk1798 watch-exit release'
expect_mut_red "R4 watch-exit-release" case_release_watch_exit

# R5: reap's pre-close release — the order assertion is what goes RED (the
# post-close housekeeping release still drains the row under this mutant).
mkmut_span r5-no-reap-release \
  'hk1798-reap-preclose-release' \
  '      : removed hk1798 reap pre-close release'
expect_mut_red "R5 reap-release-before-close" case_release_reap_order

# R6: an ended job with no live sentinel is drained by prune's terminal quota pass.
mkmut_span r6-no-ended-quota-release \
  'hk1813-ended-quota-release-call' \
  '      : removed hk1813 ended quota release'
expect_mut_red "R6 prune-ended-quota-release" case_release_prune_orphan \
  'ASSERT-RED: R6 prune releases an ended orphan quota row'

# R7: prune's pane-gone release (keep the end record; drop the release)
mkmut_span r7-no-panegone-release \
  'hk1798-pane-gone-release' \
  '          : removed hk1798 pane-gone release'
expect_mut_red "R7 prune-pane-gone-release" case_release_prune_panegone

# R8: prune's stale-job release
mkmut_span r8-no-stale-release \
  'hk1798-prune-stale-release' \
  '        : removed hk1798 stale release'
expect_mut_red "R8 prune-stale-release" case_release_prune_stale

# R9: the takeover hand-off release
mkmut_span r9-no-takeover-release \
  'hk1813-takeover-release-best-effort' \
  '  : removed hk1798 takeover release'
expect_mut_red "R9 takeover-release" case_release_takeover

# R10: pane-gone observations cannot end a job revived after its terminal.
mkmut_span r10-pane-gone-live-guard \
  'hk1798-pane-gone-end-gate' \
  '        if true; then # removed hk1798 pane-gone live guard'
expect_mut_red "R10 pane-gone-live-release-guard" case_live_revival_prune_pane_gone

# R11: housekeeping must not release a round revived after a prior completion.
mkmut_span r11-housekeeping-active-release \
  'hk1798-housekeeping-active-guard' \
  '    active) release_job_quota_pool "$job"; stop_completion_sentinel "$job"; return 0 ;;'
r11_mut_source="$MUT"
r11_mut_dir="$TMP/mut-r11-without-release-time-check"
mkdir -p "$r11_mut_dir"
awk -v pat='hk1813-release-time-check' \
  'index($0, pat) { print "    : # removed hk1813 release-time check"; next } { print }' \
  "$r11_mut_source" >"$r11_mut_dir/wrk"
chmod +x "$r11_mut_dir/wrk"
MUT="$r11_mut_dir/wrk"
expect_mut_red "R11 housekeeping-active-revive-guard" case_duplicate_done_after_revival \
  'ASSERT-RED: R11 duplicate completion preserves the revived quota row'

# R12: prune's pane-gone superseded gate — without it a stale sentinel's dead
# pane lets prune end and release the terminal-less revived round.
mkmut_span r12-no-panegone-superseded \
  'hk1798-pane-gone-superseded' \
  '        if false; then # removed hk1798 pane-gone superseded gate'
expect_mut_red "R12 pane-gone-superseded-gate" case_revive_noterminal_prune_superseded

# R13: the sentinel's own lost-grace superseded gate — without it the stale
# watcher ends and releases the live round when its grace expires.
mkmut_span r13-no-lostgrace-superseded \
  'hk1798-lost-grace-superseded' \
  '        if false; then # removed hk1798 lost-grace superseded gate'
expect_mut_red "R13 lost-grace-superseded-gate" case_revive_noterminal_lostgrace_superseded

# R14: revert the prune gate to comparing the watched pane with the newest
# job.spawned pane only — the in-flight reclaim slips past and the release
# lands, so QR18's case must still go RED.
mkmut_span r14-pane-gone-oldcheck \
  'hk1798-pane-gone-superseded' \
  '        if [[ "$(job_events_scan "$PRUNE_ROOT/$job/events" 2>/dev/null | awk -F'"'"'\\t'"'"' '"'"'{print $10; exit}'"'"')" != "$pane" ]]; then # reverted hk1798-pane-gone-superseded'
expect_mut_red "R14 pane-gone-revert-old-check" case_revive_inflight_prune_superseded

# R15: the same revert on the sentinel's lost-grace gate.
mkmut_span r15-lostgrace-oldcheck \
  'hk1798-lost-grace-superseded' \
  '        if [[ "$(job_events_scan "$jobdir/events" 2>/dev/null | awk -F'"'"'\\t'"'"' '"'"'{print $10; exit}'"'"')" != "$pane" ]]; then # reverted hk1798-lost-grace-superseded'
expect_mut_red "R15 lost-grace-revert-old-check" case_revive_inflight_lostgrace_superseded

if [[ "${WRK_JOB_END_RED_FIRST:-0}" == 1 ]]; then
  run_red_first_case "item 1 reap release-time recheck" case_reap_revived_since_scan \
    'ASSERT-RED: R16 reap skips a candidate revived after the scan'
  run_red_first_case "item 2 stale sentinel completed gate" case_sentinel_completed_superseded \
    'ASSERT-RED: R17 superseded sentinel writes no job.completed'
  run_red_first_case "item 3 foreground release warning" case_release_failure_logging_modes \
    'ASSERT-RED: R18 foreground release failure warns once on stderr'
  run_red_first_case "item 4 claim-only spawn receipt" case_t4_claim_without_spawn_is_current \
    'ASSERT-RED: R19 claim-only first round is current without a spawn receipt'
  # R26 and R27 cover regressions introduced by the receipt-less fix; the
  # unmodified base already leaves these in-flight reclaim rows untouched.
  run_red_first_case "item 4 receipt-less in-flight completion regression" case_t4_receiptless_inflight_completed \
    'ASSERT-RED: R28 receipt-less in-flight completion writes no job.completed'
  run_red_first_case "item 4 pane-less spawn reset" case_t4_missing_pane_resets_previous_spawn \
    'ASSERT-RED: R20 pane-less newest spawn does not inherit the prior pane'
  run_red_first_case "item 5 N6 stale sentinel replacement" case_respawn_replaces_only_stale_sentinel \
    'ASSERT-RED: R21 respawn replaces the old pane sentinel by its exact pid'
  run_red_first_case "item 5 N7 dead current round" case_dead_current_round_ends_after_grace \
    'ASSERT-RED: R22 pane-gone revived round ends after the grace period'
  run_red_first_case "item 6a terminal quota dry-run" case_prune_terminal_quota_dry_run \
    'ASSERT-RED: R23 prune dry-run lists ended live quota rows'
  run_red_first_case "item 6a prune scan-to-release race" case_prune_revived_during_release_scan \
    'ASSERT-RED: R24 prune skips a job revived after its release scan'
  run_red_first_case "item 6b historical release then re-record" case_prune_historical_release_releases_rerecord \
    'ASSERT-RED: R25 a historical release does not hide a newer live record'
  run_red_first_case "takeover handles a guarded release skip" case_takeover_release_guard_skip_continues_spawn \
    'ASSERT-RED: R30 takeover continues spawn when the release guard skips cleanup'
  run_red_first_case "ended receipt-less quota prune" case_prune_receiptless_ended_quota \
    'ASSERT-RED: R31 prune dry-run includes an ended receipt-less reclaimed quota row'
  echo "PASS hk1813 RED-first cases failed at assertions on base $(git -C "$ROOT" rev-parse --short HEAD)"
  exit 0
fi

run_green_contract_case "item 1 reap release-time recheck" case_reap_revived_since_scan
run_green_contract_case "item 2 stale sentinel completed gate" case_sentinel_completed_superseded
run_green_contract_case "item 3 foreground and detached failure logs" case_release_failure_logging_modes
run_green_contract_case "item 4 claim-only spawn receipt" case_t4_claim_without_spawn_is_current
run_green_contract_case "item 4 receipt-less in-flight lost-grace" case_t4_receiptless_inflight_lostgrace
run_green_contract_case "item 4 receipt-less in-flight completion" case_t4_receiptless_inflight_completed
run_green_contract_case "item 4 receipt-less in-flight prune" case_t4_receiptless_inflight_prune
run_green_contract_case "item 4 pane-less spawn reset" case_t4_missing_pane_resets_previous_spawn
run_green_contract_case "item 5 N6 stale sentinel replacement" case_respawn_replaces_only_stale_sentinel
run_green_contract_case "item 5 N7 dead current round" case_dead_current_round_ends_after_grace
run_green_contract_case "item 6a terminal quota dry-run" case_prune_terminal_quota_dry_run
run_green_contract_case "item 6a prune scan-to-release race" case_prune_revived_during_release_scan
run_green_contract_case "item 6b historical release then re-record" case_prune_historical_release_releases_rerecord
run_green_contract_case "takeover continues after guarded release skip" case_takeover_release_guard_skip_continues_spawn
run_green_contract_case "ended receipt-less reclaimed quota prune" case_prune_receiptless_ended_quota
run_green_contract_case "ended quota release requires no live sentinel" case_ended_quota_release_requires_no_live_sentinel
run_green_contract_case "lost-grace guard skip clears its sentinel pidfile" case_lostgrace_guard_skip_removes_pidfile
run_green_contract_case "prune orphan-sentinel release site" case_release_prune_sentinel_orphan

# R16: the reap candidate is only a snapshot. Its post-probe release must
# re-read both terminal ordering and the candidate pane before touching rows.
mkmut_span r16-disable-release-time-check \
  'hk1813-release-time-check' \
  '    : # removed hk1813 release-time check'
expect_mut_red "R16 reap release-time guard" case_reap_revived_since_scan \
  'ASSERT-RED: R16 reap skips a candidate revived after the scan'

# R17: a report key on a superseded watch pane cannot write a completion.
mkmut_span r17-remove-sentinel-completed-gate \
  'hk1813-sentinel-completed-current-gate' \
  '        if false; then # removed hk1813 sentinel completed gate'
expect_mut_red "R17 sentinel completed current-round gate" case_sentinel_completed_superseded \
  'ASSERT-RED: R17 superseded sentinel writes no job.completed'

# R18: foreground callers need stderr visibility while detached callers rely
# on the one structured line already written to completion-sentinel.log.
mkmut_span r18-remove-foreground-release-warning \
  'hk1813-foreground-release-warning' \
  '      if false; then # removed hk1813 foreground release warning'
expect_mut_red "R18 foreground release warning" case_release_failure_logging_modes \
  'ASSERT-RED: R18 foreground release failure warns once on stderr'

# R19: a first-round job.claim without a job.spawned receipt still owns its
# sentinel; preserve QR18/QR19 where a known prior spawn is followed by claim.
mkmut r19-revert-claim-only-current \
  's~(last_spawn == -1 and claim_count <= 1) # hk1813-t4-no-spawn-current~(last_spawn == -1 and claim_count == 0) # hk1813-t4-no-spawn-current~'
expect_mut_red "R19 claim-only spawn receipt guard" case_t4_claim_without_spawn_is_current \
  'ASSERT-RED: R19 claim-only first round is current without a spawn receipt'

# R20: a job.spawned receipt without pane_id resets the previous pane.
mkmut_span r20-inherit-old-spawn-pane \
  'hk1813-spawn-pane-reset' \
  '        pass # removed hk1813 spawn pane reset'
expect_mut_red "R20 pane-less spawn receipt reset" case_t4_missing_pane_resets_previous_spawn \
  'ASSERT-RED: R20 pane-less newest spawn does not inherit the prior pane'

# R21: an existing sentinel on another pane is stale after respawn. The
# mutation restores unconditional pidfile suppression instead of exact-pid replacement.
mkmut_span r21-keep-stale-pane-sentinel \
  'hk1813-replace-sentinel-pane-check' \
  '      return 0 # reverted hk1813 stale pane sentinel replacement'
expect_mut_red "R21 N6 stale sentinel replacement" case_respawn_replaces_only_stale_sentinel \
  'ASSERT-RED: R21 respawn replaces the old pane sentinel by its exact pid'

# R22: a current pane confirmed gone past prune's stale grace may end the
# revived round even when an older terminal precedes that revive.
mkmut_span r22-reject-dead-current-round \
  'hk1813-allow-dead-current-round' \
  '        if True: # removed hk1813 dead-current-round rule'
expect_mut_red "R22 N7 dead current round end rule" case_dead_current_round_ends_after_grace \
  'ASSERT-RED: R22 pane-gone revived round ends after the grace period'

# R23: terminal jobs with no live sentinel must be visible in dry-run and
# releasable by apply even if their stale rows have no process owner.
mkmut_span r23-disable-ended-quota-pass \
  'hk1813-ended-quota-release-pass' \
  '    continue # removed hk1813 ended quota release pass'
expect_mut_red "R23 prune terminal quota pass" case_prune_terminal_quota_dry_run \
  'ASSERT-RED: R23 prune dry-run lists ended live quota rows'

# R24: the ended-quota pass rechecks the event stream after arbiter status;
# the injected reclaim between the two reads must leave the row leased.
mkmut_span r24-disable-release-time-check \
  'hk1813-release-time-check' \
  '    : # removed hk1813 release-time check'
expect_mut_red "R24 prune release-time guard" case_prune_revived_during_release_scan \
  'ASSERT-RED: R24 prune skips a job revived after its release scan'

# R25: an earlier quota_pool.release is historical when the arbiter has a
# later live quota_pool.record for the same job and pool.
mkmut_span r25-suppress-rerecord-after-release \
  'hk1813-ended-quota-release-call' \
  '        if grep -q "quota_pool.release" "$PRUNE_ROOT/$job"/events/*; then :; else release_job_quota_pool "$job" "$_pane"; fi # hk1813 ended quota release call'
expect_mut_red "R25 historical release does not hide re-record" case_prune_historical_release_releases_rerecord \
  'ASSERT-RED: R25 a historical release does not hide a newer live record'

# R26: a receipt-less second claim is a reclaimed round; the old sentinel's
# lost-grace action must not revoke or release that round's live quota row.
mkmut r26-receiptless-lostgrace-current \
  's~(last_spawn == -1 and claim_count <= 1) # hk1813-t4-no-spawn-current~(last_spawn == -1) # hk1813-t4-no-spawn-current~'
expect_mut_red "R26 receipt-less in-flight lost-grace guard" case_t4_receiptless_inflight_lostgrace \
  'ASSERT-RED: R26 receipt-less in-flight lost-grace leaves the revived quota row live'

# R27: the prune pane-gone path must apply the same receipt-less reclaim rule.
mkmut r27-receiptless-prune-current \
  's~(last_spawn == -1 and claim_count <= 1) # hk1813-t4-no-spawn-current~(last_spawn == -1) # hk1813-t4-no-spawn-current~'
expect_mut_red "R27 receipt-less in-flight prune guard" case_t4_receiptless_inflight_prune \
  'ASSERT-RED: R27 receipt-less in-flight prune leaves the revived quota row live'

# R28: the completed path also uses current-round identity when a T4 receipt
# is missing and a reclaimed round is in flight.
mkmut r28-receiptless-completed-current \
  's~(last_spawn == -1 and claim_count <= 1) # hk1813-t4-no-spawn-current~(last_spawn == -1) # hk1813-t4-no-spawn-current~'
expect_mut_red "R28 receipt-less in-flight completion guard" case_t4_receiptless_inflight_completed \
  'ASSERT-RED: R28 receipt-less in-flight completion writes no job.completed'

# R29: this is distinct from the newer terminal quota pass, which skips a
# job while the orphan sentinel is still live.
mkmut_span r29-no-prune-sentinel-release \
  'release_job_quota_pool "$job" "$j_pane" || release_rc=$? # hk1798-prune-orphan-release' \
  '      : # removed hk1798 prune orphan-sentinel release'
expect_mut_red "R29 prune orphan-sentinel release site" case_release_prune_sentinel_orphan \
  'ASSERT-RED: R29 prune orphan-sentinel path releases the ended live quota row'

# R30: the hand-off is already committed when the release guard can safely
# skip, so its rc=2 must not abort the new spawn after changing task refs.
mkmut_span r30-abort-on-takeover-release-skip \
  'hk1813-takeover-release-best-effort' \
  '  release_job_quota_pool "$TAKEOVER_FROM" # reverted hk1813 takeover release handling'
expect_mut_red "R30 takeover continues after guarded release skip" case_takeover_release_guard_skip_continues_spawn \
  'ASSERT-RED: R30 takeover continues spawn when the release guard skips cleanup'

# R31: an ended receipt-less reclaimed round has no current pane to match,
# but terminal ordering and the no-live-sentinel check authorize pass 4.
mkmut_span r31-require-current-pane-for-ended-quota \
  'hk1813-ended-no-sentinel-mode' \
  '  if false; then # removed hk1813 ended-no-sentinel mode'
expect_mut_red "R31 ended receipt-less quota prune mode" case_prune_receiptless_ended_quota \
  'ASSERT-RED: R31 prune dry-run includes an ended receipt-less reclaimed quota row'

# R32: pass 4 must recheck that no live completion sentinel owns the ended
# job immediately before releasing its quota row.
mkmut_span r32-ignore-ended-live-sentinel \
  'hk1813-ended-quota-live-sentinel-check' \
  '    if false; then # removed hk1813 no-live-sentinel check'
expect_mut_red "R32 ended quota no-live-sentinel release guard" case_ended_quota_release_requires_no_live_sentinel \
  'ASSERT-RED: R32 ended quota release skips while a live sentinel exists'

# R33: a rc=2 release guard in lost-grace is a safe skip, not a reason to
# bypass sentinel_self_exit and strand a stale pidfile.
mkmut_span r33-strand-lostgrace-sentinel-pidfile \
  'hk1798-lost-grace-release' \
  '        created|already-ended) release_job_quota_pool "$job" "$pane" ;; # reverted lost-grace rc handling'
expect_mut_red "R33 lost-grace guard skip removes sentinel pidfile" case_lostgrace_guard_skip_removes_pidfile \
  'ASSERT-RED: R33 lost-grace guarded release skip removes the sentinel pidfile'

# R34: hk1888 — restoring the unconditional lost:timeout makes a live pane
# past the watch window write job.lost again.
mkmut_span r34-unconditional-lost-timeout \
  'hk1888-watch-expired-live-guard' \
  '      if false; then # reverted hk1888 live-pane guard'
expect_mut_red "R34 live pane past the window is not lost" live_window_working_case \
  'FAIL: je45: a live pane past the window must not write job.lost'

# R35: hk1888 round 2 — a release in the watch-expired exit must lose the live
# job's real quota row. The mutant calls the arbiter directly: a call-only
# release_job_quota_pool is an equivalent mutant for a live job, because its
# quota_release_round_current guard (hk 1813, #229) refuses to release a job
# with no work-terminal record, so that call leaves the row and writes nothing.
# expect_mut_red runs the case in a subshell, so CASE_SEQ does not advance: the
# case gets its own job name or it would reuse R34's inbox.
live_window_working_quota_case() { live_window_case je45q sentinel-working; }
mkmut_span r35-watch-expired-releases-quota \
  'hk1888-watch-expired-exit' \
  '    if [[ -n "$watch_expired" ]]; then "${ARBITER:-arbiter}" release --job "$job" --resource codex --kind quota_pool >/dev/null 2>&1 || : # reverted: watch-expired releases quota'
expect_mut_red "R35 watch-expired must not release the live job's quota row" live_window_working_quota_case \
  "FAIL: je45q: a live pane past the window must leave the job's quota row in place"

# ── hk1959 mutants: the one-confirmation-poll rule for late reports ──────
# Same subshell rule as R34/R35: each mutant case body needs its own job
# name so the reused case does not collide with an earlier run's inbox.
case_late_unstable_r36() { late_window_case je52m36 unstable; }
case_late_unstable_r37() { late_window_case je52m37 unstable; }
case_late_stable_r38() { late_window_case je51m38 stable; }
case_late_stable_r39() { late_window_case je51m39 stable; }

# R36: keying the deadline on action=none alone again makes every late
# pending skip the check — an unstable late report holds the watch forever
# instead of expiring after one confirmation poll.
mkmut r36-deadline-on-action-none \
  's~( "\$action" == none || "\$action" == pending )~( "$action" == none )~'
expect_mut_red "R36 the deadline must also gate late pendings" case_late_unstable_r36 \
  'FAIL: je52m36: the sentinel must leave once the late pending resolves'

# R37: the allowance is exactly one late pending. Letting every pending take
# the branch keeps an unstable late report's sentinel alive forever.
mkmut_span r37-every-late-pending \
  'if [[ "$action" == pending && -z "$late_pending" ]]; then # hk1959-late-pending' \
  '        if [[ "$action" == pending ]]; then # removed hk1959 once-only gate'
expect_mut_red "R37 only the first late pending is allowed" case_late_unstable_r37 \
  'FAIL: je52m37: the sentinel must leave once the late pending resolves'

# R38: the late pending still needs its confirmation poll. Expiring on the
# first sighting turns a stable late report into a watch-expired exit.
mkmut_span r38-expire-on-first-late-pending \
  'if [[ "$action" == pending && -z "$late_pending" ]]; then # hk1959-late-pending' \
  '        if false; then # removed hk1959 late-pending confirmation'
expect_mut_red "R38 the first late pending must not expire" case_late_stable_r38 \
  'FAIL: je51m38: the late sighting must log exactly one action=pending late=1'

# R39: a completed poll past the deadline is never turned into
# watch-expired — including the confirmation poll that ends a stable late
# report's watch.
mkmut r39-completed-becomes-watch-expired \
  's~( "\$action" == none || "\$action" == pending )~( "$action" == none || "$action" == pending || "$action" == completed )~'
expect_mut_red "R39 completed must never become watch-expired" case_late_stable_r39 \
  'FAIL: je51m39: the confirmed late report must complete'

# ── hk1892: a sentinel whose job dir is gone leaves quietly ──────────────
# Rule: at the top of every poll, 2 consecutive polls with the jobdir missing
# (or the events dir missing after it was seen) end the sentinel with exit 0:
# no log line, no event, no release, no directory re-created. Interval 1 and
# a polled sleep child keep every case deterministic.

# gone_new_sleep PID OLD — wait for a sleep child other than OLD (a poll ran
# and the sentinel went back to sleep) or for the sentinel to be gone.
gone_new_sleep() {
  local pid="$1" old="$2" c deadline=$(( $(date +%s) + 8 ))
  while (( $(date +%s) <= deadline )); do
    pid_gone "$pid" && return 0
    c="$(sentinel_mid_sleep "$pid" 2>/dev/null || true)"
    [[ -n "$c" && "$c" != "$old" ]] && return 0
    sleep 0.1
  done
  return 1
}

gone_start() {
  reset_case "$1" || return 3
  recovery_arm_stub
  SENT_INTERVAL=1
  start_sentinel "$1" w:p1 "$TMP/$1-report.md"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
}

gone_no_job_lost() {
  [[ -z "$(find "$TMP" -path "*$1*" -name '*job.lost*' 2>/dev/null)" ]]
}

case_gone_root() {
  local job="$1"
  gone_start "$job" || return 3
  rm -rf "$INBOX"
  if ! wait_until 8 pid_gone "$SENTINEL_PID"; then
    echo "FAIL: $job: the sentinel must exit once its job root is gone" >&2
    recovery_stop; return 1
  fi
  [[ ! -e "$INBOX" ]] || { echo "FAIL: $job: the removed root was re-created" >&2; recovery_stop; return 1; }
  gone_no_job_lost "$job" || { echo "FAIL: $job: a job.lost was written" >&2; recovery_stop; return 1; }
  [[ "$(recovery_release_count)" == 0 ]] || { echo "FAIL: $job: a release ran before the exit" >&2; recovery_stop; return 1; }
  recovery_stop
}

case_gone_events() {
  local job="$1"
  reset_case "$job" || return 3
  mkdir -p "$INBOX/$job/events"
  gone_start_after_reset "$job" || return 3
  rm -rf "$INBOX/$job/events"
  if ! wait_until 8 pid_gone "$SENTINEL_PID"; then
    echo "FAIL: $job: the sentinel must exit once a seen events dir is gone" >&2
    recovery_stop; return 1
  fi
  [[ ! -e "$INBOX/$job/events" ]] || { echo "FAIL: $job: the events dir was re-created" >&2; recovery_stop; return 1; }
  gone_no_job_lost "$job" || { echo "FAIL: $job: a job.lost was written" >&2; recovery_stop; return 1; }
  recovery_stop
}

gone_start_after_reset() {
  recovery_arm_stub
  SENT_INTERVAL=1
  start_sentinel "$1" w:p1 "$TMP/$1-report.md"
  sentinel_mid_sleep "$SENTINEL_PID" >/dev/null || return 3
}

case_gone_never_events() {
  local job="$1"
  gone_start "$job" || return 3
  sleep 3.5
  if ! kill -0 "$SENTINEL_PID" 2>/dev/null; then
    echo "FAIL: $job: a never-created events dir is not absence; the sentinel must keep running" >&2
    recovery_stop; return 1
  fi
  recovery_stop
}

case_gone_flap() {
  local job="$1" c1 lines_before lines_after
  gone_start "$job" || return 3
  c1="$(sentinel_mid_sleep "$SENTINEL_PID")" || return 3
  mv "$INBOX/$job" "$INBOX/$job.away"
  gone_new_sleep "$SENTINEL_PID" "$c1" || { recovery_stop; return 3; }
  if pid_gone "$SENTINEL_PID"; then
    echo "FAIL: $job: one missing poll must not end the sentinel" >&2
    recovery_stop; return 1
  fi
  mv "$INBOX/$job.away" "$INBOX/$job"
  lines_before="$(wc -l <"$INBOX/$job/completion-sentinel.log" 2>/dev/null | tr -d ' ')"
  sleep 3.5
  if ! kill -0 "$SENTINEL_PID" 2>/dev/null; then
    echo "FAIL: $job: the sentinel must survive a flap" >&2
    recovery_stop; return 1
  fi
  lines_after="$(wc -l <"$INBOX/$job/completion-sentinel.log" 2>/dev/null | tr -d ' ')"
  (( ${lines_after:-0} > ${lines_before:-0} )) ||
    { echo "FAIL: $job: the sentinel must keep logging after a flap" >&2; recovery_stop; return 1; }
  recovery_stop
}

echo "== JE54: a sentinel with a gone job dir exits quietly =="
case_gone_root je54a || fail "JE54 removed root"
echo "PASS je54 removed-root"
case_gone_events je54b || fail "JE54 removed events dir"
echo "PASS je54 removed-events"
case_gone_never_events je54c || fail "JE54 never-created events dir"
echo "PASS je54 never-created-events"
case_gone_flap je54d || fail "JE54 flap"
echo "PASS je54 flap"

case_gone_root_m40() { case_gone_root je54m40; }
case_gone_flap_m41() { case_gone_flap je54m41; }
case_gone_never_events_m42() { case_gone_never_events je54m42; }
case_gone_root_m43() { case_gone_root je54m43; }

# hk1892 mutants: each load-bearing piece of the rule is pinned to its case.
mkmut_span r40-no-check \
  'if [[ ! -d "$jobdir" || ( -n "$events_seen" && ! -d "$jobdir/events" ) ]]; then # hk1892-jobdir-gone' \
  '    if false; then # removed hk1892 check'
expect_mut_red "R40 the gone check must exist" case_gone_root_m40 \
  'FAIL: je54m40: the sentinel must exit once its job root is gone'

mkmut r41-exit-on-first-miss \
  's~(( gone < SENTINEL_GONE_POLLS ))~(( gone < 1 ))~'
expect_mut_red "R41 one missing poll must not end the sentinel" case_gone_flap_m41 \
  'FAIL: je54m41: one missing poll must not end the sentinel'

mkmut r42-never-created-is-gone \
  's~( -n "\$events_seen" \&\& ! -d "\$jobdir/events" )~( ! -d "$jobdir/events" )~'
expect_mut_red "R42 a never-created events dir is not absence" case_gone_never_events_m42 \
  'FAIL: je54m42: a never-created events dir is not absence'

mkmut r43-release-before-exit \
  's~(( gone < SENTINEL_GONE_POLLS )) || sentinel_self_exit "\$job" 0~(( gone < SENTINEL_GONE_POLLS )) || { "$ARBITER_BIN" release --job "$job" --resource claude --kind quota_pool; sentinel_self_exit "$job" 0; }~'
expect_mut_red "R43 no release before the exit" case_gone_root_m43 \
  'FAIL: je54m43: a release ran before the exit'

echo "PASS test-wrk-job-end: all cases"
