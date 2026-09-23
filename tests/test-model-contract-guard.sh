#!/usr/bin/env bash
# ROB-591 / AC3+AC6: bidirectional drift guard, agent-skills side.
#
# Exercises the REAL bin/wrk resolve_profile() model-ID/effort resolution and
# asserts it against a checked-in snapshot of the scopefuel catalog contract
# (src/scopefuel/recommend.py GRADE_TABLE, ROB-591 catalog-refresh rows). This
# is a plain snapshot, not a live cross-repo read — scopefuel has its own
# mirror-image guard (tests/test_wrk_contract_guard.py) asserting the real
# GRADE_TABLE against a snapshot of these same bin/wrk rows.
#
# Update discipline: whenever the Sol/Luna/Opus/Grok catalog IDs in
# scopefuel's GRADE_TABLE change, update the CONTRACT_* values below in the
# same commit/PR — this guard's whole purpose is to fail loudly when the two
# repos drift apart, so it must never be "fixed" by relaxing an assertion
# without a matching scopefuel-side change.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
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

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- checked-in scopefuel catalog contract (counterpart: scopefuel repo,
#     src/scopefuel/recommend.py GRADE_TABLE, ROB-591 rows) ------------------
CONTRACT_SOL_MODEL_ID="gpt-6-sol"
CONTRACT_LUNA_MODEL_ID="gpt-6-luna"
CONTRACT_GROK_MODEL_ID="grok-4.7"
# The launcher passes the Claude Code CLI *alias* "opus", not the literal
# model ID — scopefuel's own GRADE_TABLE row is the thing that maps that
# alias to the real ID, recorded here only so a reader can find both halves.
CONTRACT_OPUS_ALIAS="opus"
CONTRACT_OPUS_MODEL_ID="claude-opus-5-5"
# fable is absent from GRADE_TABLE (scopefuel CONSULT_ONLY_PROFILES) but its
# explicit launch ID is still part of the contract: bin/wrk passes it literally.
CONTRACT_FABLE_MODEL_ID="claude-fable-5-1"

spawn_argv() {
  local model="$1"; shift
  # No intermediate array: an empty "extra=("$@")" array expanded with
  # "${extra[@]}" throws "unbound variable" under `set -u` on Bash 3.2
  # (macOS's default /bin/bash) even though the array itself was declared —
  # bash 3.2 treats a zero-element array as unset for that expansion. "$@"
  # alone has no such quirk in any bash version, empty or not.
  : >"$TMP/herdr.log"
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
    "$WRK" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture --t T1 "$@" >/dev/null
  cat "$TMP/herdr.log"
}

assert_argv_has() {
  local model="$1" needle="$2"; shift 2
  local argv
  argv="$(spawn_argv "$model" "$@")"
  grep -qF -- "$needle" <<<"$argv" ||
    fail "profile '$model': expected argv to contain '$needle'; got: $argv"
}

# --- Sol: exactly the four real bin/wrk rows the ROB-591 brief named --------
for sol_profile in codex codex-sol codex-max; do
  assert_argv_has "$sol_profile" "-m $CONTRACT_SOL_MODEL_ID"
done
for builder_sol_profile in builder-sol captain-sol; do
  assert_argv_has "$builder_sol_profile" "-m $CONTRACT_SOL_MODEL_ID" \
    --role builder --lane guard-lane --parent guard-parent-lane
done
echo "PASS Sol profiles (codex, codex-sol, codex-max, builder-sol, captain-sol) run $CONTRACT_SOL_MODEL_ID"

# --- Luna: exactly the three real bin/wrk rows the ROB-591 brief named -----
for luna_profile in codex-luna codex-luna-hi codex-luna-max; do
  assert_argv_has "$luna_profile" "-m $CONTRACT_LUNA_MODEL_ID"
done
echo "PASS Luna profiles (codex-luna, codex-luna-hi, codex-luna-max) run $CONTRACT_LUNA_MODEL_ID"

# --- Grok: generic fallback argv ------------------------------------------
assert_argv_has grok "-m $CONTRACT_GROK_MODEL_ID"
echo "PASS grok generic fallback runs $CONTRACT_GROK_MODEL_ID"

# --- Rollback spellings must still resolve to the pre-refresh IDs ----------
assert_argv_has codex-sol56 "-m gpt-5.6-sol"
assert_argv_has codex-luna56 "-m gpt-5.6-luna"
echo "PASS rollback spellings (codex-sol56, codex-luna56) still run the pre-refresh IDs"

# --- Opus: launcher emits the CLI alias, not the literal model ID ---------
opus_argv="$(spawn_argv "$CONTRACT_OPUS_ALIAS")"
grep -qF -- "--model $CONTRACT_OPUS_ALIAS" <<<"$opus_argv" ||
  fail "profile 'opus': expected argv to contain '--model $CONTRACT_OPUS_ALIAS'; got: $opus_argv"
grep -qF -- "--effort high" <<<"$opus_argv" ||
  fail "profile 'opus': expected default --effort high (ROB-591); got: $opus_argv"
echo "PASS opus alias argv unchanged (--model opus, default --effort high) — scopefuel side maps this to $CONTRACT_OPUS_MODEL_ID"

# --- Fable: explicit consult-only launch keeps the literal 5.1 model ID ------
assert_argv_has fable "--model $CONTRACT_FABLE_MODEL_ID "
echo "PASS fable explicit consult launch runs $CONTRACT_FABLE_MODEL_ID"

echo "PASS test-model-contract-guard: bin/wrk matches the checked-in scopefuel catalog contract"
