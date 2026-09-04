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
  '[hosts.example-primary]' 'ssh = "example-primary"' 'herdr_session = "worker"' 'workspace = "workers"' \
  "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' '' \
  '[hosts.example-backup]' 'ssh = "example-backup"' 'herdr_session = "worker"' 'workspace = "workers"' \
  "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' >"$CONFIG"

run_wrk() {
  local binary="$1"; shift
  env HERDR_BIN="$ROOT/tests/fixtures/spillover-herdr" \
    SCOPEFUEL_BIN="$ROOT/tests/fixtures/scopefuel" ARBITER_BIN="$TMP/no-arbiter" \
    WRK_NO_SLEEP=1 WRK_HOSTS_CONFIG="$CONFIG" WRK_PROC_LOADAVG="$LOAD" WRK_TEST_NCPU=4 \
    WRK_SPILLOVER_LOG="$TMP/spillover.log" PANEWIRE_BIN="$ROOT/tests/fixtures/spillover-panewire" \
    WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" WRK_SCP_BIN="$ROOT/tests/fixtures/spillover-scp" \
    WRK_SSH_LOG="$TMP/ssh.log" WRK_SCP_LOG="$TMP/scp.log" WRK_WAKE_LOG="$TMP/wake.log" \
    "$binary" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -l fixture --t T1 "$@"
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
grep -q '^example-primary[[:space:]]available' <<<"$hosts_out"

# Hub is authoritative: high local pressure remains local when hub says so.
printf '%s\n' '9.00 0.10 0.10 1/1 1' >"$LOAD"
hub_local_out="$(WRK_PLACE_SCENARIO=local WRK_TEST_ACTIVE=4 run_wrk "$ROOT/bin/wrk" -w local 2>&1)"
grep -q '^OK pane=w:p1 host=local ' <<<"$hub_local_out"
grep -q 'source=hub' "$TMP/spillover.log"

# Hub failure plus high pressure spills to the first measured remote host.
: >"$TMP/ssh.log"
remote_out="$(WRK_PLACE_SCENARIO=unavailable WRK_TEST_ACTIVE=4 run_wrk "$ROOT/bin/wrk" 2>&1)"
grep -q '^OK pane=example-primary:p7 host=example-primary ' <<<"$remote_out"
grep -q -- 'HERDR_SESSION=worker' "$TMP/ssh.log"
grep -q -- '/remote/agent-skills' "$TMP/ssh.log"
grep -q -- ' -w workers' "$TMP/ssh.log"

# An unreachable candidate is skipped and the next configured candidate is used.
: >"$TMP/ssh.log"
backup_out="$(WRK_PLACE_SCENARIO=unavailable WRK_SSH_SCENARIO=primary-down WRK_TEST_ACTIVE=4 run_wrk "$ROOT/bin/wrk" 2>&1)"
grep -q '^OK pane=example-backup:p7 host=example-backup ' <<<"$backup_out"
grep -q 'example-primary.*uptime; herdr agent list' "$TMP/ssh.log"
grep -q 'example-backup.*uptime; herdr agent list' "$TMP/ssh.log"

# A hub-selected remote host without a cwd mapping fails closed; no local pane.
sed -i '0,/cwd_map =/s|cwd_map =.*|cwd_map = {"/not-the-current-cwd"="/remote/missing"}|' "$CONFIG"
set +e
unmapped_out="$(WRK_PLACE_SCENARIO=primary WRK_TEST_ACTIVE=0 run_wrk "$ROOT/bin/wrk" -w local 2>&1)"
unmapped_rc=$?
set -e
[[ "$unmapped_rc" -ne 0 ]]
grep -q 'has no cwd_map entry' <<<"$unmapped_out"
! grep -q 'host=local' <<<"$unmapped_out"

# Restore the mapping and prove --host local overrides hub placement.
sed -i "0,/cwd_map =/s|cwd_map =.*|cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}|" "$CONFIG"
: >"$TMP/ssh.log"
forced_out="$(WRK_PLACE_SCENARIO=primary WRK_TEST_ACTIVE=4 run_wrk "$ROOT/bin/wrk" -w local --host local 2>&1)"
grep -q '^OK pane=w:p1 host=local ' <<<"$forced_out"
[[ ! -s "$TMP/ssh.log" ]]

# Mutation checks: removing either boundary must make the corresponding AC red.
MUT_PRESSURE="$TMP/wrk-no-pressure"
cp "$ROOT/bin/wrk" "$MUT_PRESSURE"
sed -i 's/if spillover_local_is_pressured; then/if false; then/' "$MUT_PRESSURE"
if WRK_PLACE_SCENARIO=unavailable WRK_TEST_ACTIVE=4 run_wrk "$MUT_PRESSURE" 2>&1 | grep -q 'host=example-primary'; then
  echo 'pressure mutant survived' >&2; exit 1
fi
MUT_MAP="$TMP/wrk-no-cwd-map"
cp "$ROOT/bin/wrk" "$MUT_MAP"
sed -i 's/if ! remote_cwd="$(spillover_cwd_map "\$host" "\$cwd")"; then/if false; then/' "$MUT_MAP"
sed -i '0,/cwd_map =/s|cwd_map =.*|cwd_map = {"/not-the-current-cwd"="/remote/missing"}|' "$CONFIG"
if WRK_PLACE_SCENARIO=primary WRK_TEST_ACTIVE=0 run_wrk "$MUT_MAP" -w local 2>&1 | grep -q 'has no cwd_map entry'; then
  echo 'cwd-map mutant survived' >&2; exit 1
fi

echo 'PASS wrk-spillover mutants-red=2/2'
