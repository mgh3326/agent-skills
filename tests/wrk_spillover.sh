#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016
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

(
# Contract C: a configured hub route does not open SSH/SCP and carries the
# exact hub request contract through the curl fixture.
HUB_CONFIG="$TMP/hub-hosts.toml"
OPERATOR_ENV="$TMP/operator.env"
CF_ENV="$TMP/cf-access.env"
printf '%s\n' 'PANEWIRE_OPERATOR_TOKEN=operator-test-token' >"$OPERATOR_ENV"
printf '%s\n' 'CF_ACCESS_CLIENT_ID=cf-client-id' 'CF_ACCESS_CLIENT_SECRET=cf-client-secret' >"$CF_ENV"
printf '%s\n' '[hub]' 'hub_url = "wss://hub.fixture.invalid"' 'hub_token_env = "/tmp/node-token.env"' "hub_cf_env = \"$CF_ENV\"" "operator_token_env = \"$OPERATOR_ENV\"" '' '[hosts.machine-a]' 'via = "hub"' 'ssh = "machine-a"' 'herdr_session = "worker"' 'workspace = "worker"' "cwd_map = {\"$ROOT\"=\"/remote/repo-a\"}" "cwd_keys = {\"$ROOT\"=\"repo-a\"}" 'capacity = 3' >"$HUB_CONFIG"
printf '%s\n' 'hub fixture brief body' >"$PROMPT"

run_hub() {
  local binary="$1" config="$2"; shift 2
  env HERDR_BIN="$ROOT/tests/fixtures/spillover-herdr" SCOPEFUEL_BIN="$ROOT/tests/fixtures/scopefuel" ARBITER_BIN="$ROOT/bin/arbiter" XDG_DATA_HOME="$TMP/xdg" WRK_NO_SLEEP=1 WRK_HOSTS_CONFIG="$config" WRK_PROC_LOADAVG="$LOAD" WRK_TEST_NCPU=4 WRK_TEST_THROTTLED=0 WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SPILLOVER_LOG="$TMP/spillover.log" WRK_CURL_BIN="$ROOT/tests/fixtures/spillover-hub-curl" WRK_HUB_CURL_LOG="$TMP/hub.log" PANEWIRE_BIN="$ROOT/tests/fixtures/spillover-panewire" WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" WRK_SCP_BIN="$ROOT/tests/fixtures/spillover-scp" WRK_SSH_LOG="$TMP/ssh.log" WRK_SCP_LOG="$TMP/scp.log" WRK_WAKE_LOG="$TMP/wake.log" WRK_HUB_SCENARIO="${WRK_HUB_SCENARIO:-hub200}" "$binary" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w worker -l fixture --t T1 --job "hub-$RANDOM-$RANDOM" --host machine-a "$@"
}

# Unset via remains SSH, and an explicit ssh value takes the same path; neither
# reaches the HTTP fixture.
HUB_SSH_UNSET="$TMP/hub-ssh-unset.toml"
sed '/^via =/d' "$HUB_CONFIG" >"$HUB_SSH_UNSET"
: >"$TMP/hub.log"; : >"$TMP/ssh.log"; : >"$TMP/scp.log"
ssh_unset_out="$(run_hub "$ROOT/bin/wrk" "$HUB_SSH_UNSET" 2>&1)"
grep -q '^OK pane=.* host=machine-a ' <<<"$ssh_unset_out"
[[ -s "$TMP/ssh.log" && -s "$TMP/scp.log" && ! -s "$TMP/hub.log" ]]

HUB_SSH_EXPLICIT="$TMP/hub-ssh-explicit.toml"
sed 's/^via = "hub"/via = "ssh"/' "$HUB_CONFIG" >"$HUB_SSH_EXPLICIT"
: >"$TMP/hub.log"; : >"$TMP/ssh.log"; : >"$TMP/scp.log"
ssh_explicit_out="$(run_hub "$ROOT/bin/wrk" "$HUB_SSH_EXPLICIT" 2>&1)"
grep -q '^OK pane=.* host=machine-a ' <<<"$ssh_explicit_out"
[[ -s "$TMP/ssh.log" && -s "$TMP/scp.log" && ! -s "$TMP/hub.log" ]]

# A 200 response provides pane and job in the normal remote OK-line shape.
: >"$TMP/hub.log"; : >"$TMP/ssh.log"; : >"$TMP/scp.log"; : >"$TMP/spillover.log"
hub_200_out="$(WRK_HUB_SCENARIO=hub200 run_hub "$ROOT/bin/wrk" "$HUB_CONFIG" 2>&1)"
grep -Eq '^OK pane=pane-a host=machine-a .* job=job-a$' <<<"$hub_200_out"
grep -q '^OK pane=.* host=machine-a ' <<<"$ssh_explicit_out"
[[ ! -s "$TMP/ssh.log" && ! -s "$TMP/scp.log" ]]
python3 - "$TMP/hub.log" "$PROMPT" <<'PY'
import json, re, sys
log_path, prompt_path = sys.argv[1:]
records = [json.loads(line) for line in open(log_path, encoding="utf-8") if line.strip()]
assert len(records) == 1, records
record = records[0]
assert record["method"] == "POST"
assert record["url"] == "https://hub.fixture.invalid/v1/spawn"
headers = dict(header.split(": ", 1) for header in record["headers"])
assert headers["Authorization"] == "Bearer operator-test-token"
assert headers["CF-Access-Client-Id"] == "cf-client-id"
assert headers["CF-Access-Client-Secret"] == "cf-client-secret"
request = json.loads(record["body"])
assert re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", request["request_id"])
assert request["machine"] == "machine-a"
assert request["cwd_key"] == "repo-a"
assert request["brief"]["inline"] == open(prompt_path, encoding="utf-8").read()
assert request["wait_seconds"] == 120
assert {"-m", "-w", "-l", "--t", "--job"}.issubset(request["args"])
assert not {"-c", "-p", "--host", "--job-dup-ok"}.intersection(request["args"])
PY
grep -q 'host=machine-a.*via=hub' "$TMP/spillover.log"
if rg -F 'operator-test-token|cf-client-id|cf-client-secret|hub fixture brief body' "$TMP/spillover.log"; then
  echo 'hub routing log leaked a fixture secret or brief' >&2
  exit 1
fi

# A 504 pending reply polls once under WRK_NO_SLEEP and emits the same result.
: >"$TMP/hub.log"
hub_pending_out="$(WRK_HUB_SCENARIO=pending run_hub "$ROOT/bin/wrk" "$HUB_CONFIG" 2>&1)"
grep -Eq '^OK pane=pane-a host=machine-a .* job=job-a$' <<<"$hub_pending_out"
python3 - "$TMP/hub.log" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert [record["method"] for record in records] == ["POST", "GET"], records
request_id = json.loads(records[0]["body"])["request_id"]
assert records[1]["url"].endswith("/v1/spawn/" + request_id)
PY

# Lost and each documented HTTP error remain terminal, readable, and secret-free.
: >"$TMP/hub.log"; : >"$TMP/herdr.log"
set +e
hub_lost_out="$(WRK_HUB_SCENARIO=lost run_hub "$ROOT/bin/wrk" "$HUB_CONFIG" 2>&1)"
hub_lost_rc=$?
set -e
[[ "$hub_lost_rc" -ne 0 ]]
[[ "$(grep -c '^wrk:' <<<"$hub_lost_out")" -eq 1 ]]
grep -q 'hub spawn lost' <<<"$hub_lost_out"
[[ ! -s "$TMP/herdr.log" && "$hub_lost_out" != *operator-test-token* ]]

for scenario in hub503 hub401 hub409 hub400; do
  : >"$TMP/hub.log"
  set +e
  hub_error_out="$(WRK_HUB_SCENARIO="$scenario" run_hub "$ROOT/bin/wrk" "$HUB_CONFIG" 2>&1)"
  hub_error_rc=$?
  set -e
  [[ "$hub_error_rc" -ne 0 ]]
  [[ "$hub_error_out" != *operator-test-token* && "$hub_error_out" != *cf-client-secret* ]]
  case "$scenario" in
    hub503) grep -q '503' <<<"$hub_error_out" ;;
    hub401) grep -q '401' <<<"$hub_error_out" ;;
    hub409) grep -q '409' <<<"$hub_error_out" ;;
    hub400) grep -q '400' <<<"$hub_error_out" ;;
  esac
done

# Missing hub-only configuration is fail-closed before either hub or local work.
HUB_NO_CWD="$TMP/hub-no-cwd.toml"
sed 's|cwd_keys = .*|cwd_keys = {"/not-current"="repo-a"}|' "$HUB_CONFIG" >"$HUB_NO_CWD"
for config_case in "$HUB_NO_CWD" "$TMP/hub-no-operator.toml"; do
  if [[ "$config_case" == *no-operator* ]]; then sed '/^operator_token_env =/d' "$HUB_CONFIG" >"$config_case"; fi
  : >"$TMP/hub.log"; : >"$TMP/herdr.log"
  set +e
  hub_config_out="$(run_hub "$ROOT/bin/wrk" "$config_case" 2>&1)"
  hub_config_rc=$?
  set -e
  [[ "$hub_config_rc" -ne 0 && ! -s "$TMP/hub.log" && ! -s "$TMP/herdr.log" ]]
  grep -q 'use --host local or configure hosts.toml' <<<"$hub_config_out"
done

# Mutation checks: each altered boundary makes its matching assertion red while
# the source file remains byte-for-byte unchanged after the temporary copies.
HUB_ORIGINAL="$TMP/wrk-hub-original"
cp "$ROOT/bin/wrk" "$HUB_ORIGINAL"

MUT_ARGS="$TMP/wrk-hub-args"
cp "$ROOT/bin/wrk" "$MUT_ARGS"
sed -i.bak 's/echo \"wrk: --job-dup-ok is not permitted for a hub spawn\" >&2; return 2/SPILL_HUB_ARGS+=(--job-dup-ok)/' "$MUT_ARGS"
: >"$TMP/hub.log"
M1_out="$(WRK_HUB_SCENARIO=hub200 run_hub "$MUT_ARGS" "$HUB_CONFIG" --job-dup-ok 2>&1 || true)"
python3 - "$TMP/hub.log" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert records and "--job-dup-ok" in json.loads(records[-1]["body"])["args"]
PY
[[ "$M1_out" == *'OK pane=pane-a'* ]] || { echo 'hub args allowlist mutant survived' >&2; exit 1; }
cmp -s "$ROOT/bin/wrk" "$HUB_ORIGINAL"

MUT_AUTH="$TMP/wrk-hub-auth"
cp "$ROOT/bin/wrk" "$MUT_AUTH"
sed -i.bak 's/--header \"Authorization: Bearer \$operator_token\" //' "$MUT_AUTH"
: >"$TMP/hub.log"
WRK_HUB_SCENARIO=hub200 run_hub "$MUT_AUTH" "$HUB_CONFIG" >/dev/null 2>&1
python3 - "$TMP/hub.log" <<'PY'
import json, sys
headers = [header for record in (json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()) for header in record["headers"]]
assert not any(header.startswith("Authorization:") for header in headers)
PY
cmp -s "$ROOT/bin/wrk" "$HUB_ORIGINAL"

MUT_CWD="$TMP/wrk-hub-cwd"
cp "$ROOT/bin/wrk" "$MUT_CWD"
sed -i.bak '/has no cwd_keys entry/{n;s/return 2/spawn_cmd \"$@\"; return $?/;}' "$MUT_CWD"
: >"$TMP/hub.log"; : >"$TMP/herdr.log"
WRK_HUB_SCENARIO=hub200 run_hub "$MUT_CWD" "$HUB_NO_CWD" >/dev/null 2>&1 || true
[[ ! -s "$TMP/hub.log" && -s "$TMP/herdr.log" ]] || { echo 'hub cwd fail-closed mutant survived' >&2; exit 1; }
cmp -s "$ROOT/bin/wrk" "$HUB_ORIGINAL"

MUT_PENDING="$TMP/wrk-hub-pending"
cp "$ROOT/bin/wrk" "$MUT_PENDING"
sed -i.bak 's|spillover_hub_poll \"$base\".*|spillover_hub_emit_ok \"$host\" \"pending-pane\" \"pending-job\" \"${SPILL_HUB_ARGS[@]}\"|' "$MUT_PENDING"
: >"$TMP/hub.log"
M4_out="$(WRK_HUB_SCENARIO=pending run_hub "$MUT_PENDING" "$HUB_CONFIG" 2>&1)"
python3 - "$TMP/hub.log" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert [record["method"] for record in records] == ["POST"]
PY
[[ "$M4_out" == *'OK pane=pending-pane'* ]] || { echo 'hub pending-poll mutant survived' >&2; exit 1; }
cmp -s "$ROOT/bin/wrk" "$HUB_ORIGINAL"

echo 'PASS wrk-spillover hub-mutants-red=4/4'
)
printf '%s\n' 'spillover fixture brief' >"$PROMPT"

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

# A readable active duplicate remains terminal before either local telemetry or
# hub/SSH work, for both automatic and explicitly local routing.
for route in auto local; do
  active_job="spillover-active-$route"
  XDG_DATA_HOME="$TMP/xdg" "$ROOT/bin/arbiter" claim --job "$active_job" --agent-label owner --lane owner --t T1 >/dev/null
  : >"$TMP/ssh.log"; : >"$TMP/place.log"; : >"$TMP/herdr.log"
  set +e
  if [[ "$route" == auto ]]; then
    active_out="$(WRK_TEST_JOB="$active_job" WRK_PLACE_SCENARIO=advance run_wrk "$ROOT/bin/wrk" -w local 2>&1)"
  else
    active_out="$(WRK_TEST_JOB="$active_job" WRK_PLACE_SCENARIO=advance run_wrk "$ROOT/bin/wrk" -w local --host local 2>&1)"
  fi
  active_rc=$?
  set -e
  [[ "$active_rc" -eq 74 ]] || { echo "ASSERT P5 active duplicate expected exit 74, got $active_rc" >&2; exit 1; }
  [[ ! -s "$TMP/ssh.log" && ! -s "$TMP/place.log" && ! -s "$TMP/herdr.log" ]] || { echo 'ASSERT P5 active duplicate made placement calls' >&2; exit 1; }
done

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
