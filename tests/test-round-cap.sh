#!/usr/bin/env bash
# tests/test-round-cap.sh — #758 wrk tester-round cap contracts:
# counting (events stream only, sub-round naming cannot hide), cap refusal
# (rc 78 + job.escalate with job/head/last verdict/findings), extension only
# with a fetched hk approval grant from parent lane or operator, and
# assertion-RED mutants over the wrk source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export ARBITER_INBOX_ROOT="$TMP/inbox"
export XDG_DATA_HOME="$TMP/xdg"
export WRK_NO_SLEEP=1
export WRK_JOB_DELEGATE=0
export PANEWIRE_BIN="$TMP/absent-panewire"
# The operator set is fixed in the wrk source; exporting job lanes here must be
# ignored — a builder must not widen the trusted issuers through its own env.
export WRK_ROUND_CAP_OPERATORS="je-lane jx-lane jg-lane selfish-lane"
# Same for the trusted parent-lane set: host ids pushed through the env must
# not become grant issuers.
export WRK_ROUND_CAP_PARENT_ISSUERS="mac-dev mac-personal jrf-lane jrm-lane"

H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H3=3333333333333333333333333333333333333333
H4=4444444444444444444444444444444444444444

fail() { echo "FAIL: $*" >&2; exit 1; }

mkjob() { # mkjob <name> [parent-lane] [task-id] — builder claim envelope
  local events="$ARBITER_INBOX_ROOT/$1/events" tid=""
  mkdir -p "$events"
  [[ -z "${3:-}" ]] || tid=",\"task_id\":$3"
  cat >"$events/00001-job.claim.json" <<EOF
{"created_at":"2026-09-27T00:00:00Z","job_id":"$1","kind":"job.claim","payload":{"agent_label":"$1","owner_lane":"$1-lane","pane_id":"w:p1","parent_lane":"${2:-director-1}"${tid},"role":"builder","t_level":"T2"},"seq":1}
EOF
}

reclaim() { # reclaim <job> <parent-lane> [task-id] — a later event rewriting the recorded meta
  local tid=""
  [[ -z "${3:-}" ]] || tid=",\"task_id\":$3"
  cat >"$ARBITER_INBOX_ROOT/$1/events/00002-job.reclaim.json" <<EOF
{"created_at":"2026-10-12T00:00:00Z","job_id":"$1","kind":"job.reclaim","payload":{"agent_label":"$1","owner_lane":"$1-lane","pane_id":"w:p1","parent_lane":"$2"${tid},"role":"builder","t_level":"T2"},"seq":2}
EOF
}

expect_rc() { # expect_rc <want> <cmd...>
  local want="$1" rc=0
  shift
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq "$want" ]] || fail "expected rc=$want got rc=$rc: $*"
}

open_ok() { # open_ok <wrk> <job> <head> — must succeed
  "$1" round open "$2" --head "$3" >/dev/null 2>&1 ||
    fail "round open refused under cap: job=$2"
}

write_verdict() { # write_verdict <path> <verdict> <head>
  printf 'findings body\nVERDICT: %s @%s\n' "$2" "$3" >"$1"
}

escalate_count() { # escalate_count <events-dir> — cap-reason escalates
  python3 - "$1" <<'PY'
import json, pathlib, sys
n = 0
for p in pathlib.Path(sys.argv[1]).glob("*.json"):
    try:
        e = json.loads(p.read_text())
    except ValueError:
        continue
    if e.get("kind") == "job.escalate" and e.get("reason") == "tester round cap reached":
        n += 1
print(n)
PY
}

cat >"$TMP/hk-template" <<'EOF'
#!/usr/bin/env bash
# handoffkeep stub: doc get <key> / tasks comments <id> (JSON with \n escapes)
if [[ "$1 $2" == "doc get" ]]; then
  case "$3" in
    good2)      printf '{"session":"director-1","created_by":"director-1","body":"approved\\nround-extension: job=JOB extra=2 by=director-1\\n"}' ;;
    good2diff)  printf '{"session":"mac-personal","created_by":"director-1","body":"round-extension: job=JOB extra=2 by=director-1\\n"}' ;;
    good2nosess) printf '{"session":"","created_by":"director-1","body":"round-extension: job=JOB extra=1 by=director-1\\n"}' ;;
    forged)     printf '{"session":"JOB-lane","created_by":"JOB-lane","body":"round-extension: job=JOB extra=5 by=director-1\\n"}' ;;
    sessforge)  printf '{"session":"director-1","created_by":"mac-personal","body":"round-extension: job=JOB extra=2 by=director-1\\n"}' ;;
    pasess)     printf '{"session":"pa-integrator","created_by":"mac-personal","body":"round-extension: job=JOB extra=1 by=pa-integrator\\n"}' ;;
    padoc)      printf '{"session":"","created_by":"pa-integrator","body":"round-extension: job=JOB extra=1 by=pa-integrator\\n"}' ;;
    macdoc)     printf '{"session":"mac-personal","created_by":"mac-personal","body":"round-extension: job=JOB extra=1 by=mac-personal\\n"}' ;;
    nocreated)  printf '{"session":"director-1","body":"round-extension: job=JOB extra=2 by=director-1\\n"}' ;;
    wrongj)     printf '{"session":"director-1","created_by":"director-1","body":"round-extension: job=other-job extra=9 by=director-1\\n"}' ;;
    opdoc)      printf '{"session":"operator-desk","created_by":"operator-desk","body":"round-extension: job=JOB extra=1 by=operator\\n"}' ;;
    opgood)     printf '{"session":"operator-desk","created_by":"operator-desk","body":"round-extension: job=JOB extra=1 by=operator-desk\\n"}' ;;
    badws)      printf '{"session":"director-1","created_by":"director-1","body":"  round-extension :  job=JOB\\textra=1\\tby=director-1  \\n"}' ;;
    selfops)    printf '{"session":"JOB-lane","created_by":"JOB-lane","body":"round-extension: job=JOB extra=5 by=JOB-lane\\n"}' ;;
    nogrant)    printf '{"session":"director-1","created_by":"director-1","body":"looks approved but no grant line\\n"}' ;;
    devdoc)     printf '{"session":"mac-dev","created_by":"mac-dev","body":"round-extension: job=JOB extra=2 by=mac-dev\\n"}' ;;
    cbempty)    printf '{"session":"","created_by":"","body":"round-extension: job=JOB extra=2 by=director-1\\n"}' ;;
    cbnull)     printf '{"session":"","created_by":null,"body":"round-extension: job=JOB extra=2 by=director-1\\n"}' ;;
    cbpad)      printf '{"session":"","created_by":" director-1 ","body":"round-extension: job=JOB extra=2 by=director-1\\n"}' ;;
    cbcase)     printf '{"session":"","created_by":"Director-1","body":"round-extension: job=JOB extra=2 by=director-1\\n"}' ;;
    cbnum)      printf '{"session":"","created_by":1447,"body":"round-extension: job=JOB extra=2 by=director-1\\n"}' ;;
    *) printf 'not_found' ;;
  esac
elif [[ "$1 $2" == "tasks comments" ]]; then
  case "$3" in
    91) printf '{"comments":[{"author":"mac-personal","body":"go one more\\nround-extension: job=JOB extra=1 by=mac-personal\\n"}]}' ;;
    92) printf '{"comments":[{"author":"JOB-lane","body":"round-extension: job=JOB extra=3 by=director-1\\n"}]}' ;;
    93) printf '{"comments":[{"author":"operator-desk","body":"round-extension: job=JOB extra=1 by=operator-desk\\n"}]}' ;;
    94) printf '{"comments":[{"body":"round-extension: job=JOB extra=2 by=director-1\\n"}]}' ;;
    95) printf '{"comments":[{"author":91,"body":"round-extension: job=JOB extra=2 by=director-1\\n"}]}' ;;
    *)  printf '{"comments":[]}' ;;
  esac
elif [[ "$1 $2" == "tasks show" ]]; then
  case "$3" in
    701) printf '{"id":701,"project":"ParkingArcade","refs":{"job_id":"JOB"}}' ;;
    702) printf '{"id":702,"project":"agent-skills","refs":{"job_id":"JOB"}}' ;;
    703) printf '{"id":703,"project":"ParkingArcade","refs":{"job_id":"other-job"}}' ;;
    704) printf '{"id":704,"project":"ParkingArcade"}' ;;
    706) printf 'not json at all' ;;
    707) exit 1 ;;
    *)  printf 'not_found' ;;
  esac
else
  exit 1
fi
EOF
mk_hk() { sed "s/JOB/$1/g" "$TMP/hk-template" >"$TMP/hk-$1"; chmod +x "$TMP/hk-$1"; }
export HANDOFFKEEP_BIN="$TMP/absent-handoffkeep"

# ── counting: rounds open in order, verdict binds oldest unverdicted round ──
mkjob jc
open_ok "$WRK" jc "$H1"
open_ok "$WRK" jc "$H2"
write_verdict "$TMP/v1.md" BLOCKER "$H1"
out="$("$WRK" round verdict jc --file "$TMP/v1.md")"
grep -q 'round=1' <<<"$out" || fail "verdict must bind the oldest open round: $out"
open_ok "$WRK" jc "$H3"
status="$("$WRK" round status jc)"
grep -q 'rounds=3' <<<"$status" || fail "status lost count: $status"
grep -q 'open=2,3' <<<"$status" || fail "open rounds must be 2,3: $status"
grep -q "last_verdict=BLOCKER@$H1" <<<"$status" || fail "last verdict lost: $status"
grep -q "last_findings=$TMP/v1.md" <<<"$status" || fail "findings path lost: $status"
python3 - "$ARBITER_INBOX_ROOT/jc/events" <<'PY'
import json, pathlib, sys
evs = [json.loads(p.read_text()) for p in sorted(pathlib.Path(sys.argv[1]).glob("*.json"))]
kinds = [e["kind"] for e in evs]
assert kinds == ["job.claim", "job.round", "job.round", "job.verdict", "job.round"], kinds
assert [e["round"] for e in evs if e["kind"] == "job.round"] == [1, 2, 3]
v = next(e for e in evs if e["kind"] == "job.verdict")
assert v["round"] == 1 and v["verdict"] == "BLOCKER" and v["head"].startswith("1111"), v
PY
echo "PASS round-counting-and-binding"

# ── cap refusal: 4th open dies rc 78 and writes no job.round ────────────────
expect_rc 78 "$WRK" round open jc --head "$H4"
expect_rc 78 "$WRK" round open jc --head "$H4"
[[ "$(find "$ARBITER_INBOX_ROOT/jc/events" -name '*-job.round.json' | wc -l)" -eq 3 ]] ||
  fail "a refused open still wrote a job.round"
[[ "$(escalate_count "$ARBITER_INBOX_ROOT/jc/events")" == 1 ]] ||
  fail "cap refusal must emit exactly one reasoned job.escalate"
python3 - "$ARBITER_INBOX_ROOT/jc/events" "$TMP/v1.md" <<'PY'
import json, pathlib, sys
evs = [json.loads(p.read_text()) for p in sorted(pathlib.Path(sys.argv[1]).glob("*.json"))]
e = next(e for e in evs
         if e["kind"] == "job.escalate" and e["reason"] == "tester round cap reached")
assert e["parent_lane"] == "director-1" and e["owner_lane"] == "jc-lane", e
assert e["head"].startswith("4444"), e
assert e["rounds"] == 3 and e["cap"] == 3, e
assert e["last_verdict"].startswith("BLOCKER@1111"), e
assert e["findings_path"] == sys.argv[2] == e["report_path"], e
assert "question" in e, e
PY
echo "PASS cap-refusal-rc78-single-escalate"

# ── head changes do not reset the count (stale-count dodge) ─────────────────
mkjob jh
open_ok "$WRK" jh "$H1"
open_ok "$WRK" jh "$H2"
open_ok "$WRK" jh "$H3"
expect_rc 78 "$WRK" round open jh --head "$H1"   # same head again still capped
expect_rc 78 "$WRK" round open jh --head "$H4"   # a new head is not a new budget
echo "PASS head-change-keeps-count"

# ── sub-round naming: a verdict without an open round still counts ──────────
mkjob js
write_verdict "$TMP/vs.md" BLOCKER "$H1"
out="$("$WRK" round verdict js --file "$TMP/vs.md")"
grep -q 'round=unopened' <<<"$out" || fail "unbound verdict must report unopened: $out"
status="$("$WRK" round status js)"
grep -q 'rounds=1' <<<"$status" || fail "unopened verdict must consume a round: $status"
open_ok "$WRK" js "$H2"
open_ok "$WRK" js "$H3"
expect_rc 78 "$WRK" round open js --head "$H4"   # 1 verdict + 2 opens = 3
python3 - "$ARBITER_INBOX_ROOT/js/events" <<'PY'
import json, pathlib, sys
evs = [json.loads(p.read_text()) for p in sorted(pathlib.Path(sys.argv[1]).glob("*.json"))]
v = next(e for e in evs if e["kind"] == "job.verdict")
assert v.get("unopened") is True and v["round"] is None, v
PY
echo "PASS unopened-verdict-counts-as-round"

# ── verdict contract: malformed file and short sha are usage errors ─────────
printf 'no verdict line here\n' >"$TMP/bad.md"
expect_rc 2 "$WRK" round verdict jc --file "$TMP/bad.md"
expect_rc 2 "$WRK" round open jc --head "${H4:0:12}"
expect_rc 2 "$WRK" round verdict jc --file "$TMP/absent.md"
printf 'VERDICT: PASS @%sF\n' "$H1" >"$TMP/long41.md"        # 41-hex token
expect_rc 2 "$WRK" round verdict jc --file "$TMP/long41.md"
printf 'VERDICT: PASS @%sZ\n' "$H1" >"$TMP/tailz.md"        # 40 hex + suffix char
expect_rc 2 "$WRK" round verdict jc --file "$TMP/tailz.md"
printf 'VERDICT: PASS @%s notes\n' "$H1" >"$TMP/trail.md"   # trailing commentary
expect_rc 2 "$WRK" round verdict jc --file "$TMP/trail.md"
write_verdict "$TMP/multi.md" BLOCKER "$H1"
printf 'VERDICT: PASS @%s\n' "$H2" >>"$TMP/multi.md"        # ambiguous file
expect_rc 2 "$WRK" round verdict jc --file "$TMP/multi.md"
echo "PASS verdict-file-and-sha-contract"

# ── extension: refused without a valid approval ─────────────────────────────
mkjob je
mk_hk je
export HANDOFFKEEP_BIN="$TMP/hk-je"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" je "$h"; done
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/missing
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/forged    # own created_by claims director-1
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/sessforge # session says director-1, created_by is mac-personal
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/nocreated # no server-set identity at all
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/pasess    # session pa-integrator, created_by mac-personal
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/padoc     # pa-integrator is not this job's parent lane
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/macdoc    # mac-personal dropped from the trusted set
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/wrongj    # grant names another job
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/opdoc     # by=operator but created_by is operator-desk
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/badws     # noncanonical grant whitespace
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/selfops   # own lane in WRK_ROUND_CAP_OPERATORS must be ignored
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/nogrant   # no grant line
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:task/91       # comment author mac-personal no longer trusted
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:task/92       # comment author is the builder
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:task/94       # comment without an author
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:task/95       # non-string comment author
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/cbempty   # empty created_by
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/cbnull    # null created_by
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/cbpad     # whitespace-padded created_by — exact compare
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/cbcase    # differently cased created_by — exact compare
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/cbnum     # non-string created_by
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:bogus/x       # unknown ref scheme
expect_rc 78 "$WRK" round open je --head "$H4"                         # still capped afterwards
[[ "$(find "$ARBITER_INBOX_ROOT/je/events" -name '*-job.round.json' | wc -l)" -eq 3 ]] ||
  fail "a refused extension still wrote a job.round"
echo "PASS extension-forged-and-missing-approvals-refused"

# ── extension: valid doc grant extra=2 buys exactly two opens ───────────────
mkjob jx
mk_hk jx
export HANDOFFKEEP_BIN="$TMP/hk-jx"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jx "$h"; done
expect_rc 78 "$WRK" round open jx --head "$H4"                         # first refusal: escalate at rounds=3
[[ "$(escalate_count "$ARBITER_INBOX_ROOT/jx/events")" == 1 ]] ||
  fail "first cap refusal must emit the cap escalate"
"$WRK" round open jx --head "$H4" --extend hk:doc/good2 >/dev/null
"$WRK" round open jx --head "$H4" --extend hk:doc/good2 >/dev/null
expect_rc 78 "$WRK" round open jx --head "$H4" --extend hk:doc/good2   # grant exhausted: escalate again at rounds=5
expect_rc 78 "$WRK" round open jx --head "$H4" --extend hk:doc/good2   # same count stays deduplicated
[[ "$(escalate_count "$ARBITER_INBOX_ROOT/jx/events")" == 2 ]] ||
  fail "a refusal at a higher count must reach the parent again (got $(escalate_count "$ARBITER_INBOX_ROOT/jx/events"))"
status="$("$WRK" round status jx)"
grep -q 'rounds=5' <<<"$status" || fail "extension rounds not counted: $status"
python3 - "$ARBITER_INBOX_ROOT/jx/events" <<'PY'
import json, pathlib, sys
evs = [json.loads(p.read_text()) for p in sorted(pathlib.Path(sys.argv[1]).glob("*.json"))]
ext = [e for e in evs if e["kind"] == "job.round" and e.get("approval")]
assert len(ext) == 2, ext
for e in ext:
    assert e["approval"] == {"ref": "hk:doc/good2", "issuer": "director-1", "extra": 2}, e
esc = [e for e in evs
       if e["kind"] == "job.escalate" and e["reason"] == "tester round cap reached"]
assert [e["rounds"] for e in esc] == [3, 5], esc
PY
echo "PASS extension-doc-grant-consumed-per-round"

# ── extension: task comment author is server-set; mac-personal cannot grant ──
mkjob jt
mk_hk jt
export HANDOFFKEEP_BIN="$TMP/hk-jt"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jt "$h"; done
"$WRK" round open jt --head "$H4" --extend hk:task/93 >/dev/null        # operator-desk comment grants
expect_rc 78 "$WRK" round open jt --head "$H4" --extend hk:task/93
echo "PASS extension-task-comment-one-round"

# ── extension: doc session is ignored — only server-set created_by counts ────
mkjob jd
mk_hk jd
export HANDOFFKEEP_BIN="$TMP/hk-jd"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jd "$h"; done
"$WRK" round open jd --head "$H4" --extend hk:doc/good2diff >/dev/null   # session disagrees, created_by director-1 grants
"$WRK" round open jd --head "$H4" --extend hk:doc/good2nosess >/dev/null # empty session still grants on created_by
expect_rc 78 "$WRK" round open jd --head "$H4" --extend hk:doc/good2nosess # extra=1 consumed
echo "PASS extension-doc-session-ignored"

# ── extension: parent-lane grant needs the lane's own server-set client id ────
mkjob jp pa-integrator 701
mk_hk jp
export HANDOFFKEEP_BIN="$TMP/hk-jp"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jp "$h"; done
"$WRK" round open jp --head "$H4" --extend hk:doc/padoc >/dev/null       # created_by pa-integrator is this job's parent lane
expect_rc 78 "$WRK" round open jp --head "$H4" --extend hk:doc/padoc     # extra=1 consumed
echo "PASS extension-parent-lane-grant"

# ── extension: a builder-rewritten or host-id parent lane never grants ───────
# The recorded parent lane is builder-writable through job.reclaim events;
# only lanes in the fixed ROUND_CAP_PARENT_ISSUERS set may grant (#1447 B1).
mkjob jrf
mk_hk jrf
export HANDOFFKEEP_BIN="$TMP/hk-jrf"
reclaim jrf mac-dev
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jrf "$h"; done
expect_rc 2 "$WRK" round open jrf --head "$H4" --extend hk:doc/devdoc    # reclaim rewrote the parent to mac-dev

mkjob jrm
mk_hk jrm
export HANDOFFKEEP_BIN="$TMP/hk-jrm"
reclaim jrm mac-personal
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jrm "$h"; done
expect_rc 2 "$WRK" round open jrm --head "$H4" --extend hk:doc/macdoc    # same rewrite to mac-personal

mkjob jrh mac-personal
mk_hk jrh
export HANDOFFKEEP_BIN="$TMP/hk-jrh"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jrh "$h"; done
expect_rc 2 "$WRK" round open jrh --head "$H4" --extend hk:doc/macdoc    # a host-id parent from the start (S2)
echo "PASS extension-rewritten-parent-refused"

# ── extension: by=pa-integrator counts only on ParkingArcade server tasks ─────
# The job's recorded task_id must fetch on the server to a task whose project
# is exactly ParkingArcade and whose refs.job_id is exactly this job.
mkjob jpa pa-integrator 701
mk_hk jpa
export HANDOFFKEEP_BIN="$TMP/hk-jpa"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jpa "$h"; done
"$WRK" round open jpa --head "$H4" --extend hk:doc/padoc >/dev/null       # PA task bound to this job
expect_rc 78 "$WRK" round open jpa --head "$H4" --extend hk:doc/padoc     # extra=1 consumed

mkjob jpb pa-integrator 702
mk_hk jpb
export HANDOFFKEEP_BIN="$TMP/hk-jpb"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jpb "$h"; done
expect_rc 2 "$WRK" round open jpb --head "$H4" --extend hk:doc/padoc      # project is agent-skills

mkjob jpc pa-integrator 703
mk_hk jpc
export HANDOFFKEEP_BIN="$TMP/hk-jpc"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jpc "$h"; done
expect_rc 2 "$WRK" round open jpc --head "$H4" --extend hk:doc/padoc      # PA task bound to another job

mkjob jpd pa-integrator 704
mk_hk jpd
export HANDOFFKEEP_BIN="$TMP/hk-jpd"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jpd "$h"; done
expect_rc 2 "$WRK" round open jpd --head "$H4" --extend hk:doc/padoc      # PA task without refs.job_id

mkjob jpe pa-integrator 705
mk_hk jpe
export HANDOFFKEEP_BIN="$TMP/hk-jpe"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jpe "$h"; done
expect_rc 2 "$WRK" round open jpe --head "$H4" --extend hk:doc/padoc      # task fetch returns not_found

mkjob jpk pa-integrator 707
mk_hk jpk
export HANDOFFKEEP_BIN="$TMP/hk-jpk"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jpk "$h"; done
expect_rc 2 "$WRK" round open jpk --head "$H4" --extend hk:doc/padoc      # task fetch transport failure

mkjob jpf pa-integrator 706
mk_hk jpf
export HANDOFFKEEP_BIN="$TMP/hk-jpf"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jpf "$h"; done
expect_rc 2 "$WRK" round open jpf --head "$H4" --extend hk:doc/padoc      # task record is not JSON

mkjob jpg pa-integrator
mk_hk jpg
export HANDOFFKEEP_BIN="$TMP/hk-jpg"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jpg "$h"; done
expect_rc 2 "$WRK" round open jpg --head "$H4" --extend hk:doc/padoc      # no task_id in the job meta

# A builder relinking its own job meta to a PA task bound to another job must
# not pass: the reclaim rewrite is honoured for the read, but the server task
# still names the other job.
mkjob jpr
mk_hk jpr
export HANDOFFKEEP_BIN="$TMP/hk-jpr"
reclaim jpr pa-integrator 703
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jpr "$h"; done
expect_rc 2 "$WRK" round open jpr --head "$H4" --extend hk:doc/padoc
echo "PASS extension-pa-grant-needs-parkingarcade-task"

# ── extension: operator doc grant where by= equals the created_by ────────────
mkjob jg
mk_hk jg
export HANDOFFKEEP_BIN="$TMP/hk-jg"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jg "$h"; done
"$WRK" round open jg --head "$H4" --extend hk:doc/opgood >/dev/null
expect_rc 78 "$WRK" round open jg --head "$H4" --extend hk:doc/opgood
echo "PASS extension-operator-identity-one-round"

# ── --extend before the cap is a usage error ────────────────────────────────
mkjob ju
mk_hk ju
export HANDOFFKEEP_BIN="$TMP/hk-ju"
open_ok "$WRK" ju "$H1"
expect_rc 2 "$WRK" round open ju --head "$H2" --extend hk:doc/good2
echo "PASS extend-before-cap-refused"

# ── orphan verdict at the cap: recorded, escalated, rc 78 ───────────────────
mkjob jo
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jo "$h"; done
for n in 1 2 3; do
  write_verdict "$TMP/vo$n.md" BLOCKER "$H1"
  "$WRK" round verdict jo --file "$TMP/vo$n.md" >/dev/null
done
write_verdict "$TMP/vo4.md" BLOCKER "$H4"
expect_rc 78 "$WRK" round verdict jo --file "$TMP/vo4.md"
status="$("$WRK" round status jo)"
grep -q 'rounds=4' <<<"$status" || fail "over-cap verdict must still count: $status"
[[ "$(escalate_count "$ARBITER_INBOX_ROOT/jo/events")" == 1 ]] ||
  fail "over-cap orphan verdict must emit the cap escalate"
python3 - "$ARBITER_INBOX_ROOT/jo/events" <<'PY'
import json, pathlib, sys
evs = [json.loads(p.read_text()) for p in sorted(pathlib.Path(sys.argv[1]).glob("*.json"))]
v = [e for e in evs if e["kind"] == "job.verdict"][-1]
assert v.get("unopened") is True, v
PY
echo "PASS over-cap-orphan-verdict"

# ── assertion-RED mutants over the wrk source ────────────────────────────────
mutant() { # mutant <name> <spec-file>; spec lines are 'OLD => NEW' (first match)
  local name="$1" spec="$2"
  python3 - "$WRK" "$TMP/$name-wrk" "$spec" <<'PY'
import sys
src_path, out_path, spec_path = sys.argv[1:]
src = open(src_path, encoding="utf-8").read()
for i, line in enumerate(open(spec_path, encoding="utf-8").read().splitlines()):
    old, sep, new = line.partition(" => ")
    assert sep, f"spec line {i}: {line!r}"
    assert old in src, f"spec line {i} not found in wrk: {old!r}"
    src = src.replace(old, new, 1)
open(out_path, "w", encoding="utf-8").write(src)
PY
  chmod +x "$TMP/$name-wrk"
}

# Each spec anchor must be unique in the source or the first replace hits
# the wrong site.
python3 - "$WRK" <<'PY'
src = open(__import__("sys").argv[1], encoding="utf-8").read()
for anchor in (
    "if used >= cap:",
    '"reason": "tester round cap reached", "question": question,',
    "        used += 1  # this unbound verdict is itself a round",
    "        if extra < 1 or issuer not in allowed_issuers or issuer != identity:",
    'r"^round-extension: job=(\\S+) extra=(\\d+) by=(\\S+)$"',
    "{40})\\s*$",
    "if len(matches) > 1:",
    'ROUND_CAP_OPERATORS="operator operator-desk"',
    'doc.get("created_by")',
    "({parent} & trusted_parents) | ops",
    "issuer != identity",
    't.get("project") == "ParkingArcade"',
    'refs.get("job_id") == job',
    "                and isinstance(r.get(\"rounds\"), int) and r[\"rounds\"] >= used):",
):
    assert src.count(anchor) == 1, (anchor, src.count(anchor))
PY

# mutant: the cap check in round open is removed. RED proof: the 4th open
# must succeed under the mutant — if it still fails, the cap test cannot be
# crediting the check.
printf 'if used >= cap: => if False:\n' >"$TMP/spec-nocap"
mutant nocap "$TMP/spec-nocap"
jmc="mut-capped"
mkjob "$jmc"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/nocap-wrk" "$jmc" "$h"; done
set +e
"$TMP/nocap-wrk" round open "$jmc" --head "$H4" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 78 && "$rc" -eq 0 ]] ||
  fail "mutant nocap did not remove the cap (4th open rc=$rc) — cap assertion is vacuous"
echo "PASS mutant-nocap"

# mutant: the cap escalate keeps its kind but loses its reason — the parent
# cannot tell a cap stop from a generic escalation
printf '"reason": "tester round cap reached", "question": question, => "reason": "cap suppressed", "question": question,\n' >"$TMP/spec-noesc"
mutant noesc "$TMP/spec-noesc"
jme="mut-esc"
mkjob "$jme"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/noesc-wrk" "$jme" "$h"; done
set +e
"$TMP/noesc-wrk" round open "$jme" --head "$H4" >/dev/null 2>&1
set -e
[[ "$(escalate_count "$ARBITER_INBOX_ROOT/$jme/events")" == 0 ]] ||
  fail "mutant noesc still emitted a reasoned cap escalate"
echo "PASS mutant-noesc"

# mutant: an unopened verdict no longer counts as a round. RED proof: at the
# cap the mutant must let the over-cap verdict through with rc 0 — the rc 78
# assertion is what credits the counting.
printf '        used += 1  # this unbound verdict is itself a round =>         pass\n' >"$TMP/spec-nocount"
mutant nocount "$TMP/spec-nocount"
jmn="mut-nc"
mkjob "$jmn"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/nocount-wrk" "$jmn" "$h"; done
for n in 1 2 3; do
  write_verdict "$TMP/vnc$n.md" BLOCKER "$H1"
  "$TMP/nocount-wrk" round verdict "$jmn" --file "$TMP/vnc$n.md" >/dev/null 2>&1
done
write_verdict "$TMP/vnc4.md" BLOCKER "$H4"
set +e
"$TMP/nocount-wrk" round verdict "$jmn" --file "$TMP/vnc4.md" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant nocount still refused the over-cap verdict (rc=$rc) — verdict-cap assertion is vacuous"
echo "PASS mutant-nocount"

# mutant: approval issuer no longer checked against session/author
printf '        if extra < 1 or issuer not in allowed_issuers or issuer != identity: =>         if extra < 1 or issuer not in allowed_issuers:\n' >"$TMP/spec-noforge"
mutant noforge "$TMP/spec-noforge"
jmf="mut-nf"
mkjob "$jmf"
mk_hk "$jmf"
export HANDOFFKEEP_BIN="$TMP/hk-$jmf"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/noforge-wrk" "$jmf" "$h"; done
set +e
"$TMP/noforge-wrk" round open "$jmf" --head "$H4" --extend hk:doc/forged >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant noforge did not accept the forged approval (rc=$rc) — issuer assertion is vacuous"
echo "PASS mutant-noforge"

# mutant: the grant regex accepts noncanonical whitespace — the badws doc then
# grants, proving the strict-form assertion credits the canonical regex.
printf 'r"^round-extension: job=(\\S+) extra=(\\d+) by=(\\S+)$" => r"^\\s*round-extension\\s*:\\s*job=(\\S+)\\s+extra=(\\d+)\\s+by=(\\S+)\\s*$"\n' >"$TMP/spec-loosews"
mutant loosews "$TMP/spec-loosews"
jmw="mut-ws"
mkjob "$jmw"
mk_hk "$jmw"
export HANDOFFKEEP_BIN="$TMP/hk-$jmw"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/loosews-wrk" "$jmw" "$h"; done
set +e
"$TMP/loosews-wrk" round open "$jmw" --head "$H4" --extend hk:doc/badws >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant loosews did not accept the whitespace grant (rc=$rc) — whitespace assertion is vacuous"
echo "PASS mutant-loosews"

# mutant: the verdict regex loses its sha end boundary — a 41-hex token then
# records, proving the long-sha assertion credits the boundary.
printf '{40})\\s*$ => {40})\n' >"$TMP/spec-noshaend"
mutant noshaend "$TMP/spec-noshaend"
jml="mut-long"
mkjob "$jml"
printf 'VERDICT: PASS @%sF\n' "$H1" >"$TMP/vlong41.md"
set +e
"$TMP/noshaend-wrk" round verdict "$jml" --file "$TMP/vlong41.md" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant noshaend still refused the 41-hex verdict (rc=$rc) — sha-boundary assertion is vacuous"
echo "PASS mutant-noshaend"

# mutant: ambiguous verdict files (two VERDICT lines) are accepted — proves
# the ambiguity assertion credits the >1 match check.
printf 'if len(matches) > 1: => if False:\n' >"$TMP/spec-multi"
mutant multi "$TMP/spec-multi"
jmm="mut-mv"
mkjob "$jmm"
write_verdict "$TMP/vmulti.md" BLOCKER "$H1"
printf 'VERDICT: PASS @%s\n' "$H2" >>"$TMP/vmulti.md"
set +e
"$TMP/multi-wrk" round verdict "$jmm" --file "$TMP/vmulti.md" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant multi still refused the ambiguous verdict (rc=$rc) — ambiguity assertion is vacuous"
echo "PASS mutant-multi"

# mutant: the operator set becomes env-widenable again — a builder adds its own
# lane and its own doc grants itself. RED proof: selfops must grant (rc=0).
# shellcheck disable=SC2016 # the ${...} text is mutant-spec data, not an expansion
printf 'ROUND_CAP_OPERATORS="operator operator-desk" => ROUND_CAP_OPERATORS="${WRK_ROUND_CAP_OPERATORS:-operator operator-desk}"\n' >"$TMP/spec-envops"
mutant envops "$TMP/spec-envops"
jme2="mut-eo"
mkjob "$jme2"
mk_hk "$jme2"
export HANDOFFKEEP_BIN="$TMP/hk-$jme2"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/envops-wrk" "$jme2" "$h"; done
set +e
WRK_ROUND_CAP_OPERATORS="$jme2-lane" "$TMP/envops-wrk" round open "$jme2" --head "$H4" --extend hk:doc/selfops >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant envops did not accept the self-approval (rc=$rc) — fixed-operator-set assertion is vacuous"
echo "PASS mutant-envops"

# mutant: dedupe ignores the rounds count — any earlier cap escalate suppresses
# a later refusal at a higher count. RED proof: second escalate count stays 1.
printf '                and isinstance(r.get("rounds"), int) and r["rounds"] >= used): =>                 and isinstance(r.get("rounds"), int)):\n' >"$TMP/spec-dupsame"
mutant dupsame "$TMP/spec-dupsame"
jmd="mut-ds"
mkjob "$jmd"
mk_hk "$jmd"
export HANDOFFKEEP_BIN="$TMP/hk-$jmd"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/dupsame-wrk" "$jmd" "$h"; done
set +e
"$TMP/dupsame-wrk" round open "$jmd" --head "$H4" >/dev/null 2>&1
set -e
"$TMP/dupsame-wrk" round open "$jmd" --head "$H4" --extend hk:doc/good2 >/dev/null
set +e
"$TMP/dupsame-wrk" round open "$jmd" --head "$H4" >/dev/null 2>&1
set -e
[[ "$(escalate_count "$ARBITER_INBOX_ROOT/$jmd/events")" == 1 ]] ||
  fail "mutant dupsame still emitted the higher-count escalate — dedupe assertion is vacuous"
echo "PASS mutant-dupsame"

# mutant: the doc identity is read from the client-supplied session again —
# the sessforge doc (session director-1, created_by mac-personal) then grants.
printf 'doc.get("created_by") => doc.get("session")\n' >"$TMP/spec-sessident"
mutant sessident "$TMP/spec-sessident"
jmsi="mut-si"
mkjob "$jmsi"
mk_hk "$jmsi"
export HANDOFFKEEP_BIN="$TMP/hk-$jmsi"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/sessident-wrk" "$jmsi" "$h"; done
set +e
"$TMP/sessident-wrk" round open "$jmsi" --head "$H4" --extend hk:doc/sessforge >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant sessident did not accept the session-forged doc (rc=$rc) — created_by assertion is vacuous"
echo "PASS mutant-sessident"

# mutant: mac-personal is trusted again — the mac-personal-authored comment
# (task/91) then grants. RED proof: rc 0.
printf 'ROUND_CAP_OPERATORS="operator operator-desk" => ROUND_CAP_OPERATORS="operator operator-desk mac-personal"\n' >"$TMP/spec-macops"
mutant macops "$TMP/spec-macops"
jmmo="mut-mo"
mkjob "$jmmo"
mk_hk "$jmmo"
export HANDOFFKEEP_BIN="$TMP/hk-$jmmo"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/macops-wrk" "$jmmo" "$h"; done
set +e
"$TMP/macops-wrk" round open "$jmmo" --head "$H4" --extend hk:task/91 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant macops did not accept the mac-personal grant (rc=$rc) — operator-set assertion is vacuous"
echo "PASS mutant-macops"

# mutant: pa-integrator is allowed regardless of the job's parent lane —
# padoc then grants for a director-1 child (the job still binds a PA task so
# the mutant isolates the issuer-set change, not the server-task check).
printf '({parent} & trusted_parents) | ops => ({parent} & trusted_parents) | ops | {"pa-integrator"}\n' >"$TMP/spec-anypa"
mutant anypa "$TMP/spec-anypa"
jmpa="mut-pa"
mkjob "$jmpa" director-1 701
mk_hk "$jmpa"
export HANDOFFKEEP_BIN="$TMP/hk-$jmpa"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/anypa-wrk" "$jmpa" "$h"; done
set +e
"$TMP/anypa-wrk" round open "$jmpa" --head "$H4" --extend hk:doc/padoc >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant anypa did not accept the cross-parent grant (rc=$rc) — parent-lane assertion is vacuous"
echo "PASS mutant-anypa"

# mutant: the parent-set check is dropped — a builder-rewritten host-id
# parent then grants again (the reclaim forgery the fixed set exists to stop).
printf '({parent} & trusted_parents) | ops => {parent} | ops\n' >"$TMP/spec-noparentset"
mutant noparentset "$TMP/spec-noparentset"
jmps="mut-ps"
mkjob "$jmps"
mk_hk "$jmps"
export HANDOFFKEEP_BIN="$TMP/hk-$jmps"
reclaim "$jmps" mac-dev
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/noparentset-wrk" "$jmps" "$h"; done
set +e
"$TMP/noparentset-wrk" round open "$jmps" --head "$H4" --extend hk:doc/devdoc >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant noparentset did not accept the rewritten-parent grant (rc=$rc) — parent-set assertion is vacuous"
echo "PASS mutant-noparentset"

# mutant: the server-set identity is stripped before compare — a padded
# created_by then matches, crediting the exact-string requirement.
printf 'issuer != identity => issuer != identity.strip()\n' >"$TMP/spec-stripid"
mutant stripid "$TMP/spec-stripid"
jmst="mut-st"
mkjob "$jmst"
mk_hk "$jmst"
export HANDOFFKEEP_BIN="$TMP/hk-$jmst"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/stripid-wrk" "$jmst" "$h"; done
set +e
"$TMP/stripid-wrk" round open "$jmst" --head "$H4" --extend hk:doc/cbpad >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant stripid did not accept the padded identity (rc=$rc) — exact-match assertion is vacuous"
echo "PASS mutant-stripid"

# mutant: the identity compare is case-folded — a differently cased
# created_by then matches.
printf 'issuer != identity => issuer.lower() != identity.lower()\n' >"$TMP/spec-lowerid"
mutant lowerid "$TMP/spec-lowerid"
jmlc="mut-lc"
mkjob "$jmlc"
mk_hk "$jmlc"
export HANDOFFKEEP_BIN="$TMP/hk-$jmlc"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/lowerid-wrk" "$jmlc" "$h"; done
set +e
"$TMP/lowerid-wrk" round open "$jmlc" --head "$H4" --extend hk:doc/cbcase >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant lowerid did not accept the differently cased identity (rc=$rc) — exact-match assertion is vacuous"
echo "PASS mutant-lowerid"

# mutant: the pa-integrator project check is skipped — an agent-skills task
# then satisfies a pa-integrator grant.
printf 't.get("project") == "ParkingArcade" => True\n' >"$TMP/spec-noproj"
mutant noproj "$TMP/spec-noproj"
jmnp="mut-np"
mkjob "$jmnp" pa-integrator 702
mk_hk "$jmnp"
export HANDOFFKEEP_BIN="$TMP/hk-$jmnp"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/noproj-wrk" "$jmnp" "$h"; done
set +e
"$TMP/noproj-wrk" round open "$jmnp" --head "$H4" --extend hk:doc/padoc >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant noproj did not accept the wrong-project grant (rc=$rc) — project assertion is vacuous"
echo "PASS mutant-noproj"

# mutant: the refs.job_id match is skipped — a ParkingArcade task bound to
# another job then satisfies the grant.
printf 'refs.get("job_id") == job => True\n' >"$TMP/spec-norefs"
mutant norefs "$TMP/spec-norefs"
jmnr="mut-nr"
mkjob "$jmnr" pa-integrator 703
mk_hk "$jmnr"
export HANDOFFKEEP_BIN="$TMP/hk-$jmnr"
for h in "$H1" "$H2" "$H3"; do open_ok "$TMP/norefs-wrk" "$jmnr" "$h"; done
set +e
"$TMP/norefs-wrk" round open "$jmnr" --head "$H4" --extend hk:doc/padoc >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] ||
  fail "mutant norefs did not accept the other-job grant (rc=$rc) — refs assertion is vacuous"
echo "PASS mutant-norefs"

echo "ALL PASS round-cap"
