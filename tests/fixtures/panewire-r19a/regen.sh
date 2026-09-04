#!/usr/bin/env bash
# Regenerate the R19a fixture through the production artifact writers.
set -euo pipefail

fixture_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$fixture_dir/../../.." && pwd)"
output="${1:?usage: regen.sh OUTPUT_DIRECTORY}"

mkdir -p "$output"
if [[ -n "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "output directory must be empty: $output" >&2
  exit 2
fi

# A fixed test clock makes this byte-for-byte, while still exercising bin/arbiter
# and its atomic serializer rather than a hand-written JSON substitute.
fixture_env=(
  ARBITER_INBOX_ROOT="$output/.work"
  XDG_DATA_HOME="$output/.work/xdg"
  ARBITER_TEST_NOW=2026-09-04T07:00:00+00:00
  HOSTNAME=fixture-host
)

env "${fixture_env[@]}" "$root/bin/arbiter" claim \
  --job captain-fixture --lane lane-a --agent-label captain-fixture --t T1 \
  --role captain --parent-lane parent-a >/dev/null
env "${fixture_env[@]}" "$root/bin/arbiter" event --job captain-fixture --kind job.spawned \
  --payload-json '{"owner_lane":"lane-a","label":"captain-fixture","pane_id":"w1:p1"}' >/dev/null
(
  cd "$fixture_dir"
  env "${fixture_env[@]}" "$root/bin/wrk" escalate captain-fixture --question 'need parent decision' >/dev/null
  env "${fixture_env[@]}" "$root/bin/wrk" joined captain-fixture \
    --pr https://example.invalid/pr/1 --head deadbeef --report report.md >/dev/null
)
mv "$output/.work/captain-fixture/events/"*.json "$output/"
rm -rf "$output/.work"
