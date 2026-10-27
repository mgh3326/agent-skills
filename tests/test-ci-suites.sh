#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
from collections import Counter
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
workflow = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
assert workflow.count('"git", "diff", "--name-only", "--no-renames"') == 1, "PR docs-only diff must include rename source paths"
assert 'git diff --name-only --no-renames "${{ github.event.before }}"' in workflow, "push docs-only diff must include rename source paths"
manifest = root / "tests/ci-suites.txt"
manifest_sha256 = hashlib.sha256(manifest.read_bytes()).hexdigest()
assert manifest_sha256 == "128ae977e471a3913f32d154db93cc5cd9421e406d905e7744cd7dd20e9cb83b", "suite list changed; review all shard coverage deliberately"
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
assert len(commands) == 44, f"today's CI suite list changed unexpectedly: {len(commands)} commands"
assert Counter(shard for shard, _command in rows) == Counter({
    "wrk": 1,
    "suites-a": 10,
    "suites-b": 25,
    "python": 8,
}), "suite coverage changed: review the shard assignment and update this contract deliberately"
assert rows[0] == ("wrk", "bash tests/test-wrk.sh"), "test-wrk.sh must stay alone in its shard"
for _shard, command in rows:
    assert command.startswith(("bash ", "python3 ")), f"unsupported command: {command}"
    if command.startswith("bash "):
        path = command.split()[1]
        assert (root / path).is_file(), f"suite command target is missing: {path}"
    elif " -s tests " in command:
        pattern = command.split(" -p ", 1)[1].split()[0].strip("'\"")
        assert list((root / "tests").glob(pattern)), f"unittest discovery target is missing: {pattern}"
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

print(f"PASS ci-suites commands={len(commands)} shards=4 smoke={len(smoke_commands)} darwin_paths={len(paths)}")
PY
