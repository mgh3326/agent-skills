#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/acp-process-group"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PID_DIR="$TMP/pids"
OUT="$TMP/out"
mkdir -p "$PID_DIR"

set +e
PATH="$FIXTURE:$PATH" PID_DIR="$PID_DIR" "$ROOT/bin/acp-runner" \
  --job acp-process-group-fixture \
  --cwd "$TMP" \
  --prompt-file "$FIXTURE/prompt.md" \
  --agent junie \
  --timeout 1 \
  --out "$OUT" >"$TMP/runner.out" 2>&1
rc=$?
set -e

[[ "$rc" -eq 4 ]]
grep -q 'TIMEOUT after 1s — cancelling' "$OUT/progress.log"

for _ in $(seq 1 30); do
  if [[ -s "$PID_DIR/parent" && -s "$PID_DIR/child" && -s "$PID_DIR/grandchild" ]]; then
    break
  fi
  sleep 0.1
done

parent_pid="$(<"$PID_DIR/parent")"
child_pid="$(<"$PID_DIR/child")"
grandchild_pid="$(<"$PID_DIR/grandchild")"
echo "fixture pids: parent=$parent_pid child=$child_pid grandchild=$grandchild_pid"
echo 'process list after timeout (must be empty):'
ps -p "$parent_pid,$child_pid,$grandchild_pid" -o pid=,ppid=,pgid=,stat=,command= || true

for _ in $(seq 1 30); do
  alive=0
  for pid in "$parent_pid" "$child_pid" "$grandchild_pid"; do
    if kill -0 "$pid" 2>/dev/null; then
      alive=1
    fi
  done
  [[ "$alive" -eq 0 ]] && break
  sleep 0.1
done

for pid in "$parent_pid" "$child_pid" "$grandchild_pid"; do
  if ps -p "$pid" -o pid=,ppid=,pgid=,stat=,command=; then
    echo "leaked process: $pid" >&2
    exit 1
  fi
done

remaining="$(pgrep -f "$FIXTURE/fake_agent.py" || true)"
echo "pgrep fake_agent.py after timeout: ${remaining:-0}"
[[ -z "$remaining" ]]
echo 'PASS test-acp-runner-process-group'
