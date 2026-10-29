#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
workflow = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
assert workflow.count('"git", "diff", "--name-only", "--no-renames"') == 1, "PR docs-only diff must include rename source paths"
assert 'git diff --name-only --no-renames "${{ github.event.before }}"' in workflow, "push docs-only diff must include rename source paths"
manifest = root / "tests/ci-suites.txt"
manifest_sha256 = hashlib.sha256(manifest.read_bytes()).hexdigest()
assert manifest_sha256 == "8837fafc6b22de9cce11692842fb286e738904a2b32760d921976ea2582d68b8", "suite list changed; review all shard coverage deliberately"
rows = []
for raw in manifest.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    shard, command = line.split("|", 1)
    rows.append((shard, command))

commands = [command for _shard, command in rows]
counts = Counter(commands)
assert all(count == 1 for count in counts.values()), "every CI suite command must appear exactly once"
assert len(commands) == 51, f"today's CI suite list changed unexpectedly: {len(commands)} commands"
assert Counter(shard for shard, _command in rows) == Counter({
    "wrk": 1,
    "suites-a": 13,
    "suites-b": 27,
    "python": 10,
}), "suite coverage changed: review the shard assignment and update this contract deliberately"
assert rows[0] == ("wrk", "bash tests/test-wrk.sh"), "test-wrk.sh must stay alone in its shard"
for _shard, command in rows:
    assert command.startswith(("bash ", "python3 ")), f"unsupported command: {command}"
    if command.startswith("bash "):
        path = command.split()[1]
        assert (root / path).is_file(), f"suite command target is missing: {path}"
    elif " -m unittest discover " in command:
        pattern = command.split(" -p ", 1)[1].split()[0].strip("'\"")
        directory = command.split(" -s ", 1)[1].split()[0]
        assert list((root / directory).glob(pattern)), f"unittest discovery target is missing: {pattern}"
    else:
        target = next((part for part in command.split() if part.startswith("tests/")), None)
        assert target and (root / target).is_file(), f"suite command target is missing: {command}"

smoke = (root / ".github/macos-smoke.txt").read_text(encoding="utf-8").splitlines()
section = ""
smoke_commands = []
paths = []
for raw in smoke:
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("[") and line.endswith("]"):
        section = line
        continue
    if section == "[smoke]":
        smoke_commands.append(line)
    elif section == "[darwin-sensitive]":
        path, command, reason = line.split("|", 2)
        assert reason.strip(), f"missing Darwin sensitivity reason: {path}"
        paths.append(path)
        assert command == "-" or command in smoke_commands, f"smoke coverage is not run by macos-smoke: {command}"

assert len(smoke_commands) == len(set(smoke_commands)), "duplicate macOS smoke command"
assert all(command in commands for command in smoke_commands), "every smoke command must exist in today's CI suite list"
assert len(paths) == len(set(paths)), "duplicate Darwin-sensitive path entry"
for pattern in paths:
    matches = list(root.glob(pattern))
    assert matches and all(path.exists() for path in matches), f"Darwin-sensitive path/glob does not exist: {pattern}"

# director/gate_policy.json pins ci.yml (and other trust-bearing files) by
# sha256; a PR that edits a pinned file must re-hash it in the same commit.
# Duplicate keys anywhere would let a lenient reader see a stale value.
def no_duplicates(pairs):
    keys = [key for key, _value in pairs]
    dupes = sorted({key for key in keys if keys.count(key) > 1})
    assert not dupes, f"gate_policy.json has duplicate keys: {dupes}"
    return dict(pairs)


policy = json.loads((root / "director/gate_policy.json").read_text(encoding="utf-8"), object_pairs_hook=no_duplicates)
pins = policy["local_sources"]
assert ".github/workflows/ci.yml" in pins, "gate_policy local_sources must pin .github/workflows/ci.yml"
for rel, pinned in pins.items():
    target = (root / rel).resolve()
    assert not Path(rel).is_absolute() and root.resolve() in target.parents, f"pin outside the repo: {rel}"
    assert target.is_file(), f"pinned file is missing: {rel}"
    actual = hashlib.sha256(target.read_bytes()).hexdigest()
    assert pinned == actual, f"stale gate_policy pin for {rel}: pinned {str(pinned)[:12]}… actual {actual[:12]}…"

print(f"PASS ci-suites commands={len(commands)} shards=4 smoke={len(smoke_commands)} darwin_paths={len(paths)} pins={len(pins)}")
PY
