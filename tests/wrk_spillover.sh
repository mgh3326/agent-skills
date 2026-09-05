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

# A readable arbiter database is the normal routing precondition. Individual
# cases below replace this with an absent or lookup-failing arbiter explicitly.
XDG_DATA_HOME="$TMP/xdg" "$ROOT/bin/arbiter" claim --job spillover-seed --agent-label seed --lane seed --t T1 >/dev/null

run_wrk() {
  local binary="$1"; shift
  env HERDR_BIN="$ROOT/tests/fixtures/spillover-herdr" \
    SCOPEFUEL_BIN="$ROOT/tests/fixtures/scopefuel" ARBITER_BIN="${WRK_TEST_ARBITER_BIN:-$ROOT/bin/arbiter}" XDG_DATA_HOME="$TMP/xdg" \
    WRK_NO_SLEEP=1 WRK_HOSTS_CONFIG="$CONFIG" WRK_PROC_LOADAVG="$LOAD" WRK_TEST_NCPU=4 \
    WRK_TEST_THROTTLED=0 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_SPILLOVER_LOG="$TMP/spillover.log" PANEWIRE_BIN="$ROOT/tests/fixtures/spillover-panewire" \
    WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" WRK_SCP_BIN="$ROOT/tests/fixtures/spillover-scp" \
    WRK_SSH_LOG="$TMP/ssh.log" WRK_SCP_LOG="$TMP/scp.log" WRK_WAKE_LOG="$TMP/wake.log" \
    WRK_PLACE_LOG="$TMP/place.log" WRK_SPILLOVER_CANDIDATES_LOG="$TMP/candidates.log" \
    "$binary" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -l fixture --t T1 \
    --job "${WRK_TEST_JOB:-spillover-$RANDOM-$RANDOM}" "$@"
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

# P5: an unreadable or absent arbiter may use the ordinary local path, but is
# never enough evidence to call the hub or route remotely.
: >"$TMP/ssh.log"; : >"$TMP/place.log"; : >"$TMP/herdr.log"
XDG_DATA_HOME="$TMP/xdg" "$ROOT/bin/arbiter" claim --job spillover-lookup-fail --agent-label owner --lane owner --t T1 >/dev/null
set +e
lookup_fail_out="$(REAL_ARBITER="$ROOT/bin/arbiter" WRK_TEST_ARBITER_BIN="$ROOT/tests/fixtures/arbiter-proxy" WRK_ARBITER_PROXY_MODE=job-get-fails WRK_TEST_JOB=spillover-lookup-fail WRK_PLACE_SCENARIO=advance run_wrk "$ROOT/bin/wrk" -w local 2>&1)"
lookup_fail_rc=$?
set -e
[[ "$lookup_fail_rc" -eq 75 ]] || { echo "ASSERT P5 lookup failure expected exit 75, got $lookup_fail_rc" >&2; exit 1; }
[[ ! -s "$TMP/ssh.log" ]] || { echo 'ASSERT P5 lookup failure routed remotely' >&2; exit 1; }
[[ ! -s "$TMP/place.log" ]] || { echo 'ASSERT P5 lookup failure called hub' >&2; exit 1; }
[[ ! -s "$TMP/herdr.log" ]] || { echo 'ASSERT P5 lookup failure reached Herdr' >&2; exit 1; }

: >"$TMP/ssh.log"; : >"$TMP/place.log"; : >"$TMP/herdr.log"
absent_out="$(WRK_TEST_ARBITER_BIN="$TMP/no-arbiter" WRK_TEST_JOB=spillover-absent WRK_PLACE_SCENARIO=advance run_wrk "$ROOT/bin/wrk" -w local 2>&1)"
grep -q '^OK pane=w:p1 host=local ' <<<"$absent_out"
[[ ! -s "$TMP/ssh.log" ]] || { echo 'ASSERT P5 absent arbiter routed remotely' >&2; exit 1; }
[[ ! -s "$TMP/place.log" ]] || { echo 'ASSERT P5 absent arbiter called hub' >&2; exit 1; }

# A remote duplicate refusal is terminal: it must not probe a backup candidate
# or turn into a local spawn. Exercise both exact-once exits against two hub
# candidates in the contract-shaped advance fixture.
for duplicate_rc in 74 75; do
  : >"$TMP/ssh.log"; : >"$TMP/calls"; : >"$TMP/herdr.log"
  set +e
  duplicate_out="$(WRK_PLACE_SCENARIO=advance WRK_SSH_CALL_COUNT_FILE="$TMP/calls" WRK_SSH_FAIL_CALLS=3 WRK_SSH_FAIL_CODE="$duplicate_rc" run_wrk "$ROOT/bin/wrk" -w local 2>&1)"
  duplicate_actual_rc=$?
  set -e
  [[ "$duplicate_actual_rc" -eq "$duplicate_rc" ]] || { echo "ASSERT P5 remote duplicate expected exit $duplicate_rc, got $duplicate_actual_rc" >&2; exit 1; }
  backup_probe_count="$(grep -c 'mac-work.*uptime; herdr agent list' "$TMP/ssh.log" || true)"
  [[ "$backup_probe_count" -eq 0 ]] || { echo "ASSERT P5 remote duplicate must not advance; backup_probe_count=$backup_probe_count" >&2; exit 1; }
  [[ ! -s "$TMP/herdr.log" ]] || { echo 'ASSERT P5 remote duplicate reached local fallback' >&2; exit 1; }
done

# Mutation checks: each altered boundary must make its AC assertion red.
# M5: restoring remote routing after an unreadable lookup must make the P5
# assertion red through a genuine remote fixture spawn, not a shell error.
MUT_LOOKUP="$TMP/wrk-lookup-routes-remote"; cp "$ROOT/bin/wrk" "$MUT_LOOKUP"
sed -i.bak '/A router must never use an unavailable placement-admission lookup/,+10 s/^    return "\$rc"$/    :/' "$MUT_LOOKUP"
: >"$TMP/ssh.log"; : >"$TMP/place.log"
XDG_DATA_HOME="$TMP/xdg" "$ROOT/bin/arbiter" claim --job spillover-mutant-lookup --agent-label owner --lane owner --t T1 >/dev/null
REAL_ARBITER="$ROOT/bin/arbiter" WRK_TEST_ARBITER_BIN="$ROOT/tests/fixtures/arbiter-proxy" WRK_ARBITER_PROXY_MODE=job-get-fails WRK_TEST_JOB=spillover-mutant-lookup WRK_PLACE_SCENARIO=advance run_wrk "$MUT_LOOKUP" -w local >/dev/null 2>&1 || true
if [[ ! -s "$TMP/ssh.log" || ! -s "$TMP/place.log" ]]; then echo 'lookup-routing mutant survived' >&2; exit 1; fi

# M6: treating 74 as retryable must probe the second candidate, so the exact
# backup_probe_count=0 assertion above becomes red.
MUT_DUPLICATE="$TMP/wrk-duplicate-retries"; cp "$ROOT/bin/wrk" "$MUT_DUPLICATE"
sed -i.bak 's/2|"\$WRK_EXIT_ACTIVE_JOB_DUPLICATE"|"\$WRK_EXIT_JOB_STATE_UNREADABLE")/2)/' "$MUT_DUPLICATE"
: >"$TMP/ssh.log"; : >"$TMP/calls"
WRK_PLACE_SCENARIO=advance WRK_SSH_CALL_COUNT_FILE="$TMP/calls" WRK_SSH_FAIL_CALLS=3 WRK_SSH_FAIL_CODE=74 run_wrk "$MUT_DUPLICATE" -w local >/dev/null 2>&1 || true
backup_probe_count="$(grep -c 'mac-work.*uptime; herdr agent list' "$TMP/ssh.log" || true)"
[[ "$backup_probe_count" -gt 0 ]] || { echo 'duplicate-propagation mutant survived' >&2; exit 1; }

echo 'PASS wrk-spillover mutants-red=6/6'
