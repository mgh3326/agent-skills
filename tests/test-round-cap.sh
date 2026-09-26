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
export WRK_ROUND_CAP_OPERATORS="operator operator-desk mac-personal"

H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H3=3333333333333333333333333333333333333333
H4=4444444444444444444444444444444444444444

fail() { echo "FAIL: $*" >&2; exit 1; }

mkjob() { # mkjob <name> — builder claim envelope
  local events="$ARBITER_INBOX_ROOT/$1/events"
  mkdir -p "$events"
  cat >"$events/00001-job.claim.json" <<EOF
{"created_at":"2026-09-27T00:00:00Z","job_id":"$1","kind":"job.claim","payload":{"agent_label":"$1","owner_lane":"$1-lane","pane_id":"w:p1","parent_lane":"director-1","role":"builder","t_level":"T2"},"seq":1}
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
    good2)   printf '{"session":"director-1","body":"approved\\nround-extension: job=JOB extra=2 by=director-1\\n"}' ;;
    forged)  printf '{"session":"JOB-lane","body":"round-extension: job=JOB extra=5 by=director-1\\n"}' ;;
    wrongj)  printf '{"session":"director-1","body":"round-extension: job=other-job extra=9 by=director-1\\n"}' ;;
    opdoc)   printf '{"session":"operator-desk","body":"round-extension: job=JOB extra=1 by=operator\\n"}' ;;
    nogrant) printf '{"session":"director-1","body":"looks approved but no grant line\\n"}' ;;
    *) printf 'not_found' ;;
  esac
elif [[ "$1 $2" == "tasks comments" ]]; then
  case "$3" in
    91) printf '{"comments":[{"author":"mac-personal","body":"go one more\\nround-extension: job=JOB extra=1 by=mac-personal\\n"}]}' ;;
    92) printf '{"comments":[{"author":"JOB-lane","body":"round-extension: job=JOB extra=3 by=director-1\\n"}]}' ;;
    *)  printf '{"comments":[]}' ;;
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
echo "PASS verdict-file-and-sha-contract"

# ── extension: refused without a valid approval ─────────────────────────────
mkjob je
mk_hk je
export HANDOFFKEEP_BIN="$TMP/hk-je"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" je "$h"; done
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/missing
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/forged   # own session claims director-1
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/wrongj   # grant names another job
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:doc/nogrant  # no grant line
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:task/92      # comment author is the builder
expect_rc 2 "$WRK" round open je --head "$H4" --extend hk:bogus/x      # unknown ref scheme
expect_rc 78 "$WRK" round open je --head "$H4"                         # still capped afterwards
[[ "$(find "$ARBITER_INBOX_ROOT/je/events" -name '*-job.round.json' | wc -l)" -eq 3 ]] ||
  fail "a refused extension still wrote a job.round"
echo "PASS extension-forged-and-missing-approvals-refused"

# ── extension: valid doc grant extra=2 buys exactly two opens ───────────────
mkjob jx
mk_hk jx
export HANDOFFKEEP_BIN="$TMP/hk-jx"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jx "$h"; done
"$WRK" round open jx --head "$H4" --extend hk:doc/good2 >/dev/null
"$WRK" round open jx --head "$H4" --extend hk:doc/good2 >/dev/null
expect_rc 78 "$WRK" round open jx --head "$H4" --extend hk:doc/good2   # grant exhausted
status="$("$WRK" round status jx)"
grep -q 'rounds=5' <<<"$status" || fail "extension rounds not counted: $status"
python3 - "$ARBITER_INBOX_ROOT/jx/events" <<'PY'
import json, pathlib, sys
evs = [json.loads(p.read_text()) for p in sorted(pathlib.Path(sys.argv[1]).glob("*.json"))]
ext = [e for e in evs if e["kind"] == "job.round" and e.get("approval")]
assert len(ext) == 2, ext
for e in ext:
    assert e["approval"] == {"ref": "hk:doc/good2", "issuer": "director-1", "extra": 2}, e
PY
echo "PASS extension-doc-grant-consumed-per-round"

# ── extension: task comment by operator identity buys exactly one open ──────
mkjob jt
mk_hk jt
export HANDOFFKEEP_BIN="$TMP/hk-jt"
for h in "$H1" "$H2" "$H3"; do open_ok "$WRK" jt "$h"; done
"$WRK" round open jt --head "$H4" --extend hk:task/91 >/dev/null
expect_rc 78 "$WRK" round open jt --head "$H4" --extend hk:task/91
echo "PASS extension-task-comment-one-round"

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
    "        if identity != issuer and not (issuer in ops and identity in ops):",
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
printf '        if identity != issuer and not (issuer in ops and identity in ops): =>         if False:\n' >"$TMP/spec-noforge"
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

echo "ALL PASS round-cap"
