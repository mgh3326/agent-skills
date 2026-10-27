#!/usr/bin/env bash
# shellcheck disable=SC2016 # mutant specs and fixture JSON are literal text
# hk 2090 contract tests: the wrk prune artifact pass — cache and
# intermediate-build classes from director/artifact_policy.json
# (schema fleet.artifact-policy.v1). Evidence, final-build and record text
# are out of scope for this task and must never be touched.
#
# Every tree these tests delete is built under TMP; nothing under the real
# ~/work is referenced. Job state fixtures are hand-written event files under
# the case's own herdr-inbox/jobs root; the canonical layout is kept
# (ARBITER_INBOX_ROOT = WORK/herdr-inbox/jobs) so the policy's root paths
# resolve exactly like production.
set -euo pipefail
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="${WRK_TEST_BIN:-$ROOT/bin/wrk}"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="${ARBITER_TEST_BIN:-$ROOT/bin/arbiter}"
HK="$ROOT/tests/fixtures/handoffkeep"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wrk-artifact-prune.XXXXXX")"
# Canonicalize: TMPDIR carries a trailing slash on macOS (// segments) and
# /var is a symlink, while the pass reports normpath'd match paths — every
# string the tests compare must share one canonical form.
TMP="$(cd "$TMP" && pwd -P)"
# shellcheck disable=SC1091
. "$ROOT/tests/lib/tmp-writers.sh"
export TW_TMP="$TMP"

OWNED_PID_LOG="$TMP/owned-pids"; : >"$OWNED_PID_LOG"
own() { [[ "$1" =~ ^[0-9]+$ ]] || return 0; tw_register_pid "$OWNED_PID_LOG" "$1"; }

cleanup() {
  local tw_rc=0
  # shellcheck disable=SC2119 # the trap's cleanup takes no args by design
  tmp_writers_stop || tw_rc=$?
  (( tw_rc == 0 )) && rm -rf "$TMP"
  if [[ "$tw_rc" -ne 0 || -n "${TW_LEFTOVER_PIDS:-}" ]]; then
    echo "FAIL: tracked writers survived teardown:${TW_LEFTOVER_PIDS:-}" >&2
    exit 1
  fi
}
trap cleanup EXIT

export CLINEPASS_GATE_KEY_FILE="$TMP/clinepass-gate-key.txt"
printf 'fixture-gate-key\n' >"$CLINEPASS_GATE_KEY_FILE"
export WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml"
export ARBITER_BIN="$ARBITER" SCOPEFUEL_BIN="$SCOPEFUEL"
export XDG_DATA_HOME="$TMP/xdg-default"
mkdir -p "$XDG_DATA_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }
die3() { echo "SETUP: $*" >&2; exit 3; }  # setup failure inside a mutant case

# Per-case roots. WORK is the fleet work root: jobs root = WORK/herdr-inbox/jobs,
# webqa root = WORK/webqa-runner/jobs — the same relative layout the shipped
# policy names under ~/work.
WORK="" INBOX="" WEBQA="" HK_DB="" POLICY="" GET_SEQ="" HK_MODE_VAR="" XDG=""
ULOCK="" LSOF_STUB="" LSOF_OPEN=""
CASE_SEQ=0
reset_case() {
  CASE_SEQ=$((CASE_SEQ + 1))
  WORK="$TMP/work-$1-$CASE_SEQ"
  INBOX="$WORK/herdr-inbox/jobs"
  WEBQA="$WORK/webqa-runner/jobs"
  HK_DB="$TMP/hk-$1-$CASE_SEQ.json"
  POLICY="$TMP/policy-$1-$CASE_SEQ.json"
  XDG="$TMP/xdg-$1-$CASE_SEQ"; mkdir -p "$XDG"
  GET_SEQ="" HK_MODE_VAR="" ULOCK="" LSOF_STUB="" LSOF_OPEN=""
  # Default lsof probe: report every path clean so cases never depend on a
  # host lsof existing (it is absent from PATH on some runners). The ap7e
  # case replaces this with a controllable stub.
  LSOF_STUB="$TMP/lsof-clean-$1-$CASE_SEQ"
  printf '#!/bin/sh\nexit 1\n' >"$LSOF_STUB"
  chmod +x "$LSOF_STUB"
  mkdir -p "$INBOX" "$WEBQA"
}

prune_run() {
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$INBOX" \
    XDG_DATA_HOME="$XDG" HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" \
    ${GET_SEQ:+WRK_FIXTURE_GET_SEQUENCE="$GET_SEQ"} \
    ${HK_MODE_VAR:+HK_MODE="$HK_MODE_VAR"} \
    ${ULOCK:+WRK_PRUNE_UNITY_LOCK="$ULOCK"} \
    ${LSOF_STUB:+WRK_LSOF_BIN="$LSOF_STUB"} \
    ${LSOF_OPEN:+LSOF_STUB_OPEN="$LSOF_OPEN"} \
    "$WRK" prune --policy "$POLICY" "$@"
}

# write_event EVENTS_DIR JOB KIND MOMENT PAYLOAD_JSON — one canonical event
# file, numbered like the other writers, at an explicit created_at. The file
# mtime is set to the same moment so both clocks the scan reads agree.
write_event() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import datetime, json, os, re, sys
events, job, kind, moment, payload = sys.argv[1:6]
os.makedirs(events, exist_ok=True)
seq = max((int(n[:5]) for n in os.listdir(events) if re.match(r"\d{5}-", n)),
          default=0) + 1
doc = {"kind": kind, "job_id": job, "created_at": moment,
       "payload": json.loads(payload)}
path = os.path.join(events, "%05d-%s.json" % (seq, kind))
with open(path, "x", encoding="utf-8") as handle:
    handle.write(json.dumps(doc, sort_keys=True) + "\n")
stamp = datetime.datetime.fromisoformat(
    moment.replace("Z", "+00:00")).timestamp()
os.utime(path, (stamp, stamp))
PY
}

# mk_ended_job JOB TASK_ID PANE [MOMENT] — claim(task_id) + spawned + completed,
# all at MOMENT (default five days ago: past the default --heavy-age 3d).
mk_ended_job() {
  local moment="${4:-2026-10-21T00:00:00Z}"
  local ev="$INBOX/$1/events"
  write_event "$ev" "$1" job.claim "$moment" \
    "{\"owner_lane\":\"lane-a\",\"label\":\"lbl\",\"task_id\":$2}"
  write_event "$ev" "$1" job.spawned "$moment" \
    "{\"owner_lane\":\"lane-a\",\"label\":\"lbl\",\"pane_id\":\"$3\"}"
  write_event "$ev" "$1" job.completed "$moment" \
    "{\"owner_lane\":\"lane-a\",\"label\":\"lbl\"}"
}

# mk_live_job JOB TASK_ID PANE — claim(task_id) + spawned only, no terminal.
mk_live_job() {
  local ev="$INBOX/$1/events"
  write_event "$ev" "$1" job.claim "2026-10-26T00:00:00Z" \
    "{\"owner_lane\":\"lane-a\",\"label\":\"lbl\",\"task_id\":$2}"
  write_event "$ev" "$1" job.spawned "2026-10-26T00:00:00Z" \
    "{\"owner_lane\":\"lane-a\",\"label\":\"lbl\",\"pane_id\":\"$3\"}"
}

hk_task() { # ID STATE
  HK_STATE="$HK_DB" "$HK" tasks add --id "$1" --title "task $1" \
    --lane fixture --state "$2" >/dev/null
}

write_policy() { cat >"$POLICY"; }

policy_min() { # rows JSON on stdin is embedded into a valid envelope
  python3 -c '
import json, sys
rows = json.load(sys.stdin)
doc = {"schema": "fleet.artifact-policy.v1",
       "roots": {"jobs": "herdr-inbox/jobs", "webqa": "webqa-runner/jobs"},
       "rows": rows}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(doc, handle, indent=1)
    handle.write("\n")
' "$POLICY"
}

mk_artifact() { # DIR — a directory with a payload file
  mkdir -p "$1"
  printf 'payload-%s\n' "$(basename "$1")" >"$1/payload.bin"
}

touch_mtime() { # PATH MOMENT — set mtime for ordering
  python3 - "$1" "$2" <<'PY'
import datetime, os, sys
stamp = datetime.datetime.fromisoformat(
    sys.argv[2].replace("Z", "+00:00")).timestamp()
os.utime(sys.argv[1], (stamp, stamp))
PY
}

LOCK_PID=""
hold_lock() { # LOCK_PATH READY_FILE — flock-hold LOCK_PATH until test end
  python3 - "$1" "$2" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write("held\n")
time.sleep(120)
PY
  LOCK_PID=$!
  own "$LOCK_PID"
}

lock_released() { # LOCK_PATH — the flock is free (same probe the pass uses)
  python3 - "$1" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

mk_lsof_stub() { # CONTROL_FILE — a stub lsof: rc 0 iff its last arg is listed
  local control="$1" ; : >"$control"
  LSOF_STUB="$TMP/lsof-stub-$CASE_SEQ"
  cat >"$LSOF_STUB" <<'EOF'
#!/bin/bash
last=""
for a in "$@"; do last="$a"; done
[[ -n "$last" ]] && grep -Fxq -- "$last" "$LSOF_STUB_OPEN" 2>/dev/null
EOF
  chmod +x "$LSOF_STUB"
  LSOF_OPEN="$control"
}

# start_sentinel JOB PANE [SENT_INBOX] — a live test-owned sentinel for JOB
# (pidfile under INBOX, argv-verified, mid-sleep so it stays for the whole
# case). SENT_INBOX defaults to INBOX; a DIFFERENT inbox keeps the sentinel
# alive on an ended job — it only self-exits when its own view of the job
# has a terminal record.
start_sentinel() {
  local job="$1" pane="$2" sent_inbox="${3:-$INBOX}"
  tw_own_session env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" \
    ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$sent_inbox" \
    XDG_DATA_HOME="$XDG" \
    WRK_FIXTURE_SCENARIO=sentinel-working \
    WRK_COMPLETION_TIMEOUT_S=300 WRK_COMPLETION_INTERVAL_S=3600 \
    "$WRK" sentinel "$job" lane-a lbl "$pane" "$TMP/report-$job.md" \
    >/dev/null 2>&1 &
  SENTINEL_PID=$!
  own "$SENTINEL_PID"
  mkdir -p "$INBOX/$job"
  printf '%s\n' "$SENTINEL_PID" >"$INBOX/$job/completion-sentinel.pid"
}

stop_sentinel() {
  if [[ -n "${SENTINEL_PID:-}" ]] && kill -0 "$SENTINEL_PID" 2>/dev/null; then
    tw_kill_tree "$SENTINEL_PID" || true
  fi
  wait "${SENTINEL_PID:-0}" 2>/dev/null || true
  SENTINEL_PID=""
}

wait_until() {
  local limit="$1"; shift
  local deadline=$(( $(date +%s) + limit ))
  while (( $(date +%s) <= deadline )); do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  return 1
}

seq_gone() { # every herdr probe answers agent_not_found (pane gone)
  GET_SEQ="$TMP/gone-$CASE_SEQ.seq"; printf 'not-found\n' >"$GET_SEQ"
}

events_named() { find "$1" -name "*$2.json" 2>/dev/null | wc -l | tr -d ' '; }

# ════════════════════════════════════════════════════════════════════════
# AP1 — cache: ended job + merged task + past age + no sentinel + pane gone.
# Dry-run lists and deletes nothing; --apply deletes; records stay.
# ════════════════════════════════════════════════════════════════════════
echo "== AP1: cache row prunes a fully eligible ended job =="
reset_case ap1
hk_task 1 merged
mk_ended_job ap1 1 w:p9
mk_artifact "$INBOX/ap1/browser-cache"
printf 'report\n' >"$INBOX/ap1/report.md"
printf 'brief\n' >"$INBOX/ap1/brief.md"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
seq_gone
OUT="$(prune_run)"
grep -q "ap1.*class=cache.*action=would-remove" <<<"$OUT" ||
  fail "AP1: dry-run must list the cache match: $OUT"
[[ -d "$INBOX/ap1/browser-cache" ]] || fail "AP1: dry-run must not delete"
OUT="$(prune_run --apply)"
grep -q "ap1.*class=cache.*action=removed" <<<"$OUT" ||
  fail "AP1: --apply must print the removal line: $OUT"
[[ ! -e "$INBOX/ap1/browser-cache" ]] ||
  fail "AP1: --apply must delete the cache dir"
[[ -f "$INBOX/ap1/report.md" && -f "$INBOX/ap1/brief.md" ]] ||
  fail "AP1: reports and briefs must stay"
[[ -d "$INBOX/ap1/events" ]] || fail "AP1: the events dir must stay"
[[ "$(events_named "$INBOX/ap1/events" job.artifacts_pruned)" == 1 ]] ||
  fail "AP1: exactly one job.artifacts_pruned event must be appended"
python3 - "$INBOX/ap1/events" <<'PY' || fail "AP1: artifacts_pruned payload must carry class/path/bytes"
import glob, json, sys
rows = [json.load(open(p)) for p in glob.glob(sys.argv[1] + "/*job.artifacts_pruned.json")]
assert len(rows) == 1
r = rows[0]
assert r.get("kind") == "job.artifacts_pruned" and r.get("job_id") == "ap1", r
assert r.get("class") == "cache" and isinstance(r.get("bytes"), int), r
assert "browser-cache" in (r.get("path") or ""), r
PY
echo "PASS ap1 cache-prune-eligible-job"

# ════════════════════════════════════════════════════════════════════════
# AP2 — cache is never removed for a job that fails one eligibility rule.
# ════════════════════════════════════════════════════════════════════════
echo "== AP2: cache stays when any eligibility rule fails =="

# AP2a — job not ended.
reset_case ap2a
hk_task 1 merged
mk_live_job ap2a 1 w:p9
mk_artifact "$INBOX/ap2a/browser-cache"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap2a/browser-cache" ]] ||
  fail "AP2a: a live job's cache must stay"
grep -q "ap2a.*class=cache.*skip=yes" <<<"$OUT" ||
  fail "AP2a: the skip must be reported: $OUT"
echo "PASS ap2a not-ended"

# AP2b — a claim after the terminal record revives the job.
reset_case ap2b
hk_task 1 merged
mk_ended_job ap2b 1 w:p9
write_event "$INBOX/ap2b/events" ap2b job.reclaim "2026-10-26T00:00:00Z" \
  '{"owner_lane":"lane-a","label":"lbl","task_id":1}'
mk_artifact "$INBOX/ap2b/browser-cache"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap2b/browser-cache" ]] ||
  fail "AP2b: a revived job's cache must stay"
echo "PASS ap2b revived"

# AP2c — task still open (claimed, not merged/dropped).
reset_case ap2c
hk_task 1 claimed
mk_ended_job ap2c 1 w:p9
mk_artifact "$INBOX/ap2c/browser-cache"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap2c/browser-cache" ]] ||
  fail "AP2c: an open task's cache must stay"
grep -q "ap2c.*class=cache.*reason=task" <<<"$OUT" ||
  fail "AP2c: the task reason must be reported: $OUT"
echo "PASS ap2c task-open"

# AP2d — a live completion sentinel owns the job. The sentinel watches a
# foreign inbox where ap2d never ends, so it stays mid-sleep (a same-inbox
# sentinel would self-exit on the terminal record, and --apply's pass 2
# would stop it as an orphan first). Dry-run leaves it live through the
# artifact pass, which must then refuse the cache.
reset_case ap2d
hk_task 1 merged
mk_ended_job ap2d 1 w:p9
mk_artifact "$INBOX/ap2d/browser-cache"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
mkdir -p "$TMP/other-inbox-$CASE_SEQ"
start_sentinel ap2d w:p9 "$TMP/other-inbox-$CASE_SEQ"
wait_until 10 pgrep -P "$SENTINEL_PID" >/dev/null 2>&1 ||
  fail "AP2d: the sentinel must reach its interval sleep"
seq_gone
OUT="$(prune_run)"
[[ -d "$INBOX/ap2d/browser-cache" ]] ||
  fail "AP2d: a job with a live sentinel must keep its cache"
grep -q "ap2d.*class=cache.*reason=live-sentinel" <<<"$OUT" ||
  fail "AP2d: the sentinel reason must be reported: $OUT"
grep -q "ap2d.*action=would-remove" <<<"$OUT" &&
  fail "AP2d: no removal may be listed while the sentinel lives"
stop_sentinel
echo "PASS ap2d live-sentinel"

# AP2e — the recorded pane is still alive.
reset_case ap2e
hk_task 1 merged
mk_ended_job ap2e 1 w:p9
mk_artifact "$INBOX/ap2e/browser-cache"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
GET_SEQ="$TMP/alive-$CASE_SEQ.seq"; printf 'working\n' >"$GET_SEQ"
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap2e/browser-cache" ]] ||
  fail "AP2e: a job with a live pane must keep its cache"
grep -q "ap2e.*class=cache.*reason=pane" <<<"$OUT" ||
  fail "AP2e: the pane reason must be reported: $OUT"
echo "PASS ap2e pane-alive"

# AP2f — inside --heavy-age: terminal record only moments old.
reset_case ap2f
hk_task 1 merged
mk_ended_job ap2f 1 w:p9 "2026-10-26T10:00:00Z"
mk_artifact "$INBOX/ap2f/browser-cache"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"   # default --heavy-age is 3d
[[ -d "$INBOX/ap2f/browser-cache" ]] ||
  fail "AP2f: a fresh-ended job must keep its cache"
grep -q "ap2f.*class=cache.*reason=.*age" <<<"$OUT" ||
  fail "AP2f: the age reason must be reported: $OUT"
OUT="$(prune_run --apply --heavy-age 1s)"
[[ ! -e "$INBOX/ap2f/browser-cache" ]] ||
  fail "AP2f: --heavy-age 1s must let the same job prune: $OUT"
echo "PASS ap2f inside-heavy-age"

# AP2g — the hk task lookup itself fails (read-only; skip on failure).
reset_case ap2g
hk_task 1 merged
mk_ended_job ap2g 1 w:p9
mk_artifact "$INBOX/ap2g/browser-cache"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
seq_gone
HK_MODE_VAR=down
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap2g/browser-cache" ]] ||
  fail "AP2g: a failed task lookup must keep the cache"
echo "PASS ap2g task-lookup-failed"

# ════════════════════════════════════════════════════════════════════════
# AP3 — intermediate-build: keep_newest in any job state.
# ════════════════════════════════════════════════════════════════════════
echo "== AP3: intermediate-build keeps the newest N even on a live job =="
reset_case ap3
hk_task 1 claimed
mk_live_job ap3 1 w:p9
for b in 1 2 3 4; do
  mk_artifact "$INBOX/ap3/build-$b"
  touch_mtime "$INBOX/ap3/build-$b" "2026-10-2${b}T00:00:00Z"
done
policy_min <<'JSON'
[{"class": "intermediate-build", "root": "jobs", "glob": "build-*",
  "keep_newest": 2}]
JSON
OUT="$(prune_run)"
grep -c "action=would-remove" <<<"$OUT" | grep -q '^2$' ||
  fail "AP3: dry-run must list exactly the 2 oldest: $OUT"
for b in 1 2 3 4; do [[ -d "$INBOX/ap3/build-$b" ]] ||
  fail "AP3: dry-run must not delete"; done
OUT="$(prune_run --apply)"
[[ ! -e "$INBOX/ap3/build-1" && ! -e "$INBOX/ap3/build-2" ]] ||
  fail "AP3: the 2 oldest builds must be deleted on a live job"
[[ -d "$INBOX/ap3/build-3" && -d "$INBOX/ap3/build-4" ]] ||
  fail "AP3: the 2 newest builds must be kept"
grep -q "build-1.*action=removed" <<<"$OUT" ||
  fail "AP3: each removal prints its line: $OUT"
[[ "$(events_named "$INBOX/ap3/events" job.artifacts_pruned)" == 2 ]] ||
  fail "AP3: one artifacts_pruned event per removal"

# At-or-below keep_newest deletes nothing.
reset_case ap3b
mk_live_job ap3b 1 w:p9
for b in 1 2; do
  mk_artifact "$INBOX/ap3b/build-$b"
  touch_mtime "$INBOX/ap3b/build-$b" "2026-10-2${b}T00:00:00Z"
done
policy_min <<'JSON'
[{"class": "intermediate-build", "root": "jobs", "glob": "build-*",
  "keep_newest": 2}]
JSON
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap3b/build-1" && -d "$INBOX/ap3b/build-2" ]] ||
  fail "AP3b: at keep_newest nothing is deleted"
! grep -q "action=removed" <<<"$OUT" ||
  fail "AP3b: no removal line may be printed: $OUT"
echo "PASS ap3 keep-newest and at-limit"

# ════════════════════════════════════════════════════════════════════════
# AP4 — policy validation refuses the whole pass.
# ════════════════════════════════════════════════════════════════════════
echo "== AP4: invalid policy refuses the artifact pass =="

assert_policy_refused() { # NAME POLICY_JSON — the pass refuses, nothing moves
  reset_case "$1"
  hk_task 1 merged
  mk_ended_job "$1" 1 w:p9
  mk_artifact "$INBOX/$1/browser-cache"
  mk_artifact "$INBOX/$1/build-1"
  printf '%s\n' "$2" >"$POLICY"
  seq_gone
  local rc=0 out=""
  out="$(prune_run --apply)" || rc=$?
  [[ "$rc" -ne 0 ]] ||
    fail "AP4 $1: an invalid policy must fail the run (rc=0)"
  grep -qi "artifact.*refus" <<<"$out" ||
    fail "AP4 $1: the refusal must be reported: $out"
  [[ -d "$INBOX/$1/browser-cache" && -d "$INBOX/$1/build-1" ]] ||
    fail "AP4 $1: a refused pass must delete nothing"
}

base_envelope() { # ROWS_JSON — full policy text on stdout
  python3 -c '
import json, sys
print(json.dumps({"schema": "fleet.artifact-policy.v1",
                  "roots": {"jobs": "herdr-inbox/jobs",
                            "webqa": "webqa-runner/jobs"},
                  "rows": json.loads(sys.argv[1])}, indent=1))
' "$1"
}

assert_policy_refused ap4-class-ev \
  "$(base_envelope '[{"class":"evidence","root":"jobs","glob":"e-*"}]')"
assert_policy_refused ap4-class-final \
  "$(base_envelope '[{"class":"final-build","root":"jobs","glob":"b-*"}]')"
assert_policy_refused ap4-unknown-key \
  '{"schema":"fleet.artifact-policy.v1","roots":{"jobs":"herdr-inbox/jobs"},"rows":[],"extra":1}'
assert_policy_refused ap4-row-key \
  "$(base_envelope '[{"class":"cache","root":"jobs","glob":"c-*","nope":1}]')"
assert_policy_refused ap4-abs-glob \
  "$(base_envelope '[{"class":"cache","root":"jobs","glob":"/tmp/x"}]')"
assert_policy_refused ap4-dotdot-glob \
  "$(base_envelope '[{"class":"cache","root":"jobs","glob":"../x"}]')"
assert_policy_refused ap4-dotdot-mid \
  "$(base_envelope '[{"class":"cache","root":"jobs","glob":"a/../x"}]')"
assert_policy_refused ap4-schema \
  '{"schema":"fleet.artifact-policy.v0","roots":{"jobs":"herdr-inbox/jobs"},"rows":[]}'
assert_policy_refused ap4-keep-range \
  "$(base_envelope '[{"class":"intermediate-build","root":"jobs","glob":"b-*","keep_newest":3}]')"
assert_policy_refused ap4-bad-root \
  "$(base_envelope '[{"class":"cache","root":"nosuch","glob":"c-*"}]')"
assert_policy_refused ap4-abs-root \
  '{"schema":"fleet.artifact-policy.v1","roots":{"jobs":"/abs/path"},"rows":[]}'
echo "PASS ap4 policy-refusal"

# ════════════════════════════════════════════════════════════════════════
# AP5 — symlinks: a symlinked match is unlinked, never traversed; a match
# reached through a symlinked ancestor resolves outside and is refused.
# ════════════════════════════════════════════════════════════════════════
echo "== AP5: symlinks are never followed =="
reset_case ap5
hk_task 1 merged
mk_ended_job ap5 1 w:p9
OUTSIDE="$TMP/ap5-outside"; mkdir -p "$OUTSIDE/target"
printf 'keepme\n' >"$OUTSIDE/target/real.bin"
ln -s "$OUTSIDE/target" "$INBOX/ap5/cache-link"
mk_artifact "$INBOX/ap5/cache-real"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "cache-*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ ! -L "$INBOX/ap5/cache-link" && ! -e "$INBOX/ap5/cache-link" ]] ||
  fail "AP5: the symlink match itself must be unlinked"
[[ -f "$OUTSIDE/target/real.bin" ]] ||
  fail "AP5: the outside target must be untouched"
[[ ! -e "$INBOX/ap5/cache-real" ]] ||
  fail "AP5: the real cache dir must be removed"
grep -q "cache-link.*action=removed" <<<"$OUT" ||
  fail "AP5: unlinking the link prints its removal line: $OUT"

# Match reached THROUGH a symlinked ancestor: the match is a real dir whose
# realpath escapes the job dir — refused, target intact, link stays.
reset_case ap5b
hk_task 1 merged
mk_ended_job ap5b 1 w:p9
OUTSIDE="$TMP/ap5b-outside"; mkdir -p "$OUTSIDE/work/build-x"
printf 'keepme\n' >"$OUTSIDE/work/build-x/real.bin"
ln -s "$OUTSIDE/work" "$INBOX/ap5b/escape"
policy_min <<'JSON'
[{"class": "intermediate-build", "root": "jobs", "glob": "escape/build-*",
  "keep_newest": 1}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ -f "$OUTSIDE/work/build-x/real.bin" ]] ||
  fail "AP5b: an outside-resolving match must never be deleted"
[[ -L "$INBOX/ap5b/escape" ]] ||
  fail "AP5b: the ancestor link is not a match — it stays"
grep -q "ap5b.*\(refus\|outside\)" <<<"$OUT" ||
  fail "AP5b: the outside match must be reported refused: $OUT"
echo "PASS ap5 symlink-safety"

# ════════════════════════════════════════════════════════════════════════
# AP6 — webqa root: no events dir there, so removals log to prune.log and
# the same-named job in the jobs root carries the state evidence.
# ════════════════════════════════════════════════════════════════════════
echo "== AP6: webqa root rows =="
reset_case ap6
hk_task 1 merged
mk_ended_job wq6 1 w:p9   # the webqa job's state lives in the jobs root
mk_artifact "$WEBQA/wq6/browser-profile"
policy_min <<'JSON'
[{"class": "cache", "root": "webqa", "glob": "browser-*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ ! -e "$WEBQA/wq6/browser-profile" ]] ||
  fail "AP6: the eligible webqa cache must be removed"
[[ "$(events_named "$INBOX/wq6/events" job.artifacts_pruned)" == 0 ]] ||
  fail "AP6: a webqa-root match writes no job event"
grep -q "wq6.*browser-profile" "$INBOX/prune.log" ||
  fail "AP6: a webqa-root removal must log to prune.log"

# A webqa-only job (no job record anywhere) cannot prove ended — cache stays.
reset_case ap6b
mkdir -p "$WEBQA/wq6b/browser-profile"
printf 'x\n' >"$WEBQA/wq6b/browser-profile/payload.bin"
policy_min <<'JSON'
[{"class": "cache", "root": "webqa", "glob": "browser-*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ -d "$WEBQA/wq6b/browser-profile" ]] ||
  fail "AP6b: without a job record the cache stays (fail closed)"
# But intermediate-build needs no job state at all.
mk_artifact "$WEBQA/wq6b/run-1"; mk_artifact "$WEBQA/wq6b/run-2"
touch_mtime "$WEBQA/wq6b/run-1" "2026-10-21T00:00:00Z"
touch_mtime "$WEBQA/wq6b/run-2" "2026-10-22T00:00:00Z"
policy_min <<'JSON'
[{"class": "intermediate-build", "root": "webqa", "glob": "run-*",
  "keep_newest": 1}]
JSON
OUT="$(prune_run --apply)"
[[ ! -e "$WEBQA/wq6b/run-1" && -d "$WEBQA/wq6b/run-2" ]] ||
  fail "AP6b: webqa builds prune to keep_newest with no job record"
grep -q "wq6b.*run-1" "$INBOX/prune.log" ||
  fail "AP6b: the webqa removal must log to prune.log"
echo "PASS ap6 webqa-roots"

# ════════════════════════════════════════════════════════════════════════
# AP7 — the shipped pa-integrator rows: intermediate-build and cache share
# the unity/*/out glob (a path may match one row of each class), the
# --heavy-age default is 3d, and the unity-lock / lsof / never-touch guards
# hold. Rows mirror director/artifact_policy.json.
# ════════════════════════════════════════════════════════════════════════
echo "== AP7: shipped unity rows, 3d age, lock and lsof guards =="

# (a)+(b) on a live job: the intermediate-build row keeps the newest 2 outs;
# the cache row reports its skip (job not ended). run.log/meta.txt/evidence
# sit outside the glob and stay.
reset_case ap7a
hk_task 1 claimed
mk_live_job ap7a 1 w:p9
for b in 1 2 3 4; do
  mk_artifact "$INBOX/ap7a/unity/Proj/out-$b"
  touch_mtime "$INBOX/ap7a/unity/Proj/out-$b" "2026-10-2${b}T00:00:00Z"
done
printf 'run\n' >"$INBOX/ap7a/unity/Proj/run.log"
printf 'meta\n' >"$INBOX/ap7a/unity/Proj/meta.txt"
mk_artifact "$INBOX/ap7a/evidence-pack"
policy_min <<'JSON'
[{"class": "intermediate-build", "root": "jobs", "glob": "unity/*/out-*",
  "keep_newest": 2},
 {"class": "cache", "root": "jobs", "glob": "unity/*/out-*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ ! -e "$INBOX/ap7a/unity/Proj/out-1" && ! -e "$INBOX/ap7a/unity/Proj/out-2" ]] ||
  fail "AP7a: the 2 oldest outs must go on a live job: $OUT"
[[ -d "$INBOX/ap7a/unity/Proj/out-3" && -d "$INBOX/ap7a/unity/Proj/out-4" ]] ||
  fail "AP7a: keep_newest 2 must keep the newest outs"
[[ -f "$INBOX/ap7a/unity/Proj/run.log" && -f "$INBOX/ap7a/unity/Proj/meta.txt" ]] ||
  fail "AP7a: run.log and meta.txt are outside the glob and stay"
[[ -d "$INBOX/ap7a/evidence-pack" ]] || fail "AP7a: evidence stays"
grep -q "ap7a.*class=cache.*skip=yes reason=not-ended" <<<"$OUT" ||
  fail "AP7a: the cache row must report its not-ended skip: $OUT"

# (b) same rows on an ended+merged job: every remaining out goes.
reset_case ap7b
hk_task 1 merged
mk_ended_job ap7b 1 w:p9
for b in 1 2 3; do
  mk_artifact "$INBOX/ap7b/unity/Proj/out-$b"
  touch_mtime "$INBOX/ap7b/unity/Proj/out-$b" "2026-10-1${b}T00:00:00Z"
done
policy_min <<'JSON'
[{"class": "intermediate-build", "root": "jobs", "glob": "unity/*/out-*",
  "keep_newest": 2},
 {"class": "cache", "root": "jobs", "glob": "unity/*/out-*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ ! -e "$INBOX/ap7b/unity/Proj/out-1" && ! -e "$INBOX/ap7b/unity/Proj/out-2" &&
   ! -e "$INBOX/ap7b/unity/Proj/out-3" ]] ||
  fail "AP7b: every out must go once the job is merged: $OUT"
grep -q "ap7b.*class=cache.*action=removed" <<<"$OUT" ||
  fail "AP7b: the cache row must remove what ib kept: $OUT"

# (c) --heavy-age default is 3d: a job ended ~2 days ago keeps its cache;
# --heavy-age 1d releases it.
reset_case ap7c
hk_task 1 merged
mk_ended_job ap7c 1 w:p9 "2026-10-24T12:00:00Z"
mk_artifact "$INBOX/ap7c/browser-cache"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap7c/browser-cache" ]] ||
  fail "AP7c: a 2-day-old end must stay inside the 3d default: $OUT"
grep -q "ap7c.*reason=inside-heavy-age" <<<"$OUT" ||
  fail "AP7c: the age reason must be reported: $OUT"
OUT="$(prune_run --apply --heavy-age 1d)"
[[ ! -e "$INBOX/ap7c/browser-cache" ]] ||
  fail "AP7c: --heavy-age 1d must release the same cache"

# (d1) the pa unity lock is held: every unity path is skipped, non-unity
# matches still prune; released, the same pass removes them. ap7d2 carries
# only the unity path — its own removal event never refreshes its age.
reset_case ap7d
hk_task 1 merged
mk_ended_job ap7d 1 w:p9
mk_artifact "$INBOX/ap7d/unity/Proj/out"
mk_artifact "$INBOX/ap7d/browser-cache"
mk_ended_job ap7d2 1 w:p9
mk_artifact "$INBOX/ap7d2/unity/Proj/out"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "unity/*/out"},
 {"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
ULOCK="$TMP/pa-unity-$CASE_SEQ.lock"
hold_lock "$ULOCK" "$TMP/pa-unity-$CASE_SEQ.ready"
wait_until 10 test -f "$TMP/pa-unity-$CASE_SEQ.ready" ||
  fail "AP7d: the lock holder must take the flock"
seq_gone
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap7d/unity/Proj/out" ]] ||
  fail "AP7d: a unity path is skipped while the lock is held"
[[ -d "$INBOX/ap7d2/unity/Proj/out" ]] ||
  fail "AP7d: the second unity path is also skipped"
[[ ! -e "$INBOX/ap7d/browser-cache" ]] ||
  fail "AP7d: a non-unity match still prunes under a held unity lock"
grep -q "ap7d.*unity-lock-held" <<<"$OUT" ||
  fail "AP7d: the lock skip must be reported: $OUT"
tw_kill_tree "$LOCK_PID" 2>/dev/null || true; wait "$LOCK_PID" 2>/dev/null || true
LOCK_PID=""
wait_until 10 lock_released "$ULOCK" ||
  fail "AP7d: the lock must be free once the holder is gone"
OUT="$(prune_run --apply)"
[[ ! -e "$INBOX/ap7d2/unity/Proj/out" ]] ||
  fail "AP7d: once released, the unity path prunes: $OUT"

# (d2) a live process has the match open (lsof says so): skipped; clean
# lsof frees it.
reset_case ap7e
hk_task 1 merged
mk_ended_job ap7e 1 w:p9
mk_artifact "$INBOX/ap7e/browser-cache"
mk_artifact "$INBOX/ap7e/other-cache"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "*-cache"}]
JSON
mk_lsof_stub "$TMP/lsof-open-$CASE_SEQ"
printf '%s\n' "$INBOX/ap7e/browser-cache" >"$LSOF_OPEN"
seq_gone
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap7e/browser-cache" ]] ||
  fail "AP7e: an in-use path must be skipped"
[[ ! -e "$INBOX/ap7e/other-cache" ]] ||
  fail "AP7e: a path with no open handle still prunes"
grep -q "ap7e.*browser-cache.*path-in-use" <<<"$OUT" ||
  fail "AP7e: the in-use skip must be reported: $OUT"

# (d3) the probe tool itself is gone: unprovable means in use, so the match
# is skipped rather than removed.
reset_case ap7g
hk_task 1 merged
mk_ended_job ap7g 1 w:p9
mk_artifact "$INBOX/ap7g/browser-cache"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "*-cache"}]
JSON
LSOF_STUB="$TMP/lsof-nonexistent-$CASE_SEQ"
seq_gone
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap7g/browser-cache" ]] ||
  fail "AP7g: with no probe the match must be skipped"
grep -q "ap7g.*browser-cache.*path-in-use" <<<"$OUT" ||
  fail "AP7g: the unprobeable skip must be reported: $OUT"

# Never-touch: refs dirs and an asset-store-packs root entry are refused
# even when a glob matches them; events are likewise guarded.
reset_case ap7f
hk_task 1 merged
mk_ended_job ap7f 1 w:p9
mk_artifact "$INBOX/ap7f/refs/cache-dir"
mk_artifact "$INBOX/ap7f/cache-real"
mkdir -p "$INBOX/asset-store-packs/pack-1"
printf 'pack\n' >"$INBOX/asset-store-packs/pack-1/payload.bin"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "refs/*"},
 {"class": "cache", "root": "jobs", "glob": "cache-*"},
 {"class": "intermediate-build", "root": "jobs", "glob": "pack-*",
  "keep_newest": 1}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap7f/refs/cache-dir" ]] ||
  fail "AP7f: a refs match is never removed: $OUT"
[[ -d "$INBOX/asset-store-packs/pack-1" ]] ||
  fail "AP7f: asset-store-packs is never touched: $OUT"
[[ ! -e "$INBOX/ap7f/cache-real" ]] ||
  fail "AP7f: a normal match still prunes"
grep -q "never-touch" <<<"$OUT" ||
  fail "AP7f: the never-touch refusal must be reported: $OUT"
[[ -d "$INBOX/ap7f/events" ]] || fail "AP7f: the events dir stays"
echo "PASS ap7 shipped-rows and guards"

# ════════════════════════════════════════════════════════════════════════
# MUT — assertion-RED mutants, each applied at its real call site.
# ════════════════════════════════════════════════════════════════════════
echo "== MUT: assertion-RED mutants per brief =="

mkmut() {
  local dir="$TMP/mut-$1"; shift
  mkdir -p "$dir"
  local args=() e
  for e in "$@"; do args+=(-e "$e"); done
  { sed "${args[@]}" "$WRK" >"$dir/wrk" && chmod +x "$dir/wrk"; } ||
    fail "mutant build failed: $*"
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
    fail "MUT $desc: setup failed inside the mutant case"
  fi
  if (( rc == 0 )); then
    fail "MUT $desc: mutant stayed GREEN — the assertion does not cover it"
  fi
  if [[ -n "$expected" ]] && ! grep -Fq -- "$expected" <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "MUT $desc: RED did not come from the pinned assertion"
  fi
  echo "PASS mut $desc is assertion-RED (rc=$rc)"
}

assertion_red() { printf 'ASSERT-RED: %s\n' "$1" >&2; return 1; }

# Mutant 1 — keep_newest ignored: the newest builds are deleted too.
case_mut_keep() {
  reset_case mutk || return 3
  mk_live_job mutk 1 w:p9 || return 3
  for b in 1 2 3 4; do
    mk_artifact "$INBOX/mutk/build-$b" || return 3
    touch_mtime "$INBOX/mutk/build-$b" "2026-10-2${b}T00:00:00Z" || return 3
  done
  policy_min <<'JSON' || return 3
[{"class": "intermediate-build", "root": "jobs", "glob": "build-*",
  "keep_newest": 2}]
JSON
  prune_run --apply >/dev/null 2>&1 || true
  [[ -d "$INBOX/mutk/build-3" && -d "$INBOX/mutk/build-4" ]] ||
    assertion_red "keep_newest 2 must keep the 2 newest builds"
}
# Mutant 2 — an unsupported class (evidence) is accepted.
case_mut_class() {
  reset_case mutev || return 3
  hk_task 1 merged || return 3
  mk_ended_job mutev 1 w:p9 || return 3
  mk_artifact "$INBOX/mutev/evidence-1" || return 3
  printf '%s\n' '{"schema":"fleet.artifact-policy.v1","roots":{"jobs":"herdr-inbox/jobs"},"rows":[{"class":"evidence","root":"jobs","glob":"evidence-*"}]}' >"$POLICY" || return 3
  seq_gone
  local rc=0
  prune_run --apply >/dev/null 2>&1 || rc=$?
  (( rc != 0 )) || assertion_red "an evidence row must refuse the pass"
  [[ -d "$INBOX/mutev/evidence-1" ]] ||
    assertion_red "an evidence row must never delete"
}
# Mutant 3 — symlinks followed: the outside target is deleted.
case_mut_symlink() {
  reset_case mutsl || return 3
  hk_task 1 merged || return 3
  mk_ended_job mutsl 1 w:p9 || return 3
  local outside="$TMP/mutsl-outside"
  mkdir -p "$outside/target" || return 3
  printf 'keepme\n' >"$outside/target/real.bin" || return 3
  ln -s "$outside/target" "$INBOX/mutsl/cache-link" || return 3
  policy_min <<'JSON' || return 3
[{"class": "cache", "root": "jobs", "glob": "cache-*"}]
JSON
  seq_gone
  prune_run --apply >/dev/null 2>&1 || true
  [[ -f "$outside/target/real.bin" ]] ||
    assertion_red "the outside symlink target must be untouched"
}
# Mutant 4 — the task-merged check dropped for cache.
case_mut_task() {
  reset_case muttk || return 3
  hk_task 1 claimed || return 3
  mk_ended_job muttk 1 w:p9 || return 3
  mk_artifact "$INBOX/muttk/browser-cache" || return 3
  policy_min <<'JSON' || return 3
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
  seq_gone
  prune_run --apply >/dev/null 2>&1 || true
  [[ -d "$INBOX/muttk/browser-cache" ]] ||
    assertion_red "an open task's cache must stay"
}

# M1 — keep_newest ignored: every sorted index is dropped, so the newest
# builds are deleted too. Call site: the drop-list builder.
mkmut keep 's/k > keep/k > 0/'
expect_mut_red "keep-newest-ignored" case_mut_keep "2 newest builds"

# M2 — an unsupported class is accepted: evidence joins the allow-list at
# the schema's own CLASSES table.
mkmut class 's/"intermediate-build")/"intermediate-build", "evidence")/'
expect_mut_red "evidence-class-accepted" case_mut_class "evidence row must"

# M3 — the removal helper follows the link: unlink becomes rmtree on the
# link's realpath, deleting the outside target.
mkmut symlink 's/os\.unlink(path)/shutil.rmtree(os.path.realpath(path))/'
expect_mut_red "symlinks-followed" case_mut_symlink "symlink target must be untouched"

# M4 — the merged-or-dropped task check is dropped: every task state is
# accepted at the case arm.
mkmut task 's/echo "task-.state"; return 1/return 0/'
expect_mut_red "task-check-dropped" case_mut_task "open task"

echo "ALL ARTIFACT-PRUNE CONTRACT TESTS PASSED"
