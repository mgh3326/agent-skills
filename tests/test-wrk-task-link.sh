#!/usr/bin/env bash
# #768 contract tests: wrk spawn --task binds the handoffkeep task and the
# arbiter job. Every AC maps to cases below; the MUT section at the end runs
# assertion-RED mutants — sed'd copies of bin/wrk that drop each call site —
# so a silently removed linkage step fails the suite instead of drifting.
set -euo pipefail
# hk 1894: trust-bearing wrk and arbiter commands honour this suite's temp-dir overrides
# (HOME, ARBITER_INBOX_ROOT, XDG_DATA_HOME, HANDOFFKEEP_BIN) only in test mode.
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="$ROOT/bin/arbiter"
PANEWIRE="$ROOT/tests/fixtures/panewire"
HK="$ROOT/tests/fixtures/handoffkeep"
TMP="$(mktemp -d)"
# shellcheck disable=SC1091
. "$ROOT/tests/lib/tmp-writers.sh"
export TW_TMP="$TMP"

cleanup() {
  # kill alone does not suffice — a TERM'd writer can still be mid-append,
  # and refresh_quota_pool's detached supervisor plus its scopefuel child
  # outlive their wrk. A dentry recreated while rm walks the tree makes
  # rm -rf exit "Directory not empty" (CI runs 36283072131/36288704921).
  # tests/lib/tmp-writers.sh reaps each one by an exact verified pid —
  # completion-sentinel.pid / quota-refresh.pid / the WRK_REFRESH_PID_LOG
  # registry / a descendant walk — never a process-table pattern match.
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
# #951: MODEL is parameterizable; a claude-kind MODEL would seed folder trust
# into ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json — fixture HOME keeps the
# operator's real config untouched either way.
export HOME="$TMP/home"
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR

fail() { echo "FAIL: $*" >&2; exit 1; }

# Per-case sandbox roots so claim events and the fixture db never bleed
# between cases. reset_case NAME rotates them.
INBOX="" HK_DB="" HK_LOG="" HERDR_LOG=""
reset_case() {
  INBOX="$TMP/inbox-$1"; HK_DB="$TMP/hk-$1.json"; HK_LOG="$TMP/hk-$1.log"
  HERDR_LOG="$TMP/herdr-$1.log"
  mkdir -p "$INBOX"
  HK_STATE="$HK_DB" "$HK" tasks add --id 1 --title "case task" --lane fixture >/dev/null
}

hk_add() { HK_STATE="$HK_DB" "$HK" tasks add "$@"; }
hk_show() { HK_STATE="$HK_DB" "$HK" tasks show "$1"; }
hk_field() { hk_show "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get(sys.argv[1]) or "")' "$2"; }
hk_refs_job() { hk_show "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("refs") or {}).get("job_id") or "")'; }
claim_count() { if [[ -f "$HK_LOG" ]]; then grep -c '^claim ' "$HK_LOG" || true; else echo 0; fi; }

event_payload() {
  python3 - "$INBOX/$1/events" "$2" <<'PY'
import glob, json, sys
files = sorted(glob.glob(sys.argv[1] + "/*-" + sys.argv[2] + ".json"))
print(json.dumps(json.load(open(files[-1]))["payload"]) if files else "")
PY
}

# spawn_try [-e NAME=VAL ...] -- <wrk args>: run one spawn; rc in SPAWN_RC,
# stderr in $TMP/stderr[-$OUT_TAG].txt. Never aborts on a nonzero exit.
# Case knobs (set as call-prefix vars): SCENARIO, HK_MODE, LABEL, OUT_TAG,
# SKIP_RESET_LOGS (concurrency cases manage truncation themselves).
SPAWN_RC=0
spawn_try() {
  local extra_env=()
  while [[ "${1:-}" == "-e" ]]; do extra_env+=("$2"); shift 2; done
  [[ "${1:-}" == "--" ]] && shift
  local err_file="$TMP/stderr${OUT_TAG:+-$OUT_TAG}.txt"
  local out_file="$TMP/stdout${OUT_TAG:+-$OUT_TAG}.txt"
  if [[ -z "${SKIP_RESET_LOGS:-}" ]]; then : >"$err_file"; : >"$HERDR_LOG"; rm -f "$HK_LOG"; fi
  set +e
  # -u scrubs the ambient session env: a builder/tester run of this suite is
  # itself a spawned job and would otherwise inherit ARBITER_JOB/HK_TASK_ID.
  env -u ARBITER_JOB -u HK_TASK_ID \
    HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    XDG_DATA_HOME="$TMP/xdg-$RANDOM" ARBITER_INBOX_ROOT="$INBOX" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HK_MODE="${HK_MODE:-new}" \
    HK_LOG="$HK_LOG" PANEWIRE_BIN="$PANEWIRE" \
    WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO="${SCENARIO:-spawn}" WRK_FIXTURE_LOG="$HERDR_LOG" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
    WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml" \
    "${extra_env[@]+"${extra_env[@]}"}" \
    "$WRK" spawn -c "$ROOT" -m "${MODEL:-codex-luna}" -p "$PROMPT" -w w \
      -l "${LABEL:-fixture}" --t T1 "$@" </dev/null >"$out_file" 2>"$err_file"
  SPAWN_RC=$?
  set -e
  SCENARIO="" HK_MODE="" LABEL="" OUT_TAG="" SKIP_RESET_LOGS="" MODEL=""
}

expect_rc() {
  local want="$1" what="$2"
  [[ "$SPAWN_RC" -eq "$want" ]] ||
    fail "$what: expected rc $want, got $SPAWN_RC: $(tail -n 3 "$TMP/stderr${OUT_TAG:+-$OUT_TAG}.txt" 2>/dev/null)"
}
expect_grep() { grep -q -- "$1" "$2" || fail "$3 (missing '$1' in $2: $(tail -n 3 "$2" 2>/dev/null))"; }
no_job_dir() { [[ ! -d "$INBOX/$1" ]] || fail "$2 (unexpected job dir $INBOX/$1)"; }
no_pane() { [[ ! -s "$HERDR_LOG" ]] || fail "$1 (unexpected herdr calls: $(cat "$HERDR_LOG"))"; }
no_claim() { [[ "$(claim_count)" -eq 0 ]] || fail "$1 (hk claim ran: $(cat "$HK_LOG"))"; }
rebind_count() { if [[ -f "$HK_LOG" ]]; then grep -c '^rebind ' "$HK_LOG" || true; else echo 0; fi; }
job_event_doc() {
  python3 - "$INBOX/$1/events" "$2" <<'PY'
import glob, json, sys
files = sorted(glob.glob(sys.argv[1] + "/*-" + sys.argv[2] + ".json"))
if files:
    doc = json.load(open(files[-1]))
    print(json.dumps(doc.get("payload", doc)))
else:
    print("")
PY
}
seed_old_job() {
  local job="$1" mode="$2" rounds="${3:-0}" dir="$INBOX/$1/events"
  mkdir -p "$dir"
  printf '%s\n' '{"kind":"job.claim","at":"2026-10-18T00:00:00Z","payload":{"job_id":"'"$job"'","owner_lane":"old-lane","label":"old-label","role":"builder","task_id":1}}' >"$dir/00001-job.claim.json"
  printf '%s\n' '{"kind":"job.spawned","at":"2026-10-18T00:00:01Z","payload":{"job_id":"'"$job"'","pane_id":"w1:p10","tab_id":"w1:t10"}}' >"$dir/00002-job.spawned.json"
  local i
  for ((i=1; i<=rounds; i++)); do
    printf '{"kind":"job.round","job_id":"%s","round":%d,"at":"2026-10-18T00:00:%02dZ"}\n' "$job" "$i" "$((i+1))" >"$dir/$(printf '%05d' "$((i+2))")-job.round.json"
  done
  if [[ "$mode" == ended ]]; then
    printf '%s\n' '{"kind":"job.revoked","at":"2026-10-19T00:00:00Z","payload":{"job_id":"'"$job"'","owner_lane":"old-lane"}}' >"$dir/00020-job.revoked.json"
  elif [[ "$mode" == live ]]; then
    printf '%s\n' '{"kind":"job.revoked","at":"2026-10-18T00:00:02Z","payload":{"job_id":"'"$job"'","owner_lane":"old-lane"}}' >"$dir/00020-job.revoked.json"
    printf '%s\n' '{"kind":"job.spawned","at":"2026-10-19T00:00:00Z","payload":{"job_id":"'"$job"'","pane_id":"w1:p10","tab_id":"w1:t10"}}' >"$dir/00021-job.spawned.json"
  fi
}

seed_old_verdict() {
  local job="$1" path="$2" dir="$INBOX/$1/events"
  python3 - "$job" "$path" "$dir/00010-job.verdict.json" <<'PY'
import json, sys
job, path, output = sys.argv[1:]
with open(output, "w", encoding="utf-8") as handle:
    json.dump({"kind": "job.verdict", "job_id": job, "round": 2,
               "verdict": "PASS", "head": "a" * 40, "path": path,
               "at": "2026-10-18T00:00:04Z"}, handle)
    handle.write("\n")
PY
}

takeover_spawn() {
  MODEL=builder-sol LABEL=new-builder spawn_try -- "$@" --role builder --lane new-lane --parent director-1
}

bash "$ROOT/tests/test-wrk-parent.sh"

echo "== AC1: --task required / usage errors before any side effect =="

# A1: --role builder without --task dies at usage, nothing reached.
reset_case a1
MODEL=builder-sol spawn_try -- --role builder --lane b-lane --parent p-lane --job a1-job
expect_rc 2 "builder without --task"
expect_grep '\--task' "$TMP/stderr.txt" "builder missing-task error must name --task"
no_job_dir a1-job "no job may be created on a usage error"
no_pane "usage error must precede pane creation"
no_claim "usage error must precede any hk write"
echo "PASS a1 builder-without-task dies rc2 before side effects"

# A2: worker without --task/--parent-job and without any inheritance env.
reset_case a2
spawn_try -- --job a2-job
expect_rc 2 "worker without --task"
expect_grep '\--task' "$TMP/stderr.txt" "worker missing-task error must name --task"
no_job_dir a2-job "no job may be created on a usage error"
no_claim "usage error must precede any hk write"
echo "PASS a2 worker-without-task dies rc2 before side effects"

# A3: malformed --task values die as usage errors too.
reset_case a3
spawn_try -- --task abc
expect_rc 2 "--task abc"
no_pane "malformed --task must precede pane creation"
spawn_try -- --task 0
expect_rc 2 "--task 0"
no_pane "malformed --task must precede pane creation"
spawn_try -- --task -3
expect_rc 2 "--task -3"
no_pane "malformed --task must precede pane creation"
echo "PASS a3 malformed --task values die rc2"

# A4: --task and --parent-job are alternatives, never combined.
reset_case a4
spawn_try -- --task 1 --parent-job some-job
expect_rc 2 "--task with --parent-job"
echo "PASS a4 --task/--parent-job mutual exclusion rc2"

# A5: a task that does not exist refuses before side effects.
reset_case a5
spawn_try -- --task 424242 --job a5-job
expect_rc 2 "spawn for nonexistent task"
expect_grep 'not_found\|does not exist' "$TMP/stderr.txt" "error must name the missing task"
no_job_dir a5-job "no job for a nonexistent task"
no_claim "a missing task is never claimed"
echo "PASS a5 nonexistent task dies before side effects"

echo "== AC2: a successful spawn claims + binds in one verified step =="

# B1: happy path — exactly one claim call lands claimed_by + refs.job_id.
reset_case b1
spawn_try -- --task 1 --job b1-ok --keep
expect_rc 0 "owner-mode spawn"
[[ "$(hk_field 1 state)" == claimed ]] || fail "task must be claimed after spawn: $(hk_show 1)"
[[ "$(hk_field 1 claimed_by)" == fixture ]] || fail "claimed_by must be the spawned label"
[[ "$(hk_refs_job 1)" == b1-ok ]] || fail "refs.job_id must be the job id"
[[ "$(claim_count)" -eq 1 ]] || fail "exactly one claim call must land the link (got $(claim_count))"
claim_payload="$(event_payload b1-ok job.claim)"
grep -qE '"task_id" *: *1' <<<"$claim_payload" ||
  fail "job.claim payload must carry task_id: $claim_payload"
link_payload="$(event_payload b1-ok job.task_link)"
grep -qE '"status" *: *"linked"' <<<"$link_payload" ||
  fail "job.task_link event must record the linked outcome: $link_payload"
spawned_payload="$(event_payload b1-ok job.spawned)"
grep -qE '"task_id" *: *1' <<<"$spawned_payload" ||
  fail "job.spawned receipt must carry task_id: $spawned_payload"
grep -q 'HK_TASK_ID=1' "$HERDR_LOG" ||
  fail "spawned pane must carry HK_TASK_ID env: $HERDR_LOG"
echo "PASS b1 successful spawn claims task and binds refs.job_id atomically"

# B2: a spawn that fails after the gates changes nothing in hk — shallow
# (tab-create-fails) and deep (agent-late-foreground) failure depths.
reset_case b2a
SCENARIO=tab-create-fails spawn_try -- --task 1 --job b2a-job
[[ "$SPAWN_RC" -ne 0 ]] || fail "tab-create failure must fail the spawn"
[[ "$(hk_field 1 state)" == backlog ]] || fail "failed spawn must not claim the task"
[[ "$(hk_refs_job 1)" == "" ]] || fail "failed spawn must not bind job_id"
no_claim "a failed spawn never calls hk claim"
echo "PASS b2a tab-create failure leaves hk untouched"

reset_case b2b
SCENARIO=agent-never-foreground spawn_try -- --task 1 --job b2b-job
[[ "$SPAWN_RC" -ne 0 ]] || fail "agent-never-foreground must fail the spawn"
[[ "$(hk_field 1 state)" == backlog ]] || fail "deep failure must not claim the task"
[[ "$(hk_refs_job 1)" == "" ]] || fail "deep failure must not bind job_id"
no_claim "a deep spawn failure never calls hk claim"
echo "PASS b2b post-claim-depth failure leaves hk untouched"

echo "== AC3: fail-closed, idempotent, override only when documented =="

# C1: a task already bound to another job refuses before a pane exists.
reset_case c1
hk_add --id 7 --state claimed --claimed-by other-lane --job-id other-job >/dev/null
spawn_try -- --task 7 --job c1-job
expect_rc 2 "spawn for task bound to another job"
expect_grep 'already bound' "$TMP/stderr.txt" "error must name the existing binding"
no_pane "bound-task refusal precedes pane creation"
no_claim "a bound task is never re-claimed"
no_job_dir c1-job "no job may be created for a bound task"
echo "PASS c1 task bound to another job fails closed before side effects"

# C2: re-spawning the same job+task is idempotent — no second claim.
reset_case c2
hk_add --id 8 --state claimed --claimed-by fixture --job-id c2-job >/dev/null
spawn_try -- --task 8 --job c2-job
expect_rc 0 "idempotent re-spawn of the same job+task"
no_claim "an already-linked task must not be re-claimed"
link_payload="$(event_payload c2-job job.task_link)"
grep -qE '"status" *: *"already_linked"' <<<"$link_payload" ||
  fail "idempotent re-spawn must record already_linked: $link_payload"
echo "PASS c2 same job+task re-spawn is idempotent"

# C3: a claim left by another lane with no job bound is a half-record —
# refuse, do not merge into it.
reset_case c3
hk_add --id 9 --state claimed --claimed-by other-lane >/dev/null
spawn_try -- --task 9 --job c3-job
expect_rc 2 "spawn for a foreign half-claimed task"
expect_grep 'half-record\|claimed by' "$TMP/stderr.txt" "error must name the foreign claim"
no_claim "a foreign claim is never joined"
echo "PASS c3 foreign claimed-but-unbound task fails closed"

# C4: closed/blocked task states refuse.
reset_case c4
hk_add --id 10 --state merged --claimed-by x --job-id old >/dev/null
spawn_try -- --task 10 --job c4-job
expect_rc 2 "spawn for merged task"
expect_grep 'merged' "$TMP/stderr.txt" "error must name the closed state"
no_claim "a closed task is never claimed"
hk_add --id 11 --state needs_decision >/dev/null
spawn_try -- --task 11 --job c4b-job
expect_rc 2 "spawn for needs_decision task"
echo "PASS c4 closed/decision-blocked tasks refuse"

# C5: handoffkeep unreachable refuses the spawn — no job without its link.
reset_case c5
HK_MODE=down spawn_try -- --task 1 --job c5-job
[[ "$SPAWN_RC" -ne 0 ]] || fail "hk-down spawn must be refused"
expect_grep 'hk task precheck\|task link' "$TMP/stderr.txt" "error must name the hk gate"
no_pane "hk-down refusal precedes pane creation"
no_job_dir c5-job "no job may exist without its task link"
echo "PASS c5 hk unreachable refuses before side effects"

# C6: the override is explicit, documented, and recorded in job meta.
reset_case c6
HK_MODE=down spawn_try -- --task 1 --job c6-job --task-hk-bypass
expect_rc 0 "bypassed hk-down spawn must proceed"
claim_payload="$(event_payload c6-job job.claim)"
grep -qE '"task_id" *: *1' <<<"$claim_payload" ||
  fail "bypassed job still records task_id: $claim_payload"
grep -q 'task_link_override' <<<"$claim_payload" ||
  fail "bypassed job must record the override marker: $claim_payload"
link_payload="$(event_payload c6-job job.task_link)"
grep -q 'bypassed' <<<"$link_payload" ||
  fail "bypassed link outcome must be recorded: $link_payload"
[[ "$(hk_field 1 state)" == backlog ]] || fail "bypass never touches hk state"
echo "PASS c6 --task-hk-bypass proceeds with the override recorded"

# C7: override does not excuse a reachable hk that refuses — no silent skip.
reset_case c7
hk_add --id 12 --state claimed --claimed-by other --job-id other >/dev/null
spawn_try -- --task 12 --job c7-job --task-hk-bypass
expect_rc 2 "bypass must not override a real binding conflict"
echo "PASS c7 --task-hk-bypass cannot override a reachable-hk refusal"

# C8: concurrent spawns for one task — exactly one binds it. spawn_try
# always returns 0 (its reset tail), so the backgrounded calls record
# SPAWN_RC to a per-tag file; the winner's refs.job_id is the atomicity proof.
reset_case c8
: >"$HK_LOG"; : >"$HERDR_LOG"
( SKIP_RESET_LOGS=1 OUT_TAG=race-a spawn_try -- --task 1 --job race-a
  echo "$SPAWN_RC" >"$TMP/rc-race-a" ) &
pa=$!
( SKIP_RESET_LOGS=1 OUT_TAG=race-b spawn_try -- --task 1 --job race-b
  echo "$SPAWN_RC" >"$TMP/rc-race-b" ) &
pb=$!
wait "$pa" "$pb"
ra="$(cat "$TMP/rc-race-a")"; rb="$(cat "$TMP/rc-race-b")"
SKIP_RESET_LOGS="" OUT_TAG=""
[[ "$ra" -eq 0 || "$rb" -eq 0 ]] || fail "concurrency: one spawn must succeed (ra=$ra rb=$rb)"
[[ "$ra" -ne 0 || "$rb" -ne 0 ]] || fail "concurrency: both spawns must not bind one task (ra=$ra rb=$rb)"
bound="$(hk_refs_job 1)"
{ [[ "$ra" -eq 0 && "$bound" == race-a ]] || [[ "$rb" -eq 0 && "$bound" == race-b ]]; } ||
  fail "concurrency: bound job must be the winner (bound=$bound ra=$ra rb=$rb)"
[[ "$(hk_field 1 claimed_by)" == fixture ]] || fail "concurrency: task must be claimed"
[[ "$(claim_count)" -ge 1 ]] || fail "concurrency: a claim must have run"
echo "PASS c8 concurrent spawns serialize — exactly one binds the task"

# C9: an arbiter claim that attempted and failed runs under the
# installation-transition contract — the spawn continues unregistered and the
# task still binds through hk, the durable record, with a loud note that the
# job events carry no task_link entry (tester finding: cold-db lock race).
reset_case c9
hk_add --id 1 >/dev/null
cat >"$TMP/arbiter-deny" <<'SH'
#!/bin/sh
[ "$1" = claim ] && exit 3
exit 0
SH
chmod +x "$TMP/arbiter-deny"
spawn_try -e ARBITER_BIN="$TMP/arbiter-deny" -- --task 1 --job c9-job
expect_rc 0 "claim failure stays under the transition contract — spawn continues"
expect_grep 'arbiter claim failed' "$TMP/stderr.txt" "the unevidenced bind must be announced"
[[ "$(hk_refs_job 1)" == c9-job ]] || fail "the hk bind is the durable record: $(hk_show 1)"
[[ "$(hk_field 1 claimed_by)" == fixture ]] || fail "task must be claimed by the spawned label"
echo "PASS c9 claim-failed spawn binds via hk with a loud note"

# C9b: the same claim failure plus a post-pane die must not leak the pane —
# the cleanup trap is armed at spawn start, not only after a quota lease
# (tester finding: the losing pane survived its spawn failure).
reset_case c9b
cat >"$TMP/arbiter-deny2" <<'SH'
#!/bin/sh
[ "$1" = claim ] && exit 3
exit 0
SH
chmod +x "$TMP/arbiter-deny2"
SCENARIO=agent-never-foreground spawn_try -e ARBITER_BIN="$TMP/arbiter-deny2" -- --task 1 --job c9b-job
[[ "$SPAWN_RC" -ne 0 ]] || fail "post-pane failure must still die"
expect_grep 'closed leftover pane' "$TMP/stderr.txt" "the pane must be closed even without a lease"
echo "PASS c9b no-lease post-pane failure still closes the pane"

# C10: --task-hk-bypass must not launder a reachable failure. An hk that was
# reachable at precheck and answers the claim while dropping refs.job_id is
# a half-record, not unavailability — it dies even with the flag (review
# finding: the write-failure bypass covered verify failures).
reset_case c10
HK_MODE=old spawn_try -- --task 1 --task-hk-bypass --job c10-job
[[ "$SPAWN_RC" -ne 0 ]] || fail "verify failure must stay fail-closed despite --task-hk-bypass"
expect_grep 'task link failed\|refs.job_id' "$TMP/stderr.txt" "verify failure must be loud"
echo "PASS c10 bypass cannot launder a reachable verify failure"

echo "== AC1 inheritance: tester/advisory spawns take the parent task =="

# D1: --parent-job inheritance — task id comes from the parent's claim meta.
reset_case d1
mkdir -p "$INBOX/parent-job-1/events"
printf '%s\n' '{"kind":"job.claim","payload":{"task_id":9009,"owner_lane":"b-parent"}}' \
  >"$INBOX/parent-job-1/events/00001-job.claim.json"
hk_add --id 9009 >/dev/null
spawn_try -- --parent-job parent-job-1 --report "$INBOX/parent-job-1/verdict.md" --job d1-tester
expect_rc 0 "tester spawn inherits via --parent-job"
claim_payload="$(event_payload d1-tester job.claim)"
grep -qE '"task_id" *: *9009' <<<"$claim_payload" ||
  fail "inherited spawn must carry the parent task_id: $claim_payload"
grep -qE '"task_inherited_from" *: *"parent-job-1"' <<<"$claim_payload" ||
  fail "inherited spawn must record the parent job: $claim_payload"
no_claim "an inheriting spawn never claims the parent task"
[[ "$(hk_refs_job 9009)" == "" ]] || fail "inheriting spawn must not bind refs.job_id"
link_payload="$(event_payload d1-tester job.task_link)"
grep -qE '"status" *: *"inherited"' <<<"$link_payload" ||
  fail "inherited link outcome must be recorded: $link_payload"
echo "PASS d1 --parent-job inherits task_id without claiming"

# D2: HK_TASK_ID env — the propagated pane env inherits without --parent-job.
reset_case d2
hk_add --id 9010 >/dev/null
spawn_try -e HK_TASK_ID=9010 -- --job d2-worker
expect_rc 0 "worker spawn inherits via HK_TASK_ID env"
claim_payload="$(event_payload d2-worker job.claim)"
grep -qE '"task_id" *: *9010' <<<"$claim_payload" ||
  fail "env-inherited spawn must carry the env task_id: $claim_payload"
no_claim "env inheritance never claims"
echo "PASS d2 HK_TASK_ID env inheritance"

# D3: ARBITER_JOB env — a spawn from inside a registered pane inherits the
# calling job's task through the local claim record.
reset_case d3
mkdir -p "$INBOX/parent-job-3/events"
printf '%s\n' '{"kind":"job.claim","payload":{"task_id":9011}}' \
  >"$INBOX/parent-job-3/events/00001-job.claim.json"
hk_add --id 9011 >/dev/null
spawn_try -e ARBITER_JOB=parent-job-3 -- --job d3-worker
expect_rc 0 "worker spawn inherits via ARBITER_JOB"
claim_payload="$(event_payload d3-worker job.claim)"
grep -qE '"task_id" *: *9011' <<<"$claim_payload" ||
  fail "ARBITER_JOB-inherited spawn must carry the parent task_id: $claim_payload"
grep -qE '"task_inherited_from" *: *"parent-job-3"' <<<"$claim_payload" ||
  fail "ARBITER_JOB inheritance must name the parent job: $claim_payload"
echo "PASS d3 ARBITER_JOB pane-env inheritance"

# D4: parent claim with no task_id refuses to guess.
reset_case d4
mkdir -p "$INBOX/parent-job-4/events"
printf '%s\n' '{"kind":"job.claim","payload":{"owner_lane":"b-old"}}' \
  >"$INBOX/parent-job-4/events/00001-job.claim.json"
spawn_try -- --parent-job parent-job-4 --report "$INBOX/parent-job-4/verdict.md" --job d4-worker
expect_rc 2 "parent without task_id must not be guessed"
expect_grep 'no task_id\|--task' "$TMP/stderr.txt" "error must direct to --task"
no_job_dir d4-worker "no job for an unresolvable task"
echo "PASS d4 taskless parent job refuses to guess"

# D5: a contradicting env pair refuses rather than guessing.
reset_case d5
mkdir -p "$INBOX/parent-job-5/events"
printf '%s\n' '{"kind":"job.claim","payload":{"task_id":9012,"owner_lane":"b-parent"}}' \
  >"$INBOX/parent-job-5/events/00001-job.claim.json"
hk_add --id 9012 >/dev/null; hk_add --id 9099 >/dev/null
spawn_try -e HK_TASK_ID=9099 -- --parent-job parent-job-5 --report "$INBOX/parent-job-5/verdict.md" --job d5-worker
expect_rc 2 "parent task vs HK_TASK_ID mismatch must refuse"
expect_grep 'refusing to guess' "$TMP/stderr.txt" "mismatch must fail closed"
echo "PASS d5 contradicting task sources refuse"

# D6: a corrupt newest claim/reclaim event refuses — the newest event is
# authoritative and an unreadable one must not fall back to a stale older
# task_id (tester attack surface).
reset_case d6
mkdir -p "$INBOX/parent-job-6/events"
printf '%s\n' '{"kind":"job.claim","payload":{"task_id":9013,"owner_lane":"b-parent"}}' \
  >"$INBOX/parent-job-6/events/00001-job.claim.json"
printf '%s\n' 'not-json{{{' \
  >"$INBOX/parent-job-6/events/00002-job.reclaim.json"
hk_add --id 9013 >/dev/null
spawn_try -- --parent-job parent-job-6 --report "$INBOX/parent-job-6/verdict.md" --job d6-worker
expect_rc 2 "corrupt newest parent event must refuse"
expect_grep 'unreadable' "$TMP/stderr.txt" "corrupt newest must be named"
no_job_dir d6-worker "no job for an unreadable parent event"
echo "PASS d6 corrupt newest parent event refuses"

# D7: a corrupt OLDER event is ignored when a valid newer one is authoritative.
reset_case d7
mkdir -p "$INBOX/parent-job-7/events"
printf '%s\n' 'garbage' >"$INBOX/parent-job-7/events/00001-job.claim.json"
printf '%s\n' '{"kind":"job.reclaim","payload":{"task_id":9014,"owner_lane":"b-parent"}}' \
  >"$INBOX/parent-job-7/events/00002-job.reclaim.json"
hk_add --id 9014 >/dev/null
spawn_try -- --parent-job parent-job-7 --report "$INBOX/parent-job-7/verdict.md" --job d7-worker
expect_rc 0 "a valid newest event wins over a corrupt older one"
claim_payload="$(event_payload d7-worker job.claim)"
grep -qE '"task_id" *: *9014' <<<"$claim_payload" ||
  fail "newest-wins must inherit 9014, not the corrupt older file: $claim_payload"
echo "PASS d7 valid newest event wins over corrupt older"

# D8: a malformed inherited task id is a usage error — never laundered
# through --task-hk-bypass into an hk_unreachable override (tester finding:
# task_id "oops" bypassed as unreachable and spawned rc 0).
reset_case d8
mkdir -p "$INBOX/parent-job-8/events"
printf '%s\n' '{"kind":"job.claim","payload":{"task_id":"oops","owner_lane":"b-parent"}}' \
  >"$INBOX/parent-job-8/events/00001-job.claim.json"
spawn_try -- --parent-job parent-job-8 --report "$INBOX/parent-job-8/verdict.md" --task-hk-bypass --job d8-worker
expect_rc 2 "malformed inherited task id must refuse despite bypass"
expect_grep 'not a positive task id' "$TMP/stderr.txt" "malformed id must be named"
no_job_dir d8-worker "no job for a malformed inherited task"
echo "PASS d8 malformed inherited task id refuses despite bypass"

# D9: an inherited child + hk-down + --task-hk-bypass still never claims —
# the bypass degrades the precheck but the link write stays owner-only
# (review finding: bypassed:* status sent the inherited child into the
# claim branch).
reset_case d9
HK_MODE=down spawn_try -e HK_TASK_ID=7777 -- --task-hk-bypass --job d9-child
expect_rc 0 "inherited child + hk-down + bypass proceeds"
no_claim "an inherited child never claims, even under bypass"
link_payload="$(event_payload d9-child job.task_link)"
grep -qE '"status" *: *"bypassed:' <<<"$link_payload" ||
  fail "bypassed precheck must be recorded in the link event: $link_payload"
echo "PASS d9 inherited child never claims the parent task under bypass"

echo "== AC3 version skew: an old handoffkeep is detected, never trusted =="

# E1: deployed-skew binary — claim parses --job-id but silently drops it. The
# post-claim verify turns the half-record into a loud spawn failure, and the
# pane is cleaned up by the EXIT trap.
reset_case e1
HK_MODE=old spawn_try -- --task 1 --job e1-job
[[ "$SPAWN_RC" -ne 0 ]] || fail "old-hk spawn must fail on the verify, not pass as linked"
expect_grep 'task link failed\|repair' "$TMP/stderr.txt" "skew failure must be loud and repairable"
# the fixture's claim did land claimed_by only — the half-record is real and
# visible rather than silently trusted
[[ "$(hk_field 1 claimed_by)" == fixture ]] || fail "old-mode claim must write claimed_by only"
[[ "$(hk_refs_job 1)" == "" ]] || fail "old-mode claim must drop refs.job_id"
echo "PASS e1 old handoffkeep (drops job_id) fails loudly on the verify"

# E2: an hk so old it cannot parse --job-id at all also fails, not hangs.
reset_case e2
HK_MODE=oldflag spawn_try -- --task 1 --job e2-job
[[ "$SPAWN_RC" -ne 0 ]] || fail "oldflag-hk spawn must fail"
[[ "$(hk_field 1 state)" == backlog ]] || fail "unparseable claim must not half-write"
echo "PASS e2 flag-era handoffkeep fails without a half-record"

# E3: unreadable show output is an undecidable gate, not a silent pass.
reset_case e3
HK_MODE=garbage spawn_try -- --task 1 --job e3-job
[[ "$SPAWN_RC" -ne 0 ]] || fail "garbage show output must refuse"
no_pane "undecidable precheck precedes pane creation"
echo "PASS e3 unreadable hk output fails closed"

echo "== hub forwarding: task options survive spill-over arg rebuild =="

# F1: spillover hub args must forward --task/--parent-job/--task-hk-bypass;
# --job-dup-ok stays refused. Static check on the forwarding case arms.
grep -q -- '--task|--parent-job|--takeover-from)' "$WRK" ||
  fail "spillover hub args must forward task, inheritance and takeover options"
grep -q -- '--task-hk-bypass)' "$WRK" ||
  fail "spillover hub args must forward --task-hk-bypass"
echo "PASS f1 hub arg forwarding covers the task flags"

echo "== AC4: builder takeover rebinds only an ended task owner and carries rounds =="

# G1: a terminal old job is rebound through hk, creates paired audit records,
# inherits round two, and opens round three for the new job.
reset_case g1
hk_add --id 1 --state claimed --claimed-by old-label --job-id old-job >/dev/null
seed_old_job old-job ended 2
seed_old_verdict old-job /work/review/rounds=0/verdict.md
takeover_spawn --task 1 --job new-job --takeover-from old-job
expect_rc 0 "takeover of ended old job"
[[ "$(hk_refs_job 1)" == new-job && "$(hk_field 1 claimed_by)" == new-builder ]] ||
  fail "takeover must bind new job and label: $(hk_show 1)"
[[ "$(rebind_count)" -eq 1 ]] || fail "takeover must issue exactly one hk rebind"
no_claim "takeover must use rebind, never claim"
takeover_doc="$(job_event_doc new-job job.takeover)"
grep -qE '"from_job" *: *"old-job"' <<<"$takeover_doc" || fail "job.takeover must name OLD: $takeover_doc"
grep -qE '"task_id" *: *1' <<<"$takeover_doc" || fail "job.takeover must name the task: $takeover_doc"
grep -qE '"rounds_used" *: *2' <<<"$takeover_doc" || fail "job.takeover must carry two rounds: $takeover_doc"
task_link_payload="$(event_payload new-job job.task_link)"
grep -qE '"status" *: *"takeover"' <<<"$task_link_payload" ||
  fail "takeover must record its task link outcome: $task_link_payload"
! grep -q "unknown status 'takeover'" "$TMP/stderr.txt" ||
  fail "takeover task-link outcome must not be treated as unknown"
handed_doc="$(job_event_doc old-job job.handed_off)"
grep -qE '"to_job" *: *"new-job"' <<<"$handed_doc" || fail "old job must record handoff destination: $handed_doc"
new_head="$(git -C "$ROOT" rev-parse HEAD)"
set +e
env -u ARBITER_JOB -u HK_TASK_ID ARBITER_INBOX_ROOT="$INBOX" ARBITER_BIN="$ARBITER" \
  HANDOFFKEEP_BIN="$HK" HOME="$HOME" XDG_DATA_HOME="$TMP/round-xdg" \
  TMPDIR="$TMP" PANEWIRE_BIN="$PANEWIRE" WRK_NO_SLEEP=1 \
  "$WRK" round open new-job --head "$new_head" --repo "$ROOT" >"$TMP/round-open.out" 2>"$TMP/round-open.err"
ROUND_RC=$?
set -e
[[ "$ROUND_RC" -eq 0 ]] || fail "inherited round count must allow round three: $(cat "$TMP/round-open.err")"
grep -q 'round=3' "$TMP/round-open.out" || fail "new job must open round three: $(cat "$TMP/round-open.out")"
set +e
env -u ARBITER_JOB -u HK_TASK_ID ARBITER_INBOX_ROOT="$INBOX" ARBITER_BIN="$ARBITER" \
  HANDOFFKEEP_BIN="$HK" HOME="$HOME" XDG_DATA_HOME="$TMP/round-xdg" \
  TMPDIR="$TMP" PANEWIRE_BIN="$PANEWIRE" WRK_NO_SLEEP=1 \
  "$WRK" round open new-job --head "$new_head" --repo "$ROOT" >"$TMP/round-cap.out" 2>"$TMP/round-cap.err"
ROUND_RC=$?
set -e
[[ "$ROUND_RC" -eq 78 ]] || fail "fourth round must refuse at task cap three (rc=$ROUND_RC)"
grep -q 'round cap 3 reached' "$TMP/round-cap.err" || fail "round cap refusal must name inherited count"
round_escalate="$(job_event_doc new-job job.escalate)"
grep -qE '"job_id" *: *"new-job"' <<<"$round_escalate" || fail "round-cap escalation must belong to NEW: $round_escalate"

# A tester inheriting from NEW reads the task_id recorded by NEW's arbiter
# claim and does not change the binding.
spawn_try -- --role tester --parent-job new-job --report "$INBOX/new-job/verdict.md" --job new-job-tester
expect_rc 0 "tester inheritance from takeover job"
child_claim="$(event_payload new-job-tester job.claim)"
grep -qE '"task_id" *: *1' <<<"$child_claim" || fail "tester child must inherit NEW task: $child_claim"
grep -qE '"task_inherited_from" *: *"new-job"' <<<"$child_claim" || fail "tester child must name NEW as parent: $child_claim"
no_claim "tester inheritance from NEW must not re-claim the task"
[[ "$(hk_refs_job 1)" == new-job ]] || fail "tester inheritance must preserve NEW's binding"
echo "PASS g1 ended-job takeover rebinds task and carries the round cap"

# G2: a terminal older than the newest revive is live by the shared event
# order. Refuse before any hk write, job directory, or pane.
reset_case g2
hk_add --id 1 --state claimed --claimed-by old-label --job-id old-job >/dev/null
seed_old_job old-job live
takeover_spawn --task 1 --job live-new --takeover-from old-job
expect_rc 2 "takeover of a live old job"
expect_grep 'still live' "$TMP/stderr.txt" "live takeover refusal must name the old job"
no_pane "live old job refusal precedes pane creation"
no_job_dir live-new "live old job refusal precedes a new job record"
no_claim "live old job refusal never calls claim"
[[ "$(rebind_count)" -eq 0 ]] || fail "live old job must not reach hk rebind"
echo "PASS g2 a revive newer than terminal blocks takeover before side effects"

# G3: task conflict or an old server route leaves no pane and no takeover
# event, even though unrelated admission metadata may already exist.
for mode in rejectrebind oldroute; do
  reset_case "g3-$mode"
  hk_add --id 1 --state claimed --claimed-by old-label --job-id old-job >/dev/null
  seed_old_job old-job ended
  HK_MODE="$mode" takeover_spawn --task 1 --job "refused-$mode" --takeover-from old-job
  [[ "$SPAWN_RC" -ne 0 ]] || fail "$mode must refuse takeover"
  no_pane "$mode refusal precedes pane creation"
  no_job_dir "refused-$mode" "$mode refusal precedes local job records"
  [[ "$(hk_refs_job 1)" == old-job ]] || fail "$mode refusal must leave the task bound to OLD"
  [[ -z "$(job_event_doc "refused-$mode" job.takeover)" ]] || fail "$mode refusal must not write job.takeover"
done
echo "PASS g3 hk refusal and old route version never spawn or record takeover"

# G3b: only builder role can enter takeover mode; worker and tester refusals
# precede the handoffkeep write and pane creation.
for role in worker tester; do
  reset_case "g3b-$role"
  hk_add --id 1 --state claimed --claimed-by old-label --job-id old-job >/dev/null
  seed_old_job old-job ended
  spawn_try -- --task 1 --job "refused-role-$role" --takeover-from old-job --role "$role"
  [[ "$SPAWN_RC" -eq 2 ]] || fail "$role takeover must be a usage refusal"
  no_pane "$role takeover refusal precedes pane creation"
  [[ "$(rebind_count)" -eq 0 ]] || fail "$role takeover must not reach hk rebind"
done
echo "PASS g3b only builder role may take over"

# G4: handed-off OLD is a reap candidate only after grace with an idle pane;
# the live NEW job is never listed.
reset_case g4
mkdir -p "$INBOX/old-reap/events" "$INBOX/new-reap/events"
printf '%s\n' '{"kind":"job.claim","at":"2020-01-01T00:00:00Z","payload":{"owner_lane":"old-lane","role":"builder"}}' >"$INBOX/old-reap/events/00001-job.claim.json"
printf '%s\n' '{"kind":"job.spawned","at":"2020-01-01T00:00:01Z","payload":{"pane_id":"w1:p10","tab_id":"w1:t10"}}' >"$INBOX/old-reap/events/00002-job.spawned.json"
printf '%s\n' '{"kind":"job.handed_off","at":"2020-01-01T00:00:02Z","payload":{"to_job":"new-reap"}}' >"$INBOX/old-reap/events/00003-job.handed_off.json"
printf '%s\n' '{"kind":"job.claim","at":"2020-01-01T00:00:00Z","payload":{"owner_lane":"new-lane","role":"builder"}}' >"$INBOX/new-reap/events/00001-job.claim.json"
printf '%s\n' '{"kind":"job.spawned","at":"2020-01-01T00:00:01Z","payload":{"pane_id":"w1:p11","tab_id":"w1:t11"}}' >"$INBOX/new-reap/events/00002-job.spawned.json"
reap_out="$(env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$INBOX" \
  WRK_FIXTURE_SCENARIO=reap WRK_FIXTURE_REAP_TABS=ok \
  HOME="$HOME" XDG_DATA_HOME="$TMP/reap-xdg" TMPDIR="$TMP" \
  "$WRK" reap --grace 1s --include-builders 2>&1)"
grep -q 'would-close job=old-reap pane=w1:p10 tab=w1:t10 status=idle' <<<"$reap_out" ||
  fail "aged idle handed-off OLD must appear in reap dry-run: $reap_out"
! grep -q 'job=new-reap\|job=old-reap.*new-reap' <<<"$reap_out" ||
  fail "reap dry-run must never list live NEW: $reap_out"
echo "PASS g4 handed-off old job is reapable after grace; new job is not"

# G5: two hops. C's rounds_used is every round A consumed plus every round B
# consumed, and C's own open refuses at the cap. Returns 1 on an assertion
# miss so the chain mutant below stays assertion-RED.
case_takeover_chain() {
  G5_SEQ=$(( ${G5_SEQ:-0} + 1 ))
  reset_case "g5-$G5_SEQ"
  hk_add --id 1 --state claimed --claimed-by old-label --job-id job-a >/dev/null
  seed_old_job job-a ended 2
  takeover_spawn --task 1 --job job-b --takeover-from job-a
  [[ "$SPAWN_RC" -eq 0 ]] || { echo "FAIL: A to B takeover rc=$SPAWN_RC" >&2; return 1; }
  local b_takeover
  b_takeover="$(job_event_doc job-b job.takeover)"
  grep -qE '"rounds_used" *: *2' <<<"$b_takeover" ||
    { echo "FAIL: B must inherit A's two rounds: $b_takeover" >&2; return 1; }
  local head rc
  head="$(git -C "$ROOT" rev-parse HEAD)"
  set +e
  env -u ARBITER_JOB -u HK_TASK_ID ARBITER_INBOX_ROOT="$INBOX" ARBITER_BIN="$ARBITER" \
    HANDOFFKEEP_BIN="$HK" HOME="$HOME" XDG_DATA_HOME="$TMP/g5-xdg-$G5_SEQ" \
    TMPDIR="$TMP" PANEWIRE_BIN="$PANEWIRE" WRK_NO_SLEEP=1 \
    "$WRK" round open job-b --head "$head" --repo "$ROOT" >"$TMP/g5-b-open.out" 2>"$TMP/g5-b-open.err"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || { echo "FAIL: B must open a round: $(cat "$TMP/g5-b-open.err")" >&2; return 1; }
  grep -q 'round=3' "$TMP/g5-b-open.out" ||
    { echo "FAIL: B must open round three: $(cat "$TMP/g5-b-open.out")" >&2; return 1; }
  python3 - "$INBOX/job-b/events/90000-job.revoked.json" <<'PY' || return 1
import json, sys
doc = {"kind": "job.revoked", "job_id": "job-b", "owner_lane": "new-lane",
       "outcome": "abandoned", "reason": "fixture end",
       "at": "2099-01-01T00:00:00.000Z"}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(doc, handle)
    handle.write("\n")
PY
  takeover_spawn --task 1 --job job-c --takeover-from job-b
  [[ "$SPAWN_RC" -eq 0 ]] || { echo "FAIL: B to C takeover rc=$SPAWN_RC" >&2; return 1; }
  local c_takeover
  c_takeover="$(job_event_doc job-c job.takeover)"
  grep -qE '"rounds_used" *: *3' <<<"$c_takeover" ||
    { echo "FAIL: C rounds_used must be A's 2 plus B's 1: $c_takeover" >&2; return 1; }
  set +e
  env -u ARBITER_JOB -u HK_TASK_ID ARBITER_INBOX_ROOT="$INBOX" ARBITER_BIN="$ARBITER" \
    HANDOFFKEEP_BIN="$HK" HOME="$HOME" XDG_DATA_HOME="$TMP/g5-xdg-$G5_SEQ" \
    TMPDIR="$TMP" PANEWIRE_BIN="$PANEWIRE" WRK_NO_SLEEP=1 \
    "$WRK" round open job-c --head "$head" --repo "$ROOT" >"$TMP/g5-c-open.out" 2>"$TMP/g5-c-open.err"
  rc=$?
  set -e
  [[ "$rc" -eq 78 ]] ||
    { echo "FAIL: C must refuse at the cap (rc=$rc): $(cat "$TMP/g5-c-open.err")" >&2; return 1; }
  grep -q 'round cap 3 reached' "$TMP/g5-c-open.err" ||
    { echo "FAIL: C cap refusal must name the cap" >&2; return 1; }
  return 0
}

echo "== G5: two takeovers accumulate rounds and the third job refuses at the cap =="
case_takeover_chain || fail "G5 a takeover chain must sum rounds_used"
echo "PASS g5 two-hop takeover rounds accumulate and refuse at the cap"

echo "== MUT: assertion-RED mutants per call site =="

mkmut() { # MUT NAME SED-EXPR — build a mutated wrk copy
  local mut="$TMP/mut-$1"; shift
  if ! { sed "$1" "$WRK" >"$mut" && chmod +x "$mut"; }; then
    fail "mutant build failed: $1"
  fi
  if cmp -s "$WRK" "$mut"; then
    fail "mutant did not change its production call site: $1"
  fi
  MUT="$mut"
}

# mutant-runner: swap $WRK for the mutant and re-run one case; the contract
# assertion must FAIL (RED) — a green mutant means the check is decorative.
expect_mut_red() { # DESC MUT_CASE_FN
  local desc="$1" fn="$2"
  local saved="$WRK"; WRK="$MUT"
  if "$fn"; then
    fail "MUT $desc: mutant stayed GREEN — the assertion does not cover this call site"
  fi
  WRK="$saved"
  echo "PASS mut $desc is assertion-RED"
}

case_usage() {
  reset_case mut-u
  spawn_try -- --job mut-u-job
  [[ "$SPAWN_RC" -eq 2 ]]
}
case_hkdown() {
  reset_case mut-h
  HK_MODE=down spawn_try -- --task 1 --job mut-h-job
  [[ "$SPAWN_RC" -ne 0 && ! -s "$HERDR_LOG" ]]
}
case_link() {
  reset_case mut-l
  spawn_try -- --task 1 --job mut-l-job
  [[ "$SPAWN_RC" -eq 0 && "$(hk_field 1 state)" == claimed && "$(hk_refs_job 1)" == mut-l-job ]]
}
case_verify() {
  reset_case mut-v
  HK_MODE=old spawn_try -- --task 1 --job mut-v-job
  [[ "$SPAWN_RC" -ne 0 ]]
}
case_meta() {
  reset_case mut-m
  spawn_try -- --task 1 --job mut-m-job
  [[ "$SPAWN_RC" -eq 0 ]] &&
    grep -qE '"task_id" *: *1' <<<"$(event_payload mut-m-job job.claim)"
}
case_takeover_live() {
  reset_case mut-take-live
  hk_add --id 1 --state claimed --claimed-by old-label --job-id old-job >/dev/null
  seed_old_job old-job live
  takeover_spawn --task 1 --job mutant-live --takeover-from old-job
  [[ "$SPAWN_RC" -ne 0 && ! -s "$HERDR_LOG" && -z "$(job_event_doc mutant-live job.takeover)" ]]
}
case_takeover_refusal() {
  reset_case mut-take-refusal
  hk_add --id 1 --state claimed --claimed-by old-label --job-id old-job >/dev/null
  seed_old_job old-job ended
  HK_MODE=rejectrebind takeover_spawn --task 1 --job mutant-refusal --takeover-from old-job
  [[ "$SPAWN_RC" -ne 0 && ! -s "$HERDR_LOG" && ! -d "$INBOX/mutant-refusal" &&
     -z "$(job_event_doc mutant-refusal job.takeover)" ]]
}
case_takeover_rounds() {
  reset_case mut-take-rounds
  hk_add --id 1 --state claimed --claimed-by old-label --job-id old-job >/dev/null
  seed_old_job old-job ended 2
  takeover_spawn --task 1 --job mutant-rounds --takeover-from old-job
  [[ "$SPAWN_RC" -eq 0 ]] || return 1
  local head rc
  head="$(git -C "$ROOT" rev-parse HEAD)"
  set +e
  env -u ARBITER_JOB -u HK_TASK_ID ARBITER_INBOX_ROOT="$INBOX" ARBITER_BIN="$ARBITER" \
    HANDOFFKEEP_BIN="$HK" HOME="$HOME" XDG_DATA_HOME="$TMP/mut-round-xdg" \
    TMPDIR="$TMP" PANEWIRE_BIN="$PANEWIRE" WRK_NO_SLEEP=1 \
    "$WRK" round open mutant-rounds --head "$head" --repo "$ROOT" >"$TMP/mut-round.out" 2>"$TMP/mut-round.err"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] && grep -q 'round=3' "$TMP/mut-round.out"
}

# Neutralizing the required-task check must let a taskless spawn proceed —
# the mutant substitutes a valid id so the internal guard is bypassed too.
mkmut no-validate 's/  die "--task <hk task id> is required for --role worker.*/  TASK_ID=1/'
expect_mut_red "task_validate removal" case_usage

mkmut no-precheck 's/^[[:space:]]*hk_task_precheck$/  : hk_task_precheck removed by mutant/'
expect_mut_red "hk_task_precheck removal" case_hkdown

# shellcheck disable=SC2016 # the O3 flag is literal production source text
mkmut no-link 's/^  hk_task_link$/  : hk_task_link removed by mutant/; s/^  \[\[ "$O3_SPAWN_VERIFIED" -eq 1 \]\] || hk_task_link$/  : hk_task_link removed by mutant/'
expect_mut_red "hk_task_link removal" case_link

mkmut no-verify 's/raise SystemExit(0 if ok else 1)/raise SystemExit(0)/'
expect_mut_red "post-claim verify removal" case_verify

# shellcheck disable=SC2016 # the $TASK_ID is literal sed pattern text for the wrk source line
mkmut no-claimargs 's/^  ARBITER_CLAIM_TASK_ARGS=(--task-id "$TASK_ID")$/  ARBITER_CLAIM_TASK_ARGS=()/'
expect_mut_red "claim task_id arg removal" case_meta

mkmut no-terminal-check 's/die "takeover refused: old job.*still live; no work-terminal follows its newest revive"/: # terminal guard removed by mutant/'
expect_mut_red "live old-job terminal check removal" case_takeover_live

# shellcheck disable=SC2016 # the O3 flag is literal production source text
mkmut no-rebind-call 's/^  hk_task_takeover_rebind$/  : rebind call removed by mutant/; s/^  \[\[ "$O3_SPAWN_VERIFIED" -eq 1 \]\] || hk_task_takeover_rebind$/  : rebind call removed by mutant/'
expect_mut_red "refused rebind leaves no pane or partial record" case_takeover_refusal

mkmut no-round-inheritance 's/used += wrk_takeover_rounds(events)/# takeover inheritance removed by mutant/'
expect_mut_red "takeover round baseline removal" case_takeover_rounds

# Every hop stores 0 instead of the predecessor's full round_scan. Valid
# python, so the miss is the rounds_used / cap assertion, not an exception.
mkmut no-round-chain 's/used += wrk_takeover_rounds(events)/used += 0/g'
expect_mut_red "takeover chain under-count" case_takeover_chain

echo "PASS test-wrk-task-link: all cases"
