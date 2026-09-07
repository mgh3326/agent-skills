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

# The captain-role artifacts are durable pre-rename regression evidence. Current
# arbiter normalizes direct `--role captain` input to builder, so preserve the
# old envelope bytes as a fixture input while generating the canonical builder
# claim through the production artifact writer below.
for legacy in "$fixture_dir"/0000[1-4]-*.json; do
  cp "$legacy" "$output/"
done

# A fixed test clock makes the new builder artifact byte-for-byte stable while
# still exercising bin/arbiter and its atomic serializer rather than a
# hand-written JSON substitute.
fixture_env=(
  ARBITER_INBOX_ROOT="$output/.work"
  XDG_DATA_HOME="$output/.work/xdg"
  ARBITER_TEST_NOW=2026-09-04T07:00:00+00:00
  HOSTNAME=fixture-host
)

env "${fixture_env[@]}" "$root/bin/arbiter" claim \
  --job builder-fixture --lane builder-lane --agent-label builder-fixture --t T1 \
  --role builder --parent-lane parent-lane >/dev/null
mv "$output/.work/builder-fixture/events/00001-job.claim.json" \
  "$output/00005-builder-job.claim.json"
rm -rf "$output/.work"
