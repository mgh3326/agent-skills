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
#   hk1506-binding-unchanged
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
export HK_DOC_DIR="$TMP/hk-docs"
mkdir -p "$HK_DOC_DIR"
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

claim_job() { # claim_job job [parent] [created_at] [role] [owner]
  local job="$1" parent="${2:-director-1}" at="${3:-2026-10-23T00:00:00Z}"
  local role="${4:-builder}" owner="${5:-lane-a}"
  local events="$ARBITER_INBOX_ROOT/$job/events"
  mkdir -p "$events" "$ARBITER_INBOX_ROOT/$job"
  write_event "$events/00001-job.claim.json" <<EOF
{"kind":"job.claim","job_id":"$job","created_at":"$at","owner_lane":"$owner","label":"lbl","pane_id":"w:p1","parent_lane":"$parent","role":"$role"}
EOF
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

cat >"$HANDOFFKEEP_BIN" <<'EOF'
#!/bin/sh
if [ "$1" = "doc" ] && [ "$2" = "get" ] && [ -n "${3:-}" ] && [ -f "$HK_DOC_DIR/$3" ]; then
  cat "$HK_DOC_DIR/$3"
  exit 0
fi
exit 1
EOF
chmod +x "$HANDOFFKEEP_BIN"

grant_doc() { # grant_doc key body
  python3 -c 'import json,sys; json.dump({"created_by":"director-1","body":sys.argv[2]}, open(sys.argv[1],"w"))' \
    "$HK_DOC_DIR/$1" "$2"
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

# The same assertions run against production and each selection mutant.
head_bind_case() { # case-name suffix
  local case_name="$1" job="hb-$1-$2" status head_upper
  claim_job "$job"
  case "$case_name" in
    xy)
      open_ok "$job" "$H1"
      open_ok "$job" "$H2"
      write_verdict_file "$TMP/$job.md" PASS "$H2" 'head Y'
      verdict_ok "$job" "$TMP/$job.md"
      [[ "$(verdict_field "$job" 0 round | tail -n 1)" == 2 ]] || fail "xy must bind round 2"
      status="$("$WRK" round status "$job")"
      grep -q 'open=1[[:space:]]' <<<"$status" || fail "xy must leave round 1 open: $status"
      ;;
    oldest)
      open_ok "$job" "$H1"
      open_ok "$job" "$H1"
      write_verdict_file "$TMP/$job.md" PASS "$H1"
      verdict_ok "$job" "$TMP/$job.md"
      [[ "$(verdict_field "$job" 0 round | tail -n 1)" == 1 ]] || fail "oldest must bind round 1"
      status="$("$WRK" round status "$job")"
      grep -q 'open=2[[:space:]]' <<<"$status" || fail "oldest must leave round 2 open: $status"
      ;;
    uppercase)
      head_upper="$(printf '%s' "$H1" | tr 'a-f' 'A-F')"
      open_ok "$job" "$head_upper"
      # Seed uppercase too: round open already normalizes its input.
      python3 - "$ARBITER_INBOX_ROOT/$job/events" "$head_upper" <<'PY'
import json,pathlib,sys
for p in pathlib.Path(sys.argv[1]).glob('*.json'):
    d=json.loads(p.read_text())
    if d.get('kind')=='job.round':
        d['head']=sys.argv[2];p.write_text(json.dumps(d))
PY
      write_verdict_file "$TMP/$job.md" PASS "$head_upper"
      verdict_ok "$job" "$TMP/$job.md"
      [[ "$(verdict_field "$job" 0 head | tail -n 1)" == "$H1" ]] || fail "uppercase must normalize head"
      ;;
    noopen)
      write_verdict_file "$TMP/$job.md" PASS "$H1"
      snap_tree "$ARBITER_INBOX_ROOT/$job/events" "$TMP/$job-before"
      run_cmd "$WRK" round verdict "$job" --file "$TMP/$job.md"
      assert_rc 2
      assert_refused "wrk: round verdict: job $job has no open round; open one with wrk round open $job --head $H1"
      [[ "$(kind_count "$job" job.verdict)" == 0 ]] || fail "noopen wrote a verdict"
      [[ "$(kind_count "$job" job.escalate)" == 0 ]] || fail "noopen escalated"
      snap_tree "$ARBITER_INBOX_ROOT/$job/events" "$TMP/$job-after"
      cmp "$TMP/$job-before" "$TMP/$job-after" || fail "noopen changed events"
      ;;
  esac
}
for bind_case in xy oldest uppercase noopen; do
  head_bind_case "$bind_case" real
  echo "PASS hk1506-$bind_case"
done

claim_job head-recovery
open_ok head-recovery "$H1"
write_verdict_file "$TMP/head-recovery.md" PASS "$H2"
snap_tree "$ARBITER_INBOX_ROOT/head-recovery/events" "$TMP/recovery-before"
run_cmd "$WRK" round verdict head-recovery --file "$TMP/head-recovery.md"
assert_rc 2
assert_refused "wrk: round verdict: no open round for head $H2 on job head-recovery (open: 1@${H1:0:7}); open one with wrk round open head-recovery --head $H2"
[[ "$(kind_count head-recovery job.verdict)" == 0 ]] || fail "wrong-head wrote a verdict"
snap_tree "$ARBITER_INBOX_ROOT/head-recovery/events" "$TMP/recovery-after"
cmp "$TMP/recovery-before" "$TMP/recovery-after" || fail "wrong-head changed events"
status="$("$WRK" round status head-recovery)"
grep -q 'open=1[[:space:]]' <<<"$status" || fail "refusal must leave round 1 open: $status"
open_ok head-recovery "$H2"
verdict_ok head-recovery "$TMP/head-recovery.md"
[[ "$(verdict_field head-recovery 0 round | tail -n 1)" == 2 ]] || fail "recovery must bind round 2"
open_ok head-recovery "$H3"
run_cmd "$WRK" round open head-recovery --head "$H4" --repo "$TEST_REPO"
assert_rc 78
echo "PASS hk1506-wrong-head-recovery-stale-cap"

claim_job head-invalid
write_event "$ARBITER_INBOX_ROOT/head-invalid/events/00002-job.round.json" <<'JSON'
{"kind":"job.round","job_id":"head-invalid","round":1}
JSON
write_event "$ARBITER_INBOX_ROOT/head-invalid/events/00003-job.round.json" <<'JSON'
{"kind":"job.round","job_id":"head-invalid","round":2,"head":7}
JSON
write_verdict_file "$TMP/head-invalid.md" PASS "$H1"
run_cmd "$WRK" round verdict head-invalid --file "$TMP/head-invalid.md"
assert_rc 2
assert_refused "wrk: round verdict: no open round for head $H1 on job head-invalid (open: 1@?, 2@?); open one with wrk round open head-invalid --head $H1"
[[ "$(kind_count head-invalid job.verdict)" == 0 ]] || fail "invalid heads matched"
open_ok head-invalid "$H1"
verdict_ok head-invalid "$TMP/head-invalid.md"
[[ "$(verdict_field head-invalid 0 round | tail -n 1)" == 3 ]] || fail "invalid heads must be skipped"
echo "PASS hk1506-missing-and-nonstring-head"

claim_job head-void
open_ok head-void "$H1"
grant_doc head-void 'round-void: job=head-void round=1 by=director-1'
run_cmd "$WRK" round void head-void 1 --by hk:doc/head-void
assert_rc 0
write_verdict_file "$TMP/head-void.md" PASS "$H1"
run_cmd "$WRK" round verdict head-void --file "$TMP/head-void.md"
assert_rc 2
assert_refused "wrk: round verdict: job head-void has no open round; open one with wrk round open head-void --head $H1"
[[ "$(kind_count head-void job.verdict)" == 0 ]] || fail "void-only wrote a verdict"
open_ok head-void "$H1"
verdict_ok head-void "$TMP/head-void.md"
[[ "$(verdict_field head-void 0 round | tail -n 1)" == 2 ]] || fail "voided round was selected"
echo "PASS hk1506-voided-head-refused-then-recovered"

claim_job head-legacy
write_event "$ARBITER_INBOX_ROOT/head-legacy/events/00002-job.verdict.json" <<EOF_LEGACY
{"kind":"job.verdict","job_id":"head-legacy","round":null,"unopened":true,"head":"$H1","verdict":"PASS"}
EOF_LEGACY
status="$("$WRK" round status head-legacy)"
grep -q 'rounds=1' <<<"$status" || fail "legacy unbound must count: $status"
open_ok head-legacy "$H2"
open_ok head-legacy "$H3"
run_cmd "$WRK" round open head-legacy --head "$H4" --repo "$TEST_REPO"
assert_rc 78
run_cmd "$WRK" round audit --lane lane-a
assert_rc 0
if grep -q 'zero-rounds job=head-legacy' "$TMP/run.out"; then fail "audit dropped legacy unbound"; fi
join_ok head-legacy
echo "PASS hk1506-legacy-unbound-readers"

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
write_event "$ARBITER_INBOX_ROOT/b-ended/events/00003-job.reclaim.json" <<EOF
{"kind":"job.reclaim","job_id":"b-ended","created_at":"2026-10-23T02:00:00Z","owner_lane":"lane-a","label":"lbl","pane_id":"w:p1","parent_lane":"director-1","role":"builder"}
EOF
open_ok b-ended "$H4"
open_ok b-ended "$H2"
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
assert found
' "$ARBITER_INBOX_ROOT" c-waive
echo "PASS c-waiver-hk-task-recorded"

claim_job c-waive-doc
run_cmd "$WRK" joined c-waive-doc --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT" --rounds-waived hk:doc/waiver-key
assert_rc 0
python3 -c 'import json,os,sys
root=sys.argv[1]
for name in os.listdir(os.path.join(root,"c-waive-doc","events")):
    doc=json.load(open(os.path.join(root,"c-waive-doc","events",name),encoding="utf-8"))
    if doc.get("kind")=="job.joined":
        assert doc.get("rounds_waived")=="hk:doc/waiver-key", doc
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
seed_open_round flow-void-only
write_event "$ARBITER_INBOX_ROOT/flow-void-only/events/00082-job.round_void.json" <<'EOF'
{"kind":"job.round_void","job_id":"flow-void-only","round":1,"ref":"hk:doc/void-only","created_at":"2026-10-23T00:00:04Z"}
EOF
run_cmd "$WRK" joined flow-void-only --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: job flow-void-only has zero non-voided recorded rounds"
open_ok flow-void-only "$H2"
run_cmd "$WRK" joined flow-void-only --pr https://example.invalid/pr/1 --head "$H1" --report "$REPORT"
assert_refused "wrk: joined: job flow-void-only has zero non-voided recorded rounds"
write_verdict_file "$TMP/flow-void-only.md" PASS "$H2" 'verdict on the new round'
verdict_ok flow-void-only "$TMP/flow-void-only.md"
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
seed_round flow-pa
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

echo "== hk1506-binding-unchanged =="
claim_job flow-bind
open_ok flow-bind "$H1"
open_ok flow-bind "$H1"
write_verdict_file "$TMP/flow-bind.md" PASS "$H1" 'binds to the oldest open round on this head'
verdict_ok flow-bind "$TMP/flow-bind.md"
bound="$(verdict_field flow-bind 0 round | tail -n 1)"
[[ "$bound" == "1" ]] || fail "verdict must bind to the oldest matching open round, got $bound"
echo "PASS hk1506-binding-unchanged"

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

# ── help and the one skill line each ───────────────────────────────────
"$WRK" --help >"$TMP/usage.txt"
grep -q 'round audit' "$TMP/usage.txt" || fail "usage must name round audit"
grep -q -- '--rounds-waived' "$TMP/usage.txt" || fail "usage must name --rounds-waived"
"$WRK" round --help >"$TMP/round-help.txt"
grep -q 'audit' "$TMP/round-help.txt" || fail "round help must name audit"
grep -q 'oldest open round on its own head' "$TMP/round-help.txt" || fail "round help must explain head binding"
grep -q 'refused when there is none' "$TMP/round-help.txt" || fail "round help must explain refusal"
builder_hits="$(grep -c 'rounds-waived' "$ROOT/builder/SKILL.md" || true)"
director_hits="$(grep -c 'rounds-waived' "$ROOT/director/SKILL.md" || true)"
[[ "$builder_hits" -eq 1 ]] || fail "builder skill must mention rounds-waived on exactly one line"
[[ "$director_hits" -eq 1 ]] || fail "director skill must mention rounds-waived on exactly one line"
echo "PASS help-and-skill-lines"

# ── mutants: each applied to the real anchor, each turns its case RED ──
python3 - "$WRK" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
for anchor in (
    "if digest in digests:  # hk1449-content-sha",
    'if isinstance(r.get("head"), str) and r["head"].lower() == vsha:  # hk1506-head-bind',
    '[[ -z "$joined_end" ]] || die "joined: refused after end record $joined_end"',
    "and r.get(\"round\") in bound)  # hk1449-nonvoid-rounds",
    "if not lines or wrk_verdict_line.match(lines[0]) is None:  # hk1449-verdict-first-line",
    "if ended:  # hk1900-inlock-end",
    "if not waived and wrk_round_census(events, job)[1] <= 0:  # hk1900-inlock-zero",
    "text = data.decode(\"utf-8\", errors=\"replace\")  # hk1900-utf8-replace",
    "errors=\"replace\"):  # hk1900-verdict-decode",
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

printf '%s\n' 'if digest in digests:  # hk1449-content-sha => if False:  # hk1449-content-sha' >"$TMP/spec-hash"
mutant hash "$TMP/spec-hash"
for mutation in nohead newest casefold unbound; do
  case "$mutation" in
    nohead)
      printf '%s\n' 'if isinstance(r.get("head"), str) and r["head"].lower() == vsha:  # hk1506-head-bind => if True:  # hk1506-head-bind' >"$TMP/spec-$mutation"
      bind_case=xy ;;
    newest)
      printf '%s\n' '    for r in open_rounds: =>     for r in reversed(open_rounds):' >"$TMP/spec-$mutation"
      bind_case=oldest ;;
    casefold)
      printf '%s\n' 'if isinstance(r.get("head"), str) and r["head"].lower() == vsha:  # hk1506-head-bind => if isinstance(r.get("head"), str) and r["head"] == vsha:  # hk1506-head-bind' >"$TMP/spec-$mutation"
      bind_case=uppercase ;;
    unbound)
      printf '%s\n' '    if target is None: =>     if False:' >"$TMP/spec-$mutation"
      bind_case=noopen ;;
  esac
  mutant "$mutation" "$TMP/spec-$mutation"
  set +e
  ( WRK="$TMP/$mutation-wrk"; head_bind_case "$bind_case" "$mutation" ) >"$TMP/mut-$mutation.out" 2>&1
  mut_rc=$?
  set -e
  [[ "$mut_rc" -ne 0 ]] || fail "hk1506 $mutation mutant survived $bind_case"
  grep -q '^FAIL:' "$TMP/mut-$mutation.out" || fail "mutant must fail an assertion: $(cat "$TMP/mut-$mutation.out")"
  if grep -qE 'Traceback|SyntaxError|IndexError' "$TMP/mut-$mutation.out"; then
    fail "mutant failed by exception: $(cat "$TMP/mut-$mutation.out")"
  fi
  echo "PASS mutant-hk1506-$mutation-goes-red ($bind_case)"
done

# Identical bytes after the head is voided: the head check would allow the
# second file, so only the content hash still refuses it.
claim_job mut-hash
open_ok mut-hash "$H2"
write_verdict_file "$TMP/mut-hash-1.md" PASS "$H2" 'mutant bytes'
verdict_ok mut-hash "$TMP/mut-hash-1.md"
write_event "$ARBITER_INBOX_ROOT/mut-hash/events/00092-job.round_void.json" <<'EOF'
{"kind":"job.round_void","job_id":"mut-hash","round":1,"ref":"hk:task/8","created_at":"2026-10-23T00:30:00Z"}
EOF
cp "$TMP/mut-hash-1.md" "$TMP/mut-hash-2.md"
open_ok mut-hash "$H2"
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
open_ok mut-hash-red "$H2"
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


echo "PASS test-wrk-rounds"
