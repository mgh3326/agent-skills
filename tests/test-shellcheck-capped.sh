#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
FAKE_BIN="$TMP/fake-bin"
ARGS_FILE="$TMP/shellcheck-args"
CAPTURE_FILE="$TMP/shellcheck-input"
BYSTANDER_PID_FILE="$TMP/bystander.pid"
SHELLCHECK_PID_FILE="$TMP/shellcheck.pid"
mkdir -p "$FAKE_BIN"

cleanup() {
  local pid pid_file
  for pid_file in "$BYSTANDER_PID_FILE" "$SHELLCHECK_PID_FILE"; do
    if [[ -s "$pid_file" ]]; then
      read -r pid <"$pid_file" || true
      if [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
    fi
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

cat >"$FAKE_BIN/shellcheck" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$SHELLCHECK_ARGS_FILE"
if [[ -n "${SHELLCHECK_PID_FILE:-}" ]]; then printf '%s\n' "$$" >"$SHELLCHECK_PID_FILE"; fi
last=
for arg in "$@"; do last=$arg; done
if [[ -n "${SHELLCHECK_CAPTURE_FILE:-}" && -f "$last" ]]; then cp "$last" "$SHELLCHECK_CAPTURE_FILE"; fi
if [[ -n "${SHELLCHECK_STUB_FAIL_IF_CONTAINS:-}" && -f "$last" ]] \
  && grep -Fq "$SHELLCHECK_STUB_FAIL_IF_CONTAINS" "$last"; then
  exit 1
fi
if [[ -n "${BYSTANDER_PID_FILE:-}" ]]; then
  /bin/sleep 20 &
  printf '%s\n' "$!" >"$BYSTANDER_PID_FILE"
  exec /bin/sleep 4
fi
exit "${SHELLCHECK_STUB_EXIT:-0}"
STUB
cat >"$FAKE_BIN/systemd-run" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
last=
for arg in "$@"; do last=$arg; done
if [[ "$last" == /bin/true ]]; then
  [[ "${SYSTEMD_STUB_MODE:-fail}" == success || "${SYSTEMD_STUB_MODE:-fail}" == oom ]] || exit 1
  printf '%s\n' probe >>"$SYSTEMD_CALLS_FILE"
  exit 0
fi
if [[ "${SYSTEMD_STUB_MODE:-fail}" == oom ]]; then
  printf '%s\n' scope >>"$SYSTEMD_CALLS_FILE"
  exit 137
fi
[[ "${SYSTEMD_STUB_MODE:-fail}" == success ]] || exit 1
printf '%s\n' scope >>"$SYSTEMD_CALLS_FILE"
printf '%s\n' "$@" >"$SYSTEMD_ARGS_FILE"
while (($#)); do
  if [[ "$1" == */shellcheck ]]; then
    shellcheck=$1
    shift
    exec "$shellcheck" "$@"
  fi
  shift
done
exit 2
STUB
cat >"$FAKE_BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *Result*) printf '%s\n' "${SYSTEMD_RESULT:-success}" ;;
  *MemoryPeak*) printf '%s\n' "${SYSTEMD_MEMORY_PEAK:-[not set]}" ;;
  *) exit 2 ;;
esac
STUB
cat >"$FAKE_BIN/ps" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${BYSTANDER_PID_FILE:-}" && ! -s "${BYSTANDER_PID_FILE}" ]]; then
  printf '0\n'
  exit 0
fi
printf '%s\n' "${SHELLCHECK_STUB_RSS_KB:-0}"
STUB
chmod +x "$FAKE_BIN/shellcheck" "$FAKE_BIN/systemd-run" "$FAKE_BIN/systemctl" "$FAKE_BIN/ps"
TEST_PATH="$FAKE_BIN:$PATH"

ci_command=$(awk '
  /^[[:space:]]*-[[:space:]]*name:[[:space:]]*ShellCheck[[:space:]]*$/ { in_step = 1; next }
  in_step && /^[[:space:]]*-[[:space:]]*name:/ { exit }
  in_step && /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ { in_block = 1; next }
  in_step && !in_block && /^[[:space:]]*run:[[:space:]]*/ {
    line = $0
    sub(/^[[:space:]]*run:[[:space:]]*/, "", line)
    print line
    exit
  }
  in_step && in_block {
    line = $0
    sub(/^[[:space:]]*/, "", line)
    if (line == "") next
    continued = (line ~ /\\[[:space:]]*$/)
    sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
    command = command " " line
    if (!continued) {
      print command
      exit
    }
  }
' "$ROOT/.github/workflows/ci.yml")
read -r -a ci_words <<<"$ci_command"
[[ ${ci_words[0]} == shellcheck ]] || { echo 'FAIL: could not parse CI ShellCheck command' >&2; exit 1; }
EXPECTED_FLAGS=()
needs_value() {
  case "$1" in
    -e|-f|-i|-o|-P|-s|-S|--exclude|--format|--include|--enable|--source-path|--shell|--severity) return 0 ;;
    *) return 1 ;;
  esac
}
for ((i = 1; i < ${#ci_words[@]}; i++)); do
  arg=${ci_words[i]}
  [[ "$arg" != -- ]] || break
  [[ "$arg" == -* ]] || break
  EXPECTED_FLAGS+=("$arg")
  if [[ "$arg" != *=* ]] && needs_value "$arg"; then
    ((i + 1 < ${#ci_words[@]})) || { echo 'FAIL: CI ShellCheck option lacks a value' >&2; exit 1; }
    ((i += 1))
    EXPECTED_FLAGS+=("${ci_words[i]}")
  fi
done

assert_exit() {
  local expected=$1
  shift
  local rc=0
  "$@" || rc=$?
  [[ "$rc" == "$expected" ]] || { printf 'FAIL: expected exit %s, got %s\n' "$expected" "$rc" >&2; exit 1; }
}

assert_ci_args() {
  local file=$1
  local expected_file="$TMP/expected-args"
  {
    for flag in "${EXPECTED_FLAGS[@]}"; do printf '%s\n' "$flag"; done
    printf '%s\n' "$file"
  } >"$expected_file"
  diff -u "$expected_file" "$ARGS_FILE"
}

for code in 0 1; do
  rm -f "$ARGS_FILE"
  assert_exit "$code" env PATH="$TEST_PATH" SHELLCHECK_ARGS_FILE="$ARGS_FILE" SHELLCHECK_STUB_EXIT="$code" \
    "$ROOT/scripts/shellcheck-capped" tests/test-wrk.sh
  assert_ci_args tests/test-wrk.sh
  printf 'PASS T1-shellcheck-exit-%s-and-CI-flags\n' "$code"
done

rm -f "$ARGS_FILE" "$TMP/systemd-args" "$TMP/systemd-calls"
assert_exit 0 env PATH="$TEST_PATH" SHELLCHECK_ARGS_FILE="$ARGS_FILE" SHELLCHECK_STUB_EXIT=0 \
  SYSTEMD_STUB_MODE=success SYSTEMD_ARGS_FILE="$TMP/systemd-args" SYSTEMD_CALLS_FILE="$TMP/systemd-calls" \
  "$ROOT/scripts/shellcheck-capped" tests/test-wrk.sh
assert_ci_args tests/test-wrk.sh
grep -Fxq 'MemoryMax=2048M' "$TMP/systemd-args" || { echo 'FAIL T1: cgroup MemoryMax was not applied' >&2; exit 1; }
grep -Fxq 'MemorySwapMax=0' "$TMP/systemd-args" || { echo 'FAIL T1: cgroup swap cap was not applied' >&2; exit 1; }
printf '%s\n' probe scope >"$TMP/expected-systemd-calls"
diff -u "$TMP/expected-systemd-calls" "$TMP/systemd-calls"
echo 'PASS T1-cgroup-cap-probe-and-CI-flags'

rm -f "$ARGS_FILE" "$TMP/systemd-args" "$TMP/systemd-calls"
out="$TMP/cgroup-oom.stdout"
err="$TMP/cgroup-oom.stderr"
rc=0
env PATH="$TEST_PATH" SHELLCHECK_ARGS_FILE="$ARGS_FILE" SYSTEMD_STUB_MODE=oom \
  SYSTEMD_RESULT=oom-kill SYSTEMD_ARGS_FILE="$TMP/systemd-args" SYSTEMD_CALLS_FILE="$TMP/systemd-calls" \
  "$ROOT/scripts/shellcheck-capped" tests/test-wrk.sh >"$out" 2>"$err" || rc=$?
[[ "$rc" == 86 ]] || { printf 'FAIL T2: cgroup OOM should map to 86, got %s\n' "$rc" >&2; exit 1; }
[[ "$(wc -l <"$err" | tr -d '[:space:]')" == 1 ]] || { echo 'FAIL T2: cgroup cap should emit one stderr line' >&2; exit 1; }
grep -Fxq 'shellcheck-capped: shellcheck exceeded 2048 MB on tests/test-wrk.sh; run it in CI or use --changed BASE' "$err" || {
  echo 'FAIL T2: cgroup cap diagnostic missing' >&2
  exit 1
}
[[ ! -e "$ARGS_FILE" ]] || { echo 'FAIL T2: shellcheck ran after cgroup OOM' >&2; exit 1; }
echo 'PASS T2-cgroup-oom-maps-to-cap-exit'

rm -f "$ARGS_FILE" "$BYSTANDER_PID_FILE" "$SHELLCHECK_PID_FILE"
out="$TMP/cap.stdout"
err="$TMP/cap.stderr"
rc=0
env PATH="$TEST_PATH" SHELLCHECK_ARGS_FILE="$ARGS_FILE" SHELLCHECK_STUB_RSS_KB=524289 \
  BYSTANDER_PID_FILE="$BYSTANDER_PID_FILE" SHELLCHECK_PID_FILE="$SHELLCHECK_PID_FILE" \
  "$ROOT/scripts/shellcheck-capped" --cap-mb 512 tests/test-wrk.sh >"$out" 2>"$err" || rc=$?
[[ "$rc" == 86 ]] || { printf 'FAIL T2: expected exit 86, got %s\n' "$rc" >&2; exit 1; }
grep -Fxq 'shellcheck-capped: shellcheck exceeded 512 MB on tests/test-wrk.sh; run it in CI or use --changed BASE' "$err" || {
  echo 'FAIL T2: expected the cap diagnostic' >&2
  exit 1
}
[[ "$(wc -l <"$err" | tr -d '[:space:]')" == 1 ]] || { echo 'FAIL T2: expected one stderr line' >&2; exit 1; }
read -r stub_pid <"$SHELLCHECK_PID_FILE"
if kill -0 "$stub_pid" 2>/dev/null; then echo 'FAIL T2: shellcheck stub survived the cap' >&2; exit 1; fi
read -r bystander_pid <"$BYSTANDER_PID_FILE"
kill -0 "$bystander_pid" 2>/dev/null || { echo 'FAIL T2: bystander process was signalled' >&2; exit 1; }
echo 'PASS T2-watchdog-stops-only-shellcheck'

for bad in 100 99999 abc; do
  rm -f "$ARGS_FILE"
  assert_exit 2 env PATH="$TEST_PATH" SHELLCHECK_ARGS_FILE="$ARGS_FILE" SHELLCHECK_STUB_EXIT=0 "$ROOT/scripts/shellcheck-capped" --cap-mb "$bad" tests/test-wrk.sh
  [[ ! -e "$ARGS_FILE" ]] || { echo "FAIL T3: shellcheck ran for invalid cap $bad" >&2; exit 1; }
  printf 'PASS T3-reject-cap-%s\n' "$bad"
done

CHANGE_REPO="$TMP/change-repo"
mkdir -p "$CHANGE_REPO/scripts" "$CHANGE_REPO/bin" "$CHANGE_REPO/tests" "$CHANGE_REPO/.github/workflows"
cp "$ROOT/scripts/shellcheck-capped" "$CHANGE_REPO/scripts/shellcheck-capped"
cp "$ROOT/.github/workflows/ci.yml" "$CHANGE_REPO/.github/workflows/ci.yml"
cat >"$CHANGE_REPO/bin/wrk" <<'FIXTURE'
#!/bin/bash
# shellcheck disable=SC2034
# fixture header comment
set -e
unchanged_function() {
  echo unchanged
}
changed_function() {
  false || {
    echo brace group
  }
  awk '
    function nested() {
      print "brace"
    }
  '
  cat <<'PY'
}
heredoc content
PY
  echo old
}
sentinel_after_t4() {
  echo sentinel must not be included
}
FIXTURE
printf '%s\n' 'echo whole-file' >"$CHANGE_REPO/tests/whole.sh"
git -C "$CHANGE_REPO" init -q --initial-branch=main
git -C "$CHANGE_REPO" config user.name 'ShellCheck Capped Test'
git -C "$CHANGE_REPO" config user.email shellcheck-capped@example.invalid
git -C "$CHANGE_REPO" add bin/wrk tests/whole.sh .github/workflows/ci.yml scripts/shellcheck-capped
git -C "$CHANGE_REPO" commit -qm 'fixture base'
base=$(git -C "$CHANGE_REPO" rev-parse HEAD)
cat >"$CHANGE_REPO/bin/wrk" <<'FIXTURE'
#!/bin/bash
# shellcheck disable=SC2034
# fixture header comment
set -e
unchanged_function() {
  echo unchanged
}
changed_function() {
  false || {
    echo brace group
  }
  awk '
    function nested() {
      print "brace"
    }
  '
  cat <<'PY'
}
heredoc content
PY
  echo new
}
sentinel_after_t4() {
  echo sentinel must not be included
}
FIXTURE
git -C "$CHANGE_REPO" add bin/wrk
git -C "$CHANGE_REPO" commit -qm 'change fixture function'
rm -f "$ARGS_FILE" "$CAPTURE_FILE"
out="$TMP/changed.stdout"
env PATH="$TEST_PATH" SHELLCHECK_ARGS_FILE="$ARGS_FILE" SHELLCHECK_CAPTURE_FILE="$CAPTURE_FILE" \
  SHELLCHECK_STUB_EXIT=0 SHELLCHECK_STUB_RSS_KB=0 \
  "$CHANGE_REPO/scripts/shellcheck-capped" --changed "$base" -- tests/whole.sh bin/wrk >"$out"
grep -Fxq 'shellcheck-capped: --changed is advisory; selected bin/wrk functions lack full-file context' "$out" || {
  echo 'FAIL T4: advisory line missing' >&2
  exit 1
}
grep -Fxq tests/whole.sh "$ARGS_FILE" || { echo 'FAIL T4: non-bin/wrk file was not checked whole' >&2; exit 1; }
grep -Fxq '#!/bin/bash' "$CAPTURE_FILE" || { echo 'FAIL T4: source shebang missing from changed-function input' >&2; exit 1; }
grep -Fxq '# shellcheck disable=SC2034' "$CAPTURE_FILE" || { echo 'FAIL T4: global shellcheck directive missing' >&2; exit 1; }
grep -Fq 'changed_function() {' "$CAPTURE_FILE" || { echo 'FAIL T4: changed function missing' >&2; exit 1; }
grep -Fq 'echo brace group' "$CAPTURE_FILE" || { echo 'FAIL T4: function stopped at brace-group close' >&2; exit 1; }
grep -Fq 'print "brace"' "$CAPTURE_FILE" || { echo 'FAIL T4: function stopped inside quoted awk program' >&2; exit 1; }
grep -Fxq 'heredoc content' "$CAPTURE_FILE" || { echo 'FAIL T4: function extraction stopped inside a heredoc' >&2; exit 1; }
grep -Fq 'echo new' "$CAPTURE_FILE" || { echo 'FAIL T4: changed function body missing' >&2; exit 1; }
bash -n "$CAPTURE_FILE" || { echo 'FAIL T4: extracted function is not valid shell syntax' >&2; exit 1; }
if grep -Fq 'unchanged_function() {' "$CAPTURE_FILE"; then echo 'FAIL T4: unchanged function included' >&2; exit 1; fi
echo 'PASS T4-changed-function-advisory-and-whole-other-files'

awk '$0 == "  echo new" { print "  echo uncommitted bad edit" } { print }' \
  "$CHANGE_REPO/bin/wrk" >"$TMP/dirty-wrk"
mv "$TMP/dirty-wrk" "$CHANGE_REPO/bin/wrk"
rm -f "$ARGS_FILE" "$CAPTURE_FILE"
rc=0
env PATH="$TEST_PATH" SHELLCHECK_ARGS_FILE="$ARGS_FILE" SHELLCHECK_CAPTURE_FILE="$CAPTURE_FILE" \
  SHELLCHECK_STUB_EXIT=0 SHELLCHECK_STUB_RSS_KB=0 SHELLCHECK_STUB_FAIL_IF_CONTAINS='uncommitted bad edit' \
  "$CHANGE_REPO/scripts/shellcheck-capped" --changed "$base" -- bin/wrk >/dev/null || rc=$?
[[ "$rc" == 1 ]] || { printf 'FAIL T4: expected uncommitted bad edit to fail stub ShellCheck, got %s\n' "$rc" >&2; exit 1; }
grep -Fq 'echo uncommitted bad edit' "$CAPTURE_FILE" || { echo 'FAIL T4: working-tree edit missing from extracted function' >&2; exit 1; }
if grep -Fq 'sentinel_after_t4() {' "$CAPTURE_FILE"; then echo 'FAIL T4: unchanged function included with working-tree edit' >&2; exit 1; fi
echo 'PASS T4-uncommitted-working-tree-edit-is-checked'

for syntax_case in herestring arithmetic; do
  shape_repo="$TMP/$syntax_case-repo"
  mkdir -p "$shape_repo/scripts" "$shape_repo/bin" "$shape_repo/.github/workflows"
  cp "$ROOT/scripts/shellcheck-capped" "$shape_repo/scripts/shellcheck-capped"
  cp "$ROOT/.github/workflows/ci.yml" "$shape_repo/.github/workflows/ci.yml"
  cat >"$shape_repo/bin/wrk" <<'BASE'
#!/bin/bash
sentinel_after_shape() {
  echo sentinel
}
BASE
  git -C "$shape_repo" init -q --initial-branch=main
  git -C "$shape_repo" config user.name 'ShellCheck Capped Test'
  git -C "$shape_repo" config user.email shellcheck-capped@example.invalid
  git -C "$shape_repo" add bin/wrk scripts/shellcheck-capped .github/workflows/ci.yml
  git -C "$shape_repo" commit -qm 'shape fixture base'
  shape_base=$(git -C "$shape_repo" rev-parse HEAD)
  case "$syntax_case" in
    herestring)
      cat >"$shape_repo/bin/wrk" <<'FIXTURE'
#!/bin/bash
changed_herestring_function() {
  cat <<<'token'
  echo here-string body
}
sentinel_after_shape() {
  echo sentinel
}
FIXTURE
      ;;
    arithmetic)
      cat >"$shape_repo/bin/wrk" <<'FIXTURE'
#!/bin/bash
changed_arithmetic_function() {
  shifted=$((x<<2))
  echo arithmetic body
}
sentinel_after_shape() {
  echo sentinel
}
FIXTURE
      ;;
  esac
  git -C "$shape_repo" add bin/wrk
  git -C "$shape_repo" commit -qm "add $syntax_case fixture"
  rm -f "$ARGS_FILE" "$CAPTURE_FILE"
  env PATH="$TEST_PATH" SHELLCHECK_ARGS_FILE="$ARGS_FILE" SHELLCHECK_CAPTURE_FILE="$CAPTURE_FILE" \
    SHELLCHECK_STUB_EXIT=0 SHELLCHECK_STUB_RSS_KB=0 \
    "$shape_repo/scripts/shellcheck-capped" --changed "$shape_base" -- bin/wrk >/dev/null
  grep -Fq "changed_${syntax_case}_function() {" "$CAPTURE_FILE" || {
    echo "FAIL T4: $syntax_case function missing" >&2
    exit 1
  }
  if grep -Fq 'sentinel_after_shape() {' "$CAPTURE_FILE"; then
    echo "FAIL T4: $syntax_case was mistaken for a heredoc" >&2
    exit 1
  fi
  bash -n "$CAPTURE_FILE" || { echo "FAIL T4: $syntax_case extraction is invalid shell syntax" >&2; exit 1; }
  printf 'PASS T4-%s-not-heredoc\n' "$syntax_case"
done

cat >"$CHANGE_REPO/.github/workflows/ci.yml" <<'FIXTURE'
name: CI
jobs:
  check:
    steps:
      - name: ShellCheck
        run: |
          shellcheck -x -e SC2034 --severity=warning bin/wrk
FIXTURE
rm -f "$ARGS_FILE"
env PATH="$TEST_PATH" SHELLCHECK_ARGS_FILE="$ARGS_FILE" SHELLCHECK_STUB_EXIT=0 \
  "$CHANGE_REPO/scripts/shellcheck-capped" tests/whole.sh >/dev/null
printf '%s\n' -x -e SC2034 --severity=warning tests/whole.sh >"$TMP/expected-synthetic-args"
diff -u "$TMP/expected-synthetic-args" "$ARGS_FILE"
echo 'PASS T5-synthetic-CI-flags-forwarded'

rm -f "$ARGS_FILE"
assert_exit 0 env PATH="$TEST_PATH" SHELLCHECK_ARGS_FILE="$ARGS_FILE" SHELLCHECK_STUB_EXIT=0 "$ROOT/scripts/shellcheck-capped" tests/test-wrk.sh
assert_ci_args tests/test-wrk.sh
echo 'PASS T5-wrapper-flags-match-parsed-CI-step'

echo 'PASS test-shellcheck-capped (14 assertions)'
