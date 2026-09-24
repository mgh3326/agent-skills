#!/usr/bin/env bash
# #593 (was ROB-591): cross-repo drift guard, agent-skills side.
#
# ROB-591 guarded a duplicated table: bin/wrk carried its own Sol/Luna/Grok
# model IDs and this file asserted them against a checked-in snapshot of
# scopefuel's GRADE_TABLE. #593 removes the duplication — resolve_profile() now
# takes model ids and default efforts from `scopefuel policy launch` — so the
# guard's subject moves with it:
#
#   1. the migration is value-preserving: every ID ROB-591 pinned still comes
#      out of the launcher (the PASS lines below, unchanged);
#   2. those values genuinely come from the canon, not from a leftover literal
#      — served a model id that appears nowhere in bin/wrk, the argv follows it;
#   3. the catalog-exempt spellings (rollback pins) do NOT follow the canon;
#   4. every path that fails to reach the canon marks the spawn brief
#      `catalog=stale`, including the tolerant ones (scopefuel absent, too old
#      to have the subcommand, request failed).
#
# scopefuel has the mirror-image guard (tests/test_wrk_contract_guard.py).
# Update both in one PR — this guard exists to fail loudly on drift, so it must
# never be "fixed" by relaxing an assertion without a matching scopefuel change.
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
export WRK_LAUNCH_LOG="$TMP/launch.log"

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

# --- Fable: consult-only, and the launcher enforces it ----------------------
# Before #593 a bare `wrk -m fable` reached the launcher and only the quota gate
# stood between it and a spawn. The catalog now answers consult_only (rc 3) and
# the launcher refuses on that answer, so the bare form must not start anything.
# spawn_argv() ends in `cat`, so its status cannot carry wrk's — invoke wrk directly.
if env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$ROOT" -m fable -p "$PROMPT" -w w -l fixture --t T1 >/dev/null 2>&1; then
  fail "bare 'wrk -m fable' must be refused — the catalog answers consult_only"
fi
echo "PASS bare fable launch is refused (consult_only)"

# With the operator request it launches, on the literal 5.1 model ID.
assert_argv_has fable "--model $CONTRACT_FABLE_MODEL_ID " \
  --operator-request hk:doc/decision/2026-09-23/task593-dispatch-ac4-absorbed \
  --requested-by operator
echo "PASS operator-requested fable launch runs $CONTRACT_FABLE_MODEL_ID"

echo "PASS test-model-contract-guard: bin/wrk matches the checked-in scopefuel catalog contract"


# --- #593: the values come from the canon, not from a literal ---------------
# Serve a model id that exists nowhere in bin/wrk. If the launcher still emits
# the old literal, it never consulted the catalog.
canon_argv() {
  local model="$1" override="$2"; shift 2
  : >"$TMP/herdr.log"
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_LAUNCH_MODEL_OVERRIDE="$override" \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
    "$WRK" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture --t T1 "$@" >/dev/null
  cat "$TMP/herdr.log"
}

argv="$(canon_argv codex-sol gpt-7-sol-canary)"
grep -qF -- "-m gpt-7-sol-canary" <<<"$argv" ||
  fail "codex-sol did not follow the catalog's model id; got: $argv"
echo "PASS codex-sol argv follows the canonical model id (not a bin/wrk literal)"

argv="$(canon_argv grok grok-9.9-canary)"
grep -qF -- "-m grok-9.9-canary" <<<"$argv" ||
  fail "grok did not follow the catalog's model id; got: $argv"
echo "PASS grok argv follows the canonical model id"

argv="$(canon_argv kiro-opus canary-opus-99)"
grep -qF -- "--model canary-opus-99" <<<"$argv" ||
  fail "kiro-opus did not follow the catalog's model id; got: $argv"
echo "PASS kiro-opus argv follows the canonical model id"

# --- the exempt spellings must NOT follow the canon -------------------------
# A rollback pin that follows the server is a rollback lever that does nothing.
for pinned in codex-sol56 codex-luna56 grok46; do
  argv="$(canon_argv "$pinned" should-never-appear)"
  grep -qF -- "should-never-appear" <<<"$argv" &&
    fail "rollback spelling '$pinned' followed the catalog; it must stay pinned"
done
grep -qF -- "-m gpt-5.6-sol" <<<"$(canon_argv codex-sol56 should-never-appear)" ||
  fail "codex-sol56 lost its pinned model id"
echo "PASS rollback spellings (codex-sol56, codex-luna56, grok46) ignore the catalog"

# --- #527 overlap: codex-astra's default effort ----------------------------
# codex-astra is consult_only, so a full spawn is refused at the gate before an
# argv exists. What this side has to guarantee is that bin/wrk does not *pin* an
# effort for it — the canon's xhigh (asserted in scopefuel's own suite) only
# applies if the launcher leaves the rung to the catalog. The old literal
# DEFAULT_EFFORT=max must be gone.
grep -qE '^\s*codex-astra\) CATALOG_PROFILE=codex-astra ;;\s*$' "$WRK" ||
  fail "codex-astra must map to the catalog with no pinned effort (task #527)"
grep -qE 'codex-astra\).*DEFAULT_EFFORT=max' "$WRK" &&
  fail "codex-astra still pins DEFAULT_EFFORT=max; task #527 moves the default to xhigh via the catalog"
echo "PASS codex-astra takes its default effort from the catalog (no max pin)"

# --- every unreachable-canon path marks the brief catalog=stale -------------
brief_header() {
  local mode="$1" scopefuel_bin="$2" model="${3:-codex-sol}"
  rm -rf "$TMP/inbox"
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$scopefuel_bin" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_LAUNCH_MODE="$mode" \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
    "$WRK" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture --t T1 >/dev/null 2>&1 || true
  head -n 1 "$(find "$TMP/inbox" -name 'spawn-brief-*' -type f | head -n 1)" 2>/dev/null
}

# A negative assertion on a header that may not exist passes for the wrong
# reason: brief_header swallows the spawn status, so a regression that refused
# the healthy spawn outright would print PASS. Require a real header first.
assert_header_present() {
  local what="$1" header="$2"
  [[ "$header" == expect:* ]] ||
    fail "$what: expected a spawn brief header, got: ${header:-<none>}"
}

header="$(brief_header ok "$SCOPEFUEL")"
assert_header_present "healthy catalog" "$header"
grep -q 'catalog=stale' <<<"$header" &&
  fail "a healthy catalog must not mark the brief stale; got: $header"
echo "PASS a healthy catalog leaves the brief header unmarked"

for mode in stale broken unsupported no-provenance; do
  header="$(brief_header "$mode" "$SCOPEFUEL")"
  grep -q 'catalog=stale' <<<"$header" ||
    fail "WRK_LAUNCH_MODE=$mode did not mark the brief catalog=stale; got: $header"
done
echo "PASS stale / failed-request / missing-subcommand / missing-provenance all mark the brief catalog=stale"

# A deployment with no catalog route is not stale: production handoffkeep
# predates it, and branding every spawn during the rollout would make the marker
# meaningless before it ever mattered.
header="$(brief_header route-404 "$SCOPEFUEL")"
assert_header_present "route-404" "$header"
grep -q 'catalog=stale' <<<"$header" &&
  fail "a 404 catalog route must not mark the brief stale; got: $header"
echo "PASS a server without the catalog route does not mark the brief stale"

# A refusal from the canon stops the spawn here. Deferring to the quota gate let
# a permissive gate launch a profile the catalog had just declined.
refusal="$TMP/refusing-scopefuel"
cat >"$refusal" <<'REFUSE'
#!/bin/sh
if [ "$1" = policy ] && [ "$2" = launch ]; then
  echo "error: profile is consult_only; pass --operator-request" >&2
  exit 3
fi
exec "$SCOPEFUEL_FIXTURE" "$@"
REFUSE
chmod +x "$refusal"
rm -rf "$TMP/inbox"
if env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$refusal" SCOPEFUEL_FIXTURE="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$ROOT" -m codex-sol -p "$PROMPT" -w w -l fixture --t T1 >/dev/null 2>&1; then
  fail "a policy launch refusal (rc 3) must stop the spawn, not fall through to the gate"
fi
echo "PASS a catalog refusal (rc 3) stops the spawn"

# The refusal must carry scopefuel's own reason. rc 3 covers consult_only, a
# retired rung, an unknown profile and a stale-gated one; hard-coding the
# --operator-request remedy sent the operator after a flag that cannot fix most
# of them. Found as a coverage gap in the #593 verify round: reverting the
# passthrough left every test green.
reason_bin="$TMP/reason-scopefuel"
cat >"$reason_bin" <<'REASON'
#!/bin/sh
if [ "$1" = policy ] && [ "$2" = launch ]; then
  echo "error: profile 'codex-sol' rung 'max' is retired in the catalog" >&2
  exit 3
fi
exec "$SCOPEFUEL_FIXTURE" "$@"
REASON
chmod +x "$reason_bin"
refusal_out="$(env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$reason_bin" SCOPEFUEL_FIXTURE="$SCOPEFUEL" \
  WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn \
  WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  WRK_REFRESH_LOG="$TMP/refresh.log" WRK_REFRESH_PID_LOG="$TMP/refresh.pids" \
  WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$ROOT" -m codex-sol -p "$PROMPT" -w w -l fixture --t T1 2>&1 || true)"
grep -qF -- "rung 'max' is retired in the catalog" <<<"$refusal_out" ||
  fail "the refusal must report scopefuel's reason verbatim; got: $refusal_out"
grep -q -- "--operator-request if this launch is operator-approved" <<<"$refusal_out" &&
  fail "the refusal must not hard-code the --operator-request remedy; got: $refusal_out"
echo "PASS a catalog refusal reports scopefuel's own reason"

# The tolerant path that used to be silent: scopefuel absent entirely.
header="$(brief_header ok "$TMP/absent-scopefuel")"
grep -q 'catalog=stale' <<<"$header" ||
  fail "a missing scopefuel must still mark the brief catalog=stale; got: $header"
echo "PASS a missing scopefuel marks the brief catalog=stale (never a silent fallback)"

# --- the case table itself is part of the contract --------------------------
# Verified in #593 round 2: nothing failed if a new catalog-consuming spelling
# was added here without updating the two guard dictionaries. The cross-repo
# halves stay plain snapshots on purpose, but within this repo the real case
# table can be diffed against a checked-in list, so an added or removed spelling
# has to be acknowledged in the same commit.
WRK_CATALOG_SPELLINGS_SNAPSHOT="$(printf '%s\n' \
  builder-grok builder-luna builder-opus builder-sol captain-opus captain-sol \
  cc-glm cc-qwen38 codex codex-astra codex-luna codex-luna-hi codex-luna-max \
  codex-max codex-med codex-sol codex-terra codex-terra-max fable grok grok-hi \
  grok-med haiku kiro-cheap kiro-haiku kiro-opus kiro-opus-max kiro-opus-xhigh \
  kiro-sol kiro-sol-max kiro-sol-xhigh kiro-sonnet opus sonnet sonnet-med | sort)"

# Parse resolve_catalog_profile()'s case labels out of the real script.
WRK_CATALOG_SPELLINGS_ACTUAL="$(awk '
  /^resolve_catalog_profile\(\) \{/ { inside = 1; next }
  inside && /^\}/ { exit }
  inside && /CATALOG_PROFILE=/ {
    line = $0
    sub(/\).*/, "", line)
    gsub(/^[ \t]+/, "", line)
    n = split(line, parts, "|")
    for (i = 1; i <= n; i++) print parts[i]
  }
' "$WRK" | sort)"

if [[ "$WRK_CATALOG_SPELLINGS_SNAPSHOT" != "$WRK_CATALOG_SPELLINGS_ACTUAL" ]]; then
  echo "resolve_catalog_profile() drifted from the checked-in contract:" >&2
  diff <(printf '%s\n' "$WRK_CATALOG_SPELLINGS_SNAPSHOT") \
       <(printf '%s\n' "$WRK_CATALOG_SPELLINGS_ACTUAL") >&2 || true
  fail "update this snapshot AND scopefuel's WRK_CATALOG_SPELLINGS in the same PR"
fi
echo "PASS resolve_catalog_profile() matches the checked-in spelling contract ($(wc -l <<<"$WRK_CATALOG_SPELLINGS_ACTUAL") spellings)"

echo "PASS test-model-contract-guard: bin/wrk consumes the canonical catalog"
