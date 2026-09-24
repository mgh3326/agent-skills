#!/usr/bin/env bash
# #626 AC2: every Claude pane wrk spawns runs with prompt suggestions off.
#
# A prompt suggestion is Claude Code's grayed-out prediction of the next user
# prompt, prefilled in the composer. One of them — phrased as an operator
# confirmation — was submitted in a tester pane and flipped its verdict to PASS
# (hk:doc task/2026-09-24/phantom-suggestion-submitted). The documented off
# switch (code.claude.com/docs/en/env-vars):
#
#   CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION — "Set to `false` to turn off prompt
#   suggestions, the grayed-out predictions that appear in your prompt input.
#   Takes precedence over the `promptSuggestionEnabled` setting"
#
# wrk carries it in the pane env (herdr `tab create --env`), so these cases read
# the fixture herdr log: the env is on every Claude profile's tab, on no other
# kind's, the `agent start` argv is unchanged, and `--purpose director` (a
# resident session — the operator's call) is left alone. The remote case runs
# the ssh-forwarded `wrk spawn --host local` for real against the same fixture.
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

SETTING='--env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false'

fail() { echo "FAIL: $*" >&2; exit 1; }

# spawn_log WRK MODEL [ARGS...]: run one fixture spawn with the given wrk and
# print the herdr invocation log. A failed spawn is an error, never a verdict.
spawn_log() {
  local wrk="$1" model="$2"; shift 2
  : >"$TMP/herdr.log"
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
    "$wrk" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture --t T1 "$@" >/dev/null 2>>"$TMP/wrk.stderr" ||
    { echo "ERROR: spawn -m $model $* exited non-zero: $(tail -n 3 "$TMP/wrk.stderr")" >&2; return 99; }
  cat "$TMP/herdr.log"
}

# Assertions return 1 (RED) on a contract violation so a mutant can be told
# apart from a broken fixture (99).
tab_has_setting() {
  local label="$1" log="$2" tab
  tab="$(grep '^tab create ' <<<"$log")" || { echo "ERROR: $label: no tab create" >&2; return 99; }
  [[ " $tab " == *" $SETTING "* ]] || { echo "RED: $label: tab create lacks '$SETTING': $tab" >&2; return 1; }
}
tab_lacks_setting() {
  local label="$1" log="$2" tab
  tab="$(grep '^tab create ' <<<"$log")" || { echo "ERROR: $label: no tab create" >&2; return 99; }
  [[ "$tab" != *PROMPT_SUGGESTION* ]] || { echo "RED: $label: tab create carries the setting: $tab" >&2; return 1; }
}

claude_profiles_on() {
  local wrk="$1" model log
  # Every PROFILE_KIND=claude spelling in resolve_profile, workers and consults.
  for model in opus sonnet sonnet-med haiku cc-qwen38 cc-glm cc-dsflash cc-dspro cc-glm53; do
    log="$(spawn_log "$wrk" "$model")" || return
    tab_has_setting "$model" "$log" || return
  done
  # fable is consult_only: an operator-requested consult.
  log="$(spawn_log "$wrk" fable --operator-request hk:doc/decision/2026-09-21/astra-allowed-purposes-approved \
    --requested-by operator)" || return
  tab_has_setting "fable (operator-requested consult)" "$log" || return
  # builder lane (builder-opus and its legacy alias).
  for model in builder-opus captain-opus; do
    log="$(spawn_log "$wrk" "$model" --role builder --lane "b-$model" --parent director-x)" || return
    tab_has_setting "$model builder" "$log" || return
  done
  # consult-advisor's spawn shape: a kept Claude session.
  log="$(spawn_log "$wrk" opus --keep)" || return
  tab_has_setting "opus --keep (consult)" "$log" || return
  # Purposes other than director are still workers.
  log="$(spawn_log "$wrk" opus --purpose architect)" || return
  tab_has_setting "opus --purpose architect" "$log"
}

director_left_alone() {
  local wrk="$1" log
  log="$(spawn_log "$wrk" opus --purpose director)" || return
  tab_lacks_setting "opus --purpose director" "$log"
}

WRK="$ROOT/bin/wrk"

claude_profiles_on "$WRK"
echo "PASS claude-profiles tab-env=CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false (workers, cc-*, builder, consult --keep)"

director_left_alone "$WRK"
echo "PASS resident-optout --purpose director tab-env=unset"

# The env rides next to a profile's own env instead of replacing it.
log="$(spawn_log "$WRK" cc-dsflash)"
tab="$(grep '^tab create ' <<<"$log")"
for needle in ANTHROPIC_BASE_URL= ANTHROPIC_AUTH_TOKEN= CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 "$SETTING"; do
  [[ "$tab" == *"$needle"* ]] || fail "cc-dsflash tab create lost '$needle': $tab"
done
echo "PASS cc-profile-env preserved alongside setting"

# Non-Claude kinds are untouched.
for model in codex-sol codex-terra kiro-sol kimi-k3 kimi-k3-low devin-swe2 grok-hi oc-glm; do
  log="$(spawn_log "$WRK" "$model")"
  tab_lacks_setting "$model" "$log" || exit 1
done
echo "PASS non-claude kinds tab-env=unset"

# The Claude argv is exactly what it was: the setting is env, not a flag.
log="$(spawn_log "$WRK" opus)"
start="$(grep '^agent start ' <<<"$log")"
[[ "$start" == 'agent start fixture --kind claude --pane w:p1 --timeout 30000 -- --model opus --dangerously-skip-permissions --effort high' ]] ||
  fail "opus agent start argv changed: $start"
log="$(spawn_log "$WRK" builder-opus --role builder --lane b-argv --parent director-x)"
start="$(grep '^agent start ' <<<"$log")"
[[ "$start" == 'agent start fixture --kind claude --pane w:p1 --timeout 30000 -- --model opus --dangerously-skip-permissions --effort high' ]] ||
  fail "builder-opus agent start argv changed: $start"
echo "PASS claude argv unchanged (setting is pane env only)"

# Remote ssh spawn: the local side forwards `wrk spawn --host local` over ssh;
# this ssh stub runs that command here, against the same fixture herdr, so the
# remote-side resolve_profile is the one under test.
REMOTE_CWD="$TMP/remote-worktree"
REMOTE_TMP="$TMP/remote-tmp"
REMOTE_BIN="$TMP/remote-bin"
mkdir -p "$REMOTE_CWD" "$REMOTE_TMP" "$REMOTE_BIN"
ln -s "$WRK" "$REMOTE_BIN/wrk"
cat >"$TMP/ssh-stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
remote="${*: -1}"
# Placement's host probe: answer it here, never from a real herdr.
if [[ "$remote" == *'uptime; herdr agent list'* ]]; then
  printf '%s\n' ' 10:00 up 1 day,  load average: 0.10, 0.10, 0.10' '{"result":{"agents":[]}}'
  exit 0
fi
if [[ "$remote" == *mktemp* ]]; then
  mktemp "$REMOTE_TMP/wrk-spillover.XXXXXX"
  exit 0
fi
PATH="$REMOTE_BIN:$PATH" bash -c "$remote"
STUB
cat >"$TMP/scp-stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cp -- "$1" "${2#*:}"
STUB
chmod +x "$TMP/ssh-stub" "$TMP/scp-stub"
printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
  '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
  "cwd_map = {\"$ROOT\"=\"$REMOTE_CWD\"}" 'capacity = 3' >"$TMP/hosts.toml"
# Placement runs only behind a readable arbiter (otherwise the router falls
# back to a local spawn), so this case uses the real one on isolated state.
XDG_DATA_HOME="$TMP/xdg" "$ROOT/bin/arbiter" claim --job remote-seed --agent-label seed --lane seed --t T1 >/dev/null
remote_log() {
  local model="$1"; shift
  : >"$TMP/herdr.log"
  env HERDR_BIN="$HERDR" ARBITER_BIN="$ROOT/bin/arbiter" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_HOSTS_CONFIG="$TMP/hosts.toml" \
    WRK_SSH_BIN="$TMP/ssh-stub" WRK_SCP_BIN="$TMP/scp-stub" \
    REMOTE_TMP="$REMOTE_TMP" REMOTE_BIN="$REMOTE_BIN" \
    WRK_SPILLOVER_LOG="$TMP/spillover.log" \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
    "$WRK" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w workers -l fixture --t T1 --job "remote-$model" --host desktop "$@" >/dev/null 2>>"$TMP/wrk.stderr" ||
    { echo "ERROR: remote spawn -m $model exited non-zero: $(tail -n 3 "$TMP/wrk.stderr")" >&2; return 99; }
  cat "$TMP/herdr.log"
}
log="$(remote_log opus)"
grep -q "^tab create --workspace workers --cwd $REMOTE_CWD " <<<"$log" ||
  fail "remote spawn did not reach the remote-side tab create: $log"
tab_has_setting "remote opus" "$log" || exit 1
log="$(remote_log codex-sol)"
tab_lacks_setting "remote codex-sol" "$log" || exit 1
echo "PASS remote-ssh spawn remote-side tab-env=CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false (codex unset)"

# Mutants: each must go RED through an assertion (rc 1), not an error.
expect_red() {
  local label="$1"; shift
  local rc=0
  "$@" 2>/dev/null || rc=$?
  [[ "$rc" -eq 1 ]] || fail "mutant $label: expected assertion RED (rc 1), got rc $rc"
}
MUT="$TMP/mutants"
mkdir -p "$MUT"
line='PROFILE_ENV+=(--env "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false")'
grep -qF -- "$line" "$WRK" || fail "setting line not found in bin/wrk"
# Neutralised, not deleted: an empty `if` body would be a syntax error (rc 2).
python3 - "$WRK" "$MUT/wrk-no-setting" "$line" <<'PY'
import sys
src, dst, line = sys.argv[1:]
text = open(src, encoding="utf-8").read()
assert text.count(line) == 1, "setting line must occur exactly once"
open(dst, "w", encoding="utf-8").write(text.replace(line, ":", 1))
PY
# shellcheck disable=SC2016 # the pattern is bin/wrk source text, not an expansion
sed 's/"${PURPOSE:-}" != director/"${PURPOSE:-}" != no-such-purpose/' "$WRK" >"$MUT/wrk-no-optout"
cmp -s "$WRK" "$MUT/wrk-no-optout" && fail "opt-out mutant did not change bin/wrk"
chmod +x "$MUT"/wrk-*
expect_red setting-removed claude_profiles_on "$MUT/wrk-no-setting"
expect_red optout-removed director_left_alone "$MUT/wrk-no-optout"
echo "PASS mutants assertion-red=2/2 (setting removed, director opt-out removed)"
