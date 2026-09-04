#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROMPT="$TMP/brief.md"
CONFIG="$TMP/hosts.toml"
LOAD="$TMP/loadavg"
printf '%s\n' 'spillover fixture brief' >"$PROMPT"
printf '%s\n' '0.20 0.10 0.10 1/1 1' >"$LOAD"
printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
  '[hub]' 'hub_url = "https://example.invalid"' 'hub_token_env = "/tmp/example-token.env"' 'hub_cf_env = "/tmp/example-cf.env"' '' \
  '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
  "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' '' \
  '[hosts.mac-work]' 'ssh = "mac-work"' 'herdr_session = "worker"' 'workspace = "workers"' \
  "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' >"$CONFIG"

run_wrk() {
  local binary="$1"; shift
  env HERDR_BIN="$ROOT/tests/fixtures/spillover-herdr" \
    SCOPEFUEL_BIN="$ROOT/tests/fixtures/scopefuel" ARBITER_BIN="$TMP/no-arbiter" \
    WRK_NO_SLEEP=1 WRK_HOSTS_CONFIG="$CONFIG" WRK_PROC_LOADAVG="$LOAD" WRK_TEST_NCPU=4 \
    WRK_TEST_THROTTLED=0 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_SPILLOVER_LOG="$TMP/spillover.log" PANEWIRE_BIN="$ROOT/tests/fixtures/spillover-panewire" \
    WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" WRK_SCP_BIN="$ROOT/tests/fixtures/spillover-scp" \
    WRK_SSH_LOG="$TMP/ssh.log" WRK_SCP_LOG="$TMP/scp.log" WRK_WAKE_LOG="$TMP/wake.log" \
    WRK_PLACE_LOG="$TMP/place.log" WRK_SPILLOVER_CANDIDATES_LOG="$TMP/candidates.log" \
    "$binary" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -l fixture --t T1 "$@"
}

set_first_cwd_map() {
  local map="$1" tmp
  tmp="$(mktemp "$TMP/hosts.XXXXXX")"
  awk -v map="$map" '
    !replaced && /^cwd_map =/ { print "cwd_map = " map; replaced = 1; next }
    { print }
  ' "$CONFIG" >"$tmp"
  mv "$tmp" "$CONFIG"
}

# Below threshold stays local after the hub is unavailable.
: >"$TMP/ssh.log"; : >"$TMP/scp.log"; : >"$TMP/wake.log"
low_out="$(WRK_PLACE_SCENARIO=unavailable WRK_TEST_ACTIVE=0 run_wrk "$ROOT/bin/wrk" -w local 2>&1)"
grep -q '^OK pane=w:p1 host=local ' <<<"$low_out"
grep -q 'source=local-fallback' "$TMP/spillover.log"
[[ ! -s "$TMP/ssh.log" ]]

hosts_out="$(env HERDR_BIN="$ROOT/tests/fixtures/spillover-herdr" WRK_TEST_ACTIVE=0 \
  WRK_HOSTS_CONFIG="$CONFIG" WRK_PROC_LOADAVG="$LOAD" WRK_TEST_NCPU=4 \
  WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" WRK_SSH_LOG="$TMP/ssh.log" \
  "$ROOT/bin/wrk" hosts)"
grep -q '^desktop[[:space:]]available' <<<"$hosts_out"

# Hub is authoritative: high local pressure remains local when hub says so.
printf '%s\n' '9.00 0.10 0.10 1/1 1' >"$LOAD"
hub_local_out="$(WRK_PLACE_SCENARIO=local WRK_TEST_ACTIVE=4 run_wrk "$ROOT/bin/wrk" -w local 2>&1)"
grep -q '^OK pane=w:p1 host=local ' <<<"$hub_local_out"
grep -q 'source=hub' "$TMP/spillover.log"

# Hub failure plus high pressure spills to the first measured remote host.
: >"$TMP/ssh.log"
remote_out="$(WRK_PLACE_SCENARIO=unavailable WRK_TEST_ACTIVE=4 run_wrk "$ROOT/bin/wrk" 2>&1)"
grep -q '^OK pane=desktop:p7 host=desktop ' <<<"$remote_out"
grep -q -- 'HERDR_SESSION=worker' "$TMP/ssh.log"
grep -q -- '/remote/agent-skills' "$TMP/ssh.log"
grep -q -- ' -w workers' "$TMP/ssh.log"

# An unreachable candidate is skipped and the next configured candidate is used.
: >"$TMP/ssh.log"
backup_out="$(WRK_PLACE_SCENARIO=unavailable WRK_SSH_SCENARIO=desktop-down WRK_TEST_ACTIVE=4 run_wrk "$ROOT/bin/wrk" 2>&1)"
grep -q '^OK pane=mac-work:p7 host=mac-work ' <<<"$backup_out"
grep -q 'desktop.*uptime; herdr agent list' "$TMP/ssh.log"
grep -q 'mac-work.*uptime; herdr agent list' "$TMP/ssh.log"

# A post-probe spawn failure also advances to the next candidate.
: >"$TMP/ssh.log"
spawn_failover_out="$(WRK_PLACE_SCENARIO=advance WRK_SSH_CALL_COUNT_FILE="$TMP/calls" WRK_SSH_FAIL_CALLS=3 run_wrk "$ROOT/bin/wrk" 2>&1)"
grep -q '^OK pane=mac-work:p7 host=mac-work ' <<<"$spawn_failover_out"
[[ "$(grep '^OK ' <<<"$spawn_failover_out" | grep -o 'host=' | wc -l)" -eq 1 ]]
backup_probe_count="$(grep -c 'mac-work.*uptime; herdr agent list' "$TMP/ssh.log")"
[[ "$backup_probe_count" -ge 1 ]]
grep -qx 'desktop' "$TMP/candidates.log"
grep -qx 'mac-work' "$TMP/candidates.log"
grep -q -- '--hub-url https://example.invalid --hub-token-env /tmp/example-token.env' "$TMP/place.log"

# The verbatim hub fixture filters the three not_accepting candidates while
# preserving the eligible machine order.  If both remote spawns fail, only the
# local fallback is emitted, with exactly one host field.
: >"$TMP/ssh.log"; : >"$TMP/calls"
verbatim_out="$(WRK_PLACE_SCENARIO=verbatim WRK_SSH_CALL_COUNT_FILE="$TMP/calls" WRK_SSH_FAIL_CALLS=3,6 run_wrk "$ROOT/bin/wrk" -w local 2>&1)"
grep -qx 'desktop' "$TMP/candidates.log"
grep -qx 'mac-work' "$TMP/candidates.log"
[[ "$(grep '^OK ' <<<"$verbatim_out" | grep -o 'host=' | wc -l)" -eq 1 ]]
grep -q '^OK pane=w:p1 host=local ' <<<"$verbatim_out"

# A hub-selected remote host without a cwd mapping fails closed; no local pane.
set_first_cwd_map '{"/not-the-current-cwd"="/remote/missing"}'
set +e
unmapped_out="$(WRK_PLACE_SCENARIO=advance WRK_TEST_ACTIVE=0 run_wrk "$ROOT/bin/wrk" -w local 2>&1)"
unmapped_rc=$?
set -e
[[ "$unmapped_rc" -ne 0 ]]
grep -q 'has no cwd_map entry' <<<"$unmapped_out"
grep -q 'host=local' <<<"$unmapped_out" && { echo 'unmapped spill-over unexpectedly used local' >&2; exit 1; }

# Restore the mapping and prove --host local overrides hub placement.
set_first_cwd_map "{\"$ROOT\"=\"/remote/agent-skills\"}"
: >"$TMP/ssh.log"
forced_out="$(WRK_PLACE_SCENARIO=advance WRK_TEST_ACTIVE=4 run_wrk "$ROOT/bin/wrk" -w local --host local 2>&1)"
grep -q '^OK pane=w:p1 host=local ' <<<"$forced_out"
[[ ! -s "$TMP/ssh.log" ]]

# Mutation checks: each altered boundary must make its AC assertion red.
# M1: remove the candidate list after the first remote spawn fails.
MUT_MAP="$TMP/wrk-no-cwd-map"
cp "$ROOT/bin/wrk" "$MUT_MAP"
sed -i.bak "s/if ! remote_cwd=\"\$(spillover_cwd_map \"\$host\" \"\$cwd\")\"; then/if false; then/" "$MUT_MAP"
set_first_cwd_map '{"/not-the-current-cwd"="/remote/missing"}'
if WRK_PLACE_SCENARIO=advance WRK_TEST_ACTIVE=0 run_wrk "$MUT_MAP" -w local 2>&1 | grep -q 'has no cwd_map entry'; then
  echo 'cwd-map mutant survived' >&2; exit 1
fi
set_first_cwd_map "{\"$ROOT\"=\"/remote/agent-skills\"}"

MUT_CANDIDATES="$TMP/wrk-no-candidates"; cp "$ROOT/bin/wrk" "$MUT_CANDIDATES"
sed -i.bak '/then candidates+=/c\  if [[ "$requested" == auto ]]; then true; fi' "$MUT_CANDIDATES"
if WRK_PLACE_SCENARIO=advance WRK_SSH_SCENARIO=desktop-spawn-fails run_wrk "$MUT_CANDIDATES" -w local 2>&1 | grep -q 'host=mac-work'; then echo 'candidate mutant survived' >&2; exit 1; fi

# M2: without the substring filter, the first verbatim candidate leaks through.
MUT_ACCEPTING="$TMP/wrk-no-not-accepting"; cp "$ROOT/bin/wrk" "$MUT_ACCEPTING"
sed -i.bak 's/or "not_accepting" in str(candidate_reason)//' "$MUT_ACCEPTING"
: >"$TMP/candidates.log"
WRK_PLACE_SCENARIO=verbatim run_wrk "$MUT_ACCEPTING" -w local >/dev/null 2>&1 || true
if ! grep -qx 'rpi' "$TMP/candidates.log"; then echo 'not_accepting mutant survived' >&2; exit 1; fi

# M4: deleting local emission after candidate exhaustion prevents the AC4 OK line.
MUT_FALLBACK="$TMP/wrk-no-local-fallback"; cp "$ROOT/bin/wrk" "$MUT_FALLBACK"
sed -i.bak '0,/spillover_emit_host local "\$out"/{//b}; /spillover_emit_host local "\$out"/s//return "\$last_rc"/' "$MUT_FALLBACK"
: >"$TMP/calls"
set +e
fallback_mutant_out="$(WRK_PLACE_SCENARIO=verbatim WRK_SSH_CALL_COUNT_FILE="$TMP/calls" WRK_SSH_FAIL_CALLS=3,6 run_wrk "$MUT_FALLBACK" -w local 2>&1)"
fallback_mutant_rc=$?
set -e
[[ "$fallback_mutant_rc" -ne 0 ]]
if grep -q '^OK pane=w:p1 host=local ' <<<"$fallback_mutant_out"; then echo 'local-fallback mutant survived' >&2; exit 1; fi

echo 'PASS wrk-spillover mutants-red=4/4'
