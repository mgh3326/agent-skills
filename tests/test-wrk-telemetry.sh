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

cleanup() {
  local pidfile pid server_pid
  while IFS= read -r pidfile; do
    [[ -s "$pidfile" ]] || continue
    read -r pid <"$pidfile" || continue
    if [[ "$pid" =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; fi
  done < <(find "$TMP" -name 'completion-sentinel.pid' 2>/dev/null)
  # Fixture servers are registered in a pid file because start_hk runs in a
  # command substitution — an array update there would never survive.
  if [[ -f "$TMP/hk-server.pids" ]]; then
    while IFS= read -r server_pid; do
      if [[ "$server_pid" =~ ^[0-9]+$ ]]; then kill "$server_pid" 2>/dev/null || true; fi
    done <"$TMP/hk-server.pids"
  fi
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
HK_TASKS="$TMP/hk-tasks.json"

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

# Start one fixture server. Args: name tasks-file redirect-map-file.
# Prints the bound port. The server runs for the whole suite, so BOTH of
# its stdio streams must go to files: leaving stdout attached to the
# command substitution's pipe would keep $(start_hk ...) waiting on the
# server forever. The wait is bounded (30s — macOS runners can take
# seconds to reach a fresh python interpreter) with child-liveness checks
# so a crashed server fails fast and its output is shown, not a bare
# timeout; a live-but-deaf child is killed before `wait` so the
# diagnostic path itself can never block.
start_hk() {
  local name="$1" tasks_file="$2" rmap_file="$3"
  local port_file="$TMP/hk-$name.port" err_file="$TMP/hk-$name.err"
  local pid ready=0 rc
  env HK_FIXTURE_TASKS="$tasks_file" HK_FIXTURE_LOG="$TMP/hk-$name.log" \
    HK_FIXTURE_STATE="$TMP/hk-$name.state.json" \
    HK_FIXTURE_PORT_FILE="$port_file" HK_FIXTURE_REDIRECT_MAP="$rmap_file" \
    HK_FIXTURE_TOKEN="$HK_TOKEN" python3 "$HKSERVER" >"$err_file" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >>"$TMP/hk-server.pids"
  for _ in $(seq 1 300); do
    [[ -s "$port_file" ]] && { ready=1; break; }
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if [[ "$ready" -ne 1 ]]; then
    echo "fixture handoffkeep server '$name' did not start" >&2
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
    rc=0
    wait "$pid" 2>/dev/null || rc=$?
    echo "fixture server exit rc=$rc" >&2
    [[ -s "$err_file" ]] && cat "$err_file" >&2
    exit 1
  fi
  cat "$port_file"
}

# hop3: pure sink — only logs whether a forwarded Authorization arrived.
echo '{}' >"$TMP/hk-hop3-tasks.json"
echo '{}' >"$TMP/hk-empty-map.json"
HOP3_PORT="$(start_hk hop3 "$TMP/hk-hop3-tasks.json" "$TMP/hk-empty-map.json")"

# hop2: serves task 446 normally (the redirect target for hop1) and 302s
# every reps PUT to hop3 (the redirect source for the export test).
python3 - "$TMP/hk-hop2-tasks.json" <<'PY'
import json, sys
tasks = {"446": {"id": 446, "state": "in_progress", "lane": "x",
                 "claimed_by": "", "refs": {}, "events": []}}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(tasks, handle)
PY
python3 - "$TMP/hk-hop2-map.json" "$HOP3_PORT" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"PUT /v1/bench/reps":
               "http://localhost:%s/v1/bench/reps" % sys.argv[2]}, handle)
PY
HOP2_PORT="$(start_hk hop2 "$TMP/hk-hop2-tasks.json" "$TMP/hk-hop2-map.json")"

# hop1 (main): serves tasks 445/395 normally, 302s GET /v1/tasks/446 to
# hop2. PUT stays normal — the export tests need it.
python3 - "$TMP/hk-hop1-map.json" "$HOP2_PORT" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"GET /v1/tasks/446":
               "http://localhost:%s/v1/tasks/446" % sys.argv[2]}, handle)
PY
HK_PORT="$(start_hk hop1 "$HK_TASKS" "$TMP/hk-hop1-map.json")"
HK_URL="http://127.0.0.1:$HK_PORT"
# The per-hop logs the tests assert on.
HK_LOG="$TMP/hk-hop1.log"
HOP2_LOG="$TMP/hk-hop2.log"
HOP3_LOG="$TMP/hk-hop3.log"
HK_STATE="$TMP/hk-hop1.state.json"

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
# additional reps rows AND zero additional export attempts — a replayed
# terminal receipt must not flip exported evidence back to pending_export
# or trigger a second PUT.
before="$(reps_count)"
puts_before="$(grep -c 'PUT /v1/bench/reps' "$HK_LOG")"
wrk_hk 'done' t445-done --report "$report" >/dev/null
wrk_hk reconcile >/dev/null
wrk_hk reconcile --job t445-done >/dev/null
[[ "$(reps_count)" -eq "$before" ]] ||
  fail "repeated terminal/reconcile minted new reps rows"
[[ "$(grep -c 'PUT /v1/bench/reps' "$HK_LOG")" -eq "$puts_before" ]] ||
  fail "replayed terminal receipt triggered a second export"
python3 - "$term_receipt" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1], encoding="utf-8"))
assert receipt["projection"]["state"] == "exported", receipt["projection"]
assert receipt["projection"]["attempts"] == 1, receipt["projection"]
PY
echo "PASS telemetry-idempotent-export"

# T9 — externally produced terminal kinds reach receipts through reconcile:
# revoked, cancelled and lost never look completed. The events carry their
# explicit attempt_id — reconcile attributes only on that identity.
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
          "attempt_id": "a1", "epoch": 1}
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

# T17 — a 302 from the validated origin is refused before it is followed:
# the bind fails closed (no binding, no pane, no OK) and the second hop is
# never contacted with credentials. urllib's default redirect handler
# would forward the Authorization bearer — this is the xAI BOUNCE case.
rm -f "$TMP/herdr.log"
run_fail spawn_t codex t445-redir --task-id 446
[[ ! -e "$JOBS/t445-redir/telemetry/binding.json" ]] ||
  fail "redirected task was bound anyway"
if [[ -f "$TMP/herdr.log" ]]; then
  ! grep -q 'tab create' "$TMP/herdr.log" ||
    fail "pane created for an unverifiable (redirected) binding"
fi
! grep -q 'auth=present' "$HOP2_LOG" 2>/dev/null ||
  fail "bearer forwarded across redirect: $(cat "$HOP2_LOG")"
echo "PASS telemetry-redirect-refused-bind"

# T18 — the same refusal on the reps PUT path: a 302 drain target leaves
# the receipt pending_export (fail-closed, never dropped) and the second
# hop sees no Authorization; reconciling against the real origin then
# exports normally.
spawn_bound codex t445-redirput 445 >/dev/null
mk_events t445-redirput
redirput_report="$(mk_report t445-redirput)"
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER_BIN" \
  WRK_HANDOFFKEEP_URL="http://127.0.0.1:$HOP2_PORT" \
  WRK_HANDOFFKEEP_TOKEN="$HK_TOKEN" \
  WRK_PANEWIRE_LOG="$TMP/panewire.log" \
  "$WRK" 'done' t445-redirput --report "$redirput_report" >/dev/null 2>&1
python3 - "$JOBS/t445-redirput/telemetry" <<'PY'
import json, os, sys
telemetry = sys.argv[1]
names = [n for n in os.listdir(os.path.join(telemetry, "receipts"))
         if n.startswith("terminal-")]
assert len(names) == 1, names
receipt = json.load(open(os.path.join(telemetry, "receipts", names[0])))
projection = receipt["projection"]
assert projection["state"] == "pending_export", projection
assert str(projection["last_error"]).startswith("http_3"), projection
PY
! grep -q 'auth=present' "$HOP3_LOG" 2>/dev/null ||
  fail "bearer forwarded across reps-PUT redirect: $(cat "$HOP3_LOG")"
wrk_hk reconcile --job t445-redirput >/dev/null
python3 - "$JOBS/t445-redirput/telemetry" <<'PY'
import json, os, sys
telemetry = sys.argv[1]
names = [n for n in os.listdir(os.path.join(telemetry, "receipts"))
         if n.startswith("terminal-")]
receipt = json.load(open(os.path.join(telemetry, "receipts", names[0])))
assert receipt["projection"]["state"] == "exported", receipt["projection"]
PY
echo "PASS telemetry-redirect-refused-export"

# T19 — mutant sensitivity: restoring urllib's default redirect handling
# makes the T17/T18 assertions go RED. Run a mutant copy that re-enables
# redirect following; the bind then "succeeds" only because the bearer was
# forwarded to the second hop — the hop2 log records auth=present, which
# is exactly what T17 asserts must never happen.
cp "$WRK" "$TMP/wrk-mutant"
python3 - "$TMP/wrk-mutant" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
needle = "build_opener(_RefuseRedirect)"
assert src.count(needle) == 2, src.count(needle)
open(path, "w", encoding="utf-8").write(src.replace(needle, "build_opener()"))
PY
env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$ARBITER_BIN" WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr-mutant.log" \
  WRK_HANDOFFKEEP_URL="$HK_URL" WRK_HANDOFFKEEP_TOKEN="$HK_TOKEN" \
  "$TMP/wrk-mutant" spawn -c "$ROOT" -m codex -p "$PROMPT" -w w -l fixture \
  --job t445-mutant --task-id 446 --t T1 >/dev/null 2>&1 || true
grep -q 'GET /v1/tasks/446 auth=present' "$HOP2_LOG" ||
  fail "mutant did not forward the bearer — T17 assertion is not sensitive"
[[ -e "$JOBS/t445-mutant/telemetry/binding.json" ]] ||
  fail "mutant did not bind through the redirect — test is not sensitive"
if [[ -f "$JOBS/t445-mutant/completion-sentinel.pid" ]]; then
  mutant_sentinel=""
  read -r mutant_sentinel <"$JOBS/t445-mutant/completion-sentinel.pid" || true
  if [[ "$mutant_sentinel" =~ ^[0-9]+$ ]]; then kill "$mutant_sentinel" 2>/dev/null || true; fi
fi
rm -rf "$JOBS/t445-mutant"
echo "PASS telemetry-redirect-mutant-red"

# ---------------------------------------------------------------- repairs
# task445 phase A repair: terminal event <-> attempt correlation.
# The '# >>>' markers delimit each regression block so a pre-fix RED harness
# can slice out everything but one block and prove that block alone fails
# on the starting head.

# Shared setup for the stale-event tests: a1 completes (its flat terminal
# event is retained in the durable inbox), then a2 opens and stays open.
spawn_bound codex t445-stale 445 >/dev/null
mk_events t445-stale
wrk_hk 'done' t445-stale --report "$(mk_report t445-stale)" >/dev/null
spawn_bound codex t445-stale 445 >/dev/null

# >>> t445-red:stale-status
# T20 — telemetry-status must not count the retained a1 event as expected
# terminal evidence for the still-open a2, and nothing covered for a2.
status="$(wrk_hk telemetry-status --job t445-stale)"
grep -qx 'expected_terminal_attempts=1' <<<"$status" ||
  fail "a retained a1 event inflated expected coverage for open a2: $status"
grep -qx 'receipts_with_terminal_evidence=1' <<<"$status" || fail "$status"
grep -qx 'coverage_gap=0' <<<"$status" || fail "$status"
echo "PASS telemetry-status-stale-event-not-expected"
# >>> end stale-status

# >>> t445-red:stale-reconcile
# T21 — reconcile must not let the retained a1 event close or mint a
# receipt/rep for the open a2; the a1 event is attributable-but-covered.
reconcile_out="$(wrk_hk reconcile --job t445-stale)"
grep -q 'receipts_created=0' <<<"$reconcile_out" ||
  fail "reconcile minted a receipt for the open attempt: $reconcile_out"
grep -q 'unattributed=0' <<<"$reconcile_out" ||
  fail "the a1 event is attributable to a1, not unattributed: $reconcile_out"
python3 - "$JOBS/t445-stale" <<'PY'
import glob, json, os, sys
job_dir = sys.argv[1]
telemetry = os.path.join(job_dir, "telemetry")
attempts = json.load(open(os.path.join(telemetry, "attempts.json")))
assert attempts["a1"]["status"] == "terminal", attempts
assert attempts["a2"]["status"] == "open", \
    "a retained a1 event closed the still-open a2: %r" % attempts
names = [n for n in os.listdir(os.path.join(telemetry, "receipts"))
         if n.startswith("terminal-")]
assert all("-a2-" not in n for n in names), names
events = sorted(glob.glob(os.path.join(job_dir, "events", "*job.completed.json")))
event = json.load(open(events[-1], encoding="utf-8"))
assert event.get("attempt_id") == "a1", \
    "the wrk-owned terminal event must carry its originating attempt: %r" % event
PY
python3 - "$HK_STATE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
a2_reps = [r for r in state["reps"]
           if "job=t445-stale" in (r.get("notes") or "")
           and "attempt=a2" in r["notes"]]
assert not a2_reps, "a stale event exported a rep for the open a2: %r" % a2_reps
PY
echo "PASS telemetry-stale-event-never-closes-open-attempt"
# >>> end stale-reconcile

# >>> t445-red:attempt-ordering
# T22 — a<N> ordering is numeric. With a9 and a10 both open, `wrk done` must
# bind the terminal receipt and stamp the flat event with a10 — lexical
# ordering would pick a9.
mk_events t445-order
python3 - "$JOBS/t445-order/telemetry" <<'PY'
import json, os, sys
telemetry = sys.argv[1]
os.makedirs(os.path.join(telemetry, "receipts"), exist_ok=True)


def put(name, obj):
    with open(os.path.join(telemetry, name), "w", encoding="utf-8") as handle:
        json.dump(obj, handle)
        handle.write("\n")


put("binding.json", {
    "kind": "telemetry_binding", "schema_version": 1, "job_id": "t445-order",
    "task_id": 445, "task_ref": "hk:task/445",
    "verified_at": "2026-09-20T00:00:00+00:00", "task_state": "in_progress",
    "task_lane": "lane-t", "claimed_by": "", "state_dwell": [],
    "v_over_i": None, "observed_model": "unknown"})
attempts, segments = {}, {}
for i in range(1, 11):
    aid = "a%d" % i
    attempts[aid] = {
        "attempt_id": aid,
        "status": "open" if i >= 9 else "terminal",
        "opened_at": "2026-09-20T00:%02d:00+00:00" % i,
        "pane_id": "w:p1", "tab_id": "", "t_level": "T1"}
    if i < 9:
        attempts[aid]["closed_at"] = "2026-09-20T01:%02d:00+00:00" % i
        attempts[aid]["terminal_kind"] = "completed"
    segments[aid] = [{
        "seg": "s1",
        "identity": {"role": "worker", "profile": "codex", "effort": "",
                     "harness": "fixture", "pool": ""},
        "origin_id": 9000000990000 + i,
        "opened_at": "2026-09-20T00:%02d:00+00:00" % i}]
put("attempts.json", attempts)
put("segments.json", segments)
put("intent.json", {
    "kind": "telemetry_intent", "schema_version": 1, "job_id": "t445-order",
    "attempt_id": "a10", "status": "open", "label": "fixture",
    "model": "codex", "effort": "", "role": "worker", "t_level": "T1",
    "opened_at": "2026-09-20T00:10:00+00:00", "pane_id": "w:p1", "tab_id": ""})
PY
wrk_hk 'done' t445-order --report "$(mk_report t445-order)" >/dev/null
python3 - "$JOBS/t445-order" <<'PY'
import glob, json, os, sys
job_dir = sys.argv[1]
receipts_dir = os.path.join(job_dir, "telemetry", "receipts")
assert os.path.isfile(
    os.path.join(receipts_dir, "terminal-a10-s1-completed.json")), \
    "the latest attempt a10 must receive the terminal receipt: %r" \
    % os.listdir(receipts_dir)
attempts = json.load(open(os.path.join(job_dir, "telemetry", "attempts.json")))
assert attempts["a10"]["status"] == "terminal", attempts["a10"]
assert attempts["a9"]["status"] == "open", \
    "lexical ordering closed a9 instead of a10: %r" % attempts["a9"]
events = sorted(glob.glob(os.path.join(job_dir, "events", "*job.completed.json")))
event = json.load(open(events[-1], encoding="utf-8"))
assert event.get("attempt_id") == "a10", \
    "the flat terminal event must carry attempt a10: %r" % event
PY
echo "PASS telemetry-attempt-numeric-ordering"
# >>> end attempt-ordering

# >>> t445-red:unattributed-identities
# T23 — a terminal event is attributable only through its own explicit
# attempt_id: missing, malformed, unrecorded, and segment-less identities
# are all counted unattributed and never touch the open attempt.
spawn_bound codex t445-unattr 445 >/dev/null
mk_events t445-unattr
python3 - "$JOBS/t445-unattr" <<'PY'
import json, os, sys
job_dir = sys.argv[1]
telemetry = os.path.join(job_dir, "telemetry")
attempts_path = os.path.join(telemetry, "attempts.json")
attempts = json.load(open(attempts_path, encoding="utf-8"))
# a2 is recorded but closed and holds no participant segment: an event naming
# it still cannot be attributed (no segment), and a1 stays the open attempt
# the old code would have blamed everything on.
attempts["a2"] = {"attempt_id": "a2", "status": "abandoned",
                  "opened_at": "2026-09-20T00:00:00+00:00",
                  "closed_at": "2026-09-20T00:30:00+00:00",
                  "pane_id": "w:p9", "tab_id": "", "t_level": "T1"}
with open(attempts_path, "w", encoding="utf-8") as handle:
    json.dump(attempts, handle)
events = os.path.join(job_dir, "events")
records = [
    (3, "job.lost", {}),                      # missing identity (legacy event)
    (4, "job.revoked", {"attempt_id": "a99"}),   # recorded nowhere
    (5, "job.cancelled", {"attempt_id": "bogus"}),  # malformed
    (6, "job.failed", {"attempt_id": "a2"}),     # no participant segment
]
for seq, kind, extra in records:
    record = {"kind": kind, "job_id": "t445-unattr", "owner_lane": "lane-t",
              "label": "fixture", "pane_id": "w:p1", "host": "fixture",
              "report_path": "", "report_last_line": "", "reason": "fixture",
              "epoch": 1}
    record.update(extra)
    with open(os.path.join(events, "%05d-%s.json" % (seq, kind)), "w",
              encoding="utf-8") as handle:
        json.dump(record, handle)
PY
reconcile_out="$(wrk_hk reconcile --job t445-unattr)"
grep -q 'receipts_created=0' <<<"$reconcile_out" ||
  fail "unattributable events minted receipts: $reconcile_out"
grep -q 'unattributed=4' <<<"$reconcile_out" ||
  fail "unattributable events were not counted honestly: $reconcile_out"
python3 - "$JOBS/t445-unattr/telemetry" <<'PY'
import json, os, sys
telemetry = sys.argv[1]
names = [n for n in os.listdir(os.path.join(telemetry, "receipts"))
         if n.startswith("terminal-")]
assert not names, names
attempts = json.load(open(os.path.join(telemetry, "attempts.json")))
assert attempts["a1"]["status"] == "open", attempts
assert attempts["a2"]["status"] == "abandoned", attempts
PY
echo "PASS telemetry-unattributed-event-identities"
# >>> end unattributed-identities

# >>> t445-red:sentinel-attempt
# T24 — a sentinel-produced terminal event carries the attempt the sentinel
# was spawned to watch, and reconcile attributes it end-to-end.
spawn_bound codex t445-sentin 445 >/dev/null
mk_events t445-sentin
sent_report="$TMP/t445-sentin-report.md"
printf 'sentinel observed done\n' >"$sent_report"
env HERDR_BIN="$HERDR" ARBITER_BIN="$ARBITER_BIN" \
  WRK_FIXTURE_SCENARIO=sentinel-done \
  WRK_COMPLETION_INTERVAL_S=1 WRK_COMPLETION_TIMEOUT_S=3600 \
  WRK_SENTINEL_LOST_GRACE=3600 ARBITER_INBOX_ROOT="$JOBS" \
  "$WRK" sentinel t445-sentin lane-t fixture w:p1 "$sent_report" "" a1 \
  >/dev/null 2>&1 &
sentinel_pid=$!
for _ in $(seq 1 100); do
  compgen -G "$JOBS/t445-sentin/events/*-job.completed.json" >/dev/null && break
  sleep 0.1
done
kill "$sentinel_pid" 2>/dev/null || true
wait "$sentinel_pid" 2>/dev/null || true
python3 - "$JOBS/t445-sentin" <<'PY'
import glob, json, os, sys
job_dir = sys.argv[1]
events = sorted(glob.glob(os.path.join(job_dir, "events", "*job.completed.json")))
assert events, "sentinel produced no job.completed event"
event = json.load(open(events[-1], encoding="utf-8"))
assert event.get("attempt_id") == "a1", \
    "a sentinel terminal event must carry the watched attempt: %r" % event
PY
wrk_hk reconcile --job t445-sentin >/dev/null
[[ -f "$JOBS/t445-sentin/telemetry/receipts/terminal-a1-s1-completed.json" ]] ||
  fail "reconcile did not attribute the sentinel event to a1"
echo "PASS telemetry-sentinel-event-attempt-identity"
# >>> end sentinel-attempt

# >>> t445-red:origin-guard
# T25 — the pre-send (scheme, host, port) origin comparison is pinned
# semantically. The embedded hk_request/telemetry_drain bodies are extracted
# and executed with urllib.request.Request forged so the constructed
# request's send target resolves to a different origin — the exact failure
# the guard exists for. The real code must refuse before the bearer leaves;
# a mutant with the comparison deleted must be observed sending it, which is
# the observable difference that turns these assertions RED.

# Extract the first embedded <<'PY' body of function $2 in wrk copy $1 -> $3.
extract_wrk_py() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
start = src.index("\n%s() {" % sys.argv[2])
block = re.search(r"<<'PY'\n(.*?)\nPY\n", src[start:], re.S)
assert block, "no embedded python in %s" % sys.argv[2]
with open(sys.argv[3], "w", encoding="utf-8") as handle:
    handle.write(block.group(1) + "\n")
PY
}

hop3_count() {
  local n
  n="$(grep -c "$1" "$HOP3_LOG" 2>/dev/null || true)"
  echo "${n:-0}"
}

# Run an extracted hk_request body ($1) as "METHOD PATH" with the request
# retargeted to $4 — a different origin than the configured handoffkeep URL.
run_guard_probe() {
  GUARD_MUTANT_URL="$4" \
  WRK_HANDOFFKEEP_URL="$HK_URL" WRK_HANDOFFKEEP_TOKEN="$HK_TOKEN" \
  python3 - "$1" "$2" "$3" <<'PY'
import os, sys, urllib.request
snippet, method, path = sys.argv[1:4]
mutant_url = os.environ["GUARD_MUTANT_URL"]
_real_request = urllib.request.Request


def forged_request(*args, **kwargs):
    request = _real_request(*args, **kwargs)
    request.full_url = mutant_url
    return request


urllib.request.Request = forged_request
sys.argv = ["guard-probe", method, path, ""]
exec(compile(open(snippet, encoding="utf-8").read(), snippet, "exec"))
PY
}

# Same forgery for an extracted telemetry_drain body ($1) over jobs_root $2.
run_drain_probe() {
  GUARD_MUTANT_URL="$3" \
  WRK_HANDOFFKEEP_URL="$HK_URL" WRK_HANDOFFKEEP_TOKEN="$HK_TOKEN" \
  python3 - "$1" "$2" <<'PY'
import os, sys, urllib.request
snippet, jobs_root = sys.argv[1:3]
mutant_url = os.environ["GUARD_MUTANT_URL"]
_real_request = urllib.request.Request


def forged_request(*args, **kwargs):
    request = _real_request(*args, **kwargs)
    request.full_url = mutant_url
    return request


urllib.request.Request = forged_request
sys.argv = ["drain-probe", jobs_root, "8"]
exec(compile(open(snippet, encoding="utf-8").read(), snippet, "exec"))
PY
}

extract_wrk_py "$WRK" hk_request "$TMP/guard-hk_request.py"
hop3_gets_before="$(hop3_count 'GET /v1/tasks/445')"
set +e
guard_out="$(run_guard_probe "$TMP/guard-hk_request.py" GET /v1/tasks/445 \
  "http://127.0.0.1:$HOP3_PORT/v1/tasks/445" 2>&1)"
guard_rc=$?
set -e
[[ "$guard_rc" -eq 2 ]] ||
  fail "origin guard did not fail closed on a retargeted request (rc=$guard_rc): $guard_out"
grep -q 'refusing to send credentials to a non-configured origin' <<<"$guard_out" ||
  fail "origin refusal message missing: $guard_out"
[[ "$(hop3_count 'GET /v1/tasks/445')" -eq "$hop3_gets_before" ]] ||
  fail "a retargeted bind request reached a non-configured origin"

# Mutant: deleting the comparison must flip the assertions above — the
# forged target receives the bearer, which hop3 records as auth=present.
cp "$WRK" "$TMP/wrk-noguard"
python3 - "$TMP/wrk-noguard" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needle = "if actual != origin:"
assert src.count(needle) == 2, \
    "expected both origin comparisons, got %d" % src.count(needle)
open(sys.argv[1], "w", encoding="utf-8").write(
    src.replace(needle, "if False:"))
PY
extract_wrk_py "$TMP/wrk-noguard" hk_request "$TMP/guard-hk_request-mutant.py"
run_guard_probe "$TMP/guard-hk_request-mutant.py" GET /v1/tasks/445 \
  "http://127.0.0.1:$HOP3_PORT/v1/tasks/445" >/dev/null 2>&1 || true
grep -q 'GET /v1/tasks/445 auth=present' "$HOP3_LOG" ||
  fail "guard-deleted mutant never sent the bearer — the refusal assertion is not sensitive"

# The same pin on the reps export path: a retargeted PUT must leave the
# receipt pending_export with last_error=origin_changed and hop3 untouched.
GUARD_JOBS="$TMP/guard-jobs"
mkdir -p "$GUARD_JOBS/g1/telemetry/receipts"
python3 - "$GUARD_JOBS/g1/telemetry/receipts/terminal-a1-s1-completed.json" <<'PY'
import json, sys
receipt = {
    "kind": "telemetry_receipt", "schema_version": 1, "phase": "terminal",
    "task_id": 445, "task_ref": "hk:task/445", "job_id": "g1",
    "attempt_id": "a1", "participant_segment": "s1",
    "role": "worker", "t_level": "T1",
    "launch": {"role": "worker", "profile": "codex", "effort": "",
               "harness": "fixture", "pool": ""},
    "observed": {"model": "unknown"},
    "recorded_at": "2026-09-20T00:00:00+00:00",
    "ended_at": "2026-09-20T01:00:00+00:00",
    "terminal": {"status": "completed", "participant_semantics": "work_done",
                 "reason": "fixture", "rounds": None},
    "projection": {"state": "pending_export", "origin_id": 9000000999001,
                   "attempts": 0, "exported_at": None, "last_error": None},
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(receipt, handle)
PY
extract_wrk_py "$WRK" telemetry_drain "$TMP/guard-drain.py"
hop3_puts_before="$(hop3_count 'PUT /v1/bench/reps')"
run_drain_probe "$TMP/guard-drain.py" "$GUARD_JOBS" \
  "http://127.0.0.1:$HOP3_PORT/v1/bench/reps" >/dev/null
python3 - "$GUARD_JOBS/g1/telemetry/receipts/terminal-a1-s1-completed.json" <<'PY'
import json, sys
projection = json.load(open(sys.argv[1], encoding="utf-8"))["projection"]
assert projection["state"] == "pending_export", projection
assert projection["last_error"] == "origin_changed", projection
PY
[[ "$(hop3_count 'PUT /v1/bench/reps')" -eq "$hop3_puts_before" ]] ||
  fail "a retargeted reps PUT reached a non-configured origin"
extract_wrk_py "$TMP/wrk-noguard" telemetry_drain "$TMP/guard-drain-mutant.py"
run_drain_probe "$TMP/guard-drain-mutant.py" "$GUARD_JOBS" \
  "http://127.0.0.1:$HOP3_PORT/v1/bench/reps" >/dev/null
grep -q 'PUT /v1/bench/reps auth=present' "$HOP3_LOG" ||
  fail "guard-deleted drain mutant never sent the bearer — not sensitive"
echo "PASS telemetry-origin-guard-pinned"
# >>> end origin-guard

echo "PASS all telemetry tests"
