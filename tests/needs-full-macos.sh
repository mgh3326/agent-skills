#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git -C "$tmp" init -q
git -C "$tmp" config user.name fixture
git -C "$tmp" config user.email fixture@example.invalid
mkdir -p "$tmp/.github" "$tmp/bin" "$tmp/tests" "$tmp/scripts"
# The script reads the manifest next to itself, so run a copy beside the fixture manifest.
cp "$root/scripts/needs-full-macos" "$tmp/scripts/needs-full-macos"
cat >"$tmp/.github/macos-smoke.txt" <<'MANIFEST'
[smoke]
bash tests/test-covered.sh

[darwin-sensitive]
bin/sensitive|-|Fixture path that needs the full macOS suite.
tests/test-covered.sh|bash tests/test-covered.sh|Fixture path covered by a smoke command.
MANIFEST
touch "$tmp/bin/sensitive" "$tmp/tests/test-covered.sh"
git -C "$tmp" add .
git -C "$tmp" commit -qm base
base="$(git -C "$tmp" rev-parse HEAD)"

printf 'change\n' >> "$tmp/tests/test-covered.sh"
git -C "$tmp" add .
git -C "$tmp" commit -qm covered
covered="$(git -C "$tmp" rev-parse HEAD)"
result="$(cd "$tmp" && "$tmp/scripts/needs-full-macos" "$base" "$covered")"
[[ "$result" == no ]] || { echo "FAIL smoke-covered path requested full macOS: $result" >&2; exit 1; }

printf 'change\n' >> "$tmp/bin/sensitive"
git -C "$tmp" add .
git -C "$tmp" commit -qm uncovered
head="$(git -C "$tmp" rev-parse HEAD)"
result="$(cd "$tmp" && "$tmp/scripts/needs-full-macos" "$covered" "$head")"
[[ "$result" == $'yes\nbin/sensitive' ]] || { echo "FAIL uncovered path not reported: $result" >&2; exit 1; }

git -C "$tmp" mv bin/sensitive bin/sensitive2
git -C "$tmp" commit -qm rename-sensitive-path
renamed="$(git -C "$tmp" rev-parse HEAD)"
result="$(cd "$tmp" && "$tmp/scripts/needs-full-macos" "$head" "$renamed")"
[[ "$result" == $'yes\nbin/sensitive' ]] || { echo "FAIL renamed sensitive path not reported: $result" >&2; exit 1; }

echo 'PASS needs-full-macos smoke-covered=no uncovered=yes renamed=yes'
