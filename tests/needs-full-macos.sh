#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git -C "$tmp" init -q
git -C "$tmp" config user.name fixture
git -C "$tmp" config user.email fixture@example.invalid
mkdir -p "$tmp/.github" "$tmp/bin" "$tmp/tests"
cp "$root/.github/macos-smoke.txt" "$tmp/.github/macos-smoke.txt"
touch "$tmp/bin/wrk" "$tmp/tests/test-wrk-heavy-class.sh"
git -C "$tmp" add .
git -C "$tmp" commit -qm base
base="$(git -C "$tmp" rev-parse HEAD)"

printf 'change\n' >> "$tmp/tests/test-wrk-heavy-class.sh"
git -C "$tmp" add .
git -C "$tmp" commit -qm covered
covered="$(git -C "$tmp" rev-parse HEAD)"
result="$(cd "$tmp" && "$root/scripts/needs-full-macos" "$base" "$covered")"
[[ "$result" == no ]] || { echo "FAIL smoke-covered path requested full macOS: $result" >&2; exit 1; }

printf 'change\n' >> "$tmp/bin/wrk"
git -C "$tmp" add .
git -C "$tmp" commit -qm uncovered
head="$(git -C "$tmp" rev-parse HEAD)"
result="$(cd "$tmp" && "$root/scripts/needs-full-macos" "$covered" "$head")"
[[ "$result" == $'yes\nbin/wrk' ]] || { echo "FAIL uncovered path not reported: $result" >&2; exit 1; }

git -C "$tmp" mv bin/wrk bin/wrk2
git -C "$tmp" commit -qm rename-sensitive-path
renamed="$(git -C "$tmp" rev-parse HEAD)"
result="$(cd "$tmp" && "$root/scripts/needs-full-macos" "$head" "$renamed")"
[[ "$result" == $'yes\nbin/wrk' ]] || { echo "FAIL renamed sensitive path not reported: $result" >&2; exit 1; }

echo 'PASS needs-full-macos smoke-covered=no uncovered=yes renamed=yes'
