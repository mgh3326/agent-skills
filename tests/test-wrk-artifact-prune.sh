#!/usr/bin/env bash
# shellcheck disable=SC2016 # mutant specs and fixture JSON are literal text
# hk 2090 contract tests: the wrk prune artifact pass — cache and
# intermediate-build classes from director/artifact_policy.json
# (schema fleet.artifact-policy.v1). Evidence, final-build and record text
# are out of scope for this task and must never be touched.
# hk 2152 adds the scanner-side never-touch contract (AP8, AP10 help), the
# policy-refusal message (AP9) and the prune-record age rule (AP10); its
# moments are relative to now, never fixed dates.
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
  GET_SEQ="" HK_MODE_VAR="" LSOF_STUB="" LSOF_OPEN=""
  # Default unity lock: a path that never exists, so no case reads the host's
  # real /tmp/pa-m1-unity.lock (a held host lock would skip every unity path).
  # The lock case below replaces it with a held lock of its own.
  ULOCK="$TMP/no-unity-lock-$1-$CASE_SEQ"
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

# ago SECONDS — ISO-8601 UTC instant SECONDS before now. Ended-job fixtures
# are relative to the real clock so the age they test never drifts.
ago() {
  python3 -c '
import datetime, sys
moment = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(
    seconds=int(sys.argv[1]))
print(moment.strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$1"
}

# mk_ended_job JOB TASK_ID PANE [MOMENT] — claim(task_id) + spawned + completed,
# all at MOMENT (default five days ago: past the default --heavy-age 3d).
mk_ended_job() {
  local moment="${4:-$(ago 432000)}"
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

set_tree_mtime() { # DIR DAYS — DIR and everything inside it, DAYS days ago
  python3 - "$1" "$(ago $(( $2 * 86400 )))" <<'PY'
import datetime, os, sys
root, moment = sys.argv[1:3]
stamp = datetime.datetime.fromisoformat(
    moment.replace("Z", "+00:00")).timestamp()
for base, dirs, files in os.walk(root):
    for name in dirs + files:
        os.utime(os.path.join(base, name), (stamp, stamp), follow_symlinks=False)
os.utime(root, (stamp, stamp))
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
mk_ended_job ap2f 1 w:p9 "$(ago 86400)"
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
# AP5 — symlinks: a symlinked match whose target stays inside the job dir is
# unlinked, never traversed; a link pointing out of the job dir, and a match
# reached through a symlinked ancestor, resolve outside and are refused.
# ════════════════════════════════════════════════════════════════════════
echo "== AP5: symlinks are never followed =="
reset_case ap5
hk_task 1 merged
mk_ended_job ap5 1 w:p9
OUTSIDE="$TMP/ap5-outside"; mkdir -p "$OUTSIDE/target"
printf 'keepme\n' >"$OUTSIDE/target/real.bin"
ln -s "$OUTSIDE/target" "$INBOX/ap5/cache-link"
mkdir -p "$INBOX/ap5/inner"; printf 'inner\n' >"$INBOX/ap5/inner/keep.bin"
ln -s inner "$INBOX/ap5/cache-inlink"
mk_artifact "$INBOX/ap5/cache-real"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "cache-*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ -L "$INBOX/ap5/cache-link" ]] ||
  fail "AP5: a link whose target leaves the job dir must be refused, not unlinked"
grep -q "cache-link.*action=refused.*outside-job-dir" <<<"$OUT" ||
  fail "AP5: the outside-pointing link must be reported refused: $OUT"
[[ -f "$OUTSIDE/target/real.bin" ]] ||
  fail "AP5: the outside target must be untouched"
[[ ! -L "$INBOX/ap5/cache-inlink" && ! -e "$INBOX/ap5/cache-inlink" ]] ||
  fail "AP5: a link match pointing inside the job dir must be unlinked"
[[ -f "$INBOX/ap5/inner/keep.bin" ]] ||
  fail "AP5: the inside target must be untouched (the link is unlinked, not traversed)"
[[ ! -e "$INBOX/ap5/cache-real" ]] ||
  fail "AP5: the real cache dir must be removed"
grep -q "cache-inlink.*action=removed" <<<"$OUT" ||
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
mk_ended_job ap7c 1 w:p9 "$(ago 172800)"
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
# AP8 — hk 2152: the never-touch contract is the scanner's, not the policy's.
# The policy is runtime data (pa-integrator extends it), so a broad glob
# (*, **, unity/*/*) reaching report.md, brief.md, run.log, meta.txt, a
# pidfile, a nested refs dir or a link must not delete any of them, while a
# cache file next to them still goes.
# ════════════════════════════════════════════════════════════════════════
echo "== AP8: broad globs never reach the never-touch set =="

NEVER_SET='events refs asset-store-packs report*.md brief*.md spawn-brief* verdict*.md run.log meta.txt completion-sentinel.* *.pid state.md final-report*'
GUARD_OUT=""

# mk_guard_tree JOB — one name per never-touch pattern at the top level and
# nested under unity/Proj, a refs dir holding a link, a symlinked ancestor
# that resolves back into refs, one that leaves the job dir, and real cache
# payloads beside all of it.
mk_guard_tree() {
  local j="$INBOX/$1" f
  GUARD_OUT="$TMP/guard-outside-$1"
  for f in report.md report-2.md brief.md brief-2.md spawn-brief-1.txt \
           verdict-1.md run.log meta.txt worker.pid state.md final-report.md \
           final-report-2.txt; do
    printf 'keep-%s\n' "$f" >"$j/$f"
  done
  mkdir -p "$j/unity/Proj/refs/deep" "$j/unity/asset-store-packs/p1" "$j/refs"
  printf 'x\n' >"$j/unity/Proj/refs/x"
  printf 'y\n' >"$j/unity/Proj/refs/deep/y"
  printf 'pack\n' >"$j/unity/asset-store-packs/p1/payload.bin"
  for f in run.log meta.txt completion-sentinel.pid; do
    printf 'keep-%s\n' "$f" >"$j/unity/Proj/$f"
  done
  printf 'cache\n' >"$j/unity/Proj/cache.bin"
  printf 'ref\n' >"$j/refs/real"
  ln -s ../report.md "$j/refs/x"        # a link AT a refs path
  ln -s refs "$j/linkdir"               # linkdir/x IS refs/x, through an ancestor link
  mkdir -p "$GUARD_OUT"
  printf 'outside\n' >"$GUARD_OUT/real.bin"
  ln -s real.bin "$GUARD_OUT/y"
  ln -s "$GUARD_OUT" "$j/outlinkdir"    # an ancestor link leaving the job dir
  printf 'cache\n' >"$j/cache.bin"
  mk_artifact "$j/cachedir"
}

assert_guard_intact() { # JOB TAG — everything never-touch is still there
  local j="$INBOX/$1" t="$2" f
  for f in report.md report-2.md brief.md brief-2.md spawn-brief-1.txt \
           verdict-1.md run.log meta.txt worker.pid state.md final-report.md \
           final-report-2.txt refs/real unity/Proj/run.log unity/Proj/meta.txt \
           unity/Proj/completion-sentinel.pid unity/Proj/refs/x \
           unity/Proj/refs/deep/y unity/asset-store-packs/p1/payload.bin; do
    [[ -f "$j/$f" ]] || fail "$t: $f is never-touch and must survive"
  done
  [[ -L "$j/refs/x" ]] || fail "$t: the symlink at refs/x must survive"
  [[ -L "$j/linkdir" && -L "$j/outlinkdir" ]] ||
    fail "$t: links to refs and out of the job dir must survive"
  [[ -d "$j/events" ]] || fail "$t: the events dir must survive"
  [[ -f "$GUARD_OUT/real.bin" && -L "$GUARD_OUT/y" ]] ||
    fail "$t: the tree behind a symlinked ancestor must be untouched"
}

# AP8a — glob *: top-level matches only.
reset_case ap8a
hk_task 1 merged
mk_ended_job ap8a 1 w:p9
mk_guard_tree ap8a
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
assert_guard_intact ap8a AP8a
[[ ! -e "$INBOX/ap8a/cache.bin" && ! -e "$INBOX/ap8a/cachedir" ]] ||
  fail "AP8a: the cache file and dir beside the never-touch set must go: $OUT"
grep -q "ap8a/cache.bin.*action=removed" <<<"$OUT" ||
  fail "AP8a: the cache removal must print its line: $OUT"
[[ -f "$INBOX/ap8a/unity/Proj/cache.bin" ]] ||
  fail "AP8a: unity holds never-touch names, so a * match on it is refused whole"
grep -q "ap8a/unity .*action=refused reason=holds-never-touch" <<<"$OUT" ||
  fail "AP8a: the holding directory must be reported refused: $OUT"
grep -q "ap8a/report.md.*action=refused reason=never-touch" <<<"$OUT" ||
  fail "AP8a: the never-touch refusal must be reported: $OUT"
grep -q "ap8a/outlinkdir.*action=refused reason=outside-job-dir" <<<"$OUT" ||
  fail "AP8a: the escaping link must be reported refused: $OUT"
! grep -q "action=failed" <<<"$OUT" || fail "AP8a: no removal may fail: $OUT"

# AP8b — glob **: every depth, links under symlinked ancestors included.
reset_case ap8b
hk_task 1 merged
mk_ended_job ap8b 1 w:p9
mk_guard_tree ap8b
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "**"},
 {"class": "cache", "root": "jobs", "glob": "linkdir/*"},
 {"class": "cache", "root": "jobs", "glob": "outlinkdir/*"},
 {"class": "cache", "root": "jobs", "glob": "refs/*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
assert_guard_intact ap8b AP8b
[[ ! -e "$INBOX/ap8b/cache.bin" && ! -e "$INBOX/ap8b/cachedir" &&
   ! -e "$INBOX/ap8b/unity/Proj/cache.bin" ]] ||
  fail "AP8b: every cache file beside the never-touch set must go: $OUT"
grep -q "ap8b/unity/Proj/cache.bin.*action=removed" <<<"$OUT" ||
  fail "AP8b: the nested cache file must print its removal: $OUT"
grep -q "ap8b/linkdir/x action=refused reason=never-touch" <<<"$OUT" ||
  fail "AP8b: a link under an ancestor link into refs must be refused: $OUT"
grep -q "ap8b/outlinkdir/y action=refused reason=outside-job-dir" <<<"$OUT" ||
  fail "AP8b: a link under an ancestor link out of the job dir must be refused: $OUT"
grep -q "ap8b/refs/x action=refused reason=never-touch" <<<"$OUT" ||
  fail "AP8b: a link at refs/x must be refused: $OUT"
! grep -q "action=failed" <<<"$OUT" ||
  fail "AP8b: a match inside an already-removed dir must be skipped, not fail: $OUT"

# AP8c — intermediate-build unity/*/*: refused matches take no keep slot, so
# a newest run.log cannot push the newest real build out of the keep window.
# Three real builds whose recency disagrees with both creation order and
# lexical order: out-b is the newest, out-c was created next, out-a sorts
# first; every payload carries an explicit mtime.
reset_case ap8c
hk_task 1 claimed
mk_live_job ap8c 1 w:p9
mk_guard_tree ap8c
for b in b c a; do mk_artifact "$INBOX/ap8c/unity/Proj/out-$b"; done
set_tree_mtime "$INBOX/ap8c/unity/Proj/out-b" 2
set_tree_mtime "$INBOX/ap8c/unity/Proj/out-c" 5
set_tree_mtime "$INBOX/ap8c/unity/Proj/out-a" 9
touch_mtime "$INBOX/ap8c/unity/Proj/run.log" "$(ago 86400)"
touch_mtime "$INBOX/ap8c/unity/Proj/meta.txt" "$(ago 86400)"
rm -f "$INBOX/ap8c/unity/Proj/cache.bin"
policy_min <<'JSON'
[{"class": "intermediate-build", "root": "jobs", "glob": "unity/*/*",
  "keep_newest": 1}]
JSON
OUT="$(prune_run --apply)"
assert_guard_intact ap8c AP8c
[[ -d "$INBOX/ap8c/unity/Proj/out-b" ]] ||
  fail "AP8c: the newest real build must keep the keep_newest slot: $OUT"
[[ ! -e "$INBOX/ap8c/unity/Proj/out-a" && ! -e "$INBOX/ap8c/unity/Proj/out-c" ]] ||
  fail "AP8c: the older real builds must go: $OUT"

# AP8d — the help text names the exact set.
reset_case ap8d
FLAT="$(prune_run --help | tr '\n' ' ' | tr -s ' ')"
grep -qF -- "$NEVER_SET" <<<"$FLAT" ||
  fail "AP8d: wrk prune --help must print the exact never-touch set: $NEVER_SET"
echo "PASS ap8 never-touch-scanner"

# ════════════════════════════════════════════════════════════════════════
# AP9 — hk 2152: a policy with a valid row and then an invalid one refuses the
# pass (rc 2) and the message is exactly the reason: the loader prints rows
# only after every row passed, so no earlier row leaks into the message.
# ════════════════════════════════════════════════════════════════════════
echo "== AP9: a refusal after a valid row prints only the reason =="
reset_case ap9
hk_task 1 merged
mk_ended_job ap9 1 w:p9
mk_artifact "$INBOX/ap9/browser-cache"
base_envelope '[{"class":"cache","root":"jobs","glob":"browser-*"},{"class":"evidence","root":"jobs","glob":"e-*"}]' >"$POLICY"
seq_gone
rc=0; OUT="$(prune_run --apply)" || rc=$?
[[ "$rc" == 2 ]] || fail "AP9: a refused policy must exit 2 (rc=$rc): $OUT"
MSG="$(grep '^artifact-prune refused' <<<"$OUT")"
[[ "$MSG" == "artifact-prune refused: $POLICY — row 1 class 'evidence' is not yet supported" ]] ||
  fail "AP9: the message must be exactly the reason, got: $MSG"
! grep -q "^cache"$'\t' <<<"$OUT" ||
  fail "AP9: no earlier row text may reach the output: $OUT"
[[ -d "$INBOX/ap9/browser-cache" ]] || fail "AP9: a refused pass deletes nothing"
echo "PASS ap9 refusal-message"

# ════════════════════════════════════════════════════════════════════════
# AP10 — hk 2152: job.artifacts_pruned is housekeeping, not job activity. An
# intermediate-build prune on an ended job appends one per removal; they must
# not restart the job's --heavy-age clock, so its cache row still goes at the
# original age on the next pass.
# ════════════════════════════════════════════════════════════════════════
echo "== AP10: a prune record does not move the job's age =="
reset_case ap10
hk_task 1 merged
mk_ended_job ap10 1 w:p9
# build-b is the newest, build-c was created next, build-a sorts first.
for b in b c a; do mk_artifact "$INBOX/ap10/build-$b"; done
set_tree_mtime "$INBOX/ap10/build-b" 1
set_tree_mtime "$INBOX/ap10/build-c" 5
set_tree_mtime "$INBOX/ap10/build-a" 9
mk_artifact "$INBOX/ap10/browser-cache"
policy_min <<'JSON'
[{"class": "intermediate-build", "root": "jobs", "glob": "build-*",
  "keep_newest": 1}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ ! -e "$INBOX/ap10/build-a" && ! -e "$INBOX/ap10/build-c" && -d "$INBOX/ap10/build-b" ]] ||
  fail "AP10: the intermediate-build pass must prune to the newest: $OUT"
[[ "$(events_named "$INBOX/ap10/events" job.artifacts_pruned)" == 2 ]] ||
  fail "AP10: each removal must append a job.artifacts_pruned event"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
OUT="$(prune_run --apply)"   # default --heavy-age 3d; the job ended 5d ago
[[ ! -e "$INBOX/ap10/browser-cache" ]] ||
  fail "AP10: the prune record must not restart the heavy-age clock: $OUT"
echo "PASS ap10 prune-record-not-activity"

# ════════════════════════════════════════════════════════════════════════
# AP11 — hk 2152 round 1 B1: the scan record must not be forgeable from a
# file name. A cache file named "spill<LF>real<TAB>report.md" used to print a
# second record whose path was the relative report.md; with the job dir as the
# working directory the pass removed it. A name with a control character is
# now refused (unsafe-path), and the pass re-validates every record.
# ════════════════════════════════════════════════════════════════════════
echo "== AP11: a file name cannot forge a scan record =="
reset_case ap11
hk_task 1 merged
mk_ended_job ap11 1 w:p9
printf 'must survive\n' >"$INBOX/ap11/report.md"
printf 'cache\n' >"$INBOX/ap11/"$'spill\nreal\treport.md'
printf 'cache\n' >"$INBOX/ap11/cache.bin"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "*"}]
JSON
seq_gone
OUT="$(cd "$INBOX/ap11" && prune_run --apply)"
[[ -f "$INBOX/ap11/report.md" ]] ||
  fail "AP11: a file name must not forge a record that deletes report.md: $OUT"
[[ -e "$INBOX/ap11/"$'spill\nreal\treport.md' ]] ||
  fail "AP11: the unsafe name is refused, not removed"
grep -q 'spill.nreal.treport.md action=refused reason=unsafe-path' <<<"$OUT" ||
  fail "AP11: the unsafe name must be reported refused (escaped): $OUT"
[[ ! -e "$INBOX/ap11/cache.bin" ]] ||
  fail "AP11: an ordinary cache file beside it still goes: $OUT"
! grep -q "reason=malformed-record" <<<"$OUT" ||
  fail "AP11: the scanner itself must not emit a malformed record: $OUT"
echo "PASS ap11 record-not-forgeable"

# ════════════════════════════════════════════════════════════════════════
# AP12 — hk 2152 round 1 B2: under a recursive glob the matches nest. A
# dropped directory must not take a kept match with it, and a dropped match
# must not sit inside a kept one.
# ════════════════════════════════════════════════════════════════════════
echo "== AP12: a dropped match never takes a kept match with it =="

# AP12a — keep_newest 1 over a sole build and its payload (equal mtimes).
reset_case ap12a
hk_task 1 claimed
mk_live_job ap12a 1 w:p9
mk_artifact "$INBOX/ap12a/build-A"
set_tree_mtime "$INBOX/ap12a/build-A" 10
policy_min <<'JSON'
[{"class": "intermediate-build", "root": "jobs", "glob": "**",
  "keep_newest": 1}]
JSON
OUT="$(prune_run --apply)"
[[ -f "$INBOX/ap12a/build-A/payload.bin" && -d "$INBOX/ap12a/build-A" ]] ||
  fail "AP12a: the kept payload and the last build must survive: $OUT"
grep -q "build-A.*action=skipped reason=nested-with-kept-match" <<<"$OUT" ||
  fail "AP12a: the held directory must be reported: $OUT"

# AP12b — two builds, keep 2: the older build and its payload go, the newer
# build comes through intact. build-b-new is the newest, created first.
reset_case ap12b
hk_task 1 claimed
mk_live_job ap12b 1 w:p9
mk_artifact "$INBOX/ap12b/build-b-new"
mk_artifact "$INBOX/ap12b/build-a-old"
set_tree_mtime "$INBOX/ap12b/build-b-new" 1
set_tree_mtime "$INBOX/ap12b/build-a-old" 10
policy_min <<'JSON'
[{"class": "intermediate-build", "root": "jobs", "glob": "**",
  "keep_newest": 2}]
JSON
OUT="$(prune_run --apply)"
[[ -f "$INBOX/ap12b/build-b-new/payload.bin" ]] ||
  fail "AP12b: the newer build must come through intact: $OUT"
[[ ! -e "$INBOX/ap12b/build-a-old" ]] ||
  fail "AP12b: the older build must go: $OUT"

# AP12c — a build with an older file inside it: whichever of the build and its
# newest file takes the keep slot, the kept build stays whole.
reset_case ap12c
hk_task 1 claimed
mk_live_job ap12c 1 w:p9
mk_artifact "$INBOX/ap12c/build-A"
printf 'old\n' >"$INBOX/ap12c/build-A/old.bin"
set_tree_mtime "$INBOX/ap12c/build-A" 1
touch_mtime "$INBOX/ap12c/build-A/old.bin" "$(ago 864000)"
policy_min <<'JSON'
[{"class": "intermediate-build", "root": "jobs", "glob": "**",
  "keep_newest": 1}]
JSON
OUT="$(prune_run --apply)"
[[ -d "$INBOX/ap12c/build-A" && -f "$INBOX/ap12c/build-A/payload.bin" ]] ||
  fail "AP12c: the kept build and its newest payload must survive: $OUT"
echo "PASS ap12 nested-matches-keep"

# ════════════════════════════════════════════════════════════════════════
# AP13 — hk 2152 round 1 B2: a cache directory that contains a refused match
# is held with it. AP13a: a link out of the job dir inside a cache dir (the
# link is a refused match under **); AP13b: a link to report.md inside a cache
# dir under * (the walk resolves links and the target hits the set).
# ════════════════════════════════════════════════════════════════════════
echo "== AP13: a cache dir holding a refused match stays whole =="
reset_case ap13a
hk_task 1 merged
mk_ended_job ap13a 1 w:p9
printf 'report\n' >"$INBOX/ap13a/report.md"
OUTSIDE13="$TMP/ap13a-outside"; mkdir -p "$OUTSIDE13"; printf 'out\n' >"$OUTSIDE13/real.bin"
mkdir -p "$INBOX/ap13a/cache-folder"
printf 'data\n' >"$INBOX/ap13a/cache-folder/data.bin"
ln -s "$OUTSIDE13" "$INBOX/ap13a/cache-folder/out-link"
mkdir -p "$INBOX/ap13a/cache-folder2"
ln -s ../report.md "$INBOX/ap13a/cache-folder2/safe-link"
printf 'plain\n' >"$INBOX/ap13a/plain.bin"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "**"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ -L "$INBOX/ap13a/cache-folder/out-link" && -d "$INBOX/ap13a/cache-folder" ]] ||
  fail "AP13a: a cache dir holding a refused link match must not be removed: $OUT"
[[ -L "$INBOX/ap13a/cache-folder2/safe-link" && -f "$INBOX/ap13a/report.md" ]] ||
  fail "AP13a: a guarded link match must survive its parent dir: $OUT"
[[ -f "$OUTSIDE13/real.bin" ]] || fail "AP13a: the outside tree must be untouched"
[[ ! -e "$INBOX/ap13a/plain.bin" ]] ||
  fail "AP13a: an ordinary cache file still goes: $OUT"
grep -q "cache-folder .*action=refused reason=holds-never-touch" <<<"$OUT" ||
  fail "AP13a: the held directory must be reported: $OUT"

reset_case ap13b
hk_task 1 merged
mk_ended_job ap13b 1 w:p9
printf 'report\n' >"$INBOX/ap13b/report.md"
mkdir -p "$INBOX/ap13b/cache-folder"
ln -s ../report.md "$INBOX/ap13b/cache-folder/safe-link"
printf 'plain\n' >"$INBOX/ap13b/plain.bin"
policy_min <<'JSON'
[{"class": "cache", "root": "jobs", "glob": "*"}]
JSON
seq_gone
OUT="$(prune_run --apply)"
[[ -L "$INBOX/ap13b/cache-folder/safe-link" && -f "$INBOX/ap13b/report.md" ]] ||
  fail "AP13b: a dir holding a link to a never-touch file must stay whole: $OUT"
grep -q "cache-folder .*action=refused reason=holds-never-touch" <<<"$OUT" ||
  fail "AP13b: the held directory must be reported: $OUT"
[[ ! -e "$INBOX/ap13b/plain.bin" ]] ||
  fail "AP13b: an ordinary cache file still goes: $OUT"
echo "PASS ap13 refused-descendant-holds-dir"

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
# Mutant 3 — symlinks followed: the inside link target is deleted. The link
# points inside the job dir: an outside-pointing link is refused by the
# scanner and never reaches the remover.
case_mut_symlink() {
  reset_case mutsl || return 3
  hk_task 1 merged || return 3
  mk_ended_job mutsl 1 w:p9 || return 3
  mkdir -p "$INBOX/mutsl/keep" || return 3
  printf 'keepme\n' >"$INBOX/mutsl/keep/real.bin" || return 3
  ln -s keep "$INBOX/mutsl/cache-link" || return 3
  policy_min <<'JSON' || return 3
[{"class": "cache", "root": "jobs", "glob": "cache-*"}]
JSON
  seq_gone
  prune_run --apply >/dev/null 2>&1 || true
  [[ -f "$INBOX/mutsl/keep/real.bin" ]] ||
    assertion_red "the symlink target must be untouched"
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

# Mutant 5 — hk 2152: the never-touch check removed from the scanner.
case_mut_guard() {
  reset_case mutgd || return 3
  hk_task 1 merged || return 3
  mk_ended_job mutgd 1 w:p9 || return 3
  printf 'report\n' >"$INBOX/mutgd/report.md" || return 3
  mk_artifact "$INBOX/mutgd/browser-cache" || return 3
  policy_min <<'JSON' || return 3
[{"class": "cache", "root": "jobs", "glob": "*"}]
JSON
  seq_gone
  prune_run --apply >/dev/null 2>&1 || true
  [[ -f "$INBOX/mutgd/report.md" ]] ||
    assertion_red "a broad glob must not delete report.md"
}
# Mutant 6 — hk 2152: links skip the guard and the containment check.
case_mut_linkguard() {
  reset_case mutlg || return 3
  hk_task 1 merged || return 3
  mk_ended_job mutlg 1 w:p9 || return 3
  printf 'report\n' >"$INBOX/mutlg/report.md" || return 3
  mkdir -p "$INBOX/mutlg/refs" || return 3
  ln -s ../report.md "$INBOX/mutlg/refs/x" || return 3
  policy_min <<'JSON' || return 3
[{"class": "cache", "root": "jobs", "glob": "refs/*"}]
JSON
  seq_gone
  prune_run --apply >/dev/null 2>&1 || true
  [[ -L "$INBOX/mutlg/refs/x" ]] ||
    assertion_red "the refs/x link must survive"
}
# Mutant 7 — hk 2152: job.artifacts_pruned counts as job activity for age.
case_mut_age() {
  reset_case mutag || return 3
  hk_task 1 merged || return 3
  mk_ended_job mutag 1 w:p9 || return 3
  local b
  for b in b c a; do mk_artifact "$INBOX/mutag/build-$b" || return 3; done
  set_tree_mtime "$INBOX/mutag/build-b" 1 || return 3
  set_tree_mtime "$INBOX/mutag/build-c" 5 || return 3
  set_tree_mtime "$INBOX/mutag/build-a" 9 || return 3
  mk_artifact "$INBOX/mutag/browser-cache" || return 3
  seq_gone
  policy_min <<'JSON' || return 3
[{"class": "intermediate-build", "root": "jobs", "glob": "build-*",
  "keep_newest": 1}]
JSON
  prune_run --apply >/dev/null 2>&1 || true
  policy_min <<'JSON' || return 3
[{"class": "cache", "root": "jobs", "glob": "browser-*"}]
JSON
  prune_run --apply >/dev/null 2>&1 || true
  [[ ! -e "$INBOX/mutag/browser-cache" ]] ||
    assertion_red "a prune record must not move the job's age"
}
# Mutant 8 — hk 2152: the loader prints each valid row inside its loop.
case_mut_rows() {
  reset_case mutrw || return 3
  hk_task 1 merged || return 3
  mk_ended_job mutrw 1 w:p9 || return 3
  mk_artifact "$INBOX/mutrw/browser-cache" || return 3
  base_envelope '[{"class":"cache","root":"jobs","glob":"browser-*"},{"class":"evidence","root":"jobs","glob":"e-*"}]' >"$POLICY" || return 3
  seq_gone
  local out="" msg=""
  out="$(prune_run --apply 2>&1)" || true
  msg="$(grep '^artifact-prune refused' <<<"$out" || true)"
  [[ "$msg" == "artifact-prune refused: $POLICY — row 1 class 'evidence' is not yet supported" ]] ||
    assertion_red "the refusal message must be exactly the reason"
}
# Mutant 9 — hk 2152: a directory match holding a never-touch name is removed.
case_mut_holds() {
  reset_case muthd || return 3
  hk_task 1 merged || return 3
  mk_ended_job muthd 1 w:p9 || return 3
  mkdir -p "$INBOX/muthd/unity/Proj" || return 3
  printf 'run\n' >"$INBOX/muthd/unity/Proj/run.log" || return 3
  policy_min <<'JSON' || return 3
[{"class": "cache", "root": "jobs", "glob": "*"}]
JSON
  seq_gone
  prune_run --apply >/dev/null 2>&1 || true
  [[ -f "$INBOX/muthd/unity/Proj/run.log" ]] ||
    assertion_red "a directory holding run.log must not be removed"
}

# Mutant 10 — hk 2152 B1: a name with a control character is trusted. Both
# layers go: the scanner's unsafe-name check and the pass's record validator.
case_mut_unsafe() {
  reset_case mutun || return 3
  hk_task 1 merged || return 3
  mk_ended_job mutun 1 w:p9 || return 3
  printf 'must survive\n' >"$INBOX/mutun/report.md" || return 3
  printf 'cache\n' >"$INBOX/mutun/"$'spill\nreal\treport.md' || return 3
  policy_min <<'JSON' || return 3
[{"class": "cache", "root": "jobs", "glob": "*"}]
JSON
  seq_gone
  ( cd "$INBOX/mutun" && prune_run --apply >/dev/null 2>&1 ) || true
  [[ -f "$INBOX/mutun/report.md" ]] ||
    assertion_red "a file name must not forge a record that deletes report.md"
}
# Mutant 11 — hk 2152 B2: a directory holding a refused match is not held.
case_mut_held() {
  reset_case muthl || return 3
  hk_task 1 merged || return 3
  mk_ended_job muthl 1 w:p9 || return 3
  local outside="$TMP/muthl-outside"
  mkdir -p "$outside" "$INBOX/muthl/cache-folder" || return 3
  printf 'data\n' >"$INBOX/muthl/cache-folder/data.bin" || return 3
  ln -s "$outside" "$INBOX/muthl/cache-folder/out-link" || return 3
  policy_min <<'JSON' || return 3
[{"class": "cache", "root": "jobs", "glob": "**"}]
JSON
  seq_gone
  prune_run --apply >/dev/null 2>&1 || true
  [[ -L "$INBOX/muthl/cache-folder/out-link" ]] ||
    assertion_red "a dir holding a refused link match must not be removed"
}
# Mutant 12 — hk 2152 B2: a dropped match may hold or sit inside a kept one.
case_mut_nest() {
  reset_case mutnt || return 3
  hk_task 1 claimed || return 3
  mk_live_job mutnt 1 w:p9 || return 3
  mk_artifact "$INBOX/mutnt/build-A" || return 3
  set_tree_mtime "$INBOX/mutnt/build-A" 10 || return 3
  policy_min <<'JSON' || return 3
[{"class": "intermediate-build", "root": "jobs", "glob": "**",
  "keep_newest": 1}]
JSON
  prune_run --apply >/dev/null 2>&1 || true
  [[ -f "$INBOX/mutnt/build-A/payload.bin" ]] ||
    assertion_red "a dropped dir must not take the kept payload with it"
}
# Mutant 13 — hk 2152 B2: the subtree walk ignores links that point at the set.
case_mut_linkwalk() {
  reset_case mutlw || return 3
  hk_task 1 merged || return 3
  mk_ended_job mutlw 1 w:p9 || return 3
  printf 'report\n' >"$INBOX/mutlw/report.md" || return 3
  mkdir -p "$INBOX/mutlw/cache-folder" || return 3
  ln -s ../report.md "$INBOX/mutlw/cache-folder/safe-link" || return 3
  policy_min <<'JSON' || return 3
[{"class": "cache", "root": "jobs", "glob": "*"}]
JSON
  seq_gone
  prune_run --apply >/dev/null 2>&1 || true
  [[ -L "$INBOX/mutlw/cache-folder/safe-link" ]] ||
    assertion_red "a dir holding a link to report.md must not be removed"
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

# M5 — the never-touch check is removed from the scanner: hits() never hits,
# so a broad glob deletes report.md.
mkmut guard 's/    return any(fnmatch.fnmatchcase(name.casefold(), pat)/    return False and any(fnmatch.fnmatchcase(name.casefold(), pat)/'
expect_mut_red "never-touch-check-removed" case_mut_guard "must not delete report.md"

# M6 — links skip the guard: a link match is classified link without the
# never-touch and containment check, so the refs/x link is unlinked.
mkmut linkguard 's/return guard(match, (seat, os.path.realpath(match))) or "link"/return "link"/'
expect_mut_red "links-skip-guard" case_mut_linkguard "refs/x link must survive"

# M7 — job.artifacts_pruned counts for age: the housekeeping skip in the
# event scan is dropped, so each prune restarts the heavy-age clock.
mkmut age 's/if kind in HOUSEKEEPING:/if False:/'
expect_mut_red "prune-record-counts-for-age" case_mut_age "must not move the job's age"

# M8 — rows print inside the loader's validation loop: the refusal message
# starts with the earlier valid row.
mkmut rows 's/out\.append("/print("/'
expect_mut_red "rows-print-in-loop" case_mut_rows "exactly the reason"

# M9 — a directory match that holds a never-touch name is removed whole.
mkmut holds 's/if os.path.isdir(match) and holds_never_touch(match):/if False:/'
expect_mut_red "holds-check-removed" case_mut_holds "holding run.log must not be removed"

# M10 — a name with a control character is trusted: the scanner's unsafe-name
# check and the pass's record validator are both removed.
mkmut unsafe 's/if any(ord(ch) < 32 or ord(ch) == 127 for ch in match):/if False:/' 's/prune_artifact_record_ok "\$jobdir" "\$kind" "\$match" "\$mtime" "\$bytes" || {/true || {/'
expect_mut_red "unsafe-name-trusted" case_mut_unsafe "must not forge a record"

# M11 — ancestors of a refused match are no longer held.
mkmut held 's/if kind == "real" and os.path.normpath(match) in held:/if False:/'
expect_mut_red "refused-descendant-ancestor-removed" case_mut_held "refused link match must not be removed"

# M12 — the nested-with-kept-match filter is dropped from the removal plan.
mkmut nest 's/if (( ${#kept_list\[@\]} && ${#todo\[@\]} )); then/if false; then/'
expect_mut_red "dropped-dir-takes-kept-match" case_mut_nest "must not take the kept payload"

# M13 — the subtree walk stops resolving links that point at the set.
mkmut linkwalk 's/if parts is not None and hits(parts):/if False:/'
expect_mut_red "link-to-never-touch-ignored" case_mut_linkwalk "link to report.md must not be removed"

echo "ALL ARTIFACT-PRUNE CONTRACT TESTS PASSED"
