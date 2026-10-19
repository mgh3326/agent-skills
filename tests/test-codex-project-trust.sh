#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WRK="$ROOT/bin/wrk"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
HANDOFFKEEP="$ROOT/tests/fixtures/handoffkeep"
PANEWIRE="$ROOT/tests/fixtures/panewire"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/tmp-writers.sh"
TW_TMP="$TMP"
SOURCE="$TMP/source"
HOME_FIXTURE="$TMP/home"
XDG_DATA="$TMP/xdg-data"
FAKE_BIN="$TMP/fake-bin"
TASK_SEQ=1631000
SPAWN_SEQ=0
PROMPT="$TMP/prompt.md"

fail() {
  printf 'FAIL codex-project-trust: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ "${lock_holder_pid:-}" =~ ^[0-9]+$ ]]; then
    tw_kill_tree "$lock_holder_pid" 2>/dev/null || true
  fi
  tmp_writers_stop
  chmod 700 "$TMP/codex-readonly" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$HOME_FIXTURE" "$XDG_DATA" "$TMP/xdg-cache" "$TMP/xdg-config" \
  "$TMP/xdg-state" "$TMP/inbox/jobs" "$FAKE_BIN"
export HOME="$HOME_FIXTURE" CODEX_HOME="$TMP/codex-default" TMPDIR="$TMP"
export XDG_DATA_HOME="$XDG_DATA" XDG_CACHE_HOME="$TMP/xdg-cache"
export XDG_CONFIG_HOME="$TMP/xdg-config" XDG_STATE_HOME="$TMP/xdg-state"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$XDG_DATA/devin/cli"
python3 - "$TMP" "$XDG_DATA/devin/cli/trusted_workspaces.json" <<'PY'
import json, sys
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump({"trusted_paths": [sys.argv[1]]}, handle)
PY
printf '%s\n' 'fixture prompt' >"$PROMPT"

for agent in codex claude devin kimi; do
  cat >"$FAKE_BIN/$agent" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >>"$WRK_AGENT_STUB_LOG"
exit 0
STUB
  chmod +x "$FAKE_BIN/$agent"
done
WRK_AGENT_STUB_LOG="$TMP/agent-stubs.log"
: >"$WRK_AGENT_STUB_LOG"

git init -q "$SOURCE"
git -C "$SOURCE" config user.name 'Codex trust test'
git -C "$SOURCE" config user.email 'codex-trust-test@example.invalid'
printf '%s\n' 'fixture worktree' >"$SOURCE/README"
git -C "$SOURCE" add README
git -C "$SOURCE" commit -q -m 'fixture worktree'

add_worktree() {
  git -C "$SOURCE" worktree add --detach "$1" HEAD >/dev/null
}

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib, sys
with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
}

new_task() {
  TASK_SEQ=$((TASK_SEQ + 1))
  env -i PATH="$PATH" HK_STATE="$TMP/hk-state.json" \
    "$HANDOFFKEEP" tasks add --id "$TASK_SEQ" --title 'codex trust test' --lane fixture >/dev/null
  printf '%s\n' "$TASK_SEQ"
}

run_spawn() {
  local executable="$1" cwd="$2" model="$3" codex_home="$4"
  local home="${5:-$HOME_FIXTURE}" delay="${6:-}" py_path="${7:-}" lock_timeout="${8:-}" task label
  local env_args=(
    PATH="$FAKE_BIN:$PATH" HOME="$home" TMPDIR="$TMP"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
    XDG_DATA_HOME="$XDG_DATA" XDG_CACHE_HOME="$TMP/xdg-cache"
    XDG_CONFIG_HOME="$TMP/xdg-config" XDG_STATE_HOME="$TMP/xdg-state"
    HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" HANDOFFKEEP_BIN="$HANDOFFKEEP"
    PANEWIRE_BIN="$PANEWIRE" ARBITER_BIN="$TMP/absent-arbiter"
    ARBITER_INBOX_ROOT="$TMP/inbox" HK_STATE="$TMP/hk-state.json"
    WRK_HOSTS_CONFIG="$TMP/no-hosts.toml" WRK_NO_SLEEP=1
    WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn
    WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log"
    WRK_REFRESH_LOG="$TMP/refresh.log" WRK_REFRESH_PID_LOG="$TMP/refresh.pids"
    WRK_REFRESH_TIMEOUT_S=5 WRK_AGENT_STUB_LOG="$WRK_AGENT_STUB_LOG"
    KIMI_CODE_HOME="$TMP/kimi-code"
  )
  [[ -z "$codex_home" ]] || env_args+=(CODEX_HOME="$codex_home")
  [[ -z "$delay" ]] || env_args+=(WRK_TEST_CODEX_TRUST_DELAY_S="$delay")
  [[ -z "$py_path" ]] || env_args+=(PYTHONPATH="$py_path")
  [[ -z "$lock_timeout" ]] || env_args+=(WRK_TEST_CODEX_TRUST_LOCK_TIMEOUT_S="$lock_timeout")
  task="$(new_task)"
  SPAWN_SEQ=$((SPAWN_SEQ + 1))
  label="ct-$SPAWN_SEQ"
  env -i "${env_args[@]}" "$executable" spawn -c "$cwd" -m "$model" \
    -p "$PROMPT" -w w -l "$label" --t T1 --task "$task" --host local
}

spawn_ok() {
  local name="$1" executable="$2" cwd="$3" model="$4" codex_home="$5"
  local home="${6:-$HOME_FIXTURE}" delay="${7:-}" py_path="${8:-}" lock_timeout="${9:-}"
  local out="$TMP/$name.out" err="$TMP/$name.err"
  if ! run_spawn "$executable" "$cwd" "$model" "$codex_home" "$home" \
    "$delay" "$py_path" "$lock_timeout" >"$out" 2>"$err"; then
    cat "$out" "$err" >&2
    fail "$name spawn did not continue"
  fi
  grep -q '^OK ' "$out" || fail "$name spawn did not produce an OK line"
  if [[ "$model" == codex-luna ]]; then
    [[ "$(grep -c '^wrk: Codex project trust ' "$err" || true)" == 1 ]] ||
      fail "$name did not emit exactly one Codex trust result line"
  fi
}

assert_no_config() {
  local config_home="$1" name="$2"
  [[ ! -e "$config_home/config.toml" && ! -e "$config_home/config.toml.wrk.lock" ]] ||
    fail "$name unexpectedly touched Codex config home"
}

WORKTREE="$TMP/job-worktree"
add_worktree "$WORKTREE"
mkdir -p "$TMP/codex-existing"
CONFIG="$TMP/codex-existing/config.toml"
cat >"$CONFIG" <<'TOML'
# preserved comment
[model]
approval_policy   = "never"

# another project's table and intentionally uneven spacing
[projects."/tmp/other-project"]
  trust_level = "untrusted"
TOML
chmod 640 "$CONFIG"
ORIGINAL_SHA="$(sha256_file "$CONFIG")"
ORIGINAL_INODE="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$CONFIG")"
spawn_ok append "$WRK" "$WORKTREE" codex-luna "$TMP/codex-existing"
grep -q 'Codex project trust seeded .*validation=' "$TMP/append.err" ||
  fail 'new worktree was not reported as seeded'
python3 - "$CONFIG" "$WORKTREE" "$ORIGINAL_SHA" "$ORIGINAL_INODE" <<'PY'
import hashlib
import os
import stat
import sys

path, cwd, original_sha, original_inode = sys.argv[1:]
cwd = os.path.realpath(cwd)
with open(path, "rb") as handle:
    actual = handle.read()
prefix = b"# preserved comment\n[model]\napproval_policy   = \"never\"\n\n# another project's table and intentionally uneven spacing\n[projects.\"/tmp/other-project\"]\n  trust_level = \"untrusted\"\n"
block = ('[projects."%s"]\ntrust_level = "trusted"\n' % cwd).encode("ascii")
expected = prefix + b"\n" + block
if actual != expected:
    offset = next((i for i, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]), min(len(actual), len(expected)))
    raise AssertionError("append bytes differ (actual=%d expected=%d first_mismatch=%d)" % (len(actual), len(expected), offset))
assert hashlib.sha256(actual).hexdigest() != original_sha
assert os.stat(path).st_ino != int(original_inode), "write was in place instead of atomic replace"
assert stat.S_IMODE(os.stat(path).st_mode) == 0o640
try:
    import tomllib as parser
except ImportError:
    try:
        import tomli as parser
    except ImportError:
        parser = None
if parser is not None:
    data = parser.loads(actual.decode("utf-8"))
    assert data["projects"][cwd]["trust_level"] == "trusted"
PY
[[ "$(sha256_file "$CONFIG")" != "$ORIGINAL_SHA" ]] || fail 'config was not changed'
if grep -Eq 'approval_policy|untrusted|trust_level' "$TMP/append.err"; then
  fail 'Codex config contents appeared in spawn output'
fi
echo 'PASS append-prefix-parse-mode-atomic'

AFTER_FIRST_SHA="$(sha256_file "$CONFIG")"
spawn_ok exists "$WRK" "$WORKTREE" codex-luna "$TMP/codex-existing"
grep -q 'Codex project trust exists .*validation=' "$TMP/exists.err" || fail 'second spawn did not report exists'
[[ "$(sha256_file "$CONFIG")" == "$AFTER_FIRST_SHA" ]] || fail 'second spawn changed config bytes'
echo 'PASS existing-project-is-unchanged'

NEW_WORKTREE="$TMP/job-worktree-new"
add_worktree "$NEW_WORKTREE"
NEW_CODEX_HOME="$TMP/codex-new"
spawn_ok missing "$WRK" "$NEW_WORKTREE" codex-luna "$NEW_CODEX_HOME"
python3 - "$NEW_CODEX_HOME/config.toml" "$NEW_WORKTREE" <<'PY'
import os, stat, sys
path, cwd = sys.argv[1:]
cwd = os.path.realpath(cwd)
with open(path, "rb") as handle:
    data = handle.read()
assert data == ('[projects."%s"]\ntrust_level = "trusted"\n' % cwd).encode("ascii")
assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
PY
echo 'PASS missing-config-is-created-mode-600'

BAD_HOME="$TMP/codex-bad"
mkdir -p "$BAD_HOME"
printf '%s\n' '[projects.' >"$BAD_HOME/config.toml"
BAD_SHA="$(sha256_file "$BAD_HOME/config.toml")"
spawn_ok malformed "$WRK" "$WORKTREE" codex-luna "$BAD_HOME"
grep -q 'Codex project trust skipped (config does not parse)' "$TMP/malformed.err" ||
  fail 'malformed existing config did not warn'
[[ "$(sha256_file "$BAD_HOME/config.toml")" == "$BAD_SHA" ]] || fail 'malformed config was modified'
echo 'PASS malformed-config-fails-open-untouched'

READONLY_HOME="$TMP/codex-readonly"
mkdir -p "$READONLY_HOME"
printf '%s\n' '# read only fixture' >"$READONLY_HOME/config.toml"
READONLY_SHA="$(sha256_file "$READONLY_HOME/config.toml")"
chmod 500 "$READONLY_HOME"
spawn_ok readonly "$WRK" "$WORKTREE" codex-luna "$READONLY_HOME"
chmod 700 "$READONLY_HOME"
grep -q 'Codex project trust skipped .*lock file' "$TMP/readonly.err" ||
  fail 'read-only config directory did not warn'
[[ "$(sha256_file "$READONLY_HOME/config.toml")" == "$READONLY_SHA" ]] || fail 'read-only config changed'
echo 'PASS readonly-config-dir-fails-open-untouched'

LOCK_HOME="$TMP/codex-lock-timeout"
mkdir -p "$LOCK_HOME"
printf '%s\n' '# lock timeout fixture' >"$LOCK_HOME/config.toml"
LOCK_SHA="$(sha256_file "$LOCK_HOME/config.toml")"
LOCK_READY="$TMP/lock-ready"
python3 - "$LOCK_HOME/config.toml.wrk.lock" "$LOCK_READY" <<'PY' &
import fcntl, sys, time
with open(sys.argv[1], "a+b") as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    with open(sys.argv[2], "w", encoding="utf-8") as ready:
        ready.write("ready\n")
    time.sleep(30)
PY
lock_holder_pid=$!
for _ in {1..40}; do
  [[ -s "$LOCK_READY" ]] && break
  sleep 0.05
done
[[ -s "$LOCK_READY" ]] || fail 'lock-holder fixture did not acquire its lock'
spawn_ok lock-timeout "$WRK" "$WORKTREE" codex-luna "$LOCK_HOME" "$HOME_FIXTURE" '' '' 0.1
kill "$lock_holder_pid" 2>/dev/null || true
wait "$lock_holder_pid" 2>/dev/null || true
grep -q 'Codex project trust skipped (timed out waiting for lock)' "$TMP/lock-timeout.err" ||
  fail 'lock timeout did not warn and continue'
[[ "$(sha256_file "$LOCK_HOME/config.toml")" == "$LOCK_SHA" ]] || fail 'lock timeout changed config'
echo 'PASS lock-timeout-fails-open-untouched'

HOME_WORKTREE="$TMP/home-worktree"
add_worktree "$HOME_WORKTREE"
HOME_CODEX="$TMP/codex-home-refusal"
spawn_ok cwd-home "$WRK" "$HOME_WORKTREE" codex-luna "$HOME_CODEX" "$HOME_WORKTREE"
grep -q 'Codex project trust skipped (refusing HOME or its parent)' "$TMP/cwd-home.err" || fail 'HOME cwd was not refused'
assert_no_config "$HOME_CODEX" HOME

PARENT_WORKTREE="$TMP/home-parent-worktree"
add_worktree "$PARENT_WORKTREE"
mkdir -p "$PARENT_WORKTREE/child-home"
PARENT_CODEX="$TMP/codex-parent-refusal"
spawn_ok cwd-parent-home "$WRK" "$PARENT_WORKTREE" codex-luna "$PARENT_CODEX" "$PARENT_WORKTREE/child-home"
grep -q 'Codex project trust skipped (refusing HOME or its parent)' "$TMP/cwd-parent-home.err" || fail 'HOME parent cwd was not refused'
assert_no_config "$PARENT_CODEX" HOME-parent

ROOT_CODEX="$TMP/codex-root-refusal"
spawn_ok cwd-root "$WRK" / codex-luna "$ROOT_CODEX"
grep -q 'Codex project trust skipped (refusing filesystem root)' "$TMP/cwd-root.err" || fail 'filesystem root was not refused'
assert_no_config "$ROOT_CODEX" root

NONWORKTREE="$TMP/non-worktree"
mkdir -p "$NONWORKTREE"
NONWORKTREE_CODEX="$TMP/codex-non-worktree-refusal"
spawn_ok cwd-non-worktree "$WRK" "$NONWORKTREE" codex-luna "$NONWORKTREE_CODEX"
grep -q 'Codex project trust skipped (spawn cwd is not a linked worktree root)' "$TMP/cwd-non-worktree.err" || fail 'non-worktree cwd was not refused'
assert_no_config "$NONWORKTREE_CODEX" non-worktree

SPACE_WORKTREE="$TMP/job worktree"
add_worktree "$SPACE_WORKTREE"
SPACE_CODEX="$TMP/codex-space-refusal"
spawn_ok cwd-space "$WRK" "$SPACE_WORKTREE" codex-luna "$SPACE_CODEX"
grep -q 'Codex project trust skipped (spawn cwd contains unsupported characters)' "$TMP/cwd-space.err" || fail 'space in cwd was not refused'
assert_no_config "$SPACE_CODEX" space

QUOTE_WORKTREE="$TMP/job'worktree"
add_worktree "$QUOTE_WORKTREE"
QUOTE_CODEX="$TMP/codex-quote-refusal"
spawn_ok cwd-quote "$WRK" "$QUOTE_WORKTREE" codex-luna "$QUOTE_CODEX"
grep -q 'Codex project trust skipped (spawn cwd contains unsupported characters)' "$TMP/cwd-quote.err" || fail 'quote in cwd was not refused'
assert_no_config "$QUOTE_CODEX" quote
echo 'PASS HOME-root-worktree-and-bad-character-refusals'

DEFAULT_HOME="$TMP/default-home"
mkdir -p "$DEFAULT_HOME"
DEFAULT_CODEX="$DEFAULT_HOME/.codex"
DEFAULT_WORKTREE="$TMP/default-home-worktree"
add_worktree "$DEFAULT_WORKTREE"
spawn_ok default-home "$WRK" "$DEFAULT_WORKTREE" codex-luna '' "$DEFAULT_HOME"
[[ -f "$DEFAULT_CODEX/config.toml" ]] || fail 'unset CODEX_HOME did not use HOME/.codex'
echo 'PASS CODEX_HOME-override-and-default-paths'

NO_TOML="$TMP/no-toml"
mkdir -p "$NO_TOML"
cat >"$NO_TOML/sitecustomize.py" <<'PY'
import sys

# Block both import spellings, including importlib.import_module, so this
# fixture exercises the header-only fallback on every supported Python.
sys.modules["tomllib"] = None
sys.modules["tomli"] = None
PY
HEADER_HOME="$TMP/codex-header-only"
mkdir -p "$HEADER_HOME"
printf '%s\n' '# header-only validation fixture' >"$HEADER_HOME/config.toml"
spawn_ok header-only "$WRK" "$NEW_WORKTREE" codex-luna "$HEADER_HOME" "$HOME_FIXTURE" '' "$NO_TOML"
grep -q 'Codex project trust seeded .*validation=header-only' "$TMP/header-only.err" ||
  fail 'parser-unavailable run did not report header-only validation'
HEADER_SHA="$(sha256_file "$HEADER_HOME/config.toml")"
spawn_ok header-only-exists "$WRK" "$NEW_WORKTREE" codex-luna "$HEADER_HOME" "$HOME_FIXTURE" '' "$NO_TOML"
grep -q 'Codex project trust exists .*validation=header-only' "$TMP/header-only-exists.err" ||
  fail 'header-only mode did not detect an exact existing header'
[[ "$(sha256_file "$HEADER_HOME/config.toml")" == "$HEADER_SHA" ]] || fail 'header-only exists check changed config'
echo 'PASS header-only-validation-and-exists'

RACE_HOME="$TMP/codex-race"
RACE_A="$TMP/race-worktree-a"
RACE_B="$TMP/race-worktree-b"
add_worktree "$RACE_A"
add_worktree "$RACE_B"
run_spawn "$WRK" "$RACE_A" codex-luna "$RACE_HOME" "$HOME_FIXTURE" 1.0 >"$TMP/race-a.out" 2>"$TMP/race-a.err" &
race_a_pid=$!
run_spawn "$WRK" "$RACE_B" codex-luna "$RACE_HOME" "$HOME_FIXTURE" 1.0 >"$TMP/race-b.out" 2>"$TMP/race-b.err" &
race_b_pid=$!
wait "$race_a_pid" || fail 'first concurrent seeder failed'
wait "$race_b_pid" || fail 'second concurrent seeder failed'
grep -q '^OK ' "$TMP/race-a.out" || fail 'first concurrent spawn did not continue'
grep -q '^OK ' "$TMP/race-b.out" || fail 'second concurrent spawn did not continue'
[[ "$(grep -c '^wrk: Codex project trust ' "$TMP/race-a.err" || true)" == 1 ]] || fail 'first seeder did not log exactly one result'
[[ "$(grep -c '^wrk: Codex project trust ' "$TMP/race-b.err" || true)" == 1 ]] || fail 'second seeder did not log exactly one result'
python3 - "$RACE_HOME/config.toml" "$RACE_A" "$RACE_B" <<'PY'
import os, sys
try:
    import tomllib as parser
except ImportError:
    try:
        import tomli as parser
    except ImportError:
        parser = None
path, *cwd = sys.argv[1:]
cwd = [os.path.realpath(entry) for entry in cwd]
with open(path, "rb") as handle:
    raw = handle.read()
for entry in cwd:
    assert ('[projects."%s"]' % entry).encode("ascii") in raw.splitlines()
if parser is not None:
    with open(path, "rb") as handle:
        data = parser.load(handle)
    for entry in cwd:
        assert data["projects"][entry]["trust_level"] == "trusted"
PY
echo 'PASS concurrent-seeders-keep-both-projects'

NONCODEX_HOME="$TMP/codex-noncodex-sentinel"
mkdir -p "$NONCODEX_HOME"
printf '%s\n' 'leave-this-file-alone' >"$NONCODEX_HOME/config.toml"
NONCODEX_SHA="$(sha256_file "$NONCODEX_HOME/config.toml")"
for profile in sonnet devin-swe2 kimi-k3; do
  spawn_ok "noncodex-$profile" "$WRK" "$WORKTREE" "$profile" "$NONCODEX_HOME"
done
[[ "$(sha256_file "$NONCODEX_HOME/config.toml")" == "$NONCODEX_SHA" ]] || fail 'non-Codex profile changed Codex config'
[[ ! -e "$NONCODEX_HOME/config.toml.wrk.lock" ]] || fail 'non-Codex profile created Codex lock file'
echo 'PASS claude-devin-kimi-leave-codex-config-alone'

[[ ! -s "$WRK_AGENT_STUB_LOG" ]] || fail 'an agent binary stub was invoked instead of the herdr fixture'
echo 'PASS stubbed-agent-binaries-only'
