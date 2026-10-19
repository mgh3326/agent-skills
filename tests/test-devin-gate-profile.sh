#!/usr/bin/env bash
# hk 1604: each Devin spelling gates at its own scopefuel profile.
# Paid rungs (ds41, ds41-max, glm52, swe17) must never be judged as a SWE-2
# profile. Builder seats take the runtime profile from scopefuel grades.py
# _BUILDER_RUNGS. The hk 1380 fusion arm stays on its own names.
# Stub scopefuel and herdr only. The real-scopefuel smoke runs only when
# SCOPEFUEL_SMOKE_REPO is set, so CI does not need a scopefuel checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="$ROOT/bin/arbiter"
HANDOFFKEEP_BIN="$ROOT/tests/fixtures/handoffkeep"
PANEWIRE="$ROOT/tests/fixtures/panewire"
TMP="$(mktemp -d)"
JOB_SEQ=0
LAST_GATE=""
mkdir -p "$TMP/gate-cache"

cleanup() {
  local pidfile pid child
  if [[ -n "${TMP:-}" && -d "${TMP:-}" ]]; then
    while IFS= read -r pidfile; do
      [[ -s "$pidfile" ]] || continue
      read -r pid <"$pidfile" || continue
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      kill -STOP "$pid" 2>/dev/null || true
      while IFS= read -r child; do
        [[ "$child" =~ ^[0-9]+$ ]] || continue
        kill "$child" 2>/dev/null || true
      done < <(pgrep -P "$pid" 2>/dev/null || true)
      kill "$pid" 2>/dev/null || true
      kill -CONT "$pid" 2>/dev/null || true
    done < <(find "$TMP" -name 'completion-sentinel.pid' -print 2>/dev/null || true)
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/xdg"
export XDG_CACHE_HOME="$TMP/xdg-cache"
export XDG_CONFIG_HOME="$TMP/xdg-config"
export XDG_STATE_HOME="$TMP/xdg-state"
export XDG_RUNTIME_DIR="$TMP/xdg-runtime"
export ARBITER_INBOX_ROOT="$TMP/inbox"
export ARBITER_BIN="$TMP/absent-arbiter"
export WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml"
export PANEWIRE_BIN="$PANEWIRE"
export HANDOFFKEEP_BIN
export HK_STATE="$TMP/hk-state.json"
export HK_TASK_ID=1604000
unset CLAUDE_CONFIG_DIR || true
mkdir -p "$HOME" "$XDG_DATA_HOME/devin/cli" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" \
  "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$ARBITER_INBOX_ROOT"
chmod 700 "$XDG_RUNTIME_DIR"
python3 - "$XDG_DATA_HOME/devin/cli/trusted_workspaces.json" "$ROOT" <<'PY'
import json, sys
json.dump({"trusted_paths": [sys.argv[2]]}, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY

PROMPT="$TMP/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"
: >"$TMP/absent-arbiter"
chmod +x "$TMP/absent-arbiter"

"$HANDOFFKEEP_BIN" tasks add --id "$HK_TASK_ID" --title "gate-profile-suite" --lane fixture >/dev/null
python3 - "$HK_STATE" <<'PY'
import json, sys
path = sys.argv[1]
state = json.load(open(path, encoding="utf-8"))
for i in range(1604001, 1604200):
    state["tasks"][str(i)] = {
        "id": i, "lane": "", "title": "gate-profile pool", "kind": "implement",
        "state": "backlog", "priority": 0, "refs": {}, "claimed_by": "",
        "created_by": "fixture", "created_at": "2026-01-01T00:00:00+00:00",
        "updated_at": "2026-01-01T00:00:00+00:00", "events": []}
json.dump(state, open(path, "w", encoding="utf-8"))
PY
printf '%s\n' 1604000 >"$TMP/mint-seq"

mint_task() {
  local id
  id=$(( $(cat "$TMP/mint-seq") + 1 ))
  (( id <= 1604199 )) || fail "task pool exhausted at $id"
  printf '%s\n' "$id" >"$TMP/mint-seq"
  printf '%s\n' "$id"
}

spawn_one() {
  local wrk_bin="$1" scopefuel_bin="$2" model="$3"
  shift 3
  local task
  task="$(mint_task)"
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$scopefuel_bin" WRK_NO_SLEEP=1 \
    ARBITER_BIN="${TEST_ARBITER_BIN:-$TMP/absent-arbiter}" \
    WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO="${TEST_FIXTURE_SCENARIO:-devin-idle}" \
    WRK_FIXTURE_LOG="${TEST_HERDR_LOG:-$TMP/herdr.log}" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
    "$wrk_bin" spawn \
    -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture \
    --task "$task" "$@"
}

# Record the gate profile this wrk binary asks scopefuel for. The log's first
# line is the full gate argv and the last line is the bare profile.
measure_gate() {
  local wrk_bin="$1" model="$2" cache out rc count first gate
  # Per-key files, not an associative array: macos CI bash is 3.2.
  cache="$TMP/gate-cache/$(basename "$wrk_bin")--$model"
  if [[ -f "$cache" ]]; then
    LAST_GATE=$(cat "$cache")
    return 0
  fi
  JOB_SEQ=$((JOB_SEQ + 1))
  : >"$TMP/scopefuel.log"
  : >"$TMP/herdr.log"
  set +e
  if [[ "$model" == builder-* ]]; then
    out=$(TEST_FIXTURE_SCENARIO=devin-idle spawn_one "$wrk_bin" "$SCOPEFUEL" "$model" \
      --job "gp-$JOB_SEQ" --t T1 --role builder --lane "ln-$JOB_SEQ" --parent parent-lane 2>&1)
  else
    out=$(TEST_FIXTURE_SCENARIO=devin-idle spawn_one "$wrk_bin" "$SCOPEFUEL" "$model" \
      --job "gp-$JOB_SEQ" --t T1 2>&1)
  fi
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || fail "spawn $model rc=$rc: $out"
  count=$(grep -c . "$TMP/scopefuel.log" || true)
  first=$(head -n 1 "$TMP/scopefuel.log")
  gate=$(tail -n 1 "$TMP/scopefuel.log")
  [[ "$count" -eq 2 && "$first" == "gate -m $gate" && "$first" != *"--effort"* ]] ||
    fail "gate log for $model is not a bare -m call: $(cat "$TMP/scopefuel.log")"
  printf '%s\n' "$gate" >"$cache"
  LAST_GATE=$gate
}

# Non-SWE-2 spellings discovered from `wrk profiles` must not gate as
# devin-swe2, devin-swe2-medium, or devin-swe2-max. Returns 1 on that
# assertion (the mutant path). Any other problem exits via fail.
assert_invariant() {
  local wrk_bin="$1" profiles spelling gate required
  profiles=$("$wrk_bin" profiles)
  for required in devin-ds41 devin-ds41-max builder-ds41 builder-ds41-max devin-glm52 devin-swe17; do
    grep -qx "$required" <<<"$profiles" || fail "wrk profiles missing $required"
  done
  while IFS= read -r spelling; do
    [[ -n "$spelling" ]] || continue
    measure_gate "$wrk_bin" "$spelling"
    gate=$LAST_GATE
    case "$spelling" in
      devin-swe2|devin-swe2-medium|devin-swe2-max) continue ;;
    esac
    case "$gate" in
      devin-swe2|devin-swe2-medium|devin-swe2-max)
        echo "FAIL invariant: non-SWE-2 spelling $spelling gated as $gate" >&2
        return 1
        ;;
    esac
  done < <(printf '%s\n' "$profiles" | grep -E '^(devin-|builder-ds41)')
  return 0
}

# Pinned hk 1380 fusion arm. The expected text is this literal. The test
# does not read a git ref.
cat >"$TMP/fusion-expected.txt" <<'EOF'
    # hk 1380: the fusion spellings gate at their OWN gate_policy.json entries,
    # never at devin-swe2 — their family is the Claude family (anthropic), and
    # folding them into devin-swe2 would make a fusion tester look
    # cross-family against a claude builder and break the §2-4 separation.
    # The quota pool is still scopefuel's single `devin` pool — wrk owns no
    # pool mapping, the gate answer names the pool.
    devin-fusion-opus55|devin-fusion-sonnet55) GATE_PROFILE="$MODEL" ;;
EOF
python3 - "$WRK" "$TMP/fusion-expected.txt" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
expected = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
count = text.count(expected)
if count != 1:
    raise SystemExit("fusion arm literal count %s" % count)
PY
grep -q 'devin-swe2|builder-devin) GATE_PROFILE=devin-swe2' "$WRK" ||
  fail "devin-swe2 and builder-devin must still gate as devin-swe2"
echo "PASS fusion arm matches pinned hk 1380 literal"

# Plain case function: bash 3.2 has no associative arrays.
expected_gate() {
  case "$1" in
    devin-swe2|builder-devin) printf '%s\n' devin-swe2 ;;
    devin-swe2-medium|builder-devin-medium) printf '%s\n' devin-swe2-medium ;;
    devin-swe2-max|builder-devin-max) printf '%s\n' devin-swe2-max ;;
    devin-swe17) printf '%s\n' devin-swe17 ;;
    devin-glm52) printf '%s\n' devin-glm52 ;;
    devin-ds41|builder-ds41) printf '%s\n' devin-ds41 ;;
    devin-ds41-max|builder-ds41-max) printf '%s\n' devin-ds41-max ;;
    devin-fusion-opus55) printf '%s\n' devin-fusion-opus55 ;;
    devin-fusion-sonnet55) printf '%s\n' devin-fusion-sonnet55 ;;
    devin-argon) printf '%s\n' devin-argon ;;
    devin-argon-medium) printf '%s\n' devin-argon-medium ;;
    devin-argon-low) printf '%s\n' devin-argon-low ;;
    *) return 1 ;;
  esac
}
spelling=""
want=""
for spelling in \
  devin-swe2 builder-devin \
  devin-swe2-medium devin-swe2-max devin-swe17 devin-glm52 \
  devin-ds41 devin-ds41-max \
  builder-devin-medium builder-devin-max \
  builder-ds41 builder-ds41-max \
  devin-fusion-opus55 devin-fusion-sonnet55 \
  devin-argon devin-argon-medium devin-argon-low
do
  measure_gate "$WRK" "$spelling"
  want=$(expected_gate "$spelling") || fail "no expected gate for $spelling"
  [[ "$LAST_GATE" == "$want" ]] ||
    fail "$spelling gated as $LAST_GATE, want $want"
  printf 'gate %s -> %s\n' "$spelling" "$LAST_GATE"
done
echo "PASS mapping table"

assert_invariant "$WRK"
echo "PASS invariant: non-SWE-2 spellings do not gate as a SWE-2 profile"

# Mutant: collapse only the paid / non-SWE-2 arms back onto devin-swe2.
# Medium and max SWE-2 seats and the fusion arm stay. The invariant must
# return 1 from its assertion, not from a spawn error.
MUTANT="$TMP/wrk-mutant"
cp "$WRK" "$MUTANT"
chmod +x "$MUTANT"
python3 - "$MUTANT" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = (
    '    devin-swe2-medium|devin-swe2-max|devin-swe17|devin-glm52|devin-ds41|devin-ds41-max) GATE_PROFILE="$MODEL" ;;\n'
    "    builder-devin-medium) GATE_PROFILE=devin-swe2-medium ;;\n"
    "    builder-devin-max) GATE_PROFILE=devin-swe2-max ;;\n"
    "    builder-ds41) GATE_PROFILE=devin-ds41 ;;\n"
    "    builder-ds41-max) GATE_PROFILE=devin-ds41-max ;;\n"
)
new = (
    '    devin-swe2-medium|devin-swe2-max) GATE_PROFILE="$MODEL" ;;\n'
    "    devin-swe17|devin-glm52|devin-ds41|devin-ds41-max) GATE_PROFILE=devin-swe2 ;;\n"
    "    builder-devin-medium) GATE_PROFILE=devin-swe2-medium ;;\n"
    "    builder-devin-max) GATE_PROFILE=devin-swe2-max ;;\n"
    "    builder-ds41|builder-ds41-max) GATE_PROFILE=devin-swe2 ;;\n"
)
fusion = 'devin-fusion-opus55|devin-fusion-sonnet55) GATE_PROFILE="$MODEL" ;;'
count = text.count(old)
if count != 1:
    raise SystemExit(f"mutant anchor count {count}")
text = text.replace(old, new, 1)
if text.count(fusion) != 1:
    raise SystemExit("mutant touched the fusion arm")
if "builder-ds41|builder-ds41-max) GATE_PROFILE=devin-swe2" not in text:
    raise SystemExit("mutant did not collapse builder-ds41")
path.write_text(text, encoding="utf-8")
PY
bash -n "$MUTANT"
set +e
mutant_out=$(assert_invariant "$MUTANT" 2>&1)
mutant_rc=$?
set -e
[[ "$mutant_rc" -eq 1 ]] || fail "mutant invariant rc=$mutant_rc (want assertion 1): $mutant_out"
grep -q 'non-SWE-2 spelling' <<<"$mutant_out" ||
  fail "mutant did not fail by assertion: $mutant_out"
echo "PASS mutant: collapsing non-SWE-2 arms onto devin-swe2 goes RED"

# An installed scopefuel that rejects the name (argparse rc 2) still refuses
# the spawn, before herdr is asked to open a pane.
RC2="$TMP/scopefuel-rc2"
cat >"$RC2" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == gate && "${2:-}" == --help ]]; then
  echo 'usage: scopefuel gate -m PROFILE'
  exit 0
fi
if [[ "${1:-}" == gate ]]; then
  printf '%s\n' "$*" >>"${WRK_SCOPEFUEL_LOG:-/dev/null}"
  echo "error: argument -m/--profile: invalid choice: '$3'" >&2
  exit 2
fi
echo 'fixture: unexpected arguments' >&2
exit 2
EOF
chmod +x "$RC2"
: >"$TMP/scopefuel.log"
# Earlier successful spawns have passive sentinels. Keep this admission
# assertion on its own attempt's log so their late reads cannot contaminate it.
RC2_HERDR_LOG="$TMP/herdr-rc2.log"
: >"$RC2_HERDR_LOG"
set +e
rc2_out=$(TEST_HERDR_LOG="$RC2_HERDR_LOG" spawn_one "$WRK" "$RC2" devin-glm52 --job gp-rc2 --t T1 2>&1)
rc2_rc=$?
set -e
[[ "$rc2_rc" -ne 0 ]] || fail "rc 2 gate must refuse the spawn: $rc2_out"
grep -q 'scopefuel gate failed (exit 2)' <<<"$rc2_out" ||
  fail "rc 2 refusal lost its message: $rc2_out"
[[ ! -s "$RC2_HERDR_LOG" ]] || fail "rc 2 refusal reached herdr: $(cat "$RC2_HERDR_LOG")"
echo "PASS argparse rc 2 still refuses the spawn"

assert_launch() {
  local model="$1" launch="$2" gate="$3" out rc count first got
  JOB_SEQ=$((JOB_SEQ + 1))
  : >"$TMP/scopefuel.log"
  : >"$TMP/herdr.log"
  set +e
  if [[ "$model" == builder-* ]]; then
    out=$(TEST_ARBITER_BIN="$ARBITER" TEST_FIXTURE_SCENARIO=devin-idle \
      spawn_one "$WRK" "$SCOPEFUEL" "$model" --job "gl-$JOB_SEQ" --t T1 \
      --role builder --lane "ln-$JOB_SEQ" --parent parent-lane 2>&1)
  else
    out=$(TEST_ARBITER_BIN="$ARBITER" TEST_FIXTURE_SCENARIO=devin-idle \
      spawn_one "$WRK" "$SCOPEFUEL" "$model" --job "gl-$JOB_SEQ" --t T1 2>&1)
  fi
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || fail "launch spawn $model rc=$rc: $out"
  count=$(grep -c . "$TMP/scopefuel.log" || true)
  first=$(head -n 1 "$TMP/scopefuel.log")
  got=$(tail -n 1 "$TMP/scopefuel.log")
  [[ "$count" -eq 2 && "$first" == "gate -m $gate" && "$got" == "$gate" ]] ||
    fail "$model gate log want -m $gate, got: $(cat "$TMP/scopefuel.log")"
  python3 - "$ARBITER_INBOX_ROOT/gl-$JOB_SEQ/events" "$launch" "$gate" "$model" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text(encoding="utf-8")) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(event for event in events if event.get("kind") == "quota_pool.record")
payload = record["payload"]
launch, gate, model = sys.argv[2], sys.argv[3], sys.argv[4]
assert payload["launch_profile"] == launch, (model, payload)
assert payload["profile"] == gate, (model, payload)
assert payload["pool"] == "devin", (model, payload)
PY
  printf 'launch %s launch_profile=%s gate=%s pool=devin\n' "$model" "$launch" "$gate"
}
assert_launch devin-ds41 devin-ds41 devin-ds41
assert_launch builder-devin-medium builder-devin-medium devin-swe2-medium
assert_launch builder-ds41 builder-ds41 devin-ds41
echo "PASS launch_profile stays the launcher spelling"

run_scopefuel_smoke() {
  local repo="$1" archive venv bindir out err rc name blob verdict
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || fail "SCOPEFUEL_SMOKE_REPO is not a git checkout: $repo"
  git -C "$repo" merge-base --is-ancestor fce4ee1a176510208c4df27309c407855c1845c7 origin/main ||
    fail "scopefuel origin/main is older than fce4ee1"
  command -v prlimit >/dev/null || fail "prlimit is required for the scopefuel smoke"
  command -v timeout >/dev/null || fail "timeout is required for the scopefuel smoke"
  archive="$TMP/scopefuel-src"
  venv="$TMP/scopefuel-venv"
  bindir="$TMP/smoke-bin"
  mkdir -p "$archive" "$bindir" "$TMP/smoke-home" "$TMP/smoke-xdg/data" "$TMP/smoke-xdg/cache" \
    "$TMP/smoke-xdg/config" "$TMP/smoke-xdg/state" "$TMP/smoke-xdg/runtime" \
    "$TMP/smoke-home/.claude" "$TMP/smoke-home/.codex" "$TMP/smoke-home/.kimi"
  chmod 700 "$TMP/smoke-xdg/runtime"
  git -C "$repo" archive --format=tar origin/main | tar -C "$archive" -xf -
  # python3 -m venv needs ensurepip. When that package is absent, uv builds
  # the same throwaway venv. Nothing is installed outside $TMP.
  if python3 -m venv "$venv" >"$TMP/venv-create.err" 2>&1; then
    "$venv/bin/pip" install --disable-pip-version-check -q "$archive"
  elif command -v uv >/dev/null 2>&1; then
    rm -rf "$venv"
    uv venv --python python3 "$venv" >"$TMP/venv-create.err" 2>&1
    uv pip install --python "$venv/bin/python" -q "$archive"
  else
    fail "smoke venv could not be created: $(cat "$TMP/venv-create.err")"
  fi
  [[ -x "$venv/bin/scopefuel" ]] || fail "smoke venv has no scopefuel console script"
  cat >"$bindir/devin" <<'EOF'
#!/usr/bin/env python3
import os
import sys

def reply(text):
    sys.stdout.write(text)
    sys.stdout.flush()

def main():
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == "models" and args[1] == "list":
        reply("SWE-2 (swe-2)\n  swe-2 [Free]\n")
        return 0
    reply("Pro · 90% remaining (resets in 5d)\n")
    reply("❭ Ask Devin to build features, fix bugs, or work on your code\n")
    buf = b""
    while True:
        try:
            chunk = os.read(0, 64)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        while b"\r" in buf or b"\n" in buf:
            cut = len(buf)
            for marker in (b"\r", b"\n"):
                at = buf.find(marker)
                if at != -1 and at < cut:
                    cut = at
            line = buf[: cut + 1]
            buf = buf[cut + 1 :]
            text = line.decode("utf-8", "replace")
            if "/exit" in text:
                return 0
            if "/usage" in text:
                reply("Daily 10% used (resets in 5h)\n")
                reply("Weekly 10% used (resets in 5d)\n")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
EOF
  cat >"$bindir/fast-fail" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$bindir/devin" "$bindir/fast-fail"
  # PATH stubs so collect() cannot launch a real agent. devin itself is the
  # protocol stub above; the other names exit immediately.
  for name in grok kimi kiro-cli claude codex; do
    ln -s fast-fail "$bindir/$name"
  done
  for name in devin-swe2-medium devin-swe2-max devin-swe17 devin-glm52 devin-ds41 devin-ds41-max \
    devin-argon devin-argon-medium devin-argon-low; do
    out="$TMP/smoke-$name.out"
    err="$TMP/smoke-$name.err"
    set +e
    prlimit --as=8589934592 timeout 120 \
      env HOME="$TMP/smoke-home" \
        XDG_DATA_HOME="$TMP/smoke-xdg/data" \
        XDG_CACHE_HOME="$TMP/smoke-xdg/cache" \
        XDG_CONFIG_HOME="$TMP/smoke-xdg/config" \
        XDG_STATE_HOME="$TMP/smoke-xdg/state" \
        XDG_RUNTIME_DIR="$TMP/smoke-xdg/runtime" \
        CLAUDE_CONFIG_DIR="$TMP/smoke-home/.claude" \
        CLAUDE_SECURESTORAGE_CONFIG_DIR="$TMP/smoke-home/.claude-secure" \
        CODEX_HOME="$TMP/smoke-home/.codex" \
        KIMI_CODE_HOME="$TMP/smoke-home/.kimi" \
        PATH="$bindir:$PATH" \
        SCOPEFUEL_DEVIN_BIN="$bindir/devin" \
        SCOPEFUEL_GROK_BIN="$TMP/missing-grok" \
        SCOPEFUEL_KIMI_BIN="$TMP/missing-kimi" \
        SCOPEFUEL_KIRO_BIN="$TMP/missing-kiro" \
        "$venv/bin/scopefuel" gate -m "$name" >"$out" 2>"$err"
    rc=$?
    set -e
    blob=$(cat "$out" "$err" || true)
    if grep -q -e 'unknown profile' -e 'invalid choice' <<<"$blob"; then
      fail "smoke $name was rejected as an unknown profile (rc=$rc)"
    fi
    if [[ "$rc" -ne 0 && "$rc" -ne 3 ]]; then
      fail "smoke $name rc=$rc (want allow 0 or quota deny 3): $(head -n 1 "$err" || true)"
    fi
    if [[ "$rc" -eq 0 ]]; then
      verdict=$(head -n 1 "$out")
    else
      verdict="quota-deny $(head -n 1 "$err")"
    fi
    [[ -n "$verdict" ]] || fail "smoke $name produced an empty verdict"
    printf 'smoke -m %s rc=%s verdict=%s\n' "$name" "$rc" "$verdict"
  done
}

if [[ -n "${SCOPEFUEL_SMOKE_REPO:-}" ]]; then
  run_scopefuel_smoke "$SCOPEFUEL_SMOKE_REPO"
  echo "PASS real scopefuel smoke"
else
  echo "SKIP scopefuel smoke (SCOPEFUEL_SMOKE_REPO unset)"
fi
echo "PASS devin-gate-profile"
