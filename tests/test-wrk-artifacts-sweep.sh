#!/usr/bin/env bash
# shellcheck disable=SC2016 # embedded python and JSON fixtures are literal by design
# hk 2094 contract tests: `wrk artifacts sweep` — the artifact-store host
# sweep (design hk:doc designs/b953/artifact-store, revision 5). Dry-run by
# default; --apply deletes a local original only after its dataset's hk
# record is drive_confirmed (or, only under local_delete_at=uploaded, the
# file's own manifest row says uploaded and the file is neither evidence
# class nor mirror_required) and the manifest has the same path, bytes and
# sha256. local_deleted rows are written back to the same hk record before
# any unlink. The sweep never uploads, copies or evicts anything.
#
# Every tree these tests delete is built under the suite temp root; herdr,
# handoffkeep, scopefuel and arbiter are fixtures. No real job dir, no real
# hk server and no Drive folder is ever touched.
set -euo pipefail
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="${WRK_TEST_BIN:-$ROOT/bin/wrk}"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="${ARBITER_TEST_BIN:-$ROOT/bin/arbiter}"
HK="$ROOT/tests/fixtures/handoffkeep"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wrk-artifacts-sweep.XXXXXX")"
# shellcheck disable=SC1091
. "$ROOT/tests/lib/tmp-writers.sh"
export TW_TMP="$TMP"

OWNED_PID_LOG="$TMP/owned-pids"; : >"$OWNED_PID_LOG"
own() { [[ "$1" =~ ^[0-9]+$ ]] || return 0; tw_register_pid "$OWNED_PID_LOG" "$1"; }

cleanup() {
  local tw_rc=0
  tmp_writers_stop || tw_rc=$?
  (( tw_rc == 0 )) && rm -rf "$TMP"
  if [[ "$tw_rc" -ne 0 || -n "${TW_LEFTOVER_PIDS:-}" ]]; then
    echo "FAIL: tracked writers survived teardown:${TW_LEFTOVER_PIDS:-}" >&2
    exit 1
  fi
}
trap cleanup EXIT

export ARBITER_BIN="$ARBITER" SCOPEFUEL_BIN="$SCOPEFUEL"
export XDG_DATA_HOME="$TMP/xdg-default"
mkdir -p "$XDG_DATA_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

sha_of() { python3 -c 'import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

size_of() { wc -c <"$1" | tr -d ' '; }

# Per-case roots. INBOX sits at <work>/herdr-inbox/jobs so the policy's
# "jobs" root resolves it and sibling roots (webqa) land beside it.
INBOX="" WORK="" XDG="" HK_DB="" HERDR_LOG="" GET_SEQ="" HOSTS="" POLICY="" TMPHOME=""
CASE_SEQ=0
reset_case() {
  CASE_SEQ=$((CASE_SEQ + 1))
  WORK="$TMP/work-$1-$CASE_SEQ"
  INBOX="$WORK/herdr-inbox/jobs"
  XDG="$TMP/xdg-$1-$CASE_SEQ"
  HK_DB="$TMP/hk-$1-$CASE_SEQ.json"
  HERDR_LOG="$TMP/herdr-$1-$CASE_SEQ.log"
  TMPHOME="$TMP/home-$1-$CASE_SEQ"
  mkdir -p "$INBOX" "$TMPHOME"
  GET_SEQ="$TMP/getseq-$1-$CASE_SEQ"
  printf 'not-found\n' >"$GET_SEQ"
  HOSTS="$TMP/hosts-$1-$CASE_SEQ.toml"
  printf '[local]\nmachine_id = "test-host"\n' >"$HOSTS"
  POLICY="$TMP/policy-$1-$CASE_SEQ.json"
}

write_hosts() { # write_hosts [local_delete_at]
  {
    printf '[local]\nmachine_id = "test-host"\n'
    if [[ -n "${1:-}" ]]; then
      printf '\n[artifacts]\nlocal_delete_at = "%s"\n' "$1"
    fi
  } >"$HOSTS"
}

# Default test policy: named roots under the case work root plus one row per
# class the sweep distinguishes.
write_policy() {
  cat >"$POLICY" <<'JSON'
{
 "schema": "fleet.artifact-policy.v1",
 "roots": {
  "jobs": "herdr-inbox/jobs",
  "webqa": "webqa-runner/jobs"
 },
 "rows": [
  {"class": "record-text", "root": "jobs", "glob": "events"},
  {"class": "record-text", "root": "jobs", "glob": "report*.md"},
  {"class": "record-text", "root": "jobs", "glob": "verdict*.md"},
  {"class": "record-text", "root": "jobs", "glob": "*.log"},
  {"class": "protected", "root": "jobs", "glob": "protected/**"},
  {"class": "cache", "root": "jobs", "glob": "cache/**"},
  {"class": "intermediate-build", "root": "jobs", "glob": "unity/*/out"},
  {"class": "evidence", "root": "jobs", "glob": "evidence/**"},
  {"class": "evidence", "root": "webqa", "glob": "evidence/**"},
  {"class": "final-build", "root": "jobs", "glob": "builds/final*"},
  {"class": "final-build", "root": "webqa", "glob": "release/*"}
 ]
}
JSON
}

arb() {
  env SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" "$ARBITER" "$@"
}

# mk_ended_job JOB TASK_ID [PANE] — claim (with task_id), spawned receipt and
# a job.completed terminal. Every event is minted days ago, strictly
# increasing, because job_events_scan orders by event time and counts only
# terminals AFTER the newest revive; the newest stamp is 4d old so the
# default 3d sweep age is past. PANE "-" leaves job.spawned pane-less (no
# probe is ever made).
mk_ended_job() {
  local job="$1" task="$2" pane="${3:--}"
  local payload='{"owner_lane":"lane-a","label":"lbl"}'
  [[ "$pane" == - ]] || payload='{"owner_lane":"lane-a","label":"lbl","pane_id":"'"$pane"'"}'
  local old
  old="$(python3 -c 'import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=5)).replace(microsecond=0).isoformat())')"
  ARBITER_TEST_NOW="$old" \
    arb claim --job "$job" --lane lane-a --agent-label lbl --t T1 \
    --task-id "$task" >/dev/null
  ARBITER_TEST_NOW="$old" \
    arb event --job "$job" --kind job.spawned --payload-json "$payload" >/dev/null
  ARBITER_TEST_NOW="$(python3 -c 'import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=4)).replace(microsecond=0).isoformat())')" \
    arb event --job "$job" --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null
}

mk_task() { # mk_task ID STATE PROJECT [JOB]
  HK_STATE="$HK_DB" "$HK" tasks add --id "$1" --title "task $1" --lane lane-a \
    --state "$2" --project "$3" ${4:+--job-id "$4"} >/dev/null
}

# mk_record KEY HOST JOB TASK PROJECT SOURCE STATE CONTENTS_JSON [EXTRA_JSON]
# STATE "" leaves archive.state unset; "drive_confirmed" also stamps
# drive_confirmed_at. EXTRA_JSON is merged into archive (e.g. mirror_required).
mk_record() {
  python3 - "$HK_DB" "$@" <<'PY'
import hashlib, json, os, sys
dbp, key, host, job, task, project, source, state, contents = sys.argv[1:10]
extra = json.loads(sys.argv[10]) if len(sys.argv) > 10 else {}
try:
    with open(dbp, encoding="utf-8") as f:
        db = json.load(f)
except (OSError, ValueError):
    db = {"tasks": {}}
rows = json.loads(contents)
archive = {"source": source,
           "drive_path": "My Drive/fleet-artifacts/%s/%s" % (host, job),
           "contents": rows}
if state:
    archive["state"] = state
if state == "drive_confirmed":
    archive["drive_confirmed_at"] = "2026-10-22T00:00:00+00:00"
archive.update(extra)
body = json.dumps({
    "schema": "fleet.artifact.v2", "origin": "desk-interim", "host": host,
    "project": project, "task_id": int(task), "job_id": job,
    "archive": archive, "local_deleted": []})
docs = db.setdefault("docs", {})
docs[key] = {"id": len(docs) + 1, "key": key, "kind": "note", "session": "",
             "job": job, "body": body,
             "sha256": hashlib.sha256(body.encode()).hexdigest(),
             "created_by": "fixture",
             "created_at": "2026-01-01T00:00:00+00:00",
             "updated_at": "2026-01-01T00:00:00+00:00"}
with open(dbp, "w", encoding="utf-8") as f:
    json.dump(db, f)
PY
}

# mk_row PATH FILE [EXTRA_JSON] — one manifest row with the file's real bytes
# and sha256; EXTRA_JSON merges (state, uploaded_at, mirror_required, …).
mk_row() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import hashlib, json, sys
rel, path, extra = sys.argv[1:4]
row = {"path": rel, "bytes": len(open(path, "rb").read()),
       "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()}
if extra:
    row.update(json.loads(extra))
print(json.dumps(row))
PY
}

doc_body() {
  HK_STATE="$HK_DB" "$HK" doc get "$1" | python3 -c 'import json,sys
print(json.load(sys.stdin)["body"])'
}

# sweep [args] — the env-pinned call. Stdout+stderr merge into SWEEP_OUT,
# rc into SWEEP_RC. Extra env pairs may precede the wrk args as NAME=VALUE.
sweep() {
  local out="" rc=0
  local -a envs=()
  while [[ "${1:-}" == *=* ]]; do envs+=("$1"); shift; done
  out="$(env ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HK_STATE="$HK_DB" HANDOFFKEEP_BIN="$HK" HERDR_BIN="$HERDR" \
    HK_DOC_PUT_OK=1 SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    WRK_HOSTS_CONFIG="$HOSTS" WRK_FIXTURE_LOG="$HERDR_LOG" \
    WRK_FIXTURE_GET_SEQUENCE="$GET_SEQ" \
    HOME="$TMPHOME" TMPDIR="$TMP" "${envs[@]}" \
    "$WRK" artifacts sweep --policy "$POLICY" "$@" 2>&1)" || rc=$?
  SWEEP_RC=$rc; SWEEP_OUT="$out"
  printf '%s\n' "$out"
}

have() { grep -q -- "$1" <<<"$SWEEP_OUT"; }

have_not() { ! grep -q -- "$1" <<<"$SWEEP_OUT"; }

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw1: drive_confirmed deletes matching files, records local_deleted, keeps the rest =="
reset_case sw1
write_hosts
write_policy
mk_ended_job sw1 101 w:p9
mk_task 101 merged proj sw1
JD="$INBOX/sw1"
mkdir -p "$JD/evidence/sub" "$JD/cache" "$JD/protected"
printf 'cap-one\n' >"$JD/evidence/cap.png"
printf 'cap-two\n' >"$JD/evidence/b.png"
printf 'deep\n' >"$JD/evidence/sub/deep.png"
printf 'report\n' >"$JD/report.md"
printf 'cached\n' >"$JD/cache/c.bin"
printf 'locked\n' >"$JD/protected/p.bin"
printf 'loose\n' >"$JD/loose.bin"
R1="$(mk_row evidence/cap.png "$JD/evidence/cap.png" '{"state":"uploaded","uploaded_at":"t"}')"
R2="$(mk_row evidence/sub/deep.png "$JD/evidence/sub/deep.png" '{"state":"uploaded","uploaded_at":"t"}')"
R3="$(mk_row report.md "$JD/report.md")"
R4="$(mk_row cache/c.bin "$JD/cache/c.bin")"
R5="$(mk_row protected/p.bin "$JD/protected/p.bin")"
K1="artifacts/proj/101/sw1"
mk_record "$K1" test-host sw1 101 proj "$JD" drive_confirmed "[$R1,$R2,$R3,$R4,$R5]"

sweep --job sw1
[[ "$SWEEP_RC" == 0 ]] || fail "sw1 dry-run rc=$SWEEP_RC"
have "path=evidence/cap.png class=evidence bytes=8 action=would-delete" ||
  fail "sw1 dry-run must announce cap.png: $SWEEP_OUT"
have "path=evidence/sub/deep.png class=evidence bytes=5 action=would-delete" ||
  fail "sw1 dry-run must announce deep.png: $SWEEP_OUT"
[[ -f "$JD/evidence/cap.png" ]] || fail "sw1 dry-run deleted cap.png"
doc_body "$K1" | grep -q '"local_deleted": \[\]' ||
  fail "sw1 dry-run must not write the record"

sweep --job sw1 --apply
[[ "$SWEEP_RC" == 0 ]] || fail "sw1 apply rc=$SWEEP_RC"
have "path=evidence/cap.png class=evidence bytes=8 action=deleted" ||
  fail "sw1 apply must delete cap.png: $SWEEP_OUT"
have "path=evidence/sub/deep.png class=evidence bytes=5 action=deleted" ||
  fail "sw1 apply must delete deep.png: $SWEEP_OUT"
[[ ! -e "$JD/evidence/cap.png" ]] || fail "sw1 cap.png still present"
[[ ! -e "$JD/evidence/sub/deep.png" ]] || fail "sw1 deep.png still present"
[[ ! -d "$JD/evidence/sub" ]] ||
  fail "sw1 emptied dir evidence/sub must be removed"
[[ -d "$JD/evidence" ]] || fail "sw1 non-empty dir evidence must stay"
[[ -f "$JD/evidence/b.png" ]] || fail "sw1 not-in-manifest file deleted"
[[ -f "$JD/report.md" ]] || fail "sw1 record-text report.md deleted"
[[ -f "$JD/cache/c.bin" ]] || fail "sw1 cache file deleted"
[[ -f "$JD/protected/p.bin" ]] || fail "sw1 protected file deleted"
[[ -f "$JD/loose.bin" ]] || fail "sw1 unclassed file deleted"
[[ -d "$JD/events" ]] || fail "sw1 events dir touched"
have "path=evidence/b.png class=evidence kept reason=not-in-manifest" ||
  fail "sw1 must report not-in-manifest for b.png: $SWEEP_OUT"
have "path=protected/p.bin class=protected kept reason=protected-class" ||
  fail "sw1 must report protected-class for p.bin: $SWEEP_OUT"
have "skipped class=record-text" || fail "sw1 must count record-text skips"
have "skipped class=cache" || fail "sw1 must count cache skips"
doc_body "$K1" | python3 -c 'import json,sys
d = json.load(sys.stdin)
rows = d.get("local_deleted") or []
paths = sorted(r.get("path") for r in rows)
assert paths == ["evidence/cap.png", "evidence/sub/deep.png"], paths
for r in rows:
    assert isinstance(r.get("bytes"), int) and r["bytes"] > 0, r
    assert isinstance(r.get("sha256"), str) and len(r["sha256"]) == 64, r
    assert isinstance(r.get("local_deleted_at"), str) and r["local_deleted_at"], r' ||
  fail "sw1 record must carry local_deleted rows for both files"
echo "PASS sw1-drive-confirmed-deletes"

# A rerun deletes nothing more and records nothing twice.
sweep --job sw1 --apply
[[ -f "$JD/evidence/b.png" ]] || fail "sw1 rerun must keep b.png"
doc_body "$K1" | python3 -c 'import json,sys
d = json.load(sys.stdin)
assert len(d.get("local_deleted") or []) == 2, d["local_deleted"]' ||
  fail "sw1 rerun must not duplicate local_deleted rows"
echo "PASS sw1-rerun-idempotent"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw2: not drive_confirmed keeps files through repeated sweeps =="
reset_case sw2
write_hosts
write_policy
mk_ended_job sw2 102 w:p9
mk_task 102 merged proj sw2
JD="$INBOX/sw2"
mkdir -p "$JD/evidence"
printf 'cap\n' >"$JD/evidence/cap.png"
R="$(mk_row evidence/cap.png "$JD/evidence/cap.png" '{"state":"uploaded","uploaded_at":"t"}')"
K2="artifacts/proj/102/sw2"
mk_record "$K2" test-host sw2 102 proj "$JD" uploading "[$R]"
sweep --job sw2 --apply
have "path=evidence/cap.png class=evidence kept reason=not-confirmed" ||
  fail "sw2 must keep unconfirmed file: $SWEEP_OUT"
[[ -f "$JD/evidence/cap.png" ]] || fail "sw2 deleted an unconfirmed file"
sweep --job sw2 --apply
[[ -f "$JD/evidence/cap.png" ]] || fail "sw2 second sweep deleted an unconfirmed file"
doc_body "$K2" | python3 -c 'import json,sys
assert not (json.load(sys.stdin).get("local_deleted")), "wrote local_deleted"' ||
  fail "sw2 must not record local_deleted"
echo "PASS sw2-not-confirmed-kept"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw3: manifest row missing or different keeps the file, reported =="
reset_case sw3
write_hosts
write_policy
mk_ended_job sw3 103 w:p9
mk_task 103 merged proj sw3
JD="$INBOX/sw3"
mkdir -p "$JD/evidence"
printf 'good\n' >"$JD/evidence/good.png"
printf 'absent\n' >"$JD/evidence/norow.png"
printf 'size-differs\n' >"$JD/evidence/sizediff.png"
printf 'hash-differs\n' >"$JD/evidence/hashdiff.png"
RG="$(mk_row evidence/good.png "$JD/evidence/good.png")"
RS="$(mk_row evidence/sizediff.png "$JD/evidence/sizediff.png" '{"bytes":3}')"
RH="$(python3 - "$JD/evidence/hashdiff.png" <<'PY'
import json, sys
r = {"path": "evidence/hashdiff.png",
     "bytes": len(open(sys.argv[1], "rb").read()), "sha256": "0" * 64}
print(json.dumps(r))
PY
)"
K3="artifacts/proj/103/sw3"
mk_record "$K3" test-host sw3 103 proj "$JD" drive_confirmed "[$RG,$RS,$RH]"
sweep --job sw3 --apply
[[ ! -e "$JD/evidence/good.png" ]] || fail "sw3 matching file not deleted"
[[ -f "$JD/evidence/norow.png" ]] || fail "sw3 not-in-manifest file deleted"
[[ -f "$JD/evidence/sizediff.png" ]] || fail "sw3 bytes-differs file deleted"
[[ -f "$JD/evidence/hashdiff.png" ]] || fail "sw3 hash-differs file deleted"
have "path=evidence/norow.png class=evidence kept reason=not-in-manifest" ||
  fail "sw3 must report not-in-manifest: $SWEEP_OUT"
have "path=evidence/sizediff.png class=evidence kept reason=bytes-differs" ||
  fail "sw3 must report bytes-differs: $SWEEP_OUT"
have "path=evidence/hashdiff.png class=evidence kept reason=hash-differs" ||
  fail "sw3 must report hash-differs: $SWEEP_OUT"
echo "PASS sw3-manifest-mismatch-kept"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw4: local_delete_at=uploaded deletes non-evidence uploaded rows only =="
reset_case sw4
write_hosts uploaded
write_policy
mk_ended_job sw4 104 w:p9
mk_task 104 merged proj sw4
JD="$INBOX/sw4"
mkdir -p "$JD/evidence" "$JD/builds"
printf 'built\n' >"$JD/builds/final-app.bin"
printf 'proof\n' >"$JD/evidence/cap.png"
printf 'mirror\n' >"$JD/builds/final-1716.bin"
RF="$(mk_row builds/final-app.bin "$JD/builds/final-app.bin" '{"state":"uploaded","uploaded_at":"t"}')"
RE="$(mk_row evidence/cap.png "$JD/evidence/cap.png" '{"state":"uploaded","uploaded_at":"t"}')"
RM="$(mk_row builds/final-1716.bin "$JD/builds/final-1716.bin" '{"state":"uploaded","uploaded_at":"t","mirror_required":true}')"
K4="artifacts/proj/104/sw4"
mk_record "$K4" test-host sw4 104 proj "$JD" uploading "[$RF,$RE,$RM]"
sweep --job sw4 --apply
[[ "$SWEEP_RC" == 0 ]] || fail "sw4 apply rc=$SWEEP_RC"
[[ ! -e "$JD/builds/final-app.bin" ]] ||
  fail "sw4 final-build uploaded row must be deleted early: $SWEEP_OUT"
[[ -f "$JD/evidence/cap.png" ]] ||
  fail "sw4 evidence must wait for drive_confirmed even under uploaded"
[[ -f "$JD/builds/final-1716.bin" ]] ||
  fail "sw4 mirror_required must wait for drive_confirmed even under uploaded"
have "path=builds/final-app.bin class=final-build bytes=6 action=deleted" ||
  fail "sw4 must report the early delete: $SWEEP_OUT"
have "path=evidence/cap.png class=evidence kept reason=not-confirmed" ||
  fail "sw4 evidence keep must be reported: $SWEEP_OUT"
have "path=builds/final-1716.bin class=final-build kept reason=not-confirmed" ||
  fail "sw4 mirror_required keep must be reported: $SWEEP_OUT"
# Once the dataset is drive_confirmed the same sweep deletes the held rows.
mk_record "$K4" test-host sw4 104 proj "$JD" drive_confirmed "[$RF,$RE,$RM]"
sweep --job sw4 --apply
[[ ! -e "$JD/evidence/cap.png" ]] || fail "sw4 evidence must delete once confirmed"
[[ ! -e "$JD/builds/final-1716.bin" ]] ||
  fail "sw4 mirror_required must delete once confirmed"
echo "PASS sw4-uploaded-hatch"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw5: an unknown local_delete_at refuses the whole sweep =="
reset_case sw5
write_hosts garage_verified
write_policy
mk_ended_job sw5 105 w:p9
mk_task 105 merged proj sw5
JD="$INBOX/sw5"
mkdir -p "$JD/evidence"
printf 'cap\n' >"$JD/evidence/cap.png"
R="$(mk_row evidence/cap.png "$JD/evidence/cap.png")"
mk_record "artifacts/proj/105/sw5" test-host sw5 105 proj "$JD" drive_confirmed "[$R]"
sweep --job sw5 --apply
[[ "$SWEEP_RC" == 2 ]] || fail "sw5 must refuse rc=2 (got $SWEEP_RC): $SWEEP_OUT"
have "local_delete_at" || fail "sw5 refusal must name the key: $SWEEP_OUT"
have "garage_verified" || fail "sw5 refusal must name the value: $SWEEP_OUT"
[[ -f "$JD/evidence/cap.png" ]] || fail "sw5 deleted despite refusal"
doc_body "artifacts/proj/105/sw5" | python3 -c 'import json,sys
assert not (json.load(sys.stdin).get("local_deleted")), "wrote local_deleted"' ||
  fail "sw5 must not write local_deleted"
sweep --job sw5
[[ "$SWEEP_RC" == 2 ]] || fail "sw5 dry-run must refuse too (got $SWEEP_RC)"
[[ -f "$JD/evidence/cap.png" ]] || fail "sw5 dry-run deleted despite refusal"
echo "PASS sw5-unknown-local-delete-at-refused"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw6: a failed hk write keeps the file in place =="
reset_case sw6
write_hosts
write_policy
mk_ended_job sw6 106 w:p9
mk_task 106 merged proj sw6
JD="$INBOX/sw6"
mkdir -p "$JD/evidence"
printf 'cap\n' >"$JD/evidence/cap.png"
R="$(mk_row evidence/cap.png "$JD/evidence/cap.png")"
mk_record "artifacts/proj/106/sw6" test-host sw6 106 proj "$JD" drive_confirmed "[$R]"
sweep HK_DOC_FAIL=put --job sw6 --apply
[[ -f "$JD/evidence/cap.png" ]] || fail "sw6 deleted after a failed hk write"
have "kept reason=record-write-failed" ||
  fail "sw6 must report record-write-failed: $SWEEP_OUT"
echo "PASS sw6-failed-write-keeps"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw7: the selection gates skip open tasks, live panes, live sentinels and running jobs =="
reset_case sw7
write_hosts
write_policy

# an open task: the job ended but the task is still claimed
mk_ended_job sw7-open 171 -
mk_task 171 claimed proj sw7-open
mkdir -p "$INBOX/sw7-open/evidence"; printf 'x\n' >"$INBOX/sw7-open/evidence/c.png"
# a live pane: ended, but herdr still sees the agent
mk_ended_job sw7-pane 172 w:p9
mk_task 172 merged proj sw7-pane
mkdir -p "$INBOX/sw7-pane/evidence"; printf 'x\n' >"$INBOX/sw7-pane/evidence/c.png"
# not ended at all
arb claim --job sw7-live --lane lane-a --agent-label lbl --t T1 --task-id 173 >/dev/null
arb event --job sw7-live --kind job.spawned \
  --payload-json '{"owner_lane":"lane-a","label":"lbl","pane_id":"w:p9"}' >/dev/null
mk_task 173 merged proj sw7-live
mkdir -p "$INBOX/sw7-live/evidence"; printf 'x\n' >"$INBOX/sw7-live/evidence/c.png"
# live sentinel: a real `wrk sentinel` that started while the job was live
# and has not polled since the end record landed (an ended job's sentinel
# exits itself on its next poll, so the race window is a sleeping watcher)
OLD5="$(python3 -c 'import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=5)).replace(microsecond=0).isoformat())')"
OLD4="$(python3 -c 'import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=4)).replace(microsecond=0).isoformat())')"
ARBITER_TEST_NOW="$OLD5" \
  arb claim --job sw7-sen --lane lane-a --agent-label lbl --t T1 --task-id 174 >/dev/null
ARBITER_TEST_NOW="$OLD5" \
  arb event --job sw7-sen --kind job.spawned \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null
mk_task 174 merged proj sw7-sen
mkdir -p "$INBOX/sw7-sen/evidence"; printf 'x\n' >"$INBOX/sw7-sen/evidence/c.png"
printf 'idle\n' >"$GET_SEQ"
env ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" HK_STATE="$HK_DB" \
  HANDOFFKEEP_BIN="$HK" HERDR_BIN="$HERDR" WRK_HOSTS_CONFIG="$HOSTS" \
  WRK_FIXTURE_LOG="$HERDR_LOG" WRK_FIXTURE_GET_SEQUENCE="$GET_SEQ" \
  HOME="$TMPHOME" TMPDIR="$TMP" WRK_COMPLETION_INTERVAL_S=3600 \
  "$WRK" sentinel sw7-sen lane-a lbl w:p9 report >/dev/null 2>&1 &
SEN_PID=$!
own "$SEN_PID"
for _ in $(seq 1 100); do
  kill -0 "$SEN_PID" 2>/dev/null || break
  # -s, not -f: the log file is created before the first poll. A non-empty
  # log proves that poll wrote its line.
  [[ -s "$INBOX/sw7-sen/completion-sentinel.log" ]] && break
  sleep 0.3
done
kill -0 "$SEN_PID" 2>/dev/null ||
  fail "sw7 sentinel exited before the sweep ran"
[[ -s "$INBOX/sw7-sen/completion-sentinel.log" ]] ||
  fail "sw7 sentinel did not poll before the sweep ran"
# The poll writes the log line, then checks sentinel_job_ended in the same
# pass. Give that check time to finish before the end record lands, so the
# sentinel is in its 3600s interval sleep when the sweep looks for it.
sleep 1
ARBITER_TEST_NOW="$OLD4" \
  arb event --job sw7-sen --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null
# inside the 3d sweep age: ended just now (mk_ended_job uses now for
# claim/spawned and an old completed stamp — here a fresh end record)
arb claim --job sw7-fresh --lane lane-a --agent-label lbl --t T1 --task-id 175 >/dev/null
arb event --job sw7-fresh --kind job.completed \
  --payload-json '{"owner_lane":"lane-a","label":"lbl"}' >/dev/null
mk_task 175 merged proj sw7-fresh
mkdir -p "$INBOX/sw7-fresh/evidence"; printf 'x\n' >"$INBOX/sw7-fresh/evidence/c.png"

printf 'idle\n' >"$GET_SEQ"   # only sw7-pane probes; the pane reads alive
sweep
[[ "$SWEEP_RC" == 0 ]] || fail "sw7 sweep rc=$SWEEP_RC: $SWEEP_OUT"
have "job=sw7-open skip reason=task-claimed" ||
  fail "sw7 open task must skip: $SWEEP_OUT"
have "job=sw7-pane skip reason=pane-alive" ||
  fail "sw7 live pane must skip: $SWEEP_OUT"
have "job=sw7-live skip reason=not-ended" ||
  fail "sw7 unended job must skip: $SWEEP_OUT"
have "job=sw7-sen skip reason=live-sentinel" ||
  fail "sw7 live sentinel must skip: $SWEEP_OUT"
have "job=sw7-fresh skip reason=inside-age" ||
  fail "sw7 fresh-ended job must skip: $SWEEP_OUT"
for j in sw7-open sw7-pane sw7-live sw7-sen sw7-fresh; do
  [[ -f "$INBOX/$j/evidence/c.png" ]] || fail "sw7 deleted under a gate: $j"
done
printf 'not-found\n' >"$GET_SEQ"
kill "$SEN_PID" 2>/dev/null || true
echo "PASS sw7-selection-gates"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw8: the sweep never calls rclone, fpbulk or fileproviderctl =="
reset_case sw8
write_hosts
write_policy
mk_ended_job sw8 108 w:p9
mk_task 108 merged proj sw8
JD="$INBOX/sw8"
mkdir -p "$JD/evidence"
printf 'cap\n' >"$JD/evidence/cap.png"
R="$(mk_row evidence/cap.png "$JD/evidence/cap.png")"
mk_record "artifacts/proj/108/sw8" test-host sw8 108 proj "$JD" drive_confirmed "[$R]"
TRAP_BIN="$TMP/trap-bin-$CASE_SEQ"; CALLED="$TMP/called-$CASE_SEQ"
mkdir -p "$TRAP_BIN"; : >"$CALLED"
for tool in rclone fpbulk fileproviderctl; do
  printf '#!/usr/bin/env bash\necho "%s" >>"%s"\nexit 1\n' "$tool" "$CALLED" \
    >"$TRAP_BIN/$tool"
  chmod +x "$TRAP_BIN/$tool"
done
sweep PATH="$TRAP_BIN:/usr/bin:/bin" --job sw8 --apply
[[ ! -s "$CALLED" ]] ||
  fail "sw8 called an upload tool: $(cat "$CALLED")"
[[ ! -e "$JD/evidence/cap.png" ]] || fail "sw8 file was not deleted"
echo "PASS sw8-no-upload-tools"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw9: --job limits the sweep; default age is 3d =="
reset_case sw9
write_hosts
write_policy
for j in sw9a sw9b; do
  mk_ended_job "$j" 109 w:p9
  mk_task 109 merged proj "$j"
  mkdir -p "$INBOX/$j/evidence"; printf 'cap\n' >"$INBOX/$j/evidence/cap.png"
  R="$(mk_row evidence/cap.png "$INBOX/$j/evidence/cap.png")"
  mk_record "artifacts/proj/109/$j" test-host "$j" 109 proj "$INBOX/$j" \
    drive_confirmed "[$R]"
done
sweep --job sw9a --apply
[[ ! -e "$INBOX/sw9a/evidence/cap.png" ]] || fail "sw9a must be deleted"
[[ -f "$INBOX/sw9b/evidence/cap.png" ]] || fail "sw9b deleted under --job sw9a"
have_not "job=sw9b" || fail "sw9b must not appear under --job sw9a: $SWEEP_OUT"
sweep --apply
[[ ! -e "$INBOX/sw9b/evidence/cap.png" ]] || fail "sw9b must delete unscoped"
echo "PASS sw9-job-filter"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw10: record edge cases skip or keep, never guess =="
reset_case sw10
write_hosts
write_policy

# host-mismatch: the record names another host
mk_ended_job sw10-h 110 w:p9
mk_task 110 merged proj sw10-h
mkdir -p "$INBOX/sw10-h/evidence"; printf 'x\n' >"$INBOX/sw10-h/evidence/c.png"
R="$(mk_row evidence/c.png "$INBOX/sw10-h/evidence/c.png")"
mk_record "artifacts/proj/110/sw10-h" other-host sw10-h 110 proj \
  "$INBOX/sw10-h" drive_confirmed "[$R]"
# bad record: body is not the v2 schema
mk_ended_job sw10-b 110 w:p9
mk_task 110 merged proj sw10-b
mkdir -p "$INBOX/sw10-b/evidence"; printf 'x\n' >"$INBOX/sw10-b/evidence/c.png"
python3 - "$HK_DB" <<'PY'
import hashlib, json, sys
db = json.load(open(sys.argv[1]))
body = '{"schema":"fleet.artifact.v9","job_id":"sw10-b"}'
docs = db.setdefault("docs", {})
docs["artifacts/proj/110/sw10-b"] = {
    "id": len(docs) + 1, "key": "artifacts/proj/110/sw10-b", "kind": "note",
    "session": "", "job": "sw10-b", "body": body,
    "sha256": hashlib.sha256(body.encode()).hexdigest(),
    "created_by": "fixture", "created_at": "2026-01-01T00:00:00+00:00",
    "updated_at": "2026-01-01T00:00:00+00:00"}
json.dump(db, open(sys.argv[1], "w"))
PY
# source outside every named root
mk_ended_job sw10-o 110 w:p9
mk_task 110 merged proj sw10-o
OUTSIDE="$WORK/elsewhere/dataset"; mkdir -p "$OUTSIDE"
printf 'x\n' >"$OUTSIDE/c.png"
R="$(mk_row c.png "$OUTSIDE/c.png")"
mk_record "artifacts/proj/110/sw10-o" test-host sw10-o 110 proj \
  "$OUTSIDE" drive_confirmed "[$R]"
# source missing on disk
mk_ended_job sw10-m 110 w:p9
mk_task 110 merged proj sw10-m
mk_record "artifacts/proj/110/sw10-m" test-host sw10-m 110 proj \
  "$INBOX/sw10-m/gone" drive_confirmed "[$R]"
# a manifest row without sha256 (desk-interim path+size only) keeps the file
mk_ended_job sw10-n 110 w:p9
mk_task 110 merged proj sw10-n
JD="$INBOX/sw10-n"; mkdir -p "$JD/evidence"; printf 'x\n' >"$JD/evidence/c.png"
python3 - "$JD" <<'PY' >"$TMP/row-nosha.json"
import json, sys
print(json.dumps({"path": "evidence/c.png",
                  "bytes": 2, "size": 2}))
PY
mk_record "artifacts/proj/110/sw10-n" test-host sw10-n 110 proj \
  "$JD" drive_confirmed "[$(cat "$TMP/row-nosha.json")]"
# a desk-interim row spelling bytes as size still matches
mk_ended_job sw10-s 110 w:p9
mk_task 110 merged proj sw10-s
JD="$INBOX/sw10-s"; mkdir -p "$JD/evidence"; printf 'y\n' >"$JD/evidence/c.png"
python3 - "$JD/evidence/c.png" <<'PY' >"$TMP/row-size.json"
import hashlib, json, sys
data = open(sys.argv[1], "rb").read()
print(json.dumps({"path": "evidence/c.png", "size": len(data),
                  "sha256": hashlib.sha256(data).hexdigest()}))
PY
mk_record "artifacts/proj/110/sw10-s" test-host sw10-s 110 proj \
  "$JD" drive_confirmed "[$(cat "$TMP/row-size.json")]"
# no record at all
mk_ended_job sw10-z 110 w:p9
mk_task 110 merged proj sw10-z
mkdir -p "$INBOX/sw10-z/evidence"; printf 'x\n' >"$INBOX/sw10-z/evidence/c.png"

sweep --apply
have "job=sw10-h dataset=artifacts/proj/110/sw10-h skip reason=host-mismatch" ||
  fail "sw10 host-mismatch: $SWEEP_OUT"
have "job=sw10-b dataset=artifacts/proj/110/sw10-b skip reason=bad-record" ||
  fail "sw10 bad-record: $SWEEP_OUT"
have "job=sw10-o dataset=artifacts/proj/110/sw10-o skip reason=source-outside-roots" ||
  fail "sw10 source-outside-roots: $SWEEP_OUT"
have "job=sw10-m dataset=artifacts/proj/110/sw10-m skip reason=source-missing" ||
  fail "sw10 source-missing: $SWEEP_OUT"
have "path=evidence/c.png class=evidence kept reason=manifest-no-sha256" ||
  fail "sw10 manifest-no-sha256: $SWEEP_OUT"
have "job=sw10-z skip reason=no-record" ||
  fail "sw10 no-record: $SWEEP_OUT"
[[ -f "$INBOX/sw10-h/evidence/c.png" ]] || fail "sw10-h file deleted"
[[ -f "$INBOX/sw10-b/evidence/c.png" ]] || fail "sw10-b file deleted"
[[ -f "$OUTSIDE/c.png" ]] || fail "sw10-o file deleted"
[[ -f "$INBOX/sw10-n/evidence/c.png" ]] || fail "sw10-n file deleted"
[[ -f "$INBOX/sw10-z/evidence/c.png" ]] || fail "sw10-z file deleted"
[[ ! -e "$INBOX/sw10-s/evidence/c.png" ]] ||
  fail "sw10 size-spelled row must still delete: $SWEEP_OUT"
echo "PASS sw10-record-edge-cases"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw11: symlinks are never deleted =="
reset_case sw11
write_hosts
write_policy
mk_ended_job sw11 111 w:p9
mk_task 111 merged proj sw11
JD="$INBOX/sw11"
mkdir -p "$JD/evidence" "$WORK/outside"
printf 'target\n' >"$WORK/outside/real.bin"
ln -s "$WORK/outside/real.bin" "$JD/evidence/link.png"
printf 'cap\n' >"$JD/evidence/cap.png"
RL="$(mk_row evidence/link.png "$WORK/outside/real.bin")"
RC="$(mk_row evidence/cap.png "$JD/evidence/cap.png")"
mk_record "artifacts/proj/111/sw11" test-host sw11 111 proj "$JD" \
  drive_confirmed "[$RL,$RC]"
sweep --job sw11 --apply
[[ -L "$JD/evidence/link.png" ]] || fail "sw11 deleted a symlink"
[[ -f "$WORK/outside/real.bin" ]] || fail "sw11 followed a symlink out of the dataset"
[[ ! -e "$JD/evidence/cap.png" ]] || fail "sw11 real file not deleted"
echo "PASS sw11-symlink-safe"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw12: a non-job dataset under another named root sweeps too =="
reset_case sw12
write_hosts
write_policy
mk_ended_job sw12 112 w:p9
mk_task 112 merged proj sw12
SRC="$WORK/webqa-runner/jobs/webqa-77"
mkdir -p "$SRC/evidence"
printf 'shot\n' >"$SRC/evidence/shot.png"
R="$(mk_row evidence/shot.png "$SRC/evidence/shot.png")"
mk_record "artifacts/proj/112/sw12" test-host sw12 112 proj "$SRC" \
  drive_confirmed "[$R]"
sweep --job sw12 --apply
[[ ! -e "$SRC/evidence/shot.png" ]] ||
  fail "sw12 webqa dataset file not deleted: $SWEEP_OUT"
have "path=evidence/shot.png class=evidence bytes=5 action=deleted" ||
  fail "sw12 must report the delete: $SWEEP_OUT"
echo "PASS sw12-named-root-dataset"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw13: usage and help =="
"$WRK" artifacts sweep --help | grep -q "local_delete_at" ||
  fail "help must document local_delete_at"
"$WRK" artifacts sweep --help | grep -q "never" ||
  fail "help must say the sweep never uploads"
"$WRK" artifacts sweep --help | grep -q "uploads, copies" ||
  fail "help must say the sweep never uploads"
"$WRK" artifacts sweep --help | grep -q "drive_confirmed" ||
  fail "help must document drive_confirmed"
"$WRK" artifacts sweep --help | grep -q "uploaded" ||
  fail "help must document the uploaded hatch"
"$WRK" --help | grep -q "artifacts" || fail "top usage must name artifacts"
rc=0; "$WRK" artifacts bogus >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "unknown artifacts command must exit 2 (got $rc)"
echo "PASS sw13-help"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw14: dry-run is the default mode =="
reset_case sw14
write_hosts
write_policy
mk_ended_job sw14 114 w:p9
mk_task 114 merged proj sw14
JD="$INBOX/sw14"
mkdir -p "$JD/evidence"
printf 'cap\n' >"$JD/evidence/cap.png"
R="$(mk_row evidence/cap.png "$JD/evidence/cap.png")"
K14="artifacts/proj/114/sw14"
mk_record "$K14" test-host sw14 114 proj "$JD" drive_confirmed "[$R]"
sweep --job sw14
[[ "$SWEEP_RC" == 0 ]] || fail "sw14 rc=$SWEEP_RC"
have "path=evidence/cap.png class=evidence bytes=4 action=would-delete" ||
  fail "sw14 must print would-delete: $SWEEP_OUT"
[[ -f "$JD/evidence/cap.png" ]] || fail "sw14 default mode deleted a file"
doc_body "$K14" | python3 -c 'import json,sys
assert not (json.load(sys.stdin).get("local_deleted")), "wrote local_deleted"' ||
  fail "sw14 default mode wrote the record"
echo "PASS sw14-dry-run-default"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw15: object roots, host-scoped and job-scoped rows, policy mirror_required =="
reset_case sw15
write_hosts uploaded
cat >"$POLICY" <<'JSON'
{
 "schema": "fleet.artifact-policy.v1",
 "roots": {
  "jobs": {"path": "herdr-inbox/jobs", "kind": "per-job"},
  "webqa": {"path": "webqa-runner/jobs", "kind": "per-job"}
 },
 "rows": [
  {"class": "record-text", "root": "jobs", "glob": "events"},
  {"class": "record-text", "root": "jobs", "glob": "report*.md"},
  {"class": "final-build", "root": "jobs", "glob": "otherhost/**", "host": "other-host"},
  {"class": "final-build", "root": "jobs", "glob": "jobonly/**", "job": "sw15b"},
  {"class": "final-build", "root": "jobs", "glob": "builds/mirror*", "mirror_required": true},
  {"class": "final-build", "root": "jobs", "glob": "builds/**"},
  {"class": "evidence", "root": "jobs", "glob": "evidence/**"}
 ]
}
JSON
mk_ended_job sw15 115 w:p9
mk_task 115 merged proj sw15
JD="$INBOX/sw15"
mkdir -p "$JD/builds" "$JD/otherhost" "$JD/jobonly"
printf 'ok\n' >"$JD/builds/ok.bin"
printf 'mirror\n' >"$JD/builds/mirror.bin"
printf 'other\n' >"$JD/otherhost/only.bin"
printf 'jobonly\n' >"$JD/jobonly/only.bin"
RO="$(mk_row builds/ok.bin "$JD/builds/ok.bin" '{"uploaded_at":"t"}')"
RM="$(mk_row builds/mirror.bin "$JD/builds/mirror.bin" '{"uploaded_at":"t"}')"
RX="$(mk_row otherhost/only.bin "$JD/otherhost/only.bin" '{"uploaded_at":"t"}')"
RJ="$(mk_row jobonly/only.bin "$JD/jobonly/only.bin" '{"uploaded_at":"t"}')"
mk_record "artifacts/proj/115/sw15" test-host sw15 115 proj "$JD" uploading \
  "[$RO,$RM,$RX,$RJ]"
sweep --job sw15 --apply
[[ "$SWEEP_RC" == 0 ]] || fail "sw15 apply rc=$SWEEP_RC"
[[ ! -e "$JD/builds/ok.bin" ]] || fail "sw15 object-root final-build not deleted"
[[ -f "$JD/builds/mirror.bin" ]] || fail "sw15 policy mirror_required deleted early"
[[ -f "$JD/otherhost/only.bin" ]] || fail "sw15 other-host row applied here"
[[ -f "$JD/jobonly/only.bin" ]] || fail "sw15 other-job row applied here"
have "path=builds/mirror.bin class=final-build kept reason=not-confirmed" ||
  fail "sw15 mirror keep must be reported: $SWEEP_OUT"
mk_ended_job sw15b 116 w:p9
mk_task 116 merged proj sw15b
JB="$INBOX/sw15b"
mkdir -p "$JB/jobonly"
printf 'jobonly\n' >"$JB/jobonly/only.bin"
RB="$(mk_row jobonly/only.bin "$JB/jobonly/only.bin" '{"uploaded_at":"t"}')"
mk_record "artifacts/proj/116/sw15b" test-host sw15b 116 proj "$JB" uploading "[$RB]"
sweep --job sw15b --apply
[[ ! -e "$JB/jobonly/only.bin" ]] || fail "sw15b job-scoped row not applied"
echo "PASS sw15-policy-scoping"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw16: a file changed during the record write is kept and unrecorded =="
reset_case sw16
write_hosts
write_policy
mk_ended_job sw16 117 w:p9
mk_task 117 merged proj sw16
JD="$INBOX/sw16"
mkdir -p "$JD/evidence"
printf 'original\n' >"$JD/evidence/x.png"
R="$(mk_row evidence/x.png "$JD/evidence/x.png")"
K16="artifacts/proj/117/sw16"
mk_record "$K16" test-host sw16 117 proj "$JD" drive_confirmed "[$R]"
# The wrapper appends to the planned file during doc put, after the plan-time
# hash and before the delete-time check.
WRAP="$TMP/toctou-hk"
cat >"$WRAP" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "doc put" ]]; then
  printf 'changed-after-hash\n' >> "$WRK_ARTIFACTS_TOCTOU_TARGET"
fi
exec "$WRK_ARTIFACTS_TOCTOU_HK" "$@"
SH
chmod +x "$WRAP"
sweep HANDOFFKEEP_BIN="$WRAP" \
  WRK_ARTIFACTS_TOCTOU_TARGET="$JD/evidence/x.png" \
  WRK_ARTIFACTS_TOCTOU_HK="$HK" --job sw16 --apply
[[ "$SWEEP_RC" == 0 ]] || fail "sw16 apply rc=$SWEEP_RC: $SWEEP_OUT"
[[ -f "$JD/evidence/x.png" ]] || fail "sw16 deleted a file changed during the put"
have "path=evidence/x.png class=evidence kept reason=changed-before-delete" ||
  fail "sw16 must report changed-before-delete: $SWEEP_OUT"
doc_body "$K16" | python3 -c 'import json,sys
rows = json.load(sys.stdin).get("local_deleted") or []
assert not rows, rows' ||
  fail "sw16 recorded a deleted row for a kept file"
echo "PASS sw16-toctou-kept"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw17: a record cannot point its source at a sibling job dir =="
reset_case sw17
write_hosts
write_policy
mk_ended_job sw17 211 w:p9
mk_task 211 merged proj sw17
# The sibling job is live (its task is still claimed) and holds the victim.
mk_ended_job sw17b 212 w:p9
mk_task 212 claimed proj sw17b
B="$INBOX/sw17b"
mkdir -p "$B/evidence"
printf 'victim\n' >"$B/evidence/v.png"
R="$(mk_row evidence/v.png "$B/evidence/v.png")"
# The record sits under sw17's key but names sw17b's directory as its source.
mk_record "artifacts/proj/211/sw17" test-host sw17 211 proj "$B" drive_confirmed "[$R]"
sweep --job sw17 --apply
[[ "$SWEEP_RC" == 0 ]] || fail "sw17 rc=$SWEEP_RC: $SWEEP_OUT"
[[ -f "$B/evidence/v.png" ]] || fail "sw17 deleted a sibling job's file"
have "skip reason=source-other-job" ||
  fail "sw17 must skip source-other-job: $SWEEP_OUT"
echo "PASS sw17-source-other-job"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw18: the newest claim is chosen by event time, not file name =="
reset_case sw18
write_hosts
write_policy
mk_ended_job sw18 201 w:p9
mk_task 201 merged proj sw18
mk_task 202 claimed proj sw18
# A higher-numbered claim with an older timestamp and a higher seq: name order
# and seq-only order both pick task 202; event time picks task 201.
OLD6="$(python3 -c 'import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=6)).replace(microsecond=0).isoformat())')"
cat >"$INBOX/sw18/events/00010-job.claim.json" <<EOF
{"created_at":"$OLD6","job_id":"sw18","kind":"job.claim","payload":{"task_id":202,"owner_lane":"lane-a","agent_label":"lbl"},"seq":99}
EOF
JD="$INBOX/sw18"
mkdir -p "$JD/evidence"
printf 'claim-order\n' >"$JD/evidence/c.png"
R="$(mk_row evidence/c.png "$JD/evidence/c.png")"
mk_record "artifacts/proj/201/sw18" test-host sw18 201 proj "$JD" drive_confirmed "[$R]"
sweep --job sw18 --apply
[[ "$SWEEP_RC" == 0 ]] || fail "sw18 rc=$SWEEP_RC: $SWEEP_OUT"
[[ ! -e "$JD/evidence/c.png" ]] ||
  fail "sw18 picked the higher-named older claim: $SWEEP_OUT"
echo "PASS sw18-claim-event-time"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw19: a non-JSON doc get is a record-fetch failure, not a traceback =="
reset_case sw19
write_hosts
write_policy
mk_ended_job sw19 221 w:p9
mk_task 221 merged proj sw19
JD="$INBOX/sw19"
mkdir -p "$JD/evidence"
printf 'x\n' >"$JD/evidence/x.png"
R="$(mk_row evidence/x.png "$JD/evidence/x.png")"
mk_record "artifacts/proj/221/sw19" test-host sw19 221 proj "$JD" drive_confirmed "[$R]"
WRAP="$TMP/badjson-hk"
cat >"$WRAP" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "doc get" ]]; then
  printf 'not-json garbage\n'
  exit 0
fi
exec "$WRK_ARTIFACTS_BADJSON_HK" "$@"
SH
chmod +x "$WRAP"
sweep HANDOFFKEEP_BIN="$WRAP" WRK_ARTIFACTS_BADJSON_HK="$HK" --job sw19 --apply
[[ "$SWEEP_RC" == 0 ]] || fail "sw19 rc=$SWEEP_RC: $SWEEP_OUT"
have "skip reason=record-fetch-failed" ||
  fail "sw19 must report record-fetch-failed: $SWEEP_OUT"
have_not "Traceback" || fail "sw19 leaked a traceback: $SWEEP_OUT"
[[ -f "$JD/evidence/x.png" ]] || fail "sw19 deleted without a readable record"
echo "PASS sw19-bad-doc-json"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw20: a JSON doc get with a non-string body is a fetch failure =="
reset_case sw20
write_hosts
write_policy
mk_ended_job sw20 231 w:p9
mk_task 231 merged proj sw20
JD="$INBOX/sw20"
mkdir -p "$JD/evidence"
printf 'x\n' >"$JD/evidence/z.png"
R="$(mk_row evidence/z.png "$JD/evidence/z.png")"
mk_record "artifacts/proj/231/sw20" test-host sw20 231 proj "$JD" drive_confirmed "[$R]"
WRAP="$TMP/badbody-hk"
cat >"$WRAP" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "doc get" ]]; then
  printf '{"key":"%s","kind":"note","body":{"schema":"fleet.artifact.v2"}}\n' "${3:-}"
  exit 0
fi
exec "$WRK_ARTIFACTS_BADBODY_HK" "$@"
SH
chmod +x "$WRAP"
sweep HANDOFFKEEP_BIN="$WRAP" WRK_ARTIFACTS_BADBODY_HK="$HK" --job sw20 --apply
[[ "$SWEEP_RC" == 0 ]] || fail "sw20 rc=$SWEEP_RC: $SWEEP_OUT"
have "skip reason=record-fetch-failed" ||
  fail "sw20 must report record-fetch-failed: $SWEEP_OUT"
have_not "Traceback" || fail "sw20 leaked a traceback: $SWEEP_OUT"
[[ -f "$JD/evidence/z.png" ]] || fail "sw20 deleted without a readable record"
echo "PASS sw20-bad-body-type"

# ─────────────────────────────────────────────────────────────────────────────
echo "== sw21: a JSON doc get with no body is a fetch failure =="
reset_case sw21
write_hosts
write_policy
mk_ended_job sw21 232 w:p9
mk_task 232 merged proj sw21
JD="$INBOX/sw21"
mkdir -p "$JD/evidence"
printf 'x\n' >"$JD/evidence/z.png"
R="$(mk_row evidence/z.png "$JD/evidence/z.png")"
mk_record "artifacts/proj/232/sw21" test-host sw21 232 proj "$JD" drive_confirmed "[$R]"
WRAP="$TMP/nobody-hk"
cat >"$WRAP" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "doc get" ]]; then
  printf '{"key":"%s","kind":"note"}\n' "${3:-}"
  exit 0
fi
exec "$WRK_ARTIFACTS_NOBODY_HK" "$@"
SH
chmod +x "$WRAP"
sweep HANDOFFKEEP_BIN="$WRAP" WRK_ARTIFACTS_NOBODY_HK="$HK" --job sw21 --apply
[[ "$SWEEP_RC" == 0 ]] || fail "sw21 rc=$SWEEP_RC: $SWEEP_OUT"
have "skip reason=record-fetch-failed" ||
  fail "sw21 must report record-fetch-failed: $SWEEP_OUT"
have_not "Traceback" || fail "sw21 leaked a traceback: $SWEEP_OUT"
[[ -f "$JD/evidence/z.png" ]] || fail "sw21 deleted without a readable record"
echo "PASS sw21-missing-body"

echo "ALL PASS"
