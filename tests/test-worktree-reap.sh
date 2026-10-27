#!/usr/bin/env bash
# hk 2091 contract tests: `wrk worktree-reap` removes a linked worktree only
# when all six conditions are measured at run time — linked (never a main
# checkout), task merged/dropped through a receipt or task link naming the
# worktree as its cwd, git status --porcelain empty (untracked included),
# 0 unpushed (ls-remote equality or ancestor of a fresh origin/main),
# no live herdr pane cwd inside and no live completion sentinel of a bound
# job, and a merge/drop older than --age (default 3d). Removal is
# `git worktree remove` without --force; anything unprovable keeps with a
# named reason. The MUT section runs assertion-RED mutants — sed'd copies of
# bin/wrk — so a silently dropped check fails the suite instead of drifting.
set -euo pipefail
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
TMP="$(mktemp -d)"
# Physical path: `git worktree list` reports resolved paths (/var vs
# /private/var on macOS), and assertions compare them verbatim.
TMP="$(cd "$TMP" && pwd -P)"
export HOME="$TMP/home" WORK="$TMP/home/work"
XDG="$TMP/xdg" INBOX="$TMP/inbox" HK_DB="$TMP/hk.json" AGENTS="$TMP/agents.json"
mkdir -p "$WORK" "$INBOX" "$XDG" "$TMP/bin"
printf '%s\n' '{"result":{"agents":[]}}' >"$AGENTS"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The fixture binaries must sit under the temp root: trust-mode mutants run
# from $TMP too, and a HANDOFFKEEP_BIN under tests/fixtures is judged only
# against the script's own directory. Copies keep every invocation inside the
# temp-root allowance.
cp "$ROOT/tests/fixtures/handoffkeep" "$TMP/bin/handoffkeep"
HK="$TMP/bin/handoffkeep"

# herdr stub: `agent list` serves $HERDR_AGENTS (per-case file); anything else
# fails closed. agent list drives the live-pane cwd guard.
cat >"$TMP/bin/herdr" <<'SH'
#!/bin/sh
if [ "$1 $2" = "agent list" ]; then
  cat "${HERDR_AGENTS:?}" || exit 1
  exit 0
fi
exit 1
SH
chmod +x "$TMP/bin/herdr"

# wrk stub for a fake live completion sentinel: `stubbin/wrk sentinel J O L P R`
# stays alive as `sh stubbin/wrk sentinel J O L P R` — the argv shape
# sentinel_sweep matches. Started per sentinel case; killed by cleanup.
cat >"$TMP/bin/wrk" <<'SH'
#!/bin/sh
sleep 300
SH
chmod +x "$TMP/bin/wrk"

# Job ids are host-unique: the live-sentinel sweep matches argv on a global
# `ps`, and other suites' leaked sentinel fixtures must never collide with a
# job this test binds.
JOBP="wreap$$"
SENT_PIDS=""
cleanup() {
  local p c
  for p in $SENT_PIDS; do
    for c in $(pgrep -P "$p" 2>/dev/null || true); do kill "$c" 2>/dev/null || true; done
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# ── git fixture: bare remote + repos under $WORK ───────────────────────────
ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"

# mkrepo NAME URL — one main checkout under $WORK with origin set.
mkrepo() {
  git init -q -b main "$WORK/$1"
  git -C "$WORK/$1" config user.email fixture@example.invalid
  git -C "$WORK/$1" config user.name 'Worktree Fixture'
  printf 'seed\n' >"$WORK/$1/f"
  git -C "$WORK/$1" add f
  git -C "$WORK/$1" commit -qm init
  git -C "$WORK/$1" remote add origin "$2"
}
mkrepo repo "$ORIGIN"
git -C "$WORK/repo" push -qu origin main

iso_ago() { python3 - "$1" <<'PY'
import datetime, sys
print((datetime.datetime.now(datetime.timezone.utc)
       - datetime.timedelta(seconds=int(sys.argv[1]))).isoformat())
PY
}

# add_linked NAME — linked worktree $WORK/repo.NAME on pushed branch wk/NAME.
add_linked() {
  git -C "$WORK/repo" worktree add -q -b "wk/$1" "$WORK/repo.$1"
  git -C "$WORK/repo.$1" push -qu origin "wk/$1"
}

# seed_task ID STATE AT [JOB] — write one task into the fixture db.
seed_task() {
  python3 - "$HK_DB" "$1" "$2" "$3" "${4:-}" <<'PY'
import json, sys
path, tid, state, at, job = sys.argv[1:]
try:
    db = json.load(open(path))
except (OSError, ValueError):
    db = {"tasks": {}}
t = {"id": int(tid), "lane": "l", "title": "t", "kind": "implement",
     "priority": 0, "claimed_by": job, "created_by": "fixture", "state": state,
     "refs": {"job_id": job} if job else {},
     "created_at": at, "updated_at": at, "events": []}
if state in ("merged", "dropped"):
    t["events"].append({"kind": "transition", "from": "claimed", "to": state,
                        "by": job or "fixture", "at": at})
db.setdefault("tasks", {})[tid] = t
json.dump(db, open(path, "w"))
PY
}

# mkjob JOB WT TASK — claim receipt naming the worktree as cwd plus task.
mkjob() {
  local ev="$INBOX/$1/events"
  mkdir -p "$ev"
  cat >"$ev/00001-job.claim.json" <<EOF
{"created_at":"2026-10-20T00:00:00Z","job_id":"$1","kind":"job.claim","payload":{"agent_label":"$1","owner_lane":"$1-lane","pane_id":"w:p1","role":"worker","cwd":"$2","task_id":$3},"seq":1}
EOF
}

# mkjob_link JOB WT TASK — the "task link" half of the rule: a job.task_link
# event whose payload names the worktree as cwd.
mkjob_link() {
  local ev="$INBOX/$1/events"
  mkdir -p "$ev"
  cat >"$ev/00001-job.task_link.json" <<EOF
{"created_at":"2026-10-20T00:00:00Z","job_id":"$1","kind":"job.task_link","payload":{"status":"linked","job_id":"$1","claimed_by":"$1","mode":"owner","cwd":"$2","task_id":$3},"seq":1}
EOF
}

# reap_try [MUTANT-WRK] -- ARGS — run worktree-reap; rc in REAP_RC, stdout in
# $TMP/reap.out. A leading executable path selects a mutant binary.
REAP_RC=0
reap_try() {
  local wrk="$WRK"
  if [[ -x "${1:-}" && "${1:-}" != -* ]]; then wrk="$1"; shift; fi
  set +e
  env -u ARBITER_JOB -u HK_TASK_ID \
    HOME="$HOME" ARBITER_INBOX_ROOT="$INBOX" XDG_DATA_HOME="$XDG" \
    HANDOFFKEEP_BIN="$HK" HK_STATE="$HK_DB" HERDR_BIN="$TMP/bin/herdr" \
    HERDR_AGENTS="$AGENTS" \
    "$wrk" worktree-reap "$@" </dev/null >"$TMP/reap.out" 2>"$TMP/reap.err"
  REAP_RC=$?
  set -e
}
expect_ok() { [[ "$REAP_RC" -eq 0 ]] || fail "$1: rc=$REAP_RC err=$(tail -n2 "$TMP/reap.err")"; }
expect_line() { grep -qF -- "$1" "$TMP/reap.out" || fail "$2 (missing '$1' in: $(cat "$TMP/reap.out"))"; }

# Case A: merged task, clean, pushed, no pane, past the grace — dry-run lists
# it, --apply removes it with git worktree remove.
TID=4101; WT="$WORK/repo.a"
add_linked a; mkjob "$JOBP-a" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-a"

reap_try
expect_ok "A dry-run"
expect_line "would-remove $WT" "A dry-run lists candidate"
[[ -d "$WT" ]] || fail "A dry-run removed the worktree anyway"

reap_try --apply
expect_ok "A apply"
expect_line "removed $WT" "A apply removes"
[[ ! -e "$WT" ]] || fail "A apply: worktree dir still present"
git -C "$WORK/repo" worktree list --porcelain | grep -qF "worktree $WT" &&
  fail "A apply: worktree still registered"
git -C "$WORK/repo" rev-parse --verify "refs/heads/wk/a" >/dev/null 2>&1 ||
  fail "A apply: branch wk/a should survive worktree removal"

# Case B: the same through a job.task_link payload (the "task link" half),
# and task dropped rather than merged.
TID=4102; WT="$WORK/repo.b"
add_linked b; mkjob_link "$JOBP-b" "$WT" $TID; seed_task $TID dropped "$(iso_ago 500000)" "$JOBP-b"
reap_try --apply
expect_ok "B apply"
expect_line "removed $WT" "B task_link-linked dropped worktree removed"

# Case C: main checkout is listed but never removed.
TID=4103; mkjob "$JOBP-main" "$WORK/repo" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-main"
reap_try
expect_ok "C dry-run"
expect_line "keep $WORK/repo reason=main-checkout" "C main checkout kept"

# Case D: operator-protected paths are refused even when they look merged and
# clean — ParkingArcade as a main checkout and ParkingArcade.pa-unity as a
# linked worktree (director amendment to hk 2091).
PA_ORIGIN="$TMP/pa-origin.git"; git init -q --bare "$PA_ORIGIN"
mkrepo ParkingArcade "$PA_ORIGIN"
git -C "$WORK/ParkingArcade" push -qu origin main
git -C "$WORK/ParkingArcade" worktree add -q -b wk/pa "$WORK/ParkingArcade.pa-unity"
git -C "$WORK/ParkingArcade.pa-unity" push -qu origin wk/pa
TID=4104; mkjob "$JOBP-pa-main" "$WORK/ParkingArcade" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-pa-main"
TID=4105; mkjob "$JOBP-pa-wt" "$WORK/ParkingArcade.pa-unity" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-pa-wt"
reap_try --apply
expect_ok "D apply"
expect_line "keep $WORK/ParkingArcade reason=protected" "D protected main"
expect_line "keep $WORK/ParkingArcade.pa-unity reason=protected" "D protected linked worktree"
[[ -d "$WORK/ParkingArcade.pa-unity" ]] || fail "D: protected worktree removed"
[[ -d "$WORK/ParkingArcade" ]] || fail "D: protected main removed"

# Case E: task still open.
TID=4106; WT="$WORK/repo.e"
add_linked e; mkjob "$JOBP-e" "$WT" $TID; seed_task $TID in_progress "$(iso_ago 400000)" "$JOBP-e"
reap_try
expect_ok "E"
expect_line "keep $WT reason=task-open(state=in_progress)" "E open task kept"

# Case F: no receipt or task link names the worktree — never guessed.
TID=4107; WT="$WORK/repo.f"
add_linked f; seed_task $TID merged "$(iso_ago 400000)" ""
reap_try
expect_ok "F"
expect_line "keep $WT reason=no-task-link" "F unlinked kept"

# Case F2: an unrelated event (job.note) carrying cwd + task_id must NOT bind —
# only receipts/task-links (job.claim/reclaim/attached/spawned/task_link) may.
TID=4303; WT="$WORK/repo.f2"
add_linked f2; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-f2"
mkdir -p "$INBOX/$JOBP-f2/events"
cat >"$INBOX/$JOBP-f2/events/00001-job.note.json" <<EOF
{"created_at":"2026-10-20T00:00:00Z","job_id":"$JOBP-f2","kind":"job.note","payload":{"cwd":"$WT","task_id":$TID,"text":"unrelated note"},"seq":1}
EOF
reap_try
expect_ok "F2"
expect_line "keep $WT reason=no-task-link" "F2 unrelated event cannot bind"

# Case G: dirty tracked file.
TID=4108; WT="$WORK/repo.g"
add_linked g; mkjob "$JOBP-g" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-g"
printf 'dirty\n' >>"$WT/f"
reap_try
expect_ok "G"
expect_line "keep $WT reason=dirty" "G dirty kept"

# Case H: untracked file only.
TID=4109; WT="$WORK/repo.h"
add_linked h; mkjob "$JOBP-h" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-h"
printf 'untracked\n' >"$WT/new"
reap_try
expect_ok "H"
expect_line "keep $WT reason=dirty" "H untracked kept"

# Case I: a local commit the remote does not have.
TID=4110; WT="$WORK/repo.i"
add_linked i; mkjob "$JOBP-i" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-i"
printf 'local\n' >"$WT/local-only"
git -C "$WT" add local-only; git -C "$WT" commit -qm local
reap_try
expect_ok "I"
expect_line "keep $WT reason=unpushed" "I unpushed kept"

# Case J: detached HEAD not on main.
TID=4111; WT="$WORK/repo.j"
add_linked j; mkjob "$JOBP-j" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-j"
printf 'local\n' >"$WT/local-only"
git -C "$WT" add local-only; git -C "$WT" commit -qm local
git -C "$WT" checkout -q --detach HEAD
reap_try
expect_ok "J"
expect_line "keep $WT reason=unpushed" "J detached kept"

# Case K: a live herdr pane with its cwd inside the worktree.
TID=4112; WT="$WORK/repo.k"
add_linked k; mkjob "$JOBP-k" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-k"
printf '{"result":{"agents":[{"pane_id":"w:p9","agent_status":"working","cwd":"%s/src"}]}}' "$WT" >"$AGENTS"
reap_try
expect_ok "K"
expect_line "keep $WT reason=pane-inside(pane=w:p9)" "K pane-inside kept"
printf '%s\n' '{"result":{"agents":[]}}' >"$AGENTS"

# Case L: a live completion sentinel of a job bound to the worktree.
TID=4113; WT="$WORK/repo.l"
add_linked l; mkjob "$JOBP-l" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-l"
"$TMP/bin/wrk" sentinel "$JOBP-l" owner-1 lbl w:p1 rpt &
SENT_PIDS="$SENT_PIDS $!"
sleep 1
reap_try
expect_ok "L"
expect_line "keep $WT reason=sentinel-live(job=$JOBP-l)" "L sentinel kept"

# Case M: merge inside the grace age (default 3d; merge 1h ago).
TID=4114; WT="$WORK/repo.m"
add_linked m; mkjob "$JOBP-m" "$WT" $TID; seed_task $TID merged "$(iso_ago 3600)" "$JOBP-m"
reap_try
expect_ok "M"
expect_line "keep $WT reason=within-age" "M within-age kept"
reap_try --age 1m
expect_ok "M age"
expect_line "would-remove $WT" "M past a smaller age is a candidate"

# Case N: remote unreachable — unpushed can never be proven. Its own repo so
# the dead origin cannot poison the shared one's remote config.
mkrepo repon "$TMP/no-such-remote.git"
TID=4115; WT="$WORK/repon.n"
git -C "$WORK/repon" worktree add -q -b wk/n "$WT"
mkjob "$JOBP-n" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-n"
reap_try
expect_ok "N"
expect_line "keep $WT reason=remote-unreachable" "N unreachable kept"

# Case O: a failure skips that worktree and continues. repo.o carries a
# submodule whose dirt `git status --porcelain` cannot see (ignore=dirty in
# .gitmodules) but `git worktree remove`'s own check still refuses it; repo.p
# is an ordinary removable worktree. Both lines print and repo.p still goes.
git init -q -b main "$TMP/subsrc"
git -C "$TMP/subsrc" config user.email fixture@example.invalid
git -C "$TMP/subsrc" config user.name 'Worktree Fixture'
printf 'sub\n' >"$TMP/subsrc/s"; git -C "$TMP/subsrc" add s; git -C "$TMP/subsrc" commit -qm s
git -C "$WORK/repo" -c protocol.file.allow=always submodule add -q "$TMP/subsrc" sub
git -C "$WORK/repo" config -f .gitmodules submodule.sub.ignore dirty
git -C "$WORK/repo" add .gitmodules
git -C "$WORK/repo" commit -qm subadd
git -C "$WORK/repo" push -q origin main
TID=4116; WT="$WORK/repo.o"
git -C "$WORK/repo" worktree add -q -b wk/o "$WT"
git -C "$WT" -c protocol.file.allow=always submodule update --init -q
git -C "$WT" push -qu origin wk/o
printf 'dirt\n' >>"$WT/sub/s"
mkjob "$JOBP-o" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-o"
[[ -z "$(git -C "$WT" status --porcelain)" ]] ||
  fail "O fixture: porcelain must be empty (submodule dirt hidden by ignore=dirty)"
TID=4117; WTP="$WORK/repo.p"
add_linked p; mkjob "$JOBP-p" "$WTP" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-p"
reap_try --apply
expect_ok "O apply"
expect_line "keep $WT reason=remove-failed" "O submodule worktree refused by git"
expect_line "removed $WTP" "O continues past the failure"

echo "PASS: functional cases"

# ── MUT: assertion-RED mutants at the real call sites ──────────────────────
# Each mutant is a sed'd copy of bin/wrk; the case it flips must go RED by
# assertion (the removed line proves the check was the thing keeping it).
MUTBIN="$TMP/mut"; mkdir -p "$MUTBIN"

# MUT1: dropping the untracked check must flip an untracked-only worktree to
# a removal. The mutant adds --untracked-files=no to the porcelain call.
sed 's/"status", "--porcelain"/"status", "--porcelain", "--untracked-files=no"/' "$WRK" >"$MUTBIN/wrk-mut1"
chmod +x "$MUTBIN/wrk-mut1"
grep -q -- '--untracked-files=no' "$MUTBIN/wrk-mut1" || fail "MUT1 sed did not land"
TID=4301; WT="$WORK/repo.mut1"
add_linked mut1; mkjob "$JOBP-mut1" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-mut1"
printf 'untracked\n' >"$WT/new"
reap_try "$MUTBIN/wrk-mut1" --apply
expect_ok "MUT1"
expect_line "keep $WT reason=remove-failed" "MUT1 RED: untracked-only worktree reaches removal without the untracked check (git's own remove still refuses)"

# MUT2: trusting the local tracking ref instead of ls-remote must flip a
# stale-ref worktree to a removal. wk/m2 was pushed at the local commit, the
# remote then advanced one commit — refs/remotes/origin/wk/m2 is stale at
# HEAD while the true remote head is ahead.
TID=4201; WT="$WORK/repo.m2"
add_linked m2; mkjob "$JOBP-m2" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-m2"
printf 'local\n' >"$WT/local-only"
git -C "$WT" add local-only; git -C "$WT" commit -qm local
git -C "$WT" push -qu origin wk/m2
git clone -q "$ORIGIN" "$TMP/adv"
git -C "$TMP/adv" config user.email fixture@example.invalid
git -C "$TMP/adv" config user.name 'Worktree Fixture'
git -C "$TMP/adv" checkout -q wk/m2
printf 'ahead\n' >"$TMP/adv/ahead"
git -C "$TMP/adv" add ahead; git -C "$TMP/adv" commit -qm ahead
git -C "$TMP/adv" push -q origin wk/m2
[[ "$(git -C "$WT" rev-parse refs/remotes/origin/wk/m2)" == "$(git -C "$WT" rev-parse HEAD)" ]] ||
  fail "MUT2 fixture: local tracking ref must be stale at HEAD"
reap_try
expect_ok "MUT2 real run"
expect_line "keep $WT reason=unpushed" "MUT2 real wrk keeps stale-ref worktree"
sed 's/"ls-remote", "origin", "refs\/heads\/" + branch/"rev-parse", "--verify", "refs\/remotes\/origin\/" + branch/' "$WRK" >"$MUTBIN/wrk-mut2"
chmod +x "$MUTBIN/wrk-mut2"
grep -q 'refs/remotes/origin' "$MUTBIN/wrk-mut2" || fail "MUT2 sed did not land"
reap_try "$MUTBIN/wrk-mut2" --apply
expect_ok "MUT2"
expect_line "removed $WT" "MUT2 RED: stale-ref worktree removed by trusting the local ref"

# MUT3: --force on the remove call must flip a dirty case git refuses —
# another submodule-dirty worktree in the case-O shape.
# shellcheck disable=SC2016 # the $path text is the literal bash call site, not an expansion
sed 's/worktree remove "$path"/worktree remove --force "$path"/' "$WRK" >"$MUTBIN/wrk-mut3"
chmod +x "$MUTBIN/wrk-mut3"
grep -q 'worktree remove --force' "$MUTBIN/wrk-mut3" || fail "MUT3 sed did not land"
TID=4302; WT="$WORK/repo.mut3"
git -C "$WORK/repo" worktree add -q -b wk/mut3 "$WT"
git -C "$WT" -c protocol.file.allow=always submodule update --init -q
git -C "$WT" push -qu origin wk/mut3
printf 'dirt\n' >>"$WT/sub/s"
mkjob "$JOBP-mut3" "$WT" $TID; seed_task $TID merged "$(iso_ago 400000)" "$JOBP-mut3"
reap_try "$MUTBIN/wrk-mut3" --apply
expect_ok "MUT3"
expect_line "removed $WT" "MUT3 RED: submodule-dirty worktree removed by --force"

echo "PASS: worktree-reap"
