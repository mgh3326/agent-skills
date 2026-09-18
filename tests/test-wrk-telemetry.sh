#!/usr/bin/env bash
# task445 phase A — lifecycle telemetry receipts + bench_reps exporter.
# Every case runs against the fixture herdr and the fixture authenticated
# handoffkeep server (tests/fixtures/hkserver.py); nothing touches a real
# herdr, arbiter, panewire or handoffkeep installation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
PANEWIRE="$ROOT/tests/fixtures/panewire"
HKSERVER="$ROOT/tests/fixtures/hkserver.py"
TMP="$(mktemp -d)"

HK_PID=""
cleanup() {
  local pidfile pid
  while IFS= read -r pidfile; do
    [[ -s "$pidfile" ]] || continue
    read -r pid <"$pidfile" || continue
    if [[ "$pid" =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; fi
  done < <(find "$TMP" -name 'completion-sentinel.pid' 2>/dev/null)
  [[ -z "$HK_PID" ]] || kill "$HK_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

PROMPT="$TMP/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"
export CLINEPASS_GATE_KEY_FILE="$TMP/clinepass-gate-key.txt"
printf 'fixture-gate-key\n' >"$CLINEPASS_GATE_KEY_FILE"
export ARBITER_BIN="$TMP/absent-arbiter"
export XDG_DATA_HOME="$TMP/xdg"
export ARBITER_INBOX_ROOT="$TMP/inbox"
export PANEWIRE_BIN="$PANEWIRE"
export HANDOFFKEEP_BIN="$TMP/absent-handoffkeep"

JOBS="$ARBITER_INBOX_ROOT"
HK_TOKEN="fixture-token-445-must-not-leak"
HK_LOG="$TMP/hk-requests.log"
HK_STATE="$TMP/hk-state.json"
HK_TASKS="$TMP/hk-tasks.json"
HK_PORT_FILE="$TMP/hk-port"

fail() { echo "FAIL: $*" >&2; exit 1; }

run_fail() {
  if "$@" >/dev/null 2>&1; then
    echo "expected failure: $*" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------- fixtures

# #445: an in_progress task the builder may legally join-link.
# #395: the honesty fixture — claimed->in_progress is 1h18m55s (4735s) of
# start/status-report lag, in_progress->verifying 5000s of implementation,
# verifying->join 2030s of verification: V_over_I = 2030/5000 = 0.406.
python3 - "$HK_TASKS" <<'PY'
import json, sys
tasks = {
    "445": {"id": 445, "state": "in_progress", "lane": "builder-445",
            "claimed_by": "b445-telemetry", "refs": {},
            "events": [
                {"from": "backlog", "to": "claimed", "by": "orch",
                 "at": "2026-09-18T00:00:00+00:00"},
                {"from": "claimed", "to": "in_progress", "by": "b445",
                 "at": "2026-09-18T00:10:00+00:00"},
            ]},
    "395": {"id": 395, "state": "join", "lane": "builder-395",
            "claimed_by": "w395", "refs": {},
            "events": [
                {"from": "backlog", "to": "claimed", "by": "orch",
                 "at": "2026-09-01T00:00:00+00:00"},
                {"from": "claimed", "to": "in_progress", "by": "w395",
                 "at": "2026-09-01T01:18:55+00:00"},
                {"from": "in_progress", "to": "verifying", "by": "w395",
                 "at": "2026-09-01T02:42:15+00:00"},
                {"from": "verifying", "to": "join", "by": "w395",
                 "at": "2026-09-01T03:16:05+00:00"},
            ]},
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(tasks, handle)
PY

HK_SERVER_ERR="$TMP/hkserver.err"
env HK_FIXTURE_TASKS="$HK_TASKS" HK_FIXTURE_LOG="$HK_LOG" \
  HK_FIXTURE_STATE="$HK_STATE" HK_FIXTURE_PORT_FILE="$HK_PORT_FILE" \
  HK_FIXTURE_TOKEN="$HK_TOKEN" python3 "$HKSERVER" 2>"$HK_SERVER_ERR" &
HK_PID=$!
# Bounded readiness wait (30s — macOS runners can take seconds to reach a
# fresh python interpreter), with child-liveness checks so a crashed server
# fails fast and its stderr is shown instead of a bare timeout.
hk_ready=0
for _ in $(seq 1 300); do
  [[ -s "$HK_PORT_FILE" ]] && { hk_ready=1; break; }
  kill -0 "$HK_PID" 2>/dev/null || break
  sleep 0.1
done
if [[ "$hk_ready" -ne 1 ]]; then
  echo "fixture handoffkeep server did not start" >&2
  hk_rc=0
  wait "$HK_PID" 2>/dev/null || hk_rc=$?
  echo "fixture server exit rc=$hk_rc" >&2
  [[ -s "$HK_SERVER_ERR" ]] && cat "$HK_SERVER_ERR" >&2
  exit 1
fi
HK_PORT="$(<"$HK_PORT_FILE")"
HK_URL="http://127.0.0.1:$HK_PORT"

# Spawn against fixture herdr. $1=model $2=job; rest = extra wrk args.
spawn_t() {
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="$ARBITER_BIN" WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_HANDOFFKEEP_URL="$HK_URL" WRK_HANDOFFKEEP_TOKEN="$HK_TOKEN" \
    "$WRK" spawn -c "$ROOT" -m "$1" -p "$PROMPT" -w w -l fixture \
    --job "$2" --t T1 "${@:3}"
}

# A bound spawn including the explicit task binding.
spawn_bound() { spawn_t "$1" "$2" --task-id "${3:-445}"; }

# done/joined/reconcile/status with the live fixture server env.
wrk_hk() {
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="$ARBITER_BIN" \
    WRK_HANDOFFKEEP_URL="$HK_URL" WRK_HANDOFFKEEP_TOKEN="$HK_TOKEN" \
    WRK_PANEWIRE_LOG="$TMP/panewire.log" \
    "$WRK" "$@"
}

# Claim/spawned events are what the production arbiter would have written;
# fabricate them the same way the R20 suite does for the arbiter-absent path.
mk_events() {
  local job="$1" role="${2:-worker}" parent="${3:-}"
  mkdir -p "$JOBS/$job/events"
  python3 - "$JOBS/$job/events" "$job" "$role" "$parent" <<'PY'
import json, os, sys
events, job, role, parent = sys.argv[1:5]
claim = {"job_id": job, "kind": "job.claim", "seq": 1,
         "payload": {"agent_label": "fixture", "owner_lane": "lane-t",
                     "pane_id": "w:p1", "role": role, "t_level": "T1"}}
if parent:
    claim["payload"]["parent_lane"] = parent
spawned = {"job_id": job, "kind": "job.spawned", "seq": 2,
           "payload": {"label": "fixture", "owner_lane": "lane-t",
                       "pane_id": "w:p1"}}
for seq, record in ((1, claim), (2, spawned)):
    with open(os.path.join(events, "%05d-%s.json" % (seq, record["kind"])),
              "w", encoding="utf-8") as handle:
        json.dump(record, handle)
PY
}

mk_report() { printf 'telemetry report %s\nlast line\n' "$1" >"$TMP/report-$1.md"; echo "$TMP/report-$1.md"; }

reps() {
  python3 - "$HK_STATE" <<'PY'
import json, sys
try:
    state = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    state = {"reps": []}
for rep in state.get("reps", []):
    print(json.dumps(rep, sort_keys=True))
PY
}

reps_count() { reps | wc -l | tr -d ' '; }

receipt_json() { cat "$JOBS/$1/telemetry/receipts/$2"; }

# ---------------------------------------------------------------- tests

# T1 — invalid task ids are rejected before any admission side effect.
for bad in 0 abc -3 007 44.5; do
  run_fail spawn_t codex "t445-bad-$bad" --task-id "$bad"
done
[[ ! -e "$TMP/herdr.log" ]] || ! grep -q 'tab create' "$TMP/herdr.log" ||
  fail "invalid --task-id reached pane creation"
echo "PASS telemetry-invalid-task-id-rejected"

# T2 — a task id that does not validate through the API refuses the spawn.
run_fail spawn_bound codex t445-missing 999
[[ ! -e "$JOBS/t445-missing/telemetry/binding.json" ]] ||
  fail "unverifiable task was bound anyway"
# No configured API at all: the binding cannot be verified, so it refuses.
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$ARBITER_BIN" WRK_FIXTURE_SCENARIO=spawn \
  "$WRK" spawn -c "$ROOT" -m codex -p "$PROMPT" -w w -l fixture \
  --job t445-noenv --task-id 445 --t T1
echo "PASS telemetry-unverifiable-binding-refused"

# T3 — job-name digits are never a task join: an unmanaged spawn keeps the
# compatibility path and is reported uncovered, never silently bound.
spawn_t codex 445-unnamed --t T1 >/dev/null
[[ ! -e "$JOBS/445-unnamed/telemetry/binding.json" ]] ||
  fail "job-name digits silently bound a task"
echo "PASS telemetry-job-name-digits-never-join"

# T4 — verified explicit binding: start receipt before OK, evidence intact.
spawn_bound codex t445-ok 445 >"$TMP/spawn-ok.out"
grep -q '^OK pane=w:p1 ' "$TMP/spawn-ok.out" || fail "bound spawn produced no OK"
[[ -f "$JOBS/t445-ok/telemetry/binding.json" ]] || fail "binding.json missing"
start_receipt="$(echo "$JOBS"/t445-ok/telemetry/receipts/start-a1-*.json)"
[[ -f "$start_receipt" ]] || fail "start receipt missing"
python3 - "$start_receipt" "$HK_TOKEN" <<'PY'
import json, os, sys
receipt_path, token = sys.argv[1], sys.argv[2]
raw = open(receipt_path, encoding="utf-8").read()
receipt = json.loads(raw)
assert receipt["kind"] == "telemetry_receipt", receipt
assert receipt["schema_version"] == 1, receipt
assert receipt["phase"] == "start", receipt
assert receipt["task_ref"] == "hk:task/445", receipt
assert receipt["job_id"] == "t445-ok", receipt
assert receipt["attempt_id"] == "a1", receipt
assert receipt["participant_segment"] == "s1", receipt
assert receipt["role"] == "worker", receipt
assert receipt["t_level"] == "T1", receipt
assert receipt["observed"]["model"] == "unknown", receipt
assert receipt["launch"]["profile"] == "codex", receipt
assert receipt["launch"]["harness"], receipt
assert receipt["evidence"]["pane_id"] == "w:p1", receipt
# Metadata budget: <= 8KiB per receipt, and no secret ever lands in one.
assert len(raw.encode()) <= 8192, len(raw)
assert token not in raw, "bearer token leaked into a receipt"
PY
echo "PASS telemetry-explicit-binding-start-receipt"

# T5 — start receipt store failure: no normal ACK and no duplicate worker
# on retry (the recorded pane is adopted instead of respawned).
rm -f "$TMP/herdr.log"
set +e
env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$ARBITER_BIN" WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
  WRK_HANDOFFKEEP_URL="$HK_URL" WRK_HANDOFFKEEP_TOKEN="$HK_TOKEN" \
  WRK_TELEMETRY_FAIL_STORE=start \
  "$WRK" spawn -c "$ROOT" -m codex -p "$PROMPT" -w w -l fixture \
  --job t445-storefail --task-id 445 --t T1 >"$TMP/storefail.out" 2>"$TMP/storefail.err"
rc=$?
set -e
[[ "$rc" -eq 77 ]] || fail "start-store-failure exit=$rc, want 77"
! grep -q '^OK ' "$TMP/storefail.out" || fail "normal ACK printed despite store failure"
[[ "$(grep -c 'tab create' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "expected exactly one tab create before store failure"
spawn_bound codex t445-storefail 445 >"$TMP/storefail-retry.out"
grep -q '^OK pane=w:p1 ' "$TMP/storefail-retry.out" ||
  fail "adoption retry did not ACK"
[[ "$(grep -c 'tab create' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "retry duplicated the worker (tab create ran twice)"
adopted_receipt="$(echo "$JOBS"/t445-storefail/telemetry/receipts/start-a1-*.json)"
[[ -f "$adopted_receipt" ]] ||
  fail "start receipt missing after adoption retry"
echo "PASS telemetry-start-store-failure-no-duplicate"

# T6 — terminal receipt store failure: no normal done ACK; retry restores
# and exports the pending receipt through bench_reps.
spawn_bound codex t445-done 445 >/dev/null
mk_events t445-done
report="$(mk_report t445-done)"
set +e
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER_BIN" \
  WRK_HANDOFFKEEP_URL="$HK_URL" WRK_HANDOFFKEEP_TOKEN="$HK_TOKEN" \
  WRK_PANEWIRE_LOG="$TMP/panewire.log" WRK_TELEMETRY_FAIL_STORE=terminal \
  "$WRK" 'done' t445-done --report "$report" >"$TMP/done-fail.out" 2>"$TMP/done-fail.err"
rc=$?
set -e
[[ "$rc" -eq 77 ]] || fail "terminal-store-failure exit=$rc, want 77"
! grep -q '^OK ' "$TMP/done-fail.out" || fail "done ACK printed despite store failure"
done_out="$(wrk_hk 'done' t445-done --report "$report")"
grep -q '^OK job=t445-done ' <<<"$done_out" || fail "done retry did not ACK"
term_receipt="$(echo "$JOBS"/t445-done/telemetry/receipts/terminal-a1-*-completed.json)"
[[ -f "$term_receipt" ]] || fail "terminal receipt missing"
python3 - "$term_receipt" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1], encoding="utf-8"))
assert receipt["phase"] == "terminal", receipt
assert receipt["terminal"]["status"] == "completed", receipt
assert receipt["terminal"]["participant_semantics"] == "work_done", receipt
assert receipt["projection"]["state"] == "exported", receipt["projection"]
assert receipt["projection"]["origin_id"] >= 9000000000000, receipt
assert receipt["observed"]["model"] == "unknown", receipt
assert receipt["evidence"].get("report_sha256"), receipt
PY
echo "PASS telemetry-terminal-store-failure-recovery"

# T7 — the exported rep exists and is honest: positive high-range origin,
# unknown model stays null, roles map, and the reps GET readback is
# non-empty through the same authenticated API.
[[ "$(reps_count)" -ge 1 ]] || fail "no rep exported"
python3 - "$HK_URL" "$HK_TOKEN" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request(sys.argv[1] + "/v1/bench/reps")
req.add_header("Authorization", "Bearer " + sys.argv[2])
reps = json.load(urllib.request.urlopen(req, timeout=5))["reps"]
assert reps, "reps readback empty"
rep = next(r for r in reps if "job=t445-done" in (r.get("notes") or ""))
assert rep["origin_id"] >= 9000000000000, rep
assert rep["model_id"] is None, rep
assert rep["task_ref"] == "hk:task/445", rep
assert rep["tier"] == "T1", rep
assert rep["role"] == "impl", rep
assert rep["completed"] == 1, rep
assert rep["created_by"] == "fixture-client", rep
assert rep["grade"] is None and rep["table_grade"] is None, rep
PY
echo "PASS telemetry-rep-exported-readback"

# T8 — same terminal event and repeated reconcile: same origin_id, zero
# additional reps rows (deterministic idempotency).
before="$(reps_count)"
wrk_hk 'done' t445-done --report "$report" >/dev/null
wrk_hk reconcile >/dev/null
wrk_hk reconcile --job t445-done >/dev/null
[[ "$(reps_count)" -eq "$before" ]] ||
  fail "repeated terminal/reconcile minted new reps rows"
echo "PASS telemetry-idempotent-export"

# T9 — externally produced terminal kinds reach receipts through reconcile:
# revoked, cancelled and lost never look completed.
for case in "t445-revoked job.revoked revoked" \
            "t445-cancelled job.cancelled cancelled" \
            "t445-lost job.lost failed"; do
  job="${case%% *}"; rest="${case#* }"; kind="${rest%% *}"; want="${rest#* }"
  spawn_bound codex "$job" 445 >/dev/null
  mk_events "$job"
  python3 - "$JOBS/$job/events" "$job" "$kind" <<'PY'
import json, os, sys
events, job, kind = sys.argv[1:4]
names = [n for n in os.listdir(events) if n.endswith(".json")]
seq = max(int(n.split("-", 1)[0]) for n in names) + 1
record = {"kind": kind, "job_id": job, "owner_lane": "lane-t",
          "label": "fixture", "pane_id": "w:p1", "host": "fixture",
          "report_path": "", "report_last_line": "", "reason": "fixture",
          "epoch": 1}
with open(os.path.join(events, "%05d-%s.json" % (seq, kind)), "w",
          encoding="utf-8") as handle:
    json.dump(record, handle)
PY
  wrk_hk reconcile --job "$job" >/dev/null
  found=""
  for f in "$JOBS/$job"/telemetry/receipts/terminal-a1-*-"$want".json; do
    [[ -f "$f" ]] && found="$f"
  done
  [[ -n "$found" ]] || fail "reconcile produced no $want receipt for $job"
done
python3 - "$HK_STATE" <<'PY'
import json, sys
reps = json.load(open(sys.argv[1], encoding="utf-8"))["reps"]
by_job = {r["notes"].split()[0]: r for r in reps}
assert by_job["job=t445-revoked"]["completed"] == 0
assert by_job["job=t445-cancelled"]["completed"] == 0
assert by_job["job=t445-lost"]["completed"] == 0
PY
echo "PASS telemetry-external-terminal-kinds"

# T10 — a second attempt with a different profile opens a new participant
# segment: the task is never collapsed to one model and origins differ.
spawn_bound codex t445-segments 445 >/dev/null
mk_events t445-segments
wrk_hk 'done' t445-segments --report "$(mk_report t445-segments)" >/dev/null
spawn_bound codex-terra t445-segments 445 >/dev/null
wrk_hk 'done' t445-segments --report "$(mk_report t445-segments-b)" >/dev/null
python3 - "$JOBS/t445-segments/telemetry" <<'PY'
import json, os, sys
telemetry = sys.argv[1]
attempts = json.load(open(os.path.join(telemetry, "attempts.json")))
assert sorted(attempts) == ["a1", "a2"], attempts
receipts = {}
for name in os.listdir(os.path.join(telemetry, "receipts")):
    if name.startswith("terminal-"):
        r = json.load(open(os.path.join(telemetry, "receipts", name)))
        receipts[r["attempt_id"]] = r
assert len(receipts) == 2, receipts
a1, a2 = receipts["a1"], receipts["a2"]
assert a1["launch"]["profile"] != a2["launch"]["profile"], (a1, a2)
assert a1["projection"]["origin_id"] != a2["projection"]["origin_id"]
PY
python3 - "$HK_STATE" <<'PY'
import json, sys
reps = json.load(open(sys.argv[1], encoding="utf-8"))["reps"]
mine = [r for r in reps if "job=t445-segments" in (r.get("notes") or "")]
assert len(mine) == 2, mine
assert mine[0]["origin_id"] != mine[1]["origin_id"]
profiles = {r["profile"] for r in mine}
assert len(profiles) == 2, profiles
PY
echo "PASS telemetry-segment-change-new-origin"

# T11 — joined means pr_submitted, and the typed refs.job_id rides the
# legal in_progress->join transition (fixture task 445 is in_progress).
spawn_bound codex t445-builder 445 >/dev/null
mk_events t445-builder builder parent-lane-t
builder_report="$(mk_report t445-builder)"
joined_out="$(wrk_hk joined t445-builder --pr https://example.invalid/pr/445 \
  --head cafe445 --report "$builder_report")"
grep -q '^OK job=t445-builder ' <<<"$joined_out" || fail "joined produced no OK"
builder_receipt="$(echo "$JOBS"/t445-builder/telemetry/receipts/terminal-a1-*-completed.json)"
python3 - "$builder_receipt" "$HK_STATE" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1], encoding="utf-8"))
assert receipt["terminal"]["participant_semantics"] == "pr_submitted", receipt
assert receipt["evidence"]["task_refs_job_id"] == "linked", receipt["evidence"]
assert receipt["evidence"]["pr"] == "https://example.invalid/pr/445", receipt
state = json.load(open(sys.argv[2], encoding="utf-8"))
transitions = state.get("transitions", [])
assert transitions and transitions[-1]["task_id"] == 445, transitions
refs = transitions[-1]["refs"]
assert refs["job_id"] == "t445-builder", refs
assert refs["pr"] == "https://example.invalid/pr/445", refs
assert refs["head_sha"] == "cafe445", refs
PY
echo "PASS telemetry-joined-pr-submitted-refs-job-id"

# T12 — open attempt: bound and still running. It must never look
# completed, and coverage counters stay honest (nothing expected yet).
spawn_bound codex t445-open 445 >/dev/null
status="$(wrk_hk telemetry-status --job t445-open)"
grep -q 'expected_terminal_attempts=0' <<<"$status" ||
  fail "open attempt counted as expected terminal"
python3 - "$HK_STATE" <<'PY'
import json, sys
reps = json.load(open(sys.argv[1], encoding="utf-8"))["reps"]
assert not [r for r in reps if "job=t445-open" in (r.get("notes") or "")], reps
PY
echo "PASS telemetry-open-attempt-not-completed"

# T13 — failed export stays pending_export (never bench_written), pending
# age is deterministic, and reconcile drains it when the server returns.
spawn_bound codex t445-pending 445 >/dev/null
mk_events t445-pending
pending_report="$(mk_report t445-pending)"
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER_BIN" \
  WRK_HANDOFFKEEP_URL="http://127.0.0.1:1" WRK_HANDOFFKEEP_TOKEN="$HK_TOKEN" \
  WRK_PANEWIRE_LOG="$TMP/panewire.log" \
  WRK_TELEMETRY_NOW=2026-09-19T00:00:00+00:00 \
  "$WRK" 'done' t445-pending --report "$pending_report" >/dev/null 2>&1
python3 - "$JOBS/t445-pending/telemetry" <<'PY'
import json, os, sys
telemetry = sys.argv[1]
names = os.listdir(os.path.join(telemetry, "receipts"))
terminal = [n for n in names if n.startswith("terminal-")]
assert len(terminal) == 1, terminal
receipt = json.load(open(os.path.join(telemetry, "receipts", terminal[0])))
assert receipt["projection"]["state"] == "pending_export", receipt["projection"]
PY
status="$(env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" \
  WRK_TELEMETRY_NOW=2026-09-19T01:00:00+00:00 \
  "$WRK" telemetry-status --job t445-pending)"
grep -qx 'expected_terminal_attempts=1' <<<"$status" || fail "$status"
grep -qx 'receipts_with_terminal_evidence=1' <<<"$status" || fail "$status"
grep -qx 'coverage_gap=0' <<<"$status" || fail "$status"
grep -qx 'pending_export=1' <<<"$status" || fail "$status"
grep -qx 'pending_export_age_s=3600' <<<"$status" || fail "$status"
wrk_hk reconcile --job t445-pending >/dev/null
python3 - "$JOBS/t445-pending/telemetry" <<'PY'
import json, os, sys
telemetry = sys.argv[1]
names = os.listdir(os.path.join(telemetry, "receipts"))
receipt = json.load(open(os.path.join(
    telemetry, "receipts", [n for n in names if n.startswith("terminal-")][0])))
assert receipt["projection"]["state"] == "exported", receipt["projection"]
assert receipt["projection"]["attempts"] >= 2, receipt["projection"]
PY
echo "PASS telemetry-pending-export-age-recovery"

# T14 — the aggregate status counts every bound terminal and every
# unmanaged job honestly: 445-unnamed is uncovered, never misbound. (The
# arbiter-absent spawn wrote no job dir, so the claim/spawned events are
# what give the unmanaged job a durable presence to report.)
mk_events 445-unnamed
status="$(wrk_hk telemetry-status)"
grep -q 'unmanaged job=445-unnamed' <<<"$status" ||
  fail "unmanaged job not reported uncovered: $status"
grep -q 'pending_export=0' <<<"$status" || fail "drained exports still pending"
gap="$(sed -n 's/^coverage_gap=\([0-9][0-9]*\).*/\1/p' <<<"$status")"
[[ "$gap" -eq 0 ]] || fail "coverage gap after reconcile: $status"
echo "PASS telemetry-status-counters"

# T15 — #395 honesty fixture: claimed->in_progress dwell is classified as
# start/status-report lag (never model time), model stays unknown, and
# V_over_I lands at 0.406 below the 1.0 investigation threshold.
spawn_bound codex t445-hk395 395 >/dev/null
python3 - "$JOBS/t445-hk395/telemetry/binding.json" <<'PY'
import json, sys
binding = json.load(open(sys.argv[1], encoding="utf-8"))
assert binding["task_ref"] == "hk:task/395", binding
assert binding["observed_model"] == "unknown", binding
dwell = {d["state"]: d for d in binding["state_dwell"]}
assert dwell["claimed"]["dwell_s"] == 4735.0, dwell
assert dwell["claimed"]["class"] == "start_lag", dwell
assert dwell["in_progress"]["class"] == "implementation", dwell
assert dwell["verifying"]["class"] == "verification", dwell
assert binding["v_over_i"] == 0.406, binding["v_over_i"]
assert binding["v_over_i"] < 1.0, binding["v_over_i"]
PY
echo "PASS telemetry-hk395-honest-state-dwell"

# T16 — the fixture server saw calls only to tasks + bench_reps: zero
# bench_scores/bench_grades requests can ever have been made by this PR.
! grep -Eq 'bench/(scores|grades)' "$HK_LOG" ||
  fail "wrk called a score/grade endpoint: $(grep 'bench/' "$HK_LOG")"
grep -q 'PUT /v1/bench/reps' "$HK_LOG" || fail "no reps PUT reached the server"
echo "PASS telemetry-reps-only-export"

echo "PASS all telemetry tests"
