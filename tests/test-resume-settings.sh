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
#   AC5  non-claude kinds and --purpose director write nothing
# Mutants at the end: merge removed / ignore step removed / non-claude write —
# each must turn a check RED through an assertion (rc 1), never a fixture error.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
TMP="$(mktemp -d)"
cleanup() {
  local pidfile pid
  while IFS= read -r pidfile; do
    [[ -s "$pidfile" ]] || continue
    read -r pid <"$pidfile" || continue
    if [[ "$pid" =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; fi
  done < <(find "$TMP" -name 'completion-sentinel.pid' 2>/dev/null)
  # A detached wrk refresh supervisor can still be appending refresh.log while
  # rm walks the tree; BSD rm then exits "Directory not empty" (seen on macOS
  # CI). Retry briefly so the tail of a successful run cannot flake the suite.
  local i=0
  while ((i < 10)); do
    rm -rf "$TMP" 2>/dev/null && return 0
    i=$((i + 1))
    sleep 0.3
  done
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
export WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml"
export PANEWIRE_BIN="$ROOT/tests/fixtures/panewire"
export HANDOFFKEEP_BIN="$TMP/absent-handoffkeep"
export KIMI_CODE_HOME="$TMP/kimi-home"
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
    "$wrk" spawn -c "$cwd" -m "$model" -p "$PROMPT" -w w -l fixture --t T1 "$@" >/dev/null 2>>"$TMP/wrk.stderr"
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
chmod +x "$MUT"/wrk-*
expect_red no-merge mut_ac2
expect_red no-ignore mut_ac4
expect_red non-claude mut_ac5
echo "PASS mutants assertion-red=3/3 (merge removed, ignore removed, non-claude writes)"
