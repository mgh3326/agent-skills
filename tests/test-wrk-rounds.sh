#!/usr/bin/env bash
# hk 1449: job.verdict identity, no records after an end declaration,
# the joined gate, and read-only round audit.
# Legitimate flows covered here:
#   flow-normal-1-to-3-rounds
#   flow-voided-round
#   flow-takeover-inherited-rounds
#   flow-round-extension
#   flow-duplicate-join-after-delegated
#   flow-delegated-panewire-joined
#   flow-parking-arcade-join
#   hk1506-head-binding
#   hk1506-no-head-round-refused
#   hk1506-no-open-round-refused
#   hk1506-unbound-verdict-readers-unchanged
# hk 1970: round verdict --head-repeat REF binds a second verdict to a repeated head once per
# REF per job; identity refusals come first and a grant binds only the oldest open round.
#   hk1970-head-repeat (the hk 1964 sequence, refusals, used-once, pa-integrator, mutants)
# hk 1900: a round counts toward the join only once a verdict is recorded for it,
# the join rechecks the end record and the gate inside the events lock, and a
# verdict file with a non-UTF-8 byte is read with replacement, not skipped.
#   e-open-round-without-verdict-cannot-join
#   e-open-round-done-warns-once-and-succeeds
#   f-inlock-end-record-refused
#   f-inlock-zero-rounds-refused
#   f-hook-inert-outside-test-mode
#   g-non-utf8-copy-refused-then-recorded
#   flow-normal-1-round / flow-normal-2-rounds (and flow-normal-1-to-3-rounds)
#   flow-voided-round-then-verdict-then-joined
#   flow-takeover-own-verdict / flow-takeover-inherited-rounds
#   flow-round-extension-verdict-then-joined
#   flow-delegated-joined-gated-before-handoff
set -euo pipefail
# hk 1894: trust-bearing wrk and arbiter commands honour this suite's temp-dir overrides
# (HOME, ARBITER_INBOX_ROOT, XDG_DATA_HOME, HANDOFFKEEP_BIN) only in test mode.
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export ARBITER_INBOX_ROOT="$TMP/inbox"
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/xdg/config"
export XDG_CACHE_HOME="$TMP/xdg/cache"
export XDG_DATA_HOME="$TMP/xdg/data"
export XDG_STATE_HOME="$TMP/xdg/state"
export XDG_RUNTIME_DIR="$TMP/xdg/runtime"
export CODEX_HOME="$TMP/codex"
export TMPDIR="$TMP/tmp"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" \
  "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$TMPDIR" "$CODEX_HOME" "$ARBITER_INBOX_ROOT"
chmod 700 "$XDG_RUNTIME_DIR"
export WRK_NO_SLEEP=1
export WRK_JOB_DELEGATE=0
export PANEWIRE_BIN="$TMP/absent-panewire"
export HANDOFFKEEP_BIN="$TMP/hk"
# hk 1897: round void/extend read the claim identity from the arbiter DB row;
# give every wrk/arbiter call a temp-root canonical binary.
cp "$ROOT/bin/arbiter" "$TMP/arbiter" && chmod 700 "$TMP/arbiter"
export ARBITER_BIN="$TMP/arbiter"
export HK_DOC_DIR="$TMP/hk-docs"
export HK_TASK_DIR="$TMP/hk-tasks"
export HK_CALL_LOG="$TMP/hk-calls.log"
mkdir -p "$HK_DOC_DIR" "$HK_TASK_DIR"
: >"$HK_CALL_LOG"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

python3 - <<'PY'
import sys
assert sys.version_info >= (3, 11), sys.version
PY

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

write_event() {
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(sys.stdin); f=open(p,"w",encoding="utf-8"); json.dump(d,f,separators=(",",":")); f.write("\n"); f.close()' "$1"
}

claim_job() { # claim_job job [parent] [created_at] [role] [owner] [task_id]
  local job="$1" parent="${2:-director-1}" at="${3:-2026-10-23T00:00:00Z}"
  local role="${4:-builder}" owner="${5:-lane-a}" task_id="${6:-}"
  local events="$ARBITER_INBOX_ROOT/$job/events"
  mkdir -p "$events" "$ARBITER_INBOX_ROOT/$job"
  # hk 1897: mint the DB claim row; the events file arbiter writes stays
  # byte-identical on the identity fields — only created_at and the
  # informational label/pane_id fields are patched afterwards.
  local claim_args=(claim --job "$job" --lane "$owner" --t T2 --role "$role" --agent-label lbl)
  # --parent-lane is only valid for --role builder in arbiter claim.
  [[ "$role" == "builder" ]] && claim_args+=(--parent-lane "$parent")
  [[ -z "$task_id" ]] || claim_args+=(--task-id "$task_id")
  "$ARBITER_BIN" "${claim_args[@]}" >/dev/null || fail "claim_job $job mint failed"
  python3 - "$events/00001-job.claim.json" "$at" <<'PY'
import json, sys
p, at = sys.argv[1], sys.argv[2]
doc = json.load(open(p, encoding="utf-8"))
doc["created_at"] = at
doc["payload"]["label"] = "lbl"
doc["payload"]["pane_id"] = "w:p1"
open(p, "w", encoding="utf-8").write(json.dumps(doc, separators=(",", ":")) + "\n")
PY
}

# reclaim_job — a real arbiter reclaim row + events file, with created_at
# patched to the planted timestamp (identity fields stay arbiter-minted).
reclaim_job() { # reclaim_job job created_at [owner] [parent]
  local job="$1" at="$2" owner="${3:-lane-a}" parent="${4:-director-1}"
  local res="$TMP/reclaim-res-$job"
  "$ARBITER_BIN" lease --job "$job" --resource "$res" --kind path >/dev/null ||
    fail "reclaim_job $job lease failed"
  "$ARBITER_BIN" release --job "$job" --resource "$res" --kind path --force >/dev/null ||
    fail "reclaim_job $job release failed"
  "$ARBITER_BIN" claim --reclaim-released --job "$job" --lane "$owner" --t T2 \
    --role builder --parent-lane "$parent" --agent-label lbl >/dev/null ||
    fail "reclaim_job $job mint failed"
  python3 - "$ARBITER_INBOX_ROOT/$job/events" "$at" <<'PY'
import json, sys, os
events, at = sys.argv[1], sys.argv[2]
name = sorted(n for n in os.listdir(events) if n.endswith("-job.reclaim.json"))[-1]
p = os.path.join(events, name)
doc = json.load(open(p, encoding="utf-8"))
doc["created_at"] = at
doc["payload"]["label"] = "lbl"
doc["payload"]["pane_id"] = "w:p1"
open(p, "w", encoding="utf-8").write(json.dumps(doc, separators=(",", ":")) + "\n")
PY
}

seed_open_round() { # seed_open_round job [round] [created_at] — a round with no verdict
  local job="$1" round="${2:-1}" at="${3:-2026-10-23T00:00:01Z}"
  local events="$ARBITER_INBOX_ROOT/$job/events"
  mkdir -p "$events"
  write_event "$events/seed-job.round.json" <<EOF
{"kind":"job.round","job_id":"$job","round":$round,"head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","created_at":"$at"}
EOF
}

# hk 1900: a round counts toward the join only with a recorded verdict, so the
# seeded round carries a matching job.verdict (no path or sha, so it matches no file).
seed_round() { # seed_round job [round] [created_at]
  local job="$1" round="${2:-1}" at="${3:-2026-10-23T00:00:01Z}"
  local events="$ARBITER_INBOX_ROOT/$job/events"
  seed_open_round "$job" "$round" "$at"
  write_event "$events/seed-job.verdict.json" <<EOF
{"kind":"job.verdict","job_id":"$job","round":$round,"head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","verdict":"PASS","created_at":"$at"}
EOF
}

kind_count() { # kind_count job kind
  python3 -c 'import json,os,sys
job,kind,root=sys.argv[1:]
events=os.path.join(root,job,"events")
n=0
if os.path.isdir(events):
    for name in os.listdir(events):
        if not name.endswith(".json"):
            continue
        try:
            doc=json.load(open(os.path.join(events,name),encoding="utf-8"))
        except (OSError,ValueError):
            continue
        if isinstance(doc,dict) and doc.get("kind")==kind:
            n+=1
print(n)' "$1" "$2" "$ARBITER_INBOX_ROOT"
}

verdict_field() { # verdict_field job index field
  python3 -c 'import json,os,sys
job,index,field,root=sys.argv[1:]
events=os.path.join(root,job,"events")
rows=[]
for name in sorted(os.listdir(events)):
    if not name.endswith(".json"):
        continue
    doc=json.load(open(os.path.join(events,name),encoding="utf-8"))
    if isinstance(doc,dict) and doc.get("kind")=="job.verdict":
        rows.append((name,doc))
name,doc=rows[int(index)]
value=doc.get(field)
if value is None:
    value=""
print(name)
print(value)' "$1" "$2" "$3" "$ARBITER_INBOX_ROOT"
}

file_sha() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

snap_tree() { # snap_tree root outfile
  python3 -c 'import hashlib,os,sys
root,out=sys.argv[1:]
rows=[]
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        path=os.path.join(dirpath,name)
        rel=os.path.relpath(path,root)
        if os.path.islink(path):
            rows.append("link\t%s\t%s"%(rel,os.readlink(path)))
            continue
        data=open(path,"rb").read()
        rows.append("file\t%s\t%s\t%d"%(rel,hashlib.sha256(data).hexdigest(),len(data)))
open(out,"w",encoding="utf-8").write("\n".join(rows)+"\n")' "$1" "$2"
}

run_cmd() {
  set +e
  "$@" >"$TMP/run.out" 2>"$TMP/run.err"
  RUN_RC=$?
  set -e
}

assert_rc() {
  [[ "$RUN_RC" -eq "$1" ]] || fail "rc=$RUN_RC want=$1 stdout=$(cat "$TMP/run.out") stderr=$(cat "$TMP/run.err")"
}

assert_refused() { # exact stderr line
  [[ "$RUN_RC" -ne 0 ]] || fail "expected refusal, command succeeded: $(cat "$TMP/run.out")"
  grep -qxF "$1" "$TMP/run.err" || fail "stderr want=$1 got=$(cat "$TMP/run.err")"
}

open_ok() { # open_ok job head
  run_cmd "$WRK" round open "$1" --head "$2" --repo "$TEST_REPO"
  assert_rc 0
}

open_with() { # open_with wrk-path job head
  run_cmd "$1" round open "$2" --head "$3" --repo "$TEST_REPO"
  assert_rc 0
}

verdict_ok() { # verdict_ok job file
  run_cmd "$WRK" round verdict "$1" --file "$2"
  assert_rc 0
}

join_ok() { # join_ok job [extra wrk args...]
  local job="$1"
  shift
  run_cmd "$WRK" joined "$job" --pr https://example.invalid/pr/1449 --head "$H1" --report "$REPORT" "$@"
  assert_rc 0
  grep -q "OK job=$job " "$TMP/run.out" || fail "join stdout: $(cat "$TMP/run.out")"
  [[ "$(kind_count "$job" job.joined)" -eq 1 ]] || fail "join did not write one job.joined for $job"
}

write_verdict_file() { # path verdict head [body]
  local path="$1" verdict="$2" head="$3" body="${4:-findings}"
  printf '%s\nVERDICT: %s @%s\n' "$body" "$verdict" "$head" >"$path"
}

write_verdict_first() { # path verdict head — the VERDICT line is line 1
  printf 'VERDICT: %s @%s\n' "$2" "$3" >"$1"
}

# The stub serves doc get from HK_DOC_DIR, tasks comments from HK_TASK_DIR/comments-N and
# tasks show from HK_TASK_DIR/show-N, and records every call it receives (hk 1899).
# HK_FETCH_HOOK, when set, runs inside the waiver-record fetch — the window hk 2024
# races: after verify, before the events-lock commit.
cat >"$HANDOFFKEEP_BIN" <<'EOF'
#!/bin/sh
[ -z "${HK_CALL_LOG:-}" ] || printf '%s\n' "$*" >>"$HK_CALL_LOG"
if [ "$1" = "doc" ] && [ "$2" = "get" ] && [ -n "${3:-}" ] && [ -f "$HK_DOC_DIR/$3" ]; then
  cat "$HK_DOC_DIR/$3"
  [ -z "${HK_FETCH_HOOK:-}" ] || "$HK_FETCH_HOOK" "$@"
  exit 0
fi
if [ "$1" = "tasks" ] && [ "$2" = "comments" ] && [ -n "${3:-}" ] && [ -f "$HK_TASK_DIR/comments-$3" ]; then
  cat "$HK_TASK_DIR/comments-$3"
  [ -z "${HK_FETCH_HOOK:-}" ] || "$HK_FETCH_HOOK" "$@"
  exit 0
fi
if [ "$1" = "tasks" ] && [ "$2" = "show" ] && [ -n "${3:-}" ] && [ -f "$HK_TASK_DIR/show-$3" ]; then
  cat "$HK_TASK_DIR/show-$3"
  exit 0
fi
exit 1
EOF
chmod +x "$HANDOFFKEEP_BIN"

grant_doc() { # grant_doc key body [created_by]
  python3 -c 'import json,sys; json.dump({"created_by":sys.argv[3],"body":sys.argv[2]}, open(sys.argv[1],"w"))' \
    "$HK_DOC_DIR/$1" "$2" "${3:-director-1}"
}

grant_task() { # grant_task id author body — appends one comment to the task comments record
  python3 -c 'import json,os,sys
path,author,body=sys.argv[1:]
doc={"comments":[]}
if os.path.exists(path):
    doc=json.load(open(path,encoding="utf-8"))
doc["comments"].append({"author":author,"body":body})
json.dump(doc,open(path,"w",encoding="utf-8"))' "$HK_TASK_DIR/comments-$1" "$2" "$3"
}

task_record() { # task_record id project job_id — the server task a pa-integrator grant is checked against
  python3 -c 'import json,sys; json.dump({"id":sys.argv[2],"project":sys.argv[3],"refs":{"job_id":sys.argv[4]}}, open(sys.argv[1],"w"))' \
    "$HK_TASK_DIR/show-$1" "$1" "$2" "$3"
}

TEST_REPO="$TMP/repo"
git init -q "$TEST_REPO"
TEST_REPO="$(cd "$TEST_REPO" && pwd -P)"
git -C "$TEST_REPO" config user.name 'Round Fixture'
git -C "$TEST_REPO" config user.email 'round-fixture@example.invalid'
for n in 1 2 3 4; do
  printf 'commit %s\n' "$n" >"$TEST_REPO/commit-$n"
  git -C "$TEST_REPO" add "commit-$n"
  git -C "$TEST_REPO" commit -q -m "fixture commit $n"
done
H1="$(git -C "$TEST_REPO" rev-parse HEAD~3)"
H2="$(git -C "$TEST_REPO" rev-parse HEAD~2)"
H3="$(git -C "$TEST_REPO" rev-parse HEAD~1)"
H4="$(git -C "$TEST_REPO" rev-parse HEAD)"
REPORT="$TMP/report.md"
printf 'builder report\n' >"$REPORT"

# ── A: distinct verdicts ────────────────────────────────────────────────
claim_job a-path
open_ok a-path "$H1"
write_verdict_file "$TMP/a-path.md" PASS "$H1" 'path body'
verdict_ok a-path "$TMP/a-path.md"
run_cmd "$WRK" round verdict a-path --file "$TMP/a-path.md"
first_name="$(verdict_field a-path 0 path >/dev/null; python3 -c 'import json,os,sys
root,job=sys.argv[1:]
events=os.path.join(root,job,"events")
for name in sorted(os.listdir(events)):
    doc=json.load(open(os.path.join(events,name),encoding="utf-8"))
    if doc.get("kind")=="job.verdict":
        print(name); break' "$ARBITER_INBOX_ROOT" a-path)"
abs_path="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TMP/a-path.md")"
assert_refused "wrk: round verdict: verdict path already recorded as $first_name: $abs_path"
[[ "$(kind_count a-path job.verdict)" -eq 1 ]] || fail "same path must not write a second job.verdict"
stored_sha="$(verdict_field a-path 0 content_sha256 | tail -n 1)"
[[ "$stored_sha" == "$(file_sha "$TMP/a-path.md")" ]] || fail "job.verdict must store content_sha256, got $stored_sha"
echo "PASS a-same-path-refused"

claim_job a-bytes
open_ok a-bytes "$H1"
cp "$TMP/a-path.md" "$TMP/a-bytes-1.md"
cp "$TMP/a-path.md" "$TMP/a-bytes-2.md"
verdict_ok a-bytes "$TMP/a-bytes-1.md"
run_cmd "$WRK" round verdict a-bytes --file "$TMP/a-bytes-2.md"
bytes_name="$(python3 -c 'import json,os,sys
root,job=sys.argv[1:]
events=os.path.join(root,job,"events")
for name in sorted(os.listdir(events)):
    doc=json.load(open(os.path.join(events,name),encoding="utf-8"))
    if doc.get("kind")=="job.verdict":
        print(name); break' "$ARBITER_INBOX_ROOT" a-bytes)"
assert_refused "wrk: round verdict: verdict content $(file_sha "$TMP/a-bytes-1.md") already recorded as $bytes_name"
[[ "$(kind_count a-bytes job.verdict)" -eq 1 ]] || fail "same content must not write a second job.verdict"
echo "PASS a-same-content-refused"

claim_job a-head
open_ok a-head "$H2"
write_verdict_file "$TMP/a-head-1.md" PASS "$H2" 'head body one'
write_verdict_file "$TMP/a-head-2.md" BLOCKER "$H2" 'head body two'
verdict_ok a-head "$TMP/a-head-1.md"
run_cmd "$WRK" round verdict a-head --file "$TMP/a-head-2.md"
head_name="$(python3 -c 'import json,os,sys
root,job=sys.argv[1:]
events=os.path.join(root,job,"events")
for name in sorted(os.listdir(events)):
    doc=json.load(open(os.path.join(events,name),encoding="utf-8"))
    if doc.get("kind")=="job.verdict":
        print(name); break' "$ARBITER_INBOX_ROOT" a-head)"
assert_refused "wrk: round verdict: head $H2 already recorded as $head_name"
[[ "$(kind_count a-head job.verdict)" -eq 1 ]] || fail "same head must not write a second job.verdict"
echo "PASS a-same-head-refused"

# Same head after a planted void is allowed and binds to the next open round.
# The void command itself still refuses a round that already has a verdict.
claim_job a-voided
open_ok a-voided "$H3"
write_verdict_file "$TMP/a-void-a.md" PASS "$H3" 'voided head A'
verdict_ok a-voided "$TMP/a-void-a.md"
write_verdict_file "$TMP/a-void-b.md" PASS "$H3" 'voided head B'
run_cmd "$WRK" round verdict a-voided --file "$TMP/a-void-b.md"
[[ "$RUN_RC" -ne 0 ]] || fail "same head before the void must be refused"
grant_doc void1 "$(printf 'round-void: job=a-voided round=1 by=director-1\n')"
run_cmd "$WRK" round void a-voided 1 --by hk:doc/void1
[[ "$RUN_RC" -ne 0 ]] || fail "void command must still refuse a round that has a verdict"
grep -q 'already has a job.verdict' "$TMP/run.err" || fail "HAS_VERDICT refusal missing: $(cat "$TMP/run.err")"
write_event "$ARBITER_INBOX_ROOT/a-voided/events/00090-job.round_void.json" <<EOF
{"kind":"job.round_void","job_id":"a-voided","round":1,"ref":"hk:task/9","created_at":"2026-10-23T00:10:00Z"}
EOF
open_ok a-voided "$H3"
write_verdict_file "$TMP/a-void-c.md" PASS "$H3" 'voided head C'
verdict_ok a-voided "$TMP/a-void-c.md"
[[ "$(kind_count a-voided job.verdict)" -eq 2 ]] || fail "same head after a void must be recorded"
bound_round="$(verdict_field a-voided 1 round | tail -n 1)"
[[ "$bound_round" == "2" ]] || fail "verdict after the void must bind to round 2, got $bound_round"
echo "PASS a-same-head-after-void-allowed"

# ── B: no records after the end, until a later reclaim ──────────────────
claim_job b-ended director-1 2026-10-23T00:00:00Z
write_event "$ARBITER_INBOX_ROOT/b-ended/events/00002-job.revoked.json" <<'EOF'
{"kind":"job.revoked","job_id":"b-ended","created_at":"2026-10-23T01:00:00Z"}
EOF
END_NAME=00002-job.revoked.json
run_cmd "$WRK" round open b-ended --head "$H1" --repo "$TEST_REPO"
assert_refused "wrk: round open: refused after end record $END_NAME"
run_cmd "$WRK" round verdict b-ended --file "$TMP/a-path.md"
assert_refused "wrk: round verdict: refused after end record $END_NAME"
run_cmd "$WRK" round void b-ended 1 --by hk:doc/void1
assert_refused "wrk: round void: refused after end record $END_NAME"
run_cmd "$WRK" joined b-ended --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: refused after end record $END_NAME"
[[ "$(kind_count b-ended job.round)" -eq 0 ]] || fail "open after revoke wrote a round"
[[ "$(kind_count b-ended job.verdict)" -eq 0 ]] || fail "verdict after revoke wrote a record"
[[ "$(kind_count b-ended job.round_void)" -eq 0 ]] || fail "void after revoke wrote a record"
[[ "$(kind_count b-ended job.joined)" -eq 0 ]] || fail "joined after revoke wrote a record"
# A reclaim after the end record is a real arbiter-minted row now (hk 1897).
reclaim_job b-ended 2026-10-23T02:00:00Z
open_ok b-ended "$H1"
open_ok b-ended "$H2"
open_ok b-ended "$H4"
grant_doc void-b "$(printf 'round-void: job=b-ended round=2 by=director-1\n')"
run_cmd "$WRK" round void b-ended 2 --by hk:doc/void-b
assert_rc 0
write_verdict_file "$TMP/b-ended.md" PASS "$H4" 'after reclaim'
verdict_ok b-ended "$TMP/b-ended.md"
join_ok b-ended
echo "PASS b-end-refuses-until-reclaim"

# ── C: join gate, waiver, unmatched file, done warning ──────────────────
claim_job c-zero
run_cmd "$WRK" joined c-zero --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: job c-zero has zero non-voided recorded rounds"
[[ "$(kind_count c-zero job.joined)" -eq 0 ]] || fail "zero-round join must not write job.joined"
echo "PASS c-zero-rounds-refused"

claim_job c-waive
grant_task 1 director-1 "join-waiver: job=c-waive by=director-1"
run_cmd "$WRK" joined c-waive --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT" --rounds-waived hk:task/1
assert_rc 0
python3 -c 'import json,os,sys
root,job=sys.argv[1:]
found=False
for name in os.listdir(os.path.join(root,job,"events")):
    doc=json.load(open(os.path.join(root,job,"events",name),encoding="utf-8"))
    if doc.get("kind")=="job.joined":
        found=True
        assert doc.get("rounds_waived")=="hk:task/1", doc
        assert doc.get("rounds_waived_issuer")=="director-1", doc
assert found
' "$ARBITER_INBOX_ROOT" c-waive
echo "PASS c-waiver-hk-task-recorded"

claim_job c-waive-doc
grant_doc waiver-key "join-waiver: job=c-waive-doc by=director-1"
run_cmd "$WRK" joined c-waive-doc --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT" --rounds-waived hk:doc/waiver-key
assert_rc 0
python3 -c 'import json,os,sys
root=sys.argv[1]
for name in os.listdir(os.path.join(root,"c-waive-doc","events")):
    doc=json.load(open(os.path.join(root,"c-waive-doc","events",name),encoding="utf-8"))
    if doc.get("kind")=="job.joined":
        assert doc.get("rounds_waived")=="hk:doc/waiver-key", doc
        assert doc.get("rounds_waived_issuer")=="director-1", doc
        raise SystemExit(0)
raise SystemExit("missing joined")
' "$ARBITER_INBOX_ROOT"
echo "PASS c-waiver-hk-doc-recorded"

claim_job c-bad-waiver
run_cmd "$WRK" joined c-bad-waiver --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT" --rounds-waived not-a-ref
assert_refused "wrk: joined: --rounds-waived requires hk:doc/<key> or hk:task/<id>"
[[ "$(kind_count c-bad-waiver job.joined)" -eq 0 ]] || fail "bad waiver must not write job.joined"
run_cmd "$WRK" joined c-bad-waiver --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT" --rounds-waived 'hk:task/'
assert_refused "wrk: joined: --rounds-waived requires hk:doc/<key> or hk:task/<id>"
echo "PASS c-waiver-shape-refused"

# Waiver must not be forwarded to panewire.
claim_job c-waive-local
grant_task 1 director-1 "join-waiver: job=c-waive-local by=director-1"
cat >"$TMP/pw-waive" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$PW_LOG"
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
exit 42
EOF
chmod +x "$TMP/pw-waive"
: >"$TMP/pw-waive.log"
run_cmd env WRK_JOB_DELEGATE=1 PANEWIRE_BIN="$TMP/pw-waive" PW_LOG="$TMP/pw-waive.log" \
  "$WRK" joined c-waive-local --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT" \
  --rounds-waived hk:task/1
assert_rc 0
if grep -q 'job probe' "$TMP/pw-waive.log" || grep -q 'job joined' "$TMP/pw-waive.log"; then
  fail "a waived join must not delegate to panewire: $(cat "$TMP/pw-waive.log")"
fi
if grep -q 'rounds-waived' "$TMP/pw-waive.log"; then
  fail "waiver must not be forwarded: $(cat "$TMP/pw-waive.log")"
fi
echo "PASS c-waiver-skips-delegate"

claim_job c-unmatched
seed_round c-unmatched
unmatched="$ARBITER_INBOX_ROOT/c-unmatched/stray.md"
write_verdict_first "$unmatched" BLOCKER "$H4"
unmatched_abs="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$unmatched")"
run_cmd "$WRK" joined c-unmatched --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: unmatched tester verdict file $unmatched_abs"
[[ "$(kind_count c-unmatched job.joined)" -eq 0 ]] || fail "unmatched verdict file must not write job.joined"
echo "PASS c-unmatched-file-refused"

# A brief or report that only mentions a VERDICT line later is not a verdict file.
claim_job c-later-line
seed_round c-later-line
later="$ARBITER_INBOX_ROOT/c-later-line/report.md"
write_verdict_file "$later" PASS "$H1" 'builder report mentions a verdict later'
run_cmd "$WRK" joined c-later-line --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_rc 0
grep -q "OK job=c-later-line " "$TMP/run.out" || fail "later-line join stdout: $(cat "$TMP/run.out")"
[[ "$(kind_count c-later-line job.joined)" -eq 1 ]] || fail "a later VERDICT line must not block the join"
if grep -q 'unmatched tester verdict file' "$TMP/run.err"; then
  fail "a later VERDICT line was treated as a verdict file: $(cat "$TMP/run.err")"
fi
echo "PASS c-later-line-verdict-ignored"

claim_job c-both
both="$ARBITER_INBOX_ROOT/c-both/stray.md"
write_verdict_first "$both" BLOCKER "$H4"
both_abs="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$both")"
run_cmd "$WRK" joined c-both --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: job c-both has zero non-voided recorded rounds; unmatched tester verdict file $both_abs"
echo "PASS c-zero-and-unmatched-one-line"

claim_job c-matched
open_ok c-matched "$H2"
matched="$ARBITER_INBOX_ROOT/c-matched/verdict.md"
write_verdict_file "$matched" PASS "$H2" 'matched in the job dir'
verdict_ok c-matched "$matched"
join_ok c-matched
echo "PASS c-matched-path-allowed"

claim_job c-copy
open_ok c-copy "$H3"
write_verdict_file "$TMP/c-copy-src.md" PASS "$H3" 'bytes that will be copied'
verdict_ok c-copy "$TMP/c-copy-src.md"
cp "$TMP/c-copy-src.md" "$ARBITER_INBOX_ROOT/c-copy/copy.md"
join_ok c-copy
echo "PASS c-matched-content-sha-allowed"

claim_job c-done-both
done_stray="$ARBITER_INBOX_ROOT/c-done-both/stray.md"
write_verdict_first "$done_stray" PASS "$H1"
done_abs="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$done_stray")"
run_cmd "$WRK" 'done' c-done-both --report "$REPORT"
assert_rc 0
grep -q "OK job=c-done-both " "$TMP/run.out" || fail "done stdout: $(cat "$TMP/run.out")"
[[ "$(grep -c 'ROUNDS job=' "$TMP/run.err")" -eq 1 ]] || fail "done must warn once: $(cat "$TMP/run.err")"
grep -q "wrk: warning: ROUNDS job=c-done-both has zero non-voided recorded rounds; unmatched tester verdict file $done_abs; wrk joined would refuse" "$TMP/run.err" ||
  fail "done warning text: $(cat "$TMP/run.err")"
[[ "$(kind_count c-done-both job.completed)" -eq 1 ]] || fail "done must still write job.completed"
echo "PASS c-done-warns-once-and-succeeds"

claim_job c-done-clean
seed_round c-done-clean
run_cmd "$WRK" 'done' c-done-clean --report "$REPORT"
assert_rc 0
[[ "$(grep -c 'ROUNDS job=' "$TMP/run.err" || true)" -eq 0 ]] || fail "a round with no stray file must not warn: $(cat "$TMP/run.err")"
echo "PASS c-done-clean-silent"

claim_job c-done-worker director-1 2026-10-23T00:00:00Z worker
run_cmd "$WRK" 'done' c-done-worker --report "$REPORT"
assert_rc 0
[[ "$(grep -c 'ROUNDS job=' "$TMP/run.err" || true)" -eq 0 ]] || fail "worker done must stay silent: $(cat "$TMP/run.err")"
echo "PASS c-done-worker-silent"

# ── D: audit lists exactly the planted jobs and writes nothing ──────────
AUDIT="$TMP/audit-inbox"
mkdir -p "$AUDIT"
save_inbox="$ARBITER_INBOX_ROOT"
ARBITER_INBOX_ROOT="$AUDIT"
claim_job audit-zero
claim_job audit-live
seed_round audit-live
claim_job audit-ended
write_event "$AUDIT/audit-ended/events/00002-job.revoked.json" <<'EOF'
{"kind":"job.revoked","job_id":"audit-ended","created_at":"2026-10-23T03:00:00Z"}
EOF
write_verdict_first "$AUDIT/audit-ended/ended.md" PASS "$H1"
claim_job audit-open
seed_round audit-open
write_verdict_first "$AUDIT/audit-open/open.md" BLOCKER "$H2"
claim_job audit-matched
seed_round audit-matched
write_verdict_file "$AUDIT/audit-matched/ok.md" PASS "$H3" 'recorded bytes'
matched_abs="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$AUDIT/audit-matched/ok.md")"
write_event "$AUDIT/audit-matched/events/00080-job.verdict.json" <<EOF
{"kind":"job.verdict","job_id":"audit-matched","round":1,"head":"$H3","path":"$matched_abs","content_sha256":"$(file_sha "$AUDIT/audit-matched/ok.md")","verdict":"PASS","created_at":"2026-10-23T00:00:02Z"}
EOF
claim_job audit-void
seed_open_round audit-void
write_event "$AUDIT/audit-void/events/00081-job.round_void.json" <<'EOF'
{"kind":"job.round_void","job_id":"audit-void","round":1,"ref":"hk:task/4","created_at":"2026-10-23T00:00:03Z"}
EOF
claim_job audit-worker director-1 2026-10-23T00:00:00Z worker
mkdir -p "$AUDIT/audit-subdir/nested"
write_verdict_file "$AUDIT/audit-subdir/nested/hidden.md" PASS "$H4" 'nested'
claim_job audit-subdir
seed_round audit-subdir
write_verdict_file "$TMP/audit-link-target.md" PASS "$H4" 'link target'
ln -s "$TMP/audit-link-target.md" "$AUDIT/audit-symlink-job/link.md" 2>/dev/null || true
mkdir -p "$AUDIT/audit-symlink-job"
ln -s "$TMP/audit-link-target.md" "$AUDIT/audit-symlink-job/link.md"
claim_job audit-symlink-job
seed_round audit-symlink-job
claim_job audit-lane-b director-1 2026-10-23T00:00:00Z builder lane-b
ended_abs="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$AUDIT/audit-ended/ended.md")"
open_abs="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$AUDIT/audit-open/open.md")"
snap_tree "$AUDIT" "$TMP/audit-before"
run_cmd env ARBITER_INBOX_ROOT="$AUDIT" "$WRK" round audit
assert_rc 0
# hk 1894: audit reads the checked inbox, so in test mode its stderr is the guard's one
# override warning and nothing else.
[[ "$(grep -vc '^wrk: warning: test mode honours overridden ' "$TMP/run.err" || true)" -eq 0 ]] ||
  fail "audit must write nothing but the test-mode warning on stderr: $(cat "$TMP/run.err")"
[[ "$(grep -c '^wrk: warning: test mode honours overridden ' "$TMP/run.err" || true)" -eq 1 ]] ||
  fail "audit must print the test-mode override warning once: $(cat "$TMP/run.err")"
printf '%s\n' \
  "unmatched-verdict job=audit-ended file=$ended_abs" \
  "zero-rounds job=audit-lane-b lane=lane-b" \
  "unmatched-verdict job=audit-open file=$open_abs" \
  "zero-rounds job=audit-zero lane=lane-a" >"$TMP/audit-want"
# Sort both sides so a stable per-job order is what we lock, and the
# comparison stays exact.
sort "$TMP/run.out" >"$TMP/audit-got"
sort "$TMP/audit-want" >"$TMP/audit-want-sorted"
cmp "$TMP/audit-want-sorted" "$TMP/audit-got" || fail "audit listing: $(cat "$TMP/run.out")"
snap_tree "$AUDIT" "$TMP/audit-after"
cmp "$TMP/audit-before" "$TMP/audit-after" || fail "audit changed the job dirs"
run_cmd env ARBITER_INBOX_ROOT="$AUDIT" "$WRK" round audit --lane lane-b
assert_rc 0
grep -qxF 'zero-rounds job=audit-lane-b lane=lane-b' "$TMP/run.out" || fail "lane filter: $(cat "$TMP/run.out")"
[[ "$(grep -c . "$TMP/run.out")" -eq 1 ]] || fail "lane filter must list only lane-b: $(cat "$TMP/run.out")"
run_cmd env ARBITER_INBOX_ROOT="$AUDIT" "$WRK" round audit --lane absent-lane
assert_rc 0
[[ ! -s "$TMP/run.out" ]] || fail "unknown lane must list nothing: $(cat "$TMP/run.out")"
run_cmd env ARBITER_INBOX_ROOT="$AUDIT" "$WRK" round audit --lane lane-a
assert_rc 0
printf '%s\n' \
  "unmatched-verdict job=audit-ended file=$ended_abs" \
  "unmatched-verdict job=audit-open file=$open_abs" \
  "zero-rounds job=audit-zero lane=lane-a" >"$TMP/audit-lane-a-want"
sort "$TMP/run.out" >"$TMP/audit-lane-a-got"
sort "$TMP/audit-lane-a-want" >"$TMP/audit-lane-a-want-sorted"
cmp "$TMP/audit-lane-a-want-sorted" "$TMP/audit-lane-a-got" || fail "lane-a filter: $(cat "$TMP/run.out")"
snap_tree "$AUDIT" "$TMP/audit-after-lane"
# hk 1897 B-1: an ambient WRK_CLAIM_DB must never reach the audit's scan —
# the audit is trust-bearing and reports events-dir owner values only.
run_cmd env ARBITER_INBOX_ROOT="$AUDIT" \
  WRK_CLAIM_DB='{"audit-zero":{"o":"ghost-lane","p":"forged-parent","t":"9999"},"audit-lane-b":{"o":"lane-a"}}' \
  "$WRK" round audit
assert_rc 0
grep -qxF 'zero-rounds job=audit-zero lane=lane-a' "$TMP/run.out" ||
  fail "ambient WRK_CLAIM_DB relabelled the audit: $(cat "$TMP/run.out")"
grep -qxF 'zero-rounds job=audit-lane-b lane=lane-b' "$TMP/run.out" ||
  fail "ambient WRK_CLAIM_DB hid or moved audit-lane-b: $(cat "$TMP/run.out")"
run_cmd env ARBITER_INBOX_ROOT="$AUDIT" WRK_CLAIM_DB='not-json{{{' "$WRK" round audit
assert_rc 0
grep -qxF 'zero-rounds job=audit-zero lane=lane-a' "$TMP/run.out" ||
  fail "malformed WRK_CLAIM_DB changed the audit: $(cat "$TMP/run.out")"
cmp "$TMP/audit-before" "$TMP/audit-after-lane" || fail "lane audit changed the job dirs"
ARBITER_INBOX_ROOT="$save_inbox"
echo "PASS d-audit-lists-planted-jobs-and-writes-nothing"

# ── legitimate flows ────────────────────────────────────────────────────
echo "== flow-normal-1-to-3-rounds =="
claim_job flow-normal-1
open_ok flow-normal-1 "$H1"
write_verdict_file "$TMP/flow-1n1.md" PASS "$H1" 'only round'
verdict_ok flow-normal-1 "$TMP/flow-1n1.md"
join_ok flow-normal-1
echo "PASS flow-normal-1-round"
claim_job flow-normal-2
open_ok flow-normal-2 "$H1"
write_verdict_file "$TMP/flow-2n1.md" BLOCKER "$H1" 'round one'
verdict_ok flow-normal-2 "$TMP/flow-2n1.md"
open_ok flow-normal-2 "$H2"
write_verdict_file "$TMP/flow-2n2.md" PASS "$H2" 'round two'
verdict_ok flow-normal-2 "$TMP/flow-2n2.md"
join_ok flow-normal-2
echo "PASS flow-normal-2-rounds"
claim_job flow-normal
open_ok flow-normal "$H1"
write_verdict_file "$TMP/flow-n1.md" PASS "$H1" 'round one'
verdict_ok flow-normal "$TMP/flow-n1.md"
open_ok flow-normal "$H2"
write_verdict_file "$TMP/flow-n2.md" BLOCKER "$H2" 'round two'
verdict_ok flow-normal "$TMP/flow-n2.md"
open_ok flow-normal "$H3"
write_verdict_file "$TMP/flow-n3.md" PASS "$H3" 'round three'
verdict_ok flow-normal "$TMP/flow-n3.md"
run_cmd "$WRK" round open flow-normal --head "$H4" --repo "$TEST_REPO"
assert_rc 78
[[ "$(kind_count flow-normal job.round)" -eq 3 ]] || fail "a normal job records three rounds"
[[ "$(kind_count flow-normal job.verdict)" -eq 3 ]] || fail "a normal job records three verdicts"
join_ok flow-normal
echo "PASS flow-normal-1-to-3-rounds"

echo "== flow-voided-round =="
claim_job flow-void
open_ok flow-void "$H1"
open_ok flow-void "$H2"
open_ok flow-void "$H3"
grant_doc void-flow "$(printf 'round-void: job=flow-void round=2 by=director-1\n')"
run_cmd "$WRK" round void flow-void 2 --by hk:doc/void-flow
assert_rc 0
status="$("$WRK" round status flow-void)"
grep -q 'round 2 void (hk:doc/void-flow)' <<<"$status" || fail "void must show on status: $status"
open_ok flow-void "$H4"
echo "PASS flow-voided-round"
# Rounds 1 and 3 are still open with no verdict: the join waits for one.
run_cmd "$WRK" joined flow-void --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: job flow-void has zero non-voided recorded rounds"
write_verdict_file "$TMP/flow-void-v.md" PASS "$H4" 'verdict after the void'
verdict_ok flow-void "$TMP/flow-void-v.md"
join_ok flow-void
echo "PASS flow-voided-round-then-verdict-then-joined"
claim_job flow-void-only
write_event "$ARBITER_INBOX_ROOT/flow-void-only/events/00002-job.round.json" <<EOF
{"kind":"job.round","job_id":"flow-void-only","round":1,"head":"$H1","created_at":"2026-10-23T00:00:01Z"}
EOF
write_event "$ARBITER_INBOX_ROOT/flow-void-only/events/00082-job.round_void.json" <<'EOF'
{"kind":"job.round_void","job_id":"flow-void-only","round":1,"ref":"hk:doc/void-only","created_at":"2026-10-23T00:00:04Z"}
EOF
run_cmd "$WRK" joined flow-void-only --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: job flow-void-only has zero non-voided recorded rounds"
open_ok flow-void-only "$H1"
run_cmd "$WRK" joined flow-void-only --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: job flow-void-only has zero non-voided recorded rounds"
write_verdict_file "$TMP/flow-void-only.md" PASS "$H1" 'verdict on the new round'
verdict_ok flow-void-only "$TMP/flow-void-only.md"
bound_round="$(verdict_field flow-void-only 0 round | tail -n 1)"
[[ "$bound_round" == "2" ]] || fail "verdict must skip the voided matching round, got $bound_round"
join_ok flow-void-only
echo "PASS flow-voided-only-cannot-join-until-a-new-round"

echo "== flow-takeover-inherited-rounds =="
claim_job flow-take
write_event "$ARBITER_INBOX_ROOT/flow-take/events/00002-job.takeover.json" <<'EOF'
{"kind":"job.takeover","job_id":"flow-take","created_at":"2026-10-23T00:00:05Z","payload":{"from_job":"old-job","rounds_used":3}}
EOF
run_cmd env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" "$WRK" round audit
assert_rc 0
if grep -q 'zero-rounds job=flow-take ' "$TMP/run.out"; then
  fail "inherited rounds must not look like zero recorded rounds"
fi
run_cmd "$WRK" round open flow-take --head "$H1" --repo "$TEST_REPO"
assert_rc 78
join_ok flow-take
echo "PASS flow-takeover-inherited-rounds"
claim_job flow-take-own
write_event "$ARBITER_INBOX_ROOT/flow-take-own/events/00002-job.takeover.json" <<'EOF'
{"kind":"job.takeover","job_id":"flow-take-own","created_at":"2026-10-23T00:00:05Z","payload":{"from_job":"old-job","rounds_used":1}}
EOF
open_ok flow-take-own "$H1"
write_verdict_file "$TMP/flow-take-own.md" PASS "$H1" 'the new builder own verdict'
verdict_ok flow-take-own "$TMP/flow-take-own.md"
bound_round="$(verdict_field flow-take-own 0 round | tail -n 1)"
[[ "$bound_round" == "2" ]] || fail "takeover builder verdict must bind to its own round 2, got $bound_round"
join_ok flow-take-own
claim_job flow-take-open
write_event "$ARBITER_INBOX_ROOT/flow-take-open/events/00002-job.takeover.json" <<'EOF'
{"kind":"job.takeover","job_id":"flow-take-open","created_at":"2026-10-23T00:00:05Z","payload":{"from_job":"old-job","rounds_used":1}}
EOF
open_ok flow-take-open "$H1"
join_ok flow-take-open
echo "PASS flow-takeover-own-verdict"

echo "== flow-round-extension =="
claim_job flow-ext
open_ok flow-ext "$H1"
write_verdict_file "$TMP/flow-ext-1.md" BLOCKER "$H1" 'ext round one'
verdict_ok flow-ext "$TMP/flow-ext-1.md"
open_ok flow-ext "$H2"
write_verdict_file "$TMP/flow-ext-2.md" BLOCKER "$H2" 'ext round two'
verdict_ok flow-ext "$TMP/flow-ext-2.md"
open_ok flow-ext "$H3"
write_verdict_file "$TMP/flow-ext-3.md" BLOCKER "$H3" 'ext round three'
verdict_ok flow-ext "$TMP/flow-ext-3.md"
run_cmd "$WRK" round open flow-ext --head "$H4" --repo "$TEST_REPO"
assert_rc 78
grant_doc ext-flow "$(printf 'round-extension: job=flow-ext extra=1 by=director-1\n')"
run_cmd "$WRK" round open flow-ext --head "$H4" --repo "$TEST_REPO" --extend hk:doc/ext-flow
assert_rc 0
grep -q 'round=4' "$TMP/run.out" || fail "extension must open round 4: $(cat "$TMP/run.out")"
echo "PASS flow-round-extension"
write_verdict_file "$TMP/flow-ext-4.md" PASS "$H4" 'ext round four'
verdict_ok flow-ext "$TMP/flow-ext-4.md"
[[ "$(verdict_field flow-ext 3 round | tail -n 1)" == "4" ]] || fail "the extension verdict must bind to round 4"
join_ok flow-ext
echo "PASS flow-round-extension-verdict-then-joined"

echo "== flow-duplicate-join-after-delegated =="
claim_job flow-dup
seed_round flow-dup
cat >"$TMP/pw-dup" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
if [ "$1" = "job" ] && [ "$2" = "joined" ]; then
  python3 -c 'import json,os,sys
root,job=sys.argv[1:]
events=os.path.join(root,job,"events")
os.makedirs(events,exist_ok=True)
doc={"kind":"job.joined","job_id":job,"owner_lane":"lane-a","label":"lbl","pane_id":"w:p1","pr":"u","head":"h","created_at":"2026-10-23T04:00:00Z"}
open(os.path.join(events,"00050-job.joined.json"),"w",encoding="utf-8").write(json.dumps(doc)+"\n")' \
    "$ARBITER_INBOX_ROOT" "$3"
  exit 42
fi
exit 42
EOF
chmod +x "$TMP/pw-dup"
run_cmd env WRK_JOB_DELEGATE=1 PANEWIRE_BIN="$TMP/pw-dup" \
  "$WRK" joined flow-dup --pr https://example.invalid/pr/9 --head "$H1" --report "$REPORT"
assert_rc 0
grep -q 'already recorded' "$TMP/run.err" || fail "duplicate join must warn: $(cat "$TMP/run.err")"
[[ "$(kind_count flow-dup job.joined)" -eq 1 ]] || fail "duplicate join must not write a second job.joined"
[[ "$(kind_count flow-dup job.revoked)" -eq 1 ]] || fail "duplicate join must still declare the hub end"
echo "PASS flow-duplicate-join-after-delegated"

echo "== flow-delegated-panewire-joined =="
claim_job flow-del
seed_round flow-del
cat >"$TMP/pw-ok" <<'EOF'
#!/bin/sh
if [ "$1" = "job" ] && [ "$2" = "probe" ]; then echo panewire-job/1; exit 0; fi
if [ "$1" = "job" ] && [ "$2" = "joined" ]; then
  printf '%s\n' "$*" >>"$PW_LOG"
  python3 -c 'import json,os,sys
root,job=sys.argv[1:]
events=os.path.join(root,job,"events")
os.makedirs(events,exist_ok=True)
doc={"kind":"job.joined","job_id":job,"owner_lane":"lane-a","label":"lbl","pane_id":"w:p1","pr":"u","head":"h","created_at":"2026-10-23T04:00:01Z"}
open(os.path.join(events,"00051-job.joined.json"),"w",encoding="utf-8").write(json.dumps(doc)+"\n")' \
    "$ARBITER_INBOX_ROOT" "$3"
  exit 0
fi
exit 42
EOF
chmod +x "$TMP/pw-ok"
: >"$TMP/pw-ok.log"
run_cmd env WRK_JOB_DELEGATE=1 PANEWIRE_BIN="$TMP/pw-ok" PW_LOG="$TMP/pw-ok.log" \
  "$WRK" joined flow-del --pr https://example.invalid/pr/8 --head "$H1" --report "$REPORT"
assert_rc 0
[[ "$(kind_count flow-del job.joined)" -eq 1 ]] || fail "delegated join must leave the stub record only"
if grep -q 'rounds-waived' "$TMP/pw-ok.log"; then
  fail "delegated argv must not contain rounds-waived: $(cat "$TMP/pw-ok.log")"
fi
grep -q -- '--pr' "$TMP/pw-ok.log" || fail "delegated argv lost --pr: $(cat "$TMP/pw-ok.log")"
[[ "$(kind_count flow-del job.revoked)" -eq 1 ]] || fail "delegated join must still declare the hub end"
echo "PASS flow-delegated-panewire-joined"

claim_job flow-del-open
open_ok flow-del-open "$H1"
: >"$TMP/pw-gate.log"
run_cmd env WRK_JOB_DELEGATE=1 PANEWIRE_BIN="$TMP/pw-ok" PW_LOG="$TMP/pw-gate.log" \
  "$WRK" joined flow-del-open --pr https://example.invalid/pr/8 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: job flow-del-open has zero non-voided recorded rounds"
[[ ! -s "$TMP/pw-gate.log" ]] || fail "a refused join must not reach panewire: $(cat "$TMP/pw-gate.log")"
[[ "$(kind_count flow-del-open job.joined)" -eq 0 ]] || fail "refused delegated join wrote job.joined"
echo "PASS flow-delegated-joined-gated-before-handoff"

echo "== flow-parking-arcade-join =="
claim_job flow-pa pa-integrator
open_ok flow-pa "$H2"
write_verdict_file "$TMP/flow-pa.md" PASS "$H2" 'pa-integrator builder own round'
verdict_ok flow-pa "$TMP/flow-pa.md"
bound_round="$(verdict_field flow-pa 0 round | tail -n 1)"
[[ "$bound_round" == "1" ]] || fail "ParkingArcade builder verdict must bind to its own round 1, got $bound_round"
join_ok flow-pa
python3 -c 'import json,os,sys
root=sys.argv[1]
for name in os.listdir(os.path.join(root,"flow-pa","events")):
    doc=json.load(open(os.path.join(root,"flow-pa","events",name),encoding="utf-8"))
    if doc.get("kind")=="job.joined":
        assert doc.get("parent_lane")=="pa-integrator", doc
        raise SystemExit(0)
raise SystemExit("missing joined")
' "$ARBITER_INBOX_ROOT"
echo "PASS flow-parking-arcade-join"

echo "== hk1506-head-binding =="
claim_job bind-wrong-head
open_ok bind-wrong-head "$H1"
write_verdict_file "$TMP/bind-wrong-head.md" PASS "$H2" 'wrong-head round must stay open'
run_cmd "$WRK" round verdict bind-wrong-head --file "$TMP/bind-wrong-head.md"
assert_rc 2
assert_refused "wrk: round verdict: no open round for head $H2 on job bind-wrong-head (open: 1@${H1:0:7}); open one with wrk round open bind-wrong-head --head $H2"
[[ "$(kind_count bind-wrong-head job.verdict)" -eq 0 ]] || fail "wrong-head verdict wrote a job.verdict"
status="$("$WRK" round status bind-wrong-head)"
grep -q 'rounds=1' <<<"$status" || fail "wrong-head refusal must preserve the stale round count: $status"
grep -q 'open=1' <<<"$status" || fail "wrong-head refusal must leave round 1 open: $status"
open_ok bind-wrong-head "$H2"
verdict_ok bind-wrong-head "$TMP/bind-wrong-head.md"
bound="$(verdict_field bind-wrong-head 0 round | tail -n 1)"
[[ "$bound" == "2" ]] || fail "same file must bind to the later matching round, got $bound"
echo "PASS hk1506-wrong-head-refused-then-retried"

claim_job bind-x-y
open_ok bind-x-y "$H1"
open_ok bind-x-y "$H2"
write_verdict_file "$TMP/bind-x-y.md" PASS "$H2" 'the matching second round'
verdict_ok bind-x-y "$TMP/bind-x-y.md"
bound="$(verdict_field bind-x-y 0 round | tail -n 1)"
[[ "$bound" == "2" ]] || fail "X/Y verdict must bind to matching round 2, got $bound"
status="$("$WRK" round status bind-x-y)"
grep -q 'open=1' <<<"$status" || fail "the nonmatching X round must remain open: $status"
echo "PASS hk1506-x-y-binds-matching-round"

claim_job bind-same-head
open_ok bind-same-head "$H1"
open_ok bind-same-head "$H1"
write_verdict_file "$TMP/bind-same-head.md" PASS "$H1" 'oldest matching round wins'
verdict_ok bind-same-head "$TMP/bind-same-head.md"
bound="$(verdict_field bind-same-head 0 round | tail -n 1)"
[[ "$bound" == "1" ]] || fail "same-head verdict must bind to oldest round 1, got $bound"
status="$("$WRK" round status bind-same-head)"
grep -q 'open=2' <<<"$status" || fail "newer same-head round must remain open: $status"
echo "PASS hk1506-two-same-heads-oldest-wins"

claim_job bind-uppercase
upper_h1="$(printf '%s' "$H1" | tr '[:lower:]' '[:upper:]')"
open_ok bind-uppercase "$upper_h1"
write_verdict_file "$TMP/bind-uppercase.md" PASS "$upper_h1" 'case folds on both heads'
verdict_ok bind-uppercase "$TMP/bind-uppercase.md"
bound="$(verdict_field bind-uppercase 0 round | tail -n 1)"
[[ "$bound" == "1" ]] || fail "upper-case head must bind round 1, got $bound"
stored_head="$(verdict_field bind-uppercase 0 head | tail -n 1)"
[[ "$stored_head" == "$H1" ]] || fail "verdict head must stay normalized: $stored_head"
echo "PASS hk1506-uppercase-heads-match"

claim_job bind-none
write_verdict_file "$TMP/bind-none.md" PASS "$H1" 'no open round'
run_cmd "$WRK" round verdict bind-none --file "$TMP/bind-none.md"
assert_rc 2
assert_refused "wrk: round verdict: job bind-none has no open round; open one with wrk round open bind-none --head $H1"
[[ "$(kind_count bind-none job.verdict)" -eq 0 ]] || fail "no-open refusal wrote a job.verdict"
[[ "$(kind_count bind-none job.escalate)" -eq 0 ]] || fail "no-open refusal emitted a cap escalation"
echo "PASS hk1506-no-open-round-refused"

claim_job bind-no-head
write_event "$ARBITER_INBOX_ROOT/bind-no-head/events/00002-job.round.json" <<'EOF'
{"kind":"job.round","job_id":"bind-no-head","round":1,"created_at":"2026-10-23T00:00:01Z"}
EOF
write_verdict_file "$TMP/bind-no-head.md" PASS "$H1" 'round without a head must not match'
run_cmd "$WRK" round verdict bind-no-head --file "$TMP/bind-no-head.md"
assert_rc 2
assert_refused "wrk: round verdict: no open round for head $H1 on job bind-no-head (open: 1@<no-head>); open one with wrk round open bind-no-head --head $H1"
[[ "$(kind_count bind-no-head job.verdict)" -eq 0 ]] || fail "headless round must not bind"
echo "PASS hk1506-round-without-head-never-matches"

claim_job bind-voided-no-later
open_ok bind-voided-no-later "$H1"
write_event "$ARBITER_INBOX_ROOT/bind-voided-no-later/events/00003-job.round_void.json" <<'EOF'
{"kind":"job.round_void","job_id":"bind-voided-no-later","round":1,"ref":"hk:task/1981","created_at":"2026-10-23T00:00:02Z"}
EOF
write_verdict_file "$TMP/bind-voided-no-later.md" PASS "$H1" 'voided round cannot bind'
run_cmd "$WRK" round verdict bind-voided-no-later --file "$TMP/bind-voided-no-later.md"
assert_rc 2
assert_refused "wrk: round verdict: job bind-voided-no-later has no open round; open one with wrk round open bind-voided-no-later --head $H1"
[[ "$(kind_count bind-voided-no-later job.verdict)" -eq 0 ]] || fail "voided-only round must not bind"
echo "PASS hk1506-voided-only-round-refused"

# A historical unbound verdict remains visible to census, cap, status, audit,
# and join readers even though new verdict commands cannot create one.
claim_job unbound-reader
write_event "$ARBITER_INBOX_ROOT/unbound-reader/events/00002-job.verdict.json" <<EOF
{"kind":"job.verdict","job_id":"unbound-reader","round":null,"head":"$H1","verdict":"PASS","created_at":"2026-10-23T00:00:02Z"}
EOF
status="$("$WRK" round status unbound-reader)"
grep -q 'rounds=1' <<<"$status" || fail "round status must count the historical unbound verdict: $status"
audit="$("$WRK" round audit --lane lane-a)"
if grep -q 'zero-rounds job=unbound-reader' <<<"$audit"; then
  fail "round audit must count the historical unbound verdict: $audit"
fi
join_ok unbound-reader
echo "PASS hk1506-unbound-verdict-readers-unchanged"

# ── dodges named by the tester brief ───────────────────────────────────
claim_job dodge-crlf
open_ok dodge-crlf "$H1"
write_verdict_file "$TMP/dodge-lf.md" PASS "$H1" 'crlf body'
verdict_ok dodge-crlf "$TMP/dodge-lf.md"
python3 -c 'import sys; data=open(sys.argv[1],"rb").read().replace(b"\n", b"\r\n"); open(sys.argv[2],"wb").write(data)' \
  "$TMP/dodge-lf.md" "$TMP/dodge-crlf.md"
run_cmd "$WRK" round verdict dodge-crlf --file "$TMP/dodge-crlf.md"
assert_refused "wrk: round verdict: head $H1 already recorded as $(python3 -c 'import json,os,sys
root=sys.argv[1]
for name in sorted(os.listdir(os.path.join(root,"dodge-crlf","events"))):
    doc=json.load(open(os.path.join(root,"dodge-crlf","events",name),encoding="utf-8"))
    if doc.get("kind")=="job.verdict":
        print(name); break' "$ARBITER_INBOX_ROOT")"
[[ "$(kind_count dodge-crlf job.verdict)" -eq 1 ]] || fail "CRLF variant must not be recorded as new content"
echo "PASS dodge-crlf-same-head-refused"

claim_job dodge-ws
open_ok dodge-ws "$H2"
write_verdict_file "$TMP/dodge-ws-1.md" PASS "$H2" 'ws body'
verdict_ok dodge-ws "$TMP/dodge-ws-1.md"
printf 'ws body\nVERDICT: PASS @%s   \n' "$H2" >"$TMP/dodge-ws-2.md"
run_cmd "$WRK" round verdict dodge-ws --file "$TMP/dodge-ws-2.md"
[[ "$RUN_RC" -ne 0 ]] || fail "trailing whitespace must not be accepted as a new head"
grep -q "head $H2 already recorded" "$TMP/run.err" || fail "whitespace variant must hit the head check: $(cat "$TMP/run.err")"
if grep -q 'verdict content' "$TMP/run.err"; then
  fail "whitespace variant must not match the content hash"
fi
echo "PASS dodge-trailing-whitespace-same-head"

claim_job dodge-sub
seed_round dodge-sub
mkdir -p "$ARBITER_INBOX_ROOT/dodge-sub/nested"
write_verdict_file "$ARBITER_INBOX_ROOT/dodge-sub/nested/hidden.md" BLOCKER "$H3" 'hidden'
join_ok dodge-sub
echo "PASS dodge-subdir-ignored"

claim_job dodge-link
seed_round dodge-link
write_verdict_file "$TMP/dodge-link-target.md" BLOCKER "$H4" 'outside'
ln -s "$TMP/dodge-link-target.md" "$ARBITER_INBOX_ROOT/dodge-link/link.md"
join_ok dodge-link
echo "PASS dodge-symlink-ignored"

set_times() { # set_times path mtime
  python3 -c 'import os,sys; os.utime(sys.argv[1],(int(sys.argv[2]),int(sys.argv[2])))' "$1" "$2"
}
plant_same_second() { # plant_same_second job reclaim_name revoked_name reclaim_mtime revoked_mtime
  local job="$1" reclaim_name="$2" revoked_name="$3" reclaim_m="$4" revoked_m="$5"
  local events="$ARBITER_INBOX_ROOT/$job/events"
  mkdir -p "$events" "$ARBITER_INBOX_ROOT/$job"
  write_event "$events/00001-job.claim.json" <<EOF
{"kind":"job.claim","job_id":"$job","created_at":"2026-10-23T05:00:00Z","owner_lane":"lane-a","label":"lbl","pane_id":"w:p1","parent_lane":"director-1","role":"builder"}
EOF
  write_event "$events/$reclaim_name" <<EOF
{"kind":"job.reclaim","job_id":"$job","created_at":"2026-10-23T05:00:00Z","owner_lane":"lane-a","label":"lbl","pane_id":"w:p1","parent_lane":"director-1","role":"builder"}
EOF
  write_event "$events/$revoked_name" <<EOF
{"kind":"job.revoked","job_id":"$job","created_at":"2026-10-23T05:00:00Z"}
EOF
  set_times "$events/00001-job.claim.json" 100
  set_times "$events/$reclaim_name" "$reclaim_m"
  set_times "$events/$revoked_name" "$revoked_m"
}

plant_same_second dodge-allow-m 00002-job.reclaim.json 00003-job.revoked.json 300 200
seed_round dodge-allow-m 1 2026-10-23T04:00:00Z
join_ok dodge-allow-m
echo "PASS dodge-same-second-mtime-revive-wins"

plant_same_second dodge-deny-m 00003-job.reclaim.json 00002-job.revoked.json 100 300
run_cmd "$WRK" joined dodge-deny-m --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: refused after end record 00002-job.revoked.json"
echo "PASS dodge-same-second-mtime-end-wins"

plant_same_second dodge-allow-n 00003-job.reclaim.json 00002-job.revoked.json 150 150
seed_round dodge-allow-n 1 2026-10-23T04:00:00Z
join_ok dodge-allow-n
echo "PASS dodge-same-second-name-revive-wins"

plant_same_second dodge-deny-n 00002-job.reclaim.json 00003-job.revoked.json 150 150
run_cmd "$WRK" joined dodge-deny-n --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: refused after end record 00003-job.revoked.json"
echo "PASS dodge-same-second-name-end-wins"

# ── hk 1900 (a): an open round with no verdict is not a join round ──────
echo "== e-open-round-without-verdict =="
claim_job e-open
open_ok e-open "$H2"
run_cmd "$WRK" joined e-open --pr https://example.invalid/pr/1900 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: job e-open has zero non-voided recorded rounds"
[[ "$(kind_count e-open job.joined)" -eq 0 ]] || fail "open-then-join wrote job.joined"
write_verdict_file "$TMP/e-open.md" PASS "$H2" 'verdict recorded after the open'
verdict_ok e-open "$TMP/e-open.md"
join_ok e-open
echo "PASS e-open-round-without-verdict-cannot-join"

# A verdict-bound round whose void record was planted later still counts: a void
# only takes effect on a round that holds no verdict.
claim_job e-bound-void
open_ok e-bound-void "$H2"
write_verdict_file "$TMP/e-bound-void.md" PASS "$H2" 'bound before the void'
verdict_ok e-bound-void "$TMP/e-bound-void.md"
write_event "$ARBITER_INBOX_ROOT/e-bound-void/events/00093-job.round_void.json" <<'EOF'
{"kind":"job.round_void","job_id":"e-bound-void","round":1,"ref":"hk:task/1900","created_at":"2026-10-23T00:40:00Z"}
EOF
join_ok e-bound-void
echo "PASS e-verdict-bound-round-later-voided-still-counts"

# wrk done for a builder that opened a round and never recorded a verdict: one
# warning, and the done still lands.
claim_job e-open-done
open_ok e-open-done "$H1"
run_cmd "$WRK" 'done' e-open-done --report "$REPORT"
assert_rc 0
grep -q "OK job=e-open-done " "$TMP/run.out" || fail "done stdout: $(cat "$TMP/run.out")"
[[ "$(grep -c 'ROUNDS job=' "$TMP/run.err")" -eq 1 ]] || fail "done must warn once: $(cat "$TMP/run.err")"
grep -q "wrk: warning: ROUNDS job=e-open-done has zero non-voided recorded rounds; wrk joined would refuse" "$TMP/run.err" ||
  fail "open-only done warning text: $(cat "$TMP/run.err")"
[[ "$(kind_count e-open-done job.completed)" -eq 1 ]] || fail "open-only done must still write job.completed"
echo "PASS e-open-round-done-warns-once-and-succeeds"

# ── hk 1900 (b): the end record and the gate are rechecked inside the lock ──
# WRK_TEST_JOINED_PRECOMMIT_HOOK names a script that wrk runs under the events
# lock, after the pre-check and before the commit, and only with WRK_TEST_MODE=1.
echo "== f-inlock-recheck =="
RACE_HOOK="$TMP/race-revoke-hook"
cat >"$RACE_HOOK" <<'EOF'
#!/bin/sh
# $1 = events dir, $2 = job id: an end record lands after the pre-check.
printf '{"kind":"job.revoked","job_id":"%s","created_at":"2026-10-23T09:00:00Z"}\n' "$2" >"$1/00099-job.revoked.json"
EOF
chmod +x "$RACE_HOOK"
ZERO_HOOK="$TMP/race-zero-hook"
cat >"$ZERO_HOOK" <<'EOF'
#!/bin/sh
# $1 = events dir: the only verdict is removed after the pre-check.
rm -f "$1/seed-job.verdict.json"
EOF
chmod +x "$ZERO_HOOK"

claim_job f-race-ok
seed_round f-race-ok
join_ok f-race-ok
echo "PASS f-same-flow-joins-without-the-hook"

claim_job f-race
seed_round f-race
run_cmd env WRK_TEST_JOINED_PRECOMMIT_HOOK="$RACE_HOOK" \
  "$WRK" joined f-race --pr https://example.invalid/pr/1900 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: refused after end record 00099-job.revoked.json"
[[ "$(kind_count f-race job.joined)" -eq 0 ]] || fail "a join racing an end record wrote job.joined"
[[ "$(kind_count f-race job.revoked)" -eq 1 ]] || fail "the racing end record must be the only terminal"
echo "PASS f-inlock-end-record-refused"

claim_job f-race-waived
seed_round f-race-waived
grant_task 1900 director-1 "join-waiver: job=f-race-waived by=director-1"
run_cmd env WRK_TEST_JOINED_PRECOMMIT_HOOK="$RACE_HOOK" \
  "$WRK" joined f-race-waived --pr https://example.invalid/pr/1900 --head "$H1" --report "$REPORT" --rounds-waived hk:task/1900
assert_refused "wrk: joined: refused after end record 00099-job.revoked.json"
[[ "$(kind_count f-race-waived job.joined)" -eq 0 ]] || fail "a waiver must not override an end record"
echo "PASS f-inlock-end-record-not-waivable"

claim_job f-race-zero
seed_round f-race-zero
run_cmd env WRK_TEST_JOINED_PRECOMMIT_HOOK="$ZERO_HOOK" \
  "$WRK" joined f-race-zero --pr https://example.invalid/pr/1900 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: job f-race-zero has zero non-voided recorded rounds"
[[ "$(kind_count f-race-zero job.joined)" -eq 0 ]] || fail "a join that lost its last verdict wrote job.joined"
echo "PASS f-inlock-zero-rounds-refused"

claim_job f-race-zero-waived
seed_round f-race-zero-waived
grant_task 1900 director-1 "join-waiver: job=f-race-zero-waived by=director-1"
run_cmd env WRK_TEST_JOINED_PRECOMMIT_HOOK="$ZERO_HOOK" \
  "$WRK" joined f-race-zero-waived --pr https://example.invalid/pr/1900 --head "$H1" --report "$REPORT" --rounds-waived hk:task/1900
assert_rc 0
[[ "$(kind_count f-race-zero-waived job.joined)" -eq 1 ]] || fail "a waived join skips the zero-rounds recheck"
echo "PASS f-inlock-zero-recheck-skipped-with-waiver"

# The hook is a test seam: outside WRK_TEST_MODE=1 it must not run at all.
python3 - "$WRK" "$TMP" <<'PY'
import os, re, sys
wrk, tmp = sys.argv[1:]
src = open(wrk, encoding="utf-8").read()
match = re.search(r"^WRK_EVENTS_PY='\n(.*?)\n'$", src, re.S | re.M)
assert match, "WRK_EVENTS_PY block not found"
space = {}
exec(match.group(1), space)
hook = os.path.join(tmp, "marker-hook")
marker = os.path.join(tmp, "marker-ran")
with open(hook, "w", encoding="utf-8") as handle:
    handle.write("#!/bin/sh\n: >%s\n" % marker)
os.chmod(hook, 0o755)
events = os.path.join(tmp, "marker-events")
os.makedirs(events, exist_ok=True)
call = space["wrk_precommit_test_hook"]
os.environ["WRK_TEST_JOINED_PRECOMMIT_HOOK"] = hook
for mode in (None, "", "0", "true", "yes", "2"):
    if mode is None:
        os.environ.pop("WRK_TEST_MODE", None)
    else:
        os.environ["WRK_TEST_MODE"] = mode
    call(events, "job-x")
    assert not os.path.exists(marker), "hook ran with WRK_TEST_MODE=%r" % (mode,)
os.environ["WRK_TEST_MODE"] = "1"
call(events, "job-x")
assert os.path.exists(marker), "hook must run under WRK_TEST_MODE=1"
os.unlink(marker)
del os.environ["WRK_TEST_JOINED_PRECOMMIT_HOOK"]
call(events, "job-x")
assert not os.path.exists(marker), "no hook variable, nothing to run"
PY
echo "PASS f-hook-inert-outside-test-mode"

# ── hk 1900 (c): a verdict file with a non-UTF-8 byte is read, not skipped ──
echo "== g-non-utf8-verdict-file =="
claim_job g-badbyte
open_ok g-badbyte "$H1"
write_verdict_file "$TMP/g-clean.md" PASS "$H1" 'clean first verdict'
verdict_ok g-badbyte "$TMP/g-clean.md"
open_ok g-badbyte "$H2"
BAD_COPY="$ARBITER_INBOX_ROOT/g-badbyte/copy.md"
printf 'VERDICT: PASS @%s\nlater line with a bad byte \377 here\n' "$H2" >"$BAD_COPY"
bad_abs="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$BAD_COPY")"
run_cmd "$WRK" joined g-badbyte --pr https://example.invalid/pr/1900 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: unmatched tester verdict file $bad_abs"
[[ "$(kind_count g-badbyte job.joined)" -eq 0 ]] || fail "a non-UTF-8 copied verdict file must block the join"
run_cmd "$WRK" round verdict g-badbyte --file "$BAD_COPY"
assert_rc 0
grep -q "OK job=g-badbyte verdict=PASS head=$H2 round=2 " "$TMP/run.out" || fail "non-UTF-8 verdict file not recorded: $(cat "$TMP/run.out")"
[[ "$(kind_count g-badbyte job.verdict)" -eq 2 ]] || fail "the non-UTF-8 verdict file must be recorded as a job.verdict"
[[ "$(verdict_field g-badbyte 1 content_sha256 | tail -n 1)" == "$(file_sha "$BAD_COPY")" ]] ||
  fail "content_sha256 must stay over the raw bytes"
join_ok g-badbyte
echo "PASS g-non-utf8-copy-refused-then-recorded"

# CRLF line ends keep a VERDICT first line. A UTF-8 BOM in front of it does not:
# the line no longer starts with VERDICT, so the file is not a verdict file and
# round verdict finds no VERDICT line in it.
claim_job g-crlf
seed_round g-crlf
printf 'VERDICT: PASS @%s\r\nfindings\r\n' "$H3" >"$ARBITER_INBOX_ROOT/g-crlf/crlf.md"
crlf_abs="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$ARBITER_INBOX_ROOT/g-crlf/crlf.md")"
run_cmd "$WRK" joined g-crlf --pr https://example.invalid/pr/1900 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: unmatched tester verdict file $crlf_abs"
echo "PASS g-crlf-verdict-first-line-counts"
claim_job g-bom
seed_round g-bom
printf '\357\273\277VERDICT: PASS @%s\nfindings\n' "$H3" >"$ARBITER_INBOX_ROOT/g-bom/bom.md"
run_cmd "$WRK" round verdict g-bom --file "$ARBITER_INBOX_ROOT/g-bom/bom.md"
assert_refused "wrk: round verdict --file has no 'VERDICT: PASS|BLOCKER @<40-hex sha>' line: $ARBITER_INBOX_ROOT/g-bom/bom.md"
join_ok g-bom
echo "PASS g-bom-is-not-a-verdict-first-line"

# ── hk 1899: --rounds-waived fetches REF and verifies a join-waiver grant ──
# Grant line form, one exact line in the record:
#   join-waiver: job=<job> by=<issuer>
# The issuer must be an operator or the job parent lane (from the fixed set) and must
# equal the record server-set identity: a doc created_by or a task comment author.
echo "== h-waiver-grant =="
joined_waived() { # joined_waived job ref
  run_cmd "$WRK" joined "$1" --pr https://example.invalid/pr/1899 --head "$H1" --report "$REPORT" --rounds-waived "$2"
}

joined_field() { # joined_field job field
  python3 -c 'import json,os,sys
job,field,root=sys.argv[1:]
events=os.path.join(root,job,"events")
for name in sorted(os.listdir(events)):
    if not name.endswith(".json"):
        continue
    doc=json.load(open(os.path.join(events,name),encoding="utf-8"))
    if isinstance(doc,dict) and doc.get("kind")=="job.joined":
        print(doc.get(field,"<absent>"))
        raise SystemExit(0)
print("<no job.joined>")' "$1" "$2" "$ARBITER_INBOX_ROOT"
}

SHAPE_MSG="wrk: joined: --rounds-waived requires hk:doc/<key> or hk:task/<id>"
nogrant_msg() { # nogrant_msg job ref
  printf "wrk: joined: %s has no 'join-waiver: job=%s by=<parent-lane|operator>' grant backed by the record's server-set created_by (doc) or comment author (task)" "$2" "$1"
}

assert_waiver_refused() { # assert_waiver_refused job ref message
  joined_waived "$1" "$2"
  assert_refused "$3"
  [[ "$(kind_count "$1" job.joined)" -eq 0 ]] || fail "a refused waiver wrote job.joined for $1 ($2)"
}

# A made-up ref: the stub has no such record, so the fetch fails and nothing is written.
claim_job h-made-up
: >"$HK_CALL_LOG"
assert_waiver_refused h-made-up hk:doc/made-up-key "wrk: joined: waiver record not found in handoffkeep: hk:doc/made-up-key"
grep -qxF 'doc get made-up-key' "$HK_CALL_LOG" || fail "a well-shaped ref must be fetched: $(cat "$HK_CALL_LOG")"
assert_waiver_refused h-made-up hk:task/4040 "wrk: joined: waiver record not found in handoffkeep: hk:task/4040"
grep -qxF 'tasks comments 4040' "$HK_CALL_LOG" || fail "a task ref must be fetched with tasks comments: $(cat "$HK_CALL_LOG")"
echo "PASS h-made-up-ref-refused"

# A real doc whose body holds the grant line and whose created_by is the issuer.
claim_job h-doc
grant_doc h-doc-grant "join-waiver: job=h-doc by=director-1"
joined_waived h-doc hk:doc/h-doc-grant
assert_rc 0
grep -q "OK job=h-doc " "$TMP/run.out" || fail "waived join stdout: $(cat "$TMP/run.out")"
[[ "$(kind_count h-doc job.joined)" -eq 1 ]] || fail "a verified waiver must write one job.joined"
[[ "$(joined_field h-doc rounds_waived)" == "hk:doc/h-doc-grant" ]] || fail "rounds_waived: $(joined_field h-doc rounds_waived)"
[[ "$(joined_field h-doc rounds_waived_issuer)" == "director-1" ]] || fail "rounds_waived_issuer: $(joined_field h-doc rounds_waived_issuer)"
echo "PASS h-doc-waiver-accepted-on-zero-rounds"

# Several lines: only a later one is the grant line.
claim_job h-doc-later
grant_doc h-doc-later-grant "$(printf 'reason: the tester host was down\njoin-waiver: job=other-job by=director-1\njoin-waiver: job=h-doc-later by=director-1\n')"
joined_waived h-doc-later hk:doc/h-doc-later-grant
assert_rc 0
[[ "$(joined_field h-doc-later rounds_waived_issuer)" == "director-1" ]] || fail "a later grant line must count"
echo "PASS h-doc-waiver-later-line-accepted"

# The same through a task comment.
claim_job h-task
grant_task 5101 someone-else "a comment from another author"
grant_task 5101 director-1 "$(printf 'join-waiver: job=h-task by=director-1')"
joined_waived h-task hk:task/5101
assert_rc 0
[[ "$(joined_field h-task rounds_waived)" == "hk:task/5101" ]] || fail "rounds_waived: $(joined_field h-task rounds_waived)"
[[ "$(joined_field h-task rounds_waived_issuer)" == "director-1" ]] || fail "rounds_waived_issuer: $(joined_field h-task rounds_waived_issuer)"
grep -qxF 'tasks comments 5101' "$HK_CALL_LOG" || fail "task waiver must be fetched with tasks comments"
echo "PASS h-task-waiver-accepted"

# Operators are accepted wherever the record is server-stamped by the same identity.
claim_job h-operator
grant_doc h-operator-grant "join-waiver: job=h-operator by=operator" operator
joined_waived h-operator hk:doc/h-operator-grant
assert_rc 0
[[ "$(joined_field h-operator rounds_waived_issuer)" == "operator" ]] || fail "operator issuer not recorded"
echo "PASS h-operator-waiver-accepted"

# Refused, each with no job.joined.
claim_job h-other-job
grant_doc h-other-job-grant "join-waiver: job=h-another by=director-1"
assert_waiver_refused h-other-job hk:doc/h-other-job-grant "$(nogrant_msg h-other-job hk:doc/h-other-job-grant)"
echo "PASS h-grant-for-another-job-refused"

claim_job h-forged
grant_doc h-forged-grant "join-waiver: job=h-forged by=director-1" the-builder
assert_waiver_refused h-forged hk:doc/h-forged-grant "$(nogrant_msg h-forged hk:doc/h-forged-grant)"
grant_task 5102 the-builder "join-waiver: job=h-forged by=director-1"
assert_waiver_refused h-forged hk:task/5102 "$(nogrant_msg h-forged hk:task/5102)"
echo "PASS h-issuer-not-the-server-identity-refused"

claim_job h-outsider
grant_doc h-outsider-grant "join-waiver: job=h-outsider by=the-builder" the-builder
assert_waiver_refused h-outsider hk:doc/h-outsider-grant "$(nogrant_msg h-outsider hk:doc/h-outsider-grant)"
# pa-integrator is trusted only as the recorded parent lane of the job, not as a bystander.
grant_doc h-outsider-pa "join-waiver: job=h-outsider by=pa-integrator" pa-integrator
assert_waiver_refused h-outsider hk:doc/h-outsider-pa "$(nogrant_msg h-outsider hk:doc/h-outsider-pa)"
echo "PASS h-issuer-outside-the-allowed-set-refused"

claim_job h-other-kind
grant_doc h-void-line "round-void: job=h-other-kind round=1 by=director-1"
assert_waiver_refused h-other-kind hk:doc/h-void-line "$(nogrant_msg h-other-kind hk:doc/h-void-line)"
grant_doc h-ext-line "round-extension: job=h-other-kind extra=1 by=director-1"
assert_waiver_refused h-other-kind hk:doc/h-ext-line "$(nogrant_msg h-other-kind hk:doc/h-ext-line)"
echo "PASS h-other-grant-kinds-refused"

claim_job h-spaces
SP_LINE="join-waiver: job=h-spaces by=director-1"
SP_VARIANTS=(
  "join-waiver:  job=h-spaces by=director-1"
  "join-waiver: job=h-spaces  by=director-1"
  " $SP_LINE"
  "$SP_LINE "
  "$SP_LINE and more"
  "$(printf 'join-waiver:\tjob=h-spaces by=director-1')"
  "see $SP_LINE"
  "> $SP_LINE"
  "Join-Waiver: job=h-spaces by=director-1"
  "join-waiver job=h-spaces by=director-1"
  "join-waiver: job=h-spaces by="
  "join-waiver: by=director-1 job=h-spaces"
)
n=0
for variant in "${SP_VARIANTS[@]}"; do
  n=$((n + 1))
  grant_doc "h-spaces-$n" "$variant"
  assert_waiver_refused h-spaces "hk:doc/h-spaces-$n" "$(nogrant_msg h-spaces "hk:doc/h-spaces-$n")"
done
[[ "$n" -eq 12 ]] || fail "expected 12 whitespace and shape variants, ran $n"
echo "PASS h-whitespace-variants-refused"

# A join-waiver line is not a grant for the other two kinds.
claim_job h-cross
open_ok h-cross "$H1"
grant_doc h-cross-grant "join-waiver: job=h-cross by=director-1"
run_cmd "$WRK" round void h-cross 1 --by hk:doc/h-cross-grant
[[ "$RUN_RC" -ne 0 ]] || fail "a join-waiver line must not void a round"
grep -q "round void --by: hk:doc/h-cross-grant has no matching 'round-void: job=h-cross round=1 by=" "$TMP/run.err" || fail "round void on a join-waiver doc: $(cat "$TMP/run.err")"
echo "PASS h-join-waiver-does-not-void-or-extend"

# pa-integrator grants also need the ParkingArcade server task, as round void does.
echo "== h-waiver-pa-integrator =="
PA_HEAD="wrk: joined: pa-integrator grants need the job's hk task on the server;"
claim_job h-pa-ok pa-integrator 2026-10-23T00:00:00Z builder lane-a 7001
task_record 7001 ParkingArcade h-pa-ok
grant_doc h-pa-ok-grant "join-waiver: job=h-pa-ok by=pa-integrator" pa-integrator
joined_waived h-pa-ok hk:doc/h-pa-ok-grant
assert_rc 0
[[ "$(joined_field h-pa-ok rounds_waived_issuer)" == "pa-integrator" ]] || fail "pa-integrator issuer not recorded"
grep -qxF 'tasks show 7001' "$HK_CALL_LOG" || fail "the pa-integrator check must read the server task"
echo "PASS h-pa-integrator-waiver-accepted"

claim_job h-pa-notask pa-integrator
grant_doc h-pa-notask-grant "join-waiver: job=h-pa-notask by=pa-integrator" pa-integrator
assert_waiver_refused h-pa-notask hk:doc/h-pa-notask-grant "$PA_HEAD h-pa-notask records no task_id"
claim_job h-pa-nofetch pa-integrator 2026-10-23T00:00:00Z builder lane-a 7002
grant_doc h-pa-nofetch-grant "join-waiver: job=h-pa-nofetch by=pa-integrator" pa-integrator
assert_waiver_refused h-pa-nofetch hk:doc/h-pa-nofetch-grant "$PA_HEAD cannot fetch task 7002"
claim_job h-pa-project pa-integrator 2026-10-23T00:00:00Z builder lane-a 7003
task_record 7003 SomethingElse h-pa-project
grant_doc h-pa-project-grant "join-waiver: job=h-pa-project by=pa-integrator" pa-integrator
assert_waiver_refused h-pa-project hk:doc/h-pa-project-grant "wrk: joined: pa-integrator grants count only when the server task for h-pa-project is project ParkingArcade with refs.job_id=h-pa-project"
claim_job h-pa-refs pa-integrator 2026-10-23T00:00:00Z builder lane-a 7004
task_record 7004 ParkingArcade some-other-job
grant_doc h-pa-refs-grant "join-waiver: job=h-pa-refs by=pa-integrator" pa-integrator
assert_waiver_refused h-pa-refs hk:doc/h-pa-refs-grant "wrk: joined: pa-integrator grants count only when the server task for h-pa-refs is project ParkingArcade with refs.job_id=h-pa-refs"
echo "PASS h-pa-integrator-needs-the-parking-arcade-task"

# Shapes refused before any fetch. Each ref has a valid grant behind it in the stub, so only
# the shape check can refuse it; the stub records no call.
echo "== h-waiver-shape =="
claim_job h-shape
SHAPE_GRANT="join-waiver: job=h-shape by=director-1"
grant_doc 'a b' "$SHAPE_GRANT"
grant_doc 'a ' "$SHAPE_GRANT"
grant_doc ' a' "$SHAPE_GRANT"
grant_doc "$(printf 'a\nb')" "$SHAPE_GRANT"
grant_doc shape-key "$SHAPE_GRANT"
grant_task abc director-1 "$SHAPE_GRANT"
grant_task '1x' director-1 "$SHAPE_GRANT"
grant_task '-1' director-1 "$SHAPE_GRANT"
grant_task '12 ' director-1 "$SHAPE_GRANT"
grant_task ' 12' director-1 "$SHAPE_GRANT"
n=0
for bad in 'hk:task/abc' 'hk:task/' 'hk:doc/' 'hk:doc/a b' 'hk:doc/a ' 'hk:doc/ a' "$(printf 'hk:doc/a\nb')" \
  'hk:task/1x' 'hk:task/-1' 'hk:task/12 ' 'hk:task/ 12' 'shape-key' ' hk:doc/shape-key' 'hk:docs/shape-key' 'HK:DOC/shape-key'; do
  n=$((n + 1))
  : >"$HK_CALL_LOG"
  joined_waived h-shape "$bad"
  assert_refused "$SHAPE_MSG"
  [[ ! -s "$HK_CALL_LOG" ]] || fail "a malformed ref reached handoffkeep ($bad): $(cat "$HK_CALL_LOG")"
  [[ "$(kind_count h-shape job.joined)" -eq 0 ]] || fail "a malformed ref wrote job.joined ($bad)"
done
[[ "$n" -eq 15 ]] || fail "expected 15 malformed refs, ran $n"
echo "PASS h-malformed-refs-refused-before-any-fetch"

# An end record is checked before the fetch and cannot be waived.
claim_job h-ended
write_event "$ARBITER_INBOX_ROOT/h-ended/events/00002-job.revoked.json" <<'EOF'
{"kind":"job.revoked","job_id":"h-ended","created_at":"2026-10-23T01:00:00Z"}
EOF
grant_doc h-ended-grant "join-waiver: job=h-ended by=director-1"
: >"$HK_CALL_LOG"
joined_waived h-ended hk:doc/h-ended-grant
assert_refused "wrk: joined: refused after end record 00002-job.revoked.json"
[[ ! -s "$HK_CALL_LOG" ]] || fail "the end check must come before the fetch: $(cat "$HK_CALL_LOG")"
[[ "$(kind_count h-ended job.joined)" -eq 0 ]] || fail "a valid waiver must not override an end record"
echo "PASS h-end-record-still-refuses-a-valid-waiver"

# The waiver is verified before the events lock is taken: the test hook runs under the
# lock, so a refused waiver never reaches it and a verified one does.
WAIVER_HOOK="$TMP/waiver-lock-hook"
cat >"$WAIVER_HOOK" <<'EOF'
#!/bin/sh
: >"$WAIVER_MARKER"
EOF
chmod +x "$WAIVER_HOOK"
claim_job h-lock-refused
rm -f "$TMP/waiver-marker"
run_cmd env WRK_TEST_JOINED_PRECOMMIT_HOOK="$WAIVER_HOOK" WAIVER_MARKER="$TMP/waiver-marker" \
  "$WRK" joined h-lock-refused --pr https://example.invalid/pr/1899 --head "$H1" --report "$REPORT" --rounds-waived hk:doc/made-up-key
[[ "$RUN_RC" -ne 0 ]] || fail "a refused waiver must fail the join"
[[ ! -e "$TMP/waiver-marker" ]] || fail "a refused waiver reached the events lock"
claim_job h-lock-ok
grant_doc h-lock-ok-grant "join-waiver: job=h-lock-ok by=director-1"
run_cmd env WRK_TEST_JOINED_PRECOMMIT_HOOK="$WAIVER_HOOK" WAIVER_MARKER="$TMP/waiver-marker" \
  "$WRK" joined h-lock-ok --pr https://example.invalid/pr/1899 --head "$H1" --report "$REPORT" --rounds-waived hk:doc/h-lock-ok-grant
assert_rc 0
[[ -e "$TMP/waiver-marker" ]] || fail "a verified waiver must reach the events lock"
echo "PASS h-waiver-verified-before-the-lock"

# A verified waiver skips both refusals even on a job that has rounds and verdict files,
# which is what the usage text says: both refusals are waived only by a verified REF.
claim_job h-has-rounds
seed_round h-has-rounds
STRAY="$ARBITER_INBOX_ROOT/h-has-rounds/stray.md"
write_verdict_first "$STRAY" BLOCKER "$H4"
stray_abs="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$STRAY")"
run_cmd "$WRK" joined h-has-rounds --pr https://example.invalid/pr/1899 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: unmatched tester verdict file $stray_abs"
grant_doc h-has-rounds-grant "join-waiver: job=h-has-rounds by=director-1"
joined_waived h-has-rounds hk:doc/h-has-rounds-grant
assert_rc 0
[[ "$(joined_field h-has-rounds rounds_waived_issuer)" == "director-1" ]] || fail "waived join on a job with rounds"
echo "PASS h-waiver-skips-unmatched-file-on-a-job-with-rounds"

# The usage text names the fetch, the line form and who may issue it.
"$WRK" joined --help >"$TMP/joined-help.txt"
grep -qF 'join-waiver: job=<job> by=<issuer>' "$TMP/joined-help.txt" || fail "joined help must give the join-waiver line form"
grep -q 'fetched from handoffkeep' "$TMP/joined-help.txt" || fail "joined help must say the ref is fetched from handoffkeep"
grep -q 'parent lane or an operator' "$TMP/joined-help.txt" || fail "joined help must name who may issue the grant"
echo "PASS h-joined-help-names-the-grant"

# ── hk 2024: the claim a waiver was verified against is rechecked under the lock ──
# HK_FETCH_HOOK runs inside the waiver-record fetch: the window between the
# grant verify and the events-lock commit. The hook below models the job being
# released and reclaimed in that window — a quota_pool.release then a
# job.reclaim — so a waiver verified for the old claim must not land on the
# new one. A refused join writes nothing.
echo "== i-waiver-claim-recheck =="
CLAIM_RACE_HOOK="$TMP/claim-race-hook"
cat >"$CLAIM_RACE_HOOK" <<'EOF'
#!/bin/sh
# Runs once (RACE_MARKER): append a release to RACE_JOB's events and, when
# RACE_PARENT is set, a reclaim under that parent lane. RACE_TASK sets the
# reclaim's task_id; empty means none.
[ -f "$RACE_MARKER" ] && exit 0
: >"$RACE_MARKER"
ev="$ARBITER_INBOX_ROOT/$RACE_JOB/events"
printf '%s\n' "{\"kind\":\"quota_pool.release\",\"job_id\":\"$RACE_JOB\",\"created_at\":\"2026-10-23T05:00:00Z\",\"payload\":{\"job_id\":\"$RACE_JOB\",\"pool\":\"codex\"}}" \
  >"$ev/00090-quota_pool.release.json"
[ -n "${RACE_PARENT:-}" ] || exit 0
task=""
[ -z "${RACE_TASK:-}" ] || task=",\"task_id\":\"$RACE_TASK\""
printf '%s\n' "{\"kind\":\"job.reclaim\",\"job_id\":\"$RACE_JOB\",\"created_at\":\"2026-10-23T05:00:01Z\",\"owner_lane\":\"lane-a\",\"label\":\"lbl\",\"pane_id\":\"w:p1\",\"parent_lane\":\"$RACE_PARENT\",\"role\":\"builder\"$task}" \
  >"$ev/00091-job.reclaim.json"
EOF
chmod +x "$CLAIM_RACE_HOOK"

# Reclaimed under a different parent lane during the fetch: the verified
# parent_lane no longer matches, so the join is refused.
claim_job i-race-parent
grant_doc i-race-parent-grant "join-waiver: job=i-race-parent by=director-1"
run_cmd env HK_FETCH_HOOK="$CLAIM_RACE_HOOK" RACE_MARKER="$TMP/i-race-parent.done" \
  RACE_JOB=i-race-parent RACE_PARENT=rogue-lane \
  "$WRK" joined i-race-parent --pr https://example.invalid/pr/2024 --head "$H1" --report "$REPORT" --rounds-waived hk:doc/i-race-parent-grant
assert_refused "wrk: joined: claim changed since the waiver was verified (parent_lane director-1 -> rogue-lane); re-run wrk joined"
[[ "$(kind_count i-race-parent job.joined)" -eq 0 ]] || fail "a claim-change race wrote job.joined"
echo "PASS i-parent-lane-race-refused"

# Same parent lane, but the reclaim binds a different task_id: a pa-integrator
# grant verified against task 8001 must not land on the claim for task 8002.
claim_job i-race-task pa-integrator 2026-10-23T00:00:00Z builder lane-a 8001
task_record 8001 ParkingArcade i-race-task
grant_doc i-race-task-grant "join-waiver: job=i-race-task by=pa-integrator" pa-integrator
run_cmd env HK_FETCH_HOOK="$CLAIM_RACE_HOOK" RACE_MARKER="$TMP/i-race-task.done" \
  RACE_JOB=i-race-task RACE_PARENT=pa-integrator RACE_TASK=8002 \
  "$WRK" joined i-race-task --pr https://example.invalid/pr/2024 --head "$H1" --report "$REPORT" --rounds-waived hk:doc/i-race-task-grant
assert_refused "wrk: joined: claim changed since the waiver was verified (task_id 8001 -> 8002); re-run wrk joined"
[[ "$(kind_count i-race-task job.joined)" -eq 0 ]] || fail "a task_id race wrote job.joined"
echo "PASS i-task-id-race-refused"

# A reclaim by the same parent lane still replaces the claim: the claim
# version (the newest claim/reclaim event) changed, so the join is refused.
claim_job i-race-version
grant_doc i-race-version-grant "join-waiver: job=i-race-version by=director-1"
run_cmd env HK_FETCH_HOOK="$CLAIM_RACE_HOOK" RACE_MARKER="$TMP/i-race-version.done" \
  RACE_JOB=i-race-version RACE_PARENT=director-1 \
  "$WRK" joined i-race-version --pr https://example.invalid/pr/2024 --head "$H1" --report "$REPORT" --rounds-waived hk:doc/i-race-version-grant
assert_refused "wrk: joined: claim changed since the waiver was verified (claim_version 00001-job.claim.json -> 00091-job.reclaim.json); re-run wrk joined"
[[ "$(kind_count i-race-version job.joined)" -eq 0 ]] || fail "a same-parent reclaim wrote job.joined"
echo "PASS i-claim-version-race-refused"

# A release with no reclaim leaves the recorded claim untouched: the verified
# facts still hold and the waived join lands.
claim_job i-race-release-only
grant_doc i-race-release-only-grant "join-waiver: job=i-race-release-only by=director-1"
run_cmd env HK_FETCH_HOOK="$CLAIM_RACE_HOOK" RACE_MARKER="$TMP/i-race-release-only.done" \
  RACE_JOB=i-race-release-only RACE_PARENT= \
  "$WRK" joined i-race-release-only --pr https://example.invalid/pr/2024 --head "$H1" --report "$REPORT" --rounds-waived hk:doc/i-race-release-only-grant
assert_rc 0
[[ "$(kind_count i-race-release-only job.joined)" -eq 1 ]] || fail "release-only join must write job.joined"
[[ "$(joined_field i-race-release-only rounds_waived_issuer)" == "director-1" ]] || fail "rounds_waived_issuer: $(joined_field i-race-release-only rounds_waived_issuer)"
echo "PASS i-release-without-reclaim-joins"

# ── help and the one skill line each ───────────────────────────────────
"$WRK" --help >"$TMP/usage.txt"
grep -q 'round audit' "$TMP/usage.txt" || fail "usage must name round audit"
grep -q -- '--rounds-waived' "$TMP/usage.txt" || fail "usage must name --rounds-waived"
"$WRK" round --help >"$TMP/round-help.txt"
grep -q 'audit' "$TMP/round-help.txt" || fail "round help must name audit"
grep -q 'oldest open round on its own head and is refused when there is none' "$TMP/round-help.txt" ||
  fail "round help must explain per-head verdict binding"
builder_hits="$(grep -c 'rounds-waived' "$ROOT/builder/SKILL.md" || true)"
director_hits="$(grep -c 'rounds-waived' "$ROOT/director/SKILL.md" || true)"
[[ "$builder_hits" -eq 1 ]] || fail "builder skill must mention rounds-waived on exactly one line"
[[ "$director_hits" -eq 1 ]] || fail "director skill must mention rounds-waived on exactly one line"
echo "PASS help-and-skill-lines"

# ── hk 1970: a head-repeat grant lets a second verdict bind to a repeated head ──
echo "== hk1970-head-repeat =="
grep -q -- '--head-repeat REF' "$TMP/round-help.txt" || fail "round help must name --head-repeat REF"
grep -q 'head-repeat: job=JOB head=SHA round=N by=ISSUER' "$TMP/round-help.txt" || fail "round help must give the head-repeat line form"
hr_seed() { # hr_seed job [parent] [task_id]: round 1 BLOCKER and round 2 open on H1, PASS staged
  local job="$1" parent="${2:-director-1}" task_id="${3:-}"
  claim_job "$job" "$parent" 2026-10-23T00:00:00Z builder lane-a "$task_id"
  open_ok "$job" "$H1"
  write_verdict_file "$TMP/$job-block.md" BLOCKER "$H1" "$job round one"
  verdict_ok "$job" "$TMP/$job-block.md"
  open_ok "$job" "$H1"
  write_verdict_file "$TMP/$job-pass.md" PASS "$H1" "$job round two"
}
hr_verdict() { # hr_verdict job file ref
  run_cmd "$WRK" round verdict "$1" --file "$2" --head-repeat "$3"
}
hr_nogrant() { # hr_nogrant job head round ref: the exact no-grant refusal line
  printf "wrk: round verdict: %s has no 'head-repeat: job=%s head=%s round=%s by=<parent-lane|operator>' grant backed by the record's server-set created_by (doc) or comment author (task)" "$4" "$1" "$2" "$3"
}
hr_count() { kind_count "$1" job.verdict; }

# The hk 1964 sequence: round 1 BLOCKER at X, round 2 open at X, PASS at X.
hr_seed hr-seq
run_cmd "$WRK" round verdict hr-seq --file "$TMP/hr-seq-pass.md"
assert_refused "wrk: round verdict: head $H1 already recorded as $(verdict_field hr-seq 0 round | head -n 1)"
[[ "$(hr_count hr-seq)" -eq 1 ]] || fail "DUP_HEAD without the flag wrote a verdict"
hr_verdict hr-seq "$TMP/hr-seq-pass.md" hk:doc/hr-seq-made-up
assert_refused "wrk: round verdict: head-repeat record not found in handoffkeep: hk:doc/hr-seq-made-up"
grep -qxF 'doc get hr-seq-made-up' "$HK_CALL_LOG" || fail "a head-repeat ref must be fetched: $(cat "$HK_CALL_LOG")"
[[ "$(hr_count hr-seq)" -eq 1 ]] || fail "a made-up ref wrote a verdict"
echo "PASS hk1970-without-flag-and-made-up-ref-refused"

grant_doc hr-seq-grant "$(printf 'head-repeat: job=hr-seq head=%s round=2 by=director-1' "$H1")"
hr_verdict hr-seq "$TMP/hr-seq-pass.md" hk:doc/hr-seq-grant
assert_rc 0
grep -q "OK job=hr-seq verdict=PASS head=$H1 round=2 " "$TMP/run.out" || fail "head-repeat stdout: $(cat "$TMP/run.out")"
[[ "$(hr_count hr-seq)" -eq 2 ]] || fail "a verified grant must record the second verdict"
[[ "$(verdict_field hr-seq 1 round | tail -n 1)" == "2" ]] || fail "the second verdict must bind round 2"
[[ "$(verdict_field hr-seq 1 head_repeat | tail -n 1)" == "hk:doc/hr-seq-grant" ]] || fail "head_repeat not recorded"
[[ "$(verdict_field hr-seq 1 head_repeat_issuer | tail -n 1)" == "director-1" ]] || fail "head_repeat_issuer not recorded"
echo "PASS hk1970-hk1964-sequence-records-round-two"

# Used once: the same REF on a later round is refused even when one of its lines matches.
open_ok hr-seq "$H1"
grant_doc hr-seq-grant "$(printf 'head-repeat: job=hr-seq head=%s round=2 by=director-1\nhead-repeat: job=hr-seq head=%s round=3 by=director-1' "$H1" "$H1")"
write_verdict_file "$TMP/hr-seq-third.md" PASS "$H1" 'hr-seq round three'
hr_verdict hr-seq "$TMP/hr-seq-third.md" hk:doc/hr-seq-grant
assert_refused "wrk: round verdict: head_repeat_used hk:doc/hr-seq-grant: already recorded on a job.verdict of hr-seq"
[[ "$(hr_count hr-seq)" -eq 2 ]] || fail "a reused grant wrote a verdict"
echo "PASS hk1970-reused-grant-refused-even-with-a-matching-line"

# Refused, each with no job.verdict: the grant names the wrong job, head, round or kind,
# or its shape, issuer or identity is wrong.
hr_seed hr-refuse
refuse_grant() { # refuse_grant name body [created_by]: one refused grant, no verdict written
  grant_doc "$1" "$2" "${3:-director-1}"
  hr_verdict hr-refuse "$TMP/hr-refuse-pass.md" "hk:doc/$1"
  assert_refused "$(hr_nogrant hr-refuse "$H1" 2 "hk:doc/$1")"
  [[ "$(hr_count hr-refuse)" -eq 1 ]] || fail "refused grant $1 wrote a verdict"
}
refuse_grant hr-r-other-job "head-repeat: job=hr-other head=$H1 round=2 by=director-1"
refuse_grant hr-r-other-head "head-repeat: job=hr-refuse head=$H2 round=2 by=director-1"
refuse_grant hr-r-bound-round "head-repeat: job=hr-refuse head=$H1 round=1 by=director-1"
refuse_grant hr-r-unopened-round "head-repeat: job=hr-refuse head=$H1 round=3 by=director-1"
refuse_grant hr-r-upper-sha "head-repeat: job=hr-refuse head=$(printf '%s' "$H1" | tr '[:lower:]' '[:upper:]') round=2 by=director-1"
refuse_grant hr-r-short-sha "head-repeat: job=hr-refuse head=${H1:0:7} round=2 by=director-1"
refuse_grant hr-r-padded-round "head-repeat: job=hr-refuse head=$H1 round=02 by=director-1"
refuse_grant hr-r-outsider "head-repeat: job=hr-refuse head=$H1 round=2 by=someone-else" someone-else
refuse_grant hr-r-pa-not-parent "head-repeat: job=hr-refuse head=$H1 round=2 by=pa-integrator" pa-integrator
refuse_grant hr-r-forged "head-repeat: job=hr-refuse head=$H1 round=2 by=director-1" the-builder
refuse_grant hr-r-void-line "round-void: job=hr-refuse round=2 by=director-1"
refuse_grant hr-r-extension-line "round-extension: job=hr-refuse extra=1 by=director-1"
refuse_grant hr-r-waiver-line "join-waiver: job=hr-refuse by=director-1"
refuse_grant hr-r-mid-line "see head-repeat: job=hr-refuse head=$H1 round=2 by=director-1"
HR_LINE="head-repeat: job=hr-refuse head=$H1 round=2 by=director-1"
HR_VARIANTS=(
  "head-repeat:  job=hr-refuse head=$H1 round=2 by=director-1"
  "head-repeat: job=hr-refuse  head=$H1 round=2 by=director-1"
  " $HR_LINE"
  "$HR_LINE "
  "$HR_LINE and more"
  "$(printf 'head-repeat:\tjob=hr-refuse head=%s round=2 by=director-1' "$H1")"
  "> $HR_LINE"
  "Head-Repeat: job=hr-refuse head=$H1 round=2 by=director-1"
)
n=0
for variant in "${HR_VARIANTS[@]}"; do
  n=$((n + 1))
  refuse_grant "hr-r-space-$n" "$variant"
done
[[ "$n" -eq 8 ]] || fail "expected 8 whitespace and case variants, ran $n"
echo "PASS hk1970-refused-grant-lines-and-shapes"

# Identity comes first: a verdict with the same bytes or the same path is refused under a valid grant.
hr_seed hr-ident
grant_doc hr-ident-grant "head-repeat: job=hr-ident head=$H1 round=2 by=director-1"
cp "$TMP/hr-ident-block.md" "$TMP/hr-ident-copy.md"
hr_verdict hr-ident "$TMP/hr-ident-copy.md" hk:doc/hr-ident-grant
assert_refused "wrk: round verdict: verdict content $(file_sha "$TMP/hr-ident-copy.md") already recorded as $(verdict_field hr-ident 0 round | head -n 1)"
cp "$TMP/hr-ident-pass.md" "$TMP/hr-ident-block.md"
hr_verdict hr-ident "$TMP/hr-ident-block.md" hk:doc/hr-ident-grant
assert_refused "wrk: round verdict: verdict path already recorded as $(verdict_field hr-ident 0 round | head -n 1): $(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TMP/hr-ident-block.md")"
[[ "$(hr_count hr-ident)" -eq 1 ]] || fail "identity refusals wrote a verdict"
hr_verdict hr-ident "$TMP/hr-ident-pass.md" hk:doc/hr-ident-grant
assert_rc 0
echo "PASS hk1970-identity-refuses-before-any-grant"

# A fresh head needs no grant: the flag is refused before the grant is fetched.
claim_job hr-fresh
open_ok hr-fresh "$H3"
write_verdict_file "$TMP/hr-fresh.md" PASS "$H3" 'fresh head'
grant_doc hr-fresh-grant "head-repeat: job=hr-fresh head=$H3 round=1 by=director-1"
hr_verdict hr-fresh "$TMP/hr-fresh.md" hk:doc/hr-fresh-grant
assert_refused "wrk: round verdict: head_repeat_not_needed: head $H3 has no earlier job.verdict on hr-fresh; drop --head-repeat"
[[ "$(hr_count hr-fresh)" -eq 0 ]] || fail "a fresh head with the flag wrote a verdict"
if grep -q 'doc get hr-fresh-grant' "$HK_CALL_LOG"; then fail "a fresh head must refuse before fetching the grant"; fi
echo "PASS hk1970-fresh-head-needs-no-grant"

# A repeated head with no open round still refuses as DUP_HEAD.
claim_job hr-noopen
open_ok hr-noopen "$H1"
write_verdict_file "$TMP/hr-noopen-block.md" BLOCKER "$H1" 'no open round'
verdict_ok hr-noopen "$TMP/hr-noopen-block.md"
write_verdict_file "$TMP/hr-noopen-pass.md" PASS "$H1" 'no open round two'
grant_doc hr-noopen-grant "head-repeat: job=hr-noopen head=$H1 round=2 by=director-1"
hr_verdict hr-noopen "$TMP/hr-noopen-pass.md" hk:doc/hr-noopen-grant
assert_refused "wrk: round verdict: head $H1 already recorded as $(verdict_field hr-noopen 0 round | head -n 1)"
[[ "$(hr_count hr-noopen)" -eq 1 ]] || fail "a grant with no open round wrote a verdict"
echo "PASS hk1970-no-open-round-still-refuses-duplicate-head"

# The grant binds the oldest open round on the head (hk 1506 rule), not a newer one.
hr_seed hr-newer
open_ok hr-newer "$H1"
grant_doc hr-newer-late "head-repeat: job=hr-newer head=$H1 round=3 by=director-1"
hr_verdict hr-newer "$TMP/hr-newer-pass.md" hk:doc/hr-newer-late
assert_refused "$(hr_nogrant hr-newer "$H1" 2 hk:doc/hr-newer-late)"
grant_doc hr-newer-oldest "head-repeat: job=hr-newer head=$H1 round=2 by=director-1"
hr_verdict hr-newer "$TMP/hr-newer-pass.md" hk:doc/hr-newer-oldest
assert_rc 0
[[ "$(verdict_field hr-newer 1 round | tail -n 1)" == "2" ]] || fail "the grant must bind the oldest open round on the head"
echo "PASS hk1970-binds-the-oldest-open-round-on-the-head"

# Other accepted shapes: a task comment by the issuer, a later line, an operator issuer.
hr_seed hr-task
grant_task 5201 someone-else "head-repeat: job=hr-task head=$H1 round=2 by=director-1"
grant_task 5201 director-1 "$(printf 'head-repeat: job=hr-task head=%s round=2 by=director-1' "$H1")"
hr_verdict hr-task "$TMP/hr-task-pass.md" hk:task/5201
assert_rc 0
grep -qxF 'tasks comments 5201' "$HK_CALL_LOG" || fail "a task grant must be fetched with tasks comments"
echo "PASS hk1970-task-grant-by-server-author-accepted"

hr_seed hr-later
grant_doc hr-later-grant "$(printf 'reason: the first verdict was a runner fault\nhead-repeat: job=hr-later head=%s round=1 by=director-1\nhead-repeat: job=hr-later head=%s round=2 by=director-1' "$H1" "$H1")"
hr_verdict hr-later "$TMP/hr-later-pass.md" hk:doc/hr-later-grant
assert_rc 0
echo "PASS hk1970-later-grant-line-counts"

hr_seed hr-operator
grant_doc hr-operator-grant "head-repeat: job=hr-operator head=$H1 round=2 by=operator" operator
hr_verdict hr-operator "$TMP/hr-operator-pass.md" hk:doc/hr-operator-grant
assert_rc 0
[[ "$(verdict_field hr-operator 1 head_repeat_issuer | tail -n 1)" == "operator" ]] || fail "operator issuer not recorded"
echo "PASS hk1970-operator-grant-accepted"

# pa-integrator grants count only on the server task for this job, as round void does.
hr_seed hr-pa-ok pa-integrator 7101
task_record 7101 ParkingArcade hr-pa-ok
grant_doc hr-pa-ok-grant "head-repeat: job=hr-pa-ok head=$H1 round=2 by=pa-integrator" pa-integrator
hr_verdict hr-pa-ok "$TMP/hr-pa-ok-pass.md" hk:doc/hr-pa-ok-grant
assert_rc 0
grep -qxF 'tasks show 7101' "$HK_CALL_LOG" || fail "the pa-integrator check must read the server task"
[[ "$(verdict_field hr-pa-ok 1 head_repeat_issuer | tail -n 1)" == "pa-integrator" ]] || fail "pa-integrator issuer not recorded"
echo "PASS hk1970-pa-integrator-accepted-on-parking-arcade"

hr_seed hr-pa-bad pa-integrator 7102
task_record 7102 SomethingElse hr-pa-bad
grant_doc hr-pa-bad-grant "head-repeat: job=hr-pa-bad head=$H1 round=2 by=pa-integrator" pa-integrator
hr_verdict hr-pa-bad "$TMP/hr-pa-bad-pass.md" hk:doc/hr-pa-bad-grant
assert_refused "wrk: round verdict --head-repeat: pa-integrator grants count only when the server task for hr-pa-bad is project ParkingArcade with refs.job_id=hr-pa-bad"
[[ "$(hr_count hr-pa-bad)" -eq 1 ]] || fail "a pa-integrator grant on the wrong project wrote a verdict"

hr_seed hr-pa-notask pa-integrator
grant_doc hr-pa-notask-grant "head-repeat: job=hr-pa-notask head=$H1 round=2 by=pa-integrator" pa-integrator
hr_verdict hr-pa-notask "$TMP/hr-pa-notask-pass.md" hk:doc/hr-pa-notask-grant
assert_refused "wrk: round verdict --head-repeat: pa-integrator grants need the job's hk task on the server; hr-pa-notask records no task_id"
echo "PASS hk1970-pa-integrator-needs-the-parking-arcade-task"

# ── mutants: each applied to the real anchor, each turns its case RED ──
python3 - "$WRK" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
for anchor in (
    "if digest in digests:  # hk1449-content-sha",
    '[[ -z "$joined_end" ]] || die "joined: refused after end record $joined_end"',
    "and r.get(\"round\") in bound)  # hk1449-nonvoid-rounds",
    "if not lines or wrk_verdict_line.match(lines[0]) is None:  # hk1449-verdict-first-line",
    "if ended:  # hk1900-inlock-end",
    "if not waived and wrk_round_census(events, job)[1] <= 0:  # hk1900-inlock-zero",
    "text = data.decode(\"utf-8\", errors=\"replace\")  # hk1900-utf8-replace",
    "errors=\"replace\"):  # hk1900-verdict-decode",
    '[[ "$waived" =~ ^hk:doc/[^[:space:]]+$ || "$waived" =~ ^hk:task/[0-9]+$ ]] || die "joined: --rounds-waived requires hk:doc/<key> or hk:task/<id>"  # hk1899-waiver-shape',
    '"$tmp_waiver" join-waiver || true)"  # hk1899-waiver-fetch',
    'claim_parent="$parent"  # hk2024-claim-facts',
    "if waived:  # hk2024-claim-recheck",
    "and round_head.lower() == vsha):  # hk1506-head-bind",
    '"$tmp_approval" head-repeat "$bind_round" "$bind_head" || true)"  # hk1970-head-repeat',
):
    assert src.count(anchor) == 1, (anchor, src.count(anchor))
PY

mutant() { # mutant name spec-file
  local name="$1" spec="$2"
  python3 - "$WRK" "$TMP/$name-wrk" "$spec" <<'PY'
import sys
src_path, out_path, spec_path = sys.argv[1:]
src = open(src_path, encoding="utf-8").read()
for i, line in enumerate(open(spec_path, encoding="utf-8").read().splitlines()):
    old, sep, new = line.partition(" => ")
    assert sep, "spec line %d: %r" % (i, line)
    assert src.count(old) == 1, (old, src.count(old))
    src = src.replace(old, new, 1)
open(out_path, "w", encoding="utf-8").write(src)
PY
  chmod +x "$TMP/$name-wrk"
}

# Dropping the head comparison makes the X/Y case bind the oldest X round.
printf '%s\n' 'and round_head.lower() == vsha):  # hk1506-head-bind => and True):  # hk1506-head-bind' >"$TMP/spec-drop-head"
mutant drop-head "$TMP/spec-drop-head"
claim_job mut-drop-head
open_with "$TMP/drop-head-wrk" mut-drop-head "$H1"
open_with "$TMP/drop-head-wrk" mut-drop-head "$H2"
write_verdict_file "$TMP/mut-drop-head.md" PASS "$H2" 'X/Y head comparison mutant'
run_cmd "$TMP/drop-head-wrk" round verdict mut-drop-head --file "$TMP/mut-drop-head.md"
assert_rc 0
bound="$(verdict_field mut-drop-head 0 round | tail -n 1)"
[[ "$bound" == "1" ]] || fail "dropping head comparison did not break the X/Y case: $bound"
echo "PASS mutant-drop-head-match-goes-red"

# Reversing the candidate order makes the same-head case bind newest.
printf '%s\n' 'open_rounds = [r for r in rounds => open_rounds = [r for r in reversed(rounds)' >"$TMP/spec-newest"
mutant newest "$TMP/spec-newest"
claim_job mut-newest
open_with "$TMP/newest-wrk" mut-newest "$H1"
open_with "$TMP/newest-wrk" mut-newest "$H1"
write_verdict_file "$TMP/mut-newest.md" PASS "$H1" 'newest matching round mutant'
run_cmd "$TMP/newest-wrk" round verdict mut-newest --file "$TMP/mut-newest.md"
assert_rc 0
bound="$(verdict_field mut-newest 0 round | tail -n 1)"
[[ "$bound" == "2" ]] || fail "newest-matching mutant did not break the same-head case: $bound"
echo "PASS mutant-newest-matching-round-goes-red"

# Skipping verdict-head lowercasing makes upper-case verdict bytes miss the
# lower-case head written by round open.
printf '%s\n' 'verdict, vsha = matches[0].group(1), matches[0].group(2).lower() => verdict, vsha = matches[0].group(1), matches[0].group(2)' >"$TMP/spec-no-fold"
mutant no-fold "$TMP/spec-no-fold"
claim_job mut-no-fold
upper_h1="$(printf '%s' "$H1" | tr '[:lower:]' '[:upper:]')"
open_with "$TMP/no-fold-wrk" mut-no-fold "$upper_h1"
write_verdict_file "$TMP/mut-no-fold.md" PASS "$upper_h1" 'case-sensitive head mutant'
run_cmd "$TMP/no-fold-wrk" round verdict mut-no-fold --file "$TMP/mut-no-fold.md"
assert_rc 2
[[ "$(kind_count mut-no-fold job.verdict)" -eq 0 ]] || fail "case-sensitive mutant unexpectedly bound an upper-case verdict"
echo "PASS mutant-head-without-lowercasing-goes-red"

# Bypassing the no-open refusal writes a historical unbound verdict again.
printf '%s\n' 'if target is None: => if target is None and False:' >"$TMP/spec-write-unbound"
mutant write-unbound "$TMP/spec-write-unbound"
claim_job mut-write-unbound
write_verdict_file "$TMP/mut-write-unbound.md" PASS "$H1" 'no-open write mutant'
run_cmd "$TMP/write-unbound-wrk" round verdict mut-write-unbound --file "$TMP/mut-write-unbound.md"
assert_rc 0
python3 - "$ARBITER_INBOX_ROOT/mut-write-unbound/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
verdict = next(row for row in events if row.get("kind") == "job.verdict")
assert verdict.get("round") is None, verdict
PY
echo "PASS mutant-no-open-round-writes-unbound-goes-red"

printf '%s\n' 'if digest in digests:  # hk1449-content-sha => if False:  # hk1449-content-sha' >"$TMP/spec-hash"
mutant hash "$TMP/spec-hash"
# Identical bytes after the head is voided: the head check would allow the
# second file, so only the content hash still refuses it.
claim_job mut-hash
open_ok mut-hash "$H2"
write_verdict_file "$TMP/mut-hash-1.md" PASS "$H2" 'mutant bytes'
verdict_ok mut-hash "$TMP/mut-hash-1.md"
write_event "$ARBITER_INBOX_ROOT/mut-hash/events/00092-job.round_void.json" <<'EOF'
{"kind":"job.round_void","job_id":"mut-hash","round":1,"ref":"hk:task/8","created_at":"2026-10-23T00:30:00Z"}
EOF
open_ok mut-hash "$H2"
cp "$TMP/mut-hash-1.md" "$TMP/mut-hash-2.md"
run_cmd "$WRK" round verdict mut-hash --file "$TMP/mut-hash-2.md"
[[ "$RUN_RC" -ne 0 ]] || fail "real wrk must still refuse duplicate content after the head is voided"
[[ "$(kind_count mut-hash job.verdict)" -eq 1 ]] || fail "real wrk wrote a second verdict for the same bytes"
claim_job mut-hash-red
open_ok mut-hash-red "$H2"
run_cmd "$TMP/hash-wrk" round verdict mut-hash-red --file "$TMP/mut-hash-1.md"
assert_rc 0
write_event "$ARBITER_INBOX_ROOT/mut-hash-red/events/00092-job.round_void.json" <<'EOF'
{"kind":"job.round_void","job_id":"mut-hash-red","round":1,"ref":"hk:task/8","created_at":"2026-10-23T00:30:00Z"}
EOF
open_with "$TMP/hash-wrk" mut-hash-red "$H2"
run_cmd "$TMP/hash-wrk" round verdict mut-hash-red --file "$TMP/mut-hash-2.md"
[[ "$RUN_RC" -eq 0 ]] || fail "content-hash mutant must record the second file, rc=$RUN_RC stderr=$(cat "$TMP/run.err")"
[[ "$(kind_count mut-hash-red job.verdict)" -eq 2 ]] || fail "content-hash mutant did not write the second verdict"
echo "PASS mutant-drop-content-hash-goes-red"

# shellcheck disable=SC2016 # the mutant spec is a literal source span, not an expansion
printf '%s\n' '[[ -z "$joined_end" ]] || die "joined: refused after end record $joined_end" => :' >"$TMP/spec-end"
mutant end "$TMP/spec-end"
# hk 1900: wrk own write path rechecks the end record under the events lock, so
# dropping the pre-check no longer shows there. The delegated path has no
# in-lock recheck, so this case runs through the panewire stub: only the
# pre-check stands between an ended job and the hand-off.
claim_job mut-end
seed_round mut-end
write_event "$ARBITER_INBOX_ROOT/mut-end/events/00009-job.revoked.json" <<'EOF'
{"kind":"job.revoked","job_id":"mut-end","created_at":"2026-10-23T06:00:00Z"}
EOF
: >"$TMP/pw-end.log"
run_cmd env WRK_JOB_DELEGATE=1 PANEWIRE_BIN="$TMP/pw-ok" PW_LOG="$TMP/pw-end.log" \
  "$WRK" joined mut-end --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -ne 0 ]] || fail "real wrk must still refuse a join after revoke"
[[ "$(kind_count mut-end job.joined)" -eq 0 ]] || fail "real wrk wrote job.joined after revoke"
claim_job mut-end-red
seed_round mut-end-red
write_event "$ARBITER_INBOX_ROOT/mut-end-red/events/00009-job.revoked.json" <<'EOF'
{"kind":"job.revoked","job_id":"mut-end-red","created_at":"2026-10-23T06:00:00Z"}
EOF
run_cmd env WRK_JOB_DELEGATE=1 PANEWIRE_BIN="$TMP/pw-ok" PW_LOG="$TMP/pw-end.log" \
  "$TMP/end-wrk" joined mut-end-red --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -eq 0 ]] || fail "joined-end mutant must allow the join, rc=$RUN_RC stderr=$(cat "$TMP/run.err")"
[[ "$(kind_count mut-end-red job.joined)" -eq 1 ]] || fail "joined-end mutant did not write job.joined"
echo "PASS mutant-drop-joined-end-goes-red"

printf '%s\n' 'and r.get("round") in bound)  # hk1449-nonvoid-rounds => and r.get("round") is not None)  # hk1449-nonvoid-rounds' >"$TMP/spec-void"
mutant voided "$TMP/spec-void"
claim_job mut-void
seed_open_round mut-void
write_event "$ARBITER_INBOX_ROOT/mut-void/events/00083-job.round_void.json" <<'EOF'
{"kind":"job.round_void","job_id":"mut-void","round":1,"ref":"hk:task/7","created_at":"2026-10-23T00:00:06Z"}
EOF
run_cmd "$WRK" joined mut-void --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -ne 0 ]] || fail "real wrk must refuse a voided-only join"
[[ "$(kind_count mut-void job.joined)" -eq 0 ]] || fail "real wrk wrote job.joined for a voided-only job"
claim_job mut-void-red
seed_open_round mut-void-red
write_event "$ARBITER_INBOX_ROOT/mut-void-red/events/00083-job.round_void.json" <<'EOF'
{"kind":"job.round_void","job_id":"mut-void-red","round":1,"ref":"hk:task/7","created_at":"2026-10-23T00:00:06Z"}
EOF
run_cmd "$TMP/voided-wrk" joined mut-void-red --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -eq 0 ]] || fail "void-counting mutant must allow the join, rc=$RUN_RC stderr=$(cat "$TMP/run.err")"
[[ "$(kind_count mut-void-red job.joined)" -eq 1 ]] || fail "void-counting mutant did not write job.joined"
echo "PASS mutant-zero-rounds-counts-voided-goes-red"

# ── hk 1900 mutants ─────────────────────────────────────────────────────
# The mutant above, which counts every numbered round, also counts an open round
# that never got a verdict: the open-then-join case must go RED under it.
claim_job mut-open
open_ok mut-open "$H1"
run_cmd "$WRK" joined mut-open --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -ne 0 ]] || fail "real wrk must refuse a join with only an open round"
[[ "$(kind_count mut-open job.joined)" -eq 0 ]] || fail "real wrk wrote job.joined for an open round with no verdict"
claim_job mut-open-red
open_ok mut-open-red "$H1"
run_cmd "$TMP/voided-wrk" joined mut-open-red --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -eq 0 ]] || fail "open-round-counting mutant must allow the join, rc=$RUN_RC stderr=$(cat "$TMP/run.err")"
[[ "$(kind_count mut-open-red job.joined)" -eq 1 ]] || fail "open-round-counting mutant did not write job.joined"
echo "PASS mutant-open-round-counts-goes-red"

printf '%s\n' 'if not lines or wrk_verdict_line.match(lines[0]) is None:  # hk1449-verdict-first-line => if not any(wrk_verdict_line.match(line) for line in lines):  # hk1449-verdict-first-line' >"$TMP/spec-anyline"
mutant anyline "$TMP/spec-anyline"
claim_job mut-anyline
seed_round mut-anyline
write_verdict_file "$ARBITER_INBOX_ROOT/mut-anyline/report.md" PASS "$H2" 'later line only'
run_cmd "$WRK" joined mut-anyline --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -eq 0 ]] || fail "real wrk must ignore a VERDICT line after the first line"
[[ "$(kind_count mut-anyline job.joined)" -eq 1 ]] || fail "real wrk did not join when the VERDICT line was not first"
claim_job mut-anyline-red
seed_round mut-anyline-red
write_verdict_file "$ARBITER_INBOX_ROOT/mut-anyline-red/report.md" PASS "$H2" 'later line only'
run_cmd "$TMP/anyline-wrk" joined mut-anyline-red --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -ne 0 ]] || fail "any-line mutant must refuse the later VERDICT line, rc=$RUN_RC stderr=$(cat "$TMP/run.err")"
[[ "$(kind_count mut-anyline-red job.joined)" -eq 0 ]] || fail "any-line mutant wrote job.joined"
echo "PASS mutant-any-line-match-goes-red"

printf '%s\n' 'if ended:  # hk1900-inlock-end => if False:  # hk1900-inlock-end' >"$TMP/spec-inlock-end"
mutant inlock-end "$TMP/spec-inlock-end"
claim_job mut-inlock-end
seed_round mut-inlock-end
run_cmd env WRK_TEST_JOINED_PRECOMMIT_HOOK="$RACE_HOOK" \
  "$WRK" joined mut-inlock-end --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -ne 0 ]] || fail "real wrk must refuse a join that races an end record"
[[ "$(kind_count mut-inlock-end job.joined)" -eq 0 ]] || fail "real wrk wrote job.joined after the racing end record"
claim_job mut-inlock-end-red
seed_round mut-inlock-end-red
run_cmd env WRK_TEST_JOINED_PRECOMMIT_HOOK="$RACE_HOOK" \
  "$TMP/inlock-end-wrk" joined mut-inlock-end-red --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -eq 0 ]] || fail "in-lock-end mutant must allow the racing join, rc=$RUN_RC stderr=$(cat "$TMP/run.err")"
[[ "$(kind_count mut-inlock-end-red job.joined)" -eq 1 ]] || fail "in-lock-end mutant did not write job.joined"
echo "PASS mutant-drop-inlock-end-recheck-goes-red"

printf '%s\n' 'if not waived and wrk_round_census(events, job)[1] <= 0:  # hk1900-inlock-zero => if False:  # hk1900-inlock-zero' >"$TMP/spec-inlock-zero"
mutant inlock-zero "$TMP/spec-inlock-zero"
claim_job mut-inlock-zero
seed_round mut-inlock-zero
run_cmd env WRK_TEST_JOINED_PRECOMMIT_HOOK="$ZERO_HOOK" \
  "$WRK" joined mut-inlock-zero --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -ne 0 ]] || fail "real wrk must refuse a join that lost its last verdict"
[[ "$(kind_count mut-inlock-zero job.joined)" -eq 0 ]] || fail "real wrk wrote job.joined with zero rounds"
claim_job mut-inlock-zero-red
seed_round mut-inlock-zero-red
run_cmd env WRK_TEST_JOINED_PRECOMMIT_HOOK="$ZERO_HOOK" \
  "$TMP/inlock-zero-wrk" joined mut-inlock-zero-red --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -eq 0 ]] || fail "in-lock-zero mutant must allow the join, rc=$RUN_RC stderr=$(cat "$TMP/run.err")"
[[ "$(kind_count mut-inlock-zero-red job.joined)" -eq 1 ]] || fail "in-lock-zero mutant did not write job.joined"
echo "PASS mutant-drop-inlock-zero-recheck-goes-red"

printf '%s\n' 'text = data.decode("utf-8", errors="replace")  # hk1900-utf8-replace => text = data.decode("utf-8", errors="replace") if data.decode("utf-8", errors="replace").encode("utf-8") == data else ""  # hk1900-utf8-replace' >"$TMP/spec-utf8"
mutant utf8 "$TMP/spec-utf8"
claim_job mut-utf8
seed_round mut-utf8
printf 'VERDICT: PASS @%s\nbad byte \377 here\n' "$H2" >"$ARBITER_INBOX_ROOT/mut-utf8/copy.md"
run_cmd "$WRK" joined mut-utf8 --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -ne 0 ]] || fail "real wrk must refuse a join past a non-UTF-8 copied verdict file"
[[ "$(kind_count mut-utf8 job.joined)" -eq 0 ]] || fail "real wrk wrote job.joined past a non-UTF-8 verdict file"
claim_job mut-utf8-red
seed_round mut-utf8-red
printf 'VERDICT: PASS @%s\nbad byte \377 here\n' "$H2" >"$ARBITER_INBOX_ROOT/mut-utf8-red/copy.md"
run_cmd "$TMP/utf8-wrk" joined mut-utf8-red --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
[[ "$RUN_RC" -eq 0 ]] || fail "skip-non-UTF-8 mutant must allow the join, rc=$RUN_RC stderr=$(cat "$TMP/run.err")"
[[ "$(kind_count mut-utf8-red job.joined)" -eq 1 ]] || fail "skip-non-UTF-8 mutant did not write job.joined"
echo "PASS mutant-skip-non-utf8-files-goes-red"

printf '%s\n' 'errors="replace"):  # hk1900-verdict-decode => errors="strict"):  # hk1900-verdict-decode' >"$TMP/spec-vdecode"
mutant vdecode "$TMP/spec-vdecode"
claim_job mut-vdecode
open_ok mut-vdecode "$H2"
printf 'VERDICT: PASS @%s\nbad byte \377 here\n' "$H2" >"$TMP/mut-vdecode.md"
run_cmd "$WRK" round verdict mut-vdecode --file "$TMP/mut-vdecode.md"
assert_rc 0
claim_job mut-vdecode-red
open_ok mut-vdecode-red "$H2"
run_cmd "$TMP/vdecode-wrk" round verdict mut-vdecode-red --file "$TMP/mut-vdecode.md"
[[ "$RUN_RC" -ne 0 ]] || fail "strict-decode mutant must fail to record the non-UTF-8 verdict file"
[[ "$(kind_count mut-vdecode-red job.verdict)" -eq 0 ]] || fail "strict-decode mutant wrote a job.verdict"
echo "PASS mutant-strict-verdict-decode-goes-red"

# ── hk 1899 mutants: each applied at the real call site, each turns its invariant RED ──
# Invariant 1: a ref that is not backed by a fetched record never waives.
# shellcheck disable=SC2016 # the mutant spec is a literal source span, not an expansion
printf '%s\n' \
  'if ! round_approval_fetch "$waived" >"$tmp_waiver"; then => if false; then' \
  'waiver_grant="$(round_approval_verify "$waived" "$job" "$parent" "$ROUND_CAP_OPERATORS" "$ROUND_CAP_PARENT_ISSUERS" "$tmp_waiver" join-waiver || true)"  # hk1899-waiver-fetch => waiver_grant="granted=1 issuer=director-1"  # hk1899-waiver-fetch' \
  >"$TMP/spec-nofetch"
mutant nofetch "$TMP/spec-nofetch"
claim_job mut-nofetch
assert_waiver_refused mut-nofetch hk:doc/mut-made-up "wrk: joined: waiver record not found in handoffkeep: hk:doc/mut-made-up"
claim_job mut-nofetch-red
run_cmd "$TMP/nofetch-wrk" joined mut-nofetch-red --pr https://example.invalid/pr/1899 --head "$H1" --report "$REPORT" --rounds-waived hk:doc/mut-made-up
[[ "$RUN_RC" -eq 0 ]] || fail "no-fetch mutant must accept a made-up ref, rc=$RUN_RC stderr=$(cat "$TMP/run.err")"
[[ "$(kind_count mut-nofetch-red job.joined)" -eq 1 ]] || fail "no-fetch mutant did not write job.joined"
echo "PASS mutant-trust-the-shape-goes-red"

# Invariant 2: the issuer in the line must equal the record's server-set identity.
printf '%s\n' 'if issuer not in allowed_issuers or issuer != identity: => if issuer not in allowed_issuers or (issuer != identity and grant_kind != "join-waiver"):' >"$TMP/spec-noident"
mutant noident "$TMP/spec-noident"
claim_job mut-noident
grant_doc mut-noident-grant "join-waiver: job=mut-noident by=director-1" the-builder
assert_waiver_refused mut-noident hk:doc/mut-noident-grant "$(nogrant_msg mut-noident hk:doc/mut-noident-grant)"
claim_job mut-noident-red
grant_doc mut-noident-red-grant "join-waiver: job=mut-noident-red by=director-1" the-builder
run_cmd "$TMP/noident-wrk" joined mut-noident-red --pr https://example.invalid/pr/1899 --head "$H1" --report "$REPORT" --rounds-waived hk:doc/mut-noident-red-grant
[[ "$RUN_RC" -eq 0 ]] || fail "no-identity mutant must accept a forged issuer, rc=$RUN_RC stderr=$(cat "$TMP/run.err")"
[[ "$(kind_count mut-noident-red job.joined)" -eq 1 ]] || fail "no-identity mutant did not write job.joined"
# The mutant is scoped to join-waiver: a forged round-void grant is still refused by it.
claim_job mut-noident-void
open_ok mut-noident-void "$H1"
grant_doc mut-noident-void-grant "round-void: job=mut-noident-void round=1 by=director-1" the-builder
run_cmd "$TMP/noident-wrk" round void mut-noident-void 1 --by hk:doc/mut-noident-void-grant
[[ "$RUN_RC" -ne 0 ]] || fail "the identity check must still hold for round void under the mutant"
echo "PASS mutant-drop-waiver-identity-check-goes-red"

# Invariant 3: only hk:doc/<non-space key> and hk:task/<digits> are accepted refs.
# shellcheck disable=SC2016 # the mutant spec is a literal source span, not an expansion
printf '%s\n' '[[ "$waived" =~ ^hk:doc/[^[:space:]]+$ || "$waived" =~ ^hk:task/[0-9]+$ ]] || die "joined: --rounds-waived requires hk:doc/<key> or hk:task/<id>"  # hk1899-waiver-shape => [[ "$waived" == hk:doc/?* || "$waived" == hk:task/?* ]] || die "joined: --rounds-waived requires hk:doc/<key> or hk:task/<id>"  # hk1899-waiver-shape' >"$TMP/spec-loose"
mutant loose "$TMP/spec-loose"
claim_job mut-loose
grant_task abc director-1 "join-waiver: job=mut-loose by=director-1"
: >"$HK_CALL_LOG"
assert_waiver_refused mut-loose hk:task/abc "$SHAPE_MSG"
[[ ! -s "$HK_CALL_LOG" ]] || fail "real wrk fetched a malformed ref: $(cat "$HK_CALL_LOG")"
claim_job mut-loose-red
grant_task abc director-1 "join-waiver: job=mut-loose-red by=director-1"
run_cmd "$TMP/loose-wrk" joined mut-loose-red --pr https://example.invalid/pr/1899 --head "$H1" --report "$REPORT" --rounds-waived hk:task/abc
[[ "$RUN_RC" -eq 0 ]] || fail "loose-shape mutant must accept hk:task/abc, rc=$RUN_RC stderr=$(cat "$TMP/run.err")"
[[ "$(kind_count mut-loose-red job.joined)" -eq 1 ]] || fail "loose-shape mutant did not write job.joined"
echo "PASS mutant-loosen-the-shape-goes-red"

# Invariant 4: the waiver is verified before the refusals are decided, so a verified waiver
# joins a job with zero rounds. The mutant runs the refusal check ahead of the verification.
# shellcheck disable=SC2016 # the mutant spec is a literal source span, not an expansion
printf '%s\n' 'tmp_waiver="$(mktemp)" => wrk_joined_refuse_blocks "$job" "${WRK_TRUST_JOBS_ROOT:?trust guard did not run}"; tmp_waiver="$(mktemp)"' >"$TMP/spec-lateverify"
mutant lateverify "$TMP/spec-lateverify"
claim_job mut-late
grant_doc mut-late-grant "join-waiver: job=mut-late by=director-1"
joined_waived mut-late hk:doc/mut-late-grant
assert_rc 0
[[ "$(kind_count mut-late job.joined)" -eq 1 ]] || fail "real wrk must join a zero-round job on a verified waiver"
claim_job mut-late-red
grant_doc mut-late-red-grant "join-waiver: job=mut-late-red by=director-1"
run_cmd "$TMP/lateverify-wrk" joined mut-late-red --pr https://example.invalid/pr/1899 --head "$H1" --report "$REPORT" --rounds-waived hk:doc/mut-late-red-grant
assert_refused "wrk: joined: job mut-late-red has zero non-voided recorded rounds"
[[ "$(kind_count mut-late-red job.joined)" -eq 0 ]] || fail "late-verify mutant wrote job.joined"
echo "PASS mutant-verify-after-the-refusal-check-goes-red"

# hk 1970 mutants: each applied to the real anchor, each turns its case RED.
# shellcheck disable=SC2016 # the mutant spec is a literal source span, not an expansion
printf '%s\n' 'if ! round_approval_fetch "$head_repeat" >"$tmp_approval"; then => if false; then' >"$TMP/spec-hr-nofetch"
mutant hr-nofetch "$TMP/spec-hr-nofetch"
hr_seed hr-mut-nofetch
run_cmd "$TMP/hr-nofetch-wrk" round verdict hr-mut-nofetch --file "$TMP/hr-mut-nofetch-pass.md" --head-repeat hk:doc/hr-mut-made-up
assert_refused "$(hr_nogrant hr-mut-nofetch "$H1" 2 hk:doc/hr-mut-made-up)"
echo "PASS mutant-hr-skip-the-fetch-goes-red"

printf '%s\n' 'if digest in digests:  # hk1449-content-sha => if digest in digests and not grant_ref:  # hk1449-content-sha' >"$TMP/spec-hr-content"
mutant hr-content "$TMP/spec-hr-content"
hr_seed hr-mut-content
grant_doc hr-mut-content-grant "head-repeat: job=hr-mut-content head=$H1 round=2 by=director-1"
cp "$TMP/hr-mut-content-block.md" "$TMP/hr-mut-content-copy.md"
run_cmd "$TMP/hr-content-wrk" round verdict hr-mut-content --file "$TMP/hr-mut-content-copy.md" --head-repeat hk:doc/hr-mut-content-grant
assert_rc 0
[[ "$(hr_count hr-mut-content)" -eq 2 ]] || fail "the content mutant must record the copied bytes"
echo "PASS mutant-grant-releasing-content-goes-red"

printf '%s\n' 'head_repeat_used = bool(grant_ref) and any( => head_repeat_used = False and any(' >"$TMP/spec-hr-used"
mutant hr-used "$TMP/spec-hr-used"
hr_seed hr-mut-used
grant_doc hr-mut-used-grant "$(printf 'head-repeat: job=hr-mut-used head=%s round=2 by=director-1\nhead-repeat: job=hr-mut-used head=%s round=3 by=director-1' "$H1" "$H1")"
hr_verdict hr-mut-used "$TMP/hr-mut-used-pass.md" hk:doc/hr-mut-used-grant
assert_rc 0
open_ok hr-mut-used "$H1"
write_verdict_file "$TMP/hr-mut-used-third.md" PASS "$H1" 'mutant round three'
run_cmd "$TMP/hr-used-wrk" round verdict hr-mut-used --file "$TMP/hr-mut-used-third.md" --head-repeat hk:doc/hr-mut-used-grant
assert_rc 0
[[ "$(hr_count hr-mut-used)" -eq 3 ]] || fail "the used-once mutant must record a reused grant"
echo "PASS mutant-reused-grant-goes-red"

printf '%s\n' 'GRANT = re.compile(r"^head-repeat: job=(\S+) head=([0-9a-f]{40}) round=([1-9][0-9]*) by=(\S+)$") => GRANT = re.compile(r"^head-repeat: job=(\S+) head=([0-9a-f]{7,40}) round=([1-9][0-9]*) by=(\S+)$")' 'if m.group(2) != head_sha or m.group(3) != round_number: => if not head_sha.startswith(m.group(2)) or m.group(3) != round_number:' >"$TMP/spec-hr-prefix"
mutant hr-prefix "$TMP/spec-hr-prefix"
hr_seed hr-mut-prefix
grant_doc hr-mut-prefix-grant "head-repeat: job=hr-mut-prefix head=${H1:0:7} round=2 by=director-1"
run_cmd "$TMP/hr-prefix-wrk" round verdict hr-mut-prefix --file "$TMP/hr-mut-prefix-pass.md" --head-repeat hk:doc/hr-mut-prefix-grant
assert_rc 0
[[ "$(hr_count hr-mut-prefix)" -eq 2 ]] || fail "the prefix mutant must accept a short SHA"
echo "PASS mutant-short-sha-prefix-goes-red"

printf '%s\n' 'if issuer not in allowed_issuers or issuer != identity: => if issuer not in allowed_issuers or (issuer != identity and grant_kind != "head-repeat"):' >"$TMP/spec-hr-noident"
mutant hr-noident "$TMP/spec-hr-noident"
hr_seed hr-mut-noident
grant_doc hr-mut-noident-grant "head-repeat: job=hr-mut-noident head=$H1 round=2 by=director-1" the-builder
run_cmd "$TMP/hr-noident-wrk" round verdict hr-mut-noident --file "$TMP/hr-mut-noident-pass.md" --head-repeat hk:doc/hr-mut-noident-grant
assert_rc 0
[[ "$(hr_count hr-mut-noident)" -eq 2 ]] || fail "the identity mutant must accept a forged issuer"
echo "PASS mutant-drop-the-issuer-identity-goes-red"

echo "PASS test-wrk-rounds"
