#!/usr/bin/env bash
# #637: when wrk spawns a claude-kind worker it must persist the launch-time
# env toggle into the worker worktree's own .claude/settings.local.json — the
# file a bare `claude --resume <id>` (herdr's reboot restore) re-reads on the
# next launch. The permission mode is deliberately not persisted: a local-file
# bypassPermissions cannot take effect on claude >= 2.1.257 and would force
# Manual mode on every flagless launch in the worktree (settings-reference).
#
# Covered here:
#   AC1  absent file  -> created with exactly our env key
#   AC2  existing file -> merged; unrelated keys preserved, our env overwritten
#   AC3  malformed file -> spawn fails closed, file untouched, no pane
#        (also: non-object JSON, env:null, and a tracked file all fail closed)
#   AC4  file is git-ignored (repo info/exclude fallback); git status clean
#        (also: a global excludes file covers it, and an exclude file without
#        a trailing newline keeps its last rule intact)
#   AC5  non-claude kinds and --purpose director write nothing
#   Symlinks: .claude or settings.local.json as a symlink (dangling included)
#        is warned-and-skipped — never written through or replaced.
# Mutants at the end: merge removed / ignore step removed / non-claude write /
# symlink guard removed / exclude newline fix removed — each must turn a check
# RED through an assertion (rc 1), never a fixture error.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
TMP="$(mktemp -d)"
# wrk spawn leaves detached writers that outlive their wrk and can still be
# creating entries under $TMP at teardown, so `rm -rf` raced them on CI and
# exited "Directory not empty" (the earlier 3s retry only narrowed the race;
# PR #155 ubuntu run 36283072131 / PR #156 macOS run 36288704921 are the same
# mechanism one suite earlier):
#
#   * a nohup'd `wrk sentinel` per arbiter-registered job — this suite points
#     ARBITER_BIN at an absent binary so none register here, but the pidfile
#     sweep below stays so a future real-arbiter case cannot regress;
#   * refresh_quota_pool's detached supervisor — `( python3 - … ) &` -> fork +
#     setsid -> `scopefuel refresh <pool> --background` — which appends
#     WRK_REFRESH_LOG. It carries no pidfile and nothing waits on it.
#
# Signaling alone is not enough: a TERM'd process can still be mid-write.
# Kill them and wait until none remain, then rm.
stop_tmp_writers() {
  local pidfile pid child snap stray i
  # Sentinels are named exactly by their pidfile. STOP first so one cannot
  # fork a fresh probe/sleep child between the child sweep and the TERM.
  while IFS= read -r pidfile; do
    [[ -s "$pidfile" ]] || continue
    read -r pid <"$pidfile" || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -STOP "$pid" 2>/dev/null || true
    while IFS= read -r child; do kill "$child" 2>/dev/null || true; done \
      < <(pgrep -P "$pid" 2>/dev/null || true)
    kill "$pid" 2>/dev/null || true
    kill -CONT "$pid" 2>/dev/null || true
  done < <(find "$TMP" -name 'completion-sentinel.pid' 2>/dev/null)
  # Pidfile-less writers are matched through the env every spawned process
  # inherits (XDG_DATA_HOME/ARBITER_INBOX_ROOT/HK_STATE and the fixture logs
  # all point under $TMP): the refresh supervisor and its scopefuel child,
  # orphaned sentinel sleeps/probes, a sentinel mid `arbiter release`.
  # Excluding $$ and its current children keeps the match scoped to this
  # run's detached procs only.
  for ((i = 0; i < 100; i++)); do
    snap="$(exec ps axeww -o pid= -o ppid= -o command= 2>/dev/null)" || true
    stray="$(awk -v self="$$" -v tmp="$TMP" \
      'index($0, tmp) && $1 != self && $2 != self {print $1}' <<<"$snap")" || true
    [[ -n "$stray" ]] || return 0
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      if ((i >= 50)); then kill -9 "$pid" 2>/dev/null || true; else kill "$pid" 2>/dev/null || true; fi
    done <<<"$stray"
    sleep 0.1
  done
}
cleanup() {
  stop_tmp_writers
  rm -rf "$TMP"
}
trap cleanup EXIT
PROMPT="$TMP/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"
export CLINEPASS_GATE_KEY_FILE="$TMP/clinepass-gate-key.txt"
printf 'fixture-gate-key\n' >"$CLINEPASS_GATE_KEY_FILE"
export ARBITER_BIN="$TMP/absent-arbiter"
export XDG_DATA_HOME="$TMP/xdg"
# #951: claude-kind spawns seed folder trust into ${CLAUDE_CONFIG_DIR:-$HOME}/
# .claude.json — fixture HOME keeps the operator's real config untouched.
export HOME="$TMP/home"
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR
export ARBITER_INBOX_ROOT="$TMP/inbox"
export WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml"
export PANEWIRE_BIN="$ROOT/tests/fixtures/panewire"
# #768: spawns bind an hk task; the fixture + a minted --task per spawn_in
# call keep the resume-settings contract identical otherwise.
export HANDOFFKEEP_BIN="$ROOT/tests/fixtures/handoffkeep"
export HK_STATE="$TMP/hk-state.json"
export KIMI_CODE_HOME="$TMP/kimi-home"
# #912: devin trust seeding fails closed on a missing store, so pre-seed the
# fixture XDG root — $TMP covers every mkrepo spawn cwd below (parent
# coverage is a legitimate no-op). The trust contract itself is tested in
# tests/test-wrk.sh.
mkdir -p "$XDG_DATA_HOME/devin/cli"
printf '{"trusted_paths": ["%s"]}\n' "$TMP" >"$XDG_DATA_HOME/devin/cli/trusted_workspaces.json"
# Isolate git's global ignore machinery: on a machine where Claude Code already
# wrote **/.claude/settings.local.json into the user excludes, check-ignore
# would pass without our info/exclude fallback and the mutant below could not
# go RED. An empty GIT_CONFIG_GLOBAL alone is not enough — the default
# excludesfile ($XDG_CONFIG_HOME/git/ignore) is not config-scoped, so isolate
# the XDG config dir and the system config too.
printf '' >"$TMP/gitconfig"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export XDG_CONFIG_HOME="$TMP/xdg-config-home"

WRK="$ROOT/bin/wrk"
SETTINGS='.claude/settings.local.json'

fail() { echo "FAIL: $*" >&2; exit 1; }

# mkrepo NAME: a real git worktree (scratch repo with one commit) under $TMP.
mkrepo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" -c user.email=t@fixture -c user.name=t commit -qm init --allow-empty
  printf '%s\n' "$d"
}

# spawn_in WRK CWD MODEL [ARGS...]: one fixture spawn; prints nothing on
# success. Returns the spawn's own rc so AC3 can require a nonzero one.
spawn_in() {
  local wrk="$1" cwd="$2" model="$3"; shift 3
  : >"$TMP/herdr.log"
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
    "$wrk" spawn -c "$cwd" -m "$model" -p "$PROMPT" -w w -l fixture --t T1 \
      --task "$("$HANDOFFKEEP_BIN" tasks add --title "resume task" 2>/dev/null |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" \
      "$@" >/dev/null 2>>"$TMP/wrk.stderr"
}

# assert_settings CWD EXPECT_JSON: compare the file's parsed content to the
# expected object — key set and values must match exactly.
assert_settings() {
  local label="$1" file="$2" expected="$3"
  [[ -f "$file" ]] || { echo "RED: $label: $file was not written" >&2; return 1; }
  python3 - "$file" "$expected" <<'PY' || { echo "RED: $label: file content mismatch" >&2; return 1; }
import json, sys
file, expected = sys.argv[1], json.loads(sys.argv[2])
try:
    with open(file, encoding="utf-8") as f:
        actual = json.load(f)
except ValueError as e:
    print("unparsable: %s" % e, file=sys.stderr)
    sys.exit(1)
if actual != expected:
    print("got %s" % json.dumps(actual, sort_keys=True), file=sys.stderr)
    sys.exit(1)
PY
}

# AC1 — file absent -> created with exactly our env key.
d="$(mkrepo ac1)"
spawn_in "$WRK" "$d" opus ||
  fail "AC1 spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
assert_settings "AC1 opus" "$d/$SETTINGS" \
  '{"env":{"CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION":"false"}}' ||
  exit 1
echo "PASS AC1 create: env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false, nothing else (no defaultMode — cannot express bypass from a local file)"

# AC2 — existing file merges: unrelated keys preserved, our env overwritten.
d="$(mkrepo ac2)"
mkdir -p "$d/.claude"
printf '%s\n' '{"model":"claude-opus-5-5","env":{"OTHER_VAR":"keep","CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION":"true"},"permissions":{"allow":["Bash(npm run *)"],"defaultMode":"plan"},"extra":{"nested":[1,2]}}' \
  >"$d/$SETTINGS"
spawn_in "$WRK" "$d" sonnet ||
  fail "AC2 spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
assert_settings "AC2 merge" "$d/$SETTINGS" \
  '{"model":"claude-opus-5-5","env":{"OTHER_VAR":"keep","CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION":"false"},"permissions":{"allow":["Bash(npm run *)"],"defaultMode":"plan"},"extra":{"nested":[1,2]}}' ||
  exit 1
echo "PASS AC2 merge: unrelated keys preserved (allow list, other env var, model, nested, existing defaultMode=plan), our env overwritten"

# AC3 — malformed existing file: fail closed, never clobber, no pane.
d="$(mkrepo ac3)"
mkdir -p "$d/.claude"
printf '%s\n' '{ this is not json' >"$d/$SETTINGS"
rc=0
spawn_in "$WRK" "$d" opus || rc=$?
[[ "$rc" -ne 0 ]] || { echo "RED: AC3: spawn succeeded over a malformed $SETTINGS" >&2; exit 1; }
grep -q "not valid JSON" "$TMP/wrk.stderr" ||
  { echo "RED: AC3: no clear malformed-file message: $(tail -n 3 "$TMP/wrk.stderr")" >&2; exit 1; }
printf '%s\n' '{ this is not json' | cmp -s - "$d/$SETTINGS" ||
  { echo "RED: AC3: malformed file was modified" >&2; exit 1; }
! grep -q '^tab create ' "$TMP/herdr.log" ||
  { echo "RED: AC3: a pane was created despite the malformed file" >&2; exit 1; }
echo "PASS AC3 malformed: spawn rc=$rc, file untouched, no tab create"

# A non-object JSON file fails closed the same way.
d="$(mkrepo ac3b)"
mkdir -p "$d/.claude"
printf '%s\n' '["just","a","list"]' >"$d/$SETTINGS"
rc=0
spawn_in "$WRK" "$d" opus || rc=$?
[[ "$rc" -ne 0 ]] || { echo "RED: AC3b: spawn succeeded over a non-object $SETTINGS" >&2; exit 1; }
grep -q "not a JSON object" "$TMP/wrk.stderr" ||
  { echo "RED: AC3b: no clear message: $(tail -n 3 "$TMP/wrk.stderr")" >&2; exit 1; }
echo "PASS AC3b non-object: spawn rc=$rc fail-closed"

# A present-but-non-object env node (null included) fails closed — it is an
# existing key we do not own, not "missing".
d="$(mkrepo ac3c)"
mkdir -p "$d/.claude"
printf '%s\n' '{"env":null}' >"$d/$SETTINGS"
rc=0
spawn_in "$WRK" "$d" opus || rc=$?
[[ "$rc" -ne 0 ]] || { echo "RED: AC3c: spawn succeeded over env:null $SETTINGS" >&2; exit 1; }
printf '%s\n' '{"env":null}' | cmp -s - "$d/$SETTINGS" ||
  { echo "RED: AC3c: env:null file was modified" >&2; exit 1; }
echo "PASS AC3c env-null: spawn rc=$rc fail-closed, file untouched"

# A tracked settings.local.json belongs to the repo — wrk must never modify a
# target repo's tracked files, so the spawn fails closed.
d="$(mkrepo ac3d)"
mkdir -p "$d/.claude"
printf '%s\n' '{"env":{"OTHER_VAR":"keep"}}' >"$d/$SETTINGS"
git -C "$d" add -f "$SETTINGS"
rc=0
spawn_in "$WRK" "$d" opus || rc=$?
[[ "$rc" -ne 0 ]] || { echo "RED: AC3d: spawn succeeded over a tracked $SETTINGS" >&2; exit 1; }
grep -q "tracked in the repo" "$TMP/wrk.stderr" ||
  { echo "RED: AC3d: no clear tracked-file message: $(tail -n 3 "$TMP/wrk.stderr")" >&2; exit 1; }
printf '%s\n' '{"env":{"OTHER_VAR":"keep"}}' | cmp -s - "$d/$SETTINGS" ||
  { echo "RED: AC3d: tracked file was modified" >&2; exit 1; }
! grep -q '^tab create ' "$TMP/herdr.log" ||
  { echo "RED: AC3d: a pane was created despite the tracked file" >&2; exit 1; }
echo "PASS AC3d tracked: spawn rc=$rc fail-closed, tracked file untouched, no pane"

# AC3e — a symlinked settings file or .claude directory (dangling included) is
# never written through or replaced: wrk warns and the spawn proceeds without
# persisted settings.
d="$(mkrepo ac3e)"
mkdir -p "$d/.claude"
ln -s "$TMP/ac3e-dangling-target" "$d/$SETTINGS"   # dangling leaf symlink
spawn_in "$WRK" "$d" opus ||
  fail "AC3e dangling-symlink spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
grep -q "symlink" "$TMP/wrk.stderr" ||
  { echo "RED: AC3e: no symlink warning: $(tail -n 3 "$TMP/wrk.stderr")" >&2; exit 1; }
[[ -L "$d/$SETTINGS" ]] ||
  { echo "RED: AC3e: dangling symlink was replaced by a regular file" >&2; exit 1; }
[[ ! -e "$TMP/ac3e-dangling-target" ]] ||
  { echo "RED: AC3e: wrote through the dangling symlink" >&2; exit 1; }

# A leaf symlink to a real shared file: the target must be untouched and the
# link must remain a link.
d="$(mkrepo ac3e2)"
mkdir -p "$d/.claude"
printf '%s\n' '{"env":{"KEEP":"x"}}' >"$TMP/ac3e-shared.json"
ln -s "$TMP/ac3e-shared.json" "$d/$SETTINGS"
spawn_in "$WRK" "$d" opus ||
  fail "AC3e live-symlink spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
[[ -L "$d/$SETTINGS" ]] ||
  { echo "RED: AC3e: live symlink was replaced by a regular file" >&2; exit 1; }
printf '%s\n' '{"env":{"KEEP":"x"}}' | cmp -s - "$TMP/ac3e-shared.json" ||
  { echo "RED: AC3e: shared settings target was modified" >&2; exit 1; }

# .claude itself a symlink to a directory outside the worktree.
d="$(mkrepo ac3e3)"
mkdir -p "$TMP/ac3e-extdir"
ln -s "$TMP/ac3e-extdir" "$d/.claude"
spawn_in "$WRK" "$d" opus ||
  fail "AC3e dir-symlink spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
grep -q "symlink" "$TMP/wrk.stderr" ||
  { echo "RED: AC3e dir: no symlink warning" >&2; exit 1; }
[[ ! -e "$TMP/ac3e-extdir/settings.local.json" ]] ||
  { echo "RED: AC3e dir: wrote into the symlinked .claude target" >&2; exit 1; }
echo "PASS AC3e symlinks: dangling/live leaf and .claude dir all left alone (warn, spawn proceeds)"

# AC4 — git ignores the file. The scratch repos carry no .gitignore rule, so
# coverage must come from the repo's info/exclude fallback.
d="$(mkrepo ac4)"
spawn_in "$WRK" "$d" opus ||
  fail "AC4 spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
git -C "$d" check-ignore -q -- "$SETTINGS" ||
  { echo "RED: AC4: $SETTINGS is not git-ignored in $d" >&2; exit 1; }
grep -qxF '**/.claude/settings.local.json' "$d/.git/info/exclude" ||
  { echo "RED: AC4: info/exclude lacks the pattern: $(cat "$d/.git/info/exclude" 2>/dev/null)" >&2; exit 1; }
[[ -z "$(git -C "$d" status --porcelain)" ]] ||
  { echo "RED: AC4: git status is not clean: $(git -C "$d" status --porcelain)" >&2; exit 1; }
echo "PASS AC4 ignore: check-ignore rc=0 via repo info/exclude, git status clean"

# Same, in a linked worktree of the scratch repo — the pattern lands in the
# common dir and still covers the worktree.
linked="$TMP/ac4-linked"
git -C "$d" worktree add --detach -q "$linked"
spawn_in "$WRK" "$linked" opus ||
  fail "AC4 linked-worktree spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
git -C "$linked" check-ignore -q -- "$SETTINGS" ||
  { echo "RED: AC4: linked worktree does not ignore $SETTINGS" >&2; exit 1; }
[[ -z "$(git -C "$linked" status --porcelain)" ]] ||
  { echo "RED: AC4: linked worktree git status is not clean" >&2; exit 1; }
echo "PASS AC4 linked worktree: shared info/exclude covers it, status clean"

# A repo that already ignores the path (tracked .gitignore) gets no
# info/exclude churn.
d="$(mkrepo ac4b)"
printf '%s\n' '.claude/settings.local.json' >"$d/.gitignore"
spawn_in "$WRK" "$d" opus ||
  fail "AC4b spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
git -C "$d" check-ignore -q -- "$SETTINGS" ||
  { echo "RED: AC4b: $SETTINGS not ignored despite .gitignore" >&2; exit 1; }
[[ "$(git -C "$d" status --porcelain)" == '?? .gitignore' ]] ||
  { echo "RED: AC4b: unexpected status: $(git -C "$d" status --porcelain)" >&2; exit 1; }
# git init ships a commented default info/exclude, so absence of our pattern —
# not an empty file — proves the fallback stayed out of it.
! grep -qxF '**/.claude/settings.local.json' "$d/.git/info/exclude" ||
  { echo "RED: AC4b: info/exclude touched though .gitignore already covered it" >&2; exit 1; }
echo "PASS AC4b: existing .gitignore honored, info/exclude untouched"

# A global excludes file that already covers the path (the Claude Code default
# on machines that have run it) means wrk adds nothing to info/exclude and
# check-ignore still passes — coverage comes from the user's excludes.
d="$(mkrepo ac4c)"
printf '[core]\n\texcludesFile = %s\n' "$TMP/global-excludes" >"$TMP/gitconfig-global-excl"
printf '%s\n' '**/.claude/settings.local.json' >"$TMP/global-excludes"
GIT_CONFIG_GLOBAL="$TMP/gitconfig-global-excl" spawn_in "$WRK" "$d" opus ||
  fail "AC4c spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
GIT_CONFIG_GLOBAL="$TMP/gitconfig-global-excl" git -C "$d" check-ignore -q -- "$SETTINGS" ||
  { echo "RED: AC4c: $SETTINGS not ignored despite global excludes" >&2; exit 1; }
! grep -qxF '**/.claude/settings.local.json' "$d/.git/info/exclude" ||
  { echo "RED: AC4c: info/exclude touched though global excludes covered it" >&2; exit 1; }
[[ -z "$(GIT_CONFIG_GLOBAL="$TMP/gitconfig-global-excl" git -C "$d" status --porcelain)" ]] ||
  { echo "RED: AC4c: git status is not clean under the user's excludes" >&2; exit 1; }
echo "PASS AC4c: global excludes honored, info/exclude untouched, status clean"

# An info/exclude without a trailing newline must not lose its last rule when
# our pattern is appended (CodeRabbit CR3).
d="$(mkrepo ac4d)"
printf 'secret.txt' >"$d/.git/info/exclude"   # no trailing newline
spawn_in "$WRK" "$d" opus ||
  fail "AC4d spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
git -C "$d" check-ignore -q -- secret.txt ||
  { echo "RED: AC4d: pre-existing rule 'secret.txt' was un-ignored by the append" >&2; exit 1; }
grep -qxF 'secret.txt' "$d/.git/info/exclude" ||
  { echo "RED: AC4d: 'secret.txt' line was altered" >&2; exit 1; }
grep -qxF '**/.claude/settings.local.json' "$d/.git/info/exclude" ||
  { echo "RED: AC4d: pattern not appended on its own line" >&2; exit 1; }
git -C "$d" check-ignore -q -- "$SETTINGS" ||
  { echo "RED: AC4d: $SETTINGS is not git-ignored" >&2; exit 1; }
echo "PASS AC4d newline: existing last rule preserved, pattern appended cleanly"

# AC5 — non-claude kinds and the resident opt-out write nothing.
d="$(mkrepo ac5-devin)"
spawn_in "$WRK" "$d" devin-swe2 ||
  fail "AC5 devin spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
[[ ! -e "$d/$SETTINGS" ]] ||
  { echo "RED: AC5: devin spawn wrote $SETTINGS" >&2; exit 1; }
d="$(mkrepo ac5-codex)"
spawn_in "$WRK" "$d" codex-terra ||
  fail "AC5 codex spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
[[ ! -e "$d/$SETTINGS" ]] ||
  { echo "RED: AC5: codex spawn wrote $SETTINGS" >&2; exit 1; }
d="$(mkrepo ac5-director)"
spawn_in "$WRK" "$d" opus --purpose director ||
  fail "AC5 director spawn failed: $(tail -n 3 "$TMP/wrk.stderr")"
[[ ! -e "$d/$SETTINGS" ]] ||
  { echo "RED: AC5: --purpose director wrote $SETTINGS" >&2; exit 1; }
echo "PASS AC5: devin/codex/director-purpose spawns write no file"

# Mutants — built from bin/wrk on disk at runtime; each must fail an
# assertion (rc 1), not error out (rc 99 from the fixture helpers).
MUT="$TMP/mutants"
mkdir -p "$MUT"

expect_red() {
  local label="$1"; shift
  local rc=0
  "$@" 2>/dev/null || rc=$?
  [[ "$rc" -eq 1 ]] || fail "mutant $label: expected assertion RED (rc 1), got rc $rc"
}

# Mutant 1 — merge removed: existing content is replaced instead of merged.
python3 - "$WRK" "$MUT/wrk-no-merge" <<'PY'
import sys
src, dst = sys.argv[1:]
text = open(src, encoding="utf-8").read()
old = "            data = json.load(f)\n"
assert text.count(old) == 1, "merge line must occur exactly once"
open(dst, "w", encoding="utf-8").write(text.replace(old, "            data = {}\n", 1))
PY
mut_ac2() {
  local d; d="$(mkrepo mut1)"
  mkdir -p "$d/.claude"
  printf '%s\n' '{"env":{"OTHER_VAR":"keep"}}' >"$d/$SETTINGS"
  spawn_in "$MUT/wrk-no-merge" "$d" opus || { echo "ERROR: mutant spawn failed" >&2; return 99; }
  python3 - "$d/$SETTINGS" <<'PY' || return 1
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("env", {}).get("OTHER_VAR") == "keep", "unrelated env key lost"
PY
}

# Mutant 2 — ignore step removed: the file is written but never ignored.
python3 - "$WRK" "$MUT/wrk-no-ignore" <<'PY'
import sys
src, dst = sys.argv[1:]
text = open(src, encoding="utf-8").read()
old = "    ensure_settings_local_ignored \"$CWD\"\n"
assert text.count(old) == 1, "ignore call must occur exactly once"
open(dst, "w", encoding="utf-8").write(text.replace(old, "    :\n", 1))
PY
mut_ac4() {
  local d; d="$(mkrepo mut2)"
  spawn_in "$MUT/wrk-no-ignore" "$d" opus || { echo "ERROR: mutant spawn failed" >&2; return 99; }
  git -C "$d" check-ignore -q -- "$SETTINGS" || return 1
}

# Mutant 3 — non-claude write: the kind guard widens to codex.
python3 - "$WRK" "$MUT/wrk-nonclaude" <<'PY'
import sys
src, dst = sys.argv[1:]
text = open(src, encoding="utf-8").read()
old = '  if [[ "$PROFILE_KIND" == claude && "${PURPOSE:-}" != director ]]; then\n'
assert text.count(old) == 1, "kind guard must occur exactly once"
open(dst, "w", encoding="utf-8").write(
    text.replace(old, '  if [[ "$PROFILE_KIND" != __never__ && "${PURPOSE:-}" != director ]]; then\n', 1))
PY
mut_ac5() {
  local d; d="$(mkrepo mut3)"
  spawn_in "$MUT/wrk-nonclaude" "$d" codex-terra || { echo "ERROR: mutant spawn failed" >&2; return 99; }
  [[ ! -e "$d/$SETTINGS" ]] || return 1
}

# Mutant 4 — symlink guard removed: a dangling settings.local.json symlink is
# silently replaced by a regular file (CodeRabbit CR4 regression).
python3 - "$WRK" "$MUT/wrk-no-symlink-guard" <<'PY'
import sys
src, dst = sys.argv[1:]
text = open(src, encoding="utf-8").read()
old = '  if [[ -L "$cwd/.claude" || -L "$cwd/.claude/settings.local.json" ]]; then\n'
assert text.count(old) == 1, "symlink guard must occur exactly once"
open(dst, "w", encoding="utf-8").write(text.replace(old, "  if false; then\n", 1))
PY
mut_ac3e() {
  local d; d="$(mkrepo mut4)"
  mkdir -p "$d/.claude"
  ln -s "$TMP/mut4-target" "$d/$SETTINGS"   # dangling leaf symlink
  spawn_in "$MUT/wrk-no-symlink-guard" "$d" opus || { echo "ERROR: mutant spawn failed" >&2; return 99; }
  [[ -L "$d/$SETTINGS" ]] || return 1
}

# Mutant 5 — exclude newline fix removed: a no-final-newline info/exclude
# loses its last rule when our pattern is appended (CodeRabbit CR3).
python3 - "$WRK" "$MUT/wrk-no-newline" <<'PY'
import sys
src, dst = sys.argv[1:]
text = open(src, encoding="utf-8").read()
old = '  if [[ -s "$common/info/exclude" ]] && [[ -n "$(tail -c 1 "$common/info/exclude" 2>/dev/null)" ]]; then\n'
assert text.count(old) == 1, "newline guard must occur exactly once"
open(dst, "w", encoding="utf-8").write(text.replace(old, "  if false; then\n", 1))
PY
mut_ac4d() {
  local d; d="$(mkrepo mut5)"
  printf 'secret.txt' >"$d/.git/info/exclude"   # no trailing newline
  spawn_in "$MUT/wrk-no-newline" "$d" opus || { echo "ERROR: mutant spawn failed" >&2; return 99; }
  git -C "$d" check-ignore -q -- secret.txt || return 1
}
chmod +x "$MUT"/wrk-*
expect_red no-merge mut_ac2
expect_red no-ignore mut_ac4
expect_red non-claude mut_ac5
expect_red no-symlink-guard mut_ac3e
expect_red no-newline-guard mut_ac4d
echo "PASS mutants assertion-red=5/5 (merge removed, ignore removed, non-claude writes, symlink guard removed, newline fix removed)"
