#!/usr/bin/env bash
# Verify the three wrk artifacts subcommands route through the single shared
# command/help definitions. All command state and files stay in a temp root.
set -euo pipefail
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wrk-artifacts-routing.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/xdg-data" XDG_CONFIG_HOME="$TMP/xdg-config"
export XDG_STATE_HOME="$TMP/xdg-state" XDG_CACHE_HOME="$TMP/xdg-cache"
export ARBITER_INBOX_ROOT="$TMP/work/herdr-inbox/jobs"
export WRK_ARTIFACT_POLICY="$TMP/policy.json"
export WRK_HOSTS_CONFIG="$TMP/hosts.toml"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" \
  "$XDG_CACHE_HOME" "$ARBITER_INBOX_ROOT/route-job"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$(grep -Ec '^artifacts_cmd\(\)' "$WRK")" -eq 1 ]] || fail "artifacts_cmd definition count"
[[ "$(grep -Ec '^artifacts_help\(\)' "$WRK")" -eq 1 ]] || fail "artifacts_help definition count"
[[ "$(grep -Fxc '  artifacts) shift; artifacts_cmd "$@" ;;' "$WRK")" -eq 1 ]] || fail "artifacts dispatch count"

python3 - "$WRK_ARTIFACT_POLICY" "$ARBITER_INBOX_ROOT" <<'PY'
import json, os, sys
policy, jobs = sys.argv[1:]
with open(policy, "w", encoding="utf-8") as out:
    json.dump({
        "schema": "fleet.artifact-policy.v1",
        "roots": {"jobs": {"path": "herdr-inbox/jobs", "kind": "per-job"}},
        "rows": [{"class": "evidence", "root": "jobs", "glob": "*.txt",
                  "job": "route-job"}],
    }, out)
with open(os.path.join(jobs, "route-job", "evidence.txt"), "w", encoding="utf-8") as out:
    out.write("fixture evidence\n")
with open(os.path.join(jobs, "route-job", "final.apk"), "wb") as out:
    out.write(b"fixture final build\n")
PY

classify_out="$($WRK artifacts classify --job route-job --json)" || fail "classify route failed"
python3 - "$classify_out" <<'PY' || fail "classify subcommand was not reached"
import json, sys
data = json.loads(sys.argv[1])
assert data["jobs"]["route-job"]["classes"]["evidence"]["paths"][0]["path"].endswith("evidence.txt")
PY

"$WRK" artifacts mark-final route-job final.apk --by fixture >/dev/null || fail "mark-final route failed"
[[ -f "$ARBITER_INBOX_ROOT/route-job/final-build.json" ]] || fail "mark-final did not write marker"
grep -q '"kind":"job.final_build_marked"' "$ARBITER_INBOX_ROOT/route-job/events"/*.json || fail "mark-final did not write event"

cat >"$WRK_HOSTS_CONFIG" <<EOF
[artifacts]
drive_folder = "$TMP/drive"
fpbulk = "$TMP/fpbulk"
batch_bytes = 1000000
batch_files = 50
poll_seconds = 30
confirm_timeout_seconds = 300
confirm_gap_seconds = 120
stale_minutes = 60000
drivefs_log_dir = "$TMP/drivefs-logs"
app_check = "true"
state_dir = "$TMP/state"
scratch_dir = "$TMP/scratch"
exclude = [".env", "*.env", "*token*", "*secret*"]
EOF
mkdir -p "$TMP/source" "$TMP/drive" "$TMP/drivefs-logs"
"$WRK" artifacts move "$TMP/source" --dest "$TMP/drive/fixture/dataset" --help \
  >"$TMP/move-help" || fail "move route failed"
grep -q '^Usage: wrk artifacts move ' "$TMP/move-help" || fail "move subcommand was not reached"

echo "PASS test-wrk-artifacts-routing"
